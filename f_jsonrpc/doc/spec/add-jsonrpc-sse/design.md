# Design

## Context

- `f_mvc` 的 `RequestMeta` 已有 `case x: InputStream => respond(x, ctx)`：controller 返回 InputStream 即流式响应；
- `f_jsonrpc` 的 controller 目前只返回 `JsonValue`，路由注解 `@JsonRpcMapping` 固定 `POST + application/json`；
- 客户端 `JsonRpcClient` 的传输是 `send(body): Array<Byte>`（一次性读完），不能直接用于 SSE。

## Decisions

### D1. SSE 端点用新注解 `@SseMapping`，不动 `@JsonRpcMapping`

```cangjie
@SseMapping[path: '/rpc/stream']
public func stream(@RequestParam topic: String, @RequestParam taskId!: String): InputStream
```

`@SseMapping` 是 `RequestMapping` 的子类（与 `@JsonRpcMapping` 同法），固定 `GET`、
`produces = "text/event-stream"`，并允许 `topic` / `taskId` / `cursor` 三个查询参数。

**替代**：扩展 `@JsonRpcMapping` 支持 GET。否决——同一注解同时表达「JSON-RPC POST」与「SSE GET」会让语义模糊，
且 `@JsonRpcMapping` 已被 `JsonRpcController` 使用，改它有回归风险。

### D2. `SseHub` 是进程级单例，按 `topic` 分桶

```cangjie
public class SseHub {
    public static func subscribe(topic: String, taskId!: String, lastEventId!: Int64): SseSubscription
    public static func publish(topic: String, method: String, params: JsonValue): Int64
    public static func subscriberCount(topic: String): Int64
    public static func reset(): Unit      // 测试用
}
```

事件 id 全局单调递增（`AtomicInt64`/`Mutex`），同一 `topic` 下共享序列——这样 `Last-Event-ID` 的语义简单：
「id 大于它的都补发」。

**替代**：每订阅者独立队列 + 独立 id。否决——补发需要「按 id 找位置」，全局序列才有意义。

### D3. `SseStream <: InputStream` 用阻塞队列

```cangjie
class SseStream <: InputStream {
    // queue: ArrayDeque<Array<Byte>>，容量 256
    public func read(buffer: Array<Byte>): Int64   // 阻塞；空队列等心跳周期后返回注释帧；关闭后返回 0
    public func close(): Unit                      // 置 closed，read 返回 0（std.io 的 EOF 约定是 0，不是 -1）
}
```

- `read` 在队列空时**阻塞**（`Mutex` + `Condition`），不忙等；
- 空闲超过 15s 返回一行 `: ping\n\n`（SSE 注释帧），避免中间代理断连；
- `close()` 由 hub 在订阅者被移除时调用。

**替代**：`std.io` 的 `Pipe`。否决——标准库没有跨线程 pipe；自己用条件变量最直接。

### D4. 缓冲溢出丢最旧并 warn 一次

每订阅者 256 条上限，溢出时 `removeFirst()` 再 `addLast()`，并置 `dropped = true`（只 warn 一次，避免刷屏）。

**为什么不去阻塞发布方**：发布方是业务线程（任务状态机），阻塞它会把整个任务拖住；丢最旧对「状态进度」这类
可丢弃事件是合理取舍（A2A 的 `tasks/get` 仍能拿到最终状态）。

### D5. 客户端用 `std.net` 原生 socket 读，不复用 `JsonRpcClient`

`JsonRpcClient` 的传输契约是「发完收完」，改成流式会破坏既有调用方。新增并列的 `JsonRpcSseClient`：

```cangjie
public class JsonRpcSseClient {
    public init(url: String, topic!: String = '', taskId!: String = '', headers!: HashMap<String, String>)
    public func next(): ?JsonValue      // 一条 JSON-RPC 通知；连接正常结束返回 None
    public func close(): Unit
}
```

**替代**：给 `JsonRpcClient` 加 `stream()` 方法。否决——同一个类同时管两种生命周期，状态（连接、重连、缓冲）会互相污染。

### D6. `f_mvc` 零改动

SSE 只用到它已有的 `InputStream` 响应分支与 `CurrentHttpContext.instance.responseBuilder`（公开 API）。
若未来 `f_mvc` 提供原生 SSE，`SseController` 可整体替换，`SseHub` / 客户端不受影响。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `HttpResponseBuilder.body(InputStream)` 是否真边读边写（而非缓冲到结束） | 实现第一步就用「发一条 → 客户端立刻收到」的冒烟用例验证；若不成立，退化方案是 `SseController` 里直接操作 `ctx.request` 的 socket（仍不动 `f_mvc`） |
| 长连接占用线程 | 与 `f_mvc` 的线程模型一致（每请求一线程）；文档写明并发上限，生产按需调 `maxConcurrentStreams` |
| 进程内广播不支持多实例 | 写入 `known-limitations.md`：多实例需外部总线 |
| 客户端重连重复消费 | 用 `Last-Event-ID`；服务端保证 id 与补发，客户端只产出 id > 上次的事件 |
