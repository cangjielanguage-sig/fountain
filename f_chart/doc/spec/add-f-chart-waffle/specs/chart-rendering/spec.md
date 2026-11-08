# Spec Delta

## ADDED Requirements

### Requirement: 华夫图方格

`WaffleChart` MUST 输出恰好 `cells` 个 `class="waffle-cell"` 矩形，每行 `columns` 个，最后一行不足时左对齐。

#### Scenario: 一百格

- **WHEN** `cells` 为 100、`columns` 为 10
- **THEN** 输出 100 个 `waffle-cell`，共 10 行

#### Scenario: 不整除

- **WHEN** `cells` 为 10、`columns` 为 4
- **THEN** 输出 10 个 `waffle-cell`，共 3 行

### Requirement: 华夫图取整

`waffleCellCounts` MUST 用最大余数法把各类占比换算为整数格，返回数组之和 MUST 等于 `cells`。

#### Scenario: 整比

- **WHEN** 值为 [42, 28, 18, 12]、`cells` 为 100
- **THEN** 返回 [42, 28, 18, 12]

#### Scenario: 均分余数

- **WHEN** 值为 [1, 1, 1]、`cells` 为 10
- **THEN** 返回 [4, 3, 3]

### Requirement: 华夫图图例

`WaffleChart` MUST 为每个类别输出 `class="waffle-legend"` 文本，内容包含类别名称。

#### Scenario: 四个图例

- **WHEN** `data` 有 4 项
- **THEN** 输出 4 个 `waffle-legend` 文本

### Requirement: 华夫图校验

`cells` 与 `columns` MUST 为大于 0 的整数；`series` MUST 恰好 1 个，`data` MUST 非空，`value` MUST 为不小于 0 的数字且总和大于 0；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 格数为零

- **WHEN** `cells` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 列数为负

- **WHEN** `columns` 为 −2
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
