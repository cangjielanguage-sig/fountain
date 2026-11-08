# Spec Delta

## ADDED Requirements

### Requirement: 主题河流带

`StreamgraphChart` MUST 为每个系列输出一条 `class="stream-band"` 闭合面积带，上边界 MUST 为该系列累计上界、下边界 MUST 为累计下界。

#### Scenario: 四个系列

- **WHEN** `series` 有 4 项
- **THEN** 输出 4 条 `stream-band`

### Requirement: 河流基线

`streamBaseline` MUST 按模式返回每列基线：`zero` 全部为 0；`symmetry` 为 `-total / 2`；`wiggle` 为 `symmetry` 结果再做一次相邻三点平滑。

#### Scenario: 零基线

- **WHEN** totals 为 [10, 20]、模式为 `zero`
- **THEN** 返回 [0, 0]

#### Scenario: 对称基线

- **WHEN** totals 为 [10, 20]、模式为 `symmetry`
- **THEN** 返回 [-5, -10]

### Requirement: 河流校验

`series` MUST 非空，各系列 `data` MUST 非空且长度一致；`xAxis.labels` 非空时长度 MUST 等于数据长度；`baseline` MUST 为三种取值之一；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法基线

- **WHEN** `baseline` 为 `center`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 长度不一致

- **WHEN** 两个系列长度分别为 3 与 4
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
