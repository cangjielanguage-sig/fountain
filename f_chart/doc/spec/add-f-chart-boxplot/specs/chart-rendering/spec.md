# Spec Delta

## ADDED Requirements

### Requirement: 箱线图五数概括

`BoxPlotChart` SHALL 按每个数据项的 `min/q1/median/q3/max` 绘制箱体、中位线、上下须与端帽；`outliers` 中的值 MUST 画成圆点。

#### Scenario: 四个类别

- **WHEN** `data` 有 4 项且其中 3 个异常值
- **THEN** 输出 4 个 `class="box"`、4 条 `class="median"`、8 条 `class="whisker"` 与 3 个 `class="outlier"`

### Requirement: 五数顺序校验

`min <= q1 <= median <= q3 <= max` MUST 成立；否则抛 `InvalidValue`。

#### Scenario: 四分位数越界

- **WHEN** `q1` 大于 `median`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 箱线图数据校验

`series` MUST 恰好 1 个；统计字段 MUST 为有限数字；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 多个系列

- **WHEN** `series` 有 2 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 缺少 q3

- **WHEN** 某项没有 `q3`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`
