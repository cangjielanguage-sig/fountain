# fountain实现思想与应用第十弹

##### ——编解码器与应用通讯协议

项目链接：https://gitcode.com/Cangjie-TPC/fountain

**fountain 的通讯栈只做三件事——把对象压成字节、把字节装进帧、把帧送上连接。** 这三件事分别由 `f_codec`、`f_protocol`、`f_net` 负责，三层之间靠两个极小的接口咬合，任何一层都可以单独换掉。

这套分层解决的是一个具体问题：大多数框架把「序列化 / 协议 / 网络」放在一层，换个序列化格式要改协议，改协议要动网络层。fountain 把它们切成三层，每层只回答一个问题：

```
   业务对象                  字节                    帧                   连接
  ┌─────────┐   encode   ┌──────────┐  Message  ┌────────────┐  transfer  ┌────────┐
  │ Data /  │ ─────────► │ head+body│ ────────► │ ver cmd len│ ─────────► │ socket │
  │ T       │ ◄───────── │          │ ◄──────── │ payload crc│ ◄───────── │        │
  └─────────┘   decode   └──────────┘           └────────────┘            └────────┘
```

下面按这三层拆开讲，重点不是 API 列表，而是**每个设计决策放弃了什么**。

---

## 第一层：`f_codec`——一个字节的预算

### 用 1 个字节同时表达「类型」和「长度」

所有编解码器都要回答两个问题：这段字节是什么类型？它有多长？常见做法是分开写两个字段，或者干脆省掉类型、靠 schema 约束。fountain 的做法是把答案塞进同一个字节：

```
   head 字节
   ┌───────┬───────┐
   │ 高 4 位│ 低 4 位│
   │ 类型号 │ 长度   │
   └───────┴───────┘
```

高 4 位正好放得下 16 种类型：

| 值 | 类型 | 值 | 类型 |
| --- | --- | --- | --- |
| 0 | `NONE` | 8 | `DURATION1` |
| 1 | `STRING` | 9 | `DURATION2` |
| 2 | `BOOL` | 10 | `DATETIME1` |
| 3 | `INT` | 11 | `DATETIME2` |
| 4 | `FLOAT` | 12 | `COLLECTION` |
| 5 | `BIGINT` | 13 | `MAP` |
| 6 | `DECIMAL1` | 14 | `OBJECT` |
| 7 | `DECIMAL2` | 15 | `INPUTSTREAM` |

**收益**：字节流是自描述的。解码方不需要事先知道「下一个值是 Int64 还是 String」，也不需要外部 schema 或 IDL 注册中心。对于 RPC 这种「方法参数按声明顺序排列」的场景，协议实现只有四步：读 head、读长度、读 body、按类型构造值，然后循环。

**代价**：长度只有 4 位。所以低 4 位不能直接表示长度，只能表示「后面还有几个字节用来表示长度」。

### 低 4 位：长度、符号、空值，三种信息挤在一起

这里的规则不统一，是刻意的取舍：

| 类型族 | 低 4 位含义 |
| --- | --- |
| `INT` / `FLOAT` | **bit3 = 符号位**（0 正、1 负），**bit0..2 = body 字节数**（1..7）；长度位为 `0` 表示 8 字节 |
| `INPUTSTREAM` / `BIGINT` / `DECIMAL*` / `DURATION*` / `DATETIME*` | body 字节数（1..7）；`0` 表示 8 字节 |
| `STRING` / `COLLECTION` / `MAP` | 长度**字节数**（1..8，按实际长度取最小值）；`0` 表示「空值，后面不跟长度字节」 |

第一行是文档里容易漏掉的一层：**符号位是借来的**。`Int64(1)` 的 head 低半字节是 `1`，`Int64(-1)` 则是 `9`（`1 | 0b1000`）——符号不额外占字节，而是塞进了原本要表示长度的 4 位里。解码侧对应地取 `sign = (head & 0x08) == 0`，还会校验「符号位与实际值是否矛盾」，矛盾就抛 `CodecException`。

数值类型走「实际字节数」，是因为小整数太常见——`Int64(1)` 只写 2 个字节（head + 1 字节 body），而不是固定 9 字节。这是典型的「为高频小对象省带宽」。

字符串和容器则按需要写 1..8 个长度字节（长度 ≤ 255 时只花 1 字节），把「长度值」本身当成变长整数编码；而空值单独占一个 `head`，则是为了给最常见的 `''`、空集合、空 map 一类情况留一条极短的路径：

