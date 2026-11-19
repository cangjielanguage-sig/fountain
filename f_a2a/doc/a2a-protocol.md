# 用 `fountain::f_jsonrpc` 实现 Agent-to-Agent 协议

本文是 `f_a2a` 模块的设计基线：把 [A2A 协议](https://a2a-protocol.org/)（Agent2Agent）的**最小可用子集**
落到 `fountain::f_jsonrpc`（JSON-RPC 2.0 over HTTP）上。实现按本文逐条落地，规格与测试也由本文派生。

---

## 1. 为什么能这样映射

A2A 的线上协议就是「HTTP POST + JSON-RPC 2.0 方法调用」，与 `f_jsonrpc` 完全同构：

| A2A 概念 | `f_jsonrpc` 里对应物 |
|---|---|
| JSON-RPC 方法（`message/send` 等） | `JsonRpcRegistry.register(JsonRpcMethodMeta(...))` 或 `@JsonRpc[namespace: a2a]` |
| 请求参数对象 | JSON-RPC `params`（命名参数对象，`f_a2a` 用 `@DataAssist` 定义） |
| 错误（`TaskNotFoundError` 等） | `JsonRpcException(code, message, data)`，业务码段 `-32020 ~ -32099` |
| Agent Card（`GET /.well-known/agent.json`） | **不走 JSON-RPC**：由应用自己挂一条 `f_mvc` GET 路由，内容由 `A2aAgentCard` 序列化 |
| 流式（SSE `message/stream`） | `f_jsonrpc` 新增 SSE 传输扩展（`GET /rpc/stream` + `SseHub`，见 §7）；事件体仍是 JSON-RPC 通知 |

于是 `f_a2a` 只补三样东西，不重造传输、路由、鉴权、线程池与日志：
**数据模型**（Task / Message / Part / Artifact / AgentCard）、**任务状态机与存储**、**方法处理器与客户端薄封装**。

> 前置依赖：`f_a2a` 的流式与回调能力依赖 `f_jsonrpc` 的 SSE 扩展（`add-jsonrpc-sse`）。
> **`f_mvc` 不改**——SSE 复用它对 `InputStream` 响应体的既有支持。

---

## 2. 协议映射

方法名统一加 `a2a.` 命名空间，便于 `POST /rpc/a2a` 只暴露 A2A 方法。

| A2A 规范方法 | 本实现注册的 JSON-RPC 方法 | 说明 |
|---|---|---|
| `message/send` | `a2a.message.send` | 同步：建任务 → 执行 → 返回终态任务或 `input-required` |
| `tasks/get` | `a2a.tasks.get` | 按 `id` 取任务；未找到返回 `-32020` |
| `tasks/cancel` | `a2a.tasks.cancel` | 仅 `submitted` / `working` 可取消，否则 `-32021` |
| `message/stream` | `a2a.message.stream` | 建任务并执行，状态/产物事件经 SSE 推送（§7.1） |
| `tasks/resubscribe` | `a2a.tasks.resubscribe` | 按 `taskId` 重订阅，带 `Last-Event-ID` 补发 |
| `tasks/pushNotificationConfig/set` / `get` / `delete` | `a2a.pushConfig.set` / `.get` / `.delete` | 注册 / 查询 / 删除回调 URL |
| `agent/getAuthenticatedExtendedCard` | `a2a.agent.extendedCard` | 返回带扩展字段的卡片 |

### 错误码

| 码 | 含义 | 触发 |
|---|---|---|
| `-32700 ~ -32603` | JSON-RPC 标准错误 | 由 `f_jsonrpc` 产生，`f_a2a` 不重复定义 |
| `-32020` | `TaskNotFoundError` | `tasks/get`、`tasks/cancel` 找不到 id |
| `-32021` | `TaskNotCancelableError` | 任务已是终态 |
| `-32022` | `UnsupportedOperationError` | 调用了未实现的方法 |
| `-32023` | `ContentTypeNotSupportedError` | `Part` 不是 `text`（本实现只支持文本） |
| `-32024` | `TaskRejectedError` | 执行器返回 `rejected` |

`data` 里放 `{"taskId": "..."}`，便于客户端定位。

---

## 3. 数据模型

全部放在 `fountain::f_a2a.model`，用 `@DataAssist[props fields]` 定义，保证 `JsonValue` ↔ 对象的双向转换与 `f_jsonrpc` 的参数绑定一致。

### 3.1 AgentCard

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | `String` | 代理名称 |
| `description` | `String` | 一句话职责 |
| `url` | `String` | JSON-RPC 端点（通常 `http://host/rpc/a2a`） |
| `version` | `String` | 代理版本 |
| `capabilities` | `A2aCapabilities` | 能力位：`streaming` / `pushNotifications`（本实现恒 `false`） |
| `skills` | `ArrayList<A2aSkill>` | 技能清单（`id` / `name` / `description` / `tags`） |
| `defaultInputModes` | `ArrayList<String>` | 恒 `["text/plain"]` |
| `defaultOutputModes` | `ArrayList<String>` | 恒 `["text/plain"]` |

### 3.2 Task

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `String` | 服务端生成（`task-<时间戳>-<序号>`） |
| `contextId` | `String` | 会话/上下文标识，客户端可复用 |
| `status` | `A2aTaskState` | 见 §3.3 |
| `statusMessage` | `?A2aMessage` | 终态时的说明消息（可空） |
| `artifacts` | `ArrayList<A2aArtifact>` | 执行产物 |
| `history` | `ArrayList<A2aMessage>` | 消息历史（请求 + 响应） |
| `createdAt` / `updatedAt` | `Int64` | epoch 秒 |

### 3.3 状态机

```
submitted ──> working ──┬──> completed
                        ├──> failed
                        ├──> canceled
                        └──> input-required ──> working ──> ...
```

- `send` 同步执行：入口即刻置 `working`，执行器返回后落终态；
- `cancel` 只接受 `submitted` / `working`；
- `input-required` 是**非终态**：本轮返回该状态，客户端带同一 `contextId` 再发 `send` 继续。

### 3.4 Message / Part / Artifact

```cangjie
public class A2aPart {
    public var kind: String = 'text'     // text | file | data
    public var text: String = ''          // kind=text
    public var url: String = ''           // kind=file：外部可取的 URL，不内联字节
    public var mimeType: String = ''      // kind=file / data
    public var data: String = ''          // kind=data：小段结构化 JSON（字符串形式）
}

public class A2aMessage {
    public var role: String = 'user'     // user | agent
    public var parts: ArrayList<A2aPart>
    public var messageId: String
    public var taskId: String = ''
    public var contextId: String = ''
}

public class A2aArtifact {
    public var artifactId: String
    public var name: String = ''
    public var parts: ArrayList<A2aPart>
}
```

---

## 4. 服务端

### 4.1 组成

```cangjie
public interface A2aTaskStore {
    func save(task: A2aTask): Unit
    func get(id: String): ?A2aTask
    func list(limit: Int64): ArrayList<A2aTask>
}

public interface A2aExecutor {
    /** 处理一次 send；返回值决定任务终态 */
    func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult
}

public class A2aServer {
    public init(agentCard: A2aAgentCard, executor: A2aExecutor, store!: A2aTaskStore = InMemoryA2aTaskStore())
    /** 把 a2a.message.send / a2a.tasks.get / a2a.tasks.cancel 注册进 JsonRpcRegistry */
    public func register(): Unit
}
```

`A2aExecutionResult` 三选一：`text(...)`（→ `completed` + artifact）、`needsInput(...)`（→ `input-required`）、
`failed(...)`（→ `failed`，`statusMessage` 带原因）。

### 4.2 注册

```cangjie
let server = A2aServer(card, MyExecutor())
server.register()          // 进程内注册一次；重复调用是幂等的
```

`register()` 内部用 `JsonRpcRegistry.register(JsonRpcMethodMeta(name: 'a2a.message.send', handler: ...))`，
**超时不设**（同步执行，`CurrentHttpContext` 等请求级上下文可用）。需要超时由宿主在处理函数里自行控制。

### 4.3 Agent Card

```cangjie
@Controller
public class MyAgentCardController {
    @GetMapping[path: '/.well-known/agent.json']
    public func card(): String {
        A2aAgentCard.json(server.card)
    }
}
```

`f_a2a` 不自动挂路由：`/.well-known/agent.json` 属于宿主应用的 HTTP 面，模块只提供序列化。

### 4.4 幂等与并发

- `message.send` **不幂等**：每次调用都建新任务（A2A 规范允许，`messageId` 由客户端生成）；
- 任务存储默认内存实现，进程重启即丢；需要持久化时实现 `A2aTaskStore`（如落到 `f_store`）并注入；
- `A2aServer` 的方法处理器无共享可变状态，并发安全由 `store` 的实现负责（内存版用 `Mutex`）。

---

## 5. 客户端

```cangjie
let client = A2aClient('http://127.0.0.1:8080/rpc/a2a')
let task = client.send(A2aMessage(parts: [A2aPart(text: '帮我把今天的提交汇总一下')]))
let again = client.get(task.id)
let _ = client.cancel(task.id)
client.close()
```

- 薄封装 `JsonRpcClient`：`send` → `a2a.message.send`，`get` → `a2a.tasks.get`，`cancel` → `a2a.tasks.cancel`；
- `JsonRpcException` 原样抛出（含 `-32020` 等业务码），不吞成「空任务」；
- 重试边界沿用 `f_jsonrpc`：只有建连失败会重试，读响应阶段失败永不重试（服务端可能已执行）；
- 连接池、响应上限、超时都由 `ClientOptions` 透传。

---

## 6. 一次完整交互

```
客户端                        服务端
  │  POST /rpc/a2a                   │
  │  {"method":"a2a.message.send",   │
  │   "params":{"message":{...}},   │
  │   "id":1}                        │
  │ ───────────────────────────────> │ 1. 建任务（submitted）
  │                                  │ 2. 置 working，调用 executor
  │                                  │ 3. 落终态 + artifact + history
  │ <─────────────────────────────── │ 4. 返回 Task JSON
```

同步语义是刻意的：`f_jsonrpc` 没有 SSE，异步推送无处可推；需要「长任务」时用
`input-required` + 轮询 `tasks/get`（§3.3），或用 `notify`（无 `id`）触发后台执行后轮询。

---

## 7. 流式与扩展能力（SSE 落在 `f_jsonrpc`，`f_mvc` 不动）

A2A 的五个「高级能力」全部要实现，但它们**都不该由 `f_mvc` 承担**：`f_mvc` 是通用 Web 框架，
改动它会把影响面扩散到所有模块。做法是在 `f_jsonrpc` 内部加一层 SSE 传输扩展，`f_a2a` 在其上实现 A2A 语义。

| A2A 能力 | 落地方式 | 依赖的 `f_jsonrpc` 能力 |
|---|---|---|
| `message/stream` | `a2a.message.stream` 触发执行，把状态/产物事件通过 SSE 推给订阅者 | `SseHub`（订阅/广播）+ `GET /rpc/stream` 端点 |
| `tasks/resubscribe` | 按 `taskId` 重新订阅同一任务的 SSE 流，带 `Last-Event-ID` 补发 | 同上 + 事件 id 单调递增 |
| `tasks/pushNotificationConfig/*` | 客户端注册 `{url, token}`；任务状态变化时 `f_httpclient` POST 通知 | 无（`f_a2a` 内部实现） |
| 非文本 `Part`（file / data） | `Part.kind = "file"` 或 `"data"`，`file` 用 URL 引用而非内联字节 | 无（协议层扩展） |
| `agent/getAuthenticatedExtendedCard` | 返回带扩展字段的卡片；鉴权仍由 `f_mvc` 拦截器决定 | 无 |

### 7.1 SSE 端点与事件格式

`f_jsonrpc` 新增一个**流式端点**（与 `/rpc` 并列，不走 JSON-RPC 请求/响应）：

```
GET /rpc/stream?topic=a2a&taskId=task-1
Accept: text/event-stream
Last-Event-ID: 42            # 可选，断线重连补发
```

事件体仍是 JSON-RPC 2.0 的**通知**（无 `id`，不需要响应），这样客户端可以用同一套消息模型解析：

```
id: 43
event: message
data: {"jsonrpc":"2.0","method":"a2a.task.status","params":{"taskId":"task-1","status":"working"}}

id: 44
event: message
data: {"jsonrpc":"2.0","method":"a2a.task.artifact","params":{"taskId":"task-1","artifactId":"a-1"}}
```

### 7.2 为什么这么做而不是改 `f_mvc`

- `f_mvc` 已经能把 `InputStream` 直接作为响应体（`RequestMeta` 的 `case x: InputStream => respond(x, ctx)`），
  SSE 只需要「一个不会结束的输入流」——这是既有能力，**不需要新增框架 API**；
- 反向代理/鉴权/线程池继续由 `f_mvc` 统一处理，SSE 端点只是普通 GET 路由；
- 若将来 `f_mvc` 提供原生 SSE，`f_jsonrpc` 可以整体切过去，`f_a2a` 无感知。

### 7.3 边界与已知取舍

| 项 | 取舍 |
|---|---|
| 连接数 | 一个订阅者一个长连接；`SseHub` 按 `topic` + 可选 `taskId` 过滤，队列有界（默认 256 条，满了丢最旧并记一次 warn） |
| 心跳 | 每 15s 发一行注释 `: ping`，防止中间代理断连 |
| 多进程 | 只在进程内广播；多实例部署需外部消息总线（本期不做，写入 `known-limitations`） |
| 客户端重连 | `JsonRpcSseClient` 带 `Last-Event-ID` 重连，最多重试 3 次后抛出 |


## 8. 测试矩阵（实现时逐条落地）

| 用例 | 断言 |
|---|---|
| `A2aTask` JSON 往返 | `toJson` → `fromJson` 字段全等（含 `input-required` 状态） |
| `send` 成功 | 返回 `completed`，`artifacts[0].parts[0].text` 为执行器输出，`history` 含两条消息 |
| `send` 需要澄清 | 返回 `input-required`，任务可被 `tasks/get` 取到 |
| `send` 执行器失败 | 返回 `failed`，`statusMessage.parts[0].text` 带原因 |
| `get` 未知 id | 抛 `JsonRpcException`，`code = -32020` |
| `cancel` 未知 id | `-32020` |
| `cancel` 已完成任务 | `-32021` |
| `cancel` working 任务 | 状态变 `canceled` |
| 非文本 Part | `-32023` |
| `register()` 幂等 | 连续两次注册后方法数不翻倍 |
| `A2aClient.send` 透传错误 | 服务端 `-32020` → 客户端抛同码异常 |
| Agent Card 序列化 | 含 `capabilities.streaming=true` 与 `defaultInputModes=["text/plain"]` |
| `message/stream` 推送 | 订阅后收到 `working` → `completed` 两条事件，`id` 单调递增 |
| `tasks/resubscribe` 补发 | 带 `Last-Event-ID` 重连，只收到其后的新事件 |
| 流中取消 | `working` 期间 `tasks/cancel` → 收到 `canceled` 事件后流结束 |
| push config 注册/查询/删除 | `set` 返回配置 id；`get` 能取到；`delete` 后 `get` 为空 |
| 状态变化触发回调 | 任务完成时向注册的 URL 发出一次 POST，带 `token` |
| 非文本 Part | `kind=file` + url 能进 artifact；`kind=unknown` → `-32023` |
| 扩展卡片 | `a2a.agent.extendedCard` 返回的卡片含 `x-a2a-extensions` 字段 |

---

## 9. 与既有模块的边界

| 模块 | 关系 |
|---|---|
| `f_jsonrpc` | **唯一传输与协议实现**；`f_a2a` 只注册方法、定义模型 |
| `f_mvc` | 由 `f_jsonrpc` 间接使用；`f_a2a` 不直接依赖（除 Agent Card 路由示例） |
| `f_data` | 模型序列化（`@DataAssist`）与 `JsonValue` |
| `f_llm` | **不依赖**：A2A 是协议层，具体「代理」由宿主实现 `A2aExecutor` 时自行接 `f_llm` |
| `f_log` | 执行器异常时记录 warn（不吞异常，返回 `failed`） |
