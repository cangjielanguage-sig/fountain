# Spec Delta

## ADDED Requirements

### Requirement: 哑铃图连线

`DumbbellChart` MUST 为每个数据项输出一条 `class="dumbbell-line"` 水平连线，起点 MUST 为 `low` 的坐标、终点 MUST 为 `high` 的坐标。

#### Scenario: 三个数据项

- **WHEN** `data` 有 3 项
- **THEN** 输出 3 条 `dumbbell-line`

### Requirement: 哑铃图端点

每个数据项 MUST 输出一个 `class="dumbbell-low"` 圆和一个 `class="dumbbell-high"` 圆，圆心 MUST 位于该行的类目中线上。

#### Scenario: 端点数量

- **WHEN** `data` 有 3 项
- **THEN** 输出 3 个 `dumbbell-low` 与 3 个 `dumbbell-high`

### Requirement: 哑铃图横轴范围

横轴最小值 MUST 取 `xAxis.min`（缺省为全部 `low`/`high` 的最小值），最大值 MUST 取 `xAxis.max`（缺省为全部 `low`/`high` 的最大值）；两者相等时 MUST 自动扩展。

#### Scenario: 显式范围

- **WHEN** `xAxis.min` 为 0、`xAxis.max` 为 100
- **THEN** 输出轴刻度包含 0 与 100

### Requirement: 哑铃图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；每个数据项 MUST 提供数字型 `low` 与 `high`；`yAxis.labels` 非空时长度 MUST 等于 `data` 长度；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 缺少 high

- **WHEN** 某数据项没有 `high`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 类目数量不匹配

- **WHEN** `yAxis.labels` 有 2 项而 `data` 有 3 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
