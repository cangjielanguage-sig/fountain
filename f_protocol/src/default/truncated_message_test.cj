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

import std.io.{BufferedInputStream, ByteBuffer, InputStream, OutputStream, SeekPosition}
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 帧格式 `[cmd(1B)][len(4B 大端)][payload][crc32(4B)]` 的语义测试。
 *
 * 不变式：
 * - 帧头一个字节都没有 ⇒ 对端干净关闭（InputClosedException）；
 * - 帧中途 EOF、`len` 与实际不符、CRC 不符 ⇒ 必须抛，绝不返回“半条/损坏”的消息；
 * - 接收侧能提前知道本帧剩余字节数（len），因此载荷解码读不出帧外。
 */

/** 每次最多返回 step 字节，模拟 TCP 分段/短读。 */
private class DribbleInputStream <: InputStream {
    private var data: Array<Byte>
    private var pos = 0i64
    private let step: Int64
    DribbleInputStream(data: Array<Byte>, step: Int64) {
        this.data = data
        this.step = step
    }
    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= data.size) {
            return 0
        }
        let left = data.size - pos
        let n = if (step < left) { step } else { left }
        let take = if (n < buffer.size) { n } else { buffer.size }
        for (i in 0..take) {
            buffer[i] = data[pos + i]
        }
        pos += take
        take
    }
}
/** 只收集字节（用于把编码结果攒起来再校验）。 */
private class CollectOutputStream <: OutputStream {
    private let list = ArrayList<Byte>()
    public func write(bytes: Array<Byte>): Unit {
        for (b in bytes) {
            list.add(b)
        }
    }
    public func bytes(): Array<Byte> {
        list.toArray()
    }
}

@Test
public class Truncated_message_test {
    // ---------- 工具 ----------

    /** 把一条消息编码成线上字节（完整一帧）。 */
    private func wireOf(message: Message): Array<Byte> {
        let buf = ByteBuffer()
        message.encode().copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let all = Array<Byte>(1 << 20, repeat: 0)
        let n = buf.read(all)
        all[0..n]
    }
    /** 只喂前 keep 个字节，解码是否“抛”。 */
    private func decodeThrows(all: Array<Byte>, keep: Int64): Bool {
        let buf = ByteBuffer()
        buf.write(all[0..keep])
        buf.seek(SeekPosition.Begin(0))
        try {
            Message.decode<DataAny>(BufferedInputStream(buf))
            false
        } catch (_: Exception) {
            true
        }
    }
    /** n 字节的 INPUTSTREAM 载荷。 */
    private func payload(n: Int64): Data {
        DataCollection<Array<Byte>, Byte>(Array<Byte>(n, repeat: 0x41))
    }
    /** data 字段单独编码后的长度。 */
    private func dataFieldSize(data: Data): Int64 {
        DefaultCodec().encode(data).finish().byteSize() ?? -1
    }
    /** 帧头声明的 len。 */
    private func lenOf(frame: Array<Byte>): Int64 {
        (Int64(frame[1]) << 24) | (Int64(frame[2]) << 16) | (Int64(frame[3]) << 8) | Int64(frame[4])
    }
    /** 帧尾的 crc。 */
    private func crcOf(frame: Array<Byte>): UInt32 {
        UInt32((Int64(frame[frame.size - 4]) << 24) | (Int64(frame[frame.size - 3]) << 16) |
            (Int64(frame[frame.size - 2]) << 8) | Int64(frame[frame.size - 1]))
    }
    /** 重新拼一帧：用 declaredLen 覆盖 len，并重算 CRC（使“len 不符”能单独被测）。 */
    private func reframe(frame: Array<Byte>, declaredLen: Int64): Array<Byte> {
        let body = Array<Byte>(frame.size, repeat: 0u8)
        for (i in 0..frame.size) {
            body[i] = frame[i]
        }
        body[1] = UInt8((declaredLen >> 24) & 0xff)
        body[2] = UInt8((declaredLen >> 16) & 0xff)
        body[3] = UInt8((declaredLen >> 8) & 0xff)
        body[4] = UInt8(declaredLen & 0xff)
        let crc = crc32(body[0..body.size - 4])
        body[body.size - 4] = UInt8((Int64(crc) >> 24) & 0xff)
        body[body.size - 3] = UInt8((Int64(crc) >> 16) & 0xff)
        body[body.size - 2] = UInt8((Int64(crc) >> 8) & 0xff)
        body[body.size - 1] = UInt8(Int64(crc) & 0xff)
        body
    }

