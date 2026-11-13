# Proposal

## Why

配对连线图把同一对象的前后两次测量用一条线相连，能直观看出每个个体上升或下降，适合干预前后、培训前后等配对试验数据。

## What Changes

- 新增 `PairedLineChart`，`type` 为 `paired-line`。
- `series[0].data` 元素为 `{name, before, after}`；`xAxis.labels` MUST 为两个时间点（缺省 `["前", "后"]`）。
- 每个数据项绘制一条 `class="paired-line"` 连线、两个 `class="paired-point"` 端点与右侧 `class="paired-label"` 名称。
- 连线颜色按数据项索引取主题调色板。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增配对连线图需求。

## Impact

- 新增 `src/PairedLineChart.cj`、`src/PairedLineChart_test.cj`。
