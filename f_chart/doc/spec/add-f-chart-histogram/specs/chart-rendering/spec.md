# Spec Delta

## ADDED Requirements

### Requirement: 直方图分箱

`HistogramChart` SHALL 按 `bins` 把数据范围等宽分箱并统计频数；最大值 MUST 归入最后一箱；零频箱 MUST 不绘制。

#### Scenario: 均匀八值四箱

- **WHEN** 数据为 1–8 且 `bins` 为 4
- **THEN** 输出 4 根 `class="histogram-bar"`，每箱频数为 2

#### Scenario: 单值数据

- **WHEN** 所有数据相同且 `bins` 为 4
- **THEN** 只输出 1 根柱

### Requirement: 直方图的轴

x 轴 MUST 为连续数值轴并显示刻度；y 轴 MUST 从 0 开始表示频数。

#### Scenario: 刻度

- **WHEN** 数据范围为 1–8
- **THEN** 输出至少 2 个 `class="tick-label"`

### Requirement: 直方图的校验

`series` MUST 恰好 1 个；`data` 非空且全为数值；`bins` 为正整数；否则抛 `ChartException`。

#### Scenario: 多个系列

- **WHEN** `series` 有 2 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法 bins

- **WHEN** `bins` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 直方图类型校验

`type` 不匹配 MUST 抛 `UnsupportedChart`；`series` 缺失 MUST 抛 `MissingField`。

#### Scenario: 类型不匹配

- **WHEN** `type` 为 `bar`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
