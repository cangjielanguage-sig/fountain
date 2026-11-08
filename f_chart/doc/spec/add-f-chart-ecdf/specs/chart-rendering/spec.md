# Spec Delta

## ADDED Requirements

### Requirement: 累积频率阶梯线

`EcdfChart` MUST 为每个系列输出一条 `class="ecdf-line"` 阶梯折线，水平段 EXTEND 到下一个观测值，垂直段 MUST 对应累计频率跃升。

#### Scenario: 两个系列

- **WHEN** `series` 有 2 项
- **THEN** 输出 2 条 `ecdf-line`

### Requirement: 累积频率计算

`ecdfPoints` MUST 先对输入排序，再返回 `[x_i, (i + 1) / n]` 序列，长度 MUST 等于输入长度。

#### Scenario: 三个观测

- **WHEN** 输入为 [3, 1, 2]
- **THEN** 返回 [[1, 0.333…], [2, 0.666…], [3, 1]]（允许浮点误差）

### Requirement: 累积频率轴

x 轴 MUST 覆盖全部观测值，y 轴 MUST 覆盖 0 到 1；`xAxis.min/max`、`yAxis.min/max` 给出时 MUST 按给定值。

#### Scenario: 默认纵轴

- **WHEN** 未给 `yAxis.max`
- **THEN** 纵轴最大值为 1

### Requirement: 累积频率校验

`series` MUST 非空，每个 `data` MUST 非空且元素 MUST 为数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** 某系列 `data` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `EcdfChart` 渲染 `type` 为 `density` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
