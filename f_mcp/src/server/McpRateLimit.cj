/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_mcp.server

import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64
import fountain::f_concurrent.{AnyMomentRateLimiter, LeakingBucketRateLimiter, RateLimiter, SlidingWindowRateLimiter,
    TokenBucketRateLimiter, UnlimitedRateLimiter}
import fountain::f_data.*

/** 全局默认限流值；`None` 表示该维度不限制。 */
public struct RateLimitPolicy {
    public const RateLimitPolicy(public let perCallerRpm!: ?Int64 = None, public let perCallerToolRpm!: ?Int64 = None,
        public let perToolRpm!: ?Int64 = None, public let maxConcurrency!: ?Int64 = None,
        public let perCallerConcurrency!: ?Int64 = None) {}
}

/** 工具级覆盖；字段为 `None` 时沿用服务级 / 全局。 */
public struct ToolRateLimit {
    public const ToolRateLimit(public let perCallerRpm!: ?Int64 = None, public let perCallerToolRpm!: ?Int64 = None,
        public let perToolRpm!: ?Int64 = None, public let maxConcurrency!: ?Int64 = None,
        public let perCallerConcurrency!: ?Int64 = None) {}
}

struct ResolvedRateLimit {
    let perCallerRpm: ?Int64
    let perCallerToolRpm: ?Int64
    let perToolRpm: ?Int64
    let maxConcurrency: ?Int64
    let perCallerConcurrency: ?Int64

    const init(perCallerRpm: ?Int64, perCallerToolRpm: ?Int64, perToolRpm: ?Int64, maxConcurrency: ?Int64,
        perCallerConcurrency: ?Int64) {
        this.perCallerRpm = perCallerRpm
        this.perCallerToolRpm = perCallerToolRpm
        this.perToolRpm = perToolRpm
        this.maxConcurrency = maxConcurrency
        this.perCallerConcurrency = perCallerConcurrency
    }
}

/** 限流 / 并发闸门共用的判定结果。 */
struct RateVerdict {
    let ok: Bool
    let scope: String
    let limit: Int64
    let retryAfterMs: Int64

    const init(ok: Bool, scope: String, limit: Int64, retryAfterMs: Int64) {
        this.ok = ok
        this.scope = scope
        this.limit = limit
        this.retryAfterMs = retryAfterMs
    }

    static func pass(): RateVerdict {
        RateVerdict(true, '', 0, 0)
    }

    static func reject(scope: String, limit: Int64, retryAfterMs: Int64): RateVerdict {
        RateVerdict(false, scope, limit, retryAfterMs)
    }
}

/**
 * 限流后端 SPI。默认实现是进程内令牌桶；多实例部署时注入共享存储实现。
 */
public interface RateLimitBackend {
    /** 算法名；`RateLimitBackends.register<T>()` 用它作为注册键。 */
    static prop name: String

    /** 创建一个新的后端实例。 */
    static func new(): RateLimitBackend

    /** 消耗一个令牌；`rpm` 为每分钟配额。 */
    func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool
    func close(): Unit
}

/** 每个限流 key 对应一个 limiter；key 上带 `rpm`，配额变化时自动换新桶。 */
class LimiterPool {
    private let limiters = ConcurrentHashMap<String, RateLimiter<Bool>>()
    private let factory: (Int64) -> RateLimiter<Bool>

    init(factory: (Int64) -> RateLimiter<Bool>) {
        this.factory = factory
    }

    func acquire(key: String, rpm: Int64): Bool {
        if (rpm <= 0) {
            return true
        }
        let bucketKey = '${key}#${rpm}'
        var limiter = limiters.get(bucketKey)
        if (limiter.isNone()) {
            limiters.addIfAbsent(bucketKey, factory(rpm))
            limiter = limiters.get(bucketKey)
        }
        limiter.getOrThrow().exec(Some(false), {=> Some(true)}) ?? false
    }

    func close(): Unit {
        // f_concurrent 的限流器没有 close 接口；这里只清空映射，
        // 定时器在进程退出时由 f_concurrent 的 atExit 统一取消。
        for ((key, _) in limiters) {
            limiters.remove(key)
        }
    }
}

/**
 * 令牌桶：容量 = `rpm`，每分钟补满，允许一次性用完一分钟配额。
 */
public class TokenBucketRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'token-bucket'
        }
    }

    public static func new(): RateLimitBackend {
        TokenBucketRateLimitBackend()
    }

    private let pool = LimiterPool({
        rpm: Int64 => TokenBucketRateLimiter<Bool>(tokens: rpm, timeout: Duration.millisecond,
            populationPeriod: Duration.minute)
    })

    public func tryAcquire(key: String, rpm: Int64, _: Int64): Bool {
        pool.acquire(key, rpm)
    }

    public func close(): Unit {
        pool.close()
    }
}

/**
 * 漏桶：每分钟漏出 `rpm` 个，等待队列上限也是 `rpm`。
 */
