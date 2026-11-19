## Why

文档把 M106 定义为 M44 日历热力图的同类型条目（`type` 均为 `calendar-heatmap`），用于确认里程碑清单闭合。该条目不需要新实现，只需以回归测试锁定 M44 行为。

## What Changes

- 不新增图类型与实现。
- 新增 `CalendarHeatmapAlias_test.cj`，回归 M44 文档示例：日期范围产生 90 个日格、3 个月份标签、4 个星期标签。
- 记录 M106 与 M44 共用 `CalendarHeatmapChart`。

## Capabilities

### New Capabilities

- `chart-rendering`：记录 M106 与 M44 为同一图表条目。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/CalendarHeatmapAlias_test.cj`。
- 不修改 `CalendarHeatmapChart` 实现。
