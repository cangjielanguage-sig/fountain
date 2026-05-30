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

/**
 * FMQ + Fleet 集成测试。
 *
 * 测试 FMQ 服务端/客户端通过 fleet 完成元数据持久化：
 *   1. FMQ 服务端 → fleet：注册/获取主题元数据
 *   2. FMQ 服务端 ↔ fleet：连接保活（PING/PONG）
 *   3. FMQ 客户端 → fleet：注册/获取消费者元数据
 *   4. FMQ 客户端 ↔ fleet：连接保活
 *   5. FMQ 客户端 → FMQ 服务端：消息生产/订阅/拉取
 *
 * 架构：
 *   测试进程内启动 fleet SyncServer（绑定独立端口），
 *   通过 SyncHandler.handle() 验证 fleet 端数据；
 *   通过 f_net.Client 客户端发起 MQ 命令验证端到端流程。
 */
package fountain::fmq.server

import std.collection.ArrayList
import std.fs.{exists, remove}
import std.io.{ByteBuffer, SeekPosition}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID, Command}
import fountain::f_codec.default.DefaultCodec
import fountain::fleet.base.{HostAndPort, SyncData, KeyData, ValueData}
import fountain::fleet.server.{SyncServer, SyncHandler, NodeManager, WatchManager}
import fountain::f_store.Store
import fountain::fmq.common.extractBytes

@Test
public class FmqFleetIntegrationTest {
    private static let FLEET_PORT_TOPIC: UInt16 = 19931
    private static let FLEET_PORT_CONSUMER: UInt16 = 19932
    private static let FLEET_PORT_KEEPALIVE: UInt16 = 19933
    private static let MQ_PORT_PRODUCE: UInt16 = 19141

    // ================================================================
    // 辅助方法
    // ================================================================

    private static func cleanupDir(dir: String): Unit {
        if (exists(dir)) { remove(dir, recursive: true) }
    }

    /** 启动 fleet SyncServer，返回服务端组件 */
    private static func startFleet(port: UInt16, dir: String,
            hosts: ArrayList<HostAndPort>, nodeIndex: Int64): (SyncServer, Store, SyncHandler) {
        cleanupDir(dir)
        let store = Store(dir)
        let nm = NodeManager(hosts, nodeIndex)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let server = SyncServer(port)
        server.start(handler)
        sleep(Duration.millisecond * 800)
        (server, store, handler)
    }

