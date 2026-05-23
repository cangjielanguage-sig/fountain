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
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}

/**
 * MqClient 协议编解码单元测试。
 * 验证 MqClient 内部使用的协议编码格式与服务器解码一致。
 * 不依赖网络连接（仅测试代码层逻辑）。
 */
@Test
public class MqClientProtocolTest {
    // ── 辅助方法：模拟 MqClient 的编码方式 ──

    private static func encodeDlqPayload(topic: String, qi: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode(qi)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeTopicOpPayload(op: String, name: String, qc: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec().encode(op).encode(name).encode(qc)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeGroupOpPayload(op: String, topic: String, group: String, off: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec().encode(op).encode(topic).encode(group).encode(off).encode(0i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeDlqRedeliverPayload(topic: String, qi: Int64, msgId: String): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode(qi).encode(msgId)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    /** 模拟 MqClient.decodeDeadLetterList */
    private static func decodeDeadLetterList(data: Array<Byte>): ArrayList<(String, Array<Byte>)> {
        let result = ArrayList<(String, Array<Byte>)>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(msgId) <- dec.decode<String>(buf)
                        && let Some(msgData) <- dec.decode<Array<Byte>>(buf)) {
                        result.add((msgId, msgData))
                    }
                }
            }
        } catch (_: Exception) {}
        result
    }

