# Spec Delta

## ADDED Requirements

### Requirement: 分组柱状图布局

`GroupedBarChart` SHALL 在同一类目槽位内并列绘制每个系列的柱；柱宽 MUST 小于等于子槽宽度，同组柱 MUST 不重叠。

#### Scenario: 两组三系列

- **WHEN** 输入 2 个系列、3 个类目
- **THEN** 输出包含 6 个 `class="bar"` 的 `rect`，且同一类目的两个柱 x 坐标不同

#### Scenario: 共享数值轴

- **WHEN** 两个系列数值范围不同
- **THEN** 两系列使用同一个 `yAxis` 比例尺，柱高可直接比较

### Requirement: 分组柱的系列样式

每个系列 SHALL 使用 `series[].color` 或调色板对应颜色；图例 MUST 展示所有具名系列。

#### Scenario: 图例

- **WHEN** 两个系列都带 `name`
- **THEN** 输出包含两个 `class="legend-item"`

### Requirement: 分组柱的校验

`GroupedBarChart` MUST 复用柱状图校验：`type` 不匹配抛 `UnsupportedChart`，`series` 缺失抛 `MissingField`，长度或数值非法抛 `InvalidValue`。

#### Scenario: 类型不匹配

- **WHEN** 传入 `type` 为 `bar` 的 JSON
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
