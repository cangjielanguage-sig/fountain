# f_jsonrpc

`f_jsonrpc` 在 `f_mvc` 之上提供 **JSON-RPC 2.0 over HTTP** 的服务端与客户端能力。它只补 `f_mvc` 没有的三样东西：JSON-RPC 消息模型、运行期方法表、错误码；路由、鉴权、线程池、日志、异常兜底全部由 `f_mvc` 提供。

- 一个 JSON-RPC 端点 = 一条 `f_mvc` 路由（`RequestMeta`），`method` 在请求体内分发
- 支持单请求、批量、通知、topic 命名空间、单方法超时、JSON Schema 参数校验
- 不修改 `f_mvc` 任何公开 API（`@JsonRpcMapping` 是 `RequestMapping` 的子类）

## 依赖

```toml
[dependencies]
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_log" = {path = "../f_log"}
  "fountain::f_mvc" = {path = "../f_mvc"}
```

## 服务端

### 1. 注册方法

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
        description: '知识库检索',
        timeout: Duration.second * 5
    ))
}
```

方法名里的第一个 `.` 之前是命名空间（`kb.search` → `kb`）。不含 `.` 的方法只能从 `/rpc` 调用。

### 2. 端点

模块内置 `JsonRpcController`，自动注册两条路由：

| 路径 | 行为 |
|---|---|
| `/rpc` | 不过滤命名空间 |
| `/rpc/{topic}` | 只允许 `topic` 命名空间下的方法；该 topic 没有任何方法时返回 `-32004` |

`@JsonRpcMapping` 也可以直接用在自定义 `@Controller` 里。它把 `method` / `consumes` / `produces` 固定为 `POST` + `application/json`，只暴露路由参数：

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

### 3. 参数校验

`JsonRpcMethodMeta.paramsSchema` 接一份 `JsonObject` 形式的 JSON Schema；请求进入 handler 前用 `JsonSchemaValidator.validate` 校验，失败返回 `-32602`，`error.data` 是 `ValidationResult.toJson()`。

```cangjie
let schema = JsonObject()
schema.add('type', 'object')
schema.add('required', JsonArray(list: ArrayList<JsonValue>([JsonString('query')])))
```

### 4. 错误

handler 抛 `JsonRpcException` 时，`code` / `message` / `data` 原样返回：

```cangjie
throw JsonRpcException(-32020, 'Knowledge base not found', data: JsonString('kb-1'))
```

| 码段 | 归属 |
|---|---|
| `-32700 ~ -32603` | JSON-RPC 2.0 标准错误 |
| `-32001 ~ -32004` | f_jsonrpc 保留（Server error / Timeout / Overloaded / Unknown topic） |
| `-32020 ~ -32099` | 业务可用 |

除请求体超限（HTTP 413）与框架级异常外，协议错误一律 HTTP 200，错误放在响应体的 `error` 对象里。

### 5. 超时

```cangjie
JsonRpcMethodMeta(name: 'slow', handler: ..., timeout: Duration.millisecond * 200)
```

超时后返回 `-32002`，**但不会终止 handler**（仓颉没有抢占式取消）。长循环里用 `ctx.isExpired()` 自查，带副作用的操作请保证幂等。

## 客户端

```cangjie
let client = JsonRpcClient('http://127.0.0.1:8080/rpc')
let result = client.call('kb.search', params: JsonString('fountain'))
client.notify('kb.reindex')
let responses = client.batch([JsonRpcCall('kb.search'), JsonRpcCall('ping')])
client.close()
```

- 请求：`POST` + `Content-Type: application/json; charset=utf-8`，紧凑序列化
- `Client` 实例复用连接池，默认不重试
- 服务端返回 `error` → 抛 `JsonRpcException`；只有传输失败才抛 `IOException`

## 不做的部分

- SSE / WebSocket 传输、JSON-RPC over 其他传输
- `$ref` / `allOf` / `anyOf` / `oneOf` / `not` 的解析（schema 校验对它们 fail-closed）
- 只支持 UTF-8，不做编码探测

## 测试

```bash
cjpm test
```

单元测试覆盖单请求、批量、通知、错误码、id 保真、topic 过滤、schema 校验、超时、注解路由与客户端请求构造。

## 许可

Apache-2.0
