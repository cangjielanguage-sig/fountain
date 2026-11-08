# Spec Delta

## ADDED Requirements

### Requirement: 茎叶分组

`StemLeafChart` SHALL 按 `stemUnit` 计算茎、按 `leafDigits` 计算叶，并按茎升序、叶升序输出。

#### Scenario: 经典样本

- **WHEN** 数据为 52–96、`stemUnit` 为 10
- **THEN** 得到 5 行茎 5–9，茎 6 的叶为 `1 3 3 7`

### Requirement: 茎叶文本渲染

每行 MUST 输出茎、分隔符 `|` 与叶串；行 class 为 `stem-leaf-row`，叶串 class 为 `stem-leaf-leaves`。

#### Scenario: 五行

- **WHEN** 数据产生 5 行
- **THEN** 输出 5 个 `class="stem-leaf-row"` 与 5 个 `class="stem-leaf-leaves"`

### Requirement: 茎叶参数

`stemUnit` MUST 大于 0；`leafDigits` MUST 为非负整数；否则抛 `InvalidValue`。

#### Scenario: 非法茎单位

- **WHEN** `stemUnit` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 茎叶校验

`series` MUST 恰好 1 个；`data` 非空且全为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 多个系列

- **WHEN** `series` 有 2 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
