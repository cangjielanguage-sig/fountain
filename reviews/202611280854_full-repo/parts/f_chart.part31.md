# f_chart 模块审查报告（模块第 31/37 部分）

> **模块第 31/37 部分**（分报告）。本部分覆盖 `f_chart/src` 的 20 个文件（10 张图 + 10 个测试）：
> Lift/Line/Lollipop/Manhattan/Mosaic/NetworkHeatmap/NodeLink/Nomogram/OfflineFlame/Org/PairedLine。
> 同模块其余文件见 `parts/f_chart.part{1..30,32..37}.md`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（模块合计 251 个 `.cj` / 444 个 `.md`；**本部分** 20 个 `.cj` / 0 个 `.md`）
- **本部分范围**：`f_chart/src/{LiftChart_test, LineChart, LineChart_test, LollipopChart, LollipopChart_test, ManhattanChart, ManhattanChart_test, MosaicChart, MosaicChart_test, NetworkHeatmapChart, NetworkHeatmapChart_test, NodeLinkChart, NodeLinkChart_test, NomogramChart, NomogramChart_test, OfflineFlameChart, OfflineFlameChart_test, OrgChart, OrgChart_test, PairedLineChart}.cj`（4551 行）
- **基线**：工作区快照（`f_chart/src` 无改动，`git status` 仅列出未跟踪的 `docs/review/`、`reviews/`），**所有问题来源均为「存量」**
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **取证材料**：`f_chart/doc/chart-json-spec.md`（当前规格，含 §7 校验规则与容错默认）、`f_chart/doc/spec/add-f-chart-*/specs/chart-rendering/spec.md`（各图变更规格，仅作意图旁证）、支撑代码 `ChartConfig.cj` / `ChartFrame.cj` / `ChartScale.cj` / `ChartSvgKit.cj` / `ChartJson.cj` / `ChartTheme.cj`（只作对照，不占本部分统计）
- **报告版本**：v1（分报告；不写 `docs/review/` 下的模块报告）

## 发现

### [一般][存量] `MosaicChart` 绕开 `ChartFrame` 自绘标题与图例，`legend.show` / `legend.position` / `markerSize` / `itemGap`、`title.subtext` / `title.align` 全部失效（图例关不掉）

- **位置**：`f_chart/src/MosaicChart.cj:120-129`（标题）、`:138-152`（图例）；对照 `f_chart/src/ChartFrame.cj:98-132`（`drawTitle`）、`:134-166`（`drawLegend`）
- **来源**：存量（本部分全部文件在快照内无 diff）
- **判据**：review-checklist §2「跨层复制 / 换控制流导致的行为漂移」+ §13「配置与实现不符」
- **证据**：静态确定 —— ①`MosaicChart.draw` 全文没有 `legendVisible` 变量，图例循环 `for (index in 0..series.size)` 无条件执行，只读 `config.theme.colorAt` 与硬编码的 `10.0` / `14.0` / `18.0`；②`config.legend.show`、`position`、`markerSize`、`itemGap` 在文件内零命中（本部分其余 9 张图都经 `ChartFrame` 出标题，其中 `LineChart:159`、`LollipopChart:149`、`ManhattanChart:160`、`NetworkHeatmapChart:149`、`PairedLineChart:125` 还按 `legend.show` 计算了 `legendVisible`）；③标题只读 `config.title`，`title.subtext` / `title.align` 零命中，且基线取 `padding.top + titleFontSize`，与 `ChartFrame.cj:114` 的 `padding.top + titleFontSize / 2.0` 相差半个字号
- **描述**：`doc/chart-json-spec.md:31`、`:67-75` 把 `legend` 定位为通用字段（`show` 默认 true、"是否显示"），`ChartFrame` 是其余 9 张图的统一实现。马赛克图自己写了一份，于是 `"legend": {"show": false}` 画出来仍有图例、`position: "bottom"` 仍在顶部、`markerSize` / `itemGap` 改动无效、副标题直接丢失。这类"配置静默失效"比报错更难排查：用户会以为参数位置写错了
- **建议**：改用 `ChartFrame`：`let legendVisible = config.legend.show && !(series.isEmpty())`（或在单系列无名时隐藏），`frame.drawBackground/drawTitle/drawLegend` 三步替换 120-152 行；标题的 `top` 预留改为 `ChartFrame` 的 `plot.y` 计算（`MosaicChart.cj:133` 的 `padding.top + 64.0` 也一并交给 frame）。回归用例补 `legend.show=false` 断言 `count(svg, "legend-item") == 0`

### [一般][存量] `NetworkHeatmapChart` 的 `cellGap` 只校验下界，`cellGap ≥ 单元格边长` 时生成负宽矩形，整格静默消失

- **位置**：`f_chart/src/NetworkHeatmapChart.cj:144-147`（仅 `cellGap < 0.0` 抛错）、`:186-192`（`cellWidth - cellGap` / `cellHeight - cellGap` 直接作为 `kit.rect` 的宽高）
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 缺少边界校验」、§5「无拒绝路径」
- **证据**：静态确定 —— `order` 由 `nodes` 数量决定（`:63`），`cellWidth = frame.plot.width / Float64(order)`（`:160`）；`cellGap` 无上界，`kit.rect(x, y, cellWidth - cellGap, ...)` 在 `cellGap > cellWidth` 时为负值。SVG 1.1 规定 `width`/`height` 负值为错误值，元素不被渲染
- **描述**：`nodes` 20 个（默认 800×480 画布、`plot.width ≈ 700`）时 `cellWidth ≈ 35`，用户给 `cellGap: 40` 想"格子之间留白多一点"，得到的是 400 个负宽 rect：整张图只剩轴与标签，无任何异常提示。`showValues` 的文本定位 `x + (cellWidth - cellGap) / 2.0`（`:195`）同时变成负偏移，数值文字也跟着错位
- **建议**：校验 `cellGap < min(cellWidth, cellHeight)`，越界抛 `chartInvalidValue("cellGap", "单元格间隙必须小于单元格边长 ${min}")`；或把间隙按比例解释（`cellGap` 视为占比 0..1）并夹到 `[0, 0.9]`。注意 `cellWidth` 依赖 `frame.plot`，校验必须放在 `ChartFrame` 构造之后

### [一般][存量] `LineChart` / `LollipopChart` 不校验 `series[].color`，非法颜色直出 `fill` 属性

