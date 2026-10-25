# 设计：f_jsonrpc / f_mcp 评审缺陷收敛

> 基线 `4f249d5e`；问题编号沿用 `reviews/202610251557_jsonrpc_mcp_full_review/todo.md` 的轮次与顺序（R1-1 … R6-6），共 7 严重 + 48 一般。

## 1. 背景与约束

### 1.1 现状结构

```
f_jsonrpc
├── base      JsonRpcProtocol / JsonRpcException / JsonRpcMeta
├── client    JsonRpcClient + HttpJsonRpcTransport + ClientOptions
├── server    JsonRpcServer / JsonRpcRegistry / JsonRpcMethodMeta / JsonRpcContext
│             JsonRpcController / JsonRpcMapping
└── macros    @JsonRpc

f_mcp
├── base      McpProtocol / McpException / ContentBlock / CallToolResult …
├── client    McpClient + McpClientOptions + HttpMcpRpc / StdioMcpRpc
├── server    McpServer / McpRegistry / McpTool / McpRateLimit / McpResultStore
│             McpSse / McpController / McpConfig / McpConvert
└── macros    @Mcp
```

`f_mcp` 的 `/mcp` 端点复用 `f_jsonrpc` 的 `JsonRpcServer`（方法表 + 编解码 + 错误映射），`/mcp/sse` 直接返回 `InputStream` 给 f_mvc。

### 1.2 必须保持的不变量

1. JSON-RPC 2.0 线协议：`jsonrpc` / `id` / `method` / `params` / `result` / `error` 形态、id 保真、通知无响应、批量逐条判定。
2. MCP `2026-07-28` 无握手：逐请求 `_meta`、`server/discover`、`resultType`、`inputRequired` / `requestState` 透传。
3. HTTP 路由与注解名不变：`/rpc`、`/rpc/{topic}`、`/mcp`、`/mcp/sse`、`@JsonRpc`、`@JsonRpcMeta`、`@Mcp*`。
4. 默认安全：默认不重试、默认不限流、默认不信任 `X-Forwarded-For`、未知配置报错而非静默降级。
5. `f_jsonrpc` 不依赖 `f_mcp`；`f_mcp` 只依赖 `f_jsonrpc` 的公开面。

### 1.3 设计原则

- **契约优先**：文档、README、错误码、能力声明必须与实现同源；做不到的能力改成 `false` 并从文档删除。
- **失败要可见**：配置错误、非法游标、超限、不支持的版本一律显式报错，不静默退化。
- **热路径只做必要工作**：注册期能算的一次算完；请求期只做 O(1) 查找与必要的序列化。
- **资源有界**：所有以外部输入为 key 的容器必须有容量与 TTL。

## 2. 总体方案

三组改动互相独立、可分批交付：

```
P0（严重）
  ├─ 客户端传输：流式上限 + 重试边界 + 批量错误 + 异常封闭
  ├─ 超时模型：默认无超时 + 显式超时的 ThreadLocal 传播
  ├─ 多轮链路：inputResponses / requestState 贯通
  ├─ 大结果：UTF-8 安全截断
  ├─ 限流器池：有界 + 真正 close
  └─ 结果存储：压力回收 + 重复 token 记账

P1（一般）
  ├─ 服务端热路径：topic 索引 / schema 编译 / 元数据瘦身 / 配置读取
  ├─ 限流语义：三层合并 / 顺序 / 429 / caller 派生 / 配置校验
  ├─ 订阅与 SSE：上限 / TTL / 重连 / 解码 / 阻塞等待
  ├─ 客户端模型与 stdio：强类型模型 / 传输复用 / 选项补齐 / 版本协商
  ├─ 宏与文档：重载诊断 / 注解匹配 / 注册时机 / README 与设计文档
  └─ 测试补齐：传输 / 重试 / 上限 / 并发 / 截断 / 游标
```

## 3. 问题 → 方案映射表

> 「落点」列给出主要文件；测试落点统一在对应 `*_test.cj`。

### 3.1 严重（7）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R1-1 | `maxResponseBytes` 读完整包才判断 | `Content-Length` 预判 + 流式累计上限，超限立即停止读取并关响应 | `f_jsonrpc/src/client/JsonRpcClient.cj` |
| R1-2 | `retryOnConnectFailure` 会重试读阶段 | 传输层区分 `JsonRpcConnectException`（可重试）与普通 `IOException`（不可重试） | 同上 |
| R2-1 | 默认 500ms 超时 → 全部 `spawn` → ThreadLocal 失效 | 默认 `None`；显式超时才 `spawn`，子线程内建立/清理 `CurrentHttpContext` | `JsonRpcRegistry.cj`、`JsonRpcServer.cj`、`f_mvc/CurrentHttpContext.cj` |
| R3-1 | `inputResponses` 被服务端丢弃 | `callTool` 读取并注入 `McpToolContext`；`CallToolResult` 支持 `requestState` | `f_mcp/src/server/McpServer.cj`、`McpTool.cj`、`base/McpContent.cj` |
| R4-1 | 截断按字节切 UTF-8 `String` | `truncateUtf8` 按 rune 边界切；保留 `inputRequired` / `requestState` | `f_mcp/src/server/McpServer.cj` |
| R5-1 | `LimiterPool` 只增不删 | 容量 + 空闲 TTL + 淘汰时 `close()`；`RateLimiter` 增加 `close()` | `McpRateLimit.cj`、`f_concurrent/RateLimiter*.cj` |
| R5-2 | `sweep()` 死代码，过期条目占配额 | `put` 压力路径先 `sweep` 再判定；`sweep` 限频 | `f_mcp/src/server/McpResultStore.cj` |

### 3.2 一般（48）

#### R1 — f_jsonrpc base / client / macros（7）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R1-3 | `batch` 丢弃单对象错误 | 单对象 → 抛 `JsonRpcException(code, message, data)`；非数组非错误 → `-32603` | `JsonRpcClient.cj` |
| R1-4 | 非数字 `error.code` 抛 `JsonException` | 类型守卫；非法 code → `-32603`，保留 message；响应体解析异常统一转 `JsonRpcException` | 同上 |
| R1-5 | `-32001` 无产生点 | 保留常量并标注「保留、当前不产生」；README / 设计文档删除「通用异常 → -32001」；`-32003` 只描述批量 | `JsonRpcProtocol.cj`、两份 README、设计文档 |
| R1-6 | `ClientOptions` 未文档化 | README 增「客户端选项」小节，五个字段含默认值与影响 | `f_jsonrpc/README.md`、`README_en.md` |
| R1-7 | 宏生成 `unused variable` | handler 签名参数改为 `_` | `f_jsonrpc/src/macros/JsonRpc.cj` |
| R1-8 | `@JsonRpcMeta[..., '']` 静默关闭超时 | `''` 明确定义为「无超时」并写入 README；`getMeta` 默认值改 `''` | `JsonRpcRegistry.cj`、`JsonRpcMeta.cj`、README |
| R1-9 | 客户端测试缺口 | 传输 SPI 公开；补重试 / 上限 / keep-alive / `callAsync` / 批量错误用例 | `JsonRpcClient_test.cj`、新增 `HttpJsonRpcTransport_test.cj` |

