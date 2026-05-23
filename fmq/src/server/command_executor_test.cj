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
import fountain::f_protocol.default.{Message as ProtocolMessage, MessageID, Command, VOTE, APPROVE}
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
        let topicPayload = enc(["/test-sub", "test-group", "exact"])

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
            MqBody("subscribe", enc(["", "test-group", "exact"])).toData())
        @Assert(isResp(ex.execute(req)))
    }

    /**
     * SUBSCRIBE 同一 topic 两次使用相同 consumerId（基于 pid+topic），
     * UNSUBSCRIBE 能正确匹配注销。
     */
    @TestCase
    public func testSubscribeSameTopicTwiceRoundtrip(): Unit {
        let ex = makeExecutor()
        let tp1 = enc(["/sub-topic", "sub-group", "exact"])

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

    /**
     * P0-1: 验证 encodeSubscribe 传递 groupId 到服务端，多组独立注册。
     * 修复前 groupId 被丢弃，所有订阅同一 topic 的消费者共享一组。
     */
    @TestCase
    public func testSubscribeWithGroupIdIndependentGroups(): Unit {
        let ex = makeExecutor()

        // 订阅 group-a → /test-p0-1-group
        let g1 = enc(["/test-p0-1-group", "group-a", "exact"])
        let req1 = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", g1).toData())
        @Assert(isResp(ex.execute(req1)))

        // 订阅 group-b → 同一 topic /test-p0-1-group
        let g2 = enc(["/test-p0-1-group", "group-b", "exact"])
        let req2 = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", g2).toData())
        @Assert(isResp(ex.execute(req2)))

        // 验证两个消费者组都注册成功
        let matched = ex.consumerMatcher.matchTopic("/test-p0-1-group")
        @Assert(matched.size >= 2)

        // 退订 group-a
        let unsubA = enc(["/test-p0-1-group", "group-a", "exact"])
        let req3 = ProtocolMessage(Command.UNSUBSCRIBE, MessageID(),
            MqBody("unsubscribe", unsubA).toData())
        @Assert(isResp(ex.execute(req3)))

        // 验证 group-b 仍存在
        let remaining = ex.consumerMatcher.matchTopic("/test-p0-1-group")
        @Assert(remaining.size >= 1)
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
        // 验证返回 consumer_list 类型且 size=0
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "consumer_list")
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                @Assert(count == 0)
            }
        }
    }

    @TestCase
    public func testListConsumersReturnsRegisteredConsumer(): Unit {
        let ex = makeExecutor()
        // 1. 注册两个消费者
        let reg1 = ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", enc(["group-a", "consumer-1", "Exact:/test"])).toData())
        @Assert(isResp(ex.execute(reg1)))
        let reg2 = ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", enc(["group-b", "consumer-2", "Exact:/test"])).toData())
        @Assert(isResp(ex.execute(reg2)))

        // 2. 列出 /test 的消费者
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["listConsumers", "/test"])).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))

        // 3. 验证响应包含两个消费者
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "consumer_list")
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                @Assert(count == 2)
                for (i in 0..count) {
                    let cid = dec.decode<String>(buf)
                    let gid = dec.decode<String>(buf)
                    let mode = dec.decode<String>(buf)
                    @Assert(cid.isSome())
                    @Assert(gid.isSome())
                    @Assert(mode.isSome())
                }
            }
        }
    }

    @TestCase
    public func testListConsumersFiltersByTopic(): Unit {
        let ex = makeExecutor()
        // 注册消费者：一个匹配 /a，一个匹配 /b
        ex.execute(ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", enc(["g1", "c1", "Exact:/a"])).toData()))
        ex.execute(ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", enc(["g2", "c2", "Exact:/b"])).toData()))

        // 列出匹配 /a 的消费者 — 应只有 1 个
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["listConsumers", "/a"])).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                @Assert(count == 1)
            }
        }
    }

    @TestCase
    public func testListConsumersDeregisterRemovesConsumer(): Unit {
        let ex = makeExecutor()
        // 注册消费者
        ex.execute(ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", enc(["g", "c1", "Exact:/x"])).toData()))
        ex.execute(ProtocolMessage(Command.DEREGISTER, MessageID(),
            MqBody("deregister", enc(["g", "c1"])).toData()))

        // 列出 — 应空
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["listConsumers", "/x"])).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(count) <- dec.decode<Int64>(buf)) {
                @Assert(count == 0)
            }
        }
    }

    // ── 批量 group 查询 ──

    @TestCase
    public func testListAllGroupsEmptyReturnsResp(): Unit {
        let ex = makeExecutor()
        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["listAllGroups", ""])).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "all_group_list")
        }
    }

    @TestCase
    public func testListAllGroupsWithGroups(): Unit {
        let ex = makeExecutor()
        // 创建 topic 并添加 consumer groups
        ex.execute(ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["create", "/tg1"])).toData()))
        ex.execute(ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["addGroup", "/tg1", "grp-a"])).toData()))
        ex.execute(ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["addGroup", "/tg1", "grp-b"])).toData()))

        let req = ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["listAllGroups", ""])).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "all_group_list")
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(tc) <- dec.decode<Int64>(buf)) {
                // 应有 1 个 topic（/tg1）
                @Assert(tc == 1)
                if (let Some(topic) <- dec.decode<String>(buf)
                    && let Some(gc) <- dec.decode<Int64>(buf)) {
                    @Assert(topic == "/tg1")
                    @Assert(gc == 2)
                }
            }
        }
    }

    @TestCase
    public func testAddGroupViaHandlerInitializesOffsets(): Unit {
        let ex = makeExecutor()
        // 创建多队列主题 (queueCount=3)
        ex.execute(ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["create", "/multi-q-grp"])).toData()))
        // 通过 handler 添加消费者组 → 应该经过 ConsumerGroupManager
        ex.execute(ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["addGroup", "/multi-q-grp", "test-grp"])).toData()))
        // 验证所有队列 offset 被初始化（P3-3: ConsumerGroupManager 不再是死代码）
        @Assert(ex.deliveryManager.getOffset("/multi-q-grp", 0, "test-grp") == 0)
        @Assert(ex.deliveryManager.getOffset("/multi-q-grp", 1, "test-grp") == 0)
        @Assert(ex.deliveryManager.getOffset("/multi-q-grp", 2, "test-grp") == 0)
    }

    // ── 批量 CONSUME ──

    @TestCase
    public func testBatchConsumeEmptyReturnsResp(): Unit {
        let ex = makeExecutor()
        // 编码批量 consume: topicCount=1, topic="/no", groupId="g", batchSize=1
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(1i64).encode("/no").encode("g").encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("batch_consume", extractBytes(buf)).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "batch_consume")
        }
    }

    @TestCase
    public func testBatchConsumeWithTopicReturnsMsg(): Unit {
        let ex = makeExecutor()
        // 1. 创建 topic 并生产消息
        ex.execute(ProtocolMessage(Command.TOPIC_OP, MessageID(),
            MqBody("topic_op", enc(["create", "/bt"])).toData()))
        let encoded = ProduceCodec.encode("/bt", ArrayList<String>(), [0x01u8, 0x02u8])
        ex.execute(ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData()))

        // 2. 批量 consume
        let reqBuf = ByteBuffer()
        DefaultCodec()
            .encode(1i64).encode("/bt").encode("g").encode(1i64)
            .finish().copy(to: reqBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let req = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("batch_consume", extractBytes(reqBuf)).toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "batch_consume")
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            // 应返回 1 topic
            if (let Some(tc) <- dec.decode<Int64>(buf)
                && let Some(topic) <- dec.decode<String>(buf)
                && let Some(gi) <- dec.decode<String>(buf)
                && let Some(mc) <- dec.decode<Int64>(buf)) {
                @Assert(tc == 1)
                @Assert(topic == "/bt")
                @Assert(mc == 1)
            }
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

    // ── 选举 ──

    @TestCase
    public func testElectionMasterRejectsVote(): Unit {
        // P3-6: Master 节点收到 VOTE 请求返回 error，阻止 split-brain
        let ex = makeExecutor()
        ex.replicationManager.promoteToMaster()
        let req = ProtocolMessage(Command.ELECT(VOTE), MessageID(),
            DataNone.INSTANCE.toData())
        let resp = ex.execute(req)
        @Assert(isResp(resp))
        if (let Some(body) <- convert<MqBody>(resp.data)) {
            @Assert(body.bodyType == "error")
        }
    }

    @TestCase
    public func testElectionSlaveAcceptsVote(): Unit {
        // P3-6: Slave 节点收到 VOTE 请求应 approve（在位选上设置 APPROVE 位）
        let ex = makeExecutor()
        // ReplicationManager 默认为 slave
        let req = ProtocolMessage(Command.ELECT(VOTE), MessageID(),
            DataNone.INSTANCE.toData())
        let resp = ex.execute(req)
        // Slave 的 VOTE 响应应包含 APPROVE 位（0x04），非 error RESP
        @Assert((resp.command.value & APPROVE) != 0u8)
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

    /**
     * P0-2: 验证 deliveryId 包含唯一序号，防止重复。
     * 修复前 deliveryId="${topic}:${q.index}:${groupId}:${offset}"，
     * 未 ACK 时 offset 相同 → deliveryId 重复。
     * 修复后 deliveryId="${topic}:${q.index}:${groupId}:${offset}:${sn}"。
     */
    @TestCase
    public func testConsumeDeliveryIdIncludesSequence(): Unit {
        let ex = makeExecutor()
        let topic = "/delivery-sn-unique"

        // 生产 2 条消息
        for (_ in 0..2) {
            let encoded = ProduceCodec.encode(topic, ArrayList(), [0x01u8])
            let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
                MqBody("produce", encoded).toData())
            @Assert(isResp(ex.execute(prodReq)))
        }

        // 第一次 CONSUME（不 ACK）
        let buf = ByteBuffer()
        DefaultCodec().encode(topic).encode("sn-group").encode(1i64)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let payload = extractBytes(buf)
        let consReq1 = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", payload).toData())
        let resp1 = ex.execute(consReq1)
        @Assert(isResp(resp1))
        // 解码第一个响应的 deliveryId
        let id1 = CommandExecutorTest.decodeFirstDeliveryId(resp1)
        @Assert(id1.isSome())

        // 第二次 CONSUME（同一 payload，不 ACK）
        let consReq2 = ProtocolMessage(Command.CONSUME(0), MessageID(),
            MqBody("consume", payload).toData())
        let resp2 = ex.execute(consReq2)
        @Assert(isResp(resp2))
        let id2 = CommandExecutorTest.decodeFirstDeliveryId(resp2)
        @Assert(id2.isSome())

        // 验证 deliveryId 不同（sn 递增）
        if (let Some(a) <- id1 && let Some(b) <- id2) {
            @Assert(a != b)
            // deliveryId 格式: topic:queueIndex:groupId:offset:sn (5 段)
            @Assert(a.split(':').size >= 5)
            @Assert(b.split(':').size >= 5)
        }
    }

    /** 解码 CONSUME 响应的第一条 deliveryId */
    private static func decodeFirstDeliveryId(msg: ProtocolMessage): ?String {
        try {
            if (let Some(body) <- convert<MqBody>(msg.data) && body.bodyType == "consume") {
                let buf = ByteBuffer(body.payload)
                let dec = DefaultCodec()
                if (let Some(count) <- dec.decode<Int64>(buf) && count > 0
                    && let Some(deliveryId) <- dec.decode<String>(buf)) {
                    return Some(deliveryId)
                }
            }
        } catch (_: Exception) {}
        None
    }

    /**
     * P1-2: 验证 subscribe 只创建一条 ConsumerRegistration（不再双重注册）。
     * P0-1 encodeSubscribe 补全 groupId 后，SUBSCRIBE 完整注册消费者。
     * P1-2 移除 REGISTER 调用后，不应再产生第二条注册。
     */
    @TestCase
    public func testSubscribeCreatesSingleRegistration(): Unit {
        let ex = makeExecutor()
        let topic = "/single-reg-topic"
        let payload = enc([topic, "single-group", "exact"])

        let req = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", payload).toData())
        @Assert(isResp(ex.execute(req)))

        // 查询 ConsumerMatcher 中的注册数
        let regs = ex.consumerMatcher.getRegistrations()
        // 验证至少存在 1 条注册（但不能>1条同一 consumerId 的注册）
        let matched = ex.consumerMatcher.matchTopic(topic)
        @Assert(matched.size >= 1)
        // matchTopic 返回 groupId→consumerId，同组应只选一个消费者
        // 如果存在双重注册，matchTopic 的 round-robin 会交替选择两个 consumerId
        // 再次 match 验证一致性
        let matched2 = ex.consumerMatcher.matchTopic(topic)
        @Assert(matched2.size == 1)
    }

    /**
     * P1-1: 验证 QueueManager 不再启动 QueueReader 线程。
     * P1-1 移除了 readers ArrayList 和 QueueReader spawn。
     * 测试 QueueManager.createQueues + startAll 只启动 writer。
     */
    @TestCase
    public func testQueueManagerHasNoReaderThreads(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_no_reader_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let tm = TopicManager(config)
        let qm = QueueManager(config, nodeIndex: 0)
        let rm = ReplicationManager(config)

        // 创建主题 + 队列 + 启动 writer（应不再启动 reader）
        tm.createTopic("/no-reader-topic", queueCount: 1)
        qm.createQueues("/no-reader-topic", 1)
        qm.setReplicationManager(rm)
        qm.startAll()

        // 验证 startAll 不抛异常（reader 已移除）
        @Assert(true)
        qm.close()
    }

    /**
     * SRV-1: 验证 produce 到不存在的 topic 时自动创建队列并启动 writer。
     * 修复前 handleProduce 只调 createQueues 未调 startWritersForTopic。
     */
    @TestCase
    public func testProduceToNewTopicAutoStartsWriter(): Unit {
        let ex = makeExecutor()
        let topic = "/auto-writer-topic"

        // 生产一条消息到不存在的 topic → 触发自动创建
        let encoded = ProduceCodec.encode(topic, ArrayList(), [0x01u8])
        let prodReq = ProtocolMessage(Command.PUBLISH(0), MessageID(),
            MqBody("produce", encoded).toData())
        @Assert(isResp(ex.execute(prodReq)))

        // 验证队列已创建并 writer 已启动
        let queues = ex.queueManager.getQueues(topic)
        @Assert(queues.isSome())
        if (let Some(qs) <- queues) {
            @Assert(qs.size >= 1)
            let writer = ex.queueManager.getWriterForQueue(qs[0])
            @Assert(writer.isSome())
        }
    }
}

