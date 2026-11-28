# f_chart 模块审查报告（第 32/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：10 个 `.cj` + 10 个 `*_test.cj`；本部分无 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染 / 布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1-part32（分部分报告，由主 Agent 合并进 `f_chart_v2.md`；统计只覆盖本部分）

## 发现

### [严重] PictogramChart 图标数量由不可信输入放大，循环无上限

- **位置**：`f_chart/src/PictogramChart.cj:123-139`（`while (drawn < iconCount)` 循环）、`f_chart/src/PictogramChart.cj:145-150`（`pictogramCount`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（按不可信值放大输出、无拒绝路径）
- **证据**：静态确定 —— `unit` 只校验 `> 0`（`:47-50`），`value` 只校验 `>= 0`（`:88-90`），`iconCount = Int64(ceil(value / unit))`，随后该值直接决定 `while` 迭代次数，每次迭代都向 `SvgBuilder` 追加一个 `SvgPath` 元素。
- **描述**：`value` 与 `unit` 都是 JSON 里的用户输入，比值无任何上限。以 `{"value": 1000000, "unit": 0.000001}`（约 60 字节输入）为例，`iconCount = 1e12`：循环 10^12 次、向 DOM 追加 10^12 个路径元素，必然长时间不返回并 OOM；`columns` 只影响排布，不构成上限（`:51-55`）。`unit` 极小值完全合法（只判 `> 0`），因此这是一条"一个字段即可触发的拒绝服务路径"，而不是理论边界。
- **建议**：加显式上限（如 `MAX_ICONS = 10000`）并在超限时抛 `chartInvalidValue("unit", "图标数量超过上限")`；或按画布可容纳格数（`columns × 可用行数`）截断并对截断给出标注。

### [一般] PieChart 单扇区 100% 时扇区不可见

- **位置**：`f_chart/src/PieChart.cj:113-130`（`angle` / `endAngle` / `largeArc` / 弧路径拼接）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 退化输入未处理）；SVG 1.1 §F.6.5.4「若弧的起点与终点相同，等价于完全省略该弧段」
- **证据**：静态确定 —— 只有一个类目时 `fractions[0] = 1.0`，`sweep = 360.0`，`endAngle = angle + 360`；`startX/startY` 与 `endX/endY` 只差 `cos/sin` 在 `1e-16` 量级的浮点噪声，而 `formatSvgNumber` 按 6 位小数裁剪（`f_svg/src/SvgNumber.cj:39-48`），两者格式化后是完全相同的数字串，弧段按规范被省略，路径退化为 `M 圆心 L 端点 Z` 的零面积图形。
- **描述**：`{"type":"pie","series":[{"data":[{"name":"A","value":1}]}]}` 输出 SVG 里 `pie-slice` 元素存在但不可见（画布上只剩一条从圆心到圆周的线），用户会认为图表渲染失败。两个 50% 扇区、四个扇区等常规输入不受影响，`PieChart_test.cj` 也没有单扇区用例。
- **建议**：`sweep >= 359.999` 时改用两个半圆弧（或直接输出 `<circle>`），并补一条"单类目 100%"用例断言可见扇区。同源代码：`DonutChart.cj:108-115` 是同一份写法（范围外提示，未计入本部分统计）。

### [一般] 画布尺寸只校验 > 0，饼图半径可为负、平行坐标绘图区可反转

- **位置**：`f_chart/src/PieChart.cj:109-112`、`f_chart/src/ParallelCoordinatesChart.cj:194-197`；根因在 `f_chart/src/ChartConfig.cj:182-184`（只判 `width/height > 0`，属其他部分，仅作根因引用）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 → 非法几何值）
- **证据**：静态确定（算式可复现），渲染后果需实测（不同渲染器对非法半径的容错不同）
- **描述**：
  - 饼图：默认 `padding = 24` 时 `radius = min(w-48, h-88)/2 - 20`，因此 `w < 88` 或 `h < 128` 时 `radius < 0`，路径写出 `A -14 -14 ...`。SVG 规定半径为负属错误，元素不渲染 → 整张饼图静默消失。
  - 平行坐标：`right - left = w - 128`、`bottom - top = h - 152`，`w < 128` 或 `h < 152` 时 `step` 与 `bottom - top` 为负，维度轴从右往左排、归一化方向翻转，输出是镜像/倒置的图。
  - 同一根因下，`ChartFrame`（`ChartFrame.cj:91` 的 `plot` 宽高）也会为负，本部分 Pareto / PDP / PR / Probability / QQ 的 `rect`、`line`、`circle` 坐标随之非法。
