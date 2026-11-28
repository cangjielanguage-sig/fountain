# f_chart 模块审查报告

> **模块第 12/37 部分**（本报告只覆盖 `files/f_chart.part12.txt` 列出的 20 个文件：`doc/spec/` 下 6 个变更 —— `add-f-chart-heatmap`、`add-f-chart-histogram`、`add-f-chart-histogram2d`、`add-f-chart-hive`、`add-f-chart-horizontal-bar`、`add-f-chart-icicle`；文件构成是 5 份 `design.md`、5 份 `proposal.md`、5 份 `specs/chart-rendering/spec.md`、5 份 `tasks.md`。本部分 **0 个 `.cj`**；为核对文档承诺，另行读了对应实现 `src/{HeatmapChart,HistogramChart,Histogram2DChart,HiveChart,HorizontalBarChart,IcicleChart,FlameChart}.cj` 及 `ChartJson.cj` / `ChartScale.cj` / `ChartSvgKit.cj` / `BarRenderer.cj` 的取证片段，这些 `.cj` 归属 `src/**` 子轮，只在本报告中作为证据引用、不占本部分文件覆盖统计。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分素材是 OpenSpec 归档文档，故实际执行 checklist §13（文档与实现一致性）+ §14（功能完备性），并把每条 Requirement / Scenario / Design 条款落到 `src/` 的具体行：分箱边界（最大值归箱、退化范围）、坐标换算（0 基线、带宽）、默认值（`bins` / `nodeRadius` / `showValues` / `shape`）、异常 `kind`、分配上界，以及「文档承诺但代码恒不成立」的分支
- **报告版本**：v1（第 12/37 部分）

## 发现

### [一般][存量] #1 直方图默认分箱数：design 写 `round(sqrt(n))`，实现是截断，全函数无 `round`

