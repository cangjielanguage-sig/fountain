## Context

`fprobe` 的 `RenderPlan` 已是纯数据：每页有 `metricRows`（当前值表格）与 `series: Array<SparkSeries>`（名称、单位、历史窗口）。`FprobePainter` 把它机械映射到 `ratatui_buffer.Buffer`，目前每个序列画一行 `Sparkline`。

`f_chart.tui` 已能把同一份 JSON 渲染为多行字符画，但对外只有 `Chart.draw(JsonObject): String`，输出是带 ANSI 真彩色的整幅文本；真正决定布局的 `TuiCanvas` 是 `internal`。`fprobe` 若要复用，必须拿到「每个单元格放什么符号」，否则只能解析 ANSI 或自己复制一套 CJK 宽度与坐标算法，两条路都不可接受。

本变更因此分两层：`f_chart.tui` 暴露稳定的单元格矩阵；`fprobe` 在其上做页面适配、布局与回退。两层都按 TDD 推进，不新增依赖，不动 SVG 路径。

## Decisions

### D1：在 `f_chart.tui` 增加 `TuiCellChart`，而不是让宿主解析 ANSI

- 新增文件 `f_chart/src/tui/TuiCellChart.cj`：

```cj
package fountain::f_chart.tui

import fountain::f_data.json.JsonObject

/** 逐单元格读取图表符号；颜色由宿主决定。 */
public interface TuiCellChart {
    func drawCells(data: JsonObject): Array<Array<String>>
}
```

- `TuiLineChart` 与 `TuiBarChart` 的声明改为同时实现两个接口（仓颉支持 `&` 多接口）：

```cj
public class TuiLineChart <: Chart & TuiCellChart
public class TuiBarChart  <: Chart & TuiCellChart
```

- `TuiCanvas` 新增 `internal func cellSymbols(): Array<Array<String>>`：
  - 外层长度 `height`；
  - 每行长度严格为 `width`（不是 `plainLines` 的显示列压缩结果）；
  - 普通格输出 `cell.symbol`（默认空格是 `" "`）；
  - `continuation` 格输出 `""`。
- 选择矩阵而不是 `plainLines()` 的原因：`plainLines()` 会丢掉宽字符的续格，宿主按字符串下标写 `Buffer` 会整体左移；矩阵保留列位置，宿主直接按 `(row, col)` 写。
- 选择「只有符号、没有颜色」的原因：ANSI 真彩色是 f_chart 的主题色，fprobe 的 TUI 有自己的语义色；先只传符号，颜色由宿主统一，避免引入 ANSI 解析器。

### D2：`draw` 与 `drawCells` 共用同一份画布

- 把 `TuiLineChart.draw` 的主体抽成 `private func buildCanvas(data: JsonObject): TuiCanvas`，返回画布而不 `render()`：
  - `draw(data) = buildCanvas(data).render()`；
  - `drawCells(data) = buildCanvas(data).cellSymbols()`。
- `TuiBarRenderer` 增加 `static func canvas(data: JsonObject, expectedType: String, mode: BarMode): TuiCanvas`，把现有 `render` 的主体原样搬入并以 `return canvas` 结束：
  - `render(...) = canvas(...).render()`；
  - `TuiBarChart.drawCells` 调 `TuiBarRenderer.canvas(data, "bar", BarMode.Simple).cellSymbols()`。
- 这是纯内部重构，不改任何绘制指令的顺序与坐标，保证既有 76 个 TUI 用例的 `draw` 断言逐字节通过。

### D3：`ChartPanel` 只做「序列 → 图表 JSON → 单元格」的适配

新增 `fprobe/src/tui/ChartPanel.cj`：

```cj
public class ChartPanel {
    public static let MIN_WIDTH: Int64 = 20
    public static let MIN_HEIGHT: Int64 = 8

    public static func render(series: Array<SparkSeries>, width: Int64, height: Int64,
        chartType: String): ?Array<Array<String>>
}
```

规则：

