# Spec Delta

## ADDED Requirements

### Requirement: 残差点

`ResidualChart` MUST 为每个 `{x, y}` 数据点绘制一个 `class="residual-point"` 圆点。

#### Scenario: 六个残差

- **WHEN** `data` 有 6 个 `{x, y}` 对象
- **THEN** 输出 6 个 `class="residual-point"`

### Requirement: 残差零线

`ResidualChart` MUST 绘制一条 y=0 的 `class="residual-zero"` 参考线。

#### Scenario: 零线

- **WHEN** 数据残差在 −2 到 2 之间
- **THEN** 输出 1 条 `class="residual-zero"`

### Requirement: 残差轴范围

y 轴范围 MUST 同时覆盖全部残差与 0；未显式指定 `yAxis.min` / `yAxis.max` 时两侧 MUST 留出余量。

#### Scenario: 全部为正

- **WHEN** 全部残差都大于 0
- **THEN** y 轴范围仍包含 0

### Requirement: 残差校验

`x` / `y` MUST 为数字；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非数字残差

- **WHEN** 某点 `y` 为字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 空数据

- **WHEN** `data` 为空数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
