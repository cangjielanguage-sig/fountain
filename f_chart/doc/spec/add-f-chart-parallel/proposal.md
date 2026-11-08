# Proposal

## Why

平行坐标图把多维样本映射到多条竖直轴上，便于观察样本在多指标间的走势与分组差异。

## What Changes

- 新增 `ParallelCoordinatesChart`，`type` 为 `parallel-coordinates`。
- `dimensions: [{name, min?, max?}]` 定义维度与取值范围；缺省范围从数据推导。
- `series[].data` 为样本行数组，每行长度必须等于维度数。
- 每个样本绘制一条折线 class `parallel-line`，每条维度轴 class `dimension-axis`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增平行坐标图需求。

## Impact

- 新增 `src/ParallelCoordinatesChart.cj`、`src/ParallelCoordinatesChart_test.cj`。
- 新增内部 `parallelNormalize` 便于单测归一化。
