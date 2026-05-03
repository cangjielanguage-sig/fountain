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
package fountain::f_protocol

import std.io.{BufferedInputStream, ByteBuffer}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataAny
import fountain::f_protocol.default.*
import fountain::f_protocol.exception.CommandException

@Test
public class ProtocolTest {
    // ========== Command 枚举 ==========

    @TestCase
    public func commandRoundTripAll(): Unit {
        // 测试所有 12 种命令的 value/parse 往返
        let cases: Array<(Command, String)> = [
            (AUTH(0u8), "AUTH"),
            (AUTH(HASDATA | ACK), "AUTH(HASDATA|ACK)"),
            (SLAVEOF(REG | ACK), "SLAVEOF(REG|ACK)"),
            (SLAVEOF(0u8), "SLAVEOF"),
            (REGISTER, "REGISTER"),
            (PUBLISH(DUP | AT_MOST_ONCE | RETAIN), "PUBLISH(DUP|RETAIN)"),
            (PUBLISH(AT_LEAST_ONCE), "PUBLISH(QoS1)"),
            (PUBLISH(EXACTLY_ONCE), "PUBLISH(QoS2)"),
            (SUBSCRIBE, "SUBSCRIBE"),
            (UNSUBSCRIBE, "UNSUBSCRIBE"),
            (CONSUME(ONCE | AT_LEAST_ONCE), "CONSUME(ONCE|QoS1)"),
            (CONSUME(AT_MOST_ONCE), "CONSUME"),
            (RESP(AT_LEAST_ONCE | ACK), "RESP(ACK)"),
            (PING(WITHNODE | ACK), "PING"),
            (ELECT(VOTE | APPROVE | ASSUME | ACK), "ELECT"),
            (ACK, "ACK"),
            (DEREGISTER, "DEREGISTER")
        ]
        for ((cmd, _) in cases) {
            let encoded = cmd.value
            let decoded = Command.parse(encoded)
            @Assert(decoded == cmd, "roundTrip: ${cmd} (${encoded})")
        }
    }

    @TestCase
    public func commandUnknownThrows(): Unit {
        var threw = false
        try {
            // 高 4 位 = 4 (保留编号)
            Command.parse(0x40u8)
        } catch (_: CommandException) {
            threw = true
        }
        @Assert(threw)
    }

    @TestCase
    public func commandAuthFlags(): Unit {
        // AUTH: HASDATA(bit3) + ACK(bit0)
        let cmd1 = AUTH(HASDATA)
        @Assert((cmd1.value & 0x0Fu8) == HASDATA)
        let cmd2 = AUTH(ACK)
        @Assert((cmd2.value & 0x0Fu8) == ACK)
        let cmd3 = AUTH(HASDATA | ACK)
        @Assert((cmd3.value & 0x0Fu8) == (HASDATA | ACK))
    }

    @TestCase
    public func commandPublishQoS(): Unit {
        // PUBLISH: DUP(bit3), QoS(bit2-1), RETAIN(bit0)
        // 高 4 位 = 3
        @Assert((PUBLISH(AT_MOST_ONCE).value >> 4) == 3u8)
        @Assert((PUBLISH(AT_LEAST_ONCE).value >> 4) == 3u8)
        @Assert((PUBLISH(EXACTLY_ONCE).value >> 4) == 3u8)
        // QoS 在 bits 1-2
        let qos0 = PUBLISH(AT_MOST_ONCE).value
        @Assert((qos0 & 6u8) == 0u8)
        let qos1 = PUBLISH(AT_LEAST_ONCE).value
        @Assert((qos1 & 6u8) == 2u8)
        let qos2 = PUBLISH(EXACTLY_ONCE).value
        @Assert((qos2 & 6u8) == 4u8)
        // RETAIN flag
        @Assert((PUBLISH(RETAIN).value & 1u8) == 1u8)
    }

    // ========== QoS 枚举 ==========

    @TestCase
    public func qosRoundTrip(): Unit {
        let cases: Array<(QoS, Byte)> = [
            (QoS.AtMostOnce, 0u8),
            (QoS.AtLeastOnce, 2u8),
            (QoS.ExactlyOnce, 4u8)
        ]
        for ((qos, expectedValue) in cases) {
            @Assert(qos.value == expectedValue)
            let parsed = QoS.parse(qos.value)
            @Assert(parsed == qos)
        }
    }

    @TestCase
    public func qosFromCommandByte(): Unit {
        // QoS 编码在命令字节的 bits 1-2
        @Assert(QoS.parse(0x00u8) == QoS.AtMostOnce)
        @Assert(QoS.parse(0x02u8) == QoS.AtLeastOnce)
        @Assert(QoS.parse(0x04u8) == QoS.ExactlyOnce)
        @Assert(QoS.parse(0x06u8) == QoS.ExactlyOnce) // 两者都置位 → ExactlyOnce
    }

    // ========== ProcessID ==========

    @TestCase
    public func currentProcessIDReturnsNonZero(): Unit {
        @Assert(CurrentProcessID.instance.value != 0)
    }

    // ========== MessageID ==========

