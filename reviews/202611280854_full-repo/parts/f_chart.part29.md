# f_chart 模块审查报告（模块第 29/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：10 个实现 + 10 个测试，无 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑（`_dispatch.md` 模块重点表）
- **报告版本**：分部分报告 v1（part29，供主 Agent 合并进 `docs/review/2026-11-28/f_chart_v2.md`）

本部分覆盖图表：`flow-map` / `flowchart` / `forest` / `funnel`（含 M86 别名用例）/ `gain` / `gantt` / `gauge` / `grouped-bar` / `heat-flame` / `heat-map`。

## 发现

### [严重][存量] `gain` / `forest` 的 `LinearScale` 入参顺序颠倒，整图镜像（坐标轴方向反了）

- **位置**：`f_chart/src/GainChart.cj:125-126`（x、y 两个比例尺都反）、`f_chart/src/ForestChart.cj:183-184`（x 轴反）；同根因另见 `f_chart/src/LiftChart.cj:134-135`（范围外，供合并）
- **来源**：存量（`git blame -L 125,126 GainChart.cj` → `796b46a90` 2026-11-08「feat(f_chart): M95 增益图」）
- **判据**：review-checklist §10（正确性：坐标换算）/ §11（语义与命名、契约不符）
- **证据**：静态确定 —— `LinearScale` 的语义由 `f_chart/src/ChartScale.cj:22-43` 定义：第 3 个实参 `topPixel` 对应**最大值**、第 4 个 `bottomPixel` 对应最小值（`scale(v) = bottomPixel - (v-min)/span*(bottomPixel-topPixel)`）。同模块正确写法见 `f_chart/src/BarRenderer.cj:91`（y：`plot.y, plot.bottom()` ⇒ 大值在上）与 `f_chart/src/GanttChart.cj:105`（x：`plot.right(), plot.x` ⇒ 时间向右递增）。`GainChart` 写成 `LinearScale(xMin, xMax, plot.x, plot.right())` ⇒ xMax 落在左侧，`LinearScale(yMin, yMax, plot.bottom(), plot.y)` ⇒ yMax 落在**下方**，两轴同时反向，整图相当于旋转 180°
- **描述**：`gain` 图的样本比例轴从左到右递减、捕获比例轴从上到下递增，数据点、折线、对角基准线、刻度标签全部镜像；典型输入（`x:1.0, y:1.0`）画在左下角而非右上角，读图会得出相反结论。`forest` 的 `unitScale`（183 行）同构，置信区间、无效线与刻度整体左右翻转（0.1 画在右端、10 画在左端）。现有用例（`GainChart_test.cj`、`ForestChart_test.cj`）只数 `class` 出现次数，没有任何坐标断言，因此测不到
- **建议**：`GainChart` 改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)`、`LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`；`ForestChart` 的 `unitScale` 改为 `LinearScale(0.0, 1.0, frame.plot.right(), frame.plot.x)`。同时给 `LinearScale` 的构造参数改名（`maxPixel` / `minPixel`）并补一条几何断言用例（如「x=最大值 的像素 > x=最小值 的像素」），避免同类复制再犯

### [严重][存量] `heat-flame` 四个递归函数深度由输入决定且无上限，深链输入栈溢出

- **位置**：`f_chart/src/HeatFlameChart.cj:190-204`（`validateValues`）、`:206-214`（`assignDepth`）、`:216-224`（`layoutNode`）、`:226-256`（`drawNode`，递归在 `:253-255`）；调用点 `:127-128`、`:165`
- **来源**：存量（`git blame -L 190,193 HeatFlameChart.cj` → `4c9b402e3c` 2026-11-08）
- **判据**：review-checklist §4（无界递归：深度由输入决定）
- **证据**：静态确定（深度无上限）+ 需实测（溢出阈值）—— 递归深度 = 从根到最深叶的层数 = 最长 `parent` 链长度，上界是 `nodes` 数组长度，而 `nodes` 长度完全由 JSON 输入决定，模块内既无节点数上限也无层数上限，四个函数都不是迭代改写。唯一的守卫 `depth > total`（191、207）按本报告下一条已证明恒假，起不到限制作用
- **描述**：输入一条 1 万层、每层单子节点的 `parent` 链（合法输入：根 + 逐层 `parent` 指向上一层，`value` 递增即可通过 `validateValues` 的和校验）时，`validateValues` 先在 1 万层深度处耗尽栈帧，进程直接崩溃而不是抛 `ChartException`；`layoutNode` / `drawNode` 同深度。仓颉不保证尾调用优化，三个函数也都不是尾递归
- **建议**：改为显式栈迭代（后序算和、层序算 depth/x/width、层序绘制），或在解析阶段限制层数（如 `maxDepth` 默认 64）与节点数（如 5000），超限抛 `chartInvalidValue`，并把上限写进 `doc/chart-json-spec.md`；同根因的 `FlameChart.cj:167-206`、`DifferentialFlameChart.cj:185-224` 应一并修

### [一般][存量] `gain` 文档承诺的 `baseline` 字段未被读取，对角基准线未必等于 y=x

- **位置**：`f_chart/src/GainChart.cj:147-152`（基准线固定取绘图区对角）；承诺源 `f_chart/doc/chart-json-spec.md:1982`（「专属字段：`baseline`（对角线）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现）/ §11（契约与实现不符）
- **证据**：静态确定 —— `grep -n "baseline" f_chart/src/GainChart.cj` 只命中 `className: "gain-baseline"`（151），全文件无 `root.number("baseline")`；`LiftChart.cj:30-33` 有对应的解析与正数校验，可作对照
- **描述**：用户写 `"baseline": 0.5` 不会有任何效果也不报错。另外基准线固定画 `(xMin,yMin)→(xMax,yMax)`，只在两轴范围相同时才等价于 y=x；而 `xAxis.min/max` 与 `yAxis.min/max` 可分别覆盖（75-90），两者不等时这条「无技能基准线」位置错误，增益图的核心判读依据失真
- **建议**：解析并校验 `baseline`（正数），基准线画 `(xMin, baseline)→(xMax, baseline)` 或按 `y=x` 在各自比例尺下投影；若设计上不打算支持该字段，删除规格里的 `baseline` 描述

### [一般][存量] `forest` 校验了 `yAxis.labels` 长度却不用它渲染，配置被静默忽略

- **位置**：`f_chart/src/ForestChart.cj:103-108`（只做长度校验）、`:209-215`（行标签固定取 `row.label`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（读了不用 / 死配置字段）+ §14.1（接线缺失）
- **证据**：静态确定 —— `config.yAxis.labels` 全文件仅出现在 103-106 的校验里；绘制时 210 行传入的是 `row.label`。`ForestChart_test.cj:47` 的样例里 `yAxis.labels` 与 `data[].label` 恰好同名同序，掩盖了差异
- **描述**：用户想用 `yAxis.labels` 重命名或缩短行标签（长研究名常用缩写）时毫无效果，只会因长度不一致收到一条报错；字段语义「校验但不生效」属于半接线
- **建议**：绘制时优先用 `config.yAxis.labels[rowIndex]`（非空时），为空再回退 `row.label`；或按 §13 把该字段从 forest 小节删掉，只保留 `data[].label`

### [一般][存量] `forestLogTicks` 无迭代上限，`logBase` 接近 1 时刻度数爆炸

- **位置**：`f_chart/src/ForestChart.cj:236-254`（指数区间 242-243，循环 245-251）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.4（低效算法：循环次数由入参放大）/ §11（缺少边界校验）
- **证据**：静态确定 —— 循环次数 = `floor(log(max)/log(base)) - ceil(log(min)/log(base)) + 1`，只校验 `base > 1.0`（237）。取 `min=0.1, max=10, base=1.0000001` 得约 4.6e7 次 `pow` + 比较；同模块的 `chartNiceTicks`（`ChartScale.cj:98-103`）有 `guard < 1000` 上限，本函数没有
- **描述**：`{"xAxis":{"type":"log","logBase":1.0000001}}` 这类看似合法的配置会让单次 `draw` 卡住数十秒（每次还会向 `ticks` 追加元素，刻度数同时膨胀到千万级，标签绘制也随之后移）；无拒绝路径，只能靠调用方超时
- **建议**：给 `logBase` 加下限（如 `>= 1.01`，否则 `chartInvalidValue`），并给循环加与 `chartNiceTicks` 一致的 `guard` 上限（如 1000）；两者都触发时抛明确异常

### [一般][存量] `forest` 对数轴不校验自定义刻度值，非正刻度导致 `SvgException` 泄漏

- **位置**：`f_chart/src/ForestChart.cj:128-130`（只校验 `xMin`/`dataMin`）、`:135-147`（`config.xAxis.values` 直接当刻度）、`:221-227`（`forestLogPosition` 取 `log(value)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理 / 契约不符）；契约源 `f_chart/src/Chart.cj:33`（`@throws ChartException 输入结构或数值不合法时抛出`）
- **证据**：静态确定 —— 输入 `{"xAxis":{"type":"log","values":[0,1,10]}}` 时 `position(0, …)` 计算 `log(0) = -inf`，`unitScale.scale(-inf) = +inf`，随后 `drawXAxisNumeric` → `kit.text` → `formatSvgNumber` 在 `f_svg/src/SvgNumber.cj:33-35` 抛 `SvgException`（不是 `ChartException`）
- **描述**：前端只按 `ChartException` 捕获时会漏掉这条路径，异常类型从 `SvgException` 冒出，错误信息也不带 `xAxis.values[i]` 路径，无法定位到具体刻度
- **建议**：解析 `xAxis.values` 后逐项校验（`isLog` 时要求 `> 0`），抛带下标的 `chartInvalidValue("xAxis.values[i]", …)`；或在 `position()` 内对 `value <= 0` 直接抛 `chartInvalidValue`

