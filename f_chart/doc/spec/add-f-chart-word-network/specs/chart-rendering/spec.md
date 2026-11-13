## ADDED Requirements

### Requirement: 词网络渲染

渲染器 MUST 支持 `type` 为 `word-network` 的图表，依据节点权重与连线值绘制词语共现网络。

#### Scenario: 文档示例

- **WHEN** 输入 4 个节点、4 条连线的 `word-network`
- **THEN** 输出 4 个 `word-network-node`、4 个 `word-network-label` 与 4 条 `word-network-link`

#### Scenario: 权重决定半径

- **WHEN** 节点权重为 `40`（最大值）与 `28`
- **THEN** 前者的节点半径 MUST 大于后者
- **AND** 半径 MUST 落在 `8px` 到 `18px` 之间

#### Scenario: 圆形布局

- **WHEN** `layout` 为 `circular`
- **THEN** 所有节点 MUST 均匀分布在绘图区中心的圆周上

#### Scenario: 非法布局

- **WHEN** `layout` 既不是 `force` 也不是 `circular`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 悬空连线

- **WHEN** 连线的 `source` 或 `target` 不在 `nodes` 中
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非正权重

- **WHEN** 节点 `weight` 小于等于 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 重复节点

- **WHEN** 两个节点使用相同 `id`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** `type` 不是 `word-network`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: 词网络半径映射

节点半径 MUST 按权重开方归一化映射，避免大权重节点吞没整幅画布。

#### Scenario: 权重边界

- **WHEN** 最大权重为 `40`，半径区间为 `8`–`18`
- **THEN** 权重 `40` MUST 映射为 `18`
- **AND** 权重 `10` MUST 映射为 `8 + 10 × sqrt(0.25)`
