# f_jsonrpc

`f_jsonrpc` provides **JSON-RPC 2.0 over HTTP** on top of `f_mvc`, for both server and client. It adds only what `f_mvc` lacks: the JSON-RPC message model, a runtime method table, and the error model. Routing, authentication, thread pools, logging and exception handling all come from `f_mvc`.

- One JSON-RPC endpoint = one `f_mvc` route (`RequestMeta`); `method` is dispatched inside the request body
- Single requests, batches, notifications, topic namespaces, per-method timeouts and JSON Schema validation
- No `f_mvc` API change (`@JsonRpcMapping` is a `RequestMapping` subclass)

## Package layout

| Package | Contents |
|---------|----------|
| `fountain::f_jsonrpc.base` | Protocol constants, error model, method metadata annotation |
| `fountain::f_jsonrpc.client` | `JsonRpcClient` / `ClientOptions` |
| `fountain::f_jsonrpc.server` | `JsonRpcServer`, method table, `f_mvc` routes and argument conversion |
| `fountain::f_jsonrpc.macros` | `@JsonRpc` macro (separate package) |
| `fountain::f_jsonrpc` | Facade package: `public import`s the three packages above, keeping `import fountain::f_jsonrpc.*` working |

Client-only code can `import fountain::f_jsonrpc.client.*` and server-only code can
`import fountain::f_jsonrpc.server.*`; both share `base`. The module dependency is still `fountain::f_jsonrpc`.

With the `@JsonRpc` macro, prefer `import fountain::f_jsonrpc.*`: the expansion uses `lookup` /
`BeanFactory` / `TypeInfo` re-exported by the facade. If you import only `server` / `base`, add those
three symbols yourself.

## Specification version

