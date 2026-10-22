# f_mq 协议层（delta）

## ADDED Requirements

### Requirement: 主题延迟字段

`MQTopicMeta` 与 `MQTopicAssignment` SHALL 携带 `delayingMs: Int64`，单位为毫秒，默认 0。
注册主题时由管理端设置；分配结果落盘、广播与快照复制时 SHALL 原样携带。
`delayingMs < 0` SHALL 在注册入口被拒绝。

#### Scenario: 元数据往返

- **WHEN** `MQTopicMeta("/t", 2, 61000)` 编码后解码
- **THEN** `delayingMs == 61000`

#### Scenario: 分配往返

- **WHEN** `MQTopicAssignment("/t", 2, 0, [0, 1], 61000)` 编码后解码
- **THEN** `delayingMs == 61000`，owners 不变

### Requirement: messageId 发布时间解析

`MQMessageRecord` SHALL 提供 `publishTime(record): ?DateTime`：取 messageId 最后一个 `_` 之后的
23 位 `yyyyMMddHHmmss` + 9 位纳秒片段，按 UTC 解析。字段缺失、长度不符或数字非法时 SHALL 返回 `None`。

#### Scenario: 标准 ID

- **WHEN** messageId 为 `1_2_3_20261018183000123456789`
- **THEN** 解析出的 UTC 时间为 `2026-10-18T18:30:00.123456789Z`

#### Scenario: 非标准 ID

- **WHEN** messageId 为 `mid-1` 或时间戳位数不足
- **THEN** 返回 `None`

### Requirement: 统计请求载荷

统计查询 SHALL 通过 `REGISTER` + `MQInternalMessage{kind = "stats"}` 承载，子载荷为 topic 字符串
（空串表示全部主题）。响应为 TSV 文本，由 `fmq/metrics` 规格定义；协议层不引入新的对象载荷类。

#### Scenario: 请求往返

- **WHEN** `MQProtocol.stats("/order")` 编码后解码内部子载荷
- **THEN** 得到字符串 `"/order"`，`kind == "stats"`

#### Scenario: 内部 kind 稳定

- **WHEN** 读取 `MQInternalKind.STATS`
- **THEN** 值为 `"stats"`
