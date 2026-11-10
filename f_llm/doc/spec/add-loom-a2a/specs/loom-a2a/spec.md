# Spec Delta

## ADDED Requirements

### Requirement: 配置开关

系统 MUST 支持布尔配置 `llm_a2aEnabled`，缺省 MUST 为 `false`。
为 `false` 时 MUST NOT 注册任何 A2A 方法，MUST NOT 建立 A2A 服务端；为 `true` 时 MUST 注册全部 A2A 方法。

#### Scenario: 默认关闭

- **WHEN** 未设置 `llm_a2aEnabled`
- **THEN** `LLMConfig.a2aEnabled()` 返回 false，A2A 方法一个都没注册

#### Scenario: 开启

- **WHEN** 设置 `llm_a2aEnabled=true` 后装配
- **THEN** `a2a.message.send` 等 9 个方法可被调用

### Requirement: Supervisor 作为 A2A 智能体

开启时，收到的 `a2a.message.send` MUST 把消息正文交给 `Supervisor.dispatch`，并把结果映射为任务终态：
`dispatched` / `created` → `completed`，`clarifying` → `input-required`，其余 → `failed`；
返回正文 MUST 是 `SupervisorOutcome.message`（为空时用流程结果的事件文本）。

#### Scenario: 命中流程并完成

- **WHEN** dispatch 返回 `dispatched` 且 `message` 非空
- **THEN** A2A 任务 `status = completed`，产物正文等于该 `message`

#### Scenario: 需要澄清

- **WHEN** dispatch 返回 `clarifying`
- **THEN** A2A 任务 `status = input-required`，客户端可带同一 `contextId` 再发

#### Scenario: 没有可用流程

- **WHEN** dispatch 返回 `noUsableFlow`
- **THEN** A2A 任务 `status = failed`，正文含 Supervisor 的说明

### Requirement: Supervisor 侧 A2A 客户端

系统 MUST 提供 `LoomA2aClient`，能对任意 A2A 端点执行 `send` / `get` / `cancel`；
协议错误 MUST 原样上抛（保留 `code`）。

#### Scenario: 调用外部代理

- **WHEN** 对某个 A2A 端点 `send` 一条文本消息
- **THEN** 返回对方任务对象；对方返回 `-32020` 时调用方也拿到 `-32020`

### Requirement: 流程内可调用的 a2aCall 工具

系统 MUST 提供工具 `a2aCall`（参数 `url`、`text`），把文本发给指定 A2A 端点并返回结果正文；
`url` 为空或调用失败时 MUST 返回可读错误文本，MUST NOT 抛异常给流程。

#### Scenario: 成功转发

- **WHEN** `a2aCall` 收到合法 url 且对方返回 `completed`
- **THEN** 工具结果是对方产物正文

#### Scenario: 参数缺失

- **WHEN** `url` 为空
- **THEN** 工具结果是包含 `a2aCall requires url` 的文本，流程继续