- **JSON-RPC 2.0** ([specification](https://www.jsonrpc.org/specification), published 2013-01-04)
- Transport: HTTP(S) `POST` with `application/json`, UTF-8
- Implemented: requests / responses, batches, notifications (no response when `id` is absent), positional and named parameters, `id` echoed verbatim (string / number / `null`), standard errors `-32700` / `-32600` / `-32601` / `-32602` / `-32603`
- Extensions: `-32001 ~ -32004` are reserved by this module and `-32020 ~ -32099` are left for applications; `/rpc/{topic}` is a path-level namespace extension and does not change the message format
- Differences from the specification: protocol errors always return HTTP 200 (413 when the request body is too large) with the error in the response body; HTTP POST is the only transport (no GET / SSE / WebSocket)
- A single parameter is written as `[value]` or `{"name": value}` per the specification; bare scalars are rejected

## Dependencies

```toml
[dependencies]
  "fountain::f_bean" = {path = "../f_bean"}
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_log" = {path = "../f_log"}
  "fountain::f_macros" = {path = "../f_macros"}
  "fountain::f_mvc" = {path = "../f_mvc"}
```

## Server

### 1. Register methods

```cangjie
package demo

import fountain::f_jsonrpc.server.*
import fountain::f_data.*

main() {
    JsonRpcRegistry.register(JsonRpcMethodMeta(
        name: 'kb.search',
        handler: {ctx, params =>
            JsonString('found')
        },
        description: 'knowledge base search',
        timeout: Duration.second * 5
    ))
}
```

The part before the first `.` in a method name is its namespace (`knowledge.search` → `knowledge`). Methods without a dot can only be called through `/rpc`.

### 1.1 Register with the macro (recommended)

```cangjie
import fountain::f_jsonrpc.*
import fountain::f_jsonrpc.macros.*

@JsonRpc[namespace: knowledge]
public class SearchRPC {
    public init() {}

    @JsonRpcMeta['knowledge base search', '5s']
    public func search(param: String): String {
        'found:${param}'
    }

    @JsonRpcMeta['add', '1s']
    public func add(a: Int64, b: Int64): Int64 {
        a + b
    }
}
```

- The class gets `@Bean`; every public instance method is registered as `<namespace>.<method>`
- The second `@JsonRpcMeta` argument is a `Duration` string; use `meta.timeoutDuration` to get a `Duration`
- `JsonRpcRegistry.getMeta<T>(methodName, argTypes)` returns `JsonRpcMeta`; `argTypes` selects the overload (empty description and a `500ms` timeout when there is no annotation)
- A single parameter accepts `[value]` or `{"name": value}` per JSON-RPC; multiple parameters require an object
- A `Unit` return becomes `null`; parameters and results may be any `f_data.DataFields<T>` subtype (including `@DataAssist` objects)

### 1.2 End-to-end demo

`fjsonrpcdemo` contains a runnable server / client:

```bash
cd fjsonrpcdemo
./boot.sh e2e 18080
```

It starts the server with `fboot run` and calls `/rpc` over HTTP, covering single/multiple parameters, a `@DataAssist` object and a `Unit` result.

### 2. Endpoints

The module ships `JsonRpcController`, which registers two routes:

| Path | Behaviour |
|---|---|
| `/rpc` | no namespace filtering |
| `/rpc/{topic}` | only methods under `topic`; returns `-32004` when the topic has no methods |

`{topic}` is a path variable of the built-in `JsonRpcController` (`@JsonRpcMapping[path: '/rpc/{topic}']` + `@PathVariable topic`). It carries the same value as the macro's `namespace`: the macro attribute is called `namespace`, while the route variable is called `topic`.

`@JsonRpc[namespace: knowledge]` registers `knowledge.search`, so:

| Request | Result |
|---|---|
| `POST /rpc/knowledge` + `{"method":"knowledge.search"}` | matches |
| `POST /rpc` + `{"method":"knowledge.search"}` | matches (`/rpc` does not filter) |
| `POST /rpc/knowledge` + `{"method":"search"}` | `-32601` (no prefix completion) |
| `POST /rpc/other` + `{"method":"knowledge.search"}` | `-32004` (`other` has no methods) |
| `POST /rpc/knowledge` + `{"method":"crm.list"}` (with `crm` registered) | `-32601` (method belongs to another namespace) |
| `POST /rpc/unknown` + any method | `-32004` (no method in that namespace) |

The namespace is derived from the method name: everything before the first `.`. Methods without a dot belong to the default namespace and can only be called through `/rpc`.

`@JsonRpcMapping` can also be used in your own `@Controller`. It fixes `method` / `consumes` / `produces` to `POST` + `application/json` and exposes only routing options:

```cangjie
import fountain::f_jsonrpc.server.*
import fountain::f_mvc.*

@Controller
public class MyRpcController {
    private let server = JsonRpcRegistry.server()

    @JsonRpcMapping[path: '/my-rpc']
    public func handle(@RequestBody raw: Array<Byte>): Any {
        let ctx = CurrentHttpContext.instance
        // handle returns a JsonValue; f_mvc renders it as application/json
        match (server.handle(raw, ctx: JsonRpcContext(http: Some(ctx)))) {
            case Some(value) => value
            case None => ()
        }
    }
}
```

### 3. Parameter validation

`JsonRpcMethodMeta.paramsSchema` takes a JSON Schema `JsonObject`. At registration time it is checked and its `pattern`s are pre-compiled by `f_data.CompiledSchema.compile` (a broken schema fails at startup); requests reuse the compiled result. Failure returns `-32602` with `error.data = ValidationResult.toJson()`.

```cangjie
let schema = JsonObject()
schema.add('type', 'object')
schema.add('required', JsonArray(list: ArrayList<JsonValue>([JsonString('query')])))
```

### 4. Errors

When a handler throws `JsonRpcException`, its `code` / `message` / `data` are returned as-is (`JsonRpcException` lives in `fountain::f_jsonrpc.base`):

```cangjie
throw JsonRpcException(-32020, 'Knowledge base not found', data: JsonString('kb-1'))
```

| Range | Owner |
|---|---|
| `-32700 ~ -32603` | JSON-RPC 2.0 standard errors |
| `-32001` | reserved, never produced by the current implementation |
| `-32002` | timeout (only when `timeout` is configured explicitly) |
| `-32003` | batch size exceeded (batches only, `data = {limit, size}`) |
| `-32004` | unknown topic (no method under `/rpc/{topic}`) |
| `-32020 ~ -32099` | available for applications |

Except for oversized bodies (HTTP 413) and framework-level failures, protocol errors always use HTTP 200 with the error object in the body. The response `Content-Type` is always `application/json` (rendered by f_mvc from a `JsonValue`); the request `Accept` header is no longer copied into it.

### 5. Timeouts

```cangjie
JsonRpcMethodMeta(name: 'slow', handler: ..., timeout: Duration.millisecond * 200)
```

- **No timeout by default**: without `@JsonRpcMeta`, or with an empty second argument, the handler runs inline on the
  request thread, so request-scoped ThreadLocals such as `CurrentHttpContext` work
- An explicit timeout spawns a worker thread and restores the context with `CurrentHttpContext.scoped`
- On timeout the client receives `-32002`, but **the handler is not cancelled** (Cangjie has no preemptive
  cancellation). Poll `ctx.isExpired()` in long loops and keep side-effecting operations idempotent.

## Client

```cangjie
import fountain::f_jsonrpc.client.*
import fountain::f_jsonrpc.base.*   // JsonRpcException

let client = JsonRpcClient('http://127.0.0.1:8080/rpc')
let result = client.call('kb.search', params: JsonString('fountain'))
client.notify('kb.reindex')
let responses = client.batch([JsonRpcCall('kb.search'), JsonRpcCall('ping')])
client.close()
```

- Request: `POST` + `Content-Type: application/json; charset=utf-8`, compact serialization
- One `Client` instance reuses the connection pool; no retries by default
- A server `error` throws `JsonRpcException`; only transport failures throw `IOException`
- **Retry boundary**: only connect/send failures (`JsonRpcConnectException`) are retried up to
  `retryOnConnectFailure`; read-stage failures are never retried (the server may have executed the call)
- **Response cap**: `Content-Length` is checked first, then bytes are counted while streaming; exceeding
  `maxResponseBytes` stops reading and closes the connection immediately
- A batch rejected as a whole (`-32003` or `-32600`) throws `JsonRpcException` carrying the server `code` / `data`;
  a non-array / non-error response yields `-32603`
- A non-numeric `error.code` or an unparsable body is wrapped into `JsonRpcException`; `JsonException` never leaks

### Client options

```cangjie
let client = JsonRpcClient('http://127.0.0.1:8080/rpc', opts: ClientOptions(
    timeout: Duration.second * 10,            // default 30s
    headers: headers,                         // extra headers, e.g. Authorization
    maxResponseBytes: 4 * 1024 * 1024,        // default 8 MiB; exceeding it fails fast
    keepAlive: false,                         // default true; false sends Connection: close
    retryOnConnectFailure: 2                  // default 0; connect failures only
))
```

### Batch and body limits

| Limit | Default | Configure | Response |
|---|---|---|---|
| Batch size `maxBatchSize` | 100 | `JsonRpcServer.builder().maxBatchSize(n)` | `-32003`, `data = {limit, size}` |
| Body bytes `maxBodyBytes` | `MVCConfig.maxRequestBodySize` (2 MiB) | `maxBodyBytes(n)` or MVC config | `-32600` + HTTP 413, `data = {limit}` |

An explicit `maxBodyBytes(n)` wins; otherwise the MVC config is read per request, so a config loaded after the
server is built still takes effect.

Custom transports (stdio / test doubles) implement `JsonRpcTransport` and are injected with
`JsonRpcClient(transport, opts: ...)`.

## API reference

### `fountain::f_jsonrpc.base`

#### `JsonRpcProtocol`

Protocol constants and error codes (`public static const`):

| Member | Value / signature | Meaning |
| --- | --- | --- |
| `VERSION` | `"2.0"` | JSON-RPC version |
| `PATH` | `"/rpc"` | Default endpoint |
| `TOPIC_PATH` | `"/rpc/{topic}"` | Topic endpoint template |
| `PARSE_ERROR` | `-32700` | Parse error |
| `INVALID_REQUEST` | `-32600` | Invalid request |
| `METHOD_NOT_FOUND` | `-32601` | Method not found |
| `INVALID_PARAMS` | `-32602` | Invalid params |
| `INTERNAL_ERROR` | `-32603` | Internal error |
| `SERVER_ERROR` | `-32001` | Reserved; not produced by this implementation |
| `TIMEOUT` | `-32002` | Method timeout |
| `OVERLOADED` | `-32003` | Batch size exceeded |
| `UNKNOWN_TOPIC` | `-32004` | Unknown topic |
| `DEFAULT_MAX_BATCH_SIZE` | `100` | Default batch limit |
| `messageOf(code)` | `static func messageOf(code: Int64): String` | Default message for standard codes |

#### `JsonRpcException` and `JsonRpcError`

```cangjie
public open class JsonRpcException <: Exception {
    public let code: Int64
    public let data: ?JsonValue
    public init(code: Int64, message: String, data!: ?JsonValue = None)
}

public class JsonRpcConnectException <: IOException {
    public init(message: String)
}

public struct JsonRpcError {
    public const JsonRpcError(public let code: Int64, public let message: String, public let data: ?JsonValue)
    public static func from(ex: JsonRpcException): JsonRpcError
    public func toJson(): JsonObject
}
```

- `JsonRpcConnectException` is the only retryable transport exception (connect / send phase).
  Response-read failures are never retried because the server may already have executed the call.
- `JsonRpcError.toJson()` emits `{code, message, data?}` and can be used directly in a response body.

#### `JsonRpcMeta`

```cangjie
@Annotation[target: [MemberFunction]]
public class JsonRpcMeta {
    public const JsonRpcMeta(public let description: String, public let timeout: String)
    public prop timeoutDuration: Duration
}
```

- Applied to public instance methods of a `@JsonRpc` class. `timeout` is a `Duration` string (`"5s"`, `"1m30s"`).
- An empty string means no timeout; `timeoutDuration` parses it with `Duration.parse`.

### `fountain::f_jsonrpc.server`

#### `JsonRpcMethodMeta`

```cangjie
public type JsonRpcHandler = (JsonRpcContext, ?JsonValue) -> JsonValue

public class JsonRpcMethodMeta {
    public let name: String
    public let handler: JsonRpcHandler
    public let description: String
    public let timeout: ?Duration
    public let paramsSchema: ?JsonObject

    public init(name!: String, handler!: JsonRpcHandler, description!: String = '',
        timeout!: ?Duration = None, paramsSchema!: ?JsonObject = None)
    public func namespace(): String
}
```

- `name` is either `namespace.method` or a bare `method`; `namespace()` returns the part before
  the first `.` (empty for bare names).
- `paramsSchema` is precompiled with `f_data.CompiledSchema.compile` at construction time, so a
  malformed schema fails at startup.
- `timeout = None` runs the handler inline on the request thread; setting it spawns a worker and
  returns `-32002` on timeout.

#### `JsonRpcRegistry`

```cangjie
public class JsonRpcRegistry {
    public static func server(): JsonRpcServer
    public static func register(meta: JsonRpcMethodMeta): Unit
    public static func getMeta<T>(fnName: String, argTypes: Array<TypeInfo>): JsonRpcMeta where T <: Object
}
```

- `server()` returns the process-wide default endpoint (`/rpc`) server.
- `register` appends a method to the default endpoint; duplicate names throw `JsonRpcException(-32603)`.
- `getMeta<T>` reads `@JsonRpcMeta` from `T.fnName` for the given argument types; a missing
  annotation yields `JsonRpcMeta("", "")` (no description, no timeout).

#### `JsonRpcServer`

```cangjie
public class JsonRpcServer {
    public static func builder(): JsonRpcServerBuilder
    public func addMethod(meta: JsonRpcMethodMeta): Unit
    public func methods(): ArrayList<JsonRpcMethodMeta>
    public prop endpoint: String
    public func handle(body: Array<Byte>, ctx!: JsonRpcContext): ?JsonValue
    public func invoke(method: String, params!: ?JsonValue = None,
        ctx!: JsonRpcContext = JsonRpcContext()): JsonValue
}
```

| Method | Description |
| --- | --- |
| `addMethod` | Thread-safe; duplicate names throw `JsonRpcException(-32603)` instead of overwriting |
| `methods()` | Snapshot sorted by method name, for stable `tools/list` output |
| `handle` | Parses a single request or a batch; `None` means a notification with no response body; oversized bodies return `-32600` and set HTTP 413 |
| `invoke` | Local direct call without HTTP; a missing method throws `JsonRpcException(-32601)` |

Batch behavior in `handle`: an empty array → `-32600`; more than `maxBatchSize` → `-32003`
(`data={limit,size}`); each batch item is handled independently and notification items produce
no response.

#### `JsonRpcServerBuilder`

```cangjie
public class JsonRpcServerBuilder {
    public func endpoint(name: String): JsonRpcServerBuilder
    public func maxBatchSize(n: Int64): JsonRpcServerBuilder
    public func maxBodyBytes(n: Int64): JsonRpcServerBuilder
    public func addMethod(meta: JsonRpcMethodMeta): JsonRpcServerBuilder
    public func build(): JsonRpcServer
}
```

- When `maxBodyBytes` is unset (`0`), each request reads `MVCConfig.maxRequestBodySize`
  (default 2 MiB) at request time.
- `maxBatchSize` / `maxBodyBytes` accept positive values only; non-positive values are ignored.

#### `JsonRpcContext`

```cangjie
public class JsonRpcContext {
    public let http: ?HttpContext
    public let id: ?JsonValue
    public let endpoint: String
    public let topic: String
    public let deadline: ?MonoTime

    public init(http!: ?HttpContext = None, id!: ?JsonValue = None,
        endpoint!: String = JsonRpcProtocol.PATH, topic!: String = '', deadline!: ?MonoTime = None)
    public func setResponseHeader(name: String, value: String): Unit
    public func isExpired(): Bool
}
```

- `http = None` means stdio / local invocation; `setResponseHeader` is a no-op there.
- `isExpired()` is always `false` without a `deadline`; long-running loops should poll it.

#### `JsonRpcController` / `JsonRpcMapping`

`JsonRpcController` is the built-in `f_mvc` controller with two routes:

- `handleRoot(@RequestBody raw)` → `/rpc`
- `handleTopic(@RequestBody raw, @PathVariable topic)` → `/rpc/{topic}`

`JsonRpcMapping <: RequestMapping` is the annotation class behind `@JsonRpcMapping[path: ...]`.
It fixes `POST` + `application/json` and exposes only `path`; use it to wire a custom
`@Controller` method to `JsonRpcServer.handle`.

#### `JsonRpcArgs`

```cangjie
public class JsonRpcArgs {
    public static func extract<T>(params: ?JsonValue, name: String, named!: Bool): T where T <: DataFields<T>
    public static func toJson<T>(value: T): JsonValue where T <: DataFields<T>
    public static func toJson(value: Unit): JsonValue
}
```

Argument conversion helpers: `extract` reads a positional / named value and converts it to `T`;
`toJson` converts a return value to JSON and maps `Unit` to `null`.

### `fountain::f_jsonrpc.client`

#### `ClientOptions`

| Field | Default | Description |
| --- | --- | --- |
| `timeout` | `30s` | Per-request HTTP timeout |
| `headers` | empty | Extra request headers (for example `Authorization`) |
| `maxResponseBytes` | `8 MiB` | Response body limit; exceeding it stops reading and closes the connection |
| `keepAlive` | `true` | `false` sends `Connection: close` |
| `retryOnConnectFailure` | `0` | Retries for connect / send failures only |

#### `JsonRpcCall` / `JsonRpcResponse`

```cangjie
public struct JsonRpcCall {
    public const JsonRpcCall(public let method: String, public let params!: ?JsonValue = None)
}

public struct JsonRpcResponse {
    public const JsonRpcResponse(public let id: ?JsonValue, public let result: ?JsonValue,
        public let error: ?JsonRpcError)
    public prop isError: Bool
}
```

`batch` returns responses in input order; a per-item error is stored in `error` and does not abort
the batch.

#### `JsonRpcTransport`

```cangjie
public interface JsonRpcTransport {
    func send(body: Array<Byte>): Array<Byte>
    func close(): Unit
}
```

Custom transports (stdio / test doubles) implement `send` / `close`. A connect / send failure
should throw `JsonRpcConnectException`; a response-read failure should throw a normal exception.

#### `JsonRpcClient`

```cangjie
public class JsonRpcClient {
    public init(url: String, opts!: ClientOptions = ClientOptions())
    public init(transport: JsonRpcTransport, opts!: ClientOptions = ClientOptions())
    public func call(method: String, params!: ?JsonValue = None): JsonValue
    public func callAsync(method: String, params!: ?JsonValue = None): Future<JsonValue>
    public func notify(method: String, params!: ?JsonValue = None): Unit
    public func batch(calls: Array<JsonRpcCall>): Array<JsonRpcResponse>
    public func close(): Unit
}
```

| Method | Behavior |
| --- | --- |
| `call` | Sends one request and returns `result`; a server `error` throws `JsonRpcException`; a missing `result` throws `-32603` |
| `callAsync` | Wraps `call` in `spawn`, returning `Future<JsonValue>` |
| `notify` | Sends an `id`-less notification and returns immediately; no response parsing and no server error propagation |
| `batch` | Batch call; a whole-batch rejection (`-32003` / `-32600`) throws `JsonRpcException` |
| `close` | Closes the transport; idempotent |

### Macros

| Annotation | Target | Effect |
| --- | --- | --- |
| `@JsonRpc[namespace: xxx]` | class | Adds `@Bean` and registers public instance methods as `xxx.method`; without the attribute methods use bare names |
| `@JsonRpcMeta['description', '5s']` | method | Sets description and timeout; an empty string means no timeout |
| `@JsonRpcMapping[path: '/my-rpc']` | method | Fixes `POST` + `application/json` and wires the method into a custom controller |

`@JsonRpc` expansion relies on `lookup` / `BeanFactory` / `TypeInfo` re-exported by the facade
package; when importing only `f_jsonrpc.server` / `base`, add those three symbols or simply
`import fountain::f_jsonrpc.*`.

## Out of scope

- SSE / WebSocket or any other transport
- `$ref` / `allOf` / `anyOf` / `oneOf` / `not` resolution (schema validation fails closed)
- UTF-8 only; no charset detection


## Migration (1.3.17 → next)

| Change | Impact | Migration |
|---|---|---|
| Default timeout 500 ms → none | Calls that relied on the default no longer time out | Set `@JsonRpcMeta['desc', '5s']` explicitly |
| `JsonRpcServer.handle` returns `?JsonValue` | Callers asserting on bytes fail to compile | Use `value.toString().unsafeBytes()` |
| `JsonRpcContext.meta` removed | Code reading it fails to compile | Read `ctx.http?.request.headers.getFirst(...)` |
| `JsonRpcMethodMeta.inputSchema` / `outputSchema` removed | Constructor calls fail to compile | Take it from `McpTool` |
| A non-numeric `error.code` no longer throws `JsonException` | Behaviour changes for that catch | Catch `JsonRpcException` |

## Testing

```bash
cjpm test
```

Unit tests are split by package: `client` covers request construction, while `server` covers single requests, batches, notifications, error codes, id fidelity, topic filtering, schema validation, timeouts and annotation routing.

## License

Apache-2.0
