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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.random.Random
import std.sync.{AtomicInt64, Mutex}
import std.time.DateTime
import stdx.log.LogLevel
import fountain::f_log.impl.*
import fountain::f_mcp.base.*

public struct ResultStoreOptions {
    public const ResultStoreOptions(public let maxEntries!: Int64 = 256, public let maxBytes!: Int64 = 256 * 1024 * 1024,
        public let ttlMillis!: Int64 = 10 * 60 * 1000, public let adaptive!: Bool = true,
        public let windowMillis!: Int64 = 5 * 60 * 1000, public let rejectRateThreshold!: Float64 = 0.01,
        public let floor!: Int64 = 128, public let ceiling!: Int64 = 1024, public let shrinkConfirmWindows!: Int64 = 3) {}
}

class ResultEntry {
    let content: ResourceContent
    let bytes: Int64
    let createdAtNanos: Int64

    init(content: ResourceContent, bytes: Int64, createdAtNanos: Int64) {
        this.content = content
        this.bytes = bytes
        this.createdAtNanos = createdAtNanos
    }
}

class ByteBudget {
    private let used = AtomicInt64(0)

    func reserve(bytes: Int64, max: Int64): Bool {
        while (true) {
            let current = used.load()
            if (current + bytes > max) {
                return false
            }
            if (used.compareAndSwap(current, current + bytes)) {
                return true
            }
        }
        false
    }

    func release(bytes: Int64): Unit {
        used.fetchAdd(-bytes)
    }

    func value(): Int64 {
        used.load()
    }
}

/**
 * 大结果的临时存储：条数、总字节、TTL 三重约束；CAS 预留字节；惰性回收。
 * `maxEntries` 可在运行期按窗口统计自适应调整（只调这一个维度）。
 */
public class ToolResultStore {
    static let log = LoggerFactory.getLogger<ToolResultStore>()

    private let options: ResultStoreOptions
    private let entries = ConcurrentHashMap<String, ResultEntry>()
    private let budget = ByteBudget()

    private let maxEntries: AtomicInt64
    private let count = AtomicInt64(0)
    private let puts = AtomicInt64(0)
    private let rejectedByCount = AtomicInt64(0)
    private let rejectedByBytes = AtomicInt64(0)

    private let windowMutex = Mutex()
    private let windowStartNanos = AtomicInt64(nowNanos())
    private let lastSweepNanos = AtomicInt64(0)
    private let sweeps = AtomicInt64(0)
    private let windowLocks = AtomicInt64(0)
    private var lastPuts = 0
    private var lastRejectedByCount = 0
    private var lastRejectedByBytes = 0
    private var shrinkStreak = 0

    public init(options!: ResultStoreOptions = ResultStoreOptions()) {
        this.options = options
        this.maxEntries = AtomicInt64(options.maxEntries)
    }

    /** 写入并返回 token；条数或字节超限时返回 `None`。 */
    public func put(content: ResourceContent): Option<String> {
        let token = newToken()
        if (put(token, content)) {
            Some(token)
        } else {
            None<String>
        }
    }

    public func put(token: String, content: ResourceContent): Bool {
        let bytes = estimateBytes(content)
        if (count.load() >= maxEntries.load()) {
            // 满额先回收过期条目，否则过期数据会永久占着配额
            sweepIfDue()
            if (count.load() >= maxEntries.load()) {
                rejectedByCount.fetchAdd(1)
                evaluate()
                return false
            }
        }
        if (!budget.reserve(bytes, options.maxBytes)) {
            sweepIfDue()
            if (!budget.reserve(bytes, options.maxBytes)) {
                rejectedByBytes.fetchAdd(1)
                evaluate()
                return false
            }
        }
        // 同一个 token 被覆盖时只换内容：不重复计数，并释放旧字节
        let previous = entries.add(token, ResultEntry(content, bytes, nowNanos()))
        match (previous) {
            case Some(prev) => budget.release(prev.bytes)
            case _ => count.fetchAdd(1)
        }
        puts.fetchAdd(1)
        evaluate()
        true
    }

    public func get(token: String): Option<ResourceContent> {
        match (entries.get(token)) {
            case Some(entry) =>
                if (nowNanos() - entry.createdAtNanos > options.ttlMillis * 1_000_000) {
                    removeEntry(token)
                    return None<ResourceContent>
                }
                Some(entry.content)
            case _ => None<ResourceContent>
        }
    }

    public func sweep(): Unit {
        let now = nowNanos()
        lastSweepNanos.store(now)
        sweeps.fetchAdd(1)
        let expired = ArrayList<String>()
        for ((token, entry) in entries) {
            if (now - entry.createdAtNanos > options.ttlMillis * 1_000_000) {
                expired.add(token)
            }
        }
        for (token in expired) {
            removeEntry(token)
        }
    }

