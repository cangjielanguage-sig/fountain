# Application protocol

`fountain::f_protocol` is the API module of the **application communication protocol**: implement its interfaces to define your own
communication protocol. This module also provides a default implementation (frame encoding/decoding + `Message` factories + `MessageID`),
which `fountain::f_net` uses directly.

## Interfaces

```cj
/**
 * EN is the encoding result, DE is the decoding result
 */
public interface Protocol<EN, DE> where EN <: MessageCopier {
    /**
     * Encode: encode the current message into a writable EN
     */
    func encode(): EN
    /**
     * Decode: read one frame from the input stream
     * @param input Input stream
     * @param T     Expected payload type (FromToData; DataFields<T> is a sub-interface of it)
     */
    static func decode<T>(input: InputStream): DE where T <: FromToData
}

public interface MessageCopier {
    /**
     * Copy the data to the OutputStream referenced by the argument to
     * @param closeToOnEnd Whether to close the output stream after copying
     */
    func copy(to!: OutputStream, closeToOnEnd!: Bool): Unit
}
```

`T` only affects how the payload is interpreted: in the default implementation `Message.decode<T>` converts the payload according to `T`;
with `DataFields<T>` it goes through field mapping, while `DataAny` is the neutral choice of "decode by the type carried in the frame head"
(used by the read loops of `f_rpc` / `f_net`).

## Default implementation

### Package name

`fountain::f_protocol.default`

### On-the-wire frame format

| Field | Length | Description |
| --- | --- | --- |
| `version` | 1B | Fixed `1`; any other value throws `CodecException` |
| `command` | 1B | High 4 bits = `Command` ordinal, low 4 bits = flag bits (see the table below) |
| `len` | 4B | Number of payload bytes (big endian); bounded by `protocol_maxFramePayload` (1GB by default) and validated on both the sending and receiving sides |
| `payload` | `len` B | Layout see below |
| `crc32` | 4B | Covers `version + command + len + payload` |

**payload layout (the write order of `Message.encode()` is the protocol)**: `time(DateTime)` → `pid` → `tid` → `hostId` → `data`.
Messages without a payload use `DataNone.INSTANCE`.

Decoding exception semantics:

- The first byte cannot be read at all (the peer closed cleanly) ⇒ `InputClosedException`;
- Version mismatch, payload not fully read, CRC mismatch, or EOF in the middle ⇒ `CodecException`.

> The CRC implementation comes from `f_util`, so the dynamic library loading order must be **f_util before f_protocol**, otherwise you get `undefined symbol: crc32Update`.

### Flag constants

```cj
/* The meaning of Bit 3 / Bit 2 / Bit 1 / Bit 0 depends on the command, see below */
public const HASDATA = 8u8   // AUTH:     bit3
public const REG     = 8u8   // SLAVEOF:  bit3
public const DUP     = 8u8   // PUBLISH:  bit3
public const ONCE    = 8u8   // CONSUME:  bit3
public const VOTE    = 8u8   // ELECT:    bit3
public const WITHNODE= 8u8   // Reserved (ping() does not set it at present)
public const EXACTLY_ONCE = 4u8
public const APPROVE      = 4u8
public const AT_LEAST_ONCE= 2u8
public const ASSUME       = 2u8
public const RETAIN       = 1u8
public const ACK          = 1u8
public const AT_MOST_ONCE = 0u8
```

| Command | Bit 3 | Bit 2 | Bit 1 | Bit 0 |
| --- | --- | --- | --- | --- |
| AUTH | HASDATA | 0 | 0 | ACK |
| SLAVEOF | REG | 0 | 0 | ACK |
| REGISTER | 0 | 0 | 0 | ACK (always 1) |
| PUBLISH | DUP | QoS1 | QoS0 | RETAIN |
| DLQ_LIST / DLQ_REDELIVER / DLQ_REDELIVER_ALL / ERROR | 0 | 0 | 0 | ACK (always 1) |
| SUBSCRIBE / UNSUBSCRIBE | 0 | 0 | 0 | ACK (always 1) |
| CONSUME | ONCE | QoS1 | QoS0 | 0 |
| RESP | 0 | QoS1 | QoS0 | ACK |
| PING | 0 (`ping()` always sends `PING(1)` and does not set bit3) | 0 | 0 | ACK |
| ELECT | VOTE | APPROVE | ASSUME | ACK |
| ACK | 0 | 0 | 0 | 0 |
| DEREGISTER | 0 | 0 | 0 | ACK (always 1) |

### Enums

