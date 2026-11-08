# Spec Delta

## ADDED Requirements

### Requirement: 散点矩阵布局

`ScatterMatrixChart` SHALL 按变量数绘制 n×n 单元；对角单元显示变量名 class `diag-label`，非对角单元绘制两变量散点 class `matrix-point`。

#### Scenario: 三变量

- **WHEN** `variables` 有 3 项、样本 9 行
- **THEN** 输出 3 个 `class="diag-label"` 与 54 个 `class="matrix-point"`

### Requirement: 单元归一化

每个非对角单元 MUST 使用对应两列的最小/最大值把点映射到单元内。

#### Scenario: 列范围

- **WHEN** 某列数据为 160–183
- **THEN** `columnRange` 返回 `[160,183]`

### Requirement: 散点矩阵数据

`variables` MUST 非空；每行长度 MUST 等于变量数；数据 MUST 为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 行长度不匹配

- **WHEN** 变量数为 3 而某行只有 2 个值
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 空变量

- **WHEN** `variables` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
