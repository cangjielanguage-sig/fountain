# Spec Delta

## Purpose

定义 `f_mcp` 的 MCP 协议语义：无握手（2026-07-28）的逐请求版本与能力、`server/discover`、`tools/*`、`resources/*`、内容块、分页、legacy 提示，以及复用 `f_jsonrpc` 的客户端。

## ADDED Requirements

### Requirement: 逐请求版本与 `_meta`

服务端 MUST 在每次请求的 `params._meta` 中读取 `io.modelcontextprotocol/protocolVersion`；缺失或不是字符串 MUST 返回 `-32602`；不是 `2026-07-28` MUST 返回 `-32022`，且 `error.data.supported` MUST 非空。校验通过后，交给业务 handler 的 `params` MUST 已剥离 `_meta`。

#### Scenario: 版本不支持

- **WHEN** 请求 `_meta` 里版本为 `1900-01-01`
- **THEN** 返回 `-32022`，`data.supported` 包含 `2026-07-28`，`data.requested` 为原值

#### Scenario: 缺少 `_meta`

- **WHEN** `tools/list` 的 `params` 没有 `_meta`
- **THEN** 返回 `-32602`

#### Scenario: 版本合法

- **WHEN** `_meta` 版本为 `2026-07-28`
- **THEN** 请求被受理，且 handler 收到的 `params` 不含 `_meta`

### Requirement: legacy 对端提示

服务端收到 legacy 方法（`initialize` / `notifications/initialized`）时 MUST 返回 `-32601`，`error.data.legacyMethod` 为收到的方法名，`message` MUST 包含升级提示；客户端收到 `server/discover` 的 `-32601` 时 MUST 抛 `McpException` 并提示对端可能是旧版。

#### Scenario: 旧客户端连新服务端

- **WHEN** 请求 `method` 为 `initialize`
- **THEN** 返回 `-32601`，`data.legacyMethod = "initialize"`，`message` 含 "upgrade"

#### Scenario: 新客户端连旧服务端

- **WHEN** `discover()` 收到 `-32601`
- **THEN** 抛 `McpException`，消息提示对端可能是 MCP 2025-11-25 及更早版本

### Requirement: 能力声明与 `server/discover`

`server/discover` MUST 返回 `resultType = "complete"`、`supportedVersions`、`capabilities`、`_meta.io.modelcontextprotocol/serverInfo`。`capabilities` MUST 只包含已完整实现的能力：`tools` 与 `resources`；MUST NOT 出现 `prompts` 键；`listChanged` 与 `subscribe` MUST 为 `false`。

#### Scenario: discover

- **WHEN** 调用 `server/discover`
- **THEN** `result.supportedVersions` 含 `2026-07-28`，`result.capabilities` 含 `tools` 与 `resources`，不含 `prompts`

#### Scenario: 能力一致性

- **WHEN** `capabilities` 声明了 `resources`
- **THEN** `resources/list` 与 `resources/read` 都可调用

### Requirement: 工具表

`build()` MUST 校验工具名（1~128 字符，仅 `A-Za-z0-9_.-`，服务端内唯一）；工具 `inputSchema` MUST 是合法 JSON Schema 对象，含 `$ref` MUST 在构建时报错并指出位置。`tools/list` MUST 按工具名升序返回，支持 `cursor` 分页，`nextCursor` 不透明。

#### Scenario: 非法工具名

- **WHEN** 注册名为 `bad name` 的工具
- **THEN** `build()` 抛异常

#### Scenario: `$ref`

- **WHEN** `inputSchema` 含 `$ref`
- **THEN** `build()` 抛异常，消息含 `$ref` 与位置

#### Scenario: 分页与稳定顺序

- **WHEN** 注册 `b`、`a`、`c`，`pageSize = 2`
- **THEN** 第一页为 `a,b` 且有 `nextCursor`；第二页为 `c`，无 `nextCursor`；多次请求顺序一致

### Requirement: `tools/call` 单轮

`tools/call` MUST 按 `inputSchema` 校验 `arguments`，失败返回 `-32602` 且 `error.data` 为校验结果；工具执行失败 MUST 用 `isError: true` 表达（不是 JSON-RPC 错误）；支持 `text` / `image` / `audio` / `resource` / `resource_link` 内容块；返回 `structuredContent` 时 MUST 同时把一个序列化文本块放进 `content`。

#### Scenario: 参数不合法

- **WHEN** `arguments` 不满足 `minLength` 约束
- **THEN** 返回 `-32602`，handler 未被调用

#### Scenario: 业务失败

- **WHEN** handler 返回 `CallToolResult(isError: true, content: [text])`
- **THEN** 响应 `result.isError = true`，不产生 JSON-RPC `error`

#### Scenario: structuredContent 双写

