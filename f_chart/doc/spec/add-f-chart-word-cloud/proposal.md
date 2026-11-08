## Why

`f_chart` 缺少文本权重可视化能力。词云以字号映射词频，是用户反馈、标签分布等场景的常用图表；`tag-cloud`（M104）也将复用同一实现。

## What Changes

- 新增 `WordCloudChart`（`type` 为 `word-cloud`），实现 `Chart` 接口。
- `words: [{text, weight, color?}]` 按权重降序排列；字号在 `minFontSize`（默认 12）与 `maxFontSize`（默认 64）之间按权重开方映射。
- `rotate` 为允许的旋转角度数组（默认 `[0]`），按词序循环取用；目前支持 `0` / `90` / `-90`。
- 采用确定性货架式布局，避免重叠；超出绘图区的后续词不再绘制。

## Capabilities

### New Capabilities

- `chart-rendering`：新增词云图的 JSON 契约与渲染行为，并记录 `tag-cloud` 别名复用。

### Modified Capabilities

无。

## Impact

- 新增 `f_chart/src/WordCloudChart.cj` 与 `f_chart/src/WordCloudChart_test.cj`。
- 复用 `ChartConfig`、`ChartFrame`、`ChartSvgKit` 与 `chartTextWidth`。
