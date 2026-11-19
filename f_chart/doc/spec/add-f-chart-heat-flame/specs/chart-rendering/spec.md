# Spec Delta

## ADDED Requirements

### Requirement: 热火焰节点

`HeatFlameChart` MUST 为每个节点绘制一个 `class="heat-flame-node"` 矩形，宽度按 `value / 根节点 value` 分配，子节点 MUST 从父节点左端依次排列。

#### Scenario: 六个节点

- **WHEN** `nodes` 有 6 个节点
- **THEN** 输出 6 个 `heat-flame-node`

#### Scenario: 标签

- **WHEN** 节点 `name` 为 main
- **THEN** SVG 中包含 `heat-flame-label` 文本 main

### Requirement: 热度颜色

`heatFlameColor` MUST 在比例为 0 时返回冷色、为 1 时返回热色；三色时比例 0.5 MUST 返回中间色；比例 MUST 夹到 0–1。

#### Scenario: 两端色

- **WHEN** 比例为 0 与 1
- **THEN** 分别返回 `colorRange` 的首色与末色

#### Scenario: 三色中点

- **WHEN** `colorRange` 有三个颜色且比例为 0.5
- **THEN** 返回中间色

### Requirement: 热度字段

`heatField` MUST 默认为 `self`；指定字段存在时 MUST 为数字，缺省时 MUST 按 0 处理；`colorRange` MUST 至少两个合法颜色。

#### Scenario: 自定义字段

- **WHEN** `heatField` 为 cost 且节点提供 `cost`
- **THEN** 按 cost 占最大值的比例取色

#### Scenario: 非数字热度

- **WHEN** 热度字段值为字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 热火焰校验

`nodes` MUST 非空；id MUST 唯一；`parent` MUST 指向存在的节点；MUST 恰好有一个根；`value` MUST 大于 0；父节点 value MUST 不小于子节点 value 之和。

#### Scenario: 未知父节点

- **WHEN** 某节点 `parent` 为不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