    /** 至多每秒真正扫一次表：满额写入是热路径，不能每次都全表遍历。 */
    private func sweepIfDue(): Unit {
        let now = nowNanos()
        let last = lastSweepNanos.load()
        if (now - last < 1_000_000_000) {
            return
        }
        if (!lastSweepNanos.compareAndSwap(last, now)) {
            return
        }
        sweep()
    }

    public func close(): Unit {
        for ((token, _) in entries) {
            entries.remove(token)
        }
        count.store(0)
        budget.release(budget.value())
    }

    public prop size: Int64 {
        get() {
            count.load()
        }
    }

    public prop maxEntryCount: Int64 {
        get() {
            maxEntries.load()
        }
    }

    public prop usedBytes: Int64 {
        get() {
            budget.value()
        }
    }

    /** 全表扫描次数，用于确认限频生效。 */
    public prop sweepCount: Int64 {
        get() {
            sweeps.load()
        }
    }

    /** 进入窗口锁的次数，用于确认窗口未到期时走了无锁快路径。 */
    public prop windowLockCount: Int64 {
        get() {
            windowLocks.load()
        }
    }

    private func removeEntry(token: String): Unit {
        if (let Some(removed) <- entries.remove(token)) {
            count.fetchAdd(-1)
            budget.release(removed.bytes)
        }
    }

    private func estimateBytes(content: ResourceContent): Int64 {
        var total = Int64(content.uri.size)
        if (let Some(text) <- content.text) {
            total += Int64(text.size)
        }
        if (let Some(blob) <- content.blob) {
            total += blob.size
        }
        total
    }

    public func newToken(): String {
        let random = Random()
        return random.nextUInt64().toString() + random.nextUInt64().toString()
    }

    // —— 自适应调容 ——

    private func evaluate(): Unit {
        if (!options.adaptive) {
            return
        }
        let now = nowNanos()
        let windowNanos = options.windowMillis * 1_000_000
        // 无锁快路径：窗口未到期时连窗口锁都不碰
        if (now - windowStartNanos.load() < windowNanos) {
            return
        }
        var snapshot = ''
        var resizedFrom = 0
        var resizedTo = 0
        var resizeReason = ''
        synchronized(windowMutex) {
            windowLocks.fetchAdd(1)
            if (now - windowStartNanos.load() < windowNanos) {
                return
            }
            let putTotal = puts.load()
            let rejectCount = rejectedByCount.load()
            let rejectBytes = rejectedByBytes.load()
            let dPuts = putTotal - lastPuts
            let dCount = rejectCount - lastRejectedByCount
            let dBytes = rejectBytes - lastRejectedByBytes
            lastPuts = putTotal
            lastRejectedByCount = rejectCount
            lastRejectedByBytes = rejectBytes
            windowStartNanos.store(now)

            let current = maxEntries.load()
            let rejectTotal = dCount + dBytes
            let attempts = dPuts + rejectTotal
            let rejectRate = if (attempts > 0) {
                Float64(rejectTotal) / Float64(attempts)
            } else {
                0.0
            }
            let occupancy = if (current > 0) {
                Float64(count.load()) / Float64(current)
            } else {
                0.0
            }
            var decision = 'hold'
            var reason = 'below_threshold'
            var target = current
            if (dBytes > 0) {
                reason = 'bytes_bound'
                shrinkStreak = 0
            } else if (rejectRate > options.rejectRateThreshold && current < options.ceiling) {
                target = min(options.ceiling, current + maxOf(1, current / 4))
                decision = 'grow'
                reason = 'reject_rate'
                shrinkStreak = 0
            } else if (occupancy < 0.25 && current > options.floor) {
                shrinkStreak++
                if (shrinkStreak >= options.shrinkConfirmWindows) {
                    target = maxOf(options.floor, current - maxOf(1, current / 8))
                    decision = 'shrink'
                    reason = 'idle_windows'
                    shrinkStreak = 0
                } else {
                    reason = 'idle_pending'
                }
            } else {
                shrinkStreak = 0
                reason = if (current >= options.ceiling) {
                    'at_ceiling'
                } else {
                    'below_threshold'
                }
            }
            snapshot = 'puts=${dPuts} rej_count=${dCount} rej_bytes=${dBytes} ' +
                'reject_rate=${rejectRate} occupancy=${occupancy} max_entries=${current} ' +
                'decision=${decision} reason=${reason}'
            if (target != current) {
                maxEntries.store(target)
                resizedFrom = current
                resizedTo = target
                resizeReason = reason
            }
        }
        // 格式化与日志都在锁外
        log.append(LogLevel.DEBUG, 'mcp.resultstore.eval ${snapshot}', None<Exception>)
        if (resizedTo != 0) {
            log.append(LogLevel.INFO, 'mcp.resultstore.resize from=${resizedFrom} to=${resizedTo} reason=${resizeReason}',
                None<Exception>)
        }
    }

    private static func maxOf(a: Int64, b: Int64): Int64 {
        if (a > b) {
            a
        } else {
            b
        }
    }

    private static func nowNanos(): Int64 {
        DateTime.now().toUnixTimeStamp().toNanoseconds()
    }
}
