/*
Copyright (c) 2025 WuJingrun（吴京润）

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

internal import fountain::f_codec.exception.CodecException
// 帧校验用的是 f_util 的标准 CRC-32（IEEE 802.3）；帧要“边写边算/边读边算”，故用其增量接口
internal import fountain::f_util.{crc32, crc32Init, crc32Update, crc32Finish}

/*
 * f_protocol 因此依赖 f_util。注意加载顺序：应用启动时 f_app 按目录顺序依次 dlopen 各包 .so
 * 且符号即时解析，`f_protocol@fountain` 排在 `f_util@fountain` 之前 —— 顺序不满足时会在加载期
 * 报 `undefined symbol: crc32Update`（已实测）。详见 .autocode/bug.md 的相关记录。
 */

/**
 * 单帧 payload 上限（默认 1GB，可由 `protocol_maxFramePayload` 配置）：防“声称超大长度”拖死对端。
 *
 * 注意：**不能在包初始化期读配置** —— 应用启动时 `f_app` 会逐个加载并初始化各包，
 * 那一刻 `Config` 可能还没就绪，会在 Init Image 阶段抛 NoneValueException，把整包 init 打挂（已实测）。
 * 因此延迟到首次使用时再读一次并缓存。
 */
private var maxFramePayloadCache = None<Int64>
internal func framePayloadLimit(): Int64 {
    match (maxFramePayloadCache) {
        case Some(n) => n
        case None =>
            let n = ProtocolConfig.getMaxFramePayload()
            maxFramePayloadCache = Some(n)
            n
    }
}
/** 帧头：cmd(1B) + len(4B)；帧尾：crc32(4B)。 */
private const FRAME_HEAD_SIZE: Int64 = 5
private const FRAME_CRC_SIZE: Int64 = 4
private const FRAME_OVERHEAD: Int64 = FRAME_HEAD_SIZE + FRAME_CRC_SIZE

/** 大端写 4 字节（取 Int64 低 32 位）。 */
private func putInt32BE(out: Array<Byte>, offset: Int64, value: Int64): Unit {
    out[offset] = UInt8((value >> 24) & 0xff)
    out[offset + 1] = UInt8((value >> 16) & 0xff)
    out[offset + 2] = UInt8((value >> 8) & 0xff)
    out[offset + 3] = UInt8(value & 0xff)
}
/** 大端读 4 字节为无符号值（0..2^32-1）。 */
private func getInt32BE(data: Array<Byte>, offset: Int64): Int64 {
    (Int64(data[offset]) << 24) | (Int64(data[offset + 1]) << 16) |
        (Int64(data[offset + 2]) << 8) | Int64(data[offset + 3])
}
/** 读满 buffer。返回 0 表示“一个字节都没读到”（对端干净关闭）；读到一半就 EOF 视为帧被截断。 */
private func readFully(input: InputStream, buffer: Array<Byte>): Int64 {
    var got = 0i64
    while (got < buffer.size) {
        let tmp = Array<Byte>(buffer.size - got, repeat: 0u8)
        let n = input.read(tmp)
        if (n <= 0) {
            if (got == 0) {
                return 0
            }
            throw CodecException('frame truncated: ${got} of ${buffer.size} bytes read')
        }
        for (i in 0..n) {
            buffer[got + i] = tmp[i]
        }
        got += n
    }
    got
}

/** 透传写出，同时增量累计 CRC32（让 crc 覆盖 cmd+len+payload）。 */
private class Crc32OutputStream <: OutputStream {
    var crc: UInt32
    Crc32OutputStream(crc0: UInt32, private let inner: OutputStream) {
        this.crc = crc0
    }
    public func write(bytes: Array<Byte>): Unit {
        crc = crc32Update(crc, bytes)
        inner.write(bytes)
    }
}

