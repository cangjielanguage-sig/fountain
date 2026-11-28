# f_chart 模块审查报告（第 25/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 18 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（`git status f_chart` 无改动，无 diff）⇒ 本部分所有问题来源均为「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：分部分报告（v1 口径），由主 Agent 与同日抽样版合并为 `<module>_v2.md`

## 发现

### [一般][存量] 冲积图末列节点标签固定画在节点右侧，越出绘图区被裁切

- **位置**：`f_chart/src/AlluvialChart.cj:255`（`node.x + nodeWidth + 4.0`），坐标来源 `AlluvialChart.cj:175-180`
- **来源**：存量（工作区快照无 diff）
- **判据**：review-checklist §11（边界差一 / 布局边界）、§10 正确性
- **证据**：静态确定 —— 末列（`column == stages.size - 1`）由 `:178-179` 得到 `node.x = plot.right - nodeWidth`，标签起点为 `plot.right + 4.0`；`ChartFrame` 只给 `padding.right`（默认 24，`ChartConfig.cj:22`）作为右侧留白（`ChartFrame.cj:85-91`），故标签可用宽度仅 `24 - 4 = 20px`。示例数据里 `"新客"/"老客"` 在 `fontSize - 2 = 10` 时约 20px 已贴边，更长名称（如 `"流失用户"`）必然被 viewBox 裁掉。
- **描述**：多阶段冲积图的最后一列标签一律向右排，超出画布右边界；SVG 默认不裁剪但 viewBox 之外不可见，实际表现是末列标签被切一半或完全不可见。
- **建议**：按列决定锚点——末列用 `anchor: "end"` 画在 `node.x - 4.0`，其余列保持 `"start"`；或在 `ChartFrame` 传入 `rightLabelWidth` 给末列预留文本宽度。

### [一般][存量] 「连续轴范围」有 6 套实现，留白策略互相漂移

- **位置**：
  - `f_chart/src/AreaChart.cj:323-373`（`resolveYRange`：下界不留白、上界 ×1.05）
  - `f_chart/src/BarRenderer.cj:394-424`（`applyAxisRange`：上下界各 ×1.05）
  - `f_chart/src/BoxPlotChart.cj:249-264` 与 `f_chart/src/BoxScatterChart.cj:228-243`（两份逐字节相同：两端各按 `span × 0.05` 留白）
  - `f_chart/src/BlandAltmanChart.cj:95-116`（手写 5% / 8% 留白）
  - `f_chart/src/BulletChart.cj:122-132`（不留白）
  - 对照实现 `f_chart/src/LineChart.cj:457-478`（`lineRange`：两端按 `span × 0.05`，且**一侧显式时另一侧不留白**）
- **来源**：存量
- **判据**：review-checklist §2（换文件复制 + 近似重复导致行为漂移）
- **证据**：静态确定 —— 同一语义「数据范围 → 轴范围 + 5% 留白」出现 6 份，判据差异可枚举：`LineChart.lineRange` 用 `axisMax.isSome()` 抑制对侧留白，`BoxPlot/BoxScatter` 的同名函数缺这两个判断；`AreaChart` 用乘法 1.05 且下界完全不留白；`BarRenderer` 上下界都乘 1.05。
- **描述**：同一份数据在柱状图里负值下方有 5% 余量，在面积图里最低点正好压在轴上；轴留白属对外观感契约，用户切换 `type` 会看到不一致的边界。合并时若只抄一份，很容易把某一图的既有留白改掉。
- **建议**：以 `lineRange`（`LineChart.cj:457`）为唯一实现，落到 `ChartScale.cj`（`internal func axisRange(dataMin, dataMax, axisMin, axisMax, paddingRatio, path)`），各图改为传参；`AreaChart`/`BarRenderer` 的乘法留白改由 `paddingRatio` 表达。合并需附改动前后的轴范围单测（含单侧显式 min/max、常量数据两种边界）。

### [一般][存量] 轴边距与刻度宽度计算在 6 个图各写一遍；气泡图硬编码导致 `labelRotate` 时标签被裁

