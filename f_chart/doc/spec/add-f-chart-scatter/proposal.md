# Proposal

## Why

散点图展示两个连续变量的关系，是关系类图表的基础。M6 提供数值/时间双轴散点，并复用 M5 的连续轴与范围算法。

## What Changes

- 新增 `ScatterChart`，`type` 为 `scatter`。
- `series[].data` 为 `{x,y}` 对象数组；x 轴支持 `linear` / `time`。
- 支持 `symbol` 与 `symbolSize`，多系列颜色与图例。
- 复用 `lineRange`、`ChartFrame.drawXAxisNumeric`、`ChartSvgKit` 点形状。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增散点图需求。

## Impact

- 新增 `src/ScatterChart.cj`、`src/ScatterChart_test.cj`。
