# Spec Delta

## ADDED Requirements

### Requirement: 二维分箱

`Histogram2DChart` SHALL 按 `bins` 把 x/y 范围等宽分箱并统计每个单元的点数；零频单元 MUST 不绘制。

#### Scenario: 三个点

- **WHEN** 数据为 3 个 `{x,y}`、`bins` 为 `[4,4]` 且落在不同单元
- **THEN** 输出 3 个单元

### Requirement: 单元形状

`shape` 为 `square` 时 MUST 输出 `class="cell"` 矩形；为 `hexagon` 时 MUST 输出 `class="hexagon"` 路径。

#### Scenario: 默认六边形

- **WHEN** 未指定 `shape`
- **THEN** 输出包含 `class="hexagon"`

### Requirement: 二维直方图校验

`bins` MUST 为两个正整数；点 MUST 为有限数值；`shape` MUST 为合法枚举；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法分箱

- **WHEN** `bins` 为 `[0, 4]`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非数值坐标

- **WHEN** 某点 `x` 为字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
