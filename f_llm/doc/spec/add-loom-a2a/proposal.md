# Proposal

## Why

`loom.Supervisor` 已经能把一句自然语言派发到某个流程并拿到运行结果，但入口只有进程内调用
（`Supervisor.install(...)` + `dispatch(prompt)`）。这带来两个缺口：

- **对外**：别的智能体/客户端没法用标准协议访问这个能力；
- **对内**：Supervisor 也没法反过来调用别人。

`f_a2a` 已经在 `sts/1.3.x` 上落地（任务模型、9 个 JSON-RPC 方法、SSE 推送、客户端），
形状正好匹配：A2A 的「发消息 → 执行 → 回结果」就是 `dispatch(prompt) → SupervisorOutcome`。

## What Changes

- **依赖**：`f_llm/cjpm.toml` 增加 `fountain::f_a2a`。
- **配置**：新增 `llm_a2aEnabled`（布尔，**默认 false**）。关闭时行为与现在完全一致，不注册任何方法。
- **服务端**：开启时把 Supervisor 包装成 `A2aExecutor` 并注册 `A2aServer`：
  - `a2a.message.send` → `Supervisor.dispatch(message.text())`；
  - 结果映射：`dispatched`/`created` → `completed`（正文为 `outcome.message` 或流程结果）、
    `clarifying` → `input-required`、`noUsableFlow` → `failed`；
  - 卡片由 `LLMConfig` 里的名称/描述拼出，`url` 指向 `/rpc/a2a`。
- **客户端**：新增 `LoomA2aClient`（薄封装 `f_a2a` 的 `A2aClient`），让 Supervisor 侧能访问其他 A2A 服务；
  并提供流程内工具 `a2aCall`（参数 `url` / `text`），`kind=tool` 与 `kind=llm` 的步骤都能用。

## Capabilities

### New Capabilities
- `loom-a2a`：开关、Supervisor↔A2A 的双向桥（服务端 + 客户端 + 工具）。

## Impact

- 代码：`f_llm/cjpm.toml`、`src/config/LLMConfig.cj`、新增 `src/loom/a2a/`（服务端桥、客户端、工具）、
  流程装配处按开关注册；
- 默认关闭：不开 `llm_a2aEnabled` 时下载/启用路径零变化，既有用例不受影响；
- 测试：新增开关、结果映射、客户端透传、工具错误分支的用例；服务端用注入的 dispatch 替身，不依赖真实 Supervisor。
