# f_chart 模块审查报告（第 10/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个文件，全部为 `.md`；模块整体 251 个 `.cj` + 444 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线，全部问题来源记「存量」）
- **审查重点**：`doc/spec/add-f-chart-{flowchart,forest,funnel,funnel-alias,gain,gantt}` 的规格与实现一致性；由此追出的渲染/布局算法正确性、坐标与边界、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（模块第 10/37 部分，仅覆盖 `files/f_chart.part10.txt` 的 20 个 `.md`）

> 说明：本部分清单只有 6 个变更的 `proposal/design/tasks/specs` 文档。规格里的每条 MUST/SHALL 都回到实现逐个核对（`Flowchart.cj` / `ForestChart.cj` / `FunnelChart.cj` / `GainChart.cj` / `GanttChart.cj` 及其直接依赖 `ChartScale.cj` / `ChartFrame.cj` / `ChartTime.cj` / `ChartSvgKit.cj`），因此下文的实现侧缺陷都是「文档核对追出」的，坐标结论用仓库里已提交的画廊产物（`f_chart/charts/*.svg`）做了交叉验证。实现文件若在其他部分被重复报告，请按同一根因合并。

## 发现

### [严重][存量] 森林图/增益图坐标轴方向反转：像素参数顺序与 `LinearScale` 语义相反

- **位置**：`f_chart/src/GainChart.cj:125-126`（x、y 两个比例尺）、`f_chart/src/ForestChart.cj:183`（单位比例尺）
- **来源**：存量（快照模式无基线；`git blame` 无 diff 可比）
- **判据**：review-checklist §13（规格与实现漂移）+ §11（渲染结果错误）；对照 `f_chart/src/ChartScale.cj:22-43` 的 `LinearScale` 契约「`topPixel` 对应最大值、`bottomPixel` 对应最小值」
- **证据**：静态确定 —— `LinearScale(min, max, topPixel, bottomPixel)` 中 `scale(max) = topPixel`。`GainChart` 传 `(plot.x, plot.right)` 使 x 最大值落在左边界，传 `(plot.bottom, plot.y)` 使 y 最小值落在顶边；`ForestChart` 传 `(plot.x, plot.right)` 使 `position=0`（即 `lower`）落在右边界。已提交产物与算式一致：`f_chart/charts/M095-gain.svg` 里 y 轴刻度 `0` 在 `y=74`、`1` 在 `y=432`（纵向翻转），`gain-baseline` 从 `(776,74)` 画到 `(56,432)`（右上→左下）；`f_chart/charts/M050-forest.svg` 里刻度 `0.1` 在 `x=696`、`10` 在 `x=73`（横向镜像）
- **描述**：`add-f-chart-gain/specs/chart-rendering/spec.md:16` 要求对角线「连接左下角与右上角」，实现画成右上到左下；两轴刻度文字也自左向右递减。森林图同样把 `lower` 画在 `upper` 右侧，对数轴刻度自右向左递减。两图对使用者呈现的是镜像/翻转的数据位置，属于输出错误而不是风格差异：`GainChart` 是 180° 旋转（两轴同时反向），`ForestChart` 是水平镜像。现有测试只统计 `class="..."` 出现次数（`GainChart_test.cj:58-76`、`ForestChart_test.cj:64-99`），未断言任何坐标，故长期未被发现
- **建议**：按 `LinearScale` 契约改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)` 与 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`（x 轴正确写法可参照 `GanttChart.cj:105`）；同时给两个测试各加一条坐标断言（如「`x=0` 的点 cx 小于 `x=1` 的点」），否则同类回归仍会漏过

### [严重][存量] 流程图自动布局按固定层距排布，4 层以上整体画出画布

