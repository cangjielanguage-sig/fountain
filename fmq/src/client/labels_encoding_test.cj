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
public class LabelsEncodingTest {
    @TestCase
    public func testMessageListWithLabelsRoundtrip(): Unit {
        // 模拟服务端编码
        let msgs = ArrayList<(String, ArrayList<String>, Array<Byte>)>()
        let labels1 = ArrayList<String>()
        labels1.add("urgent")
        labels1.add("order")
        msgs.add(("delivery-1", labels1, [0x01u8, 0x02u8]))
        let labels2 = ArrayList<String>()
        msgs.add(("delivery-2", labels2, [0x03u8]))  // 空 labels

        // 使用 encodeMessageListWithIds 协议编码
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(msgs.size)
        for ((id, labels, data) in msgs) {
            enc.encode(id).encode(labels.size)
            for (l in labels) { enc.encode(l) }
            enc.encode(data)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let encoded = extractBytes(buf)

        // 解码验证 labels 正确传递
        let decoded = Consumer.decodeMessageListWithLabels(encoded)
        @Assert(decoded.size == 2)
        @Assert(decoded[0][0] == "delivery-1")  // deliveryId
        @Assert(decoded[0][1].size == 2)          // labels
        @Assert(decoded[0][1][0] == "urgent")
        @Assert(decoded[0][2].size == 2)          // payload
        @Assert(decoded[1][1].size == 0)          // 空 labels
    }
}
