# Spec Delta

## ADDED Requirements

### Requirement: 象形图图标数量

`pictogramCount` MUST 返回 `ceil(value / unit)`，即每 `unit` 个数值对应一个图标；`value` 为 0 时 MUST 返回 0。

#### Scenario: 整除

- **WHEN** value 为 120、unit 为 10
- **THEN** 返回 12

#### Scenario: 向上取整

- **WHEN** value 为 15、unit 为 10
- **THEN** 返回 2

### Requirement: 象形图图标

`PictogramChart` MUST 为每个数据项输出 `pictogramCount(value, unit)` 个 `class="pictogram-icon"` 图形，每行最多 `columns` 个，超出后换行；`icon` 为 `person`、`circle`、`square` 时 MUST 输出对应形状，其它非空字符串 MUST 作为 SVG path 原样绘制。

#### Scenario: 两类共十八个图标

- **WHEN** 两个数据项的值分别为 120 与 60、`unit` 为 10
- **THEN** 输出 18 个 `pictogram-icon`

#### Scenario: 自定义路径

- **WHEN** `icon` 为 `"M0 0 L10 0 L10 10 Z"`
- **THEN** SVG 中包含该路径

### Requirement: 象形图标签

每个数据项 MUST 输出一条 `class="pictogram-label"` 文本，内容包含名称与数值。

#### Scenario: 两个标签

- **WHEN** `series` 有两个数据项
- **THEN** 输出 2 个 `pictogram-label` 文本

### Requirement: 象形图校验

`unit` MUST 大于 0，`columns` MUST 为正整数，`icon` MUST 非空；`series` MUST 非空，每个 `data` MUST 非空，`value` MUST 为不小于 0 的数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 单位为零

- **WHEN** `unit` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 空图标

- **WHEN** `icon` 为空字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
