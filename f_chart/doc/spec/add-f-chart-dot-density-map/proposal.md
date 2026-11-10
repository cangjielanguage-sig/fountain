# Proposal

## Why

点密度地图在区域底图上叠加代表个体的点，用点的数量与大小表达门店、事件或人口的分布密度，比按行政区聚合的颜色更能保留空间细节。

## What Changes

- 新增 `DotDensityMapChart`，`type` 为 `dot-density-map`。
- `viewBox` 为 `[x, y, w, h]`；`regions` 为底图路径；`points` 的元素为 `{x, y, weight?}`。
- `radius` 为基准点半径，默认 3；权重按平方根缩放半径。
- 底图 class `dot-density-region`，点 class `dot-density-point`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增点密度地图需求。

## Impact

- 新增 `src/DotDensityMapChart.cj`、`src/DotDensityMapChart_test.cj`。
- 新增内部 `dotDensityRadius` 便于单测半径缩放。
