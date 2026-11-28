# f_chart 模块审查报告（第 30/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件，全部为 `.cj`；10 个实现 + 10 个配套测试）
- **基线**：工作区快照（`git diff 120fd2542 -- f_chart` 为空，`git status --porcelain f_chart` 为空，HEAD `f309f0b55`）⇒ 本部分全部问题来源为「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并为 `docs/review/2026-11-28/f_chart_v2.md`）

## 发现

### [严重][存量] 分箱数无上界，按不可信数值预分配数组 → OOM；乘积溢出时抛非契约异常

- **位置**：`f_chart/src/HistogramChart.cj:167-186`（`resolveBinCount`）、`f_chart/src/HistogramChart.cj:248-251`（按 `binCount` 逐个 `add(0)`）；`f_chart/src/Histogram2DChart.cj:111-123`（`bins` 解析）、`f_chart/src/Histogram2DChart.cj:288-291`（`0..(binsX * binsY)`）
- **来源**：存量（快照模式，`f_chart` 与 `120fd2542` 无差异）
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）
- **证据**：静态确定 —— `resolveBinCount` 只校验 `raw >= 1.0 && raw == floor(raw)`，`parseBinCount` 只校验 `raw < 1.0 || raw != floor(raw)`，两者都无上限；随后直接用该值向上取整地预分配 `Int64` 单元
- **描述**：`bins` 来自图表 JSON 配置（调用方/用户可控）。单个 `Int64` 占 8 字节：`bins=1e8` 一次分配 800MB；`binsX=binsY=1e5` 时 `binsX*binsY=1e10` 项 ≈ 80GB，必然 OOM。另外 `Histogram2DChart.cj:289` 的乘积与 `Int64(raw)` 转换都可能溢出：仓颉默认整数溢出策略是 `@OverflowThrowing`（`docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md:88`），溢出会抛非 `ChartException` 的异常，调用方若按契约只捕 `ChartException` 就会直接失败。
- **建议**：在 `parseBinCount` / `resolveBinCount` 增加硬上限（如单轴 ≤ 1000、`binsX*binsY` ≤ 10000），超限抛 `chartInvalidValue`；乘积前先做上限比较，避免依赖溢出行为；分配改用 `Array<Int64>(n, repeat: 0)` 并确认 `n` 已经过上限校验。

### [一般][存量] 轴范围覆盖数据范围后，图元未按有效范围重算也未裁剪，绘制溢出绘图区

- **位置**：`f_chart/src/HistogramChart.cj:118`（`xScale` 用 `xRange`）与 `:147-161`（柱起点用 `bins.minimum`）；`f_chart/src/Histogram2DChart.cj:166-167`（scale 用 `xRange`/`yRange`）与 `:180-181`、`:194-211`（格坐标用 `result.xMin`/`result.yMin`）；`f_chart/src/HorizontalBarChart.cj:113`（`baseline = xScale.scale(0.0)`）与 `:129-139`；`f_chart/src/LassoPathChart.cj:178-181`（零线 `yScale.scale(0.0)`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释/契约不符、越界绘制）、§10 正确性
- **证据**：静态确定 —— `ChartSvgKit.rect/path/line` 不做裁剪（`ChartSvgKit.cj:36-72`、`:194`）；`SvgBuilder` 对 `clip-path` 只做 `url(...)` 引用校验（`SvgBuilder.cj:317-321`），本部分各图也没有任何裁剪调用；几何量来自数据范围，坐标映射来自可能被 `xAxis.min/max`、`yAxis.min/max` 覆盖的有效范围
- **描述**：例：`histogram` 数据 1..8、`xAxis.min = 5` 时，第 1、2 箱起点 `bins.minimum=1` 经 `xScale` 映射到 `plot.x` 左侧，柱子画进 y 轴标签区甚至画布外；`2d-histogram` 同理（先按数据范围分箱，再用被覆盖的轴范围映射）。`HorizontalBarChart` 固定以 0 为基线，`xAxis.min > 0` 时基线落在 `plot.x` 左侧，所有柱子横向溢出；`LassoPathChart` 的 0 参考线在 `yAxis.min > 0` 时画到绘图区下方，压住 x 轴刻度。这四个图元都会出现在最终 SVG 里，只是位置错误，用户难以判断是数据错还是渲染错。
- **建议**：几何量统一由有效范围推导（分箱/单元格起点用 `xRange[0]`、`yRange[0]`，或把数据裁剪到有效范围内再分箱）；基线/零线取 `clamp(scale(0.0), plot.x, plot.right())`；如需保留溢出可见性，改为显式 clipPath。

### [一般][存量] LearningCurveChart 只对点排序，标准差数组未同步，误差带错位