#### R2 — f_jsonrpc server（8）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R2-2 | `JsonRpcContext.meta` 无消费者 | 删除字段与两个 controller 的逐请求头拷贝 | `JsonRpcContext.cj`、`JsonRpcController.cj`、`f_mcp/McpController.cj` |
| R2-3 | `resolve` 全表扫描 + 重复切片 | 注册期维护 topic 集合；元数据预计算 `namespace` | `JsonRpcServer.cj`、`JsonRpcMethodMeta.cj` |
| R2-4 | `paramsSchema` 每请求重走 + 正则重编译 | 新增 `JsonSchemaValidator.compile` / `CompiledSchema`，注册期编译 | `f_data/src/json/JsonSchema*.cj`、`JsonRpcMethodMeta.cj` |
| R2-5 | `inputSchema` / `outputSchema` 无读取者 | 删除两个字段与构造参数；修正注释 | `JsonRpcMethodMeta.cj` |
| R2-6 | 同名重载加载期抛异常 | 宏展开期检测重名并报编译错误 | `f_jsonrpc/src/macros/JsonRpc.cj` |
| R2-7 | README `/rpc/other` 示例错误 | 改为 `-32004`，与 `resolve` 语义一致 | `f_jsonrpc/README.md`、`README_en.md` |
| R2-8 | `Content-Type` 取自 `Accept` | `handle` 返回 `?JsonValue`，controller 返回 `Any`，走 `respond(JsonValue)` 输出 `application/json` | `JsonRpcServer.cj`、`JsonRpcController.cj` |
| R2-9 | 批量 / 请求体上限未文档化且被静态快照 | 按请求解析 `MVCConfig.maxRequestBodySize`；README 写明两个上限与 `data` 字段 | `JsonRpcServer.cj`、README |

#### R3 — f_mcp base / client / macros（11 一般，另有 R3-1 严重见上）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R3-2 | `callToolAuto` 不回传 `requestState` | 解析响应 `requestState`，下一轮原样带上 | `McpClient.cj` |
| R3-3 | stdio 自建 JSON-RPC 层、固定 id、不校验 id、不处理通知 | 改为 `JsonRpcTransport` 实现，复用 `JsonRpcClient` | `McpClient.cj`、新增 `StdioJsonRpcTransport` |
| R3-4 | stdio 忽略 `timeout` | 读线程 + 信号量 + 截止时间，超时抛 `IOException` | 同上 |
| R3-5 | HTTP 客户端只映射 `timeout` | `McpClientOptions` 补 `headers` / `maxResponseBytes` / `keepAlive` / `retryOnConnectFailure` | `McpClient.cj` |
| R3-6 | `protocolVersion` 可变共享无同步 | `Mutex` 保护读写；协商只改一次并记 INFO；并发只重试一次 | 同上 |
| R3-7 | 客户端结果模型与 base 割裂 | base 增 `fromJson` 与强类型分页 / 结果模型；客户端返回强类型 | `base/McpContent.cj`、新增 `base/McpModels.cj`、`McpClient.cj` |
| R3-8 | 游标不校验，负偏移越界 | `decodeCursor: ?Int64`；非法 → `-32602`；越界 → 空页 | `base/McpProtocol.cj`、`McpServer.cj` |
| R3-9 | 每参数 JSON→String→再解析；返回值重复序列化 | `JsonValue.toData()` + `T.tryFromData`；返回值 `toData()` 后一次生成 JSON | `f_mcp/src/server/McpConvert.cj` |
| R3-10 | 宏按注解短名匹配 | 取 `fullIdentifier` 末段比较；重名编译报错 | `f_mcp/src/macros/Mcp.cj` |
| R3-11 | README / 设计文档与实现大面积偏差 | README 重写客户端与服务端 API 表；设计文档标注「以实现为准」并逐条修正 | 两份 README、两份设计文档 |
| R3-12 | `@Mcp` 在模块加载期 `build()`，与后续 `configure` 互斥 | 删除宏内 `build()`；首次 `server()` 才构建；README 说明注册顺序 | `f_mcp/src/macros/Mcp.cj`、`McpRegistry.cj`、README |

#### R4 — f_mcp server 核心（6）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R4-2 | 声明 `resources.subscribe = true` 但无方法 | 改为 `false`；保留 `prompts`；能力一致性测试 | `McpServer.cj`、README、设计文档 |
| R4-3 | 订阅者 / 队列无上限无过期 | `maxSubscribers` / `queueCapacity` / detached TTL；队列满丢最旧并计数；`close()` 清空 | `McpServer.cj`、`McpSse.cj` |
| R4-4 | prompt 每请求反射查注解；注册重复查找 | 注册期算好参数元数据；合并为一次查找 | `McpRegistry.cj` |
| R4-5 | `tools/call` 重复序列化 2~3 次 | 只序列化一次，量字节 / 入库 / 截断共用 | `McpServer.cj` |
| R4-6 | `tools/list` 每请求重建 JSON | 首次请求惰性缓存条目 JSON（构造一次后只读复用），请求期只切片 | `McpServer.cj` |
| R4-7 | 每工具 `maxConcurrency` 共用 key `'g'` | 全局并发只取服务级；工具并发独立 key；语义写入 README | `McpServer.cj`、`McpRateLimit.cj` |

#### R5 — f_mcp 限流 / 结果 / SSE / 配置（10）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R5-3 | `release` 无条件删 key，计数丢失 | 条目「计数 + 上限 + 最近使用」；release 只减；空闲 TTL 回收 | `McpRateLimit.cj` |
| R5-4 | 校验前写 `Transfer-Encoding: chunked` | 校验通过后再写；错误返回 400 且无 chunked | `McpController.cj` |
| R5-5 | `subscriptionId` 一次性 | detach 而非删除；detached TTL 内可重连；30 分钟只 detach | `McpSse.cj`、`McpServer.cj` |
| R5-6 | SSE 查询串不解码 / 空 topics 反转 | 百分号解码 + trim；显式空 topics → 400 | `McpController.cj` |
| R5-7 | `any-moment` 几乎不限流 | 移除后端与注册项；配置引用报错 | `McpRateLimit.cj`、README |
| R5-8 | 重复 token 记账错误 | `add` 返回值判重；释放旧字节、不重复计数 | `McpResultStore.cj` |
| R5-9 | `evaluate` 每次抢锁、锁内格式化 | 窗口时间原子化；快路径无锁；日志与格式化移出锁 | `McpResultStore.cj` |
| R5-10 | `McpConfig` 数值无语义校验 | 负值报错、0 = 不限制、小数拒绝、未知键拒绝、CSV 段数 / 空段校验、rpm 上限 | `McpConfig.cj` |
| R5-11 | `Builder.rateLimit` 整体替换配置 | `RateLimitPolicy.overlay` 逐字段合并 | `McpServer.cj`、`McpRateLimit.cj` |
| R5-12 | 0 语义三路不一致 | 注解默认 `-1`（继承）/ `0`（不限制）/ `>0`（限额）；并发用 lease 释放 | `McpAnnotations.cj`、`McpRegistry.cj`、`McpServer.cj` |

