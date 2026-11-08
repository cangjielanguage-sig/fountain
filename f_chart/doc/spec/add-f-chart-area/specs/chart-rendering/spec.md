# Spec Delta

## ADDED Requirements

### Requirement: 面积图填充

`AreaChart` SHALL 在折线下方绘制填充区域，范围从曲线到 0 基线；填充路径 class 为 `area`，描边路径 class 为 `line`。

#### Scenario: 四个类目

- **WHEN** `xAxis.labels` 有 4 项且 `series[0].data` 为 4 个数值
- **THEN** 输出 1 条 `class="area"` 与 1 条 `class="line"`

#### Scenario: 填充透明度

- **WHEN** `areaStyle.opacity` 为 0.25
- **THEN** 填充路径包含 `fill-opacity="0.25"`

### Requirement: 面积图缺测

`null` MUST 断开面积与折线，相邻有效点形成独立路径。

#### Scenario: 中间缺测

- **WHEN** 数据为 `[10, 20, null, 40, 50]`
- **THEN** 输出 2 条 `class="area"` 与 2 条 `class="line"`

### Requirement: 面积图的轴与数据形状

`AreaChart` MUST 支持类目数值数组与 `{x,y}` 连续点，同一图内不得混用；y 轴默认包含 0。

#### Scenario: 连续点

- **WHEN** 数据为 `{x: 0, y: 5}` 与 `{x: 10, y: 15}`
- **THEN** 输出包含 1 条 `class="area"`

#### Scenario: 混合形状

- **WHEN** 一个系列用数值数组、另一个用对象数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 面积图的校验

`type` 不匹配 MUST 抛 `UnsupportedChart`；`series` 缺失 MUST 抛 `MissingField`；长度或数值非法 MUST 抛 `InvalidValue`。

#### Scenario: 类型不匹配

- **WHEN** `type` 为 `line`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
