# Proposal

## Why

矩形树图用嵌套矩形面积展示层级构成与占比，是层级数据的标准可视化。

## What Changes

- 新增 `TreemapChart`，`type` 为 `treemap`。
- `nodes` 为 `{id,name,parent,value?}`；叶子节点必须有 `value`，内部节点值由子节点求和。
- 使用 `squarify` 布局（按面积分配矩形）。
- 叶子矩形 class `treemap-cell`，名称文本 class `treemap-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增矩形树图需求。

## Impact

- 新增 `src/TreemapChart.cj`、`src/TreemapChart_test.cj`。
- 新增内部 `treemapWeights` 便于单测面积权重。
