# Spec Delta

## ADDED Requirements

### Requirement: 百分比条入口

`type` 为 `percent-bar` 时 MUST 由 `PercentBarChart` 渲染，且 MUST 复用 `percent-stacked-bar` 的百分比堆叠算法：每个类目归一化到 100%，纵向堆叠各系列。

#### Scenario: 文档示例

- **WHEN** 输入 4 个类目、3 个系列的 `percent-bar`
- **THEN** 输出 12 个 `class="bar"` 矩形与 3 条图例文本

### Requirement: 百分比条校验

`series` MUST 非空且各系列数据长度 MUST 等于类目数；`yAxis.max` MUST 被固定为 100；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 类型不匹配

- **WHEN** 用 `PercentBarChart` 渲染 `type` 为 `bar` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

#### Scenario: 数据长度不一致

- **WHEN** 类目数为 4、某系列只有 3 个数值
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
