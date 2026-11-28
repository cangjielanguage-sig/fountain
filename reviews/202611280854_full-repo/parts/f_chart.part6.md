# f_chart 模块审查报告

> **模块第 6/37 部分**（本报告只覆盖 `files/f_chart.part6.txt` 列出的 20 个文件：`doc/spec/add-f-chart-{chord,choropleth,circle-packing,combo,confusion-matrix,contour}` 六个变更的 design / proposal / spec / tasks。`src/**` 的 251 个 `.cj` 与其余 `doc/**` 由其他子轮产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG。本部分 20 个文件全是六个图种的规格/设计文档，因此执行方式是「以文档为契约、回源码取证」：把 `spec.md` 的每条 MUST/SHALL 与 `design.md` 的算法描述逐条落到 `src/ChordChart.cj`、`ChoroplethChart.cj`、`CirclePackingChart.cj`、`ComboChart.cj`、`ConfusionMatrixChart.cj`、`ContourChart.cj` 的对应语句（含被复用的 `HeatFlameChart.cj` / `HeatmapChart.cj` / `LineChart.cj` / `ChartFrame.cj` / `ChartScale.cj`），并顺带按 §1–§12 过这 6 个实现文件。
- **报告版本**：v1（第 6/37 部分）

## 发现

### [严重][存量] #1 `CirclePackingChart` 的四个树遍历都是无深度上限的递归，深度等于节点数，长链输入必崩

- **位置**：`f_chart/src/CirclePackingChart.cj:112`（`resolveTotals(rootNode, 0, nodes.size)`）、`:146-168`（`resolveTotals`）、`:170-188`（`sortChildren`）、`:190-219`（`layoutChildren`）、`:221-240`（`drawNode`）；相关条款：`f_chart/doc/spec/add-f-chart-circle-packing/specs/chart-rendering/spec.md:34` 的校验清单未限制节点数或层级深度
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归：深度由输入决定」
- **证据**：静态确定 —— 递归深度上界由输入决定且代码中没有任何常量上限：`nodes` 数组长度不限（`:60-64` 只判非空），校验只要求「恰好一个根 + parent 存在」（`:108-110`），因此 `[{root}, {a,parent:root}, {b,parent:a}, …]` 这种 N 级链是完全合法的输入；`resolveTotals` / `sortChildren` / `layoutChildren` / `drawNode` 各自沿 `children` 递归一层。传进去的第三参 `total: Int64` 实际是 `nodes.size`，守卫 `depth > total`（`:147`、`:171`、`:197`）只能拦住「深度 > 节点数」，对链状输入等于没有上限。`layoutChildren`/`drawNode` 每帧还带 5 个参数与多次 `Float64` 运算，栈帧不小。具体在 N 等于多少时爆栈取决于 SDK 默认线程栈大小，需实测，但「无上限」这一点是静态确定的。
- **描述**：这是本部分唯一会导致进程崩溃的路径。用户只要把层级图的输入摊平成一条链（组织架构、目录树、BOM 展开都会出现深链），`draw` 就会在 `resolveTotals` 或 `drawNode` 里抛栈溢出；由于 `draw` 没有捕获，异常会穿透到调用方。同一份数据用 `sum` 之外的任何字段都不影响——校验阶段（`:96-110`）不会因为深链报错，错误要等到递归时才发生，定位成本高。
- **建议**：把 `resolveTotals`/`sortChildren` 改成显式栈（`ArrayList<(node, depth)>` 后序遍历），`layoutChildren`/`drawNode` 用队列做广度遍历；同时在解析阶段加一条显式上限（如 `maxDepth` 默认 64，超过抛 `InvalidValue` 并在 spec 里写明），让「太深」变成可诊断的输入错误而不是崩溃。

### [一般][存量] #2 `ComboChart` 左右轴的柱组从同一 band 起点起画，双轴柱互相重叠

- **位置**：`f_chart/src/ComboChart.cj:498-501`（`drawBars` 分别画左右两组）、`:516-522`（两组各自 `slot = band.bandWidth / groupCount` 且都从 `band.bandStart(index)` 起步）；契约见 `f_chart/doc/spec/add-f-chart-combo/design.md:9`（「每组占一个子槽」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「与规格冲突」、§10「正确性：坐标与边界」
- **证据**：静态确定 —— `drawBarGroups` 的 x 计算是 `band.bandStart(index) + groupIndex * slot + (slot - barWidth) / 2.0`，`slot = band.bandWidth / groups.size`，两个调用（`drawBarGroups(..., leftGroups, ..., leftScale, false)` 与 `(..., rightGroups, ..., rightScale, true)`）传入的 `band` 是同一个；左组 `groupCount = leftGroups.size`、右组 `groupCount = rightGroups.size`，两者都从 `bandStart(index)` 开始铺满整个 band。于是左轴第 0 组与右轴第 0 组的 x 区间完全重合（宽度都取 `bandWidth / 各自组数` 的 0.6）。
- **描述**：`series[].axis` 对柱类系列是允许的（`design.md:5,9` 与 spec 的「双轴」需求），一旦用户给两个 bar 系列分别标 `left` / `right`，两组柱子就叠在同一位置：后画的右轴柱直接盖住左轴柱，读图时只能看到一组，而且盖住哪个取决于系列顺序。折线/散点因为有各自的 `scale`，不会出现这个问题，所以这个缺陷只在「双轴 + 柱」组合下触发。
- **建议**：把左右柱组当作同一个子槽序列排布——先算出 `leftGroups.size + rightGroups.size` 的总组数，再按 `groupIndex` 全局递增分配 slot（左组在前、右组在后）；或者给两组各分半个 band。补一条断言「左右各一个 bar 系列时，两类柱的 x 区间不相交」的测试。

### [一般][存量] #3 `ComboChart` 堆叠组内所有分段都用组内首系列的颜色，同组的多段柱无法区分

- **位置**：`f_chart/src/ComboChart.cj:562-565`（`case None => config.theme.colorAt(group.series[0].paletteIndex)`）；对照 `:197-203`（图例按 `series[index]` 逐系列取色）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符 / 契约与实现不符」、§10「正确性」
- **证据**：静态确定 —— 堆叠分支的循环变量是 `item`（`for (item in group.series)`），但取色用的是 `group.series[0].paletteIndex`，与 `item` 无关；`ComboSeries.paletteIndex` 在解析时就是系列下标（`:242,250`）。因此一个含 3 个系列的 `stacked-bar` 组，3 段全部拿到第 1 个系列的颜色，而图例显示 3 种颜色。单系列分支（`:530-533`）用 `group.series[0]` 是对的（此时只有一个元素），说明这是写错变量而非有意为之。
- **描述**：堆叠柱的核心信息是「同一条柱子里各段的比例」，颜色全同后视觉上退化成一根纯色柱，段与段之间也没有描边（`kit.rect` 的 `stroke` 默认 `None`，`ChartSvgKit.cj:42`），单凭图形无法区分段，必须回头看数值。百分比堆叠柱同理。
- **建议**：改为 `config.theme.colorAt(item.paletteIndex)`；`ComboSeries` 已有该字段，无需改结构。补一条断言「同组 3 段的 `fill` 互不相同」的测试。