1. `series` 为空、`series[0].values` 为空 → `None`。
2. `width < 20 || height < 8` → `None`（与 `ChartConfig` / `TuiFrame` 的最小画布一致，提前拦截而不是靠异常）。
3. `chartType` 不是 `line`/`bar` → `None`。
4. 只取 `series[0]`：不同指标可能是 `%`、`B`、`B/s`、`ms`，共用一根数值轴会误导；每页第一条在 `ProjectionCatalog` 中就是该页主指标。
5. 构造 JSON 后调用对应类的 `drawCells`；捕获 `ChartException` 与其它 `Exception`，返回 `None`，**不允许**图表异常穿透到帧循环。

JSON 构造复用 `report/ChartSpec`，新增工厂：

```cj
public static func forCells(chartType: String, seriesName: String,
    values: Array<Float64>, width: Int64, height: Int64): ChartSpec
```

它把 `title` 设为空（面板本身已有页标题，序列名交给图例）、`xAxis.labels` 留空、`series` 设为单个 `ChartSeriesSpec(seriesName, values)`、`width`/`height` 设为字符画布尺寸。`jsonObject()` 仍负责把 `chartType` 改名为 `type`。

**坐标轴模式（调研修正）**：`ChartConfig` 的 `xAxis` 默认类型是 `category`；而 `TuiPointCommon.tuiParsePointSeries` 在 `linear`/`time` 模式下要求 `data` 的每一项是 `{x, y}` 对象，**不能**直接吃 `Array<Float64>`。因此 TUI 监控图唯一可行的输入是类目模式：`data` 为数值数组，`tuiResolveLabels` 自动生成 `1..N` 的横轴标签。这也正是需求底稿给出的 JSON 形态（不配 `xAxis.labels`）。标签在类目带过窄时由 `TuiFrame` 自动不绘制，只保留折线/柱体与纵轴刻度，符合监控趋势的阅读需求。

### D4：`RenderPlan` 增加图表意图，`chartHeight` 由视口高度计算

`MetricPage` 增加：

```cj
public func chartType(): String {
    match (this) {
        case CPU | MEMORY | NETWORK | SERVICE | HEALTH => "line"
        case DISK => "bar"
        case TOPOLOGY | ALARMS => ""
    }
}
```

`RenderPlan` 在 `note` 之后追加三个带默认值的字段，既有构造调用无需修改：

```cj
public let chartType: String
public let chartSeries: ?SparkSeries
public let chartHeight: Int64

public init(..., note: String,
    chartType: String = "",
    chartSeries: ?SparkSeries = None<SparkSeries>,
    chartHeight: Int64 = 0)
```

`RenderPlanBuilder.build` 增加 `viewportHeight: Int64 = 0` 参数，并：

- `chartType = page.chartType()`；
- `chartSeries = if (series.isEmpty()) None else Some(series[0])`；
- `chartHeight = if (chartType.isEmpty()) 0 else TuiLayout.chartHeight(viewportHeight, metricRows.size)`。

新增 `fprobe/src/tui/TuiLayout.cj`，把右栏几何常量收敛到一处：

```
视口高度 H
body        = H - 2        // 顶部标题 1 行 + 底部状态 1 行
panel inner = body - 2     // 右侧 panel 上下边框
chart       = max(0, inner - metricRows.size - 1)   // 1 行为表格与图表之间的空白
```

`viewportHeight` 的来源：`Painter` 接口新增 `func viewportHeight(): Int64`。

- `FprobePainter` 返回 `Int64(renderer.size().height)`（小于 0 或未知时 0）；
- `NullPainter` 返回 0；
- `RenderLoop.renderOnce()` 在构建 plan 时传入 `painter.viewportHeight()`；
- 测试替身（`RecordingPainter`、`SlowPainter`、`RecordingFrameRenderer` 驱动的 painter）返回可配置高度，默认 24。

这样 `chartHeight` 不是拍脑袋的常量，而是与 `FprobePainter` 实际可用的右栏内部高度同源；`Painter` 仍是渲染抽象，不把 `Rect`/`Buffer` 泄漏给 `RenderPlanBuilder`。

### D5：`FprobePainter` 的绘制顺序与回退

