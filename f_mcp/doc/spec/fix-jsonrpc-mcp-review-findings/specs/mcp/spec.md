# Spec Delta

## Purpose

收敛 `f_mcp` 的协议契约与服务端 / 客户端缺陷：多轮 `input_required` 断裂、能力声明与实际方法不符、分页游标可制造内部错误、stdio 传输是独立 JSON-RPC 实现、客户端结果模型与 base 割裂、宏注解匹配与注册时机问题。覆盖 R3、R4（部分）与 R6-1。

## MODIFIED Requirements

### Requirement: 逐请求版本与 `_meta`

服务端 MUST 在每次请求的 `params._meta` 中读取 `io.modelcontextprotocol/protocolVersion`；缺失或不是字符串 MUST 返回 `-32602`；不是 `2026-07-28` MUST 返回 `-32022`，且 `error.data.supported` MUST 非空。校验通过后，交给业务 handler 的 `params` MUST 已剥离 `_meta`。

服务端 MUST 同时校验 HTTP 头 `MCP-Protocol-Version`（存在时）：

- 头值不是受支持版本 MUST 返回 `-32022`；
- 头值与 body `_meta` 中的版本不一致 MUST 返回 `-32602`，`error.data` 含 `header` 与 `body` 两个值；
- 头缺失时 MUST 只按 body 校验（兼容不带该头的客户端）。

#### Scenario: 版本不支持

- **WHEN** 请求 `_meta` 里版本为 `1900-01-01`
- **THEN** 返回 `-32022`，`data.supported` 包含 `2026-07-28`，`data.requested` 为原值

#### Scenario: 缺少 `_meta`

- **WHEN** `tools/list` 的 `params` 没有 `_meta`
- **THEN** 返回 `-32602`

#### Scenario: 版本合法

- **WHEN** `_meta` 版本为 `2026-07-28`
- **THEN** 请求被受理，且 handler 收到的 `params` 不含 `_meta`

#### Scenario: 头与 body 不一致

- **WHEN** `MCP-Protocol-Version: 2026-07-28`，body `_meta` 版本为 `2025-11-25`
- **THEN** 返回 `-32602`，`data.header = "2026-07-28"`，`data.body = "2025-11-25"`

#### Scenario: 头版本不受支持

- **WHEN** `MCP-Protocol-Version: 1900-01-01`，body 版本为 `2026-07-28`
- **THEN** 返回 `-32022`

### Requirement: 能力声明与 `server/discover`

`server/discover` MUST 返回 `resultType = "complete"`、`supportedVersions`、`capabilities`、`_meta.io.modelcontextprotocol/serverInfo`。

`capabilities` MUST 只声明已完整实现的能力：

- `tools`：MUST 存在，`listChanged = false`；
- `resources`：MUST 存在，`listChanged = false`，`subscribe = false`（本版本未实现 `resources/subscribe` / `resources/unsubscribe`）；
- `prompts`：MUST 存在（`prompts/list` 与 `prompts/get` 已实现），`listChanged = false`。

MUST NOT 声明任何没有对应方法的能力；新增能力时 MUST 同时补方法、测试与 README。

#### Scenario: discover

- **WHEN** 调用 `server/discover`
- **THEN** `result.supportedVersions` 含 `2026-07-28`，`result.capabilities` 含 `tools` / `resources` / `prompts`

#### Scenario: 不声明空壳能力

- **WHEN** `capabilities.resources.subscribe = true`
- **THEN** 方法表必须存在 `resources/subscribe` 与 `resources/unsubscribe`；否则测试失败

#### Scenario: 能力一致性

- **WHEN** `capabilities` 声明了 `resources`
- **THEN** `resources/list` 与 `resources/read` 都可调用

### Requirement: 工具表

`build()` MUST 校验工具名（1~128 字符，仅 `A-Za-z0-9_.-`，服务端内唯一）；工具 `inputSchema` MUST 是合法 JSON Schema 对象，含 `$ref` / `$defs` MUST 在构建时报错并指出位置。`tools/list` MUST 按工具名升序返回，支持 `cursor` 分页，`nextCursor` 不透明。

工具描述 JSON MUST 在 `build()` 后冻结并缓存；`tools/list` MUST NOT 为每个工具重新构造 `JsonObject`。返回的条目 MUST NOT 让调用方修改后污染注册表（实现可选择返回缓存引用并约定只读，或返回拷贝；本版本采用「缓存引用 + 序列化后不再保留引用」）。

