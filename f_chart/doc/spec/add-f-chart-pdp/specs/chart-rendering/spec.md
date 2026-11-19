# Spec Delta

## ADDED Requirements

### Requirement: PDP 曲线

`PdpChart` MUST 输出 1 条 `class="pdp-line"` 折线，按 `x` 升序连接全部数据点，并 MUST 为每个数据项输出一个 `class="pdp-point"` 圆点。

#### Scenario: 六个数据点

- **WHEN** `data` 有 6 项
- **THEN** 输出 1 条 `pdp-line` 与 6 个 `pdp-point`

### Requirement: PDP 特征标注

`feature` 非空时 MUST 在绘图区左上角输出 `class="pdp-feature"` 文本，内容包含特征名。

#### Scenario: 特征名

- **WHEN** `feature` 为 `年龄`
- **THEN** SVG 包含 `年龄` 且存在 1 个 `pdp-feature`

### Requirement: PDP 轴

x 轴与 y 轴 MUST 覆盖全部数据；`xAxis.min/max`、`yAxis.min/max` 给出时 MUST 按给定值。

#### Scenario: 轴标题

- **WHEN** `xAxis.title` 为 `年龄`、`yAxis.title` 为 `预测值`
- **THEN** SVG 包含两个标题

### Requirement: PDP 校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`x`、`y` MUST 为数字；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 空数据

- **WHEN** `data` 为空
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** 用 `PdpChart` 渲染 `type` 为 `shap` 的输入
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`
