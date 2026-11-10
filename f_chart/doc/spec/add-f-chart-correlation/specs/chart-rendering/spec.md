# Spec Delta

## ADDED Requirements

### Requirement: 相关矩阵渲染

`CorrelationMatrixChart` SHALL 绘制 n×n 个单元，每个单元 class 为 `correlation-cell`，并按相关系数映射颜色。

#### Scenario: 四变量矩阵

- **WHEN** 数据为 4×4 方阵
- **THEN** 输出 16 个 `class="correlation-cell"`

### Requirement: 相关系数标注

`showValues` 默认为 true，此时每个单元 MUST 输出 `class="cell-value"` 数值文本；为 false 时 MUST 不输出。

#### Scenario: 关闭数值

- **WHEN** `showValues` 为 false
- **THEN** 输出 0 个 `class="cell-value"`

### Requirement: 相关系数配色

`correlationColor(value, low, mid, high)` MUST 在 value 为 -1/0/1 时分别返回 low/mid/high；`colorRange` 可覆盖默认三色。

#### Scenario: 端点颜色

- **WHEN** value 为 1
- **THEN** 返回 `colorRange[2]`

### Requirement: 相关矩阵校验

数据 MUST 为方阵且元素在 [-1,1]；`method` MUST 为合法枚举；标签长度 MUST 与矩阵阶数一致；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非方阵

- **WHEN** 数据为 2×3
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 越界系数

- **WHEN** 某元素为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
