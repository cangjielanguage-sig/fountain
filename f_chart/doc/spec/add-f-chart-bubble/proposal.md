# Proposal

## Why

气泡图在散点基础上用面积/半径编码第三维数值，是关系类图表的多变量扩展。

## What Changes

- 新增 `BubbleChart`，`type` 为 `bubble`。
- `series[].data` 为 `{x,y,size,label?}` 对象数组；`sizeRange` 控制半径范围（默认 `[4,30]`）。
- 多系列颜色、图例与可选标签。
- 复用连续双轴与 `drawXAxisNumeric`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增气泡图需求。

## Impact

- 新增 `src/BubbleChart.cj`、`src/BubbleChart_test.cj`。
- 新增内部 `bubbleRadius` 便于单测半径映射。