    // ---------- 帧长自洽：头里的 len 必须等于实际写出的载荷字节数 ----------

    @TestCase
    public func declaredLenMatchesWrittenPayload(): Unit {
        // 服务端响应的真实载荷形状：Array<String>（订阅返回的主机列表）
        let data: Array<String> = ['127.0.0.1:1203,1.000000']
        let frame = wireOf(Message.resp(MessageID(pid: 1, tid: 1, hostId: 0),
            qos: QoS.AtMostOnce, ack: false, data: data))
        @Assert(lenOf(frame) == frame.size - 5 - 4)
        let decoded = Message.decode<Array<String>>(DribbleInputStream(frame, frame.size))
        let got: Array<String> = match (decoded.tryFromData<Array<String>>()) {
            case x: Array<String> => x
            case x: ?Array<String> => x ?? []
            case _ => []
        }
        println('Array<String> 往返: got.size=${got.size}, want=${data.size}, first=${if (got.size > 0) { got[0] } else { '<empty>' }}')
        @Assert(got.size == data.size)
        @Assert(got[0] == data[0])
    }

    @TestCase
    public func declaredLenMatchesNestedPayload(): Unit {
        // 嵌套结构（数组里再套数组）最容易把长度算错：len 偏大 ⇒ 对端会一直等永远不来的剩余字节
        let nested: Array<Array<String>> = [['a', 'bb'], ['ccc']]
        let frame = wireOf(Message(Command.REGISTER, nested.toData()))
        @Assert(lenOf(frame) == frame.size - 5 - 4)
        let decoded = Message.decode<Array<Array<String>>>(DribbleInputStream(frame, frame.size))
        let got: Array<Array<String>> = match (decoded.tryFromData<Array<Array<String>>>()) {
            case x: Array<Array<String>> => x
            case x: ?Array<Array<String>> => x ?? []
            case _ => []
        }
        @Assert(got.size == 2 && got[1].size == 1 && got[1][0] == 'ccc')
    }

    // ---------- 正常路径 ----------

    /** 完整消息必须能正常解出来（防止把修复做成“一律抛”）。 */
    @TestCase
    public func completeMessageStillDecodes(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(decodeThrows(all, all.size) == false)
    }

    /** 帧结构就是 [cmd][len][payload][crc]，且 len/crc 与内容自洽。 */
    @TestCase
    public func frameLayoutIsCmdLenPayloadCrc(): Unit {
        let cmd = Command.REGISTER.value
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(all[0] == cmd)
        @Assert(lenOf(all) == all.size - 9)                       // payload = 总长 - 头 5 - crc 4
        @Assert(crcOf(all) == crc32(all[0..all.size - 4]))        // crc 覆盖 cmd+len+payload
    }

    // ---------- 截断：头 / 体 / 尾 ----------