#### R6 — 跨模块文档 / 契约（6）

| ID | 问题 | 决策 | 落点 |
| --- | --- | --- | --- |
| R6-1 | 设计要求校验 `MCP-Protocol-Version`，实现没有 | `requireMeta(ctx, params)` 校验头存在时的版本与一致性 | `McpServer.cj`、README |
| R6-2 | 无限流 429 / XFF / caller 规则不符 | 429 + `Retry-After`；`X-Forwarded-For`（默认关闭）；caller 规则写入 README | `McpServer.cj`、`McpConfig.cj`、README |
| R6-3 | 设计声明的配置项 / 类型不存在 | 文档收敛到实现；`maxResultBytes` 归属 `McpTool`；删除 `onExceed` / `RateLimitAction` / `AdaptivePolicy` 的声明 | `f_mcp/doc/f_mcp模块设计.md`、README |
| R6-4 | `-32002` 跨模块语义冲突 | MCP `RESOURCE_NOT_FOUND` 迁到 `-32040`；码段写入 README | `base/McpProtocol.cj`、README |
| R6-5 | 先扣令牌再查并发 | 顺序改为并发优先；失败释放 lease；不消耗令牌 | `McpServer.cj` |
| R6-6 | SSE 每连接空转 / O(n²) 拼接 / 逐字节拷贝 | 信号量阻塞等待；`StringBuilder`；批量拷贝 | `McpSse.cj`、`McpServer.cj` |

## 4. 详细设计

### 4.1 f_jsonrpc 客户端传输

#### 4.1.1 传输 SPI

```cangjie
public interface JsonRpcTransport {
    func send(body: Array<Byte>): Array<Byte>
    func close(): Unit
}

/** 建连 / 发送阶段失败：唯一可重试的异常。 */
public class JsonRpcConnectException <: IOException {
    init(message: String) { super(message) }
}
```

`JsonRpcClient` 增加公开构造：

```cangjie
public init(transport: JsonRpcTransport, opts!: ClientOptions = ClientOptions())
```

`maxRetries` 从 `opts.retryOnConnectFailure` 取。HTTP 与 stdio 都走同一 `call` / `batch` / `notify`。

#### 4.1.2 发送与读取

```
send(body):
  build request (POST, Content-Type, Accept, Connection: close when !keepAlive)
  try   response = client.send(...)
  catch e -> throw JsonRpcConnectException(e.message)          // 可重试
  try
    declared = parseLong(headers['Content-Length'])            // 无则 None
    if (declared > maxResponseBytes) throw TooLarge            // 不读 body
    bytes = readCapped(response.body, maxResponseBytes)        // 流式累计
    bytes
  catch e -> response.close(); throw e                         // 不可重试
```

`readCapped`：8 KiB 定长缓冲循环 `read`，累计 `total`；`total > cap` 立即 `throw JsonRpcException(INTERNAL_ERROR, "response body exceeds ...")`。`ArrayList<Byte>` 按 `Content-Length` 预分配（已知且 `<= cap` 时按声明值，减少扩容重分配），每轮把 `buffer[0..size]` 切片 `add(all:)` 进列表——body 字节在这里搬运**一次**；结束后 `unsafeData()` 直接交出底层数组，不再有「`ArrayList` → `Array`」的整体拷贝。即：省掉的是整包副本，逐段切片搬运这一趟保留（缓冲复用，无法省）。

`sendWithRetry`：

```
while true:
  try return transport.send(body)
  catch e: JsonRpcConnectException -> if attempt >= maxRetries throw e else attempt++
```

普通 `IOException` 不进入重试分支。

#### 4.1.3 响应解析

- `parseObject`：`JsonValue.fromBytes` 抛出的任何异常统一 `throw JsonRpcException(INTERNAL_ERROR, "malformed json-rpc response: <reason>")`。
- `toResponse`：
  - `error` 非对象 → `JsonRpcError(INTERNAL_ERROR, "malformed error object")`；
  - `code` 非 `JsonInt` / `JsonDecimal` → `INTERNAL_ERROR`，message 保留服务端文案；
  - `message` 非字符串 → `"Error"`；
  - `result` 缺失且无 `error` → 由 `call` 抛 `-32603`。
- `batch`：
  - 顶层是 `JsonArray` → 现有同序映射；
  - 顶层是 `JsonObject` 且有 `error` → `throw JsonRpcException(code, message, data)`；
  - 其它 → `throw JsonRpcException(INTERNAL_ERROR, "malformed batch response: expected an array")`；
  - 缺 id 条目 → 仍合成 `-32603`，message 带原 id。

### 4.2 f_jsonrpc 服务端

#### 4.2.1 返回类型与 Content-Type

`JsonRpcServer.handle` 改为 `?JsonValue`：

```cangjie
public func handle(body: Array<Byte>, ctx!: JsonRpcContext): ?JsonValue
```

- 通知 → `None`；
- 单条 → `JsonObject`；
- 批量 → `JsonArray`；
- 错误 → `JsonObject`（`respondError`）。

`JsonRpcController` 返回 `Any`（`JsonValue` / `Unit`），f_mvc 走 `respond(JsonValue)`：缺失 `Accept` 或 `*/*` 时输出 `application/json`，特定 `Accept` 时按其协商。这样 `Content-Type` 不再来自 `Accept` 原文。

非 JSON 的 `Accept`（如 `text/plain`）按 `produces` 协商规则返回 406；JSON-RPC 客户端应发送 `application/json` 或不发送 `Accept`。

> 不选「f_mvc 加 Content-Type 已设置判断」：`HttpResponseBuilder.header` 是 append 语义，需要读取已有头，跨模块耦合更大；返回 `JsonValue` 同时省掉一次「先序列化再交出字节」。

#### 4.2.2 topic 索引

`JsonRpcServer` 增加 `private let topics = ConcurrentHashMap<String, Unit>()`：

- `addMethod`：注册成功后 `topics.addIfAbsent(meta.namespace(), ())`；
- `resolve`：
  ```
  if topic.isEmpty() -> methods_.get(method) ?? METHOD_NOT_FOUND
  if !topics.contains(topic) -> UNKNOWN_TOPIC
  match methods_.get(method):
    Some(m) if m.namespace() == topic -> (Some(m), 0)
    Some(_) -> METHOD_NOT_FOUND     // 属于别的命名空间
    None -> METHOD_NOT_FOUND
  ```

`JsonRpcMethodMeta` 构造期把命名空间算进 `private let ns`；`public func namespace(): String` 保留原签名并直接返回 `ns`（源兼容，且请求期不再切片）。

#### 4.2.3 注册期 schema 编译

`f_data` 新增：

