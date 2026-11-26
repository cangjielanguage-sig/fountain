## ADDED Requirements

### Requirement: 词云渲染

渲染器 MUST 支持 `type` 为 `word-cloud` 的图表，按权重映射字号并绘制词项。

#### Scenario: 文档示例

- **WHEN** 输入 6 个词、`minFontSize` 为 14、`maxFontSize` 为 56、`rotate` 为 `[0, 90]`
- **THEN** 输出 6 个 `word-cloud-word`

#### Scenario: 字号范围

- **WHEN** 权重最大的词参与渲染
- **THEN** 其字号 MUST 等于 `maxFontSize`
- **AND** 权重最小的词字号 MUST 等于 `minFontSize`

#### Scenario: 旋转循环

- **WHEN** `rotate` 为 `[0, 90]`
- **THEN** 第 2、4、6 个词 MUST 输出 `rotate(90 ...)` 变换

#### Scenario: 词语颜色覆盖

- **WHEN** 词项提供 `color` 字段
- **THEN** 该词 MUST 使用指定颜色，而不是主题调色板颜色

#### Scenario: 空词表

- **WHEN** `words` 为空数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法字号

- **WHEN** `minFontSize` 小于等于 0，或 `maxFontSize` 小于 `minFontSize`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法权重

- **WHEN** 词项 `weight` 小于等于 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** `type` 不是 `word-cloud`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: 词云字号映射

字号映射 MUST 使用权重开方归一化，保证权重差异在字号上平滑呈现。

#### Scenario: 线性归一化输入

- **WHEN** 权重区间为 `[20, 80]`、字号区间为 `[12, 64]`
- **THEN** 权重 `80` 映射为 `64`
- **AND** 权重 `20` 映射为 `12`
- **AND** 权重 `50` 映射为 `12 + 52 × sqrt(0.5)`

#### Scenario: 权重相同

- **WHEN** 所有词权重相同
- **THEN** 每个词 MUST 使用 `minFontSize`