- **位置**：`f_chart/doc/spec/add-f-chart-histogram/design.md:5`；对照 `f_chart/src/HistogramChart.cj:167-186`（`179` 行 `Int64(sqrt(Float64(sampleSize)))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与实现不符」
- **证据**：静态确定 —— `design.md:5` 写 `bins` 缺省为 `max(1, round(sqrt(n)))`；`resolveBinCount` 的缺省分支只有一次截断转换，随后 `if (approx < 1) 1`，函数体内无 `round`。同批 `proposal.md:10` 只写「按样本量的平方根取整」（未定舍入），`README.md:836` 与 `README_en.md:832` 都写 `floor(sqrt(n))`，与实现一致、与 design 相反
- **描述**：`n = 8` 时 `round` 得 3 箱、截断得 2 箱；`n = 15` 时 4 对 3。默认分箱会改变柱数、柱宽与每箱频数，按 design 写验收用例必然失败；`HistogramChart_test.cj` 中缺省分箱路径无用例，漂移不会被测试发现
- **建议**：`design.md:5` 改为 `max(1, floor(sqrt(n)))`（与两版 README、实现一致）；若确实要 `round`，则改实现并补 `n = 8` 的缺省分箱用例，二选一

### [一般][存量] #2 横向柱高缺少 design 承诺的 24px 上限

- **位置**：`f_chart/doc/spec/add-f-chart-horizontal-bar/design.md:8`；对照 `f_chart/src/HorizontalBarChart.cj:114`、`121-125`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺的默认值与实现不符」
- **证据**：静态确定 —— design 写「柱高 `min(24, bandWidth * 0.6)`」；实现 `slot = band.bandWidth / max(series.size, 1)`，`requested = barWidth ?? slot * 0.6`，`barHeight = minFloat(requested, slot * 0.95)`，文件内无字面量 `24`
- **描述**：设计意图是「类别少时柱也不超过 24px」，实现只保证不超过行高的 95%。单系列 5 类目（默认画布）时 `slot * 0.6` 在 40px 量级，约为设计值的 1.6 倍；`README.md:396` 的示例恰好传 `barWidth: 24`，把差异掩盖了
- **建议**：实现补 `minFloat(minFloat(requested, slot * 0.95), 24.0)`，或把 design 改成「默认 `slot * 0.6`、上限 `slot * 0.95`、显式 `barWidth` 优先」并说明取消定值的原因

### [一般][存量] #3 显式 `xAxis.min > 0`（或 `max < 0`）时，横柱的 0 基线落在绘图区外，柱越界且方向反转

- **位置**：`f_chart/src/HorizontalBarChart.cj:113`（`let baseline = xScale.scale(0.0)`）、`242-266`（显式 min/max 优先）；对照 `f_chart/src/BarRenderer.cj:115-122`（同类图对基线做了钳制）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界越界」「契约与实现不符」；§2（同一规则两处实现、只有一处钳制 ⇒ 行为漂移）
- **证据**：静态确定 —— `LinearScale.scale` 是纯线性映射（`ChartScale.cj:23-43`），`resolveRange` 在 `axis.min` 存在时直接返回该值、不检查 0 是否在区间内。设 `xAxis.min = 10`、数据 20–30：`baseline = scale(0.0)` 落在 `plot.right()` 之外，`left = min(baseline, valueX) = valueX`、`width = |valueX - baseline|`，矩形从数值位置向右跨出绘图区。`BarRenderer.cj:115-121` 的同规则是 `range[0] > 0 → baseline 取 range[0]`、`range[1] < 0 → 取 range[1]`，把基线钳在区内
- **描述**：`design.md:12` 同时承诺「x 范围包含 0」与「显式 min/max 优先」，两条在 `min > 0` 时互相冲突；实现选了后者又没兜底。只画 10–300 这一段以放大差异是条形图常见用法，产出却方向错误、越出绘图区 —— 本部分唯一会让人读错数据的缺陷
- **建议**：按 `BarRenderer` 钳制基线（`range[0] > 0 → range[0]`，`range[1] < 0 → range[1]`，否则 0），并补 `min > 0`、`max < 0` 两个用例；该规则建议抽到 `ChartScale` 共用（`DotChart.cj:113`、`ComboChart.cj:527` 也是裸 `scale(0.0)`，属范围外提示）

### [一般][存量] #4 分箱数没有上界：`bins` 直接决定分配量

- **位置**：`f_chart/src/HistogramChart.cj:167-177`（只校验 `>= 1` 且为整数）、`247-251`（按 `binCount` 建 `ArrayList<Int64>`）；`f_chart/src/Histogram2DChart.cj:224-233`、`289-291`（按 `binsX * binsY` 建数组）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」
- **证据**：静态确定（分配量可由输入直接算出）—— `bins` 只做 `raw < 1.0 || raw != floor(raw)` 校验，无上限、无与样本量的关系约束。一维 `bins = 1e8` ⇒ `1e8 × 8 B ≈ 800 MB`（`ArrayList` 扩容期还要翻倍）；`1e9` ⇒ 8 GB。二维 `[50000, 50000]` ⇒ `2.5e9` 槽 ≈ 20 GB。`Int64(raw)` 对超 `Int64` 范围的浮点也无防护
- **描述**：两份 spec 只写「`bins`（两个）正整数」（`histogram/specs/.../spec.md:30`、`histogram2d/specs/.../spec.md:25`），没有任何上限或与样本量匹配的约束；一个数据点即可触发巨额分配（数据量与分配量解耦）。二维另有溢出面：`binsX * binsY` 超过 `Int64` 上限（各约 3.04e9）会溢出为负，`0..(负数)` 得到空 `counts`，随后 `countAt` 的 `yIndex * binsX + xIndex` 越界
- **建议**：两处加常量上限（如 1024）并写进 spec；二维用 `binsX > 上限 / binsY` 的形式做乘法前比较，避免溢出

### [一般][存量] #5 冰柱图环检测恒不成立，成环节点被静默丢弃

- **位置**：`f_chart/src/IcicleChart.cj:166-169`（`validateValues` 的 `if (depth > total) throw`）、`182-185`（`assignDepth` 同款）、`94-111`（只有根可达的子树被遍历）；同构代码 `f_chart/src/FlameChart.cj:167-195`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒假分支」、§11「错误处理静默」「失败路径当成功」
- **证据**：静态确定 —— 每个节点只有一个 `parent`，`id` 重复被 `:70-74` 拒绝、父节点不存在被 `:100-102` 拒绝；恰好一个根时可达树深度 `≤ n-1 < total`，`depth > total` 永不成立。真正的环（A.parent=B、B.parent=A 外加正常根）不在这棵树上，`roots.size == 1` 照样通过，`validateValues(rootNode, ...)` 只走根子树
- **描述**：输入 `[{id:"r",parent:null,value:10},{id:"a",parent:"b",value:1},{id:"b",parent:"a",value:1}]` 返回一份「少两个节点」的合法 SVG：无异常、无日志、无缺口提示，而 `"节点关系存在环"` 这条错误信息永远不会抛出。两处恒假分支给维护者「已经防住」的错觉
- **建议**：建树后断言 `已挂载数 + roots.size == parsed.size`，差额即环/孤立组件并抛 `chartInvalidValue("nodes", "节点关系存在环")`；删掉 `depth > total` 两处伪校验

### [一般][存量] #6 冰柱图四层递归全部无深度上限，深链输入爆栈

- **位置**：`f_chart/src/IcicleChart.cj:166-180`、`182-190`、`192-200`、`202-244`（`241-243` 递归）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归」（仓颉不保证尾调用优化）
- **证据**：静态确定（递归无出口条件）+ 需实测（崩溃阈值）—— 四个函数都只按 `child` 递归，唯一上界 `depth > total` 如 #5 所述永不触发；深度 = 树深 = `nodes` 长度，无常量上限、无迭代化
- **描述**：冰柱/火焰图的数据是调用栈或目录树，深链是正常形态。万级退化链会连续四次深递归（校验 → 定深 → 布局 → 绘制），栈空间按最坏一次计；爆栈是进程级崩溃
- **建议**：建树改 BFS（顺带完成环检测与定深），`layoutNode` 与 `drawNode` 改显式栈迭代，保持先父后子与子节点从左累加的顺序不变

### [一般][存量] #7 渲染尺寸参数只有下界没有上界：`cellGap` / `barWidth` 能产生负宽、负高矩形

- **位置**：`f_chart/src/HeatmapChart.cj:108-111`（`cellGap` 只校验 `>= 0`）、`157-162`（`cellWidth - cellGap` / `cellHeight - cellGap`）；`f_chart/src/HorizontalBarChart.cj:183`（`barWidth` 原样读入）、`121-125`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」
- **证据**：静态确定 —— `ChartSvgKit.rect`（`ChartSvgKit.cj:36-55`）把 `width` / `height` 直接交给 `SvgBuilder.rect`，不钳制。`cellGap = 200`、5 列时 `cellWidth ≈ 140`，单元格 `width = -60`，`showValues` 的文字锚点落在负尺寸矩形中心；`"barWidth": -5` 时 `barHeight = -5`
- **描述**：spec 的承诺是单向的（`heatmap/specs/.../spec.md:39` 只写「`cellGap` MUST 非负」，`horizontal-bar` 的 spec 完全没提 `barWidth`）。负尺寸矩形在 SVG 下不被渲染 ⇒ 整图空白或某根柱消失，且无异常可查
- **建议**：`cellGap` 钳到 `min(cellWidth, cellHeight) * 0.5` 或超限抛 `InvalidValue`；`barWidth` 要求 `> 0 && <= slot`。`HiveChart.cj:64-67` 的 `nodeRadius` 同样只有下界

### [一般][存量] #8 冰柱图与火焰图整份复制，design 却声称「共享树构建/宽度分配/校验/配色」

- **位置**：`f_chart/doc/spec/add-f-chart-icicle/design.md:5`；代码 `f_chart/src/IcicleChart.cj:49-155`、`157-204` 对照 `f_chart/src/FlameChart.cj:50-156`、`158-204`
- **来源**：存量（两文件同为 2026 版权头、同批次落地）
- **判据**：review-checklist §2「只改类型名」形态 —— 函数体逐行对齐，仅类型名与一个默认值不同
- **证据**：静态确定 —— 把 `FlameNode` 统一成占位名后 `diff`：`draw` 主体 107 行只差两行（`ChartConfig.parse` 的 `"flame"`/`"icicle"`、`orientation` 默认 `bottom-up`/`top-down`）；`findNode` / `validateValues` / `assignDepth` / `layoutNode` 完全相同（仅一处 `throw` 换行差异）；`drawNode` 同构
- **描述**：design 明写「冰柱图与火焰图共享树构建、宽度分配、校验与配色规则，仅默认方向相反」，实现没有共享任何代码。后果是同一缺陷修两遍（#5 / #6 就是双份），且两份已出现格式级漂移，后续修一处漏一处的概率高
- **建议**：抽 `internal` 共享实现（共享节点类型 + 树构建/校验/宽度分配 + 可配置默认 orientation），两图只保留 `drawNode` 差异；`flameColorIndex`、`heatColor` 已是共享函数，沿用同一落点

### [轻微][存量] #9 频数轴会出现 0.5 步长刻度

- **位置**：`f_chart/doc/spec/add-f-chart-histogram/specs/chart-rendering/spec.md:19-21`；代码 `f_chart/src/HistogramChart.cj:85-90`、`141`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格口径与实现不一致」
- **证据**：静态确定 —— `yRange = [0, maxCount*1.05]`，`chartNiceTicks(0, 2.1, 5)`：`rawStep = 0.42` → `magnitude = 0.1`、`normalized = 4.2` → `step = 0.5`，刻度为 `0, 0.5, 1, 1.5, 2, 2.5`
- **描述**：spec 要求「y 轴 MUST 从 0 开始表示频数」，频数是整数，但浮点上界走 nice ticks 后标签出现 0.5 / 1.5 / 2.5。数据正确、观感失真
- **建议**：频数轴单独取整数步长（`step` 向上取整且 ≥ 1），或 `yRange` 上界取整；spec 同步写「频数刻度取整数」

### [轻微][存量] #10 蜂巢图「各组布置在圆周上」在单分组时不成立

- **位置**：`f_chart/doc/spec/add-f-chart-hive/specs/chart-rendering/spec.md:7`、`f_chart/doc/spec/add-f-chart-hive/design.md:10`；代码 `f_chart/src/HiveChart.cj:153-168`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格 MUST 与实现相反」
- **证据**：静态确定 —— `groupNames.size == 1` 时 `angle = 0` 且 `clusterX/Y` 直接取 `plot.centerX/Y`，即绘图区中心而非半径 `0.32 * 短边` 的圆周上；`README.md:1704`（「簇心沿大圆周分布」）同样无例外说明
- **描述**：单分组时是一个居中团簇，规格文字读起来是「永远在圆周上」。实现的选择合理，但文档缺该例外，无法据此写断言
- **建议**：spec / design / README 三处补「单分组时簇心置于绘图区中心」

### [轻微][存量] #11 蜂巢图 design 说「空值归入空字符串分组」，显式 `null` 实际抛异常

- **位置**：`f_chart/doc/spec/add-f-chart-hive/design.md:5`；`f_chart/src/HiveChart.cj:93`；`f_chart/src/ChartJson.cj:68-84`、`208-213`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现不符」、§11「空值未处理」
- **证据**：待确认（「空值」是否含 JSON `null`）+ 静态确定（代码路径）—— `json.string(groupField, default: "")` 只在键**缺失**时返回默认值；键存在且为 `null` 时走 `jsonStringValue`，非字符串即抛 `InvalidValue("期望字符串")`。模块内 `IcicleChart.cj:76-86` 对 `parent` 显式区分 `isNull`，`ChartJson.number` 也把 `null` 视为 `None`，说明「null 视为空」已有先例
- **描述**：真实数据里 `group` 为 `null` 比键缺失更常见（左连接、可选标签）。若「空值」包含 `null`，则整图因一个 `null` 失败而不是落进空分组
- **建议**：`HiveChart.cj:93` 先判 `isNull` 再取默认值，或把 design 改成「缺失/空串归入空分组；显式 `null` 抛 `InvalidValue`」，并在 spec 校验条款写一句

### [轻微][存量] #12 分箱数的整数校验（含相同文案）在两个文件里各写一遍

- **位置**：`f_chart/src/HistogramChart.cj:170-176` 与 `f_chart/src/Histogram2DChart.cj:225-231`；兜底另见 `HistogramChart.cj:234-236`、`Histogram2DChart.cj:265-267`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制 / 只改形参名」
- **证据**：静态确定 —— 两段均为「非 `Int`/`Decimal` → `"期望正整数"`；`raw < 1.0 || raw != floor(raw)` → `"分箱数必须为正整数"`；`Int64(raw)`」，逐行同构
- **描述**：目前行为一致、无漂移；但 #4 的上限校验要同时加到三处，漏一处就出现「一维拦住、二维放过」
- **建议**：抽 `internal func parseIntBinCount(value: JsonValue, path: String): Int64`（或 `ChartJson` 增加 `positiveInt`），上限与文案收进去

### [轻微][存量] #13 热力图同一段带宽算了两遍（`cellWidth` 与 `BandScale.bandWidth`）

- **位置**：`f_chart/src/HeatmapChart.cj:129-131`、`157`、`202`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— `BandScale` 的 `bandWidth = (end - start) / count`（`ChartScale.cj:51-58`），此处 `start = plot.x`、`end = plot.right()`，故 `columnBand.bandWidth == cellWidth`；单元格用前者、列标签用后者
- **描述**：当前恒等、无缺陷；一旦 `ChartFrame` 的 `width` 与 `right() - x` 之间引入留白（例如加右侧图例列），单元格与列标签即错位，且不易在截图里发现
- **建议**：删掉 `cellWidth`，统一用 `columnBand.bandWidth`；y 方向同理

### [轻微][存量] #14 四份规格的校验清单漏掉实现里已有的硬约束

- **位置**：`f_chart/doc/spec/add-f-chart-heatmap/specs/chart-rendering/spec.md:37-39`；`f_chart/doc/spec/add-f-chart-histogram2d/specs/chart-rendering/spec.md:23-25`；`f_chart/doc/spec/add-f-chart-horizontal-bar/specs/chart-rendering/spec.md:5-7`；`f_chart/doc/spec/add-f-chart-icicle/proposal.md:10`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」/ §14「承诺面不完整」
- **证据**：静态确定 —— ① 热力图 `HeatmapChart.cj:35-37` 拒绝多系列、`:59-61` 拒绝空行，spec 只写「矩阵非空且每行长度一致」；② 二维直方图 `Histogram2DChart.cj:83-85` 拒绝多系列、`:92-94` 拒绝空 `data`，spec 校验条只列 `bins`/点/`shape`；③ 条形图 `HorizontalBarChart.cj:207-216` 强制 `data` 长度等于 `yAxis.labels` 长度，spec 场景隐含但未声明；④ 冰柱图 `IcicleChart.cj:88-90` 要求 `value > 0`，proposal 只描述字段形状
- **描述**：四条约束都有明确抛错、属对外可观察行为，规格没写 ⇒ 读者无法据此写用例，也无法判断「多系列是否合法」
- **建议**：补进对应 `spec.md` 的校验 Requirement（含 `kind`），或在 proposal 的「What Changes」点名

## 优化可行性方案

> 本部分无 profile / bench 数据，以下三条均为「无基线（待验证）」，**不进 `todo.md` / `tasks.md`**。

### [CPU] 蜂巢图 / 冰柱图的节点 id 查找是线性扫描，整体 O(n²)

- **现状**：`HiveChart` 建节点时逐个比对 id（`87-91`，O(n²)），每条链接校验两端各调一次 `findNode`（`113-118`），绘制时再各调一次（`194-195`），`findNode` 全表扫描（`215-222`）⇒ O(n² + m·n)。`IcicleChart` 建树时每个有父节点的节点调一次 `findNode`（`98`，扫描 `157-164`）⇒ O(n²)。n、m 由输入决定，典型规模 10²–10⁴
- **方案**：解析阶段建 `HashMap<String, Int64>`（id → 下标），重复 id 在插入时抛错，后续全部 O(1) 查表
- **预期**：O(n²) → O(n + m)；n = 5000、m = 10000 时比较次数由约 5×10⁷ 降到 1.5×10⁴ 量级（复杂度推导，非实测收益）
- **代价**：多一个 map（与节点数组同量级）；`HashMap` 迭代顺序不参与输出，不影响确定性
- **验证**：`cjpm bench -O2` 跑 n ∈ {100, 1000, 5000, 10000}，取中位数与离散程度；断言 `draw` 输出逐字节不变（可复用现有确定性用例）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 热力图每格重复解析三个颜色字符串

- **现状**：`HeatmapChart.cj:156` 每格调用 `heatmapColor`，后者在 `:233-235` 对 low/mid/high 各做一次 `SvgColor.tryParse`；200×200 矩阵 ⇒ 120 000 次解析，而颜色在一次渲染内不变
- **方案**：`draw` 内解析一次，新增 `heatmapColorOf(ratio, low: SvgColor, mid: SvgColor, high: SvgColor)`，原 `heatmapColor` 保留给 `DifferentialFlameChart` / `HeatFlameChart`
- **预期**：解析次数由 `3×rows×cols` 降到 3；端到端降幅取决于解析在渲染总耗时中的占比（未测）
- **代价**：多一个 `internal` 函数，无 API 变更
- **验证**：`cjprof record` 渲染 200×200 热力图，看 `SvgColor.tryParse` / `heatmapColor` 自耗时占比；`cjpm bench -O2` 改前后中位数对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 渲染前的数据多留一份副本：`toArray()` 与双重容器

- **现状**：`HeatmapChart` 用 `ArrayList<Array<Float64>>` 存矩阵（每行一次 `toArray()`，`68-88`），行数组与 `ArrayList` 底层数组同时存活到 `draw` 结束；`HistogramChart` 把输入先收进 `ArrayList<Float64>` 再 `toArray()`（`70-82`）；`Histogram2DChart` 同理（`95-107`、`288-310`）。峰值约为「原始 JSON 数字 + 解析副本 + 分箱数组」三份并存
- **方案**：`values` 用 `Array` 一次分配（先取 `items.size` 再填充），省掉扩容期临时容量；`HeatmapChart` 改一维 `Array<Float64>` + `rowCount * columnCount` 索引，去掉每行小数组的对象头
- **预期**：`ArrayList` 扩容峰值约降 30–50%，热力图再省 `rowCount` 个数组对象。**缺改前 `getAllocatedHeapSize()` / RSS 基线，不能写成确定收益**
- **代价**：一维索引牺牲可读性（可与 #13 一并做）；分箱数组无法省掉
- **验证**：同输入（10 万数字矩阵 / 100 万样本直方图）多轮 `draw`，对比 `getAllocatedHeapSize()`、`getUsedHeapSize()`、RSS 的稳态与峰值；`-O2`、同机器
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HiveChart.findNode` 的 O(n·m) 扫描是蜂巢图渲染的主要 CPU 项 | `f_chart/src/HiveChart.cj:113-118, 194-195, 215-222` | 自耗时占比、调用路径 | `cjprof record` 跑 n=5000 / m=10000 的 `draw` 200 次，看 `findNode` self time 占比 |
| 2 | 冰柱图深链输入会在「万级」深度爆栈 | `f_chart/src/IcicleChart.cj:166-244` | 崩溃临界深度、单帧栈占用 | 生成 1k / 5k / 10k / 20k 层退化链逐级 `draw`，记录首次栈溢出的深度（同 SDK、默认栈大小） |
| 3 | `bins` 取 10³–10⁴ 量级时，分箱数组的分配与清零成为端到端主要耗时 | `f_chart/src/HistogramChart.cj:247-251`；`f_chart/src/Histogram2DChart.cj:289-291` | 分配量、单次耗时、GC 次数 | 固定 100 个数据点，`bins` 取 16 / 1024 / 65536 / 1e6，分段计时并记 `getAllocatedHeapSize()` 与 GC 次数 |
| 4 | 颜色解析占热力图渲染耗时的显著比例 | `f_chart/src/HeatmapChart.cj:225-248` | `SvgColor.tryParse` 自耗时占比 | `cjprof record` 渲染 200×200 矩阵 20 次，取占比中位数 |

