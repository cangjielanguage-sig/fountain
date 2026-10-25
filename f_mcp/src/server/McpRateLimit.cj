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
import std.time.MonoTime
import fountain::f_concurrent.{LeakingBucketRateLimiter, RateLimiter, SlidingWindowRateLimiter,
    TokenBucketRateLimiter, UnlimitedRateLimiter}
import fountain::f_data.*

/** 全局默认限流值；`None` 表示该维度不限制。 */
public struct RateLimitPolicy {
    public const RateLimitPolicy(public let perCallerRpm!: ?Int64 = None, public let perCallerToolRpm!: ?Int64 = None,
        public let perToolRpm!: ?Int64 = None, public let maxConcurrency!: ?Int64 = None,
        public let perCallerConcurrency!: ?Int64 = None) {}

    /** 逐字段合并：`override` 有值的字段覆盖 `this`，没写的字段继承。 */
    public func overlay(override: RateLimitPolicy): RateLimitPolicy {
        RateLimitPolicy(
            perCallerRpm: override.perCallerRpm ?? perCallerRpm,
            perCallerToolRpm: override.perCallerToolRpm ?? perCallerToolRpm,
            perToolRpm: override.perToolRpm ?? perToolRpm,
            maxConcurrency: override.maxConcurrency ?? maxConcurrency,
            perCallerConcurrency: override.perCallerConcurrency ?? perCallerConcurrency)
    }
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
    /** 服务级全局并发上限：只取 `RateLimitPolicy.maxConcurrency`。 */
    let globalConcurrency: ?Int64
    /** 工具并发上限：只取 `ToolRateLimit.maxConcurrency`。 */
    let toolConcurrency: ?Int64
    let perCallerConcurrency: ?Int64

