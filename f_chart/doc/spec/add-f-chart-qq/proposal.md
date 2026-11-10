# Proposal

## Why

QQ 图通过比较样本分位数与理论分位数检验分布假设，是统计诊断的常用工具。

## What Changes

- 新增 `QQChart`，`type` 为 `qq`。
- `series[0].data` 为数值数组；`distribution` 取 `normal` / `uniform` / `exponential`，默认 `normal`。
- 理论分位点 `p_i = (i + 0.5) / n`；散点 class `qq-point`。
- `showLine` 默认 true，用最小二乘参考线 class `qq-line`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增 QQ 图需求。

## Impact

- 新增 `src/QQChart.cj`、`src/QQChart_test.cj`。
- 新增内部 `normalQuantile` / `qqTheoryQuantiles` 便于单测。
