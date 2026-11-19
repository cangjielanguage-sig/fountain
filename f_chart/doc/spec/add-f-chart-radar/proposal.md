# Proposal

## Why

雷达图用于比较多个指标的综合表现。M13 提供指标轴、网格环与多系列多边形。

## What Changes

- 新增 `RadarChart`，`type` 为 `radar`。
- 顶层 `indicators: [{name, max}]`；`series[].data` 与指标等长。
- 绘制 4 层网格、指标轴与标签、多系列多边形与顶点。
- 数值按 `value / max` 归一化，越界钳制到 `[0, 1]`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增雷达图需求。

## Impact

- 新增 `src/RadarChart.cj`、`src/RadarChart_test.cj`。
