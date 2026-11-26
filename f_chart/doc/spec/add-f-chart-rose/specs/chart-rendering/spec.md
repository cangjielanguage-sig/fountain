# Spec Delta

## ADDED Requirements

### Requirement: 玫瑰图扇区

`RoseChart` MUST 为 `series[0].data` 的每一项绘制一个 `class="rose-slice"` 扇区，扇区角度 MUST 均分为 360° / 项数，起点 MUST 为 −90°。

#### Scenario: 四个扇区

- **WHEN** `data` 有 4 项
- **THEN** 输出 4 个 `rose-slice`，每个扫过 90°

### Requirement: 玫瑰图半径

`roseRadius` MUST 在 `radius` 模式下返回 `maxRadius * value / maxValue`，在 `area` 模式下返回 `maxRadius * sqrt(value / maxValue)`。

#### Scenario: 线性半径

- **WHEN** value 为 50、maxValue 为 100、maxRadius 为 200、模式为 `radius`
- **THEN** 半径为 100

#### Scenario: 面积半径

- **WHEN** value 为 25、maxValue 为 100、maxRadius 为 200、模式为 `area`
- **THEN** 半径为 100

### Requirement: 玫瑰图标签

每个非零扇区 MUST 输出 `class="rose-label"` 文本，内容为类目名称。

#### Scenario: 标签数量

- **WHEN** `data` 有 4 项
- **THEN** 输出 4 个 `rose-label` 文本

### Requirement: 玫瑰图校验

`series` MUST 恰好 1 个，`data` MUST 非空，`value` MUST 为不小于 0 的数字且总和大于 0；`roseType` MUST 为 `radius` 或 `area`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 非法模式

- **WHEN** `roseType` 为 `angle`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 全零数据

- **WHEN** 所有 `value` 为 0
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
