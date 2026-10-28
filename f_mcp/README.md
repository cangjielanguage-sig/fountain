# f_mcp

`f_mcp` 是 MCP（Model Context Protocol）的客户端 / 服务端 SDK。消息层完全复用 `f_jsonrpc`，本模块只实现 MCP 语义：版本与能力、`server/discover`、工具、资源、提示词、订阅、限流与结果处理。

- 协议版本：`2026-07-28`（无握手；逐请求 `_meta` 校验）
- 服务端：`/mcp`（JSON-RPC）+ `/mcp/sse`（订阅推送）
- 客户端：HTTP（复用 `JsonRpcClient`）与 stdio（子进程）
- 依赖：`f_jsonrpc` / `f_data` / `f_log` / `f_mvc`（controller）、`f_concurrent`（限流）、`f_config`（`mcp_rateLimit` / `mcp_version`）

## 包结构

| 包 | 内容 |
|----|------|
| `fountain::f_mcp.base` | `McpProtocol`、`McpException`、内容模型（`ContentBlock` / `CallToolResult` / `ResourceContent` / `PromptMessage`） |
| `fountain::f_mcp.client` | `McpClient` |
| `fountain::f_mcp.server` | 服务端、工具 / 资源 / 提示词、注解、限流、结果与 SSE |
| `fountain::f_mcp.macros` | `@Mcp` 宏（独立包） |
| `fountain::f_mcp` | 门面包：`public import` 以上三个包，兼容 `import fountain::f_mcp.*` |

只写服务端时可 `import fountain::f_mcp.server.*` + `fountain::f_mcp.base.*`，客户端用
`fountain::f_mcp.client.*` + `fountain::f_mcp.base.*`。使用 `@Mcp` 宏时建议 `import fountain::f_mcp.*`：
宏展开会用到门面包再导出的 `lookup` / `BeanFactory` / `TypeInfo` / `ArrayList` / `JsonValue`。

## 规范版本