- **位置**：`f_chart/src/LearningCurveChart.cj:112`（`sortLiftPoints(raw.toArray())`）、`:80-114`（`std` 按 JSON 顺序收集）、`:220-237`（band 用 `item.points[position]` 配 `item.std[position]`）
- **来源**：存量
- **判据**：review-checklist §11（数据错位）、§2（近似重复导致的行为漂移）
- **证据**：静态确定 —— 排序只发生在 `raw` 上，`stdValues` 全程未参与排序，长度校验（`:87-89`）只比 size
- **描述**：规格（`doc/chart-json-spec.md:2025-2031`）只要求 `data` 为 `{x,y}`，未要求按 x 升序。输入乱序时 `points` 被重排而 `std` 保持原序，`shade: true` 画出的上下界与对应点不匹配，`dataMinY/dataMaxY`（`:131-134`）也随之算错。现有用例 `drawsBand` 的数据本身有序，测不出该问题。
- **建议**：把 `(x, y, std)` 作为一条记录一起排序（或对索引数组排序后同时取 points/std），保证 `std` 与点严格配对。

### [一般][存量] 几何参数缺少取值校验，可产生负宽高矩形（SVG 非法，图元静默消失）

- **位置**：`f_chart/src/HeatmapChart.cj:108-111`（`cellGap` 只校验非负）、`f_chart/src/HeatmapChart.cj:157-161`（`cellWidth - cellGap`）；`f_chart/src/HorizontalBarChart.cj:121-139`（`barWidth` 未校验，`barHeight = minFloat(requested, slot*0.95)`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定 —— `cellGap` 无上界，`barWidth` 连 `> 0` 都没判；`ChartSvgKit.rect` 直接把参数写给 `SvgBuilder.rect`（`SvgAuthoringBuilder.cj:115-132`），后者原样 `svgPx(width/height)` 输出，无绝对值/夹取
- **描述**：5 列 800px 画布配 `cellGap: 200` 时 `cellWidth` 已远小于 200（`cellWidth - cellGap < 0`）；`barWidth: -24` 时 `barHeight` 为负。SVG 规范中负 `width`/`height` 非法，浏览器直接丢弃该 `<rect>`，表现是"数据有、图上没有"，且无异常提示。
- **建议**：`cellGap` 上限取 `min(cellWidth, cellHeight) / 2`（按实际列/行数算），`barWidth` 要求 `> 0` 且 `≤ slot`，越界抛 `chartInvalidValue`；`ChartSvgKit.rect` 可加一道 `width/height >= 0` 断言式检查。

### [一般][存量] IcicleChart 四层递归深度由输入决定，无深度上限

- **位置**：`f_chart/src/IcicleChart.cj:166-180`（`validateValues`）、`:182-190`（`assignDepth`）、`:192-200`（`layoutNode`）、`:202-244`（`drawNode`，`:241-243` 递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归，深度由输入决定）
- **证据**：静态确定（无任何深度上限/迭代兜底）；崩溃阈值需实测
- **描述**：递归深度 = 树高，树高的上界 = `nodes` 条数（JSON 输入，未限制条数）。仓颉不保证尾调用优化，且 `drawNode` 自身 8 个参数、每帧还带 `String`/`IcicleNode` 引用，深链（数万层）会先爆栈再谈堆。`assignDepth` 的 `depth > total` 守卫只是"深度不超过节点数"，不是栈保护。
- **建议**：改为显式栈迭代（先算出 depth 与 x 偏移，再顺序绘制），或引入深度上限常量（如 512）并在建树阶段抛明确异常。

### [一般][存量] IcicleChart 环检测恒不触发，成环节点被静默丢弃

- **位置**：`f_chart/src/IcicleChart.cj:94-111`（建树 + `roots.size != 1` 校验）、`:167-169`、`:183-185`（`depth > total` 守卫）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支/死守卫）、§11（静默丢数据）
- **证据**：静态确定 —— 从唯一根 DFS 的树最大深度为 `total-1`，`depth > total` 永不成立；环状父子关系（A.parent=B、B.parent=A）不产生无父节点，`roots.size` 仍为 1，也无法从根到达
- **描述**：最小复现：`root` + `a(parent=b)` + `b(parent=a)`。`roots.size == 1` 通过，`validateValues(root)` 碰不到 a/b，`layoutNode/drawNode` 也不会访问它们 ⇒ 三个节点只画出一个，没有异常。注释承诺的"节点关系存在环"错误路径不可达。
- **建议**：建 `children` 后先做一次父链环检测（每节点沿 `parentId` 走并计数，超 `nodes.size` 即判环），发现环抛 `chartInvalidValue`；同时删除两处恒假的 `depth > total` 守卫，避免误以为已有环保护。

### [一般][存量] M17 直方图规格与实现不符：`bins` 上界数组不支持、默认值不同、`normalize` 完全未实现

