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
package fountain::f_rpc

import std.unittest.*
import std.unittest.testmacro.*
import std.io.OutputStream
import fountain::f_protocol.default.Message

class EncodedMessageTestFailingSink <: OutputStream & Resource {
    private var closed = false
    public func write(bytes: Array<Byte>): Unit {
        throw Exception('simulated write failure')
    }
    public func flush(): Unit {}
    public func isClosed(): Bool {
        closed
    }
    public func close(): Unit {
        closed = true
    }
}

@Test
public class EncodedMessageReleaseTest {
    /**
     * P0-1 + P0-2 回归：向不可写的目标反复写出编码消息。
     *
     * 旧实现：`EncodedMessage.copy` 里 `to.write([command])` 一抛就永远不会走到 `bytes.copy(...)`，
     * 借出的编码缓冲永不归还 → 池在 ~1024 次后耗尽 → 下一次 `encode()` 永久阻塞（本用例会挂死）。
     * 新实现：finally 里无条件 release，写失败还会 close 目标连接（避免对端看到半条消息）。
     */
    @TestCase
    public func writeFailureReleasesPoolAndClosesTarget(): Unit {
        let sink = EncodedMessageTestFailingSink()
        for (i in 0..2000) {
            let em = Message.ping().encode()
            var threw = false
            try {
                em.copy(to: sink)
            } catch (_: Exception) {
                threw = true
            }
            // sink 必然写失败：必须抛出（而不是静默）
            if (!threw) {
                @Expect(false)
            }
            // P0-1：写失败必须关闭目标，避免半条消息留在流上
            if (!sink.isClosed()) {
                @Expect(false)
            }
        }
        @Assert(true)
    }
}
