# Proposal

## Why

概率图把样本分位数与指定理论分布的分位数对比，用一条参考线判断样本是否近似服从正态、均匀或指数分布，是分布假设检验的常用可视化手段。

## What Changes

- 新增 `ProbabilityChart`，`type` 为 `probability`。
- `series[0].data` 为数值数组；`distribution` 取 `normal` / `uniform` / `exponential`，默认 `normal`。
- `showLine` 默认 true，输出最小二乘参考线。
- 散点 class `probability-point`，参考线 class `probability-line`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增概率图需求。

## Impact

- 新增 `src/ProbabilityChart.cj`、`src/ProbabilityChart_test.cj`。
- 复用 `qqTheoryQuantiles` / `qqFitLine` 与 `LinearScale`。
