# f_chart 模块审查报告（模块第 35/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个源文件：SwarmChart / SwimlaneChart / TimelineChart / TreemapChart / ViolinBoxChart / ViolinChart / VolcanoChart / WaffleChart / WaterfallChart 及其测试）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1（本文件只是第 35 部分分报告，`docs/review/` 下的模块报告由主 Agent 合并）

## 发现

### [严重][存量] 矩形树图切分错误：面积不按权重，约 38% 画布空白

- **位置**：`f_chart/src/TreemapChart.cj:230`（`let childWidth = width * ratio`）、`:238`（`let childHeight = height * ratio`），循环 `:230-243`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（与规格/README 冲突）+ §6.4（算法实现与声明不符）
- **证据**：静态确定 —— 已入库渲染产物 `f_chart/charts/M034-treemap.svg` 实测（`width=760,height=480`，绘图区 672×352 = 236 544 px²）：
  - `lib`（值 260）329.66×352 = 116 040 px²
  - `bin`（值 120）152.15×111.16 = 16 913 px²
  - `log`（值 90）114.11×99.62 = 11 368 px²
  - `cache`（值 60）76.08×39.85 = 3 031 px²
  - 值比 260:120 ≈ 2.17:1，面积比 116 040:16 913 ≈ 6.86:1；四格合计仅 147 352 px²，**37.7% 绘图区为空白**
- **描述**：切分时子块宽/高用**父级全尺寸**乘「占父级总值的比例」，而不是用「占剩余面积的比例」；用掉一条边后另一个方向仍按全尺寸算，导致先画的子块吃掉几乎整个矩形、后面的子块只剩窄条，且剩余空间不再分配。treemap 的唯一编码方式就是「面积 ∝ 数值」，该实现使面积失真 3 倍以上并留下大片空白，直接违背 `README.md:1450`「层级节点按权重铺满父矩形」。
- **建议**：按剩余量递归：维护 `remainingValue`（未分配子节点值之和）与 `remainingWidth/remainingHeight`，每次 `ratio = nodeValue(child) / remainingValue`，并沿当前较长边切分（squarify 的 strip 版）；补充「面积 = 值 × 单位面积」的几何断言测试（见轻微 #4）。

### [严重][存量] 时间线 `group` 着色哈希溢出抛 ArithmeticException（非 ChartException）

- **位置**：`f_chart/src/TimelineChart.cj:209`（`hash = hash * 31 + Int64(rune.position())`，函数 `eventColor` `:204-214`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界/数值溢出）+ §10（异常契约）
- **证据**：静态确定 —— `f_chart/cjpm.toml` 的 `compile-option = "--dy-std -O2"` 未设 `--int-overflow`，默认 `throwing`（文档 `cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/compile_options.md:233-239`：「指定固定精度整数运算的溢出策略，默认为 throwing…溢出时会抛出异常」）。按 `hash_n ≈ c·31ⁿ/30` 估算：ASCII（c≈100）第 12 个字符后 hash ≈ 2.6e18，第 13 个字符乘 31 即 > 9.22e18；汉字（c≈20000）第 12 个字符后 ≈ 5.2e17，第 13 个字符同样溢出。即 **group 名约 13 个字符就触发**
- **描述**：`events[].group` 是普通字符串标签（`doc/chart-json-spec.md:2221` 明确 `group?`）。名字稍长（如「2026年第一季度营销活动」13 字）时 `hash * 31` 整数溢出，抛 `ArithmeticException`；`Chart.draw` 契约只承诺 `ChartException`（`Chart.cj:33`、`README.md:41`），调用方按 `ChartException` 捕获会漏掉，整个渲染线程异常退出。第 211 行 `config.theme.colorAt(abs(hash))` 在 `Int64.MinValue` 上还会二次溢出/产生负下标（`ChartTheme.colorAt` 用 `index % palette.size`，负数取模仍为负）。
- **建议**：逐步取模，照抄同模块已有写法 `f_chart/src/FlameChart.cj:258`（`hash = (hash * 31 + Int64(byte)) % 1000003`），再 `colorAt(hash)`；或改用 `&*`/`&+` 回绕运算符并显式取 `abs` 前的掩码。补一个 13+ 字符 group 的用例。

### [严重][存量] 矩形树图递归深度由输入决定，深链会栈溢出；`nodeValue` 使每层重复遍历子树

