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
        public let data: Array<DataAny>
    ) {}
    public init(command: Command, data: Array<DataAny>) {
        this(command, MessageID(), data)
    }
    public static func builder(command: Command) {
        MessageBuilder(command)
    }
    public func encode(): EncodedMessage {
        let encoder = DefaultCodec()
        encoder.encode(id.pid).encode(id.tid).encode(id.time).encode(data)
        EncodedMessage(command.value, encoder.finish())
    }
    public static func decode<T>(input: BufferedInputStream<T>, closeFromOnEnd!: Bool = false): Message where T <: InputStream {
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
        let data = decoder.decode<Array<DataAny>>(input).getOrThrow {IllegalArgumentException()}
        Message(command, MessageID(pid: pid, tid: tid, time: time), data)
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

public struct MessageBuilder {
    private let data = ArrayList<DataAny>()
    public MessageBuilder(private let command: Command) {}
    public func add<T>(data: T): MessageBuilder where T <: DataFields<T> {
        this.data.add(match (data) {
            case x: DataAny => x
            case _ => match (data.toData()) {
                case x: DataAny => x
                case x => DataAny(x)
            }
        })
        this
    }
    public func build(): Message {
        Message(command, data.unsafeData())
    }
}
