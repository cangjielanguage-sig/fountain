# Proposal

## Why

火焰图把调用栈按耗时宽度铺开、按深度堆叠，能一眼看出 CPU 时间主要消耗在哪些函数路径上，是性能剖析的标准可视化。

## What Changes

- 新增 `FlameChart`，`type` 为 `flame`。
- `nodes` 的元素为 `{id, name, parent, value}`；`parent` 为 `null` 表示根。
- `orientation` 默认 `bottom-up`，支持 `top-down`。
- `colorBy` 取 `name`（默认）或 `value`；`frameHeight` 默认 18。
- 节点矩形 class `flame-node`，标签 class `flame-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增火焰图需求。

## Impact

- 新增 `src/FlameChart.cj`、`src/FlameChart_test.cj`。
- 新增内部 `flameColorIndex` 便于单测名称配色。
