# Proposal

## Why

分级统计地图用颜色深浅表达各区域指标高低，配合已投影的 SVG 路径可直接嵌入报表，是区域对比与资源分布展示的常用图。

## What Changes

- 新增 `ChoroplethChart`，`type` 为 `choropleth`。
- `viewBox` 为 `[x, y, w, h]`，缺省取画布尺寸；`regions` 的元素为 `{id, name, value, path}`。
- `colorRange` 至少两个颜色，按区域值归一化后取色。
- `showLabels` 默认 false，为 true 时在区域路径质心输出名称。
- 区域 path class `choropleth-region`，标签 class `choropleth-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增分级统计地图需求。

## Impact

- 新增 `src/ChoroplethChart.cj`、`src/ChoroplethChart_test.cj`。
- 新增内部 `pathCentroid` 便于单测路径质心。
