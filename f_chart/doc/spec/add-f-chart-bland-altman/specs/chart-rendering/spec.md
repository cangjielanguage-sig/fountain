# Spec Delta

## ADDED Requirements

### Requirement: Bland-Altman 散点

`BlandAltmanChart` MUST 为每个测量对输出一个 `class="bland-altman-point"` 圆点，横坐标 MUST 为 `(x + y) / 2`、纵坐标 MUST 为 `y - x`。

#### Scenario: 六个测量对

- **WHEN** `data` 有 6 项
- **THEN** 输出 6 个 `bland-altman-point`

### Requirement: 一致性界限

`blandAltmanStats` MUST 返回 `[meanDiff, meanDiff − 1.96·sd, meanDiff + 1.96·sd]`，其中 `sd` 为差值的样本标准差；只有一个测量对时 `sd` MUST 为 0。

#### Scenario: 恒定差值

- **WHEN** 差值为 [1, 1, 1]
- **THEN** 返回 [1, 1, 1]

#### Scenario: 单对测量

- **WHEN** 只有一个测量对且差值为 2
- **THEN** 返回 [2, 2, 2]

### Requirement: 一致性参考线

`BlandAltmanChart` MUST 输出一条 `class="bland-altman-mean"` 均值线、两条 `class="bland-altman-limit"` 界限线，并在右端标注数值。

#### Scenario: 参考线数量

- **WHEN** 输入 6 个测量对
- **THEN** 输出 1 条 `bland-altman-mean` 与 2 条 `bland-altman-limit`

### Requirement: Bland-Altman 校验

`series` MUST 恰好 1 个且 `data` MUST 非空；每项 MUST 提供数字型 `x` 与 `y`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 缺少 y

- **WHEN** 某测量对没有 `y`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 类型不匹配

- **WHEN** 用 `BlandAltmanChart` 渲染 `type` 为 `scatter` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
