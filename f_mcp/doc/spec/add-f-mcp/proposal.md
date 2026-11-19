# Proposal

## Why

MCP 的消息层就是 JSON-RPC 2.0，`f_jsonrpc` 已经提供了消息模型、方法表、错误码与客户端传输。缺的是 MCP 的语义层：每请求的协议版本与能力、`server/discover`、`tools/*`、`resources/*`、内容块、分页，以及服务端必须实现的参数校验、限流与大结果处理。

没有这一层，每个要暴露 LLM 工具的服务都要把 MCP 的版本校验、能力声明、工具表、内容块和错误语义重写一遍，而且很容易在「声明了能力却没有实现」「工具名不合法」「大结果打爆内存」这些地方出错。

## What Changes

- **实现模块 `f_mcp`**（仓颉动态链接库，路径依赖 `../f_jsonrpc`、`../f_data`、`../f_log`）：
  - **服务端**：`McpServer` + Builder、工具表、资源表、能力声明、`server/discover`、`tools/list`、`tools/call`（单轮）、`resources/list`、`resources/read`；`build()` 时校验工具名 / schema / URI / 重复注册
  - **版本**：对齐 `2026-07-28`（无握手），逐请求校验 `_meta` 协议版本；不支持返回 `-32022` + `supported`；legacy 方法（`initialize` 等）返回带升级提示的 `-32601`
  - **内容块**：`text` / `image` / `audio` / `resource` / `resource_link`；`structuredContent` 同时写一个 text 块
  - **分页**：`cursor` 不透明字符串，`tools/list` 按名字、`resources/list` 按 URI 确定性排序
  - **限流**：三层配置（全局 / 服务级 / 每工具覆盖）、调用方 / 调用方×工具 / 工具全局令牌桶、全局与工具子并发闸门；超限 `-32050` + `data.scope`
  - **大结果**：超过 `maxResultBytes`（默认 1 MB）转单个 `resource_link`，临时结果存 `ToolResultStore`（256 条 / 256 MB / 10 分钟，CAS 字节预算，惰性回收）；未配 `publicBaseUrl` 时截断并标记 `data.truncated`
  - **客户端**：`McpClient.http`（复用 `f_jsonrpc.JsonRpcClient`），自动注入 `_meta`、`discover`、`listTools` / `listAllTools`、`callTool`、`listResources` / `readResource`；`-32022` 只重试一次；legacy 服务端给出升级提示
  - **部署形态**：`@Controller` 挂在 `/mcp`，由 `fboot run` 加载动态库
- 设计文档迁入 `f_mcp/doc/`；`.modules` 已登记
- **本轮追加（用户要求）**：stdio 客户端传输、`input_required` 的 `Auto` 多轮、`ToolResultStore` 运行期自适应调容、SSE / `subscriptions/listen`、`prompts`、分布式限流

## Capabilities

### New Capabilities

- `mcp`: MCP 2026-07-28 的协议语义——版本与 `_meta`、能力声明、`server/discover`、工具与资源方法、内容块、分页、legacy 提示、客户端
- `mcp-guardrails`: 服务端护栏——三层限流与并发闸门、限流错误语义、大结果转 `resource_link` / 截断、临时结果存储

### Modified Capabilities

无（`f_jsonrpc` / `f_mvc` 的既有行为不变）

## Impact

- **新增代码**：`f_mcp/src/**`（协议常量、服务端、工具/资源、内容块、限流、结果存储、客户端、controller）与同包测试
- **依赖**：`f_jsonrpc`（消息层与 HTTP 客户端）、`f_data`（JsonSchema / JsonValue）、`f_log`（日志）；不新增第三方依赖
- **运行期**：动态库 + `fboot run`；`/mcp` 路由在 `static init` 注册（必须在 `MVCStarter.initialize()` 之前）
- **兼容性**：只实现 `2026-07-28`，不实现 legacy 握手；旧版对端会收到明确的升级提示
- **已知偏差**：协议层限流错误沿用 `f_jsonrpc` 的「协议错误 HTTP 200」约定，`-32050` 不额外映射 429（design 记录）
