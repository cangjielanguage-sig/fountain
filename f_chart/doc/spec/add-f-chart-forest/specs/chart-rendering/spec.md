# Spec Delta

## ADDED Requirements

### Requirement: 森林图区间

`ForestChart` MUST 为每个数据点绘制一条 `class="forest-ci"` 水平区间线与一个 `class="forest-point"` 估计值方块。

#### Scenario: 四个研究

- **WHEN** `data` 有 4 个对象
- **THEN** 输出 4 条 `forest-ci` 与 4 个 `forest-point`

### Requirement: 无效线

`nullLine` 默认为 1，此时 MUST 输出 1 条 `class="forest-null"` 竖直虚线。

#### Scenario: 默认无效线

- **WHEN** 未提供 `nullLine`
- **THEN** 输出 1 条 `forest-null`

### Requirement: 权重映射

`forestMarkerSize` MUST 在权重为 0 时返回 6、在权重等于最大值时返回 14；未提供 `weight` 时方块边长为 8。

#### Scenario: 最大权重

- **WHEN** `weight` 为 100 且最大权重为 100
- **THEN** 方块边长为 14

### Requirement: 对数轴

`xAxis.type` 为 `log` 时 `lower` / `upper` MUST 大于 0，位置 MUST 按 `log(value)` 线性映射；`forestLogPosition` 在 0.1–10 上把 1 映射到 0.5。

#### Scenario: 对数位置

- **WHEN** `min` 为 0.1、`max` 为 10、值为 1
- **THEN** `forestLogPosition` 返回 0.5

#### Scenario: 非正区间端点

- **WHEN** 对数轴下 `lower` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 森林图校验

`lower` MUST 不大于 `estimate`，`estimate` MUST 不大于 `upper`；`weight` 提供时 MUST 非负；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 区间倒置

- **WHEN** `lower` 为 2、`upper` 为 1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
