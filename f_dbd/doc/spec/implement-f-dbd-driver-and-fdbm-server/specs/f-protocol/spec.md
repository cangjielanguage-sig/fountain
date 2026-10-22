## ADDED Requirements

### Requirement: 带载荷的 UNSUBSCRIBE 构造器（MUST）

本要求为强制要求（MUST）。

`f_protocol` 必须提供 `Message.unsubscribe<T>(data!: T)`：命令为 `UNSUBSCRIBE`、载荷由 `data.toData()` 产生、`MessageID` 由构造器自动生成。它供 `f_dbd` 在关闭游标时携带 `QueryResultClosePayload`（`f_dbd/doc/详细设计.md` §3.6.1、§5.9）使用。

#### Scenario: 自动生成 MessageID 并携带载荷

- **GIVEN** 一个实现了 `ToData` 的载荷对象 `P`
- **WHEN** 调用 `Message.unsubscribe(data: P)`
- **THEN** 返回消息的 `command` 是 `UNSUBSCRIBE`
- **AND** 其 `data` 等于 `P.toData()`
- **AND** 其 `id` 是一个新生成的 `MessageID`（非空、与手工构造的 `MessageID()` 同构）

#### Scenario: 连续两次调用产生不同的 MessageID

- **GIVEN** 同一载荷对象 `P`
- **WHEN** 连续调用 `Message.unsubscribe(data: P)` 两次
- **THEN** 两条消息的 `id` 不相等
- **AND** 两条消息的 `data` 相同

#### Scenario: 与既有 subscribe 重载同构

- **GIVEN** 同一载荷对象 `P`
- **WHEN** 分别调用 `Message.subscribe(data: P)` 与 `Message.unsubscribe(data: P)`
- **THEN** 两条消息的 `id` 生成方式一致（均为自动生成）
- **AND** 两条消息的 `data` 相同、仅 `command` 不同

### Requirement: 既有 UNSUBSCRIBE 构造器语义不变（MUST）

本要求为强制要求（MUST）。

新增重载不得改变 `unsubscribe(id)` 与 `unsubscribe(id, data!)` 的行为，既有调用方（f_rpc 等）无需修改。

#### Scenario: 指定 MessageID 的重载仍使用传入的 id

- **GIVEN** 一个指定 id `M` 与载荷 `P`
- **WHEN** 调用 `Message.unsubscribe(M, data: P)`
- **THEN** 返回消息的 `id` 等于 `M`
- **AND** `data` 等于 `P.toData()`

#### Scenario: 仅指定 MessageID 的重载不携带载荷

- **GIVEN** 一个指定 id `M`
- **WHEN** 调用 `Message.unsubscribe(M)`
- **THEN** 返回消息的 `id` 等于 `M`
- **AND** `data` 为 `DataNone`（无载荷）

#### Scenario: 三个重载可共存且重载解析无歧义

- **GIVEN** 调用方分别以 `(MessageID)`、`(MessageID, data!)`、`(data!)` 三种实参形式调用 `unsubscribe`
- **WHEN** 编译并运行
- **THEN** 三处调用分别解析到对应重载，编译无歧义、行为各自正确
