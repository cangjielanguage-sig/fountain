# fountain实现思想与应用第十四弹

##### ——JSONRPC & MCP

项目链接：https://gitcode.com/Cangjie-TPC/fountain

如果要选一个「最被低估的协议」，我会投 JSON-RPC 2.0。

它只有几页纸：请求是 `{jsonrpc, method, params, id}`，响应是 `{jsonrpc, result, id}` 或 `{jsonrpc, error, id}`。没有 schema、没有 IDL、没有代码生成、没有传输层规定。但正因为什么都没有，它可以跑在 HTTP 上、stdio 上、WebSocket 上，可以被 `curl` 调、被脚本拼、被模型生成。

fountain 用它做了两件事：

- `f_jsonrpc`：在 `f_mvc` 之上补齐 **JSON-RPC 2.0 over HTTP**；
- `f_mcp`：在 `f_jsonrpc` 之上补齐 **MCP（Model Context Protocol）** 的语义。

两者是严格的上下层关系：

```
  ┌──────────────────────────────────────────────┐
  │  f_mcp   工具 / 资源 / 提示词 / 能力 / 限流   │  ← 语义层
  ├──────────────────────────────────────────────┤
  │  f_jsonrpc  方法表 / 批量 / 通知 / 错误码     │  ← 消息层
  ├──────────────────────────────────────────────┤
  │  f_mvc   路由 / 鉴权 / 线程池 / 日志 / 兜底   │  ← Web 层
  └──────────────────────────────────────────────┘
```

---

## 一、`f_jsonrpc` 的第一原则：不重写 MVC

很多框架在做「新协议支持」时，会顺手再写一套路由、鉴权、线程池。结果是同一套能力有两份实现，行为迟早不一致。

`f_jsonrpc` 的选择是**只补 `f_mvc` 没有的三样东西**：

1. JSON-RPC 消息模型（请求 / 响应 / 批量 / 通知）；
2. 运行期方法表（`method` 字符串 → 处理函数）；
3. 错误码体系。

路由、鉴权、线程池、日志、异常兜底**全部复用 `f_mvc`**。具体做法是：

> **一个 JSON-RPC 端点 = 一条 `f_mvc` 路由（`RequestMeta`），`method` 在请求体内分发。**

于是 `@JsonRpcMapping` 干脆就是 `RequestMapping` 的子类，把 `method` / `consumes` / `produces` 固定成 `POST` + `application/json`，只暴露路由参数。**`f_mvc` 的公开 API 一行没改。**

这个设计的收益不只是省代码：

- 鉴权注解（`@IgnoreAuth` / `@IgnorePrivilege`）在 JSON-RPC 端点上照样生效；
- 访问日志、错误处理器、请求体大小限制照样生效；
- 运维只需要理解一套 HTTP 服务的行为。

---

## 二、方法怎么注册：宏、命名空间、两个端点

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

`@JsonRpc` 做了三件事：给类加 `@Bean`；把每个 public 实例方法注册成 `<namespace>.<方法名>`；`@JsonRpcMeta['描述', '时长']` 提供描述与单方法超时。

上例注册出的方法名是 `knowledge.search` 和 `knowledge.add`。

模块内置的 `JsonRpcController` 自动注册两条路由：

| 路径 | 行为 |
| --- | --- |
| `/rpc` | 不过滤命名空间 |
| `/rpc/{topic}` | 只允许 `topic` 命名空间下的方法；该 topic 没有任何方法时返回 `-32004` |

**命名空间是「方法名的前缀」，不是「路由的别名」**。这个区分决定了很多行为：

| 请求 | 结果 |
| --- | --- |
| `POST /rpc/knowledge` + `{"method":"knowledge.search"}` | 命中 |
| `POST /rpc` + `{"method":"knowledge.search"}` | 命中（`/rpc` 不过滤） |
| `POST /rpc/knowledge` + `{"method":"search"}` | `-32601`（**不做前缀补全**） |
| `POST /rpc/other` + `{"method":"knowledge.search"}` | `-32004`（`other` 下没有方法） |
| `POST /rpc/knowledge` + `{"method":"crm.list"}` | `-32601`（方法属于别的命名空间） |