### [一般][存量] `gantt` 重复 `task.id` 静默覆盖，依赖箭头指向错误任务

- **位置**：`f_chart/src/GanttChart.cj:63-66`（建 `taskIndex` 时无查重）、`:67-76`（依赖校验只查存在性）
- **来源**：存量
- **判据**：review-checklist §11（静默数据错误）/ §10（缺少边界校验）
- **证据**：静态确定 —— `taskIndex[tasks[index].id] = index` 后写覆盖前写，无 `contains` 判断也无报错；同模块 `Flowchart.cj:91-97` 对节点 id 做了重复校验，`HeatFlameChart.cj:78-82` 同样做校验，只有 `gantt` 漏掉
- **描述**：两个任务同名 `id` 时，所有 `dependsOn` 指向它都会解析到**后一个**任务，依赖折线与箭头连到错误行；后一个任务的任务条还会覆盖前一个的进度渲染，用户无法从输出看出输入有歧义
- **建议**：建索引前用 `if (taskIndex.contains(id)) throw chartInvalidValue("tasks[${index}].id", "任务 id 重复")`，与 `Flowchart` 保持一致；补一条重复 id 的负向用例

### [一般][存量] `gantt` 未实现规格承诺的 `lane`，全部任务挤在单列

- **位置**：`f_chart/src/GanttChart.cj:184-210`（`parseTasks` 不读 `lane`）、`:125-154`（`rowHeight = plot.height / tasks.size`，单列排布）；承诺源 `f_chart/doc/chart-json-spec.md:2142`（`tasks: [{…, lane?, color?}]`）与 `:2151-2157`（示例 `lane` 分组为「需求/设计/开发/测试/上线」）
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现 / 只做了一半）
- **证据**：静态确定 —— `grep -n "lane" f_chart/src/GanttChart.cj` 零命中；`GanttTask`（23-49）无 `lane` 字段；行位置完全由数组下标决定（129、161）
- **描述**：规格示例（5 个任务分 5 条泳道）按当前实现会变成 5 行逐行排列、泳道标签（`yAxis.labels`）也不出现，与文档图意不符；用户按文档组织数据得不到对应视觉结构
- **建议**：`parseTasks` 读入 `lane`，用「lane → 行号」映射决定 `centerY`（无 `lane` 时回退数组下标），并在规格中明确 `lane` 多任务同行的行高分配规则；若不实现则应从规格删除 `lane` 与示例

