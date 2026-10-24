# f_mcp

`f_mcp` 是 MCP（Model Context Protocol）的客户端 / 服务端 SDK。消息层完全复用 `f_jsonrpc`，本模块只实现 MCP 语义：版本与能力、`server/discover`、工具、资源、提示词、订阅、限流与大结果处理。

- 协议版本：`2026-07-28`（无握手；逐请求 `_meta` 校验）
- 服务端：`/mcp`（JSON-RPC）+ `/mcp/sse`（订阅推送）
- 客户端：HTTP（复用 `JsonRpcClient`）与 stdio（子进程）
- 依赖：`f_jsonrpc` / `f_data` / `f_log` / `f_mvc`（controller 需要）

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

三层：全局 `RateLimitPolicy` → `Builder.rateLimit` → 每工具 `ToolRateLimit`。维度：调用方 / 调用方×工具 / 工具全局的令牌桶，加上全局总并发与工具子并发。超限返回 `-32050`，`data.scope` 为 `caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool`。

多实例部署可注入共享后端：

```cangjie
b.rateLimitBackend(myRedisBackend)   // 实现 RateLimitBackend
```

### 大结果

超过 `maxResultBytes`（默认 1 MB）时：

- 配了 `publicBaseUrl`：转成一个 `resource_link`，内容存 `ToolResultStore`（默认 256 条 / 256 MB / 10 分钟），可通过 `resources/read` 读回
- 没配：截断并标记 `data.truncated = true`

`ToolResultStore` 默认开启运行期自适应调容：按窗口统计拒绝率与占用率，只调 `maxEntries`（`ResultStoreOptions` 可配 `floor` / `ceiling` / 阈值 / 窗口）。

### 订阅与 SSE

`subscriptions/listen` 返回 `subscriptionId`；`GET /mcp/sse?topics=tools/list_changed` 返回 `text/event-stream`，每条事件是一个 JSON-RPC 通知。心跳 15 秒，连接最长 30 分钟。

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

- 分布式限流只提供 SPI + 进程内实现，跨实例需要注入共享存储后端
- SSE 依赖 `f_mvc` 的流式响应；本机没有 fboot，HTTP 端到端冒烟未跑
- 不做 `prompts/list_changed` 推送（能力里固定 `false`）