- **位置**：
  - `maxYLabelWidth` 循环：`AreaChart.cj:141-150`、`BarRenderer.cj:73-82`、`BlandAltmanChart.cj:131-137`、`BoxPlotChart.cj:159-168`、`BoxScatterChart.cj:119-128`、`BubbleChart.cj:167-176`
  - `xLabelHeight` 三元式：`AreaChart.cj:151-155`、`BarRenderer.cj:84-88`、`BlandAltmanChart.cj:138-142`、`BoxPlotChart.cj:169-173`、`BoxScatterChart.cj:129-133`、`BulletChart.cj:147-151`
  - **漂移点**：`BubbleChart.cj:177` 不走三元式，直接传 `config.theme.fontSize + 12.0`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑导致的行为漂移）、§11（与 `xAxis.labelRotate` 契约不符）
- **证据**：静态确定 —— `ChartFrame.drawXAxisNumeric`（`ChartFrame.cj:290-309`）按 `axis.labelRotate` 旋转标签并在 `plot.bottom() + 10.0` 处以 `anchor: "end"` 绘制，需要约 48px；`ChartFrame` 的底部留白完全来自构造参数 `xLabelHeight`（`ChartFrame.cj:87`）。气泡图固定只留 `fontSize + 12 ≈ 22px`，`labelRotate != 0` 时旋转文本落到画布外。
- **描述**：6 份相同代码里唯一漏改的一份（`BubbleChart`）就是出问题的一份；其余 5 图行为一致。触发条件：`type: "bubble"` + `xAxis.labelRotate: 45`（该字段对所有图开放，`ChartConfig.cj:79`）。
- **建议**：把「按 y 刻度算左留白」和「按 rotate 算底留白」收进 `ChartFrame`（例如 `ChartFrame.forAxes(config, legendVisible, yTicks, series…)`），或至少把 `xLabelHeight` 提成 `chartXLabelHeight(config)` 放在 `ChartScale.cj`；`BubbleChart` 改用该函数。

### [一般][存量] Bland-Altman 复用 `bulletNumber`，负的测量值被当成非法输入拒绝

- **位置**：`f_chart/src/BlandAltmanChart.cj:68-69`（调用）、`f_chart/src/BulletChart.cj:233-243`（实现，`number < 0.0` 抛 `InvalidValue "数值不能为负"`）
- **来源**：存量
- **判据**：review-checklist §2（跨图复制被当成通用工具）、§11（契约与实现不符 / 语义与命名不符）
- **证据**：静态确定 —— 该 helper 名为 `bulletNumber`，语义却包含「非负」约束；同 helper 还被 `CandlestickChart.cj:74-77`、`DumbbellChart.cj:70-71`、`PairedLineChart.cj:79-80` 复用。承诺源 `f_chart/doc/chart-json-spec.md:981-999` 只写「`series[0].data` 为成对测量 `{x, y}`」，未限制符号；Bland-Altman 用于两种测量方法的一致性比较，原始测量值取负（温度偏移、对数比、坐标差）是正常输入。
- **描述**：`{x: -1.2, y: -0.8}` 这类合法测量对会被拒绝，报错文案 `series[0].data[0].x: 数值不能为负` 与「Bland-Altman 不接受负数」这一未写进文档的限制都不易排查；哑铃图/配对折线图同类风险。
- **建议**：拆成 `requiredFiniteNumber(json, field, path)`（`BoxPlotChart.cj:241-247` 的 `requiredNumber` 已是这个语义）与 `bulletNonNegativeNumber`；Bland-Altman/哑铃/配对折线改用前者，子弹图/蜡烛图保留非负校验（蜡烛图的 low/high 是否允许负数需用户确认）。是否放宽属契约变更，需用户拍板。

### [轻微][存量] 空 `series` 数组报 `MissingField`，与同模块「空数组 = InvalidValue」的约定不一致

- **位置**：`AreaChart.cj:63-65`、`BarRenderer.cj:56-58`、`BubbleChart.cj:73-75`、`BlandAltmanChart.cj:43-45`、`BoxPlotChart.cj:65-67`、`BoxScatterChart.cj:43-45`、`BulletChart.cj:47-49`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）、§10 契约一致性
- **证据**：静态确定 —— 字段存在但为空时 `chartMissingField("series")` 产出消息「缺少必填字段」，`path` 也指向存在的字段；同模块 `AlluvialChart.cj:69-71`、`ArcChart.cj:94-96` 对空数组抛 `InvalidValue`。测试（如 `AreaChart_test.cj:129-138`）只覆盖真正缺键，未覆盖空数组。
- **建议**：统一成 `chartInvalidValue("series", "至少需要一个系列")`；若认为「空系列在语义上等于缺失」是有意设计，请在 `ChartJson` 注释里写明，并补一条对应用例。

