# Proposal

## Why

核密度图用平滑曲线展示分布形状，比直方图更适合比较多个分布。

## What Changes

- 新增 `DensityChart`，`type` 为 `density`。
- `series[].data` 为数值数组；`bandwidth` 可选，默认 Silverman 规则。
- 支持多系列叠加；`fill` 为 true 时填充曲线下方。
- 复用连续数值轴与 `drawXAxisNumeric`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增核密度图需求。

## Impact

- 新增 `src/DensityChart.cj`、`src/DensityChart_test.cj`。
- 新增内部 `gaussianKde` 便于单测密度值。