- **建议**：`ChartConfig.parse` 增加最小画布校验（例如 `width >= 200 && height >= 150`，或按 padding + 轴标签宽度动态判断），或在各图对 `radius` / `plot.width` / `plot.height` 取 `max(0.0, ...)` 并对退化情形给出明确异常。

### [一般] PdpChart / PrChart 的 x 轴被镜像（数值从右向左增大）

- **位置**：`f_chart/src/PdpChart.cj:132`、`f_chart/src/PrChart.cj:130`
- **来源**：存量
- **判据**：review-checklist §11（语义与实现不符）
- **证据**：静态确定 —— `LinearScale.scale` 的公式是 `bottomPixel - (v-min)/span*(bottomPixel-topPixel)`（`f_chart/src/ChartScale.cj:36-43`）。传入 `(plot.x, plot.right())` 时 `scale(min) = plot.right()`、`scale(max) = plot.x`，即最小值落在右端。同模块 15 张图用的是 `(plot.right(), plot.x)`（如 `ProbabilityChart.cj:110`、`QQChart.cj:110`、`LineChart.cj:177`），该写法 `scale(min) = plot.x`，方向正确。
- **描述**：PDP 的特征值（`x`）与 PR 的召回率（`x`）都会左高右低显示；`drawXAxisNumeric` 用同一个 `xScale` 定位刻度（`ChartFrame.cj:291-307`），所以刻度标签也随之为倒序（如从左到右 70、60、…、20）。图表内部自洽（点、线、刻度一致倒置），因此现有用例（只数图元个数、只查字符串）全部通过，问题不会被测试发现。
- **建议**：改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)`；补一条断言"首刻度像素 < 末刻度像素"的用例。范围外提示：`RocChart.cj:123`、`VolcanoChart.cj:156`、`ManhattanChart.cj:165`、`ResidualChart.cj:112`、`SurvivalChart.cj:168` 等 15 个文件采用同一写法，建议由主 Agent 合并为一条模块级问题。

### [一般] `cumulativeFormat` 文档化但实现里被硬编码取代

- **位置**：`f_chart/src/ParetoChart.cj:171-179`（`"${Int64(tick)}%"`）；承诺源 `f_chart/doc/chart-json-spec.md:1615`
- **来源**：存量
- **判据**：review-checklist §14.1（接线缺失：配置项从未被读取）/ §13（文档与实现不符）
- **证据**：静态确定 —— 全仓 grep `cumulativeFormat` 只命中 `doc/chart-json-spec.md:1615` 一处，`src/` 内零引用；右侧百分比标签固定写 `Int64(tick)%`，也不走 `chartFormatTick`。
- **描述**：文档声明 `cumulativeFormat`（默认 `{value}%`），用户按文档传 `"cumulativeFormat": "{value} %"` 或 `"{value} pct"` 时不会有任何效果，也不会报错（被静默忽略），属于"读了不用"的契约缺失。
- **建议**：`let cumulativeFormat = root.string("cumulativeFormat", default: "{value}%")`，用 `chartFormatTick(tick, cumulativeFormat)` 出标签；或者删除文档字段并写明百分比标签固定格式。

### [一般] `pie.innerRadius` 文档化但 PieChart 完全不读取

- **位置**：`f_chart/src/PieChart.cj:42-151`（无 `innerRadius` 读取）；承诺源 `f_chart/doc/chart-json-spec.md:1248`
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现）/ §13
- **证据**：静态确定 —— `innerRadius` 在 `src/` 只出现在 `DonutChart.cj:73-75,126,142` 与 `GaugeChart.cj:116`，`PieChart` 内零命中；`draw` 只用 `centerX/centerY/radius` 画实心扇区。
- **描述**：文档把 `innerRadius`（默认 0）列为 `pie` 的专属字段，实现忽略该字段：用户对 `pie` 传 `0.5` 期望得到环形图，实际得到实心饼图，且无告警。默认值 0 恰好与实心实现一致，所以只有显式传参的用户会踩到。
- **建议**：`pie` 读取并按比例挖空（与 `DonutChart` 复用同一段逻辑），或把文档改成"仅 `donut` 支持 `innerRadius`"。

### [一般] QQChart 与 ProbabilityChart 整段复制，只改类型名与 class 前缀

- **位置**：`f_chart/src/QQChart.cj:31-194` vs `f_chart/src/ProbabilityChart.cj:31-194`；`QQChart.cj:156-193` vs `ProbabilityChart.cj:156-193`（`sortValues`、`resolveRange` 完全相同）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 字面量的复制）
- **证据**：静态确定 —— `diff` 两段 164 行代码只有 5 处不同：`ChartConfig.parse` 的类型串（`qq` / `probability`）、系列数量校验的错误文案、`qq-line` → `probability-line`、`qq-point` → `probability-point`；`sortValues`（16 行）与 `resolveRange`（21 行）逐字相同。连类注释都一致（两文件 `:23-27`）。规范自己也承认"`probability` 与 QQ 图同形"（`doc/chart-json-spec.md:1729`）。
- **描述**：两份实现共享 90% 以上语义，任何一侧的修复（例如上面第 3、4 条的画布与轴问题、后续加 `innerRadius`/分位数算法调整）都只改一半，形成行为漂移；测试也各写一套，漂移不会立刻暴露。这是"表现形式相同的重复"，不是两个需要独立演进的能力。
- **建议**：抽 `internal class QqPlotRenderer { static func render(data, expectedType, classPrefix): String }`，两个 Chart 退化为参数转发——与 M75/M4 用 `BarRenderer.render(data, "percent-bar"|"percent-stacked-bar", BarMode.PercentStacked)` 的既有做法一致；差异点（类型串、文案、class 前缀）显式参数化。

### [轻微] 两个只写不读的字段

- **位置**：`f_chart/src/PieChart.cj:24-32`（`PieSlice.value`，写于 `:80`，全文只读 `slices[index].name` `:138`）；`f_chart/src/ParallelCoordinatesChart.cj:37-46`（`ParallelSeriesData.name`，构造于 `:123`，`:133/:238/:242` 只用 `rows` 与 `color`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— 两个文件内 grep 字段名，`PieSlice.value`、`ParallelSeriesData.name` 只出现在构造与声明处，无任何读取点；两个类都是 `internal`，成员不可对外访问。
- **描述**：`PieChart` 的占比计算另用平行数组 `values`（`:63,84`），`PieSlice.value` 纯冗余；`ParallelCoordinatesChart` 的系列名既不进图例也不进任何标注，`name` 解析后即丢弃（同时 `:94` 的 `name` 局部量只用于构造）。
- **建议**：`PieSlice` 只保留 `name`；`ParallelSeriesData` 删 `name`（若将来要做图例再按需补回）。

### [轻微] 插入排序在 9 处重复实现

- **位置**：`f_chart/src/ParetoChart.cj:202-217`（`paretoOrder`，降序下标）、`f_chart/src/PrChart.cj:197-212`（`sortPoints`，按 `x` 升序）、`f_chart/src/QQChart.cj:156-171` 与 `f_chart/src/ProbabilityChart.cj:156-171`（`sortValues`，Float64 升序）、`LiftChart.cj:203-218`（`sortLiftPoints`，被本部分 `PdpChart.cj:62` 复用）、`BoxScatterChart.cj:245`、`SwarmChart.cj:218`、`ViolinBoxChart.cj:298`、`ViolinChart.cj:271`（均为 `sortValues`）
- **来源**：存量
- **判据**：review-checklist §2（换算/算法复制）
- **证据**：静态确定 —— 9 个函数体都是"`for (i in 1..size) { j=i; while (j>0 && cmp(a[j], a[j-1])) swap; j-- }"的同一插入排序，只差比较键（`values[...]` / `sorted[j].x` / `sorted[j][0]`）与升降方向。
- **描述**：算法一致但实现散落 9 处：一处修正（例如改成稳定排序或换 O(n log n)）无法覆盖其余；`PdpChart` 跨文件复用 `LiftChart` 的 `sortLiftPoints`，也让"PDP 依赖 Lift"这种无意义耦合固化。
- **建议**：抽 `internal func chartSortDoubles(values: Array<Float64>, descending!: Bool = false): Array<Float64>` 与 `chartSortIndices(values: Array<Float64>, descending!: Bool = false): Array<Int64>` 放 `ChartScale.cj`（同层工具），`sortPoints`/`sortLiftPoints` 用索引版本；合并前先列出差异（升降序、比较键、稳定性），把差异显式参数化。复杂度问题见「待验证假设」第 1 条。

