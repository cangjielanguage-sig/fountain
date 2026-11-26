# Proposal

## Why

克利夫兰点图用点与细线代替条形，类别多时更轻量，也便于精确对齐数值。M12 复用条形图的横向类目布局。

## What Changes

- 新增 `DotChart`，`type` 为 `dot`。
- `yAxis.labels` 为类别，`xAxis` 为数值轴。
- 每个值画一条从 0 基线到点的细线（`stem`）和一个圆点（`dot`）。
- 支持负值、`null`、多系列颜色与图例。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增点图需求。

## Impact

- 新增 `src/DotChart.cj`、`src/DotChart_test.cj`。
