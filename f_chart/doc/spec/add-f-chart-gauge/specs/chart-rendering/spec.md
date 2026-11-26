## ADDED Requirements

### Requirement: 仪表盘渲染

渲染器 MUST 支持 `type` 为 `gauge` 的图表，在起止角度之间绘制阈值色带、指针与中心数值。

#### Scenario: 文档示例

- **WHEN** 输入 `min` 为 0、`max` 为 100、3 个阈值、数值为 72 的 `gauge`
- **THEN** 输出 3 个 `gauge-band`、1 条 `gauge-needle` 与 1 个 `gauge-value`
- **AND** `gauge-value` 文本为 `72`

#### Scenario: 默认量程

- **WHEN** 未提供 `min` 与 `max`
- **THEN** 量程 MUST 为 `[0, 100]`

#### Scenario: 默认角度

- **WHEN** 未提供 `startAngle` 与 `endAngle`
- **THEN** 起始角 MUST 为 `-120` 度、结束角 MUST 为 `120` 度

#### Scenario: 无阈值

- **WHEN** `thresholds` 为空或缺失
- **THEN** 输出 1 个覆盖整个量程的 `gauge-band`

#### Scenario: 多个阈值

- **WHEN** 阈值依次为 60、85、100
- **THEN** 色带 MUST 依次覆盖 `[0,60]`、`[60,85]`、`[85,100]`

#### Scenario: 数值越界

- **WHEN** 数值小于 `min` 或大于 `max`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法量程

- **WHEN** `max` 小于等于 `min`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法角度

- **WHEN** `startAngle` 大于等于 `endAngle`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 阈值非递增

- **WHEN** 阈值序列不是严格递增，或超出量程
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** `type` 不是 `gauge`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: 仪表盘角度映射

数值到角度的映射 MUST 为线性映射，并支持内部函数直接验证。

#### Scenario: 量程端点

- **WHEN** `min` 为 0、`max` 为 100、角度为 `-120` 到 `120`
- **THEN** 数值 `0` 映射为 `-120` 度
- **AND** 数值 `100` 映射为 `120` 度
- **AND** 数值 `50` 映射为 `0` 度