`paintMetrics` 调整为：

1. 逐行画 `metricRows`（不变）。
2. 若 `plan.series` 为空或已到内容区底部 → 返回。
3. 表格与图表之间保留 1 行空白（沿用现有逻辑）。
4. 计算 `available = min(plan.chartHeight, inner.bottom() - y)`。
5. 若 `chartType` 非空、`chartSeries` 为 `Some`、`available >= TuiLayout.MIN_CHART_HEIGHT`：
   - 调用注入的 `chartRender([series], Int64(inner.width), available, chartType)`；
   - `Some(cells)` → `paintCells(...)` 后返回；
   - `None` → 继续走回退。
6. 回退：对 `plan.series` 的**每一条**序列画单行 `Sparkline`（与变更前一致），这样小终端仍能看到所有指标。

`paintCells` 的写入规则：

- 外层行 `0..cells.size`，内层列 `0..cells[row].size`，均按 `inner` 裁剪；
- `symbol.isEmpty()`（宽字符续格）→ 跳过写入，但列号仍然前进；
- 非空 → `buffer.setString(inner.x + col, y + row, symbol, Style().withFg(Color.Green))`；
- 不写背景色、不写 ANSI。

为可测试性，`FprobePainter` 构造增加注入点：

```cj
public init(renderer: FrameRenderer,
    chartRender!: (Array<SparkSeries>, Int64, Int64, String) -> ?Array<Array<String>> = ChartPanel.render)
```

生产路径不传参；用例传入假矩阵，断言写入位置、跳过空串与高度参数，不需要真实终端或真实 f_chart。

宽度回退：`ChartPanel.render` 内部检查 `inner.width < 20` 返回 `None`，painter 自动落到 sparkline；`RenderPlan` 不携带 `chartWidth`，因为宽度可行性在绘制时才知道，且不影响「是否规划图表」的高度判断。

### D6：只画第一序列，但表格保留全部指标

- 右侧指标表仍按 `ProjectionCatalog` 展示该页全部指标当前值。
- 图表只画 `chartSeries`（第一条）。CPU 的使用率、内存的「总量」、磁盘的「最大使用率」、网络的「接收」、服务的「最大延迟」、健康的「堆已用」分别成为各自页面的主图。
- 低高度回退时回到「每序列一行 sparkline」，不丢失信息；这是有意的双模行为，不是遗漏。

### D7：不改 SVG 报告路径

- `ChartRenderer` / `ChartSelector` / `ReportBuilder` 不动；`ChartSpec.fromValues` 的语义不变。
- `ChartSpec.forCells` 只增加一个工厂，`jsonObject()` 仍输出既有 `type`/`series` 结构；TUI 使用空 `title` 与空 `xAxis.labels`，不影响报告。

## Testing

| 层 | 用例 | 断言 |
| --- | --- | --- |
| `TuiCanvas` | `cellSymbolsKeepsColumnWidth` | 3×2 画布、含 CJK，行数 2、每行 3 元素、宽字符续格为 `""` |
| `TuiLineChart` | `drawCellsMatchesDraw` | 40×12 `line`，12 行 × 40 列；逐行过滤空串拼接等于 `draw` 去 ANSI 文本 |
| `TuiLineChart` | `drawCellsHasNoAnsi` | 所有元素不含 `ESC` |
| `TuiBarChart` | `drawCellsMatchesDraw` | 40×12 `bar`，尺寸与符号一致，包含 `█` |
| `TuiBarChart` | `drawCellsRejectsTinyCanvas` | `width=10` → `ChartException(InvalidValue)` |
| `ChartPanel` | `jsonHasNameDataAndSize` | `chartJson` 的 `type`/`width`/`height` 正确，`series[0].name` 与 `data` 等于入参 |
| `ChartPanel` | `emptySeriesOrValuesReturnNone` | `[]`、`values=[]` → `None` |
| `ChartPanel` | `tinySizeReturnsNone` | `19×8`、`20×7` → `None` |
| `ChartPanel` | `lineAndBarProduceMatrices` | line 含 `*`/`o`，bar 含 `█`，尺寸等于 `height×width` |
| `ChartPanel` | `unknownTypeReturnsNone` | `area` → `None` |
| `MetricPage` | `chartTypePerPage` | 六个页面 `line`、磁盘 `bar`、拓扑/告警 `""` |
| `TuiLayout` | `chartHeightUsesViewport` | H=24 且 6 个指标 → 13；H=12 且 6 个 → 1；H=0 → 0 |
| `RenderPlan` | `chartFieldsFollowPage` | CPU 首序列与 `line`；DISK `bar`；TOPOLOGY/ALARMS `None`/`0` |
| `FprobePainter` | `writesFakeCells` | 假矩阵写入 `(inner.x+col, y+row)`，空串列不写、后续列不左移；调用参数高度 = `min(chartHeight, 剩余)` |
| `FprobePainter` | `heightFallbackUsesSparkline` | 12 行终端、CPU 页 → 出现 `▁..█`，假 chart 未被调用 |
| `FprobePainter` | `noneFromChartFallsBack` | 宽度不足或 `chartRender` 返回 `None` → sparkline |
| `RenderLoop` | `passesViewportHeight` | 假 painter 返回 12，断言 builder 生成的 `chartHeight < 8` |

