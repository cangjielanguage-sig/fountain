# Spec Delta

## ADDED Requirements

### Requirement: 曼哈顿散点

`ManhattanChart` MUST 为每个数据项输出一个 `class="manhattan-point"` 圆点，颜色 MUST 按染色体顺序在两种主题色之间交替。

#### Scenario: 五个位点

- **WHEN** `data` 有 5 项
- **THEN** 输出 5 个 `manhattan-point`

### Requirement: 染色体间隔

`manhattanPositions` MUST 按染色体首次出现顺序分组；同一染色体内部的显示位置 MUST 保持相对差值；相邻染色体之间 MUST 插入 `chromosomeGap` 的空白。

#### Scenario: 单染色体

- **WHEN** 所有点属于同一染色体、gap 为 100
- **THEN** 返回位置与输入 `xs` 相同

#### Scenario: 两个染色体

- **WHEN** 第一组 x 跨度为 100、gap 为 50
- **THEN** 第二组首点的显示位置为第一组最小位置加 150

### Requirement: 显著性阈值线

提供 `threshold` 时 MUST 输出一条 `class="manhattan-threshold"` 水平虚线。

#### Scenario: 阈值线

- **WHEN** `threshold` 为 5
- **THEN** 输出 1 条 `manhattan-threshold`

### Requirement: 曼哈顿校验

`series` MUST 恰好 1 个且 `data` MUST 非空；`x`、`y` MUST 为数字，`chromosome` MUST 为非空字符串；`chromosomeGap` MUST 非负；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 缺少染色体

- **WHEN** 某数据项没有 `chromosome`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 负间距

- **WHEN** `chromosomeGap` 为 −10
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
