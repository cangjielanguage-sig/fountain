# Proposal

## Why

环形图是饼图的空心变体，中心区域可放汇总文本，视觉上更适合仪表盘。

## What Changes

- 新增 `DonutChart`，`type` 为 `donut`。
- 数据形状与饼图一致；`innerRadius` 控制内半径比例（0–1，默认 0.55）。
- `centerText` 在圆心显示汇总文本。
- 扇区 class `donut-slice`，内孔 class `donut-hole`，中心文本 class `center-text`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增环形图需求。

## Impact

- 新增 `src/DonutChart.cj`、`src/DonutChart_test.cj`。
- 复用 `pieFractions` / `formatPercent`。
