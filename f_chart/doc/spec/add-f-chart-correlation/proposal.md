# Proposal

## Why

相关矩阵图用颜色矩阵展示多变量相关系数，是关系类图表的核心。

## What Changes

- 新增 `CorrelationMatrixChart`，`type` 为 `correlation-matrix`。
- `series[0].data` 为 n×n 方阵；`method` 取 `pearson` / `spearman`；`showValues` 默认 true。
- `colorRange` 为 `[低, 中, 高]` 三色，默认红-白-蓝。
- 矩阵单元 class `correlation-cell`，数值文本 class `cell-value`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增相关矩阵图需求。

## Impact

- 新增 `src/CorrelationMatrixChart.cj`、`src/CorrelationMatrixChart_test.cj`。
- 新增内部 `correlationColor` 便于单测配色。
