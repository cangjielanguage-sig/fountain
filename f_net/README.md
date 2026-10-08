# f_net

`fountain::f_net` 是 fountain 的 TCP 传输层：把 `f_protocol` 的 `Message` 帧读写落到连接上，并管理连接生命周期
（心跳巡检、失败计数、限流执行、关闭时序）。对上层（`f_rpc` 的 `RPCClient`）提供「多节点客户端池」`MultiClient`。

## 包名

| 包 | 内容 |
| --- | --- |
| `fountain::f_net` | `MessageFuture`、`SocketBuffer`、`SocketParams`（internal，仅经 builder 间接使用） |
| `fountain::f_net.client` | `Client` / `ClientBuilder`、`MultiClient` / `MultiClientBuilder`、`ListeningClient`、`ClientException` |
| `fountain::f_net.server` | `Server` / `ServerBuilder` |

## 基本类型

### `MessageFuture<DE>`

```cj
/**
 * 获取解码数据，本类型的公共函数是并发安全的
 */
public class MessageFuture<DE> {
    /** 没有数据就一直阻塞，直到读取线程解码出结果并唤醒本线程 */
    public func get(): DE
    /** 没有数据立即返回 None<DE> */
    public func tryGet(): ?DE
    /** 没有数据就阻塞到 timeout，超时后立即返回（超时前有数据会被唤醒） */
    public func tryGet(timeout: Duration): ?DE
}
```

`MessageFuture` 持有的是**原始 `Message`**（`MessageFuture<Message>`），载荷要调用方自己 `convert<T>(msg.data)`。
填充结果用的 `set()` 不是 public，只有同包的读取线程会调用。

### `SocketBuffer <: IOStream & Resource`

```cj
/**
 * 一条连接上的帧缓冲区
 */
public class SocketBuffer <: IOStream & Resource {
    /** 编码 message 并写到 socket（整帧写出的互斥见 close()） */
    public func transfer(message: Message): Unit
    public func read(bytes: Array<Byte>): Int64     // 读满一帧用，见 f_protocol.Message.decode
    public func write(bytes: Array<Byte>): Unit
    public func flush(): Unit
    public func isClosed(): Bool
    /** 先等在写的那一帧退场（上限 2s）再关 socket：对端看到的是「完整帧 + EOF」，不是半帧 */
    public func close(): Unit
    public prop localAddress: SocketAddress
    public prop remoteAddress: SocketAddress
}
```

构造器不公开：`SocketBuffer` 由 `Client` / `Server` 内部创建（每个 TCP 连接一个）。

## 客户端

### `Client<T>`

```cj
public class Client<T> where T <: DataFields<T> {
    /** 4 个 builder 重载：host!+port! / address!:(String,UInt16) / address!:String / address!:IPSocketAddress */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, address!: String,
        checkDuration!: Duration, checker!: () -> ?Message): ClientBuilder<T>
    /** 消息自带 id（Message.id）；返回原始响应 Message */
    public func transfer(message: Message): MessageFuture<Message>
    /** 等待响应的超时版本；超时或 client 已关闭返回 None */
    public func transfer(message: Message, timeout: Duration): ?Message
    /** 订阅/推送式收流：executor 收到的是该 Message 之后的响应流 */
    public func transfer<T>(message: Message, executor: (Message) -> Unit): ListeningClient<T> where T <: DataFields<T>
    public prop address: IPSocketAddress
    public func isClosed(): Bool
    /** 幂等：取消巡检定时器 + 关闭全部连接缓冲 */
    public func close(): Unit
}
```

`ClientBuilder<T>`（`build(): Client<T>`）的常用设置：`bindToDevice` / `keepAlive` / `linger` / `noDelay` /
`quickAcknowledge` / `readTimeout` / `receiveBufferSize` / `sendBufferSize` / `writeTimeout` /
`socketOption(level, option, value, valueLength)` / `socketOptionBool` / `socketOptionIntNative` /
`pingTimeout`（**默认 1s**，太短会造成拆链重连风暴）。

行为要点：

- **读取循环用 `Message.decode<DataAny>` 做中性解码**：非 PING 消息原样交给 `MessageFuture`，多态载荷由调用方 `convert<T>`；
- **心跳容忍**：连续 `CHECK_FAILURE_TOLERANCE = 3` 次检查失败才拆链重建；一次检查成功要求
  `res.id == m.id && Command.ACK`；
- 所有 buffer 关闭后 `Client` 自行关闭；`transfer` 在已关闭时抛 `Exception('Client is closed')`；
- 构建失败会抛出 `ClientException`。

### `MultiClient<W, T>`：多节点客户端池

