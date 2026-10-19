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
package fountain::fmq.cluster

import std.sync.{AtomicBool, Timer}
import std.time.DateTime
import fountain::f_log.*
import fountain::fmq.queue.{DeadLetterQueue, QueueManager}

/**
 * 段 TTL 清理：普通队列用 `segmentedLogTTL`，死信用独立的 `deadMsgTTL`。
 *
 * 删除条件：`updateTime + ttl < now` 且「没有游标引用该段」；当前段由 f_io 拒绝删除（`!last` 双重保护）。
 */
protected class LogCleaner {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.LogCleaner")

    private let queues: QueueManager
    private let deadLetter: DeadLetterQueue
    private let referenced: (String, Int64, Int64) -> Bool
    private let ttl: Duration
    private let deadMsgTTL: Duration
    private let interval: Duration
    private let closed = AtomicBool(false)
    private var timer: ?Timer = None

    protected init(queues: QueueManager, deadLetter: DeadLetterQueue, referenced: (String, Int64, Int64) -> Bool,
        ttl: Duration, deadMsgTTL: Duration, interval!: Duration = Duration.minute * 5) {
        this.queues = queues
        this.deadLetter = deadLetter
        this.referenced = referenced
        this.ttl = ttl
        this.deadMsgTTL = deadMsgTTL
        this.interval = interval
    }

    /** 一轮清理：返回删除的段数（普通队列 + 死信）。 */
    protected func cleanOnce(now: DateTime): Int64 {
        var removed = 0i64
        for ((topic, queueIndex, queue) in queues.allLogs()) {
            for (meta in queue.segments()) {
                if (meta.last) {
                    continue
                }
                if (meta.updateTime + ttl < now && !referenced(topic, queueIndex, meta.index)) {
                    queue.removeById(meta.index)
                    removed++
                }
            }
        }
        removed += deadLetter.cleanExpired(deadMsgTTL, now)
        if (removed > 0) {
            log.info("removed ${removed} expired segments")
        }
        removed
    }

    protected func start(now!: () -> DateTime = {=> DateTime.now()}): Unit {
        timer = Some(Timer.repeat(interval, interval, {=> cleanOnce(now())}))
    }

    protected func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        match (timer) {
            case Some(t) =>
                t.cancel()
                timer = None
            case None => ()
        }
    }
}
