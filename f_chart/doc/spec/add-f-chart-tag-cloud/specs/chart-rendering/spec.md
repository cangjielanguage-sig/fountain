## ADDED Requirements

### Requirement: 标签云别名

渲染器 MUST 将 `type` 为 `tag-cloud` 的输入按词云规则渲染，行为与 `word-cloud` 完全一致。

#### Scenario: 文档示例

- **WHEN** 输入 4 个词、`type` 为 `tag-cloud` 的图表
- **THEN** 输出 4 个 `word-cloud-word`

#### Scenario: 字号边界

- **WHEN** 权重为 `90`（最大）与 `40`（最小），未指定字号区间
- **THEN** 两者字号分别为默认的 `64` 与 `12`

#### Scenario: 其他类型仍被拒绝

- **WHEN** `type` 既不是 `word-cloud` 也不是 `tag-cloud`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
