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
import std.fs.*
import std.sync.AtomicInt64
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.payload.MQDeadLetterMessage
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::fmq.meta.{MetaApplyResult, MetaStore}
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::f_io.LogPosition
import fountain::fmq.queue.{CursorCatalog, CursorStore, DeadLetterQueue, QueueLog, QueueManager}
import fountain::fmq.test.TestDirs

@Test
class LogCleanerTest {
    private static func rootOf(name: String): String {
        TestDirs.of("log_cleaner", name)
    }

    private static func clean(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    private static func make(name: String, maxFileSize: Int64): (String, QueueManager, DeadLetterQueue) {
        let root = rootOf(name)
        clean(root)
        let queues = QueueManager("${root}/logs", maxFileSize, 1)
        queues.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
        let dead = DeadLetterQueue("${root}/dead", maxFileSize, 1)
        (root, queues, dead)
    }

    /** 目录下的段文件名（用于断言「按段回收」而不是只看计数）。 */
    private static func segmentFiles(dir: String): ArrayList<String> {
        let result = ArrayList<String>()
        if (!exists(dir)) {
            return result
        }
        Directory.walk(dir) {info: FileInfo =>
            if (!info.isDirectory() && info.name.startsWith("log_")) {
                result.add(info.name)
            }
            true
        }
        result
    }

    private static func fill(queue: QueueManager) {
        let log = queue.queueOf("/t", 0).getOrThrow()
        for (i in 0..6) {
            log.append(Array<Byte>(20, repeat: UInt8(i)))
        }
    }

    @TestCase
    public func expiredSegmentsWithoutReferencesAreRemoved(): Unit {
        let (root, queues, dead) = make("expired", 40)
        try {
            fill(queues)
            let log = queues.queueOf("/t", 0).getOrThrow()
            let before = log.segments().size
            @Assert(before >= 2)
            let cleaner = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.second * -1,
                Duration.hour * 72)
            let removed = cleaner.cleanOnce(DateTime.now())
            @Assert(removed >= 1)
            // 精确断言：除当前段外全部回收，剩余段号集合只有一个元素
            let after = log.segments()
            @Assert(after.size == 1)
            @Assert(after[0].index == Int64(before))
            @Assert(after[0].last)
            cleaner.close()
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    @TestCase
    public func referencedSegmentsAreKept(): Unit {
        let (root, queues, dead) = make("referenced", 40)
        try {
            fill(queues)
            let log = queues.queueOf("/t", 0).getOrThrow()
            let firstSealed = log.segments()[0]
            @Assert(!firstSealed.last)
            let cleaner = LogCleaner(queues, dead, {_, _ => firstSealed.index},
                Duration.second * -1, Duration.hour * 72)
            cleaner.cleanOnce(DateTime.now())
            // 被引用的段保留
            var stillThere = false
            for (meta in log.segments()) {
                if (meta.index == firstSealed.index) {
                    stillThere = true
                }
            }
            @Assert(stillThere)
            cleaner.close()
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    @TestCase
    public func currentSegmentIsNeverRemoved(): Unit {
        let (root, queues, dead) = make("current", 1024 * 1024)
        try {
            let log = queues.queueOf("/t", 0).getOrThrow()
            log.append([1u8, 2u8, 3u8])
            let cleaner = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.second * -1,
                Duration.hour * 72)
            @Assert(cleaner.cleanOnce(DateTime.now()) == 0)
            @Assert(log.segments().size == 1)
            cleaner.close()
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    @TestCase
    public func deadLetterUsesItsOwnTtl(): Unit {
        let (root, queues, dead) = make("dead_ttl", 200)
        try {
            // 普通队列只有一个当前段（不会被删）
            queues.queueOf("/t", 0).getOrThrow().append([1u8])
            // 死信造出封口段
            for (i in 0..4) {
                dead.append(MQDeadLetterMessage("/t", 0, "g", Int64(i), 0, 1, DateTime.now(),
                    Array<Byte>(20, repeat: UInt8(i))))
            }
            let before = segmentFiles("${root}/dead").size
            @Assert(before >= 2)
            @Assert(dead.cleanExpired(Duration.second * -1, DateTime.now()) >= 1)
            // 按段回收：过期段的文件确实少了一个（R3-M11）
            @Assert(segmentFiles("${root}/dead").size < before)
            // 再用 cleaner：普通队列 TTL 很大 → 不删；死信 TTL 负 → 已无封口段则为 0
            let cleaner = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.hour * 72,
                Duration.second * -1)
            cleaner.cleanOnce(DateTime.now())
            @Assert(queues.queueOf("/t", 0).getOrThrow().segments().size == 1)
            cleaner.close()
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    @TestCase
    public func offlineGroupPositionKeepsSegments(): Unit {
        let (root, queues, dead) = make("offline_group", 32)
        let meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${root}/metas")
        try {
            fill(queues)
            let log = queues.queueOf("/t", 0).getOrThrow()
            @Assert(log.segments().size >= 3)
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            // 离线组只有磁盘位点：停在段 2
            store.save("/t", 0, "g", LogPosition(2, 0))
            let catalog = CursorCatalog(store, meta)
            let cleaner = LogCleaner(queues, dead, {topic, queueIndex => catalog.floorOf(topic, queueIndex)},
                Duration.second * -1, Duration.hour * 72)
            try {
                cleaner.cleanOnce(DateTime.now())
            } finally {
                cleaner.close()
            }
            var hasTwo = false
            for (segment in log.segments()) {
                @Assert(segment.index >= 2)
                if (segment.index == 2) {
                    hasTwo = true
                }
            }
            @Assert(hasTwo)
        } finally {
            meta.close()
            queues.close()
            dead.close()
            clean(root)
        }
    }

    @TestCase
    public func neverConsumedGroupKeepsEverySegment(): Unit {
        let (root, queues, dead) = make("never_consumed", 32)
        let meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${root}/metas")
        try {
            fill(queues)
            let log = queues.queueOf("/t", 0).getOrThrow()
            let before = log.segments().size
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            let catalog = CursorCatalog(store, meta)
            let cleaner = LogCleaner(queues, dead, {topic, queueIndex => catalog.floorOf(topic, queueIndex)},
                Duration.second * -1, Duration.hour * 72)
            try {
                @Assert(cleaner.cleanOnce(DateTime.now()) == 0)
            } finally {
                cleaner.close()
            }
            @Assert(log.segments().size == before)
        } finally {
            meta.close()
            queues.close()
            dead.close()
            clean(root)
        }
    }

    @TestCase
    public func removingGroupLetsSegmentsBeReclaimed(): Unit {
        let (root, queues, dead) = make("group_removed", 32)
        let meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${root}/metas")
        try {
            fill(queues)
            let log = queues.queueOf("/t", 0).getOrThrow()
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "slow")) == MetaApplyResult.Applied)
            store.save("/t", 0, "slow", LogPosition(1, 0))
            let catalog = CursorCatalog(store, meta)
            let cleaner = LogCleaner(queues, dead, {topic, queueIndex => catalog.floorOf(topic, queueIndex)},
                Duration.second * -1, Duration.hour * 72)
            try {
                @Assert(cleaner.cleanOnce(DateTime.now()) == 0)
                @Assert(meta.removeGroup("/t", "slow").isSome())
                catalog.removeGroup("/t", "slow")
                @Assert(cleaner.cleanOnce(DateTime.now()) >= 1)
            } finally {
                cleaner.close()
            }
            @Assert(log.segments().size == 1)
        } finally {
            meta.close()
            queues.close()
            dead.close()
            clean(root)
        }
    }

    /** 单个队列的清理失败不得中断整轮：其它队列照常回收（A41）。 */
    @TestCase
    public func oneQueueFailureDoesNotStopOthers(): Unit {
        let root = rootOf("isolate")
        clean(root)
        let queues = QueueManager("${root}/logs", 40, 1)
        queues.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
        queues.openTopic(MQTopicAssignment("/u", 1, 0, [0]), 0)
        let dead = DeadLetterQueue("${root}/dead", 40, 1)
        try {
            let logT = queues.queueOf("/t", 0).getOrThrow()
            let logU = queues.queueOf("/u", 0).getOrThrow()
            for (i in 0..6) {
                logT.append(Array<Byte>(20, repeat: UInt8(i)))
                logU.append(Array<Byte>(20, repeat: UInt8(i)))
            }
            let beforeT = logT.segments().size
            let beforeU = logU.segments().size
            @Assert(beforeT >= 2 && beforeU >= 2)
            let cleaner = LogCleaner(queues, dead, {topic, _ =>
                if (topic == "/t") {
                    throw Exception("boom")
                }
                Int64.Max
            }, Duration.second * -1, Duration.hour * 72)
            try {
                let removed = cleaner.cleanOnce(DateTime.now())
                @Assert(removed >= 1)
                // /t 一个都没删，/u 被回收
                @Assert(logT.segments().size == beforeT)
                @Assert(logU.segments().size < beforeU)
            } finally {
                cleaner.close()
            }
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    /** 单个段删除失败不得中断同队列其它段，并留下含 topic/queue/段号的 ERROR（R2-G3）。 */
    @TestCase
    public func oneSegmentFailureDoesNotStopOthersAndLogsError(): Unit {
        let (root, queues, dead) = make("segment_isolate", 40)
        let log = queues.queueOf("/t", 0).getOrThrow()
        CapturingAppender.install()
        try {
            fill(queues)
            let before = log.segments()
            @Assert(before.size >= 3)
            let victim = before[0].index
            let cleaner = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.second * -1,
                Duration.hour * 72, removeSegment: {queueLog, index =>
                    if (index == victim) {
                        throw Exception("cannot unlink segment")
                    }
                    queueLog.removeById(index)
                })
            try {
                let removed = cleaner.cleanOnce(DateTime.now())
                @Assert(removed >= 1)
                // 只有失败的段留下
                @Assert(log.segments().size == 2)
                @Assert(CapturingAppender.waitFor(["/t/0#${victim}", "cannot unlink segment"]))
                @Assert(CapturingAppender.waitFor(["removed", "failed 1"]))
            } finally {
                cleaner.close()
            }
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    /** 段删除中途失败后重开：失败的段仍在、其余已回收，状态可解释（R3-M11）。 */
    @TestCase
    public func failedSegmentRemovalLeavesReadableStateAfterReopen(): Unit {
        let root = rootOf("partial_remove")
        clean(root)
        let queues = QueueManager("${root}/logs", 40, 1)
        queues.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
        let dead = DeadLetterQueue("${root}/dead", 40, 1)
        var victim = -1i64
        try {
            let log = queues.queueOf("/t", 0).getOrThrow()
            fill(queues)
            let before = log.segments()
            @Assert(before.size >= 3)
            let victimIndex = before[0].index
            victim = victimIndex
            let cleaner = LogCleaner(queues, dead, {_, _ => Int64.Max}, Duration.second * -1,
                Duration.hour * 72, removeSegment: {queueLog, index =>
                    if (index == victimIndex) {
                        throw Exception("unlink failed")
                    }
                    queueLog.removeById(index)
                })
            try {
                @Assert(cleaner.cleanOnce(DateTime.now()) >= 1)
            } finally {
                cleaner.close()
            }
            @Assert(log.segments().size == 2)
        } finally {
            queues.close()
        }
        // 重开：失败的段仍在，成功的段已消失，当前段可继续写
        let reopened = QueueManager("${root}/logs", 40, 1)
        reopened.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
        try {
            let again = reopened.queueOf("/t", 0).getOrThrow()
            // 重开时 f_io 会再开一个空的活动段：失败的段 + 原活动段 + 新活动段
            @Assert(again.segments().size == 3)
            @Assert(again.segments()[0].index == victim)
            var lastCount = 0
            for (meta in again.segments()) {
                if (meta.last) {
                    lastCount++
                }
            }
            @Assert(lastCount == 1)
            again.append(Array<Byte>(20, repeat: 0x7Fu8))
        } finally {
            reopened.close()
            dead.close()
            clean(root)
        }
    }

    /** 普通队列整队失败时，死信清理仍要照常执行（R2-G4）。 */
    @TestCase
    public func deadLetterStillCleansWhenQueueFails(): Unit {
        let (root, queues, dead) = make("dead_after_queue_failure", 200)
        try {
            queues.queueOf("/t", 0).getOrThrow().append([1u8])
            for (i in 0..4) {
                dead.append(MQDeadLetterMessage("/t", 0, "g", Int64(i), 0, 1, DateTime.now(),
                    Array<Byte>(20, repeat: UInt8(i))))
            }
            let cleaner = LogCleaner(queues, dead, {_, _ =>
                throw Exception("cursor lookup boom")
            }, Duration.hour * 72, Duration.second * -1)
            try {
                // 普通队列全失败，删除数全部来自死信清理
                @Assert(cleaner.cleanOnce(DateTime.now()) >= 1)
            } finally {
                cleaner.close()
            }
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }

    /** 定时器回调抛异常也不能让后续轮次停摆（A41）。 */
    @TestCase
    public func timerKeepsRunningAfterFailure(): Unit {
        let (root, queues, dead) = make("timer_isolate", 40)
        try {
            fill(queues)
            let calls = AtomicInt64(0)
            let cleaner = LogCleaner(queues, dead, {_, _ =>
                let n = calls.fetchAdd(1)
                if (n == 0) {
                    throw Exception("first round boom")
                }
                Int64.Max
            }, Duration.second * -1, Duration.hour * 72, interval: Duration.millisecond * 50)
            try {
                cleaner.start()
                var waited = 0
                while (calls.load() < 2 && waited < 200) {
                    sleep(Duration.millisecond * 10)
                    waited++
                }
                @Assert(calls.load() >= 2)
            } finally {
                cleaner.close()
            }
        } finally {
            queues.close()
            dead.close()
            clean(root)
        }
    }
}
