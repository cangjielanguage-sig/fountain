# Proposal

## Why

日历热力图把每天的值排成周 × 星期的网格，用颜色深浅呈现长期活跃度与周期性模式，适合提交记录、签到和日指标监控等按天汇总的数据。

## What Changes

- 新增 `CalendarHeatmapChart`，`type` 为 `calendar-heatmap`。
- `series[0].data` 的元素为 `{date, value}`；同一日期多次出现时值相加。
- `startDate` / `endDate` 控制范围，缺省取数据的最小/最大日期；`cellSize` 默认 14；`weekStart` 取 `mon` / `sun`，默认 `mon`。
- `colorRange` 至少两个颜色，按最大值归一化后分档取色。
- 单元格 class `calendar-cell`，月份标签 class `month-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增日历热力图需求。

## Impact

- 新增 `src/CalendarHeatmapChart.cj`、`src/CalendarHeatmapChart_test.cj`。
- `ChartTime` 追加 `partsOfDays`；新增内部 `calendarWeekday` / `calendarColor` 便于单测。
- M106 与本图同实现，后续直接复用。
