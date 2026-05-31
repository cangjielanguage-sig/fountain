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
public class ConsumeClosedQueueTest {
    private static let counter = AtomicInt64(0)

    private static func closedDir(): String {
        "/tmp/fmq_consume_closed_${counter.fetchAdd(1) + 1}"
    }

    @TestCase
    public func testHandleConsumeSkipsClosedQueue(): Unit {
        let dir = closedDir()
        let q = MqQueue("/test-closed", 0, dir, 4096)
        q.append([0xAAu8, 0xBBu8])
        q.sync()
        @Assert(!q.isClosed())
        // 关闭队列
        q.close()
        @Assert(q.isClosed())
        // 关闭后 tryReadFromLog 应返回 None
        @Assert(q.tryReadFromLog(0).isNone())
        // 清理
        removeDir(dir)
    }
}
