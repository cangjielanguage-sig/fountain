# f_jsonrpc

`f_jsonrpc` provides **JSON-RPC 2.0 over HTTP** on top of `f_mvc`, for both server and client. It adds only what `f_mvc` lacks: the JSON-RPC message model, a runtime method table, and the error model. Routing, authentication, thread pools, logging and exception handling all come from `f_mvc`.

- One JSON-RPC endpoint = one `f_mvc` route (`RequestMeta`); `method` is dispatched inside the request body
- Single requests, batches, notifications, topic namespaces, per-method timeouts and JSON Schema validation
- No `f_mvc` API change (`@JsonRpcMapping` is a `RequestMapping` subclass)

## Dependencies

```toml
[dependencies]
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_log" = {path = "../f_log"}
  "fountain::f_mvc" = {path = "../f_mvc"}
```

## Server

### 1. Register methods

```cangjie
package demo

import fountain::f_jsonrpc.*
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

The part before the first `.` in a method name is its namespace (`kb.search` → `kb`). Methods without a dot can only be called through `/rpc`.

### 1.1 Register with the macro (recommended)

```cangjie
import fountain::f_jsonrpc.*
import fountain::f_jsonrpc.macros.*

@JsonRpc[topic: kb]
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

- The class gets `@Bean`; every public instance method is registered as `<topic>.<method>`
- The second `@JsonRpcMeta` argument is a `Duration` string; use `meta.timeoutDuration` to get a `Duration`
- `JsonRpcRegistry.getMeta<T>(methodName)` returns `JsonRpcMeta` (empty description and a `500ms` timeout when there is no annotation)
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

`@JsonRpcMapping` can also be used in your own `@Controller`. It fixes `method` / `consumes` / `produces` to `POST` + `application/json` and exposes only routing options:

```cangjie
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

When a handler throws `JsonRpcException`, its `code` / `message` / `data` are returned as-is:

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

Unit tests cover single requests, batches, notifications, error codes, id fidelity, topic filtering, schema validation, timeouts, annotation routing and client request construction.

## License

Apache-2.0
