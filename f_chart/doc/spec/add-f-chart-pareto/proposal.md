# Proposal

## Why

帕累托图用降序柱加累计折线找出主要问题，是质量控制与优先级分析的常用图。

## What Changes

- 新增 `ParetoChart`，`type` 为 `pareto`。
- `xAxis.labels` 为类别；`series[0].data` 为计数，自动降序排列。
- 柱 class `pareto-bar`，累计折线 class `pareto-line`，折线点 class `pareto-point`。
- `showCumulative` 默认 true。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增帕累托图需求。

## Impact

- 新增 `src/ParetoChart.cj`、`src/ParetoChart_test.cj`。
- 新增内部 `paretoOrder` / `paretoCumulative` 便于单测。