#### Scenario: 非法工具名

- **WHEN** 注册名为 `bad name` 的工具
- **THEN** `build()` 抛异常

#### Scenario: `$ref`

- **WHEN** `inputSchema` 含 `$ref`
- **THEN** `build()` 抛异常，消息含 `$ref` 与位置

#### Scenario: 分页与稳定顺序

- **WHEN** 注册 `b`、`a`、`c` 三个工具，`pageSize = 2`
- **THEN** 第一页为 `a`、`b` 且带 `nextCursor`；第二页为 `c` 且无 `nextCursor`

#### Scenario: 描述缓存

- **WHEN** 连续调用 `tools/list` 10 次
- **THEN** 工具描述 JSON 构造次数为 1（构建期），请求期只做切片

### Requirement: 资源表与 URI 规则

资源 URI MUST 满足：完整 `http(s)/ftp` URL，或以 `/` 开头的绝对路径（构建时用 `publicBaseUrl` 拼成完整 URI）；不含 fragment；不占用 `/mcp/tool-results/` 前缀。

`resources/list` 的条目 JSON MUST 在 `build()` 后缓存；请求期 MUST NOT 重新构造。

读取不存在的资源或已过期的大结果 MUST 返回 MCP 业务段错误码 `-32040`（`RESOURCE_NOT_FOUND`），`error.data` 含 `uri` 与 `reason`（`unknown` / `expired`）。MUST NOT 再使用 `f_jsonrpc` 保留的 `-32002`。

#### Scenario: 资源不存在

- **WHEN** `resources/read` 请求未注册的 `uri`
- **THEN** 返回 `-32040`，`data.uri` 为原值，`data.reason = "unknown"`

#### Scenario: file:// 被拒

- **WHEN** 注册或读取 `file:///etc/passwd`
- **THEN** 读取返回 `-32602`；注册时 `build()` 抛异常

#### Scenario: 二进制资源

- **WHEN** handler 返回 `blob`
- **THEN** `contents[0].blob` 为 base64 字符串

#### Scenario: 过期的大结果

- **WHEN** `resources/read` 读取已过 TTL 的 tool-result 链接
- **THEN** 返回 `-32040`，`data.reason = "expired"`

#### Scenario: 前缀冲突

- **WHEN** 注册以 `/mcp/tool-results/` 开头的用户资源
- **THEN** `build()` 抛异常

### Requirement: prompts

`prompts/list` MUST 按名字升序返回，支持游标分页；`prompts/get` MUST 校验必填参数并返回 `description` + `messages`。

prompt 参数的 `description` / `required` MUST 在注册期从 `@McpPromptArg` 计算一次；`prompts/get` MUST NOT 再次反射查找注解。注册路径 MUST 只做一次 `getInstanceFunction` 查找。

`prompts/list` 的条目 JSON MUST 在 `build()` 后缓存。

#### Scenario: 必填缺失

- **WHEN** prompt 参数 `topic` 标记 `required = true`，`prompts/get` 未提供
- **THEN** 返回 `-32602`，`data` 为参数名

#### Scenario: 不重复反射

- **WHEN** 连续调用 `prompts/get` 10 次
- **THEN** `findAnnotation<McpPromptArg>` 调用次数为注册期的参数个数，不随请求增长

#### Scenario: 列表

- **WHEN** 注册两个 prompt
- **THEN** `prompts/list` 按名字升序返回，能力声明含 `prompts`

#### Scenario: 取 prompt

- **WHEN** `prompts/get` 传入已声明的参数
- **THEN** 返回渲染后的 `messages`

### Requirement: subscriptions/listen 与 SSE

`subscriptions/listen` MUST 创建订阅者并返回 `subscriptionId`、`subscribedTopics`、`sseUrl`。服务端 MUST 约束订阅者总量与每订阅者队列长度；未建立 SSE 连接的订阅者 MUST 在 detached TTL（默认 60 秒）后回收；`McpServer.close()` MUST 清空订阅中心。

未连接状态的起点 MUST 是订阅者**创建时刻**：`subscriptions/listen` 创建后即进入 detached 计时；由 `/mcp/sse` 直接创建（未走 `subscriptions/listen`）的订阅者 MUST 在创建后立即绑定（attach），MUST NOT 存在「永远未 attach、因而永不回收」的订阅者。`detach` MUST 幂等：对已 detach 或从未 attach 的订阅者都 MUST 写入 detach 时刻而不报错。

