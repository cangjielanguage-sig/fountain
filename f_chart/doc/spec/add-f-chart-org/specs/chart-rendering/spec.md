# Spec Delta

## ADDED Requirements

### Requirement: 组织图节点

`OrgChart` MUST 为每个节点绘制一个 `class="org-node"` 矩形，矩形尺寸 MUST 等于 `nodeWidth` × `nodeHeight`；节点名称 MUST 输出为 `class="org-label"` 文本。

#### Scenario: 六个节点

- **WHEN** `nodes` 有 6 项且单根
- **THEN** 输出 6 个 `org-node` 矩形与 6 个 `org-label` 文本

### Requirement: 组织图连线

除根节点外，每个节点 MUST 输出一条 `class="org-link"` 正交折线，把父节点底部（`horizontal` 时为右侧）中点连到子节点顶部（`horizontal` 时为左侧）中点。

#### Scenario: 连线数量

- **WHEN** `nodes` 有 6 项且单根
- **THEN** 输出 5 条 `org-link` 折线

### Requirement: 组织图布局

`orgLayout` MUST 为每个叶子分配一个不相交的槽位，父节点中心 MUST 等于其子节点中心的平均值；`layout` 为 `vertical` 时同层节点沿 x 排布、层级沿 y 递增，为 `horizontal` 时同层节点沿 y 排布、层级沿 x 递增。

#### Scenario: 父节点居中

- **WHEN** 某节点有两个子节点，槽位为 0 与 1
- **THEN** 该节点的槽位为 0.5

#### Scenario: 水平布局

- **WHEN** `layout` 为 `horizontal`
- **THEN** 子节点 x 坐标大于父节点 x 坐标

### Requirement: 组织图校验

`nodes` MUST 非空、`id` 唯一、恰好一个根、`parent` 指向存在的节点且不存在环；`layout` MUST 为 `vertical` 或 `horizontal`；`nodeWidth`、`nodeHeight` MUST 大于 0，`levelGap` MUST 非负；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 未知父节点

- **WHEN** 某节点 `parent` 指向不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法布局

- **WHEN** `layout` 为 `radial`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 节点尺寸为零

- **WHEN** `nodeWidth` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
