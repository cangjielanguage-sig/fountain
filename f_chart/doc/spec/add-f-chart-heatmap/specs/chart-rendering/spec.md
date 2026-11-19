# Spec Delta

## ADDED Requirements

### Requirement: 热力单元格

`HeatmapChart` MUST 为矩阵每个元素绘制一个 `class="heatmap-cell"` 矩形。

#### Scenario: 三行五列

- **WHEN** `data` 为 3 行 5 列矩阵
- **THEN** 输出 15 个 `class="heatmap-cell"`

### Requirement: 热力颜色

`colorRange` MUST 为三个颜色；矩阵最小值 MUST 映射到低色，中间值 MUST 映射到中色，最大值 MUST 映射到高色，其余值 MUST 线性插值。

#### Scenario: 三色端点

- **WHEN** `colorRange` 为 `["#e8f1fb", "#7fb3d5", "#1f4e79"]`
- **THEN** 最小值单元格为 `#e8f1fb`，最大值单元格为 `#1f4e79`

#### Scenario: 中点

- **WHEN** 归一化值为 0.5
- **THEN** `heatmapColor` 返回中色

### Requirement: 热力数值标签

`showValues` 默认为 false；为 true 时 MUST 为每个单元格输出一个 `class="heatmap-value"` 文本。

#### Scenario: 显示数值

- **WHEN** `showValues` 为 true 且矩阵有 15 个元素
- **THEN** 输出 15 个 `class="heatmap-value"`

### Requirement: 热力图校验

矩阵 MUST 非空且每行长度一致；`xAxis.labels` MUST 与列数一致，`yAxis.labels` MUST 与行数一致；元素 MUST 为数字；`cellGap` MUST 非负；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 行长度不一致

- **WHEN** 第一行 5 个元素、第二行 4 个元素
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 列标签不匹配

- **WHEN** `xAxis.labels` 有 4 个而矩阵有 5 列
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
