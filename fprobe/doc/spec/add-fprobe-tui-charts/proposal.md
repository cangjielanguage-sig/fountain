# Proposal

## Why

`fprobe` 的控制台右侧指标区目前只有自绘的单行 `Sparkline`（`▁▂▃▄▅▆▇█`）。它只能表达「相对高低」，没有坐标轴、刻度、图例，也无法看出一个窗口内的趋势形状；运维在 SSH 里看到一排方块时，仍然要回到表格读当前值。

仓库的 `f_chart` 已经有 TUI 子包 `fountain::f_chart.tui`：折线、柱状、散点等 8 个类把同一份图表 JSON 渲染成多行字符画，自带标题、图例、坐标轴、刻度、CJK 宽度处理与 ANSI 真彩色，最小画布 20×8。`fprobe` 已经依赖 `f_chart`，`RenderPlan` 也已经携带 `SparkSeries`（名称、单位、历史数值），把它接到 TUI 是本变更最直接的收益：不新写图表引擎，只做一层适配。

直接复用有一个硬阻塞：`TuiCanvas` 是 `internal`，`plainLines()` 每行按显示列输出、宽字符只输出一个 rune，宿主无法据此还原单元格坐标；`render()` 又内嵌 ANSI 转义，宿主若解析 ANSI 既脆弱又要自己算 Unicode 宽度。因此 `f_chart.tui` 必须先提供「逐单元格符号矩阵」这一层稳定接口，`fprobe` 才能安全地把图表写进自己的 `ratatui_buffer.Buffer`。

小终端（右侧剩余高度不足 8 行，或宽度不足 20 列）仍需要保留现有的单行 `Sparkline` 作为回退，避免 f_chart 的最小尺寸约束把图表区变成空白。

## What Changes

- `f_chart.tui` 新增公开接口 `TuiCellChart`：
  - `func drawCells(data: JsonObject): Array<Array<String>>`。
  - 矩阵行数等于画布 `height`，每行元素数等于画布 `width`；宽字符后半格为空字符串；不含 ANSI 转义。
  - `TuiLineChart` 与 `TuiBarChart` 实现该接口；`draw` 保持原样（ANSI 真彩色输出不变）。
  - 新增 `internal TuiCanvas.cellSymbols()`；把折线/柱状「构建画布」的逻辑从 `draw` 中抽出，`draw` 与 `drawCells` 共用同一份画布。
- `fprobe` 新增 `tui/ChartPanel.cj` 适配层：
  - `ChartPanel.render(series: Array<SparkSeries>, width: Int64, height: Int64, chartType: String): ?Array<Array<String>>`。
  - 只取第一条序列，避免「百分比」与「字节/秒」混在同一根数值轴上。
  - 用 `ChartSpec.forCells` 生成图表 JSON，调用 `TuiLineChart`/`TuiBarChart` 的 `drawCells`。
  - 空序列、空数值、未知类型、尺寸不足（宽 < 20 或高 < 8）、f_chart 抛异常时一律返回 `None`，由调用方回退。
- `MetricPage` 新增 `chartType()`：CPU/内存/网络/服务/健康 → `line`，磁盘 → `bar`，拓扑/告警 → `""`。
- `RenderPlan` 增加三个纯数据字段（带默认值，既有构造调用不破坏）：
  - `chartType: String`；
  - `chartSeries: ?SparkSeries`（当前页第一条）；
  - `chartHeight: Int64`（由视口高度与指标行数算出，未知视口为 0）。
- `Painter` 增加 `viewportHeight(): Int64`；`FprobePainter` 暴露真实终端高度，`NullPainter` 返回 0；`RenderLoop` 把它传给 `RenderPlanBuilder`，使 `chartHeight` 与实际右栏内部高度一致。
- `FprobePainter` 调整右栏绘制：
  - 先画指标表，再留一行空白；
  - `chartHeight ≥ 8` 且宽度足够时逐单元格写入图表；任一条件不满足或 `ChartPanel` 返回 `None` 时回退为现有 sparkline（回退时仍画全部序列）；
  - 图表单元格跳过空字符串（宽字符后半格），统一使用宿主主题色。
