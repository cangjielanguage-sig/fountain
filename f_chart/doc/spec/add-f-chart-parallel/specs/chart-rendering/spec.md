# Spec Delta

## ADDED Requirements

### Requirement: 平行坐标轴

`ParallelCoordinatesChart` SHALL 为每个维度绘制一条竖直轴与维度名；轴 class `dimension-axis`，名称 class `dimension-label`。

#### Scenario: 四个维度

- **WHEN** `dimensions` 有 4 项
- **THEN** 输出 4 条 `class="dimension-axis"` 与 4 个 `class="dimension-label"`

### Requirement: 样本折线

每个样本行 MUST 输出一条 `class="parallel-line"` 折线，顶点按各维度归一化位置分布。

#### Scenario: 五个样本

- **WHEN** 数据共 5 行
- **THEN** 输出 5 条 `class="parallel-line"`

### Requirement: 维度归一化

`parallelNormalize(value, min, max)` MUST 把 min/max 映射到 0/1，并钳制到 `[0,1]`。

#### Scenario: 中点

- **WHEN** value 为 5、范围为 0–10
- **THEN** 返回 0.5

### Requirement: 平行坐标校验

维度数 MUST 大于 0；每行长度 MUST 等于维度数；维度范围 MUST 递增；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 行长度不匹配

- **WHEN** 维度数为 4 而某行只有 3 个值
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法范围

- **WHEN** 某维度 `min` 等于 `max`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
