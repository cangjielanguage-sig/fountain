# Spec Delta

## ADDED Requirements

### Requirement: 箱线散点绘制

`BoxScatterChart` MUST 为每组绘制一个箱体、一条中位线、一条须线与两个端帽，并为每个样本绘制一个 `class="box-scatter-point"` 圆点。

#### Scenario: 单组十个样本

- **WHEN** 扁平 `data` 有 10 个数值且 `showBox` 为 true
- **THEN** 输出 10 个 `box-scatter-point`、1 个 `box-scatter-box`、1 条 `box-scatter-median`、1 条 `box-scatter-whisker`、2 个 `box-scatter-cap`

#### Scenario: 关闭箱体

- **WHEN** `showBox` 为 false
- **THEN** 输出 0 个 `box-scatter-box`，但原始点数量不变

### Requirement: 箱体统计

`boxScatterBounds` MUST 返回 `[下须, Q1, 中位数, Q3, 上须]`；须线端点 MUST 取 1.5 倍四分位距栅栏内的最小与最大值。

#### Scenario: 一到十

- **WHEN** 已排序数据为 1–10
- **THEN** 返回 `[1, 3, 5, 7, 10]`

### Requirement: 抖动范围

`jitter` MUST 在 0–1 之间，默认 0.15；抖动偏移 MUST 由 `swarmOffsets` 归一化后按组半宽缩放。

#### Scenario: 非法抖动

- **WHEN** `jitter` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 箱线散点校验

嵌套数组时 `xAxis.labels` MUST 与组数一致；每组 MUST 非空且全为数字；`data` 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 组数与标签不一致

- **WHEN** 两组数据但 `xAxis.labels` 有三个标签
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