- **位置**：`f_chart/src/LineChart.cj:115`（`json.string("color")` 后直接进 `drawSeries` → `kit.path(..., stroke: color)`）、`f_chart/src/LollipopChart.cj:82`（同上 → `:198-202` 的 `kit.line` / `kit.circle`）
- **来源**：存量
- **判据**：review-checklist §13「API / 配置与源码不符」+ `doc/chart-json-spec.md:2713`（"颜色字符串无法解析 → `InvalidValue`，`path` 例 `series[0].color`"）
- **证据**：静态确定 —— 两处只做 `json.string("color")`，文件内 `SvgColor` 零命中；同模块 `NetworkHeatmapChart.cj:133-142` 对 `colorRange` 是逐个 `SvgColor.tryParse` 并抛 `InvalidValue` 的，说明校验能力现成、只是这两张图没接。属性转义由 `SvgWriter` 负责（`f_svg/src/SvgAuthoringBuilder.cj:255-259` 注释），因此**不构成注入**，但 `fill="chartreuse2"` 这类拼写错误会原样进入 SVG 并被渲染器忽略，系列退化成黑色
- **描述**：规格把颜色校验列为通用规则，10 张图里只有网络热力图执行；调用方拿到的是"图能出来、颜色不对"的结果，与"非法输入必须抛 `InvalidValue`"的契约相反
- **建议**：在 `ChartJson` 增加 `color(name: String): ?String`（内部 `SvgColor.tryParse`，失败抛 `chartInvalidValue(pathOf(name), "非法颜色 ${text}")`），`LineChart:115`、`LollipopChart:82` 改用它；`theme.palette` 的解析（`ChartTheme.cj:39-42`）可复用同一入口

### [一般][存量] `OrgChart` 没有真正的环检测：存在合法根时，环内节点被静默混入布局（叠在同一槽位）并画出互指连线

- **位置**：`f_chart/src/OrgChart.cj:108-122`（只用"根数量 == 1"间接兜底）、`:125`（`orgLayout`）、`:152-202`（绘制）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失 / 静默失效」；意图源：`f_chart/src/OrgChart_test.cj:197-215`（`rejectsCycle`）+ `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md`（"`parent` 指向存在的节点且不存在环"）
- **证据**：静态确定 —— 自环/双节点环在**没有其它根**时确实会抛错，但抛的是 `:120-122` 的"必须恰好有一个根节点"（环内节点都有父节点，`roots` 为空，走 `roots.size != 1` 分支）。若输入为 `[{id:"r",parent:null},{id:"a",parent:"b"},{id:"b",parent:"a"}]`：`a`、`b` 各自挂到对方 `children`（`:113`），`roots` 只有一个 `r`，校验通过；`orgAssignDepth/orgAssignSlots` 从 `r` 出发（`:250-252`）只访问 `r`，`a`/`b` 的 `depth`/`slot` 保持初值 0（`:28-29`），最终三者画在同一坐标，并输出两条 `org-link` 互指
- **描述**：契约要求"不存在环"必须报错，实现只在"没有根"这一种形态下偶然报错，错误文案还指向根数量而非环，排查成本高；其余形态产出重叠节点，属于静默数据错误。现有用例 `rejectsCycle` 恰好只覆盖了无根形态，因此测试是绿的
- **建议**：在 `:108-122` 之后加一次可达性校验：从 `roots[0]` 走一遍并计数，`visited != nodes.size` 时抛 `chartInvalidValue("nodes", "节点关系存在环或存在不可达节点")`；或沿用 `OfflineFlameChart` 的深度上界思路（但需注意那份实现本身不可达，见下条）。补用例：`root + 双节点环` 应抛 `InvalidValue`

### [一般][存量] `LollipopChart` 在显式 `yAxis.min > 0` 时把茎线的 0 基线画到绘图区之外

- **位置**：`f_chart/src/LollipopChart.cj:124-138`（`yMin` 取显式值）、`:187`（`baseline = yScale.scale(0.0)`）、`:193-202`（从 `baseline` 画到 `y`）
- **来源**：存量
- **判据**：review-checklist §11「边界 / 坐标越界」、§10「正确性」；规格侧张力见 `f_chart/doc/spec/add-f-chart-lollipop/specs/chart-rendering/spec.md`（"茎从 0 基线到该值" 与 "`yAxis.min` 给出时 MUST 按给定值" 互斥）
- **证据**：静态确定 —— `LinearScale.scale` 为 `bottomPixel - (value - min)/span * (bottomPixel - topPixel)`（`ChartScale.cj:41`），`min > 0` 时 `scale(0) > bottomPixel`。取 `yAxis.min: 2`、数据 `[4.2, 3.6]`：`dataMin` 从 0 起算（`:112-113`）故 `yMax=4.2`、`yMin=2`，`(0-2)/2.2 = -0.909`，`scale(0)` 落在 `plot.bottom()` 下方约 `0.91 × plot.height` 处，茎线整根从绘图区外穿入
- **描述**：茎的起点溢出 x 轴下方，压到刻度标签与轴标题区域（`frame.drawXAxis` 在 `plot.bottom()+6` 起画标签），画布边缘还会被裁掉一截，视觉上像"数据从空气中长出来"。默认（不给 min）时 `dataMin` 从 0 起算（`:112-113`），所以正常路径不受影响，属边界配置触发
- **建议**：`baseline` 改为 `yScale.scale(clamp(0.0, yMin, yMax))`，即 `if (yMin > 0.0) frame.plot.bottom() else if (yMax < 0.0) frame.plot.y else yScale.scale(0.0)`；或在 `:124-131` 直接校验 `yAxis.min <= 0 <= yAxis.max`（与"纵轴范围 MUST 包含 0"一致）后抛 `InvalidValue`。二选一需在 `doc/chart-json-spec.md` 的 M79 小节写明

### [一般][存量] 刻度不做范围裁剪：显式 `axis.values`（以及 `chartNiceTicks` 的 floor/ceil 扩展）落在轴域外时，刻度线/网格/标签画到绘图区外

- **位置**：`f_chart/src/LineChart.cj:137-141` + `:151-155`、`f_chart/src/LollipopChart.cj:139-143`、`f_chart/src/ManhattanChart.cj:134-143`、`f_chart/src/PairedLineChart.cj:106-110`（四张图均把 `config.*Axis.values` 原样交给 `frame.drawYAxis` / `drawXAxisNumeric`，无过滤）
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 越界」、§10「正确性」
- **证据**：静态确定 —— `ChartFrame.drawYAxis`（`ChartFrame.cj:168-202`）对每个 tick 直接 `scale.scale(tick)` 后画 `line` 与 `text`，无 `min/max` 过滤；`chartNiceTicks`（`ChartScale.cj:94-95`）用 `floor(min/step)*step` / `ceil(max/step)*step` 扩展首末刻度，返回值本身就可能越出 `[min,max]`。`yAxis.values` 是 `doc/chart-json-spec.md` 2.4 小节（`xAxis` / `yAxis`）记载的通用字段，四张图都无"必须落在轴域内"的校验
- **描述**：`yAxis: {"values": [0, 50, 100]}` 配数据 1..2（轴域约 0.95..2.05）时，`0`、`50`、`100` 三个刻度的网格线与标签分别画在 `plot` 下方、下方更远处与上方，坐标出现负值或超出画布，SVG 本身合法但视觉上是"轴外的孤立数字"。同源问题在 `chartNiceTicks` 侧（`ChartScale.cj`，属其它部分）已由 part2 的「范围外提示」记录，本部分记的是**四张图都缺裁剪/校验**
- **建议**：抽一个 `chartClipTicks(ticks, min, max)`（或给 `ChartFrame` 加 `range` 参数），过滤 `min - eps <= t <= max + eps` 的刻度；对显式 `values` 越界抛 `chartInvalidValue("yAxis.values[i]", "刻度必须落在轴范围内")`。两条路径的取舍需在 `doc/chart-json-spec.md` 写明

