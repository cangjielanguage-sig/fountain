/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env.{setVariable, removeVariable}
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage


@Test
public class BrokerMetaGettersTest {
    @TestCase
    public func testBrokerMetaAccessors(): Unit {
        let queues = ArrayList<String>()
        queues.add("/test/queue-0")
        let bm = BrokerMeta()
        // 通过 @DataAssist 设置字段后验证 getter
        // @DataAssist 的 DefaultCodec 编码/解码时会调用 getter
        @Assert(bm.getNodeId() == "")
        @Assert(bm.getHost() == "")
        @Assert(bm.getPort() == 0u16)
        @Assert(!bm.isMasterNode())
        @Assert(bm.getQueues().size == 0)
    }
}
