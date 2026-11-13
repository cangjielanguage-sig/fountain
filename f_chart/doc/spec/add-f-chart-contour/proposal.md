# Proposal

## Why

等高线图用颜色与等值边界展示二维响应面，是空间与关系分析的重要图。

## What Changes

- 新增 `ContourChart`，`type` 为 `contour`。
- `series[0].data` 为 `{x,y,value}` 网格点，要求覆盖完整矩形网格。
- `levels` 控制等值层级数（默认 8）；`interpolate` 取 `linear` / `nearest`。
- 每个网格单元按值分层着色（class `contour-cell`），相邻层边界画 `contour-line`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增等高线图需求。

## Impact

- 新增 `src/ContourChart.cj`、`src/ContourChart_test.cj`。
- 新增内部 `contourLevel` 便于单测分层。
