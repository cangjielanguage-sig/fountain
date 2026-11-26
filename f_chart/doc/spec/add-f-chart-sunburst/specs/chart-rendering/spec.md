# Spec Delta

## ADDED Requirements

### Requirement: 旭日扇环

`SunburstChart` MUST 为根节点之外的每个节点绘制一个 `class="sunburst-arc"` 扇环，扇环角度按节点总量占父节点的比例分配。

#### Scenario: 七个节点

- **WHEN** `nodes` 有 7 项且单根
- **THEN** 输出 6 个 `sunburst-arc`

#### Scenario: 扇环路径

- **WHEN** 调用 `sunburstArcPath`
- **THEN** 返回同时包含内外两段圆弧的闭合路径

### Requirement: 旭日标签

`SunburstChart` MUST 为深度为 1 的节点输出 `class="sunburst-label"` 文本。

#### Scenario: 两个一级分类

- **WHEN** 根节点有 2 个子节点
- **THEN** 输出 2 个 `sunburst-label`

### Requirement: 旭日排序

`sort` MUST 取 `value` / `none`，默认 `value`；为 `value` 时同级子节点 MUST 按总量降序排列。

#### Scenario: 默认排序

- **WHEN** 未提供 `sort`
- **THEN** 同级子节点按总量降序排列

### Requirement: 旭日图校验

`nodes` MUST 非空、id 唯一、恰好一个根、`parent` 指向存在的节点；叶子 MUST 提供大于 0 的 `value`；`innerRadius` MUST 在 0–0.95 之间；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法内半径

- **WHEN** `innerRadius` 为 1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 叶子缺值

- **WHEN** 某叶子节点未提供 `value`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
