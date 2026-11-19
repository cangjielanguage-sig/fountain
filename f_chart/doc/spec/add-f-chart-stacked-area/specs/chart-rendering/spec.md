# Spec Delta

## ADDED Requirements

### Requirement: 堆叠面积累加

`StackedAreaChart` SHALL 按 `stack` 分组累加系列；同一分组内后一层的底边为前一层的顶边。

#### Scenario: 三层同组

- **WHEN** 3 个系列共享同一 `stack`，某类目值为 10、20、30
- **THEN** 该组类目总量为 60，且输出 3 条 `class="stacked-area"`

#### Scenario: 不同分组

- **WHEN** 两个系列 `stack` 不同
- **THEN** 两组分别从 0 起算，总量取较大组

### Requirement: 堆叠面积的 y 范围

y 轴范围 MUST 覆盖所有分组的累计最大值与最小值，并包含 0。

#### Scenario: 含负值

- **WHEN** 同组值为 20 与 -30
- **THEN** y 轴下界不超过 -10

### Requirement: 堆叠面积的校验

`series` 缺失 MUST 抛 `MissingField`；长度不一致或数值非法 MUST 抛 `InvalidValue`；`type` 不匹配 MUST 抛 `UnsupportedChart`。

#### Scenario: 长度不一致

- **WHEN** 两个系列数据长度不同
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 堆叠面积的图例

每个具名系列 SHALL 出现在图例中，颜色取 `series[].color` 或调色板。

#### Scenario: 三个系列

- **WHEN** 三个系列都有 `name`
- **THEN** 输出 3 个 `class="legend-item"`
