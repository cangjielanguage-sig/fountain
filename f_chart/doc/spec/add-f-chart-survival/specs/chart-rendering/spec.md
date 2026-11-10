# Spec Delta

## ADDED Requirements

### Requirement: 生存阶梯线

`SurvivalChart` MUST 为每个系列绘制一条 `class="survival-line"` 阶梯线：先水平延伸到下一时间点，再垂直变化到新的生存率。每个数据点 MUST 输出一个 `class="survival-point"`。

#### Scenario: 两个系列

- **WHEN** `series` 有两个系列、各 5 个点
- **THEN** 输出 2 条 `survival-line` 与 10 个 `survival-point`

### Requirement: 删失标记

`showCensors` 默认为 true，`censored` 为 true 的数据点 MUST 输出一个 `class="survival-censor"` 文本 `+`；为 false 时不输出。

#### Scenario: 一个删失点

- **WHEN** 某系列有 1 个 `censored` 为 true 的点
- **THEN** 输出 1 个 `class="survival-censor"`

#### Scenario: 关闭删失

- **WHEN** `showCensors` 为 false
- **THEN** 输出 0 个 `class="survival-censor"`

### Requirement: 生存置信带

`confidence` 默认为 false；为 true 时 MUST 为每个系列输出一条 `class="survival-band"` 半透明带。区间由 `survivalConfidence` 计算，取 `S ± 1.96·sqrt(S(1−S)/n)` 并夹到 0–1。

#### Scenario: 开启置信带

- **WHEN** `confidence` 为 true 且有两个系列
- **THEN** 输出 2 条 `class="survival-band"`

#### Scenario: 区间端点

- **WHEN** `survival` 为 0.5、样本数为 100
- **THEN** 下界约为 0.402，上界约为 0.598

### Requirement: 生存图校验

`time` MUST 为非负数字；`survival` MUST 在 0–1 之间；每个系列 `data` MUST 非空；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 生存率越界

- **WHEN** 某点 `survival` 为 1.2
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 负时间

- **WHEN** 某点 `time` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
