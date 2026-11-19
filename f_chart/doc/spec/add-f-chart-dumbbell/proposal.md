# Proposal

## Why

哑铃图用一条连线和两个端点对比同一对象的两次测量值，适合前后得分、两期指标等成对数据，避免双柱造成的视觉拥挤。

## What Changes

- 新增 `DumbbellChart`，`type` 为 `dumbbell`。
- `series[0].data` 元素为 `{name, low, high}`；`yAxis.labels` 为类目，`xAxis` 为线性数值轴。
- 每个数据项绘制一条 `class="dumbbell-line"` 连线与两个端点圆 `dumbbell-low` / `dumbbell-high`。
- 横轴范围优先取 `xAxis.min` / `xAxis.max`，缺省覆盖全部 `low` 与 `high`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增哑铃图需求。

## Impact

- 新增 `src/DumbbellChart.cj`、`src/DumbbellChart_test.cj`。
