# Spec Delta

## ADDED Requirements

### Requirement: 圆堆积节点

`CirclePackingChart` MUST 为每个节点绘制一个 `class="circle-packing-circle"` 圆；父圆 MUST 包住其子圆。

#### Scenario: 七个节点

- **WHEN** `nodes` 有 7 项且单根
- **THEN** 输出 7 个 `circle-packing-circle`

### Requirement: 圆面积

`circlePackingRadius` MUST 返回 `sqrt(value) * scale`，使圆面积与节点总量成正比。

#### Scenario: 半径计算

- **WHEN** value 为 100、scale 为 2
- **THEN** 半径为 20

### Requirement: 圆堆积标签

半径不小于 18 的节点 MUST 输出 `class="circle-packing-label"` 文本。

#### Scenario: 大圆标签

- **WHEN** 根圆半径大于 18
- **THEN** SVG 中包含 `circle-packing-label` 文本

### Requirement: 圆堆积校验

`nodes` MUST 非空、id 唯一、恰好一个根、`parent` 指向存在的节点；叶子 MUST 提供大于 0 的 `value`；`padding` MUST 非负；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负间距

- **WHEN** `padding` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 叶子缺值

- **WHEN** 某叶子节点未提供 `value`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
