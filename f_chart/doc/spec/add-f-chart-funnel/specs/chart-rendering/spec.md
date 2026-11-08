# Spec Delta

## ADDED Requirements

### Requirement: 漏斗阶段

`FunnelChart` SHALL 为每个阶段绘制一个 `class="funnel-stage"` 阶段条，宽度与数值成正比。

#### Scenario: 四个阶段

- **WHEN** `data` 有 4 个 `{name,value}`
- **THEN** 输出 4 个 `class="funnel-stage"`

### Requirement: 转化率

`showConversion` 默认为 true，相邻阶段之间 MUST 输出 `class="conversion-label"`，文本为 `next / current × 100%`。

#### Scenario: 转化率数值

- **WHEN** 当前阶段为 10000、下一阶段为 6200
- **THEN** 转化率为 62.0%

### Requirement: 漏斗标签

每个阶段 MUST 输出 `class="stage-label"` 名称与数值文本。

#### Scenario: 四个标签

- **WHEN** 阶段数为 4
- **THEN** 输出 4 个 `class="stage-label"`

### Requirement: 漏斗校验

数值 MUST 非负且最大值大于 0；`series` MUST 恰好 1 个；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负值

- **WHEN** 某 `value` 为 -5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
