# Proposal

## Why

二维直方图展示两个连续变量的联合密度，是散点图之外观察聚集与空洞的有效方式。

## What Changes

- 新增 `Histogram2DChart`，`type` 为 `2d-histogram`。
- `series[0].data` 为 `{x,y}` 对象数组；`bins` 为 `[x分箱, y分箱]`，默认 `[20,20]`。
- `shape` 取 `hexagon` / `square`，默认 `hexagon`。
- 按 count 映射颜色深浅，零频单元不绘制。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增二维直方图需求。

## Impact

- 新增 `src/Histogram2DChart.cj`、`src/Histogram2DChart_test.cj`。
- 新增内部 `histogram2DCounts` / `heatColor` 便于单测。
