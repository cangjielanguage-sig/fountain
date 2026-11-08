# Spec Delta

## ADDED Requirements

### Requirement: 配对连线

`PairedLineChart` MUST 为每个数据项输出一条 `class="paired-line"` 线段，起点 MUST 对应 `before`、终点 MUST 对应 `after`。

#### Scenario: 四个受试者

- **WHEN** `data` 有 4 项
- **THEN** 输出 4 条 `paired-line`

### Requirement: 配对端点与标签

每个数据项 MUST 输出 2 个 `class="paired-point"` 圆点，并 MUST 在第二个点右侧输出 `class="paired-label"` 名称文本。

#### Scenario: 端点与标签数量

- **WHEN** `data` 有 4 项
- **THEN** 输出 8 个 `paired-point` 与 4 个 `paired-label`

### Requirement: 配对连线时间点

`xAxis.labels` 非空时 MUST 恰好 2 个；两个时间点 MUST 等距分布在绘图区左右两侧。

#### Scenario: 三个时间点

- **WHEN** `xAxis.labels` 有 3 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 配对连线校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`before`、`after` MUST 为非负数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 缺少 after

- **WHEN** 某数据项没有 `after`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 类型不匹配

- **WHEN** 用 `PairedLineChart` 渲染 `type` 为 `slope` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