### [轻微][存量] 空 `data` 数组静默通过，输出只有坐标轴的空白图

- **位置**：`AreaChart.cj:77-94`（空 `data` 得到空 `points`）、`AreaChart.cj:312-321`（`validateLengths` 只比较长度，`0 == 0` 通过）、`BarRenderer.cj:272-285`（`parseValues` 返回空数组后无任何非空校验）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）、§3（半成品路径）
- **证据**：静态确定 —— 兄弟图 `BoxPlotChart.cj:79-81`、`BubbleChart.cj:110-112`、`BulletChart.cj:59-61`、`BoxScatterChart.cj:57-59` 都抛「数据不能为空」；这两个图直接渲染空图，调用方拿不到任何失败信号。
- **建议**：`parseCategoryPoints`/`parseContinuousPoints`/`parseValues` 返回后校验 `size > 0`，抛 `chartInvalidValue("${path}.data", "数据不能为空")`。

### [轻微][存量] `AreaChart.resolveYRange` 两个分支恒不成立（不可达）

- **位置**：`f_chart/src/AreaChart.cj:347-352`
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `dataMin` 初值 `0.0`（`:324`），首个数据点赋值 `minFloat(0.0, value) ≤ 0`，其后只做 `minFloat`，故 `dataMin > 0.0` 永不成立；`dataMax` 对称恒 `≥ 0`，故 `dataMax < 0.0` 永不成立。
- **建议**：删除两段，改用注释说明「初值 0 已保证范围跨 0」；`var minimum`（`:353`）同时可降为 `let`。

### [轻微][存量] 未使用的 `import std.math.*`

- **位置**：`AlluvialChart.cj:19`、`BubbleChart.cj:19`、`BubbleChart_test.cj:18`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 三文件内无 `cos/sin/abs/sqrt/floor/ceil/pow/log10` 等 `std.math` 符号；它们用的 `minFloat/maxFloat` 是 `BarRenderer.cj:454-468` 定义的模块内函数。（`ArcChart.cj:21` 用 `cos/sin`，`AreaChart.cj` 不 import 但用模块内 `minFloat`，均无问题。）
- **建议**：删除这三行 import。

### [轻微][存量] `BarRenderer` 的 `case _` 分支缩进断裂

- **位置**：`f_chart/src/BarRenderer.cj:211-239`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 可维护性）
- **证据**：静态确定 —— `for (seriesIndex ...)` 的两层嵌套体（`:212-237`）与 `case _ =>`（`:201`）同列，`}` 收口在 `:238-239`，与文件其余部分（4 空格递进）不一致，容易误读作用域。
- **建议**：跑一次 `cjfmt` 或手工对齐；无行为变化。

### [轻微][存量] 箱线散点图平铺模式只取 `labels[0]`，多余标签被静默忽略

- **位置**：`f_chart/src/BoxScatterChart.cj:87-93`（对照嵌套数组分支 `:79-84` 有长度校验）
- **来源**：存量
- **判据**：review-checklist §11（校验不对称 / 静默丢弃输入）
- **证据**：静态确定 —— `labels.size >= 2` 且数据为扁平数组时，仅 `labels[0]` 作为组名，其余标签既不报错也不参与渲染；同一函数在嵌套分支对 `labels.size != groups.size` 抛 `InvalidValue`。
- **建议**：平铺模式若 `labels.size > 1` 抛 `chartInvalidValue("xAxis.labels", "扁平数据只支持 1 个标签")`。

### [轻微][存量] 面积图面积填充默认透明度 0.3 与规格的 0.2 不符

