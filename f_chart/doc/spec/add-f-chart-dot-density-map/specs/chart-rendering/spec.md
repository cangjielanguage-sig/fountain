# Spec Delta

## ADDED Requirements

### Requirement: 点密度底图

`DotDensityMapChart` MUST 为每个 region 输出一个 `class="dot-density-region"` 的 `<path>`；`regions` 缺省时 MUST 只绘制点。

#### Scenario: 一个底图区域

- **WHEN** `regions` 有 1 项
- **THEN** 输出 1 个 `dot-density-region`

#### Scenario: 无底图

- **WHEN** 未提供 `regions`
- **THEN** 仍输出全部 `dot-density-point`

### Requirement: 点密度点位

`DotDensityMapChart` MUST 为每个 point 输出一个 `class="dot-density-point"` 圆点，圆心为 `(x, y)`。

#### Scenario: 五个点

- **WHEN** `points` 有 5 项
- **THEN** 输出 5 个 `dot-density-point`

### Requirement: 点密度半径

`radius` MUST 默认为 3 且大于 0；`dotDensityRadius` MUST 按权重平方根缩放：权重 1 返回基准半径，权重 4 返回两倍基准半径。

#### Scenario: 权重四

- **WHEN** 基准半径为 3、权重为 4
- **THEN** 半径为 6

### Requirement: 点密度校验

`points` MUST 非空；`x` / `y` MUST 为数字；`weight` 提供时 MUST 大于 0；`radius` MUST 大于 0；`points` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空点集

- **WHEN** `points` 为空数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 负权重

- **WHEN** 某点 `weight` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