- **位置**：`f_chart/src/HistogramChart.cj:167-186`（只接受单个正整数，默认 `sqrt(n)`）、`:48-165`（`draw` 内无 `normalize` 读取，全文件 `grep -c normalize` = 0）
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）、§14（承诺了但没实现）
- **证据**：静态确定 —— 承诺源 `doc/chart-json-spec.md:758`：「`series[].bins`（分箱数或上界数组，默认 10）、`series[].normalize`（是否转为频率密度，默认 false）」；缺失证据：`HistogramChart.cj:170-177` 对非数字抛 "期望正整数"，`:179` 默认取 `sqrt(sampleSize)`，全文件无 `normalize`
- **描述**：照文档传 `bins: [0,10,20,30]` 会抛 `InvalidValue`；传 `normalize: true` 被静默忽略，输出仍是频数柱，但使用者按文档理解会读成密度——属于"不报错但口径错"。默认值 10 与实现的 `sqrt(n)` 也不一致（20 个样本时 4 箱 vs 文档 10 箱）。
- **建议**：二选一——实现上界数组（`bins: number[]` 走另一分支，`Array<Float64>` 边界）与 `normalize`（`count / (n * width)`）；或修改规格删掉这两项并把默认值写成 `sqrt(n)`。`normalize` 若保留，`computeHistogram`（`:230-263`）需接收归一化开关。

### [一般][存量] LassoPathChart 与 LearningCurveChart 的绘制骨架逐段重复

- **位置**：`f_chart/src/LassoPathChart.cj:38-214` 与 `f_chart/src/LearningCurveChart.cj:40-275`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名/换字段的重复逻辑）
- **证据**：静态确定 —— 两文件同构段落逐一对应：series 解析（`volcanoNumber` 取 x/y + `raw.add`）→ `sortLiftPoints` → min/max 与 3%/5% padding → `xMin/xMax/yMin/yMax` 校验 → ticks/tickLabels → `maxYLabelWidth` → `xLabelHeight` → `ChartFrame` → `LinearScale` → `SvgBuilder`/`ChartSvgKit` → legend 数组 → 折线 `M/L` 拼接 → 点 `circle` → `drawXAxisNumeric`
- **描述**：约 100 行同语义代码两份，真正的差异只有两处：是否画 `std` 带（LearningCurve `:80-114,220-237`）、默认系列名来源（`variables[i]` vs 序号）；连 `legendVisible` 条件都写成同一个 `series.size > 1`。第 3 条发现（std 未同步排序）正是这种复制粘贴后的局部改动遗漏。
- **建议**：抽 internal 的「XY 多系列折线管线」（解析 `{x,y}` 序列 → 范围 → 轴 → frame → legend → path/points），差异用参数表达（`std` 可选、默认名回调、图元 class 前缀不同）；落点放 `f_chart` 内部 util 文件，保持同包可见性。

### [一般][存量] `resolveLabels` 在 8 个图表中重复，其中两份仅错误文案不同

- **位置**：`f_chart/src/HeatmapChart.cj:206-221` 与 `CorrelationMatrixChart.cj:192-207`（逐行相同，仅 `"矩阵维度"` / `"矩阵阶数"` 不同）；同语义变体：`AreaChart.cj:295`、`BarRenderer.cj:287`、`DotChart.cj:188`、`HorizontalBarChart.cj:190`、`LineChart.cj:287`、`StackedAreaChart.cj:262`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 两份 `(labels, count, path)` 版本函数体一致（空则生成 `1..count`，非空则校验长度），6 份 `(labels, series)` 版本是"取最长序列长度生成 `1..n`"的同一逻辑
- **描述**：同一"缺省类别标签"策略散落 8 处，任何一处改默认格式（如改成 `"类别 1"`）都会产生不一致；错误消息也被复制成两份文案，未来容易漏改。
- **建议**：抽 `chartResolveLabels(labels, count, path, mismatchMessage)` 与 `chartGenerateLabels(count)` 到 f_chart 内部 util，各图调用并显式传文案；`(labels, series)` 版本先算 longest 再复用 `chartResolveLabels`。

### [轻微][存量] `HiveLink.value` 解析并校验后从不读取

- **位置**：`f_chart/src/HiveChart.cj:41-51`（字段与构造）、`:119-123`（解析 + `> 0` 校验）、`:193-199`（绘制只用 `source/target`，`strokeWidth: 1.2` 固定）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置字段）
- **证据**：静态确定 —— 全文件无 `link.value` / `.value` 读取，字段只在构造时赋值
- **描述**：规格 `doc/chart-json-spec.md:1550-1575` 的示例给了 `value`，但未说明语义，实现也没有映射到线宽/透明度。使用者以为权重会体现，实际所有连线等粗。
- **建议**：待确认设计意图——若要表达权重，按 `value/maxValue` 映射 `strokeWidth`（如 0.8~3.0）；若不需要，删除字段与校验，避免误导。

