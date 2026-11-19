# Proposal

## Why

子弹图在一行内同时表达实际值、目标值与绩效区间，用背景色带替代仪表盘刻度，适合 KPI 完成率、服务水平等目标对比场景。

## What Changes

- 新增 `BulletChart`，`type` 为 `bullet`。
- `yAxis.labels` 为类目，`xAxis` 为线性数值轴；`series[0].data` 元素为 `{name, value, target, ranges}`。
- `ranges` 为从低到高的区间上界数组，背景色带按区间分段绘制。
- 值条 class `bullet-value`，区间条 class `bullet-range`，目标线 class `bullet-target`，类目标签沿用轴文本。
- 新增内部 `bulletRangeColor` 与 `bulletRange`（校验并返回排序后的区间上界）。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增子弹图需求。

## Impact

- 新增 `src/BulletChart.cj`、`src/BulletChart_test.cj`。