- **位置**：`f_chart/src/AreaChart.cj:283`（`json.number("opacity", default: 0.3)`）、`AreaChart.cj:291`（`case None => 0.3`）
- **来源**：存量
- **判据**：review-checklist §13（默认值与源码不符，文档承诺侧：`f_chart/doc/chart-json-spec.md:623`「`series[].areaStyle.opacity`（默认 0.2）」）
- **证据**：静态确定 —— 两处默认值均为 `0.3`，规格写 `0.2`；`AreaChart_test.cj:55-64` 只断言显式 `0.25` 生效，未覆盖默认值。
- **建议**：确认期望值后二者取一（改代码或改规格）；若改代码，同步 `f_chart/README.md` 的 `area` 小节。

### [轻微][存量] 同文件/同族函数的重复实现（标签生成、长度校验、排序、高度比例）

- **位置**：
  - `AreaChart.cj:295-321` 与 `BarRenderer.cj:287-313`：`resolveLabels` + `validateLengths` 算法与错误文案（「数据长度 X 与 xAxis.labels 长度 Y 不一致」）完全一致，仅元素类型（`Array<LinePoint>` / `Array<?Float64>`）不同
  - `BoxPlotChart.cj:249-264` 与 `BoxScatterChart.cj:228-243`：`resolveYRange` 逐字节相同
  - `ArcChart.cj:205-211`（`sequentialOrder`）与 `ArcChart.cj:216-219`（`arcNodeOrder` 的身份下标前缀）重复；`ArcChart.cj:220-228` 与 `BoxScatterChart.cj:250-258` 是同一插入排序的两份实现
  - `AlluvialChart.cj:168-174`：`alluvialHeights`（`:286-303`）内部已求和并算 `usable`，调用方再求一次 `sumTotals`、再算一次 `usable`，`heights[i] = totals[i] * scale` 与 `scale = usable / sumTotals` 是同一公式的两遍
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 同语义多份）
- **证据**：静态确定 —— 上述四组逐行比对，输入-输出-副作用一致，差异点已在上一条「轴范围」中单列。
- **建议**：`validateLengths` 改接 `Array<Int64>` 长度列表，与 `resolveLabels` 一起放 `ChartScale.cj`；`AlluvialChart` 让 `alluvialHeights` 直接返回 `(heights, scale)`，删掉调用方的重复求和；`sequentialOrder` 用 `arcNodeOrder` 的参数化版本（`sort: Bool`）替代。

## 优化可行性方案

### [CPU] 两处手写插入排序改为 O(n log n) 排序

- **现状**：`f_chart/src/ArcChart.cj:220-228`（按关联总流量对节点下标做插入排序，n = `nodes` 个数）与 `f_chart/src/BoxScatterChart.cj:250-258`（对每组样本值做插入排序，n = 该组点数），样本量直接来自用户 JSON，无上限校验；n = 10k 时比较次数约 5×10⁷。
- **方案**：`ArcChart` 侧排序「下标数组 + 比较器 `totals[j] > totals[j-1]`」（保持稳定），`BoxScatter` 侧对 `values` 的副本排序；两者都用标准库稳定排序替代手写内循环。
- **预期**：复杂度从 O(n²) 降到 O(n log n)，10k 样本比较次数从约 5×10⁷ 降到约 1.3×10⁵；单次 `draw` 的排序段耗时可忽略。
- **代价**：需确认标准库排序的比较器签名与「相等元素保持原序」语义（`arcNodeOrder` 的平票顺序会影响节点角度，属可见输出）；`BoxScatter` 仍需保留一份输入副本（排序不能改原数组）。
- **验证**：`cjpm bench -O2`，1k / 10k / 50k 三档，`ArcChart` 与 `BoxScatterChart` 各取中位数与离散度；`arcNodeOrder` 平票用例的 SVG 输出需与改动前逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 冲积图按阶段分桶，去掉「每列扫全量节点」

- **现状**：`f_chart/src/AlluvialChart.cj:154-163` 对每个阶段列扫描全部节点（`O(stages × nodes)`），并每列新建 `members`/`totals` 两个 `ArrayList` 与 `heights` 数组。
- **方案**：解析节点时一次性把 `nodeIndex` 追加进 `Array<ArrayList<Int64>>`（长度 = `stages.size`），列循环直接取桶；`totals`/`heights` 仍按列分配，但不再扫全量。
- **预期**：节点遍历从 `stages × nodes` 降到 `nodes`（stages=10、nodes=10k 时 10 万 → 1 万次比较），并少建 `stages` 个 `members` 集合。
- **代价**：`stages` 数量在解析期才确定，需要把 `nodeIndex` 编号与建桶顺序对齐（当前 `nodeIndex` 只用于错误路径文案）。
- **验证**：`cjpm bench -O2` 对比 10 阶段 × 10k 节点输入的 `draw` 中位数；输出 SVG 必须逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] Bland-Altman 去掉 `rawPairs` 这份重复数据

