# f_mcp

`f_mcp` 是 MCP（Model Context Protocol）的客户端 / 服务端 SDK。消息层完全复用 `f_jsonrpc`，本模块只实现 MCP 语义：版本与能力、`server/discover`、工具、资源、提示词、订阅、限流与大结果处理。

- 协议版本：`2026-07-28`（无握手；逐请求 `_meta` 校验）
- 服务端：`/mcp`（JSON-RPC）+ `/mcp/sse`（订阅推送）
- 客户端：HTTP（复用 `JsonRpcClient`）与 stdio（子进程）
- 依赖：`f_jsonrpc` / `f_data` / `f_log` / `f_mvc`（controller）、`f_concurrent`（限流）、`f_config`（`mcp_rateLimit`）

## 规范版本

- **MCP 2026-07-28**（[规范](https://modelcontextprotocol.io/specification/2026-07-28)），只实现这一版，不做多版本共存
- 消息格式：**JSON-RPC 2.0**，消息层由 `f_jsonrpc` 提供
- 无握手：不实现 `initialize` / `notifications/initialized`；每个请求在 `params._meta` 携带 `io.modelcontextprotocol/protocolVersion`、`clientInfo`、`clientCapabilities`，`server/discover` 的响应 `_meta` 回 `serverInfo`
- 发现：`server/discover`；版本不匹配返回 `-32022`，`error.data.supported` 给出支持列表
- 已实现方法：`server/discover`、`tools/list`、`tools/call`、`resources/list`、`resources/read`、`prompts/list`、`prompts/get`、`subscriptions/listen`
- 能力声明：`tools.listChanged=false`、`resources.subscribe=true` + `resources.listChanged=false`、`prompts.listChanged=false`
- 传输：`POST /mcp` 返回单个 JSON 响应，`GET /mcp/sse` 推送订阅通知（`text/event-stream`）；无会话 id，服务端不主动发请求
- 未实现：`sampling` / `roots` / `logging` / `completions` / `resources/templates/list`；需要向客户端索取信息的场景走 `tools/call` 的 `resultType: "input_required"`
- 扩展：`-32050` 限流、`-32002` 资源不存在、大结果外链 `/mcp/tool-results/`
- legacy 对端：`initialize` / `notifications/initialized` 返回 `-32601`，`data` 带 `legacyMethod` 与 `supportedVersion`，不静默降级

设计取舍见 [`doc/f_mcp模块设计.md`](doc/f_mcp模块设计.md)。

## 服务端

```cangjie
import fountain::f_mcp.*
import fountain::f_data.*

main() {
    McpRegistry.configure({b =>
        b.serverInfo('kb-server', '1.0.0')
         .publicBaseUrl('https://mcp.example.com')
         .rateLimit(RateLimitPolicy(perCallerRpm: 120, maxConcurrency: 32))
         .tool(McpTool.builder('kb.search')
             .description('知识库检索')
             .inputSchema(schema)
             .handler({ctx, args => CallToolResult.text('found')})
             .build())
         .resource(McpResource.builder('https://example.com/doc', 'doc')
             .handler({ctx =>
                 let list = ArrayList<ResourceContent>()
                 list.add(ResourceContent(ctx.uri, Some('text/plain'), Some('content'), None))
                 list
             }).build())
         .prompt(McpPrompt.builder('greet')
             .argument('name', required: true)
             .handler({args => /* ArrayList<PromptMessage> */})
             .build())
    })
}
```

字段（`@DataAssist` 类）可以直接生成 schema：

```cangjie
McpTool.of<SearchRequest>('kb.search')
```

### 方法

| 方法 | 说明 |
|---|---|
| `server/discover` | 版本、能力、`serverInfo` |
| `tools/list` / `tools/call` | 工具表与调用 |
| `resources/list` / `resources/read` | 资源（URI 只接受 http/https/ftp） |
| `prompts/list` / `prompts/get` | 提示词 |
| `subscriptions/listen` | 订阅通知（配合 `/mcp/sse`） |

`initialize` 等 legacy 方法返回 `-32601` + `data.legacyMethod`，提示客户端升级。

### 限流

三层：全局 `RateLimitPolicy` → `Builder.rateLimit` → 每工具 `ToolRateLimit`。维度：调用方 / 调用方×工具 / 工具全局，加上全局总并发与工具子并发。超限返回 `-32050`，`data.scope` 为 `caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool`。

单实例默认用 `f_concurrent.TokenBucketRateLimiter`，每个限流 key 一个令牌桶。全局默认值可由配置项 `mcp_rateLimit` 提供（`Builder.rateLimit()` 优先）：

```bash
# perCallerRpm,perCallerToolRpm,perToolRpm,maxConcurrency,perCallerConcurrency
export mcp_rateLimit=600,120,6000,64,8

# 或 JSON，省略的字段表示不限制
export mcp_rateLimit='{"perCallerRpm":600,"perCallerToolRpm":120,"perToolRpm":6000}'
```

**跨进程限流**：`f_concurrent` 的限流器是进程内的，不能直接跨进程。需要实现 `RateLimitBackend` 并注入：

```cangjie
b.rateLimitBackend(myRedisBackend)   // 多实例共享同一个 Redis / 数据库
```

`tryAcquire(key, rpm, nowNanos)` 的 `key` 已经带了作用域前缀（`c:` / `ct:` / `t:`），可以直接作为共享存储的键。Redis 可用 `INCR key` + `EXPIRE 60` 做固定窗口，或用 Lua 脚本做令牌桶；数据库可用单行 `UPDATE ... RETURNING` / 行锁。f_mcp 不内置 Redis 客户端，避免绑定具体存储。

并发闸门（`maxConcurrency` / `perCallerConcurrency`）仍是进程内的；跨实例的全局并发需要网关或独立的共享信号量。

### 大结果

超过 `maxResultBytes`（默认 1 MB）时：

- 配了 `publicBaseUrl`：转成一个 `resource_link`，内容存 `ToolResultStore`（默认 256 条 / 256 MB / 10 分钟），可通过 `resources/read` 读回
- 没配：截断并标记 `data.truncated = true`

`ToolResultStore` 默认开启运行期自适应调容：按窗口统计拒绝率与占用率，只调 `maxEntries`（`ResultStoreOptions` 可配 `floor` / `ceiling` / 阈值 / 窗口）。

### 订阅与 SSE

`subscriptions/listen` 返回 `subscriptionId` 和可直接连接的 `sseUrl`；`GET` 该 URL（`/mcp/sse?subscriptionId=N`）会绑定到同一个订阅者，每条事件是一个 JSON-RPC 通知。也兼容 `?topics=tools/list_changed` 的旧用法。心跳 15 秒，连接最长 30 分钟；响应使用 `Transfer-Encoding: chunked`（长度未知的流）。

客户端可直接用 `McpClient.listen(topics)` 获取订阅结果：

```cangjie
let sub = client.listen(['tools/list_changed'])
let sseUrl = sub['sseUrl'].asString().value
```

## 客户端

```cangjie
let client = McpClient.http('http://127.0.0.1:8080/mcp')
let tools = client.listAllTools()
let result = client.callTool('kb.search', arguments: args)

// input_required 自动多轮
let final = client.callToolAuto('kb.search', arguments: args, handler: {input =>
    JsonObject()   // 由调用方根据 inputRequired 生成 inputResponses
}, maxRounds: 4)

client.close()
```

stdio：

```cangjie
let client = McpClient.stdio('/usr/local/bin/my-mcp-server', args: ['--stdio'])
```

- 每次请求自动注入 `_meta`（版本、`clientInfo`、`clientCapabilities`）
- 服务端返回 `-32022` 时换用 `supported[0]` 只重试一次
- `Manual`（`callTool`）原样返回 `input_required`；`Auto` 用 `callToolAuto`

## 测试

```bash
cjpm test
```

覆盖协议发现、版本 / legacy、工具 / 资源 / prompts、限流、大结果与自适应存储、订阅、SSE 格式、stdio 行分帧、客户端 `_meta` 与多轮。

## 已知限制

- 分布式限流提供 `RateLimitBackend` SPI；默认实现基于 `f_concurrent` 令牌桶，仍是进程内，跨实例需注入共享存储后端
- SSE 依赖 `f_mvc` 的流式响应，并且必须声明 `Transfer-Encoding: chunked`；端到端由 `fmcpdemo/boot.sh e2e` 覆盖
- 不做 `prompts/list_changed` 推送（能力里固定 `false`）

## 端到端 demo

`fmcpdemo` 提供可运行的 server / client：

```bash
cd fmcpdemo
./boot.sh e2e 18082
```

客户端走 HTTP 覆盖 `server/discover`、`tools/list`、`tools/call`、`resources/read`、`prompts/get`，再订阅 `/mcp/sse` 并触发一条 `notifications/tools/list_changed`。服务端启动时还会用两个共享 `RateLimitBackend` 的 `McpServer` 验证第 4 次调用返回 `-32050`。