### [轻微][存量] LearningCurveChart 的 `metric` 校验后完全未使用

- **位置**：`f_chart/src/LearningCurveChart.cj:43-46`
- **来源**：存量
- **判据**：review-checklist §1（死配置字段）
- **证据**：静态确定 —— `metric` 只参与 `!= "score" && != "loss"` 判断，之后无任何引用
- **描述**：规格 `doc/chart-json-spec.md:2027` 只列出该字段、未写效果，因此无法断定"应有行为"（横轴标注？loss 轴反向？）——记为待确认；但当前状态是"接受参数、无任何作用"，容易让使用者误以为图已按 loss 语义渲染。
- **建议**：明确语义并接线（如 `metric == "loss"` 时轴标题/方向变化），或在规格中标注"仅作元数据、不影响渲染"。

### [轻微][存量] 恒假分支与等价冗余分支

- **位置**：`f_chart/src/HeatmapChart.cj:90-92`（`!hasValue`：每行非空必已赋值，不可达）；`f_chart/src/Histogram2DChart.cj:188-192`（循环内 `frequency > 0` 保证 `maxCount > 0`，else 恒不可达）；`f_chart/src/HistogramChart.cj:180-184`（`sqrt(sampleSize) < 1` 恒假，`sampleSize ≥ 1`）；`f_chart/src/HistogramChart.cj:210`（`maxCount > 0` 恒真）；`f_chart/src/HorizontalBarChart.cj:49-53`（`if (!labels.isEmpty()) labels else Array<String>()`，两支等价）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支、兼容残留）
- **证据**：静态确定 —— 上游均有"空数组即抛"的前置校验（`HeatmapChart.cj:59-61`、`HistogramChart.cj:67-69`、`Histogram2DChart.cj:92-94`）
- **描述**：五处分支不改变行为，只增加阅读成本；`Histogram2DChart.cj:188-192` 与 `HistogramChart.cj:210` 的 else 值（`0.0` / `1.0`）从未被使用，若将来有人调整上游校验而不改这里，会出现静默错误值。
- **建议**：删除不可达分支或改为断言；`HorizontalBarChart.cj:49-53` 直接写 `let labels = config.yAxis.labels`。

### [轻微][存量] "主题字号减常数"未做下限保护，可输出 0/负 `font-size`

- **位置**：`f_chart/src/InfluenceChart.cj:168`（`fontSize - 2.0`）、`f_chart/src/IcicleChart.cj:227`、`f_chart/src/HiveChart.cj:206`（`minFloat(fontSize - 2.0, nodeRadius * 0.9)`）、`f_chart/src/LiftChart.cj:165`（`fontSize - 1.0`）
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— `ChartTheme.parse`（`ChartTheme.cj:44`，范围外）对 `fontSize` 无下限校验，默认 12 但可配 0/1/负数；`nodeRadius` 只要 `> 0`（`HiveChart.cj:65-67`）即可
- **描述**：`theme.fontSize: 1` 时上列各处得到 -1/0，SVG `font-size` 为负非法（属性被忽略，文本按默认字号渲染），表现为标签突然变大或重叠。影响仅限文字观感，故定为轻微。
- **建议**：统一用 `maxFloat(1.0, fontSize - k)`；根因修复在 `ChartTheme.parse` 增加 `fontSize >= 1.0` 校验（属其他部分）。

### [轻微][存量] HorizontalBarChart 接受空数据数组，静默输出空图

- **位置**：`f_chart/src/HorizontalBarChart.cj:158-188`（`parseSeries` 不校验 `data` 非空）、`:190-205` + `:126-143`（生成 0 个标签、0 根柱）
- **来源**：存量
- **判据**：review-checklist §11（契约与同模块其他图表不一致）
- **证据**：静态确定 —— 同模块其余图表都有 `数据不能为空` 校验（如 `HistogramChart.cj:67-69`、`HeatmapChart.cj:45-47`、`InfluenceChart.cj:64-66`），本文件没有；`BandScale` 对 `count <= 0` 返回 `bandWidth = 0`（`ChartScale.cj:57`），不会抛错
- **描述**：`series: [{ "data": [] }]` 会渲染一张只有标题和坐标轴的空白图，调用方无法区分"没数据"与"数据全为 null"。
- **建议**：与同模块一致，`values.isEmpty()` 时抛 `chartInvalidValue("series[i].data", "数据不能为空")`。

### [轻微][存量] 测试辅助 `count` / `draw` 在 106/110 个测试文件中逐字重复