- **WHEN** handler 返回 `structuredContent`
- **THEN** `content` 里至少有一个 `text` 块包含其序列化文本

### Requirement: 资源表与 URI 规则

资源 URI MUST 是合法 URI、不含 fragment，scheme MUST 只接受 `http` / `https` / `ftp`；`build()` MUST 拒绝重复 URI 与非法 URI。`resources/list` MUST 按 URI 升序返回并支持 `cursor`；`resources/read` MUST 返回 `contents` 数组，不存在的 URI MUST 返回 `-32002`（`data.uri` 为原值），临时结果过期 MUST 返回 `-32002` 且 `data.reason = "expired"`。

#### Scenario: file:// 被拒

- **WHEN** 注册或读取 `file:///etc/passwd`
- **THEN** 返回 `-32602`（注册时则 `build()` 抛异常）

#### Scenario: 资源不存在

- **WHEN** 读取未注册的 `https://x/y`
- **THEN** 返回 `-32002`，`data.uri = "https://x/y"`

#### Scenario: 二进制资源

- **WHEN** handler 返回 `blob`
- **THEN** `contents[0].blob` 为 base64 字符串

### Requirement: 客户端

`McpClient.http` MUST 复用 `f_jsonrpc.JsonRpcClient`，每次请求自动注入 `_meta`（版本、`clientInfo`、`clientCapabilities`）；MUST 提供 `discover`、`listTools` / `listAllTools`、`callTool`、`listResources` / `readResource`、`close`；收到 `-32022` MUST 只重试一次；`callTool` 返回 `resultType` 与原始 `input_required` 结果供调用方处理。

#### Scenario: 自动注入 `_meta`

- **WHEN** 调用 `listTools`
- **THEN** 请求 `params._meta` 含 `protocolVersion`、`clientInfo`、`clientCapabilities`

#### Scenario: 版本重试一次

- **WHEN** 服务端返回 `-32022` 且 `supported` 非空
- **THEN** 客户端换用 `supported[0]` 重试一次；再失败则抛 `McpException`

#### Scenario: 分页聚合

- **WHEN** 服务端分两页返回工具
- **THEN** `listAllTools` 返回两页合并结果；超过轮次上限时抛异常

### Requirement: HTTP 端点

模块 MUST 提供 `@Controller`，把 `/mcp` 的原始请求体交给 `McpServer`；路由 MUST 是 `POST` + `application/json`（复用 `@JsonRpcMapping`）。

#### Scenario: 路由注册

- **WHEN** 模块被加载
- **THEN** `/mcp` 注册为 POST 路由，`consumes` 与 `produces` 均为 `application/json`

### Requirement: prompts

服务端 MUST 提供 `prompts/list` 与 `prompts/get`；`build()` MUST 校验 prompt 名字与参数声明；未知 prompt 或缺少必填参数 MUST 返回 `-32602`；返回 MUST 是 `messages` 数组（role + content）。

#### Scenario: 列表

- **WHEN** 注册两个 prompt
- **THEN** `prompts/list` 按名字升序返回，能力声明含 `prompts`

#### Scenario: 取 prompt

- **WHEN** `prompts/get` 传入已声明的参数
- **THEN** 返回渲染后的 `messages`

### Requirement: subscriptions/listen 与 SSE

服务端 MUST 提供 `subscriptions/listen`；订阅后 MUST 通过 `SubscriptionHub` 把通知投递给订阅者。`/mcp/sse` MUST 返回 `text/event-stream`，每条事件是一个 JSON-RPC 通知；连接关闭 MUST 注销订阅。

#### Scenario: 订阅

- **WHEN** 调用 `subscriptions/listen` 订阅 `tools/list_changed`
- **THEN** 后续发布的通知出现在该订阅者的 SSE 流里

### Requirement: stdio 客户端

`McpClient.stdio(command, args)` MUST 用子进程的 stdin/stdout 按行收发 JSON-RPC 消息；stderr MUST 独立消费；`close()` MUST 关闭子进程。

#### Scenario: 行分帧

- **WHEN** 子进程输出两行 JSON-RPC 响应
- **THEN** 客户端按行解析，不把 stderr 混进响应

### Requirement: `input_required` Auto 多轮

`callToolAuto(handler, maxRounds)` MUST 在 `resultType == "input_required"` 时调用 handler，拿 `inputResponses` 后用新的 id 重发 `tools/call`；超过 `maxRounds` MUST 抛 `McpException`；`Manual` MUST 原样返回。

#### Scenario: 两轮完成

- **WHEN** 第一轮返回 `input_required`，handler 给出响应，第二轮返回 `complete`
- **THEN** 返回第二轮结果，且两次请求 id 不同

#### Scenario: 超过轮次

- **WHEN** 每轮都返回 `input_required` 且达到 `maxRounds`
- **THEN** 抛 `McpException`