### [一般][存量] `gauge` 阈值未覆盖到 `max` 时留下空白扇段

- **位置**：`f_chart/src/GaugeChart.cj:136-149`（循环只画 `[bandStart, bandEnd]`，无收尾段）
- **来源**：存量
- **判据**：review-checklist §10（渲染完整性）/ §11（契约与实现不符）
- **证据**：静态确定 —— `bandStart` 从 `startAngle` 起，每次 `bandEnd = gaugeAngleForValue(threshold.value, …)` 后 `bandStart = bandEnd`；循环结束后不再画 `[last, endAngle]`。`thresholds` 只要求严格递增且 `<= max`（64-69），不要求末项等于 `max`；规格 `doc/chart-json-spec.md:2577-2599` 也未要求
- **描述**：`thresholds: [{value:60},{value:85}]`（max=100）时 85–100 区间没有任何色带，仪表盘出现缺口；缺口宽度随量程变化，容易被误读成「数据缺失」
- **建议**：循环后补一段 `gaugeArcPath(…, bandStart, endAngle)`，用最后一个阈值色或统一的「超阈值色」填充；或在解析时要求 `末项 value == max`，否则抛 `chartInvalidValue`

### [一般][存量] `heat-flame` 环/不可达节点被静默丢弃，两处「存在环」守卫恒不可达

- **位置**：`f_chart/src/HeatFlameChart.cj:111-128`（建树 + 只校验根数量）、`:190-193` 与 `:206-209`（`depth > total` 守卫）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）+ §11（静默数据错误）
- **证据**：静态确定 —— 每个节点只有一个 `parent`，`roots.size == 1` 要求全图恰有一个无父节点；环上每个节点都有父节点，因此环必然是**与根不相连的独立分量**，`validateValues`/`assignDepth` 只沿根可达子树下钻，深度上界 `<= nodes.size - 1 < total`，`depth > total` 恒假。环分量既不参与布局与绘制，也不报错
- **描述**：输入 `root(parent=null)`、`b(parent=c)`、`c(parent=b)` 时 `b`、`c` 整块消失（不渲染、不计入 `validateValues` 的子节点和校验），用户看到「少了两块」而没有任何提示；两处环检测代码实际是死分支
- **建议**：解析阶段用父链查环（沿 `parent` 上溯计数，超过 `nodes.size` 判环）或用 `HashSet` 做访问标记，并在建树后校验「可达节点数 == nodes.size」，不满足抛 `chartInvalidValue`；把 `depth > total` 换成这条可达性校验，同时补一条环输入用例

### [一般][存量] `funnel` 层高可为负，矮画布 + 多阶段生成非法 rect 与重叠文本

