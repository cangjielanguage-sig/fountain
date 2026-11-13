# Spec Delta

## ADDED Requirements

### Requirement: 瀑布图别名

M87 条目 MUST 复用 M16 的 `WaterfallChart`，`type` 为 `waterfall` 时 MUST 产出与 M16 相同的增减柱、连接器与标签，不新增独立实现。

#### Scenario: 文档示例

- **WHEN** 输入 5 个阶段（2 个 `total`、1 个 `increase`、2 个 `decrease`）的 `waterfall`
- **THEN** 输出 5 个 `waterfall-bar` 与 4 条 `connector`

#### Scenario: 类型不匹配

- **WHEN** 用 `WaterfallChart` 渲染 `type` 为 `bar` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