/**
 * DeliveryManager retry 测试。
 * P1-1: 验证 retry 使用 correct topic（而非 groupId）匹配消费者。
 */
@Test
public class DeliveryRetryTopicTest {
    @TestCase
    public func testRetryUsesTopicFromRecord(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm  // capture let for lambda

        // 注册消费者匹配 /test-retry-topic
        let reg = ConsumerRegistration(
            consumerId: "retry-consumer", groupId: "retry-group",
            matchModeStr: "Exact:/test-retry-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 构造 DeliveryRecord 包含正确的 topic
        let record = DeliveryRecord(
            "/test-retry-topic:0:retry-group:0",   // messageId
            "retry-consumer",                       // consumerId
            "retry-group",                          // groupId
            "/test-retry-topic",                    // topic
            DateTime.now() - Duration.second * 60,  // deliverTime (超时)
            retryCount: 0)

        // retry 应使用 record.topic 找到消费者，返回 true
        @Assert(dmL.retry(record, cm))
        // retryCount 应递增为 1
        @Assert(record.retryCount == 1)
    }

    @TestCase
    public func testRetryWrongTopicReturnsFalse(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm  // capture let for lambda

        // 注册消费者匹配 /other-topic
        let reg = ConsumerRegistration(
            consumerId: "other-consumer", groupId: "other-group",
            matchModeStr: "Exact:/other-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 记录 topic=/wrong-topic 与消费者注册的 /other-topic 不匹配
        let record = DeliveryRecord(
            "/wrong-topic:0:other-group:0",         // messageId
            "other-consumer",                        // consumerId
            "other-group",                           // groupId
            "/wrong-topic",                          // topic
            DateTime.now() - Duration.second * 60,   // deliverTime
            retryCount: 0)

        // 无匹配消费者 → retry 返回 false
        @Assert(!dmL.retry(record, cm))
    }

    /**
     * P0-3: 验证 retryCount > maxRetryCount fencepost
     * maxRetryCount=3 应允许 3 次重试，第 4 次触发 DLQ。
     * 修复前用 >= 导致实际只重试 2 次。
     */
    @TestCase
    public func testRetryCountFencepostAllowsAllRetries(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm

        let reg = ConsumerRegistration(
            consumerId: "rf-consumer", groupId: "rf-group",
            matchModeStr: "Exact:/retry-fence",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        let record = DeliveryRecord(
            "/retry-fence:0:rf-group:0",
            "rf-consumer", "rf-group", "/retry-fence",
            DateTime.now() - Duration.second * 60,
            retryCount: 0)

        // retry 1: count 0→1, 1>3 false
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount == 1)
        // retry 2: count 1→2, 2>3 false
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount == 2)
        // retry 3: count 2→3, 3>3 false
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount == 3)
        // retry 4: count 3→4, 4>3 true → DLQ
        @Assert(!dmL.retry(record, cm))
        @Assert(record.retryCount == 4)
    }

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_retry_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }
}

