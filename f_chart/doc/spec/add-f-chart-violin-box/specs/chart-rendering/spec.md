# Spec Delta

## ADDED Requirements

### Requirement: 小提琴箱线绘制

`ViolinBoxChart` MUST 为每组绘制一个 `class="violin-box-violin"` 轮廓；`showBox` 为 true 时 MUST 再绘制箱体、中位线、须线与两个端帽。

#### Scenario: 单组

- **WHEN** 单组数据且 `showBox` 为 true
- **THEN** 输出 1 个 `violin-box-violin`、1 个 `violin-box-box`、1 条 `violin-box-median`、1 条 `violin-box-whisker`、2 个 `violin-box-cap`

#### Scenario: 关闭箱体

- **WHEN** `showBox` 为 false
- **THEN** 输出 0 个 `violin-box-box`，但 `violin-box-violin` 仍为 1

### Requirement: 异常值

`showOutliers` 默认为 true，此时 MUST 为超出 1.5 倍四分位距栅栏的样本绘制 `class="violin-box-outlier"` 圆点；为 false 时不输出。

#### Scenario: 极端值

- **WHEN** 数据为 1–9 与 100
- **THEN** 输出 1 个 `violin-box-outlier`

#### Scenario: 关闭异常值

- **WHEN** `showOutliers` 为 false
- **THEN** 输出 0 个 `violin-box-outlier`

### Requirement: 小提琴带宽

`bandwidth` 提供时 MUST 大于 0；未提供时 MUST 使用 `defaultBandwidth`（Silverman 规则）。

#### Scenario: 非法带宽

- **WHEN** `bandwidth` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 小提琴箱线校验

嵌套数组时 `xAxis.labels` MUST 与组数一致；每组 MUST 非空且全为数字；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 组数与标签不一致

- **WHEN** 两组数据但标签有三个
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
