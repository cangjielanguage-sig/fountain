# Spec Delta

## ADDED Requirements

### Requirement: 学习曲线折线

`LearningCurveChart` MUST 为每个系列输出一条 `class="learning-line"` 折线与对应数量的 `class="learning-point"` 圆点，数据按 `x` 升序连接。

#### Scenario: 两个系列

- **WHEN** `series` 有 2 项、每项 4 个数据点
- **THEN** 输出 2 条 `learning-line` 与 8 个 `learning-point`

### Requirement: 学习曲线标准差带

`shade` 为 `true` 且系列提供与数据等长的 `std` 数组时 MUST 输出一条 `class="learning-band"` 面积带；`shade` 为 `false` 或无 `std` 时 MUST 不输出。

#### Scenario: 显示标准差带

- **WHEN** `shade` 为 true、系列含 4 个 `std`
- **THEN** 输出 1 条 `learning-band`

#### Scenario: 无标准差数据

- **WHEN** `shade` 为 true 但系列不含 `std`
- **THEN** 输出 0 条 `learning-band`

### Requirement: 学习曲线指标

`metric` MUST 为 `score` 或 `loss`（默认 `score`），仅用于语义标注，不改变坐标方向。

#### Scenario: 损失指标

- **WHEN** `metric` 为 `loss`
- **THEN** 正常输出曲线

### Requirement: 学习曲线校验

`series` MUST 非空且每个 `data` MUST 非空；`x`、`y` MUST 为数字；`std` 提供时长度 MUST 与 `data` 一致且元素非负；`metric` MUST 为两种取值之一；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 标准差长度不符

- **WHEN** `data` 有 4 项而 `std` 有 3 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 非法指标

- **WHEN** `metric` 为 `accuracy`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