- **位置**：本部分 10 个测试文件 `HeatMap_test.cj:28-36`、`HeatmapChart_test.cj:28-36`、`Histogram2DChart_test.cj:28-36`、`HistogramChart_test.cj:28-36`、`HiveChart_test.cj:28-36`、`HorizontalBarChart_test.cj:29-37`、`IcicleChart_test.cj:28-36`、`InfluenceChart_test.cj:29-37`、`LassoPathChart_test.cj:28-36`、`LearningCurveChart_test.cj:28-36`
- **来源**：存量
- **判据**：review-checklist §2（同一函数体复制）
- **证据**：静态确定 —— `grep -l "private func count(svg: String, needle: String): Int64" *_test.cj` 命中 106 个文件，函数体完全一致（`while (let Some(index) <- svg.indexOf(needle, from))` 计数）；`private func draw(json: String)` 亦为每文件一段同构包装
- **描述**：单文件内无重复，属跨测试文件的模板复制；`needle.toArray().size` 每轮还新建数组，纯测试开销。合并建议需保留"测试类各自持有 `draw` 类型"的差异。
- **建议**：抽 `f_chart` 测试公共文件（如 `TestSvgSupport.cj`）提供 `svgCount(svg, needle)`，各测试类只保留 `draw` 包装；这是测试可维护性改进，不影响生产代码。

### [轻微][存量] 手写 SVG "M/L" 折线拼接在 20 个文件中重复

- **位置**：本部分 `f_chart/src/Histogram2DChart.cj:327-340`（`hexagonPath`）、`LassoPathChart.cj:186-202`、`LearningCurveChart.cj:221-238` 与 `:246-255`、`LiftChart.cj:171-180`
- **来源**：存量
- **判据**：review-checklist §2（字面量/结构复制）
- **证据**：静态确定 —— `grep 'append("M ${formatSvgNumber'` 在 `f_chart/src` 命中 20 个文件、26 处，模式统一为"首点 `M x y`、其余 ` L x y`、末尾可选 ` Z`"
- **描述**：`ChartSvgKit` 只有 `path(d)`（`ChartSvgKit.cj:194`），没有"点序列 → d"的封装，于是每个折线图各写一遍。任何格式调整（如改成相对坐标、加精度控制）需要改 26 处。
- **建议**：给 `ChartSvgKit` 增加 `polyline(points, close!, className!)` 或 `chartPathData(points, close)` 纯函数，先替换本部分 4 处，再逐步收敛其余图表。

### [轻微][存量] 通用排序工具寄生在具体图表文件 `LiftChart.cj`

- **位置**：`f_chart/src/LiftChart.cj:203-218`（`sortLiftPoints`）
- **来源**：存量
- **判据**：review-checklist §2（落点分层）/ §10 设计合理性
- **证据**：静态确定 —— 被 6 个其他图表调用：`CalibrationChart.cj:69`、`GainChart.cj:61`、`PdpChart.cj:62`、`LassoPathChart.cj:80`、`LearningCurveChart.cj:112`，加上 `LiftChart.cj:65` 自身
- **描述**：一个与 lift 语义无关的"按 x 稳定排序"函数定义在某个图表文件里，其他图表反向依赖它；查找时需要先知道它藏在 `LiftChart.cj`。排序算法本身是插入排序，复杂度问题见「优化可行性方案」。
- **建议**：移到 f_chart 内部 util 文件并改名（如 `sortPointsByX`），保留 `internal` 可见性以兼容现有调用。

### [轻微][存量] IcicleChart 支持 `frameHeight`，但 M53 规格未记录

- **位置**：`f_chart/src/IcicleChart.cj:121-124`（读取并校验 `frameHeight`，默认 18.0）；（对照）`doc/chart-json-spec.md:2299` 的 M53 专属字段只列 `orientation`、`colorBy`，同名字段在 M52 火焰图（`doc/chart-json-spec.md:2275`）有记录
- **来源**：存量
- **判据**：review-checklist §13 / §14.2（公开配置项未文档化）
- **证据**：静态确定 —— 代码读取该字段，M53 小节（`doc/chart-json-spec.md:2297-2320`）正文与示例均无 `frameHeight`
- **描述**：使用者按 M53 文档无法知道可以调层高；而调了又确实生效，属于文档覆盖缺口（不是实现缺陷）。
- **建议**：在 M53 小节的"专属字段"补齐 `frameHeight`（默认 18，且会被 `plot.height/(maxDepth+1)` 上限压缩，见 `IcicleChart.cj:131-138`）。

## 优化可行性方案

> 以下均为"还能更好"，不是缺陷。本部分没有改前基线数据，全部标 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] `sortLiftPoints` 用插入排序，被 7 个图表共用

