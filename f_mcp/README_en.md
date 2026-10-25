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

Three layers: global `RateLimitPolicy` → `Builder.rateLimit` → per-tool `ToolRateLimit`. Dimensions: caller / caller×tool / tool, plus global and per-tool concurrency gates. Over-limit returns `-32050` with `data.scope` in `caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool`.

The single-instance default uses `f_concurrent.TokenBucketRateLimiter`, one bucket per rate-limit key. The global default can come from `mcp_rateLimit` (an explicit `Builder.rateLimit()` wins):

```bash
# perCallerRpm,perCallerToolRpm,perToolRpm,maxConcurrency,perCallerConcurrency
export mcp_rateLimit=600,120,6000,64,8

# or JSON; omitted fields mean unlimited
export mcp_rateLimit='{"perCallerRpm":600,"perCallerToolRpm":120,"perToolRpm":6000}'
```

**Cross-process limiting**: `f_concurrent` limiters are process-local. Implement `RateLimitBackend` against shared storage and inject it:

```cangjie
b.rateLimitBackend(myRedisBackend)   // shared by all instances
```

The `key` passed to `tryAcquire(key, rpm, nowNanos)` is already scoped (`c:` / `ct:` / `t:`), so it can be used directly as a Redis key. Use `INCR` + `EXPIRE 60` for a fixed window, a Lua script for a token bucket, or a row lock / `UPDATE ... RETURNING` in a database. f_mcp does not bundle a Redis client, so it stays storage-agnostic.

Concurrency gates (`maxConcurrency` / `perCallerConcurrency`) remain process-local; a cross-instance concurrency cap needs a gateway or a shared semaphore.

### Large results

Beyond `maxResultBytes` (1 MB by default):

- with `publicBaseUrl`: a single `resource_link`; the content is kept in `ToolResultStore` (256 entries / 256 MB / 10 minutes by default) and readable through `resources/read`
- without: truncate and set `data.truncated = true`

`ToolResultStore` adapts `maxEntries` at runtime per window (reject rate / occupancy; `ResultStoreOptions` exposes `floor` / `ceiling` / thresholds).

### Subscriptions and SSE

`subscriptions/listen` returns a `subscriptionId` and a ready-to-use `sseUrl`; `GET` that URL (`/mcp/sse?subscriptionId=N`) binds the SSE connection to the same subscriber. Each event is a JSON-RPC notification. The legacy `?topics=tools/list_changed` form still works. Heartbeat every 15 s; connection lives up to 30 minutes.

## Client

```cangjie
let client = McpClient.http('http://127.0.0.1:8080/mcp')
let sub = client.listen(['tools/list_changed'])
let sseUrl = sub['sseUrl'].asString().value
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

## End-to-end demo

`fmcpdemo` contains a runnable server / client:

```bash
cd fmcpdemo
./boot.sh e2e 18082
```

The client covers `server/discover`, `tools/list`, `tools/call`, `resources/read` and `prompts/get` over HTTP, then subscribes to `/mcp/sse` and triggers a `notifications/tools/list_changed` event. At startup the server also builds two `McpServer` instances sharing one `RateLimitBackend` and asserts the 4th call returns `-32050`.
