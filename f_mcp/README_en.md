# f_mcp

`f_mcp` is a client / server SDK for MCP (Model Context Protocol). The message layer is `f_jsonrpc`; this module implements only MCP semantics: version and capabilities, `server/discover`, tools, resources, prompts, subscriptions, rate limiting and results.

- Protocol version: `2026-07-28` (no handshake; per-request `_meta` validation)
- Server: `/mcp` (JSON-RPC) + `/mcp/sse` (subscriptions)
- Client: HTTP (reuses `JsonRpcClient`) and stdio (subprocess)
- Dependencies: `f_jsonrpc` / `f_data` / `f_log` / `f_mvc` (controller), `f_concurrent` (rate limiting), `f_config` (`mcp_rateLimit` / `mcp_version`)

## Package layout

| Package | Contents |
|---------|----------|
| `fountain::f_mcp.base` | `McpProtocol`, `McpException`, content models (`ContentBlock` / `CallToolResult` / `ResourceContent` / `PromptMessage`) |
| `fountain::f_mcp.client` | `McpClient` |
| `fountain::f_mcp.server` | Server, tools / resources / prompts, annotations, rate limiting, results and SSE |
| `fountain::f_mcp.macros` | `@Mcp` macro (separate package) |
| `fountain::f_mcp` | Facade package: `public import`s the three packages above, keeping `import fountain::f_mcp.*` working |

Server-only code can `import fountain::f_mcp.server.*` + `fountain::f_mcp.base.*`, while clients use
`fountain::f_mcp.client.*` + `fountain::f_mcp.base.*`. With the `@Mcp` macro, prefer
`import fountain::f_mcp.*`: the expansion uses `lookup` / `BeanFactory` / `TypeInfo` / `ArrayList` /
`JsonValue` re-exported by the facade.

## Specification version

