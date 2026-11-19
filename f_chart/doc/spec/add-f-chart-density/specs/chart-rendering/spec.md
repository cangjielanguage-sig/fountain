# Spec Delta

## ADDED Requirements

### Requirement: 高斯核密度

`DensityChart` SHALL 用高斯核估计密度：`f(x) = 1/(n·h·√(2π)) · Σ exp(-((x-xi)/h)²/2)`。

#### Scenario: 两个零值

- **WHEN** 数据为 `[0, 0]`、带宽为 1、在 x=0 求值
- **THEN** 密度约为 0.3989

### Requirement: 密度曲线

每个系列 MUST 输出一条 `class="density-line"` 路径；`fill` 为 true 时 MUST 额外输出 `class="density-area"` 的填充区域。

#### Scenario: 两个系列

- **WHEN** 2 个系列，其中 1 个 `fill` 为 true
- **THEN** 输出 2 条 `class="density-line"` 与 1 条 `class="density-area"`

### Requirement: 带宽与范围

`bandwidth` 缺省时 MUST 用 Silverman 规则估计；显式 `bandwidth` MUST 大于 0。x 范围 MUST 覆盖数据两侧各 3 个带宽。

#### Scenario: 非法带宽

- **WHEN** `bandwidth` 为 -1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 密度图校验

`series` 缺失 MUST 抛 `MissingField`；数据为空或非数值 MUST 抛 `InvalidValue`；`type` 不匹配 MUST 抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** 某系列 `data` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
