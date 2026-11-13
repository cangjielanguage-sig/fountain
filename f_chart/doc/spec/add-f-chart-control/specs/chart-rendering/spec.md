# Spec Delta

## ADDED Requirements

### Requirement: 控制图折线

`ControlChart` SHALL 按数据顺序绘制 `class="control-line"` 折线与每点一个 `class="control-point"`；越出控制限的点 MUST 使用 `class="control-outlier"`。

#### Scenario: 八个测量值

- **WHEN** `data` 有 8 个数值且全部在控制限内
- **THEN** 输出 1 条 `class="control-line"` 与 8 个 `class="control-point"`，0 个 `class="control-outlier"`

#### Scenario: 越限点

- **WHEN** 某值大于 `ucl`
- **THEN** 该点使用 `class="control-outlier"`

### Requirement: 控制限绘制

`ControlChart` MUST 绘制 `class="control-center"`、`class="control-ucl"`、`class="control-lcl"` 三条参考线。

#### Scenario: 三条参考线

- **WHEN** 提供 `center` / `ucl` / `lcl`
- **THEN** 三类参考线各输出 1 条

### Requirement: 控制限计算

未提供 `center` 时 MUST 取数据均值；未提供 `ucl` / `lcl` 时 MUST 按 `center ± 3σ` 计算；`sigma` 未提供时 MUST 用样本标准差（分母 n−1）。

#### Scenario: 均值与样本标准差

- **WHEN** 数据为 3、5、7
- **THEN** 均值为 5，样本标准差为 2

#### Scenario: 自动控制限

- **WHEN** 未提供控制限且数据均值为 5、样本标准差为 2
- **THEN** `ucl` 为 11，`lcl` 为 −1

### Requirement: 控制图校验

`data` MUST 非空且全为数字；`ucl` MUST 不小于 `lcl`；标签长度 MUST 与数据一致；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 标签长度不一致

- **WHEN** 标签 3 个而数据 8 个
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 控制限倒置

- **WHEN** `ucl` 小于 `lcl`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
