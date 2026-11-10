# Spec Delta

## ADDED Requirements

### Requirement: 桑基节点

`SankeyChart` SHALL 为每个节点绘制 `class="sankey-node"` 矩形，并按吞吐量确定高度。

#### Scenario: 六个节点

- **WHEN** `nodes` 有 6 项
- **THEN** 输出 6 个 `class="sankey-node"`

### Requirement: 桑基流量带

每条 `link` MUST 输出一条 `class="sankey-link"` 路径，线宽与 `value` 成正比。

#### Scenario: 五条流量

- **WHEN** `links` 有 5 项
- **THEN** 输出 5 条 `class="sankey-link"`

### Requirement: 层级计算

`sankeyLayers(nodeCount, sources, targets)` MUST 返回每个节点的最长路径层级。

#### Scenario: 链式分层

- **WHEN** 链接为 0→2、1→2、2→3、3→4、4→5
- **THEN** 层级为 0、0、1、2、3、4

### Requirement: 桑基校验

`source`/`target` MUST 指向存在的节点；`value` MUST 大于 0；`nodes`/`links` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 悬空端点

- **WHEN** 某链接 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
