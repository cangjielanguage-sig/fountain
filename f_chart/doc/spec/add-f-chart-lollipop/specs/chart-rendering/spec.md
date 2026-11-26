# Spec Delta

## ADDED Requirements

### Requirement: 棒棒糖茎与圆头

`LollipopChart` MUST 为每个非 `null` 数值输出一条从 0 基线到该值的 `class="lollipop-stem"` 竖线与一个位于数值端点的 `class="lollipop-head"` 圆。

#### Scenario: 五个类目

- **WHEN** 一个系列有 5 个非空数值
- **THEN** 输出 5 个 `lollipop-stem` 与 5 个 `lollipop-head`

#### Scenario: 缺测跳过

- **WHEN** 系列数据为 `[4.2, null, 3.6]`
- **THEN** 输出 2 个 `lollipop-stem` 与 2 个 `lollipop-head`

### Requirement: 棒棒糖圆点大小

系列级 `symbolSize` MUST 大于 0，缺省为 8；圆点半径 MUST 为 `symbolSize / 2`。

#### Scenario: 非法点大小

- **WHEN** `symbolSize` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 棒棒糖纵轴

纵轴范围 MUST 包含 0；`yAxis.min` / `yAxis.max` 给出时 MUST 按给定值，否则 MUST 取数据与 0 的最小/最大值。

#### Scenario: 缺省范围包含零

- **WHEN** 数据为 [4.2, 5.1]
- **THEN** 纵轴刻度包含 0

### Requirement: 棒棒糖校验

`series` MUST 非空；`xAxis.labels` 非空时长度 MUST 等于数据长度；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 长度不一致

- **WHEN** `xAxis.labels` 有 3 项而数据有 5 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `LollipopChart` 渲染 `type` 为 `dot` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
