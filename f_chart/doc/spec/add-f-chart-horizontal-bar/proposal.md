# Proposal

## Why

类别名较长或类别较多时，竖向柱状图标签拥挤；条形图把类别放到纵轴，更易读。M11 提供横向柱与共享的横向类目布局。

## What Changes

- 新增 `HorizontalBarChart`，`type` 为 `horizontal-bar`。
- `yAxis.labels` 为类别，`xAxis` 为数值轴；柱从 0 基线水平延伸。
- 支持负值、`null`、调色板、图例与数值刻度。
- 复用 `ChartFrame.drawXAxisNumeric`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增条形图需求。

## Impact

- 新增 `src/HorizontalBarChart.cj`、`src/HorizontalBarChart_test.cj`。
