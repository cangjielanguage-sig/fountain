# f_a2a

**Agent-to-Agent（A2A）协议**的动态库实现：任务模型、状态机、服务端与客户端，
传输与协议完全复用 [`fountain::f_jsonrpc`](../f_jsonrpc)（JSON-RPC 2.0 over HTTP，流式走 SSE）。
`f_mvc` 不需要任何改动。

设计基线见 [`doc/a2a-protocol.md`](doc/a2a-protocol.md)。

## 模块定位

| 项 | 说明 |
|---|---|
| 提供 | 模型（`A2aTask` / `A2aMessage` / `A2aPart` / `A2aArtifact` / `A2aAgentCard`）、`A2aServer`、`A2aClient`、`A2aTaskStore`、`A2aExecutor`、`A2aPushConfigStore` |
| 不提供 | 传输与路由（用 `f_jsonrpc` / `f_mvc`）、LLM 调用（宿主实现 `A2aExecutor` 时自己接 `f_llm`） |
| 输出类型 | `dynamic`（`cjpm build` 产出动态库） |

## 依赖

```toml
[dependencies]
  "fountain::f_collection" = {path = "../f_collection"}
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_httpclient" = {path = "../f_httpclient"}
  "fountain::f_jsonrpc" = {path = "../f_jsonrpc"}
  "fountain::f_log" = {path = "../f_log"}
```

## 注册的 JSON-RPC 方法（9 个）

| 方法 | 作用 |
|---|---|
| `a2a.message.send` | 建任务 → 同步执行 → 返回终态任务 |
| `a2a.message.stream` | 同上，并把 `a2a.task.status` / `a2a.task.artifact` 事件推到 SSE |
| `a2a.tasks.get` | 按 `id` 取任务；未找到 `-32020` |
| `a2a.tasks.cancel` | 只能取消 `submitted` / `working`；终态 `-32021` |
| `a2a.tasks.resubscribe` | 重订阅：返回任务并补发一条当前状态事件 |
| `a2a.agent.extendedCard` | 基础卡片 + `x-a2a-extensions`（没配就是基础卡片） |
| `a2a.pushConfig.set` / `get` / `delete` | 任务 → 回调 URL 的注册表 |

错误码：`-32020` 任务不存在、`-32021` 不可取消、`-32023` 非文本 Part、`-32024` 拒绝，均在 `-32020 ~ -32099` 业务码段内。

## 服务端

```cangjie
import fountain::f_a2a.*

class MyExecutor <: A2aExecutor {
    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        A2aExecutionResult.done('完成：${message.text()}')
    }
}

let card = A2aAgentCard(name: '日报代理', description: '汇总每日提交',
                        url: 'http://127.0.0.1:8080/rpc/a2a')
let server = A2aServer(card, MyExecutor())
server.register()          // 幂等：重复调用不会重复注册
```

调一下（走 `f_jsonrpc` 的 `/rpc` 端点，方法名在请求体里）：

```bash
curl -s http://127.0.0.1:8080/rpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"a2a.message.send",
       "params":{"message":{"role":"user","messageId":"m1",
                 "parts":[{"kind":"text","text":"把今天的提交汇总一下"}]}}}'
```

### 流式

```bash
curl -N 'http://127.0.0.1:8080/rpc/stream?topic=a2a&taskId=task-1' \
     -H 'Accept: text/event-stream'
```

```
id: 1
event: message
data: {"jsonrpc":"2.0","method":"a2a.task.status","params":{"taskId":"task-1","status":"working"}}
```

先调 `a2a.message.stream` 建任务，再用返回的 `id` 订阅；断线重连带 `Last-Event-ID` 补发。

### 推送回调

```cangjie
// 任务进入终态时向 url POST 一条带 token 的 JSON-RPC 通知；失败只 warn
```

`a2a.pushConfig.set` 参数 `{"taskId":"task-1","url":"https://hook/a2a","token":"tk-1"}`。

### 扩展卡片

```cangjie
@Controller
public class CardController {
    @GetMapping[path: '/.well-known/agent.json']
    public func card(): String {
        A2aAgentCard(name: '日报代理', url: 'http://127.0.0.1:8080/rpc/a2a').json()
    }
}
```

