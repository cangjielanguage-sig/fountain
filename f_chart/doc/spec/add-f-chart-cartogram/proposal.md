# Proposal

## Why

变形地图按数值缩放各区域轮廓，使面积与指标成比例，能在保留大致地理相对位置的同时突出数值差异，适合人口、销量等总量对比。

## What Changes

- 新增 `CartogramChart`，`type` 为 `cartogram`。
- `viewBox` 为 `[x, y, w, h]`；`regions` 的元素为 `{id, name, value, path, centroid?}`。
- `scaleBy` 取 `value` 或 `sqrt`，默认 `sqrt`；缩放以区域质心为中心。
- `colorRange` 可选，按值分档着色，默认蓝色梯度。
- 区域 path class `cartogram-region`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增变形地图需求。

## Impact

- 新增 `src/CartogramChart.cj`、`src/CartogramChart_test.cj`。
- 新增内部 `cartogramScale` 便于单测缩放比例。
