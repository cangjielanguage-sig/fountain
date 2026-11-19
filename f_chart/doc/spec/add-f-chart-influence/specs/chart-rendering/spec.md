# Spec Delta

## ADDED Requirements

### Requirement: 影响点

`InfluenceChart` MUST 为每个 `{x, y}` 数据点绘制一个 `class="influence-point"` 圆点。

#### Scenario: 五个样本

- **WHEN** `data` 有 5 个对象
- **THEN** 输出 5 个 `class="influence-point"`

### Requirement: Cook 距离映射

点半径 MUST 随 `cooksDistance` 增大；`influenceRadius` 在 Cook 距离为 0 时返回 4，在等于最大值时返回 12。

#### Scenario: 零距离

- **WHEN** `cooksDistance` 为 0
- **THEN** 半径为 4

#### Scenario: 最大距离

- **WHEN** `cooksDistance` 等于样本最大值
- **THEN** 半径为 12

### Requirement: 影响点标签

提供 `label` 时 MUST 输出 `class="influence-label"` 文本；未提供时不输出。

#### Scenario: 带标签

- **WHEN** 某点 `label` 为 A
- **THEN** 输出 1 个 `class="influence-label"` 且内容含 A

### Requirement: 影响图校验

`x` / `y` MUST 为数字；`cooksDistance` 提供时 MUST 非负；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负 Cook 距离

- **WHEN** 某点 `cooksDistance` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非数字杠杆值

- **WHEN** 某点 `x` 为字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
