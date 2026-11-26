# Spec Delta

## ADDED Requirements

### Requirement: 泳道带

`SwimlaneChart` MUST 为每个 `lanes` 项输出一条 `class="swimlane-lane"` 矩形带与一条 `class="swimlane-label"` 名称文本；`direction` 为 `horizontal` 时带为横向、自上而下排列，为 `vertical` 时带为纵向、自左而右排列。

#### Scenario: 三条泳道

- **WHEN** `lanes` 有 3 项
- **THEN** 输出 3 个 `swimlane-lane` 与 3 个 `swimlane-label`

### Requirement: 泳道节点

`SwimlaneChart` MUST 为每个 `nodes` 项输出一个 `class="swimlane-node"` 矩形与 `class="swimlane-node-label"` 文本，节点 MUST 位于其 `lane` 对应的泳道内，同一泳道内节点 MUST 按声明顺序排列。

#### Scenario: 四个节点

- **WHEN** `nodes` 有 4 项且 `lane` 均有效
- **THEN** 输出 4 个 `swimlane-node` 与 4 个 `swimlane-node-label`

### Requirement: 泳道连线

`SwimlaneChart` MUST 为每条 `edges` 输出一条 `class="swimlane-edge"` 正交折线，并在终点绘制箭头。

#### Scenario: 三条连线

- **WHEN** `edges` 有 3 条
- **THEN** 输出 3 条 `swimlane-edge`

### Requirement: 泳道校验

`lanes` MUST 非空且 id 唯一；`nodes` MUST 非空、id 唯一、`lane` MUST 指向存在的泳道；`edges` 的 `source`/`target` MUST 指向存在的节点；`direction` MUST 为 `horizontal` 或 `vertical`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知泳道

- **WHEN** 某节点 `lane` 指向不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法方向

- **WHEN** `direction` 为 `diagonal`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 未知端点

- **WHEN** 某条边的 `target` 指向不存在的节点
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
