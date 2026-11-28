# f_chart 模块审查报告

> **模块第 8/37 部分**（本报告只覆盖 `files/f_chart.part8.txt` 列出的 20 个文件，全部位于 `f_chart/doc/spec/add-f-chart-*`：differential-flame / donut / dot-density-map / dot-strip / dot / dumbbell 六个变更的 `proposal.md` / `design.md` / `tasks.md` / `specs/chart-rendering/spec.md`。`src/**` 的 251 个 `.cj`、模块 README 与其余 `doc/**` 由其他子轮产出，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分全为变更 spec 文档，因此实际执行的是：把每份 `spec.md` 的 Requirement / Scenario 当成验收契约，逐条回读对应实现（`DonutChart.cj`、`DifferentialFlameChart.cj`、`DotChart.cj`、`DotDensityMapChart.cj`、`DotStripChart.cj`、`DumbbellChart.cj`，以及 `ChartFrame.cj` / `ChartScale.cj` / `ChartTheme.cj` 的支撑语义）核对渲染、坐标、边界与默认值口径；并按 checklist §13 的归档口径（`doc/spec/**` 只核"当时结论是否自洽"）判定漂移。
- **补充阅读（不在本部分清单，归其他子轮，不参与统计）**：`add-f-chart-differential-flame/design.md`、`add-f-chart-differential-flame/proposal.md` 未列入 `files/f_chart.part8.txt`，为核对 #4 的"退回 value1"语义读入，问题仍归本部分 #4 记录。为跑 §2 重复逻辑与 §11 存量缺陷的机械检查，另读了 `PieChart.cj`、`HorizontalBarChart.cj`、`BulletChart.cj`、`ChartJson.cj`、`ChartConfig.cj`、`HeatmapChart.cj` 与 6 个 `*_test.cj`，以及已入库样例 `f_chart/charts/M077-dumbbell.svg`。
- **报告版本**：v1（第 8/37 部分）

## 发现

### [一般][存量] #1 哑铃图 design 声称"网格与横轴刻度由 ChartFrame 绘制"，实现把横向比例尺当纵坐标用，网格线画到绘图区外与画布外

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/design.md:11`；对照 `f_chart/src/DumbbellChart.cj:133,152`、`f_chart/src/ChartFrame.cj:168-178`
- **来源**：存量（快照模式无基线）；`git log -S "drawYAxis(kit, ticks, xScale)"` 未追（只读审阅），按快照统一记存量
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符 / 契约与实现不符」
- **证据**：静态确定 —— `ChartFrame.drawYAxis(kit, ticks, scale)` 的 `scale.scale(tick)` 结果被直接当 **y** 用（`ChartFrame.cj:172`，随后 `174-177` 画 `(plot.x, y) → (plot.right(), y)` 横线、`179-186` 在 `plot.x - 8` 处写刻度文本）。哑铃图的 y 轴是类目 `BandScale`（`DumbbellChart.cj:132`），唯一的 `LinearScale` 是横向的 `xScale`（`133`：`LinearScale(min, max, plot.right(), plot.x)`），但 `152` 仍然 `frame.drawYAxis(kit, ticks, xScale)`。已入库样例 `f_chart/charts/M077-dumbbell.svg` 复现：网格线 y 依次为 73.44 / 213.952 / 354.464 / **494.976 / 635.488 / 776**，绘图区实际是 74–432、画布高 480，即 3 条落在绘图区外、其中 2 条整条在画布外；同时左侧出现两套标签——类目名（`A 团队` 等，`DumbbellChart.cj:168-178`）与数值刻度 `0/20/40/60/80/100`（`ChartFrame.cj:179-186`）都贴在 `x = 65.44`。
- **描述**：design 只写了"网格与横轴刻度由 `ChartFrame` 绘制"，没有写清横向类目图的网格方向与所用比例尺；实现照字面调用了纵向 API，结果是坐标轴装饰错位（数据图元 `dumbbell-line` / `dumbbell-low` / `dumbbell-high` 本身位置正确）。按 §13 的归档口径，这不是"文档过期"，而是文档口径与绘制行为在归档当时就不自洽：读者按 design 无法推出"网格应垂直于数值轴"。
- **建议**：design 补一句"横向类目图的数值轴在底部，网格为等值竖线；纵轴仅类目标签、不设数值刻度"；实现侧（源码归对应子轮）改为新增 `drawXGrid(kit, ticks, xScale)` 画竖线，或直接删掉 `152` 的 `drawYAxis` 调用。
- **范围外提示**：`DumbbellChart.cj:152` 是实质缺陷（全模块仅此一处把 `xScale` 传给 `drawYAxis`，已用 `grep -rn "frame.drawYAxis(" src` 排除复用模式），源码不在本部分清单，留给覆盖该文件的子轮定级。

### [一般][存量] #2 环形图 design 规定"白色内孔 + 主题文本色"，主题背景可配成深色时中心文本不可读

- **位置**：`f_chart/doc/spec/add-f-chart-donut/design.md:9-11`；对照 `f_chart/src/DonutChart.cj:141-154`、`f_chart/src/ChartTheme.cj:25,38`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移 / 关键段落缺失」、§11「边界未处理」
- **证据**：静态确定 —— design 写"外半径…内半径 = 外半径 × `innerRadius`""先按饼图方式绘制扇区，再画**白色**内孔圆，最后绘制 `centerText`""中心文本…颜色取主题文本色"。实现内孔硬编码 `fill: "#ffffff"`（`DonutChart.cj:143`），中心文本取 `config.theme.textColor`（`150`），扇区百分比标签再硬编码 `#333333`（`133`）。而主题背景与文本色是用户可配项：`ChartTheme.cj:25` 默认 `background = "#ffffff"`，`:38` 从输入的 `theme.background` 读取。
- **描述**：内孔用白色实心圆代替"挖洞"（背景色/透明），在 `theme.background` 非白（深色仪表盘是环形图的典型场景）时会出现白斑；若同时配深色主题的浅色 `textColor`，中心文本正好落在白圆上，对比度反转成不可读。design 只承诺"白色内孔 + 主题文本色"，没有规定二者在非白主题下的组合规则，属口径缺失。
- **建议**：design 改为"内孔填充取 `theme.background`（或环形扇区改用 `fill-rule: evenodd` 的复合路径真正挖空）"，并补一句"中心文本与背景的对比由主题负责"；实现侧把 `143` 的 `#ffffff` 换成 `config.theme.background`、`133` 的 `#333333` 换成主题色。
- **范围外提示**：`DonutChart.cj:143,133` 的硬编码颜色是实质缺陷，源码不在本部分清单。