```cangjie
public class CompiledSchema {
    public static func compile(schema: JsonObject): CompiledSchema
    public func validate(value: JsonValue, options!: ValidationOptions = ValidationOptions()): ValidationResult
    public prop schema: JsonObject
}
```

- `compile` 遍历 schema 文档一次：校验关键字取值类型（由 `validateDoc` 的同一套读取函数完成）、把所有 `pattern` 预编译成 `Regex` 存入 `HashMap<String, Regex>`（key 为 schema 路径）、收集不支持的未知关键字；
- `validate` 复用现有 `validateDoc`，把 `pattern` 解析改为「查预编译表」；语义与 `JsonSchemaValidator.validate` 完全一致；
- `JsonRpcMethodMeta` 构造期 `paramsSchema` → `compiledParams = CompiledSchema.compile(schema)`；`checkParamsEx` 使用 `compiledParams`。

权衡：不重写 AST 校验器。schema 文档通常只有几十个节点，遍历成本远小于正则编译；把「编译」定义为「结构校验 + 正则预编译 + 关键字预解析」已经消除脏 schema 的延迟暴露与热路径编译，同时避免出现两套校验语义。

#### 4.2.4 超时与执行模型

```
getMeta: 无注解 -> JsonRpcMeta('', '')          // 默认无超时
macro:   timeout == '' -> None
invokeHandler:
  timeout == None -> meta.handler(ctx, params)   // 内联
  timeout == Some(t) ->
     future = spawn { CurrentHttpContext.scoped(ctx.http) { meta.handler(ctx, params) } }
     future.get(t) catch TimeoutException -> JsonRpcException(-32002, 'Request timed out')
```

`f_mvc` 新增：

```cangjie
public static func scoped<T>(ctx: ?HttpContext, body: () -> T): T {
    match (ctx) {
        case Some(h) => context.set(h)
        case _ => ()
    }
    try { body() } finally { context.set(None<HttpContext>) }
}
```

`set` / `clear` 保持包内可见，外部只用 `scoped`。

#### 4.2.5 请求体上限

`JsonRpcServer` 保存 `configuredMaxBodyBytes: Int64`（0 表示未配置）与 `maxBatchSize`；`handle` 内：

```
let limit = if (configuredMaxBodyBytes > 0) configuredMaxBodyBytes
            else (MVCConfig.maxRequestBodySize ?? 2 * 1024 * 1024)
```

每次请求一次 `Config` 读（HashMap 查），可忽略。

#### 4.2.6 元数据瘦身

`JsonRpcMethodMeta` 删除 `inputSchema` / `outputSchema`；`JsonRpcContext` 删除 `meta`。`McpController` 的版本头校验改读 `ctx.http.request.headers`。

### 4.3 f_jsonrpc 宏

- `handler: {_, $paramsVar => ...}`，消除 `unused variable`；
- `expand` 内维护 `HashSet<String>` 收集 `fullName`；第二次出现即 `diagReport(ERROR, f.identifier.toTokens(), "duplicate json-rpc method '${fullName}': overloaded public methods need distinct names", '')`；
- `getMeta` 默认 `JsonRpcMeta('', '')`；`timeoutDuration` 仅在非空时调用。

### 4.4 f_mcp 协议与服务端

#### 4.4.1 版本与能力

```cangjie
requireMeta(ctx, params):
  meta = params._meta (必须对象)
  bodyVersion = meta.protocolVersion (必须非空字符串)
  header = ctx.http?.request.headers.getFirst('MCP-Protocol-Version')
  header 存在:
      header 不受支持 -> -32022(data.supported)
      header != bodyVersion -> -32602(data: {header, body})
  bodyVersion != VERSION -> -32022
  剥离 _meta，返回 params
```

校验顺序 MUST 固定为「header 受支持性 → header 与 body 一致性 → body 受支持性」。若先判 body，则 body 非法时提前 `-32022`，header 与 body 不一致的分支永远不可达（当前实现即此问题）。

`capabilities()`：`tools.listChanged=false`、`resources.subscribe=false, listChanged=false`、`prompts.listChanged=false`。

`McpProtocol` 新增 `OVERLOADED = -32003`（订阅者总量超限时使用），与 `f_jsonrpc` 的同名保留码语义一致。

#### 4.4.2 多轮

```
callTool:
  request = requireMeta(ctx, params)
  inputResponses = request.inputResponses        // 任意 JSON，原样
  requestState   = request.requestState
  toolCtx = McpToolContext(callerId, requestId, inputResponses, requestState)
```

`McpToolContext` 新增两个可选参数（`None` 默认，源兼容）。

`CallToolResult` 新增 `requestState: ?JsonValue`，`toJson()` 输出。`requestState` 从 handler 返回结果进入 JSON-RPC `result`，客户端 `toCallToolResult` 解析。

`callToolAuto`：

```
var responses: ?JsonValue = None
var state: ?JsonValue = None
loop:
  params = {name, arguments}
  responses 存在 -> params.inputResponses = responses
  state 存在 -> params.requestState = state
  result = call
  if result.resultType != 'input_required' -> return result
  responses = handler(result.inputRequired)
  state = result.requestState          // 原样，不解析
```

#### 4.4.3 分页

`McpProtocol.decodeCursor(cursor: String): ?Int64`：
- 空串 → `Some(0)`（调用方已区分「缺失」）；
- base64 解码失败 / 非 UTF-8 / 无 `offset:` / 非整数 / `< 0` / `> 10_000_000` → `None`。

`cursorOf(request)`：

```
match request.get('cursor'):
  None -> 0
  Some(JsonString(s)) -> decodeCursor(s) ?? throw McpException(-32602, 'invalid cursor', data: JsonString(s))
  Some(other) -> throw McpException(-32602, 'cursor must be a string', data: other)
```

`offset >= list.size` → 空页，无 `nextCursor`。

#### 4.4.4 缓存条目

`build()` 只建索引，**不**预生成条目 JSON。条目对象在**首次 `list` 请求时**惰性构造（`toolJson` / `resourceJson` / `promptJson`），写入 `McpTool.listJson` / `McpResource.listJson` / `McpPrompt.listJson`，之后同一对象被复用；连续 N 次 `list` 只构造 1 次。spec 的「`build()` 后冻结并缓存」按「`build()` 之后、首次请求时填充并冻结」实现，构造次数口径（连续 10 次 = 1 次）一致。

缓存条目**只读**：`listXxx` 只把缓存对象追加进页数组，不做拷贝；HTTP 路径序列化后即丢弃引用，安全。但本地 `handle()` / `invoke()` 路径直接返回 `JsonValue`，拿到的是**同一个引用**，未经序列化——调用方 MUST NOT 修改返回的条目（改了就写穿到注册表，污染后续所有 `list` 响应）。需要可变副本的调用方自行深拷贝，服务端不为此在热路径上做拷贝。

#### 4.4.5 大结果

