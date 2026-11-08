# Proposal

## Why

箱线图概括分布时会隐藏原始样本，箱线加散点组合把每个观测值叠加在箱体旁，既保留分位数概览又能看出样本量、离群与堆积情况。

## What Changes

- 新增 `BoxScatterChart`，`type` 为 `box-scatter`。
- `series[0].data` 支持「每组一个数值数组」的嵌套数组；单组时可写扁平数值数组。
- `showBox` 默认 true，绘制须线、端帽、箱体与中位线；原始点始终绘制。
- `jitter` 控制点的水平抖动比例，默认 0.15，取值 0–1。
- 箱体 class `box-scatter-box`，中位线 `box-scatter-median`，须线 `box-scatter-whisker`，端帽 `box-scatter-cap`，原始点 `box-scatter-point`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增箱线 + 散点组合图需求。

## Impact

- 新增 `src/BoxScatterChart.cj`、`src/BoxScatterChart_test.cj`。
- 复用 `quantileSorted` / `swarmOffsets`；新增内部 `boxScatterBounds` 便于单测。