### [一般][存量] #3 豆图 spec 要求"圆心 MUST 位于所属类目带内"，但 `jitter` 只校验非负、无上界，偏移可整条越出类目带

- **位置**：`f_chart/doc/spec/add-f-chart-dot-strip/specs/chart-rendering/spec.md:7`（另见 `:16`、`:32-39`）；对照 `f_chart/src/DotStripChart.cj:74-77,172,188-191`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」；边界校验缺失见 §10「正确性」
- **证据**：静态确定 —— spec 的 Requirement 写"圆心 MUST 位于所属类目带内，水平偏移 MUST 由 `dotStripOffset` 决定"；`dotStripOffset` 返回 `(fraction * 2 - 1) * jitter * bandwidth`（`DotStripChart.cj:191`），而 `jitter` 校验只有 `jitter < 0.0` 一条（`:75`）。取 `jitter = 0.5` 时 `|offset|` 可达 `0.5 * bandwidth`，圆心正好压在带边界；`jitter = 1.0` 时偏移等于一整条带宽，圆心落到相邻类目带内。spec 的 Scenario 只覆盖 `jitter = 0.15`（`:20`），因此现有测试与实现都不暴露该冲突。
- **描述**：Requirement 承诺的"带内"不是实现能保证的性质，取决于用户传入的 `jitter`；文档没有给上界，等于把一条不可满足的约束写成了验收标准。使用者按 spec 认为"点一定落在本列"会在 `jitter ≥ 0.5` 时拿到越界渲染。
- **建议**：二选一并同步两边——(a) spec 增加"`jitter` MUST 在 `[0, 0.5]`，越界抛 `InvalidValue`"，实现补校验；(b) 把 Requirement 改成"圆心水平偏移不超过 `jitter × 类目带宽`"，不再承诺带内。推荐 (a)，与 `dotSize` 半径叠加后的视觉重叠也更可控。
- **范围外提示**：`DotStripChart.cj:75` 缺少 `jitter` 上界是实质缺陷，源码不在本部分清单。

### [一般][存量] #4 差分火焰图 spec 允许根 `value2 = 0` 却未定义宽度基准，该输入下所有节点宽度为 0、整图空白

