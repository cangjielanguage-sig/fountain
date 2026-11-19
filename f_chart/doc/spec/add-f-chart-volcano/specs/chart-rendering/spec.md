# Spec Delta

## ADDED Requirements

### Requirement: 火山图分类

`volcanoCategory` MUST 在 `x >= foldChangeThreshold && y >= pThreshold` 时返回 `up`，在 `x <= -foldChangeThreshold && y >= pThreshold` 时返回 `down`，其余返回 `none`。

#### Scenario: 上调

- **WHEN** x 为 2.1、y 为 3.6、foldChangeThreshold 为 1、pThreshold 为 1.3
- **THEN** 返回 `up`

#### Scenario: 边界

- **WHEN** x 为 1、y 为 1.3、阈值为 1 与 1.3
- **THEN** 返回 `up`

#### Scenario: 不显著

- **WHEN** x 为 0.3、y 为 0.8
- **THEN** 返回 `none`

### Requirement: 火山图散点与颜色

`VolcanoChart` MUST 为每个数据项输出一个 `class="volcano-point"` 圆点；上调点 MUST 追加 `volcano-up` 并使用 `upColor`（缺省 `#e53935`），下调点 MUST 追加 `volcano-down` 并使用 `downColor`（缺省 `#1e88e5`），其余追加 `volcano-nonsig` 并使用 `#9e9e9e`。

#### Scenario: 五个点

- **WHEN** `data` 有 5 项
- **THEN** 输出 5 个 `volcano-point`，其中 2 个 `volcano-up`、1 个 `volcano-down`、2 个 `volcano-nonsig`

### Requirement: 火山图阈值线

`VolcanoChart` MUST 输出三条 `class="volcano-threshold"` 虚线：`x = foldChangeThreshold`、`x = -foldChangeThreshold`、`y = pThreshold`。

#### Scenario: 三条阈值线

- **WHEN** 任意合法输入
- **THEN** 输出 3 条 `volcano-threshold`

### Requirement: 火山图标签

显著项提供 `label` 时 MUST 输出 `class="volcano-label"` 文本；不显著项 MUST 不输出标签。

#### Scenario: 显著项标签

- **WHEN** 上调项带 `label` 为 `GENE2`
- **THEN** SVG 包含 `GENE2`

### Requirement: 火山图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`x`、`y` MUST 为数字；`foldChangeThreshold` MUST 不小于 0，`pThreshold` MUST 不小于 0；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 负阈值

- **WHEN** `pThreshold` 为 −1
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `VolcanoChart` 渲染 `type` 为 `scatter` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
