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
public class DataFilterAckTest {
    @TestCase
    public func testAckPayloadFormatForFilteredMessage(): Unit {
        let payload = Consumer.encodeAckPayload("topic:0:group:42", "/test", 0)
        // 解码验证格式: deliveryId(String) + topic(String) + queueIndex(Int64)
        let buf = ByteBuffer(payload)
        let dec = DefaultCodec()
        if (let Some(id) <- dec.decode<String>(buf)
            && let Some(tp) <- dec.decode<String>(buf)
            && let Some(qi) <- dec.decode<Int64>(buf)) {
            @Assert(id == "topic:0:group:42")
            @Assert(tp == "/test")
            @Assert(qi == 0)
        }
    }

    @TestCase
    public func testDataFilterMatchRejectsUnknownField(): Unit {
        // DefaultCodec 编码 "a"→1, "b"→2
        let buf = ByteBuffer()
        DefaultCodec()
            .encode("a").encode(1i64)
            .encode("b").encode(2i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        // 过滤 $z 不存在的字段 → 应返回 false
        @Assert(!Consumer.dataFilterMatch("$z", raw))
    }

    @TestCase
    public func testDataFilterMatchRejectsEmptyPayload(): Unit {
        // 空 payload 无法解码 → 应安全返回 false
        @Assert(!Consumer.dataFilterMatch("$.x", []))
    }

    /**
     * P2-3: 验证 unsubscribe 场景下的 ACK payload 格式与 extractQueueIndex 兼容。
     * deliveryId 格式为 "topic:queueIdx:groupId:offset:sn"，extractQueueIndex 提取
     * parts[parts.size-3] 作为 queueIndex。本测试确保两种典型 deliveryId 格式
     * extractQueueIndex 返回正确值，ACK 编码后解析回原始字段。
     */
    @TestCase
    public func testUnsubscribeAckFormat(): Unit {
        // 典型 deliveryId: topic:queueIdx:groupId:offset:sn
        let deliveryId = "/test:3:my-group:42:1"
        if (let Some(qi) <- ConsumerLoop.extractQueueIndex(deliveryId)) {
            let payload = Consumer.encodeAckPayload(deliveryId, "/test", qi)
            let buf = ByteBuffer(payload)
            let dec = DefaultCodec()
            if (let Some(id) <- dec.decode<String>(buf)
                && let Some(tp) <- dec.decode<String>(buf)
                && let Some(idx) <- dec.decode<Int64>(buf)) {
                @Assert(id == deliveryId)
                @Assert(tp == "/test")
                @Assert(idx == qi)
            }
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func testExtractQueueIndexFromVariousFormats(): Unit {
        // 验证不同 deliveryId 格式下 extractQueueIndex 返回正确索引
        @Assert(ConsumerLoop.extractQueueIndex("/t:0:g:1:0") == Some(0))
        @Assert(ConsumerLoop.extractQueueIndex("/t:7:g:1:0") == Some(7))
        @Assert(ConsumerLoop.extractQueueIndex("/t:9:g:1:0") == Some(9))
        // 格式异常: 不足 2 段 → None
        @Assert(ConsumerLoop.extractQueueIndex("/t:g").isNone())
    }
}
