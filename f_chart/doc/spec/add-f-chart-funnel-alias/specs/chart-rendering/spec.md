# Spec Delta

## ADDED Requirements

### Requirement: 漏斗图别名

M86 条目 MUST 复用 M35 的 `FunnelChart`，`type` 为 `funnel` 时 MUST 产出与 M35 相同的阶段条与转化率标签，不新增独立实现。

#### Scenario: 文档示例

- **WHEN** 输入 4 阶段、`showConversion` 为 true 的 `funnel`
- **THEN** 输出 4 个 `funnel-stage`、4 个 `stage-label` 与 3 个 `conversion-label`

#### Scenario: 类型不匹配

- **WHEN** 用 `FunnelChart` 渲染 `type` 为 `pyramid` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