- **位置**：`f_chart/src/FunnelChart.cj:105-117`（`top`/`bottom`/`stageHeight` 计算，矩形在 113-117）
- **来源**：存量
- **判据**：review-checklist §11（边界：负数尺寸）/ §10（缺少边界校验）
- **证据**：静态确定 —— `top = padding.top + 60`、`bottom = height - padding.bottom - 30`、`stageHeight = (bottom - top - gap*(n-1)) / n`；只有 `width/height > 0`（`ChartConfig.cj:182-183`）与 `gap >= 0`（81-83）被校验，`stageHeight <= 0` 无校验。例：`height=100`（padding 默认 24）⇒ `bottom-top = 46-84 = -38`，3 个阶段时 `stageHeight ≈ -14.7`
- **描述**：`rect` 高度为负（SVG 渲染器按无效/反向处理，多数浏览器丢弃），阶段名与转化率文本挤在同一位置或落到画布外；用户只看到空白漏斗
- **建议**：计算后校验 `stageHeight > 0`（并给出「画布高度不足或阶段过多」的路径化错误），或按阶段数自适应压缩 `gap` / 缩小 60px 的头部预留

### [一般][存量] 地图类（`flow-map` / `heat-map`）的 viewBox、底图、标题绘制整段重复

- **位置**：`f_chart/src/FlowMapChart.cj:62-75` ↔ `f_chart/src/HeatMap.cj:43-56`（viewBox 解析与校验逐行同构）；`FlowMapChart.cj:161-191` ↔ `HeatMap.cj:122-152`（背景矩形 + 标题 + `regions[].path` 底图绘制）；`FlowMapChart.cj:77-101` ↔ `HeatMap.cj:62-77`（regions 解析，前者多 id 去重与质心计算）
- **来源**：存量
- **判据**：review-checklist §2（跨层/跨文件复制：同一套校验与绘制散落多处）
- **证据**：静态确定 —— 两段 viewBox 代码除变量作用域外完全一致（`size != 4 || [2] <= 0 || [3] <= 0` 判定与三条错误文案相同）；底图段同样顺序调用 `kit.rect/viewBox` → `kit.text(title)` → 遍历 `regions` 画 `#f0f0f0` 填充 + `#cccccc` 描边的 path
- **描述**：新增地图类型（`choropleth` / `cartogram` / `dot-density-map`）时又要复制一遍，改一处漏一处；例如后来 `choropleth` 已经用了另一套；同时「regions 必须至少一个」「id 去重」「质心缓存」只有 `flow-map` 有，`heat-map` 无，行为已经漂移
- **建议**：抽 `MapCanvas`（内部 `viewBox` 解析 + `drawBaseMap(kit, regions)` + `drawTitle`）到 `ChartFrame.cj` 或新 `MapSupport.cj`，`flow-map` 仅保留 flows 部分；regions 解析统一成 `Array<MapRegion>`（id/name/path/center 可选，按需计算质心）

### [一般][存量] 火焰图三处实现逐行同构（`heat-flame` / `flame` / `differential-flame`）

- **位置**：`f_chart/src/HeatFlameChart.cj:64-128`（节点解析 + 建树 + 校验调用）与 `:181-256`（findNode / validateValues / assignDepth / layoutNode / drawNode）；对照 `f_chart/src/FlameChart.cj:58-112`、`:158-248`；`f_chart/src/DifferentialFlameChart.cj:176-224`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名：`FlameNode` → `HeatFlameNode`）
- **证据**：静态确定 —— `validateValues`（HeatFlameChart 190-204 vs FlameChart 167-184）、`assignDepth`（206-214 vs 186-194）、`layoutNode`（216-224 vs 196-204）除节点类型与字段外逐行一致；`drawNode` 仅在 `colorBy`/`ratio` 取值上不同；`findNode` 只有返回类型不同
- **描述**：三份（含 `OfflineFlameChart` / `TuiFlameChart` 变体）同构代码各自维护，`validateValues` 的环检测、`layoutNode` 的宽度累加、`drawNode` 的标签阈值判断任何一处修 bug 都要改三遍；本文上一条的栈溢出与静默丢节点缺陷也因此同时存在于三处
- **建议**：抽「火焰树模型 + 布局」到 `FlameLayout.cj`（`parseFlameNodes` / `validateFlameTree` / `layoutFlame`），颜色与绘制差异以策略参数（`heatField` / `ratioSource` / `colorMode`）传入；`heat-flame` 只保留热力取色

### [一般][存量] `gain` 与 `lift` 曲线主体逐行同构，已出现行为漂移

- **位置**：`f_chart/src/GainChart.cj:30-61`（series 校验 + `{x,y}` 解析）↔ `f_chart/src/LiftChart.cj:34-65`；`GainChart.cj:154-180`（折线 + 点）↔ `LiftChart.cj:170-196`；同用 `volcanoNumber` / `sortLiftPoints`
- **来源**：存量
- **判据**：review-checklist §2（只改图名 / 字面量复制）
- **证据**：静态确定 —— 两段 series 解析除错误文案里的「增益图/提升图」外完全一致；折线路径拼接与散点循环（`M … L …` + `circle 3.5`）除 class 名（`gain-line`/`lift-line`）外一致。差异只有基线画法（对角 vs 水平 `baseline`）、右留白（`LiftChart.cj:130-133` 传 `rightLabelWidth: 40.0`）与 y 轴留白策略
- **描述**：同一能力的两个图各写 150 行，已经漂移：`lift` 有基线数值标签与右留白，`gain` 没有；`lift` 的 y 范围带 8% 留白，`gain` 强制两轴同一范围。后续修比例尺（本报告第一条）要改两处、容易漏
- **建议**：抽 `LineSeriesRenderer`（series 解析 + 比例尺 + 折线/点 + 轴），把「基线类型（水平/对角）」「轴范围策略」「右留白」作为参数；参照已有的 `BarRenderer.cj` 分层

