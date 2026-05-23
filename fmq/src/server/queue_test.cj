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
import std.fs.{Directory, remove}

/**
 * MqQueue.tryReadFromLog 单元测试。
 * 使用临时目录创建 SegmentedLog，验证 append + read + skip 的正确性。
 */
@Test
public class MqQueueReadTest {
    @TestCase
    public func testAppendAndRead(): Unit {
        let q = MqQueue("/test-a", 0, "/tmp/fmqq_a", 4096)
        q.append([0x01u8, 0x02u8])
        q.sync()

        let r = q.tryReadFromLog(0)
        @Assert(r.isSome())

        q.close()
        cleanupDir("/tmp/fmqq_a")
    }

    @TestCase
    public func testReadMultipleAndCycle(): Unit {
        let q = MqQueue("/test-b", 0, "/tmp/fmqq_b", 4096)
        q.append([0x10u8])
        q.append([0x20u8])
        q.append([0x30u8])
        q.sync()

        // 顺序读取 3 条
        @Assert(q.tryReadFromLog(0).isSome())
        @Assert(q.tryReadFromLog(0).isSome())
        @Assert(q.tryReadFromLog(0).isSome())
        // 流耗尽后重新从头读取
        @Assert(q.tryReadFromLog(0).isSome())

        q.close()
        cleanupDir("/tmp/fmqq_b")
    }

    @TestCase
    public func testSkipFirstReadsSecond(): Unit {
        let q = MqQueue("/test-c", 0, "/tmp/fmqq_c", 4096)
        q.append([0x01u8])
        q.append([0x02u8])
        q.sync()

        let r = q.tryReadFromLog(1)
        @Assert(r.isSome())

        q.close()
        cleanupDir("/tmp/fmqq_c")
    }

    @TestCase
    public func testReadAfterCloseReturnsNone(): Unit {
        let q = MqQueue("/test-d", 0, "/tmp/fmqq_d", 4096)
        q.append([0xFFu8])
        q.sync()
        q.close()
        @Assert(q.tryReadFromLog(0).isNone())
        cleanupDir("/tmp/fmqq_d")
    }

    @TestCase
    public func testTryFinishDrainWhenNoStream(): Unit {
        let q = MqQueue("/test-e", 0, "/tmp/fmqq_e", 4096)
        // 未排空 → 直接 true
        @Assert(q.tryFinishDrain())

        // 排空中且无 stream → close 并返回 true
        q.draining.store(true)
        @Assert(q.tryFinishDrain())
        @Assert(q.isClosed())

        cleanupDir("/tmp/fmqq_e")
    }

    @TestCase
    public func testConcurrentReadAndClose(): Unit {
        let q = MqQueue("/test-f", 0, "/tmp/fmqq_f", 4096)
        q.append([0x01u8])
        q.sync()

        // 并发读写：验证 close 不导致 SIGSEGV
        let f1 = spawn { q.tryReadFromLog(0) }
        let f2 = spawn { q.close() }
        f1.get()
        f2.get()
        // 不抛异常就算通过
        @Assert(q.isClosed())
        cleanupDir("/tmp/fmqq_f")
    }

    @TestCase
    public func testConcurrentReadAndCloseStress(): Unit {
        // 压力测试：20轮并发读写+关闭，验证修复后无竞态崩溃
        for (i in 0..20) {
            let dir = "/tmp/fmqq_stress_${i}"
            let q = MqQueue("/stress", 0, dir, 4096)
            q.append([0x01u8])
            q.sync()
            let f1 = spawn { q.tryReadFromLog(0) }
            let f2 = spawn { q.close() }
            f1.get()
            f2.get()
            @Assert(q.isClosed())
            cleanupDir(dir)
        }
    }

    @TestCase
    public func testDrainingBlocksAppend(): Unit {
        let q = MqQueue("/test-g", 0, "/tmp/fmqq_g", 4096)
        @Assert(!q.draining.load())

        q.draining.store(true)
        @Assert(q.draining.load())

        // 排空中 append 应抛异常
        var threw: Bool = false
        try {
            q.append([0x01u8])
        } catch (_: MqException) { threw = true }
        @Assert(threw)

        q.close()
        cleanupDir("/tmp/fmqq_g")
    }

    private static func cleanupDir(path: String): Unit {
        try {
            for (entry in Directory.readFrom(path)) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove(path)
        } catch (_: Exception) {}
    }
}

/**
 * QueueWriter 线程生命周期测试。
 * P2: startSyncThread 幂等性，两次调用不应崩溃。
 */
@Test
public class QueueWriterTest {
    @TestCase
    public func testStartSyncThreadDoubleCallNoCrash(): Unit {
        let q = MqQueue("/test-sync2", 0, "/tmp/fmqq_sync2", 4096)
        let hosts = ArrayList<String>()
        hosts.add("localhost:7201")
        let config = MqConfig.forTest(dataDir: "/tmp/fmqq_sync2", mqHosts: hosts)
        let rm = ReplicationManager(config)
        let writer = QueueWriter(q, config, replicationManager: rm)
        // 两次调用 startSyncThread 不应崩溃或报错
        writer.startSyncThread()
        writer.startSyncThread()
        @Assert(true)
        q.close()
        cleanupDir("/tmp/fmqq_sync2")
    }

    private static func cleanupDir(path: String): Unit {
        try {
            for (entry in Directory.readFrom(path)) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove(path)
        } catch (_: Exception) {}
    }
}
