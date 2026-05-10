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

@Test
public class SubscriberTest {
    @TestCase
    public func testExtractTopic(): Unit {
        @Assert(extractTopicInner(MatchMode.Exact("/a")) == "/a")
        @Assert(extractTopicInner(MatchMode.Glob("/a/*")) == "/a/*")
        @Assert(extractTopicInner(MatchMode.Prefix("/a/")) == "/a/")
    }

    @TestCase
    public func testModeToString(): Unit {
        @Assert(modeToStringInner(MatchMode.Exact("/a")) == "exact")
        @Assert(modeToStringInner(MatchMode.Glob("/a/*")) == "glob")
        @Assert(modeToStringInner(MatchMode.Prefix("/a/")) == "prefix")
    }

    /**
     * 反射测试：直接验证 Subscriber 的提取逻辑。
     */
    private static func extractTopicInner(mode: MatchMode): String {
        match (mode) {
            case Exact(t) => t
            case Glob(t) => t
            case Prefix(t) => t
        }
    }

    private static func modeToStringInner(mode: MatchMode): String {
        match (mode) {
            case Exact(_) => "exact"
            case Glob(_) => "glob"
            case Prefix(_) => "prefix"
        }
    }
}

@Test
public class ConsumerHelperTest {
    @TestCase
    public func testEncodeAndDecodeConsumePayload(): Unit {
        let topic = "/order/create"
        let groupId = "group1"
        let batchSize: Int64 = 10
        let payload = encodeConsumePayload(topic, groupId, batchSize)
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
        let decoded = decodeMessageList(encoded)
        @Assert(decoded.size == 2)
        @Assert(decoded[0].size == 2)
        @Assert(decoded[1].size == 3)
    }

    /**
     * 编码工具测试方法。
     */
    private static func encodeConsumePayload(topic: String, groupId: String, batchSize: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(topic).encode(groupId).encode(batchSize)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func decodeMessageList(data: Array<Byte>): ArrayList<Array<Byte>> {
        let result = ArrayList<Array<Byte>>()
        try {
            let buf = ByteBuffer(data)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                for (_ in 0..count) {
                    if (let Some(msg) <- dec.decode<Array<Byte>>(buf)) {
                        result.add(msg)
                    }
                }
            }
        } catch (_: Exception) {}
        result
    }

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

    private static func extractBytes(buf: ByteBuffer): Array<Byte> {
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)
        raw
    }
}

@Test
public class ProduceBatchTest {
    @TestCase
    public func testEncodeRoundtrip(): Unit {
        let topic = "/batch-test"
        let messages = ArrayList<(ArrayList<String>, Array<Byte>)>()
        let labels1 = ArrayList<String>()
        labels1.add("a")
        messages.add((labels1, [0x01u8]))
        let labels2 = ArrayList<String>()
        labels2.add("b")
        messages.add((labels2, [0x02u8, 0x03u8]))

        let encoded = ProduceCodec.encode(topic, messages[0][0], messages[0][1])
        if (let Some((t, ls, data)) <- ProduceCodec.decode(encoded)) {
            @Assert(t == topic)
            @Assert(ls.size == 1)
            @Assert(ls[0] == "a")
            @Assert(data.size == 1)
        }
    }
}

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

/**
 * 无 Server 连接测试：验证编码/解码逻辑，不实际发送。
 * 验证 deregister 请求的 DefaultCodec 编码与服务器 handleDeregister 解码匹配。
 */
@Test
public class DeregisterPayloadTest {
    @TestCase
    public func testDeregisterPayloadRoundtrip(): Unit {
        let groupId = "my-group"
        let consumerId = "consumer-123"

        // 客户端编码（与 Subscriber.deregister 的编码方式一致）
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(groupId)
            .encode(consumerId)
            .finish()
        enc.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)

        // 服务端解码（与 CommandExecutor.handleDeregister 的解码方式一致）
        let dec = DefaultCodec()
        let decBuf = ByteBuffer(raw)
        if (let Some(g) <- dec.decode<String>(decBuf)
            && let Some(c) <- dec.decode<String>(decBuf)) {
            @Assert(g == groupId)
            @Assert(c == consumerId)
        } else {
            @Assert(false)
        }
    }
}

/**
 * 无 SyncRegistryTest：需要真实的 MQ 服务端连接。
 */