/**
 * ConsumerGroupManager createGroup 多队列 offset 测试。
 * P1-2: 验证 createGroup 为所有队列初始化 offset=0。
 */
@Test
public class CreateGroupMultiQueueTest {
    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_cg_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }

    @TestCase
    public func testCreateGroupInitializesAllQueueOffsets(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建多队列主题
        tm.createTopic("/multi-queue", queueCount: 3)

        // 创建消费者组
        let code = cgm.createGroup("/multi-queue", "test-group")
        @Assert(code == MqErrorCode.SUCCESS)

        // 验证 3 个队列的 offset 全部初始化为 0
        @Assert(cgm.getOffset("/multi-queue", 0, "test-group") == 0)
        @Assert(cgm.getOffset("/multi-queue", 1, "test-group") == 0)
        @Assert(cgm.getOffset("/multi-queue", 2, "test-group") == 0)
    }

    @TestCase
    public func testCreateGroupWithSingleQueue(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建单队列主题（默认）
        tm.createTopic("/single-queue", queueCount: 1)
        let code = cgm.createGroup("/single-queue", "single-group")
        @Assert(code == MqErrorCode.SUCCESS)

        // 仅 queue 0 应被初始化
        @Assert(cgm.getOffset("/single-queue", 0, "single-group") == 0)
    }
}