「不做前缀补全」是一个刻意的选择。补全看起来更友好，但它会让「客户端以为自己在调 A，实际调到了 B」变得可能——**在协议层，明确失败比智能猜测安全**。

### 也可以不用宏

```cangjie
JsonRpcRegistry.register(JsonRpcMethodMeta(
    name: 'kb.search',
    handler: {ctx, params => JsonString('found')},
    description: '知识库检索',
    timeout: Duration.second * 5
))
```

宏只是语法糖。动态注册在「方法由配置决定」或「插件化」的场景里更好用。

---

## 三、协议细节：三个「照规范做」的地方

### 1. `id` 原样回传

JSON-RPC 允许 `id` 是字符串、数字或 `null`。很多实现会「统一转成字符串」或「统一转成数字」，然后在批量场景里对不上号。

`f_jsonrpc` 的做法是**保真**：来什么类型，回什么类型。批量请求里每个子请求的 `id` 独立，响应按 `id` 匹配。

### 2. 单参数也必须包起来

规范要求 `params` 是数组或对象，所以**单参数也要写成 `[值]` 或 `{"名": 值}`，不接受裸标量**。

这一条经常被抱怨「不人性化」，但它是可交互性的基础：如果允许裸标量，那么 `params: "abc"` 到底是「一个字符串参数」还是「一个字符数组」就说不清了。

### 3. 通知没有响应

带 `id` 是请求，不带 `id` 是通知。通知**不回包**——HTTP 层只回一个空的成功响应，客户端不要等结果。

---

## 四、超时：默认不设，设了也不杀

这是 `f_jsonrpc` 里最容易被误解的设计。

```cangjie
@JsonRpcMeta['慢查询', '5s']     // 显式超时
@JsonRpcMeta['普通查询', '']      // 空串 = 不设超时
```

- **默认不设超时**：`@JsonRpcMeta` 没写、或第二参数是空串时，handler 在**请求线程内联执行**，`CurrentHttpContext` 等请求级 ThreadLocal 完整可用；
- **只有显式配置超时才会 `spawn` 子线程**，并在子线程内用 `CurrentHttpContext.scoped` 恢复上下文。

为什么默认不设？因为「超时」在服务端本质上是个假概念：**你没法真的杀掉一个正在跑的 handler**（仓颉没有抢占式取消）。超时能做的只是「不再等它」，然后返回 `-32002`。

于是就有了这条必须写进文档的警告：

> 超时后返回 `-32002`，**但 handler 不会终止**。长循环里用 `ctx.isExpired()` 自查，带副作用的操作必须幂等。

如果默认就开 500ms 超时，业务会大面积出现「客户端收到超时、服务端还在写库」——这比不设超时危险得多。**默认不做半吊子的事**，这是这个设计的核心。

---

## 五、参数校验：schema 在注册期编译

```cangjie
JsonRpcMethodMeta(
    name: 'kb.search',
    handler: ...,
    paramsSchema: schema      // JsonObject 形式的 JSON Schema
)
```

注册期用 `f_data.CompiledSchema.compile` 做结构校验并预编译 `pattern`，请求期直接复用编译结果。

**脏 schema 在启动时就报错**，而不是等第一次请求打进来才发现。失败返回 `-32602`，`error.data` 是 `ValidationResult.toJson()`——客户端能拿到「哪个字段、哪条规则没过」。

不支持 `$ref` / `allOf` / `anyOf` / `oneOf` / `not`，对这些是 fail-closed（直接判失败）。理由和前面一致：**宁可拒绝，也不要给一个「看起来通过了」的错误结果**。

---

## 六、客户端：重试边界画在哪

```cangjie
let client = JsonRpcClient('http://127.0.0.1:8080/rpc', opts: ClientOptions(
    timeout: Duration.second * 10,            // 默认 30s
    headers: headers,                         // 额外请求头，如 Authorization
    maxResponseBytes: 4 * 1024 * 1024,        // 默认 8 MiB
    keepAlive: true,
    retryOnConnectFailure: 2                  // 默认 0
))
```

最重要的一条是**重试边界**：

| 阶段 | 失败 | 是否重试 |
| --- | --- | --- |
| 建立连接 | `JsonRpcConnectException` | 按 `retryOnConnectFailure` 重试 |
| 发送请求 | `JsonRpcConnectException` | 按配置重试 |
| 读响应 | IO / 解析失败 | **永不重试**（服务端可能已经执行） |

