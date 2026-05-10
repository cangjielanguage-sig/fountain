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
}