```cj
public enum QoS <: Equatable<QoS> & ToString {
    | AtMostOnce    // 0
    | AtLeastOnce   // 2
    | ExactlyOnce   // 4
    public prop value: Byte
    /** Decoded with the mask AT_MOST_ONCE|AT_LEAST_ONCE|EXACTLY_ONCE; illegal bits throw CommandException */
    public static func parse(value: Byte): QoS
}

public enum Command <: Hashable & Equatable<Command> & ToString {
    | AUTH(Byte)        // 0
    | SLAVEOF(Byte)     // 1
    | REGISTER          // 2
    | PUBLISH(Byte)     // 3
    | DLQ_LIST          // 4
    | DLQ_REDELIVER     // 5
    | DLQ_REDELIVER_ALL // 6
    | ERROR             // 7
    | SUBSCRIBE         // 8
    | UNSUBSCRIBE       // 9
    | CONSUME(Byte)     // 10
    | RESP(Byte)        // 11
    | PING(Byte)        // 12
    | ELECT(Byte)       // 13
    | ACK               // 14
    | DEREGISTER        // 15
    public prop value: Byte          // High 4 bits command number | low 4 bits flag bits
    public static func parse(value: Byte): Command   // An unknown command number throws CommandException
}
```

### Message definition

```cj
public struct Message <: Protocol<EncodedMessage, Message> {
    public Message(public let command: Command, public let id: MessageID, public let data: Data)
    public init(command: Command, data: Data)
    public init(command: Command)                 // No payload
    public init(command: Command, id: MessageID)  // No payload + given id

    /** Payload conversion: throws DataException when it cannot be converted */
    public func tryFromData<T>(): ?T where T <: FromData
    /** Generic construction */
    public static func build<T>(command: Command, id: MessageID, data: ?T): Message where T <: ToData
    public func encode(): EncodedMessage

    /* Factories: all return Message (EncodedMessage is produced only by encode()); the ones that need a reply carry an id argument */
    public static func auth<T>(hasData!: Bool, ack!: Bool, authData!: T): Message where T <: ToData
    public static func slaveof(reg!: Bool, ack!: Bool, ...): Message          // Also host+port / IPAddress / IPSocketAddress / TcpSocket overloads
    public static func register<T>(data!: T): Message where T <: ToData
    public static func publish<T>(dup!: Bool, qos!: QoS, retain!: Bool, data!: T): Message where T <: ToData
    public static func subscribe<T>(data!: T): Message where T <: ToData
    public static func unsubscribe(id: MessageID, data!: T): Message where T <: ToData
    public static func unsubscribe(id: MessageID): Message
    public static func consume<T>(once!: Bool, qos!: QoS, data!: T): Message where T <: ToData
    public static func resp<T>(id: MessageID, qos!: QoS, ack!: Bool, data!: T): Message where T <: ToData
    public static func ping(): Message
    public static func elect<T>(vote!: Bool, approve!: Bool, assume!: Bool, ack!: Bool, data!: T): Message where T <: ToData
    public static func ack(id: MessageID): Message
    public static func ack<T>(id: MessageID, data!: T): Message where T <: ToData
    public static func error(id: MessageID): Message
    public static func error<T>(id: MessageID, data!: T): Message where T <: ToData
    public static func deregister<T>(data!: T): Message where T <: ToData
}

public struct EncodedMessage <: MessageCopier & Releasable {
    /** Release the pool items held during encoding (idempotent); it must also be released when writing fails, otherwise the pool leaks */
    public func release(): Unit
    /** closeToOnEnd defaults to false */
    public func copy(to!: OutputStream, closeToOnEnd!: Bool = false): Unit
}

public class MessageID <: Hashable & Equatable<MessageID> & ToString {
    public static let pidgen: ProcessID = CurrentProcessID.instance
    public MessageID(
        public let time!: DateTime = DateTime.now(),
        public let pid!: Int64 = pidgen.value,
        public let tid!: Int64 = Thread.currentThread.id,
        public let hostId!: Int64 = ProtocolConfig.getProtocolHostId()
    )
    public func hashCode(): Int64
    public operator func ==(other: MessageID): Bool
    public func toString(): String
}
```

- The equality/hash of `MessageID` **uses only `time`/`pid`/`tid`** (`hostId` does not participate);
- `EncodedMessage` implements `Releasable`: **`release()` must be called after writing it out** (idempotent), and also when writing fails;
- `Message.decode<T>` validates against the `len` in the frame head and `SizeBoundedInput.remainingBytes` before decoding, so that a peer "claiming an oversized length" cannot hang the other side.

### Configuration items

| Configuration | Default | Description |
| --- | --- | --- |
| `protocol_hostId` | `0` | Host ID, unique for each host within the whole cluster (written into `MessageID`) |
| `protocol_maxFramePayload` | `1 << 30` (1GB) | Upper bound of the payload of a single frame; validated on both the sending and receiving sides |

The configuration is read and cached **only on first use** (it must not be read during package initialization: `Config` may not be ready then).

## Related documents

The old excerpts in `doc/接口.md` and `doc/默认实现.md` have been deleted —— **this README and `src/**` are the only source**.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `CommandException` (class), `CurrentProcessID` (struct), `public func read(buffer: Array<Byte>): Int64`, `public func write(bytes: Array<Byte>): Unit`