### [轻微][存量] `OfflineFlameChart` 的两处"环检测"不可达（死代码），而真正的环仍被静默丢弃

- **位置**：`f_chart/src/OfflineFlameChart.cj:177-179`（`validateValues` 的 `depth > total`）、`:193-195`（`assignDepth` 的同款判断）
- **来源**：存量
- **判据**：review-checklist §1「恒假分支 / 不可达语句」、§3「错误被静默吞掉」
- **证据**：静态确定 —— 每个节点只有一个 `parentId`（`:77-87`），`:96-106` 把它挂进唯一父节点的 `children`，因此结构必然是有向森林；`validateValues/assignDepth` 都只从 `roots[0]`（`:110`）/`selected`（`:121`）出发，沿 `children` 下行，**单亲森林从根出发不可能回到已访问节点**，`depth` 严格等于路径深度且 ≤ 节点数，`depth > total` 恒假。旁证：`OrgChart.cj:218-238` 的同构递归完全没有这层判断
- **描述**：两段"节点关系存在环"的异常实际永不抛出；而 `[{id:"r",parent:null},{id:"a",parent:"b"},{id:"b",parent:"a"}]` 这类输入会通过 `:107-109` 的单根校验，`a`/`b` 既不报错也不绘制。规格只要求"恰好一个树根"，所以行为不算违约，但代码里两处"环检测"会误导后续维护者以为已覆盖
- **建议**：删除两处 `depth/total` 参数（连同 `total` 形参），改为在 `:107-109` 之后用"可达计数 == `parsed.size`"一次性判定环/不可达并抛 `chartInvalidValue("nodes", ...)`；或在注释里写明"单亲森林无环，环只会表现为不可达节点，故此处不做深度保护"

### [轻微][存量] 重复逻辑：图例名称/颜色数组在两处逐行同构构建

- **位置**：`f_chart/src/LineChart.cj:190-199` 与 `f_chart/src/LollipopChart.cj:175-184`
- **来源**：存量
- **判据**：review-checklist §2「同语义、不同文件复制」
- **证据**：静态确定 —— 两段都是 `names.add(series[i].name)` + `colors.add(match (color) { Some(c) => c; None => theme.colorAt(i) })` + `names.toArray()/colors.toArray()`，差异只有列表变量名（`series` 元素类型分别为 `LineSeries` / `LollipopSeries`）
- **描述**：同一"系列名 + 解析后颜色"的推导写了两遍，颜色解析规则（显式优先、否则 `colorAt(index)`）一旦变化（例如加调色板越界告警）要改两处
- **建议**：在 `ChartTheme` 或 `ChartFrame` 上提供 `resolveColors(count, colors: Array<?String>): Array<String>`，两张图各传一次 `Option` 数组；不建议上泛型，参数用 `Array<?String>` 即可

### [轻微][存量] 重复逻辑：染色体"首次出现顺序"去重在一个文件里写了两遍，且 `draw` 侧再按顺序线性回查 → O(n·c)

- **位置**：`f_chart/src/ManhattanChart.cj:205-210`（`chromosomeOrder` 构建）与 `:243-248`（`manhattanPositions` 内 `order` 构建）；回查在 `:211-213` + `:228-235`
- **来源**：存量
- **判据**：review-checklist §2「同文件两两比对」、§6.4「热点 `contains` / 线性查找」
- **证据**：静态确定 —— 两段循环体完全一致（`if (!order.contains(chromosome)) { order.add(chromosome) }`）；`chromosomeIndexOf` 对每个点再线性扫一遍 `order`，`order.contains` 也是线性，整体 `O(n·c)`（c = 染色体数，人类 24 + 性染色体，量级固定，故只记为轻微）
- **描述**：`manhattanPositions` 内部已经算出了分组顺序却不返回，调用方只能重建一遍再做反查；`chromosomeIndexOf` 未命中时返回 `0`（`:234`）而不是报错，把"顺序表与点集不同步"的编码错误伪装成"第 0 号染色体颜色"
- **建议**：让 `manhattanPositions` 返回 `(positions, order)`（或加一个 `ManhattanLayout` 小结构），`draw` 直接用返回的 `order`；反查改成一次性建 `HashMap<String, Int64>`，把 `chromosomeIndexOf` 的兜底改成 `-1` 并在调用处断言

### [轻微][存量] 重复逻辑：节点 id 唯一性与 id→节点查找在 4 个文件里各写一份，均为 O(n²)

- **位置**：去重循环 `f_chart/src/NetworkHeatmapChart.cj:55-59`、`f_chart/src/NodeLinkChart.cj:88-92`、`f_chart/src/OfflineFlameChart.cj:71-75`、`f_chart/src/OrgChart.cj:88-92`；查找函数 `NodeLinkChart.cj:184-191`（返回 `Int64`，未命中 `-1`）、`OfflineFlameChart.cj:167-174`（返回 `?Node`）、`OrgChart.cj:208-215`（返回 `Option<OrgNode>`）、`ManhattanChart.cj:228-235`（同型，见上条）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名的复制 / 复制导致语义漂移」（四段去重同构，三份查找的未命中语义分别是 `-1` / `None` / `None`）
- **证据**：静态确定 —— 四段去重循环逐行同构（`for (existing in nodes) { if (existing.id == id) throw chartInvalidValue(..., "节点 id 重复") }`），三份 `findNode` 除返回类型外一致；`NodeLinkChart` 还在 `:122-127`、`:158-159`、`:243-244` 重复调用 `findNode`（力导向里每轮每条边两次）
- **描述**：同一份"id 唯一 + id 索引"的契约复制了 4 次，错误文案一致但未命中语义不一致，调用方（`NodeLinkChart.cj:158`）拿 `-1` 直接做下标，一旦上游校验被改动就是越界崩溃；同时 4 处都是线性扫描（性能面见「优化可行性方案」）
- **建议**：在 `ChartJson`（或新增 `ChartNodes` 工具）提供 `buildIndex(nodes)` 返回 `HashMap<String, Int64>`，去重与查找都走它，未命中统一抛 `chartInvalidValue`；四个图改为"建索引一次 + 取值"

### [轻微][存量] 重复逻辑：三个小工具分别重写了 `chartTextWidth`、`maxFloat`、`jsonNumberValue` 的语义