    const init(perCallerRpm: ?Int64, perCallerToolRpm: ?Int64, perToolRpm: ?Int64, globalConcurrency: ?Int64,
        toolConcurrency: ?Int64, perCallerConcurrency: ?Int64) {
        this.perCallerRpm = perCallerRpm
        this.perCallerToolRpm = perCallerToolRpm
        this.perToolRpm = perToolRpm
        this.globalConcurrency = globalConcurrency
        this.toolConcurrency = toolConcurrency
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

/** 池内条目：limiter 本体 + 最近使用时间（相对池创建时刻的纳秒数）。 */
class LimiterEntry {
    let limiter: RateLimiter<Bool>
    let lastUsed: AtomicInt64

    LimiterEntry(limiter: RateLimiter<Bool>, now: Int64) {
        this.limiter = limiter
        this.lastUsed = AtomicInt64(now)
    }
}

/**
 * 每个限流 key 对应一个 limiter；key 上带 `rpm`，配额变化时自动换新桶。
 *
 * 有界 + 空闲 TTL：以调用方为 key 的容器如果只增不删，每个 key 都会常驻一个
 * 定时器和队列，进程跑久了就是内存与线程泄漏。
 */
class LimiterPool {
    private let limiters = ConcurrentHashMap<String, LimiterEntry>()
    private let factory: (Int64) -> RateLimiter<Bool>
    private let maxSize: Int64
    private let idleTtlNanos: Int64
    private let origin = MonoTime.now()
    private let ops = AtomicInt64(0)

    init(factory: (Int64) -> RateLimiter<Bool>, maxSize!: Int64 = 10_000,
        idleTtl!: Duration = Duration.minute * 10) {
        this.factory = factory
        this.maxSize = maxSize
        this.idleTtlNanos = idleTtl.toNanoseconds()
    }

    func acquire(key: String, rpm: Int64): Bool {
        if (rpm <= 0) {
            return true
        }
        let bucketKey = '${key}#${rpm}'
        let now = (MonoTime.now() - origin).toNanoseconds()
        var entry = limiters.get(bucketKey)
        if (entry.isNone()) {
            limiters.addIfAbsent(bucketKey, LimiterEntry(factory(rpm), now))
            entry = limiters.get(bucketKey)
        }
        let e = entry.getOrThrow()
        e.lastUsed.store(now)
        if (ops.fetchAdd(1) % 256 == 0) {
            sweep(now)
        }
        e.limiter.exec(Some(false), {=> Some(true)}) ?? false
    }

    prop size: Int64 {
        get() {
            limiters.size
        }
    }

    /** 主动清理（测试与 `close` 兼容用）：淘汰的 limiter 必须 `close()`。 */
    func sweepNow(): Unit {
        sweep((MonoTime.now() - origin).toNanoseconds())
    }

    func close(): Unit {
        for ((key, _) in limiters) {
            if (let Some(removed) <- limiters.remove(key)) {
                removed.limiter.close()
            }
        }
    }

    private func sweep(now: Int64): Unit {
        for ((key, entry) in limiters) {
            if (now - entry.lastUsed.load() > idleTtlNanos) {
                if (let Some(removed) <- limiters.remove(key)) {
                    removed.limiter.close()
                }
            }
        }
        while (limiters.size > maxSize) {
            var oldestKey = ''
            var oldest = Int64.Max
            for ((key, entry) in limiters) {
                let used = entry.lastUsed.load()
                if (used < oldest) {
                    oldest = used
                    oldestKey = key
                }
            }
            if (oldestKey.isEmpty()) {
                break
            }
            if (let Some(removed) <- limiters.remove(oldestKey)) {
                removed.limiter.close()
            } else {
                break
            }
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

/** 并发闸门条目：计数 + 最近使用时间，`release` 到 0 也不删 key。 */
class GateEntry {
    let count: AtomicInt64
    let lastUsed: AtomicInt64

    GateEntry(now: Int64) {
        this.count = AtomicInt64(0)
        this.lastUsed = AtomicInt64(now)
    }
}

/**
 * 并发闸门：全局总并发 / 工具并发 / 调用方（或调用方×工具）子并发。
 *
 * `release` 只减计数、不删 key：删 key 会与并发的 `tryAcquire` 竞态，
 * 导致新条目从 0 开始计数、别人的计数被吞掉。空闲条目由 TTL / 容量回收。
 */
public class ConcurrencyGate {
    private let counts = ConcurrentHashMap<String, GateEntry>()
    private let maxSize: Int64
    private let idleTtlNanos: Int64
    private let origin = MonoTime.now()
    private let ops = AtomicInt64(0)

    public init(maxSize!: Int64 = 10_000, idleTtl!: Duration = Duration.minute * 10) {
        this.maxSize = maxSize
        this.idleTtlNanos = idleTtl.toNanoseconds()
    }

    /** `limit <= 0` 表示不限制，返回 `false`（未占槽，调用方不要释放）。 */
    public func tryAcquire(key: String, limit: Int64): Bool {
        if (limit <= 0) {
            return false
        }
        let now = (MonoTime.now() - origin).toNanoseconds()
        var entry = counts.get(key)
        if (entry.isNone()) {
            counts.addIfAbsent(key, GateEntry(now))
            entry = counts.get(key)
        }
        let found = entry.getOrThrow()
        found.lastUsed.store(now)
        if (ops.fetchAdd(1) % 256 == 0) {
            sweep(now)
        }
        while (true) {
            let current = found.count.load()
            if (current >= limit) {
                return false
            }
            if (found.count.compareAndSwap(current, current + 1)) {
                return true
            }
        }
        false
    }

    public func release(key: String): Unit {
        match (counts.get(key)) {
            case Some(entry) =>
                while (true) {
                    let current = entry.count.load()
                    if (current <= 0) {
                        return
                    }
                    if (entry.count.compareAndSwap(current, current - 1)) {
                        return
                    }
                }
            case _ => ()
        }
    }

    public func close(): Unit {
        for ((key, _) in counts) {
            counts.remove(key)
        }
    }

    /** 当前 key 数（不含已经回收的空闲条目）。 */
    public func size(): Int64 {
        counts.size
    }

    /** 主动回收空闲条目（测试用）。 */
    public func sweepNow(): Unit {
        sweep((MonoTime.now() - origin).toNanoseconds())
    }

    private func sweep(now: Int64): Unit {
        for ((key, entry) in counts) {
            if (entry.count.load() == 0 && now - entry.lastUsed.load() > idleTtlNanos) {
                counts.remove(key)
            }
        }
        while (counts.size > maxSize) {
            var oldestKey = ''
            var oldest = Int64.Max
            for ((key, entry) in counts) {
                let used = entry.lastUsed.load()
                if (used < oldest) {
                    oldest = used
                    oldestKey = key
                }
            }
            if (oldestKey.isEmpty() || !counts.remove(oldestKey).isSome()) {
                break
            }
        }
    }
}

/** 并发槽位的释放凭据：只释放真正占到的 key（key 自带，避免释放时丢参数）。 */
struct ConcurrencyLease {
    let verdict: RateVerdict
    let global: Bool
    let toolKey: String
    let callerKey: String

    const init(verdict: RateVerdict, global: Bool, toolKey!: String = '', callerKey!: String = '') {
        this.verdict = verdict
        this.global = global
        this.toolKey = toolKey
        this.callerKey = callerKey
    }
}
