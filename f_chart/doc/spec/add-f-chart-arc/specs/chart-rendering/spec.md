# Spec Delta

## ADDED Requirements

### Requirement: 弧线图节点

`ArcChart` MUST 把节点均匀排列在绘图区中心的圆周上，并为每个节点输出一个 `class="arc-node"` 圆点与一个 `class="arc-label"` 文本。

#### Scenario: 五个节点

- **WHEN** `nodes` 有 5 项
- **THEN** 输出 5 个 `arc-node` 与 5 个 `arc-label`

### Requirement: 弧线与弧高

`ArcChart` MUST 为每条链接输出一条 `class="arc-line"` 二次贝塞尔曲线；`arcHeight` MUST 在 0–1 之间，默认 0.5，越大弧线越靠近圆心。

#### Scenario: 四条链接

- **WHEN** `links` 有 4 项
- **THEN** 输出 4 条 `arc-line`

#### Scenario: 非法弧高

- **WHEN** `arcHeight` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 弧线图排序

`sort` MUST 取 `value` / `none`，默认 `none`；为 `value` 时 `arcNodeOrder` MUST 按节点关联总流量降序返回下标。

#### Scenario: 按值排序

- **WHEN** 节点总流量为 3、10、5
- **THEN** 下标顺序为 1、2、0

### Requirement: 弧线图校验

`nodes` MUST 至少两个且 id 唯一；`links` MUST 非空；`source` / `target` MUST 指向存在的节点；`value` 提供时 MUST 大于 0；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知端点

- **WHEN** 某链接 `target` 不存在
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