- **位置**：`f_chart/src/OrgChart.cj:266-286`（`orgFitLabel` 内的字宽模型）、`f_chart/src/NomogramChart.cj:236-238`（`maxNameWidthOf`，实为 `maxFloat`）；数值读取侧 `NomogramChart.cj:96-99`（`jsonNumberValue`）、`ManhattanChart.cj:77-78`（`volcanoNumber`，`VolcanoChart.cj:228-234`）、`PairedLineChart.cj:79-80`（`bulletNumber`，`BulletChart.cj:233-243`）
- **来源**：存量
- **判据**：review-checklist §2「换算复制 / 字面量复制」
- **证据**：静态确定 —— `orgFitLabel:274-278` 的 `rune.position() >= 0x2E80 ? fontSize : fontSize * 0.56` 与 `ChartScale.cj:113-123` 的 `chartTextWidth` 逐字相同；`maxNameWidthOf` 与 `std.math.maxFloat` 语义相同（`NomogramChart` 未导入 `std.math`，因此自写了一份）；`volcanoNumber` 的"kind 检查 + jsonNumberValue"与 `jsonNumberValue`（`ChartJson.cj:215-227`，内含同样的 kind 检查）重复，`bulletNumber` 是它再加一次非负判断
- **描述**：字宽模型有两份实现，改 CJK 阈值时极易只改一处，导致"边距按新模型算、截断按旧模型算"，标签越界；数值读取三份实现里，`volcanoNumber` 的类型预检是纯冗余（`jsonNumberValue` 已经抛同样的 `InvalidValue`），而 `bulletNumber` 多出的非负约束被 `PairedLineChart` 继承（其 delta 规格确实要求非负，属隐式耦合：子弹图的规则泄漏到配对图）
- **建议**：`orgFitLabel` 用 `chartTextWidth` 做累加与判定（或抽出 `chartFitLabel(text, maxWidth, fontSize)` 放 `ChartScale.cj`，`DecisionTree/Swimlane/Timeline` 三处调用点一并受益，属其它部分）；`maxNameWidthOf` 删掉改用 `maxFloat` 并补 `import std.math.*`；`volcanoNumber` 收敛为 `jsonNumberValue(json.required(field), ...)`；`bulletNumber` 改名 `nonNegativeNumber` 并移到 `ChartJson` 附近，避免"配对图依赖子弹图"

### [轻微][存量] 校验口径与 `chart-json-spec.md` 不一致：空数据的三张图抛异常、`NodeLinkChart` 不校验空 `links`

- **位置**：`f_chart/src/ManhattanChart.cj:64-66`、`f_chart/src/PairedLineChart.cj:67-69`、`f_chart/src/MosaicChart.cj:99-101`（空数据抛 `InvalidValue`）；`f_chart/src/NodeLinkChart.cj:109-135`（`links` 为空数组时不报错）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；`doc/chart-json-spec.md:2722`（"空数据：仍输出带标题与坐标框的 SVG，不抛异常；仅当结构缺失才抛 `MissingField`"）、`:2699-2714`（校验规则表）
- **证据**：静态确定 —— 三处 `isEmpty()` 分支直接 `throw chartInvalidValue(..., "数据不能为空"/"列总和必须大于 0")`；`LineChart`/`LollipopChart` 面对 `data: []` 则正常输出空图（`LineChart.cj:287-302` 生成空标签、`:335-338` 在 `!hasData` 时回落到 `[0,1]`，之后照常画坐标框）。反向：`NodeLinkChart` 用 `requiredArray("links")` 只保证字段存在，`:110-114` 对空数组不设分支，最终画出"一堆孤立节点"
- **描述**：同一份通用规格里"空数据不抛异常"是明确规则，而各图自己的 delta 规格（manhattan / paired-line 均为"`data` MUST 非空"）与它冲突，实现各自选了一边。对使用者表现为：换张图、同样的空数组，有时拿到空图、有时拿到 `ChartException`。`links` 空数组则相反——delta 规格写"`links` MUST 非空"，实现没校验
- **建议**：先定口径（建议以 `chart-json-spec.md:2722` 为准，允许空图），再统一：三处删掉 `isEmpty` 抛错分支（保留 `grandTotal <= 0` 这类"有数据但无法绘制"的判断），`NodeLinkChart` 补 `if (linkItems.isEmpty()) throw chartInvalidValue("links", "至少需要一条链接")`；两版 README 与三份 delta 规格同步

### [轻微][存量] `NomogramChart` 的 `variables[].points` 只做递增校验、不参与绘制

- **位置**：`f_chart/src/NomogramChart.cj:71-74`（`points` 读出后仅做两次比较）、`:75`（`NomogramVariable(name, range[0], range[1])` — 结构里没有 `points` 字段）、`:134-159`（每行刻度尺固定占满 `plot.x → plot.right()`）
- **来源**：存量
- **判据**：review-checklist §14.1「半成品 / 承诺了但只做一半」；承诺源 `f_chart/doc/chart-json-spec.md:1853`（`variables: [{name, range, points}]`）与 `f_chart/doc/spec/add-f-chart-nomogram/proposal.md:5`（"把多个预测变量的取值折算为分值"）
- **证据**：静态确定 —— `points` 在 `:71-74` 之后零引用（`:110` 起只用 `variable.rangeMin/rangeMax`）；`NomogramVariable`（`:23-33`）只有 `name/rangeMin/rangeMax`。而同文件的 `risk` 是按 `totalPoints` 归一化定位的（`:192-194`），说明"折算成总分"的能力只做在了风险轴那一侧
- **描述**：列线图的读法是"变量值 → 该变量的分值刻度 → 累加成总分 → 查风险"，现在每个变量的刻度尺长度都一样（都铺满绘图区），`points: [0,100]` 与 `points: [0,60]` 画出来完全相同，读者无法换算出分值。当前 delta 规格只要求"校验 `points` 递增"，因此**不算违约**，但与 proposal 与字段表的意图有落差，需规格负责人确认这是有意的简化
- **建议**：二选一并写进 `doc/chart-json-spec.md` 的 M51 小节：①按 `points[1] / maxPointsTotal` 决定每行刻度尺的长度（`NomogramVariable` 加 `pointsMin/pointsMax`，`draw` 里用 `plot.width * points[1]/maxPoints`），同时把"总分"行改为各变量分值上限之和；②在字段表注明"`points` 仅用于校验，渲染不使用"，并从 proposal 删掉"折算为分值"的表述

### [轻微][存量] `OrgChart` 的父槽位取"首末子节点中点"，3 个以上子节点且子树宽度不均时不等于子节点中心均值