/** 帧体输入流：最多读出 len 字节（物理上读不出帧外）+ 增量 CRC；帧体读尽后表现为 EOF。 */
private class FrameBodyStream <: InputStream {
    var remaining: Int64
    var crc: UInt32
    FrameBodyStream(size: Int64, crc0: UInt32, private let inner: InputStream) {
        this.remaining = size
        this.crc = crc0
    }
    public func read(buffer: Array<Byte>): Int64 {
        var got = 0i64
        while (got < buffer.size && remaining > 0) {
            let left = buffer.size - got
            let want = if (left < remaining) { left } else { remaining }
            let tmp = Array<Byte>(want, repeat: 0u8)
            let n = inner.read(tmp)
            if (n <= 0) {
                // 帧还没读完，对端就没了 ⇒ 截断（不是“干净关闭”）
                throw CodecException('frame truncated: ${remaining} bytes unread')
            }
            for (i in 0..n) {
                buffer[got + i] = tmp[i]
            }
            crc = crc32Update(crc, tmp[0..n])
            got += n
            remaining -= n
        }
        got
    }
}

public struct Message <: Protocol<EncodedMessage, Message> {
    public Message(
        public let command: Command,
        public let id: MessageID,
        public let data: Data
    ) {}
    public init(command: Command, data: Data) {
        this(command, MessageID(), data)
    }
    public init(command: Command){
        this(command, DataNone.INSTANCE)
    }
    public init(command: Command, id: MessageID){
        this(command, id, DataNone.INSTANCE)
    }
    public func tryFromData<T>(): ?T where T <: FromData {
        match(T.tryFromData(data)){
            case x: ?T => x
            case x: T => x
            case _ => throw DataException('data ${data} cannot be converted to ${TypeInfo.of<T>()}')
        }
    }
/*
| **  Control Packet   ** | **Bit 3** | **Bit 2** | **Bit 1** | **Bit 0** |
| ----------------------- | --------- | --------- | --------- | --------- |
| AUTH                    | HASDATA   | 0         | 0         | ACK       |
| SLAVEOF                 | REG       | 0         | 0         | ACK       |
| REGISTER                | 0         | 0         | 0         | ACK       |
| PUBLISH                 | DUP       | QoS1      | Qos0      | RETAIN    |
| SUBSCRIBE               | 0         | 0         | 0         | ACK       |
| UNSUBSCRIBE             | 0         | 0         | 0         | ACK       |
| CONSUME                 | ONCE      | QoS1      | QoS0      | 0         |
| RESP                    | 0         | QoS1      | QoS0      | ACK       |
| PING                    | 0         | 0         | 0         | ACK       |
| ELECT                   | VOTE      | APPROVE   | ASSUME    | ACK       |
| ACK                     | 0         | 0         | 0         | 0         |
| ERROR                   | 0         | 0         | 0         | 0         |
| DEREGISTER              | 0         | 0         | 0         | ACK       |
*/
    private static func toData<T>(data: ?T): Data where T <: ToData {
        match(data){
            case Some(x) => x.toData()
            case _ => DataNone.INSTANCE
        }
    }
    private static func build<T>(command: Command, data: ?T): Message where T <: ToData {
        Message(command, toData<T>(data))
    }
    private static func build(command: Command): Message {
        Message(command)
    }
    private static func build(command: Command, id: MessageID): Message {
        Message(command, id)
    }
    public static func build<T>(command: Command, id: MessageID, data: ?T): Message where T <: ToData {
        Message(command, id, toData<T>(data))
    }
    public static func auth<T>(hasData!: Bool, ack!: Bool, authData!: T): Message  where T <: ToData {
        if (hasData) {
            build<T>(AUTH(HASDATA | to(ack, ACK)), authData)
        } else {
            build(AUTH(to(ack, ACK)))
        }
    }
    public static func slaveof(reg!: Bool, ack!: Bool): Message {
        build(SLAVEOF(to(reg, REG) | to(ack, ACK)))
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterHost!: String, masterPort!: UInt16): Message {
        build<String>(SLAVEOF(to(reg, REG) | to(ack, ACK)), '${masterHost}:${masterPort}')
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterHost!: IPAddress, masterPort!: UInt16): Message {
        slaveof(reg: reg, ack: ack, masterHost: masterHost.toString(), masterPort: masterPort)
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterAddress!: IPSocketAddress): Message {
        slaveof(reg: reg, ack: ack, masterHost: masterAddress.address, masterPort: masterAddress.port)
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterSocket!: TcpSocket): Message {
        slaveof(reg: reg, ack: ack, masterAddress: (masterSocket.remoteAddress as IPSocketAddress).getOrThrow())
    }
    public static func register<T>(data!: T): Message  where T <: ToData {
        build<T>(REGISTER, data)
    }
    public static func publish<T>(dup!: Bool, qos!: QoS, retain!: Bool, data!: T): Message where T <: ToData {
        build<T>(PUBLISH(to(dup, DUP) | qos.value | to(retain, RETAIN)), data)
    }
    public static func subscribe<T>(data!: T): Message where T <: ToData {
        build<T>(SUBSCRIBE, data)
    }
    public static func unsubscribe<T>(id: MessageID, data!: T): Message where T <: ToData {
        build<T>(UNSUBSCRIBE, id, data)
    }
    public static func unsubscribe(id: MessageID): Message {
        build(UNSUBSCRIBE, id)
    }
    
