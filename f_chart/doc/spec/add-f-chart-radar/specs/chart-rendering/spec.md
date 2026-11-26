# Spec Delta

## ADDED Requirements

### Requirement: 雷达指标轴

`RadarChart` SHALL 按 `indicators` 数量均分圆周，绘制指标轴与标签；每条轴从中心指向外圈。

#### Scenario: 五个指标

- **WHEN** `indicators` 有 5 项
- **THEN** 输出 5 个 `class="indicator-label"`

### Requirement: 雷达系列

每个系列 MUST 画成闭合多边形，并在每个指标顶点画一个符号；`data` 长度 MUST 等于指标数。

#### Scenario: 两个系列

- **WHEN** 2 个系列、5 个指标
- **THEN** 输出 2 个 `class="radar-area"` 与 10 个 `class="symbol"`

#### Scenario: 长度不一致

- **WHEN** 某系列 data 只有 4 项而指标有 5 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 数值归一化

数值 MUST 按 `value / max` 映射到半径，越界钳制到 `[0, 1]`；`max` 必须大于 0。

#### Scenario: 超上限

- **WHEN** 某值为 max 的 2 倍
- **THEN** 该顶点落在最外圈
