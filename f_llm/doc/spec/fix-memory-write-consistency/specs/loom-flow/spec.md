# Spec Delta

## ADDED Requirements

### Requirement: 会话摘要写入走统一网关

`Memory.remember` MUST 优先通过 `LoomHostApi.callStore("memory","add", …)` 写入，MUST 支持调用方指定 `namespace` 与 `kind`；默认值 MUST 与 loom 的检索默认值一致（`namespace='loom'`、`kind='session'`）。未装配网关时 MUST 回落到存储适配器，MUST NOT 抛给调用方。

#### Scenario: 已装配时走网关

- **WHEN** 已安装存储网关，调用 `Memory.remember('s1','摘要')`
- **THEN** 网关收到一条 `memory.add`，payload 的 `namespace` 为 `loom`、`kind` 为 `session`

#### Scenario: 自定义命名空间

- **WHEN** 调用 `Memory.remember('s1','摘要', namespace: 'work', kind: 'note')`
- **THEN** payload 中分别是 `work` 与 `note`

#### Scenario: 未装配时回落

- **WHEN** 没有安装存储网关
- **THEN** 写入仍完成（走适配器），调用方无异常

### Requirement: 经验 kind 纳入预定义集合

`MemoryKinds` MUST 提供 `experience` 与 `experience_failed` 常量并纳入 `predefined()`；两者的检索权重 MUST 为 `0.8`（与纳入前一致，不改变既有排序）。

#### Scenario: 预定义包含经验 kind

- **WHEN** 查询 `MemoryKinds.predefined()`
- **THEN** 同时包含 `experience` 与 `experience_failed`

#### Scenario: 权重不回归

- **WHEN** 取 `weightOf('experience')` 与 `weightOf('experience_failed')`
- **THEN** 都是 `0.8`
