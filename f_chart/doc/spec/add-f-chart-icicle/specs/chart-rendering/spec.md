# Spec Delta

## ADDED Requirements

### Requirement: 冰柱节点

`IcicleChart` MUST 为每个节点绘制一个 `class="icicle-node"` 矩形，宽度按 `value / 根节点 value` 分配，子节点 MUST 从父节点左端依次排列。

#### Scenario: 七个节点

- **WHEN** `nodes` 有 7 个节点
- **THEN** 输出 7 个 `icicle-node`

#### Scenario: 标签

- **WHEN** 节点 `name` 为 main
- **THEN** SVG 中包含 `icicle-label` 文本 main

### Requirement: 冰柱方向

`orientation` MUST 默认取 `top-down`，此时根节点 MUST 位于顶部、子节点向下展开；为 `bottom-up` 时根节点 MUST 位于底部、子节点向上展开。

#### Scenario: 默认方向

- **WHEN** 未提供 `orientation`
- **THEN** 根节点的 y 坐标小于其子节点

#### Scenario: 自底向上

- **WHEN** `orientation` 为 `bottom-up`
- **THEN** 根节点的 y 坐标大于其子节点

### Requirement: 冰柱配色

`colorBy` MUST 默认为 `name`，为 `value` 时按节点 value 占根节点的比例取色。

#### Scenario: 名称配色

- **WHEN** 未提供 `colorBy`
- **THEN** 颜色由节点名称稳定映射到调色板

### Requirement: 冰柱图校验

`nodes` MUST 非空；id MUST 唯一；`parent` MUST 指向存在的节点；MUST 恰好有一个根；`value` MUST 大于 0；父节点 value MUST 不小于子节点 value 之和；`orientation` / `colorBy` MUST 取允许值。

#### Scenario: 未知父节点

- **WHEN** 某节点 `parent` 为不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 多个根

- **WHEN** 两个节点的 `parent` 都为 null
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