### [一般][存量] #4 `ComboChart` 折线/散点的缺省色硬编码 `#4e79a7`，与图例的调色板取色不一致

- **位置**：`f_chart/src/ComboChart.cj:630-634`（`flushLine` 的 `case None => "#4e79a7"`）、`:651-654`（`drawScatters` 同样的硬编码）；对照 `:197-203` 与 `ChartTheme.cj:54-58`、`:18-21`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性：图例与图形一致性」
- **证据**：静态确定 —— 图例颜色由 `series[index].color` 或 `config.theme.colorAt(index)` 决定（`palette` 默认 `#4e79a7, #f28e2b, #e15759, …`，`ChartTheme.cj:19`）；折线与散点的缺省色是字面量 `#4e79a7`。第 0 个系列恰好等于 `palette[0]`，所以单系列示例测不出来；从第 1 个系列起图例是 `#f28e2b`、线却是 `#4e79a7`，多个无线色的 line 系列则全部画成同一种蓝。
- **描述**：同一张图里「图例说有橙色系列」而图上没有橙色，属于典型的图例/图形错位，会让读者把两条线看成同一条。自定义 `theme.palette` 时连第 0 个系列也会错。
- **建议**：`flushLine`/`drawScatters` 增加 `config` 参数，缺省值改成 `config.theme.colorAt(item.paletteIndex)`，与 `drawBarGroups` 的取色路径统一（可顺手把「系列取色」抽成一个 `comboSeriesColor(config, item)`，三处共用）。

### [一般][存量] #5 `ComboChart` 左轴范围无条件包含 0，与设计「柱参与时才包含 0」不符，纯折线的图被压扁

- **位置**：`f_chart/src/ComboChart.cj:364-365`（`dataMin` / `dataMax` 初始化为 `0.0`）、`:404-412`、`:437-444`；契约见 `f_chart/doc/spec/add-f-chart-combo/design.md:17`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「与规格冲突」
- **证据**：静态确定 —— `design.md:17` 写「柱参与时范围包含 0」，而实现把 `dataMin`/`dataMax` 的初值设成 `0.0`（`:364-365`），后面对 line/scatter 只做 `minFloat`/`maxFloat`（`:415-436`），`hasBar` 分支（`:440-443`）再补一次 0 完全没有意义（初值已经是 0）。结果：只有 line 系列、数值 100–200 的图，`lineRange` 收到 `dataMin = 0`、`dataMax = 200`，加 5% padding 后轴范围是 `[-10, 210]`，数据只占约 45% 高度。
- **描述**：设计意图是「有柱才从 0 起，纯折线按数据范围留 5%」，实现把这条规则变成了全局规则。对仪表盘里「叠加图只有线」的用法（`combo` 允许单 line 系列）会明显损失可读性，而且因为 `lineRange` 会再加 5% padding，负方向还多出一段没有意义的空白。
- **建议**：把初值改成 `dataMin = Float64.MAX` / `dataMax = -Float64.MAX`（或先收集完再取极值），保留 `:440-443` 的 `hasBar` 补 0；`hasData == false` 时仍返回 `[0.0, 1.0]`。

### [一般][存量] #6 `CirclePackingChart` 网格排布让角格子圆越出父圆，违反 spec「父圆 MUST 包住其子圆」

- **位置**：`f_chart/src/CirclePackingChart.cj:203-216`（`columns`/`rows`/`cellWidth`/`cellHeight`/`maxRadius` 与子圆圆心计算）；契约见 `f_chart/doc/spec/add-f-chart-circle-packing/specs/chart-rendering/spec.md:7`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§10「正确性：几何边界」
- **证据**：静态确定（纯几何推导）—— 子圆半径被钳到 `min(cellWidth, cellHeight) / 2 - padding`（`:214-216`），子圆心在 `(col+0.5)·cellWidth` 的格心（`:212-213`）。当 `columns ≥ 2 且 rows ≥ 2` 时，角格心到父圆心的距离是 `sqrt((R - cw/2)² + (R - ch/2)²)`；取最坏情形 `cw = ch = R`（4 个等大子节点，`columns = rows = 2`）时距离为 `R/√2 ≈ 0.707R`，子圆半径上限 `R/2 - p`，外接半径 ≈ `1.207R - p > R`。代入测试样例的尺度（`CirclePackingChart_test.cj:43-44`：640×640、`padding 2`、根总量 310 ⇒ `R ≈ 0.45×608 ≈ 273`）：4 个等大子节点时角格心距圆心 ≈ 193，子圆半径 ≈ 134.5，外接 ≈ 327.5，越出父圆约 55px。现有样例根下只有 2 个子节点（1 行网格）恰好不触发。
- **描述**：圆堆积图的语义就是「父圆面积 = 子圆面积之和，且父圆包住子圆」；现在只要某个父节点有 3 个以上子节点（2×2 网格，其中 2 个是角格），角上的子圆就会溢出到父圆外，与兄弟父圆互相压盖。测试只数 `circle-packing-circle` 个数（`CirclePackingChart_test.cj:60-62`），所以这条 MUST 从未被验证。
- **建议**：把子圆限制在父圆内——按 `最大内接矩形` 缩小 `cellWidth/cellHeight`（边长取 `R·√2/(1+√2)` 量级，或直接按 `sqrt(2)·R/(cols+1)` 收紧），或对每个角格再乘一次 `1/sqrt(2)` 的半径折扣；同时补一条测试：对每个子圆断言 `dist(center, parentCenter) + childRadius <= parentRadius + ε`。

### [一般][存量] #7 等高线的两个专属字段没接线：`interpolate` 校验后完全不生效，`levels` 数组只当计数器用

