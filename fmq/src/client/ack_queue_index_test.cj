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
public class AckQueueIndexTest {
    @TestCase
    public func testAckPayloadWithDeliveryIdQueueIndex(): Unit {
        // deliveryId 格式: "topic:queueIndex:groupId:offset"
        let deliveryId = "/order:3:groupA:42"

        // encodeAckPayload 编码 (msgId, topic, queueIndex)
        let payload = Consumer.encodeAckPayload(deliveryId, "/order", 3)

        // 解码验证 queueIndex 正确
        let buf = ByteBuffer(payload)
        let dec = DefaultCodec()
        if (let Some(id) <- dec.decode<String>(buf)
            && let Some(tp) <- dec.decode<String>(buf)
            && let Some(qi) <- dec.decode<Int64>(buf)) {
            @Assert(id == deliveryId)
            @Assert(tp == "/order")
            @Assert(qi == 3)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func testExtractQueueIndexFromDeliveryId(): Unit {
        @Assert(ConsumerLoop.extractQueueIndex("/a:0:g:0") == Some(0))
        @Assert(ConsumerLoop.extractQueueIndex("/b:5:g:10") == Some(5))
        @Assert(ConsumerLoop.extractQueueIndex("/c/d:7:x:3") == Some(7))
    }

    @TestCase
    public func testDataFilterAckUsesDeliveryIdQueueIndex(): Unit {
        // 模拟 ConsumerLoop dataFilter 不匹配时 ACK: deliveryId="/topic:3:g:5"
        // 验证 encodeAckPayload 使用 queueIndex=3（提取自 deliveryId）而非 0
        let deliveryId = "/topic:3:g:5"
        if (let Some(queueIndex) <- ConsumerLoop.extractQueueIndex(deliveryId)) {
            @Assert(queueIndex == 3)

            // 使用提取的 queueIndex 编码 ACK
            let payload = Consumer.encodeAckPayload(deliveryId, "/topic", queueIndex)

            // 解码验证
            let buf = ByteBuffer(payload)
            let dec = DefaultCodec()
            if (let Some(id) <- dec.decode<String>(buf)
                && let Some(tp) <- dec.decode<String>(buf)
                && let Some(qi) <- dec.decode<Int64>(buf)) {
                @Assert(qi == 3)
                @Assert(qi != 0)  // 确保不是硬编码的 0
            } else {
                @Assert(false)
            }
        } else {
            @Assert(false)
        }
    }
}