### [轻微] 测试 `count` helper 在 106 个 `*_test.cj` 中逐字复制，且每次命中分配数组

- **位置**：本部分 10 个测试文件的 `count`：`PairedLineChart_test.cj:28-36`、`ParallelCoordinatesChart_test.cj:28-36`、`ParetoChart_test.cj:29-37`、`PdpChart_test.cj:28-36`、`PercentBarChart_test.cj:28-36`、`PercentStackedBarChart_test.cj:29-37`、`PictogramChart_test.cj:28-36`、`PieChart_test.cj:29-37`、`PrChart_test.cj:28-36`、`ProbabilityChart_test.cj:28-36`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制，跨文件）+ §8（每次命中的无谓分配）
- **证据**：静态确定 —— 全模块 `grep "private func count(svg: String, needle: String): Int64"` 命中 106 个文件，函数体逐字相同（108 处 `from = index + needle.toArray().size`，无第二种写法）。
- **描述**：`needle.toArray()` 每命中一次就把 needle 复制成一个字节数组，只为取长度；单测里 `count` 被反复调用（每张图 3–6 次、每次扫整段 SVG），是纯浪费的分配。106 份副本也意味着改判定逻辑要改 106 处。测试准备代码本身通常不判重复，但"同一 9 行函数复制 106 份且带反模式分配"已超出可读性展开的范畴。
- **建议**：抽到模块内测试工具文件（如 `ChartTestUtil.cj`，`internal func countOccurrences(haystack: String, needle: String): Int64`），内部预取 `needle.size`；顺带把 `draw(json)` 包装同质化（本部分 10 个 `draw` 也只有类名不同）。

