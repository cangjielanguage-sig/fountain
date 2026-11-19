# Spec Delta

## ADDED Requirements

### Requirement: 百分比堆叠归一化

`PercentStackedBarChart` SHALL 对每个类目按 `abs(value)` 求和后归一化，使该类目所有段合计为 100%。

#### Scenario: 两段构成

- **WHEN** 某类目两段为 60 与 40
- **THEN** 两段分别占 60% 与 40%

#### Scenario: 负值按绝对值参与构成

- **WHEN** 某类目为 -30 与 70
- **THEN** 两段分别占 30% 与 70%

### Requirement: 百分比堆叠的轴

默认 y 轴 MUST 为 0–100；显式 `yAxis.min` / `yAxis.max` 可覆盖默认范围。

#### Scenario: 默认轴

- **WHEN** 未给 `yAxis.min` / `yAxis.max`
- **THEN** y 轴范围为 0–100

### Requirement: 空类目

某类目所有段都为 0 或 `null` 时 MUST 跳过该类目，不生成柱。

#### Scenario: 全零

- **WHEN** 某类目两段均为 0
- **THEN** 该类目不生成 `class="bar"`
