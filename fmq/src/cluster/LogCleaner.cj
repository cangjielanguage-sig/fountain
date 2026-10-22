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
import fountain::fmq.queue.{DeadLetterQueue, QueueLog, QueueManager}

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
    /** 备份队列的段视图（由 server 包注入 `BackupStore.allLogs()`，避免 cluster → server 反向依赖）。 */
    private let backupLogs: () -> Array<(Int64, String, Int64, QueueLog)>
    /** 备份队列的保留边界：位点最小值，缺失时返回 1（保留全部）。 */
    private let backupFloor: (Int64, String, Int64) -> Int64
    /** 段删除动作：生产走 `QueueLog.removeById`，用例注入失败以验证隔离（R2-G3）。 */
    private let removeSegment: (QueueLog, Int64) -> Unit
    private let closed = AtomicBool(false)
    private var timer: ?Timer = None

    protected init(queues: QueueManager, deadLetter: DeadLetterQueue, floorOf: (String, Int64) -> Int64,
        ttl: Duration, deadMsgTTL: Duration, interval!: Duration = Duration.minute * 5,
        backupLogs!: () -> Array<(Int64, String, Int64, QueueLog)> = {=> []},
        backupFloor!: (Int64, String, Int64) -> Int64 = {_, _, _ => 1},
        removeSegment!: (QueueLog, Int64) -> Unit = {log, index => log.removeById(index)}) {
        this.queues = queues
        this.deadLetter = deadLetter
        this.floorOf = floorOf
        this.ttl = ttl
        this.deadMsgTTL = deadMsgTTL
        this.interval = interval
        this.backupLogs = backupLogs
        this.backupFloor = backupFloor
        this.removeSegment = removeSegment
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
                            removeSegment(queue, meta.index)
                            removed++
                        } catch (e: Exception) {
                            // 段级失败单独记 ERROR：汇总日志只有计数，排障要能定位到具体段（R2-G3）
                            log.error("cannot remove segment ${topic}/${queueIndex}#${meta.index}: ${e.message}")
                            failures.add("${topic}/${queueIndex}#${meta.index}(${e.message})")
                        }
                    }
                }
            } catch (e: Exception) {
                // 位点查询等前置步骤失败：只跳过该队列，其它对象照常清理
                log.error("cannot clean queue ${topic}/${queueIndex}: ${e.message}")
                failures.add("${topic}/${queueIndex}(${e.message})")
            }
        }
        // 备份副本队列：保留边界取该队列全部组备份位点的最小值，无位点则全部保留（A66）
        for ((owner, topic, queueIndex, backupLog) in backupLogs()) {
            try {
                let floor = backupFloor(owner, topic, queueIndex)
                for (meta in backupLog.segments()) {
                    if (meta.last) {
                        continue
                    }
                    if (meta.updateTime + ttl < now && meta.index < floor) {
                        try {
                            removeSegment(backupLog, meta.index)
                            removed++
                        } catch (e: Exception) {
                            log.error("cannot remove backup segment ${owner}/${topic}/${queueIndex}#${meta.index}: " +
                                "${e.message}")
                            failures.add("backup ${owner}/${topic}/${queueIndex}#${meta.index}(${e.message})")
                        }
                    }
                }
            } catch (e: Exception) {
                log.error("cannot clean backup queue ${owner}/${topic}/${queueIndex}: ${e.message}")
                failures.add("backup ${owner}/${topic}/${queueIndex}(${e.message})")
            }
        }
        try {
            removed += deadLetter.cleanExpired(deadMsgTTL, now)
        } catch (e: Exception) {
            log.error("cannot clean dead-letter segments: ${e.message}")
            failures.add("dead-letter(${e.message})")
        }
        // 轮末汇总：一个计数行就够看整轮结果，明细都在上面的 ERROR 里
        if (failures.size > 0) {
            log.warn("cleanup round: removed ${removed} segment(s), failed ${failures.size} object(s): " +
                "${String.join(failures.toArray(), delimiter: ",")}")
        } else if (removed > 0) {
            log.info("cleanup round: removed ${removed} segment(s), failed 0")
        }
        removed
    }

    protected func start(): Unit {
        // 定时回调必须自吞异常，否则一次失败会让后续所有轮次停摆（A41）。
        // 时钟不注入：需要固定时间的用例直接调 cleanOnce(now)，不走定时器。
        timer = Some(Timer.repeat(interval, interval, {=>
            try {
                cleanOnce(DateTime.now())
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
