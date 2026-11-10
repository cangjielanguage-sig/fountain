## Context

`tag-cloud` 与 `word-cloud` 语义、字段、布局完全相同，属真实别名。`WordCloudChart` 目前用固定字符串 `"word-cloud"` 调用 `ChartConfig.parse`，任何其他 `type` 都会被拒绝。需要放开该别名，同时保留对其他类型的拒绝。

## Decisions

- 先读取 `type`，若为 `tag-cloud` 则以 `"tag-cloud"` 作为期望类型传入 `ChartConfig.parse`；否则沿用 `"word-cloud"`。
- 不新增类或源文件，避免别名分叉。
- 别名测试独立成 `TagCloud_test.cj`，与 M86/M87 的别名回归方式一致。

## Risks

- `type` 为其他值时仍由 `ChartConfig.parse` 抛出 `UnsupportedChart`，无行为变化。
- 别名测试与词云测试共享实现，若实现回归两者都会失败，属预期。

## Testing

- 回归文档 M104 示例：4 个词、默认字号边界 `12`/`64`。
- 非别名类型仍报 `UnsupportedChart`。
- 全量回归在签名后执行 `cjpm test --skip-build`。
