# Spec Delta

## ADDED Requirements

### Requirement: 环形扇区

`DonutChart` SHALL 按占比绘制 `class="donut-slice"` 扇区，并在圆心叠加 `class="donut-hole"` 内孔。

#### Scenario: 四个类别

- **WHEN** `data` 有 4 个 `{name,value}`
- **THEN** 输出 4 个 `class="donut-slice"` 与 1 个 `class="donut-hole"`

### Requirement: 中心文本

`centerText` 非空时 MUST 在圆心输出 `class="center-text"` 文本。

#### Scenario: 总预算

- **WHEN** `centerText` 为 `总预算 100%`
- **THEN** 输出包含该文本的 `center-text` 节点

### Requirement: 内半径

`innerRadius` MUST 在 0 到 1 之间；越界抛 `InvalidValue`。

#### Scenario: 非法内半径

- **WHEN** `innerRadius` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 环形图校验

数值 MUST 非负且总和大于 0；`series` MUST 恰好 1 个；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负值

- **WHEN** 某 `value` 为 -5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
