# f_jsonrpc

`f_jsonrpc` 在 `f_mvc` 之上提供 **JSON-RPC 2.0 over HTTP** 的服务端与客户端能力。它只补 `f_mvc` 没有的三样东西：JSON-RPC 消息模型、运行期方法表、错误码；路由、鉴权、线程池、日志、异常兜底全部由 `f_mvc` 提供。

- 一个 JSON-RPC 端点 = 一条 `f_mvc` 路由（`RequestMeta`），`method` 在请求体内分发
- 支持单请求、批量、通知、topic 命名空间、单方法超时、JSON Schema 参数校验
- 不修改 `f_mvc` 任何公开 API（`@JsonRpcMapping` 是 `RequestMapping` 的子类）

## 包结构

| 包 | 内容 |
|----|------|
| `fountain::f_jsonrpc.base` | 协议常量、错误模型、方法元数据注解 |
| `fountain::f_jsonrpc.client` | `JsonRpcClient` / `ClientOptions` |
| `fountain::f_jsonrpc.server` | `JsonRpcServer`、方法表、`f_mvc` 路由与参数转换 |
| `fountain::f_jsonrpc.macros` | `@JsonRpc` 宏（独立包） |
| `fountain::f_jsonrpc` | 门面包：`public import` 以上三个包，兼容 `import fountain::f_jsonrpc.*` |

客户端可以只 `import fountain::f_jsonrpc.client.*`，服务端只 `import fountain::f_jsonrpc.server.*`，共用 `base`；
模块依赖仍声明 `fountain::f_jsonrpc`。

使用 `@JsonRpc` 宏时建议 `import fountain::f_jsonrpc.*`：宏展开会用到门面包再导出的
`lookup` / `BeanFactory` / `TypeInfo`，只导入 `server` / `base` 时需要自行补这三个符号。

## 规范版本

- **JSON-RPC 2.0**（[规范原文](https://www.jsonrpc.org/specification)，2013-01-04 发布）
- 传输：HTTP(S) `POST` + `application/json`，UTF-8
- 已实现：请求 / 响应、批量、通知（无 `id` 不回包）、位置参数与命名参数、`id` 原样回传（字符串 / 数字 / `null`）、标准错误码 `-32700` / `-32600` / `-32601` / `-32602` / `-32603`
- 扩展：`-32001 ~ -32004` 为模块保留码段，`-32020 ~ -32099` 留给业务；`/rpc/{topic}` 是 HTTP 路径层的命名空间扩展，不改变消息格式
- 与规范的差异：协议错误统一返回 HTTP 200（请求体超限返回 413），错误放在响应体的 `error` 对象；传输只做 HTTP POST，不提供 GET / SSE / WebSocket
- 单参数也按规范写成 `[值]` 或 `{"名": 值}`，不接受裸标量

## 依赖

```toml
[dependencies]
  "fountain::f_bean" = {path = "../f_bean"}
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_log" = {path = "../f_log"}
  "fountain::f_macros" = {path = "../f_macros"}
  "fountain::f_mvc" = {path = "../f_mvc"}
```

## 服务端

### 1. 注册方法

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
        description: '知识库检索',
        timeout: Duration.second * 5
    ))
}
```

方法名里的第一个 `.` 之前是命名空间（`knowledge.search` → `knowledge`）。不含 `.` 的方法只能从 `/rpc` 调用。

### 1.1 用宏注册（推荐）

```cangjie
import fountain::f_jsonrpc.*
import fountain::f_jsonrpc.macros.*

@JsonRpc[namespace: knowledge]
public class SearchRPC {
    public init() {}

    @JsonRpcMeta['知识库检索', '5s']
    public func search(param: String): String {
        'found:${param}'
    }

