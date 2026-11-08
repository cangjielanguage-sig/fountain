# Proposal

## Why

百分比条把每个类目的构成压缩为一根 100% 横条，用于季度收入构成、渠道占比等需要横向比较构成的场景。

## What Changes

- 新增 `PercentBarChart`，`type` 为 `percent-bar`。
- 数据形状与 `percent-stacked-bar` 相同：`xAxis.labels` 为类目，`series[i].data` 为数值数组。
- 实现复用 `BarRenderer` 的 `PercentStacked` 模式，仅类型判别字符串不同；不引入新图元。
- 新增回归测试覆盖文档示例。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增百分比条别名入口需求。

## Impact

- 新增 `src/PercentBarChart.cj`、`src/PercentBarChart_test.cj`。
