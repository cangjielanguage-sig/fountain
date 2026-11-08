## Why

文档把 `tag-cloud` 定义为 `word-cloud` 的别名（M104）。两者字段与视觉完全一致，只需让 `WordCloudChart` 接受该 `type`，避免重复实现。

## What Changes

- `WordCloudChart` 接受 `type` 为 `word-cloud` 或 `tag-cloud`。
- 其他类型继续抛出 `UnsupportedChart`。
- 新增 `TagCloud_test.cj`，回归文档 M104 示例。

## Capabilities

### New Capabilities

- `chart-rendering`：明确 `tag-cloud` 与 `word-cloud` 等价。

### Modified Capabilities

无。

## Impact

- 修改 `f_chart/src/WordCloudChart.cj` 的类型读取。
- 新增 `f_chart/src/TagCloud_test.cj`。
