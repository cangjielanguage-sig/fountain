# Spec Delta

## ADDED Requirements

### Requirement: 概率图散点

`ProbabilityChart` MUST 为每个样本值绘制一个 `class="probability-point"` 圆点，横坐标为理论分位数、纵坐标为排序后的样本值。

#### Scenario: 十一个样本

- **WHEN** `data` 有 11 个数值
- **THEN** 输出 11 个 `class="probability-point"`

### Requirement: 概率图参考线

`showLine` 默认为 true，此时 MUST 输出 1 条 `class="probability-line"`；为 false 时不输出。

#### Scenario: 关闭参考线

- **WHEN** `showLine` 为 false
- **THEN** 输出 0 条 `class="probability-line"`

### Requirement: 概率分布选择

`distribution` MUST 为 `normal` / `uniform` / `exponential` 之一；缺省时 MUST 使用 `normal`。

#### Scenario: 均匀分布

- **WHEN** `distribution` 为 `uniform`
- **THEN** 正常输出散点与参考线

#### Scenario: 未知分布

- **WHEN** `distribution` 为 `poisson`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 概率图校验

`data` MUST 非空且全为数字；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非数字样本

- **WHEN** `data` 含字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
