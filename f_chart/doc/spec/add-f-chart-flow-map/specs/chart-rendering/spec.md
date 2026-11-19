# Spec Delta

## ADDED Requirements

### Requirement: 流向路径

`FlowMapChart` MUST 为每条 flow 输出一条 `class="flow-map-path"` 的 `<path>`；提供 `points` 时 MUST 依次连接各坐标，缺省时 MUST 连接 source 与 target 的区域质心。

#### Scenario: 带折线坐标

- **WHEN** `flows` 有 2 项且都提供 `points`
- **THEN** 输出 2 条 `flow-map-path`

#### Scenario: 缺省直线

- **WHEN** flow 未提供 `points`
- **THEN** 路径从 source 质心连到 target 质心

### Requirement: 流向宽度

`flowMapWidth` MUST 在 value 为 0 时返回 1、在 value 等于最大值时返回 5。

#### Scenario: 最大流量

- **WHEN** `value` 等于最大流量
- **THEN** 线宽为 5

### Requirement: 流向地图底图

`FlowMapChart` MUST 为每个 region 输出一个 `class="flow-map-region"` 的 `<path>`。

#### Scenario: 两个区域

- **WHEN** `regions` 有 2 项
- **THEN** 输出 2 个 `flow-map-region`

### Requirement: 流向地图校验

`regions` MUST 非空且 id 唯一；`source` / `target` MUST 指向存在的区域；`value` MUST 大于 0；`points` 每项 MUST 为两个数字；`flows` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知端点

- **WHEN** 某 flow 的 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非正流量

- **WHEN** 某 flow 的 `value` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