`subscriptionId` MUST 支持在 SSE 断开后于 detached TTL 内重连；同一订阅者同时只允许一条活动流。30 分钟上限到达时 MUST 结束当前流并 detach（保留至 TTL），MUST NOT 立即永久删除订阅者。

`/mcp/sse` MUST：

- 在订阅者校验通过后才写入 `Transfer-Encoding: chunked`；
- 对查询串做百分号解码与 trim；
- `topics` 缺省表示订阅全部；`topics=`（显式空串）MUST 返回 HTTP 400，MUST NOT 退化为「订阅全部」；
- 无效 `subscriptionId` MUST 返回 HTTP 400（不再以 200 承载 JSON-RPC 错误码）。

SSE 流 MUST 在无事件时阻塞等待（带超时），MUST NOT 以固定 100ms 间隔空转；事件拼接 MUST 使用 `StringBuilder`，写出 MUST 使用批量字节拷贝。

#### Scenario: 订阅上限

- **WHEN** 已达 `maxSubscribers` 仍调用 `subscriptions/listen`
- **THEN** 返回 `-32003`，不新建订阅者

#### Scenario: 未连接即泄漏

- **WHEN** 客户端拿到 `sseUrl` 后不连接，等待超过 detached TTL
- **THEN** 订阅者被回收，队列与计时资源释放

#### Scenario: 断线重连

- **WHEN** SSE 流异常关闭后 60 秒内用同一 `subscriptionId` 重连
- **THEN** 重连成功，期间排队的通知仍可收到

#### Scenario: 编码后的 topic

- **WHEN** 请求 `?topics=tools%2Flist_changed`
- **THEN** 订阅的 topic 为 `tools/list_changed`，能收到该主题通知

#### Scenario: 空 topics

- **WHEN** 请求 `?topics=`
- **THEN** 返回 HTTP 400，不建立订阅

#### Scenario: 无效订阅 id 不污染响应头

- **WHEN** `subscriptionId` 不存在
- **THEN** 响应为 400，且不含 `Transfer-Encoding: chunked`

#### Scenario: 订阅

- **WHEN** 调用 `subscriptions/listen` 订阅 `tools/list_changed`，再连接返回的 `sseUrl`
- **THEN** 后续发布的通知出现在该订阅者的 SSE 流里
- **WHEN** 同一个 `subscriptionId` 再次建立 SSE 连接
- **THEN** 拒绝建立 SSE 连接，不再新建订阅者

### Requirement: 客户端

客户端 MUST 提供 `discover` / `listTools` / `listAllTools` / `callTool` / `callToolAuto` / `listResources` / `readResource` / `listPrompts` / `getPrompt` / `listen` / `close`。

客户端返回类型 MUST 复用 base 模型，MUST NOT 直接返回裸 `JsonObject`：

| 方法 | 返回 |
| --- | --- |
| `discover` | `DiscoverResult` |
| `listTools` | `ToolPage` |
| `listAllTools` | `Array<McpToolDescriptor>` |
| `callTool` / `callToolAuto` | `CallToolResult` |
| `listResources` | `ResourcePage` |
| `readResource` | `ReadResourceResult` |
| `listPrompts` | `PromptPage` |
| `getPrompt` | `GetPromptResult` |
| `listen` | `ListenResult` |

所有 base 模型 MUST 提供 `fromJson`，未知内容块类型 MUST 原样保留（`kind()` 返回服务端 `type`，`toJson()` 可还原），MUST NOT 丢弃。

`McpClientOptions` MUST 提供 `timeout`（默认 30s）、`protocolVersion`、`clientName`、`clientVersion`、`capabilities`、`maxRounds`（默认 8）、`headers`、`maxResponseBytes`（默认 8 MiB）、`keepAlive`（默认 true）、`retryOnConnectFailure`（默认 0）。HTTP 专属选项对 stdio MUST 文档化说明「忽略」。

`protocolVersion` 协商 MUST 线程安全：版本读取与更新 MUST 在锁内完成；一次协商 MUST 记录 INFO 日志；并发命中 `-32022` 时 MUST NOT 各自改写版本、MUST NOT 产生 N 次额外重试。

#### Scenario: 强类型工具列表

