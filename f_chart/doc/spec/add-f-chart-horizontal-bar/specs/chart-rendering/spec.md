# Spec Delta

## ADDED Requirements

### Requirement: 横向类目布局

`HorizontalBarChart` SHALL 把 `yAxis.labels` 的类别自上而下排列，柱从数值 0 基线水平延伸。

#### Scenario: 五个类别

- **WHEN** `yAxis.labels` 有 5 项、`series[0].data` 有 5 个数值
- **THEN** 输出 5 个 `class="bar"` 与 5 个类别标签

### Requirement: 条形图的负值与缺测

负值柱 MUST 从 0 基线向左；`null` MUST 跳过。

#### Scenario: 负值

- **WHEN** 数据包含负数
- **THEN** 对应柱带 `bar-negative`

### Requirement: 数值轴

`xAxis` MUST 使用线性比例尺并绘制 nice 刻度；显式 `min` / `max` 优先。

#### Scenario: 刻度

- **WHEN** x 范围为 0–300
- **THEN** 输出至少 2 个 `class="tick-label"`