    public static func consume<T>(once!: Bool, qos!: QoS, data!: T): Message where T <: ToData {
        build<T>(CONSUME(to(once, ONCE) | qos.value), data)
    }
    public static func resp<T>(id: MessageID, qos!: QoS, ack!: Bool, data!: T): Message where T <: ToData {
        build<T>(RESP(qos.value | to(ack, ACK)), id, data)
    }
    public static func ping(): Message {
        build(PING(1))
    }
    public static func elect<T>(vote!: Bool, approve!: Bool, assume!: Bool, ack!: Bool, data!: T): Message where T <: ToData {
        build<T>(ELECT(to(vote, VOTE) | to(approve, APPROVE) | to(assume, ASSUME) | to(ack, ACK)), data)
    }
    public static func ack(id: MessageID): Message {
        build(Command.ACK, id)
    }
    public static func ack<T>(id: MessageID, data!: T): Message where T <: ToData {
        build<T>(Command.ACK, id, data)
    }
    public static func error<T>(id: MessageID, data!: T): Message where T <: ToData {
        build<T>(Command.ERROR, id, data)
    }
    public static func error(id: MessageID): Message {
        build(Command.ERROR, id)
    }
    public static func deregister<T>(data!: T): Message where T <: ToData {
        build<T>(DEREGISTER, data)
    }
    private static func to(bool: Bool, byte: Byte): Byte {
        if(bool) { byte } else { 0u8 }
    }
    public func encode(): EncodedMessage {
        let bytes = DefaultCodec().encode(id.time).encode(id.pid).encode(id.tid).encode(id.hostId).encode(data).finish()
        EncodedMessage(command.value, bytes)
    }
    /**
     * 解码一帧：`[cmd(1B)][len(4B 大端 = payload 字节数)][payload][crc32(4B，覆盖 cmd+len+payload)]`。
     *
     * - 帧头一个字节都没读到 = 对端干净关闭（`InputClosedException`，reader 视为连接结束）；
     * - 帧中途 EOF / `len` 与实际不符 / CRC 不符 ⇒ 一律抛，绝不返回“半条消息”；
     * - payload 用限长流解码，**物理上读不出本帧**（即使载荷内部长度字段被写坏）。
     */
    public static func decode<T>(input: InputStream): Message where T <: FromToData {
        let header = Array<Byte>(FRAME_HEAD_SIZE, repeat: 0u8)
        if (readFully(input, header) == 0) {
            throw InputClosedException('no readable byte in InputStream')
        }
        let command = Command.parse(header[0])
        let payloadSize = getInt32BE(header, 1)
        if (payloadSize > framePayloadLimit()) {
            throw CodecException('frame payload size ${payloadSize} exceeds limit ${framePayloadLimit()}')
        }
        // 限长流：解码器最多读到本帧末尾；CRC 从帧头开始累计
        let body = FrameBodyStream(payloadSize, crc32Update(crc32Init(), header), input)
        let decoder = DefaultCodec()
        let time = decoder.decode<DateTime>(body).getOrThrow {IllegalArgumentException()}
        let pid = decoder.decode<Int64>(body).getOrThrow {IllegalArgumentException()}
        let tid = decoder.decode<Int64>(body).getOrThrow {IllegalArgumentException()}
        let hostId = decoder.decode<Int64>(body).getOrThrow {IllegalArgumentException()}
        let data = decoder.decode<T>(body)
        if (body.remaining > 0) {
            // 声明长度比实际载荷长 ⇒ 载荷内部字段边界与帧不一致
            throw CodecException('frame payload not fully consumed: ${body.remaining} of ${payloadSize} bytes left')
        }
        let crcBytes = Array<Byte>(FRAME_CRC_SIZE, repeat: 0u8)
        if (readFully(input, crcBytes) == 0) {
            throw CodecException('frame crc missing')
        }
        let expected = crc32Finish(body.crc)
        let actual = UInt32(getInt32BE(crcBytes, 0))
        if (expected != actual) {
            throw CodecException('frame crc mismatch: expect ${expected}, actual ${actual}')
        }
        build<T>(command, MessageID(time: time, pid: pid, tid: tid, hostId: hostId), data)
    }
}