    @JsonRpcMeta['加法', '1s']
    public func add(a: Int64, b: Int64): Int64 {
        a + b
    }
}
```

- 类上自动加 `@Bean`；每个 public 实例方法注册为 `<namespace>.<方法名>`
- `@JsonRpcMeta['描述', '5s']` 的第二个参数是 `Duration` 字符串，可用 `meta.timeoutDuration` 取 `Duration`
- `JsonRpcRegistry.getMeta<T>(方法名, argTypes)` 返回 `JsonRpcMeta`；`argTypes` 用来匹配重载（无注解时描述为空串、**不设超时**）
- `timeout` 写空串 `''` 等价于「不设超时」；只有写了 `'5s'` 这类值才会走子线程 + `future.get(t)`
- 单参数按 JSON-RPC 规范传 `[值]` 或 `{"参数名": 值}`；多参数必须传对象
- 返回 `Unit` 时 `result` 为 `null`；参数/返回值可以是任意 `f_data.DataFields<T>` 子类型（含 `@DataAssist` 对象）

### 1.2 端到端 demo

`fjsonrpcdemo` 提供可运行的 server / client：

```bash
cd fjsonrpcdemo
./boot.sh e2e 18080
```

它会用 `fboot run` 启动服务端，再由客户端走 HTTP 调用 `/rpc`，覆盖单参数、多参数、`@DataAssist` 对象与 `Unit` 返回值。

### 2. 端点

模块内置 `JsonRpcController`，自动注册两条路由：

| 路径 | 行为 |
|---|---|
| `/rpc` | 不过滤命名空间 |
| `/rpc/{topic}` | 只允许 `topic` 命名空间下的方法；该 topic 没有任何方法时返回 `-32004` |

`{topic}` 是内置 `JsonRpcController` 的路径变量（`@JsonRpcMapping[path: '/rpc/{topic}']` + `@PathVariable topic`），它对应的就是宏里的 `namespace`：宏属性叫 `namespace`，路由变量叫 `topic`，两者是同一个值。

`@JsonRpc[namespace: knowledge]` 注册出的方法名是 `knowledge.search`，因此：

| 请求 | 结果 |
|---|---|
| `POST /rpc/knowledge` + `{"method":"knowledge.search"}` | 命中 |
| `POST /rpc` + `{"method":"knowledge.search"}` | 命中（`/rpc` 不过滤命名空间） |
| `POST /rpc/knowledge` + `{"method":"search"}` | `-32601`（不做前缀补全） |
| `POST /rpc/other` + `{"method":"knowledge.search"}` | `-32004`（`other` 下没有任何方法） |
| `POST /rpc/knowledge` + `{"method":"crm.list"}`（`crm` 已注册） | `-32601`（方法属于别的命名空间） |
| `POST /rpc/unknown` + 任意 method | `-32004`（该命名空间下没有任何方法） |

命名空间从方法名反推：第一个 `.` 之前的部分；不含 `.` 的方法属于默认命名空间，只能从 `/rpc` 调用。

`@JsonRpcMapping` 也可以直接用在自定义 `@Controller` 里。它把 `method` / `consumes` / `produces` 固定为 `POST` + `application/json`，只暴露路由参数：

```cangjie
import fountain::f_jsonrpc.server.*
import fountain::f_mvc.*

@Controller
public class MyRpcController {
    private let server = JsonRpcRegistry.server()

    @JsonRpcMapping[path: '/my-rpc']
    public func handle(@RequestBody raw: Array<Byte>): Any {
        let ctx = CurrentHttpContext.instance
        // handle 返回 JsonValue：由 f_mvc 按 application/json 输出
        match (server.handle(raw, ctx: JsonRpcContext(http: Some(ctx)))) {
            case Some(value) => value
            case None => ()
        }
    }
}
```

### 3. 参数校验

`JsonRpcMethodMeta.paramsSchema` 接一份 `JsonObject` 形式的 JSON Schema；注册期用 `f_data.CompiledSchema.compile` 做结构校验并预编译 `pattern`（脏 schema 在启动时就报错），请求期直接复用编译结果，失败返回 `-32602`，`error.data` 是 `ValidationResult.toJson()`。

```cangjie
let schema = JsonObject()
schema.add('type', 'object')
schema.add('required', JsonArray(list: ArrayList<JsonValue>([JsonString('query')])))
```

### 4. 错误

handler 抛 `JsonRpcException` 时，`code` / `message` / `data` 原样返回（`JsonRpcException` 在 `fountain::f_jsonrpc.base`）：

```cangjie
throw JsonRpcException(-32020, 'Knowledge base not found', data: JsonString('kb-1'))
```

| 码段 | 归属 |
|---|---|
| `-32700 ~ -32603` | JSON-RPC 2.0 标准错误 |
| `-32001` | 保留，当前实现不产生（`SERVER_ERROR` 仅作占位） |
| `-32002` | 超时（只有显式配置 `timeout` 才会产生） |
| `-32003` | 批量条数超限（仅批请求，`data` = `{limit, size}`） |
| `-32004` | 未知 topic（`/rpc/{topic}` 下没有任何方法） |
| `-32020 ~ -32099` | 业务可用 |

除请求体超限（HTTP 413）与框架级异常外，协议错误一律 HTTP 200，错误放在响应体的 `error` 对象里。响应 `Content-Type` 固定为 `application/json`（来自 f_mvc 对 `JsonValue` 的渲染），不再取请求的 `Accept` 原文。

### 5. 超时

```cangjie
JsonRpcMethodMeta(name: 'slow', handler: ..., timeout: Duration.millisecond * 200)
```

- **默认不设超时**：没有 `@JsonRpcMeta` 或注解第二参数为空串时，handler 在请求线程内联执行，
  `CurrentHttpContext` 等请求级 ThreadLocal 完整可用
- 显式配置超时才会 `spawn` 子线程，并在子线程内用 `CurrentHttpContext.scoped` 恢复上下文
- 超时后返回 `-32002`，**但不会终止 handler**（仓颉没有抢占式取消）。长循环里用 `ctx.isExpired()` 自查，带副作用的操作请保证幂等

## 客户端

```cangjie
import fountain::f_jsonrpc.client.*
import fountain::f_jsonrpc.base.*   // JsonRpcException

