# Proposal

## Why

马赛克图用列宽与堆叠高度同时编码两个分类变量的构成关系，是分类数据关联分析的重要图。

## What Changes

- 新增 `MosaicChart`，`type` 为 `mosaic`。
- `xAxis.labels` 为第一维类别；每个 `series` 为第二维类别，`data` 为各类别计数。
- 列宽按列总和占比，列内高度按系列值占比。
- 每个单元 class `mosaic-cell`，类别标签 class `mosaic-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增马赛克图需求。

## Impact

- 新增 `src/MosaicChart.cj`、`src/MosaicChart_test.cj`。
- 新增内部 `mosaicColumnTotals` 便于单测列总和。