- **现状**：`LiftChart.cj:203-218` 为插入排序，最坏 O(n²)：n=10k 时约 5×10⁷ 次比较 + 同量级 `ArrayList` 读写；调用方 6 个图表 + 自身，输入规模 = series 内点数（`LiftChart.cj:65`、`CalibrationChart.cj:69`、`GainChart.cj:61`、`PdpChart.cj:62`、`LassoPathChart.cj:80`、`LearningCurveChart.cj:112`）
- **方案**：移到内部 util 并改为 O(n log n) 稳定排序（归并，或 `std.sort` 的稳定版本；用 x 比较，等值时保持原序）
- **预期**：n ≥ 1k 时排序段从平方级降到 n log n；n=10k 约降两个数量级（排序段内部，不含端到端）
- **代价**：需确认标准库排序的稳定性语义（先查 `std.sort` 文档）；等值 x 的顺序必须不变，否则路径/带子的画法会变
- **验证**：`cjpm bench -O2`，同输入 n=1k/10k/50k，取中位数与离散度；对照改前改后
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] HiveChart / IcicleChart 的 O(n²) 查重与线性查父

- **现状**：`HiveChart.cj:87-91` 每加一个节点都线性扫已有节点查重（O(n²)）；`:113-118` 每条 link 两次 `findNode` 线性扫描（O(n·m)）；`:129-144` 分组按名字线性查重（O(n·g)）。`IcicleChart.cj:70-74` 同样 O(n²)，`:98-101` 每个节点线性 `findNode` 找父
- **方案**：一次遍历建 `Dictionary<String, Int64>`（id → 下标），查重、找父、找 link 端点全部 O(1)；分组用 `Dictionary<String, Int64>` 映射到组下标
- **预期**：建图从 O(n²+n·m) 降到 O(n+m)；1k 节点 + 1k 链接量级收益明显，小图无感
- **代价**：多一个字典的内存（n 项）；插入顺序仍需保持，分组数组遍历顺序不能变（用下标数组维持原序）
- **验证**：`cjpm bench -O2`，节点 1k/5k/20k（链式与星形两种分布），记录端到端耗时中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] HeatmapChart 每个单元格重复解析三个颜色字符串

- **现状**：`HeatmapChart.cj:156` 在 `row × column` 双层循环内调用 `heatmapColor`，后者在 `:233-235` 对 low/mid/high 各做一次 `SvgColor.tryParse`（字符串解析 + 对象分配），末尾还 `toString()` 生成新字符串；100×100 矩阵 = 3 万次解析 + 1 万次格式化
- **方案**：在 `draw` 循环外解析一次 `SvgColor`（并保留一个接 `SvgColor` 的 internal 重载），循环内只做通道插值与字符串拼接；颜色字符串可复用同一 `StringBuilder`
- **预期**：颜色解析次数 3N → 3；解析段 CPU 与年轻代分配随之下降（端到端占比未测）
- **代价**：`heatmapColor(ratio, low, mid, high)` 是 internal 且被 `HeatmapChart_test.cj:100-102` 直接调用，需保留原签名或同步改测试
- **验证**：`cjprof record` 看 `parseHeatmapColor`/`SvgColor.tryParse` 自耗时占比；`cjpm bench` 100×100、500×500 矩阵对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] HeatmapChart 的矩阵用 `ArrayList<Array<Float64>>`，行对象与整表拷贝各一份