```cj
// 空字符串：只有 head，低半字节 0，没有长度字节
// 空集合/空映射：只有 COLLECTION.value / MAP.value 一个字节
```

这两条空值分支必须在解码侧也成对出现。漏掉的话，解码器会去读一个不存在的长度字节——在 `parseInt64` 里就是索引长度为 0 的数组越界。这也是这个设计唯一的「隐式契约」：**编码侧的空值短路，解码侧必须显式认领**。

另外，`FLOAT` 禁止 NaN / ±Inf，编码时直接抛 `CodecException`。浮点的特殊值在跨语言通讯里几乎没有共识，与其各自解释，不如在入口拒绝。

### 接口：编码器是链式的，解码器是泛型的

```cj
public interface Encoder {
    func encode(data: Data): Encoder
    func encode(data: DataAny): Encoder
    func encode<T>(data: T): Encoder where T <: DataFields<T>
    func encodeNone(): Encoder
    func encode(value: Bool): Encoder
    func encode(value: String): Encoder
    func encode(value: Int64): Encoder        // Int8/16/32、UInt8..UInt64 同理
    func encode(value: Float64): Encoder      // Float16/32 同理
    func encode(value: BigInt): Encoder
    func encode(value: Decimal): Encoder
    func encode(value: Duration): Encoder
    func encode(value: DateTime): Encoder
    func encode(value: Array<Byte>): Encoder
    func encode(data: InputStream, size: Int64): Encoder
    func encode(data: File): Encoder
    func finish(): BytesCopyTo
}

public interface Decoder {
    /** T 是期望的载荷类型（FromToData；DataFields<T> 是它的子接口） */
    func decode<T>(input: InputStream): ?T where T <: FromToData
}

public interface Codec <: Encoder & Decoder {}
```

接口有两处设计细节：

1. **`Encoder` 返回自身**，所以可以一路 `.encode(a).encode(b).encode(c)` 写成一帧。编码顺序就是协议顺序，没有字段名、没有分隔符。
2. **`decode<T>` 的 `T` 只是「期望类型」**，不是「唯一类型」。同一个字节流，按 `Int64` 解出来是整数，按 `DataAny` 解出来是一个 `Data` 对象——后者叫中性解码，RPC 和 `f_net` 的读取循环用的就是这一档，因为它们在读的那一刻还不知道载荷该是什么类型。

### 三个防御性设计

编解码器是「不可信输入」进入系统的第一道门，fountain 在这里放了三道闸。

**一、`SizeBoundedInput`：拦住「声明长度 = 1TB」**

```cj
public interface SizeBoundedInput <: InputStream {
    /** 本帧剩余可读字节数（不得为负） */
    prop remainingBytes: Int64
}
```

帧头里的 `len` 能限住「可读字节数」，但限不住 `Array<Byte>(声明长度)` 这一步分配——载荷里一个损坏的长度字段，就足以让解码器尝试 TB 级分配，进程当场被 OOM 干掉。所以解码器在**按线上长度分配缓冲之前**，先问输入流「本帧还剩多少字节」。实现这个接口的是 `f_protocol` 的帧体流。

**二、对象类型登记**

`OBJECT` 类型线上只传一个哈希，不传类名。解码方必须能把这个哈希映射回类型，所以 `DefaultCodec` 维护一张注册表，键是 `murmurHash(限定名)`：

```cj
DefaultCodec.registerType<T>()                                  // 静态满足约束时
DefaultCodec.registerType(qualifiedName: String, creator: () -> SimpleDataObject)  // 宏展开走这条
```

`@DataAssist` 修饰的类型会自登记，`@RPCStub` / `@RPCSkeleton` 展开时也会把接口的参数/返回类型登记进去。所以业务代码通常不需要手写这行；但**跨模块解码对象类型前必须登记**，否则解码时抛 `CodecException`——这是「按名字找类」的必然成本，换来的是线上不必传类名。

**三、大载荷落盘**

payload 超过 `fileThreshold`（默认 4096，随 `setBytesPool(arraySize:)` 变化）时，编码器把它写进 `/tmp/tmpFile<UUID>`，帧里只带文件名。这样大对象不会全量驻留内存，代价是多一次磁盘往返——所以阈值可配。

