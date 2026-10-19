# fmq 消费语义（delta）

## ADDED Requirements

### Requirement: 延迟投递

主题定义中的 `delaying` SHALL 作用于该主题的所有队列与订阅组：一条记录只有在
「发布时间 + delaying ≤ 当前时间」时才可投递。发布时间 SHALL 取自该记录 messageId 末尾的
23 位 UTC 时间戳。

未到期的记录 SHALL 停在队首：不投递、不创建未决项、不标记已决、不推进 `committed`；
到期后从同一位置继续。延迟 SHALL 跨服务重启有效（不依赖内存状态）。
messageId 无法解析出发布时间时，SHALL 视为已到期并记录 WARN。
`delaying = 0s` 时行为与无延迟完全一致。

#### Scenario: 未到期不投递

- **WHEN** 主题 `delaying=1m1s`，消息在 T 时刻发布，T+30s 时消费
- **THEN** 返回空，`committed` 不变

#### Scenario: 到期后投递

- **WHEN** 同一消息到 T+1m1s 后再次消费
- **THEN** 正常返回该消息，位置与发布时一致

#### Scenario: 零延迟

- **WHEN** 主题未设置 delaying
- **THEN** 发布后可立即消费

#### Scenario: 队首阻塞

- **WHEN** 队列中第一条未到期、第二条已到期（不同发布时刻）
- **THEN** 第二条不越过第一条投递；`committed` 停在第一条之前

#### Scenario: 重启后仍延迟

- **WHEN** 发布后重启服务端，在到期前消费
- **THEN** 仍返回空；到期后可正常消费

#### Scenario: 非标准 messageId

- **WHEN** 记录的 messageId 不含 23 位时间戳
- **THEN** 视为已到期并投递，同时记录 WARN