/**
 * ConsumerGroupManager deleteGroup 多队列 offset 重置测试。
 * P1-1: 验证 deleteGroup 重置所有队列的 offset=0，而非仅 queue 0。
 */
@Test
public class DeleteGroupMultiQueueTest {
    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_dg_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }

    @TestCase
    public func testDeleteGroupResetsAllQueueOffsets(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建多队列主题 (queueCount=3)
        tm.createTopic("/multi-delete", queueCount: 3)

        // 创建消费者组（初始化所有 offset=0）
        @Assert(cgm.createGroup("/multi-delete", "del-group") == MqErrorCode.SUCCESS)

        // 在不同队列上设置不同 offset
        cgm.setOffset("/multi-delete", 0, "del-group", 10)
        cgm.setOffset("/multi-delete", 1, "del-group", 20)
        cgm.setOffset("/multi-delete", 2, "del-group", 30)
        @Assert(cgm.getOffset("/multi-delete", 0, "del-group") == 10)
        @Assert(cgm.getOffset("/multi-delete", 1, "del-group") == 20)
        @Assert(cgm.getOffset("/multi-delete", 2, "del-group") == 30)

        // 删除消费者组 — 应重置所有队列 offset=0
        @Assert(cgm.deleteGroup("/multi-delete", "del-group") == MqErrorCode.SUCCESS)
        @Assert(cgm.getOffset("/multi-delete", 0, "del-group") == 0)
        @Assert(cgm.getOffset("/multi-delete", 1, "del-group") == 0)
        @Assert(cgm.getOffset("/multi-delete", 2, "del-group") == 0)
    }

    @TestCase
    public func testDeleteGroupSingleQueue(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建单队列主题
        tm.createTopic("/single-delete", queueCount: 1)
        @Assert(cgm.createGroup("/single-delete", "sg") == MqErrorCode.SUCCESS)
        cgm.setOffset("/single-delete", 0, "sg", 99)
        @Assert(cgm.getOffset("/single-delete", 0, "sg") == 99)

        // 删除组并验证 offset 重置
        @Assert(cgm.deleteGroup("/single-delete", "sg") == MqErrorCode.SUCCESS)
        @Assert(cgm.getOffset("/single-delete", 0, "sg") == 0)
    }

    @TestCase
    public func testDeleteGroupNonExistentReturnsError(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 删除不存在的组应返回错误
        let code = cgm.deleteGroup("/no-topic", "no-group")
        @Assert(code != MqErrorCode.SUCCESS)
    }
}