- **WHEN** `listTools()` 返回一页
- **THEN** `page.tools[0].name` / `.inputSchema` 可直接访问，不需 `JsonObject` 转换

#### Scenario: 未知内容块

- **WHEN** 服务端返回 `{"type":"audio", ...}`
- **THEN** `CallToolResult.content[0].kind() == "audio"`，`toJson()` 与原 JSON 等价

#### Scenario: 并发版本协商

- **WHEN** 8 个线程同时收到 `-32022`（`supported = ["2026-07-28"]`）
- **THEN** 版本只被改写一次，每个请求最多重试一次

#### Scenario: HTTP 鉴权头

- **WHEN** `McpClientOptions.headers = {"Authorization": "Bearer x"}` 连接 HTTP 端点
- **THEN** 每个请求都带该头

#### Scenario: 自动注入 `_meta`

- **WHEN** 调用 `listTools`
- **THEN** 请求 `params._meta` 含 `protocolVersion`、`clientInfo`、`clientCapabilities`

#### Scenario: 版本重试一次

- **WHEN** 服务端返回 `-32022` 且 `supported` 非空
- **THEN** 客户端换用 `supported[0]` 重试一次；再失败则抛 `McpException`

#### Scenario: 分页聚合

- **WHEN** 服务端分两页返回工具
- **THEN** `listAllTools` 返回两页合并结果；超过轮次上限时抛异常

### Requirement: stdio 客户端

stdio 传输 MUST 复用 `f_jsonrpc` 的消息层（`JsonRpcTransport` + `JsonRpcClient`），MUST NOT 自建请求 / 响应编解码。

stdio 传输 MUST：

1. 每个请求使用 `JsonRpcClient` 分配的单调递增 id；
2. 只把 `id` 匹配的响应交给调用方；
3. 跳过并记录服务端 `notifications/*`；
4. 跳过非 JSON 行并记 WARN（MUST NOT 让一行日志 / banner 变成错误响应或未捕获异常）；
5. 遵守 `McpClientOptions.timeout`：读超时后抛 `IOException`，不永久阻塞；
6. `close()` 关闭 stdin、终止子进程并结束读线程。

#### Scenario: 服务端发通知

- **WHEN** 子进程先输出一条 `notifications/tools/list_changed`，再输出 id 匹配的响应
- **THEN** 客户端忽略通知并返回正确结果

#### Scenario: 多行噪声

- **WHEN** 子进程在响应前输出一行 `starting server...`
- **THEN** 客户端记 WARN 并继续等待匹配 id 的响应

#### Scenario: 读超时

- **WHEN** 子进程不输出任何内容，`timeout = 500ms`
- **THEN** 约 500ms 后抛错，调用线程不被永久阻塞

#### Scenario: id 单调

- **WHEN** 连续调用两次 `callTool`
- **THEN** 两个请求的 JSON-RPC id 分别为 1、2

#### Scenario: 行分帧

- **WHEN** 子进程输出两行 JSON-RPC 响应
- **THEN** 客户端按行解析，不把 stderr 混进响应

### Requirement: `input_required` Auto 多轮

`tools/call` 第二轮及以后 MUST 读取 `params.inputResponses` 与 `params.requestState`，并通过 `McpToolContext` 交给 handler；handler MUST 能读到完整原值。

`CallToolResult` MUST 支持 `requestState`（不透明 JSON），并在 `toJson()` 中原样输出；`inputRequired` 与 `requestState` MUST 在多轮间原样传递。

`McpClient.callToolAuto` MUST 把上一轮响应的 `requestState` 原样带回下一轮请求，MUST 同时带上本轮 `inputResponses`；MUST NOT 解析或修改 `requestState`。

#### Scenario: 第二轮读到回答

- **WHEN** 第一轮 handler 返回 `resultType = "input_required"`，客户端回答后再次调用
- **THEN** 第二轮 handler 的 `ctx.inputResponses` 等于客户端回答

#### Scenario: requestState 透传

- **WHEN** 服务端第一轮返回 `requestState = {"cursor":7}`
- **THEN** 第二轮请求的 `params.requestState` 为 `{"cursor":7}`，且 handler 的 `ctx.requestState` 相同

#### Scenario: 多轮收敛

- **WHEN** 服务端第二轮返回 `complete`
- **THEN** `callToolAuto` 返回该结果，不因缺少 `requestState` 反复触发第一轮

#### Scenario: 两轮完成

