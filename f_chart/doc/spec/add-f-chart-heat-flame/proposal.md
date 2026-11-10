# Proposal

## Why

热火焰图在火焰图调用栈上用颜色编码自身耗时或自定义热度字段，让热点函数在保持层级结构的同时直接以颜色突显，比单看宽度更快定位优化目标。

## What Changes

- 新增 `HeatFlameChart`，`type` 为 `heat-flame`。
- `nodes` 的元素为 `{id, name, parent, value, <heatField>}`。
- `heatField` 指定热度字段名，默认 `self`；字段缺省按 0 处理。
- `colorRange` 为 `[冷, 热]` 或 `[冷, 中, 热]`，按热度占最大值的比例插值。
- 节点矩形 class `heat-flame-node`，标签 class `heat-flame-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增热火焰图需求。

## Impact

- 新增 `src/HeatFlameChart.cj`、`src/HeatFlameChart_test.cj`。
- 新增内部 `heatFlameColor` 便于单测两端色与中点色。
