# Spec Delta

## ADDED Requirements

### Requirement: 组合图系列类型

`ComboChart` SHALL 支持柱、分组柱、堆叠柱、百分比堆叠柱、折线、散点六种系列类型；未知类型 MUST 抛 `UnsupportedChart`。

#### Scenario: 柱 + 线

- **WHEN** 一个 `bar` 系列与一个 `line` 系列
- **THEN** 输出同时包含 `class="bar"` 与 `class="line"`

#### Scenario: 未知类型

- **WHEN** `series[0].type` 为 `area`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: 双轴

`series[].axis` 为 `right` 时 MUST 使用 `yAxis2` 的比例尺；否则使用 `yAxis`。

#### Scenario: 右轴

- **WHEN** 折线声明 `axis: "right"` 且 `yAxis2.max` 为 50
- **THEN** 输出包含右轴刻度 50

### Requirement: 组合柱分组

柱类系列 MUST 按 `stack` 分组：不同组并列，同组堆叠；`percent-stacked-bar` 组归一化到 100%。

#### Scenario: 堆叠组

- **WHEN** 两个 `stacked-bar` 系列共享 `stack`
- **THEN** 同类目下两段同 x

### Requirement: 散点类目映射

组合图散点的 `x` SHALL 接受类目名或类目下标；越界或未命中 MUST 抛 `InvalidValue`。

#### Scenario: 类目名

- **WHEN** `x` 为 `Q1` 且 `xAxis.labels` 包含 `Q1`
- **THEN** 点落在 Q1 槽位中心
