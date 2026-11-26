# Proposal

## Why

单系列柱状图只能比较一组数值；实际分析常需要在同一类目下并列比较多个系列（如各季度多个产品）。M2 提供分组柱状图，并顺势把柱状渲染抽成可复用的内部渲染器，为 M3/M4/M7 打底。

## What Changes

- 新增 `GroupedBarChart`，`type` 为 `grouped-bar`。
- 抽出内部 `BarRenderer`，支持 `simple` / `grouped` / `stacked` / `percent-stacked` 四种模式；`BarChart` 行为保持不变。
- 分组模式：每个类目槽位按系列数均分，柱在子槽内居中，同组柱不重叠。
- 复用 M1 的轴、网格、图例、调色板、错误语义。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增分组柱状图布局需求。

## Impact

- 新增 `src/GroupedBarChart.cj`、`src/GroupedBarChart_test.cj`、`src/BarRenderer.cj`。
- `BarChart` 改为薄封装，公开行为与测试不变。
