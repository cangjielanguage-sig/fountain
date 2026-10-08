# 应用协议

`fountain::f_protocol` 是**应用通讯协议**的 API 模块：实现它的接口即可定义自己的通讯协议；
本模块同时提供一套默认实现（帧编解码 + `Message` 工厂 + `MessageID`），`fountain::f_net` 直接使用它。

## 接口

```cj
/**
 * EN 是编码结果，DE 是解码结果
 */
public interface Protocol<EN, DE> where EN <: MessageCopier {
    /**
     * 编码：把当前消息编码为可写出的 EN
     */
    func encode(): EN
    /**
     * 解码：从输入流读出一帧
     * @param input 输入流
     * @param T     期望的载荷类型（FromToData；DataFields<T> 是它的子接口）
     */
    static func decode<T>(input: InputStream): DE where T <: FromToData
}

public interface MessageCopier {
    /**
     * 将数据复制到参数 to 引用的 OutputStream
     * @param closeToOnEnd 复制完成后是否关闭输出流
     */
    func copy(to!: OutputStream, closeToOnEnd!: Bool): Unit
}
```

`T` 只影响载荷怎么解释：默认实现里 `Message.decode<T>` 会按 `T` 转换载荷，有 `DataFields<T>` 时走字段映射，
`DataAny` 则是「按帧头自带的类型解码」的中性选择（`f_rpc` / `f_net` 的读取循环用这一档）。

## 默认实现

### 包名

`fountain::f_protocol.default`

### 线上帧格式

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| `version` | 1B | 固定 `1`；其它值抛 `CodecException` |
| `command` | 1B | 高 4 位 = `Command` 序号，低 4 位 = 标志位（见下表） |
| `len` | 4B | payload 字节数（大端）；受 `protocol_maxFramePayload`（默认 1GB）限制，收发两侧都校验 |
| `payload` | `len` B | 布局见下 |
| `crc32` | 4B | 覆盖 `version + command + len + payload` |

**payload 布局（`Message.encode()` 的写出顺序即协议）**：`time(DateTime)` → `pid` → `tid` → `hostId` → `data`。
无载荷消息用 `DataNone.INSTANCE`。

解码异常语义：

- 首字节就读不到（对端干净关闭）⇒ `InputClosedException`；
- 版本不符、载荷没读尽、CRC 不符、中途 EOF ⇒ `CodecException`。

> CRC 实现来自 `f_util`，动态库加载顺序必须 **f_util 先于 f_protocol**，否则报 `undefined symbol: crc32Update`。

### 标志位常量

```cj
/* Bit 3 / Bit 2 / Bit 1 / Bit 0 的含义按命令不同，见下 */
public const HASDATA = 8u8   // AUTH:     bit3
public const REG     = 8u8   // SLAVEOF:  bit3
public const DUP     = 8u8   // PUBLISH:  bit3
public const ONCE    = 8u8   // CONSUME:  bit3
public const VOTE    = 8u8   // ELECT:    bit3
public const WITHNODE= 8u8   // 预留（当前 ping() 不置位）
public const EXACTLY_ONCE = 4u8
public const APPROVE      = 4u8
public const AT_LEAST_ONCE= 2u8
public const ASSUME       = 2u8
public const RETAIN       = 1u8
public const ACK          = 1u8
public const AT_MOST_ONCE = 0u8
```

| 命令 | Bit 3 | Bit 2 | Bit 1 | Bit 0 |
| --- | --- | --- | --- | --- |
| AUTH | HASDATA | 0 | 0 | ACK |
| SLAVEOF | REG | 0 | 0 | ACK |
| REGISTER | 0 | 0 | 0 | ACK（固定 1） |
| PUBLISH | DUP | QoS1 | QoS0 | RETAIN |
| DLQ_LIST / DLQ_REDELIVER / DLQ_REDELIVER_ALL / ERROR | 0 | 0 | 0 | ACK（固定 1） |
| SUBSCRIBE / UNSUBSCRIBE | 0 | 0 | 0 | ACK（固定 1） |
| CONSUME | ONCE | QoS1 | QoS0 | 0 |
| RESP | 0 | QoS1 | QoS0 | ACK |
| PING | 0（`ping()` 固定发 `PING(1)`，不置 bit3） | 0 | 0 | ACK |
| ELECT | VOTE | APPROVE | ASSUME | ACK |
| ACK | 0 | 0 | 0 | 0 |
| DEREGISTER | 0 | 0 | 0 | ACK（固定 1） |

### 枚举

```cj
public enum QoS <: Equatable<QoS> & ToString {
    | AtMostOnce    // 0
    | AtLeastOnce   // 2
    | ExactlyOnce   // 4
    public prop value: Byte
    /** 按掩码 AT_MOST_ONCE|AT_LEAST_ONCE|EXACTLY_ONCE 取值，非法位抛 CommandException */
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
    public prop value: Byte          // 高 4 位命令号 | 低 4 位标志位
    public static func parse(value: Byte): Command   // 未知命令号抛 CommandException
}
```

### 消息定义

```cj
public struct Message <: Protocol<EncodedMessage, Message> {
    public Message(public let command: Command, public let id: MessageID, public let data: Data)
    public init(command: Command, data: Data)
    public init(command: Command)                 // 无载荷
    public init(command: Command, id: MessageID)  // 无载荷 + 指定 id

    /** 载荷转换：转不了抛 DataException */
    public func tryFromData<T>(): ?T where T <: FromData
    /** 通用构造 */
    public static func build<T>(command: Command, id: MessageID, data: ?T): Message where T <: ToData
    public func encode(): EncodedMessage

    /* 工厂：全部返回 Message（EncodedMessage 只由 encode() 产出），需要回包的都带 id 参数 */
    public static func auth<T>(hasData!: Bool, ack!: Bool, authData!: T): Message where T <: ToData
    public static func slaveof(reg!: Bool, ack!: Bool, ...): Message          // 另有 host+port / IPAddress / IPSocketAddress / TcpSocket 重载
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
    /** 释放编码期间占用的池项（幂等）；写出失败时也必须释放，否则池会泄漏 */
    public func release(): Unit
    /** closeToOnEnd 默认 false */
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

- `MessageID` 的相等/哈希**只用 `time`/`pid`/`tid`**（`hostId` 不参与）；
- `EncodedMessage` 实现了 `Releasable`：**写出后必须 `release()`**（幂等），写失败也要释放；
- `Message.decode<T>` 在解码前会按帧头的 `len` 与 `SizeBoundedInput.remainingBytes` 校验，避免「声称超大长度」拖死对端。

### 配置项

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `protocol_hostId` | `0` | 主机 ID，整个集群内每台主机唯一（写进 `MessageID`） |
| `protocol_maxFramePayload` | `1 << 30`（1GB） | 单帧 payload 上限，收发两侧都校验 |

配置在**首次使用时**才读取并缓存（不能在包初始化期读：那时 `Config` 可能还没就绪）。

## 相关文档

原 `doc/接口.md`、`doc/默认实现.md` 的旧摘录已删除 —— **本 README 与 `src/**` 是唯一出处**。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`CommandException`（class）、`CurrentProcessID`（struct）、`public func read(buffer: Array<Byte>): Int64`、`public func write(bytes: Array<Byte>): Unit`