### [轻微] PictogramChart 未知 icon 名静默当 path 输出

- **位置**：`f_chart/src/PictogramChart.cj:153-190`（`case _ => icon`）
- **来源**：存量
- **判据**：review-checklist §3（静默降级，无兜底提示）
- **证据**：静态确定 —— `icon` 只校验非空（`:44-46`），除 `circle`/`square`/`person` 外一律原样作为 `d` 属性值；`SvgBuilder.attr` 的转义由 `SvgWriter` 负责（`f_svg/src/SvgAuthoringBuilder.cj:255-259`，不会造成注入），但拼错的形状名会形成非法路径。
- **描述**：`"icon": "persn"` 这类拼写错误不会报错、不会落日志，输出里每个图标都是一个空路径元素（`pictogram-icon` 计数正常、画面全空），排查成本高；文档把"或 SVG path 字符串"写成同一字段，用户无法区分"名字拼错"与"路径写错"。
- **建议**：仅当字符串以路径命令（`M`/`m`/`L`/`C`/`Z` 等）开头才按原始 path 处理，否则抛 `chartInvalidValue("icon", "未知图标")`。

### [轻微] ParetoChart 的"总和必须大于 0"校验重复，关闭累计线时仍做无效计算

- **位置**：`f_chart/src/ParetoChart.cj:91-93` 与 `f_chart/src/ParetoChart.cj:225-227`（同一句文案 `"总和必须大于 0"` 两处）；`:84`（`showCumulative` 尚未读取就调用 `paretoCumulative`）
- **来源**：存量
- **判据**：review-checklist §2（同一错误文案复制）/ §1（无效计算）
- **证据**：静态确定 —— `paretoCumulative` 在 `total <= 0.0` 时抛同文案异常，`draw` 内 `maxValue <= 0.0` 再抛一次；`let showCumulative = root.bool(...)` 在 `:85` 才读取，而 `:84` 已经算完累计值。
- **描述**：两处同义校验的触发顺序不同（`total` 与 `max`），错误路径重复；`showCumulative: false` 的图仍付出一次 O(n) 累计计算与一次 `sortedValues.toArray()` 拷贝。
- **建议**：只保留 `paretoCumulative` 内的校验（或先算 `total` 再分流），把 `paretoCumulative` 调用移进 `if (showCumulative)` 分支。