### 池与 `release()`：借了就要还

编解码是高频路径，fountain 给它配了两个池：编码缓冲池和字节数组池。

```cj
DefaultCodec.setBufferPool(initSize!: 1024, minSize!: 1024, maxSize!: 1024,
    maxWaiting!: Duration.second * 30)
DefaultCodec.setBytesPool(initSize!: 0, minSize!: 1, maxSize!: 1024,
    arraySize!: 4096, maxWaiting!: Duration.second * 30)
```

池带来的责任是显式的：**只解码、不写出也必须调用 `release()`**。`release()` 是幂等的，多调一次不会出错，但漏调会让池慢慢泄漏。`f_rpc` 在首次 `start()` 时会按 `rpc_codec*` 配置重建这两个池，所以线上调参不用改代码。

### 用起来是什么样

```cj
import fountain::f_codec.*
import fountain::f_codec.default.*
import fountain::f_data.*

let codec = DefaultCodec()
let bytes = codec
    .encode(Int64(42))
    .encode('hello world')
    .encode(DataList())          // 空集合：只写一个 COLLECTION head 字节
    .finish()                    // BytesCopyTo（也是 Releasable）

codec.release()                  // 归还编码期间借出的池项

let input = /* InputStream，最好同时实现 SizeBoundedInput */
let a: ?Int64 = codec.decode<Int64>(input)
let b: ?String = codec.decode<String>(input)
let c = codec.decodeData(input)  // 中性解码：拿到 Data，由调用方自行转换
codec.release()
```

---

## 第二层：`f_protocol`——一帧的解剖

`f_codec` 产出的是「一串字节」，还不是「一条消息」。消息需要边界、需要类型、需要能判断对错，这些是 `f_protocol` 的事。

### 帧格式

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| `version` | 1B | 固定 `1`；其它值抛 `CodecException` |
| `command` | 1B | 高 4 位 = 命令号，低 4 位 = 标志位 |
| `len` | 4B | payload 字节数（大端），受 `protocol_maxFramePayload` 限制 |
| `payload` | `len` B | `time → pid → tid → hostId → data` |
| `crc32` | 4B | 覆盖前面全部字段 |

固定 6 字节帧头加 4 字节 CRC（合计 10 字节开销），换来三个能力：**定界**（不用猜消息在哪结束）、**校验**（CRC 先挡掉传输/解析错位）、**自描述**（命令和标志位都在头里）。

`len` 在收发两侧都校验，默认上限 1GB（`protocol_maxFramePayload`）。这一条和 `f_codec` 的 `SizeBoundedInput` 是配套的：一侧限制「能发多大」，另一侧限制「能信多大」。

### 一个字节里的命令与标志位

`command` 字节复用了 `f_codec` head 的思路：高 4 位是 16 个命令，低 4 位是命令相关的标志。

```cj
public enum Command {
    | AUTH(Byte)        //  0
    | SLAVEOF(Byte)     //  1
    | REGISTER          //  2
    | PUBLISH(Byte)     //  3
    | DLQ_LIST          //  4
    | DLQ_REDELIVER     //  5
    | DLQ_REDELIVER_ALL //  6
    | ERROR             //  7
    | SUBSCRIBE         //  8
    | UNSUBSCRIBE       //  9
    | CONSUME(Byte)     // 10
    | RESP(Byte)        // 11
    | PING(Byte)        // 12
    | ELECT(Byte)       // 13
    | ACK               // 14
    | DEREGISTER        // 15
}
```

标志位的含义**随命令变化**，这一点很关键：

| 命令 | Bit 3 | Bit 2 | Bit 1 | Bit 0 |
| --- | --- | --- | --- | --- |
| `AUTH` | `HASDATA` | 0 | 0 | `ACK` |
| `SLAVEOF` | `REG` | 0 | 0 | `ACK` |
| `PUBLISH` | `DUP` | QoS1 | QoS0 | `RETAIN` |
| `CONSUME` | `ONCE` | QoS1 | QoS0 | 0 |
| `ELECT` | `VOTE` | `APPROVE` | `ASSUME` | `ACK` |
| `RESP` | 0 | QoS1 | QoS0 | `ACK` |

能这么省，是因为命令本身已经确定了上下文的解释框架：`PUBLISH` 的低位只可能是 QoS 和 retain，`ELECT` 的低位只可能是投票语义。**用「命令隐含的语义空间」换取一个字节**，这是协议设计里典型的密度优化。