- **位置**：`f_chart/src/ContourChart.cj:111-114`（`interpolate` 只做取值校验，此后全文无引用）、`:247-265`（`levels` 为数组时只返回 `items.size`，元素值丢弃）；承诺源：`f_chart/README.md:1267`、`f_chart/doc/chart-json-spec.md:1140`、`f_chart/doc/spec/add-f-chart-contour/proposal.md:11`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现 / 半成品」、§1「读了不用」
- **证据**：静态确定（搜索证据）—— `grep -rn "interpolate" f_chart/src`（排除测试）只有 `ContourChart.cj:111-113` 三行：读值、比较、抛异常，之后既没有分支也没有传参给绘制逻辑；`bands` 的计算（`:158-161`）与单元格矩形（`:162-179`）都只看 `contourLevel`，与 `interpolate` 无关。`levels` 数组分支（`:250-256`）只 `return items.size`，`items` 的数值既没校验递增也没参与分层——尽管同一函数的错误文案写着「期望正整数或递增数组」（`:258`）。而 `doc/chart-json-spec.md:1140` 把两者列为「专属字段」（`levels`：等值线层级数**或显式数组**；`interpolate`：`linear` / `nearest`），README:1267 的示例也带着 `"interpolate": "linear"`。
- **描述**：用户传 `interpolate: "nearest"` 得到与 `linear` 完全相同的 SVG（因为没有插值环节，单元格就是离散色块），传 `levels: [0, 10, 25, 60]` 得到的是「4 个等宽分档」，而不是按 0/10/25/60 分档。两个字段都是「写了不生效」的静默降级，最坏情况下用户以为改了配色分档、实际图没变。测试也只覆盖了「非法值要抛」（`ContourChart_test.cj:100-113`），没有行为断言。
- **建议**：二选一——(a) 实现：`interpolate == "nearest"` 时按最近网格点取 band（`linear` 走当前逻辑），`levels` 为数组时用元素作为阈值、校验严格递增；(b) 若短期不做，把两字段从 README / `chart-json-spec.md` 移除，或降级为「仅校验、无效」并在文档里注明，`levels` 数组分支直接拒绝（避免「接受但不生效」）。

### [一般][存量] #8 节点 id 去重与 `findNode` 在模块内各写一遍（本部分命中 3 个图），且都是 O(n²) 线性扫描

- **位置**：`f_chart/src/ChordChart.cj:82-86` + `:204-211`、`f_chart/src/CirclePackingChart.cj:74-78` + `:137-144`、`f_chart/src/ChoroplethChart.cj:82-86`、`f_chart/src/ChordChart.cj:107-113`（每链接两次 `findNode`）+ `:170-183`（画带时再来三次）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改类型名 / 字面量复制）」、§6.4「热点 `contains` / `indexOf`」
- **证据**：静态确定（搜索证据）—— `grep -rn "private func findNode" f_chart/src` 命中 **14** 处：`AlluvialChart:275`、`ArcChart:196`、`ChordChart:204`、`CirclePackingChart:137`、`DifferentialFlameChart:176`、`FlameChart:158`、`HeatFlameChart:181`、`HiveChart:215`、`IcicleChart:157`、`NodeLinkChart:184`、`OfflineFlameChart:167`、`SunburstChart:141`、`TreemapChart:150`、`tui/TuiFlameChart:144`，函数体逐行同构，只有元素类型和返回类型不同（`Int64` 返回 -1 / `?T` 返回 None 两种风格）。`grep -rn "id 重复"` 命中 **≥19** 个图表文件，环内都是「`for (existing in nodes) if (existing.id == id) throw`」，仅名词不同（节点 / 区域）。
- **描述**：同一套「id 唯一 + 按 id 找节点」在两个文件里都退化成 O(n²)：解析 N 个节点时逐个线性比对已有节点，建链接时每条链接再扫两遍（`ChordChart.cj:107-108`），画带时对同一条链接又扫三遍（`:170,171,183`）。这类图（和弦、桑基、火焰）的节点数常有几百到几千，重复逻辑同时带来「改一处漏一处」的维护风险——现在已经分叉成两种返回约定，新增图很容易沿用错的那种。
- **建议**：在模块内加一个共享工具（如 `chartNodeIndex<T>`：`HashMap<String, Int64>`，提供 `add(id, path, noun)` 与 `require(id, path)`），供各节点类图共用；`findNode` 的 14 份实现按「先改本部分命中的 3 个、再逐步收敛」的节奏替换。合并时保留两种语义差异点：错误文案里的名词（节点 / 区域）与「找不到是抛异常还是返回 None」，用参数显式表达。

### [一般][存量] #9 `pathCentroid` 把 SVG 弧线标志位和小数指数当坐标，还静默吞掉解析失败，标签位置会偏

- **位置**：`f_chart/src/ChoroplethChart.cj:176-203`（逐字节取数 + `catch (_: Exception) { () }`）；契约见 `f_chart/doc/spec/add-f-chart-choropleth/design.md:16`、`specs/chart-rendering/spec.md:30`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 解析」、§3「`catch` 静默吃掉异常」
- **证据**：静态确定 —— 扫描器把「数字 / `.` / `-`」都当数字起点（`:182`），后续只接受数字与 `.`（`:187`），因此：①`A 5 5 0 0 1 10 10`（圆弧，画圆角区域常用）里的 `rot` 与两个 flag `0 0 1` 会被当成坐标，7 个数字按两两配对得 (5,5)、(0,0)、(1,10)（末位 10 落单丢弃），质心由真实的 (10,10) 偏到 ≈(2,5)；②SVG 允许指数记法，`1e-5` 会被拆成 `1` 与 `-5` 两个数，配对关系整体错位；③`Float64.parse` 失败（例如孤立 `.`）进 `catch` 后 `()` 直接丢弃（`:194-198`），既不报错也不计数，质心在无提示的情况下偏一点。
- **描述**：这条路径只在 `showLabels` 为真时影响标签坐标，但输出的是「标签画在区域外/压在边界上」这类肉眼可见的错误，而且用户在 JSON 里写的是完全合法的 SVG path（`README.md:2624-2627` 的示例就是 `M … L … Z` 折线，暂时碰不到弧，但设计文档没限制 path 语法）。同一实现还被 `f_chart/src/CartogramChart.cj:94`、`f_chart/src/FlowMapChart.cj:98` 复用，含弧路径的底图会在三张图上一起偏。同一条链路上 `path.toArray()` 与每个数字一次 `String.fromUtf8` 也带来多余分配。
- **建议**：改成状态机解析——只取命令字母后的坐标对，识别 `A/a` 命令跳过 5 个参数中的前 2 个（rx/ry）与后 1 个（x/y），flag 只吃单字符；支持 `e/E` 指数；`Float64.parse` 失败时抛 `InvalidValue`（与 `:204-206` 的「至少两个坐标点」保持同一错误等级），不要空 `catch`。

