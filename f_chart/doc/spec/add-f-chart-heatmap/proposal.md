# Proposal

## Why

热力图用颜色深浅表达二维矩阵的数值高低，能在有限画布内同时比较行列两个维度的模式，是相关性、时段活跃度与混淆矩阵等场景的常用图。

## What Changes

- 新增 `HeatmapChart`，`type` 为 `heatmap`。
- `series[0].data` 为二维数值矩阵；行对应 `yAxis.labels`，列对应 `xAxis.labels`。
- `colorRange` 为 `[低, 中, 高]` 三色，默认蓝色梯度；数值按矩阵最小/最大值归一化后线性插值。
- `showValues` 默认 false，为 true 时在单元格内显示数值；`cellGap` 默认 1。
- 单元格 class `heatmap-cell`，数值文本 class `heatmap-value`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增热力图需求。

## Impact

- 新增 `src/HeatmapChart.cj`、`src/HeatmapChart_test.cj`。
- 新增内部 `heatmapColor` 三色插值函数便于单测。