代价是「同一个 bit 在不同命令下含义不同」，所以这个表必须写进文档、且在 `Command.parse` 里对未知命令号直接抛 `CommandException`——宁可炸，也不要猜。

### `Message`：请求和响应是同一种类型

```cj
public struct Message <: Protocol<EncodedMessage, Message> {
    public Message(public let command: Command, public let id: MessageID, public let data: Data)
    public init(command: Command, data: Data)
    public init(command: Command)                 // 无载荷
    public init(command: Command, id: MessageID)  // 无载荷 + 指定 id

    public func tryFromData<T>(): ?T where T <: FromData
    public static func build<T>(command: Command, id: MessageID, data: ?T): Message where T <: ToData
    public func encode(): EncodedMessage
}
```

`Message` 不区分 Request / Response，靠 `command` 区分，靠 `id` 配对。这个选择让「回包」变成一件没有歧义的事：`RESP(id, ...)`、`ERROR(id, ...)`、`ACK(id)` 全都带着原请求的 `MessageID`。

`MessageID` 由 `time + pid + tid + hostId` 组成，但**相等和哈希只用前三项**——`hostId` 只是给运维看的，不参与身份判定。按 `hostId` 做去重会得到和框架不一致的结论。

工厂方法都返回 `Message`，因为 `EncodedMessage` 只由 `encode()` 产出：

```cj
let req  = Message.publish(dup: false, qos: QoS.AtLeastOnce, retain: false, data!: payload)
let sub  = Message.subscribe(data!: 'topic')
let resp = Message.resp(id: req.id, qos: QoS.AtMostOnce, ack!: true, data!: result)
let ack  = Message.ack(id: req.id)
let ping = Message.ping()
```

### 协议是接口，不是结构

`Protocol` 只约束编码与解码两个动作：

```cj
public interface Protocol<EN, DE> where EN <: MessageCopier {
    func encode(): EN
    static func decode<T>(input: InputStream): DE where T <: FromToData
}

public interface MessageCopier {
    func copy(to!: OutputStream, closeToOnEnd!: Bool): Unit
}
```

`EN` 只要求「能被复制到输出流」，`DE` 是解码结果。**`f_net` 从来不需要知道帧的字节布局**，它只调用 `encode()` 拿到一个 `MessageCopier`，然后 `copy(to: socket)`。这意味着：换一套二进制协议、换一套文本协议、甚至换成带压缩的帧，都不需要改网络层——只要实现 `Protocol`。

`EncodedMessage` 实现 `Releasable`，所以有一条硬规矩：**写出后必须 `release()`，写失败也要释放**，否则编码池会泄漏。这类「资源跟着值走」的设计在 fountain 里反复出现（codec、protocol、pool），值得记住。

### 解码异常的两分法

| 情况 | 异常 | 上层动作 |
| --- | --- | --- |
| 首字节就读不到（对端干净关闭） | `InputClosedException` | 正常断链，DEBUG 日志 |
| 版本不符 / 载荷没读尽 / CRC 不符 / 中途 EOF | `CodecException` | 字节流已错位，必须断链 |

这两类必须分开：前者是「对方走了」，后者是「数据坏了」。如果混成一个异常，正常关闭会刷 ERROR；更危险的是把协议错位当成正常关闭——流已经错位，继续读只会解出垃圾。

> 一个部署坑：CRC 实现在 `f_util`，动态库加载顺序必须 **f_util 先于 f_protocol**，否则报 `undefined symbol: crc32Update`。

### 配置

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `protocol_hostId` | `0` | 主机 ID，集群内每台主机唯一（写进 `MessageID`） |
| `protocol_maxFramePayload` | `1 << 30` | 单帧 payload 上限，收发两侧校验 |

配置在**首次使用时**读取并缓存，不能在包初始化期读——那时 `Config` 可能还没就绪。这个「延迟读配置」的模式在 fountain 里是通用约定，后面几篇还会遇到。

---

## 第三层：`f_net`——连接的生命周期

有了帧，就有了「一次请求-响应」的语义。`f_net` 要解决的是：如何在 TCP 上跑这种语义，并且让坏连接自己退场。

### `Client`：请求-响应配对

