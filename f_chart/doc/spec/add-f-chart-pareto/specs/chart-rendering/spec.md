# Spec Delta

## ADDED Requirements

### Requirement: 帕累托柱

`ParetoChart` SHALL 按数值降序绘制 `class="pareto-bar"` 柱。

#### Scenario: 六个类别

- **WHEN** `data` 有 6 个数值
- **THEN** 输出 6 个 `class="pareto-bar"`

### Requirement: 累计折线

`showCumulative` 默认为 true，此时 MUST 输出 1 条 `class="pareto-line"` 与每个类别一个 `class="pareto-point"`；为 false 时不输出。

#### Scenario: 关闭累计

- **WHEN** `showCumulative` 为 false
- **THEN** 输出 0 条 `class="pareto-line"` 与 0 个 `class="pareto-point"`

### Requirement: 降序与累计

`paretoOrder` MUST 返回降序下标；`paretoCumulative` MUST 返回累计百分比，最后一项为 100。

#### Scenario: 排序

- **WHEN** 值为 30、120、80
- **THEN** 下标顺序为 1、2、0

#### Scenario: 累计百分比

- **WHEN** 值为 120、80、55、30、12、8
- **THEN** 最后一项为 100

### Requirement: 帕累托校验

数值 MUST 非负；标签长度 MUST 与数据一致；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 长度不一致

- **WHEN** 标签 3 个而数据 4 个
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 负值

- **WHEN** 某值为 -5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
