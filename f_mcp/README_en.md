# f_mcp

`f_mcp` is a client / server SDK for MCP (Model Context Protocol). The message layer is `f_jsonrpc`; this module implements only MCP semantics: version and capabilities, `server/discover`, tools, resources, prompts, subscriptions, rate limiting and large results.

- Protocol version: `2026-07-28` (no handshake; per-request `_meta` validation)
- Server: `/mcp` (JSON-RPC) + `/mcp/sse` (subscriptions)
- Client: HTTP (reuses `JsonRpcClient`) and stdio (subprocess)
- Dependencies: `f_jsonrpc` / `f_data` / `f_log` / `f_mvc` (for the controller)

## Server

```cangjie
import fountain::f_mcp.*
import fountain::f_data.*

main() {
    McpRegistry.configure({b =>
        b.serverInfo('kb-server', '1.0.0')
         .publicBaseUrl('https://mcp.example.com')
         .rateLimit(RateLimitPolicy(perCallerRpm: 120, maxConcurrency: 32))
         .tool(McpTool.builder('kb.search')
             .description('knowledge base search')
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

A `@DataAssist` class can provide the schema directly:

```cangjie
McpTool.of<SearchRequest>('kb.search')
```

### Methods

| Method | Description |
|---|---|
| `server/discover` | versions, capabilities, `serverInfo` |
| `tools/list` / `tools/call` | tool list and calls |
| `resources/list` / `resources/read` | resources (http/https/ftp only) |
| `prompts/list` / `prompts/get` | prompts |
| `subscriptions/listen` | subscribe to notifications (with `/mcp/sse`) |

Legacy methods such as `initialize` return `-32601` with `data.legacyMethod`, telling clients to upgrade.

### Rate limiting

Three layers: global `RateLimitPolicy` → `Builder.rateLimit` → per-tool `ToolRateLimit`. Dimensions: caller / caller×tool / tool token buckets, plus global and per-tool concurrency gates. Over-limit returns `-32050` with `data.scope` in `caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool`.

For multi-instance deployments, inject a shared backend:

```cangjie
b.rateLimitBackend(myRedisBackend)   // implements RateLimitBackend
```

### Large results

Beyond `maxResultBytes` (1 MB by default):

- with `publicBaseUrl`: a single `resource_link`; the content is kept in `ToolResultStore` (256 entries / 256 MB / 10 minutes by default) and readable through `resources/read`
- without: truncate and set `data.truncated = true`

`ToolResultStore` adapts `maxEntries` at runtime per window (reject rate / occupancy; `ResultStoreOptions` exposes `floor` / `ceiling` / thresholds).

### Subscriptions and SSE

`subscriptions/listen` returns a `subscriptionId`; `GET /mcp/sse?topics=tools/list_changed` returns `text/event-stream` where each event is a JSON-RPC notification. Heartbeat every 15 s; connection lives up to 30 minutes.

## Client

```cangjie
let client = McpClient.http('http://127.0.0.1:8080/mcp')
let tools = client.listAllTools()
let result = client.callTool('kb.search', arguments: args)

// input_required auto rounds
let final = client.callToolAuto('kb.search', arguments: args, handler: {input =>
    JsonObject()   // build inputResponses from inputRequired
}, maxRounds: 4)

client.close()
```

stdio:

```cangjie
let client = McpClient.stdio('/usr/local/bin/my-mcp-server', args: ['--stdio'])
```

- Every request injects `_meta` (version, `clientInfo`, `clientCapabilities`)
- On `-32022` the client switches to `supported[0]` and retries once
- `Manual` (`callTool`) passes `input_required` through; `Auto` uses `callToolAuto`

## Testing

```bash
cjpm test
```

Covers discovery, version / legacy, tools / resources / prompts, rate limiting, large results and adaptive storage, subscriptions, SSE framing, stdio line framing, client `_meta` and multi-round.

## Known limitations

- Distributed rate limiting is an SPI plus an in-process implementation; cross-instance counting needs a shared backend
- SSE relies on `f_mvc` streaming; no fboot here, so the HTTP smoke test is pending
- `prompts/list_changed` is not pushed (capability is `false`)
