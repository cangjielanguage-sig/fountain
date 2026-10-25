# f_mcp

`f_mcp` is a client / server SDK for MCP (Model Context Protocol). The message layer is `f_jsonrpc`; this module implements only MCP semantics: version and capabilities, `server/discover`, tools, resources, prompts, subscriptions, rate limiting and results.

- Protocol version: `2026-07-28` (no handshake; per-request `_meta` validation)
- Server: `/mcp` (JSON-RPC) + `/mcp/sse` (subscriptions)
- Client: HTTP (reuses `JsonRpcClient`) and stdio (subprocess)
- Dependencies: `f_jsonrpc` / `f_data` / `f_log` / `f_mvc` (controller), `f_concurrent` (rate limiting), `f_config` (`mcp_rateLimit`)

## Specification version

- **MCP 2026-07-28** ([specification](https://modelcontextprotocol.io/specification/2026-07-28)); only this version is implemented, with no multi-version coexistence
- Message format: **JSON-RPC 2.0**, provided by `f_jsonrpc`
- No handshake: `initialize` / `notifications/initialized` are not implemented; every request carries `io.modelcontextprotocol/protocolVersion`, `clientInfo` and `clientCapabilities` in `params._meta`, and the `server/discover` response returns `serverInfo` in `_meta`
- Discovery: `server/discover`; a version mismatch returns `-32022` with `error.data.supported`
- Methods implemented: `server/discover`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, `prompts/list`, `prompts/get`, `subscriptions/listen`
- Capabilities: `tools.listChanged=false`, `resources.subscribe=true` + `resources.listChanged=false`, `prompts.listChanged=false`
- Transport: `POST /mcp` returns a single JSON response; `GET /mcp/sse` pushes subscription notifications (`text/event-stream`). There is no session id and the server never sends requests
- Not implemented: `sampling` / `roots` / `logging` / `completions` / `resources/templates/list`; asking the client for input uses `tools/call` with `resultType: "input_required"`
- Extensions: `-32050` rate limited, `-32002` resource not found, results linked from `/mcp/tool-results/`
- Legacy peers: `initialize` / `notifications/initialized` return `-32601` with `legacyMethod` and `supportedVersion` in `data`; there is no silent downgrade

See [`doc/f_mcp模块设计.md`](doc/f_mcp模块设计.md) for the design rationale.

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
         .resource(McpResource.builder('/doc', 'doc')
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

### Register with annotations (`@Mcp`)

```cangjie
import fountain::f_mcp.*
import fountain::f_mcp.macros.*
import fountain::f_data.*
import fountain::f_data.macros.*

@DataAssist[props fields]
public class SearchRequest {
    public var query: String = ''

    public init() {}
}

@DataAssist[props fields]
public class SearchResult {
    public var total: Int64 = 0
    public var summary: String = ''

    public init() {}

    public init(total: Int64, summary: String) {
        this.total = total
        this.summary = summary
    }
}

@Mcp
public class KnowledgeService {
    public init() {}

    @McpToolMeta[name: 'kb.search', description: 'knowledge base search']
    public func search(req: SearchRequest): SearchResult {
        SearchResult(1, 'found: ${req.query}')
    }

    @McpResourceMeta[uri: '/doc', name: 'doc', description: 'docs', mediaType: 'text/plain']
    public func doc(): ArrayList<ResourceContent> {
        // return a list of ResourceContent
    }

    @McpPromptMeta[name: 'greet', description: 'build a greeting']
    public func greet(name: String, @McpPromptArg[description: 'name'] title: String): ArrayList<PromptMessage> {
        // return a list of PromptMessage
    }
}
```

- `@Mcp` adds `@Bean`, registers everything at module load, then calls `McpRegistry.build()`; use one `@Mcp` class per process
- **tool**: exactly one parameter, an `@DataAssist[props fields]` class; `inputSchema` comes from that type
- **resource**: no parameters; `uri` is required; `mediaType` maps to `McpResource.mimeType`; the `/doc` example needs `mcp_publicBaseUrl`
- **prompt**: the function parameters are the `PromptArgument`s, using the parameter name as `name`; `@McpPromptArg` sets `description` / `required` (default `true`); use `Option<T>` for optional arguments
- an empty `name` falls back to the function name; public functions without these annotations are ignored

#### Argument and result conversion

Arguments are converted from JSON with `f_data`'s `fromJson` rules, and results are converted with
`toJson` (`McpConvert`), so methods can return business objects directly:

| Function | Return value | Result |
|----------|--------------|--------|
| tool | `CallToolResult` | used as is |
| tool | `String` | text content |
| tool | any other JSON-convertible value | JSON text, also written to `structuredContent` when it is an object |
| tool | `Unit` | empty content |
| resource | `ArrayList<ResourceContent>` | used as is |
| resource | `String` | one `text/plain` content |
| resource | any other JSON-convertible value | one `application/json` content |
| resource | `Unit` | one empty text content |
| prompt | `ArrayList<PromptMessage>` | used as is |
| prompt | `String` / any other JSON-convertible value | one `user` message |
| prompt | `Unit` | no messages |

A non-empty `mediaType` in `@McpResourceMeta` overrides the content `mimeType`.

The registry APIs are also available directly:

```cangjie
McpRegistry.getToolMeta<T, R>(name, argTypes)
McpRegistry.getResourceMeta<T, R>(name, argTypes, fn)
McpRegistry.getPromptMeta<T, R>(name, argTypes, fn)
McpRegistry.build()
```

### Public base URL and resource URIs

`publicBaseUrl` is the public root of this server, used to build absolute URLs.

#### Configuration

`Builder` wins over the configuration key:

```cangjie
b.publicBaseUrl('https://mcp.example.com')
```

```bash
export mcp_publicBaseUrl=https://mcp.example.com
```

Both strip trailing `/`; an empty value means unset.

It affects three places:

- result links: `${publicBaseUrl}/mcp/tool-results/{token}`
- the `sseUrl` returned by `subscriptions/listen`
- relative URI resolution for `McpResource.builder`

#### The `McpResource.builder` uri

The first argument accepts two forms:

| Input | Result |
|---|---|
| `/doc` | `${publicBaseUrl}/doc` |
| `https://docs.example.com/doc` | used verbatim, no prefix |

```cangjie
// relative path: requires publicBaseUrl
McpResource.builder('/doc', 'doc')

// full URL: independent of publicBaseUrl
McpResource.builder('https://docs.example.com/doc', 'doc')
```

`//example.com/doc`, `file://`, a relative path without `/`, and URIs containing `#fragment` throw `McpException` at build time.

Without `publicBaseUrl`: results are truncated, `sseUrl` is relative, and `McpResource.builder('/doc', ...)` throws `McpException` when the server is built.

### Methods

| Method | Description |
|---|---|
| `server/discover` | versions, capabilities, `serverInfo` |
| `tools/list` / `tools/call` | tool list and calls |
| `resources/list` / `resources/read` | resources (full http/https/ftp URL, or a path starting with `/`) |
| `prompts/list` / `prompts/get` | prompts |
| `subscriptions/listen` | subscribe to notifications (with `/mcp/sse`) |

Legacy methods such as `initialize` return `-32601` with `data.legacyMethod`, telling clients to upgrade.

### Rate limiting

Three layers: global `RateLimitPolicy` → `Builder.rateLimit` → per-tool `ToolRateLimit`. Dimensions: caller / caller×tool / tool, plus global and per-tool concurrency gates. Over-limit returns `-32050` with `data.scope` in `caller` / `caller_tool` / `tool` / `concurrency` / `concurrency_tool`.

Five `RateLimitBackend` implementations are built in, all backed by `f_concurrent` limiters with one limiter per rate-limit key:

| `mcp_rateLimitBackend` | Limiter | Semantics |
|---|---|---|
| `token-bucket` (default) | `TokenBucketRateLimiter` | `rpm` per minute, bursts up to `rpm` |
| `leaking-bucket` | `LeakingBucketRateLimiter` | leaks `rpm` per minute, queue capped at `rpm` |
| `sliding-window` | `SlidingWindowRateLimiter` | 1-minute sliding window, limit `rpm` |
| `any-moment` | `AnyMomentRateLimiter` | `rpm` as an instantaneous concurrency cap, not a per-minute quota |
| `unlimited` | `UnlimitedRateLimiter` | no limiting |

An explicit `Builder.rateLimitBackend(...)` wins over configuration. Names are case-insensitive and ignore `-` / `_`; an unknown name throws `IllegalArgumentException` at `build()`.

#### `RateLimitBackend` and `RateLimitBackends`

`RateLimitBackend` is the rate-limit algorithm SPI; the five built-in implementations are registered in `RateLimitBackends` at module load:

```cangjie
public interface RateLimitBackend {
    static prop name: String              // algorithm name, also the registry key
    static func new(): RateLimitBackend   // create an instance
    func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool
    func close(): Unit                    // called by McpServer.close()
}
```

A custom implementation:

```cangjie
public class MyRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() { 'my-algo' }
    }

    public static func new(): RateLimitBackend {
        MyRateLimitBackend()
    }

    public func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool {
        // key is already scoped: c: / ct: / t:
        // rpm <= 0 means unlimited
        true
    }

    public func close(): Unit {}
}
```

Register and use it:

```cangjie
// 1. register; the same name overrides the built-in implementation
RateLimitBackends.register<MyRateLimitBackend>()

// 2a. select through configuration: export mcp_rateLimitBackend=my-algo
// 2b. or inject directly
let server = McpServer.builder()
    .rateLimitBackend(RateLimitBackends.of('my-algo'))
    .build()
```

`RateLimitBackends.of(name)` creates an instance by name and throws `IllegalArgumentException` when unregistered. Names are case-insensitive and ignore `-` / `_`.

The global default comes from `mcp_rateLimit` and `mcp_rateLimitBackend`:

```bash
# perCallerRpm,perCallerToolRpm,perToolRpm,maxConcurrency,perCallerConcurrency
export mcp_rateLimit=600,120,6000,64,8

# or JSON; omitted fields mean unlimited
export mcp_rateLimit='{"perCallerRpm":600,"perCallerToolRpm":120,"perToolRpm":6000}'

# rate-limit algorithm
export mcp_rateLimitBackend=sliding-window
```

**Cross-process limiting**: `f_concurrent` limiters are process-local. Implement `RateLimitBackend` against shared storage and inject it:

```cangjie
b.rateLimitBackend(myRedisBackend)   // shared by all instances
```

The `key` passed to `tryAcquire(key, rpm, nowNanos)` is already scoped (`c:` / `ct:` / `t:`), so it can be used directly as a Redis key. Use `INCR` + `EXPIRE 60` for a fixed window, a Lua script for a token bucket, or a row lock / `UPDATE ... RETURNING` in a database. f_mcp does not bundle a Redis client, so it stays storage-agnostic.

Concurrency gates (`maxConcurrency` / `perCallerConcurrency`) remain process-local; a cross-instance concurrency cap needs a gateway or a shared semaphore.

### Results

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

Covers discovery, version / legacy, tools / resources / prompts, rate limiting, results and adaptive storage, subscriptions, SSE framing, stdio line framing, client `_meta` and multi-round.

## Known limitations

- Distributed rate limiting ships a `RateLimitBackend` SPI; the default implementation is a process-local `f_concurrent` token bucket, so cross-instance counting needs a shared backend
- SSE relies on `f_mvc` streaming and must declare `Transfer-Encoding: chunked`; end-to-end coverage lives in `fmcpdemo/boot.sh e2e`
- `prompts/list_changed` is not pushed (capability is `false`)

## End-to-end demo

`fmcpdemo` contains a runnable server / client:

```bash
cd fmcpdemo
./boot.sh e2e 18082
```

The client covers `server/discover`, `tools/list`, `tools/call`, `resources/read` and `prompts/get` over HTTP, then subscribes to `/mcp/sse` and triggers a `notifications/tools/list_changed` event. At startup the server also builds two `McpServer` instances sharing one `RateLimitBackend` and asserts the 4th call returns `-32050`.