    /** 模拟 MqClient.decodeTopicList */
    private static func decodeTopicList(data: Array<Byte>): ArrayList<String> {
        let result = ArrayList<String>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(t) <- dec.decode<String>(buf)) {
                        result.add(t)
                    }
                }
            }
        } catch (_: Exception) {}
        result
    }

    private static func extractBytes(buf: ByteBuffer): Array<Byte> {
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)
        raw
    }

    // ──────────────── 测试用例 ────────────────

    // ── DLQ 负载编解码 ──

    @TestCase
    public func testDlqPayloadRoundtrip(): Unit {
        let topic = "/test-dlq"
        let qi: Int64 = 2
        let encoded = encodeDlqPayload(topic, qi)

        // 模拟服务端解码
        let dec = DefaultCodec()
        let buf = ByteBuffer(encoded)
        if (let Some(t) <- dec.decode<String>(buf)
            && let Some(i) <- dec.decode<Int64>(buf)) {
            @Assert(t == topic)
            @Assert(i == qi)
        } else { @Assert(false) }
    }

    @TestCase
    public func testDlqRedeliverPayloadRoundtrip(): Unit {
        let topic = "/test-redeliver"
        let qi: Int64 = 1
        let msgId = "msg-001"
        let encoded = encodeDlqRedeliverPayload(topic, qi, msgId)

        let dec = DefaultCodec()
        let buf = ByteBuffer(encoded)
        if (let Some(t) <- dec.decode<String>(buf)
            && let Some(i) <- dec.decode<Int64>(buf)
            && let Some(m) <- dec.decode<String>(buf)) {
            @Assert(t == topic)
            @Assert(i == qi)
            @Assert(m == msgId)
        } else { @Assert(false) }
    }

    @TestCase
    public func testDeadLetterListEncodeDecode(): Unit {
        // 模拟服务端编码 DLQ 列表
        let buf = ByteBuffer()
        DefaultCodec().encode(2i64)
            .encode("msg-1").encode([0x01u8])
            .encode("msg-2").encode([0x02u8, 0x02u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let data = extractBytes(buf)

        let decoded = decodeDeadLetterList(data)
        @Assert(decoded.size == 2)
        @Assert(decoded[0][0] == "msg-1")
        @Assert(decoded[0][1].size == 1)
        @Assert(decoded[1][0] == "msg-2")
        @Assert(decoded[1][1].size == 2)
    }

    @TestCase
    public func testDeadLetterListEmpty(): Unit {
        let buf = ByteBuffer()
        DefaultCodec().encode(0i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let data = extractBytes(buf)
        @Assert(decodeDeadLetterList(data).size == 0)
    }

    @TestCase
    public func testDeadLetterListInvalidDataReturnsEmpty(): Unit {
        @Assert(decodeDeadLetterList([0x01u8]).size == 0)
    }

    // ── TOPIC_OP 负载编解码 ──

    @TestCase
    public func testTopicOpCreatePayloadRoundtrip(): Unit {
        let op = "create"
        let name = "/new-topic"
        let qc: Int64 = 3
        let encoded = encodeTopicOpPayload(op, name, qc)

        let dec = DefaultCodec()
        let buf = ByteBuffer(encoded)
        if (let Some(o) <- dec.decode<String>(buf)
            && let Some(n) <- dec.decode<String>(buf)
            && let Some(q) <- dec.decode<Int64>(buf)) {
            @Assert(o == op)
            @Assert(n == name)
            @Assert(q == qc)
        } else { @Assert(false) }
    }

    @TestCase
    public func testTopicOpListPayloadRoundtrip(): Unit {
        let encoded = encodeTopicOpPayload("list", "", 0)

        let dec = DefaultCodec()
        let buf = ByteBuffer(encoded)
        if (let Some(o) <- dec.decode<String>(buf)
            && let Some(n) <- dec.decode<String>(buf)) {
            @Assert(o == "list")
            @Assert(n == "")
        } else { @Assert(false) }
    }

    @TestCase
    public func testTopicListDecode(): Unit {
        // 模拟服务端编码 topic list
        let buf = ByteBuffer()
        DefaultCodec().encode(3i64)
            .encode("/a").encode("/b").encode("/c")
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let data = extractBytes(buf)

        let decoded = decodeTopicList(data)
        @Assert(decoded.size == 3)
        @Assert(decoded[0] == "/a")
        @Assert(decoded[1] == "/b")
        @Assert(decoded[2] == "/c")
    }

    @TestCase
    public func testTopicListEmpty(): Unit {
        let buf = ByteBuffer()
        DefaultCodec().encode(0i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let data = extractBytes(buf)
        @Assert(decodeTopicList(data).size == 0)
    }

    @TestCase
    public func testTopicListInvalidDataReturnsEmpty(): Unit {
        @Assert(decodeTopicList([0xFFu8]).size == 0)
    }

    // ── GROUP_OP 负载编解码 ──

    @TestCase
    public func testGroupOpAddPayloadRoundtrip(): Unit {
        let op = "addGroup"
        let topic = "/test-group-topic"
        let group = "my-group"
        let off: Int64 = 0
        let encoded = encodeGroupOpPayload(op, topic, group, off)

        let dec = DefaultCodec()
        let buf = ByteBuffer(encoded)
        if (let Some(o) <- dec.decode<String>(buf)
            && let Some(t) <- dec.decode<String>(buf)
            && let Some(g) <- dec.decode<String>(buf)
            && let Some(of) <- dec.decode<Int64>(buf)) {
            @Assert(o == op)
            @Assert(t == topic)
            @Assert(g == group)
            @Assert(of == off)
        } else { @Assert(false) }
    }

    @TestCase
    public func testGroupOpResetOffsetPayloadRoundtrip(): Unit {
        let op = "resetOffset"
        let topic = "/reset-topic"
        let group = "consumer-group"
        let off: Int64 = 42
        let encoded = encodeGroupOpPayload(op, topic, group, off)

        let dec = DefaultCodec()
        let buf = ByteBuffer(encoded)
        if (let Some(o) <- dec.decode<String>(buf)
            && let Some(t) <- dec.decode<String>(buf)
            && let Some(g) <- dec.decode<String>(buf)
            && let Some(of) <- dec.decode<Int64>(buf)) {
            @Assert(o == op)
            @Assert(t == topic)
            @Assert(g == group)
            @Assert(of == off)
        } else { @Assert(false) }
    }

    // ── 无效数据边界 ──

    @TestCase
    public func testDecodeShortBufferReturnsEmpty(): Unit {
        @Assert(decodeTopicList([]).size == 0)
        @Assert(decodeDeadLetterList([]).size == 0)
    }
}
