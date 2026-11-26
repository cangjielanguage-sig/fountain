## ADDED Requirements

### Requirement: TUI 子包与图表类

模块 MUST 提供子包 `fountain::f_chart.tui`，其中包含 `TuiBarChart`、`TuiGroupedBarChart`、`TuiStackedBarChart`、`TuiPercentStackedBarChart`、`TuiLineChart`、`TuiScatterChart`、`TuiComboChart` 七个公开类；每个类 MUST 实现 `fountain::f_chart.Chart`。

#### Scenario: 类型分发

- **WHEN** 用 `bar` JSON 调用 `TuiBarChart().draw`
- **THEN** 返回非空字符画字符串
- **AND** 用 `bar` JSON 调用 `TuiLineChart().draw` 抛出 `UnsupportedChart`

#### Scenario: 与 SVG 版共存

- **WHEN** 同时导入 `fountain::f_chart.*` 与 `fountain::f_chart.tui.*`
- **THEN** `BarChart` 与 `TuiBarChart` 不产生命名冲突

### Requirement: 字符画布尺寸

TUI 渲染 MUST 把 `width` 与 `height` 解释为字符列数与行数；缺省时 MUST 使用 80 列 × 24 行。画布宽高小于 20×8 时 MUST 抛出 `InvalidValue`。

#### Scenario: 缺省尺寸

- **WHEN** JSON 未提供 `width` 与 `height`
- **THEN** 输出恰好 24 行
- **AND** 每行显示宽度为 80 列

#### Scenario: 自定义尺寸

- **WHEN** JSON 提供 `"width": 60, "height": 20`
- **THEN** 输出恰好 20 行，每行显示宽度为 60 列

#### Scenario: 尺寸过小

- **WHEN** JSON 提供 `"width": 10`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: ANSI 彩色输出

`draw` MUST 返回 ANSI 24 位真彩色字符串；每个颜色段以 `ESC[38;2;R;G;Bm` 开始，每行 MUST 以 `ESC[0m` 复位并以 `\n` 结束。颜色 MUST 由主题调色板或系列 `color` 解析得到。

#### Scenario: 颜色转义

- **WHEN** 使用默认主题渲染柱状图
- **THEN** 输出包含 `\u{1B}[38;2;78;121;167m`
- **AND** 每行以 `\u{1B}[0m\n` 结束

#### Scenario: 自定义系列颜色

- **WHEN** 系列 `color` 为 `#ff0000`
- **THEN** 该系列标记使用 `\u{1B}[38;2;255;0;0m`

#### Scenario: 非法颜色

- **WHEN** 系列 `color` 为 `not-a-color`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

### Requirement: 通用布局

字符画 MUST 包含标题、可选图例、纵轴刻度与横轴标签；绘图区 MUST 留有左侧刻度宽度与底部标签行。类目标签过多时 MUST 通过抽稀避免重叠。

#### Scenario: 标题与图例

- **WHEN** JSON 提供 `title` 与两个具名系列
- **THEN** 首行包含标题文本
- **AND** 图例行包含两个系列名与色块 `■`

#### Scenario: 坐标轴

- **WHEN** 渲染任意笛卡尔图
- **THEN** 输出包含 `│` 纵轴、`─` 横轴与 `└` 轴角
- **AND** 输出包含至少两个纵轴刻度标签

### Requirement: 柱状图族

柱状图族 MUST 支持 `bar`、`grouped-bar`、`stacked-bar`、`percent-stacked-bar` 四种类型。柱体 MUST 使用 `█` 绘制；`bar` 单系列占满类目带，`grouped-bar` 在类目带内并排，`stacked-bar` 自基线累加，`percent-stacked-bar` 先按类目归一到 100% 再累加。

#### Scenario: 单系列柱

- **WHEN** 输入 6 个类目的 `bar`
- **THEN** 每个非零类目至少出现一个 `█`
- **AND** 输出包含全部类目标签

#### Scenario: 分组柱

