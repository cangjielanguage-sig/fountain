# Proposal

## Why

热力地图在区域底图上用带透明度的彩色圆点叠加事件密度，能在保留地理轮廓的同时直观呈现访问、事故或订单在空间上的聚集程度。

## What Changes

- 新增 `HeatMapChart`，`type` 为 `heat-map`。
- `viewBox` 为 `[x, y, w, h]`；`regions` 为底图路径；`points` 的元素为 `{x, y, value}`。
- `radius` 为影响半径，默认 24；`colorRange` 按值归一化后取色。
- 底图 class `heat-map-region`，热力点 class `heat-map-point`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增热力地图需求。

## Impact

- 新增 `src/HeatMapChart.cj`、`src/HeatMapChart_test.cj`。
- 复用 `heatFlameColor` 与 `SvgViewBox`。