服务端返回的 `error` 一律转成 `JsonRpcException`（带 `code` / `message` / `data`），只有传输失败才抛 `IOException`。**「业务错误」和「通讯错误」必须是两种异常**，否则客户端没法决定「要不要重试」。

响应大小也有硬上限：先用 `Content-Length` 预判，再流式累计字节数，超过 `maxResponseBytes` 立即停止读取并关闭连接。防止一个恶意/异常服务端把客户端内存打满。

---

## 七、`f_mcp`：MCP 不是新协议

MCP（Model Context Protocol）经常被描述成「AI 的工具协议」，听起来像要重造一套 RPC。但拆开看，它的消息层就是 JSON-RPC 2.0：

```
   McpClient ──── JSON-RPC 2.0 (POST /mcp) ────► McpServer
             └─── SSE (GET /mcp/sse) ─────────► 订阅通知
```

**MCP 加的是语义，不是协议**：能力协商、工具、资源、提示词、订阅、限流、结果处理。所以 `f_mcp` 复用了 `f_jsonrpc` 的全部消息层能力（单调 id、响应 id 匹配、错误映射），自己只实现语义。

### 版本：无握手，逐请求校验

`f_mcp` 只实现 **MCP 2026-07-28** 这一版，不搞多版本共存。

它**不实现** `initialize` / `notifications/initialized` 握手。取而代之的是：每个请求在 `params._meta` 里带上

```
io.modelcontextprotocol/protocolVersion
clientInfo
clientCapabilities
```

服务端逐请求校验；`server/discover` 的响应 `_meta` 回 `serverInfo`。版本不匹配返回 `-32022`，`error.data.supported` 给出支持列表。

为什么去掉握手？因为握手是**有状态**的：一旦协商完成，服务端就要为每个会话记住「这个客户端支持什么」。而无状态的逐请求校验让服务端可以水平扩展、可以随时重启。代价是每个请求多带几十字节。

对 legacy 对端，`initialize` 返回 `-32601`，`data` 里带 `legacyMethod` 与 `supportedVersion`——**明确告知，不静默降级**。静默降级会让客户端以为功能可用，然后在某个能力上突然失败。

### 已实现的方法

| 方法 | 说明 |
| --- | --- |
| `server/discover` | 版本、能力、`serverInfo` |
| `tools/list` / `tools/call` | 工具表与调用 |
| `resources/list` / `resources/read` | 资源 |
| `prompts/list` / `prompts/get` | 提示词 |
| `subscriptions/listen` | 订阅通知（配合 `/mcp/sse`） |

能力声明是诚实的：`tools.listChanged=false`、`resources.subscribe=false`、`prompts.listChanged=false`（没实现 `resources/subscribe`，就不声明）。未实现：`sampling` / `roots` / `logging` / `completions` / `resources/templates/list`。

**能力声明与实际实现一致**，比「全部声明 true 然后部分不可用」对客户端友好得多。

### 写一个 MCP 服务

```cangjie
@Mcp['kb-server']
public class KnowledgeService {
    public init() {}

    @McpToolMeta[name: 'kb.search', description: '知识库检索']
    public func search(req: SearchRequest): SearchResult {
        SearchResult(1, 'found: ${req.query}')
    }

    @McpResourceMeta[uri: '/doc', name: 'doc', description: '文档', mediaType: 'text/plain']
    public func doc(): ArrayList<ResourceContent> { ... }

    @McpPromptMeta[name: 'greet', description: '生成问候']
    public func greet(name: String,
        @McpPromptArg[description: '姓名'] title: String): ArrayList<PromptMessage> { ... }
}
```

约束很明确：

- **tool** 必须恰好一个参数，且是 `@DataAssist[props fields]` 类——`inputSchema` 由该类型生成；
- **resource** 必须无参数，`uri` 不能为空；
- **prompt** 的参数就是 `PromptArgument`，参数名即 `name`；
- `@Mcp` 自动加 `@Bean`，模块加载期完成注册并 `build()`。

返回值做了转换，所以方法可以直接返回业务对象：

