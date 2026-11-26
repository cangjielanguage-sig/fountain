# Proposal

## Why

南丁格尔玫瑰图用等角度扇区的半径长度表达数值大小，适合比较品类销量、人口构成等份额差异明显的类目。

## What Changes

- 新增 `RoseChart`，`type` 为 `rose`。
- 数据来自 `series[0].data`，元素为 `{name, value}`。
- 专属字段 `roseType` 取 `radius`（默认，半径与数值线性）或 `area`（半径与数值平方根）。
- 扇区 class `rose-slice`，标签 class `rose-label`。
- 新增内部 `roseRadius` 便于单测半径映射。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增南丁格尔玫瑰图需求。

## Impact

- 新增 `src/RoseChart.cj`、`src/RoseChart_test.cj`。
