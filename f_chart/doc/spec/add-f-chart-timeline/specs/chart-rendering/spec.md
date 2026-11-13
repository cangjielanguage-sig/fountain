# Spec Delta

## ADDED Requirements

### Requirement: 时间线事件

`TimelineChart` MUST 为每个事件输出一个 `class="timeline-dot"` 圆点，并 MUST 输出一条 `class="timeline-axis"` 轴线。

#### Scenario: 四个事件

- **WHEN** `events` 有 4 项
- **THEN** 输出 4 个 `timeline-dot` 与 1 条 `timeline-axis`

### Requirement: 时间线文本

每个事件 MUST 输出 `class="timeline-date"` 日期文本与 `class="timeline-title"` 标题文本；提供 `description` 时 MUST 输出 `class="timeline-desc"` 描述文本。

#### Scenario: 四个事件

- **WHEN** `events` 有 4 项且都带 `description`
- **THEN** 输出 4 个 `timeline-date`、4 个 `timeline-title`、4 个 `timeline-desc`

### Requirement: 时间线方向

`orientation` MUST 为 `horizontal`（默认）或 `vertical`；水平布局 MUST 事件按序等距分布在水平轴上、相邻事件交替位于轴上下；垂直布局 MUST 事件按序等距分布在竖直轴上。

#### Scenario: 水平方向

- **WHEN** `orientation` 为 `horizontal`
- **THEN** 输出水平轴线与交替分布的文本

#### Scenario: 非法方向

- **WHEN** `orientation` 为 `diagonal`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 时间线校验

`events` MUST 非空；每个事件 MUST 提供字符串型 `date` 与 `title`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 缺少标题

- **WHEN** 某事件没有 `title`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 类型不匹配

- **WHEN** 用 `TimelineChart` 渲染 `type` 为 `gantt` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
