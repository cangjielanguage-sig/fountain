# Spec Delta

## ADDED Requirements

### Requirement: 混淆矩阵方格

`ConfusionMatrixChart` MUST 为方阵的每个元素输出一个 `class="confusion-cell"` 矩形；矩阵 MUST 为 N×N，`labels` 数量 MUST 等于 N。

#### Scenario: 三分类

- **WHEN** `labels` 有 3 项、矩阵为 3×3
- **THEN** 输出 9 个 `confusion-cell`

### Requirement: 混淆矩阵归一化

`confusionNormalize` MUST 支持三种模式：`none` 返回原矩阵；`row` 使每行之和为 1；`column` 使每列之和为 1；行和或列和为 0 时 MUST 保持原值 0。

#### Scenario: 行归一化

- **WHEN** 矩阵为 [[1, 1], [2, 0]]、模式为 `row`
- **THEN** 返回 [[0.5, 0.5], [1, 0]]

#### Scenario: 列归一化

- **WHEN** 矩阵为 [[1, 1], [2, 0]]、模式为 `column`
- **THEN** 返回 [[1/3, 1], [2/3, 0]]

### Requirement: 混淆矩阵文本

`showValues` 为真时 MUST 为每个单元格输出 `class="confusion-value"` 数值文本；MUST 为每个类别输出 `class="confusion-label"` 行标签与列标签。

#### Scenario: 三分类文本

- **WHEN** 3 个类别且 `showValues` 为 true
- **THEN** 输出 9 个 `confusion-value` 与 6 个 `confusion-label`

### Requirement: 混淆矩阵校验

`series` MUST 恰好 1 个；`data` MUST 为方阵；`labels` MUST 非空且数量等于矩阵边长；单元格 MUST 为不小于 0 的数字；`normalize` MUST 为三种取值之一；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非方阵

- **WHEN** 矩阵为 2×3
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 标签数量不符

- **WHEN** `labels` 有 2 项而矩阵为 3×3
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法归一化模式

- **WHEN** `normalize` 为 `all`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
