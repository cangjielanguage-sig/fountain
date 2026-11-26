# Proposal

## Why

折线图是趋势分析的基础图。M5 需要同时支持类目数据与连续 XY 数据，并为后续面积图、组合图提供折线/点的绘制能力。

## What Changes

- 新增 `LineChart`，`type` 为 `line`。
- 支持 `series[].data` 为数值数组（类目轴）或 `{x,y}` 对象数组（数值/时间轴）。
- 支持 `smooth`（二次贝塞尔）与 `symbol`（circle/square/diamond/none）样式。
- `null` 断开折线，不生成该点的符号。
- 新增 `ChartTime`（`YYYY-MM-DD` 解析/格式化）、`ChartSvgKit.circle`、`ChartFrame.drawXAxisNumeric`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增折线图与连续轴需求。

## Impact

- 新增 `src/LineChart.cj`、`src/LineChart_test.cj`、`src/ChartTime.cj`。
- 扩展 `ChartSvgKit`、`ChartFrame`；不影响柱状图。
