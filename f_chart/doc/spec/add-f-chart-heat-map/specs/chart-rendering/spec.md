# Spec Delta

## ADDED Requirements

### Requirement: 热力地图底图

`HeatMapChart` MUST 为每个 region 输出一个 `class="heat-map-region"` 的 `<path>`。

#### Scenario: 一个底图区域

- **WHEN** `regions` 有 1 项
- **THEN** 输出 1 个 `heat-map-region`

### Requirement: 热力点

`HeatMapChart` MUST 为每个 point 输出一个 `class="heat-map-point"` 圆点，半径为 `radius`，填充色按 `value` 相对最大值取 `colorRange` 插值。

#### Scenario: 四个热力点

- **WHEN** `points` 有 4 项
- **THEN** 输出 4 个 `heat-map-point`

#### Scenario: 默认半径

- **WHEN** 未提供 `radius`
- **THEN** 圆点半径为 24

### Requirement: 热力地图颜色

`colorRange` MUST 至少两个合法颜色；最小值的点 MUST 取首色，最大值 MUST 取末色。

#### Scenario: 最值取色

- **WHEN** 点值为最小值或最大值
- **THEN** 分别使用 `colorRange` 首色与末色

### Requirement: 热力地图校验

`points` MUST 非空；`value` MUST 为非负数字；`radius` MUST 大于 0；`points` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负值

- **WHEN** 某点 `value` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非正半径

- **WHEN** `radius` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
