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
public class TryFinishDrainConcurrentCloseTest {
    @TestCase
    public func testTryFinishDrainWithConcurrentClose(): Unit {
        let q = MqQueue("/test-p3-2", 0, "/tmp/fmqq_p32", 4096)
        @Assert(!q.isClosed())
        @Assert(!q.draining.load())

        // 设置 draining=true
        q.draining.store(true)

        // close 后再 tryFinishDrain
        q.close()
        @Assert(q.isClosed())

        // tryFinishDrain 应检测到 closed 并返回 true
        @Assert(q.tryFinishDrain())

        try {
            for (entry in Directory.readFrom("/tmp/fmqq_p32")) {
                try { remove(entry.path.toString()) } catch (_: Exception) {}
            }
            remove("/tmp/fmqq_p32")
        } catch (_: Exception) {}
    }
}
