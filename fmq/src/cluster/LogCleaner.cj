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

import std.collection.ArrayList
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
    private let floorOf: (String, Int64) -> Int64
    private let ttl: Duration
    private let deadMsgTTL: Duration
    private let interval: Duration
    private let closed = AtomicBool(false)
    private var timer: ?Timer = None

    protected init(queues: QueueManager, deadLetter: DeadLetterQueue, floorOf: (String, Int64) -> Int64,
        ttl: Duration, deadMsgTTL: Duration, interval!: Duration = Duration.minute * 5) {
        this.queues = queues
        this.deadLetter = deadLetter
        this.floorOf = floorOf
        this.ttl = ttl
        this.deadMsgTTL = deadMsgTTL
        this.interval = interval
    }

    /**
     * 一轮清理：返回删除的段数（普通队列 + 死信）。
     *
     * 单个段/单个队列的删除失败不能中断整轮：逐对象 try/catch，最后汇总一条日志（A41）。
     */
    protected func cleanOnce(now: DateTime): Int64 {
        var removed = 0i64
        let failures = ArrayList<String>()
        for ((topic, queueIndex, queue) in queues.allLogs()) {
            try {
                for (meta in queue.segments()) {
                    if (meta.last) {
                        continue
                    }
                    // 只有「段号小于全部组位点最小段号」的段才无人需要
                    if (meta.updateTime + ttl < now && meta.index < floorOf(topic, queueIndex)) {
                        try {
                            queue.removeById(meta.index)
                            removed++
                        } catch (e: Exception) {
                            failures.add("${topic}/${queueIndex}#${meta.index}(${e.message})")
                        }
                    }
                }
            } catch (e: Exception) {
                // 位点查询等前置步骤失败：只跳过该队列，其它对象照常清理
                failures.add("${topic}/${queueIndex}(${e.message})")
            }
        }
        try {
            removed += deadLetter.cleanExpired(deadMsgTTL, now)
        } catch (e: Exception) {
            failures.add("dead-letter(${e.message})")
        }
        if (failures.size > 0) {
            log.warn("cleanup skipped ${failures.size} object(s): ${String.join(failures.toArray(), delimiter: ",")}")
        }
        if (removed > 0) {
            log.info("removed ${removed} expired segments")
        }
        removed
    }

    protected func start(now!: () -> DateTime = {=> DateTime.now()}): Unit {
        // 定时回调必须自吞异常，否则一次失败会让后续所有轮次停摆（A41）
        timer = Some(Timer.repeat(interval, interval, {=>
            try {
                cleanOnce(now())
            } catch (e: Exception) {
                log.error("cleanup round failed: ${e.message}")
            }
            ()
        }))
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