- **位置**：`f_chart/src/Flowchart.cj:252-260`（`layoutNodes` 两个分支都用 `level * (maxNodeSize + 90.0)` 与 `plot` 尺寸无关的固定步长）
- **来源**：存量
- **判据**：review-checklist §11（布局边界/坐标越界）+ `add-f-chart-flowchart/specs/chart-rendering/spec.md:30`（`layout` 为 `vertical` 时按入边深度自上而下分层）
- **证据**：静态确定 —— 默认画布 800×480、`padding` 24（`ChartConfig.cj:22-25`、`ChartConfig.cj:167-168`），无标题时 `plot.height = 432`，纵向层距 `maxNodeHeight + 90 = 138`；第 4 层节点中心 `y = 24 + 3×138 + 24 = 462`，节点下沿 486 > 480。仓库自带画布产物同现象：`f_chart/charts/M009-flowchart.svg`（900×520，6 节点）中第 4 层节点在 `y=552`、第 5 层在 `y=712`，即 6 个节点有 3 个完全落在画布外
- **描述**：`vertical` / `horizontal` 两个分支都只按层号乘常量步长定位，从不按 `plot.height` / `plot.width` 或层数缩放，也没有把画布尺寸自适应放大。任何深度 ≥4 的链式流程（含库自带的 M9 示例）都会被裁掉后半段；出现环时 `levels` 在 n 轮松弛中继续增长（`Flowchart.cj:219-228`），坐标会更远，问题同样表现为「节点静默消失」而不是报错
- **建议**：先算出最大层号，令层距 = `min(maxNodeHeight + 90, plot.height / (maxLevel + 1))`，或按 `maxLevel` 反推所需画布高度并同步 `viewBox`；对 `maxLevel` 设上限并在超限时抛 `InvalidValue`，避免靠画布裁剪掩盖

### [一般][存量] 森林图 `yAxis.labels` 只做长度校验，从不参与绘制

- **位置**：`f_chart/src/ForestChart.cj:103-108`（校验）与 `f_chart/src/ForestChart.cj:209-215`（绘制时用的是 `row.label`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用：配置读入后无效果）+ §14（接线缺失）
- **证据**：静态确定 —— 全文件仅此处读取 `config.yAxis.labels`，随后行标签固定取 `row.label`；`ForestChart_test.cj:47` 的样例把 `yAxis.labels` 与数据 `label` 写成同一组文字，所以测试无法暴露
- **描述**：调用方按 `doc/chart-json-spec.md:83`（`labels` 为类目轴标签）传入自定义 `yAxis.labels` 时，只会在长度不符时收到异常，长度相符时标签被静默丢弃；`add-f-chart-forest/design.md:11` 又写「行标签取数据 `label`」，两处约定不一致
- **建议**：二选一——要么按 `yAxis.labels[rowIndex]` 绘制并让数据 `label` 只做缺省回退，要么删掉这段校验并在 `design.md` / `chart-json-spec.md` 明确「森林图行标签只取数据 `label`，`yAxis.labels` 忽略」

### [一般][存量] 甘特图 `lane` 字段未解析、`yAxis.labels` 未使用，规格与样例却都要求

- **位置**：`f_chart/src/GanttChart.cj:184-210`（`parseTasks` 只读 id/name/start/end/progress/dependsOn/color）、`f_chart/src/GanttChart.cj:125-135`（行高按任务数均分，标签取 `task.name`）
- **来源**：存量
- **判据**：review-checklist §14（承诺了但没实现，需双证）
- **证据**：静态确定 —— 承诺源：`f_chart/doc/spec/add-f-chart-gantt/design.md:5`「每个任务解析 id/name/start/end/progress/dependsOn/lane/color」、`f_chart/doc/spec/add-f-chart-gantt/proposal.md:10`「顶层 `tasks`：{…, lane?, color?}」，且 `f_chart/src/ChartGallery_test.cj:193-200` 的官方样例每个任务都带 `lane`；缺失证据：`grep -rn "lane" f_chart/src/GanttChart.cj f_chart/src/GanttChart_test.cj` 无命中
- **描述**：`lane` 被文档当作行分组/泳道语义，实现完全忽略，所有任务按数组顺序一行一个；同样地 `yAxis.labels`（样例里给了 `["需求","设计","开发","测试","上线"]`）也没有任何读取点，左侧标签只能用 `task.name`。使用者按文档给 `lane` 分组，得到的是未分组的平铺结果且无任何提示
- **建议**：要么实现 `lane`（按 lane 分组、lane 名作为分组标题或行标签，同类任务共行）、并在缺少 `name` 时回退到 `yAxis.labels[index]`；要么从 `design.md` / `proposal.md` / `chart-json-spec.md` 删除 `lane` 与示例中的该字段，避免继续误导

### [一般][存量] 流程图边端点偏移取 `min(宽,高)/2`，横向边的箭头被节点覆盖

