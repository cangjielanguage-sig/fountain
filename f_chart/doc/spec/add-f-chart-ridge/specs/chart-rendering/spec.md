# Spec Delta

## ADDED Requirements

### Requirement: 山脊分布层次

`RidgeChart` SHALL 为每个系列绘制一条填充核密度曲线，并沿 y 方向逐行错位排列；每行 class `ridge-area`，描边 class `ridge-line`。

#### Scenario: 四组分布

- **WHEN** `series` 有 4 项
- **THEN** 输出 4 个 `class="ridge-area"`、4 个 `class="ridge-line"` 与 4 个 `class="ridge-label"`

### Requirement: 重叠系数

`overlap` MUST 在 0 到 1 之间，且越大曲线振幅越高；振幅按 `bandHeight × (0.8 + 0.4 × overlap)` 计算。

#### Scenario: 重叠对比

- **WHEN** `overlap` 为 0 与 1
- **THEN** 后者振幅大于前者

#### Scenario: 非法重叠

- **WHEN** `overlap` 为 1.5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 山脊图校验

`bandwidth` MUST 大于 0；每组数据非空且全为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** 某系列 `data` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
