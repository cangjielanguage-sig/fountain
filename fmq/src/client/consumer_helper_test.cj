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
public class ConsumerHelperTest {
    @TestCase
    public func testEncodeAndDecodeConsumePayload(): Unit {
        let topic = "/order/create"
        let groupId = "group1"
        let batchSize: Int64 = 10
        let payload = Consumer.encodeConsumePayload(topic, groupId, batchSize)
        let buf = ByteBuffer(payload)
        let dec = DefaultCodec()
        if (let Some(t) <- dec.decode<String>(buf)
            && let Some(g) <- dec.decode<String>(buf)
            && let Some(b) <- dec.decode<Int64>(buf)) {
            @Assert(t == topic)
            @Assert(g == groupId)
            @Assert(b == batchSize)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func testEncodeAndDecodeMessageList(): Unit {
        let list = ArrayList<Array<Byte>>()
        list.add([0x01u8, 0x02u8])
        list.add([0x03u8, 0x04u8, 0x05u8])

        let encoded = encodeMessageList(list)
        let decoded = Consumer.decodeMessageList(encoded)
        @Assert(decoded.size == 2)
        @Assert(decoded[0].size == 2)
        @Assert(decoded[1].size == 3)
    }

    /**
     * 编码消息列表用于测试（保留：CommandExecutor.encodeMessageList 为 private 不可访问）。
     * 生产函数 Consumer.encodeConsumePayload / Consumer.decodeMessageList / extractBytes
     * 已在测试中替代。
     */
    private static func encodeMessageList(msgs: ArrayList<Array<Byte>>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(msgs.size)
        for (m in msgs) {
            enc.encode(m)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }
}