| 函数 | 返回值 | 结果 |
| --- | --- | --- |
| tool | `CallToolResult` | 原样使用 |
| tool | `String` | 文本内容 |
| tool | 其它可转 JSON 的值 | JSON 文本；是对象时同时写 `structuredContent` |
| tool | `Unit` | 空内容 |
| resource | `String` | 一段 `text/plain` |
| prompt | `String` | 一条 `user` 消息 |

### 限流：三层合并 + 一个 SPI

MCP 的调用方是「模型」，最容易被一条循环调用打爆，所以限流是刚需。

配置分三层，**逐字段合并**（不是整体替换）：

```
mcp_rateLimit 配置  →  Builder.rateLimit  →  每工具 ToolRateLimit
     （全局默认）          （服务级）            （工具级，-1 继承、0 不限制）
```

检查顺序是固定的：

```
全局并发 → 工具并发 → 调用方并发 → perCallerRpm → perCallerToolRpm → perToolRpm
```

这个顺序有讲究：**被并发拒绝的请求不消耗 rpm 令牌**，rpm 拒绝会释放已占的并发槽位。否则「并发闸门挡住的请求」会白白吃掉配额，导致限流参数怎么调都不对。

超限返回 `-32050`，`data.scope` 指明是哪一层（`concurrency` / `concurrency_tool` / `concurrency_caller` / `caller` / `caller_tool` / `tool`），HTTP 场景同时返回 `429` + `Retry-After`。

调用方标识按优先级取：

```
X-Forwarded-For 第一段（需信任配置）
  → Authorization 的 SHA-256 前 16 字节
  → remoteAddr（去端口）
  → anonymous（本地调用为 local）
```

内置 4 种后端（`token-bucket` / `leaking-bucket` / `sliding-window` / `unlimited`），都基于 `f_concurrent` 的限流器。**跨实例限流**需要实现 `RateLimitBackend` 并注入共享存储：

```cangjie
public interface RateLimitBackend {
    static prop name: String
    static func new(): RateLimitBackend
    func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool
    func close(): Unit
}
```

`key` 已经带了作用域前缀（`c:` / `ct:` / `t:`），可以直接当共享存储的键——Redis 用 `INCR` + `EXPIRE 60` 做固定窗口，或 Lua 做令牌桶；数据库用单行 `UPDATE ... RETURNING` / 行锁。f_mcp 不内置 Redis 客户端，**避免绑定具体存储**。

一个诚实的边界：**并发闸门仍然是进程内的**。跨实例的全局并发需要网关或独立共享信号量。

### 结果太大怎么办

超过 `maxResultBytes`（默认 1 MB）时：

- 配了 `publicBaseUrl`：转成一个 `resource_link`，内容存 `ToolResultStore`（默认 256 条 / 256 MB / 10 分钟），可通过 `resources/read` 读回；
- 没配：按 UTF-8 字符边界截断（不会切出半个中文 / emoji），保留 `isError` / `resultType` / `inputRequired` / `requestState`，并标记 `data.truncated = true` 与 `data.limit`。

**截断而不报错**是给模型的友好设计：模型能看懂「结果被截断了，去读链接」，比收到一个 `-32603` 更有用。

`publicBaseUrl` 会影响三处，配错会踩：

1. 结果链接 `${publicBaseUrl}/mcp/tool-results/{token}`；
2. `subscriptions/listen` 返回的 `sseUrl`；
3. `McpResource.builder` 的相对 URI 补全（`/doc` → `${publicBaseUrl}/doc`）。

不配时：结果截断、`sseUrl` 为相对路径、`McpResource.builder('/doc', ...)` **在构建期抛 `McpException`**。

### 订阅：SSE 的三个数字

`subscriptions/listen` 返回 `subscriptionId` 与可直接连接的 `sseUrl`；`GET /mcp/sse?subscriptionId=N` 绑定同一个订阅者，每条事件是一个 JSON-RPC 通知。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| 订阅者总量 | 1024 | `maxSubscribers(...)` |
| 单订阅者队列 | 256 条 | 满了丢最旧并计数 |
| 断线保留 | 60 秒 | 期间可用同一个 `subscriptionId` 重连 |

心跳 15 秒，空闲连接阻塞等待（不是每 100ms 空转），响应 `Transfer-Encoding: chunked`。断线与 30 分钟到点都只 detach，不销毁——**重连能接上，比重新订阅省事**。

