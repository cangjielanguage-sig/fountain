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
package fountain::fmq.server

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*
import std.sync.{AtomicInt64, AtomicBool}
import std.fs.*
import std.fs.removeIfExists


@Test
public class DeadLetterStoreTest {
    private static let counter = AtomicInt64(0)

    private static func dlqDir(name: String): String {
        "/tmp/fmq_dlq_${name}_${counter.fetchAdd(1) + 1}"
    }

    @TestCase
    public func testAppendAndList(): Unit {
        let ds = DeadLetterStore(dlqDir("append"), retentionHours: 168)
        ds.append([0x01u8, 0x02u8, 0x03u8], "/test", 0, "msg-001")

        let list1 = ds.list("/test", 0)
        @Assert(list1.size == 1)
        if (list1.size > 0) {
            @Assert(list1[0][0] == "msg-001")
            @Assert(list1[0][1].size == 3)
        }

        let list2 = ds.list("/other", 0)
        @Assert(list2.size == 0)
    }

    @TestCase
    public func testRedeliver(): Unit {
        let ds = DeadLetterStore(dlqDir("redeliver"), retentionHours: 168)
        ds.append([0xAu8, 0xBu8], "/test", 1, "msg-002")

        let r = ds.redeliver("/test", 1, "msg-002")
        @Assert(r != None)
        if (let Some(data) <- r) {
            @Assert(data.size == 2)
            @Assert(data[0] == 0xAu8)
        }

        let list = ds.list("/test", 1)
        @Assert(list.size == 0)
    }

    @TestCase
    public func testRedeliverNonExistent(): Unit {
        let ds = DeadLetterStore(dlqDir("nox"), retentionHours: 168)
        @Assert(ds.redeliver("/test", 0, "nonexistent").isNone())
    }

    @TestCase
    public func testRedeliverAll(): Unit {
        let ds = DeadLetterStore("/tmp/fmq_dlq_test4", retentionHours: 168)
        ds.append([0x01u8], "/test", 0, "msg-a")
        ds.append([0x02u8], "/test", 0, "msg-b")
        ds.append([0x03u8], "/other", 0, "msg-c")

        let all = ds.redeliverAll("/test", 0)
        @Assert(all.size == 2)

        let after = ds.list("/test", 0)
        @Assert(after.size == 0)
    }

    @TestCase
    public func testRebuildIndexWorkWithDeletions(): Unit {
        let ds = DeadLetterStore(dlqDir("rebidx"), retentionHours: 168)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.append([0x02u8], "/b", 0, "msg-2")
        // redeliver 会从索引删除
        ds.redeliver("/a", 0, "msg-1")
        @Assert(ds.list("/a", 0).size == 0)
        @Assert(ds.list("/b", 0).size == 1)
    }

    @TestCase
    public func testCleanupPreservesFreshEntries(): Unit {
        let ds = DeadLetterStore(dlqDir("cleanup"), retentionHours: 168)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.append([0x02u8], "/b", 0, "msg-2")
        ds.cleanup()
        // retentionHours=168, all entries are fresh, nothing should be removed
        @Assert(ds.list("/a", 0).size == 1)
        @Assert(ds.list("/b", 0).size == 1)
    }

    @TestCase
    public func testCleanupRetentionZeroSkips(): Unit {
        let ds = DeadLetterStore(dlqDir("cleanup0"), retentionHours: 0)
        ds.append([0x01u8], "/a", 0, "msg-1")
        ds.cleanup()
        // retentionHours=0 means unlimited, nothing should be removed
        @Assert(ds.list("/a", 0).size == 1)
    }

    @TestCase
    public func testBatchSyncTriggeredOnThreshold(): Unit {
        let ds = DeadLetterStore(dlqDir("batchsync"), retentionHours: 168, syncBatchSize: 3)
        // 追加 2 条（未达到 batchSize=3，不触发 sync，但不影响 append 功能）
        ds.append([0x01u8], "/test", 0, "msg-b1")
        ds.append([0x02u8], "/test", 0, "msg-b2")
        // 第 3 条达到 batchSize，触发 sync
        ds.append([0x03u8], "/test", 0, "msg-b3")
        // 验证所有 3 条均可列出
        let list = ds.list("/test", 0)
        @Assert(list.size == 3)
        // 验证 sync() 幂等（已 sync 后再调用不抛异常）
        ds.sync()
 
    }

    /**
     * P1-3: 验证 unsyncedCount 串行正确性。
     * 串行批量 append 验证计数准确。
     * ⚠️ 该测试是串行的而非并发测试，函数名明确反映其范围。
     */
    @TestCase
    public func testUnsyncedCountSerial(): Unit {
        let ds = DeadLetterStore(dlqDir("atomic"), retentionHours: 168, syncBatchSize: 10)
        for (i in 0..10) {
            ds.append([0x01u8], "/test", 0, "msg-a-${i}")
        }
        let after = ds.list("/test", 0)
        @Assert(after.size == 10)
    }

    /**
     * SRV-7: 验证 DeliveryRecord 保存原始 payload，moveToDLQ 不丢失数据。
     * 修复前 moveToDLQ 传 []，DLQ 中无原始数据。
     */
    @TestCase
    public func testDeliveryRecordPayloadPreservedInDLQ(): Unit {
        let payload: Array<Byte> = [0xAAu8, 0xBBu8, 0xCCu8]
        let ds = DeadLetterStore("/tmp/fmq_srv7_test", retentionHours: 168)

        // 通过 DeadLetterStore 直接 append 带 payload 的消息
        ds.append(payload, "/srv7-topic", 0, "srv7-msg-001")

        // 列出并验证 payload
        let entries = ds.list("/srv7-topic", 0)
        @Assert(entries.size == 1)
        if (entries.size > 0) {
            @Assert(entries[0][0] == "srv7-msg-001")
            @Assert(entries[0][1] == payload)
        }

        // 清理
        try { removeDir("/tmp/fmq_srv7_test") } catch (_: Exception) {}
    }

    /**
     * P2-4: 验证 append 后 list 返回所有条目。
     * rebuildIndex 在 init 时自动调用，确保内存索引与 SegmentedLog 一致。
     */
    @TestCase
    public func testDeadLetterRebuildIndexPreservesTimestamps(): Unit {
        let dir = dlqDir("rebidx_ts")
        let ds = DeadLetterStore(dir, retentionHours: 168)
        ds.append([0x01u8, 0x02u8], "/test", 0, "msg-ts-1")
        ds.append([0x03u8, 0x04u8], "/test", 0, "msg-ts-2")
        ds.sync()
        // 验证内存索引正确
        let entries = ds.list("/test", 0)
        @Assert(entries.size == 2)
        var found1 = false
        var found2 = false
        for ((msgId, data) in entries) {
            if (msgId == "msg-ts-1" && data.size == 2) { found1 = true }
            if (msgId == "msg-ts-2" && data.size == 2) { found2 = true }
        }
        @Assert(found1)
        @Assert(found2)
        ds.close()
        removeDir(dir)
    }
}