```cj
public class MultiClient<W, T> <: Resource & Iterable<Client<T>> {
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1,
        checkDuration!: Duration, checker!: () -> ?Message): MultiClientBuilder<W, T>
}

public class MultiClientBuilder<W, T> where W <: Addable<W> & Comparable<W>, T <: DataFields<T> {
    /** 轮询：step 步长、min/max 算法取值区间、origin 是累计权重键的起点（缺省 = min，兼容旧行为） */
    public func roundRobin(step: W, min: W, max: W, origin!: ?W = None): This
    /** 随机：在 [min, max) 上按权重取值 */
    public func random(min: W, max: W): This
    /** 添加节点：weight 为该节点的权重，地址可给 String / (host, port) / IPSocketAddress，也可传 Iterable */
    public func add(weight: W, address: String): This
    public func build(): MultiClient<W, T>
}
```

- `W` 只支持 `Int64` / `Float64`（其它类型抛 `LoadBalanceException`）；
- **迭代语义**：`MultiClient` 是 `Iterable<Client<T>>`，`for(client in multiClient)` 按负载算法顺序产出，
  **首元素即本次选中的节点，后续元素是重试节点**（`f_rpc` 的 `RPCClient` 依赖这一语义）；
- **权重语义（累计权重桶）**：内部 TreeMap 以各节点的累计权重为键（`origin + w₁ + … + wᵢ`），
  取节点 = 第一个键 ≥ 算法给出的值，节点 i 覆盖 `(K_{i-1}, K_i]`。因此权重场景应传
  `origin = 0`、`min` 落在第一个桶**内部**（例如 `step / 2`）、`max = Σw`；
  若 `origin` 与 `min` 相同，取值序列会与桶边界对齐，**永远命中第一个节点**（见 `.autocode/bugs/bug-archived-20261004-2.md`）。

### `ListeningClient<T>`

`transfer<T>(message, executor)` 的返回值：把某条消息之后的响应持续交给 `executor`，`close()` 幂等。

## 服务端

```cj
public class Server<T> where T <: DataFields<T> {
    public init(bufferQueueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration, executors!: Int64 = 200,
                unavailableChecked!: Int64 = 3,
                defaultResp!: (MessageID) -> ?Message = {_=> None},
                limiter!: RateLimiter<Unit> = UnlimitedRateLimiter<Unit>(),
                checker!: () -> ?Message)
    public static func builder(bufferQueueSize!: Int64 = 1024, checkDuration!: Duration,
        checker!: () -> ?Message, bindAt!: UInt16): ServerBuilder<T>
    /** 阻塞的 accept 循环：调用方自己 spawn */
    public func start(executor: (SocketBuffer, Message) -> ?Message): Unit
    public func isClosed(): Bool
    public func close(): Unit
}
```

`start()` 的每条连接循环：

1. `Message.decode<T>(buffer)` 解出一帧；读到 EOF（对端干净关闭）按 DEBUG 记 `tcp closed` 并断链，
   解码失败（字节流错位）记 WARN `error occurred on decoding` 并**必须**断链；
2. **PING 由 `Server` 内置回 ACK**，心跳 ACK（`checkerId` 里记着的 id）也在这里被识别，都不会进 executor；
3. 业务消息走 `executors.call(limiter){executor(buffer, req)}`：executor 拿到 **buffer + 已解码的 Message**，
   返回 `None` 时用 `defaultResp(req.id)` 兜底，仍为 `None` 则不回包；
4. 连接不可用判定：同一连接 ping 计数超过 `unavailableChecked`（默认 3）即判不可用并关闭。

限流只作用于第 3 步（executor 路径），PING/ACK 不受限。`ServerBuilder` 的参数分两层：

- 无前缀（`bindToDevice` / `receiveBufferSize` / `sendBufferSize` / `reuseAddress` / `backlogSize` /
  `socketOption*`）作用于**监听 socket**；
- `socket*` 前缀（`socketNoDelay` / `socketLinger` / `socketKeepalive` 等经 `SocketParams`）作用于
  **accept 之后的每条连接**；
- 其它：`executors(n)`、`defaultResponse(fn)`、四个限流器构造（`anyMomentRateLimiter` /
  `leakingBucketRateLimiter` / `slidingWindowRateLimiter` / `tokenBucketRateLimiter`）。

## 相关文档

- `doc/审查报告.md`：2026-05-03 的静态审查快照（当时的文件数/用例数，已与现状不符，仅供历史参考）；
- 原 `doc/` 下的 API 摘录（基本类型 / 客户端 / 服务端）已删除，**以本 README 与源码为准**。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- `MultiClient`：`func iterator(): Iterator<Client<T>>`
- `ServerBuilder`：`func setSocketOptionBool(level: Int32, option: Int32, value: Bool): This`、`func setSocketOptionIntNative(level: Int32, option: Int32, value: IntNative): This`、`socketBindToDevice`（func）、`func socketQuickAcknowledge(quickAcknowledge: Bool): This`、`func socketReadTimeout(readTimeout: ?Duration): This`、`func socketReceiveBufferSize(receiveBufferSize: Int64): This`、`func socketSendBufferSize(sendBufferSize: Int64): This`、`func socketWriteTimeout(writeTimeout: ?Duration): This`
