# Spec Delta

## ADDED Requirements

### Requirement: 马赛克单元

`MosaicChart` SHALL 为「类别 × 系列」的每个组合绘制一个 `class="mosaic-cell"` 矩形。

#### Scenario: 四列两系列

- **WHEN** `xAxis.labels` 有 4 项、`series` 有 2 项
- **THEN** 输出 8 个 `class="mosaic-cell"`

### Requirement: 列宽与列内高度

列宽 MUST 与该列总和成正比；列内每个系列高度 MUST 与该系列值占列总和的比例成正比。

#### Scenario: 列总和

- **WHEN** 两个系列在某列的值分别为 120 与 80
- **THEN** 列总和为 200

### Requirement: 马赛克标签

每个类别 MUST 输出 `class="mosaic-label"` 文本，且系列名出现在图例中。

#### Scenario: 类别标签

- **WHEN** `xAxis.labels` 包含 `华东`
- **THEN** 输出包含 `华东`

### Requirement: 马赛克校验

数值 MUST 非负；各系列长度 MUST 一致；列总和 MUST 大于 0；`series` 缺失抛 `MissingField`；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 长度不一致

- **WHEN** 两个系列数据长度不同
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 负值

- **WHEN** 某 `value` 为 -5
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