### [轻微][存量] `heatFlameColor` 两个分支不可达，且只使用前三个颜色

- **位置**：`f_chart/src/HeatFlameChart.cj:260-283`（`colors.isEmpty()` 261-263、`colors.size == 1` 274-276）；调用点 `HeatFlameChart.cj:134-136`、`HeatMap.cj:108-110`、`CartogramChart.cj:116-118`、`ChoroplethChart.cj:107-109`、`ConfusionMatrixChart.cj:127`（字面量 2 色）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）/ §11（静默忽略入参）
- **证据**：静态确定 —— 五个调用点在调用前都保证 `colorRange.size >= 2`（含字面量 `["#e3f2fd","#0d47a1"]`），故 `isEmpty` 与 `size == 1` 两条分支不可达；`size >= 3` 时只取 `colors[0..2]`（272），第 4 个及以后的颜色被静默丢弃
- **描述**：色阶函数名义上支持 0/1/2/3+ 色，实际只有 2 色与 3 色两种生效；调用方传 4 色（如 `calendar-heatmap` 风格的分级色）时不会报错但也不会生效，排查成本高
- **建议**：把契约收窄为「至少 2 色，取前 3 色，>3 抛 `chartInvalidValue`」并在文档写明，删掉两条不可达分支；若确需 N 色分段，改为按 `ratio*(n-1)` 选相邻两色插值

### [轻微][存量] `gain` 的 `span` 计算后从未使用

- **位置**：`f_chart/src/GainChart.cj:71-74`
- **来源**：存量
- **判据**：review-checklist §1（局部变量赋值后不读）
- **证据**：静态确定 —— `grep -n "span" f_chart/src/GainChart.cj` 仅命中 71/72/73 三行；后续 `xMin/xMax` 直接用 `rangeMin/rangeMax`（75-90），`span` 未参与任何表达式
- **描述**：读代码时会误以为坐标范围经过 `span` 修正，实际是纯残留；`LiftChart.cj:85-96` 的 `ySpan` 才是真正参与留白计算的写法
- **建议**：删除 71-74；若本意是「数据范围为 0 时扩成 1」，应改为把 `rangeMin/rangeMax` 按 `span` 扩展，而不是算完丢弃

### [轻微][存量] `Flowchart.parseEdges` 的 `nodes` 参数未使用

- **位置**：`f_chart/src/Flowchart.cj:185-206`（签名在 185），调用点 `:89`
- **来源**：存量
- **判据**：review-checklist §1（无读取的参数）
- **证据**：静态确定 —— 函数体只使用 `root.array("edges")` 与 `json.requiredString`，`nodes` 零引用；节点存在性校验在 `draw` 里用 `idMap` 另做（98-105）
- **描述**：参数暗示「解析边时需要节点信息」，与实现不符；也让人误以为边解析已做端点校验
- **建议**：删掉该参数（调用点同步改），或把 98-105 的端点校验移进来使用它

### [轻微][存量] `FunnelChart` 的 `import std.math.*` 未使用

- **位置**：`f_chart/src/FunnelChart.cj:19`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 全文无 `abs/sqrt/minFloat/maxFloat/pow/log/ceil/floor/sin/cos/round` 调用（`funnelConversion` 只用四则运算，`values[position] / maxValue * maxWidth` 同理）
- **描述**：多余的 import 会掩盖真实依赖，`cjlint` 也会报
- **建议**：删除该行

### [轻微][存量] 数值类型判定与 `jsonNumberValue` 重复（`funnel` / `gauge`）

- **位置**：`f_chart/src/FunnelChart.cj:62-66`、`f_chart/src/GaugeChart.cj:103-107`
- **来源**：存量
- **判据**：review-checklist §2（同一校验两遍，语义相同）
- **证据**：静态确定 —— 两处都先 `if (!(value.kind.isInt || value.kind.isDecimal)) throw chartInvalidValue(…, "期望数字")`，紧接着调用 `jsonNumberValue(value, …)`，而后者（`f_chart/src/ChartJson.cj:215-227`）做的就是同一判定 + 有限数判定
- **描述**：同一条规则两套文案（「期望数字」/「期望数字」一致，但错误路径是否带有限数校验取决于走哪条），后续改文案容易只改一处；`GaugeChart` 的错误文案还写成「数值必须是数字」
- **建议**：删掉显式 `kind` 判断，直接 `jsonNumberValue`；文案统一放在 `ChartJson.cj`

### [轻微][存量] `Flowchart` 未校验 `layout` / `shape` 枚举，未知值静默回退