- **位置**：`f_chart/src/OrgChart.cj:235-237`
- **来源**：存量
- **判据**：review-checklist §10「正确性（布局算法）」；意图源 `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md`（"父节点中心 MUST 等于其子节点中心的平均值"）
- **证据**：静态确定 —— `slot = (children[0].slot + children.last.slot) / 2.0`。子槽位由叶子游标连续分配（`:226-238`），若三个子节点的槽位为 `1.5`（宽子树）、`4`、`6`，父槽位得 `3.75`，而三者中心均值是 `3.83`
- **描述**：两子节点时两者恒等（故现有用例 `centersParent` 通过）；≥3 子节点且子树宽度不均时父节点会偏向宽子树一侧，连线出现斜折，视觉上是"树没对齐"，不影响连线拓扑
- **建议**：改为 `sum(child.slot) / children.size`（真正的均值，也是同类 tidy-tree 的常规做法）；补一个"三子节点 + 宽度不均子树"的槽位断言用例

### [轻微][存量] `ManhattanChart` 的染色体配色走调色板循环，而非"两种主题色交替"

- **位置**：`f_chart/src/ManhattanChart.cj:211-213`（`config.theme.colorAt(chromosomeIndex)`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」——证据等级**待确认**：该要求只写在已归档的 delta 规格（`doc/spec/add-f-chart-manhattan/specs/chart-rendering/spec.md`"颜色 MUST 按染色体顺序在两种主题色之间交替"），当前 `doc/chart-json-spec.md` 的 M93 小节未约定配色
- **证据**：静态确定（行为）/ 待确认（是否仍要求）—— `colorAt` 为 `palette[index % size]`（`ChartTheme.cj:54-60`），默认 10 色调色板，因此 11 号染色体开始与 1 号同色；文件内没有"两两交替"的取模或奇偶分支
- **描述**：曼哈顿图的通行画法是相邻染色体深浅交替，便于肉眼分辨边界。现在 24 条染色体得到 10 种颜色循环，相邻染色体可能撞色，读者会误判分组边界。若归档规格已被当前规格取代，本条可直接关闭
- **建议**：`let color = config.theme.colorAt(chromosomeIndex % 2)`（或 `if (chromosomeIndex % 2 == 0) theme.colorAt(0) else theme.colorAt(1)`），并把这条写进 `doc/chart-json-spec.md` 的 M93 小节，避免下次又漂移

### [轻微][存量] 通用折线类型声明在具体图表文件里，被 3 张无关图跨文件复用

- **位置**：`f_chart/src/LineChart.cj:24-32`（`LinePoint`）、`:35-43`（`LinePixel`）、`:46-69`（`LineSeries`）；使用方 `f_chart/src/AreaChart.cj:25,34,222-270,420-442`、`f_chart/src/ComboChart.cj:596-609`、`f_chart/src/RadarChart.cj:141,220`
- **来源**：存量
- **判据**：review-checklist §10「设计合理性（职责划分 / 依赖方向）」
- **证据**：静态确定 —— 三个类型都是 `internal` 且定义在 `LineChart.cj`，`LineSeries` 只被 `LineChart` 自己用（`grep` 全 module：仅 `LineChart.cj` 命中），`LinePoint`/`LinePixel` 被 Area/Combo/Radar 引用
- **描述**：`AreaChart` 等要依赖"折线图"这个具体文件的内部类型，改名或拆分 `LineChart.cj` 会波及三张图；`LineSeries` 却没有跨文件使用，放在这里更无必要
- **建议**：把 `LinePoint`/`LinePixel` 移到 `ChartScale.cj` 或新建 `ChartPoints.cj`（同包内部共享类型），`LineSeries` 留在 `LineChart.cj`

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分**没有任何 profile / bench 数据**，以下全部为「无基线（待验证）」，不进 `tasks.md`。

### [CPU]（O1）力导向布局的复杂度是 80 × N² + 80 × |E| × 2 × N

- **现状**：`NodeLinkChart.cj:227` 固定 80 轮；每轮先 `for (left in 0..nodes.size) for (right in left+1..nodes.size)` 做一次全对斥力（`:228-241`，`N(N-1)/2` 次 `sqrt`），再对每条边调用 `findNode` 两次（`:242-244`，每次线性扫 `N`）做 id→下标映射；绘制阶段 `:158-159` 又为每条边调用两次 `findNode`
- **方案**：进入 `runForce` 前一次性把 `links` 映射成 `Array<(Int64, Int64, Float64)>`（`HashMap<String, Int64>` 建索引），此后每轮只按下标取值；斥力可用 Barnes-Hut 四叉树近似，但属算法替换，建议先做索引化这一档
- **预期**：像素级等价（同一迭代顺序、同样的浮点加法顺序），仅去掉 `80 × |E| × 2 × N` 次字符串比较；收益随 `|E|·N` 增长，需实测
- **代价**：改动局限于 `NodeLinkChart.runForce` 与 `draw` 的边绘制；不改变输出（前提是保持原有的节点遍历顺序）
- **验证**：`cjpm bench -O2` 同一输入（N=200 / |E|=800 与 N=800 / |E|=3000 两档）取中位数与离散度，`cjprof record` 看 `findNode` 的 self time 占比
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU]（O2）4 处节点 id 去重与 4 处 id→节点查找都是线性扫描

- **现状**：`NetworkHeatmapChart.cj:55-59`、`NodeLinkChart.cj:88-92`、`OfflineFlameChart.cj:71-75`、`OrgChart.cj:88-92` 的重复 id 检测为 `n(n-1)/2` 次字符串比较；`OfflineFlameChart.cj:99`（每个节点一次）、`OrgChart.cj:112`（每个节点一次）在装配父子关系时再做一次全表扫描 → 解析阶段整体 O(n²)
- **方案**：建 `HashMap<String, Int64>` 索引，去重与查找都 O(1)；`NodeLinkChart` 的 `findNode`（`:184-191`）一并改索引
- **预期**：解析阶段从 O(n²) 降到 O(n)；N=10k 时字符串比较次数从 5×10⁷ 量级降到 10⁴ 量级（推算值，需实测）
- **代价**：多一个 `HashMap`（与 `nodes` 同生命周期，O(n) 额外内存，可接受）；错误文案与抛错时机不变
- **验证**：`cjpm bench -O2`，输入 1k / 5k / 10k 节点，测端到端 `draw` 时间与分配量
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU]（O3）`NetworkHeatmapChart` 每个单元格都重新解析一次颜色字符串

- **现状**：`NetworkHeatmapChart.cj:133-142` 已经用 `SvgColor.tryParse` 校验过 `colorRange`，但绘制时 `:190` 调 `heatFlameColor(ratio, colorRange)` → `HeatFlameChart.cj:271-282` 内部再次 `parseHeatFlameColor`（≥3 色走 `heatmapColor`，同样逐个解析）。N×N 单元格 → `N²` 次（3 色时约 `3N²` 次）字符串解析
- **方案**：在 `:126-142` 的校验循环里把结果存成 `Array<SvgColor>`（或预计算的 `RGB` 三元组），绘制时用「预解析颜色 + ratio」的内插函数；`heatFlameColor` 保持现有签名供 `HeatFlameChart` 使用
- **预期**：N=100 时省掉约 3 万次颜色解析；`tryParse` 单次成本需实测后换算端到端占比
- **代价**：`NetworkHeatmapChart` 需要新写一个"已解析调色板"的内插小函数（约 15 行），内插公式必须与 `heatFlameColor` 完全一致，需加等价性用例（同一 `ratio` 输出同一字符串）
- **验证**：`cjprof record` 对比改前改后 `SvgColor.tryParse` 的 self time 占比；`cjpm bench` 100×100 与 200×200 两档
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存]（O4）`ManhattanChart` 同时持有 4 份 O(n) 数组