let client = JsonRpcClient('http://127.0.0.1:8080/rpc')
let result = client.call('kb.search', params: JsonString('fountain'))
client.notify('kb.reindex')
let responses = client.batch([JsonRpcCall('kb.search'), JsonRpcCall('ping')])
client.close()
```

- 请求：`POST` + `Content-Type: application/json; charset=utf-8`，紧凑序列化
- `Client` 实例复用连接池，默认不重试
- **重试边界**：只有建连 / 发送阶段失败（`JsonRpcConnectException`）会按 `retryOnConnectFailure` 重试；
  读响应阶段失败（服务端可能已经执行）永不重试
- **响应上限**：先用 `Content-Length` 预判，再流式累计字节数，超过 `maxResponseBytes` 立即停止读取并关闭连接
- 批量整体被拒（`-32003` 超限 / `-32600` 空批量）时直接抛 `JsonRpcException`，携带服务端的 `code` / `data`；
  非数组、非错误对象响应报 `-32603`
- `error.code` 非数字、响应体不是合法 JSON 一律映射为 `JsonRpcException`，不泄漏 `JsonException`

### 6. 客户端选项

```cangjie
let client = JsonRpcClient('http://127.0.0.1:8080/rpc', opts: ClientOptions(
    timeout: Duration.second * 10,            // 默认 30s
    headers: headers,                         // 额外请求头，如 Authorization
    maxResponseBytes: 4 * 1024 * 1024,        // 默认 8 MiB，超限直接报错
    keepAlive: false,                         // 默认 true；false 时发送 Connection: close
    retryOnConnectFailure: 2                  // 默认 0（不重试），仅建连失败可重试
))
```

### 7. 请求体与批量上限

| 上限 | 默认值 | 配置方式 | 超限响应 |
|---|---|---|---|
| 单次批量条数 `maxBatchSize` | 100 | `JsonRpcServer.builder().maxBatchSize(n)` | `-32003`，`data = {limit, size}` |
| 请求体字节数 `maxBodyBytes` | `MVCConfig.maxRequestBodySize`（2 MiB） | `maxBodyBytes(n)` 或 MVC 配置 | `-32600` + HTTP 413，`data = {limit}` |

显式 `maxBodyBytes(n)` 优先；没显式配置时每次请求现读 `MVCConfig.maxRequestBodySize`，因此在 server 构造之后再加载配置也生效。

自定义传输（stdio / 测试替身）可以直接实现 `JsonRpcTransport` 并通过 `JsonRpcClient(transport, opts: ...)` 注入。
- 服务端返回 `error` → 抛 `JsonRpcException`；只有传输失败才抛 `IOException`

## 不做的部分

- SSE / WebSocket 传输、JSON-RPC over 其他传输
- `$ref` / `allOf` / `anyOf` / `oneOf` / `not` 的解析（schema 校验对它们 fail-closed）
- 只支持 UTF-8，不做编码探测


## 迁移（1.3.17 → 下一版）

| 变更 | 影响 | 迁移 |
|---|---|---|
| 默认超时 500ms → 无 | 依赖默认超时的调用不再超时 | 显式写 `@JsonRpcMeta['描述', '5s']` |
| `JsonRpcServer.handle` 返回 `?JsonValue` | 断言字节的调用方编译失败 | 改用 `value.toString().unsafeBytes()` |
| `JsonRpcContext.meta` 删除 | 读该字段的代码编译失败 | 改读 `ctx.http?.request.headers.getFirst(...)` |
| `JsonRpcMethodMeta.inputSchema` / `outputSchema` 删除 | 构造时传参编译失败 | 从 `McpTool` 取 |
| `error.code` 非数字不再抛 `JsonException` | 依赖该异常类型的代码行为变化 | 统一捕获 `JsonRpcException` |

## 测试

```bash
cjpm test
```

单元测试按包分布：`client` 覆盖客户端请求构造，`server` 覆盖单请求、批量、通知、错误码、id 保真、topic 过滤、schema 校验、超时与注解路由。

## 许可

Apache-2.0