- **MCP 2026-07-28** ([specification](https://modelcontextprotocol.io/specification/2026-07-28)); only this version is implemented, with no multi-version coexistence
- Message format: **JSON-RPC 2.0**, provided by `f_jsonrpc`
- No handshake: `initialize` / `notifications/initialized` are not implemented; every request carries `io.modelcontextprotocol/protocolVersion`, `clientInfo` and `clientCapabilities` in `params._meta`, and the `server/discover` response returns `serverInfo` in `_meta`
- Discovery: `server/discover`; a version mismatch returns `-32022` with `error.data.supported`
- Methods implemented: `server/discover`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, `prompts/list`, `prompts/get`, `subscriptions/listen`
- Capabilities: `tools.listChanged=false`, `resources.subscribe=false` + `resources.listChanged=false`, `prompts.listChanged=false` (`resources/subscribe` is not implemented, so it is not advertised)
- Transport: `POST /mcp` returns a single JSON response; `GET /mcp/sse` pushes subscription notifications (`text/event-stream`). There is no session id and the server never sends requests
- Not implemented: `sampling` / `roots` / `logging` / `completions` / `resources/templates/list`; asking the client for input uses `tools/call` with `resultType: "input_required"`
- Extensions: `-32050` rate limited, `-32040` resource not found (`-32002` is reserved for f_jsonrpc timeouts), results linked from `/mcp/tool-results/`
- Legacy peers: `initialize` / `notifications/initialized` return `-32601` with `legacyMethod` and `supportedVersion` in `data`; there is no silent downgrade

See [`doc/f_mcp模块设计.md`](doc/f_mcp模块设计.md) for the design rationale.

## Server

```cangjie
import std.collection.ArrayList
import fountain::f_mcp.server.*
import fountain::f_mcp.base.*
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

@Mcp['kb-server']
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
- `@Mcp['kb-server']` or `@Mcp[kbServer]` sets `serverInfo.name` (string literal or identifier); without an attribute the name is `fountain-mcp`
- `serverInfo.version` comes from `mcp_version`, defaulting to `1.0.0`
- **tool**: exactly one parameter, an `@DataAssist[props fields]` class; `inputSchema` comes from that type
- `@McpToolMeta`'s `perCallerRpm` / `perCallerToolRpm` / `perToolRpm` / `maxConcurrency` / `perCallerConcurrency` map directly to `ToolRateLimit`; `0` means unlimited
- **resource**: no parameters; `uri` is required; `mediaType` maps to `McpResource.mimeType`; the `/doc` example needs `mcp_publicBaseUrl`
- **prompt**: the function parameters are the `PromptArgument`s, using the parameter name as `name`; `@McpPromptArg` sets `description` / `required` (default `true`); use `Option<T>` for optional arguments
- an empty `name` falls back to the function name; public functions without these annotations are ignored

`server/discover` reports `serverInfo` like this:

```json
{"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"kb-server","version":"1.0.0"}}}
```

When using the `Builder` directly, pass an empty `version` to `serverInfo(name, version)` to use
`mcp_version`; a non-empty explicit value wins.

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
McpRegistry.getToolMeta<T>(name, argTypes)
McpRegistry.getResourceMeta<T>(name, argTypes)
McpRegistry.getPromptMeta<T>(name, argTypes)
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

Three layers merged field by field: `mcp_rateLimit` config → `Builder.rateLimit` → per-tool `ToolRateLimit`
(fields you omit are inherited; layers are no longer replaced as a whole).

Dimensions: caller / caller×tool / tool, plus service-level global concurrency and per-tool concurrency.

The check order is fixed: global concurrency → tool concurrency → caller concurrency → perCallerRpm →
perCallerToolRpm → perToolRpm. A request rejected by a concurrency gate **does not consume** an rpm token, and an
rpm rejection releases the concurrency slots it already holds. Over-limit returns `-32050` with `data.scope` in
`concurrency` / `concurrency_tool` / `concurrency_caller` / `caller` / `caller_tool` / `tool`; over HTTP the
response is also `429` with `Retry-After`.

The caller identity is derived in this order: first `X-Forwarded-For` entry (trusted only with
`mcp_trustForwardedFor=true` or `Builder.trustForwardedFor(true)`) → first 16 bytes of the SHA-256 of
`Authorization` → `remoteAddr` without the port → `anonymous` (`local` for in-process calls).

Five `RateLimitBackend` implementations are built in, all backed by `f_concurrent` limiters with one limiter per rate-limit key:

| `mcp_rateLimitBackend` | Limiter | Semantics |
|---|---|---|
| `token-bucket` (default) | `TokenBucketRateLimiter` | `rpm` per minute, bursts up to `rpm` |
| `leaking-bucket` | `LeakingBucketRateLimiter` | leaks `rpm` per minute, queue capped at `rpm` |
| `sliding-window` | `SlidingWindowRateLimiter` | 1-minute sliding window, limit `rpm` |
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
- without: truncate on a UTF-8 rune boundary (never splits a CJK character or emoji), keep `isError` /
  `resultType` / `inputRequired` / `requestState`, and set `data.truncated = true` plus `data.limit`

`ToolResultStore` adapts `maxEntries` at runtime per window (reject rate / occupancy; `ResultStoreOptions` exposes `floor` / `ceiling` / thresholds).

### Subscriptions and SSE

`subscriptions/listen` returns a `subscriptionId` and a ready-to-use `sseUrl`; `GET` that URL (`/mcp/sse?subscriptionId=N`) binds the SSE connection to the same subscriber. Each event is a JSON-RPC notification. The `?topics=tools/list_changed` form is also supported (the query string is percent-decoded and trimmed; an explicit `topics=` returns 400 instead of silently subscribing to everything).

- At most 1024 subscribers, 256 queued notifications per subscriber (oldest dropped and counted), and 60 s of
  retention while detached; tune with `McpServerBuilder.maxSubscribers(...)` / `subscriberQueueCapacity(...)` /
  `subscriberDetachedTtl(...)`
- Both a disconnect and the 30-minute cap only detach the subscriber: the same `subscriptionId` can reconnect
  within the grace period
- Heartbeat every 15 s; idle connections block on a condition variable (no 100 ms polling)

## Client

```cangjie
import fountain::f_mcp.client.*
import fountain::f_mcp.base.*
import fountain::f_data.*

let client = McpClient.http('http://127.0.0.1:8080/mcp')
let sub = client.listen(['tools/list_changed'])
let sseUrl = sub.sseUrl
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
- On `-32022` the client switches to `supported[0]` and retries once; the version is guarded by a `Mutex`, so
  concurrent hits rewrite it only once
- `Manual` (`callTool`) passes `input_required` through; `Auto` uses `callToolAuto`, forwarding `requestState`
  into the next round

The client returns strongly typed models (all from `f_mcp.base`), so fields are directly accessible; use
`.toJson()` (or `DiscoverResult.raw` / `McpToolDescriptor.raw`) when you need the wire form:

| Method | Returns |
|---|---|
| `discover` | `DiscoverResult` |
| `listTools` | `ToolPage` |
| `listAllTools` | `Array<McpToolDescriptor>` |
| `callTool` / `callToolAuto` | `CallToolResult` (source-compatible alias `McpCallToolResult`) |
| `listResources` | `ResourcePage` |
| `readResource` | `ReadResourceResult` |
| `listPrompts` | `PromptPage` |
| `getPrompt` | `GetPromptResult` |
| `listen` | `ListenResult` |

`CallToolResult.content` holds `ContentBlock` values; unknown block types are preserved (`kind()` returns the
server-side `type`, `toJson()` restores it).

### Client options

```cangjie
let options = McpClientOptions()
options.timeout = Duration.second * 10            // default 30s
options.headers.add('Authorization', 'Bearer x')  // HTTP only; ignored by stdio
options.maxResponseBytes = 4 * 1024 * 1024        // HTTP only; 8 MiB by default
options.keepAlive = false                         // HTTP only; false sends Connection: close
options.retryOnConnectFailure = 2                 // connect failures only; 0 by default
let client = McpClient.http('http://127.0.0.1:8080/mcp', options: options)
```

HTTP and stdio share the `f_jsonrpc.JsonRpcClient` message layer (monotonic ids, response id matching, error
mapping); stdio ignores `headers` / `keepAlive` / `maxResponseBytes` and uses `timeout` as the read timeout.


## Migration (1.3.17 → next)

| Change | Impact | Migration |
|---|---|---|
| `RESOURCE_NOT_FOUND` moves from `-32002` to `-32040` | Clients branching on the code | Check `-32040` |
| `decodeCursor` returns `?Int64` | Code using the old value | Handle `None` → `-32602` |
| `mcp_rateLimitBackend=any-moment` removed | Config referencing it fails at startup | Use `token-bucket` / `sliding-window` |
| `ToolRateLimit.maxConcurrency` semantics | It used to act as the global cap | Use `RateLimitPolicy.maxConcurrency` for the global cap |
| `@McpToolMeta` numeric default `0` → `-1` | An explicit `0` means "unlimited" now | Omit the field to inherit |
| Stricter `mcp_rateLimit` validation | Invalid config fails at startup | Fix the config as the error message says |
| MCP client returns strongly typed models | Code relying on `JsonObject` indexing | Use model fields (e.g. `page.tools[0].name`) or `.toJson()` / `.raw` |
| `McpCallToolResult.content` elements are `ContentBlock` | Code reading `text` via array indexing | Use `content[0].toJson()['text']` or `kind()` |

## Testing

```bash
cjpm test
```

Tests are split by package: `client` covers the HTTP / stdio clients, `_meta` injection and multi-round
calls, while `server` covers discovery, version / legacy handling, tools / resources / prompts, rate
limiting, results and adaptive storage, subscriptions and SSE framing.

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
