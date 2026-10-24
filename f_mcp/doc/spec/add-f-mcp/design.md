# Design

## Context

- `f_jsonrpc` 已提供：JSON-RPC 消息模型、运行期方法表、错误对象、批量/通知、`@JsonRpcMapping`、`JsonRpcServer` / `JsonRpcClient`。
- `f_data` 已提供 `JsonSchemaValidator.validate`（文档版）与 `toJsonSchema<T>()`。
- 硬约束：`f_mvc` 零改动；`f_mcp` 只依赖 `f_jsonrpc` / `f_data` / `f_log`（用户指定，不引入 `f_cache` / `f_process`）。
- 无 fboot 环境：HTTP 端到端冒烟不可执行，协议逻辑以进程内直调测试覆盖。

## Goals / Non-Goals

**Goals:**

- 服务端：`server/discover`、`tools/list`、`tools/call`（单轮）、`resources/list`、`resources/read`；能力声明不出现空壳。
- 客户端：HTTP 传输、`_meta` 自动注入、版本重试一次、legacy 检测、分页聚合。
- 护栏：三层限流 + 并发闸门；大结果转 `resource_link` / 截断；临时结果存储。

**Non-Goals:**

- 可配置 HTTP 路由（固定 `/mcp`）
- 跨进程的强一致分布式限流（提供 SPI + 本地实现，多实例需外部存储后端）

## Decisions

### D1. 消息层完全复用 `f_jsonrpc`

`McpServer` 内部持有一个 `JsonRpcServer`，把五个 MCP 方法注册进去；`/mcp` 的 `@Controller` 只做「原始字节 → `handle` → 响应字节」。MCP 不重复实现 JSON 编解码、批量、通知、错误对象。

### D2. 版本与 `_meta`

常量 `MCP_PROTOCOL_VERSION = '2026-07-28'`。每个方法的 handler 先做统一校验：

1. `params._meta` 存在且为对象
2. `io.modelcontextprotocol/protocolVersion` 为字符串
3. 版本等于常量，否则 `-32022`（`data.supported = ["2026-07-28"]`、`data.requested`）
4. 通过后**剥离 `_meta`** 再交给业务逻辑

legacy 方法（`initialize` / `notifications/initialized`）注册为显式方法，返回 `-32601` + `data.legacyMethod` + 升级文案。

### D3. 能力声明

`capabilities = { "tools": {"listChanged": false}, "resources": {"subscribe": false, "listChanged": false} }`，**没有 `prompts` 键**。`server/discover` 的 `_meta` 回写 `serverInfo`。

### D4. 工具表与构建期校验

`McpTool` 在 `build()` 时校验：名字长度/字符/唯一性；`inputSchema` 是 JSON Schema 对象；递归扫描 `$ref` / `$defs` 并拒绝（指出 JSON Pointer）。`tools/list` 用 `pageSize`（默认 100）+ 不透明 cursor（内部是 offset 的 base64url 近似：直接 `offset:<n>` 的十六进制编码），按名字升序。

`McpToolBuilder.of<T>()` 调 `JsonObject.toJsonSchema<T>()`；显式 schema 与文件加载最终都归一成 `JsonObject`。

### D5. 资源表与 URI

`McpResource` 在 `build()` 时校验：URI 可解析、无 fragment、scheme ∈ {http, https, ftp}、全局唯一、handler 非空；`/mcp/tool-results/` 前缀为框架保留，用户注册即报错。

`resources/list` 按 URI 升序 + cursor；`resources/read` 先查临时结果前缀，再查用户表；不存在 → `-32002`（`data.uri`），临时结果过期 → `-32002` + `data.reason = "expired"`。`contents` 始终是数组。

URI 解析用 `stdx.encoding.url.URL`（`f_jsonrpc` 已在用 `f_mvc`，其 public import 带出 `stdx.encoding.url.*`？不依赖这个假设，直接 import）。

### D6. 内容块

`ContentBlock` 用单一 class + `type` 字段 + 五个静态工厂（text / image / audio / resource / resourceLink），`toJson()` 按类型输出。`image` / `audio` 的 `data` 与 `resource.blob` 在协议层 base64（`stdx.encoding.base64`）。

`CallToolResult.toJson()` 在 `structuredContent` 非空时自动追加一个 `text` 块（序列化后的 JSON），保证老客户端可用。

### D7. 限流（不依赖 `f_cache`）

- `RateLimitPolicy` / `ToolRateLimit`：三层配置，逐字段取第一个非 `None`。
- 令牌桶：`BucketEntry { tokens: Float64, lastRefillNanos, lastUsedNanos }`，存 `ConcurrentHashMap<String, BucketEntry>`；桶操作加锁（每个 entry 一把 `Mutex`，或全局分段锁——实现用 `synchronized(entry)`）。每 1024 次访问或 60 秒惰性扫一次，淘汰 10 分钟未用的桶。
- 并发闸门：`ConcurrentHashMap<String, AtomicInt64>`，`tryAcquire` 失败回滚并 `recycle`，`release` 用 `remove` 返回值减账；`recycle` 先比对引用再删（无 `remove(k,v)`）。
- 调用方 ID：`Authorization: Bearer <token>` → SHA-256 前 16 字节 hex；否则 `request.remoteAddr`；非 HTTP（本地直调）为 `local`。
- 超限：`-32050`，`data.scope` ∈ 五个值，`data.limit`、`data.retryAfterMs`。
  **偏差**：`f_jsonrpc` 把协议错误统一映射 HTTP 200，因此不做 429；`retryAfterMs` 已给出重试建议。

