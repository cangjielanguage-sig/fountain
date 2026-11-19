# Proposal

## Why

堆叠柱状图在同一根柱上展示总量与构成，是分组柱之外最常用的比较图。M3 在既有 `BarRenderer` 上增加 `Stacked` 模式，复用轴、图例与校验。

## What Changes

- 新增 `StackedBarChart`，`type` 为 `stacked-bar`。
- `BarRenderer` 增加 `Stacked` 模式：同类别柱共享 x，正值向上堆叠、负值向下堆叠。
- y 轴范围按每个类目的正/负总和计算，而不是单个系列的最大值。
- 复用 M1/M2 的主题、图例、错误语义。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增堆叠柱状图布局与范围需求。

## Impact

- 新增 `src/StackedBarChart.cj`、`src/StackedBarChart_test.cj`。
- `BarRenderer` 增加一个模式分支，不改动 Simple/Grouped 行为。
