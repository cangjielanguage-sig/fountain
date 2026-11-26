# Spec Delta

## ADDED Requirements

### Requirement: 变量刻度尺

`NomogramChart` MUST 为每个变量绘制一条 `class="nomogram-variable"` 水平刻度尺，并在两端标注变量取值范围的最小值与最大值。

#### Scenario: 三个变量

- **WHEN** `variables` 有 3 项
- **THEN** 输出 3 条 `nomogram-variable`

### Requirement: 总分与风险刻度

`NomogramChart` MUST 绘制一条 `class="nomogram-total"` 总分刻度尺，并为每个风险映射绘制一个 `class="nomogram-risk-tick"`。

#### Scenario: 四个风险点

- **WHEN** `risk` 有 4 项
- **THEN** 输出 4 个 `nomogram-risk-tick`

### Requirement: 列线图位置

`nomogramPosition` MUST 把值线性归一化到 0–1 并夹到该区间；`totalPoints` 为 0–240 时，120 MUST 映射到 0.5。

#### Scenario: 中点

- **WHEN** 范围为 0–240、值为 120
- **THEN** `nomogramPosition` 返回 0.5

### Requirement: 列线图校验

`variables` MUST 非空；每项 `range` / `points` MUST 为两个递增数字；`totalPoints` MUST 递增；`risk.points` MUST 落在总分范围内；`risk.probability` MUST 在 0–1 之间。

#### Scenario: 范围倒置

- **WHEN** 某变量 `range` 为 `[80, 20]`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 风险点越界

- **WHEN** 某 `risk.points` 超出 `totalPoints`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
