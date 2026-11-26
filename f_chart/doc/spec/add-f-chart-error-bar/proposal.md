# Proposal

## Why

误差线图在均值或估计值上叠加置信区间、标准差等不确定范围，是实验对比与统计推断结果最常用的表达方式之一。

## What Changes

- 新增 `ErrorBarChart`，`type` 为 `error-bar`。
- `series[0].data` 的元素为 `{x, y, low, high}`：`y` 为中心值，`low` / `high` 为误差下界与上界。
- 默认类目轴：`x` 为类目名，顺序由 `xAxis.labels` 或数据出现顺序决定；`xAxis.type` 为 `linear` / `time` 时按数值轴或时间轴定位。
- 竖线 class `error-bar-line`，端帽 class `error-bar-cap`，中心点 class `error-bar-point`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增误差线图需求。

## Impact

- 新增 `src/ErrorBarChart.cj`、`src/ErrorBarChart_test.cj`。
- 复用 `BandScale`、`LinearScale`、`ChartFrame` 与 `ChartTime`。