- **现状**：`f_chart/src/BlandAltmanChart.cj:59-75` 每个测量点构造 `Array<Float64>`（2 元素）存入 `rawPairs`，再 `toArray()` 复制一次，交给 `blandAltmanStats`（`:222-243`）重算 `y - x`；而 `pairs` 里已经存了同一个 `diff`。n = 10k 时多出 1 万个 2 元素数组 + 2 次列表复制 + 1 万次减法。
- **方案**：`blandAltmanStats` 改接 `Array<BlandAltmanPair>`（或直接接 `Array<Float64>` 的 diff 列表），删掉 `rawPairs`；同步 `BlandAltmanChart_test.cj:83/93/102` 的三处调用。
- **预期**：每张图少 n 个短数组与 1 次 `ArrayList → Array` 复制；峰值内存下降量随 n 线性，n=10k 时约 1 万个对象。
- **代价**：改一个 `internal` 函数签名与 3 个测试调用；无对外契约变化。
- **验证**：同输入 10k 点循环 100 次，对比 `getAllocatedHeapSize()` 与进程 RSS；SVG 输出逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序在万级样本下成为 `draw` 的主要耗时 | `ArcChart.cj:220-228`、`BoxScatterChart.cj:250-258` | 自耗时占比、n 的拐点 | `cjprof record` 跑 1k/10k 点，`cjpm bench -O2` 取中位数 |
| 2 | 节点 id 去重（`O(n²)`）与每条链接 `findNode`（`O(n·m)`）在万级输入下拖慢 | `AlluvialChart.cj:104-108`、`AlluvialChart.cj:218-219`、`ArcChart.cj:83-87`、`ArcChart.cj:155-156` | 输入规模与耗时曲线 | 造 10k 节点 / 20k 链接输入，分段计时解析段与绘制段 |
| 3 | 冲积图每阶段重建 `members`/`totals`/`heights` 与重复求和带来可观的短生命周期分配 | `AlluvialChart.cj:154-174` | 分配量、峰值占比 | `getAllocatedHeapSize()` 前后对照，10 阶段 × 10k 节点 |
| 4 | local mode 对解析期临时对象（`AreaSeries`/`BubblePoint`/`BulletItem` 等）有峰值内存收益 | `AreaChart.cj:222-274`、`BubbleChart.cj:113-127`、`BulletChart.cj:62-98` | 改前/改后峰值内存（`getUsedHeapSize()` + RSS） | 需 `--experimental --enable-local-mode` 编译对照，同输入同并发；注意 `cjLocalRegionMaxSize` 上限与工具链支持 |
| 5 | 气泡图半径只按「全图 size 极值 + 每系列半径区间」映射，跨系列同 size 半径不同，是否与规格预期一致 | `BubbleChart.cj:136-147`、`BubbleChart.cj:209-211` | 规格确认（尺寸归一化是否应跨系列统一） | 与需求方确认后补一条多系列同 size 的用例 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-word-network/specs/chart-rendering/spec.md` | .md | ✅ | 与 `WordNetworkChart.cj` 逐条核对（半径 8–18、开方映射、circular 布局、四类异常），一致 |
| 2 | `f_chart/doc/spec/add-f-chart-word-network/tasks.md` | .md | ✅ | 4 组任务均已完成：`WordNetworkChart.cj`/`_test.cj` 存在，`README.md:171` 有 M103 登记 |
| 3 | `f_chart/src/AlluvialChart.cj` | .cj | ✅ | 见发现 1、§2 项、优化方案 2 |
| 4 | `f_chart/src/AlluvialChart_test.cj` | .cj | ✅ | 覆盖节点/流量带/标签计数、高度分配、7 类非法输入、确定性 |
| 5 | `f_chart/src/ArcChart.cj` | .cj | ✅ | 见 §2 项与优化方案 1 |
| 6 | `f_chart/src/ArcChart_test.cj` | .cj | ✅ | 覆盖排序、弧高、端点、节点数、重复 id、类型 |
| 7 | `f_chart/src/AreaChart.cj` | .cj | ✅ | 见发现 2、5、6、7、11、12 |
| 8 | `f_chart/src/AreaChart_test.cj` | .cj | ✅ | 覆盖填充、透明度、缺测断段、连续点、平滑、混用形状 |
| 9 | `f_chart/src/BarChart.cj` | .cj | ✅ | 32 行薄封装，委托 `BarRenderer.render(..., BarMode.Simple)`；注释指向的 `doc/chart-json-spec.md` 存在 |
| 10 | `f_chart/src/BarChart_test.cj` | .cj | ✅ | 覆盖默认/显式画布、颜色优先级、网格、图例、错误路径、SVG 可解析 |
| 11 | `f_chart/src/BarRenderer.cj` | .cj | ✅ | 见发现 2、5、6、10、12 |
| 12 | `f_chart/src/BlandAltmanChart.cj` | .cj | ✅ | 见发现 2、4、12 与优化方案 3 |
| 13 | `f_chart/src/BlandAltmanChart_test.cj` | .cj | ✅ | 覆盖点数、界限线、轴标题、统计量（常值/单对/标准差）、缺 y、类型 |
| 14 | `f_chart/src/BoxPlotChart.cj` | .cj | ✅ | 见发现 2、5、12；五数顺序校验完整 |
| 15 | `f_chart/src/BoxPlotChart_test.cj` | .cj | ✅ | 覆盖箱体/须/端帽/异常值计数、标签、五数顺序、多系列、缺字段 |
| 16 | `f_chart/src/BoxScatterChart.cj` | .cj | ✅ | 见发现 2、5、9、12 与优化方案 1 |
| 17 | `f_chart/src/BoxScatterChart_test.cj` | .cj | ✅ | 覆盖单组/嵌套组、`showBox` 关闭、五数、标签不一致、jitter、空组 |
| 18 | `f_chart/src/BubbleChart.cj` | .cj | ✅ | 见发现 3、5、8 |
| 19 | `f_chart/src/BubbleChart_test.cj` | .cj | ✅ | 覆盖半径映射边界、非法 sizeRange、缺 size、非数值、类型 |
| 20 | `f_chart/src/BulletChart.cj` | .cj | ✅ | 见发现 2、4；`ranges` 递增校验与色带实现完整 |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 3（标签越界、空 data、空 series 语义）、设计 1（跨图复用 `bulletNumber`）、可读性 1（缩进）、语言特性 1（恒 `var`/死分支并入轻微项）；无外部输入拼接、无安全性问题 |
| §1 死代码 | 2 | 已逐文件过 `return/throw/break/continue` 后续语句、逐个 `private` 函数搜全仓引用（`stageIndexOf`/`findNode`/`determineContinuous`/`flushSegment`/`drawSymbol`/`drawLimit`/`requiredNumber`/`sortValues` 等均有调用）、`internal` 符号在本模块搜引用（`alluvialHeights`/`arcNodeOrder`/`bulletRangeColor`/`bubbleRadius`/`blandAltmanStats`/`boxScatterBounds` 等均有调用或测试引用）；`public` 的 `AlluvialChart`/`ArcChart`/`AreaChart`/`BarChart`/`BlandAltmanChart`/`BoxPlotChart`/`BoxScatterChart`/`BubbleChart`/`BulletChart` 均为对外 `Chart` 实现，不判死代码。命中：恒假分支（`AreaChart.cj:347-352`）、未使用 import（3 处） |
| §2 重复逻辑 | 4 | 已把本部分 9 个图的 `draw` 与 20 余个私有函数压成「输入→输出→副作用」两两比对；命中 4 组：轴范围 6 份、轴边距 6 份、标签生成/长度校验 2 份、插入排序/顺序数组/冲积图求和各 2 份 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`（全部分文件 grep 无命中）、无 `catch {}`；`case None => ()` 仅用于可选字段正常缺失（`point.y`/`outliers`/`series.color`），属语义正确的兜底 |
| §4 栈溢出 | 0 | 本部分无递归：`draw` 全是单层/双层循环，无自引用结构遍历；`findNode`/`stageIndexOf` 为线性查找 |
| §5 OOM | 0 | 输入来自已解析 JSON，容器规模 ∝ 输入；无按报文头预分配、无全局只增容器、无「全量提交任务」。输出经 `SvgBuilder` 全量拼接属既有设计，未超本部分判据 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点结论不成立；排序与幂等查找已列入待验证假设 1–3 |
| §6.2 大粒度锁 | 0 | 本部分无线程共享状态、无锁 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无单消费者队列 |
| §6.4 低效算法 | 2 | 插入排序 O(n²)（`ArcChart.cj:220-228`、`BoxScatterChart.cj:250-258`）与每阶段扫全量节点 O(stages×nodes)（`AlluvialChart.cj:154-163`）：复杂度可静态判定，但缺耗时占比 → 只进优化方案（无基线）与待验证假设，不作为缺陷 |
| §7 降堆内存方案 | 1 | `BlandAltmanChart.rawPairs` 重复数据（优化方案 3）；其余 `toArray()` 复制属既有风格、量级小，无基线不下结论 |
| §8 降 CPU 方案 | 2 | 排序换 O(n log n)、冲积图按阶段分桶；均无基线 |
| §9 local mode 可行性 | 0 | 本部分无「函数内大对象且不逃逸」的强证据，也无峰值内存数据；仅作为待验证假设 4，不写成建议 |
| §11 现有代码的 BUG（存量） | 6 | 本部分 9 个 `draw` 的边界（空数组、单元素、常量数据、负值、越界坐标）逐个核对；命中 6 条：标签越界、空 `data`、空 `series` 语义、`bulletNumber` 负值、平铺标签丢弃、`labelRotate` 底留白不足 |
| §12 并发安全与锁粒度 | 0 | `Chart` 实现无字段、无静态可变状态，`BarRenderer` 全 `static func` 且只用局部变量；实例可并发复用。`BarMode`/`BarSeries` 均为不可变值，无线程共享路径 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 9 个 public 图类型均能在 `f_chart/README.md` 里程碑表（M1/M14/M19/M26/M45/M63/M66/M76/M91）与 JSON 小节中检索到；`word-network` 的 spec/tasks 承诺项在 `WordNetworkChart.cj` 全部落地（含 README M103 登记） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 2 个均与实现对（spec 一致，tasks 全部完成），跨文件规格 `doc/chart-json-spec.md` 仅作承诺源引用（属其它部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 12 条，是否纳入修复待用户决定。

