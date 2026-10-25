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
| `POST /rpc/other` + `{"method":"knowledge.search"}` | `-32601` (different namespace) |
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
        match (server.handle(raw, ctx: JsonRpcContext(http: Some(ctx)))) {
            case Some(bytes) => bytes
            case None => ()
        }
    }
}
```

### 3. Parameter validation

`JsonRpcMethodMeta.paramsSchema` takes a JSON Schema `JsonObject`. `params` is validated with `JsonSchemaValidator.validate` before the handler runs; failure returns `-32602` and `error.data` is `ValidationResult.toJson()`.

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
| `-32001 ~ -32004` | reserved by f_jsonrpc (Server error / Timeout / Overloaded / Unknown topic) |
| `-32020 ~ -32099` | available for applications |

Except for oversized bodies (HTTP 413) and framework-level failures, protocol errors always use HTTP 200 with the error object in the body.

### 5. Timeouts

```cangjie
JsonRpcMethodMeta(name: 'slow', handler: ..., timeout: Duration.millisecond * 200)
```

On timeout the client receives `-32002`, but **the handler is not cancelled** (Cangjie has no preemptive cancellation). Poll `ctx.isExpired()` in long loops and keep side-effecting operations idempotent.

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

## Out of scope

- SSE / WebSocket or any other transport
- `$ref` / `allOf` / `anyOf` / `oneOf` / `not` resolution (schema validation fails closed)
- UTF-8 only; no charset detection

## Testing

```bash
cjpm test
```

Unit tests are split by package: `client` covers request construction, while `server` covers single requests, batches, notifications, error codes, id fidelity, topic filtering, schema validation, timeouts and annotation routing.

## License

Apache-2.0
