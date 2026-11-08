# Spec Delta

## ADDED Requirements

### Requirement: 折线图数据形状

`LineChart` SHALL 支持两种数据：与 `xAxis.labels` 等长的数值数组，以及 `{x, y}` 对象数组。同一图内 MUST 只使用一种形状。

#### Scenario: 类目折线

- **WHEN** `xAxis.labels` 有 3 项且 `series[0].data` 为 3 个数值
- **THEN** 输出包含一条 `class="line"` 路径与 3 个 `class="symbol"`

#### Scenario: 混合形状

- **WHEN** 一个系列用数值数组、另一个用对象数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 缺测断开

`null` 数据点 MUST 断开折线；相邻有效点 MUST 形成独立路径。

#### Scenario: 中间缺测

- **WHEN** 数据为 `[1, 2, null, 4, 5]`
- **THEN** 输出包含 2 条 `class="line"` 路径、4 个符号

### Requirement: 连续轴

`xAxis.type` 为 `linear` 时 MUST 按数值比例尺定位；为 `time` 时 MUST 接受 `YYYY-MM-DD` 并格式化为日期刻度。

#### Scenario: 数值 X

- **WHEN** 数据为 `{x: 0, y: 1}` 与 `{x: 10, y: 5}`
- **THEN** 两点按 x 值线性分布

#### Scenario: 时间 X

- **WHEN** 数据 x 为 `2026-01-01`、`2026-01-08`
- **THEN** x 轴刻度包含 `2026-01`

### Requirement: 平滑与符号

`series[].smooth` 为 true 时 MUST 使用曲线路径（包含 `Q` 命令）；`symbol` 为 `none` 时 MUST 不生成符号。

#### Scenario: 平滑

- **WHEN** `smooth` 为 true
- **THEN** 路径包含 `Q`

#### Scenario: 无符号

- **WHEN** `symbol` 为 `none`
- **THEN** 输出不包含 `class="symbol"`
