# f_a2a

**Agent-to-Agent（A2A）协议**的动态库实现：任务模型、状态机、服务端与客户端，传输与协议完全复用
[`fountain::f_jsonrpc`](../f_jsonrpc)（JSON-RPC 2.0 over HTTP）。

设计基线见 [`doc/a2a-protocol.md`](doc/a2a-protocol.md)——协议映射、数据模型、状态机、错误码、支持边界都在那里。

## 模块定位

| 项 | 说明 |
|---|---|
| 提供 | `A2aAgentCard` / `A2aTask` / `A2aMessage` / `A2aPart` / `A2aArtifact` 模型；`A2aServer`（方法注册 + 任务存储）；`A2aClient` |
| 不提供 | 传输（用 `f_jsonrpc`）、路由与鉴权（用 `f_mvc`）、LLM 调用（由宿主实现 `A2aExecutor` 时自行接 `f_llm`） |
| 输出类型 | `dynamic`（`cjpm build` 产出动态库） |

## 依赖

```toml
[dependencies]
  "fountain::f_collection" = {path = "../f_collection"}
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_jsonrpc" = {path = "../f_jsonrpc"}
  "fountain::f_log" = {path = "../f_log"}
```

## 快速开始

服务端：

```cangjie
import fountain::f_a2a.*

let card = A2aAgentCard(name: '日报代理', description: '汇总每日提交', url: 'http://127.0.0.1:8080/rpc/a2a',
                        version: '1.0.0')
let server = A2aServer(card, MyExecutor())
server.register()      // 注册 a2a.message.send / a2a.tasks.get / a2a.tasks.cancel
```

客户端：

```cangjie
let client = A2aClient('http://127.0.0.1:8080/rpc/a2a')
let task = client.send(A2aMessage(parts: [A2aPart(text: '把今天的提交汇总一下')]))
println(task.status)   // completed | failed | input-required | canceled
```

## 构建

```bash
cd f_a2a
cjpm build
cjpm test
```

## 边界

- 同步语义：`message/send` 一次调用跑完执行器并返回终态任务；长任务用 `input-required` + 客户端轮询 `tasks/get`；
- 不支持 SSE 流式（`message/stream`）、`tasks/resubscribe`、push notification 与非文本 `Part`，理由见设计文档 §7；
- 任务存储默认内存实现，重启即丢；需要持久化时实现 `A2aTaskStore` 注入。