## 总评

本部分 9 个图（冲积、弧线、面积、柱、Bland-Altman、箱线、箱线散点、气泡、子弹）结构高度同构：解析 → 校验 → 范围 → 布局 → `SvgBuilder` 输出，全部无状态、无线程共享，无空实现与递归，输入校验覆盖度在图表库里属于较好水平（五数顺序、`ranges` 严格递增、`sizeRange`、`jitter`、`labelRotate` 都有对应校验与用例）。

没有严重项，阻塞级问题为零。真正需要排期的是三类「同构带来的漂移」：

1. **轴范围与轴边距各写 6 份，已经漂了**——`AreaChart` 与 `BarRenderer` 的负值留白不同，`BubbleChart` 漏掉 `labelRotate` 的底留白。这类问题单看任一文件都像对的，必须横向比对才暴露，建议在下一轮把 `axisRange` / `xLabelHeight` / `yLabelWidth` 收进 `ChartScale`/`ChartFrame`，并用「同一数据集换 `type`」的对照用例锁住边界。
2. **跨图复用 helper 夹带了私有语义**——`bulletNumber` 的「非负」限制被 Bland-Altman、哑铃、配对折线继承。这是本部分唯一会让合法数据被拒绝的问题，且报错文案指向字段而不是「不支持负数」，排查成本高，建议优先处理（是否放宽需用户拍板）。
3. **渲染边界的最后 20px**——冲积图末列标签越界、气泡/散点标签可越出画布。属于确定性布局缺陷，改法明确、风险低，可与上面两项一起排。

优化空间集中在两处 O(n²) 手写排序与冲积图每阶段全量扫描，复杂度可静态判定，但收益没有测量数据，按纪律只进「优化可行性方案（无基线）」与「待验证假设」。
