# Spec Delta

## ADDED Requirements

### Requirement: 校准曲线

`CalibrationChart` MUST 输出 1 条 `class="calibration-line"` 折线，按 `x` 升序连接全部数据点，并 MUST 为每个数据项输出一个 `class="calibration-point"` 圆点。

#### Scenario: 六个数据点

- **WHEN** `data` 有 6 项
- **THEN** 输出 1 条 `calibration-line` 与 6 个 `calibration-point`

### Requirement: 校准对角线

`diagonal` 为 `true`（默认）时 MUST 输出一条 `class="calibration-diagonal"` 虚线，连接左下角与右上角；为 `false` 时 MUST 不输出。

#### Scenario: 默认显示

- **WHEN** 未给 `diagonal`
- **THEN** 输出 1 条 `calibration-diagonal`

#### Scenario: 关闭对角线

- **WHEN** `diagonal` 为 false
- **THEN** 输出 0 条 `calibration-diagonal`

### Requirement: 校准图轴

x 轴与 y 轴 MUST 覆盖全部数据并默认包含 0 到 1；`xAxis.min/max`、`yAxis.min/max` 给出时 MUST 按给定值。

#### Scenario: 默认范围

- **WHEN** 未给轴范围且数据落在 0 到 1 内
- **THEN** 两轴范围均为 0 到 1

### Requirement: 校准图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`x`、`y` MUST 为数字；提供 `binCount` 时 MUST 为正整数；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法分箱数

- **WHEN** `binCount` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `CalibrationChart` 渲染 `type` 为 `gain` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