全部用例离线、无真实 TTY、无 ANSI 终端依赖；`f_chart` 既有 SVG 与 TUI 用例必须全绿。

## Risks

- **两处高度计算漂移**：`TuiLayout.chartHeight` 与实际 `inner.bottom() - y` 必须同源。缓解：常量集中在 `TuiLayout`；painter 仍用 `min(plan.chartHeight, 实际剩余)` 并在 `< 8` 时回退；`TuiLayout_test` 覆盖 0、临界 8、指标行数占满三种边界。
- **宽字符写 Buffer 漂移**：矩阵已保留续格为空串，painter 必须「跳过写入但列号前进」。若误用 `filter` 后再写，中文行会左移；用假矩阵（含 `""`）专门断言。
- **f_chart 最小尺寸**：20×8 是 `TuiFrame` 的硬约束；`ChartPanel` 提前返回 `None`，不让异常进入帧循环；窄终端表现与变更前一致。
- **类目轴标签缺失**：60 个点、40 余列的画布上，类目带宽度可能不足 2 列，`TuiFrame` 不画横轴标签，只留 `┬` 与纵轴刻度。这是字符网格的固有限制，文档中说明；趋势与量级仍可读。
- **单序列的局限**：同一页多个指标不会同时出现在图上。这是刻意的单位隔离；如需对比，后续可做「按单位分轴」或交互切换，不在本次范围。
- **每帧分配**：`drawCells` 每帧分配 `W×H` 个字符串（典型 50×13）。在现代终端刷新频率下可忽略；若后续出现性能问题，可在 `ChartPanel` 内按 `(series 引用, width, height, type)` 做一帧缓存，本次不做。
- **`Painter` 接口扩展**：新增 `viewportHeight()` 会破坏外部实现者。`fprobe` 是应用模块，仓库内只有 `FprobePainter`、`NullPainter` 与 3 个测试替身；任务中逐一同步，不保留隐式默认实现以免掩盖遗漏。
- **空/常量数据**：全 0 或全相同值时，`tuiValueRange` 会把范围扩为 1，图表仍可绘制；`ChartPanel` 只拦截空数组，不拦截常量序列。

## Migration

- 无配置迁移、无数据迁移、无依赖变化。
- `Chart.draw`、`TuiLineChart.draw`、`TuiBarChart.draw` 输出不变；既有调用方零改动。
- `RenderPlan` 新字段带默认值；`RenderPlanBuilder.build` 新参数带默认值；未传视口高度的测试与 resident 路径得到 `chartHeight = 0`，行为等同旧版（sparkline）。
- `Sparkline` 保留，作为低高度/窄宽度回退，不删除。

## Open Questions

- 无。图表类型、回退阈值、单序列策略均已在需求底稿中确定；若后续需要「每页可切换指标」，另开变更。
