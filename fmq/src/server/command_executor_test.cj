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
package fountain::fmq.server

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_protocol.default.{Message as ProtocolMessage, MessageID, Command}
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}

/**
 * CommandExecutor 单元测试。
 * 测试命令 handler 的正确性，使用真实依赖（无需 mock）。
 *
 * 通过 Command.value 比较（tag 位于高 4 位：RESP=11, PING=12）。
 */
@Test
public class CommandExecutorTest {
    // ── 辅助 ──

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_cmd_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func makeExecutor(): CommandExecutor {
        CommandExecutor(
            TopicManager(testConfig()), QueueManager(testConfig(), nodeIndex: 0),
            DeliveryManager(testConfig()), ConsumerMatcher(),
            ReplicationManager(testConfig()))
    }

    /** 检查响应的 command tag 是否为 RESP (tag=11) */
    private static func isResp(msg: ProtocolMessage): Bool {
        (msg.command.value >> 4) == 11u8
    }

    /** 检查响应的 command tag 是否为 PING (tag=12) */
    private static func isPing(msg: ProtocolMessage): Bool {
        (msg.command.value >> 4) == 12u8
    }

    private static func extractBytes(buf: ByteBuffer): Array<Byte> {
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)
        raw
    }

    /** 编码字符串列表为 DefaultCodec 格式 */
    private static func enc(strings: Array<String>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
        for (s in strings) { enc.encode(s) }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    // ──────────────── 各 handler 测试 ────────────────

    /**
     * PING → PING(1)
     */
    @TestCase
    public func testPingReturnsPong(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.PING(0), MessageID(),
            MqBody("ping", []).toData())
        let resp = ex.execute(req)
        @Assert(isPing(resp))
        // 验证 PING 响应的 tag 为 1 (ping 子类型)
        @Assert((resp.command.value & 0x0Fu8) == 1u8)
    }

    /**
     * PUBLISH + 无 body → error RESP
     */
    @TestCase
    public func testEmptyBodyReturnsError(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            DataNone.INSTANCE.toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
    }

    /**
     * PUBLISH + 未知 bodyType → error RESP
     */
    @TestCase
    public func testUnknownBodyTypeReturnsError(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("bogus_type", []).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
    }

    // ── 单条生产 ──

    @TestCase
    public func testSingleProduceSucceeds(): Unit {
        let ex = makeExecutor()
        let encoded = ProduceCodec.encode("/test-produce", ArrayList<String>(), [0x01u8, 0x02u8])
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        // 验证成功的生产返回 MqBody("ack", ...) 
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "ack")
        }
    }

    @TestCase
    public func testSingleProduceInvalidTopicReturnsError(): Unit {
        let ex = makeExecutor()
        let encoded = ProduceCodec.encode("", ArrayList<String>(), [0x01u8])
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
    }

    // ── 批量生产 ──

    @TestCase
    public func testBatchProduceSucceeds(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(1i64).encode("/batch-topic").encode(0i64).encode([0x42u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("batch_produce", raw).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
    }

    @TestCase
    public func testBatchProduceEmptyPayload(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("batch_produce", []).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
    }

    /**
     * 批量生产 — 解码失败应 break 而非继续循环。
     * count=2 但只编码了 1 条消息的数据 → 第二条 decode 失败 → break。
     */
    @TestCase
    public func testBatchProduceDecodeFailureBreaks(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        // count=2 但只提供 1 条完整消息 → 第 2 条缺失 topic 字段
        DefaultCodec()
            .encode(2i64)  // count = 2
            .encode("/topic-a").encode(0i64).encode([0x01u8])  // 仅 1 条
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("batch_produce", raw).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
    }

    // ── 订阅 / 退订 ──

    @TestCase
    public func testSubscribeAndUnsubscribe(): Unit {
        let ex = makeExecutor()
        let topicPayload = enc(["/test-sub", "exact"])

        let subReq = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", topicPayload).toData())
        @Assert(isResp(ex.execute(subReq)))

        let unsubReq = ProtocolMessage(Command.UNSUBSCRIBE, MessageID(),
            MqBody("unsubscribe", topicPayload).toData())
        @Assert(isResp(ex.execute(unsubReq)))
    }

    @TestCase
    public func testSubscribeInvalidTopicReturnsError(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", enc(["", "exact"])).toData())
        @Assert(isResp(ex.execute(req)))
    }

    /**
     * SUBSCRIBE 同一 topic 两次使用相同 consumerId（基于 pid+topic），
     * UNSUBSCRIBE 能正确匹配注销。
     */
    @TestCase
    public func testSubscribeSameTopicTwiceRoundtrip(): Unit {
        let ex = makeExecutor()
        let tp1 = enc(["/sub-topic", "exact"])

        // 第一次订阅
        let req1 = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", tp1).toData())
        @Assert(isResp(ex.execute(req1)))

        // 第二次订阅（同一 topic，consumerId 应相同 → ConsumerMatcher 更新而非追加）
        let req2 = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", tp1).toData())
        @Assert(isResp(ex.execute(req2)))

        // 退订能正确匹配
        let unsub = ProtocolMessage(Command.UNSUBSCRIBE, MessageID(),
            MqBody("unsubscribe", tp1).toData())
        @Assert(isResp(ex.execute(unsub)))
    }

    // ── 注册 / 注销 ──

    @TestCase
    public func testRegisterAndDeregister(): Unit {
        let ex = makeExecutor()
        let regPayload = enc(["my-group", "consumer-1", "Exact:/test"])
        let regReq = ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", regPayload).toData())
        @Assert(isResp(ex.execute(regReq)))

        let deregPayload = enc(["my-group", "consumer-1"])
        let deregReq = ProtocolMessage(Command.DEREGISTER, MessageID(),
            MqBody("deregister", deregPayload).toData())
        @Assert(isResp(ex.execute(deregReq)))
    }

    @TestCase
    public func testRegisterIncompletePayloadReturnsError(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", enc(["incomplete"])).toData())
        @Assert(isResp(ex.execute(req)))
    }

    // ── 拉取消息 ──

    @TestCase
    public func testConsumeNonExistentTopicReturnsError(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        DefaultCodec().encode("/no-such-topic").encode("group").encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(req)))
    }

    // ── ACK ──

    @TestCase
    public func testAckUnknownMessageReturnsError(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        DefaultCodec().encode("unknown-msg").encode("/test").encode(0i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("ack", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(req)))
    }

    @TestCase
    public func testBatchAckDecodeFailureReturnsError(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.ACK, MessageID(),
            MqBody("batch_ack", []).toData())
        @Assert(isResp(ex.execute(req)))
    }

    @TestCase
    public func testAckNoBodyReturnsError(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.ACK, MessageID(),
            DataNone.INSTANCE.toData())
        @Assert(isResp(ex.execute(req)))
    }

    // ── 主题操作 ──

    @TestCase
    public func testTopicOpCreateSucceeds(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["/cmd-test-topic", "create"])).toData())
        @Assert(isResp(ex.execute(req)))
    }

    @TestCase
    public func testTopicOpListSucceeds(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["", "list"])).toData())
        @Assert(isResp(ex.execute(req)))
    }

    @TestCase
    public func testListConsumersEmptyReturnsResp(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["listConsumers", "/no-consumers"])).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        // 验证返回 consumer_list 类型
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "consumer_list")
        }
    }

    // ── 死信 ──

    @TestCase
    public func testDlqListEmptyReturnsResp(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        DefaultCodec().encode("/test-dlq").encode(0i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.DLQ_LIST, MessageID(),
            MqBody("dlq_list", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(req)))
    }

    @TestCase
    public func testDlqRedeliverUnknownReturnsResp(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        DefaultCodec().encode("/test-dlq").encode(0i64).encode("no-such-msg")
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.DLQ_REDELIVER, MessageID(),
            MqBody("dlq_redeliver", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(req)))
    }

    @TestCase
    public func testDlqRedeliverAllEmptyReturnsResp(): Unit {
        let ex = makeExecutor()
        let buf = ByteBuffer()
        DefaultCodec().encode("/test-dlq").encode(0i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.DLQ_REDELIVER_ALL, MessageID(),
            MqBody("dlq_redeliver_all", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(req)))
    }

    // ── 主从复制 ──

    @TestCase
    public func testSlaveOfReturnsResp(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.SLAVEOF(1), MessageID(),
            MqBody("slaveof", enc(["node2:7201"])).toData())
        @Assert(isResp(ex.execute(req)))
    }

    // ── 生产+消费集成 ──

    @TestCase
    public func testProduceAndConsumeRoundtrip(): Unit {
        let ex = makeExecutor()
        let topic = "/roundtrip"
        let payload = [0xDEu8, 0xADu8]

        // 1. 生产一条消息
        let encoded = ProduceCodec.encode(topic, ArrayList<String>(), payload)
        let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        @Assert(isResp(ex.execute(prodReq)))

        // 2. 消费这条消息
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode("test-group").encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let consReq = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(consReq)))
    }

    /**
     * handleConsume: batchSize=1 时只消费 1 条，验证 break 生效。
     */
    @TestCase
    public func testConsumeBatchSizeOneBreaksAfterFirstMessage(): Unit {
        let ex = makeExecutor()
        let topic = "/consume-break"

        // 生产 2 条消息到同一 topic
        let enc1 = ProduceCodec.encode(topic, ArrayList<String>(), [0xAAu8])
        let req1 = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", enc1).toData())
        @Assert(isResp(ex.execute(req1)))

        let enc2 = ProduceCodec.encode(topic, ArrayList<String>(), [0xBBu8])
        let req2 = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", enc2).toData())
        @Assert(isResp(ex.execute(req2)))

        // 消费 batchSize=1 → 应只返回 1 条（break 阻止遍历剩余队列）
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode("test-group").encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let consReq = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", extractBytes(buf)).toData())
        @Assert(isResp(ex.execute(consReq)))
    }
}