```
applyLargeResult(tool, result):
  limit = tool.maxResultBytes ?? 1 MiB
  encoded = result.toJson()
  json = encoded.toString()                 // 唯一一次完整序列化
  if json.size <= limit -> encoded
  if baseUrl:
     token, link
     put(token, ResourceContent(link, application/json, json, None))
     成功 -> resource_link 结果（保留 isError/resultType/inputRequired/requestState）
     失败 -> truncated(result, json, limit)
  else -> truncated(result, json, limit)

truncated(result, json, limit):
  cut = truncateUtf8(json, limit)           // 按 rune 边界
  CallToolResult(content:[text(cut)], isError, resultType,
                  inputRequired, requestState,
                  extra: {truncated:true, limit})
```

`truncateUtf8`：遍历 `toRuneArray()`，累计每个 rune 的 UTF-8 字节数，超过 `limit` 时停止，输出 `StringBuilder`。保证结果 ≤ `limit` 且为合法 UTF-8。

`CallToolResult.extra`（新增，`?JsonObject`）在 `toJson` 中并入顶层 `data`，用于承载 `truncated` / `limit`。

### 4.5 f_mcp 客户端

#### 4.5.1 传输统一

删除 `HttpMcpRpc` / `StdioMcpRpc`，保留 `McpRpc` 作为包内测试接缝；两个实现统一为 `JsonRpcMcpRpc`，内部只包一个 `JsonRpcClient`：

```cangjie
class JsonRpcMcpRpc <: McpRpc {
    private let client: JsonRpcClient
    init(client: JsonRpcClient) { this.client = client }
    public func call(method: String, params: ?JsonValue): JsonValue {
        client.call(method, params: params)
    }
    public func close(): Unit { client.close() }
}

public init(url: String, options!: McpClientOptions = McpClientOptions()) {
    this.rpc = JsonRpcMcpRpc(JsonRpcClient(url, opts: options.toJsonRpcOptions()))
    ...
}

public static func stdio(command: String, args!: Array<String> = [],
    options!: McpClientOptions = McpClientOptions()): McpClient {
    McpClient(JsonRpcMcpRpc(JsonRpcClient(StdioJsonRpcTransport(command, args, options.timeout),
                                          opts: options.toJsonRpcOptions())), options)
}
```

#### 4.5.2 StdioJsonRpcTransport

```
init: launch(command, args, piped)
      readerThread = spawn { while readln(): lines.offer(line) }

send(body):
  deadline = now + timeout
  id = JsonValue.fromBytes(body).asObject()['id']
  write(body + '\n'); flush
  loop:
    remaining = deadline - now; if <= 0 -> throw IOException('stdio response timeout')
    line = lines.poll(remaining)
    None -> throw IOException('stdio server closed the stream')
    parsed = try JsonValue.fromStr(line) catch -> log WARN 'non-json stdio output'; continue
    parsed 是 JsonObject 且无 id：
        method 以 'notifications/' 开头 -> log DEBUG; continue
        有 method -> log DEBUG 'ignored stdio request'; continue
    parsed.id == id -> return line.bytes
    其它 id -> log WARN 'stale stdio response id=...'; continue

close: close stdin; terminate; wait(2s); stop reader
```

`lines` 为「`Mutex` + `Condition` + `ArrayList<String>`」或「`Semaphore` + 队列」，实现时按 SDK 可用原语选择，语义要求：带超时的阻塞取、`close` 后立即唤醒。

#### 4.5.3 选项与版本

```cangjie
public class McpClientOptions {
    public var timeout = Duration.second * 30
    public var protocolVersion = McpProtocol.VERSION
    public var clientName = 'fountain-mcp-client'
    public var clientVersion = '1.0.0'
    public var capabilities = JsonObject()
    public var maxRounds: Int64 = 8
    public var headers = HashMap<String, String>()
    public var maxResponseBytes: Int64 = 8 * 1024 * 1024
    public var keepAlive = true
    public var retryOnConnectFailure: Int64 = 0
}
```

`toJsonRpcOptions()` 映射为 `ClientOptions`；stdio 忽略 `headers` / `keepAlive` / `maxResponseBytes`（文档说明）。

版本协商：

```
rpcCall(method, params, triedVersion!: ?String = None):
  version = currentVersion()
  try rpc.call
  catch (e: McpException) / (e: JsonRpcException) where code == -32022:
      next = negotiate(triedVersion ?? version, e)
      if next != version || triedVersion.isNone() -> rpcCall(..., triedVersion: version)
      throw
  catch (e: IOException) -> throw McpException(INTERNAL_ERROR, 'transport failed: ...')
```

`negotiate` 在 `Mutex` 内：若当前版本已不同于本次请求使用的版本 → 直接返回（别处已协商）；否则从 `data.supported[0]` 更新并 `log INFO`。

#### 4.5.4 强类型模型

新增 `f_mcp/src/base/McpModels.cj`（全部 `public`，均含 `fromJson` / `toJson`）：

- `McpServerInfo { name, version }`
- `McpCapabilities { raw: JsonObject }` + `toolsListChanged` / `resourcesSubscribe` / `resourcesListChanged` / `promptsListChanged`；`toJson()` 返回 `raw`（保留未知字段）
- `DiscoverResult { supportedVersions, capabilities, serverInfo, raw }`
- `McpToolDescriptor { name, description, inputSchema: JsonObject, raw }`
- `ResourceDescriptor { uri, name, description, mimeType }`
- `PromptDescriptor { name, description, arguments: Array<PromptArgument> }`
- `ToolPage { tools: Array<McpToolDescriptor>, nextCursor: ?String }`
- `ResourcePage`、`PromptPage` 同构
- `ReadResourceResult { contents: Array<ResourceContent> }`
- `GetPromptResult { description, messages: Array<PromptMessage> }`
- `ListenResult { subscriptionId, subscribedTopics, sseUrl }`

`ContentBlock` 增加：

```cangjie
public static func fromJson(obj: JsonObject): ContentBlock   // 保留 type 原文，未知类型不丢弃
```

`CallToolResult.fromJson` / `ResourceContent.fromJson` / `PromptMessage.fromJson` / `PromptArgument.fromJson`。

`McpClient` 返回类型见 4.4 对应的 spec 表。保留 `public type McpCallToolResult = CallToolResult` 作为源兼容别名。

#### 4.5.5 宏转换

```
argument<T>(value):  T.tryFromData(value.toData())  -> 失败抛 -32602
toolResult<T>(value):
   json = JsonValue.from(value.toData())            // 一次转换
   content = [text(json.toString())]
   structuredContent = json is JsonObject ? json : None
```

不再 `toString()` → `fromJson` 往返。

### 4.6 限流与并发

#### 4.6.1 策略合并

```
RateLimitPolicy.overlay(override)  // 每个字段：override 有值取 override，否则取 base
build(): policy = McpConfig.rateLimit().overlay(rateLimitPolicy)
```

工具层：

