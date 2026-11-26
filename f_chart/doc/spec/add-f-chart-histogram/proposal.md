# Proposal

## Why

直方图用分箱展示连续数据的频数分布，是分布类图表的基础。M17 提供自动分箱与频数柱。

## What Changes

- 新增 `HistogramChart`，`type` 为 `histogram`。
- `series[0].data` 为数值数组；`series[0].bins` 指定分箱数（默认按样本量的平方根取整）。
- 分箱范围取数据最小/最大值，最大值归入最后一箱；零频箱不绘制。
- y 轴为频数，x 轴为连续数值轴。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增直方图需求。

## Impact

- 新增 `src/HistogramChart.cj`、`src/HistogramChart_test.cj`。
- 新增内部 `computeHistogram` 便于单测分箱。
