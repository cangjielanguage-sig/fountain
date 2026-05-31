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
package fountain::fmq.client

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID}


@Test
public class ConsumerDecodeWithLabelsTest {
    @TestCase
    public func testDecodeMessageListWithLabelsRoundtrip(): Unit {
        // 模拟服务端 encodeMessageListWithIds 的输出
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(2)  // count = 2
        // msg 1
        enc.encode("/topic/a:0:groupA:0")  // deliveryId
            .encode(1)  // labelCount = 1
            .encode("key=val")  // label
            .encode(Array<Byte>(3, repeat: 1u8))  // data
        // msg 2
        enc.encode("/topic/a:1:groupA:1")  // deliveryId
            .encode(0)  // labelCount = 0
            .encode(Array<Byte>(3, repeat: 2u8))  // data
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)

        let decoded = Consumer.decodeMessageListWithLabels(raw)
        @Assert(decoded.size == 2)

        let (d0, l0, p0) = decoded[0]
        @Assert(d0 == "/topic/a:0:groupA:0")
        @Assert(l0.size == 1)
        @Assert(l0[0] == "key=val")
        @Assert(p0.size == 3)

        let (d1, l1, p1) = decoded[1]
        @Assert(d1 == "/topic/a:1:groupA:1")
        @Assert(l1.size == 0)
        @Assert(p1.size == 3)
    }
}
