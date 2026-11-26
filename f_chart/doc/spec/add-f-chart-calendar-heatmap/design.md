# Design

## 1. 日期与范围

- 用 `ChartTime.parseDays` 把 `YYYY-MM-DD` 转成天数。
- 未给 `startDate` 时取数据最小日期，未给 `endDate` 时取数据最大日期；若数据为空则抛错。
- 同一天多个条目求和；显式范围外的日期抛 `InvalidValue`。

## 2. 网格

- `calendarWeekday(days, weekStart)`：1970-01-01 为星期四；周一为 0 时星期四为 3，周日为 0 时星期四为 4。
- 列号 `week = (dayIndex + startWeekday) / 7`，行号 `row = (dayIndex + startWeekday) % 7`。
- 单元格尺寸取 `cellSize`，并按绘图区宽高上限收缩；格间留 1px。

## 3. 颜色

`calendarColor(ratio, colors)` 用 `floor(ratio * 颜色数)` 分档，比例 1 夹到最后一档。

## 4. 标签

- 月份变化时在对应列顶部输出 `class="month-label"`，内容为 `N月`。
- 左侧按星期输出 `一/三/五/日`（周一开头）或 `日/二/四/六`（周日开头）。
