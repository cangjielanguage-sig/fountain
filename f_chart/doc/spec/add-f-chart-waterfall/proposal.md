# Proposal

## Why

瀑布图把增减项逐项累加，直观展示从期初到期末的变化过程，常用于财务分析。

## What Changes

- 新增 `WaterfallChart`，`type` 为 `waterfall`。
- `series[0].data` 为对象数组：`{name?, value, type?}`，`type` 取 `total` / `increase` / `decrease`。
- `total` 柱从 0 画到 value 并重置累计；`increase` / `decrease` 从当前累计画到 `累计 + value`。
- 相邻柱之间画虚线连接器（class `connector`）。
- 柱 class 为 `waterfall-bar`，并按类型附加 `waterfall-total` / `waterfall-increase` / `waterfall-decrease`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增瀑布图需求。

## Impact

- 新增 `src/WaterfallChart.cj`、`src/WaterfallChart_test.cj`。
- 新增内部纯函数 `waterfallSpan` 用于单测累计逻辑。
