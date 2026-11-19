# Spec Delta

## ADDED Requirements

### Requirement: 树图叶子

`TreemapChart` SHALL 为每个叶子节点绘制一个 `class="treemap-cell"` 矩形，面积与节点值成正比。

#### Scenario: 四个叶子

- **WHEN** 层级中有 4 个带 `value` 的叶子
- **THEN** 输出 4 个 `class="treemap-cell"`

### Requirement: 树图布局

布局 MUST 按子节点值比例划分父矩形；内部节点值 MUST 等于子节点值之和。

#### Scenario: 权重归一化

- **WHEN** 叶子值为 120、260、90、60
- **THEN** 权重总和为 1，首项为 120/530

### Requirement: 树图标签

每个叶子 MUST 输出 `class="treemap-label"` 名称文本。

#### Scenario: 四个标签

- **WHEN** 有 4 个叶子
- **THEN** 输出 4 个 `class="treemap-label"`

### Requirement: 树图校验

`parent` MUST 指向存在的节点；叶子 `value` MUST 大于 0；`tiling` MUST 为 `squarify`；`nodes` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 悬空父节点

- **WHEN** 某节点 `parent` 指向不存在的 id
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法 tiling

- **WHEN** `tiling` 为 `binary`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
