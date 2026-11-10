# Proposal

## Why

冰柱图把火焰图倒置，根节点位于顶部、调用层级向下展开，更符合文件目录与组织结构的阅读习惯，也便于从上到下追踪子调用占比。

## What Changes

- 新增 `IcicleChart`，`type` 为 `icicle`。
- `nodes` 的元素为 `{id, name, parent, value}`；`parent` 为 `null` 表示根。
- `orientation` 默认 `top-down`，也支持 `bottom-up`。
- `colorBy` 取 `name`（默认）或 `value`；`frameHeight` 默认 18。
- 节点矩形 class `icicle-node`，标签 class `icicle-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增冰柱图需求。

## Impact

- 新增 `src/IcicleChart.cj`、`src/IcicleChart_test.cj`。
- 复用 `flameColorIndex` 与 `heatColor`。