### [轻微][存量] #10 `drawBarGroups` 的 `right` 形参从未使用，`labelCount()` 是无意义包装

- **位置**：`f_chart/src/ComboChart.cj:504-512`（`right: Bool`）、`:217-219`（`labelCount`）、`:210`（调用点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「死代码：读了不用 / 无调用者的间接层」
- **证据**：静态确定 —— `drawBarGroups` 函数体（`:513-581`）只引用 `groups`、`kit`、`config`、`band`、`labelCount`、`scale`，`right` 没有任何出现；`labelCount(labels)` 唯一实现是 `labels.size`，唯一调用点是 `drawBars(..., labelCount(labels), ...)`，而调用方手上就有 `labels`/`band.count`。
- **描述**：说明「左右两组」这条信息在函数内完全丢失了——与第 #2 条同源：函数不知道自己在画哪一侧，也就无法与另一侧共享子槽。
- **建议**：删除 `right` 形参（或在修 #2 时真正用它做槽位分配）；`labelCount()` 直接用 `labels.size`。

### [轻微][存量] #11 孤立节点（无任何链接）在 `ChordChart` 里得到 0 角度弧，与 spec「分段后仍有正角度」不符

- **位置**：`f_chart/src/ChordChart.cj:126-144`（`span = node.total / total * available`）、`:161-168`（照常输出 `chord-arc`）；契约见 `f_chart/doc/spec/add-f-chart-chord/specs/chart-rendering/spec.md:34`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 空集合」、§13「规格与实现漂移」
- **证据**：静态确定 —— `total` 只累加被链接引用到的节点（`:119-120`），完全没有链接的节点 `total == 0`，于是 `span == 0`、`startAngle == endAngle`（`:139-142`），`chordArcPath` 生成起终点重合的退化弧（`A r r 0 0 1` 同点），视觉上什么都不画；`showLabels` 打开时该节点的标签仍落在 `midAngle` 上。spec 只校验了 `padAngle * nodes.size < 2π`（`:133-135`），没有校验「每个节点至少有一条链接」。
- **描述**：`nodes` 用来声明图例/标签集合，`links` 决定流量，两者不一致时（典型：某个类别本季度没有交易）图不会报错，但会少一块弧且无法解释。spec 的措辞「分段后仍有正角度」在数学上要求每个 `span > 0`，实现只保证了总可用角为正。
- **建议**：在 `padAngle` 校验旁补一条「每个节点 `total > 0`，否则抛 `InvalidValue`（文案指明哪个节点没有链接）」；若希望容忍孤立节点，则在 spec 里把「正角度」改成「总角度为正，孤立节点输出零长度弧」并说明渲染表现。

### [轻微][存量] #12 `ContourChart.indexOf` 未命中时返回 0，把「找不到」伪装成「第 0 个坐标」

- **位置**：`f_chart/src/ContourChart.cj:238-245`（`0`）；调用点 `:94-95`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「`case None => ()` 式兜底把错误吃掉」、§11「错误处理缺失或静默」
- **证据**：静态确定 —— `indexOf` 遍历不到时直接 `0`，而不是抛异常或返回 `Option`；`values[position]` 随即写入 `yIndex * xs.size + xIndex` 的第 0 列。调用点依赖「`xs`/`ys` 由同一批 `points` 去重而来，`x`/`y` 必定命中」这个隐含前提，但前提是靠浮点 `==` 维持的，一旦 `uniqueSorted` 的相等判定与 `indexOf` 不一致（例如 `-0.0` 与 `0.0`、或将来换成 NaN/精度归一化），数据会静默落到错误的网格单元，重复坐标检测（`:97-99`）也会误报。
- **描述**：这是「不可达兜底返回值」的典型形态：今天不会触发，但一旦触发就是错位的色块，没有任何信号。
- **建议**：返回 `?Int64`，调用点 `match` 未命中时抛 `chartInvalidValue("series[0].data", "网格坐标无法定位")`；顺带把去重与查下标合成一趟 `HashMap<Float64, Int64>` 构建。

### [轻微][存量] #13 `uniqueSorted` 去重与排序都是 O(n²)，网格点数上千后解析阶段明显

- **位置**：`f_chart/src/ContourChart.cj:211-236`（去重双层 `for` + 插入排序）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §6.4「热点里对 `Array` 反复 `contains`」「每请求排序」
- **证据**：静态确定（复杂度）—— 去重对每个点线性扫描已收集的 `unique`（`:216-221`），排序用插入排序（`:226-234`），对 P 个点合计 O(P²)；同一函数的 `points.size == xs.size * ys.size` 校验（`:84`）说明 P 就是完整网格规模，`50×50` 网格即 2500 次外层 × 平均 1250 次内层。
- **描述**：低效算法本身可静态认定，但「解析阶段是否已成为端到端热点」没有测量数据（`ContourChart` 的典型网格规模未知），故只按轻微记录，收益进「待验证假设」。
- **建议**：一次性把 `x`/`y` 放进 `HashMap<Float64, Unit>` 去重 + `xs.sort()`；或直接按「点到 (行, 列)」的 `HashMap<Int64, Float64>` 建网格，免去 `uniqueSorted` 与 `indexOf` 两趟。

### [轻微][存量] #14 `colorRange` 超过 3 个颜色时多出的颜色被静默丢弃，最大值拿不到「末色」

- **位置**：`f_chart/src/ChoroplethChart.cj:103-119`（只校验 `size >= 2`）、`:152-154`（统一走 `heatFlameColor`）；`f_chart/src/HeatFlameChart.cj:271-272` → `f_chart/src/HeatmapChart.cj:225-248`（只取 `colors[0..2]`）；契约见 `f_chart/doc/spec/add-f-chart-choropleth/specs/chart-rendering/spec.md:21`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `heatFlameColor` 在 `colors.size >= 3` 时固定调用 `heatmapColor(value, colors[0], colors[1], colors[2])`（`HeatFlameChart.cj:271-272`），`heatmapColor` 的签名只有 low/mid/high 三个位置参数，`ratio == 1.0` 时返回 `high == colors[2]`；`ChoroplethChart` 侧没有对 `colorRange.size > 3` 做任何限制或提示。于是传 `["#e8f1fb","#7fb3d5","#1f4e79","#0b2545"]` 时，最大值取到 `#1f4e79` 而非末色 `#0b2545`，第 4 个颜色全程未被使用。
- **描述**：影响面限于「调用方传 4 色以上」的输入（README:2621 与 spec 示例都是 3 色），但 spec 明确写「最小值 MUST 取首色，最大值 MUST 取末色」，与实现不一致；同模块其他图（如热力图）也共用 `heatFlameColor`，配色语义不统一时容易误判。
- **建议**：要么在 `:107-109` 把上限收紧到 2–3 并给出明确文案（「colorRange 支持 2 或 3 个颜色」），要么在 `heatFlameColor` 里对 N 色做均匀分段插值（N-1 段线性插值），让「末色 = 最大值」在任何长度下成立。