## 文件覆盖

> 与 `files/f_chart.part12.txt` 一一对应（该文件 20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-heatmap/specs/chart-rendering/spec.md` | .md | ✅ | 4 条 Requirement 逐条对照 `HeatmapChart.cj`，成立（`showValues` 默认 false、三色端点与 0.5 中点、15 格计数、`MissingField`/`UnsupportedChart`、行长度与标签校验）；`cellGap` 缺上界见 #7，校验清单缺项见 #14 |
| 2 | `f_chart/doc/spec/add-f-chart-heatmap/tasks.md` | .md | ✅ | 4 项全部 `[x]`；对应用例存在且覆盖单元格数、三色插值、数值标签、负 `cellGap` |
| 3 | `f_chart/doc/spec/add-f-chart-histogram/design.md` | .md | ✅ | 分箱公式与实现不符（#1）；「柱色取调色板首位」未提 `series.color` 覆盖（`HistogramChart.cj:64,143-146`，属描述不完整）；其余（退化范围 ±0.5、下标钳制、零频跳过、轴选型、1.05 系数）与实现一致 |
| 4 | `f_chart/doc/spec/add-f-chart-histogram/proposal.md` | .md | ✅ | `type`、数据形状、缺省分箱、最大值归末箱、零频不绘制、y 轴为频数 —— 与实现一致（缺省口径见 #1） |
| 5 | `f_chart/doc/spec/add-f-chart-histogram/specs/chart-rendering/spec.md` | .md | ✅ | 4 条 Requirement + 6 个 Scenario 成立（1–8 四箱各 2 条、单值 1 根柱、`bins=0` → `InvalidValue`、`type=bar` → `UnsupportedChart`）；「正整数」缺上界见 #4，频数刻度见 #9 |
| 6 | `f_chart/doc/spec/add-f-chart-histogram/tasks.md` | .md | ✅ | 4 项全部 `[x]`；测试覆盖分箱、零频、单值、坐标轴、校验、确定性 |
| 7 | `f_chart/doc/spec/add-f-chart-histogram2d/design.md` | .md | ✅ | 退化 ±0.5、下标钳制、`y * binsX + x` 展平、`heatColor(count/maxCount)`、`cell`/`hexagon` 类名、半径 `min(cellW, cellH) * 0.55` —— 与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-histogram2d/proposal.md` | .md | ✅ | `2d-histogram`、`{x,y}`、`bins` 默认 `[20,20]`、`shape` 默认 `hexagon`、零频不绘制、两个内部单测入口（`histogram2DCounts`/`heatColor` 均存在） |
| 9 | `f_chart/doc/spec/add-f-chart-histogram2d/specs/chart-rendering/spec.md` | .md | ✅ | 3 条 Requirement + 4 个 Scenario 成立（「有限数值」由 `jsonNumberValue` 的 `isNaN/isInf` 兜住）；「两个正整数」缺上界见 #4，校验清单缺项见 #14 |
| 10 | `f_chart/doc/spec/add-f-chart-histogram2d/tasks.md` | .md | ✅ | 4 项全部 `[x]`；测试覆盖单元数、六边形、计数、非法 `bins`/`shape` |
| 11 | `f_chart/doc/spec/add-f-chart-hive/design.md` | .md | ✅ | 分组顺序、簇半径 0.32、簇内小圆半径、链接 1.2px、`flameColorIndex` 配色、标签白色 —— 与实现一致；单分组圆周见 #10，「空值」口径见 #11 |
| 12 | `f_chart/doc/spec/add-f-chart-hive/proposal.md` | .md | ✅ | `hive`、`nodes`+`links`、`groupField` 默认 `group`、`nodeRadius` 10、`clusterGap` 80、三个类名 —— 与实现一致 |
| 13 | `f_chart/doc/spec/add-f-chart-hive/specs/chart-rendering/spec.md` | .md | ✅ | 4 条 Requirement + 5 个 Scenario 成立（节点/标签/连线计数、默认半径、未知端点、非正半径）；「圆周」表述见 #10 |
| 14 | `f_chart/doc/spec/add-f-chart-hive/tasks.md` | .md | ✅ | 4 项全部 `[x]`；测试覆盖节点、连线、分组布局、参数、校验 |
| 15 | `f_chart/doc/spec/add-f-chart-horizontal-bar/design.md` | .md | ✅ | 布局与比例尺选型一致；柱高 24px 上限缺失见 #2；「x 范围包含 0」与「显式优先」自相矛盾见 #3；`BandScale`/`LinearScale`/`drawXAxisNumeric`/`niceTicks`/`chartFormatTick` 引用均存在 |
| 16 | `f_chart/doc/spec/add-f-chart-horizontal-bar/proposal.md` | .md | ✅ | `horizontal-bar`、`yAxis.labels` 为类别、负值/`null`/调色板/图例/刻度 —— 与实现一致 |
| 17 | `f_chart/doc/spec/add-f-chart-horizontal-bar/specs/chart-rendering/spec.md` | .md | ✅ | 3 条 Requirement + 3 个 Scenario 成立（5 类 5 柱 5 标签、负值 `bar-negative`、`null` 跳过、nice 刻度）；未覆盖的 `min > 0` 分支见 #3，长度一致性未声明见 #14 |
| 18 | `f_chart/doc/spec/add-f-chart-horizontal-bar/tasks.md` | .md | ✅ | 4 项全部 `[x]`；测试仅 3 例显式 `min: 0`，无 `min > 0` / `max < 0` 用例（#3 未被覆盖） |
| 19 | `f_chart/doc/spec/add-f-chart-icicle/design.md` | .md | ✅ | 方向公式、宽度分配、父值容子、`icicle-label` 4px 偏移 —— 与实现逐字一致；「共享」声明不成立见 #8；`frameHeight` 未记录实现的自适应收缩（`IcicleChart.cj:131-138`） |
| 20 | `f_chart/doc/spec/add-f-chart-icicle/proposal.md` | .md | ✅ | `icicle`、`{id,name,parent,value}`、`orientation` 默认 `top-down`、`colorBy` 默认 `name`、`frameHeight` 18、两个类名 —— 与实现一致；`value > 0` 未写见 #14 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 4 条（#3 坐标越界、#5 静默丢节点、#6 无界递归、#9 频数刻度失真）。本部分无 `.cj` 入口，分层设计、值/引用语义、注入与凭据维度不适用（文档只描述单图 JSON 结构，无拼串、无凭据）。可读性：5 份 `design.md` + 5 份 `spec.md` 结构统一，未发现结构性缺陷 |
| §1 死代码 | 1 | #5（`IcicleChart.cj:167-169`、`183-185` 的 `depth > total` 恒假分支；`FlameChart.cj` 同款）。做法：对「文档承诺的校验分支」逐个推可达性。未做 6 个 `.cj` 的全部 `private`/`internal` 符号全仓引用搜索（属 `src/**` 子轮），本维度只保证「文档承诺对应的分支」已判定；另逐个 grep 验证了文档引用的 20 余个符号与全部 CSS class 均存在（`heatmapColor`/`computeHistogram`/`histogram2DCounts`/`heatColor`/`flameColorIndex`/`BandScale`/`LinearScale`/`chartNiceTicks`/`chartFormatTick`/`drawXAxisNumeric`/`drawYAxis`/`heatmap-cell`/`histogram-bar`/`hive-*`/`icicle-*` 等） |
| §2 重复逻辑 | 3 | #8（冰柱图 vs 火焰图整份复制，diff 只差类型名与默认方向）、#12（分箱整数校验逐行同构）、#13（热力图带宽两种算法）；另在 #3 记了 `BarRenderer` 与 `HorizontalBarChart` 的 0 基线规则重复且行为漂移。`HistogramChart`/`Histogram2DChart`/`HeatmapChart`/`HiveChart`/`HorizontalBarChart` 之间无同语义实现（退化处理相似但坐标系与输出 class 不同，属独立演进）；各变更的 `proposal.md`/`tasks.md` 结构重复属 OpenSpec 模板，不判 |
| §3 空实现 | 0 | 逐条比对 5 份 in-scope spec 的 18 条 Requirement 与实现，无空函数体、无 `TODO`/`FIXME`、无占位异常；`Histogram2DChart.cj:124` 的 `case None => ()` 是可选字段缺失的正常分支，不是吞错；5 份 `tasks.md` 全部 `[x]` 且所指文件/测试存在 |
| §4 栈溢出 | 1 | #6。判定依据「递归深度 = 输入树深、无常量上限」；崩溃层数 `需实测`，已列假设 #2，未据此提高严重度 |
| §5 OOM | 1 | #4，已量化：一维 `1e8 bins` ≈ 800 MB、`1e9` ≈ 8 GB；二维 `[50000,50000]` ≈ 20 GB，并有 `binsX*binsY` 溢出路径。资源释放/句柄维度不适用（无文件、连接、CFFI） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据。`findNode` 的 O(n·m)、颜色逐格解析只作线索，已降级为优化方案 + 假设 #1/#4 |
| §6.2 大粒度锁 | 0 | 6 个实现均无锁、无 `synchronized`、无共享可变状态；`Chart` 契约要求纯函数（`Chart.cj:27-35`），`draw` 全用局部变量 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池调用；渲染是单线程同步流程 |
| §6.4 低效算法 | 0 | 已识别两处线索（`HiveChart`/`IcicleChart` 线性 id 查找），无占比数据，按铁律不记为缺陷，改为优化方案 + 假设 #1 |
| §7 降堆内存方案 | 1 | 一条 `[堆内存]` 方案（`ArrayList` 扩容峰值 + 每行小数组），`无基线（待验证）`。未提池化：无生命周期证据 |
| §8 降 CPU 方案 | 2 | 两条 `[CPU]` 方案（id 查表、颜色预解析），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 已核约束、结论不可行：6 个 `draw` 的中间结构（`HistogramBins` / `Histogram2DResult` / `HiveNode` / `IcicleNode`）跨函数传递、经 `children` 回填，`IcicleNode` 还被 `drawNode` 递归持有，属明显逃逸；且需 `--experimental`，无前后峰值数据，不建议排期 |
| §11 现有代码的 BUG（存量） | 6 | #3（基线越界）、#4（分箱无上界）、#5（环检测恒假 + 静默丢节点）、#6（无界递归）、#7（负尺寸矩形）、#9（频数刻度）。均由文档条款顺带核对实现命中，未做全仓考古 |
| §12 并发安全与锁粒度 | 0 | 无线程共享路径：6 个类均只有空 `init()`、无字段，`draw` 中间态全为局部变量；`Chart` 契约声明纯函数（`Chart.cj:27-35`），无锁可谈粒度 |
| §14 功能完备性与 README 覆盖 | 1 | #14（spec 校验清单缺 4 条实现已强制的约束）。其余双向核对完成：18 条 Requirement 均有实现分支，`proposal.md` 承诺的 11 个字段（`bins`/`shape`/`groupField`/`nodeRadius`/`clusterGap`/`orientation`/`colorBy`/`frameHeight`/`colorRange`/`showValues`/`cellGap`）全部可解析；六种图在 README 均有独立小节（`README.md:380`/`832`/`998`/`1307`/`1700`/`2506`），`type` 字符串与实现逐一对应 |
| §13 文档一致性 | 6 | #1、#2、#9、#10、#11、#14，以及 #3 的附带项（design「x 范围包含 0」未被保证）。其余 Requirement / Scenario / Design 条款逐条核对一致 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`add-f-chart-heatmap` 的 design/proposal 在第 11 部分、`add-f-chart-icicle` 的 spec/tasks 在第 13 部分，本部分不含 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 8 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 14 条，是否纳入修复待用户决定。

