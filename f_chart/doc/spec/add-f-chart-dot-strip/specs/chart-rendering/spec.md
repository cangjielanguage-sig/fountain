# Spec Delta

## ADDED Requirements

### Requirement: 豆图散点

`DotStripChart` MUST 为每个观测数值输出一个 `class="dot-strip-dot"` 圆点，圆心 MUST 位于所属类目带内，水平偏移 MUST 由 `dotStripOffset` 决定。

#### Scenario: 八个观测

- **WHEN** 一个系列有 8 个数值
- **THEN** 输出 8 个 `dot-strip-dot`

### Requirement: 豆图抖动

`dotStripOffset` MUST 返回落在 `[-jitter * bandwidth, jitter * bandwidth]` 内的确定性偏移，且不同索引 MUST 产生不同偏移（除退化场景）。

#### Scenario: 抖动范围

- **WHEN** index 为 0 到 7、jitter 为 0.15、bandwidth 为 100
- **THEN** 每个偏移的绝对值不超过 15

### Requirement: 豆图点大小

`dotSize` MUST 大于 0，缺省 7；圆点半径 MUST 为 `dotSize / 2`。

#### Scenario: 非法点大小

- **WHEN** `dotSize` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 豆图校验

`jitter` MUST 非负；`series` MUST 非空且每个 `data` MUST 非空；`data` 元素 MUST 为数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负抖动

- **WHEN** `jitter` 为 −0.1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `DotStripChart` 渲染 `type` 为 `swarm` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