### [轻微][存量] #15 `ConfusionMatrixChart` 单元格边长有 1px 下限，画布偏窄时网格会溢出绘图区

- **位置**：`f_chart/src/ConfusionMatrixChart.cj:110-115`（`maxFloat(min(...), 1.0)` 与 `gridX/gridY` 居中）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」
- **证据**：静态确定 —— `cellSize = max(min(gridWidth/N, gridHeight/N), 1.0)`。当标签很长或画布很窄（`plot.width - rowLabelWidth < N`）时 `gridWidth` 可能小于 `N` 甚至为负，`min(...)` 为负后被抬到 1.0，`totalSize = N` 反而大于 `gridWidth`，`gridX = plot.x + rowLabelWidth + (gridWidth - totalSize)/2` 把网格推到 `rowLabelWidth` 左侧、盖住行标签并越出画布；`gridY` 同理可能盖住列标签/标题。
- **描述**：`ChartConfig` 只校验 `width/height > 0`（`ChartConfig.cj:182-184`），没有最小尺寸约束，所以窄画布是可达输入；此时输出仍是合法 SVG，只是内容压在一起，属于可诊断性差的降级。
- **建议**：`cellSize` 下限改为 `0`，并在 `gridWidth`/`gridHeight <= 0` 时抛 `InvalidValue`（「画布不足以容纳 N×N 矩阵与标签」）；或按 `N` 自动缩字号/截断标签。

### [轻微][存量] #16 分级统计地图的校验清单漏了 `id` 必填且唯一

- **位置**：`f_chart/doc/spec/add-f-chart-choropleth/specs/chart-rendering/spec.md:44`（校验清单）；对照 `f_chart/doc/spec/add-f-chart-choropleth/proposal.md:10`（字段列表）、`f_chart/src/ChoroplethChart.cj:81-86`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档缺关键约束」、§14.1「规格漏项导致按文档造数据被拒」
- **证据**：静态确定 —— `spec.md:44` 只写「每项 MUST 有字符串 `path` 与数字 `value`」，实现 `:81` 用 `json.requiredString("id")` 且 `:82-86` 对重复 `id` 抛 `InvalidValue`；`proposal.md:10` 的元素形状里确实有 `id`。
- **描述**：照 `spec.md:44` 的清单构造不带 `id` 的 `regions` 会直接抛错，验收方与实现方对同一输入结论相反；重复 id 的拒绝也没有任何规格依据。
- **建议**：`spec.md:44` 补「每项 MUST 有唯一的字符串 `id`」，并加一条「重复 id → `InvalidValue`」的场景。

### [轻微][存量] #17 和弦规格的「比例」口径与设计/实现不一致（每条链接被计两次）

- **位置**：`f_chart/doc/spec/add-f-chart-chord/specs/chart-rendering/spec.md:7`（规格）；对照 `f_chart/doc/spec/add-f-chart-chord/design.md:9-12`（设计）、`f_chart/src/ChordChart.cj:119-120`（双向累加）、`:126-144`（按 `Σ 节点总量` 分配）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移：验收口径不可复现」
- **证据**：静态确定 —— 每条链接的 `value` 同时累加到 `source` 与 `target` 的 `total`（`:119-120`），分母 `total = Σ 节点总量`（`:126-129`）因此是总流量的 2 倍。规格写「占**全部总流量**的比例」，按字面「两个节点 + 一条链接」场景下每个节点应占 100%，实现给出 50%。
- **描述**：行为本身是对的（只有用 `Σ 节点总量` 作分母才能把可用角度填满），错的是 `spec.md:7` 的文字：它把「节点总量」说成了「总流量」。按规格写的验收用例会算出相反结论，测不出问题时也说不清是实现错还是用例错。
- **建议**：`spec.md:7` 改为「弧长按该节点总量（作为 source/target 的 `value` 之和）占所有节点总量之和的比例分配」，与 `design.md:9-12` 统一措辞，并补一条单链接场景断言「两个节点各占 50%」。

### [轻微][存量] #18 组合图「六种系列类型」中 `bar` 与 `grouped-bar` 实现完全等价

- **位置**：`f_chart/doc/spec/add-f-chart-combo/specs/chart-rendering/spec.md:7`；实现 `f_chart/src/ComboChart.cj:238`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档描述的能力颗粒度与实现不符」、§2「只改名字的重复分支」
- **证据**：静态确定 —— `:238` 是 `case "bar" | "grouped-bar"` 同一分支，两者都产生 `ComboKind.Bar` 与空 `stack`；是否并列只取决于同组系列个数（`:471`、`:516-522`），与类型名无关。
- **描述**：规格把两者列为两种类型，实际只有 5 种语义。用户只写一个 `grouped-bar` 系列时得到的是普通柱，与「分组柱」的预期不符，也无法通过类型名强制并列。
- **建议**：文档注明 `grouped-bar` 是 `bar` 的别名（分组行为由系列数量与 `stack` 决定），或让 `grouped-bar` 强制独占一组以产生稳定的并列语义；后者需补一条「单 `grouped-bar` 系列仍占满子槽」的用例。

## 优化可行性方案

> 不是缺陷，是"还能更好"。全部缺改前基线，只作为下一轮补数据的候选。

### [堆内存] `confusionNormalize` 对 `none` 模式也整表复制，矩阵在绘制期存在 3 份副本

- **现状**：`draw` 里每行先 `ArrayList<Float64>` 再 `toArray()`（`ConfusionMatrixChart.cj:71-86`），得到 `matrix`；随后 `rawMatrix = matrix.toArray()`（`:89`）；`confusionNormalize` 无论模式都会新建 `rows × cols` 的 `ArrayList` 并 `toArray()`（`:192-199`），`none` 模式完全可以直接返回入参。N×N 的 `Float64` 装箱数组在 N=100 时是 1e4 个元素 × 3 份。
- **方案**：`none` 模式在 `confusionNormalize` 开头直接 `return matrix`；行构造改成先取 `cells.size` 再填 `Array<Float64>(n, repeat: 0.0)`，去掉 `ArrayList → toArray` 的中转；`rawMatrix` 与 `displayMatrix` 合并为一个变量。
- **预期**：绘制期矩阵副本从 3 份降到 1–2 份，减少 O(N²) 的临时分配；峰值内存与 GC 次数下降。
- **代价**：几乎没有语义变化（`none` 返回入参后调用方不得原地修改，当前调用方只读）。
- **验证**：对 N=100/500 的矩阵连续 `draw` 1e4 次，比较 `getAllocatedHeapSize()` 增量与 RSS 稳态（`mem §1.2`）；同时断言归一化输出与原实现逐元素一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 节点 id 去重与 `findNode` 改一次建索引，替掉 3 处 O(n²) 去重与每条链接 5 次线性查找

