# Design

## 1. 解析

`tasks` 必填且非空。每个任务解析 id/name/start/end/progress/dependsOn/lane/color；日期用 `ChartTime.parseDays`。

## 2. 布局

- x：`LinearScale(minDay, maxDay, plot.right, plot.x)`；范围取所有任务起止并前后留 2 天。
- y：任务按数组顺序一行一个；`rowHeight = plot.height / tasks.size`。
- 左侧任务名占 `yLabelWidth`。
- 条高 `min(18, rowHeight * 0.6)`；进度条宽度为条宽 × progress。

## 3. 依赖

从依赖任务条的右端到当前任务条的左端画三段折线（水平-垂直-水平），末端画三角箭头；class `dependency`。

## 4. 轴

时间刻度用 `chartNiceTicks` + `ChartTime.formatDays`，复用 `ChartFrame.drawXAxisNumeric`；竖向网格线 class `grid`。
