# Spec Delta

## ADDED Requirements

### Requirement: 决策树节点

`DecisionTreeChart` MUST 为每个节点输出一个 `class="decision-node"` 矩形与 `class="decision-node-label"` 文本；`leaf` 为 `true` 的节点 MUST 追加 `decision-leaf`。

#### Scenario: 五个节点

- **WHEN** `nodes` 有 5 项、其中 3 个为叶子
- **THEN** 输出 5 个 `decision-node`、5 个 `decision-node-label`，其中 3 个带 `decision-leaf`

### Requirement: 决策树分支

`DecisionTreeChart` MUST 为每条边输出一条 `class="decision-edge"` 折线；边提供 `label` 时 MUST 输出 `class="decision-edge-label"` 文本。

#### Scenario: 四条分支

- **WHEN** `edges` 有 4 条且均带 `label`
- **THEN** 输出 4 条 `decision-edge` 与 4 个 `decision-edge-label`

### Requirement: 决策树布局

`decisionTreeLayout` MUST 为每个叶子分配不相交槽位，父节点槽位 MUST 等于子节点槽位平均值，层级 MUST 沿纵轴递增。

#### Scenario: 两个子节点

- **WHEN** 某节点有两个叶子子节点
- **THEN** 该节点槽位为两子节点槽位的中点，子节点 y 大于父节点 y

### Requirement: 决策树校验

`nodes` MUST 非空且 `id` 唯一；`edges` 的 `source`/`target` MUST 指向存在的节点；树 MUST 恰好一个根且无环；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知端点

- **WHEN** 某条边的 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 多个根

- **WHEN** `nodes` 中有两个无入边节点
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
