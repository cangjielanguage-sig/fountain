# Spec Delta

## ADDED Requirements

### Requirement: 蜂巢节点

`HiveChart` MUST 按 `groupField` 把节点分组，并把各组均匀布置在绘图区圆周上；每个节点 MUST 输出一个 `class="hive-node"` 圆点与一个 `class="hive-label"` 文本。

#### Scenario: 五个节点三个分组

- **WHEN** `nodes` 有 5 项
- **THEN** 输出 5 个 `hive-node` 与 5 个 `hive-label`

### Requirement: 蜂巢连线

`HiveChart` MUST 为每条链接输出一条 `class="hive-link"` 线段，连接两端节点圆心。

#### Scenario: 四条链接

- **WHEN** `links` 有 4 项
- **THEN** 输出 4 条 `hive-link`

### Requirement: 蜂巢参数

`nodeRadius` MUST 默认 10 且大于 0；`clusterGap` MUST 默认 80 且大于 0；`groupField` MUST 非空。

#### Scenario: 默认半径

- **WHEN** 未提供 `nodeRadius`
- **THEN** 节点半径为 10

### Requirement: 蜂巢校验

`nodes` MUST 非空且 id 唯一；`links` MUST 非空；`source` / `target` MUST 指向存在的节点；`value` 提供时 MUST 大于 0；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知端点

- **WHEN** 某链接 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非正半径

- **WHEN** `nodeRadius` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
