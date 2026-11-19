# Spec Delta

## ADDED Requirements

### Requirement: 蜂群点绘制

`SwarmChart` SHALL 为每个数值绘制一个 `class="swarm-point"` 圆点，并按数值排序后分配抖动偏移。

#### Scenario: 两组六点

- **WHEN** 两组各 3 个数值
- **THEN** 输出 6 个 `class="swarm-point"`

### Requirement: 抖动方向

`side` 为 `left` 时所有偏移 MUST 不大于 0；为 `right` 时 MUST 不小于 0；为 `both` 时 MUST 交替正负。偏移绝对值 MUST 不超过 `jitter`。

#### Scenario: 单侧抖动

- **WHEN** `side` 为 `left` 且 `jitter` 为 0.4
- **THEN** 所有偏移落在 `[-0.4, 0]`

### Requirement: 蜂群数据形状

`data` MUST 支持嵌套数组与扁平数组；同图内不得混用；每组不得为空。

#### Scenario: 扁平数据

- **WHEN** `data` 为扁平数值数组
- **THEN** 输出对应数量的 `class="swarm-point"`

### Requirement: 蜂群校验

`jitter` MUST 在 0 到 1 之间；`side` MUST 为合法枚举；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法 jitter

- **WHEN** `jitter` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法 side

- **WHEN** `side` 为 `up`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
