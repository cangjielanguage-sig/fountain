# Spec Delta

## ADDED Requirements

### Requirement: 饼图扇区

`PieChart` SHALL 按数值占比把圆周分成扇区，每个扇区输出 `class="pie-slice"` 路径。

#### Scenario: 四个类别

- **WHEN** `data` 有 4 个 `{name,value}`
- **THEN** 输出 4 个 `class="pie-slice"`

### Requirement: 百分比标签

`showPercent` 默认为 true，每个扇区 MUST 输出 `class="pie-label"` 百分比文本；为 false 时 MUST 输出类别名文本。

#### Scenario: 百分比

- **WHEN** 某类别占比 38%
- **THEN** 对应标签包含 `38.0%`

### Requirement: 占比计算

`pieFractions(values)` MUST 返回各值占总和的归一化占比，总和为 1。

#### Scenario: 四个值

- **WHEN** 值为 38、27、20、15
- **THEN** 占比为 0.38、0.27、0.20、0.15

### Requirement: 饼图校验

数值 MUST 非负且总和大于 0；`series` MUST 恰好 1 个；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负值

- **WHEN** 某 `value` 为 -5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 总和为零

- **WHEN** 所有 `value` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
