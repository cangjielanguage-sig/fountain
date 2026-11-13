# Proposal

## Why

斜率图用两条竖直基准线之间的斜线对比两个时间点的取值，适合排名变化、前后差异等成对时序对比。

## What Changes

- 新增 `SlopeChart`，`type` 为 `slope`。
- `xAxis.labels` MUST 恰好 2 个；每个 `series[i].data` MUST 恰好 2 个数值。
- 每系列绘制一条 `class="slope-line"` 连线、左右两个 `class="slope-point"` 圆点与右侧 `class="slope-label"` 名称。
- 纵轴范围为全部数值的最小/最大值，支持 `yAxis.min` / `yAxis.max` 覆盖。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增斜率图需求。

## Impact

- 新增 `src/SlopeChart.cj`、`src/SlopeChart_test.cj`。
