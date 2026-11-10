# Spec Delta

## ADDED Requirements

### Requirement: 网络热力单元格

`NetworkHeatmapChart` MUST 为 N×N 矩阵的每个元素输出一个 `class="network-heatmap-cell"` 矩形，N MUST 等于 `nodes` 数量。

#### Scenario: 四节点

- **WHEN** `nodes` 有 4 项且矩阵为 4×4
- **THEN** 输出 16 个 `network-heatmap-cell`

#### Scenario: 节点标签

- **WHEN** 节点 `name` 为网关
- **THEN** SVG 中包含网关文本

### Requirement: 网络热力数值

`showValues` MUST 默认为 false；为 true 时 MUST 为每个单元格输出一个 `class="network-heatmap-value"` 文本。

#### Scenario: 显示数值

- **WHEN** `showValues` 为 true 且矩阵为 4×4
- **THEN** 输出 16 个 `network-heatmap-value`

### Requirement: 网络热力校验

矩阵 MUST 为方阵且阶数等于节点数；节点 id MUST 唯一；元素 MUST 为数字；单元格间距 MUST 非负；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非方阵

- **WHEN** 矩阵第一行 4 个元素、第二行 3 个元素
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 阶数不符

- **WHEN** 矩阵为 3×3 而 `nodes` 有 4 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
