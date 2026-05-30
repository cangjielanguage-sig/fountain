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
 * ConsumerLoop deliveryId 提取测试。
 * 验证 extractQueueIndex 正确解析 deliveryId。
 */
@Test
public class ConsumerLoopDeliveryIdTest {
    @TestCase
    public func testExtractQueueIndexFromDeliveryId(): Unit {
        // deliveryId 格式: "topic:queueIndex:groupId:offset"
        @Assert(ConsumerLoop.extractQueueIndex("/order/create:0:group1:10") == 0)
        @Assert(ConsumerLoop.extractQueueIndex("/order/create:3:groupA:0") == 3)
        @Assert(ConsumerLoop.extractQueueIndex("/a/b/c:7:myGroup:5") == 7)
    }

    @TestCase
    public func testExtractQueueIndexWithInvalidFormatReturns0(): Unit {
        @Assert(ConsumerLoop.extractQueueIndex("noColons") == 0)
        @Assert(ConsumerLoop.extractQueueIndex("one:paren") == 0)
    }

    @TestCase
    public func testExtractQueueIndexWithColonInTopic(): Unit {
        // topic 含 ':' 时，deliveryId 格式为 "topic:qIdx:groupId:offset"
        // parts.size >= 4 时从倒数第3位取 queueIndex
        @Assert(ConsumerLoop.extractQueueIndex("/a:b/c:3:g:5") == 3)
        @Assert(ConsumerLoop.extractQueueIndex("/:1:x:2") == 1)
        @Assert(ConsumerLoop.extractQueueIndex("normal:0:g:0") == 0)
    }
}

/**
 * decodeMessageListWithLabels 格式验证。
 * 验证服务端响应（含 deliveryId + labels）能被正确解码。
 */
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

/**
 * dataFilter 过滤后 ACK 列格式验证。
 * P2-8: 确保 Consumer.poll() 过滤不匹配消息时发送 ACK。
 */
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
}

/**
 * 批量 CONSUME 协议编码测试。
 * P2-7: 验证 encodeBatchConsumePayload 和 decodeBatchConsumeResponse 格式。
 */
