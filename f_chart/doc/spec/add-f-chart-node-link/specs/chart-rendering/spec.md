# Spec Delta

## ADDED Requirements

### Requirement: 节点与连线

`NodeLinkChart` MUST 为每个节点输出一个 `class="node-link-node"` 圆点，为每条链接输出一条 `class="node-link-edge"` 线段。

#### Scenario: 五个节点五条链接

- **WHEN** `nodes` 有 5 项、`links` 有 5 项
- **THEN** 输出 5 个 `node-link-node` 与 5 条 `node-link-edge`

#### Scenario: 节点标签

- **WHEN** 节点 `name` 为网关
- **THEN** SVG 中包含 `node-link-label` 文本网关

### Requirement: 布局模式

`layout` MUST 取 `force` / `circular` / `manual`，默认 `force`；`manual` 时每个节点 MUST 提供 `x` 与 `y`。

#### Scenario: 手工坐标

- **WHEN** `layout` 为 `manual` 且节点提供 `x`、`y`
- **THEN** 正常输出节点与连线

#### Scenario: 手工缺坐标

- **WHEN** `layout` 为 `manual` 但某节点缺少 `y`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 非法布局

- **WHEN** `layout` 为 `grid`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 连线宽度

`nodeLinkWidth` MUST 在 value 为 0 时返回 1、在等于最大 value 时返回 4。

#### Scenario: 最大权重

- **WHEN** `value` 等于最大链路值
- **THEN** 线宽为 4

### Requirement: 节点链接图校验

`nodes` MUST 非空且 id 唯一；`links` MUST 非空；`source` / `target` MUST 指向存在的节点；`value` 提供时 MUST 大于 0。

#### Scenario: 未知端点

- **WHEN** 某链接 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 重复节点 id

- **WHEN** 两个节点使用相同 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
