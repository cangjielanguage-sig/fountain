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

        // 并发读写
        let f1 = spawn { q.tryReadFromLog(0) }
        let f2 = spawn { q.close() }
        f1.get()
        f2.get()
        // 不抛异常就算通过
        @Assert(q.isClosed())
        cleanupDir("/tmp/fmqq_f")
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