```
resolveLimit(tool):
  global     = { perCallerRpm: policy... , maxConcurrency: policy.maxConcurrency }
  toolLimit  = tool.rateLimit
  merge(global, toolLimit)  // 除 maxConcurrency 外逐字段覆盖
  globalConcurrency = policy.maxConcurrency
  toolConcurrency   = toolLimit.maxConcurrency
```

#### 4.6.2 检查顺序与 lease

```
enum 顺序：
  1 acquire global 'conc:g'      (limit = policy.maxConcurrency)
  2 acquire tool    'conc:t:<tool>' (limit = toolLimit.maxConcurrency)
  3 acquire caller  'conc:ct:<caller>\0<tool>' (limit = perCallerConcurrency)
  4 tryAcquire 'rpm:c:<caller>'
  5 tryAcquire 'rpm:ct:<caller>\0<tool>'
  6 tryAcquire 'rpm:t:<tool>'

ConcurrencyLease { global: Bool, tool: Bool, caller: Bool }
release(lease): 只释放 lease 中为 true 的 key
```

任一 rpm 失败 → `release(lease)` 后抛 `-32050`。`limit <= 0` 不获取、lease 标记 false。

#### 4.6.3 ConcurrencyGate

```
Entry { count: AtomicInt64, limit: Int64, lastUsed: AtomicInt64 }
tryAcquire(key, limit):
   if limit <= 0 -> false（表示未获取，lease=false）
   entry = getOrCreate(key, limit)
   CAS count < limit -> +1
release(key):
   entry = get(key) ?? return
   CAS count > 0 -> -1（到 0 不删）
sweep(): 移除 count==0 且 now-lastUsed > idleTtl；超过容量时移除最久未使用
```

#### 4.6.4 LimiterPool

```
Entry { limiter: RateLimiter<Bool>, lastUsed: AtomicInt64 }
acquire(key, rpm):
   if rpm <= 0 -> true
   bucketKey = '${key}#${rpm}'
   entry = getOrCreate
   entry.lastUsed = now
   every 256 ops -> sweep()
   limiter.exec(Some(false), {=> Some(true)}) ?? false
sweep():
   移除 idle > 10min 或（size > 10_000 时）最久未使用；每个都被 limiter.close()
close(): 全部 close
```

`RateLimiter` 增加 `public open func close(): Unit {}`；`TokenBucket` / `LeakingBucket` / `SlidingWindow` 覆盖为 `timer.cancel()`（`Timer` 需要提升为字段）。

`LimiterPool` 与 `ConcurrencyGate` 的容量 / 空闲 TTL 为构造参数（默认 10 000 / 10 分钟），测试注入小值验证淘汰；生产路径由内置后端使用默认值。

#### 4.6.5 429 与 caller

`rateLimitError(ctx, verdict)`：`ctx.http` 存在时 `status(429)` + `Retry-After: max(1, ceil(retryAfterMs/1000))`。

`verdict.scope` 与拒绝维度一一对应（6 个取值，对应 `specs/mcp-guardrails/spec.md` 的表和 README）：`concurrency`（全局并发）/ `concurrency_tool`（工具并发）/ `concurrency_caller`（调用方×工具并发，gate key `conc:ct:<caller>\0<tool>`）/ `caller` / `caller_tool` / `tool`（三档 rpm）。scope 与是否走 HTTP 无关，HTTP 只额外决定 429 + `Retry-After`。

`callerId(ctx)` 按 spec 的 4 级顺序；`mcp_trustForwardedFor` 默认 `false`，可通过配置项或 `McpServerBuilder.trustForwardedFor(Bool)` 开启。

#### 4.6.6 后端集合

删除 `AnyMomentRateLimitBackend` 与其注册；`fromConfig` 对未知名保留现有 `IllegalArgumentException`，消息列出 `RateLimitBackends` 全部可用名。

#### 4.6.7 `mcp_rateLimit` CSV 解析

CSV 是**按位置**覆盖的 5 段：`perCallerRpm,perCallerToolRpm,perToolRpm,maxConcurrency,perCallerConcurrency`。判定规则：

```
parts = raw.split(',')
if parts.size > 5 -> 报错（尾部多余段）
for i in 0..parts.size:
    empty = parts[i].trim().isEmpty()
    empty && 存在 j > i 且 parts[j] 非空 -> 报错（中间空段，消息含 FIELDS[i]）
    empty -> None
    else -> 非负整数 / <= 1_000_000 / 0 -> None / >0 -> 值
```

尾部空段等价于省略（`'1,,,'` 与 `'1'` 等价），保持既有部署与既有用例兼容；`'1,,120'` 这类「空段后仍有值」的输入无法区分「省略」与「写错」，必须报错而不是静默当作省略。

### 4.7 结果存储

```
put(token, content):
  bytes = estimate
  if count >= max:
      sweepIfDue()
      if count >= max: rejectedByCount++; evaluate(); return false
  if !budget.reserve(bytes, maxBytes):
      sweepIfDue()
      if !budget.reserve(bytes, maxBytes): rejectedByBytes++; evaluate(); return false
  old = entries.add(token, ResultEntry(...))
  match old:
      Some(prev) -> budget.release(prev.bytes)     // count 不变
      None -> count.fetchAdd(1)
  puts.fetchAdd(1); evaluate(); true
```

`sweepIfDue()`：`now - lastSweep > 1s` 才真正扫；扫完更新 `lastSweep`。

`evaluate()`：

```
if !adaptive: return
now = ...
if now - windowStart.load() < windowNanos: return       // 无锁快路径
snapshot = synchronized(windowMutex) {
    if now - windowStart < windowNanos: return hold
    ... 计算并更新窗口状态 ...
    (decision, reason, current, target, dPuts, dCount, dBytes, rejectRate, occupancy)
}
log.debug(...)   // 锁外
if target != current: maxEntries.store(target); log.info(...)
```

### 4.8 SSE 与订阅

#### 4.8.1 订阅中心

```
McpSubscriber {
   id, topics, attached, detachedAtNanos(创建即 = now)
   queue: ArrayList<JsonObject>, queueMutex, sem
   offer(n): lock { if queue.size >= cap { queue.remove(0); dropped++ } queue.add(n) } sem.release()
   take(timeout): sem.acquire(timeout) -> lock { drain all }
}
SubscriptionHub {
   subscribers: ArrayList, mutex
   maxSubscribers = 1024, detachedTtl = 60s, queueCapacity = 256
   subscribe(topics): prune(); if size >= max -> throw -32003; add(attached=false, detachedAt=now)
   detach(sub): 幂等；无论 attached 与否都 attached=false, detachedAt=now
   attach(id): find !attached 且未超 TTL -> attached=true, detachedAt=0
   publish(topic, params): snapshot under lock; offer outside lock
   prune(): remove !attached && now-detachedAt > TTL
   close(): clear
}
McpSseStream(hub, topics): sub = hub.subscribe(topics); hub.attach(sub.id)   // 直连也必须 attach
```