- **位置**：`f_chart/src/Flowchart.cj:285-290`（`startOffset` / `endOffset`）
- **来源**：存量
- **判据**：review-checklist §11（坐标计算与实际边界不符）
- **证据**：静态确定 —— 默认矩形节点 120×48，`min(120,48)/2 + 2 = 26`；横向连边时节点半宽是 60，连线起点与箭头终点都落在节点内部 34px 处，而节点在边之后绘制（`Flowchart.cj:145-159`）且带不透明填充（`Flowchart.cj:316`、`346`），故 26px 连线与整个箭头被遮住。`layout` 为 `horizontal` 或 `manual` 横向摆放时触发；纵向边不受影响（24+2 恰好等于半高）
- **描述**：形状边界偏移应当按连边方向求交（矩形取 `|ux|*w/2 + |uy|*h/2` 形式，菱形/椭圆另算），现在取短边一半，宽扁节点上的横向边显示为「无箭头、线贴着节点内部」
- **建议**：按单位向量与包围盒求交计算偏移量（至少矩形：`|ux|*(w/2) + |uy|*(h/2)`），或按 `shape` 分派到各自的边界函数；补一条横向布局的坐标断言

### [一般][存量] 漏斗图 `gap` 与可用宽度无下限校验，可生成负尺寸图元

- **位置**：`f_chart/src/FunnelChart.cj:80-83`（`gap` 只判非负）、`f_chart/src/FunnelChart.cj:108-112`（`maxWidth` 与 `stageHeight` 直接相除）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 / 负值进入几何计算）
- **证据**：静态确定 —— 4 阶段、`gap=200` 时 `stageHeight = (342 - 600)/4 = -64.5`，`kit.rect` 收到负 `height`（SVG 中负宽高为错误值，元素不渲染）；`width=200` 时 `maxWidth = 200 - 24 - 24 - 120 = 32`，`width=150` 时直接为负，阶段条反向
- **描述**：`gap` 只校验 `< 0`，没有 `gap * (n-1) < 可用高度` 的约束；`maxWidth` 也未校验 `> 0`。后果是图元静默消失或反向绘制，而不是明确报错
- **建议**：校验 `stageHeight > 0`（否则抛 `InvalidValue`，路径 `gap`），并对 `maxWidth <= 0` 抛 `InvalidValue`（路径 `width`）；测试补 `gap` 过大与画布过窄两个用例

### [一般][存量] 甘特图任务 id 重复时静默覆盖

- **位置**：`f_chart/src/GanttChart.cj:63-66`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失，重复键静默覆盖）
- **证据**：静态确定 —— `taskIndex[tasks[index].id] = index` 直接赋值，无 `contains` 检查；对照 `Flowchart.cj:92-97` 对重复节点 id 抛 `InvalidValue`，同类输入两种处理
- **描述**：两条任务共用同一 `id` 时后者覆盖前者，`dependsOn` 指向该 id 时只会连到后一条，前一条既拿不到依赖也收不到依赖，且没有任何报错；`add-f-chart-gantt/proposal.md:12` 只约定了「`dependsOn` 指向不存在的任务 id 时抛 `InvalidValue`」，未覆盖重复 id
- **建议**：构造 `taskIndex` 时检测重复并抛 `chartInvalidValue("tasks[i].id", "任务 id 重复")`，与流程图保持一致；补一条重复 id 用例

### [轻微][存量] 漏斗图 proposal 与 design/通用规格/实现三处矛盾（「梯形」「从大到小」均未实现）

- **位置**：`f_chart/doc/spec/add-f-chart-funnel/proposal.md:10`（「按值从大到小绘制梯形阶段」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部与实现不一致）；§14（承诺未实现）
- **证据**：静态确定 —— `design.md:5` 写「阶段从上到下按输入顺序排列」、`design.md:9-11` 写「矩形 class `funnel-stage`」，`specs/chart-rendering/spec.md:7` 只要求「宽度与数值成正比」，`f_chart/doc/chart-json-spec.md:1341` 也是「按数组顺序从上到下」；`FunnelChart.cj:110-117` 画的是输入顺序的 `rect`，无排序、无梯形
- **描述**：四份文档三种说法：proposal 说排序 + 梯形，design/通用规格/实现是输入顺序 + 矩形。照 proposal 写用例的调用方会得到「顺序相同、形状不同」的结果
- **建议**：以 `design.md` 为准修正 proposal（改为「按输入顺序绘制矩形阶段条」），或若确实需要梯形则改实现并在 spec 里加「梯形」要求；两者只能留一个

