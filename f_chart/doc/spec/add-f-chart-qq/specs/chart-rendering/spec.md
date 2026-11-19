# Spec Delta

## ADDED Requirements

### Requirement: QQ 理论分位数

`QQChart` SHALL 对 n 个样本使用 `p_i = (i + 0.5) / n` 计算理论分位数；`normal` 用标准正态、`uniform` 用 `p`、`exponential` 用 `-ln(1-p)`。

#### Scenario: 均匀分布四分位

- **WHEN** 样本量为 4、`distribution` 为 `uniform`
- **THEN** 理论分位数为 0.125、0.375、0.625、0.875

#### Scenario: 标准正态中位数

- **WHEN** `p` 为 0.5
- **THEN** `normalQuantile` 约为 0

### Requirement: QQ 散点与参考线

每个样本 MUST 输出一个 `class="qq-point"`；`showLine` 为 true 时 MUST 输出一条 `class="qq-line"`，为 false 时不输出。

#### Scenario: 五个样本

- **WHEN** 样本量为 5 且 `showLine` 为 true
- **THEN** 输出 5 个 `class="qq-point"` 与 1 条 `class="qq-line"`

### Requirement: QQ 校验

`distribution` MUST 为合法枚举；`series` MUST 恰好 1 个；数据非空且全为数值；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法分布

- **WHEN** `distribution` 为 `beta`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