`detachedAt` 的起点是创建时刻而不是首次 detach：否则从未 attach 的订阅者既不满足 `detachedAt > 0`，也无法通过 `detach()`（旧实现 `!attached` 直接 return）写入时间戳，最终永久驻留且继续占用 `maxSubscribers` 与队列内存。`attach` 必须清 `detachedAt`，否则重连后的订阅者会在下一次 `prune` 被误删。

三个上限可通过 `McpServerBuilder.maxSubscribers(n)` / `subscriberQueueCapacity(n)` / `subscriberDetachedTtl(d)` 配置（默认即上表），供测试与按部署调整；`McpServer.close()` MUST 调用 `hub.close()`。

#### 4.8.2 SSE 流

`read` 循环：`subscriber.take(15s)` → 有事件则 `StringBuilder` 拼 `event: message\ndata: ...\n\n`；无事件且距上次写 > 15s → `: ping\n\n`；否则继续等待（不再 `sleep(100ms)`）。

`close()` / 30 分钟到点 → `hub.detach(subscriber)`，EOF。

字节输出：`pending` 为 `Array<Byte>`，`read` 用 `copyTo` / 切片赋值一次拷完。

#### 4.8.3 查询串

`McpController` 用统一的 `queryOf(url)` 解析 `key=value` 列表，值做百分号解码（`%XX`，`+` → 空格）与 `trimAscii`：

- `subscriptionId=` 空或非整数 → 400；
- `topics` 缺省 → `None`（订阅全部）；`topics=` 显式空 → 400；其余按 `,` 拆分、trim、丢弃空项；
- 先校验再 `responseBuilder.header('Transfer-Encoding', 'chunked')`；
- 错误时 `status(400)` 并抛出带说明的异常。

### 4.9 跨模块支撑改动

| 模块 | 改动 | 理由 |
| --- | --- | --- |
| `f_data` | `JsonSchemaValidator.compile` / `CompiledSchema` | 注册期校验与正则预编译 |
| `f_mvc` | `CurrentHttpContext.scoped` | 显式超时时在子线程恢复请求上下文 |
| `f_concurrent` | `RateLimiter.close` + 三个定时器型 limiter 覆盖 | 限流器池淘汰时真正释放 Timer |

### 4.10 文档收敛

- `f_jsonrpc/README.md` / `README_en.md`：客户端选项、错误码表（`-32001` 保留、`-32003` 仅批量）、`/rpc/{topic}` 示例、`maxBatchSize` / `maxBodyBytes`、超时默认值与 `''` 语义、重试边界、`Content-Type`。
- `f_mcp/README.md` / `README_en.md`：客户端选项与返回类型、`input_required` / `requestState`、能力表（`subscribe=false`）、错误码（`-32040`）、限流顺序 / 三层合并 / caller 规则 / 429、`any-moment` 移除、订阅上限与重连、`-1/0/>0` 语义。
- `f_jsonrpc/doc/f_jsonrpc模块设计.md`、`f_mcp/doc/f_mcp模块设计.md`：文首加「实现为准」横幅；逐条修正被点名的 API / 配置 / 错误码 / 能力段落；删除 `onExceed` / `RateLimitAction` / `AdaptivePolicy` 等未实现声明。
- `f_mcp/doc/f_mcp模块设计.md` 的定点清理（T43 / T44 收口）：
  - 资源不存在 / 过期链接：`-32002` → `-32040`（接口表、错误表、流程图、测试矩阵共 9 处：:716、:923、:926、:1208、:1256、:2248、:2259、:2281、:2349）；
  - 删除 `AdaptivePolicy` 类与 13 项配置表（:1299-1342），`ResultStoreOptions` 按实际 9 个字段重写，修 :1286「8 个字段」；
  - :937「`resources/subscribe` ❌ 不做…首版无 SSE」改为「SSE 已实现；未实现的是逐资源 `resources/subscribe` / `unsubscribe`」；
  - :526 `JsonRpcContext.meta`、:536-543 `JsonRpcMethodMeta.inputSchema/outputSchema` 的旧声明删除，与 :1314「不再有」保持一致。
- `f_jsonrpc/doc/f_jsonrpc模块设计.md:1102`：`maxResponseBytes` 的「截断」改为「超限立即抛错并关闭响应」。
- 代码注释同步：`f_mcp/src/server/McpConfig.cj:31` 删除 `any-moment`；`f_mcp/src/macros/Mcp.cj:30` 删除「最后调用 `McpRegistry.build()`」。
- 验收口径：`f_mcp/doc` 中 `AdaptivePolicy` / `any-moment` / MCP 侧 `-32002` 零命中；文档出现的公开符号都能在源码找到。

## 5. 兼容性与迁移

| 变更 | 影响 | 迁移 |
| --- | --- | --- |
| `JsonRpcContext.meta` 删除 | 直接读该字段的代码编译失败 | 改读 `ctx.http?.request.headers` |
| `JsonRpcMethodMeta.inputSchema/outputSchema` 删除 | 构造时传参会编译失败 | 从 MCP 的 `McpTool` 取 |
| `JsonRpcServer.handle` 返回 `JsonValue` | 断言字节的测试需改 | `result.toString().unsafeBytes()` |
| 默认超时 500ms → 无 | 依赖默认超时的调用不再超时 | 显式 `@JsonRpcMeta['desc','5s']` |
| `RESOURCE_NOT_FOUND` -32002 → -32040 | 客户端按码分支需改 | 改判断 `-32040` |
| `decodeCursor` 返回 `?Int64` | 直接使用返回值的代码需改 | `?? 0` 或显式处理非法 |
| `any-moment` 移除 | 配置启动报错 | 换 `token-bucket` / `sliding-window`；并发用 `maxConcurrency` |
| `ToolRateLimit.maxConcurrency` 语义 | 原本被当作全局上限 | 全局用 `RateLimitPolicy.maxConcurrency` |
| `@McpToolMeta` 默认 `0` → `-1` | 显式写 `0` 的语义从「继承」变「不限制」 | 想继承就不写该字段 |
| MCP 客户端返回强类型 | 依赖 `JsonObject` 的代码需改 | 用模型字段或 `.raw` |
| `ConcurrencyGate.tryAcquire` 对 `limit <= 0` 返回 `false`（未占槽） | 旧实现返回 `true`；直接依赖返回值的调用方会误判 | 用 `ConcurrencyLease` 判断是否释放 |

## 6. 测试策略

遵循 TDD：每个任务先写失败用例，再实现。