### [轻微] ParallelCoordinatesChart 允许 `data` 为空数组，与同模块校验口径不一致

- **位置**：`f_chart/src/ParallelCoordinatesChart.cj:96-125`（`data` 元素逐个解析，未校验非空）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验；同类图口径不一致）
- **证据**：静态确定 —— `json.requiredArray("data")` 后直接 `for (row in dataArray.getItems())`，空数组得到 `rows = []`，继续参与维度推断（`hasData` 保持 `false`，范围退化为 0–1）并输出空图；本部分 Pareto（`:49-51`）、Pie（`:59-61`）、PR（`:56-58`）、Probability（`:50-52`）、PDP（`:46-48`）对空 `data` 一律抛 `chartInvalidValue`。
- **描述**：同一份数据形状在 6 张图里有 5 张拒绝、1 张接受，调用方无法用统一规则做前置校验；空输入得到"合法但空白"的 SVG，比抛错更难排查。
- **建议**：补 `if (dataArray.getItems().isEmpty()) { throw chartInvalidValue("${path}.data", "数据不能为空") }`，与其余图对齐。

## 优化可行性方案

### [CPU] `normalQuantile` 每次调用分配 4 个系数数组

- **现状**：`f_chart/src/QQChart.cj:220-235` 在函数体内构造 `a`（6 元素）、`b`（5）、`c`（6）、`d`（4）四个 `Array<Float64>`；`qqTheoryQuantiles`（`:197-209`）对每个样本调用一次 `normalQuantile`，因此 `n` 个样本 = `4n` 次小数组分配（n=10k → 4 万次；n=100k → 40 万次），且 `ProbabilityChart` 走同一条路径。
- **方案**：把 4 个数组提为文件级 `let QQ_ACKLAM_A/B/C/D`（只读常量，构造一次），函数内按名引用。
- **预期**：每张 QQ / probability 图少 `4n` 次分配与对应 GC 压力；分配次数按 `n` 线性下降（具体端到端降幅需测）。
- **代价**：约 168 B 常驻；无常量语义变化，系数拼写必须逐字核对（现有单测只校验 0.5 / 0.975 两个点，建议补 `p=0.001`、`p=0.999` 的边界值）。
- **验证**：`cjpm bench -O2` 同输入对照 `n = 1k / 10k / 100k` 的 `draw` 中位数与离散度，或用 `cjprof heap` 看分配次数；不接受单次最快值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `sortValues` 的 array → ArrayList → array 双拷贝

- **现状**：`f_chart/src/QQChart.cj:156-171`、`f_chart/src/ProbabilityChart.cj:156-171`、`f_chart/src/PrChart.cj:197-212` 都把入参 `Array` 逐元素复制进 `ArrayList`，排序后再 `toArray()`；调用点本身已先做过 `values.toArray()`（`QQChart.cj:72`、`ProbabilityChart.cj:72`），因此同一份数据在峰值时存在 3 份（原 ArrayList 内部数组、副本 Array、排序用 ArrayList 内部数组）。
- **方案**：排序函数直接接收 `Array<Float64>` / `Array<PrPoint>` 并在其副本上原地排序，去掉 ArrayList 中转；若 std 提供 `Array.sort`/`sortBy` 优先复用。
- **预期**：每张图少 1–2 次 n 元素分配（n=10k `Float64` 约 80 KB，`PrPoint` 引用数组约 80 KB）。
- **代价**：原地排序会改变入参数组顺序，需确认调用方不再使用原顺序（当前调用点都是刚拷出的局部副本，安全）；语义（稳定性）需与现实现对齐。
- **验证**：同输入下 `getAllocatedHeapSize()` 峰值与 `draw` 耗时对照，多轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 平行坐标每行的多次中间复制