### 客户端

```cangjie
let client = McpClient.http('http://127.0.0.1:8080/mcp')
let tools = client.listAllTools()
let result = client.callTool('kb.search', arguments: args)

// input_required 自动多轮
let final = client.callToolAuto('kb.search', arguments: args, handler: {input =>
    JsonObject()      // 由调用方根据 inputRequired 生成 inputResponses
}, maxRounds: 4)

client.close()
```

stdio 传输：`McpClient.stdio('/usr/local/bin/my-mcp-server', args: ['--stdio'])`。

两种传输都复用 `f_jsonrpc.JsonRpcClient` 的消息层。stdio 忽略 `headers` / `keepAlive` / `maxResponseBytes`，读超时由 `timeout` 控制。

`Manual`（`callTool`）原样返回 `input_required`；`Auto`（`callToolAuto`）会自动把 `requestState` 带回下一轮。**「模型要问人要信息」这件事，协议层用一个 `resultType` 表达，而不是靠多次调用拼上下文**。

---

## 八、两个模块的分工

| 关注点 | `f_jsonrpc` | `f_mcp` |
| --- | --- | --- |
| 消息格式 | JSON-RPC 2.0 | 复用 |
| 端点 | `/rpc`、`/rpc/{topic}` | `/mcp`、`/mcp/sse` |
| 方法分发 | 方法表 + 命名空间 | 工具 / 资源 / 提示词三套表 |
| 错误码 | 标准码 + `-32001~-32004` | 增加 `-32022` / `-32040` / `-32050` |
| 超时 | 单方法可选 | 沿用 |
| 限流 | 无 | 三层合并 + SPI |
| 结果处理 | 原样返回 | 截断 / 外链 |

`f_mcp` 没有重新实现客户端连接、id 匹配、错误映射——它把「消息怎么传」这件事完全交给了 `f_jsonrpc`。**这就是分层的好处：语义层可以专心做语义。**

---

## 九、上线清单

**`f_jsonrpc`**

1. `@JsonRpc` 宏要用 `import fountain::f_jsonrpc.*`（门面包再导出了 `lookup` / `BeanFactory` / `TypeInfo`），只导 `server` / `base` 时要自己补。
2. 超时默认不设；**显式设了也不会终止 handler**，有副作用的逻辑要幂等，长循环用 `ctx.isExpired()` 自查。
3. 单参数必须写 `[值]` 或 `{"名": 值}`，不接受裸标量。
4. 批量上限默认 100（`-32003`），请求体上限默认取 `MVCConfig.maxRequestBodySize`（2 MiB，超限 HTTP 413 + `-32600`）。
5. 客户端只在建连/发送阶段重试；读响应阶段永不重试。
6. 业务错误码用 `-32020 ~ -32099`，别占用标准码段。

**`f_mcp`**

1. `publicBaseUrl` 影响结果链接、`sseUrl`、资源 URI 三处，生产必须配成对外可达地址。
2. tool 必须**恰好一个** `@DataAssist` 参数；resource 必须无参数。
3. `@McpToolMeta` 的数值默认 `-1`（继承），显式写 `0` 表示不限制——`0` 和「不写」不是一回事。
4. 限流并发闸门是进程内的；跨实例要注入 `RateLimitBackend`。
5. 只实现 2026-07-28，legacy `initialize` 返回 `-32601`，不支持降级。
6. `resources/subscribe` 未实现，能力声明里是 `false`——别按「已支持」写客户端。

---

## 一句话收尾

`f_jsonrpc` 把 JSON-RPC 2.0 接进 MVC，而不是另起一套 Web 框架；`f_mcp` 把 MCP 的语义接进 JSON-RPC，而不是另起一套协议。

**协议设计的高级感，不在于定义了多少方法，而在于每一层都只说这一层该说的话。**

---

**同系列**

- [编解码器与应用通讯协议](fountain实现思想与应用第10弹——编解码器与应用通讯协议.md)
- [RPC实现](fountain实现思想与应用第11弹——RPC实现.md)
- [数据库中间件](fountain实现思想与应用第12弹——数据库中间件.md)
- [消息队列](fountain实现思想与应用第13弹——消息队列.md)
