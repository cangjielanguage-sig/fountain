# Proposal

## Why

流向地图在区域底图上用带箭头的路径表达人口、物流或资金在节点间的迁移量与方向，是空间流动关系最直观的表达方式。

## What Changes

- 新增 `FlowMapChart`，`type` 为 `flow-map`。
- `viewBox` 为 `[x, y, w, h]`；`regions` 的元素为 `{id, name, path}`。
- `flows` 的元素为 `{source, target, value, points?}`；`points` 为 `[[x, y], ...]` 折线坐标，缺省时用两端区域质心连直线。
- 路径宽度按 `value` 相对最大值缩放（1–5px）。
- 底图 class `flow-map-region`，流向路径 class `flow-map-path`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增流向地图需求。

## Impact

- 新增 `src/FlowMapChart.cj`、`src/FlowMapChart_test.cj`。
- 新增内部 `flowMapWidth` 便于单测宽度缩放。
