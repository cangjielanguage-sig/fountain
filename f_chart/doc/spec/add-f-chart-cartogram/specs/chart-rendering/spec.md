# Spec Delta

## ADDED Requirements

### Requirement: 变形区域

`CartogramChart` MUST 为每个 region 输出一个 `class="cartogram-region"` 的 `<path>`，并以质心为中心按 `cartogramScale` 缩放。

#### Scenario: 三个区域

- **WHEN** `regions` 有 3 项
- **THEN** 输出 3 个 `cartogram-region`

#### Scenario: 质心缺省

- **WHEN** 某 region 未提供 `centroid`
- **THEN** 使用 `pathCentroid` 计算缩放中心

### Requirement: 变形比例

`cartogramScale` MUST 在 `scaleBy` 为 `sqrt` 时返回 `sqrt(value / maxValue)`，为 `value` 时返回 `value / maxValue`；最大值的区域 MUST 返回 1。

#### Scenario: 平方根缩放

- **WHEN** value 为 100、最大值为 400、`scaleBy` 为 `sqrt`
- **THEN** 返回 0.5

#### Scenario: 线性缩放

- **WHEN** value 为 100、最大值为 400、`scaleBy` 为 `value`
- **THEN** 返回 0.25

### Requirement: 变形地图配色

未提供 `colorRange` 时 MUST 使用默认蓝色梯度；提供时 MUST 至少两个合法颜色，并按值相对最大值取色。

#### Scenario: 默认配色

- **WHEN** 未提供 `colorRange`
- **THEN** 区域填充色来自默认蓝色梯度

### Requirement: 变形地图校验

`regions` MUST 非空；`value` MUST 为非负数字；`path` MUST 至少包含两个坐标点；`centroid` 提供时 MUST 为两个数字；`scaleBy` MUST 取 `value` / `sqrt`。

#### Scenario: 非法 scaleBy

- **WHEN** `scaleBy` 为 `log`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法质心

- **WHEN** `centroid` 只有一个数字
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