`f_a2a` 不自动挂这条路由：它属于宿主应用的 HTTP 面，模块只提供序列化。

## 客户端

```cangjie
let client = A2aClient('http://127.0.0.1:8080/rpc')
let task = client.send(A2aMessage(parts: [A2aPart(text: '把今天的提交汇总一下')]))
println(task.status)        // completed | failed | input-required | canceled
let again = client.get(task.id)
let _ = client.cancel(task.id)
client.close()
```

协议错误（如 `-32020`）**原样上抛**，不改写、不吞。

## 数据模型要点

- `A2aPart.kind`：`text` / `file`（`url` + `mimeType`，不内联字节）/ `data`（小段 JSON 字符串）；未知类型 → `-32023`；
- 状态机：`submitted → working → completed | failed | canceled`，`input-required` **是非终态**，客户端带同一 `contextId` 再发即可续跑；
- 任务存储默认内存实现（`Mutex`，读出的是**副本**），重启即丢；需要持久化时实现 `A2aTaskStore` 注入。

## 构建

```bash
cd f_a2a
cjpm build
cjpm test        # 32/32
```

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`A2aCapabilities`（class）、`A2aError`（class）、`A2aEvents`（class）、`A2aExecutionResult`（class）、`A2aJson`（class）、`A2aSkill`（class）、`A2aStates`（class）、`InMemoryA2aTaskStore`（class）
- `A2aAgentCard`：`var capabilities: A2aCapabilities = A2aCapabilities()`、`var skills: ArrayList<A2aSkill> = ArrayList<A2aSkill>()`、`var version: String =`
- `A2aArtifact`：`var artifactId: String =`、`textOf`（func）
- `A2aCapabilities`：`var pushNotifications: Bool = false`、`var streaming: Bool = true`
- `A2aError`：`static let CONTENT_TYPE_UNSUPPORTED: Int64 = -32023`、`static let TASK_NOT_CANCELABLE: Int64 = -32021`、`static let TASK_NOT_FOUND: Int64 = -32020`、`static let TASK_REJECTED: Int64 = -32024`、`static let UNSUPPORTED: Int64 = -32022`
- `A2aEvents`：`static let METHOD_ARTIFACT =`、`METHOD_STATUS`（let）、`TOPIC`（let）、`notify`（func）、`publish`（func）、`pushBody`（func）、`statusParams`（func）
- `A2aExecutionResult`：`let needsInput: Bool`、`reject`（func）、`let rejected: Bool`
- `A2aJson`：`arrayOf`（func）、`artifactOf`（func）、`artifactsOf`（func）、`copyOf`（func）、`intOf`（func）、`messageOf`（func）、`messagesOf`（func）、`partOf`（func）、`partsOf`（func）、`strOf`（func）、`taskOf`（func）
- `A2aMessage`：`var messageId: String =`、`var role: String =`
- `A2aPart`：`isSupported`（func）
- `A2aServer`：`static let METHOD_CANCEL =`、`static let METHOD_CARD =`、`METHOD_COUNT`（let）、`static let METHOD_GET =`、`static let METHOD_PUSH_DELETE =`、`static let METHOD_PUSH_GET =`、`static let METHOD_PUSH_SET =`、`static let METHOD_RESUBSCRIBE =`、`METHOD_SEND`（let）、`static let METHOD_STREAM =`、`cancelTask`（func）、`getTask`（func）、`pushDelete`（func）、`pushGet`（func）、`pushSet`（func）、`registrationCount`（func）
- `A2aSkill`：`var tags: ArrayList<String> = ArrayList<String>()`
- `A2aStates`：`static let CANCELED =`、`static let COMPLETED =`、`static let FAILED =`、`static let INPUT_REQUIRED =`、`static let SUBMITTED =`、`static let WORKING =`、`isTerminal`（func）、`isValid`（func）
- `A2aTask`：`var artifacts: ArrayList<A2aArtifact> = ArrayList<A2aArtifact>()`、`var createdAt: Int64 = 0`、`var history: ArrayList<A2aMessage> = ArrayList<A2aMessage>()`、`isTerminal`（func）、`var statusMessage: ?A2aMessage = None`、`var updatedAt: Int64 = 0`
- `InMemoryA2aTaskStore`：`count`（func）、`list`（func）、`save`（func）