- **现状**：`f_chart/src/ParallelCoordinatesChart.cj:104-120` 每行先用 `ArrayList<Float64>` 累积再 `toArray()`，`:123` 再 `rows.toArray()`，`:86` 的 `series` 也是 `ArrayList`；`values` 的扩容副本与 `toArray()` 副本同时存活，峰值约为最终数据的 2–3 倍。
- **方案**：维度数已知（`dimensionCount`），直接 `Array<Float64>(dimensionCount, repeat: 0.0)` 按索引写入，长度不符再抛错；`series`/`rows` 改为按输入长度预分配的数组。
- **预期**：`n` 行 × `m` 维少 1 份中间副本（约 `n·m·8 B`），峰值内存按行数线性下降。
- **代价**：需要先取长度再写入，代码略增；错误路径文案不变。
- **验证**：`n = 1k / 10k` 行、`m = 4` 维时的峰值 heap 与 RSS 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑，不作为缺陷，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序 O(n²) 在类目数 5k+ 时成为 `draw` 主要耗时（Pareto 排序 + 累计） | `ParetoChart.cj:202`、`PrChart.cj:197`、`QQChart.cj:156` | 函数自耗时占比、n 与耗时曲线 | `cjprof record` 跑 pareto / pr，输入 1k / 5k / 20k 条，`-O2`，同机对照 |
| 2 | 每张图把整棵 `SvgBuilder` DOM 与输出串全量物化，峰值内存 ≈ 图元数 × 单元素开销 | 本部分全部 `draw`（如 `PictogramChart.cj:99-140`、`QQChart.cj:117-153`） | 峰值 heap/RSS 与图元计数 | 1 万点散点/1 万图标各跑 100 次，取 `getAllocatedHeapSize()` 峰值与 RSS 中位数 |
| 3 | 106 份 `count` helper 的 O(n·m) 扫描占测试总时长可观比例 | 本部分 10 个 `*_test.cj` 的 `count` | 测试总耗时、`count` 调用次数与单次扫描长度 | 对 `f_chart` 跑 `cjpm test` 分段计时，统计 `count` 调用总数与平均 SVG 长度 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/PairedLineChart_test.cj` | .cj | ✅ | 仅测试；`count` helper 重复（见发现 #10），被测实现不在本部分 |
| 2 | `f_chart/src/ParallelCoordinatesChart.cj` | .cj | ✅ | 死字段 #8、画布边界 #3、空 data 校验 #13 |
| 3 | `f_chart/src/ParallelCoordinatesChart_test.cj` | .cj | ✅ | 覆盖归一化 / 范围推断 / 行长度 / 非数值 / 缺 series；无单维度、空 data 用例 |
| 4 | `f_chart/src/ParetoChart.cj` | .cj | ✅ | `cumulativeFormat` 未接线 #5、重复校验 #12、排序重复 #9 |
| 5 | `f_chart/src/ParetoChart_test.cj` | .cj | ✅ | 覆盖柱/线/点计数、降序、累计、负值、长度不一致；无 `cumulativeFormat` 用例 |
| 6 | `f_chart/src/PdpChart.cj` | .cj | ✅ | x 轴镜像 #4、复用 `LiftChart.sortLiftPoints`/`VolcanoChart.volcanoNumber` |
| 7 | `f_chart/src/PdpChart_test.cj` | .cj | ✅ | 只断言字符串与图元计数，未校验坐标，故 #4 未被发现 |
| 8 | `f_chart/src/PercentBarChart.cj` | .cj | ✅ | 31 行薄封装，转发 `BarRenderer.render(..., BarMode.PercentStacked)`；文档声明为别名，不判重复 |
| 9 | `f_chart/src/PercentBarChart_test.cj` | .cj | ✅ | 覆盖 12 段柱、图例、类目、类型不匹配、长度不一致 |
| 10 | `f_chart/src/PercentStackedBarChart.cj` | .cj | ✅ | 与 #8 仅类型串不同（文档 `doc/spec/add-f-chart-percent-bar/design.md:9` 声明"其余行为完全一致"） |
| 11 | `f_chart/src/PercentStackedBarChart_test.cj` | .cj | ✅ | 覆盖 4 段、归一化、0–100 轴、零类目跳过、可解析性 |
| 12 | `f_chart/src/PictogramChart.cj` | .cj | ✅ | OOM #1、未知 icon 静默降级 #11 |
| 13 | `f_chart/src/PictogramChart_test.cj` | .cj | ✅ | 覆盖计数、三种内置图标、自定义 path、零 unit、空 icon；无数量上限用例 |
| 14 | `f_chart/src/PieChart.cj` | .cj | ✅ | 单扇区 #2、负半径 #3、死字段 #8、`innerRadius` 未实现 #6 |
| 15 | `f_chart/src/PieChart_test.cj` | .cj | ✅ | 覆盖四扇区、百分比、占比、负值、零总和、多系列；无单扇区 100% 用例 |
| 16 | `f_chart/src/PrChart.cj` | .cj | ✅ | x 轴镜像 #4、排序双拷贝（优化 #2） |
| 17 | `f_chart/src/PrChart_test.cj` | .cj | ✅ | 覆盖曲线/点/基线、AP、越界；未校验坐标方向 |
| 18 | `f_chart/src/ProbabilityChart.cj` | .cj | ✅ | 与 QQChart 整段重复 #7 |
| 19 | `f_chart/src/ProbabilityChart_test.cj` | .cj | ✅ | 覆盖点/线计数、三种分布、未知分布、非数值、空数据 |
| 20 | `f_chart/src/QQChart.cj` | .cj | ✅ | 重复 #7、`normalQuantile` 每调用分配（优化 #1）；`qqTheoryQuantiles`/`qqFitLine`/`normalQuantile` 被概率图复用 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_chart.part32.txt` 一行不差）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#2 #3 #4；设计：`PdpChart` 复用 `LiftChart`/`VolcanoChart` 的 helper（命名与归属不符，已在 #9 建议中提及）；语言特性 / 可读性：无额外命中；安全性：`pictogram.icon` 原样进入 `d` 属性但由 `SvgWriter` 转义（`SvgAuthoringBuilder.cj:255-259`），无注入 |
| §1 死代码 | 1 | `PieSlice.value`、`ParallelSeriesData.name` 只写不读（#8）；已逐个核对本部分全部 `internal` / `private` 符号：`parallelNormalize`、`paretoOrder`、`paretoCumulative`、`pictogramCount`、`pictogramIconPath`、`pieFractions`、`formatPercent`、`qqTheoryQuantiles`、`normalQuantile`、`qqFitLine` 均有调用者（含跨文件），`resolveYRange` / `sortPoints` / `sortValues` / `resolveRange` 均为本文件内被调用；`public class *Chart` 属对外 API，不判 |
| §2 重复逻辑 | 4 | #7 QQ/Probability 整段复制、#9 插入排序 9 处、#10 测试 helper 106 份、#12 同一错误文案两处；另已核对 `PercentBarChart` 与 `PercentStackedBarChart` 为文档声明的别名（`doc/spec/add-f-chart-percent-bar/design.md:9`），不算缺陷 |
| §3 空实现 | 1 | #11 未知 icon 静默降级为 path；本部分无空函数体、无 `TODO`/`FIXME`，无 `catch {}` 吞异常 |
| §4 栈溢出 | 0 | 本部分无递归（`normalQuantile` 为多项式逼近、`qqFitLine`/排序均为迭代）；无自引用结构遍历 |
| §5 OOM | 1 | #1 图标数按 `value/unit` 无界放大；其余图表的容器规模均与输入数组长度同阶，未见按报文字段预分配 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，热点结论不成立，已列入「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池使用 |
| §6.4 低效算法 | 0 | 插入排序 O(n²) 是大 n 下的疑点，但无耗时数据，降级进「待验证假设」#1；`paretoOrder` 之外的复杂度均为 O(n·m) 且与输入同阶 |
| §7 降堆内存方案 | 2 | 排序双拷贝、平行坐标行复制（均标注 `无基线`） |
| §8 降 CPU 方案 | 1 | `normalQuantile` 系数数组提升为常量（`无基线`）；测试 `count` 的 `needle.toArray()` 并入 #10 |
| §9 local mode 可行性 | 0 | 不适用：`docs/LocalMode.md:442` 已判定 f_chart「SVG DOM → toSvgString 是最大临时区，但要 local 化必须先全链 local 化 f_svg/f_xml，且 Chart.draw 是接口实现，当前不做」；`docs/LocalMode-O2-Plan.md:124` 亦判定 f_chart 小对象收益为负。无峰值内存前后数据，不提出改造 |
| §11 现有代码的 BUG（存量） | 3 | #2 单扇区弧退化、#3 画布无下限导致负半径/反转、#4 x 轴镜像；已逐函数核对边界（空数组、单元素、全零、负值、NaN 输入路径），其余分支均有显式校验 |
| §12 并发安全与锁粒度 | 0 | 本部分每个 `*Chart` 都是无字段（仅 `init() {}`）的纯函数式 `draw`，全部状态为局部变量；已确认模块内无全局 `var` / 静态可变成员、`chartTextWidth` 等 helper 无缓存表，故无共享可变状态 |
| §14 功能完备性与 README 覆盖 | 2 | #5 `cumulativeFormat`、#6 `pie.innerRadius` 均"文档承诺、实现未接线"；其余公开类型（`PercentBarChart`、`PercentStackedBarChart`、`PictogramChart`、`PieChart`、`PrChart`、`ProbabilityChart`、`QQChart`、`ParetoChart`、`PdpChart`、`ParallelCoordinatesChart`）在 `README.md` 与 `doc/chart-json-spec.md` 均有条目 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单无 `.md`；文档侧只做了与实现对齐的抽查（`doc/chart-json-spec.md:1248`、`:1615`、`:1729`），`doc/**` 的成篇审查归其他部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量 13 条（含上述全部发现）；按门禁规则默认只报不修，是否纳入修复待用户决定。