public struct EncodedMessage <: MessageCopier & Releasable {
    /** 超过该字节数就不做合并（避免为了“一次 write”而把大帧全量缓冲）。 */
    private static let SMALL_MESSAGE_LIMIT = 4096
    EncodedMessage(
        private let command: Byte,
        private let bytes: BytesCopyTo
    ) {}
    /** 释放编码期间占用的池项（幂等）。写出失败时也必须释放，否则池会泄漏。 */
    public func release(): Unit {
        if (let r: Releasable <- bytes) {
            r.release()
        }
    }
    /** 帧的 len 字段：payload 字节数。流式载荷也必须给得出（否则无法成帧）。 */
    private func payloadSize(): Int64 {
        match (bytes.byteSize()) {
            case Some(n) =>
                if (n > framePayloadLimit()) {
                    throw CodecException('frame payload size ${n} exceeds limit ${framePayloadLimit()}')
                }
                n
            case None => throw CodecException('payload size unknown: cannot frame this message')
        }
    }
    /** 小帧：整帧 `[cmd][len][payload][crc]` 一次 write。 */
    private func asOneSmallFrame(): ?Array<Byte> {
        if (let Some(n) <- bytes.byteSize() && n <= SMALL_MESSAGE_LIMIT && let Some(payload) <- bytes.asBytes()) {
            let out = Array<Byte>(FRAME_OVERHEAD + n, repeat: 0u8)
            out[0] = command
            putInt32BE(out, 1, n)
            for (i in 0..payload.size) {
                out[FRAME_HEAD_SIZE + i] = payload[i]
            }
            putInt32BE(out, FRAME_HEAD_SIZE + n, Int64(crc32(out[0..FRAME_HEAD_SIZE + n])))
            out
        } else {
            None<Array<Byte>>
        }
    }
    public func copy(to!: OutputStream, closeToOnEnd!: Bool = false): Unit {
        var ok = false
        try {
            let size = payloadSize()
            if (let Some(frame) <- asOneSmallFrame()) {
                // 小帧：整帧一次 write，写失败也不会在流上留下“半条”
                to.write(frame)
            } else {
                // 大帧：头（含 len）→ 流式载荷（边写边算 CRC）→ 尾 CRC。
                // 对端凭 len 即可判定截断；CRC 覆盖 cmd+len+payload，能发现损坏。
                let header = Array<Byte>(FRAME_HEAD_SIZE, repeat: 0u8)
                header[0] = command
                putInt32BE(header, 1, size)
                // 初值只做 init：header 由 tee.write 累加一次，避免帧头被算两遍
                let tee = Crc32OutputStream(crc32Init(), to)
                tee.write(header)
                bytes.copy(to: tee, closeToOnEnd: false, closeFromOnEnd: false)
                let crcBytes = Array<Byte>(FRAME_CRC_SIZE, repeat: 0u8)
                putInt32BE(crcBytes, 0, Int64(crc32Finish(tee.crc)))
                to.write(crcBytes)
            }
            to.flush()
            ok = true
        } finally {
            // 无论成败都归还池项（原实现只在 bytes.copy 走完时才归还）
            release()
            if (!ok && let r: Resource <- to && !r.isClosed()) {
                // 写失败：帧只剩一半留在流上，必须断链，让对端看到 EOF 而不是半条
                r.close()
            }
        }
        if (closeToOnEnd && let r: Resource <- to && !r.isClosed()) {
            r.close()
        }
    }
}