- **位置**：`f_chart/doc/spec/add-f-chart-differential-flame/specs/chart-rendering/spec.md:7`、`:40`；对照 `f_chart/src/DifferentialFlameChart.cj:96,157,216`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移 / 边界口径缺失」、§11「边界未处理」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 校验只拒绝"两者都为 0"：`if (value1 <= 0.0 && value2 <= 0.0) throw`（`:96`），所以根节点 `{value1: 100, value2: 0}` 是合法输入（纯回退版本）。宽度公式是 `node.width = node.value2 / rootWidth * plotWidth`（`:216`），`rootWidth` 在 `rootNode.value2 <= 0` 时退回 `value1`（`:157`）——只换了分母，分子仍是 `value2 = 0`；又因为 `validateValues` 保证子节点 `value2` 之和不超过父节点，根为 0 时全部后代 `value2` 也是 0，于是所有 `diff-flame-node` 宽度为 0，标签还额外被 `node.width > chartTextWidth(...) + 6.0`（`:242`）挡掉，输出只剩背景与标题。`DifferentialFlameChart_test.cj:58` 只统计 `class="diff-flame-node"` 出现次数，零宽矩形数量仍为 6，测试红不了。
- **描述**：spec 的 Requirement 把宽度定义为 `value2 / 根节点 value2`，校验又主动允许根 `value2 = 0`，两个条款在边界上互相矛盾；design（`add-f-chart-differential-flame/design.md:6`，清单外）写了"根 `value2` 为 0 时退回 `value1`"，但该约定既没进 spec，实现也没有把分子一起退回，承诺落空。
- **建议**：spec 补 Requirement"根 `value2` 为 0 时 MUST 以 `value1` 作为归一基准（分子分母同时切换）"，并在 Scenario 里给一条"根 `value2 = 0 → 输出宽度按 `value1` 分配的节点"；或让校验直接拒绝根 `value2 = 0` 并写明 `kind`。实现侧修 `:157/:216`（源码归对应子轮）。

### [一般][存量] #5 环形图整块复制饼图扇区绘制，`showPercent: false` 在环形图上退化成"不显示任何标签"

- **位置**：`f_chart/doc/spec/add-f-chart-donut/design.md:10`（"先按饼图方式绘制扇区"）；对照 `f_chart/src/DonutChart.cj:100-140`、`f_chart/src/PieChart.cj:107-149`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（重复逻辑 / 只改类名 / 近似重复含边界判断缺失）、§11（契约与实现不符）、§14.1（只做了一半的分支）
- **证据**：静态确定 —— 两段逐行对齐：`centerX = width/2`、`centerY = height/2 + 10`、`radius = min(w-padL-padR, h-padT-padB-40)/2 - 20`、`angle = -90.0 + startAngle`、起终点三角函数 + `A r r 0 largeArc 1` 拼串、`stroke #ffffff` 全部相同；差异只有三处：className（`donut-slice` vs `pie-slice`）、标签半径（`radius*(1+innerRadius)/2` vs `radius*0.65`）、标签文本分支 —— 饼图是 `if (showPercent) formatPercent(...) else slices[index].name`（`PieChart.cj:135-139`），环形图是 `if (showPercent) { formatPercent(...) }`（`DonutChart.cj:124-137`）**没有 else**。
- **描述**：`startAngle` / `showPercent` 被一并从饼图抄入（`DonutChart.cj:78-79`），但 donut 的 proposal / design / spec 与 README 的 M32 章节都没有这两个字段。同名字段在两图语义不同：饼图关掉百分比后改显示类目名，环形图关掉后一个标签都不显示，使用者无从预期；复制也让描边、字号、外半径公式今后必须两处同步改。
- **建议**：把"扇区路径 + 标签位置策略"抽成公共辅助（或让环形图直接复用饼图的绘制函数），差异用参数传入；`showPercent: false` 在环形图上明确定义（显示类目名或明确不支持）；把 `startAngle` / `showPercent` 写进 donut 的 design 与 spec delta。