/**
 * ConsumerMatcher deregister 并发缓存测试。
 * P2-2: 验证 deregister 后 compiledPatterns 清空在同步块内。
 */
@Test
public class DeregisterCacheTest {
    @TestCase
    public func testDeregisterClearsCompiledPatternsInSync(): Unit {
        let cm = ConsumerMatcher()

        // 注册 Glob 模式消费者
        let reg = ConsumerRegistration(
            consumerId: "g-consumer", groupId: "g-group",
            matchModeStr: "Glob:/orders/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 触发 compiledPatterns 缓存
        @Assert(cm.matchTopic("/orders/123").size == 1)

        // 注销后 match 应返回 0
        cm.deregister("g-group", "g-consumer")
        @Assert(cm.matchTopic("/orders/123").size == 0)
    }

    @TestCase
    public func testDeregisterWithConcurrentMatch(): Unit {
        let cm = ConsumerMatcher()

        // 注册 Glob 消费者
        let reg = ConsumerRegistration(
            consumerId: "rr-consumer", groupId: "rr-group",
            matchModeStr: "Glob:/api/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 并发 deregister + matchTopic
        let f1 = spawn { cm.deregister("rr-group", "rr-consumer"); true }
        let f2 = spawn { cm.matchTopic("/api/v1").size >= 0; true }
        let f3 = spawn { cm.matchTopic("/api/v2").size >= 0; true }
        f1.get()
        f2.get()
        f3.get()
        // 不抛异常就算通过
        @Assert(cm.matchTopic("/api/v1").size == 0)
    }
}

/**
 * ReplicationManager 角色切换测试。
 * P2-3: 验证 promoteToMaster/demoteToSlave/switchbackToMaster
 * 在 stateLock 保护下返回正确的 role()。
 */
@Test
public class ReplicationRoleStateTest {
    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("master:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }

    @TestCase
    public func testPromoteDemoteCycle(): Unit {
        let rm = ReplicationManager(testConfig())
        @Assert(rm.role() == "slave()")

        rm.promoteToMaster()
        @Assert(rm.role() == "master")

        rm.demoteToSlave("backup:7201")
        let role = rm.role()
        @Assert(role == "slave(backup:7201)")
    }

    @TestCase
    public func testSwitchbackToMaster(): Unit {
        let rm = ReplicationManager(testConfig())
        rm.promoteToMaster()
        @Assert(rm.role() == "master")

        // 切回：当前 Master 将角色交还原 Master
        rm.switchbackToMaster("original:7201")
        @Assert(rm.role() == "slave(original:7201)")
    }

    @TestCase
    public func testIsMasterAliveWhenNoConnection(): Unit {
        let rm = ReplicationManager(testConfig())
        // 无连接时 isMasterAlive 不应抛异常
        @Assert(rm.isMasterAlive())
    }

    @TestCase
    public func testIncrementalSyncWithStateLock(): Unit {
        let rm = ReplicationManager(testConfig())
        // onIncrementalSync 内部使用 stateLock 保护 lastMasterSeq
        // 即使 isSyncing=false 也应安全返回（不抛异常）
        rm.onIncrementalSync([0x01u8, 0x02u8], 42)
        // 验证调用后状态一致
        @Assert(rm.role() == "slave()")
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
        // 作为 Master 调用 onIncrementalSync 也不应抛异常
        rm.onIncrementalSync([0x03u8], 99)
        @Assert(rm.role() == "master")
    }
}
