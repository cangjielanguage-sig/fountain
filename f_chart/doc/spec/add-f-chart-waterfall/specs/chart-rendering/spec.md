# Spec Delta

## ADDED Requirements

### Requirement: 瀑布图增减累计

`WaterfallChart` SHALL 按数据顺序累计：`total` 从 0 画到 `value` 并重置累计；其余类型从当前累计画到 `当前累计 + value`。

#### Scenario: 期初到期末

- **WHEN** 数据为 total 120、increase 80、decrease -45、total 140
- **THEN** 输出 4 根柱，最后累计为 140

#### Scenario: 负值

- **WHEN** `value` 为 -45
- **THEN** 该柱从累计 200 画到 155，且带 `waterfall-decrease`

### Requirement: 瀑布图连接器

相邻柱之间 MUST 绘制 1 条 `class="connector"` 的虚线，数量为柱数减一。

#### Scenario: 五根柱

- **WHEN** 数据有 5 项
- **THEN** 输出 4 条 `class="connector"`

### Requirement: 瀑布图轴范围与校验

y 轴范围 MUST 覆盖 0 与所有累计端点；`series` MUST 恰好 1 个；`value` 必须为有限数。

#### Scenario: 多个系列

- **WHEN** `series` 有 2 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非数值

- **WHEN** 某 `value` 为字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 瀑布图类型校验

`type` 不匹配 MUST 抛 `UnsupportedChart`；`series` 缺失 MUST 抛 `MissingField`。

#### Scenario: 类型不匹配

- **WHEN** `type` 为 `bar`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
