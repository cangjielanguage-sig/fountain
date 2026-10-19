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

import std.fs.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.payload.MQDeadLetterMessage
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::fmq.queue.{DeadLetterQueue, QueueManager}

@Test
class LogCleanerTest {
    private static func rootOf(name: String): String {
        "/tmp/fmq_test_log_cleaner/${name}"
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
            let cleaner = LogCleaner(queues, dead, {_, _, _ => false}, Duration.second * -1,
                Duration.hour * 72)
            let removed = cleaner.cleanOnce(DateTime.now())
            @Assert(removed >= 1)
            // 当前段仍在
            let after = log.segments()
            @Assert(after.size >= 1)
            for (meta in after) {
                @Assert(meta.last || after.size == 1)
            }
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
            let cleaner = LogCleaner(queues, dead, {_, _, index => index == firstSealed.index},
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
            let cleaner = LogCleaner(queues, dead, {_, _, _ => false}, Duration.second * -1,
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
        let (root, queues, dead) = make("dead_ttl", 60)
        try {
            // 普通队列只有一个当前段（不会被删）
            queues.queueOf("/t", 0).getOrThrow().append([1u8])
            // 死信造出封口段
            for (i in 0..4) {
                dead.append(MQDeadLetterMessage("/t", 0, "g", Int64(i), 0, 1, DateTime.now(),
                    Array<Byte>(20, repeat: UInt8(i))))
            }
            @Assert(dead.cleanExpired(Duration.second * -1, DateTime.now()) >= 1)
            // 再用 cleaner：普通队列 TTL 很大 → 不删；死信 TTL 负 → 已无封口段则为 0
            let cleaner = LogCleaner(queues, dead, {_, _, _ => false}, Duration.hour * 72,
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
}