- **现状**：`ChordChart.cj:82-86`（解析期 O(n²)）、`:107-113` 与 `:170-183`（每条链接 5 次线性 `findNode`）；`CirclePackingChart.cj:74-78`、`:137-144`；`ChoroplethChart.cj:82-86`。输入规模：和弦/桑基类图常见 10²–10³ 节点与链接。
- **方案**：解析时用 `HashMap<String, Int64>` 同时完成去重与建索引，后续按 id 取下标 O(1)；`ChordChart` 的链接解析直接保存 `sourceIndex`/`targetIndex`，画带时不再回查（`ChordLink` 增加两个 `Int64` 字段）。
- **预期**：解析与绘制从 O(n²)/O(m·n) 降到 O(n+m)；具体占比未知，需要 profile 才能给端到端数字。
- **代价**：多一个 `HashMap`（O(n) 内存）；`findNode` 的 `?T` 版本若保留需维持两种语义。
- **验证**：`cjpm bench -O2` 对照 200/1000/5000 节点的和弦图 `draw`，记录中位数与 P95，并断言 SVG 输出逐字节一致（当前实现是确定性的）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ComboChart` 每次 `draw` 把柱组重复构建 4 次

- **现状**：`buildBarGroups` 在 `resolveAxisRange`（`ComboChart.cj:376`，左右各一次即 2 次）与 `drawBars`（`:498-499`，再 2 次）里各调一遍，一次 `draw` 共 4 次构建，每次都重新扫全部系列并新建 `ComboBarGroup`/`ArrayList`。
- **方案**：在 `draw` 开头构建一次 `leftGroups`/`rightGroups`，作为参数传给 `resolveAxisRange` 与 `drawBars`；顺带让 `drawBarGroups` 拿到全局槽位信息（与缺陷 #2 的修法同源）。
- **预期**：组合图绘制期少 3 次 O(series) 扫描与相应分配；系列数少时收益有限。
- **代价**：`resolveAxisRange` 签名变化（内部方法，无对外影响）。
- **验证**：`cjpm bench -O2` 对照 20 系列 × 50 类目的 `draw`，看中位数变化是否超出噪声（<5% 不做）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 和弦图解析/绘制是热点（每条链接 5 次线性 `findNode` + 解析期 O(n²) 去重） | `f_chart/src/ChordChart.cj:82-86,107-113,170-183` | 自耗时占比、n/m 规模 | `cjprof record` 跑 1000 节点 / 3000 链接的 `draw` ×1000，`cjprof report` 看 `findNode` self time |
| 2 | `combo` 的 4 次 `buildBarGroups` 有可观开销 | `f_chart/src/ComboChart.cj:376,498-499` | 绘制耗时占比 | `cjpm bench -O2` 对照 20 系列 × 50 类目，改前改后各 10 轮取中位数 |
| 3 | 等高线 `uniqueSorted` 的 O(P²) 在大网格下明显 | `f_chart/src/ContourChart.cj:211-236` | P 的实际分布、解析耗时占比 | 用 50×50 / 200×200 网格各跑 100 次 `draw`，分段计时解析段 vs 绘制段 |
| 4 | 圆堆积的插入排序在宽树（根下数百子节点）下可见 | `f_chart/src/CirclePackingChart.cj:174-184` | 兄弟节点数上限、耗时占比 | 构造根下 500 子节点的输入，`cjpm bench -O2` 对照 `sort` 前后 |
| 5 | `pathCentroid` 的逐字节 `toArray()` + 每数字一次 `String.fromUtf8` 在区域多时占解析时间 | `f_chart/src/ChoroplethChart.cj:176-203` | 区域数 × 路径长度、耗时占比 | 500 个区域各 200 段 path 的输入跑 `cjprof`，看 `pathCentroid` self time |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part6.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-chord/specs/chart-rendering/spec.md` | .md | ✅ | 4 条需求逐条对 `ChordChart.cj`；「正角度」未落实见 #11，「比例」口径措辞见 #17 |
| 2 | `f_chart/doc/spec/add-f-chart-chord/tasks.md` | .md | ✅ | 流程记录（4 项全勾），无实现承诺 |
| 3 | `f_chart/doc/spec/add-f-chart-choropleth/design.md` | .md | ✅ | 坐标/区域/标签三段与 `ChoroplethChart.cj:47-171` 一致；质心算法见 #9 |
| 4 | `f_chart/doc/spec/add-f-chart-choropleth/proposal.md` | .md | ✅ | 字段与 class 名均落地；`colorRange` 长度语义见 #14 |
| 5 | `f_chart/doc/spec/add-f-chart-choropleth/specs/chart-rendering/spec.md` | .md | ✅ | 「最值取首/末色」在 ≥4 色时不成立，见 #14；校验清单漏 `id`，见 #16 |
| 6 | `f_chart/doc/spec/add-f-chart-choropleth/tasks.md` | .md | ✅ | 流程记录（4 项全勾） |
| 7 | `f_chart/doc/spec/add-f-chart-circle-packing/design.md` | .md | ✅ | 比例 k、降序、网格排布、18px 标签均与实现一致；「父圆包住子圆」见 #6 |
| 8 | `f_chart/doc/spec/add-f-chart-circle-packing/proposal.md` | .md | ✅ | `padding` 默认 2 与 `CirclePackingChart.cj:55` 一致 |
| 9 | `f_chart/doc/spec/add-f-chart-circle-packing/specs/chart-rendering/spec.md` | .md | ✅ | 圆面积/标签/校验均落地；「MUST 包住」违反，见 #6；深度无上限见 #1 |
| 10 | `f_chart/doc/spec/add-f-chart-circle-packing/tasks.md` | .md | ✅ | 流程记录（4 项全勾） |
| 11 | `f_chart/doc/spec/add-f-chart-combo/design.md` | .md | ✅ | 轴/分组/叠加/范围四段：范围「柱参与才含 0」不符，见 #5 |
| 12 | `f_chart/doc/spec/add-f-chart-combo/proposal.md` | .md | ✅ | 六种系列类型、双轴、`yAxis2` 均已落地 |
| 13 | `f_chart/doc/spec/add-f-chart-combo/specs/chart-rendering/spec.md` | .md | ✅ | 类型判别/右轴/堆叠/散点映射均成立；「六种类型」实为 5 种语义，见 #18；左右柱重叠不属其断言范围，见 #2 |
| 14 | `f_chart/doc/spec/add-f-chart-combo/tasks.md` | .md | ✅ | 流程记录（5 项全勾） |
| 15 | `f_chart/doc/spec/add-f-chart-confusion-matrix/design.md` | .md | ✅ | 数据/归一化/布局/文本/校验与 `ConfusionMatrixChart.cj` 一致；仅「`none` 显示整数」一条只对整数输入成立（`formatSvgNumber` 会保留小数，spec 也允许小数单元格），属措辞不精确，未单列 |
| 16 | `f_chart/doc/spec/add-f-chart-confusion-matrix/proposal.md` | .md | ✅ | `normalize` / `showValues` 默认值与 `:30-34` 一致 |
| 17 | `f_chart/doc/spec/add-f-chart-confusion-matrix/specs/chart-rendering/spec.md` | .md | ✅ | 三种模式、行/列和、标签计数与实现一致；矩阵复制见「优化方案」 |
| 18 | `f_chart/doc/spec/add-f-chart-confusion-matrix/tasks.md` | .md | ✅ | 流程记录（4 项全勾） |
| 19 | `f_chart/doc/spec/add-f-chart-contour/design.md` | .md | ✅ | 网格/分层/绘制三段与 `ContourChart.cj` 一致（`heatColor(band/(levels-1))` 对应 `:165-169`）；`interpolate` 未在此文档出现 |
| 20 | `f_chart/doc/spec/add-f-chart-contour/proposal.md` | .md | ✅ | 「`interpolate` 取 linear/nearest」只做了校验，见 #7 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | #2（左右柱重叠，坐标）、#3（堆叠取色变量用错）、#4（图例与图形配色不一致）。设计维度：六份 design/proposal 与实现的职责划分一致，`Chart` 纯函数契约未被破坏（无静态可变状态）；语言特性：`?Float64`/`match`、`Array<Array<Float64>>`、`Float64` 装箱使用得当，未见值/引用语义误用；安全性：本部分无外部输入注入面（输入是结构化 JSON，无 SQL/命令/路径拼接），无凭据；可读性：`ComboChart` 的 `labelCount()`、`drawBarGroups` 的 `right` 形参见 #10 |
| §1 死代码 | 1 | #10：`drawBarGroups` 的 `right` 形参在函数体内零引用（`ComboChart.cj:504-512` vs `:513-581`）；`labelCount()` 只 `return labels.size`，属无意义间接层。其余逐个检查：`ChordNode`/`ChordLink`/`ChordNode.total..midAngle`、`chordArcPath`/`chordWidth`（测试 `ChordChart_test.cj:99-109` 引用，属「仅测试使用的 internal」= 可见性建议，不判死代码）、`CirclePackingNode` 全部字段（`total/x/y/radius` 均在布局与绘制中被读）、`circlePackingRadius`（同文件 + 测试）、`ChoroplethRegion` 六字段（全部被读）、`pathCentroid`（同文件 + 测试）、`confusionNormalize`/`confusionText`（同文件 + 测试）、`ContourPoint`、`contourLevel`（同文件 + 测试）、`ComboKind`/`ComboSeries`/`ComboBarGroup` 的每个字段均被读；`ComboSeries.symbolSize`/`smooth`/`symbol` 在散点/折线绘制中被读。不可达语句：6 个 `draw` 的 `return`/`throw` 后无同层语句；未使用的 `import` 未发现（`std.math.*`、`formatSvgNumber`、`SvgColor` 均有引用）。对外可达 public（6 个 `public class` 与 `public init`/`draw`）不判 |
| §2 重复逻辑 | 1 | #8：`findNode` 14 份同构实现（含同模块 `tui/TuiFlameChart.cj:144`）、「id 唯一」循环 ≥19 处，差异只在元素类型、错误名词与返回约定（-1 / `None`）。同文件内其余函数已两两比对：`ChordChart` 的 2 个解析循环（节点/链接）字段不同、不构成重复；`ComboChart` 的 `parseValues` 与 `parseScatterPoints` 输入形状不同（`number｜null` vs `{x,y}`）；`ContourChart` 的 `resolveLevels`/`resolveRange`/`uniqueSorted`/`indexOf` 语义互不重叠；`CirclePackingChart` 的 `resolveTotals`/`sortChildren`/`layoutChildren` 都是「递归 + 守卫」，但分别做求和/排序/定位，合并只会增加分支 |
| §3 空实现 | 1 | #12：`indexOf` 未命中返回 0 的兜底；另有 `ChoroplethChart.cj:194-198` 的 `catch (_: Exception) { () }`（并入 #9 取证）。6 个 `draw` 均无空分支、无 `TODO`/`FIXME`、无 `UnsupportedException` 占位（`ComboChart.cj:270-275` 的 `UnsupportedChart` 是契约要求的未知类型拒绝） |
| §4 栈溢出 | 1 | #1：`CirclePackingChart` 四条递归链，深度 = 树深 = 输入节点链长，无常量上限。其余 5 个图逐函数确认无自递归/间接递归（`ChordChart`、`ChoroplethChart`、`ComboChart`、`ConfusionMatrixChart`、`ContourChart` 全为循环） |
| §5 OOM | 0 | 逐个核对分配点：`ContourChart.cj:87-90` 的 `xs.size * ys.size` 预分配发生在 `points.size == xs.size * ys.size` 校验（`:84`）之后，规模受输入自身约束，不存在「按报文字段放大预分配」；`ComboChart`/`ConfusionMatrix`/`Chord` 都只按输入元素数建集合，无全局缓存、无只增不减容器、无「循环内 `result = result + part`」；`draw` 返回单个 SVG 串，`StringBuilder`/`Append` 增长与输出规模同阶。`CirclePackingChart` 的递归每层只持有已有节点对象，不产生随深度倍增的临时对象。故未成立 OOM 缺陷（规模上限缺失本身已在 #1 讨论） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，六份文档也没有性能承诺；不成立「发现」，相关线索（和弦 `findNode`、`combo` 重复建组、等高线去重）全部降级到「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | 6 个实现文件内无 `synchronized`、无 `Mutex`、无锁内 I/O（`grep -n "synchronized\|Mutex\|spawn"` 零命中）；`draw` 每次调用只操作局部对象 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池使用，不存在「提交后立即 get」或并发度=1 的配置 |
| §6.4 低效算法 | 1 | #13：`uniqueSorted` 去重 + 插入排序 O(P²)（复杂度静态确定，占比待测）；#8 里的 O(n²) 去重与 O(m·n) 查找归入 §2 统计，不重复计数。`CirclePackingChart:174-184` 的插入排序、`ComboChart` 的 4 次建组作为同源线索列入待验证假设 2/4 |
| §7 降堆内存方案 | 0 | 缺陷侧 0 条；方案侧 1 条（`confusionNormalize` 对 `none` 也整表复制），因无基线只进「优化可行性方案」，不计缺陷 |
| §8 降 CPU 方案 | 0 | 缺陷侧 0 条；方案侧 2 条（id 索引化、`combo` 建组复用），同样无基线 |
| §9 local mode 可行性 | 0 | 6 个 `draw` 的临时对象（节点表、矩阵、网格、SVG 串）都随返回值或成员结构逃逸到函数外（`SvgBuilder` 持有输出、`ArrayList` 被返回/存储），不满足 `@ local!` 的逃逸约束；且无峰值内存基线，不写改造建议 |
| §11 现有代码的 BUG（存量） | 3 | #9（`pathCentroid` 解析弧标志/指数 + 空 `catch`）、#11（零流量节点退化弧）、#15（`cellSize` 下限导致网格溢出）。另核对了：`ChordChart` 的 `padAngle` 累计（`cursor` 每节点消耗 `span + padAngle`，末节点回到起点，无累积漂移）、`chordWidth` 的 `ratio` 已被 `maxValue` 保证 ≤1、`confusionText` 的两位小数四舍五入（`round(value*100)`，`:233-237`）、`contourLevel` 的上下钳制、`ComboChart` 的 `validateLengths` 长度校验与 `parseScatterPoints` 的越界校验，均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态可列：6 个类只有 `public init()`、没有实例字段（`ChordChart`/`ChoroplethChart`/`ComboChart`/`ConfusionMatrixChart`/`ContourChart`/`CirclePackingChart` 均无实例字段），`draw` 的所有中间结构都是局部变量；`internal class ChordNode` 等只在单次调用内构造并传递，无线程间发布路径。`CHART_DEFAULT_PALETTE` 是 `let` 常量但类型为 `Array<String>`（可变数组，`ChartTheme.cj:19`），当前无写入点，且是 `internal`；作为「可变全局」的潜在风险记录在此，不判缺陷（无写路径） |
| §13 文档一致性 | 6 | #5（`combo` 范围含 0）、#6（`circle-packing` 父圆包住子圆）、#14（`choropleth` 最值取末色）、#16（`choropleth` 校验清单漏 `id`）、#17（`chord` 比例口径）、#18（`combo` 类型计数夸大）。反向核对通过的项：六份 design 的公式与常量（`k = 0.45·min/√total`、`sqrt(value)*scale`、`band = floor(...)×levels` 钳制、`heatFlameColor(ratio, ["#e3f2fd","#0d47a1"])`、`normalize` 三模式、`padding` 默认 2、`levels` 默认 8、`showValues` 默认 true、`showLabels` 默认 false、`padAngle` 默认 0.02）在源码中逐条命中；class 名（`chord-arc`/`chord-ribbon`/`chord-label`/`choropleth-region`/`choropleth-label`/`circle-packing-circle`/`circle-packing-label`/`confusion-cell`/`confusion-value`/`confusion-label`/`contour-cell`/`contour-line`/`bar`/`line`/`symbol`）全部存在 |
| §14 功能完备性与 README 覆盖 | 1 | #7（`interpolate` / `levels` 数组承诺未实现）。另核对：六图在 `README.md` 均有独立小节（`1671` chord、`2609` choropleth、`1558` circle-packing、`2856` combo、`2110` confusion-matrix、`1253` contour），`type` 字符串与 `ChartConfig.parse` 的 `expectedType` 一致；六个 `tasks.md` 全部勾选且对应文件存在（无「任务勾了但文件缺失」） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；20 个 `.md` 全部逐行读完（合计 495 行） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分覆盖的六个图种（和弦、分级统计、圆堆积、组合、混淆矩阵、等高线）在文档侧写得相当扎实：每份 `spec.md` 都给了可判定的 MUST 与具体场景，「数据形状 → 归一化 → 布局 → 文本 → 校验」的分节也和代码一一对应，六份 `tasks.md` 的红绿流程说明这些图是按 TDD 落地的。逐条核对后，**实现侧的校验面基本没有漏项**（类型判别、必填字段、方阵/网格完整性、id 唯一、父子存在、颜色合法性都有对应抛错；规格文本本身的漏项见 #16），坐标换算（`LinearScale` 方向、`band.center`、`lineRange` 5% 留白、`contourLevel` 钳制）也没有算错。

