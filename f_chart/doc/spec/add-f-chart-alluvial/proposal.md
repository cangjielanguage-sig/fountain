# Proposal

## Why

冲积图把同一实体在多个阶段的分布画成节点列与流量带，能直观展示用户状态、预算或库存随时间在类别之间的迁移。

## What Changes

- 新增 `AlluvialChart`，`type` 为 `alluvial`。
- `stages` 为阶段名数组；`nodes` 的元素为 `{id, name?, stage}`；`links` 的元素为 `{source, target, value}`。
- `nodeWidth` 默认 14，`nodeGap` 默认 10。
- 节点 class `alluvial-node`，流量带 class `alluvial-link`，标签 class `alluvial-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增冲积图需求。

## Impact

- 新增 `src/AlluvialChart.cj`、`src/AlluvialChart_test.cj`。
- 新增内部 `alluvialHeights` 便于单测列内高度分配。
