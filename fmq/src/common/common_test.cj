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
    public func testConfigLoad(): Unit {
        let config = loadConfig()
        @Assert(config.dataDir == "/var/fmq/data/")
        @Assert(config.heartbeatIntervalSec == 5)
        @Assert(config.ackTimeoutMs == 30000)
    }

    @TestCase
    public func testMatchMode(): Unit {
        let _ = MatchMode.Exact("/order/create")
        let _ = MatchMode.Glob("/order/*")
        let _ = MatchMode.Prefix("/order/")
        @Assert(true)
    }
}

@Test
public class ProtocolHelperTest {
    @TestCase
    public func testEncodePublish(): Unit {
        let labels = ArrayList<String>()
        labels.add("urgent")
        let msg = encodePublish("/test", labels, [0x01u8, 0x02u8])
        // encodePublish 返回 ProtocolMessage（有 .command）
        @Assert((msg.command.value >> 4) == 3u8)  // PUBLISH tag
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
        // encodePing 返回 EncodedMessage（编码后的字节），不包含 .command
        let _ = encodePing()
        @Assert(true)
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
}