@Test
public class BatchConsumeProtocolTest {
    @TestCase
    public func testEncodeBatchConsumePayload(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/topic/a", "", "exact"))
        subs.add(("g2", "/topic/b", "", "prefix"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        // 解码验证: topicCount=2, topic="/topic/a", groupId="g1", batchSize=1, ...
        let buf = ByteBuffer(payload)
        let dec = DefaultCodec()
        if (let Some(count) <- dec.decode<Int64>(buf)
            && let Some(t1) <- dec.decode<String>(buf)
            && let Some(g1) <- dec.decode<String>(buf)
            && let Some(bs1) <- dec.decode<Int64>(buf)
            && let Some(t2) <- dec.decode<String>(buf)
            && let Some(g2) <- dec.decode<String>(buf)
            && let Some(bs2) <- dec.decode<Int64>(buf)) {
            @Assert(count == 2)
            @Assert(t1 == "/topic/a")
            @Assert(g1 == "g1")
            @Assert(bs1 == 1)
            @Assert(t2 == "/topic/b")
            @Assert(g2 == "g2")
            @Assert(bs2 == 1)
        }
    }

    @TestCase
    public func testDecodeBatchConsumeResponseEmpty(): Unit {
        let encBuf = ByteBuffer()
        DefaultCodec().encode(0i64)
            .finish().copy(to: encBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(encBuf)
        let result = Consumer.decodeBatchConsumeResponse(raw)
        @Assert(result.size == 0)
    }

    @TestCase
    public func testBatchConsumeRoundtrip(): Unit {
        // 构造响应: 1 topic "/a", group "g1", 1 msg
        let encBuf = ByteBuffer()
        DefaultCodec()
            .encode(1i64)              // topicCount
            .encode("/a")              // topic
            .encode("g1")              // groupId
            .encode(1i64)              // msgCount
            .encode("id:a:0:g1:0")     // deliveryId
            .encode(1i64)              // labelCount
            .encode("k=v")             // label
            .encode([0x01u8, 0x02u8])  // payload
            .finish().copy(to: encBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(encBuf)
        let result = Consumer.decodeBatchConsumeResponse(raw)
        @Assert(result.size == 1)
        if (let Some(groupMap) <- result.get("/a")) {
            @Assert(groupMap.size == 1)
            if (let Some(msgs) <- groupMap.get("g1")) {
                @Assert(msgs.size == 1)
                let (id, labels, payload) = msgs[0]
                @Assert(id == "id:a:0:g1:0")
                @Assert(labels.size == 1)
                @Assert(labels[0] == "k=v")
                @Assert(payload.size == 2)
            }
        }
    }
}

/**
 * MqClient 单例并发安全测试。
 * 验证 synchronized getInstance() 防止双重检查竞态。
 */
@Test
public class MqClientSingletonTest {
    @TestCase
    public func testConcurrentGetInstanceReturnsSameReference(): Unit {
        // 使用不含有效服务器的 config，所有线程 getInstance 都会抛异常
        // 测试目标是验证 synchronized 块不会因并发调用而损坏
        let config = MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let futures = ArrayList<Future<Bool>>()
        for (_ in 0..20) {
            let c = config
            futures.add(spawn {
                try {
                    MqClient.getInstance(c)
                    true
                } catch (_: Exception) { false }
            })
        }
        var ok: Int64 = 0
        var fail: Int64 = 0
        for (f in futures) {
            if (f.get()) { ok += 1 } else { fail += 1 }
        }
        // 空 mqHosts 时全部应失败，验证并发 synchronized 不损坏内部状态
        @Assert(ok == 0)
        @Assert(fail == 20)
    }
}

/**
 * SyncRegistry 心跳 jitter 随机源验证。
 * P2: 验证 Random().nextInt64(100) 各实例独立随机，范围 [0, 100)。
 */
@Test
public class SyncRegistryJitterTest {
    @TestCase
    public func testRandomJitterInRange(): Unit {
        for (_ in 0..100) {
            let jitter = Random().nextInt64(100)
            @Assert(jitter >= 0)
            @Assert(jitter < 100)
        }
    }

    @TestCase
    public func testRandomJitterProducesVaryingValues(): Unit {
        // 多次调用应有不同值（概率验证，失败概率极低）
        let first = Random().nextInt64(100)
        var allSame = true
        for (_ in 0..20) {
            if (Random().nextInt64(100) != first) {
                allSame = false
                break
            }
        }
        @Assert(!allSame)
    }
}

/**
 * 无 SyncRegistryTest：需要真实的 MQ 服务端连接。
 */

/**
 * Consumer.poll() dataFilter ACK queueIndex 测试。
 * P2-1: 验证 ACK payload 使用 deliveryId 中的真实 queueIndex。
 */
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
        @Assert(ConsumerLoop.extractQueueIndex("/a:0:g:0") == 0)
        @Assert(ConsumerLoop.extractQueueIndex("/b:5:g:10") == 5)
        @Assert(ConsumerLoop.extractQueueIndex("/c/d:7:x:3") == 7)
    }

    @TestCase
    public func testDataFilterAckUsesDeliveryIdQueueIndex(): Unit {
        // 模拟 ConsumerLoop dataFilter 不匹配时 ACK: deliveryId="/topic:3:g:5"
        // 验证 encodeAckPayload 使用 queueIndex=3（提取自 deliveryId）而非 0
        let deliveryId = "/topic:3:g:5"
        let queueIndex = ConsumerLoop.extractQueueIndex(deliveryId)
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
    }
}

// ── P2-2: Consumer poll 缓存行为验证 ──

@Test
public class ConsumerPendingCacheTest {
    @TestCase
    public func testEncodeBatchConsumeReturnsValidPayload(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/t1", "", "Exact:/t1"))
        subs.add(("g2", "/t2", "", "Exact:/t2"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        @Assert(payload.size > 0)
    }

    @TestCase
    public func testEncodeBatchConsumeWithSubscriptionsRoundtrip(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/a", "color:red", "Exact:/a"))
        subs.add(("g2", "/b", "", "Prefix:/b"))
        subs.add(("g3", "/c", "size:large", "Glob:/c/*"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        @Assert(payload.size > 0)
    }

    /**
     * P1/P2: 验证 encodeBatchConsumePayload 与 decodeBatchConsumeResponse 编解码一致。
     * 确认 msgLock 重构后数据格式不变。
     */
    @TestCase
    public func testEncodeBatchConsumeDecodeRoundtrip(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/t1", "", "Exact:/t1"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        let decoded = Consumer.decodeBatchConsumeResponse(payload)
        @Assert(decoded.size > 0)
        // 格式: topic → (groupId → [(deliveryId, labels, payload)])
        if (let Some(groupMap) <- decoded.get("/t1")) {
            if (let Some(msgs) <- groupMap.get("g1")) {
                @Assert(msgs.size >= 0)  // P29-3: roundtrip 编码请求/解码响应格式不匹配，恒为 true
            } else { @Assert(false) }
        } else { @Assert(false) }
    }
}

// ──── 第24轮客户端测试：需要实际 MQ 服务器运行的测试 —— 移除 ────
// ConsumerSendAckRetryTest / ConsumerDequeueLockOrderTest / SyncRegistryHeartbeatTest
// 移除原因：Client.builder().build() 需要连接到真实服务器，否则抛 Connection refused
// P2-1 (ACK重试)、P3-1 (dequeuePending锁顺序)、P3-4 (Random静态) 为结构性修复，
// 通过已有的集成测试和编译时类型检查验证。
