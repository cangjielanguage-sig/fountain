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
package fountain::fmq.queue

import std.collection.ArrayList
import std.fs.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.payload.MQDeadLetterMessage
import fountain::fmq.test.TestDirs

@Test
class DeadLetterQueueTest {
    private static func rootOf(name: String): String {
        TestDirs.of("dead_letter", name)
    }

    private static func clean(root: String): Unit {
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    private static func make(index: Int64): MQDeadLetterMessage {
        MQDeadLetterMessage("/t", 1, "grp", index, index * 10, 4, DateTime.now(), [UInt8(index), 0xAAu8])
    }

    private static func readAll(queue: DeadLetterQueue, from: LogPosition): ArrayList<MQDeadLetterMessage> {
        let result = ArrayList<MQDeadLetterMessage>()
        let itr = queue.iterate(from)
        while (true) {
            let item = itr.next()
            if (item.isNone()) {
                break
            }
            result.add(item.getOrThrow())
        }
        result
    }

    @TestCase
    public func appendAndIterateFromFirst(): Unit {
        let root = rootOf("iterate")
        clean(root)
        let queue = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            @Assert(queue.append(make(1)).seq == 1)
            queue.append(make(2))
            queue.append(make(3))
            let messages = readAll(queue, LogPosition(1, 0))
            @Assert(messages.size == 3)
            @Assert(messages[0].segmentedIndex == 1)
            @Assert(messages[1].segmentedIndex == 2)
            @Assert(messages[2].segmentedIndex == 3)
            @Assert(messages[1].record.copyBytes() == [2u8, 0xAAu8])
            @Assert(messages[2].deliverCount == 4)
            @Assert(messages[2].subscribeGroup == "grp")
            @Assert(messages[2].queueIndex == 1)
        } finally {
            queue.close()
            clean(root)
        }
    }

    @TestCase
    public func iterateFromMiddlePosition(): Unit {
        let root = rootOf("middle")
        clean(root)
        let queue = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            queue.append(make(1))
            let second = queue.append(make(2))
            queue.append(make(3))
            let messages = readAll(queue, second)
            @Assert(messages.size == 2)
            @Assert(messages[0].segmentedIndex == 2)
            @Assert(messages[1].segmentedIndex == 3)
        } finally {
            queue.close()
            clean(root)
        }
    }

    @TestCase
    public func reopenKeepsAllEntries(): Unit {
        let root = rootOf("reopen")
        clean(root)
        let first = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            first.append(make(1))
            first.append(make(2))
        } finally {
            first.close()
        }
        let second = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            let messages = readAll(second, LogPosition(1, 0))
            @Assert(messages.size == 2)
            @Assert(messages[0].record.copyBytes() == [1u8, 0xAAu8])
            @Assert(messages[1].record.copyBytes() == [2u8, 0xAAu8])
        } finally {
            second.close()
            clean(root)
        }
    }

    @TestCase
    public func cleanExpiredRemovesOnlySealedSegments(): Unit {
        let root = rootOf("clean")
        clean(root)
        // 段上限很小，写完两条并 rotate 后存在封口段
        let queue = DeadLetterQueue(root, 256, 1)
        try {
            queue.append(make(1))
            queue.append(make(2))
            queue.sync()
            // 用负 TTL 让所有封口段都「超期」；当前段必须保留
            let removed = queue.cleanExpired(Duration.second * -1, DateTime.now())
            @Assert(removed >= 1)
            // 大 TTL 不会误删
            let noneRemoved = queue.cleanExpired(Duration.hour * 24, DateTime.now())
            @Assert(noneRemoved == 0)
        } finally {
            queue.close()
            clean(root)
        }
    }

    @TestCase
    public func cleanWithLargeTtlDeletesNothing(): Unit {
        let root = rootOf("no_clean")
        clean(root)
        let queue = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            queue.append(make(1))
            queue.append(make(2))
            @Assert(queue.cleanExpired(Duration.hour * 72, DateTime.now()) == 0)
            @Assert(readAll(queue, LogPosition(1, 0)).size == 2)
        } finally {
            queue.close()
            clean(root)
        }
    }

    /** 组间隔离：同一队列里不同组的死信各自保留组名与原始字节（A72）。 */
    @TestCase
    public func entriesFromDifferentGroupsStayIsolated(): Unit {
        let root = rootOf("groups")
        clean(root)
        let queue = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            let a = MQDeadLetterMessage("/t", 0, "gA", 1, 0, 4, DateTime.now(), [0x0Au8, 0x0Bu8])
            let b = MQDeadLetterMessage("/t", 0, "gB", 1, 10, 4, DateTime.now(), [0x0Cu8, 0x0Du8])
            queue.append(a)
            queue.append(b)
            let messages = readAll(queue, LogPosition(1, 0))
            @Assert(messages.size == 2)
            @Assert(messages[0].subscribeGroup == "gA")
            @Assert(messages[1].subscribeGroup == "gB")
            @Assert(messages[0].record.copyBytes() == [0x0Au8, 0x0Bu8])
            @Assert(messages[1].record.copyBytes() == [0x0Cu8, 0x0Du8])
        } finally {
            queue.close()
            clean(root)
        }
    }

    /** 大记录（>4KB）进死信后必须逐字节读回（A72）。 */
    @TestCase
    public func largeRecordSurvivesDeadLetter(): Unit {
        let root = rootOf("large")
        clean(root)
        let queue = DeadLetterQueue(root, 1024 * 1024, 1)
        try {
            let bytes = Array<Byte>(8192, repeat: 0x5Au8)
            bytes[0] = 0x01u8
            bytes[8191] = 0x02u8
            queue.append(MQDeadLetterMessage("/t", 0, "g", 1, 0, 4, DateTime.now(), bytes))
            let messages = readAll(queue, LogPosition(1, 0))
            @Assert(messages.size == 1)
            @Assert(messages[0].record.size() == 8192)
            @Assert(messages[0].record.copyBytes() == bytes)
        } finally {
            queue.close()
            clean(root)
        }
    }

    /** TTL 按「封口段」判定：当前段永不删除，封口段过期才回收。 */
    @TestCase
    public func cleanExpiredLeavesOnlyCurrentSegment(): Unit {
        let root = rootOf("ttl_segments")
        clean(root)
        // 每条消息大于段上限 40 字节 ⇒ 每次 append 都轮转，4 条产生 3 个封口段
        let queue = DeadLetterQueue(root, 40, 1)
        try {
            for (i in 0..4) {
                queue.append(MQDeadLetterMessage("/t", 0, "g", Int64(i), 0, 4, DateTime.now(),
                    Array<Byte>(20, repeat: UInt8(i))))
            }
            // 负 TTL：封口段全部过期被回收，当前段不动
            let removed = queue.cleanExpired(Duration.second * -1, DateTime.now())
            @Assert(removed >= 1)
            // 再跑一次：只剩当前段，无可回收
            @Assert(queue.cleanExpired(Duration.second * -1, DateTime.now()) == 0)
            // 大 TTL 同样不误删
            @Assert(queue.cleanExpired(Duration.hour * 24, DateTime.now()) == 0)
        } finally {
            queue.close()
            clean(root)
        }
    }
}
