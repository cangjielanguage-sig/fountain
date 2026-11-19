## ADDED Requirements

### Requirement: 日历热力图里程碑闭合

M106 MUST 复用 `CalendarHeatmapChart`，与 M44 使用相同的 `calendar-heatmap` 类型与渲染规则。

#### Scenario: 文档示例

- **WHEN** 输入 2026-01-01 到 2026-03-31、6 条数据的 `calendar-heatmap`
- **THEN** 输出 90 个 `calendar-cell`
- **AND** 输出 3 个 `month-label`
- **AND** 输出 4 个 `weekday-label`

#### Scenario: 颜色分档

- **WHEN** `colorRange` 提供 4 个颜色
- **THEN** 最高值日期的单元格 MUST 使用第 4 个颜色

#### Scenario: 类型不匹配

- **WHEN** `type` 不是 `calendar-heatmap`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