- `report/ChartSpec` 增加 `forCells` 工厂：标题为空、单具名系列、类目轴标签留空（由 TUI 自动生成 `1..N`）、指定字符画布宽高。报告路径不受影响。
- 文档与镜像：更新 `f_chart/README.md`、`f_chart/doc/f_chart模块设计.md`、`fprobe/doc/tui.md`；把本变更四件套镜像到 `fprobe/doc/spec/add-fprobe-tui-charts/`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-tui`：新增「逐单元格绘制接口（`TuiCellChart`）」要求，明确矩阵尺寸、宽字符续格、与 `draw` 的符号一致性，以及 `draw` 行为不变。
- `probe-supervisor`：修改「控制台模式」要求——右侧指标区从「必须使用 sparkline」改为「优先多行图表、尺寸不足回退 sparkline」，并规定各监控页的图表类型、拓扑/告警页不绘图。

## Impact

- 代码：
  - `f_chart/src/tui/TuiCellChart.cj`（新增）、`TuiCanvas.cj`、`LineChart.cj`、`TuiBarRenderer.cj`、`BarChart.cj`。
  - `fprobe/src/tui/ChartPanel.cj`（新增）、`TuiLayout.cj`（新增）、`RenderPlan.cj`、`ViewModel.cj`（`MetricPage.chartType`）、`Painter.cj`、`FprobePainter.cj`、`RenderLoop.cj`。
  - `fprobe/src/report/ChartSpec.cj`（新增 `forCells` 工厂，既有调用不变）。
  - `fprobe/src/runtime/RuntimeSupport.cj`（`NullPainter.viewportHeight`）。
  - 测试：`f_chart/src/tui/TuiCanvas_test.cj`、`TuiLineChart_test.cj`、`TuiBarChart_test.cj`（或新增 `TuiCellChart_test.cj`）；`fprobe/src/tui/ChartPanel_test.cj`（新增）、`TuiLayout_test.cj`（新增）、`RenderPlan_test.cj`、`FprobePainter_test.cj`、`RenderLoop_test.cj`、`SupervisorApp_test.cj`、`report/ChartSpec_test.cj`。
- 依赖：不变。`fprobe` 已依赖 `f_chart`；`f_chart.tui` 仍为零第三方依赖；不引入 `ratatui_widgets`、`crossterm`。
- 配置：不新增配置项。图表类型由监控页固定映射，不开放 `probe_chart_*` 到 TUI（该配置只服务 SVG 报告）。
- 兼容性：`Chart.draw` 与 `TuiLineChart`/`TuiBarChart` 的 `draw` 输出保持逐字节不变；`RenderPlan` 新字段带默认值；`Painter` 接口新增方法是本模块内部抽象，需同步更新 3 个测试替身与 `NullPainter`。
- 视觉：右侧指标区从「N 行 sparkline」变为「指标表 + 一块多行带轴图表」；高度不足时与变更前一致。
- 性能：每帧最多生成一次 `W×H` 的字符串矩阵（典型 50×13），只在有图表且高度足够的页面发生；相对一次终端差分刷新可忽略。
- 风险：布局高度在 `RenderPlanBuilder` 与 `FprobePainter` 两处计算，必须用同一套常量并加实际剩余高度的 `min` 兜底；宽字符写入 `Buffer` 时只能写首格、跳过续格，否则列会漂移。

## Non-Goals

- 不改 SVG 报告图表；报告仍走 `ChartSelector` + `f_chart` 的 SVG 实现。
- 不把拓扑页画成图形（仍为设备/链路文本行）。
- 不为 `f_chart.tui` 其余 6 个类补 `TuiCellChart`；本次只覆盖 `TuiLineChart` 与 `TuiBarChart`。
- 不把 f_chart 系列颜色映射到终端主题，也不做 ANSI 解析；图表单元格统一使用宿主前景色。
- 不做多序列叠加（不同单位不共用轴）、缩放、平移、水平滚动或交互式图表。
- 不新增图表高度配置项；高度完全由终端视口与指标表行数决定。
