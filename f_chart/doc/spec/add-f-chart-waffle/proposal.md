# Proposal

## Why

华夫图把总量拆成固定数量的方格，用着色方格数量表达占比，比饼图更易于逐格比较，适合预算、席位、覆盖率等构成展示。

## What Changes

- 新增 `WaffleChart`，`type` 为 `waffle`。
- 数据来自 `series[0].data`，元素为 `{name, value}`。
- 专属字段 `cells`（总格数，默认 100）、`columns`（每行列数，默认 10）。
- 方格 class `waffle-cell`，图例文本 class `waffle-legend`。
- 新增内部 `waffleCellCounts`，用最大余数法把占比取整为整数格并保证格子总数为 `cells`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增华夫图需求。

## Impact

- 新增 `src/WaffleChart.cj`、`src/WaffleChart_test.cj`。
