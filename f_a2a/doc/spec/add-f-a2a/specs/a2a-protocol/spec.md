# Spec Delta

## ADDED Requirements

### Requirement: 任务模型与状态机

系统 MUST 提供 `A2aTask`（`id` / `contextId` / `status` / `statusMessage` / `artifacts` / `history` / `createdAt` / `updatedAt`）
与状态枚举 `submitted` / `working` / `completed` / `failed` / `canceled` / `input-required`；
`input-required` MUST 视为非终态，其余四个 MUST 视为终态。模型 MUST 支持 `JsonValue` 双向往返。

#### Scenario: JSON 往返

- **WHEN** 一个 `status = input-required` 的任务序列化后再解析
- **THEN** 所有字段（含 `history` 与 `artifacts`）与原文一致

#### Scenario: 状态分类

- **WHEN** 查询某状态的「是否终态」
- **THEN** `input-required` 返回 false，其余四种返回 true

### Requirement: 消息发送

`a2a.message.send` MUST 接收 `message`（含至少一个 `text` 类型 `Part`），创建任务并同步执行宿主提供的
`A2aExecutor`，返回执行后的任务；执行器返回的三类结果 MUST 分别映射到 `completed`（带 artifact）、
`input-required`、`failed`（带 `statusMessage`）。非 `text` 类型 MUST 抛 `-32023`。

#### Scenario: 成功

- **WHEN** 执行器返回 `text('完成')`
- **THEN** 任务 `status = completed`，`artifacts[0].parts[0].text = '完成'`，`history` 有 user 与 agent 两条消息

#### Scenario: 需要补充信息

- **WHEN** 执行器返回 `needsInput('请给出日期范围')`
- **THEN** 任务 `status = input-required`，可被 `tasks/get` 取到

#### Scenario: 失败

- **WHEN** 执行器返回 `failed('上游超时')`
- **THEN** 任务 `status = failed`，`statusMessage.parts[0].text` 含 `上游超时`

#### Scenario: 非文本 Part

- **WHEN** `Part.kind = "file"`
- **THEN** 抛 `JsonRpcException`，`code = -32023`

### Requirement: 任务查询与取消

`a2a.tasks.get` MUST 按 `id` 返回任务，未找到 MUST 抛 `-32020`；`a2a.tasks.cancel` MUST 只接受
`submitted` / `working`（其它状态抛 `-32021`），成功时把状态置为 `canceled`；未找到 MUST 抛 `-32020`。

#### Scenario: 查询未知任务

- **WHEN** `tasks/get` 一个不存在的 id
- **THEN** 抛 `JsonRpcException`，`code = -32020`

#### Scenario: 取消进行中的任务

- **WHEN** 任务处于 `working` 且调用 `tasks/cancel`
- **THEN** 状态变为 `canceled`

#### Scenario: 取消已终结的任务

- **WHEN** 任务处于 `completed` 且调用 `tasks/cancel`
- **THEN** 抛 `JsonRpcException`，`code = -32021`

### Requirement: 方法注册幂等

`A2aServer.register()` 重复调用 MUST NOT 重复注册（方法表条目数不变），MUST 注册且仅注册
`a2a.message.send` / `a2a.tasks.get` / `a2a.tasks.cancel` 三个方法。

#### Scenario: 连续注册两次

- **WHEN** 调用 `register()` 两次
- **THEN** 三个方法各存在一份，且 `capabilities.streaming` 仍为 false

### Requirement: 客户端透传协议错误

`A2aClient` MUST 通过 `f_jsonrpc` 的 `JsonRpcClient` 调用三个方法；服务端返回的错误 MUST 以
`JsonRpcException` 原样抛给调用方（保留 `code` / `message` / `data`），MUST NOT 吞成空结果。

#### Scenario: 服务端 404 任务

- **WHEN** `client.get('missing')`
- **THEN** 抛出 `JsonRpcException`，`code = -32020`

### Requirement: Agent Card 序列化

`A2aAgentCard` MUST 能序列化为 A2A 兼容的 JSON：包含 `name` / `description` / `url` / `version` /
`capabilities`（`streaming=false`、`pushNotifications=false`）/ `skills` /
`defaultInputModes=["text/plain"]` / `defaultOutputModes=["text/plain"]`。

#### Scenario: 序列化内容

- **WHEN** 序列化默认构造的卡片
- **THEN** `capabilities.streaming` 为 `false`，`defaultInputModes` 为 `["text/plain"]`
### Requirement: 流式消息

`a2a.message.stream` MUST 接受与 `message.send` 相同的参数，执行过程中 MUST 通过 SSE 推送状态与产物事件；
每条事件 MUST 是 JSON-RPC 通知（`method` 为 `a2a.task.status` 或 `a2a.task.artifact`），`params` 含 `taskId`。

#### Scenario: 订阅后收到两条事件

- **WHEN** 客户端订阅并调用 `a2a.message.stream`，执行器同步返回 `text('完成')`
- **THEN** 依次收到 `working` 与 `completed` 两条事件，id 单调递增

#### Scenario: 流中取消

- **WHEN** 执行器尚未返回时调用 `tasks/cancel`
- **THEN** 收到 `canceled` 事件后流正常结束

### Requirement: 断线重订阅

`a2a.tasks.resubscribe` MUST 按 `taskId` 重新订阅该任务的流，并透传 `Last-Event-ID`；已终结的任务 MUST 立即补发终态事件后结束。

#### Scenario: 重订阅已终结任务

- **WHEN** 任务已是 `completed`，客户端重订阅
- **THEN** 立刻收到一条 `completed` 事件，随后流结束

### Requirement: 推送通知配置

`a2a.pushConfig.set` / `get` / `delete` MUST 维护「任务 → 回调 URL」的注册表；任务进入终态时 MUST 向注册的 URL
POST 一次 JSON-RPC 通知（带 `token`），失败 MUST 只记录 warn，MUST NOT 影响任务终态。

#### Scenario: 注册并触发

- **WHEN** 任务创建后 `set` 一个回调 URL，随后任务完成
- **THEN** 该 URL 收到一次 POST，body 里 `method = "a2a.task.status"`、`token` 与注册时一致

#### Scenario: 回调失败不影响任务

- **WHEN** 回调 URL 不可达
- **THEN** 任务仍是 `completed`，日志有一条 warn

### Requirement: 非文本 Part

`Part.kind` MUST 支持 `text` / `file` / `data`：`file` MUST 用 `url` + `mimeType` 引用（MUST NOT 内联字节），
`data` MUST 用小段 JSON 字符串；未知 `kind` MUST 抛 `-32023`。

#### Scenario: 文件引用

- **WHEN** 执行器返回 `A2aPart(kind: "file", url: "https://…/a.pdf", mimeType: "application/pdf")`
- **THEN** artifact 里原样保留该 `url` 与 `mimeType`

#### Scenario: 未知类型

- **WHEN** `kind = "video"`
- **THEN** 抛 `JsonRpcException`，`code = -32023`

### Requirement: 扩展卡片

`a2a.agent.extendedCard` MUST 返回在基础卡片上附加 `x-a2a-extensions` 字段的 JSON；未配置扩展时 MUST 返回基础卡片。

#### Scenario: 带扩展

- **WHEN** 服务器配置了 `x-a2a-extensions` 内容
- **THEN** 返回的卡片里该字段与配置一致，其余字段与基础卡片相同