- **位置**：`f_chart/src/Flowchart.cj:108`（`layout` 任意字符串）、`:320-346`（`shape` 的 `case _ =>` 回退矩形）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验，静默回退）/ §13（`horizontal` 未进规格）
- **证据**：静态确定 —— `layout` 只与 `"manual"`、`"horizontal"` 比较，其它值一律走垂直分层；`shape` 只匹配 `diamond/ellipse/round/parallelogram/document`，未知值画普通矩形。规格 `doc/chart-json-spec.md:2164` 列了 6 种 `shape`，未提 `horizontal`
- **描述**：拼写错误（`"HORIZONTAL"`、`"diamnod"`）不报错也不提示，图静默变成另一种形态，排障只能靠肉眼比对
- **建议**：解析时校验枚举并抛 `chartInvalidValue("nodes[i].shape", "期望 rect/round/diamond/ellipse/parallelogram/document")`、`("layout", "期望 vertical/horizontal/manual")`；把 `horizontal` 补进规格

### [轻微][存量] `gauge` 未限制角度跨度 ≤ 360°，超过时弧段语义失真

- **位置**：`f_chart/src/GaugeChart.cj:45-49`（只校验 `startAngle < endAngle`）、`:197-225`（`gaugeArcPath` 单段 `A` 命令）
- **来源**：存量
- **判据**：review-checklist §11（边界校验缺失）
- **证据**：静态确定 —— `endAngle - startAngle` 无上限，`gaugeArcPath` 用一个 `A rx ry 0 largeArc 1 …` 表达整段；SVG 圆弧命令单段最多表达 360°，跨度更大时实际绘制角度小于配置值，`largeArc`（208）也只有 0/1 两种
- **描述**：`startAngle:-400, endAngle:400`（跨度 800°）时图形与指针位置不再对应配置角度，且指针可落在色带之外，读者无法判断真实刻度
- **建议**：校验 `endAngle - startAngle <= 360`（超出抛 `chartInvalidValue`），或将跨度限制在 `(0, 360]` 并文档化

### [轻微][存量] `gauge` 静默忽略多余的 series 与 data 项

- **位置**：`f_chart/src/GaugeChart.cj:83-110`（只取 `seriesItems[0]` 与 `dataItems[0]`）
- **来源**：存量
- **判据**：review-checklist §11（静默丢弃输入）/ §14.1（只处理部分输入）
- **证据**：静态确定 —— 无 `seriesItems.size != 1` 校验（对照 `FunnelChart.cj:39-41`、`ForestChart.cj:58-60`、`GainChart.cj:35-37` 都有），`dataItems.size` 也只判非空
- **描述**：多系列或多数据点时，除第一个外全部被丢弃且无提示；同一份数据换到 `funnel`/`forest` 会报「仅支持 1 个系列」，契约不一致
- **建议**：加 `seriesItems.size == 1` 与 `dataItems.size == 1` 的校验，错误文案与其它单值图统一；若确实要支持多指针，应显式实现而不是静默截断

## 优化可行性方案

### [CPU] `heat-flame` / `flow-map` 的 O(n²) 查重与查找、三处手写插入排序

- **现状**：`HeatFlameChart.cj:78-82` 每节点对 `parsed` 全表查重、`:115`（`findNode`，实现 181-188）每节点再线性找父节点 ⇒ 约 2×n²/2 次字符串比较，n=10k 时约 1e8 次。`FlowMapChart.cj:91-95` regions 去重 O(R²)、`:125-130` 每条 flow 两次 `findRegion`（225-232）再在绘制循环 `:196-197` 重复两次 ⇒ O(F·R)。`FlowMapChart.cj:234-249`、`HeatMap.cj:167-182`、`LiftChart.cj:203-218` 为插入排序，逆序输入最坏 O(n²)
- **方案**：一轮收集后建 `HashMap<String, Int64>`（id → 下标/对象），查重与父节点解析都走 O(1)；排序改用 `std.sort`（仓库已有用法：`f_llm/src/channel/ChannelMediator.cj:19` `import std.sort.*`），稳定序需求用「值 + 原下标」比较器保证
- **预期**：n=10k 的节点/流输入，比较次数从 ~1e8 降到 ~1e4，排序从 O(n²) 降到 O(n log n)；端到端收益取决于图表数据规模（未测）
- **代价**：`HashMap` 额外 O(n) 堆内存；排序改为稳定版需要额外比较键；`flow-map` 的 `findRegion` 需改成索引表后同步 `regions[...]` 访问
- **验证**：`cjpm bench -O2`，同一份 JSON 分别取 1k / 10k / 50k 节点（及 1k / 5k flows），比较改前改后中位数与 P95
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 排序前的整表第三次复制

