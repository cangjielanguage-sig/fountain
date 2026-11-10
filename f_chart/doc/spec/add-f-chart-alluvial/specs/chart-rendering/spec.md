# Spec Delta

## ADDED Requirements

### Requirement: 冲积节点

`AlluvialChart` MUST 按 `stages` 顺序把节点排成列，每列内节点自上而下堆叠，并为每个节点输出一个 `class="alluvial-node"` 矩形与一个 `class="alluvial-label"` 文本。

#### Scenario: 五个节点两个阶段

- **WHEN** `nodes` 有 5 项、`stages` 有 2 项
- **THEN** 输出 5 个 `alluvial-node` 与 5 个 `alluvial-label`

### Requirement: 冲积流量带

`AlluvialChart` MUST 为每条链接输出一条 `class="alluvial-link"` 填充带，带宽由 `value` 与列高比例决定。

#### Scenario: 五条链接

- **WHEN** `links` 有 5 项
- **THEN** 输出 5 条 `alluvial-link`

### Requirement: 列内高度

`alluvialHeights` MUST 按总量比例分配可用高度，并扣除节点间距；总量为 1、1、可用高度 100、间距 10 时 MUST 返回 `[45, 45]`。

#### Scenario: 两节点均分

- **WHEN** totals 为 `[1, 1]`、available 为 100、gap 为 10
- **THEN** 返回 `[45, 45]`

### Requirement: 冲积图校验

`stages` MUST 非空；节点 `stage` MUST 属于 `stages`；`links` MUST 非空且 value 大于 0；`nodeWidth` MUST 大于 0；`nodeGap` MUST 非负；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知阶段

- **WHEN** 某节点 `stage` 不在 `stages` 中
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非正节点宽

- **WHEN** `nodeWidth` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