- **MCP 2026-07-28**（[规范](https://modelcontextprotocol.io/specification/2026-07-28)），只实现这一版，不做多版本共存
- 消息格式：**JSON-RPC 2.0**，消息层由 `f_jsonrpc` 提供
- 无握手：不实现 `initialize` / `notifications/initialized`；每个请求在 `params._meta` 携带 `io.modelcontextprotocol/protocolVersion`、`clientInfo`、`clientCapabilities`，`server/discover` 的响应 `_meta` 回 `serverInfo`
- 发现：`server/discover`；版本不匹配返回 `-32022`，`error.data.supported` 给出支持列表
- 已实现方法：`server/discover`、`tools/list`、`tools/call`、`resources/list`、`resources/read`、`prompts/list`、`prompts/get`、`subscriptions/listen`
- 能力声明：`tools.listChanged=false`、`resources.subscribe=false` + `resources.listChanged=false`、`prompts.listChanged=false`（没有实现 `resources/subscribe`，因此不声明）
- 传输：`POST /mcp` 返回单个 JSON 响应，`GET /mcp/sse` 推送订阅通知（`text/event-stream`）；无会话 id，服务端不主动发请求
- 未实现：`sampling` / `roots` / `logging` / `completions` / `resources/templates/list`；需要向客户端索取信息的场景走 `tools/call` 的 `resultType: "input_required"`
- 扩展：`-32050` 限流、`-32040` 资源不存在（`-32002` 留给 f_jsonrpc 超时）、结果外链 `/mcp/tool-results/`
- legacy 对端：`initialize` / `notifications/initialized` 返回 `-32601`，`data` 带 `legacyMethod` 与 `supportedVersion`，不静默降级

设计取舍见 [`doc/f_mcp模块设计.md`](doc/f_mcp模块设计.md)。

## 服务端

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
             .description('知识库检索')
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

字段（`@DataAssist` 类）可以直接生成 schema：

```cangjie
McpTool.of<SearchRequest>('kb.search')
```

### 用注解注册（`@Mcp`）

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

    @McpToolMeta[name: 'kb.search', description: '知识库检索']
    public func search(req: SearchRequest): SearchResult {
        SearchResult(1, 'found: ${req.query}')
    }

    @McpResourceMeta[uri: '/doc', name: 'doc', description: '文档', mediaType: 'text/plain']
    public func doc(): ArrayList<ResourceContent> {
        // 返回 ResourceContent 列表
    }

    @McpPromptMeta[name: 'greet', description: '生成问候']
    public func greet(name: String, @McpPromptArg[description: '姓名'] title: String): ArrayList<PromptMessage> {
        // 返回 PromptMessage 列表
    }
}
```

- `@Mcp` 自动给类加 `@Bean`，在模块加载期完成注册并调用 `McpRegistry.build()`
- `McpRegistry.build()` 可以重复调用：每次按当前累计的注册重建 `McpServer`，新注册的 tool / resource / prompt 立即生效；因此一个进程可以有多个 `@Mcp` 类，也允许 `main()` 里继续 `configure`（下一次 `build()` 或 `configure` 会自动重建）。只应在启动阶段调用（会重建结果缓存、订阅与限流状态）
- 属性 `@Mcp['kb-server']` 或 `@Mcp[kbServer]` 指定 `serverInfo.name`（字符串常量或标识符）；不写属性时 name 为 `fountain-mcp`
- `serverInfo.version` 取配置项 `mcp_version`，未配置时为 `1.0.0`
- **tool**：函数必须恰好一个参数，参数是 `@DataAssist[props fields]` 类；`inputSchema` 由该类型生成
- `@McpToolMeta` 的 `perCallerRpm` / `perCallerToolRpm` / `perToolRpm` / `maxConcurrency` / `perCallerConcurrency` 直接映射为 `ToolRateLimit`：`-1`（默认）沿用服务级配置、`0` 表示不限制、`>0` 表示限额
- **resource**：函数必须无参数；`uri` 不能为空；`mediaType` 对应 `McpResource.mimeType`；示例中的 `/doc` 需要配置 `mcp_publicBaseUrl`
- **prompt**：函数参数就是 `PromptArgument`，参数名即 `name`；`@McpPromptArg` 提供 `description` / `required`（默认 `true`）；可选参数建议用 `Option<T>`
- 注解里的 `name` 为空时回退到函数名；没有这三个注解的 public 函数会被忽略

`server/discover` 返回的 `serverInfo` 形如：

```json
{"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"kb-server","version":"1.0.0"}}}
```

直接使用 `Builder` 时，`serverInfo(name, version)` 的 `version` 传空串表示取 `mcp_version`；
显式传入非空值则以显式值为准。

#### 入参与返回值转换

入参按 `f_data` 的 `fromJson` 规则从 JSON 转成函数声明的参数类型；返回值按 `toJson` 规则
（`McpConvert`）转成 MCP 结果，因此方法可以直接返回业务对象：

| 函数 | 返回值 | 结果 |
|------|--------|------|
| tool | `CallToolResult` | 原样使用 |
| tool | `String` | 文本内容 |
| tool | 其它可转 JSON 的值 | JSON 文本，且是对象时同时写入 `structuredContent` |
| tool | `Unit` | 空内容 |
| resource | `ArrayList<ResourceContent>` | 原样使用 |
| resource | `String` | 一段 `text/plain` 内容 |
| resource | 其它可转 JSON 的值 | 一段 `application/json` 内容 |
| resource | `Unit` | 一段空文本内容 |
| prompt | `ArrayList<PromptMessage>` | 原样使用 |
| prompt | `String` / 其它可转 JSON 的值 | 一条 `user` 消息 |
| prompt | `Unit` | 没有消息 |

`@McpResourceMeta` 的 `mediaType` 非空时覆盖内容里的 `mimeType`。

对应的注册 API 也可以直接调用：

```cangjie
McpRegistry.getToolMeta<T>(name, argTypes)
McpRegistry.getResourceMeta<T>(name, argTypes)
McpRegistry.getPromptMeta<T>(name, argTypes)
McpRegistry.build()
```

### 公共地址与资源 URI

`publicBaseUrl` 是本服务对外暴露的根地址，用于生成绝对 URL。

#### 配置方式

`Builder` 优先于配置项：

```cangjie
b.publicBaseUrl('https://mcp.example.com')
```

```bash
export mcp_publicBaseUrl=https://mcp.example.com
```

两处都会去掉末尾 `/`；为空表示未配置。

它影响三处：

- 结果链接：`${publicBaseUrl}/mcp/tool-results/{token}`
- `subscriptions/listen` 返回的 `sseUrl`
- `McpResource.builder` 的相对 URI 补全

#### `McpResource.builder` 的 uri

第一个参数支持两种写法：

| 传入 | 结果 |
|---|---|
| `/doc` | `${publicBaseUrl}/doc` |
| `https://docs.example.com/doc` | 原样使用，不拼接 `publicBaseUrl` |

```cangjie
// 相对路径：需要 publicBaseUrl
McpResource.builder('/doc', 'doc')

// 完整 URL：与 publicBaseUrl 无关
McpResource.builder('https://docs.example.com/doc', 'doc')
```

`//example.com/doc`、`file://`、不带 `/` 的相对路径、含 `#fragment` 的 URI 都会在构建期抛 `McpException`。

未配置 `publicBaseUrl` 时：结果截断、`sseUrl` 为相对路径、`McpResource.builder('/doc', ...)` 在构建服务时抛 `McpException`。

### 方法

| 方法 | 说明 |
|---|---|
| `server/discover` | 版本、能力、`serverInfo` |
| `tools/list` / `tools/call` | 工具表与调用 |
| `resources/list` / `resources/read` | 资源（完整 http/https/ftp URL，或以 `/` 开头的路径） |
| `prompts/list` / `prompts/get` | 提示词 |
| `subscriptions/listen` | 订阅通知（配合 `/mcp/sse`） |

`initialize` 等 legacy 方法返回 `-32601` + `data.legacyMethod`，提示客户端升级。

### 限流

三层逐字段合并：`mcp_rateLimit` 配置 → `Builder.rateLimit` → 每工具 `ToolRateLimit`（未写的字段继承上一层，不再整体替换）。

限流维度：调用方 / 调用方×工具 / 工具全局，加上服务级全局并发与工具级并发。

检查顺序固定为「全局并发 → 工具并发 → 调用方并发 → perCallerRpm → perCallerToolRpm → perToolRpm」：
被并发拒绝的请求**不消耗** rpm 令牌，rpm 拒绝会释放已占的并发槽位。超限返回 `-32050`，
`data.scope` 为 `concurrency` / `concurrency_tool` / `concurrency_caller` / `caller` / `caller_tool` / `tool`；
HTTP 场景同时返回 `429` + `Retry-After`。

调用方标识按优先级取：`X-Forwarded-For` 第一段（仅 `mcp_trustForwardedFor=true` 或
`Builder.trustForwardedFor(true)` 时信任）→ `Authorization` 的 SHA-256 前 16 字节 →
`remoteAddr`（去掉端口）→ `anonymous`（本地调用为 `local`）。

单实例内置 4 种 `RateLimitBackend`，都基于 `f_concurrent` 的限流器；每个限流 key 一个 limiter，
池有容量与空闲 TTL，淘汰时会真正 `close()` 掉 limiter 的定时器：

| `mcp_rateLimitBackend` | 算法 | 语义 |
|---|---|---|
| `token-bucket`（默认） | `TokenBucketRateLimiter` | 每分钟 `rpm`，允许突发到 `rpm` |
| `leaking-bucket` | `LeakingBucketRateLimiter` | 每分钟漏出 `rpm`，等待队列上限 `rpm` |
| `sliding-window` | `SlidingWindowRateLimiter` | 1 分钟滑动窗口，上限 `rpm` |
| `unlimited` | `UnlimitedRateLimiter` | 不限制 |

`Builder.rateLimitBackend(...)` 显式注入优先于配置。名字大小写与 `-` / `_` 不敏感；未知名字在 `build()` 时抛 `IllegalArgumentException`。

#### `RateLimitBackend` 与 `RateLimitBackends`

`RateLimitBackend` 是限流算法 SPI；内置的 4 种实现已在模块加载时注册到 `RateLimitBackends`
（`any-moment` 已移除：SPI 只有 acquire 没有 release，选择它等于静默关闭限流，配置引用会直接报错）：

```cangjie
public interface RateLimitBackend {
    static prop name: String              // 算法名，也是注册键
    static func new(): RateLimitBackend   // 创建实例
    func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool
    func close(): Unit                    // McpServer.close() 时调用
}
```

自定义实现：

```cangjie
public class MyRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() { 'my-algo' }
    }

    public static func new(): RateLimitBackend {
        MyRateLimitBackend()
    }

    public func tryAcquire(key: String, rpm: Int64, nowNanos: Int64): Bool {
        // key 已带作用域前缀：c: / ct: / t:
        // rpm <= 0 表示不限制
        true
    }

    public func close(): Unit {}
}
```

注册与使用：

```cangjie
// 1. 注册；同名会覆盖内置实现
RateLimitBackends.register<MyRateLimitBackend>()

// 2a. 配置选择：export mcp_rateLimitBackend=my-algo
// 2b. 或直接注入
let server = McpServer.builder()
    .rateLimitBackend(RateLimitBackends.of('my-algo'))
    .build()
```

`RateLimitBackends.of(name)` 按名字创建实例，未注册时抛 `IllegalArgumentException`；名称大小写与 `-` / `_` 不敏感。

全局默认值可由 `mcp_rateLimit` 与 `mcp_rateLimitBackend` 提供：

```bash
# perCallerRpm,perCallerToolRpm,perToolRpm,maxConcurrency,perCallerConcurrency
export mcp_rateLimit=600,120,6000,64,8

# 或 JSON，省略的字段表示不限制
export mcp_rateLimit='{"perCallerRpm":600,"perCallerToolRpm":120,"perToolRpm":6000}'

# 限流算法
export mcp_rateLimitBackend=sliding-window
```

**跨进程限流**：`f_concurrent` 的限流器是进程内的，不能直接跨进程。需要实现 `RateLimitBackend` 并注入：

```cangjie
b.rateLimitBackend(myRedisBackend)   // 多实例共享同一个 Redis / 数据库
```

`tryAcquire(key, rpm, nowNanos)` 的 `key` 已经带了作用域前缀（`c:` / `ct:` / `t:`），可以直接作为共享存储的键。Redis 可用 `INCR key` + `EXPIRE 60` 做固定窗口，或用 Lua 脚本做令牌桶；数据库可用单行 `UPDATE ... RETURNING` / 行锁。f_mcp 不内置 Redis 客户端，避免绑定具体存储。

并发闸门（`maxConcurrency` / `perCallerConcurrency`）仍是进程内的；跨实例的全局并发需要网关或独立的共享信号量。

### 结果

超过 `maxResultBytes`（默认 1 MB）时：

- 配了 `publicBaseUrl`：转成一个 `resource_link`，内容存 `ToolResultStore`（默认 256 条 / 256 MB / 10 分钟），可通过 `resources/read` 读回
- 没配：按 UTF-8 字符边界截断（不会切出半个中文 / emoji），保留 `isError` / `resultType` / `inputRequired` / `requestState`，并标记 `data.truncated = true` 与 `data.limit`

`ToolResultStore` 默认开启运行期自适应调容：按窗口统计拒绝率与占用率，只调 `maxEntries`（`ResultStoreOptions` 可配 `floor` / `ceiling` / 阈值 / 窗口）。

### 订阅与 SSE

`subscriptions/listen` 返回 `subscriptionId` 和可直接连接的 `sseUrl`；`GET` 该 URL（`/mcp/sse?subscriptionId=N`）会绑定到同一个订阅者，每条事件是一个 JSON-RPC 通知。也支持 `?topics=tools/list_changed`（查询串做百分号解码与 trim；显式 `topics=` 返回 400，不会反转成「订阅全部」）。

- 订阅者总量上限 1024、单订阅者队列 256 条（满了丢最旧并计数）、未连接保留 60 秒，可用
  `McpServerBuilder.maxSubscribers(...)` / `subscriberQueueCapacity(...)` / `subscriberDetachedTtl(...)` 调整
- 断线与 30 分钟到点都只 detach：grace 内可用同一个 `subscriptionId` 重连
- 心跳 15 秒；空闲连接阻塞等待（不再每 100ms 空转）；响应使用 `Transfer-Encoding: chunked`

客户端可直接用 `McpClient.listen(topics)` 获取订阅结果：

```cangjie
let sub = client.listen(['tools/list_changed'])
let sseUrl = sub.sseUrl
```

## 客户端

```cangjie
import fountain::f_mcp.client.*
import fountain::f_mcp.base.*
import fountain::f_data.*

let client = McpClient.http('http://127.0.0.1:8080/mcp')
let tools = client.listAllTools()
let result = client.callTool('kb.search', arguments: args)

// input_required 自动多轮
let final = client.callToolAuto('kb.search', arguments: args, handler: {input =>
    JsonObject()   // 由调用方根据 inputRequired 生成 inputResponses
}, maxRounds: 4)

client.close()
```

stdio：

```cangjie
let client = McpClient.stdio('/usr/local/bin/my-mcp-server', args: ['--stdio'])
```

- 每次请求自动注入 `_meta`（版本、`clientInfo`、`clientCapabilities`）
- 服务端返回 `-32022` 时换用 `supported[0]` 只重试一次；版本由 `Mutex` 保护，并发命中只改写一次
- `Manual`（`callTool`）原样返回 `input_required`；`Auto` 用 `callToolAuto`，并把 `requestState` 原样带回下一轮

客户端返回强类型（都来自 `f_mcp.base`），字段可直接访问；需要原文时用 `.toJson()`（或 `DiscoverResult.raw` / `McpToolDescriptor.raw`）：

| 方法 | 返回 |
|---|---|
| `discover` | `DiscoverResult` |
| `listTools` | `ToolPage` |
| `listAllTools` | `Array<McpToolDescriptor>` |
| `callTool` / `callToolAuto` | `CallToolResult`（源兼容别名 `McpCallToolResult`） |
| `listResources` | `ResourcePage` |
| `readResource` | `ReadResourceResult` |
| `listPrompts` | `PromptPage` |
| `getPrompt` | `GetPromptResult` |
| `listen` | `ListenResult` |

`CallToolResult.content` 是 `ContentBlock`；未知内容块类型不会被丢弃（`kind()` 返回服务端原文，`toJson()` 可还原）。

### 客户端选项

```cangjie
let options = McpClientOptions()
options.timeout = Duration.second * 10            // 默认 30s
options.headers.add('Authorization', 'Bearer x')  // 仅 HTTP；stdio 忽略
options.maxResponseBytes = 4 * 1024 * 1024        // 仅 HTTP；默认 8 MiB
options.keepAlive = false                         // 仅 HTTP；false 发送 Connection: close
options.retryOnConnectFailure = 2                 // 仅建连失败重试；默认 0
let client = McpClient.http('http://127.0.0.1:8080/mcp', options: options)
```

HTTP 与 stdio 都复用 `f_jsonrpc.JsonRpcClient` 的消息层（单调 id、响应 id 匹配、错误映射）；
stdio 忽略 `headers` / `keepAlive` / `maxResponseBytes`，读超时由 `timeout` 控制。


## 迁移（1.3.17 → 下一版）

| 变更 | 影响 | 迁移 |
|---|---|---|
| `RESOURCE_NOT_FOUND` 从 `-32002` 迁到 `-32040` | 按码分支的客户端 | 判断 `-32040` |
| `decodeCursor` 返回 `?Int64` | 直接使用返回值的代码 | 显式处理 `None` → `-32602` |
| `mcp_rateLimitBackend=any-moment` 移除 | 配置引用启动报错 | 换 `token-bucket` / `sliding-window` |
| `ToolRateLimit.maxConcurrency` 语义 | 以前被当成全局上限 | 全局用 `RateLimitPolicy.maxConcurrency` |
| `@McpToolMeta` 数值默认 `0` → `-1` | 显式写 `0` 从「继承」变「不限制」 | 想继承就不写该字段 |
| `JsonRpcContext.meta` / `mcp_rateLimit` 校验收紧 | 非法配置启动失败 | 按错误消息修正配置 |
| MCP 客户端返回强类型 | 依赖 `JsonObject` 与下标取值的代码 | 改用模型字段（如 `page.tools[0].name`），或 `.toJson()` / `.raw` |
| `McpCallToolResult.content` 元素变为 `ContentBlock` | 原来按数组下标读 `text` | 用 `content[0].toJson()['text']` 或 `kind()` |

## 测试

```bash
cjpm test
```

测试按包分布：`client` 覆盖 HTTP / stdio 客户端、`_meta` 注入与多轮调用，`server` 覆盖协议发现、版本 / legacy、工具 / 资源 / prompts、限流、结果与自适应存储、订阅与 SSE 格式。

## 已知限制

- 分布式限流提供 `RateLimitBackend` SPI；默认实现基于 `f_concurrent` 令牌桶，仍是进程内，跨实例需注入共享存储后端
- SSE 依赖 `f_mvc` 的流式响应，并且必须声明 `Transfer-Encoding: chunked`；端到端由 `fmcpdemo/boot.sh e2e` 覆盖
- 不做 `prompts/list_changed` 推送（能力里固定 `false`）

## 端到端 demo

`fmcpdemo` 提供可运行的 server / client：

```bash
cd fmcpdemo
./boot.sh e2e 18082
```

客户端走 HTTP 覆盖 `server/discover`、`tools/list`、`tools/call`、`resources/read`、`prompts/get`，再订阅 `/mcp/sse` 并触发一条 `notifications/tools/list_changed`。服务端启动时还会用两个共享 `RateLimitBackend` 的 `McpServer` 验证第 4 次调用返回 `-32050`。