- **位置**：`f_chart/src/TreemapChart.cj:191`（`layoutNode` 递归 `:234`、`:239`）、`:159-172`（`nodeValue` 递归 `:168`）、`:174-189`（`sortChildren` 比较器内 `:181` 反复调 `nodeValue`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4（无界递归）+ §6.4（重复计算）
- **证据**：静态确定 —— 递归深度 = 父子链长度，代码无深度计数、无迭代化、无访问集合；仓颉不保证尾调用优化。按 1 万层链估算：`nodes` 数组 1 万条（JSON ≈ 0.8 MB，完全可解析）即可达 1 万层，`layoutNode` 每帧含 6 个 `Float64` 形参 + 局部变量（数百字节量级）⇒ 数 MB 级栈占用，超过常见线程栈（具体字节数按 SDK/平台待确认）
- **描述**：两处递归叠加：`layoutNode` 每层调用 `nodeValue(node)` 重算整棵子树之和，深链上总代价 O(depth²)；`sortChildren` 的插入排序比较器也每次重算 `nodeValue`。深链既可能先爆栈，也会在爆栈前先表现为二次复杂度耗时。
- **建议**：一次后序遍历把 `value` 缓存进 `TreemapNode`（加 `var total: Float64`），排序前预计算排序键；`layoutNode` 改为显式栈迭代（节点 + 矩形入栈），或加深度上限（如 64 层）超限抛 `InvalidValue`。

### [一般][存量] `TreemapChart` 用实例字段保存绘制状态，违反 `Chart` 纯函数契约

- **位置**：`f_chart/src/TreemapChart.cj:46`（`private var leafIndex: Int64 = 0`）、`:141`（`this.leafIndex = 0`）、`:201-202`（`colorAt(this.leafIndex)` / `this.leafIndex++`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）+ §12.1（共享可变状态）
- **证据**：静态确定 —— `Chart` 契约写明「实现必须保持纯函数语义：不修改 `data`，同一输入产生确定性输出」（`f_chart/src/Chart.cj:24-25`）；本实现在 `draw` 中写 `this.leafIndex`
- **描述**：`draw` 不是纯函数：①同一实例被并发调用时两个线程共享 `leafIndex++`，颜色分配互相污染（确定性输出被破坏）；②`draw` 中途抛异常后实例状态遗留（下次 `draw` 虽会重置，但重入调用会错乱）；③仓内无共享实例的用例，宿主持有单例时才会暴露 ⇒ 并发后果 **待确认**（缺：下游是否缓存 Chart 实例）
- **建议**：`leafIndex` 作为 `layoutNode` 的入参/返回（`func layoutNode(..., leafIndex: Int64): Int64`），或把整个绘制状态收进 `draw` 内的局部 `var`；顺便删掉这个字段。

### [一般][存量] 矩形树图静默丢节点：父链成环、叶子缺 `value` 均无提示

- **位置**：`f_chart/src/TreemapChart.cj:104-117`（只校验 `roots.size == 1`）、`:159-164`（叶子无 `value` 时返回 `0.0`）、`:222-224`（`total <= 0.0` 直接 `return`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失/静默）+ §14.1（规格要求未校验）
- **证据**：静态确定 —— 构造 `root(parent:null)` + `a(parent:"b")` + `b(parent:"a")`：`roots` 仍只有 `root`，校验通过，`a/b` 既不是根也不在 `root` 子树中，`layoutNode` 遍历不到，**不绘制、不报错**。规格要求「叶子必须有 `value`」（`doc/chart-json-spec.md:1318`），但缺失时按 0 处理，子块面积为 0 被静默跳过
- **描述**：两种输入错误都表现为「图少了几块」，使用者得不到任何错误信号，且与同文件对重复 id / 悬空 parent 的严格校验（`:71-75`、`:107-111`）不一致。
- **建议**：解析阶段对叶子强制 `value`（缺失即 `InvalidValue`）；布局前做一次可达性遍历，`visited.size != parsed.size` 时抛 `InvalidValue("nodes", "存在环或不可达节点")`。

### [一般][存量] 火山图 y 轴上下翻转，阈值区与着色区自相矛盾

