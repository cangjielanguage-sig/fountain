# Proposal

## Why

散点矩阵把多个变量的两两关系排成矩阵，是探索多变量数据的常用概览图。

## What Changes

- 新增 `ScatterMatrixChart`，`type` 为 `scatter-matrix`。
- `variables` 定义变量名；`series[].data` 为样本行，每行长度等于变量数。
- 非对角单元绘制两变量散点（class `matrix-point`），对角单元显示变量名（class `diag-label`）。
- 每个单元独立使用两变量的数据范围归一化。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增散点矩阵图需求。

## Impact

- 新增 `src/ScatterMatrixChart.cj`、`src/ScatterMatrixChart_test.cj`。
- 新增内部 `columnRange` 便于单测列范围。
