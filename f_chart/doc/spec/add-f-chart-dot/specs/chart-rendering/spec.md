# Spec Delta

## ADDED Requirements

### Requirement: 克利夫兰点图

`DotChart` SHALL 在类别行上画一个圆点表示数值，并从 0 基线到圆点画一条细线。

#### Scenario: 三个类别

- **WHEN** `yAxis.labels` 有 3 项且数据为 3 个数值
- **THEN** 输出 3 个 `class="dot"` 与 3 条 `class="stem"`

### Requirement: 点图的负值与缺测

负值点 MUST 落在 0 基线左侧；`null` MUST 跳过。

#### Scenario: 缺测

- **WHEN** 数据为 `[10, null, 30]`
- **THEN** 只生成 2 个 `class="dot"`

### Requirement: 点图样式

`series[].color` 优先于调色板；`series[].symbolSize` 控制点直径。

#### Scenario: 自定义颜色

- **WHEN** `series[0].color` 为 `#abcdef`
- **THEN** 点与 stem 使用该颜色