- **现状**：`HeatmapChart.cj:48-89` 每行先建 `ArrayList<Float64>` 再 `row.toArray()` 存入外层 `ArrayList`，最后一次 `matrix[r][c]` 访问；行数 R 时多 R 个 `Array` 对象头，且每行发生一次全量复制（峰值时旧 `ArrayList` 与 `Array` 同时在世）
- **方案**：改用单块 `Array<Float64>(R*C, repeat: 0.0)` 平铺存储，读取用 `r*C + c`；行长度校验改为对平铺索引取模校验
- **预期**：堆对象数 R+1 → 1；峰值少一次 R×C 的浮点复制（R=C=1000 约 8MB）
- **代价**：索引计算替代二维下标，可读性下降；越界从"行数组越界"变成"平铺偏移越界"，需保留现有报错路径文案
- **验证**：多轮渲染下 `getAllocatedHeapSize()` 与 RSS 对照，配 `getUsedHeapSize()` 峰值；同输入 100×100、1000×1000
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `heatmapColor` 的重复颜色解析是热力图主要 CPU 段 | `f_chart/src/HeatmapChart.cj:156`、`:233-235` | 自耗时占比 | `cjprof record` 渲染 1000×1000 矩阵，取 `SvgColor.tryParse` 与 `heatmapColor` 的 self time |
| 2 | 插入排序在万级点数的系列上已有可感知开销 | `f_chart/src/LiftChart.cj:203-218` | 排序段耗时与占比 | `cjpm bench -O2`，n=1k/10k/50k，单独计时排序前后 |
| 3 | HiveChart 在千级节点/链接时 O(n²) 建图成为瓶颈 | `f_chart/src/HiveChart.cj:87-144` | 建图段耗时 | 5k 节点 + 5k 链接 profile，量 `findNode` 调用次数与累计耗时 |
| 4 | IcicleChart 深链的实际爆栈阈值 | `f_chart/src/IcicleChart.cj:192-244` | 崩溃深度 | 生成 1k/5k/10k 层链式 `nodes`，逐级试渲染，记录首个崩溃深度与平台栈大小 |
| 5 | 矩阵/点数组适合 local mode，能降峰值内存 | `f_chart/src/HeatmapChart.cj:48-89`、`f_chart/src/Histogram2DChart.cj:95-109` | 峰值内存与逃逸结论 | 开启 `--experimental --enable-local-mode` 后对比 `getUsedHeapSize()` 峰值与 `getAllocatedLocalObjectSize()`；确认 `matrix`/`points` 不逃逸出 `draw` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/HeatMap_test.cj` | .cj | ✅ | 测 `HeatMap.cj` 的 `HeatMapChart`（`heat-map`），含 `count` 模板重复（§2） |
| 2 | `f_chart/src/HeatmapChart.cj` | .cj | ✅ | 见发现 #12（死分支）、#4（cellGap）、#9（resolveLabels 重复）、优化方案 3/4 |
| 3 | `f_chart/src/HeatmapChart_test.cj` | .cj | ✅ | 覆盖矩阵/标签/负值；未覆盖 `cellGap` 过大与轴范围覆盖 |
| 4 | `f_chart/src/Histogram2DChart.cj` | .cj | ✅ | 见 #1（无界 bins）、#2（轴范围）、#12（死分支） |
| 5 | `f_chart/src/Histogram2DChart_test.cj` | .cj | ✅ | 覆盖 bins=0/shape/多系列；未覆盖超大 bins 与溢出 |
| 6 | `f_chart/src/HistogramChart.cj` | .cj | ✅ | 见 #1、#2、#7（规格不符）、#12（死分支） |
| 7 | `f_chart/src/HistogramChart_test.cj` | .cj | ✅ | 覆盖分箱/最大值归末箱/空数据；无 `normalize`、数组 bins 用例 |
| 8 | `f_chart/src/HiveChart.cj` | .cj | ✅ | 见 #10（value 未用）、#13（字号下限）、优化方案 2 |
| 9 | `f_chart/src/HiveChart_test.cj` | .cj | ✅ | 覆盖节点/链接计数、非法半径、重复 id |
| 10 | `f_chart/src/HorizontalBarChart.cj` | .cj | ✅ | 见 #2（0 基线）、#4（barWidth）、#14（空数据）、#9（resolveLabels） |
| 11 | `f_chart/src/HorizontalBarChart_test.cj` | .cj | ✅ | 覆盖负值类名、null 跳过、SVG 可解析；无 barWidth 用例 |
| 12 | `f_chart/src/IcicleChart.cj` | .cj | ✅ | 见 #5（递归）、#6（环检测失效）、#18（frameHeight 文档缺口） |
| 13 | `f_chart/src/IcicleChart_test.cj` | .cj | ✅ | 覆盖 7 节点/方向/多根/子值超父；无环、无深链用例 |
| 14 | `f_chart/src/InfluenceChart.cj` | .cj | ✅ | 见 #13（字号下限）；范围/tick/图元实现正常 |
| 15 | `f_chart/src/InfluenceChart_test.cj` | .cj | ✅ | 覆盖半径映射、负 Cook 距离、缺 series |
| 16 | `f_chart/src/LassoPathChart.cj` | .cj | ✅ | 见 #2（零线）、#8（与 LearningCurve 重复）、#16（path 拼接） |
| 17 | `f_chart/src/LassoPathChart_test.cj` | .cj | ✅ | 仅 4 个用例（路径计数、图例、空数据、类型），无确定性/可解析/轴范围用例，覆盖面明显低于同批其他图表 |
| 18 | `f_chart/src/LearningCurveChart.cj` | .cj | ✅ | 见 #3（std 未同步排序）、#11（metric 未用）、#8、#16 |
| 19 | `f_chart/src/LearningCurveChart_test.cj` | .cj | ✅ | 覆盖带子/缺 std/长度不符/非法 metric；数据均有序，测不出 #3 |
| 20 | `f_chart/src/LiftChart.cj` | .cj | ✅ | 见 #16（path）、#17（sortLiftPoints 位置）、#13（字号） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：#2、#3、#4、#5、#6；设计合理性：#8（重复骨架）、#17（工具函数错位）；可读性/可维护性：#12（恒假分支）、#15/#16（模板重复）；安全性：无外部字符串直接进 SVG 属性（数值经 `formatSvgNumber`、文案仅在 `<text>` 内且 `SvgBuilder` 负责转义），未命中注入类问题 |
| §1 死代码 | 4 | 逐个 `private`/`internal` 符号全仓搜引用（20 个 `private` 方法、17 个 `internal` 类型/函数均已核对，除下文列出的字段与分支外均有调用者）；命中：`HiveLink.value` 未读、`metric` 未用、5 处恒假/等价分支、Icicle 两处恒假守卫。对外可达 `public`（`*Chart.draw`）不判 |
| §2 重复逻辑 | 5 | 已两两比对本部分 10 个 `draw` 与全部私有方法：`resolveLabels` 8 份、LassoPath/LearningCurve 骨架、`count`/`draw` 测试模板 106 处、`M/L` 路径 26 处、`sortLiftPoints` 错位分层 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；测试里的 `try/catch` 均断言 `ChartErrorKind`，空分支 `case None => ()` 均为可选字段缺省（`bins`/`std`/`color`），语义合法 |
| §4 栈溢出 | 1 | 仅 IcicleChart 四个递归函数（#5）；其余图表均为循环实现，无自引用结构、无递归打印/比较 |
| §5 OOM | 1 | 分箱数无上界（#1）；矩阵/节点数组规模与输入 JSON 同阶，不构成放大，未单列 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据，热点结论不成立；5 条候选已全部降级到「待验证假设」，无一条写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无并发容器 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池；全部为单次同步渲染 |
| §6.4 低效算法 | 2 | 插入排序 `sortLiftPoints`、Hive/Icicle 的 O(n²) 查重查父；因缺耗时占比，按规则放进优化方案（无基线），不计入缺陷 |
| §7 降堆内存方案 | 1 | HeatmapChart 矩阵扁平化（无基线） |
| §8 降 CPU 方案 | 3 | 稳定排序、字典索引化、颜色解析外提（均无基线） |
| §9 local mode 可行性 | 0 | 无改前改后峰值内存数据，`matrix`/`points` 是否逃逸未验证；只写进「待验证假设 #5」，不写成建议 |
| §11 现有代码的 BUG（存量） | 6 | 本部分 20 个文件全部为存量：#2、#3、#4、#6、#14，加上 #1 的上界缺失。所有结论均给出触发输入或前置校验缺失点 |
| §12 并发安全与锁粒度 | 0 | 10 个 `Chart` 实现均无成员字段，`draw` 的全部状态是局部变量；`HiveNode`/`IcicleNode`/`Point2D` 等在每次调用内新建，无线程共享路径（线程封闭成立），因此无共享可变状态、无锁粒度问题 |
| §14 功能完备性与 README 覆盖 | 2 | `normalize` 承诺未实现（#7）；`frameHeight` 代码支持但 M53 规格未记录（#18）。其余 10 个类型字符串与 `doc/chart-json-spec.md:147-243` 的映射逐项一致 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完；本部分无 `.md`，文档一致性以 `doc/chart-json-spec.md` 对应小节（147/323/756/906/1188/1550/1701/1957/2025/2043/2297）作对照 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量 18 条，是否纳入修复待用户决定。

## 总评

本部分 10 个图表实现风格高度统一：都走 `ChartConfig.parse` 校验 `type`、都有"缺字段/类型/负值/空集合"的显式异常和对应测试，`draw` 无成员状态、无线程共享，因此没有并发与句柄资源面的风险；数值到 SVG 的格式化统一走 `formatSvgNumber`，也没有注入面。真正的阻塞项只有一个：**分箱数无上界**，一个字段就能把进程打到 OOM，`binsX*binsY` 溢出时还会退化成越界崩溃（#1），建议优先修。其次是两类"图会画错但不报错"的问题：轴范围被 `min/max` 覆盖后图元不裁剪、不重算（#2），以及 LearningCurveChart 只排序点不排序 `std`（#3）——前者影响面广（4 个图表），后者只在乱序输入下出现，现有用例都覆盖不到，建议各补一条边界用例。IcicleChart 的递归与失效环检测（#5、#6）属于输入极端才会触发，可排期处理。重复逻辑方面最值得动手的是 LassoPath/LearningCurve 的绘制骨架（#9），#3 就是复制后漏改的直接后果；`resolveLabels`、测试 `count`、`M/L` 拼接属于"改一次要改 N 处"的维护成本，可随下次改动顺带收敛。规格漂移集中在 M17 直方图（#7），需要产品或用户拍板是补实现还是改文档。

范围外提示（不计入本部分统计）：`ChartFrame.drawXAxis`（`ChartFrame.cj:204-243`）与 `drawXAxisNumeric`（`:278-322`）几乎逐行相同；`ChartTheme.parse`（`ChartTheme.cj:44`）未校验 `fontSize` 下限，是 #13 的根因。