- **现状**：`FlowMapChart.sortFlows`（234-249）与 `HeatMap.sortByValue`（167-182）都把 `ArrayList` 先 `toArray()`（1 份），再逐项 `add` 进新 `ArrayList`（第 2 份），最后再 `toArray()`（第 3 份）；同一批引用同时在 3 个等长容器里存活到函数返回。`FlowMapChart.cj:136-157` 每条 flow 的 `points` 也是 `ArrayList` → `toArray()` 双份
- **方案**：直接用 `Array` 承载并就地排序（或 `std.sort` 于 `Array`），删除中间 `ArrayList` 与首尾两次 `toArray()`；`points` 先按 `pointItems.size` 一次分配再填
- **预期**：峰值少 2×n 个引用槽（n 为 flow/point 数，10k 规模约 160 KB）与 2 次整表 GC 扫描；收益量级小，属「顺手清理」
- **代价**：需保证排序稳定性与现有绘制顺序一致（同值元素按输入顺序叠放）；改动局限在这两个函数
- **验证**：`getAllocatedHeapSize()` 包住单次 `draw`（同输入 10k 点），改前改后各跑 5 轮取中位数；同时核对 SVG 输出与改前逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `heat-flame` 建树的 O(n²) 查重/查找在 n≥10k 时成为单次 `draw` 的主要耗时 | `f_chart/src/HeatFlameChart.cj:78-82,115` | 自耗时占比、调用次数 | 生成 10k 节点 JSON，`cjprof record` 跑 100 次 `draw`，看 `findNode` 与 id 比较的 self time |
| 2 | `flow-map` 的 O(F·R) 线性查找 + 插入排序在 F=5k、R=1k 时可感知 | `f_chart/src/FlowMapChart.cj:125-130,196-197,234-249` | F·R 规模下的单次耗时占比 | 生成 1k 区域 × 5k 流的 JSON，分段计时 `parse` / `sortFlows` / `draw` |
| 3 | 单次 `draw` 的临时分配（`StringBuilder` + 多层 `ArrayList`）在 10k 数据点时造成明显 GC 抖动 | 本部分全部 `draw` | 每次分配字节数、GC 次数 | `getAllocatedHeapSize()` 前后差 + `cjprof heap`，同输入跑 5 轮 |
| 4 | 2 色 `colorRange` 时每个节点 2 次 `SvgColor.tryParse`（`heatFlameColor` 277-278）在 10k 节点下可测 | `f_chart/src/HeatFlameChart.cj:271-282` | 解析耗时占比 | 微基准：10k 次 `heatFlameColor` 调用，对照预解析后的插值实现 |

> 4 条均无改前基线，仅作下一轮补数据清单，不计入模块统计，不进 `todo.md` / `tasks.md`。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/FlowMapChart.cj` | .cj | ✅ | 比例尺/查重/排序问题，见发现与优化方案 |
| 2 | `f_chart/src/FlowMapChart_test.cj` | .cj | ✅ | 11 个用例，无坐标断言（掩盖镜像类缺陷） |
| 3 | `f_chart/src/Flowchart.cj` | .cj | ✅ | `parseEdges` 未用参数、枚举未校验 |
| 4 | `f_chart/src/Flowchart_test.cj` | .cj | ✅ | 含 manual 布局与 `SvgParser` 往返用例 |
| 5 | `f_chart/src/ForestChart.cj` | .cj | ✅ | x 轴镜像、`yAxis.labels` 未生效、`forestLogTicks` 无上限 |
| 6 | `f_chart/src/ForestChart_test.cj` | .cj | ✅ | 只断言计数，未覆盖对数轴自定义 `values` |
| 7 | `f_chart/src/FunnelAlias_test.cj` | .cj | ✅ | M86 别名用例（`type` 仍为 `funnel`），与规格 `:222,1609` 一致 |
| 8 | `f_chart/src/FunnelChart.cj` | .cj | ✅ | 层高可负、未用 import、重复类型校验 |
| 9 | `f_chart/src/FunnelChart_test.cj` | .cj | ✅ | 覆盖转化率与多系列拒绝 |
| 10 | `f_chart/src/GainChart.cj` | .cj | ✅ | 双轴镜像、`baseline` 未实现、`span` 死代码 |
| 11 | `f_chart/src/GainChart_test.cj` | .cj | ✅ | 无坐标断言 |
| 12 | `f_chart/src/GanttChart.cj` | .cj | ✅ | 重复 id、`lane` 未实现；x 轴比例尺用法正确 |
| 13 | `f_chart/src/GanttChart_test.cj` | .cj | ✅ | 未覆盖重复 id / `lane` |
| 14 | `f_chart/src/GaugeChart.cj` | .cj | ✅ | 阈值缺口、角度跨度、多 series 静默截断 |
| 15 | `f_chart/src/GaugeChart_test.cj` | .cj | ✅ | 5 个用例，含越界/角度/阈值负向 |
| 16 | `f_chart/src/GroupedBarChart.cj` | .cj | ✅ | 31 行，委托 `BarRenderer`，无问题 |
| 17 | `f_chart/src/GroupedBarChart_test.cj` | .cj | ✅ | 含 `groupedBarX` 不重叠断言 |
| 18 | `f_chart/src/HeatFlameChart.cj` | .cj | ✅ | 递归无深度上限、静默丢节点、死分支 |
| 19 | `f_chart/src/HeatFlameChart_test.cj` | .cj | ✅ | 9 个用例，无深链/环用例 |
| 20 | `f_chart/src/HeatMap.cj` | .cj | ✅ | 与 `flow-map` 骨架重复；排序 O(n²) |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4（比例尺镜像、对数刻度异常类型、gantt 重复 id、funnel 负层高）+ 渲染完整性 1（gauge 缺口）+ 可读性 1（未用 import）；无安全问题（SVG 属性转义由 `f_svg` 负责，范围外） |
| §1 死代码 | 6 | 已逐个 private/internal 符号全模块 grep：`flowMapWidth`/`forestLog*`/`funnelConversion`/`gaugeAngleForValue` 等均有调用者（部分仅测试，属可见性建议，未计）；命中 = 不可达环守卫（HeatFlame 190-193/206-209）、`heatFlameColor` 两分支、`span`、`parseEdges` 未用参数、未用 import、`ForestChart` 的 `yAxis.labels` 死配置 |
| §2 重复逻辑 | 5 | 已对 10 个实现文件的函数体做「输入-输出-副作用」两两比对：地图骨架（viewBox/底图/regions）、火焰图三实现、gain↔lift 曲线、三处插入排序 + 四处 colorRange 校验、数值类型校验两遍。测试文件里 20 份 `count()` 辅助按 §2 误报边界不报 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch { () }`；`match` 的 `case None => ()` 均为可选字段正常缺省 |
| §4 栈溢出 | 1 | `heat-flame` 四个递归（本报告第 2 条）；本部分其余图表无递归（`flowchart` 分层为迭代，`gantt`/`gauge`/`funnel` 无递归） |
| §5 OOM | 0 | 所有容器规模与输入线性、无全局缓存/注册表；`funnel`/`gauge` 容器由 `series[0].data` 长度决定；递归爆栈归 §4，非堆问题 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点不成立；已列入「待验证假设」1-4 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 共享可变状态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 任务提交 |
| §6.4 低效算法 | 1 | `forestLogTicks` 迭代次数随 `logBase→1` 爆炸（已按无基线上限论证，属算法+校验）；O(n²) 查重/查找与插入排序因缺测量数据只进优化方案与假设 |
| §7 降堆内存方案 | 1 | 排序前整表第三次复制（见优化方案，无基线） |
| §8 降 CPU 方案 | 1 | HashMap 索引 + `std.sort`（见优化方案，无基线） |
| §9 local mode 可行性 | 0 | 所有 `draw` 返回 `String`，节点数组/临时 `ArrayList` 虽在函数内创建，但经 `SvgBuilder` 与返回值逃逸；且无峰值内存数据，改造不成立 |
| §11 现有代码的 BUG（存量） | 22 | 本部分全部 22 条发现均为存量（快照基线 `120fd2542`，逐条 `git blame` 抽查为 2026-11-08 的模块提交） |
| §12 并发安全与锁粒度 | 0 | 各 `Chart` 实现类无字段（`public init() {}`），`draw` 内状态全为局部变量、不修改入参，符合 `Chart.cj:25-30` 的纯函数契约；无线程共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | `gain.baseline` 未实现、`gantt.lane` 未实现；本部分无 `.md`，文档覆盖由其它部分负责，此处仅引用 `doc/chart-json-spec.md` 作承诺源 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个 `.cj` 全部读完；无 `.md`，§13 不适用（规格对照见 §14） |

