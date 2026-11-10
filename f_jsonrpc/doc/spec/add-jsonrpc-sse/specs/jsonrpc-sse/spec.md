# Spec Delta

## ADDED Requirements

### Requirement: 服务端推送（SSE）

`f_jsonrpc` MUST 提供 `GET /rpc/stream` 端点，返回 `text/event-stream` 长连接；
每次 `publish` MUST 编码为一帧 `id` / `event` / `data`，其中 `data` MUST 是 JSON-RPC 2.0 通知。

#### Scenario: 订阅后收到发布的事件

- **WHEN** 客户端订阅 `topic=a2a`，随后发布一条 `a2a.task.status`
- **THEN** 客户端收到一帧，`data` 解析后 `method = "a2a.task.status"`，`id` 从 1 递增

#### Scenario: 按 taskId 过滤

- **WHEN** 订阅带 `taskId=task-1`，随后分别发布 `task-1` 与 `task-2` 的事件
- **THEN** 只收到 `task-1` 的那条

#### Scenario: 响应的内容类型

- **WHEN** 发起 `GET /rpc/stream`
- **THEN** 响应头 `Content-Type` 为 `text/event-stream`，且带 `Cache-Control: no-cache`

### Requirement: 断线补发

订阅时 MUST 接受 `Last-Event-ID`（或查询参数 `cursor`）；命中缓冲时 MUST 只补发 id 大于该值的事件。

#### Scenario: 带 Last-Event-ID 重连

- **WHEN** 已收到 id 1、2，断线后用 `Last-Event-ID: 2` 重连，期间发布 id 3
- **THEN** 只收到 id 3

#### Scenario: 超出缓冲范围

- **WHEN** `Last-Event-ID` 早于缓冲里最旧的一条
- **THEN** 从最旧的一条开始补发（不报错、不静默丢弃）

### Requirement: 有界缓冲与背压

每个订阅者的待发队列 MUST 有上限（默认 256 条）；溢出时 MUST 丢最旧的一条并记录一次 warn，
MUST NOT 无限增长或阻塞发布方。

#### Scenario: 慢消费者

- **WHEN** 订阅者不读且发布 300 条
- **THEN** 发布调用全部立即返回；订阅者之后能读到数据（最旧的可能已丢），且日志有一条 warn

### Requirement: 客户端流式消费

`JsonRpcSseClient` MUST 逐帧解析并以 JSON-RPC 通知的形式产出；网络中断时 MUST 带 `Last-Event-ID`
重连（最多 3 次），超过后 MUST 抛出异常而不是静默结束。

#### Scenario: 正常消费

- **WHEN** 服务端推送 3 条事件
- **THEN** 客户端 `next()` 依次返回 3 条通知，第四次返回 `None`

#### Scenario: 重连成功

- **WHEN** 第一次连接在收到 1 条后断开，服务端还有 2 条
- **THEN** 客户端自动重连后补收这 2 条，不重复返回第 1 条

#### Scenario: 重连用尽

- **WHEN** 连续 4 次连接失败
- **THEN** 抛出异常，消息中含重试次数
