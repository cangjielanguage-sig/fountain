# Proposal

## Why

堆叠面积图在趋势之上表达构成变化。M15 在面积图基础上按 `stack` 分组累加各系列，形成层叠区域。

## What Changes

- 新增 `StackedAreaChart`，`type` 为 `stacked-area`。
- `series[].stack` 相同的系列累加；不同 stack 分组独立层叠。
- 每个系列的面积为「本系列累计区间」到「前序累计区间」。
- `null` 按 0 参与堆叠。
- y 轴范围覆盖所有累计层的最大/最小值，并包含 0。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增堆叠面积图需求。

## Impact

- 新增 `src/StackedAreaChart.cj`、`src/StackedAreaChart_test.cj`。
- 新增内部纯函数 `stackedAreaBounds` 便于单测累计与分组。
