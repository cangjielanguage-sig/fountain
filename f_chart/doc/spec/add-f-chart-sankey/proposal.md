# Proposal

## Why

桑基图用流量带展示节点之间的流向与规模，是流量、转化与流向分析的标准图。

## What Changes

- 新增 `SankeyChart`，`type` 为 `sankey`。
- `nodes: [{id,name}]` 与 `links: [{source,target,value}]`；端点必须存在。
- 按最长路径分层，节点高度与吞吐量成正比。
- 节点 class `sankey-node`，流量带 class `sankey-link`，标签 class `sankey-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增桑基图需求。

## Impact

- 新增 `src/SankeyChart.cj`、`src/SankeyChart_test.cj`。
- 新增内部 `sankeyLayers` 便于单测分层。
