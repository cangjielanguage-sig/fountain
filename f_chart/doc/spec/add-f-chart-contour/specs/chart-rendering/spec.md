# Spec Delta

## ADDED Requirements

### Requirement: 等高线网格

`ContourChart` SHALL 把 `{x,y,value}` 点整理成规则网格，每个单元输出 `class="contour-cell"` 并按值分层着色。

#### Scenario: 三乘三网格

- **WHEN** 数据为 9 个点组成的 3×3 网格
- **THEN** 输出 4 个 `class="contour-cell"`

### Requirement: 等值边界

相邻单元层级不同时 MUST 在共享边绘制 `class="contour-line"` 线段。

#### Scenario: 梯度数据

- **WHEN** value 从 10 递增到 34 且 `levels` 为 4
- **THEN** 输出至少 1 条 `class="contour-line"`

### Requirement: 等高线参数

`levels` MUST 为正整数或递增数组；`interpolate` MUST 为 `linear` / `nearest`；否则抛 `InvalidValue`。

#### Scenario: 非法层级

- **WHEN** `levels` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 等高线校验

网格 MUST 完整且无重复坐标；`value` MUST 为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 缺少网格点

- **WHEN** 3×3 网格缺少一个点
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