## 总评

本部分覆盖 6 个图表变更的 20 份 spec 文档。文档整体质量高：`spec delta` 的 Requirement 与 Scenario 有可判定的 THEN（类名计数、`kind` 取值、默认半径），`proposal` 的字段清单与 `design` 的公式基本能直接对上实现，5 份 `tasks.md` 全部完成且能追到测试文件，没有「文档写了、代码没有」的空承诺。

风险集中在三处：

- **边界与上界**（#3 / #4 / #7）：渲染对「合法但极端」的参数只做单向校验。`bins` 无上界，一个数据点即可打出 GB 级分配；`xAxis.min > 0` 时横柱的 0 基线落在绘图区外、柱方向反了（`BarRenderer` 有钳制、横柱漏了）；`cellGap` / `barWidth` 能产出负尺寸矩形，SVG 静默不渲染。建议优先修 #3 与 #4。
- **规格与实现漂移**（#1 / #2 / #9 / #10 / #11 / #14）：六处文档口径落后或漏项。改文档几行即可，但 #1 会让按 design 写的验收用例失败，#14 会让 spec 无法覆盖实现已强制的约束。
- **结构重复**（#8）：冰柱图与火焰图 240 行级整份复制，而设计文档声称共享；#5 / #6 两条缺陷因此在两份代码里各存一份。这是本部分唯一「改一次要改两处」的系统性风险，建议列可排期的重构。

三条性能方案与四条待验证假设均无基线，不进修复清单。无 `严重` 项：未发现可稳定复现的崩溃路径（栈溢出需深链输入，层数待实测）、未发现并发问题（渲染是纯函数、无共享状态）、未发现数值算错（#3 是坐标放置错）。

本报告只读文件，未修改任何源码，未跑构建。

范围外提示：`FlameChart.cj:167-204` 与冰柱图同源的递归/环检测/复制问题属其他部分覆盖范围，合并时请去重；`NetworkHeatmapChart.cj` 复用 `heatmap-cell` / `heatmap-value` 类名，其规格属第 11/13 部分。