### [轻微][存量] 流程图 spec 场景「4 项节点 → 4 个 `class="node"`」与菱形 class 要求冲突

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/specs/chart-rendering/spec.md:11-12` 与 `:19-26`
- **来源**：存量
- **判据**：review-checklist §13（规格自相矛盾，场景不可验收）
- **证据**：静态确定 —— `Flowchart.cj:326` 对 `diamond` 输出 `class="node node-diamond"`，字面不含 `class="node"`；`Flowchart_test.cj:58` 因此只能断言「4 节点里 3 个 `class="node"` + 1 个 `node node-diamond`
- **描述**：同一条 spec 的「四个节点」场景与「节点形状」需求互斥：只要含菱形节点，场景断言就失效。写成验收用例时会误判失败
- **建议**：把场景改为「输出 4 个含 `node` class 的节点，其中菱形节点为 `node node-diamond`」，并在 spec 中明确 class 组合规则（`node` 恒有，形状 class 叠加）

### [轻微][存量] 森林图权重全为 0 时返回 8，违反 spec「权重为 0 MUST 返回 6」

- **位置**：`f_chart/src/ForestChart.cj:257-260`（`maxWeight <= 0.0` 先返回 8.0）
- **来源**：存量
- **判据**：review-checklist §13（MUST 未落实）
- **证据**：静态确定 —— `specs/chart-rendering/spec.md:25`「`forestMarkerSize` MUST 在权重为 0 时返回 6」；单条数据 `weight: 0`（或多条全 0）时 `maxWeight = 0`，函数在 `weight <= 0.0` 分支之前先命中 `maxWeight <= 0.0` 返回 8
- **描述**：唯一边界差异：显式给了 `weight: 0` 却按「无权重」显示 8px，与 spec 的 MUST 相反；`design.md:16` 的措辞（「无权重时 8；权重 0 时 6」）也没说明 `maxWeight = 0` 时算哪一种
- **建议**：把 `maxWeight <= 0.0` 的判断下移到 `weight <= 0.0` 之后，或在 spec 里补一句「全部权重为 0 时视为无权重」；补一条全零权重用例

### [轻微][存量] 死代码/未使用项 3 处

- **位置**：`f_chart/src/GainChart.cj:71-74`、`f_chart/src/Flowchart.cj:185`、`f_chart/src/FunnelChart.cj:19`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 无调用者的参数 / 未使用 import）
- **证据**：静态确定 —— ① `var span = rangeMax - rangeMin` 及其 `if` 修正后再无任何读取（`grep -n "span" GainChart.cj` 仅 71-73 三行）；② `parseEdges(root: ChartJson, nodes: Array<FlowNode>)` 函数体（186-205 行）从不引用 `nodes`，唯一调用点 `Flowchart.cj:89` 传了它；③ `FunnelChart.cj` 内无任何 `std.math` 符号（`sqrt/abs/round/pow/log/ceil/floor/minFloat/maxFloat` 均无命中）
- **描述**：`span` 是想给「零跨度」兜底但坐标计算改用 `rangeMin/rangeMax` 之后忘了删；`nodes` 参数是签名演进残留；`std.math.*` 是复制模板 import
- **建议**：删掉 `span` 三行、`parseEdges` 的 `nodes` 形参与调用点实参、`FunnelChart.cj` 的 `import std.math.*`

### [轻微][存量] `ChartTime.parseDays` 只校验 `day <= 31`，非法日期被静默归一化

- **位置**：`f_chart/src/ChartTime.cj:35-37`
- **来源**：存量
- **判据**：review-checklist §11（输入校验不严导致静默数据漂移）
- **证据**：静态确定 —— `2026-02-31` 通过 `month 1..12 / day 1..31` 检查，`daysFromCivil(2026, 2, 31)` 按 `doy` 公式会算出 3 月 3 日，不抛异常；`add-f-chart-gantt/design.md:5` 把日期解析完全托付给该函数
- **描述**：甘特图任务的起止日期写错（月份天数不匹配）时不会报错，而是被静默挪到相邻日期，`end <= start` 的校验也可能因此改变结论。另 `parseDays` 忽略时间部分，与文档「可带时间部分，忽略时间」（`ChartTime.cj:21`）一致，不算问题
- **建议**：按 `(year, month)` 校验当月天数（闰年 2 月 29），越界抛 `chartInvalidValue(path, "日期不存在")`；补 `2026-02-31`、`2024-02-29`、`2025-02-29` 三条用例

### [轻微][存量] 跨文件重复：`xLabelHeight` 计算块 3 处逐字重复，`ForestChart.position` 重写了比例尺归一化

- **位置**：`f_chart/src/ForestChart.cj:157-161`、`f_chart/src/GainChart.cj:118-122`、`f_chart/src/GanttChart.cj:99-103`；`f_chart/src/ForestChart.cj:221-227`
- **来源**：存量
- **判据**：review-checklist §2（换文件复制的同语义片段）
- **证据**：静态确定 —— 三处 `xLabelHeight` 均为 `if (labelRotate == 0.0) { fontSize + 12.0 } else { 48.0 }`，仅上下文不同；`ForestChart.position()` 的 `(value - min) / (max - min)` 与 `LinearScale.scale` 的归一化部分同义，只是输出 0–1
- **描述**：轴标签高度常量（12 / 48）散落在各图，改一处不会同步；`position` 与 `LinearScale` 两套归一化并存，是上一条「像素参数顺序颠倒」得以在森林图单独出现的原因之一
- **建议**：把 `xLabelHeight` 提为 `ChartAxis` 的方法或 `ChartFrame` 的静态计算；`ForestChart` 直接用两个 `LinearScale`（x 用对数变换后的值构造）替代自写 `position`

### [轻微][存量] 甘特图依赖箭头的 class 与 design 不一致（`dependency` vs `dependency-arrow`）

- **位置**：`f_chart/doc/spec/add-f-chart-gantt/design.md:16`；实现 `f_chart/src/GanttChart.cj:171`、`f_chart/src/GanttChart.cj:176`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（class / 选择器契约与文档不符）
- **证据**：静态确定 —— `design.md:16`「从依赖任务条的右端到当前任务条的左端画三段折线（水平-垂直-水平），末端画三角箭头；class `dependency`」，读作折线与箭头共用该 class；实现折线为 `className: "dependency"`（`:171`），箭头为 `className: "dependency-arrow"`（`:176`）。`add-f-chart-gantt/specs/chart-rendering/spec.md:25` 只约束折线的 `class="dependency"`，未约束箭头
- **描述**：按设计文档写样式或后处理（`querySelectorAll('.dependency')`）只能命中折线，箭头靠内联 `fill` 上色，主题替换、高亮、导出时箭头会被漏掉
- **建议**：`design.md:16` 补明「折线 `dependency`、箭头 `dependency-arrow`」；若要统一选择器，则箭头改为同一 class，并在样式中同时给 `stroke` 与 `fill`

### [轻微][存量] 流程图 spec 未记录 `horizontal` 布局、`rect`/`round` 形状与有环输入口径

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/specs/chart-rendering/spec.md:19-35`；实现 `f_chart/src/Flowchart.cj:252-260`（horizontal）、`Flowchart.cj:329-330`（round）、`Flowchart.cj:345-346`（默认 rect）、`Flowchart.cj:219-228`（层级松弛）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）+ §14.1（规格覆盖面不足）
- **证据**：静态确定 —— 同一 spec 的形状需求（`:19-21`）只列 `diamond`/`ellipse`/`parallelogram`/`document`，布局需求（`:30`）只列 `vertical`/`manual`；实现另有 `case "round"`、默认 `rect` 分支与 `layout == "horizontal"`，`f_chart/README.md:76` 也写「六种形状」，说明实现口径是 6 种形状 + 3 种布局。有环输入时 `levels` 在 n 轮松弛中最多增长到 O(n)（与严重 #2 同源），spec 对环未作任何约定
- **描述**：按 spec 写验收只能覆盖一半形状与竖向布局，横向布局与圆角矩形属「文档外能力」；回退边（如「驳回 → 重新提交」）是流程图常见结构，规格既不说支持也不说拒绝，实现既不报错也不保证落在画布内
- **建议**：spec 补全 6 种形状与三种 `layout`；对环明确口径，建议在层级松弛前做 DFS 环检测并抛 `InvalidValue`，与严重 #2 的「层号上限」一起修

