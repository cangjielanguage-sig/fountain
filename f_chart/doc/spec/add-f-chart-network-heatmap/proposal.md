# Proposal

## Why

网络热力图用方阵展示节点间关系强度，行列标签来自同一组节点，能快速比较有向流量的对称性与热点，是调用链、社交互动与共现分析的常用图。

## What Changes

- 新增 `NetworkHeatmapChart`，`type` 为 `network-heatmap`。
- `nodes` 的元素为 `{id, name}`，行列标签按节点顺序生成。
- `series[0].data` 为 N×N 数值矩阵；`colorRange`、`showValues`、`cellGap` 与热力图一致。
- 单元格 class `network-heatmap-cell`，数值文本 class `network-heatmap-value`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增网络热力图需求。

## Impact

- 新增 `src/NetworkHeatmapChart.cj`、`src/NetworkHeatmapChart_test.cj`。
- 复用 `heatmapColor` 与热力图的单元格布局。
