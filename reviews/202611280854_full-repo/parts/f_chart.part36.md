# f_chart 模块审查报告（第 36/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：14 个实现 `.cj` + 6 个 `*_test.cj`，0 个 `.md`）
- **基线**：工作区快照（`git status` 除审查目录外无改动，HEAD `f309f0b5`；无 diff 可比）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1（分部分报告；仅覆盖 `files/f_chart.part36.txt` 的 20 个文件，合并由主 Agent 完成）

## 发现

### [一般][存量] 百分比堆叠把负值静默丢弃，整列可能什么都不画

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:200-222`（`positive` 只累加 `value > 0.0`，随后 `if (value <= 0.0 || positive <= 0.0) { continue }`）、`f_chart/src/tui/ComboChart.cj:303-325`（同一逻辑的第二份）
- **来源**：存量（快照模式无基线；两段均在快照提交内，`git blame` 追到 `f4e27a68c5` 2026-11-09）
- **判据**：review-checklist §11（数据静默丢失 / 语义与命名不符）、§10 正确性
- **证据**：静态确定 —— 非百分比路径显式维护 `negativeBase`（`TuiBarRenderer.cj:230-234`）来堆负值，百分比路径却直接 `continue`：负值既不进 `positive` 分母，也不产生任何柱体；当某类目全为负值时 `positive == 0`，该列完全没有输出。
- **描述**：`"type":"percent-stacked-bar"` 且数据含负值（如 `[30, -20, 50]`）时，渲染结果只含正值的相对占比（30/80、50/80），负值那一层凭空消失，且没有异常、没有日志；同一份数据在 `"type":"stacked-bar"` 下会正常画出负向柱。调用方无法从输出判断数据被丢弃，属静默错图。现有用例 `TuiBarChart_test.cj` / `TuiComboChart_test.cj` 只喂正数与 null，覆盖不到。
- **建议**：先定口径再改代码——① 若要支持正负混排：`positive += abs(value)`、负值走 `negativeBase` 并按 `abs/positive` 归一化（与 `stacked` 分支结构一致）；② 若不支持：在 `canvas()` 解析阶段对 `PercentStacked` 的负值直接 `throw chartInvalidValue("series.data", "百分比堆叠不支持负值")`。两条都比当前「默默丢」好；改完补一条含负值的用例，断言输出行数与分母口径。

### [一般][存量] 组合图堆叠槽位只按 `stack` 分组、不看 `axis`，跨轴同组系列共用一个比例尺

- **位置**：`f_chart/src/tui/ComboChart.cj:244-259`（分组键 `key = stack.isEmpty() ? name : stack`，未拼 axis）、`f_chart/src/tui/ComboChart.cj:280-282`（`let scale = if (first.rightAxis) { rightScale } else { leftScale }`）、`f_chart/src/tui/ComboChart.cj:229-243`（percent 槽位按 `mode == "percent"` 全并）
- **来源**：存量
- **判据**：review-checklist §11（配置可触发的静默错图）、§10 正确性（布局算法）
- **证据**：静态确定 —— 解析阶段只校验「`axis: right` 必须有 `yAxis2`」（`ComboChart.cj:97-100`），没有校验「同一 stack 组必须同轴」；`buildBarSlots` 合并条件只有 `existing.mode == "stacked" && existing.key == key`，把左右轴的同名/同 stack 系列并进一个槽位；`drawBars` 之后整槽统一用 `first.rightAxis` 决定比例尺，后续成员一律按该比例尺投影。
- **描述**：`[{name:"占比", type:"stacked-bar", stack:"s", data:[10,20]}, {name:"占比", type:"stacked-bar", stack:"s", axis:"right", data:[3000,4000]}]` 这类输入会被接受，但第二个系列按左轴（0–20 量级）投影 3000 → 严重超出绘图区后被 `clampTuiRow` 贴到边界，结果是「一根贴顶的柱」而不是右轴比例下的柱。`percent` 槽位同理（所有 `percent-stacked-bar` 不分轴合并）。输出仍是合法字符画，不报错。
- **建议**：分组键改为 `"${axis}:${key}"`（`axis` 取 `left`/`right`），或在 `buildBarSlots` 前直接拒绝「同 stack 键跨轴」的组合并给出 `chartInvalidValue("series.axis", …)`；percent 槽位同样按轴拆开。补一条左右轴同 stack 的用例，断言两个槽位列不重叠。

### [一般][存量] TUI 画布尺寸只有下限没有上限，`TuiCanvas` 按 `width × height` 直接预分配

- **位置**：`f_chart/src/ChartConfig.cj:180-184`（只校验 `width > 0 && height > 0`）、`f_chart/src/tui/TuiCanvas.cj:33-43`（`while (index < width * height) { list.add(TuiCell()) }` → `toArray()`）、`f_chart/src/tui/TuiFrame.cj:71-73`（只校验 `< 20 / < 8`）
- **来源**：存量
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）、§11（缺少边界校验）
- **证据**：静态确定 —— 分配量 = `Int64(width) * Int64(height)` 个 `TuiCell` 对象（每个含 2 个 `String` 引用 + 1 个 `Bool`，对象头另计），再加一次 `ArrayList → Array` 的等长指针数组拷贝（`TuiCanvas.cj:42`，`toArray` 语义见 `std/collection/collection_package_class.md` 「func toArray(): Array<T>」）。全链路没有任何上限常量或配置项；`ChartConfig` 是 `Chart` 公共接口的唯一入口，外部可传任意 `width/height`。
- **描述**：`{"type":"bar","width":20000,"height":20000}`（合法 JSON、通过全部校验）会尝试构造 4×10⁸ 个 `TuiCell`，按每对象 ≥24B 估算即 ≥9.6GB，单次请求直接 OOM；`width*height` 在 Int64 上溢出时按仓颉默认策略（`docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md:88`「默认采取抛出异常」）抛 `ArithmeticException`，同样是一次请求打崩。仓内现有调用方 `fprobe/src/tui/ChartPanel.cj:77-96` 用终端尺寸（有界），所以实际风险取决于宿主；**若 JSON 的 width/height 来自终端用户或 LLM 输出，本条应升级为「严重」**。
- **建议**：在 `ChartConfig.parse` 或 `TuiFrame.init` 增加上限（例如 TUI 场景 `width ≤ 500 && height ≤ 200`，与终端现实尺寸同阶），超限抛 `chartInvalidValue`；`TuiCanvas` 内部对 `width*height` 做乘法前的除法校验，避免溢出。

### [一般][存量] `tuiStripAnsi` 遇到孤立 ESC（后一字节不是 `[`）进入死循环

- **位置**：`f_chart/src/tui/TuiColor.cj:59-75`，关键在 `else` 分支 `70-72`：`let start = index; while (index < bytes.size && bytes[index] != 0x1B) { index++ }`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 死循环）、§10 正确性
- **证据**：静态确定 —— 进入 `else` 的条件是「`bytes[index]` 不是 ESC，或 ESC 后没有 `[`，或 ESC 是最后一个字节」；当 `bytes[index]` 本身就是 0x1B 时，内层 `while` 的首次判断即为假，`index` 一步都不前进，`builder.append(bytes[start..index])` 追加空串，外层 `while (index < bytes.size)` 于是永久自旋。`0x1B` 后跟 `[` 但序列里没有 `m` 时还有第二个问题：`62-67` 会吞掉其后全部文本（`index` 直接到 `bytes.size`）。
- **描述**：任何含孤立 ESC 的文本（JSON 里写 `"\u001b"` 做标题、或标签里混入控制字符）都会让 `tuiStripAnsi` / `tuiPlainLines` 永久挂死。当前 `tuiStripAnsi` 只被测试（`TuiBarChart_test.cj:47` 等）与 `tuiPlainLines`（`TuiColor.cj:81`）调用，生产渲染路径（`TuiCanvas.render`）不经过它，所以定为「一般」；但它是 `internal` 工具，宿主一旦拿它清洗用户文本就会挂死。
- **建议**：`else` 分支前补 `if (bytes[index] == 0x1B) { index++; continue }`（跳过孤立 ESC），并把「ESC 后无 `[`」与「CSI 无 `m`」都按「跳过一个字节」处理；补一条 `tuiStripAnsi("a\u{1B}b") == "ab"` 的用例，避免以后再靠人眼。

### [一般][存量] 词云 `rotate: -90` 的词条沿基线向上生长，溢出为它预留的行盒

- **位置**：`f_chart/src/WordCloudChart.cj:133-142`（`angle != 0` 时 `boxWidth = fontSize`、`boxHeight = chartTextWidth(...)`）、`f_chart/src/WordCloudChart.cj:163-171`（`kit.text(anchorX, cursorY, …, rotate: angle)`，默认 `anchor: "start"`、`dominant-baseline: middle`）
- **来源**：存量
- **判据**：review-checklist §11（坐标越界）、§10 正确性（布局算法）
- **证据**：静态确定 —— SVG 的 `rotate(a)` 正值顺时针；文本基线方向为局部 +x。`-90°` 把 +x 映射为屏幕 `(0,-1)`，即文字从 `cursorY` **向上**排布，占据 `[cursorY - textWidth, cursorY]`；而布局按 `[cursorY, cursorY + boxHeight]` 记账（`rowHeight`、`cursorY + boxHeight > plot.bottom()` 的裁剪判断都基于后者）。`+90°` 才是向下排布、与记账一致。
- **描述**：配置显式允许 `-90`（`WordCloudChart.cj:64` 校验集合为 `{0, 90, -90}`），但 `-90` 的词条会画到自己行盒之外：首行直接顶到 `plot.y` 以上（进入标题区甚至 `y < 0`），其余行压到上一行的词上——而词云本来的取舍就是「靠盒不重叠」。`boxHeight` 的取值同时参与换行/裁剪，所以底部的溢出判断对 `-90` 完全失效。现有用例 `WordCloudChart_test.cj:75-77` 只统计 `rotate(90 ` 出现 3 次，`-90` 没有任何坐标断言。
- **建议**：`-90` 时锚点取盒底 `cursorY + boxHeight`（或改用 `text-anchor: end`），使文字向上排满同一盒；两条分支统一写成一个局部 `textAnchorY`。补一条 `rotate:[-90]` 的用例，断言输出里该 `text` 的 `y` 等于行盒底部坐标。

### [轻微][存量] 堆叠柱的累积/归一化逻辑在 TuiBarRenderer 与 TuiComboChart 各写一份

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:196-249`（`drawStacked` 的类目循环）与 `f_chart/src/tui/ComboChart.cj:301-351`（`drawBars` 的 `else` 分支）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/跨文件复制）
- **证据**：静态确定 —— 两段逐行同构：`positive` 汇总 → `positiveBase/negativeBase` → `isPercent/ slot.mode == "percent"` 决定归一化 → `from/to` → 两次 `clampTuiRow` → `tuiFillColumn(…, tuiSeriesSymbol(idx))`。差异只有三点：模式用 `enum BarMode` 还是 `String`、外层是「类目 → 系列」还是「槽位 → 类目 → 槽位成员」、符号下标取 `seriesIndex` 还是 `slot.indexes[index]`。上文「负值静默丢弃」因此也存在两份（已合并成一条）。
- **描述**：这一份逻辑已经出现「一处有 `isPercent()` 辅助、另一处靠字符串比较」的表示分歧；本次修负值口径必须同时改两处，漏一处就是两张图行为不一致。不是「为可读性刻意展开」——单段 50 行以上。
- **建议**：在 `TuiChartCommon` 抽 `internal func tuiStackSpan(mode: TuiStackMode, values: Array<?Float64>, from: Int64, to: Int64): Array<(Float64, Float64)>`（返回该区间每层的 `from/to`），调用方只负责取颜色/符号与画列；先迁移 `TuiBarRenderer`，再让 combo 复用。

### [轻微][存量] 「系列数与 labels 对齐」的校验三份、图例名/色收集四份

- **位置**：校验：`f_chart/src/tui/TuiBarRenderer.cj:78-87`、`f_chart/src/tui/ComboChart.cj:111-120`、`f_chart/src/tui/LineChart.cj:45-54`（三处错误文案字面相同：「数据长度必须与 xAxis.labels 一致」）；图例收集：`TuiBarRenderer.cj:105-110`、`ComboChart.cj:166-171`、`LineChart.cj:66-71`、`ScatterChart.cj:44-49`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换类型名）
- **证据**：静态确定 —— 三处都是「`count = max(series.size)` → `tuiResolveLabels(config, count)` → 逐系列 `if (item.values.size != labels.size) throw chartInvalidValue("series.data", "数据长度必须与 xAxis.labels 一致")`」，只有取值字段名（`values` / `points`）不同；四处图例收集都是「`for (item in series) { names.add(item.name); colors.add(item.color) }` + `tuiLegendVisible`」。`TuiChartCommon.cj:36-45` 已经有 `tuiResolveLabels`，说明作者本来就在收敛，只差最后一层。
- **描述**：目前三处等价、无行为漂移，但三处的 `count` 初值写法不同：`TuiBarRenderer` 用 `series[0].values.size`，`ComboChart`/`LineChart` 用 `1`，后续任何一处放宽（例如允许缺省末尾值）都会变成三套契约。属可维护性，不影响当前输出。
- **建议**：`TuiChartCommon` 加 `internal func tuiAlignedLabels(config: ChartConfig, sizes: Array<Int64>): Array<String>`（内部做 max + 全等校验 + 统一错误文案）与 `tuiLegendEntries(series)`；四处直接替换。

### [轻微][存量] 区间夹取函数 4 份实现（`clampTuiRow` / `clampTuiColumn` / `clampWordCoordinate` / `TuiFrame.clampRow`）

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:260-268`、`f_chart/src/tui/LineChart.cj:153-161`、`f_chart/src/WordNetworkChart.cj:237-245`（本部分内三份；范围外另有 `f_chart/src/tui/TuiFrame.cj:239-247`、`f_chart/src/NodeLinkChart.cj:265-275`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 只改边界方法名）
- **证据**：静态确定 —— 四段函数体完全一致：`if (value < min) min else if (value > max) max else value`；差异只有参数类型（`Int64` vs `Float64`）与边界取 `plot.right()/bottom()` 还是直接传 `minimum/maximum`。
- **描述**：同一语义四份实现，新增图型时继续复制第五份；其中 `clampTuiRow`（`TuiBarRenderer`）与 `clampTuiColumn`（`LineChart`）分居两个文件，靠 import 包内可见互相借用，命名也不统一（`Row`/`Column` 表达的是坐标轴，不是夹取语义）。
- **建议**：在 `TuiChartCommon` 提供 `internal func clampInt64(value, minimum, maximum)` 与 `internal func clampFloat64(...)`（或两个 `@Overload`），四处改为调用；跨包外两处可在合并报告里一并列出。

### [轻微][存量] `TuiBarSeries.stack` 解析后从未被读取（死字段）

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:27`（字段声明）、`33`（构造函数赋值）、`73`（`json.string("stack", default: "")`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置字段）
- **证据**：静态确定 —— `grep -rn "\.stack" f_chart/src/tui` 只命中 `ComboChart.cj:43/245`（另一个类 `TuiComboSeries`）与 `TuiBarRenderer.cj:33`；`TuiBarSeries.stack` 在全仓（排除 `.worktrees`）没有任何读取点。`drawStacked` 对同图所有系列一律堆进同一列，从不看该字段。
- **描述**：柱状图族接受 `series[].stack`（与 combo、SVG 版一致）但 TUI 实现静默忽略：写 `"stack":"a"` / `"stack":"b"` 的两组系列仍会被堆到一根柱上，用户以为按组分开。当前 SVG 版 `BarRenderer.render(…, BarMode.Stacked)` 同样不分堆叠组，所以更像「字段尚未接线」而不是单侧漂移。
- **建议**：二选一——① 删掉字段与 `json.string("stack", …)`，并在 `doc/chart-json-spec.md` 写明 TUI/`stacked-bar` 不支持分组；② 按 `stack` 拆多个堆叠组（与 combo 的 `buildBarSlots` 对齐），同时补 SVG 版。不要保持「解析了但不用」。

### [轻微][存量] 柱宽下限 1 列，在系列/类目数接近绘图区列数时柱体互相覆盖

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:163-164`（`slotWidth = band.bandWidth / slotCount`；`barWidth = max(floor(slotWidth * 0.6), 1)`）与 `f_chart/src/tui/ComboChart.cj:276-277`（同型）
- **来源**：存量
- **判据**：review-checklist §11（边界/数值）、§10 正确性（渲染布局）
- **证据**：静态确定 —— `slotWidth = band.bandWidth / slotCount`，`barWidth = max(floor(slotWidth * 0.6), 1)`，所以只要 `slotWidth < 1` 就有 `barWidth(1) > slotWidth`，相邻槽位的 `x` 间距不足 1 列，`tuiFillColumn` 后写覆盖先写。两个触发面：① 60 列画布（`plot` 约 50 列）配 60 个系列时 `slotWidth ≈ 50/60 ≈ 0.83`，全部柱压进同一两列，只剩最后一个系列的符号；② 60 个类目时 `bandWidth ≈ 0.83`，柱宽 1 列同样跨类目重叠。
- **描述**：极端参数（类目数或系列数 ≥ 绘图区列数）下柱状图退化成「一列色块」，且跨类目的柱也会互相覆盖；没有降级策略（省略类目、强制堆叠）也不报错。这不是性能问题，是可视结果失真，属边界补强。
- **建议**：`slotWidth < 1` 时按比例丢弃/合并（例如最多渲染 `floor(bandWidth)` 个槽位并在标题区标注「已省略 N 个系列」），或直接 `throw chartInvalidValue("width", "绘图区过窄，无法容纳 N 个系列")`；`bandWidth < 1` 时同理处理类目。补一条 60 系列 × 60 列的用例断言不会所有柱重叠在同一列。

### [轻微][存量] 词云不校验「词盒 vs 绘图区」，超宽首词越界、超高首词直接输出空图

- **位置**：`f_chart/src/WordCloudChart.cj:133-150`
- **来源**：存量
- **判据**：review-checklist §11（边界越界 / 静默失效）、§3（失败路径当成功）
- **证据**：静态确定 —— 换行条件 `if (cursorX > frame.plot.x && cursorX + boxWidth > frame.plot.right())` 要求「不是本行第一个词」，因此单行首个词 `boxWidth > plot.width` 时永远不换行，直接画到 `plot.right()` 之外（只能靠 SVG viewBox 裁掉）；高度方向 `if (cursorY + boxHeight > frame.plot.bottom()) { break }` 在首词就成立时立刻跳出，输出只有背景与标题——按 `ChartFrame` 的边距算式（`ChartFrame.cj:67-91`：`top = padding.top(24) + titleFontSize+6`，`bottom = padding.bottom(24) + 0`），`height=120` 且带标题时 `plot.height = 120-48-24 = 48 < maxFontSize(默认 64)`，第一个词就会被跳过。
- **描述**：同一张图在「画布够大」时正常，缩到词盒放不下就变成一张空图，调用方无法区分「词表为空」「画布太小」「全部词被裁掉」；越界词条则是渲染到画布外的不可见文本（不计入可见结果却计入 `word-cloud-word` 计数，测试仍会通过）。
- **建议**：进入循环前算 `requiredMin = minFontSize`（含 `chartTextWidth` 的最长词）并与 `plot` 宽高比较，不满足时抛 `chartInvalidValue("width"/"maxFontSize", "画布无法容纳词云")`；单行首词超宽时按 `plot.width` 截断（`tuiTruncate` 同款语义）或缩小字号重排。补一条 `height=120` 的小画布用例，断言抛异常而不是返回空图。

### [轻微][存量] 词云 `type` 别名的三元表达式含恒等分支，且 `type` 被解析两次

- **位置**：`f_chart/src/WordCloudChart.cj:41-43`
- **来源**：存量
- **判据**：review-checklist §1（恒真分支 / 重复读取）、§10 可读性
- **证据**：静态确定 —— `let expectedType = if (chartType == "tag-cloud") { "tag-cloud" } else { "word-cloud" }`，真分支等于 `chartType` 本身，等价于 `chartType == "tag-cloud" ? chartType : "word-cloud"`；紧接着 `ChartConfig.parse(data, expectedType)` 内部又 `requiredString("type")` 重读同一字段（`ChartConfig.cj:171`）。
- **描述**：意图是「`tag-cloud` 是 `word-cloud` 的别名」（`TagCloud_test.cj` 直接构造 `WordCloudChart` 验证这一点），但写法让人以为两个分支都要算，别名机制也只在这一处内联。不影响行为。
- **建议**：改为 `if (chartType == "tag-cloud") { chartType } else { "word-cloud" }` 并加一行注释说明别名来源；若模块已有别名约定（见 `TagCloud_test.cj`、`FunnelAlias_test.cj`），把「接受别名」的判断收敛到一处 helper，`draw` 里只保留一行。

> **范围外提示（不计入统计）**：`f_chart/src/tui/TuiText.cj:65` 的 `tuiPadRight` 全仓无引用；`f_chart/src/tui/TuiFrame.cj:43/47` 的 `TuiRect.centerX/centerY` 无引用（`TuiFrame` 内部只有 `clampRow` 在用）。两者不在本部分文件清单内，留给对应部分处理。

## 优化可行性方案

### [堆内存] `TuiCanvas` 去掉 `ArrayList → toArray` 的一次性中转

- **现状**：`TuiCanvas.cj:36-42` 先 `while (index < width*height) { list.add(TuiCell()) }` 建 `ArrayList<TuiCell>`，再 `list.toArray()` 复制成 `Array<TuiCell>`；峰值同时持有 ArrayList 的底层指针数组与新 `Array`（`toArray` 返回新数组，见 `std/collection/collection_package_class.md:2618`）。80×24 = 1920 个引用 ≈ 15KB 峰值浪费；300×100 = 30000 → ≈ 240KB。
- **方案**：直接用 `Array<TuiCell>(Int64(width * height), { _ => TuiCell() })`（构造签名见 `docs/dev-guide/source_zh_cn/basic_data_type/array.md:46`；同一文档 `:39` 明确 `repeat` 形式**不拷贝**引用，因此不能写 `repeat: TuiCell()`）。
- **预期**：单次绘制少一次 O(w·h) 指针数组拷贝，峰值分配量减半（对象数不变）；大画布一次性请求的瞬时峰值下降最明显。
- **代价**：零语义变化；`Array` 的闭包初始化每元素一次调用，与现在 `while + add` 的调用次数相同。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 单次 `drawCells` 的分配采样，输入 80×24 / 200×60 两档，各取 10 轮中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 词网络：用 `HashMap` 索引替代全部线性 `findWordNode`，并给力导向加规模上限

- **现状**：`WordNetworkChart.cj:199-227` 每轮（共 80 轮）对每条链接做 2 次 `findWordNode` 线性扫描（`215-216`），渲染阶段再对每条链接做 2 次（`144-145`）；`findWordNode` 是 O(N) 字符串比较（`171-178`）。总比较次数 ≈ `80 × 2 × L × N + 2 × L × N`，N=300、L=1000 时约 4.8×10⁷ 次字符串比较；另有 `81-85` 的重复 id 校验是 O(N²)。
- **方案**：解析阶段建 `HashMap<String, Int64>`（id → 下标），`WordNetworkLink` 里直接存 `sourceIndex/targetIndex`；`81-85` 的重复校验改为「`contains` + 插入」一次完成；`runWordForce` 保留 O(N²/2) 的排斥循环（那是算法本身），但迭代次数改为常量上限 + 节点数分档（如 `min(80, max(20, 4000/N))`）。
- **预期**：链接相关比较从 `O(80·L·N)` 降到 `O(80·L)`，N=300/L=1000 时减少约 4.8×10⁷ 次比较；具体端到端降幅需实测（排斥循环仍是 O(80·N²)，Amdahl 上限受它约束）。
- **代价**：`WordNetworkLink` 结构变化（`f_chart` 内部类，无对外契约）；迭代次数按节点数调整会改变大图的布局收敛结果（图会「更团」），需产品确认是否接受。
- **验证**：`cjpm bench -O2`，输入 50/300/1000 节点 × 3 倍链接，记录单次 `draw` 耗时中位数与 P95；同时比对现有 `WordNetworkChart_test.cj` 的节点/连线计数用例输出不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 词云排序从插入排序换成 `std.sort`（先确认稳定性）

- **现状**：`WordCloudChart.cj:197-212` 手写插入排序，最坏 O(n²)（词表本身按权重逆序时），并且先 `ArrayList → toArray` 复制一次；词云常见输入是几百到几千词，n=2000 时移动量可达 2×10⁶ 次。
- **方案**：改用 `std.sort` 按键排序的稳定降序重载：`sort<WordCloudWord, Float64>(arr, key: { w => w.weight }, stable: true, descending: true)`（签名与参数语义见 `std/sort/sort_package_api/sort_package_funcs.md:6-22`，`stable`/`descending` 默认均为 false，必须显式传）。
- **预期**：n=2000 时比较次数从 ~2×10⁶ 降到 ~2×10⁴ 量级；端到端收益取决于排序在 `draw` 中的占比（未测）。
- **代价**：必须先核实当前 SDK 下 `sort` 的稳定性与「相等元素保持输入顺序」一致（现有 `wordCloudOrder` 的注释承诺稳定）；若不稳定需在比较器里带原始下标做 tie-break。
- **验证**：`cjpm bench -O2`，词表 100/1000/5000 三档，同输入取中位数；再用「全部同权重」用例断言输出顺序与改造前逐字节相同。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 力导向布局的 `findWordNode` 线性扫描是词网络绘制的主要耗时 | `WordNetworkChart.cj:199-227`、`144-145` | 自耗时占比（相对 `sqrt`/浮点运算） | `cjprof record` 绘制 300 节点 / 1000 链接的词网络，看 `findWordNode` 与 `String.==` 的 self time |
| 2 | 插入排序在词云词数 > 1000 后成为瓶颈 | `WordCloudChart.cj:202-210` | n = 100/1000/5000 的单次耗时 | `cjpm bench -O2`，固定 6 字符词、随机权重，取中位数与离散度 |
| 3 | `TuiCanvas` 的 `TuiCell` 网格分配（含 `toArray` 副本）占单次绘制分配量的大头 | `TuiCanvas.cj:36-42` | 单次 `draw` 的分配字节数与 GC 次数 | 200×60 画布下 `getAllocatedHeapSize()` 前后差 + `cjprof heap`，跑 10 轮取中位数 |
| 4 | 高系列密度柱状图的覆盖写会退化成「一列」，实际业务中是否会遇到 | `TuiBarRenderer.cj:163-184` | 真实图表的系列/类目分布 | 统计 fprobe/下游实际提交的 chart JSON 中 `series.size` 与 `labels.size` 的分位数（P50/P99） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/WordCloudChart.cj` | .cj | ✅ | 见 #5、#11、#12；`wordCloudOrder`/`wordCloudFontSize` 为 `internal`，有调用者 |
| 2 | `f_chart/src/WordCloudChart_test.cj` | .cj | ✅ | 覆盖字号边界、非法 rotate；未覆盖 `-90`、小画布 |
| 3 | `f_chart/src/WordNetworkChart.cj` | .cj | ✅ | 见优化方案（CPU）与假设 #1；`findWordNode` 越界已由解析期校验兜住 |
| 4 | `f_chart/src/WordNetworkChart_test.cj` | .cj | ✅ | 覆盖悬空连线、重复 id；未覆盖大规模节点 |
| 5 | `f_chart/src/tui/BarChart.cj` | .cj | ✅ | 薄封装，`Chart + TuiCellChart` 双实现，与 `TuiBarRenderer` 对齐 |
| 6 | `f_chart/src/tui/ComboChart.cj` | .cj | ✅ | 见 #1、#2、#6、#7、#10 |
| 7 | `f_chart/src/tui/GroupedBarChart.cj` | .cj | ✅ | 薄封装，仅 `Chart`（无 `drawCells`），与 fprobe 只取 bar/line 一致 |
| 8 | `f_chart/src/tui/LineChart.cj` | .cj | ✅ | 见 #7、#8；类目/数值/时间三轴分支已核对 |
| 9 | `f_chart/src/tui/PercentStackedBarChart.cj` | .cj | ✅ | 薄封装，负值口径问题落在 `TuiBarRenderer` |
| 10 | `f_chart/src/tui/ScatterChart.cj` | .cj | ✅ | 见 #7；无 `drawCells`，`render()` 直出 |
| 11 | `f_chart/src/tui/StackedBarChart.cj` | .cj | ✅ | 薄封装 |
| 12 | `f_chart/src/tui/TuiBarChart_test.cj` | .cj | ✅ | 覆盖负值（`handlesNegative`）但只测非百分比模式 |
| 13 | `f_chart/src/tui/TuiBarRenderer.cj` | .cj | ✅ | 见 #1、#6、#7、#8、#9、#10；`TuiBarSeries.stack` 死字段 |
| 14 | `f_chart/src/tui/TuiCanvas.cj` | .cj | ✅ | 见 #3、优化方案（堆内存）；`plainLines` 仅测试使用（可见性建议，不判死代码） |
| 15 | `f_chart/src/tui/TuiCanvas_test.cj` | .cj | ✅ | 覆盖宽字符、截断、对齐、线段；未覆盖超大尺寸 |
| 16 | `f_chart/src/tui/TuiCellChart.cj` | .cj | ✅ | 对外接口文档与 `drawCells` 契约一致（列数固定、续格空串） |
| 17 | `f_chart/src/tui/TuiCellChart_test.cj` | .cj | ✅ | 逐单元格 vs ANSI 逐行对齐断言扎实 |
| 18 | `f_chart/src/tui/TuiChartCommon.cj` | .cj | ✅ | 见 #7、#8（收敛落点）；`tuiValueRange`/`tuiTicks` 边界已核对 |
| 19 | `f_chart/src/tui/TuiColor.cj` | .cj | ✅ | 见 #4；`tuiContrastColor` 被 `TuiFlameChart.cj:265` 使用（非死代码） |
| 20 | `f_chart/src/tui/TuiComboChart_test.cj` | .cj | ✅ | 覆盖柱+线+散点、右轴、混堆叠；未覆盖跨轴同 stack |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：负值丢弃、跨轴共尺、`-90` 溢出、画布无上限、孤立 ESC 死循环；可读性：#12 与 #7/#8 的命名不统一（`clampTuiRow` vs `clampWordCoordinate`）；设计：渲染器职责清晰（parse→frame→draw 三段），但 `TuiBarRenderer.canvas` 单函数 100 行、`TuiComboChart.draw` 140 行，属可读性偏弱未单列；语言特性：`Option<?Float64>` 全部 `match` 展开，无 `getOrThrow` 滥用，`ArrayList` 索引赋值合法；安全性：所有文本经 `ChartSvgKit.text → SvgBuilder.text`、颜色经 `SvgColor.parse` 校验（`TuiColor.cj:30`），无手拼属性，未发现注入面；资源：本部分无文件句柄/原生内存，全部 GC 托管 |
| §1 死代码 | 1 | 已逐个搜索：`private`（`markContinuation`、`findWordNode`、`placeWordRing`、`runWordForce`、`clampWordCoordinate`、`drawSideBySide`、`drawStacked`、`isPercent`、`drawLines`、`isSupportedComboKind`、`buildBarSlots`、`drawBars`、`drawOverlays`、`buildCanvas`）全部有调用者；`internal` 顶层函数 21 个（`tuiSeriesColor`/`tuiResolveLabels`/`tuiValueRange`/`tuiTicks`/`tuiTickLabelWidth`/`tuiLegendVisible`/`tuiSeriesSymbol`/`tuiFillColumn`/`tuiMinInt64`/`tuiMaxInt64`/`tuiAnsiReset`/`tuiAnsiForeground`/`tuiContrastColor`/`tuiStripAnsi`/`tuiPlainLines`/`clampTuiRow`/`clampTuiColumn`/`wordCloudFontSize`/`wordCloudOrder`/`wordNetworkRadius`/`wordNetworkRingPoint`）在 `f_chart` 内均有引用（`tuiStripAnsi`/`tuiPlainLines` 仅测试 → 可见性建议，不判死代码）；`public` 图表类与 `TuiCellChart` 接口对外可达，不判。命中 1 条：`TuiBarSeries.stack` 读了不用 |
| §2 重复逻辑 | 3 | 已两两比对 20 个文件里 40 余个函数体的「输入-输出-副作用」：命中堆叠累积两份（#6）、系列长度校验三份 + 图例收集四份（#7）、区间夹取四份（#8）；另核对 `cellSymbols`/`plainLines`/`render` 三种输出形态不构成重复，测试辅助 `draw`/`count` 属误报边界（刻意展开的测试准备代码），未计 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`、无 `catch (_: Exception) {}`；`catch` 仅 `TuiColor.cj:32`（转抛 `chartInvalidValue`）与 `TuiColor.cj:49`（颜色无法解析时兜底返回 `#ffffff`，函数注释已说明其用途是保证标签可读）；`case None => ()` 均为可选字段正常缺失（`axis.min/max`、`?Float64` 数据点、`rotate` 缺省） |
| §4 栈溢出 | 0 | 本部分无递归：`wordCloudOrder` 是双层 `while` 插入排序（`WordCloudChart.cj:202-210`）、`runWordForce` 是固定 80 轮的双层循环（`WordNetworkChart.cj:199-234`）、`drawLine` 是 Bresenham `while(true)` 但每步必推进 `currentX/currentY` 且坐标已 clamp（`TuiCanvas.cj:126-140`），均无深度随输入增长的调用链 |
| §5 OOM | 1 | 命中画布尺寸无上限（#3）。其余集合（`words`/`nodes`/`links`/`series`/`cells` 行数组）长度均与输入同阶，绘制结束即释放；`tuiTicks` 返回的 `axis.values` 也无条数上限（`ChartConfig.cj:82` 整段读入，`ChartConfig.cj:85-87` 只把 `tickCount` 抬到 ≥ 2），但内存量级远小于画布、且为一次性数组，未单独成条 |
| §6.1 热点瓶颈 | 0 | `scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`（通用），未提供本模块 profile/bench；热点不成立，已把力导向查找、插入排序、画布分配 3 项列入待验证假设（另 1 项核实柱状图参数分布） |
| §6.2 大粒度锁 | 0 | 本部分无锁：无 `synchronized`/`Mutex`/`Atomic`，所有状态是 `draw` 内的局部对象 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/通道；本部分 9 个 `draw`（词云、词网络、bar/grouped/stacked/percent-stacked/line/scatter/combo）与 2 个 `drawCells` 均为同步纯计算 |
| §6.4 低效算法 | 2 | 静态复杂度可判的两处：插入排序 O(n²)（`WordCloudChart.cj:197-212`）、力导向里 `O(80·L·N)` 的线性查找（`WordNetworkChart.cj:199-227`）；二者均无耗时数据，只进「优化可行性方案（CPU）」与待验证假设，不按缺陷统计 |
| §7 降堆内存方案 | 1 | `TuiCanvas` 的 `ArrayList → toArray` 中转，证据状态 `无基线` |
| §8 降 CPU 方案 | 2 | 词网络索引化、词云排序换 `std.sort`，证据状态均 `无基线` |
| §9 local mode 可行性 | 0 | 本部分唯一函数内大对象是 `TuiCanvas.cells`（`TuiCell` 网格）：逃逸检查通过（只被 `TuiCanvas` 持有，`TuiCanvas` 在 `canvas()/draw()` 内结束生命周期，不返回、不入成员/全局），理论上可做 local region；但 `TuiCell` 是可变引用类型（`var symbol/color/continuation`），需要 local 构造函数与 `split` 级工具链支持，且没有峰值内存前后对照 —— 按 checklist §9「没有前后峰值数据只能是待验证假设」，未列为方案，也不进待验证假设表（缺的是改造前置条件而非测量项） |
| §11 现有代码的 BUG（存量） | 5 | 已核对本部分所有边界：空 `series`/`data`/`words`/`nodes`（均有 `InvalidValue`/`MissingField`）、单元素（`nodes[0].weight`、`ordered[0].weight` 前已校验非空）、除零（`maxWeight-maxWeight`、`maxValue<=0`、`palette` 空、`positive<=0`、`slotWidth` 均有兜底或分支）、`Option` 展开、`clamp` 上下界（`plot` 至少 1×1 由 `TuiFrame.cj:103-105` 保证）；命中负值丢弃、跨轴共尺、画布无上限、孤立 ESC、`-90` 溢出 |
| §12 并发安全与锁粒度 | 0 | 无全局 `var`、无静态可变字段、无单例、无注册表：`WordNetworkNode` 的 `var x/y`、`TuiCell` 的 `var symbol/color/continuation` 都是每次 `draw` 内新建的局部图元，无线程共享路径；`TuiBarRenderer`/`TuiCanvas` 等无字段状态（`static func` 只做纯计算），按「线程封闭」判安全 |
| §14 功能完备性与 README 覆盖 | 2 | 本部分无 `.md`，无法做 README 对照（模块 README/doc 在其他部分）；命中：`TuiBarSeries.stack` 接线缺失（#9）、`TuiCellChart` 只有 `TuiBarChart`/`TuiLineChart` 两个实现（`grep` 确认，其余 TUI 图只能走 ANSI）。后者无承诺源（接口注释只说宿主需要时可用），未按缺陷计，仅记录为信息 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分无 `.md`，§13 不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 12 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

本部分（词云 / 词网络 + 7 个 TUI 图表及其公共层）是「纯计算 + 自绘字符网格」的形态：没有全局可变状态、没有锁、没有递归、没有资源句柄，所有输入都走 `ChartJson` 的带路径校验，非法输入基本都能抛 `InvalidValue`/`MissingField`；`TuiCellChart` 的「逐单元格 vs ANSI 逐行一致」断言也是同类项目里少见的扎实写法。基础质量明显高于平均水平，本部分没有阻塞级缺陷。

风险集中在三处：

1. **数值口径不统一**。百分比堆叠对负值的处理与普通堆叠不同（静默丢弃），而 combo 复制了同一份逻辑，于是「同一份数据换一个 `type` 就少一层柱」。这条与下一条是本部分最值得先修的：它不报错、不崩溃，只让读图结论错。
2. **组合图的槽位分组只看 `stack` 不看 `axis`**，左右轴同组时整槽按首系列的比例尺投影，属于「配置可触发的静默错图」；现有用例根本没有跨轴组合，测试拦不住。
3. **边界与资源**。TUI 画布 `width×height` 没有任何上限，`Chart` 是对外接口，一次超大尺寸请求就能把进程打到 OOM；词云的 `-90` 旋转与「盒 vs 绘图区」两处只在极端参数下暴露，属可排期的边界补强。`tuiStripAnsi` 的死循环只影响测试工具链，但改起来只要一行。

可排期的还有重复逻辑收敛（堆叠累积两份、长度校验三份、夹取四份）：它们的收益是可维护性——本次修「负值口径」必须同时改两处，已经能说明问题。所有性能结论（插入排序、力导向线性查找、画布分配）本轮都没有 `-O2` 前后对照，只进了「优化可行性方案（无基线）」与「待验证假设」，不作为缺陷统计。