    /** 帧头只收到 3 字节 ⇒ 必须抛（不是干净关闭）。 */
    @TestCase
    public func truncatedHeaderMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(decodeThrows(all, 3))
    }

    /** 载荷砍掉尾部 300B ⇒ 必须抛（修复前会零填充放行）。 */
    @TestCase
    public func truncatedInlinePayloadMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(decodeThrows(all, all.size - 300))
    }

    /** 载荷 9000B（> fileThreshold，走流式分支）截断 ⇒ 必须抛。 */
    @TestCase
    public func truncatedStreamedPayloadMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(9000)))
        @Assert(decodeThrows(all, all.size - 5000))
    }

    /** 尾 CRC 少 2 字节 ⇒ 必须抛。 */
    @TestCase
    public func truncatedCrcMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(decodeThrows(all, all.size - 2))
    }

    /** EOF 恰好落在 data 字段起始处 ⇒ 必须抛（修复前会静默当成“没有 data”）。 */
    @TestCase
    public func eofAtDataFieldMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(16)))
        let dataSize = dataFieldSize(payload(16))
        @Assert(dataSize > 0)
        @Assert(decodeThrows(all, all.size - dataSize))
    }

    // ---------- 损坏与长度不一致 ----------

    /** 载荷被改动一个字节（CRC 不变）⇒ 必须抛。 */
    @TestCase
    public func crcMismatchMustThrow(): Unit {
        let frame = wireOf(Message(Command.REGISTER, payload(1000)))
        let body = Array<Byte>(frame.size, repeat: 0u8)
        for (i in 0..frame.size) {
            body[i] = frame[i]
        }
        body[100] = body[100] ^ 0x01                              // 污染载荷，CRC 失配
        @Assert(decodeThrows(body, body.size))
    }

    /** len 比实际载荷长 4B（CRC 已按新的 len 重算）⇒ 必须抛（读不到那么长）。 */
    @TestCase
    public func declaredLenLongerMustThrow(): Unit {
        let frame = wireOf(Message(Command.REGISTER, payload(1000)))
        let bad = reframe(frame, lenOf(frame) + 4)
        @Assert(decodeThrows(bad, bad.size))
    }

    /** len 比实际载荷短 4B（CRC 已重算）⇒ 必须抛（头部字段被截在两字节中间）。 */
    @TestCase
    public func declaredLenShorterMustThrow(): Unit {
        let frame = wireOf(Message(Command.REGISTER, payload(1000)))
        let bad = reframe(frame, lenOf(frame) - 4)
        @Assert(decodeThrows(bad, bad.size))
    }

    /** 声称 1MB 但只给了几十字节 ⇒ 立刻抛，而不是按声明长度去分配/阻塞。 */
    @TestCase
    public func overDeclaredLenFailsFast(): Unit {
        let frame = wireOf(Message(Command.REGISTER, payload(16)))
        let bad = reframe(frame, 1024 * 1024)
        @Assert(decodeThrows(bad, bad.size))
    }

    // ---------- 短读 / 短写（模拟 TCP 分段） ----------

    /** 逐字节喂入：帧仍必须被正确解析（限长流 + 读满逻辑不能依赖“一次读全”）。 */
    @TestCase
    public func frameSurvivesDribbledReads(): Unit {
        let frame = wireOf(Message(Command.REGISTER, payload(300)))
        let decoded = Message.decode<DataAny>(DribbleInputStream(frame, 1))
        @Assert(decoded.command.value == Command.REGISTER.value)
    }

    /** 大帧（走“头 + 流式载荷 + 尾 CRC”三次以上 write）编码结果仍必须是合法一帧。 */
    @TestCase
    public func streamedFrameIsSelfConsistent(): Unit {
        let sink = CollectOutputStream()
        Message(Command.REGISTER, payload(9000)).encode().copy(to: sink, closeToOnEnd: false)
        let bytes = sink.bytes()
        @Assert(bytes[0] == Command.REGISTER.value)
        @Assert(lenOf(bytes) == bytes.size - 9)
        @Assert(crcOf(bytes) == crc32(bytes[0..bytes.size - 4]))
        @Assert(decodeThrows(bytes, bytes.size) == false)
    }

    /**
     * 帧 CRC 的类型实证：标准检查值 CRC-32("123456789") = 0xCBF43926
     * （IEEE 802.3 / zlib：反射多项式 0xEDB88320、初值 0xFFFFFFFF、末尾异或 0xFFFFFFFF）。
     */
    @TestCase
    public func frameCrcIsStandardCrc32(): Unit {
        @Assert(crc32('123456789'.unsafeBytes()) == 0xCBF43926u32)
        @Assert(crc32(Array<Byte>()) == 0u32)
    }

    // ---------- 帧内“值级”长度：必须在分配缓冲前挡住超大声明 ----------

    /** 一段 data 字段的线上字节：STRING 头(低4位=长度字段占几字节) + 长度 + 内容。 */
    private func stringField(declared: Int64, content: Array<Byte>): Array<Byte> {
        let out = Array<Byte>(9 + content.size, repeat: 0u8)
        out[0] = DataType.STRING.value | 8u8                    // 长度字段固定 8 字节，便于构造超大声明
        for (i in 0..8) {
            out[1 + i] = UInt8((declared >> (8 * (7 - i))) & 0xff)
        }
        for (i in 0..content.size) {
            out[9 + i] = content[i]
        }
        out
    }

    /** 借合法帧的“消息 id 前缀”，只把 data 字段换成给定的字节，并重算 len/CRC。 */
    private func frameWithDataField(dataField: Array<Byte>): Array<Byte> {
        let legit = wireOf(Message(Command.REGISTER, 'AB'.toData()))
        let dataSize = dataFieldSize('AB'.toData())
        @Assert(dataSize > 0)
        let prefix = legit[5..legit.size - 4 - dataSize]         // id 字段部分（帧头 5B、CRC 4B）
        let payload = Array<Byte>(prefix.size + dataField.size, repeat: 0u8)
        for (i in 0..prefix.size) {
            payload[i] = prefix[i]
        }
        for (i in 0..dataField.size) {
            payload[prefix.size + i] = dataField[i]
        }
        let frame = Array<Byte>(5 + payload.size + 4, repeat: 0u8)
        frame[0] = Command.REGISTER.value
        for (i in 0..4) {
            frame[1 + i] = UInt8((payload.size >> (8 * (3 - i))) & 0xff)
        }
        for (i in 0..payload.size) {
            frame[5 + i] = payload[i]
        }
        let crc = crc32(frame[0..5 + payload.size])               // crc 覆盖 cmd+len+payload
        for (i in 0..4) {
            frame[5 + payload.size + i] = UInt8((Int64(crc) >> (8 * (3 - i))) & 0xff)
        }
        frame
    }

    /** 自检：换成“声明长度正确”的 data 字段后仍能解出 AB —— 证明上面的拼接方式没问题。 */
    @TestCase
    public func splicedDataFieldStillDecodes(): Unit {
        let frame = frameWithDataField(stringField(2, 'AB'.unsafeBytes()))
        let decoded = Message.decode<DataAny>(DribbleInputStream(frame, frame.size))
        match (decoded.data) {
            case x: DataString => @Assert(x.data == 'AB')
            case _ => @Assert(false)
        }
    }

    /**
     * 载荷内部的“值级”长度声明超过本帧剩余字节 ⇒ 必须在**分配缓冲前**拒绝。
     * 修复前：这里会直接按 1TB 去 `Array<Byte>(size)`，结果是 OOM / 分配失败，而不是可诊断的 CodecException。
     */
    @TestCase
    public func oversizedValueLengthIsRejectedBeforeAllocating(): Unit {
        let declared = 1i64 << 40                                 // 1TB
        let frame = frameWithDataField(stringField(declared, 'AB'.unsafeBytes()))
        let buf = ByteBuffer()
        buf.write(frame)
        buf.seek(SeekPosition.Begin(0))
        try {
            Message.decode<DataAny>(BufferedInputStream(buf))
            @Assert(false)                                        // 必须抛
        } catch (e: CodecException) {
            @Assert(e.message.contains('left in frame'))           // 且必须是“超预算”这一条，而不是分配失败
        } catch (_: Exception) {
            @Assert(false)
        }
    }
}