### D8. 大结果与临时存储

- 阈值 `maxResultBytes`（默认 1 MB，可按工具覆盖）。
- 配了 `publicBaseUrl`：`ToolResultStore.put(token, content)`，返回单个 `resource_link`；token 为 16 字节随机数的 base64url（用 `Random` 生成，避免引入新依赖）。
- 未配：截断文本 + `data.truncated = true` + warning。
- `ToolResultStore`：`ConcurrentHashMap` + `ByteBudget`（CAS 预留）+ 条数/字节/TTL 三重约束；`get` 按 `remove` 返回值减账；`put` 在条数/字节压力时 `sweep()`；无后台线程；`close()` 清空。
- **不做自适应调容**（Non-Goal），参数通过 `ResultStoreOptions` 配置。

### D9. 客户端

`McpClient` 依赖包内 `McpRpc` 接口（`call` / `close`），默认实现包装 `f_jsonrpc.JsonRpcClient`；这样单测可以注入假 RPC，不需要 HTTP 服务器。

- `_meta` 注入：`protocolVersion` / `clientInfo` / `clientCapabilities`
- `discover()`：调 `server/discover`，`-32601` → `McpException`（旧服务端）
- `-32022`：取 `data.supported[0]` 更新 session 版本并重试一次
- `listAllTools`：轮次上限 100、总条数上限 1000
- `callTool`：返回 `CallToolResult`，`resultType` 原样保留（`input_required` 由调用方处理）
- `close()`：关闭底层 client

### D10. stdio 客户端

用 `std.process.launch` 起子进程，stdin 写一行一个 JSON-RPC 消息、stdout 按行读；stderr 单独消费避免阻塞。只做客户端侧（设计 3.2.1），不做 server-side 夹具。

### D11. `input_required` 的 Auto 多轮

`CallToolResult.resultType == "input_required"` 时，`McpClient.callToolAuto(handler, maxRounds)` 把 `inputRequired` 交给 handler，拿到 `inputResponses` 后用**新的 id** 再发一次 `tools/call`；超过 `maxRounds` 抛 `McpException`。`Manual` 保持原样返回。

### D12. 自适应调容

`ToolResultStore` 每窗口（默认 5 分钟）统计 `puts` / `rejectedByCount` / `rejectedByBytes` / 占用量：拒绝率 > 1% 且未触顶 → `maxEntries` 上调 25%；连续 3 个窗口占用 < 25% 且本窗口无字节拒绝 → 下调 12.5%（不低于 `floor`）；只调 `maxEntries`，不调 `maxBytes` / TTL。每窗口一条 debug 日志，每次调整一条 info 日志。

### D13. SSE / `subscriptions/listen`

`subscriptions/listen` 注册订阅并返回 `resultType=complete`；`SubscriptionHub` 按 topic 维护订阅者队列。`/mcp/sse` 用 `HttpResponseBuilder.body(InputStream)` 输出 `text/event-stream`，事件是 JSON-RPC 通知。`f_mvc` 的 controller 返回 `Unit` 时不再改写响应，因此不需要改 `f_mvc`。

### D14. prompts

`prompts/list` + `prompts/get`，能力声明 `prompts: {listChanged: false}`；`prompts/get` 的参数按声明校验，未知 prompt → `-32602`，返回 `messages` 数组。

### D15. 分布式限流

定义 `RateLimitBackend` SPI（`tryAcquire(key, limit, windowMs, now): Bool`、`release`），默认 `LocalRateLimitBackend`（进程内令牌桶）。多实例部署时由使用方注入共享后端（Redis / `f_store`），f_mcp 不绑定具体存储。

### D16. 部署

`@Controller` + `@JsonRpcMapping[path:'/mcp']`，方法返回 `Any`（bytes 或 `Unit`）。`McpRegistry.server()` 持有进程内默认 `McpServer`，应用在 static init 注册工具/资源。

## Risks / Trade-offs

| 风险 | 处置 |
|---|---|
| 无 fboot，`/mcp` 的 HTTP 行为（415 / 空 body）未实测 | 记录为遗留项，协议逻辑由单测覆盖 |
| 未做 stdio，无法连外部 stdio server 自测 | 明确列为 Non-Goal；HTTP 客户端可连任何 Streamable HTTP 服务端 |
| 未做自适应调容 | 固定参数可配；日志/统计字段保留在 `ToolResultStore` 里，后续变更再加调容 |
| 限流桶未用 `f_cache` | 自管 TTL + 惰性淘汰；桶数上限由调用方规模决定，10 分钟未用即回收 |
| 429 未实现 | `-32050` + `retryAfterMs` 已能表达重试建议 |
| `URL` 解析与 base64 依赖 stdx | 与仓库其它模块一致，不新增第三方依赖 |
