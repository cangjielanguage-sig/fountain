# Spec Delta

## ADDED Requirements

### Requirement: 火焰节点

`FlameChart` MUST 为每个节点绘制一个 `class="flame-node"` 矩形，宽度按 `value / 根节点 value` 占满绘图区，子节点 MUST 从父节点左端依次排列。

#### Scenario: 七个节点

- **WHEN** `nodes` 有 7 个节点
- **THEN** 输出 7 个 `flame-node`

#### Scenario: 标签

- **WHEN** 节点 `name` 为 main
- **THEN** SVG 中包含 `flame-label` 文本 main

### Requirement: 火焰方向

`orientation` MUST 默认取 `bottom-up`，此时根节点 MUST 位于底部、子节点逐层向上；为 `top-down` 时根节点 MUST 位于顶部、子节点向下展开。

#### Scenario: 自底向上

- **WHEN** 未提供 `orientation`
- **THEN** 根节点的 y 坐标大于其子节点

#### Scenario: 自顶向下

- **WHEN** `orientation` 为 `top-down`
- **THEN** 根节点的 y 坐标小于其子节点

### Requirement: 火焰配色

`colorBy` 默认为 `name`，此时颜色 MUST 由 `flameColorIndex(name, paletteSize)` 决定且对相同名称稳定；为 `value` 时 MUST 按节点 value 占根节点的比例取色。

#### Scenario: 名称配色稳定

- **WHEN** 连续两次计算 main 的颜色下标
- **THEN** 两次结果相同且在 0–paletteSize−1 之间

### Requirement: 火焰图校验

`nodes` MUST 非空；节点 id MUST 唯一；`parent` MUST 指向存在的节点；MUST 恰好有一个根；`value` MUST 大于 0；父节点 value MUST 不小于子节点 value 之和；`orientation` / `colorBy` MUST 取允许值。

#### Scenario: 未知父节点

- **WHEN** 某节点 `parent` 为不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 多个根

- **WHEN** 两个节点的 `parent` 都为 null
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