**范围外提示**：`FlowMapChart.cj:98` 依赖 `pathCentroid`，该函数把 SVG 弧命令参数当坐标平均（根因在 `ChoroplethChart.cj:176-217`，已由 part27 单列）。`regions[].path` 含 `A`/`H`/`V` 时，缺省 `points` 的 flow 端点会落在错误位置；本文未重复计数，修 `pathCentroid` 时一并覆盖 `flow-map`。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 12 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分 10 个图整体结构清晰：解析-校验-布局-绘制四段分明，错误文案带 JSON 路径，类目/数值比例尺基本统一走 `Chart`/`ChartFrame`/`ChartSvgKit`，边界校验在多数图上做得比同类库更细（`gauge` 量程、`forest` CI 顺序、`heat-flame` 子节点和校验）。

真正需要先处理的是两类系统性问题：

1. **坐标换算错误**（严重）：`GainChart` 两轴、`ForestChart` 的 x 轴把 `LinearScale` 的 `topPixel/bottomPixel` 写反，输出整图镜像；这类缺陷不影响异常与计数类用例，只能靠坐标断言发现，建议连同 `LinearScale` 的参数命名一起修，并补几何断言。
2. **递归无深度上限**（严重）：`heat-flame` 四个递归函数深度等于输入链长，深链 JSON 直接崩溃进程；同根因还在 `flame` / `differential-flame`，应统一抽布局工具并加上限。

其次是「文档承诺、代码不读」的静默失效：`gain.baseline`、`gantt.lane`、`forest` 的 `yAxis.labels`，以及 `gauge` 阈值末段未补满、`funnel` 负层高这类渲染完整性问题；`gantt` 重复 id 会画出错误依赖，属静默数据错误。

可维护性方面，地图骨架、三份火焰图、`gain`/`lift` 曲线与三处手写插入排序构成明显的复制扩散，是后续修 bug 漏改的主要来源；这些与 O(n²) 查找一起建议在比例尺与递归两项修完后排期。

本部分存量 22 条（严重 2 / 一般 12 / 轻微 8），是否纳入修复待用户决定；两条严重项建议优先确认。优化方案与待验证假设均无改前/改后对照数据，本轮不作为结论。
