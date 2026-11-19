# Proposal

## Why

蜡烛图用影线与实体表达开盘、最高、最低、收盘四个价格，是金融市场观察价格波动与涨跌趋势的标准图形。

## What Changes

- 新增 `CandlestickChart`，`type` 为 `candlestick`。
- `series[0].data` 元素为 `{date, open, high, low, close}`。
- 每根蜡烛输出 `class="candlestick-wick"` 影线与 `class="candlestick-body"` 实体；收盘不低于开盘时附加 `candlestick-up`，否则附加 `candlestick-down`。
- 新增内部 `candlestickUp(open, close)` 与 `candlestickRange(items)` 便于单测。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增蜡烛图需求。

## Impact

- 新增 `src/CandlestickChart.cj`、`src/CandlestickChart_test.cj`。
