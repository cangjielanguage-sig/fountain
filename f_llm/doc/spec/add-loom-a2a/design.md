# Design

## Context

- `Supervisor.dispatch(prompt: String): SupervisorOutcome`，`outcome.kind` 四态 + `message` + `result: ?Event`；
- `f_a2a` 提供 `A2aServer(card, executor).register()`、`A2aExecutor.execute(task, message)`、`A2aClient`；
- 配置读取沿用 `LLMConfig` 现有形态：`Config.getValue<Bool>(LLM + '_xxx')`，缺省 `false`。

## Decisions

### D1. 开关放 `LLMConfig.a2aEnabled()`，键名 `llm_a2aEnabled`

```cangjie
public static func a2aEnabled(): Bool {
    Config.getValue<Bool>(LLM + '_a2aEnabled') ?? false
}
```

与 `supervisorEnabled()` 同形。**默认 false** 是硬要求：A2A 会开一个对外可调的入口，
不该在升级后悄悄生效。

### D2. 服务端 = `A2aExecutor` 适配器，不把 A2A 概念塞进 Supervisor

```cangjie
class SupervisorAgent <: A2aExecutor {
    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        map(Supervisor.current()?.dispatch(message.text()))
    }
}
```

`Supervisor` 保持「只认自然语言、只返回自己的 outcome」；A2A 的状态映射集中在 `map()` 一处。

**替代**：给 Supervisor 加 A2A 方法。否决——会把协议依赖压进核心类，且 Supervisor 已有静态单例语义，越加越乱。

### D3. 结果映射用 `outcome.kind` 而不是猜文本

| outcome.kind | A2A 状态 | 正文 |
|---|---|---|
| `dispatched` / `created` | `completed` | `outcome.message` 非空用它，否则用 `outcome.result` 的 `data` |
| `clarifying` | `input-required` | `outcome.message` |
| `noUsableFlow` | `failed` | `outcome.message` |

**为什么不把 `noUsableFlow` 映射成 `-32024 rejected`**：这不是「代理拒绝执行」，而是「当前没有能干的流程」，
属任务失败而非协议拒绝；客户端据此重试/换说法更自然。

### D4. 客户端独立成类 `LoomA2aClient`，不并进 `A2aClient`

`f_a2a` 的 `A2aClient` 是通用协议客户端；`LoomA2aClient` 只加「拿文本、取正文、空结果报错」这类
f_llm 习惯的便捷方法（`ask(url, text): String`）。两者是组合关系，不是继承。

### D5. `a2aCall` 工具与 `loomStoreCall` 同形

```cangjie
@DataAssist[props fields]
class A2aCallParam { nextEvent, url, text }
```
`url` 为空 → 返回 `a2aCall requires url`；调用异常 → 返回 `a2aCall failed: …`，**不外抛**。
与 `memoryCall` / `storeCall` 的错误风格一致，流程不会因一次外部调用中断。

### D6. 注册时机：装配后按开关触发，且只触发一次

在 `LoomWiring` 装配末尾调用 `LoomA2a.startIfEnabled()`；内部用静态标志保证幂等
（`A2aServer.register()` 本身也幂等，但重复 `new` 会丢任务存储）。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `dispatch` 是同步阻塞的，长流程会让 A2A 请求等很久 | 文档写明；需要异步时用 `message/stream` 走 SSE（`f_a2a` 已支持） |
| Supervisor 是进程级单例，多租户场景不隔离 | 本期不引入租户维度，写入 `known-limitations` |
| 开启后等于暴露一个可执行入口 | 默认关闭 + 复用 `f_mvc` 鉴权拦截器（A2A 端点与 `/rpc` 同一套） |
| 外部代理不可达 | `a2aCall` 吞异常返回文本；`LoomA2aClient` 抛 `JsonRpcConnectException` 由调用方决定 |
