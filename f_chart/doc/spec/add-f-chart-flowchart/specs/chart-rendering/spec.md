# Spec Delta

## ADDED Requirements

### Requirement: 流程图节点与边

`Flowchart` SHALL 按 `nodes` 绘制节点、按 `edges` 绘制带箭头的边；`source` / `target` MUST 指向存在的节点。

#### Scenario: 四个节点

- **WHEN** `nodes` 有 4 项
- **THEN** 输出 4 个 `class="node"`

#### Scenario: 悬空边

- **WHEN** 某条边的 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 节点形状

`shape` 为 `diamond` 时 MUST 输出 `node-diamond`；`ellipse` / `parallelogram` / `document` MUST 使用对应路径或椭圆。

#### Scenario: 菱形判断节点

- **WHEN** 节点 `shape` 为 `diamond`
- **THEN** 输出包含 `class="node node-diamond"`

### Requirement: 自动布局

`layout` 为 `vertical` 时 SHALL 按入边深度自上而下分层；`manual` 时 MUST 使用节点 `x` / `y`。

#### Scenario: 链式三层

- **WHEN** A→B→C 且 layout 为 vertical
- **THEN** 三个节点的 y 坐标递增
