# Spec Delta

## ADDED Requirements

### Requirement: 柱状图入口与类型判别

`BarChart` SHALL 实现 `Chart`，仅接受 `type` 为 `bar` 的 JSON；其他 `type` MUST 抛 `ChartException`，`kind` 为 `UnsupportedChart`。

#### Scenario: 正常入口

- **WHEN** 调用 `BarChart().draw` 传入 `type` 为 `bar` 且含 `series` 的 JSON
- **THEN** 返回以 `<svg` 开头的字符串

#### Scenario: 类型不匹配

- **WHEN** 传入 `type` 为 `line` 的 JSON
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: 类目到柱的映射

柱状图 SHALL 按 `xAxis.labels` 的顺序绘制等宽类目槽，每个数值对应一根柱；柱高由 `yAxis` 的线性比例尺映射，柱底为数值 0 的基线。

#### Scenario: 三根柱

- **WHEN** `xAxis.labels` 有 3 项且 `series[0].data` 有 3 个数值
- **THEN** 输出包含 3 个 `class="bar"` 的 `rect`

#### Scenario: 标签与数据长度不一致

- **WHEN** `xAxis.labels` 有 2 项而 `series[0].data` 有 3 项
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`，消息包含 `series[0].data`

### Requirement: 负值与缺测

数值为负时柱 MUST 从 0 基线向下绘制；`null` 数据点 MUST 跳过且不生成柱。

#### Scenario: 负值

- **WHEN** 数据为 `[-10, 20]`
- **THEN** 第一根柱的底边在 0 基线、顶边向下

#### Scenario: 缺测

- **WHEN** 数据为 `[10, null, 30]`
- **THEN** 只生成 2 根柱

### Requirement: 主题与图例

柱状图 SHALL 按 `theme.palette` 循环取色；`series[].color` 优先于调色板；单系列且 `name` 为空时 MUST 自动隐藏图例。

#### Scenario: 调色板取色

- **WHEN** 未给 `series[0].color` 且 `theme.palette` 首色为 `#4e79a7`
- **THEN** 第一根柱的 `fill` 为 `#4e79a7`

#### Scenario: 单系列无名隐藏图例

- **WHEN** 只有一个系列且 `name` 为空
- **THEN** 输出不包含图例文本

### Requirement: 确定性与可解析

同一 JSON 输入 MUST 产生逐字节相同的 SVG；输出 MUST 可被 `f_svg` 的解析器解析，根元素为 `svg` 且带 `width`、`height`、`viewBox`。

#### Scenario: 两次绘制一致

- **WHEN** 对同一 JSON 连续调用两次 `draw`
- **THEN** 两次返回的字符串相等

#### Scenario: 往返解析

- **WHEN** 对输出调用 `SvgParser.parse`
- **THEN** 解析成功且根元素标签为 `svg`