问题集中在两类：

- **几何/渲染的边界**：圆堆积的子圆会越出父圆（#6，直接违反 spec 的 MUST）、双轴柱组起点重合导致重叠（#2）、堆叠段同色（#3）、图例与折线配色脱节（#4）。这四条都只能靠看图发现，现有测试只数 class 个数，断言不到几何与颜色，所以长期未被捕获。建议优先补「几何不变量」与「颜色唯一性」两类断言。
- **「接受但不生效」的输入**：等高线的 `interpolate` 与 `levels` 数组（#7）是唯一有文档承诺却完全没有实现路径的项，属于会误导使用者的静默降级，应当在本轮就定下来（实现或撤文档）。

**阻塞项**只有 #1（`CirclePackingChart` 递归无深度上限导致的栈溢出）。它不影响常规示例，但深链输入是真实存在的（目录树、组织架构），而 `draw` 无捕获、进程直接崩，建议本轮修掉并加 `maxDepth` 上限。

其余为可排期项：#5（纯折线被压到 0 起点）与 #9（质心解析）影响可读性但不出错；#8 的 14 份 `findNode` 是模块级技术债，按「本部分 3 个先收敛」推进即可。文档措辞层面还有 3 条轻微：#16（校验清单漏 `id`）会让照文档造数据的人直接被拒，#17（比例口径）与 #18（类型计数）属同一类「文字比实现走得远」的漂移——这三条改文档即可，不必动代码，但应趁本轮一并收掉，否则下一轮重审还会重新命中。三条优化方案全部缺改前基线，本轮只作为下一轮补数据的候选，未写成收益结论。

存量缺陷共 18 条（严重 1 / 一般 8 / 轻微 9），是否纳入修复待用户决定；本报告只读文件，未做任何修改，也未跑构建。