```cj
public class Client<T> where T <: DataFields<T> {
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1,
        address!: String, checkDuration!: Duration, checker!: () -> ?Message): ClientBuilder<T>

    public func transfer(message: Message): MessageFuture<Message>
    public func transfer(message: Message, timeout: Duration): ?Message
    public func close(): Unit
}
```

`transfer` 立刻返回一个 `MessageFuture<Message>`，真正的响应由读取线程填进去：

```cj
public class MessageFuture<DE> {
    public func get(): DE                    // 阻塞到有数据
    public func tryGet(): ?DE                // 没有就立即返回 None
    public func tryGet(timeout: Duration): ?DE
}
```

这个设计的核心是「**发送与接收解耦**」：业务线程发完就阻塞在自己的 future 上，读取线程只管从 socket 解帧、按 `id` 找到对应的 future、填值。多个请求可以同时在飞，互不阻塞。

注意 `MessageFuture` 持有的是**原始 `Message`**，载荷要调用方自己 `convert<T>(msg.data)`。这是有意的：网络层不做类型解释，它只负责把字节变成消息。

### 心跳：三次失败才拆链

连接断了不可怕，可怕的是「看起来还活着」。`Client` 每 `checkDuration` 发一次 `checker()` 生成的检查包，判定成功的条件是：

```
响应.id == 请求.id && 响应.command == Command.ACK
```

而且**连续 3 次失败（`CHECK_FAILURE_TOLERANCE`）才拆链重建**。容忍的原因是：一次 ping 超时可能只是瞬时抖动或对端 GC，立刻拆链会引发「拆链 → 重连 → 再抖 → 再拆」的风暴。反过来，容忍次数太多又会让坏连接长期占着不放——3 是一个偏保守的折中值。

`ClientBuilder` 里还有一条与它相关的坑：`pingTimeout` **默认 1s**，设得太短会造成拆链重连风暴。

### `MultiClient`：一个「迭代即负载均衡」的抽象

```cj
public class MultiClient<W, T> <: Resource & Iterable<Client<T>> {
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1,
        checkDuration!: Duration, checker!: () -> ?Message): MultiClientBuilder<W, T>
}
```

它同时是「客户端池」和「负载均衡器」，而且**迭代语义就是调用语义**：

```cj
for (client in multiClient) {
    // 第一个元素 = 本次选中的节点
    // 后续元素 = 重试节点
}
```

`f_rpc` 的 `RPCClient` 就依赖这个语义：第一个失败就换下一个，天然实现了「失败切换」。

权重用的是**累计权重桶**：内部 `TreeMap` 以各节点的累计权重为键（`origin + w₁ + … + wᵢ`），取节点 = 第一个键 ≥ 算法给出的值，节点 i 覆盖 `(K_{i-1}, K_i]`。

`MultiClient` 有一个隐蔽的坑：**如果 `origin` 和 `min` 相同，取值序列会与桶边界对齐，永远命中第一个节点。** 正确用法是 `origin = 0`、`min` 落在第一个桶内部（例如 `step / 2`）、`max = Σw`。负载均衡「看起来配了但不生效」，通常就是这一处。

另外，`W` 只支持 `Int64` / `Float64`，其它类型抛 `LoadBalanceException`——泛型不是为了任意数值类型，只是为了「权重可以是整数计数，也可以是浮点比例」。

### `Server`：把不该进线程池的东西挡在外面

```cj
public class Server<T> where T <: DataFields<T> {
    public init(bufferQueueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration,
        executors!: Int64 = 200, unavailableChecked!: Int64 = 3,
        defaultResp!: (MessageID) -> ?Message = {_=> None},
        limiter!: RateLimiter<Unit> = UnlimitedRateLimiter<Unit>(),
        checker!: () -> ?Message)

    /** 阻塞的 accept 循环：调用方自己 spawn */
    public func start(executor: (SocketBuffer, Message) -> ?Message): Unit
}
```

每条连接的处理循环是固定的五步：

1. `Message.decode<T>(buffer)` 解一帧；EOF 记 DEBUG `tcp closed`，解码失败记 WARN 并**必须断链**；
2. `PING` 由 `Server` 内置回 `ACK`，心跳 ACK 也在这一层识别，**都不进 executor**；
3. 业务消息走 `executors.call(limiter){ executor(buffer, req) }`；
4. executor 返回 `None` 时用 `defaultResp(req.id)` 兜底，仍为 `None` 就不回包；
5. 同一连接 ping 计数超过 `unavailableChecked` 判不可用并关闭。