public class LeakingBucketRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'leaking-bucket'
        }
    }

    public static func new(): RateLimitBackend {
        LeakingBucketRateLimitBackend()
    }

    private let pool = LimiterPool({
        rpm: Int64 => LeakingBucketRateLimiter<Bool>(timeout: Duration.millisecond * 5, maxWaitings: rpm,
            leakingPerDuration: rpm, leakingDuration: Duration.minute)
    })

    public func tryAcquire(key: String, rpm: Int64, _: Int64): Bool {
        pool.acquire(key, rpm)
    }

    public func close(): Unit {
        pool.close()
    }
}

/**
 * 滑动窗口：窗口 1 分钟、上限 `rpm`。
 */
public class SlidingWindowRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'sliding-window'
        }
    }

    public static func new(): RateLimitBackend {
        SlidingWindowRateLimitBackend()
    }

    private let pool = LimiterPool({
        rpm: Int64 => SlidingWindowRateLimiter<Bool>(window: Duration.minute, timeout: Duration.millisecond * 5,
            limit: rpm)
    })

    public func tryAcquire(key: String, rpm: Int64, _: Int64): Bool {
        pool.acquire(key, rpm)
    }

    public func close(): Unit {
        pool.close()
    }
}

/**
 * 任意时刻限流：把 `rpm` 当作**瞬时并发上限**，不是每分钟配额。
 *
 * `RateLimitBackend` 只有 acquire 没有 release，而 `AnyMomentRateLimiter`
 * 限制的是同时执行的任务数，因此这里只能在判定期间短暂占用槽位；
 * 它适合对比/实验，不建议用来表达「每分钟 rpm 次」。
 */
public class AnyMomentRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'any-moment'
        }
    }

    public static func new(): RateLimitBackend {
        AnyMomentRateLimitBackend()
    }

    private let pool = LimiterPool({
        rpm: Int64 => AnyMomentRateLimiter<Bool>(maxTokens: rpm, timeout: Duration.millisecond)
    })

    public func tryAcquire(key: String, rpm: Int64, _: Int64): Bool {
        pool.acquire(key, rpm)
    }

    public func close(): Unit {
        pool.close()
    }
}

/** 不限制：始终放行。 */
public class UnlimitedRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'unlimited'
        }
    }

    public static func new(): RateLimitBackend {
        UnlimitedRateLimitBackend()
    }

    private let limiter = UnlimitedRateLimiter<Bool>()

    public func tryAcquire(_: String, _: Int64, _: Int64): Bool {
        limiter.exec(Some(false), {=> Some(true)}) ?? false
    }

    public func close(): Unit {}
}

/** 内置 `RateLimitBackend` 的注册表与工厂。 */
public class RateLimitBackends {
    public static const DEFAULT_NAME = 'token-bucket'

    private static let backends = ConcurrentHashMap<String, () -> RateLimitBackend>()

    static init() {
        register<TokenBucketRateLimitBackend>()
        register<LeakingBucketRateLimitBackend>()
        register<SlidingWindowRateLimitBackend>()
        register<AnyMomentRateLimitBackend>()
        register<UnlimitedRateLimitBackend>()
    }

    /**
     * 注册自定义后端；同名重复注册会覆盖。
     *
     * 注册键是 `T.name`，大小写与 `-` / `_` 不敏感。
     */
    public static func register<T>(): Unit where T <: RateLimitBackend {
        backends.add(normalize(T.name), T.new)
    }

    /** 按名字创建后端；未注册时抛 `IllegalArgumentException`。 */
    public static func of(name: String): RateLimitBackend {
        match (backends.get(normalize(name))) {
            case Some(factory) => factory()
            case _ => throw IllegalArgumentException("unknown rate limit backend '${name}'")
        }
    }

    /** 读取 `mcp_rateLimitBackend`；未配置时返回令牌桶。未知名字直接报错。 */
    public static func fromConfig(): RateLimitBackend {
        let name = McpConfig.rateLimitBackendName()
        if (name.isEmpty()) {
            return of(DEFAULT_NAME)
        }
        match (backends.get(normalize(name))) {
            case Some(factory) => factory()
            case _ => throw IllegalArgumentException("unknown ${McpConfig.RATE_LIMIT_BACKEND} '${name}'")
        }
    }

    private static func normalize(name: String): String {
        name.trimAscii().toAsciiLower().replace('-', '').replace('_', '')
    }
}

/** 并发闸门：全局总并发 + 调用方（或调用方×工具）子并发。 */
public class ConcurrencyGate {
    private let counts = ConcurrentHashMap<String, AtomicInt64>()

    public func tryAcquire(key: String, limit: Int64): Bool {
        if (limit <= 0) {
            return true
        }
        var counter = counts.get(key)
        if (counter.isNone()) {
            counts.addIfAbsent(key, AtomicInt64(0))
            counter = counts.get(key)
        }
        let atomic = counter.getOrThrow()
        while (true) {
            let current = atomic.load()
            if (current >= limit) {
                return false
            }
            if (atomic.compareAndSwap(current, current + 1)) {
                return true
            }
        }
        false
    }

    public func release(key: String): Unit {
        match (counts.get(key)) {
            case Some(atomic) =>
                let remaining = atomic.fetchAdd(-1) - 1
                if (remaining <= 0) {
                    counts.remove(key)
                }
            case _ => ()
        }
    }

    public func close(): Unit {
        for ((key, _) in counts) {
            counts.remove(key)
        }
    }

    public func size(): Int64 {
        counts.size
    }
}
