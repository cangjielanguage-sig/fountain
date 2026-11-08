# Spec Delta

## ADDED Requirements

### Requirement: 日历单元格

`CalendarHeatmapChart` MUST 为 `[startDate, endDate]` 内的每一天绘制一个 `class="calendar-cell"` 矩形，包括没有数据的日期。

#### Scenario: 整月

- **WHEN** `startDate` 为 2026-01-01、`endDate` 为 2026-01-31
- **THEN** 输出 31 个 `class="calendar-cell"`

#### Scenario: 缺省范围

- **WHEN** 未提供 `startDate` / `endDate`
- **THEN** 范围取数据中的最小与最大日期

### Requirement: 星期起始

`weekStart` MUST 为 `mon` 或 `sun`，默认 `mon`；`calendarWeekday` 返回对应起始下的星期下标（0–6）。

#### Scenario: 星期四

- **WHEN** 日期为 2026-01-01（星期四）
- **THEN** `weekStart` 为 `mon` 时返回 3，为 `sun` 时返回 4

### Requirement: 日历颜色分档

颜色 MUST 按值相对最大值的比例从 `colorRange` 中分档选取；比例为 0 MUST 取第一个颜色，比例为 1 MUST 取最后一个颜色。

#### Scenario: 最小与最大

- **WHEN** 比例分别为 0 与 1
- **THEN** 分别返回 `colorRange` 的首色与末色

### Requirement: 日历热力图校验

`date` MUST 为 `YYYY-MM-DD`；`value` MUST 为非负数字；`startDate` MUST 不大于 `endDate`；显式范围外的数据 MUST 抛错；`colorRange` MUST 至少两个合法颜色；`cellSize` MUST 大于 0；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 范围倒置

- **WHEN** `startDate` 晚于 `endDate`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 日期越界

- **WHEN** 显式范围外的 `date` 出现在数据中
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 负值

- **WHEN** 某天 `value` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
