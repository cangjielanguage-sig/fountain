# Spec Delta

## ADDED Requirements

### Requirement: 增益曲线

`GainChart` MUST 输出 1 条 `class="gain-line"` 折线，按 `x` 升序连接全部数据点，并 MUST 为每个数据项输出一个 `class="gain-point"` 圆点。

#### Scenario: 六个数据点

- **WHEN** `data` 有 6 项
- **THEN** 输出 1 条 `gain-line` 与 6 个 `gain-point`

### Requirement: 增益对角线

`GainChart` MUST 输出一条 `class="gain-baseline"` 虚线，连接左下角与右上角（`y = x` 基准）。

#### Scenario: 一条对角线

- **WHEN** 任意合法输入
- **THEN** 输出 1 条 `gain-baseline`

### Requirement: 增益图轴

x 轴与 y 轴 MUST 覆盖全部数据并默认包含 0 到 1；`xAxis.min/max`、`yAxis.min/max` 给出时 MUST 按给定值。

#### Scenario: 默认范围

- **WHEN** 未给轴范围且数据落在 0 到 1 内
- **THEN** 两轴范围均为 0 到 1

### Requirement: 增益图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`x`、`y` MUST 为数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** `data` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `GainChart` 渲染 `type` 为 `lift` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
