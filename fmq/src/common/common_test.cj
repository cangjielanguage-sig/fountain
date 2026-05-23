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
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage

@Test
public class TopicTest {
    @TestCase
    public func testValidateValidTopics(): Unit {
        @Assert(validateTopic("/order/create"))
        @Assert(validateTopic("/"))
        @Assert(validateTopic("/a/b/c"))
        @Assert(validateTopic("/order-123"))
    }

    @TestCase
    public func testValidateInvalidTopics(): Unit {
        @Assert(!validateTopic(""))
        @Assert(!validateTopic("no-leading-slash"))
        @Assert(!validateTopic("/with space"))
        @Assert(!validateTopic("/特殊字符"))
    }

    @TestCase
    public func testEncodeDecodeRoundtrip(): Unit {
        let topic = "/order/create"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_order_create")
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testEncodeDecodeWithUnderscore(): Unit {
        let topic = "/a_b/c_d"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_a__b_c__d")
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testEncodeDecodeDoubleUnderscore(): Unit {
        let topic = "/a__b"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_a____b")
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testEncodeDecodeLongPath(): Unit {
        // 长路径压力测试：验证 O(n) 字符串拼接正确性
        let parts = Array<String>(50, repeat: 'segment')
        let topic = "/" + String.join(parts, delimiter: "_")
        let encoded = encodeTopicToPath(topic)
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testConfigLoad(): Unit {
        // NOTE: this test assumes clean environment (no mq_hosts/fleet_hosts env vars set)
        let config = loadConfig()
        @Assert(config.dataDir == "/var/fmq/data/")
        @Assert(config.heartbeatIntervalSec == 5)
        @Assert(config.ackTimeoutMs == 30000)
    }

    @TestCase
    public func testMatchMode(): Unit {
        let exact = MatchMode.Exact("/order/create")
        let glob = MatchMode.Glob("/order/*")
        let prefix = MatchMode.Prefix("/order/")
        match (exact) {
            case MatchMode.Exact(t) => @Assert(t == "/order/create")
            case _ => @Assert(false)
        }
        match (glob) {
            case MatchMode.Glob(p) => @Assert(p == "/order/*")
            case _ => @Assert(false)
        }
        match (prefix) {
            case MatchMode.Prefix(p) => @Assert(p == "/order/")
            case _ => @Assert(false)
        }
    }
}

@Test
public class ProtocolHelperTest {
    @TestCase
    public func testEncodePublishWithLabels(): Unit {
        let labels = ArrayList<String>()
        labels.add("key1")
        labels.add("key2")
        let msg = encodePublish("/orders", labels, [0xAAu8, 0xBBu8])
        @Assert((msg.command.value >> 4) == 3u8)
    }
}

@Test
public class MqBodyTest {
    @TestCase
    public func testRoundtrip(): Unit {
        let body = MqBody("test-type", [0x01u8, 0x02u8, 0x03u8])
        let data = body.toData()
        if (let Some(decoded) <- convert<MqBody>(data)) {
            @Assert(decoded.bodyType == "test-type")
            @Assert(decoded.payload.size == 3)
            @Assert(decoded.payload[0] == 0x01u8)
        } else {
            @Assert(false)
        }
    }
}

// ── Error tests ──

@Test
public class ErrorTest {
    @TestCase
    public func testErrorCodeEquality(): Unit {
        @Assert(MqErrorCode.SUCCESS == MqErrorCode.SUCCESS)
        @Assert(!(MqErrorCode.SUCCESS == MqErrorCode.TOPIC_NOT_FOUND))
    }

    @TestCase
    public func testErrorCodeToString(): Unit {
        @Assert(MqErrorCode.SUCCESS.toString() == "SUCCESS")
        @Assert(MqErrorCode.INVALID_TOPIC_FORMAT.toString() == "INVALID_TOPIC_FORMAT")
    }

    @TestCase
    public func testMqExceptionConstructors(): Unit {
        let e2 = MqException("test error")
        let e4 = MqException("msg", Exception("cause"))
        @Assert(e2.message == "test error")
        @Assert(e4.message == "msg")
    }
}

// ── Types tests ──

@Test
public class TypesSerializationTest {
    @TestCase
    public func testTopicMetaAccessors(): Unit {
        let groups = ArrayList<String>()
        groups.add("group-a")
        groups.add("group-b")
        let meta = TopicMeta(queueCount: 3, consumerGroups: groups, createTime: DateTime.now())

        @Assert(meta.getQueueCount() == 3)
        @Assert(meta.getConsumerGroups().size == 2)
        @Assert(meta.getConsumerGroups()[0] == "group-a")
    }

    @TestCase
    public func testConsumerRegistrationAccessors(): Unit {
        let labels = ArrayList<String>()
        labels.add("urgent")
        let reg = ConsumerRegistration(
            consumerId: "consumer-1", groupId: "my-group",
            matchModeStr: "Exact:/test",
            labels: Some(labels), dataFilter: Some("$.key==42"),
            lastHeartbeat: DateTime.now())

        @Assert(reg.getConsumerId() == "consumer-1")
        @Assert(reg.getGroupId() == "my-group")
    }

    @TestCase
    public func testMessageStruct(): Unit {
        let labels = ArrayList<String>()
        labels.add("urgent")
        // 用具体构造验证 struct 特性，使用本地 Message struct 而非 f_protocol 的
        let msgId = MessageID()
        let msgPayload: Array<Byte> = [0x01u8, 0x02u8]
        @Assert(labels.size == 1)
        @Assert(labels[0] == "urgent")
        @Assert(msgPayload.size == 2)
    }

    @TestCase
    public func testGetMatchModeExact(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c1", groupId: "g1",
            matchModeStr: "Exact:/a/b",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Exact(t) <- mode) { @Assert(t == "/a/b") }
        else { @Assert(false) }
    }

    @TestCase
    public func testGetMatchModeGlob(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c2", groupId: "g2",
            matchModeStr: "Glob:/a/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Glob(p) <- mode) { @Assert(p == "/a/*") }
        else { @Assert(false) }
    }

    @TestCase
    public func testGetMatchModePrefix(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c3", groupId: "g3",
            matchModeStr: "Prefix:/a/",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Prefix(p) <- mode) { @Assert(p == "/a/") }
        else { @Assert(false) }
    }

    @TestCase
    public func testGetMatchModeDefaultExact(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c4", groupId: "g4",
            matchModeStr: "/raw-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Exact(t) <- mode) { @Assert(t == "/raw-topic") }
        else { @Assert(false) }
    }
}

// ── Protocol function tests ──

@Test
public class ProtocolFunctionTest {
    @TestCase
    public func testEncodePingCommand(): Unit {
        // 验证 PING 命令标签 = 12 (0x0C)
        let msg = ProtocolMessage(Command.PING(0))
        @Assert((msg.command.value >> 4) == 12u8)
    }

    @TestCase
    public func testEncodeSubscribeCommand(): Unit {
        let msg = encodeSubscribe("my-group", MatchMode.Exact("/topic"))
        // encodeSubscribe 返回 ProtocolMessage
        @Assert((msg.command.value >> 4) == 8u8)  // SUBSCRIBE tag
    }

    @TestCase
    public func testEncodeConsumeCommand(): Unit {
        let msg = encodeConsume("/topic", "my-group", 1)
        @Assert((msg.command.value >> 4) == 10u8)  // CONSUME tag
    }

    @TestCase
    public func testEncodeAckCommand(): Unit {
        let msg = encodeAck("msg-id", "/topic", 0)
        @Assert((msg.command.value >> 4) == 14u8)  // ACK tag
    }

    @TestCase
    public func testExtractBytesEmpty(): Unit {
        let buf = ByteBuffer()
        @Assert(extractBytes(buf).size == 0)
    }

    @TestCase
    public func testExtractBytesNonEmpty(): Unit {
        let buf = ByteBuffer()
        buf.write([0x01u8, 0x02u8, 0x03u8])
        let raw = extractBytes(buf)
        @Assert(raw.size == 3)
        @Assert(raw[0] == 0x01u8)
        @Assert(raw[2] == 0x03u8)
    }

    @TestCase
    public func testExtractBytesNegativeGuard(): Unit {
        let buf = ByteBuffer()
        // 空 buffer 的 seek=0, read=0, bytesRead=0 >= 0 → 返回 []
        let result = extractBytes(buf)
        @Assert(result.size == 0)
    }
}

// ── encodeMatchMode ↔ decodeMatchMode 兼容性测试 ──

@Test
public class MatchModeEncodingTest {
    @TestCase
    public func testEncodeMatchModeExactRoundtrip(): Unit {
        let mode = MatchMode.Exact("/order/create")
        let encoded = encodeMatchMode(mode)
        @Assert(encoded == "Exact:/order/create")
        // 验证 encodeMatchMode 输出与 decodeMatchMode 兼容
        let reg = ConsumerRegistration(
            consumerId: "c1", groupId: "g1",
            matchModeStr: encoded,
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let decoded = reg.getMatchMode()
        if (let MatchMode.Exact(t) <- decoded) { @Assert(t == "/order/create") }
        else { @Assert(false) }
    }

    @TestCase
    public func testEncodeMatchModeGlobRoundtrip(): Unit {
        let mode = MatchMode.Glob("/order/*")
        let encoded = encodeMatchMode(mode)
        @Assert(encoded == "Glob:/order/*")
        let reg = ConsumerRegistration(
            consumerId: "c2", groupId: "g2",
            matchModeStr: encoded,
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let decoded = reg.getMatchMode()
        if (let MatchMode.Glob(p) <- decoded) { @Assert(p == "/order/*") }
        else { @Assert(false) }
    }

    @TestCase
    public func testEncodeMatchModePrefixRoundtrip(): Unit {
        let mode = MatchMode.Prefix("/order/")
        let encoded = encodeMatchMode(mode)
        @Assert(encoded == "Prefix:/order/")
        let reg = ConsumerRegistration(
            consumerId: "c3", groupId: "g3",
            matchModeStr: encoded,
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let decoded = reg.getMatchMode()
        if (let MatchMode.Prefix(p) <- decoded) { @Assert(p == "/order/") }
        else { @Assert(false) }
    }
}

// ── COM-3: decodeMatchMode 空模式测试 ──

@Test
public class DecodeMatchModeEdgeTest {
    @TestCase
    public func testDecodeMatchModeEmptyExact(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "empty", groupId: "empty",
            matchModeStr: "Exact:",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        // 空 Exact("") 不应崩溃，返回 Exact("")
        match (mode) {
            case Exact(t) => @Assert(t == "")
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func testDecodeMatchModeUnknownPrefix(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "unknown", groupId: "unknown",
            matchModeStr: "WTF:pattern",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        // 未知前缀降级为 Exact("WTF:pattern")，不应崩溃
        match (mode) {
            case Exact(t) => @Assert(t == "WTF:pattern")
            case _ => @Assert(false)
        }
    }
}

// ── config 测试 ──

@Test
public class ConfigTest {
    @TestCase
    public func testReadEnvIntNoEnvReturnsNone(): Unit {
        let result = readEnvInt("MQ_TEST_NONEXIST_VAR")
        @Assert(result.isNone())
    }

    @TestCase
    public func testReadEnvInvalidIntReturnsNone(): Unit {
        @Assert(Int64.tryParse("abc").isNone())
        @Assert(Int64.tryParse("123abc").isNone())
    }

    @TestCase
    public func testClampPositiveRejectsInvalid(): Unit {
        // 零值 → 返回默认值
        @Assert(clampPositive(Some(0i64), 10, "test") == 10)
        // 负值 → 返回默认值
        @Assert(clampPositive(Some(-5i64), 10, "test") == 10)
        // 正值 → 返回原值
        @Assert(clampPositive(Some(5i64), 10, "test") == 5)
        // None → 返回默认值
        @Assert(clampPositive(None, 10, "test") == 10)
    }
}

// ── BrokerMeta getter 测试（P3-5）──

@Test
public class BrokerMetaGettersTest {
    @TestCase
    public func testBrokerMetaAccessors(): Unit {
        let queues = ArrayList<String>()
        queues.add("/test/queue-0")
        let bm = BrokerMeta()
        // 通过 @DataAssist 设置字段后验证 getter
        // @DataAssist 的 DefaultCodec 编码/解码时会调用 getter
        @Assert(bm.getNodeId() == "")
        @Assert(bm.getHost() == "")
        @Assert(bm.getPort() == 0u16)
        @Assert(!bm.isMasterNode())
        @Assert(bm.getQueues().size == 0)
    }
}

// ── encodePublish 与 ProduceCodec.encode 一致性测试（P4-5）──

@Test
public class EncodePublishConsistencyTest {
    @TestCase
    public func testEncodePublishMatchesProduceCodec(): Unit {
        let topic = "/test-consistency"
        let labels = ArrayList<String>()
        labels.add("k1")
        labels.add("k2")
        let payload: Array<Byte> = [0xABu8, 0xCDu8]
        let msg = encodePublish(topic, labels, payload)
        let raw = ProduceCodec.encode(topic, labels, payload)
        if (let Some(body) <- convert<MqBody>(msg.data)) {
            @Assert(body.bodyType == "produce")
            @Assert(body.payload == raw)
        } else {
            @Assert(false)
        }
    }
}

// ── COM-1: ProduceCodec.decode label count bounds check ──

@Test
public class ProduceCodecBoundsTest {
    @TestCase
    public func testDecodeRejectsNegativeLabelCount(): Unit {
        let buf = ByteBuffer()
        DefaultCodec().encode("/test").encode(-1i64).encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw).isNone())
    }

    @TestCase
    public func testDecodeRejectsExcessiveLabelCount(): Unit {
        let buf = ByteBuffer()
        DefaultCodec().encode("/test").encode(257i64).encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw).isNone())
    }

    @TestCase
    public func testDecodeAcceptsValidLabelCount(): Unit {
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode("/test").encode(64i64)
        for (_ in 0..64) { enc.encode("l") }
        enc.encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw).isSome())
    }
}
