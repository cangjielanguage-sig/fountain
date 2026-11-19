# Design

## Context

`f_a2a/doc/a2a-protocol.md` 已定义协议映射与数据模型；本文件只记**实现层面的取舍**。
约束：不改任何既有模块的公开 API；传输/路由/鉴权/日志全部复用 `f_jsonrpc` 与 `f_mvc`。

## Decisions

### D1. 四个包：`model` / `server` / `client` / 门面

```
f_a2a/src/
├── model/  A2aAgentCard.cj  A2aTask.cj  A2aMessage.cj  A2aPart.cj  A2aError.cj
├── server/ A2aExecutor.cj   A2aTaskStore.cj  A2aServer.cj
├── client/ A2aClient.cj
├── imports.cj              （门面 public import）
└── A2a.cj                  （包级常量：命名空间 / 默认 modes）
```

**替代**：单包平铺。否决——`model` 会被客户端与服务端同时引用，分包后客户端可以只依赖 `model + client`。

### D2. `send` 同步执行，不做后台线程

`A2aServer` 的 handler 内联调用 `executor.execute(task, message)`，拿到结果后落终态再返回。

**替代**：起线程异步执行 + 轮询。否决——`f_jsonrpc` 只在显式配置 `timeout` 时才 spawn，内联执行才能用
`CurrentHttpContext` 等请求级上下文；异步还需要额外的任务调度与状态同步，收益不足以支撑。

### D3. 任务存储接口 + 内存实现（`Mutex` + 拷贝返回）

```cangjie
public interface A2aTaskStore {
    func save(task: A2aTask): Unit
    func get(id: String): ?A2aTask
    func list(limit: Int64): ArrayList<A2aTask>
}
```

`InMemoryA2aTaskStore` 用 `Mutex` 保护 `HashMap`，`get`/`list` 返回**副本**（`A2aTask.copy()`），
避免调用方改到存储里的对象。

**替代**：直接返回引用。否决——服务端与客户端模型共享可变字段，返回引用会让「取消后再读」这类并发路径读到中间态。

### D4. 错误码固定分配，`data` 带 `taskId`

| 码 | 常量 | 场景 |
|---|---|---|
| `-32020` | `A2aError.TASK_NOT_FOUND` | `get` / `cancel` 找不到 |
| `-32021` | `A2aError.TASK_NOT_CANCELABLE` | 终态任务被取消 |
| `-32022` | `A2aError.UNSUPPORTED` | 预留（当前无方法产生） |
| `-32023` | `A2aError.CONTENT_TYPE_UNSUPPORTED` | 非文本 `Part` |
| `-32024` | `A2aError.TASK_REJECTED` | 执行器返回 `rejected` |

全部落在 `f_jsonrpc` 允许的业务码段 `-32020 ~ -32099` 内，`data` 统一 `{"taskId": "..."}`。

### D5. 注册幂等靠服务端自己记账

`A2aServer` 持 `registered: Bool` + `Mutex`；`register()` 第二次直接返回。
`JsonRpcRegistry` 是进程级全局表，重复注册会让方法表条目翻倍（同名后写覆盖，但计数与超时元数据会漂移）。

**替代**：依赖 `JsonRpcRegistry` 去重。否决——它没有「按名覆盖」的显式语义，且测试间会互相污染。

### D6. 执行器异常一律转 `failed`，不让它变成 `-32603`

```cangjie
try { executor.execute(...) } catch (e: Exception) {
    LoggerFactory.getLogger<A2aServer>().warn('a2a executor failed: ${e.message}')
    A2aExecutionResult.failed('executor failed: ${e.message}')
}
```

理由：A2A 语义里「代理执行失败」是**任务状态**，不是协议错误；用 `-32603` 会让客户端分不清
「我调错了」与「代理处理失败」。异常同时打 warn，不静默。

### D7. 客户端薄封装，错误原样抛

`A2aClient.send/get/cancel` 各自组 `params` 对象并调 `JsonRpcClient.call`，把返回的 `Task` JSON 反序列化；
`JsonRpcException` 不捕获。重试语义、连接池、响应上限全部由 `ClientOptions` 决定（与 `f_jsonrpc` 一致）。

### D8. 依赖方向

`f_a2a` → `f_jsonrpc` → `f_mvc`；`f_a2a` **不依赖 `f_llm`**——「代理」由宿主实现 `A2aExecutor` 时自行接
LLM/流程，模块只负责协议。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `JsonRpcRegistry` 是全局表，测试之间会互相看到注册的方法 | `register()` 幂等 + 测试用独立 namespace（`a2a`）+ 只断言自己的三个方法名 |
| 内存任务存储无上限，长期运行会涨 | `list(limit)` 支持分页；生产用持久化实现替换（文档写明） |
| `input-required` 需要客户端自己续跑，容易漏 | 文档与 README 都给出「带同一 `contextId` 再 send」的写法 |
| `--dy-std` 动态库在部分平台需要额外链接参数 | `cjpm.toml` 按 `f_jsonrpc` 的 target 段落逐平台复制 |