## 总评

本部分代码整体结构统一：每张图都是"`ChartConfig.parse` → 逐项校验 → 建 `SvgBuilder` → 落图元"的线性流程，错误路径基本都用 `chartInvalidValue(path, 文案)` 带出精确字段路径，测试覆盖了计数、类型判别和主要非法输入，可读性好。风险集中在三处：

1. **唯一阻塞项是 `PictogramChart` 的图标数放大**（#1）：一个 `unit` 字段即可把 60 字节输入变成 10^12 次循环与同量 DOM，属可直接打挂进程的路径，建议优先修。
2. **一组"看着对、其实反了/没了"的渲染缺陷**（#2 单扇区 100% 空白、#3 小画布负半径与反转、#4 PDP/PR x 轴镜像）：都源于几何算式缺少退化分支，且测试只断言图元个数与字符串包含，坐标与可见性完全没有校验——这也是这批问题能长期存在的原因。建议补"坐标断言"类用例（首末刻度像素位置、单类目/单点/全零输入）。
3. **契约层面的两处文档漂移**（#5 `cumulativeFormat`、#6 `pie.innerRadius`）和**一份整段复制的实现**（#7 QQ/Probability）：前者让按文档配置的用户静默失效，后者让后续修复天然只改一半，属于必须排期的技术债但不阻塞发布。

死代码（2 个只写字段）与重复逻辑（插入排序 9 份、测试 helper 106 份）量级清楚、影响可控，可随下次触碰文件时顺手收敛；插入排序的复杂度与全量 SVG 物化的峰值内存都还缺测量数据，本轮只作为「待验证假设」登记，不构成缺陷。
