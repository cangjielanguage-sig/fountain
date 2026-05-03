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
package fountain::f_protocol.default

import std.io.{BufferedInputStream, ByteBuffer, SeekPosition}
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ProtocolTest {
    // ========== Command 枚举 ==========

    @TestCase
    public func commandRoundTripAll(): Unit {
        let cases: Array<(Command, String)> = [
            (Command.AUTH(0u8), "AUTH"),
            (Command.AUTH(HASDATA | ACK), "AUTH(HASDATA|ACK)"),
            (Command.SLAVEOF(REG | ACK), "SLAVEOF(REG|ACK)"),
            (Command.SLAVEOF(0u8), "SLAVEOF"),
            (Command.REGISTER, "REGISTER"),
            (Command.PUBLISH(DUP | AT_MOST_ONCE | RETAIN), "PUBLISH(DUP|RETAIN)"),
            (Command.PUBLISH(AT_LEAST_ONCE), "PUBLISH(QoS1)"),
            (Command.PUBLISH(EXACTLY_ONCE), "PUBLISH(QoS2)"),
            (Command.SUBSCRIBE, "SUBSCRIBE"),
            (Command.UNSUBSCRIBE, "UNSUBSCRIBE"),
            (Command.CONSUME(ONCE | AT_LEAST_ONCE), "CONSUME(ONCE|QoS1)"),
            (Command.CONSUME(AT_MOST_ONCE), "CONSUME"),
            (Command.RESP(AT_LEAST_ONCE | ACK), "RESP(ACK)"),
            (Command.PING(WITHNODE | ACK), "PING"),
            (Command.ELECT(VOTE | APPROVE | ASSUME | ACK), "ELECT"),
            (Command.ACK, "ACK"),
            (Command.DEREGISTER, "DEREGISTER")
        ]
        for ((cmd, _) in cases) {
            let v = cmd.value
            let decoded = Command.parse(v)
            @Assert(decoded.value == cmd.value)
        }
    }

    @TestCase
    public func commandUnknownThrows(): Unit {
        var threw = false
        try {
            Command.parse(0x40u8)  // 高 4 位 = 4（保留编号）
        } catch (_: CommandException) {
            threw = true
        }
        @Assert(threw)
    }

    @TestCase
    public func commandAuthFlags(): Unit {
        let cmd1 = Command.AUTH(HASDATA)
        @Assert((cmd1.value & 0x0Fu8) == HASDATA)
        let cmd2 = Command.AUTH(ACK)
        @Assert((cmd2.value & 0x0Fu8) == ACK)
        let cmd3 = Command.AUTH(HASDATA | ACK)
        @Assert((cmd3.value & 0x0Fu8) == (HASDATA | ACK))
    }

    @TestCase
    public func commandPublishQoS(): Unit {
        @Assert((Command.PUBLISH(AT_MOST_ONCE).value >> 4) == 3u8)
        @Assert((Command.PUBLISH(AT_LEAST_ONCE).value >> 4) == 3u8)
        @Assert((Command.PUBLISH(EXACTLY_ONCE).value >> 4) == 3u8)
        // QoS 在 bits 1-2
        let qos0 = Command.PUBLISH(AT_MOST_ONCE).value
        @Assert((qos0 & 6u8) == 0u8)
        let qos1 = Command.PUBLISH(AT_LEAST_ONCE).value
        @Assert((qos1 & 6u8) == 2u8)
        let qos2 = Command.PUBLISH(EXACTLY_ONCE).value
        @Assert((qos2 & 6u8) == 4u8)
        // RETAIN flag
        @Assert((Command.PUBLISH(RETAIN).value & 1u8) == 1u8)
    }

    // ========== QoS 枚举 ==========

    @TestCase
    public func qosValues(): Unit {
        @Assert(QoS.AtMostOnce.value == AT_MOST_ONCE)
        @Assert(QoS.AtLeastOnce.value == AT_LEAST_ONCE)
        @Assert(QoS.ExactlyOnce.value == EXACTLY_ONCE)
    }

    @TestCase
    public func qosFromCommandByte(): Unit {
        @Assert(AT_MOST_ONCE == 0u8)
        @Assert(AT_LEAST_ONCE == 2u8)
        @Assert(EXACTLY_ONCE == 4u8)
    }

    // ========== ProcessID ==========

    @TestCase
    public func currentProcessIDReturnsNonZero(): Unit {
        @Assert(CurrentProcessID.instance.value != 0)
    }

    // ========== MessageID ==========

    @TestCase
    public func messageIDUniqueness(): Unit {
        let id1 = MessageID()
        let id2 = MessageID()
        @Assert(id1 != id2)
        @Assert(id1.hashCode() != id2.hashCode())
    }

    @TestCase
    public func messageIDEquals(): Unit {
        let dur = Duration.second * 1000
        let id1 = MessageID(pid: 1, tid: 1, time: DateTime.fromUnixTimeStamp(dur))
        let id2 = MessageID(pid: 1, tid: 1, time: DateTime.fromUnixTimeStamp(dur))
        @Assert(id1 == id2)
        @Assert(id1.hashCode() == id2.hashCode())
    }

    // ========== Message 工厂方法 ==========

    @TestCase
    public func messageFactoryAuth(): Unit {
        let encoded = Message.auth(hasData: true, ack: true, authData: DataAny(DataReal(42.0)))
        @Assert(encoded is EncodedMessage)
    }

    @TestCase
    public func messageFactoryPublish(): Unit {
        let encoded = Message.publish(dup: true, qos: QoS.AtLeastOnce, retain: false, data: DataAny(DataString("hello")))
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
        let msg = Message(Command.PUBLISH(AT_MOST_ONCE))
        let buf = ByteBuffer()
        msg.encode().copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == msg.command.value)
        @Assert(decoded.id == msg.id)
    }

    @TestCase
    public func messageEncodeDecodeWithData(): Unit {
        let data: Data = DataReal(12345.0)
        let msg = Message(Command.REGISTER, data)
        let buf = ByteBuffer()
        msg.encode().copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == msg.command.value)
        let decodedData = decoded.tryFromData<DataAny>()
        if (let d: DataAny <- decodedData) {
            @Assert(d.data.toString() == data.toString())
        }
    }

    @TestCase
    public func messageEncodeDecodeWithStringData(): Unit {
        let data: Data = DataString("protocol test message")
        let msg = Message(Command.PUBLISH(AT_MOST_ONCE), data)
        let buf = ByteBuffer()
        msg.encode().copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == msg.command.value)
        let decodedData = decoded.tryFromData<DataAny>()
        if (let d: DataAny <- decodedData) {
            @Assert(d.data.toString() == data.toString())
        }
    }

    @TestCase
    public func messageEncodeDecodeAllCommands(): Unit {
        let commands: Array<Command> = [
            Command.AUTH(HASDATA | ACK),
            Command.REGISTER,
            Command.PUBLISH(AT_LEAST_ONCE),
            Command.SUBSCRIBE,
            Command.UNSUBSCRIBE,
            Command.CONSUME(ONCE),
            Command.RESP(AT_MOST_ONCE | ACK),
            Command.PING(WITHNODE | ACK),
            Command.ELECT(VOTE | APPROVE),
            Command.ACK,
            Command.DEREGISTER
        ]
        for (cmd in commands) {
            let msg = Message(cmd)
            let buf = ByteBuffer()
            msg.encode().copy(to: buf, closeToOnEnd: false)
            buf.seek(SeekPosition.Begin(0))
            let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
            @Assert(decoded.command.value == msg.command.value)
        }
    }

    // ========== EncodedMessage ==========

    @TestCase
    public func encodedMessageCopyWritesBytes(): Unit {
        let data: Data = DataReal(777.0)
        let msg = Message(Command.AUTH(ACK), data)
        let buf = ByteBuffer()
        msg.encode().copy(to: buf, closeToOnEnd: false)
        // 验证命令字节
        buf.seek(SeekPosition.Begin(0))
        let cmdByte = Array<Byte>(1, repeat: 0u8)
        let n = buf.read(cmdByte)
        @Assert(n == 1)
        @Assert(cmdByte[0] == Command.AUTH(ACK).value)
    }

    // ========== 边界情况 ==========

    @TestCase
    public func messageTryFromDataOnEmptyMessage(): Unit {
        // 不带数据的命令 → data 字段为 DataNone
        let msg = Message(Command.PING(WITHNODE))
        // PING 使用自动生成的 MessageID 且无业务数据
        @Assert(msg.data is DataNone)
    }

    @TestCase
    public func messageFactoryPingWithData(): Unit {
        let encoded = Message.ping(DataAny(DataReal(3.14)))
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == Command.PING(WITHNODE | ACK).value)
    }

    @TestCase
    public func messageFactoryElectAllFlags(): Unit {
        let encoded = Message.elect(vote: true, approve: true, assume: true, ack: true,
            data: DataAny(DataString("elect-data")))
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == Command.ELECT(VOTE | APPROVE | ASSUME | ACK).value)
    }

    @TestCase
    public func messageRoundTripWithNoneData(): Unit {
        let msg = Message(Command.REGISTER, DataNone.INSTANCE)
        let buf = ByteBuffer()
        msg.encode().copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let decoded = Message.decode<ByteBuffer, DataAny>(BufferedInputStream(buf))
        @Assert(decoded.command.value == msg.command.value)
        @Assert(decoded.id == msg.id)
    }
}