- **现状**：`ManhattanChart.cj:67-69` 建 `points`（`ManhattanPoint`，含 `x/y/chromosome`）、`xs`（`Array<Float64>`）、`chromosomes`（`Array<String>`，与点的 `chromosome` 是同一批引用），`:89` 再由 `manhattanPositions` 复制出 `positions`（`Array<Float64>`，`:249-252` 先完整复制 `xs` 再改写）。峰值约 `n × (对象头 + 2×8 + 8) + 2 × n × 8 + n × 8`，随点数线性增长，全部活到函数结束
- **方案**：`manhattanPositions` 直接在 `xs` 的副本上原地改写（已如此），把 `points` 的 `x` 改为"不单独存 x，读 `positions[index]`"；或让 `manhattanPositions` 接收 `ArrayList<ManhattanPoint>` 并只返回偏移后的坐标，省掉 `chromosomes`（`points[i].chromosome` 已在）
- **预期**：省 1～2 份 n 元素数组（`n=10⁶` 时约 8～16 MB）；峰值占比需实测
- **代价**：`ManhattanPoint.x` 变成"原始 x"，绘制时用 `positions[index]`，可读性略降；`manhattanPositions` 是 `internal` 且被测试直接调用（`ManhattanChart_test.cj:77,87`），签名变更需同步用例
- **验证**：`getAllocatedHeapSize()` + RSS 多轮绘制 10 万/50 万/100 万点的稳态对照（`-O2`，同输入）
- **证据状态**：无基线（待验证，不进 tasks）

### [local mode] 结论：本部分不推荐

