## 1. 公共基础（TDD）

- [x] 1.1 Red：新增 `ChartConfig.parse` 默认尺寸用例（TUI 不传 width/height 时得到 80×24）
- [x] 1.2 Green：为 `ChartConfig.parse` 增加 `defaultWidth` / `defaultHeight` 可选参数，既有调用不变
- [x] 1.3 Red：新增 `TuiCanvas_test.cj`，覆盖写入、CJK 双宽、截断、Bresenham 线段、ANSI 行尾复位、行数/列宽
- [x] 1.4 Green：实现 `TuiCanvas.cj`、`TuiColor.cj`、`tuiText` 宽度工具与 `tuiStripAnsi` 测试辅助
- [x] 1.5 Red：新增 `TuiFrame_test.cj`，覆盖标题、图例、纵轴刻度、横轴标签与抽稀
- [x] 1.6 Green：实现 `TuiFrame.cj`（布局、坐标轴、网格、标签）

## 2. 柱状图族

- [x] 2.1 Red：`TuiBarChart_test.cj` 覆盖单系列、负值、null、缺字段与类型错误
- [x] 2.2 Green：实现 `TuiBarRenderer`（Simple）与 `tui/BarChart.cj`
- [x] 2.3 Red：`TuiGroupedBarChart_test.cj` 覆盖多系列并排与颜色区分
- [x] 2.4 Green：实现 Grouped 模式与 `tui/GroupedBarChart.cj`
- [x] 2.5 Red：`TuiStackedBarChart_test.cj` 覆盖同 stack 累加与正负堆叠
- [x] 2.6 Green：实现 Stacked 模式与 `tui/StackedBarChart.cj`
- [x] 2.7 Red：`TuiPercentStackedBarChart_test.cj` 覆盖每类柱高一致与 0 和类目
- [x] 2.8 Green：实现 PercentStacked 模式与 `tui/PercentStackedBarChart.cj`

## 3. 折线与散点

- [x] 3.1 Red：`TuiLineChart_test.cj` 覆盖类目轴、数值轴、时间轴、null 断开与 smooth 兼容
- [x] 3.2 Green：实现 `tui/LineChart.cj`
- [x] 3.3 Red：`TuiScatterChart_test.cj` 覆盖数值/时间轴、负值与点数量
- [x] 3.4 Green：实现 `tui/ScatterChart.cj`

## 4. 组合图

- [x] 4.1 Red：`TuiComboChart_test.cj` 覆盖柱+线+散点三类型、柱族混合、百分比叠加与右轴
- [x] 4.2 Green：实现 `tui/ComboChart.cj` 的系列分类、槽位分配与双轴
- [x] 4.3 Red：补充组合图非法 `series[].type` 用例
- [x] 4.4 Green：补齐组合图类型校验

## 5. 文档与交付

- [x] 5.1 更新 `f_chart/README.md` 与 `f_chart/README_en.md` 的 TUI 章节与用法示例
- [x] 5.2 更新 `f_chart/doc/f_chart模块设计.md` 的子包版图与渲染约定
- [x] 5.3 运行 `openspec validate add-f-chart-tui --strict` 并清零 CRITICAL
- [x] 5.4 全量 `cjpm test` 回归（SVG 1092 + TUI 新增用例）全绿
- [x] 5.5 归档变更并同步四件套到 `f_chart/doc/spec/add-f-chart-tui/`
