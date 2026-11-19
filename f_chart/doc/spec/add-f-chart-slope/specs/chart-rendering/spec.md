# Spec Delta

## ADDED Requirements

### Requirement: 斜率图连线与端点

`SlopeChart` MUST 为每个系列输出一条 `class="slope-line"` 连线，起点位于第一个时间点、终点位于第二个时间点；每个系列 MUST 输出 2 个 `class="slope-point"` 圆点。

#### Scenario: 三个系列

- **WHEN** `series` 有 3 项
- **THEN** 输出 3 条 `slope-line` 与 6 个 `slope-point`

### Requirement: 斜率图右侧标签

每个系列 MUST 在第二个时间点右侧输出 `class="slope-label"` 文本，内容为系列名称。

#### Scenario: 三个标签

- **WHEN** `series` 有 3 项
- **THEN** 输出 3 个 `slope-label`

### Requirement: 斜率图时间点

`xAxis.labels` MUST 恰好 2 个，且每个系列 `data` MUST 恰好 2 个数字；两个时间点 MUST 等距分布在绘图区左右两侧。

#### Scenario: 三个时间点

- **WHEN** `xAxis.labels` 有 3 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 数据长度不为二

- **WHEN** 某系列 `data` 有 3 个数值
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 斜率图校验

`series` MUST 非空；`yAxis.min` MUST 小于 `yAxis.max`（若同时给出）；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 类型不匹配

- **WHEN** 用 `SlopeChart` 渲染 `type` 为 `line` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