### [一般][存量] #6 哑铃图拒绝负值 `low` / `high`，与 design 的"只要求数字"不符

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/design.md:5`（"两者均必须为数字"）、`design.md:20`（校验清单）；对照 `f_chart/src/DumbbellChart.cj:70-71`、`f_chart/src/BulletChart.cj:238-241`
- **来源**：存量（快照模式无基线；`bulletNumber` 复用自 M76 子弹图）
- **判据**：review-checklist §11（契约与实现不符）、§13（文档与实现不一致）
- **证据**：静态确定 —— `bulletNumber` 除"必填 + 数字"外还有 `if (number < 0.0) throw chartInvalidValue(..., "数值不能为负")`（`BulletChart.cj:238-241`，注释只写"缺失抛 MissingField，类型不符抛 InvalidValue"）；`DumbbellChart.cj:70-71` 用它读 `low` / `high`，而 design 的"数据"节只要求数字、"校验"节列出的抛错条件也不含负值。
- **描述**：哑铃图是成对测量对比（前后得分、两期指标、温差、盈亏、相对基准差），负值天然合法；当前实现把 `low = -3` 判成 `InvalidValue`，且错误文案"数值不能为负"是子弹图的约束，调用方无法从哑铃图文档推出这一限制。
- **建议**：哑铃图改用只校验"必填 + 数字"的读取（`jsonNumberValue(json.required("low"), ...)`），把非负约束留在子弹图；若产品上确需非负，在 design 的数据/校验两节写明，并在 `spec.md` 补 `InvalidValue` 的 Scenario。

### [轻微][存量] #7 环形图 spec 的"4 个类别 → 4 个 donut-slice"与"零占比扇区被跳过"的实现不符

- **位置**：`f_chart/doc/spec/add-f-chart-donut/specs/chart-rendering/spec.md:9-12`、`:32-34`；对照 `f_chart/src/DonutChart.cj:108-110`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 扇区只在 `if (sweep > 0.0)` 时输出（`DonutChart.cj:110`），`sweep = fractions[index] * 360.0`；而校验只要求"数值非负且总和大于 0"（spec `:34`，实现 `:66-72` 与 `pieFractions`），`[3, 3, 3, 0]` 是合法输入却只输出 3 个 `donut-slice`，与 Scenario 的"4 个类别 → 4 个 `donut-slice`"冲突。内孔 `donut-hole` 无条件绘制（`:141`），所以该 Scenario 的"1 个 hole"始终成立。
- **描述**：Scenario 写的是"data 有 4 个 `{name,value}`"，未限定四值均正；实现按占比裁掉了 0 值类别。视觉上跳过 0 值合理，问题在文档把边界口径留成空白，测试也就无法据此覆盖零值。
- **建议**：Scenario 改为"`data` 有 4 个**正** `value` → 输出 4 个 `donut-slice`"，Requirement 补一句"占比为 0 的类别不绘制扇区（也不绘制标签）"。

### [轻微][存量] #8 豆图 design 的抖动公式与实现差一个相位常量，按文档复算得不到实现的偏移

- **位置**：`f_chart/doc/spec/add-f-chart-dot-strip/design.md:14`；对照 `f_chart/src/DotStripChart.cj:189`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」
- **证据**：静态确定 —— 文档写"用 `sin(index * 12.9898) * 43758.5453` 取小数部分映射到 `[-1, 1]`"，实现是 `sin(Float64(index) * 12.9898 + 4.1414) * 43758.5453`（`:189`），多一个 `+ 4.1414`。spec 只约束偏移落在 `±jitter × bandwidth`（`spec.md:16`）和"不同索引偏移不同"，两者对该相位都不敏感，所以用例不会失败，文档却无法用来复现点位。
- **描述**：确定性抖动是本图唯一影响坐标的算法，文档给出的公式是被当作规格引用的；相位差异会让按文档重写渲染（或写对照测试）的人算出不同点位。
- **建议**：文档补上 `+ 4.1414`（说明是去相关的相位偏移），或实现去掉该常量；任选其一并保持单测对具体数值的断言。

### [轻微][存量] #9 点密度地图 proposal 只写"`regions` 为底图路径"，实际元素必须是 `{path}` 对象

- **位置**：`f_chart/doc/spec/add-f-chart-dot-density-map/proposal.md:10`；对照 `f_chart/doc/spec/add-f-chart-dot-density-map/specs/chart-rendering/spec.md:7`、`f_chart/src/DotDensityMapChart.cj:67-75`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例 / 字段形状与实现不符」、§14.2「公开字段未文档化」
- **证据**：静态确定 —— 实现逐个要求 `item.kind.isObject`（否则抛 `InvalidValue("regions[i]", "期望区域对象")`，`:69-71`），再用 `json.requiredString("path")` 取值（`:73`）；proposal 与 spec 都只说"底图路径"，没有写出元素形态与必填键名。按文档写 `"regions": ["M0 0 L100 0 ..."]` 会被判为"期望区域对象"。
- **描述**：`regions` 是本图唯一的可选结构字段，形状写不清会让使用者第一步就撞错；同目录的 `points` 反而写明了 `{x, y, weight?}`（`proposal.md:10`），两份字段的描述精度不一致。
- **建议**：proposal 与 spec 都改成"`regions` 的元素为 `{path}`，`path` 为必填 SVG path 字符串；缺 `path` 抛 `MissingField`"，并给一个最小样例。

### [轻微][存量] #10 豆图 proposal 把 `jitter` / `dotSize` 写成图表级"专属字段"，实际按系列读取，顶层同名键被静默忽略

- **位置**：`f_chart/doc/spec/add-f-chart-dot-strip/proposal.md:11`；对照 `f_chart/doc/spec/add-f-chart-dot-strip/design.md:5`、`f_chart/src/DotStripChart.cj:74-81`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档与代码不一致」、§11「语义与命名不符」
- **证据**：静态确定 —— `json.number("jitter", default: 0.15)` 与 `json.number("dotSize", default: 7.0)` 的 `json` 是 `series[i]` 的对象（`DotStripChart.cj:57,74,78`），与同目录 design 的"每系列解析 `data`、`jitter`、`dotSize`"（`design.md:5`）一致；`ChartConfig.parse` 不校验未知字段（`grep -n "未知\|unknown" ChartConfig.cj` 无命中），所以顶层写 `"jitter": 0.3` 既不生效也不报错。
- **描述**：proposal 与 design 对同一组字段的层级说法不一致，读者按 proposal（"专属字段"通常理解为图表级）配置会得到"配置写了但图没变"的静默失败。
- **建议**：proposal 改成"`series[i].jitter`（水平抖动比例，默认 0.15）、`series[i].dotSize`（点直径，默认 7），按系列独立配置"。

### [轻微][存量] #11 文档未覆盖两个实现的可见细节：`symbolSize` 默认 8、环形图百分比标签类名 `pie-label`

- **位置**：`f_chart/doc/spec/add-f-chart-dot/specs/chart-rendering/spec.md:23-25`、`f_chart/doc/spec/add-f-chart-donut/proposal.md:12`；对照 `f_chart/src/DotChart.cj:173-176`、`f_chart/src/DonutChart.cj:135`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2「公开字段 / 类名未文档化」
- **证据**：静态确定 —— 点图 spec 只写"`series[].symbolSize` 控制点直径"，未给默认值，实现默认 `8.0`（`DotChart.cj:173`）且半径取 `symbolSize / 2`（`:131`）；环形图 proposal 枚举了三个类名 `donut-slice` / `donut-hole` / `center-text`（`proposal.md:12`），实现里扇区百分比标签用的是 `class="pie-label"`（`DonutChart.cj:135`），该目录两份文档均未提及。
- **描述**：类名与默认值是这两张图对外可观察契约（CSS 定制、快照比对都依赖它）；`pie-label` 复用了饼图类名，对环形图使用者是"没写在文档里的隐式契约"，按 proposal 写样式会漏掉标签。
- **建议**：点图 spec 补"`symbolSize` 默认 8，圆半径 = `symbolSize / 2`"；环形图 proposal 的类名清单补 `pie-label`（或让实现改用 `donut-label` 并在文档同步，二者择一）。

### [轻微][存量] #12 点图、哑铃图与横向条形图三处复制同一套"横向数值轴 + 类目行"布局样板

- **位置**：`f_chart/doc/spec/add-f-chart-dot/design.md:5`（"与 M11 相同"）；对照 `f_chart/src/DotChart.cj:105-148`、`f_chart/src/DumbbellChart.cj:132-179`、`f_chart/src/HorizontalBarChart.cj:103-153`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（跨层复制 / 只改类型名）
- **证据**：静态确定 —— 三处的 `for (tick in ticks) { kit.line(x, plot.y, x, plot.bottom(), grid) }`、`baseline = xScale.scale(0.0)`、`slot = band.bandWidth / max(series.size, 1)`、`y = band.bandStart(index) + seriesIndex*slot (+ slot/2)`、`plot.x - 8.0` 处的类目标签、`drawXAxisNumeric` 收尾逐行同型；差异只有图元（`rect` / `stem+circle` / `dumbbell-line+两端点`）与是否画 baseline。
- **描述**：复制尚未造成数据错误，但已经分叉出一次错误 —— #1 的 `drawYAxis` 误用正是在复制时选错轴方法；后续调轴距、网格规则、类目标签位置要改三处，容易继续分叉。
- **建议**：在 `ChartFrame` 上抽"横向数值轴 + 类目行"装配（画网格 → 算 `slot` → 类目标签 → `drawXAxisNumeric`），图元留给各图回调；抽取前把三处差异（是否画 baseline、系列数上限、标签宽度来源）显式参数化，避免把差异藏进复制品。

## 优化可行性方案

本部分只有变更 spec 文档，没有可执行代码，也没有改前 / 改后测量数据，**不提出任何性能或内存方案**（避免把"文档措辞"包装成优化项）。

### [堆内存] 无

- 本部分无 `.cj`，spec 中也未包含可测量的内存契约。

### [CPU] 无

- 同上。若后续子轮在 `src/**` 命中渲染热点，其结论须带 `cjprof` / `cjpm bench`（`-O2`）数据，本部分不预置假设。

## 待验证假设

> 本部分不含代码，未提出性能假设（0 条）。下表三条属"需要实测才能确认的视觉/行为/稳定性猜测"，不是性能结论，也不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 深色主题（`theme.background` 非白）下环形图内孔白斑与中心文本对比度反转的实际可读性影响面 | `f_chart/src/DonutChart.cj:143,150` | 主题背景与 `textColor` 的取值分布、实际渲染截图 | 用 `theme: {background: "#1e1e1e", textColor: "#eeeeee"}` 跑 M032 用例并导出 SVG，目视 + 对比度计算（WCAG） |
| 2 | 其它横向类目图（`BarRenderer` 等未调用 `drawYAxis` 的图）是否也存在"数值轴网格缺失 / 位置错"的视觉缺陷 | `f_chart/src/BarRenderer.cj:113` 等 | 各图样例 SVG 的网格与刻度坐标实测 | 批量解析 `f_chart/charts/M*.svg` 中 `class="grid"` 的端点，按绘图区边界统计越界比例 |
| 3 | 差分火焰的深链输入（如 1 万层单链）在 `layoutNode` / `drawNode` 无深度保护递归下是否栈溢出 | `f_chart/src/DifferentialFlameChart.cj:214-259` | 单帧大小、平台栈上限、首个崩溃深度 | 构造 1k / 5k / 10k / 50k 层单链 `nodes` 调 `draw`，记录是否 `StackOverflow` 与首个失败深度 |

## 文件覆盖

> 与 `files/f_chart.part8.txt` 一一对应（该文件 20 行，全部为 `.md`）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-differential-flame/specs/chart-rendering/spec.md` | .md | ✅ | 宽度/颜色/校验逐条核对；见 #4（根 `value2 = 0` 口径缺失）；颜色场景与 `heatmapColor` 一致 |
| 2 | `f_chart/doc/spec/add-f-chart-differential-flame/tasks.md` | .md | ✅ | 4 项全 `[x]`；`DifferentialFlameChart_test.cj` 存在且覆盖节点/颜色/校验，与勾选一致 |
| 3 | `f_chart/doc/spec/add-f-chart-donut/design.md` | .md | ✅ | 见 #2（白色内孔 + 主题文本色）、#5（"按饼图方式绘制扇区"= 整段复制）；占比复用 `pieFractions`、绘制顺序、字号均与实现一致 |
| 4 | `f_chart/doc/spec/add-f-chart-donut/proposal.md` | .md | ✅ | `innerRadius` 默认 0.55 与 `DonutChart.cj:73` 一致；类名清单见 #11（`pie-label` 未列） |
| 5 | `f_chart/doc/spec/add-f-chart-donut/specs/chart-rendering/spec.md` | .md | ✅ | 见 #7（4 扇区 Scenario 与零值跳过）；内半径越界、负值、`type` 不匹配三场景均成立 |
| 6 | `f_chart/doc/spec/add-f-chart-donut/tasks.md` | .md | ✅ | 4 项全 `[x]`；测试文件与 `DonutChart_test.cj:61-69` 断言一致 |
| 7 | `f_chart/doc/spec/add-f-chart-dot-density-map/design.md` | .md | ✅ | viewBox 缺省取画布、底图先画点后画、`dotDensityRadius` 平方根规则均与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-dot-density-map/proposal.md` | .md | ✅ | 见 #9（`regions` 元素形态）；`radius` 默认 3、类名、`points` 形状一致 |
| 9 | `f_chart/doc/spec/add-f-chart-dot-density-map/specs/chart-rendering/spec.md` | .md | ✅ | 底图/点位/半径/校验四组场景逐条成立（空点集 → `InvalidValue`，负权重 → `InvalidValue`） |
| 10 | `f_chart/doc/spec/add-f-chart-dot-density-map/tasks.md` | .md | ✅ | 4 项全 `[x]`；`DotDensityMapChart_test.cj` 覆盖底图/点位/半径/校验 |
| 11 | `f_chart/doc/spec/add-f-chart-dot-strip/design.md` | .md | ✅ | 见 #8（抖动公式相位）、#10（字段层级）、#12（布局样板）；8% 余量、`dotSize/2`、校验项均一致 |
| 12 | `f_chart/doc/spec/add-f-chart-dot-strip/proposal.md` | .md | ✅ | 见 #10（"专属字段"未写系列级）；type/类名与实现一致 |
| 13 | `f_chart/doc/spec/add-f-chart-dot-strip/specs/chart-rendering/spec.md` | .md | ✅ | 见 #3（"圆心在带内"无上界支撑）；点大小、负抖动、类型不匹配场景成立 |
| 14 | `f_chart/doc/spec/add-f-chart-dot-strip/tasks.md` | .md | ✅ | 4 项全 `[x]`；测试覆盖散点/抖动/点大小/校验 |
| 15 | `f_chart/doc/spec/add-f-chart-dot/design.md` | .md | ✅ | 布局（BandScale 行 + LinearScale 数值 + 含 0）、stem/点、显式 min/max 优先均与实现一致；"与 M11 相同"对应的样板复制见 #12 |
| 16 | `f_chart/doc/spec/add-f-chart-dot/proposal.md` | .md | ✅ | 负值/`null`/多系列/图例与 `DotChart.cj:121-137,216-263` 一致 |
| 17 | `f_chart/doc/spec/add-f-chart-dot/specs/chart-rendering/spec.md` | .md | ✅ | 3 场景（3 点 3 stem、`null` 跳过、自定义颜色）均成立；默认值见 #11 |
| 18 | `f_chart/doc/spec/add-f-chart-dot/tasks.md` | .md | ✅ | 4 项全 `[x]`；`DotChart_test.cj` 存在 |
| 19 | `f_chart/doc/spec/add-f-chart-dumbbell/design.md` | .md | ✅ | 见 #1（网格/刻度口径与实现不符）、#6（"只要求数字"与实际非负约束）；连线、端点半径与颜色（2px / `#bdbdbd` / 5px / 6px）逐项与实现一致 |
| 20 | `f_chart/doc/spec/add-f-chart-dumbbell/proposal.md` | .md | ✅ | 三个类名、`xAxis.min/max` 优先、`low > high` 允许均与实现一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | #6（哑铃图把合法的负值判为非法，属契约/正确性问题）；其余边界与坐标口径问题归入 §13 / §14 计数，不重复；无外部输入解析、无凭据、无注入面 |
| §1 死代码 | 0 | 20 个文件均为 `.md`，无可执行声明。机械动作改为"文档内是否留有未兑现的承诺"：逐份核对 5 个变更的 `tasks.md` 勾选与 `src/*_test.cj` 是否存在（6 个测试文件均存在），未发现"勾了但无产物"；`doc/spec/**` 属归档变更，不判"过期文档=死代码" |
| §2 重复逻辑 | 2 | #5（环形图逐行复制饼图扇区绘制，差异只有 class / 标签半径 / `showPercent` 分支）、#12（点图、哑铃图与 `HorizontalBarChart` 的轴与类目行样板三处同型）。机械动作：①逐份比对 5 份 `spec.md` 的 Requirement 与 Scenario（differential-flame 3+2、donut 4+4、dot-density 4+6、dot-strip 4+5、dot 3+3），五个变更的验收语义互不重叠；②把 6 个实现的 15 个方法按"输入-输出-副作用"两两比对，并把 `DonutChart` 对 `PieChart`、`DotChart`/`DumbbellChart` 对 `HorizontalBarChart` 的同型段落逐行对照 —— 前者命中 #5，后者命中 #12。四份 spec 都重复出现"`type` 不匹配抛 `UnsupportedChart`"这类通用验收句，但各属独立变更的验收快照，合并会破坏变更历史，按 §2 误报边界不判重复 |
| §3 空实现 | 0 | 6 份 `tasks.md` 无 `TODO`/`FIXME` 占位；5 份 `spec.md` 的 Scenario 均有对应实现分支（除 #4 的边界缺口，已单列）；`Regions` 缺省分支 `case None => ()`（`DotDensityMapChart.cj:76`）属 spec 明确允许的"无底图"语义，不是空实现 |
| §4 栈溢出 | 0 | 文档未承诺任何递归深度。核对实现：`validateValues` / `assignDepth` 有 `depth > total` 保护，但 `layoutNode` / `drawNode`（`DifferentialFlameChart.cj:214-259`）没有，递归深度等于树深、由输入决定；缺栈帧大小与崩溃深度数据，按铁律只进「待验证假设 #3」 |
| §5 OOM | 0 | spec 未声明任何数据规模上限，也没有"全量物化"承诺；本部分无代码可判。是否该给 `nodes` / `points` 加上限属源码子轮判定，本部分不臆断 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分也无代码；不提出热点结论（见「待验证假设」，3 条均非性能结论） |
| §6.2 大粒度锁 | 0 | 无代码、无线程同步面 |
| §6.3 并发串行 | 0 | 同上 |
| §6.4 低效算法 | 0 | 同上。文档中的复杂度描述只有 `dotStripOffset` 的 O(1) 抖动与 `dotDensityRadius` 的 O(1) 半径换算，均无隐藏嵌套 |
| §7 降堆内存方案 | 0 | 无代码、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数，local region 候选无从谈起；文档也未提及 local mode |
| §11 现有代码的 BUG（存量） | 3 | 为核对文档承诺读了 6 个实现与 `ChartFrame` / `PieChart` / `HorizontalBarChart` / `BulletChart`，确认 3 条存量缺陷：#1（横向轴传 `drawYAxis`，样例 `charts/M077-dumbbell.svg` 复现）、#4（根 `value2 = 0` 零宽）、#6（`bulletNumber` 的非负约束外溢到哑铃图）。`DonutChart.cj:133/143` 硬编码颜色、`DotStripChart.cj:75` 缺 `jitter` 上界留在 #2 / #3 的取证与「范围外提示」，源码归覆盖 `src/**` 的子轮 |
| §12 并发安全与锁粒度 | 0 | `Chart.draw` 在 `Chart.cj:24-25` 被声明为纯函数语义（不改 `data`、同输入确定性输出），6 份文档未声明任何共享状态或线程安全契约不同；无共享可变状态可判 |
| §14 功能完备性与 README 覆盖 | 3 | #7（spec 承诺 4 扇区、实现跳过零值）、#9（`regions` 元素形态与 `path` 键未文档化）、#11（`symbolSize` 默认值、`pie-label` 类名未文档化）。反向核对成立项：6 个 `type` 字符串（`donut` / `differential-flame` / `dot` / `dot-density-map` / `dot-strip` / `dumbbell`）在 `src/*.cj` 均有 `ChartConfig.parse(data, "<type>")` 入口并在 `ChartGallery_test.cj` 有样例；`innerRadius` 0.55、`radius` 3、`jitter` 0.15、`dotSize` 7 四个文档默认值与实现常量逐一相等 |
| §13 文档一致性 | 7 | #1（渲染坐标口径）、#2（内孔与文本配色组合）、#3（"带内"承诺无上界支撑）、#4（根 `value2 = 0` 宽度基准缺失）、#6（"只要求数字"与实际非负约束不符）、#8（抖动公式相位）、#10（字段层级）。#5 / #12 属实现重复，#7 / #9 / #11 属"该写没写"，分别计入 §2 与 §14，不在此重复。按 §13 归档口径，`doc/spec/**` 只核"当时结论是否自洽"，故全部按口径缺口而非"过期"定级 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件。清单外补充阅读：`add-f-chart-differential-flame/{design,proposal}.md`、`PieChart.cj`、`HorizontalBarChart.cj`、`BulletChart.cj`、`ChartJson.cj`、`ChartConfig.cj`、`HeatmapChart.cj`、6 个 `*_test.cj` 与已入库样例 `charts/M077-dumbbell.svg`，均不计入覆盖数 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分覆盖 `f_chart/doc/spec/` 下 6 个新增图表的变更文档（20 个 `.md`，合计 463 行）。这些 spec 写得比多数项目的设计文档更可验收：每份都是"Requirement + WHEN/THEN Scenario"结构，字段名、类名、默认值、错误 `kind` 基本都能在实现里一一对上（`innerRadius` 0.55、`radius` 3、`jitter` 0.15、`dotSize` 7、`#e53935` / `#4a90d9` 颜色、5px/6px 端点半径、8% 轴余量全部核对通过），`tasks.md` 的勾选也与 `src/*_test.cj` 的实际存在一致。

风险集中在**边界条款没写透**与**复制粘贴带出的口径漂移**，前者恰好落在本轮重点（坐标与边界）上：

- 一般项 #1 最值得先改：哑铃图 design 只写"网格与横轴刻度由 `ChartFrame` 绘制"，实现把横向 `xScale` 传给纵向 API，样例 `M077-dumbbell.svg` 里一半网格线跑到绘图区外、两条整条在画布外，左侧还叠了两套标签。这是典型的"按文档看没问题、按文档做就出错"，实际修复在源码侧，文档要补的是"横向类目图的网格方向与比例尺"。
- 一般项 #2 / #3 / #4 是同类问题：内孔颜色与中心文本色的组合在非白主题下不可读（#2）、`jitter` 无上界使"圆心在类目带内"无法保证（#3）、根 `value2 = 0` 时宽度基准未定义导致整图空白（#4）。#5 / #6 则是"复制粘贴带出的两套口径"：环形图整块复制饼图绘制后，`showPercent: false` 从"显示类目名"退化成"不显示"（#5）；哑铃图把子弹图的"非负"约束一并复制进来，拒绝原本合法的负值（#6）。这五条都建议先定契约（给约束并校验 / 降低承诺 / 抽公共实现），改动都在几行文档 + 一处校验或分支。
- 轻微项 #7–#12 属字段与类名覆盖不全 + 样板重复：零值扇区、抖动公式的相位常量、`regions` 的元素形态、`jitter` / `dotSize` 的层级、`symbolSize` 默认值与 `pie-label` 类名，以及点图/哑铃图/横向条形图三处同型的布局代码。修正成本低，但都是使用者第一步就会碰到的地方。

本部分没有 `.cj`，但为核对文档承诺回读了 6 个实现：**重复逻辑与存量缺陷**已按 §2 / §11 取证（#5 / #12、#1 / #4 / #6）；**死代码、OOM、并发安全、性能热点**仍未在本轮取证——它们只能在覆盖 `src/**` 的子轮判定，本报告不据此对模块整体下结论；**栈溢出**只列了待验证假设 #3，等实测数据再定级。

存量缺陷共 12 条（一般 6 / 轻微 6），是否纳入修复待用户决定；本报告只读文件，未做任何源码修改。
