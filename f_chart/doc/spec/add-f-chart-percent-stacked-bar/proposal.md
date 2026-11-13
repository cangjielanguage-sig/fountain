# Proposal

## Why

比较各组构成比例时，绝对值堆叠会受总量影响；百分比堆叠把每个类目归一化到 100%，直接比较构成。M4 复用 `BarRenderer` 的堆叠布局，只改变数值归一化与 y 轴范围。

## What Changes

- 新增 `PercentStackedBarChart`，`type` 为 `percent-stacked-bar`。
- `BarRenderer` 增加 `PercentStacked` 模式：每个类目按 `abs(value)` 占比归一化到 100%，段从 0 向上堆叠。
- 默认 y 轴固定 0–100；显式 `yAxis.min/max` 可覆盖。
- 复用主题、图例、校验与错误语义。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增百分比堆叠柱状图需求。

## Impact

- 新增 `src/PercentStackedBarChart.cj`、`src/PercentStackedBarChart_test.cj`。
- `BarRenderer` 增加一个模式分支。