第 2 步让心跳和业务共享一条连接，但**不共享线程池**。如果 ping 也排队进业务线程池，一次业务洪峰就会让 ping 超时，进而触发客户端拆链，引发重连风暴。

第 3 步的限流只作用于业务路径，`PING`/`ACK` 不受限，理由同上。

`ServerBuilder` 的参数分两层，这个划分容易搞混：

- 无前缀（`bindToDevice` / `receiveBufferSize` / `sendBufferSize` / `reuseAddress` / `backlogSize`）作用于**监听 socket**；
- `socket*` 前缀（`socketNoDelay` / `socketLinger` / `socketKeepalive`）作用于 **accept 之后的每条连接**。

前者是「这个服务器怎么监听」，后者是「每条连接怎么表现」，配错位置会发现「参数没生效」。

### 关闭时序：让对端看到完整帧

`SocketBuffer.close()` 做了一件不太常见的事：**先等正在写的那一帧退场（上限 2s），再关 socket**。

```cj
/** 先等在写的那一帧退场（上限 2s）再关 socket：对端看到的是「完整帧 + EOF」，不是半帧 */
public func close(): Unit
```

如果不这么做，对端可能读到半个帧头，然后按 `len` 去读一个不存在的 payload，最后以 `CodecException` 告终——一个正常的关闭动作，在对端变成了「协议错误」。这类细节决定了排障时看到的是 DEBUG 还是 ERROR。

---

## 三层怎么咬合：一次调用走过的路

以 `f_rpc` 的一次远程调用为例：

```
  ① Stub 构造 RPCMessage
        │
  ② f_codec 把 RPCMessage 编成 Data
        │
  ③ f_protocol 包成 Message(CONSUME, id, data)，encode() 成 EncodedMessage
        │
  ④ f_net.Client.transfer() 写 socket，同时登记 MessageFuture(id)
        │
  ⑤ 服务端 f_net.Server 解帧 → 非 PING → 进 executors
        │
  ⑥ f_protocol 解出 Message → f_codec 解出 RPCMessage → ServiceHub 找到方法
        │
  ⑦ 反向：RESP(id, result) 沿原路回到 ④ 的 future
```

这条链路里，每一层都只认识自己那一层的抽象：Stub 认识接口，codec 认识类型，protocol 认识命令，net 认识连接。**没有一层需要知道下一层的内部结构**，这就是把三层切开的价值。

---

## 边界与坑（照抄前先看这里）

1. **空值编码要成对处理**：空字符串 / 空集合 / 空映射在编码侧是「只写 head」的短路，解码侧必须显式认领 `0`，否则会去读不存在的长度字节。
2. **`SizeBoundedInput` 不是可选项**：自定义 `InputStream` 不实现它，解码器就失去了「按声明长度分配前先校验」的能力。
3. **`release()` 必须调**：`DefaultCodec` 与 `EncodedMessage` 都借了池，漏调就是泄漏；写失败也要释放。
4. **对象类型要登记**：跨模块解码 `OBJECT` 前必须 `registerType`，否则 `CodecException`。
5. **CRC 的库加载顺序**：`f_util` 必须先于 `f_protocol`。
6. **`pingTimeout` 默认 1s**：太短会引发拆链重连风暴。
7. **`MultiClient` 的 `origin` / `min` 要对齐桶内部**，否则永远命中第一个节点。
8. **`MessageID` 的 `hostId` 不参与相等/哈希**，别拿它做去重。
9. **`protocol_hostId` 要在集群内唯一**，否则多节点的 `MessageID` 无法区分。
10. **协议错位必须断链**：`CodecException` 之后继续读只会得到垃圾。

---

## 一句话收尾

`f_codec` 用 1 个字节换掉了 schema，`f_protocol` 用 1 个字节换掉了命令表，`f_net` 用 3 次容忍换掉了重连风暴。

**这套通讯栈的取舍集中在两处：每一层只花该花的字节，只做该做的判断。**

---

**同系列**

- [RPC实现](fountain实现思想与应用第11弹——RPC实现.md)
- [数据库中间件](fountain实现思想与应用第12弹——数据库中间件.md)
- [消息队列](fountain实现思想与应用第13弹——消息队列.md)
- [JSONRPC & MCP](fountain实现思想与应用第14弹——JSONRPC&MCP.md)