- **现状**：每张图的 `draw` 都产生大量"函数内创建、函数内丢弃"的临时对象（`LinePoint`/`LinePixel`/`ManhattanPoint`、各种 `ArrayList`、`StringBuilder` 片段），纸面上符合 local region 的适用形态
- **卡点**：①返回值是 `String`（SVG 全文），而 `SvgBuilder` 的图元树全程参与构造，逃逸链贯穿整个 `draw`，用 `exclave` 只能救最外层，收益被稀释；②`Chart` 接口签名 `draw(data: JsonObject): String` 无法标注 mode 重载，改造要动接口与全部 100+ 实现（跨部分）；③所有线程共用的 `cjLocalRegionMaxSize` 是新的 OOM 面，大图（10 万点）容易先撞 `LocalRegionOutOfMemoryError`
- **结论**：在拿到"峰值内存对照"之前不作为方案提出；若要评估，先在单张图的"中间点数组"上做局部试点（`LinePoint`/`ManhattanPoint` 的分配量占峰值比例需先测）
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 力导向布局在 N≥500 时成为主耗时（80 轮 × N² 对计算） | `f_chart/src/NodeLinkChart.cj:227-241` | 自耗时占比、端到端 `draw` 时间随 N 的曲线 | `cjprof record` 跑 N=100/300/800 各 30 轮，`cjpm bench -O2` 取中位数 |
| 2 | `findNode` 在边数 `E` 大时占比超过斥力项（`80 × E × 2 × N` 次字符串比较） | `f_chart/src/NodeLinkChart.cj:242-254` | `findNode` self time 占比 | 同上场景，固定 N=500、E=500/2000 两档对比 |
| 3 | 曼哈顿图 100 万点时的峰值内存与 `positions` 复制占比 | `f_chart/src/ManhattanChart.cj:67-89` | 峰值 RSS、`getAllocatedHeapSize()`、各数组占比 | 生成 10 万/50 万/100 万点 JSON，`-O2` 多轮绘制取峰值 |
| 4 | 网络热力图 100×100 时颜色解析占比可观 | `f_chart/src/NetworkHeatmapChart.cj:182-205` | `SvgColor.tryParse` self time 占比 | `cjprof record` 跑 50×50 / 100×100 / 200×200，统计 `tryParse` 调用次数与耗时 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_chart.part31.txt` 一一对应（清单 20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/LiftChart_test.cj` | .cj | ✅ | 用例与 `LiftChart`（属其它部分）契约一致：曲线/基准线/轴/非正基准/空数据/类型不符 6 组；`count()` 自实现，无缺陷 |
| 2 | `f_chart/src/LineChart.cj` | .cj | ✅ | 见 #3、#6、#8、#16（`series[].color`、`axis.values` 越界、图例名色重复、类型跨图复用） |
| 3 | `f_chart/src/LineChart_test.cj` | .cj | ✅ | 10 组用例覆盖类目/连续/时间轴/断线/smooth/symbol=none/混合形状/确定性/可解析；未覆盖 `xAxis.type=time` + 数值类目、单点成段 |
| 4 | `f_chart/src/LollipopChart.cj` | .cj | ✅ | 见 #3、#5、#6、#8（`series[].color`、0 基线越界、`axis.values`、图例名色重复） |
| 5 | `f_chart/src/LollipopChart_test.cj` | .cj | ✅ | 7 组用例；未覆盖 `yAxis.min > 0`（即 #5 的触发条件） |
| 6 | `f_chart/src/ManhattanChart.cj` | .cj | ✅ | 见 #6、#9、#15（`axis.values`、染色体顺序重复 + `chromosomeIndexOf` 兜底、配色） |
| 7 | `f_chart/src/ManhattanChart_test.cj` | .cj | ✅ | `insertsGap` 用注释写清了两组位移的推导，与实现一致；未覆盖 `threshold` 落在数据范围外 |
| 8 | `f_chart/src/MosaicChart.cj` | .cj | ✅ | 见 #1、#12（自绘头部、空数据口径） |
| 9 | `f_chart/src/MosaicChart_test.cj` | .cj | ✅ | 9 组用例；未覆盖 `legend.show=false`、零总和列、标签数 > 数据长度 |
| 10 | `f_chart/src/NetworkHeatmapChart.cj` | .cj | ✅ | 见 #2、#10（`cellGap` 上界、id 去重）；`colorRange` 超过 3 色只消费前 3 色，见「范围外提示」 |
| 11 | `f_chart/src/NetworkHeatmapChart_test.cj` | .cj | ✅ | 10 组用例覆盖方阵/阶数/重复 id/非数字/确定性；未覆盖 `cellGap` 上界 |
| 12 | `f_chart/src/NodeLinkChart.cj` | .cj | ✅ | 见 #10、#12、O1/O2（id 去重、空 `links`、力导向复杂度） |
| 13 | `f_chart/src/NodeLinkChart_test.cj` | .cj | ✅ | 11 组用例；未覆盖空 `links`、`charge=0`、单节点图 |
| 14 | `f_chart/src/NomogramChart.cj` | .cj | ✅ | 见 #11、#13（`maxNameWidthOf` 重写 `maxFloat`、`points` 未参与绘制） |
| 15 | `f_chart/src/NomogramChart_test.cj` | .cj | ✅ | 11 组用例覆盖校验与 `nomogramPosition`；用例本身只断言刻度数量，未断言刻度尺长度与 `points` 的关系（与 #13 一致） |
| 16 | `f_chart/src/OfflineFlameChart.cj` | .cj | ✅ | 见 #7、#10（不可达环检测、id 去重） |
| 17 | `f_chart/src/OfflineFlameChart_test.cj` | .cj | ✅ | 11 组用例覆盖子树/深度/未知 root/多根；未覆盖"有根 + 环" |
| 18 | `f_chart/src/OrgChart.cj` | .cj | ✅ | 见 #4、#10、#11、#14（环漏检、id 去重、`orgFitLabel` 字宽、父槽位中点） |
| 19 | `f_chart/src/OrgChart_test.cj` | .cj | ✅ | 12 组用例；`rejectsCycle` 只覆盖无根形态（#4 的漏检原因） |
| 20 | `f_chart/src/PairedLineChart.cj` | .cj | ✅ | 见 #6、#11、#12（`axis.values`、`bulletNumber` 复用、空数据口径） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。
（`README.md`、`README_en.md`、`doc/**` 与其余 231 个 `.cj` 属其它部分；本部分只把 `doc/chart-json-spec.md`、各 `doc/spec/add-f-chart-*/` 与 6 个支撑 `.cj` 当对照证据，不占本部分统计。）

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 6（#1 配置失效、#2 负宽矩形、#3 颜色未校验、#4 环漏检、#5 基线越界、#6 刻度越界）；设计 1（#16 类型跨图复用）；可读性 1（手工下标计数器 `nodeIndex++`/`rowIndex++` 等在 8 个文件重复，归入 #11 的"小工具重复"表述，不单列）；语言特性 0（`Option` 全部有显式分支、`Array`/`ArrayList` 语义正确、无强制解包）；安全性 0（属性/文本转义由 `SvgWriter` 负责，`series[].color` 只产生非法属性值、不构成注入，见 #3） |
| §1 死代码 | 2 | ①`OfflineFlameChart.cj:177-179,193-195` 两处 `depth > total` 不可达（#7）。②`NodeLinkChart.cj:196-202` 的 `placeManual` 中 `case None => 0.0` 两处分支不可达——`:97-104` 已对 `layout == "manual"` 缺 `x`/`y` 抛 `MissingField`，`:138-139` 又保证只有 manual 才进 `placeManual`，故 `manualX/manualY` 必为 `Some`。②与 #7 同类（"结构与上游校验已排除的分支"），位置单列、不另计严重度。其余机械核对：15 个 `internal` 类型（`LinePoint/LinePixel/LineSeries/LollipopSeries/ManhattanPoint/MosaicSeries/NetworkHeatmapNode/NodeLinkNode/NodeLinkEdge/NomogramVariable/NomogramRisk/OfflineFlameNode/OrgNode/OrgSlotCursor/PairedItem`）逐个全仓搜引用，均有调用者（`LineSeries` 仅本文件用，非死代码）；10 个 `internal` 函数（`lineRange/nodeLinkWidth/manhattanPositions/mosaicColumnTotals/nomogramPosition/orgFitLabel/orgAssignDepth/orgAssignSlots/orgLayout/findOrgNode`）均有非测试调用者，`chromosomeIndexOf` 亦在 `draw` 内使用；`private` 函数逐个确认被本文件调用（`LineChart` 10 个、`NodeLinkChart` 5 个、`OfflineFlameChart` 5 个、`NomogramChart` 3 个）；`return`/`continue` 后无同层语句；10 个图的 `import` 逐条核对无未使用（`OrgChart.cj` 未 `import std.math` 但用 `maxFloat`，与同模块 `AreaChart`/`ErrorBarChart`/`ResidualChart` 同写法且模块已有编译产物，按隐式导入处理，不作问题） |
| §2 重复逻辑 | 5 | #8（图例名/色）、#9（染色体顺序）、#10（id 去重+查找）、#11（字宽/`maxFloat`/数值读取）、#1（头部绘制与 `ChartFrame` 并存）。已两两比对：本部分 10 张图的 `draw` 主体（解析→校验→比例尺→builder→绘制）形态相似但数据结构、校验规则、图元序列各不相同，不判重复；测试文件里的 `draw()`/`count()` 辅助按检查表属"测试准备代码"，不判 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}` 静默吞异常（20 个文件 `grep -n "catch"` 零命中）；`public init() {}` 是 `Chart` 实现的无状态构造，接口无成员要求初始化，属合理空构造；`NomogramChart.drawName` 等小函数均有实际绘制行为。`NomogramChart` 的 `points` 只读不用归入 #13（§14），不算空实现 |
| §4 栈溢出 | 2 | `OfflineFlameChart.cj:176-215`（`validateValues`/`assignDepth`/`layoutNode`/`drawNode` 四段递归）与 `OrgChart.cj:218-238`（`orgAssignDepth`/`orgAssignSlots`）的递归深度均等于树深，只由 `nodes` 条数约束，无常量上限（#7 已指出 `depth > total` 那层保护不可达）。因单帧只含少量标量、达到溢出所需深度（万级链）未实测，按证据分级不判严重；建议给 `nodes` 条数设上限或改显式栈（设计变更，未列入优化方案） |
| §5 OOM | 0 | 逐个文件核对：无按报文长度 `Array(n, repeat:)` 预分配（`cellWidth/cellHeight/rowHeight` 均为除法）；无全局/静态容器（`CHART_DEFAULT_PALETTE` 为常量）；无缓存；`MosaicChart` 的 `valuesMatrix` 与 `ManhattanChart` 的 `xs/chromosomes/positions` 都是 O(n) 且随函数结束释放，峰值 ≈ 输入 JSON 的常数倍；唯一的"无界"是大点数导致的线性增长，属输入规模问题，已列入待验证假设 #3 |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile / bench 数据（`scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`，与图表渲染无关）。力导向、id 查找、颜色解析、曼哈顿数组复制四条线索全部降级为「优化可行性方案（无基线）」+「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件 `synchronized`/`Mutex`/`ReentrantLock` 零命中，无锁 |
| §6.3 并发串行 | 0 | `spawn`/`Future`/线程池零命中；`Chart` 为纯函数式 `draw`，无内部并发 |
| §6.4 低效算法 | 0（转为方案） | 命中形态 5 处（力导向 O(80·N²)、`findNode` O(E·N)、id 去重 O(n²)、染色体 `contains`+线性回查 O(n·c)、每格重复解析颜色），但缺"实际耗时占比"，按检查表要求不计为发现，全部写入「优化可行性方案」的 CPU 三条（O1/O2/O3）与待验证假设 #1/#2/#4 |
| §7 降堆内存方案 | 1 | 只有 `ManhattanChart` 的四份数组可合并（方案 O4）；其余图的对象数 ≈ 图元数，无中间副本可删。`clear()`/`gc()` 类假象未出现在本部分 |
| §8 降 CPU 方案 | 3 | 力导向索引化、id 查找索引化、颜色预解析（O1/O2/O3）；均为无基线待验证 |
| §9 local mode 可行性 | 1 | 已按 5 条约束逐条评估（逃逸 / 接口 mode 重载 / local region 上限 / 数据口径 / 实验特性），结论"不推荐、需先做局部峰值对照"，未写成优化建议 |
| §11 现有代码的 BUG（存量） | 13 | 16 条发现中属"读到的现有代码缺陷"的是 #1～#7、#9、#11～#15（#8/#10/#16 是重复逻辑与设计问题，已计入 §2 / §10 行）。已逐条核对：边界（空数组、单元素、负值、越界坐标、未命中下标返回 `-1`）、空值（`Option` 分支全覆盖，无强制解包）、错误处理（无 `catch`，错误均带 `path`）、资源（无文件/句柄/原生内存）、并发（无共享状态）、契约（对照 `chart-json-spec.md` §7 校验表逐条比对） |
| §12 并发安全与锁粒度 | 0 | 每张图的全部状态都是 `draw` 内的局部对象（`ArrayList`/`Array`/值类型 `ChartConfig`），无字段级共享；`public class XxxChart <: Chart` 无成员变量，`draw` 可被多线程并发调用（每个调用独立分配），线程封闭可证明；`ChartTheme.palette` 是 `var` 但只在 `parse` 期写入后只读，无发布后写入 |
| §14 功能完备性与 README 覆盖 | 4 | #1（`legend.*`/`title.subtext` 失效）、#13（`points` 未接）、#12（空 `links` 未校验）、#5（`yAxis.min>0` 与"茎从 0 基线起"互斥）。README 覆盖正向核对：10 个公开类名在 `f_chart/README.md` 与 `README_en.md` 各命中 1 次，在 `doc/chart-json-spec.md`/`doc/f_chart模块设计.md`/`doc/spec/` 合计命中 4–13 次，无"公开 API 未文档化"；10 个测试文件均存在且被 `files/` 清单收录 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 行全部读完（4551 行）；本部分无 `.md`，§13 的文档侧判定改由「代码 ↔ `doc/chart-json-spec.md`」对照完成，命中 6 条（#1、#3、#6、#12、#13、#15） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量 16 条（严重 0 / 一般 6 / 轻微 10），是否纳入修复待用户决定。

