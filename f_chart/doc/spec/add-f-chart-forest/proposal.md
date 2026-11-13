# Proposal

## Why

森林图把多个研究的效应量与置信区间排成同一行序列，并用无效线提供视觉基准，是荟萃分析与多组对比结果汇总的标准图形。

## What Changes

- 新增 `ForestChart`，`type` 为 `forest`。
- `series[0].data` 的元素为 `{label, estimate, lower, upper, weight?}`。
- `nullLine` 默认 1，绘制竖直虚线；x 轴支持 `linear` 与 `log`。
- 置信区间 class `forest-ci`，估计值方块 `forest-point`，无效线 `forest-null`。
- `weight` 提供时按最大权重映射方块边长（6–14px）。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增森林图需求。

## Impact

- 新增 `src/ForestChart.cj`、`src/ForestChart_test.cj`。
- 新增内部 `forestLogPosition` / `forestLogTicks` / `forestMarkerSize` 便于单测。