| 层 | 方式 | 重点 |
| --- | --- | --- |
| 传输 | 可注入 `JsonRpcTransport` 替身 + 本地 TCP/`stdx` server | 流式上限（chunked 超限）、`Content-Length` 预判、重试边界、keep-alive 二次调用、`Connection: close` |
| 服务端 | 直接调 `JsonRpcServer.handle` / `invoke` | topic O(1)、schema 注册期报错、重名重载、body 上限配置化、`Content-Type` |
| 超时 | handler 内读 `CurrentHttpContext` + 睡眠 | 默认内联、显式超时 `-32002`、子线程 ThreadLocal |
| MCP 服务端 | 构造 `McpServer` + 直接调方法 | 多轮 `inputResponses`/`requestState`、游标非法、能力一致性、截断中文、缓存条目、限流顺序 |
| 限流 | 直接操作 `LimiterPool` / `ConcurrencyGate` / `ToolResultStore` | 容量淘汰、close 取消 Timer、release 竞态、重复 token、压力 sweep |
| SSE | `McpSseStream.poll` + 假 hub | 无事件不空转（调用计数）、阻塞等待、重连、未 attach 订阅者 TTL 回收、30 分钟只 detach、解码、400 |
| stdio | bash 脚本模拟子进程 | 通知、噪声行、id 匹配、读超时、id 单调 |
| 宏 | 编译期诊断用例（沿用 `f_macros` 现有机制）；无机制时以「注册结果 + 构建日志」验证 | 重名报错、全限定注解、无警告 |
| 文档 | 人工核对 + 关键示例变成测试 | README 代码片段可编译 |

回归门禁：`f_jsonrpc`、`f_mcp`、`f_data`、`f_mvc`、`f_concurrent` 各自 `cjpm test` 全绿；`fboot build` 通过；`openspec validate fix-jsonrpc-mcp-review-findings` 0 错。

补测清单（verify 复审要求：勾选任一任务前必须先有对应用例）：

| 任务 | 用例要点 |
| --- | --- |
| T41.1–41.3 | 头/body 不一致 `-32602`（`data.header/body`）、头不受支持 `-32022`、无头只按 body |
| T11.1–11.2 | `tools/call` 全路径序列化计数：小结果 1 次；大结果 + `publicBaseUrl` ≤ 2 次 |
| T32.1–32.4 | 真 HTTP：`headers` 逐请求命中、`maxResponseBytes` 超限、`keepAlive=false`、建连失败重试 |
| T33.1 | 8 线程并发协商：版本只改写 1 次、单请求最多重试 1 次、INFO 日志 1 条 |
| T29.1–29.4 | 编码 topic 能收到通知、`?topics=a, b` 两项、`?topics=` 400、无效 id 400 且无 chunked |
| T36.1–36.3 | `findAnnotation` 次数 = 参数个数、`getInstanceFunction` 1 次、条目 JSON 构造 1 次 |
| T38.1–38.3 | 全限定注解、与 `McpRegistry.configure` 共存、重名编译期报错 |
| T27.2 / T27.5 | 未 attach 订阅者 TTL 回收、30 分钟只 detach |
| T1.1 | 服务端未读完 body（已落地字节 < `Content-Length`） |

## 7. 替代方案与取舍

1. **默认保留 500ms 超时，改为传播 ThreadLocal**：仍然每次调用多一个线程，且 500ms 对含 DB / 下游 HTTP 的 handler 过于激进；超时后 handler 继续执行会让非幂等操作重复。选择「默认无超时」。
2. **`batch` 单对象错误时返回 N 份相同错误**：保留数组形状，但调用方仍无法区分「批量超限」与「单条失败」，且会产生 N 倍响应体积。选择抛 `JsonRpcException`。
3. **重试时按方法是否幂等决定**：需要额外的幂等声明与传播，且默认值仍不安全。选择「只在建连/发送阶段重试」。
4. **`resources.subscribe` 实现逐资源订阅**：需要资源变更事件源与 per-URI 订阅表，超出本次修复范围。选择声明 `false`。
5. **MCP `RESOURCE_NOT_FOUND` 保留 `-32002`**：与 f_jsonrpc 的超时码冲突，同一进程无法区分。选择迁到业务段 `-32040`。
6. **完整重写 JSON Schema 校验器为 AST**：会引入两套语义与大面积回归风险。选择「结构校验 + 正则预编译 + 复用遍历器」，并在文档中说明取舍。
7. **`LimiterPool` 只做容量上限不取消 Timer**：淘汰后 Timer 仍持有 limiter 与队列，等于没修。选择改 `f_concurrent` 增加 `close()`。
8. **SSE 改异步 IO**：需要 f_mvc 提供非阻塞响应通道，超出范围。选择阻塞等待 + 批量拷贝，先把空闲 CPU 降到 0。

## 8. 实施顺序

1. **P0-A 客户端传输**（R1-1、R1-2、R1-3、R1-4、R1-9 的用例骨架）
2. **P0-B 超时模型**（R2-1、R1-8）
3. **P0-C 多轮链路**（R3-1、R3-2，含服务端 `requestState`）
4. **P0-D 大结果截断**（R4-1、R4-5）
5. **P0-E 限流器池与结果存储**（R5-1、R5-2、R5-8）
6. **P1-A 服务端热路径**（R2-2、R2-3、R2-4、R2-5、R2-8、R2-9）
7. **P1-B 限流语义**（R4-7、R5-3、R5-7、R5-10、R5-11、R5-12、R6-2、R6-5）
8. **P1-C 订阅与 SSE**（R4-2、R4-3、R5-4、R5-5、R5-6、R6-6）
9. **P1-D 客户端模型与 stdio**（R3-3、R3-4、R3-5、R3-6、R3-7、R3-8、R3-9、R4-4、R4-6）
10. **P1-E 宏与注册**（R1-7、R2-6、R3-10、R3-12）
11. **P1-F 文档与契约**（R1-5、R1-6、R2-7、R3-11、R4-2 文档部分、R6-1、R6-3、R6-4）
12. **P1-G verify 收口**（V3–V8）：订阅者生命周期 → 版本头校验顺序 → CSV 空段 → 补测 → 文档残留 → `openspec validate` 归零

P0 未全绿不得进入 P1；P1 每阶段结束后跑对应模块全量回归。P1-G 未收敛前不得进入 archive，`tasks.md` 的 Z5 / Z6 保持未勾选。

## 9. 风险

| 风险 | 缓解 |
| --- | --- |
| `JsonRpcServer.handle` 返回类型变更波及大量测试 | 先改服务端 + 一个 controller，再批量修测试；编译错误即清单 |
| 显式超时的 ThreadLocal 传播涉及线程生命周期 | 只在 `Some(t)` 路径启用，`scoped` 用 `finally` 清理；补用例验证清理 |
| `f_concurrent` 增加 `close()` 可能影响其他模块 | 默认空实现，只有三个定时器型 limiter 覆盖；单独回归 `f_concurrent` |
| 强类型模型与现有 demo 不兼容 | 保留 `.raw` 与 `McpCallToolResult` 类型别名；demo 编译验证 |
| 截断后 JSON 不再是合法 JSON | 明确写入文档：截断版是文本前缀，`data.truncated` 标记；保留 `limit` |
| SSE 阻塞等待依赖 `Semaphore` / `Condition` 实际签名 | 实现前先查 SDK 文档；若超时等待不可用，退化为 1s 轮询（仍比 100ms 好），并在 design 变更记录 |
| `McpConfig` 收紧校验可能让既有部署启动失败 | 在 README「迁移」列出；错误消息给出字段与合法值 |