    /** 编码字符串数组 */
    private static func encodeStrings(v: Array<String>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
        for (s in v) { enc.encode(s) }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    // ================================================================
    // 测试 1：FMQ 服务端 → fleet：注册/获取主题元数据
    // ================================================================

    @TestCase
    public func testFmqServerRegisterTopicToFleet(): Unit {
        let fleetDir = "/tmp/fmq_fleet_int/topic"
        let hosts = ArrayList<HostAndPort>([HostAndPort("127.0.0.1:${FLEET_PORT_TOPIC}")])
        let (fleetServer, store, handler) = startFleet(FLEET_PORT_TOPIC, fleetDir, hosts, 0)
        sleep(Duration.second * 3)

        let topicName = "/fmq/fleet/test-topic-1"
        let topicMeta = TopicMeta(queueCount: 3,
            consumerGroups: ArrayList(),
            createTime: DateTime.now())
        let encoded = DefaultCodec().encode(topicMeta.toData()).finish()
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let rawVal = extractBytes(buf)

        // 1. REGISTER 到 fleet
        let fleetKey = "/mq/topics${topicName}"
        let resp = handler.handle(ProtocolMessage(Command.REGISTER,
            SyncData(fleetKey, 0, rawVal).toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })

        // 2. 验证 fleet Store 持久化
        if (let Some(stored) <- store.get(fleetKey.unsafeBytes())) {
            @Assert(stored.size == rawVal.size)
        } else {
            @Assert(false)
        }

        // 3. ACK 读取验证
        let ackResp = handler.handle(ProtocolMessage(Command.ACK,
            KeyData(fleetKey).toData()))
        let valueOpt = convert<ValueData>(ackResp.data)
        if (let Some(vd) <- valueOpt && vd.value.isSome()) {
            @Assert(vd.value.getOrThrow().size == rawVal.size)
        } else {
            @Assert(false)
        }

        fleetServer.close(); store.close(); cleanupDir(fleetDir)
    }

    // ================================================================
    // 测试 2：FMQ 服务端 ↔ fleet 连接保活
    // ================================================================

    @TestCase
    public func testFmqServerKeepAliveToFleet(): Unit {
        let fleetDir = "/tmp/fmq_fleet_int/keepalive"
        let hosts = ArrayList<HostAndPort>([HostAndPort("127.0.0.1:${FLEET_PORT_KEEPALIVE}")])
        let (fleetServer, store, handler) = startFleet(FLEET_PORT_KEEPALIVE, fleetDir, hosts, 0)
        sleep(Duration.second * 3)

        for (_ in 0..5) {
            let r = handler.handle(ProtocolMessage(Command.PING(0),
                SyncData("", 0, []).toData()))
            @Assert(match (r.command) { case PING(1) => true case _ => false })
        }

        fleetServer.close(); store.close(); cleanupDir(fleetDir)
    }

    // ================================================================
    // 测试 3：FMQ 客户端 → fleet：注册/获取消费者元数据
    // ================================================================

    @TestCase
    public func testFmqClientRegisterConsumerToFleet(): Unit {
        let fleetDir = "/tmp/fmq_fleet_int/consumer"
        let hosts = ArrayList<HostAndPort>([HostAndPort("127.0.0.1:${FLEET_PORT_CONSUMER}")])
        let (fleetServer, store, handler) = startFleet(FLEET_PORT_CONSUMER, fleetDir, hosts, 0)
        sleep(Duration.second * 3)

        let consumerReg = ConsumerRegistration(
            consumerId: "consumer-abc",
            groupId: "test-group",
            matchModeStr: "Exact:/order/create",
            labels: None,
            dataFilter: Some("$.key == 42"),
            lastHeartbeat: DateTime.now())

        let encoded = DefaultCodec().encode(consumerReg.toData()).finish()
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let rawReg = extractBytes(buf)

        let consumeKey = "/mq/consumes/${consumerReg.consumerId}"
        let resp = handler.handle(ProtocolMessage(Command.REGISTER,
            SyncData(consumeKey, 0, rawReg).toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })

        if (let Some(stored) <- store.get(consumeKey.unsafeBytes())) {
            @Assert(stored.size == rawReg.size)
        } else { @Assert(false) }

        let ackResp = handler.handle(ProtocolMessage(Command.ACK,
            KeyData(consumeKey).toData()))
        let valueOpt = convert<ValueData>(ackResp.data)
        if (let Some(vd) <- valueOpt && vd.value.isSome()) {
            @Assert(vd.value.getOrThrow().size == rawReg.size)
        } else { @Assert(false) }

        fleetServer.close(); store.close(); cleanupDir(fleetDir)
    }

    // ================================================================
    // 测试 4：FMQ 客户端 ↔ fleet 连接保活
    // ================================================================

    @TestCase
    public func testFmqClientKeepAliveToFleet(): Unit {
        let fleetDir = "/tmp/fmq_fleet_int/clientkp"
        let hosts = ArrayList<HostAndPort>([HostAndPort("127.0.0.1:${FLEET_PORT_CONSUMER}")])
        let (fleetServer, store, handler) = startFleet(FLEET_PORT_CONSUMER, fleetDir, hosts, 0)
        sleep(Duration.second * 3)

        for (_ in 0..5) {
            let r = handler.handle(ProtocolMessage(Command.PING(0),
                SyncData("", 0, []).toData()))
            @Assert(match (r.command) { case PING(1) => true case _ => false })
        }

        fleetServer.close(); store.close(); cleanupDir(fleetDir)
    }

    // ================================================================
    // 测试 5：FMQ 客户端 → FMQ 服务端：消息生产、订阅、拉取
    // ================================================================

    @TestCase
    public func testClientProduceSubscribeConsumeViaFmq(): Unit {
        let fleetDir = "/tmp/fmq_fleet_int/e2e"
        let hosts = ArrayList<HostAndPort>([HostAndPort("127.0.0.1:${FLEET_PORT_KEEPALIVE}")])
        let (fleetServer, store, handler) = startFleet(FLEET_PORT_KEEPALIVE, fleetDir, hosts, 0)
        sleep(Duration.second * 3)

        let mqDir = "/tmp/fmq_fleet_int/mq_data"
        cleanupDir(mqDir)
        let config = mqConfigWithFleet(FLEET_PORT_KEEPALIVE, MQ_PORT_PRODUCE, mqDir)
        let topicManager = TopicManager(config)
        let queueManager = QueueManager(config, nodeIndex: 0)
        let deliveryManager = DeliveryManager(config)
        let consumerMatcher = ConsumerMatcher()
        let replicationManager = ReplicationManager(config)
        let executor = CommandExecutor(
            topicManager, queueManager, deliveryManager,
            consumerMatcher, replicationManager, config: config)

        let server = MqServer(bindPort: MQ_PORT_PRODUCE, queueSize: 1024)
        server.start({ msg => executor.execute(msg) })

        // 等待 TcpServerSocket 初始化
        sleep(Duration.millisecond * 800)

        // 轮询等待就绪
        for (_ in 0..80) {
            try {
                let testSock = TcpSocket("127.0.0.1", MQ_PORT_PRODUCE)
                testSock.close()
                break
            } catch (_: Exception) {
                sleep(Duration.millisecond * 100)
            }
        }

        let client = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
            queueSize: 1024, socketCount: 1,
            host: "127.0.0.1", port: MQ_PORT_PRODUCE,
            idGetter: { msg => msg.id },
            checkDuration: Duration.second * 5,
            checker: { _ => true }
        ).noDelay(true).build()

        let topic = "/fmq/e2e/test-topic"

        // 1. 创建主题
        let createPayload = encodeStrings(["create", topic, "1"])
        let createReq = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", createPayload).toData())
        let createResp = client.transfer(createReq.id, createReq, Duration.second * 5)
        @Assert(createResp.isSome())

        // 2. 生产消息
        let msgPayload = [0xE2u8, 0xE3u8, 0xE4u8]
        let produceEncoded = ProduceCodec.encode(topic, ArrayList<String>(), msgPayload)
        let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", produceEncoded).toData())
        let prodResp = client.transfer(prodReq.id, prodReq, Duration.second * 5)
        @Assert(prodResp.isSome())

        // 3. 订阅 topic
        let subPayload = encodeStrings([topic, "exact"])
        let subReq = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", subPayload).toData())
        let subResp = client.transfer(subReq.id, subReq, Duration.second * 5)
        @Assert(subResp.isSome())

        // 4. 拉取消费
        let consumeBuf = ByteBuffer()
        DefaultCodec().encode(topic).encode("test-group").encode(1i64)
            .finish().copy(to: consumeBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let consumeReq = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", extractBytes(consumeBuf)).toData())
        let consumeResp = client.transfer(consumeReq.id, consumeReq, Duration.second * 5)
        @Assert(consumeResp.isSome())

        // 5. 验证 RESP 类型
        if (let Some(resp) <- consumeResp) {
            @Assert((resp.command.value >> 4) == 11u8)
        }

        client.close()
        server.close()
        fleetServer.close(); store.close()
        cleanupDir(fleetDir); cleanupDir(mqDir)
    }

    private static func mqConfigWithFleet(fleetPort: UInt16, mqPort: UInt16, dataDir: String): MqConfig {
        let mqHosts = ArrayList<String>()
        mqHosts.add("127.0.0.1:${mqPort}")
        let syncHosts = ArrayList<String>()
        syncHosts.add("127.0.0.1:${fleetPort}")
        MqConfig(
            mqHosts: mqHosts, syncHosts: syncHosts,
            dataDir: dataDir, segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}
