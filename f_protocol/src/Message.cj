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
package f_protocol

public struct Message {
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
    public func tryFromData<T>() where T <: DataFields<T> {
        T.tryFromData(data)
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
| ELECT                   | VOTE      | APPROVE   | 0         | ACK       |
| ACK                     | 0         | 0         | 0         | 0         |
| DEREGISTER              | 0         | 0         | 0         | ACK       |
*/
    private static func build<T>(command: Command, data: T): EncodedMessage where T <: DataFields<T> {
        Message(command, data.toData()).encode()
    }
    private static func build(command: Command): EncodedMessage {
        Message(command).encode()
    }
    public static func auth<T>(hasData!: Bool, ack!: Bool, authData!: T): EncodedMessage  where T <: DataFields<T> {
        build<T>(AUTH(to(hasData, HASDATA) | to(ack, ACK)), authData)
    }
    public static func slaveof(reg!: Bool, ack!: Bool): EncodedMessage {
        build(SLAVEOF(to(reg, REG) | to(ack, ACK)))
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterHost!: String, masterPort!: UInt16): EncodedMessage {
        build<String>(SLAVEOF(to(reg, REG) | to(ack, ACK)), '${masterHost}:${masterPort}')
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterHost!: IPAddress, masterPort!: UInt16): EncodedMessage {
        slaveof(reg: reg, ack: ack, masterHost: masterHost.toString(), masterPort: masterPort)
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterAddress!: IPSocketAddress): EncodedMessage {
        slaveof(reg: reg, ack: ack, masterHost: masterAddress.address, masterPort: masterAddress.port)
    }
    public static func slaveof(reg!: Bool, ack!: Bool, masterSocket!: TcpSocket): EncodedMessage {
        slaveof(reg: reg, ack: ack, masterAddress: (masterSocket.remoteAddress as IPSocketAddress).getOrThrow())
    }
    public static func register<T>(data!: T): EncodedMessage  where T <: DataFields<T> {
        build<T>(REGISTER, data)
    }
    public static func publish<T>(dup!: Bool, qos!: QoS, retain!: Bool, data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(PUBLISH(to(dup, DUP) | qos.value | to(retain, RETAIN)), data)
    }
    public static func subscribe<T>(data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(SUBSCRIBE, data)
    }
    public static func unsubscribe<T>(data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(UNSUBSCRIBE, data)
    }
    public static func consume<T>(once!: Bool, qos!: QoS, data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(CONSUME(to(once, ONCE) | qos.value), data)
    }
    public static func resp<T>(qos!: QoS, ack!: Bool, data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(RESP(qos.value | to(ack, ACK)), data)
    }
    public static func ping(): EncodedMessage {
        build(PING(1))
    }
    public static func ping<T>(data: T): EncodedMessage where T <: DataFields<T> {
        build<T>(PING(WITHNODE | ACK), data)
    }
    public static func elect<T>(vote!: Bool, approve!: Bool, ack!: Bool, data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(ELECT(to(vote, VOTE) | to(approve, APPROVE) | to(ack, ACK)), data)
    }
    public static func ack<T>(data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(Command.ACK, data)
    }
    public static func deregister<T>(data!: T): EncodedMessage where T <: DataFields<T> {
        build<T>(DEREGISTER, data)
    }
    private static func to(bool: Bool, byte: Byte){
        if(bool){
            byte
        }else{
            0u8
        }
    }
    public func encode(): EncodedMessage {
        let bytes = DefaultCodec().encode(id.pid).encode(id.tid).encode(id.time).encode(data).finish()
        EncodedMessage(command.value, bytes)
    }
    public static func decode<I, T>(input: BufferedInputStream<I>, closeFromOnEnd!: Bool = false): Message where I <: InputStream, T <: DataFields<T> {
        let b = [0u8]
        let l = input.read(b)
        if (l == 0) {
            throw IllegalArgumentException('no readable byte in InputStream')
        }
        let command = Command.parse(b[0])
        let decoder = DefaultCodec()
        let pid = decoder.decode<Int64>(input).getOrThrow {IllegalArgumentException()}
        let tid = decoder.decode<Int64>(input).getOrThrow {IllegalArgumentException()}
        let time = decoder.decode<DateTime>(input).getOrThrow {IllegalArgumentException()}
        let data = decoder.decode<T>(input)
        Message(command, MessageID(pid: pid, tid: tid, time: time), data.toData())
    }
}

public struct EncodedMessage {
    EncodedMessage(
        private let command: Byte,
        private let bytes: BytesCopyTo
    ) {}
    public func copy(to!: OutputStream, closeToOnEnd!: Bool = false): Unit {
        to.write([command])
        bytes.copy(to: to, closeToOnEnd: closeToOnEnd, closeFromOnEnd: false)
        to.flush()
    }
}
