# Spec Delta

## ADDED Requirements

### Requirement: 提升曲线

`LiftChart` MUST 输出 1 条 `class="lift-line"` 折线，按 `x` 升序连接全部数据点，并 MUST 为每个数据项输出一个 `class="lift-point"` 圆点。

#### Scenario: 六个数据点

- **WHEN** `data` 有 6 项
- **THEN** 输出 1 条 `lift-line` 与 6 个 `lift-point`

### Requirement: 提升基准线

`LiftChart` MUST 输出一条 `class="lift-baseline"` 水平虚线，位置为 `baseline`（默认 1）。

#### Scenario: 一条基准线

- **WHEN** 任意合法输入
- **THEN** 输出 1 条 `lift-baseline`

### Requirement: 提升图轴

x 轴 MUST 覆盖全部 `x` 并默认从 0 到 1；y 轴 MUST 覆盖全部 `y` 与 `baseline`；`xAxis.min/max`、`yAxis.min/max` 给出时 MUST 按给定值。

#### Scenario: 默认横轴

- **WHEN** 未给 `xAxis.min/max`、数据 x 落在 0 到 1 内
- **THEN** 横轴范围为 0 到 1

### Requirement: 提升图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`x`、`y` MUST 为数字，`baseline` MUST 为正数；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非正基准线

- **WHEN** `baseline` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `LiftChart` 渲染 `type` 为 `gain` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
