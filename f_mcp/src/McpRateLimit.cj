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
package fountain::f_mcp

import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64
import fountain::f_concurrent.TokenBucketRateLimiter
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
    /** 消耗一个令牌；`rpm` 为每分钟配额。 */
    func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool
    func close(): Unit
}

class LimiterEntry {
    let limiter: TokenBucketRateLimiter<Bool>

    init(rpm: Int64) {
        this.limiter = TokenBucketRateLimiter<Bool>(
            tokens: rpm,
            timeout: Duration.millisecond,
            populationPeriod: Duration.minute)
    }
}

/**
 * 进程内限流后端：每个 key 一个 f_concurrent 令牌桶。
 *
 * 进程内实现无法跨进程共享计数；多实例部署时注入基于 Redis / 数据库的
 * `RateLimitBackend`，本类只作为单实例默认值。
 */
public class LocalRateLimitBackend <: RateLimitBackend {
    private let limiters = ConcurrentHashMap<String, LimiterEntry>()

    public func tryAcquire(key: String, rpm: Int64, _: Int64): Bool {
        if (rpm <= 0) {
            return true
        }
        let bucketKey = '${key}#${rpm}'
        var entry = limiters.get(bucketKey)
        if (entry.isNone()) {
            limiters.addIfAbsent(bucketKey, LimiterEntry(rpm))
            entry = limiters.get(bucketKey)
        }
        entry.getOrThrow().limiter.exec(Some(false), {=> Some(true)}) ?? false
    }

    public func close(): Unit {
        // f_concurrent 的令牌桶没有 close 接口；这里只清空映射，
        // 定时器在进程退出时由 f_concurrent 的 atExit 统一取消。
        for ((key, _) in limiters) {
            limiters.remove(key)
        }
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