- **WHEN** 第一轮返回 `input_required`，handler 给出响应，第二轮返回 `complete`
- **THEN** 返回第二轮结果，且两次请求 id 不同

#### Scenario: 超过轮次

- **WHEN** 每轮都返回 `input_required` 且达到 `maxRounds`
- **THEN** 抛 `McpException`

## ADDED Requirements

### Requirement: 分页游标校验

`McpProtocol.decodeCursor(cursor: String)` MUST 返回 `?Int64`：合法游标返回 `Some(offset)`（空串视为 `0`）；非法（base64 解码失败、无 `offset:` 前缀、非整数、负数、超出上限）MUST 返回 `None`，由调用方转成 `-32602`。`cursor` 字段缺失由调用方直接按 `0` 处理，不进入 `decodeCursor`。

服务端 `tools/list` / `resources/list` / `prompts/list` MUST：

- `cursor` 缺失 → 从 0 开始；
- `cursor` 存在但不是字符串 → `-32602`；
- `cursor` 非法 → `-32602`，`error.data` 含原游标；
- 合法 `offset >= size` → 返回空页，不抛越界。

#### Scenario: 负偏移

- **WHEN** 请求 `cursor = base64("offset:-5")`
- **THEN** 返回 `-32602`，不抛 `IndexOutOfBoundsException`

#### Scenario: 非字符串 cursor

- **WHEN** 请求 `"cursor": 1`
- **THEN** 返回 `-32602`

#### Scenario: 非法游标不退化

- **WHEN** 请求 `cursor = "not-base64"`
- **THEN** 返回 `-32602`，不静默返回首页

#### Scenario: 越界偏移

- **WHEN** 只有 3 个工具，`cursor = base64("offset:99")`
- **THEN** `tools` 为空数组，无 `nextCursor`

### Requirement: 宏注册与注解匹配

`@Mcp` 宏 MUST 按注解**末段名**匹配 `McpToolMeta` / `McpResourceMeta` / `McpPromptMeta`，支持 `@fountain::f_mcp::server::McpToolMeta[...]` 等全限定写法。

`@Mcp` 展开 MUST NOT 在模块加载期调用 `McpRegistry.build()`；构建 MUST 延迟到首次 `McpRegistry.server()`（即首次 HTTP 请求 / controller 实例化）。因此「`@Mcp` 类 + `main()` 里 `McpRegistry.configure(...)`」MUST 可以共存。

同一方法名被重复注册 MUST 在编译期报错（与 `@JsonRpc` 一致），MUST NOT 静默跳过第二个。

#### Scenario: 全限定注解

- **WHEN** 方法标注 `@fountain::f_mcp::server::McpToolMeta[name: 'x']`
- **THEN** 该工具被注册，`tools/list` 可见

#### Scenario: 注解与手工注册共存

- **WHEN** 工程里有一个 `@Mcp` 类，`main()` 里再调用 `McpRegistry.configure({b => b.tool(...)})`
- **THEN** 启动不抛 `McpRegistry is already initialized`，两个来源的工具都出现

#### Scenario: 重复工具名

- **WHEN** `@Mcp` 类里两个方法解析出相同工具名
- **THEN** 编译期报错并指出方法名

### Requirement: 客户端结果模型

`f_mcp.base` MUST 提供以下可从 JSON 还原的模型，供服务端与客户端共用：

- `McpServerInfo`、`McpCapabilities`（保留未知字段）、`DiscoverResult`；
- `McpToolDescriptor`、`ResourceDescriptor`、`PromptDescriptor`、`ToolPage`、`ResourcePage`、`PromptPage`；
- `ReadResourceResult`、`GetPromptResult`、`ListenResult`；
- `ContentBlock.fromJson`、`CallToolResult.fromJson`、`ResourceContent.fromJson`、`PromptMessage.fromJson`。

`CallToolResult` MUST 新增可选 `requestState`；`toJson()` MUST 在 `requestState` 非 `None` 时输出同名字段。

#### Scenario: 往返一致

- **WHEN** 对任意服务端生成的合法结果调用 `fromJson(json)` 再 `toJson()`
- **THEN** 输出与输入语义等价（未知字段允许按模型丢弃，但内容块与结构字段不得丢失）

#### Scenario: 未知能力字段

- **WHEN** 服务端 `capabilities.tools` 新增 `foo: true`
- **THEN** 客户端 `McpCapabilities.toJson()` 仍包含 `foo`