- **位置**：`f_chart/src/VolcanoChart.cj:157`（`LinearScale(axisMinY, axisMaxY, frame.plot.bottom(), frame.plot.y)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（与规格/注释冲突；渲染方向错误）
- **证据**：静态确定 —— `LinearScale` 自述「`topPixel` 对应最大值，`bottomPixel` 对应最小值」（`f_chart/src/ChartScale.cj:22`），此处把 `plot.bottom()` 当 `topPixel` 传入。已入库产物 `f_chart/charts/M092-volcano.svg` 实测：刻度 `0` 在 y≈-5.8（画布顶），`5` 在 y≈495.8（画布底）；`GENE1`(y=4.1) 圆心 cy=405，`GENE3`(y=0.8) 圆心 cy=74；p 阈值线在 y=124.6
- **描述**：数值越大越靠下，y 轴刻度自上而下递增，与 `README.md:2055`「纵轴为 -log10(p)」及全模块其余图（如 M020 violin 的 0 在 y=432、150 在 y=56）相反。结果是红色「上调」点落在 p 阈值线**下方**、灰色「不显著」点落在线**上方**，同一张图里颜色语义与视觉分区互相冲突，读者会把显著性判反。
- **建议**：改为 `LinearScale(axisMinY, axisMaxY, frame.plot.y, frame.plot.bottom())`；补一个断言「高 y 点 cy 更小」的用例（见轻微 #4）。

### [一般][存量] 华夫图 `cells` / `columns` 无上界：输出体积按格数线性放大，网格可溢出画布

- **位置**：`f_chart/src/WaffleChart.cj:41-50`（只校验 `>= 1` 且为整数）、`:97-107`（`rows`、`cellSize`、`gridWidth`）、`:120-138`（按 `cells` 循环出矩形）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（OOM，须量化）+ §11（缺边界校验）
- **证据**：静态确定 + 输出体积实测 —— 已入库 `f_chart/charts/M073-waffle.svg` 为 100 格 13 963 B，约 **140 B/格**；`cells: 1000000`（20 字节 JSON）⇒ SVG 字符串 ≈ 140 MB，`toSvgString()` 再整体复制一次 ⇒ 峰值 ~280 MB；`cells: 10000000` ⇒ GB 级，必然 OOM 或长时间阻塞。同一处 `columns: 10000` 时 `cell` 被 `maxFloat(..., 1.0)` 钳到 1 px，`gridWidth = 10000 + 2×9999 ≈ 3×columns` px，远超画布，图整体不可见（`WaffleChart.cj:99-107`）
- **描述**：`cells` 只是「总格数」样式参数（默认 100），实现把它当作渲染元素个数且无上限、无「画布能容纳多少格」的钳制。若图表 JSON 来自外部/用户配置（`待确认`），这是一个 7 个数量级的放大面；即使配置可信，误写 `cells: 100000` 也会产出 14 MB SVG。
- **建议**：给 `cells`（如 ≤ 10000）与 `columns`（如 ≤ 200）显式上限并在超限时抛 `InvalidValue`；或按 `plot` 尺寸反推最大可容纳格数 `floor(plot.width/最小格宽) × floor(plot.height/最小格高)` 后钳制，并在 SVG 里注明已降采样。

### [一般][存量] 矩形树图/华夫图自绘标题与图例，绕过 `ChartFrame` 且行为漂移（`subtext`、`align` 丢失）

- **位置**：`f_chart/src/TreemapChart.cj:131-140`（自绘标题）、`f_chart/src/WaffleChart.cj:140-168`（自绘图例）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（跨文件复制同一布局规则导致行为漂移）+ §11（契约不符）
- **证据**：静态确定 —— `ChartFrame.drawTitle`（`f_chart/src/ChartFrame.cj:98-132`）处理 `titleAlign`、`subtitle`，基线为 `padding.top + titleFontSize/2`；`TreemapChart` 固定 `anchor: "middle"`、基线 `padding.top + titleFontSize`，且完全不读 `config.subtitle`/`config.titleAlign`。已入库产物对照：M034 标题 y=42，M092/M016 标题 y=33。`WaffleChart` 自绘图例的换行阈值、色块尺寸（`:150-158`）与 `ChartFrame.drawLegend`（`:134-166`）另一套，且预留高度 28 与 `ChartFrame` 的 26（`:79`、`:88`）不一致
- **描述**：规格承诺 `title.subtext` 与 `title.align` 对全图生效（`doc/chart-json-spec.md:43-44`），矩形树图静默忽略；同一标题在两种图里高度差 9 px。属「重复逻辑导致的行为漂移」，后续修 `ChartFrame` 也修不到这两张图。
- **建议**：`TreemapChart` 改用 `ChartFrame` + `frame.drawTitle(kit)`（绘图区用 `frame.plot` 再内缩即可）；`WaffleChart` 改用 `frame.drawLegend` 或在 `ChartFrame` 中加「带数值/可换行」的可选参数，避免第三套图例布局。

### [一般][存量] 单系列图表把「输入解析 + 数值工具」整段复制到 4 个文件（逐字节相同）

- **位置**：
  - `parseValues`：`f_chart/src/SwarmChart.cj:187-199`、`f_chart/src/ViolinBoxChart.cj:267-279`、`f_chart/src/ViolinChart.cj:240-252`（`diff` 结果逐字节相同）
  - `resolveYRange`：`SwarmChart.cj:201-216`、`ViolinBoxChart.cj:281-296`、`ViolinChart.cj:254-269`（逐字节相同）
  - `sortValues`（插入排序）：`SwarmChart.cj:218-233`、`ViolinBoxChart.cj:298-313`、`ViolinChart.cj:271-286`（逐字节相同）
  - 「series 必须为长度 1 的对象 + 嵌套/扁平分组」前导块：`SwarmChart.cj:45-99`、`ViolinChart.cj:45-99`、`ViolinBoxChart.cj:45-99`（`diff` 仅差类型名 `SwarmGroup`/`ViolinGroup`/`ViolinBoxGroup` 与错误文案里的图名前缀）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（「只改类型名」/「字面量复制」）
- **证据**：静态确定 —— `sed` 取段后 `diff` 三次均无差异（parseValues/sortValues/resolveYRange）；前导块 `diff` 仅 3 处类型名 + 1 处文案差异
- **描述**：同一套「只允许一个系列、嵌套数组与扁平数组二选一、标签长度校验、5% padding 的 y 范围」规则在 4 个文件各写一遍，任何一处修（例如给 `resolveYRange` 加 `isNaN` 校验、把插入排序换成标准排序）都要改 4 遍，现实是已经出现漂移：`BoxScatterChart.cj` 的同名私有函数也是同一份拷贝。范围外的 `ProbabilityChart.cj:156`、`QQChart.cj:156` 的 `sortValues` 同体。
- **建议**：在 `f_chart/src` 内新增包内工具（如 `ChartSeries.cj`：`chartParseSeries`、`chartValues`、`chartResolveYRange`、`chartSortValues`），落点遵守「通用能力留在本模块 util」；`SwarmGroup/ViolinGroup/ViolinBoxGroup` 三个只有 `name+values` 的类可合并为一个 `NamedValues`。

### [一般][存量] 小提琴图与「小提琴+箱线图」的核密度轮廓绘制 47 行逐字节相同

- **位置**：`f_chart/src/ViolinChart.cj:165-211` 与 `f_chart/src/ViolinBoxChart.cj:166-212`（`diff` 仅差 `className: "violin"` / `"violin-box-violin"`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复 → 行为漂移风险）
- **证据**：静态确定 —— 两段 `sed` 后 `diff` 只有第 45 行 className 不同；两图 90% 的 `draw` 主体（解析、y 范围、坐标框、图例、KDE 采样 41 点、路径拼接）同样对齐，差异点仅：`showOutliers`/须线与端帽、箱宽 0.1 vs 0.12、`quantileSorted` vs `boxScatterBounds`
- **描述**：`violin` 是 `violin-box` 关闭箱线与异常值的特例，现在是两份实现：`violin-box` 的采样点数、填充透明度、路径拼接方式一旦修改，`violin` 不会同步。两图测试也只覆盖各自的 class 名，漂移无法被发现。
- **建议**：把「组解析 + KDE 轮廓 path」抽成包内函数（如 `chartViolinPath(group, center, maxHalf, yScale, bandwidth): String`），两图共用；或让 `ViolinChart` 内部委托 `ViolinBoxChart` 的绘制步骤并传 `showBox=false, showOutliers=false`（需先把 className 参数化，避免破坏已入库 SVG 的 `class` 契约）。

### [一般][存量] `tiling` 只实现 `squarify`，规格承诺的 `slice` 直接报错

- **位置**：`f_chart/src/TreemapChart.cj:118-121`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现）
- **证据**：静态确定 —— 承诺源 `doc/chart-json-spec.md:1318`「专属字段：`tiling`（`squarify` / `slice`，默认 `squarify`）」；实现 `if (tiling != "squarify") { throw chartInvalidValue("tiling", "目前仅支持 squarify") }`，全仓搜 `"slice"` 在 `f_chart/src` 无命中
- **描述**：按规格写 `"tiling": "slice"` 的调用方会收到 `InvalidValue`。要么补实现（slice-and-dice 只需按单一方向切分，代码量很小），要么把规格改成只列 `squarify`。
- **建议**：补 `slice` 分支（沿长边单方向顺序切分），或在 `doc/chart-json-spec.md` 与 README 中删掉 `slice` 并说明「仅支持 squarify」。

### [轻微][存量] 未使用的通配 import `std.math.*`

- **位置**：`f_chart/src/SwimlaneChart.cj:19`、`f_chart/src/TreemapChart.cj:19`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 两个文件内搜 `abs(|floor(|ceil(|round(|sqrt(|pow(|log10(|minFloat(|maxFloat(` 均无命中，文件内只有 `Float64` 算术
- **描述**：通配 import 不报错但会扩大名字解析面，也掩盖真实依赖。
- **建议**：删除这两行。

### [轻微][存量] 泳道名不做截断，长名压到节点区

- **位置**：`f_chart/src/SwimlaneChart.cj:182-189`（横向泳道名）、`:198-206`（纵向泳道名）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性/渲染边界）
- **证据**：静态确定 —— 横向预留 `laneLabelWidth = 90.0`（`:169`），但泳道名直接用 `kit.text(...)` 全量输出，没有 `orgFitLabel`；同文件的节点标签用了截断（`:319`）
- **描述**：泳道名超过约 7 个汉字就画进节点区，与节点矩形重叠；同一张图里节点标签会省略、泳道标签不会，规则不一致。
- **建议**：泳道名套 `orgFitLabel(lane.name, laneLabelWidth - 16.0, fontSize)`。

### [轻微][存量] 瀑布图标签优先规则写了两遍，`starts/ends` 该用 `let`

- **位置**：`f_chart/src/WaterfallChart.cj:106-111`（`defaultName` 用 `labels[index]`）与 `:132-135`（`axisLabels` 又用 `labels[position]` 覆盖 `points[position].name`）；`:118-119`（`var starts` / `var ends` 从未重新赋值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同一规则复制）+ §1（`let`/`var` 惯用法，轻微）
- **证据**：静态确定 —— 两处都表达「xAxis.labels 优先于 item.name」；`starts`/`ends` 只调 `.add()`，可变性只需容器内部可变
- **描述**：规则改一处漏一处就会导致刻度名与柱名不一致；`var` 让读者以为会被整体重新赋值。
- **建议**：`axisLabels` 直接用 `points[position].name`（保留 `name` 缺省即用 `labels[index]` 的既有规则），删除重复循环；两处改 `let`。

### [轻微] 本部分测试只断言 class 名出现次数，几何/方向类缺陷零覆盖

- **位置**：`f_chart/src/TreemapChart_test.cj:59-61`、`f_chart/src/VolcanoChart_test.cj:65`、`f_chart/src/SwarmChart_test.cj:51`、`f_chart/src/SwimlaneChart_test.cj:68-69`、`f_chart/src/WaterfallChart_test.cj:63-66`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可测试性）+ 本报告严重 #1、#3 与一般 #3 均因此未被发现
- **证据**：静态确定 —— 测试全部用 `count(svg, "class=\"...\"")` 计数或 `contains(text)`，没有任何 `<rect>` 坐标/面积、`cy` 相对顺序的断言
- **描述**：本报告列出的「面积不按权重」「y 轴翻转」都能在保持 class 计数不变的前提下存在，因此测试通过不代表渲染正确。
- **建议**：为 treemap 加「面积比 ≈ 值比（误差 ≤ 1%）」「所有子块面积之和 == 绘图区面积」；为 volcano 加「y 更大的点 cy 更小」；为 waffle 加「cells 超上限抛 InvalidValue」。
- **备注**：`f_chart/src/WaterfallAlias_test.cj` 与本模块 `WaterfallChart_test.cj` 高度重复，但已核对为设计约定（`README.md:726`「别名：M87 也使用 `waterfall`，复用 `WaterfallChart`」、`doc/spec/add-f-chart-calendar-alias/design.md:13`「别名里程碑的预期冗余」），**不计入重复逻辑问题**。

## 优化可行性方案

> 以下均无改前/改后基线，只登记为下一轮补数据的候选，不进修复清单。

### [CPU] `sortValues` 插入排序 + 树图比较器内重算子节点和

- **现状**：`sortValues` 在 4 处实现为插入排序（`SwarmChart.cj:218`、`ViolinBoxChart.cj:298`、`ViolinChart.cj:271`、范围外 `BoxScatterChart.cj:245`），输入是用户 JSON 里的原始数值序列，元素个数无上限；treemap 的 `sortChildren` 是插入排序且比较时调 `nodeValue`（`TreemapChart.cj:179-187`），单次比较 O(子树)
- **方案**：改为标准库排序（预计算排序键），`nodeValue` 结果缓存到节点
- **预期**：插入排序最坏 O(n²)；1 万点乱序输入时比较次数从 ~5×10⁷ 降到 ~1.3×10⁵ 量级（理论值，未测）
- **代价**：需要一次额外数组（n 个 `Float64` 键）；排序稳定性若被依赖需显式指定
- **验证**：`cjpm bench -O2` 同输入（1k/10k 随机与升序两种分布）对照中位数与 P95；`cjprof record` 看 `sortValues`/`nodeValue` 自耗时占比
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 泳道图/树图按 id 线性查找，整体 O(n²)

- **现状**：`SwimlaneChart` 重复 id 检查 `:91-95`、`:114-118` 对每条记录线性扫已有列表；每条边两次 `findSwimNode`（`:241-242`），`findSwimNode` 自身 O(n)（`:341-348`）⇒ 建图阶段 O(n² + n·e)。`TreemapChart.findNode`（`:150-157`）对每个节点线性扫一次 ⇒ O(n²)
- **方案**：解析时建 `HashMap<String, Int64>` 索引（id → 序号），重复检查与端点解析都走哈希
- **预期**：5 千节点/1.5 万边时比较次数从 ~7×10⁷ 降到 ~2×10⁴（理论值，未测）
- **代价**：多一份 id 索引（~n 个字符串引用），生命周期限于 `draw`
- **验证**：构造 5k 节点、15k 边的泳道图，`cjpm bench -O2` 对照构建耗时；确认输出 SVG 逐字节相同
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 点图逐点生成独立 `<g>`，SVG 缓冲随点数线性膨胀

- **现状**：`ChartSvgKit.circle`（`ChartSvgKit.cj:123-137`）每点 `group()` + `circle` + `class` + `fill` + `end()`，每点约 100-200 B 文本；`SwarmChart` 每组 `sortValues` + `swarmOffsets` 各分配一个 `ArrayList` 副本（`:166-167`），`ViolinChart/ViolinBoxChart` 每组 41 个采样固定分配 2 个 `ArrayList` + `StringBuilder`（`:174-185`）
- **方案**：同色同 class 的点合并为一个 `<path>`（`M cx cy m -r 0 a r r 0 1 0 2r 0 ...` 的圆点 path），减少元素数与字符串拼接次数；`sortValues` 直接在入参数组的副本上原地排序，去掉一次 `ArrayList→Array` 复制
- **预期**：1 万点 swarm 的 SVG 文本从 ~1.5 MB 降到 ~0.6 MB（按 150 B/点估算，未实测）；GC 分配次数同比例下降
- **代价**：`class` 语义从 `circle` 变成 `path`，若下游 CSS 依赖 `circle` 选择器会失效；需同步已入库 `charts/*.svg`
- **验证**：同输入（1k/10k 点）前后对比 SVG 字节数与 `getAllocatedHeapSize()` 峰值；浏览器渲染时间对照
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sortValues` 插入排序是点图（swarm/violin/violin-box/box-scatter）主耗时 | `SwarmChart.cj:218` 等 4 处 | 自耗时占比、输入规模 | `cjprof record` 跑 1k/10k 点随机输入，比对 `sortValues` self time |
| 2 | treemap 深链上 `nodeValue` 重复计算使布局呈 O(depth²) | `TreemapChart.cj:159-243` | depth=100/1k/10k 的分段耗时 | 加毫秒埋点跑三种深链，画 depth-耗时曲线 |
| 3 | 单点 SVG 体积约 150 B，点图输出是主要内存占用 | `ChartSvgKit.cj:123`、`SwarmChart.cj:170` | 每点字节数与峰值 RSS | 1k/10k 点时测 `toSvgString()` 长度与 `getAllocatedHeapSize()` 峰值 |
| 4 | `cells` 放大到 1e6 时华夫图渲染进入秒级并触发 GC 抖动 | `WaffleChart.cj:120-138` | 端到端耗时、GC 次数 | 固定 `cells` 梯度（1e3/1e4/1e5/1e6）跑 `cjpm bench -O2`，记录中位数与 GC 计数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/SwarmChart.cj` | .cj | ✅ | 见一般 #6（重复） |
| 2 | `f_chart/src/SwarmChart_test.cj` | .cj | ✅ | 仅计数断言 |
| 3 | `f_chart/src/SwimlaneChart.cj` | .cj | ✅ | 见轻微 #1、#2 |
| 4 | `f_chart/src/SwimlaneChart_test.cj` | .cj | ✅ | 未覆盖长泳道名/大图 |
| 5 | `f_chart/src/TagCloud_test.cj` | .cj | ✅ | 别名回归测试（M104），与设计约定一致 |
| 6 | `f_chart/src/TimelineChart.cj` | .cj | ✅ | 见严重 #2；`date` 只当标签用，见范围外提示 #2 |
| 7 | `f_chart/src/TimelineChart_test.cj` | .cj | ✅ | 无 `group` 用例 |
| 8 | `f_chart/src/TreemapChart.cj` | .cj | ✅ | 见严重 #1/#3、一般 #1/#2/#5/#8、轻微 #1 |
| 9 | `f_chart/src/TreemapChart_test.cj` | .cj | ✅ | 只看 class 计数，几何无断言 |
| 10 | `f_chart/src/ViolinBoxChart.cj` | .cj | ✅ | 见一般 #6/#7 |
| 11 | `f_chart/src/ViolinBoxChart_test.cj` | .cj | ✅ | 覆盖 showBox/showOutliers/带宽 |
| 12 | `f_chart/src/ViolinChart.cj` | .cj | ✅ | 见一般 #6/#7 |
| 13 | `f_chart/src/ViolinChart_test.cj` | .cj | ✅ | 覆盖嵌套/扁平/空组 |
| 14 | `f_chart/src/VolcanoChart.cj` | .cj | ✅ | 见一般 #3 |
| 15 | `f_chart/src/VolcanoChart_test.cj` | .cj | ✅ | 分类函数有单测，坐标方向无断言 |
| 16 | `f_chart/src/WaffleChart.cj` | .cj | ✅ | 见一般 #4/#5 |
| 17 | `f_chart/src/WaffleChart_test.cj` | .cj | ✅ | 未覆盖 cells/columns 上界 |
| 18 | `f_chart/src/WaterfallAlias_test.cj` | .cj | ✅ | 别名冗余为设计约定（`README.md:726`），不计问题 |
| 19 | `f_chart/src/WaterfallChart.cj` | .cj | ✅ | 见轻微 #3 |
| 20 | `f_chart/src/WaterfallChart_test.cj` | .cj | ✅ | span/bounds 有单测 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：treemap 面积切分、volcano y 翻转、treemap 环/缺值静默；设计：`leafIndex` 实例状态破坏纯函数契约；可读性：标题/图例绕过 ChartFrame、泳道名不截断。安全性：本部分只把数字/字符串写进 SVG，转义由 `f_svg` 负责，未发现注入面 |
| §1 死代码 | 1 | 逐个 `private`/`internal` 符号全仓搜引用：`swarmOffsets`(7)、`findSwimLane`(2)、`findSwimNode`(5)、`eventColor`(3)、`nodeValue`(5)、`sortChildren`(8)、`quantileSorted`(7)、`volcanoNumber/Category/LabelText`、`waffleCellCounts`、`waterfallSpan/Bounds/Color` 均有调用者；`treemapWeights` 仅 `TreemapChart_test.cj:66` 使用，属「仅测试使用」→ 只记可见性信息（internal 已是测试可达的最小可见性），不算死代码；`return` 后无同层语句；命中项为 2 处未使用通配 import（轻微 #1） |
| §2 重复逻辑 | 3 | 已把 9 个源文件与 9 个测试文件的函数体压成「输入→输出→副作用」两两比对：命中 parseValues/resolveYRange/sortValues 三函数逐字节复制（一般 #6）、violin/violin-box 轮廓块逐字节复制（一般 #7）、标题与图例自绘（一般 #5）；`WaterfallAlias_test` 已核对为设计约定不计；`kit.*` 薄封装属刻意分层，不算重复 |
| §3 空实现 | 0 | 逐个 `catch` / 空分支检查：本部分无 `catch`，无空函数体，无 TODO；`case None => ()` 均为可选字段正常缺省；`peak <= 0` / `total <= 0` 的提前返回有语义（分别为无密度、无值），但后者静默丢叶已并入一般 #2 |
| §4 栈溢出 | 1 | treemap 的 `layoutNode`/`nodeValue`/`sortChildren` 递归深度＝输入父子链长度、无上限、无环检测（严重 #3）；其余图均为单层循环，无自引用结构 |
| §5 OOM | 1 | waffle `cells` 放大（一般 #4，已量化 140 B/格）；其余图为「输入元素数 ↔ 输出元素数」同阶（1 点 1 图元），无全量物化、无按报文头预分配、无全局容器 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 cjprof/bench 数据，`sortValues`、`nodeValue`、逐点 SVG 三条线索全部降级为待验证假设 #1/#2/#3，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享容器；`ChartSvgKit`/`ChartFrame` 均为每次 `draw` 新建对象 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 Future、无线程池 |
| §6.4 低效算法 | 2 | 插入排序 O(n²)（`sortValues` ×4）与 id 线性查找 O(n²) 已进「优化可行性方案（无基线）」；treemap 面积切分属算法错误，记在严重 #1 |
| §7 降堆内存方案 | 1 | 逐点 `<g>` 合并为 path（优化方案 [堆内存]，无基线）；`ArrayList→Array` 副本可去 |
| §8 降 CPU 方案 | 2 | 排序复杂度、id 索引（均无基线）；无 profile 数据故不进修复清单 |
| §9 local mode 可行性 | 0 | 本部分临时对象是「每组一个 `ArrayList` + 每采样一个 `Float64`」，峰值远小于 JSON/SVG 缓冲；且 `Chart` 契约要求返回 `String`（逃逸），local region 无收益面，不成立 |
| §11 现有代码的 BUG（存量） | 6 | 已核对边界/空值/错误处理：treemap 面积（严重 #1）、timeline hash 溢出（严重 #2）、treemap 递归（严重 #3）、`leafIndex` 契约（一般 #1）、treemap 环与缺值（一般 #2）、volcano y 翻转（一般 #3）；其余边界（空 series、空组、标签长度、负值、带宽 0、除零）均有显式校验，`chartNiceTicks` 有 1000 次上限与 NaN/Inf 保护 |
| §12 并发安全与锁粒度 | 1 | 唯一共享可变状态是 `TreemapChart.leafIndex`（一般 #1）；其余 Chart 实现为「每次 draw 全局部变量」，无静态/全局可变状态，无锁 |
| §14 功能完备性与 README 覆盖 | 2 | `tiling: slice` 未实现（一般 #8）；treemap 忽略 `title.subtext`/`title.align`（一般 #5）；`group`、`showBox`、`showOutliers`、`bandwidth`、`cells`、`columns`、`direction`、`orientation` 等文档字段均已接线 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单只有 `.cj`，无 `.md`；文档一致性用范围外 `README.md`/`doc/chart-json-spec.md` 作承诺源交叉核对（见范围外提示） |

**范围外提示**（只记一句，未展开、不计入统计）：
1. `doc/chart-json-spec.md:838` 写 `jitter`「默认自动」，`SwarmChart.cj:101` 实为固定 `0.3`。
2. `README.md:2427` 称时间线「事件按时间排布」，`TimelineChart.cj` 从不解析 `date`、按数组下标等距放置（乱序输入时图上时序错乱，是否要求调用方预排序待确认）。
3. `ChartFrame.drawYAxis`（`ChartFrame.cj:168-202`）把 `chartNiceTicks` 超出数据范围的刻度照样画出，已入库 SVG 里出现画布外刻度（M020 `200` 在 y=-69、M092 `0` 在 y=-5.8）。
4. 同一「y 轴翻转」写法还出现在 `BlandAltmanChart.cj:149`、`CalibrationChart.cj:130`、`EcdfChart.cj:145`、`GainChart.cj:126`、`LassoPathChart.cj:157`，应由对应部分统一复核。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 8 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

本部分共 15 条发现，**全部为存量**（快照模式无基线可比）。存量缺陷默认只报不修，是否纳入修复待用户决定。

## 总评

9 个图实现里，Swimlane、Timeline（除 `group` 着色）、Violin、ViolinBox、Volcano（除轴方向）、Waffle（除规模上限）、Waterfall 的结构与校验都整齐：空输入、类型不符、重复 id、悬空引用、非法枚举、非数值元素都有显式 `ChartException`，`chartNiceTicks`/`gaussianKde`/`defaultBandwidth`/`quantileSorted` 这些共享工具对 NaN、Inf、零方差都做了保护，本部分未见静默吞异常与资源泄漏面。

阻塞项集中在 `TreemapChart`：面积切分算法与「面积 ∝ 数值」的核心语义不符（实测 6.9:1 的面积比对应 2.17:1 的值比、38% 画布空白），并且递归深度不设限、父链成环/叶子缺值静默丢节点、用实例字段存绘制状态破坏 `Chart` 纯函数契约——这一张图建议整体重写布局与状态管理，其余问题可排期。`TimelineChart` 的 `group` 哈希溢出是第二处必修项：13 个字符的标签就会抛非 `ChartException`，属于随时会被真实数据踩到的崩溃。第三类可排期问题是 `ViolinChart`/`ViolinBoxChart` 与三个数值工具的整段复制，以及 treemap/waffle 绕过 `ChartFrame` 造成的标题、图例行为漂移——这类问题不修不会出错，但会让后续每一处修改都要改 3-4 遍。

性能侧本部分没有 profile 或 bench 数据，故只登记 3 条优化候选与 4 条待验证假设，未写成缺陷。