## 优化可行性方案

### [堆内存] 增益图每个数据点一个 2 元素 `Array<Float64>`

- **现状**：`GainChart.cj:48-61` 先把每点存成 `Array<Float64>`（`[x, y]`，2 元素堆对象 + 外层 `ArrayList`），再经 `sortLiftPoints` 复制一份 `ArrayList` 后 `toArray()`；n 个点约 2n 个小数组 + 2 个指针数组常驻到绘制结束
- **方案**：改用 `struct GainPoint { let x: Float64; let y: Float64 }`（值类型，`Array<GainPoint>` 一次分配），排序后不再复制
- **预期**：n=10⁴ 时少约 2×10⁴ 次小对象分配与约 1.6×10⁵ 字节头开销（按 8 字节头 + 2×8 字节载荷粗算），峰值分配量随 n 线性下降；对 SVG 字符串长度无影响
- **代价**：`sortLiftPoints` 为 `LiftChart` 共享函数，需保留旧重载或同步改 `LiftChart`；改动后 `GainChart` 与 `LiftChart` 的数据结构要一致演进
- **验证**：同输入（1k / 1万 / 10万点）跑 `cjpm bench -O2` 对照 `getAllocatedHeapSize()` 与 RSS，中位数取 5 轮
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sortLiftPoints` 用插入排序处理增益/提升曲线

- **现状**：`f_chart/src/LiftChart.cj:203-218` 为插入排序，最坏 O(n²)；`GainChart.cj:61` 每次绘制都调用一次，输入是调用方给的完整点集
- **方案**：换成标准库排序（按 `x` 升序），保留「相等 `x` 保持原顺序」的稳定语义
- **预期**：n=10⁴ 且逆序输入时比较次数从约 5×10⁷ 降到约 1.3×10⁵；端到端收益取决于排序在总耗时中的占比（未测）
- **代价**：需确认 std 排序为稳定排序，否则同 `x` 的点绘制顺序会变（影响折线形状）
- **验证**：`cjpm bench -O2`，输入 1k/1万/10万、正序/逆序/随机三种分布，对照 `GainChart.draw` 总耗时与 `sortLiftPoints` 分段计时
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 增益/提升图的排序是绘制耗时主项（n ≥ 1万、逆序输入时） | `f_chart/src/LiftChart.cj:203-218` | `sortLiftPoints` 自耗时占比 | `cjprof record` 跑 `GainChart.draw`，输入 1万/10万点，看 self time |
| 2 | 流程图分层松弛 O(节点数 × 边数) 在大图上成为瓶颈 | `f_chart/src/Flowchart.cj:219-228` | 节点/边规模与自耗时占比 | 构造 500 节点/1000 边与 5000 节点/10000 边两组输入，分段计时 `layoutNodes` |
| 3 | SVG 字符串拼接在大点数时主导增益图耗时与分配 | `f_chart/src/GainChart.cj:154-171` | `StringBuilder` 增长次数与单次绘制耗时 | 同上输入下对比「只解析 + 只排序 + 只拼接」三段计时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-flowchart/specs/chart-rendering/spec.md` | .md | ✅ | 与实现基本一致；场景断言问题见轻微 #2，规格未覆盖 `horizontal`/`rect`/`round`/有环输入见轻微 #8 |
| 2 | `f_chart/doc/spec/add-f-chart-flowchart/tasks.md` | .md | ✅ | 5 项全部 `[x]`，所列 `ChartSvgKit.ellipse` 已落地（`ChartSvgKit.cj:139-164`） |
| 3 | `f_chart/doc/spec/add-f-chart-forest/design.md` | .md | ✅ | 与实现逐条对上；`yAxis.labels` 与 `design.md:11` 说法冲突（见一般 #1） |
| 4 | `f_chart/doc/spec/add-f-chart-forest/proposal.md` | .md | ✅ | 新增类/内部函数均已存在 |
| 5 | `f_chart/doc/spec/add-f-chart-forest/specs/chart-rendering/spec.md` | .md | ✅ | 权重 0 边界未落实（轻微 #3）；轴方向问题见严重 #1 |
| 6 | `f_chart/doc/spec/add-f-chart-forest/tasks.md` | .md | ✅ | 全部 `[x]`，与 `ForestChart.cj` 一一对应 |
| 7 | `f_chart/doc/spec/add-f-chart-funnel-alias/design.md` | .md | ✅ | 别名关系成立：无独立实现，`ChartGallery_test.cj:2093` 复用 `FunnelChart` |
| 8 | `f_chart/doc/spec/add-f-chart-funnel-alias/proposal.md` | .md | ✅ | 仅新增测试，与 `FunnelAlias_test.cj` 一致 |
| 9 | `f_chart/doc/spec/add-f-chart-funnel-alias/specs/chart-rendering/spec.md` | .md | ✅ | 场景计数与 `FunnelAlias_test.cj:63-72` 一致 |
| 10 | `f_chart/doc/spec/add-f-chart-funnel-alias/tasks.md` | .md | ✅ | 2 项 `[x]` |
| 11 | `f_chart/doc/spec/add-f-chart-funnel/design.md` | .md | ✅ | 与实现一致（输入顺序 + 矩形），但与 proposal 矛盾（轻微 #1） |
| 12 | `f_chart/doc/spec/add-f-chart-funnel/proposal.md` | .md | ✅ | 「梯形」「从大到小」未实现（轻微 #1） |
| 13 | `f_chart/doc/spec/add-f-chart-funnel/specs/chart-rendering/spec.md` | .md | ✅ | 阶段/转化率/标签计数均已实现并有测试；`gap` 边界缺失（一般 #4） |
| 14 | `f_chart/doc/spec/add-f-chart-funnel/tasks.md` | .md | ✅ | 全部 `[x]` |
| 15 | `f_chart/doc/spec/add-f-chart-gain/design.md` | .md | ✅ | 轴范围/对角线/校验与实现对得上；对角线方向见严重 #1 |
| 16 | `f_chart/doc/spec/add-f-chart-gain/proposal.md` | .md | ✅ | 三个 class 均已输出 |
| 17 | `f_chart/doc/spec/add-f-chart-gain/specs/chart-rendering/spec.md` | .md | ✅ | `gain-line` 升序、`gain-point`、轴范围均已实现；方向问题见严重 #1 |
| 18 | `f_chart/doc/spec/add-f-chart-gain/tasks.md` | .md | ✅ | 全部 `[x]` |
| 19 | `f_chart/doc/spec/add-f-chart-gantt/design.md` | .md | ✅ | `lane` 未实现（一般 #2）；依赖箭头 class 见轻微 #7；其余布局公式与 `GanttChart.cj` 逐条一致 |
| 20 | `f_chart/doc/spec/add-f-chart-gantt/proposal.md` | .md | ✅ | `lane` 未实现（一般 #2）、`dependsOn` 校验已实现；重复 id 未覆盖（一般 #5） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 正确性：严重 #1/#2（坐标方向、布局越界）、一般 #4（负尺寸）；可读性：轻微 #6（重复常量）；安全性：仅处理 JSON 数值与字符串，无注入面、无凭据，0 命中 |
| §1 死代码 | 3 | 逐个核对本部分涉及的 5 个类与其私有成员：`FlowNode/FlowEdge/ForestRow/GanttTask` 全部字段有读取点，`parseNodes/parseEdges/layoutNodes/drawEdge/drawNode/parseTasks/position/forestLogTicks/forestMarkerSize` 均有调用者；命中的是 `GainChart` 死变量、`parseEdges` 死参数、`FunnelChart` 未用 import（轻微 #4）。`public` 类 `Flowchart/ForestChart/FunnelChart/GainChart/GanttChart` 对外可达，不判 |
| §2 重复逻辑 | 1 | 已把 5 个 `draw` 主体压成「输入 → 输出 → 副作用」比对：结构相似但字段与 class 名不同（业务差异），不合并；真正的同语义重复是 `xLabelHeight` 块 ×3 与 `position` 对 `LinearScale` 的重写（轻微 #6）。`GainChart` 复用 `sortLiftPoints`/`volcanoNumber` 属于合理复用 |
| §3 空实现 | 0 | 5 个 `draw` 均有完整实现；`Flowchart.cj:203` 的 `case None => ()` 对应「edges 可选」，`ChartSvgKit` 的 `match` 空分支均为可选参数分支，均非吞异常；无 `TODO` / `UnsupportedException` |
| §4 栈溢出 | 0 | 无递归：`layoutNodes` 用 n 轮松弛而非 DFS，`sortLiftPoints` 为迭代插入排序，`ChartTime` 为纯算术；环检测缺失只影响坐标（已并入严重 #2），不产生栈增长 |
| §5 OOM | 0 | 无全局可变容器（仅 `CHART_DEFAULT_PALETTE` 常量）；单次 `draw` 的分配量与输入条数线性，`chartNiceTicks` 有 `guard < 1000`；无按报文长度预分配。缺少点数上限属产品取舍，列入优化与假设，不定为缺陷 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，未把「排序 O(n²)」「分层松弛 O(V·E)」写成结论，仅进「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分实现无锁、无临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无队列 |
| §6.4 低效算法 | 1 | 线索命中 2 处（插入排序、分层松弛），因无测量数据只作「待验证假设」，不计入发现；`forestLogTicks` 指数循环有上下界，不构成低效 |
| §7 降堆内存方案 | 1 | 增益图每点小数组（见优化方案第一节）；森林图 `rows` 为必要中间结构，无多余副本 |
| §8 降 CPU 方案 | 1 | 排序改标准库（见优化方案第二节）；其余无基线 |
| §9 local mode 可行性 | 0 | 本部分实现产出的是逃逸的 SVG `String`，中间对象（`ArrayList`/点数组）生命周期与返回值同长，`local` 无法覆盖；且需 `--experimental`，收益无法用峰值内存证明，不列为可行 |
| §11 现有代码的 BUG（存量） | 7 | 逐条核对了 5 个 `draw` 的空集合、除零、越界与重复键：`series` 空/多系列（已校验）、`data` 空（已校验）、`xMax<=xMin`（已校验）、`rowHeight` 除零（rows 非空已保证）、`tasks` 空（已校验）；命中的是严重 #1/#2、一般 #1-#5（另见轻微 #3 权重边界、#5 日期校验） |
| §12 并发安全与锁粒度 | 0 | 5 个图表类只有 `init() {}` 与 `draw`，无成员状态，`draw` 只读入参并返回新字符串，天然线程封闭；`LinearScale`/`ChartFrame` 为每次调用新建的局部对象 |
| §13 文档一致性 | 6 | 逐条核对 spec/design/proposal 引用的符号与行为：`ChartSvgKit.ellipse`、`ChartTime.parseDays/formatDays`、`chartNiceTicks`、`ChartFrame.drawXAxisNumeric`、`LinearScale`、`forestLogPosition/forestLogTicks/forestMarkerSize`、`funnelConversion` 全部存在且签名一致；命中的是严重 #1（对角线方向）、轻微 #1（proposal 自相矛盾）、轻微 #2（场景与 class 冲突）、轻微 #3（权重 0 的 MUST）、轻微 #7（依赖箭头 class）、轻微 #8（流程图规格未覆盖 horizontal/rect/round/有环） |
| §14 功能完备性与 README 覆盖 | 3 | `lane` 未实现（一般 #2）、`yAxis.labels` 只校验不生效（一般 #1）、流程图规格覆盖面不足（轻微 #8），均给了「承诺源 + 缺失证据」双证；README 覆盖属模块其他部分，本部分不重复判定 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_chart.part10.txt` 行数一致，无遗漏 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 15 条（本部分全部为存量，快照模式无基线），是否纳入修复待用户决定。范围外提示：`f_chart/doc/chart-json-spec.md:1982` 声明增益图有专属字段 `baseline`（对角线开关），实现 `GainChart.cj` 无任何读取点；另 `LinearScale` 像素参数顺序颠倒的写法在 `BlandAltmanChart` / `CalibrationChart` / `EcdfChart` / `InfluenceChart` / `LassoPathChart` / `LearningCurveChart` / `LiftChart` / `ManhattanChart` / `PdpChart` / `PrChart` / `ResidualChart` / `RocChart` / `SurvivalChart` / `VolcanoChart` 中同样存在，建议按同一根因合并处理。

## 总评

这 6 份变更文档的完成度不低：每条 spec 要求都能在实现里找到落点，`tasks.md` 的 `[x]` 与代码一一对应，校验路径（缺失字段、类型不符、区间倒置、负数、悬空边/依赖）也基本齐备，命名与 class 约定前后一致。主要风险集中在**坐标与布局**而不是文档措辞：森林图与增益图的比例尺像素参数与 `LinearScale` 契约相反，导致轴方向反转（增益图整体 180° 旋转，有已提交 SVG 佐证）；流程图自动布局用固定层距，库自带的 6 节点示例就有 3 个节点落在画布外。这两条属于必须修的输出错误，且现有测试只统计 class 次数、没有任何坐标断言，是它们长期存活的直接原因——建议修复时同步补坐标断言，否则同类回归还会复发。文档侧的问题（`lane` 承诺未实现、`yAxis.labels` 空转、漏斗图 proposal 的「梯形/排序」、权重 0 的边界 MUST、依赖箭头 class、流程图规格漏记布局与形状）属口径不统一，排期修正即可；性能方面本部分没有可复核的测量数据，排序复杂度与分层松弛只作为下一轮补数据的假设，不作为结论。