- **WHEN** 输入 2 个系列的 `grouped-bar`
- **THEN** 同一类目带内出现两种不同颜色的 `█`

#### Scenario: 堆叠柱

- **WHEN** 输入 3 个系列且 `stack` 相同的 `stacked-bar`
- **THEN** 同一列中三种颜色的 `█` 自下而上连续排列

#### Scenario: 百分比堆叠

- **WHEN** 输入各系列和不等的 `percent-stacked-bar`
- **THEN** 每个类目的柱高一致，且每列颜色段按比例分配

### Requirement: 折线图

折线图 MUST 支持类目、数值与时间三种横轴；数据点之间 MUST 用 Bresenham 线段连接；`null` MUST 断开折线；`smooth` MUST 被接受但不改变字符画拓扑。

#### Scenario: 类目折线

- **WHEN** 输入 6 个点的 `line`
- **THEN** 输出包含 `*` 线段与 `o` 数据点
- **AND** 折线跨越至少 5 个横向列

#### Scenario: 缺测断开

- **WHEN** 数据为 `[1, null, 3]`
- **THEN** 中间类目没有 `*`，两侧存在独立线段

#### Scenario: 时间轴

- **WHEN** `xAxis.type` 为 `time` 且数据项含 `x` 日期
- **THEN** 横轴标签为 `YYYY-MM-DD` 形式

### Requirement: 散点图

散点图 MUST 按 `(x, y)` 定位并绘制 `o` 标记；横轴 MUST 支持数值与时间；纵轴范围 MUST 覆盖全部数据点。

#### Scenario: 数值散点

- **WHEN** 输入 8 个 `{x,y}` 点
- **THEN** 输出包含 8 个 `o`（重叠点可少于 8 个可见标记）

#### Scenario: 负值

- **WHEN** 数据包含负的 `y`
- **THEN** 纵轴范围包含 0，负值点位于 0 轴下方

### Requirement: 组合图

组合图 MUST 支持 `bar`、`line`、`scatter`、`grouped-bar`、`stacked-bar`、`percent-stacked-bar` 六种系列类型，任意两种或三种类型 MUST 能同时呈现在同一绘图区。`axis` 为 `right` 的系列 MUST 使用 `yAxis2` 的刻度范围。

#### Scenario: 三类型组合

- **WHEN** 输入 `bar` + `line` + `scatter` 三个系列
- **THEN** 输出同时包含 `█`、`*`、`o`
- **AND** 输出包含右轴刻度（存在 `yAxis2` 时）

#### Scenario: 柱族混合

- **WHEN** 输入 `grouped-bar` + `stacked-bar` 两个系列
- **THEN** 同一类目带内既有并排柱，也有堆叠柱，且颜色可区分

#### Scenario: 百分比叠加入组合

- **WHEN** 输入两个 `percent-stacked-bar` 系列与一个 `line` 系列
- **THEN** 柱段占满类目带高度，折线叠加在上层

### Requirement: 字符宽度与截断

画布 MUST 按显示宽度处理文本：CJK 字符占 2 列，其他字符占 1 列；超出可用宽度的标签 MUST 截断并以 `…` 结尾；宽字符不得越过右边界。

#### Scenario: CJK 标题居中

- **WHEN** 标题为 `月度销售额`、画布宽 80
- **THEN** 标题在纯文本行中完整出现且左右留白大致对称

#### Scenario: 窄画布截断

- **WHEN** 类目标签宽度超过类目带宽度
- **THEN** 标签以 `…` 结尾且不越界

### Requirement: TUI 错误语义

TUI 渲染 MUST 复用 `ChartException`；类型不匹配为 `UnsupportedChart`，缺字段为 `MissingField`，非法数值或颜色为 `InvalidValue`。

#### Scenario: 缺少 series

- **WHEN** `bar` JSON 不含 `series`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 数据长度不符

- **WHEN** 系列数据长度与 `xAxis.labels` 不一致
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
