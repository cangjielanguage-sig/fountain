/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

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
import std.sync.Mutex
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID, Command}
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}

/**
 * MQ 全链路集成测试。
 * 启动真实 TCP 服务端，通过 f_net::Client 发送命令，验证完整通信流程。
 * 注意：这些测试需要独占端口，不可并行。
 */
@Test
public class MqIntegrationTest {
    private static let BASE_PORT: UInt16 = 19100u16
    private static let TEST_HOST = "127.0.0.1"
    private static var portCounter: Int64 = 0
    private static let counterLock = Mutex()

    // ── 服务端辅助 ──

    private static func nextPort(): UInt16 {
        synchronized(counterLock) {
            let p = BASE_PORT + UInt16(portCounter)
            portCounter += 1
            p
        }
    }

    private static func testConfig(port: UInt16): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("127.0.0.1:${port}")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_int_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 30, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }

    private static func startServer(): (MqServer, UInt16) {
        let port = nextPort()
        let config = testConfig(port)
        let topicManager = TopicManager(config)
        let queueManager = QueueManager(config, nodeIndex: 0)
        let deliveryManager = DeliveryManager(config)
        let consumerMatcher = ConsumerMatcher()
        let replicationManager = ReplicationManager(config)
        let executor = CommandExecutor(
            topicManager, queueManager, deliveryManager,
            consumerMatcher, replicationManager, config: config)

        let server = MqServer(bindPort: port, queueSize: 1024)
        server.start({ msg => executor.execute(msg) })
        // 等待 f_net::Server 完成 TCP 绑定
        sleep(Duration.second * 3)
        (server, port)
    }

    private static func makeClient(port: UInt16): Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID> {
        Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
            queueSize: 1024, socketCount: 1,
            host: TEST_HOST, port: port,
            idGetter: { msg => msg.id },
            checkDuration: Duration.second * 30,
            checker: { _ => true }
        ).noDelay(true).build()
    }

    private static func extractBytes(buf: ByteBuffer): Array<Byte> {
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)
        raw
    }

    // ──────────────── 测试 1: 管理端 ↔ 服务端 ────────────────

    @TestCase
    public func testCliCreateTopicAndList(): Unit {
        let (server, port) = startServer()
        let client = makeClient(port)
        sleep(Duration.millisecond * 200)

        // 1. 创建主题
        let topic = "/int-test-cli"
        let createPayload = encodeStrings(["create", topic, "1"])
        let createReq = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", createPayload).toData())
        let createResp = client.transfer(createReq.id, createReq, Duration.second * 5)
        @Assert(createResp.isSome())

        // 2. 列出主题
        let listPayload = encodeStrings(["list", "", "0"])
        let listReq = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", listPayload).toData())
        let listResp = client.transfer(listReq.id, listReq, Duration.second * 5)
        @Assert(listResp.isSome())

        client.close()
        server.close()
    }

    // ──────────────── 测试 2: 生产者 ↔ 服务端 ────────────────

    @TestCase
    public func testProduceMessageViaTcp(): Unit {
        let (server, port) = startServer()
        let client = makeClient(port)
        sleep(Duration.millisecond * 200)

        // 生产一条消息（先创建主题）
        let topic = "/int-test-produce"
        let createPayload = encodeStrings(["create", topic, "1"])
        let createReq = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", createPayload).toData())
        client.transfer(createReq.id, createReq, Duration.second * 5)

        // 生产
        let payload = [0x41u8, 0x42u8, 0x43u8]
        let encoded = ProduceCodec.encode(topic, ArrayList<String>(), payload)
        let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        let prodResp = client.transfer(prodReq.id, prodReq, Duration.second * 5)
        @Assert(prodResp.isSome())

        client.close()
        server.close()
    }

    // ──────────────── 测试 3: 消费者 ↔ 服务端 ────────────────

    @TestCase
    public func testConsumeMessageViaTcp(): Unit {
        let (server, port) = startServer()
        let client = makeClient(port)
        sleep(Duration.millisecond * 200)

        let topic = "/int-test-consume"

        // 创建主题
        let createPayload = encodeStrings(["create", topic, "1"])
        let createReq = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", createPayload).toData())
        client.transfer(createReq.id, createReq, Duration.second * 5)

        // 生产一条消息
        let payload = [0xDEu8, 0xADu8]
        let encoded = ProduceCodec.encode(topic, ArrayList<String>(), payload)
        let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        let prodResp = client.transfer(prodReq.id, prodReq, Duration.second * 5)
        @Assert(prodResp.isSome())

        // 订阅 topic
        let subPayload = encodeStrings([topic, "exact"])
        let subReq = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", subPayload).toData())
        let subResp = client.transfer(subReq.id, subReq, Duration.second * 5)
        @Assert(subResp.isSome())

        // 拉取消费
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode("test-group").encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let consumeReq = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", extractBytes(buf)).toData())
        let consumeResp = client.transfer(consumeReq.id, consumeReq, Duration.second * 5)
        @Assert(consumeResp.isSome())

        client.close()
        server.close()
    }

    // ──────────────── 测试 4: 生产者 → 服务端 → 消费者 全链路 ────────────────

    @TestCase
    public func testEndToEndProduceAndConsume(): Unit {
        let (server, port) = startServer()
        let producer = makeClient(port)
        let consumer = makeClient(port)
        sleep(Duration.millisecond * 200)

        let topic = "/int-test-e2e"
        let groupId = "e2e-group"

        // 1. 创建主题
        let createPayload = encodeStrings(["create", topic, "1"])
        let createReq = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", createPayload).toData())
        let createResp = producer.transfer(createReq.id, createReq, Duration.second * 5)
        @Assert(createResp.isSome())

        // 2. 生产者发送消息
        let msgPayload = [0xE2u8, 0xE3u8]
        let encoded = ProduceCodec.encode(topic, ArrayList<String>(), msgPayload)
        let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        let prodResp = producer.transfer(prodReq.id, prodReq, Duration.second * 5)
        @Assert(prodResp.isSome())

        // 3. 消费者订阅
        let subPayload = encodeStrings([topic, "exact"])
        let subReq = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", subPayload).toData())
        let subResp = consumer.transfer(subReq.id, subReq, Duration.second * 5)
        @Assert(subResp.isSome())

        // 4. 消费者拉取
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode(groupId).encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let consumeReq = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", extractBytes(buf)).toData())
        let consumeResp = consumer.transfer(consumeReq.id, consumeReq, Duration.second * 5)
        @Assert(consumeResp.isSome())

        // 5. 验证响应是 RESP 类型
        if (let Some(resp) <- consumeResp) {
            @Assert((resp.command.value >> 4) == 11u8)  // RESP tag
        }

        producer.close()
        consumer.close()
        server.close()
    }

    private static func encodeStrings(v: Array<String>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
        for (s in v) { enc.encode(s) }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }
}
