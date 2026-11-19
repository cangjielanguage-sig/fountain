# Proposal

## Why

茎叶图用文本保留原始数值，适合小样本分布展示。M22 提供茎叶分组与 SVG 文本渲染。

## What Changes

- 新增 `StemLeafChart`，`type` 为 `stem-leaf`。
- `series[0].data` 为数值数组；`stemUnit` 默认 10，`leafDigits` 默认 1。
- 按茎分组、叶排序，逐行输出茎、分隔符与叶串。
- 非数值、空数据、非法参数均抛 `ChartException`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增茎叶图需求。

## Impact

- 新增 `src/StemLeafChart.cj`、`src/StemLeafChart_test.cj`。
- 新增内部 `stemLeafRows` 便于单测分组。