    @TestCase
    public func messageIDUniqueness(): Unit {
        // 连续生成的 ID 应不同
        let id1 = MessageID()
        let id2 = MessageID()
        @Assert(id1 != id2)
        // hash 也应不同
        @Assert(id1.hashCode() != id2.hashCode())
    }

    @TestCase
    public func messageIDEquals(): Unit {
        let id1 = MessageID(pid: 1, tid: 1, time: DateTime.fromUnixTimeStamp(1000))
        let id2 = MessageID(pid: 1, tid: 1, time: DateTime.fromUnixTimeStamp(1000))
        @Assert(id1 == id2)
        @Assert(id1.hashCode() == id2.hashCode())
    }

    // ========== Message 工厂方法 ==========

    @TestCase
    public func messageFactoryAuth(): Unit {
        let encoded = Message.auth(hasData: true, ack: true, authData: DataAny(Int64(42)))
        @Assert(encoded is EncodedMessage)
    }

    @TestCase
    public func messageFactoryPublish(): Unit {
        let encoded = Message.publish(dup: true, qos: QoS.AtLeastOnce, retain: false, data: DataAny("hello"))
        @Assert(encoded is EncodedMessage)
    }

    @TestCase
    public func messageFactoryPing(): Unit {
        let encoded = Message.ping()
        @Assert(encoded is EncodedMessage)
    }

    // ========== Message 编码/解码往返 ==========

    @TestCase
    public func messageEncodeDecodeSimple(): Unit {
        let msg = Message(PUBLISH(AT_MOST_ONCE))
        let encoded = msg.encode()
        @Assert(encoded is EncodedMessage)

        // 编码后 copy 到 ByteBuffer
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)

        // 回读解码
        buf.seek(0)
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command == msg.command)
        @Assert(decoded.id == msg.id)
    }

    @TestCase
    public func messageEncodeDecodeWithData(): Unit {
        let data = DataAny(Int64(12345))
        let msg = Message(REGISTER, data)
        let encoded = msg.encode()

        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)

        buf.seek(0)
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command == msg.command)
        // 解码后数据可转换回 DataAny
        let decodedData = decoded.tryFromData<DataAny>()
        @Assert(decodedData.isSome())
        if (let Some(d) <- decodedData) {
            @Assert(d == data)
        }
    }

    @TestCase
    public func messageEncodeDecodeWithStringData(): Unit {
        let data = DataAny("protocol test message")
        let msg = Message(PUBLISH(AT_MOST_ONCE), data)
        let encoded = msg.encode()

        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)

        buf.seek(0)
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command == msg.command)
        let decodedData = decoded.tryFromData<DataAny>()
        @Assert(decodedData.isSome())
        if (let Some(d) <- decodedData) {
            @Assert(d.getString() == data.getString())
        }
    }

    @TestCase
    public func messageEncodeDecodeAllFactoryMethods(): Unit {
        // 逐一测试各种命令的工厂方法 → 编解码往返
        let testCases: Array<Message> = [
            Message(AUTH(HASDATA | ACK)),
            Message(REGISTER),
            Message(PUBLISH(AT_LEAST_ONCE)),
            Message(SUBSCRIBE),
            Message(UNSUBSCRIBE),
            Message(CONSUME(ONCE)),
            Message(RESP(AT_MOST_ONCE | ACK)),
            Message(PING(WITHNODE | ACK)),
            Message(ELECT(VOTE | APPROVE)),
            Message(ACK),
            Message(DEREGISTER)
        ]
        for (msg in testCases) {
            let encoded = msg.encode()
            let buf = ByteBuffer()
            encoded.copy(to: buf, closeToOnEnd: false)
            buf.seek(0)
            let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
            @Assert(decoded.command == msg.command,
                "cmd roundtrip: ${msg.command} → ${decoded.command}")
        }
    }

    // ========== EncodedMessage ==========

    @TestCase
    public func encodedMessageCopyWritesBytes(): Unit {
        let data = DataAny(Int64(777))
        let msg = Message(AUTH(ACK), data)
        let encoded = msg.encode()

        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)
        // 应至少写入 1 字节命令 + 编码数据
        @Assert(buf.writerPosition > 1)

        // 验证命令字节
        buf.seek(0)
        let cmdByte = Array<Byte>(1, repeat: 0u8)
        let n = buf.read(cmdByte)
        @Assert(n == 1)
        @Assert(cmdByte[0] == AUTH(ACK).value)
    }

    // ========== 边界情况 ==========

    @TestCase
    public func messageTryFromDataReturnsNoneOnMismatch(): Unit {
        // 不带数据的命令 → tryFromData 返回 None
        let msg = Message(PING(WITHNODE))
        let result = msg.tryFromData<DataAny>()
        @Assert(result.isNone())
    }

    @TestCase
    public func messageFactoryPingWithData(): Unit {
        let encoded = Message.ping(data: DataAny(Float64(3.14)))
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)
        buf.seek(0)
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == PING(WITHNODE | ACK).value)
    }

    @TestCase
    public func messageFactoryElectAllFlags(): Unit {
        let encoded = Message.elect(vote: true, approve: true, assume: true, ack: true, data: DataAny("elect-data"))
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)
        buf.seek(0)
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == ELECT(VOTE | APPROVE | ASSUME | ACK).value)
    }
}
