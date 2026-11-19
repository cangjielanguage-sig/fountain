# Spec Delta

## ADDED Requirements

### Requirement: 地图区域

`ChoroplethChart` MUST 为每个 region 输出一个 `class="choropleth-region"` 的 `<path>`，路径数据 MUST 原样使用 `path` 字段。

#### Scenario: 四个区域

- **WHEN** `regions` 有 4 项
- **THEN** 输出 4 个 `choropleth-region`

#### Scenario: 视图框

- **WHEN** `viewBox` 为 `[0, 0, 760, 560]`
- **THEN** SVG 根元素包含 `viewBox="0 0 760 560"`

### Requirement: 区域配色

区域颜色 MUST 按 `value` 相对最小/最大值归一化后从 `colorRange` 取色；最小值 MUST 取首色，最大值 MUST 取末色。

#### Scenario: 最值

- **WHEN** 区域值等于最小值与最大值
- **THEN** 分别使用 `colorRange` 首色与末色

### Requirement: 地图标签

`showLabels` MUST 默认为 false；为 true 时 MUST 为每个区域输出一个 `class="choropleth-label"` 文本，位置取路径坐标均值。

#### Scenario: 显示标签

- **WHEN** `showLabels` 为 true 且 `regions` 有 4 项
- **THEN** 输出 4 个 `choropleth-label`

#### Scenario: 路径质心

- **WHEN** 路径为边长 10 的正方形
- **THEN** `pathCentroid` 返回 `[5, 5]`

### Requirement: 地图校验

`regions` MUST 非空；每项 MUST 有字符串 `path` 与数字 `value`；`path` MUST 至少包含两个坐标点；`colorRange` MUST 至少两个合法颜色；`regions` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法路径

- **WHEN** `path` 不含坐标数字
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