## 总评

本部分 10 张图的**骨架质量整齐**：`ChartConfig` 统一解析信封、`ChartFrame` 统一坐标框、`ChartScale` 统一比例尺与刻度、`ChartSvgKit` 统一图元与 class 命名，因此没有一张图出现"完全没校验"或"结构对不上"的硬伤；数值解析全部经 `jsonNumberValue` 兜住 `NaN`/`Inf`，测试覆盖也基本按"正常 + 每种错误各一条"展开（10 个测试文件 94 个 `@TestCase`）。除 `MosaicChart` 外，其余 9 张图都复用了 `ChartFrame`，说明分层是被遵守的。

风险集中在三处：

1. **绕开通用层的那一张图**（`MosaicChart`，一般 #1）：自己画标题和图例，于是 `legend.show` 关不掉、`position`/`markerSize`/`itemGap`/`subtext`/`align` 全部静默失效。这类"配置写了没效果"是本部分最容易被用户当成 bug 报上来的问题，修法也最便宜（换回 `ChartFrame` 三个调用）。
2. **边界配置触发越界绘制**（一般 #2/#5/#6）：负宽矩形、0 基线落到轴外、刻度画到轴外，三者都是"输入合法但几何越界"，代码里没有任何拒绝路径或裁剪。共同点是**没有一张图把"画之前先确认坐标落在 plot 内"当成不变量**，建议统一加一层裁剪/校验，而不是逐图打补丁。
3. **重复实现导致的语义分叉**（轻微 #8～#11）：图例名色推导、染色体顺序、节点 id 索引、字宽模型、数值读取各有一到四份副本。其中 `findNode` 返回 `-1` 被直接当下标用（`NodeLinkChart.cj:158`）、`chartTextWidth` 与 `orgFitLabel` 两套字宽是最容易在后续改动里变成真 BUG 的两处。

`OrgChart` 的环检测（一般 #4）值得单独排期：现有用例之所以是绿的，是因为它恰好只测了"没有根"这一形态；有合法根时环节点会被叠画在同一坐标，属于"静默产出错误图"。

性能与内存方面本部分**没有任何测量数据**，因此不给结论：四条线索（力导向 80×N²、id 线性查找、每格颜色解析、曼哈顿四份数组）全部写成"无基线待验证"的优化方案与假设，下一轮补 `cjprof record` 与 `cjpm bench -O2` 后再决定是否进 `tasks.md`。local mode 按五条约束评估后判定为"不推荐"，理由是 SVG 字符串全程逃逸 + `Chart` 接口无法做 mode 重载。

未跑构建与测试（只读审查），所有涉及运行时耗时的判断均已降级；`OrgChart.cj` 使用 `maxFloat` 而未显式 `import std.math`，因同模块另有三处同写法且模块已有编译产物，未按编译错误处理。

## 范围外提示（不计入本部分统计）

- `f_chart/src/HeatFlameChart.cj:260-283`：`heatFlameColor` 在 `colors.size >= 3` 时只取 `colors[0..2]`，第 4 个及以后的颜色永不生效。调用侧 `NetworkHeatmapChart.cj:126-142` 对任意长度 `colorRange` 逐个做合法性校验并全部接受，于是"多给的颜色被静默忽略"（长度上界应在调用侧或规格里约定；函数本身属其它部分）。
- `f_chart/src/ChartScale.cj:94-95`：`chartNiceTicks` 用 `floor/ceil` 扩展首末刻度但不扩轴域，与本部分 #6 同源（part2 的「范围外提示」已记录产物证据 `charts/M001-bar.svg` 的负坐标刻度）。
- `f_chart/src/FlameChart.cj:252-261`：`flameColorIndex` 是名称散列，`NodeLinkChart.cj:170` 用它把 `group` 映射成调色板下标，不同 `group` 可能散列到同一颜色（无冲突检测），且同一 group 的颜色随 `palette` 长度变化——目前没有图例，用户无法反查颜色含义，是否需要"group → 固定色 + 图例"待产品口径确认。
