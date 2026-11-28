# f_chart 模块审查报告（第 26/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：12 个实现 + 8 个 `_test.cj`，见「文件覆盖」）
- **基线**：工作区快照（`git log -1` = `f309f0b55`；`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并进 `f_chart.md`）

## 发现

### [严重][存量] 日历热力图按用户给的日期区间逐日生成图元，3.65M 天区间无拒绝路径

- **位置**：`f_chart/src/CalendarHeatmapChart.cj:152`（`dayCount`）、`:154`（`weekCount`）、`:183-216`（逐日循环，每天一次 `kit.rect`）
- **来源**：存量（快照模式无基线；`git blame` 指向 `ee0b54af0d 2026-11-08` 之前的历史行）
- **判据**：review-checklist §5（OOM：无界容器 / 无拒绝路径）+ §11（边界）
- **证据**：静态确定 —— `startDays`/`endDays` 来自 `ChartTime.parseDays`（`f_chart/src/ChartTime.cj:27-39`，只要求 4 位年 + 月 1..12 + 日 1..31，允许 `0001-01-01`~`9999-12-31`），`dayCount = endDays - startDays + 1`（`:153`）没有任何上限判断；`:183` 的循环对每一天都追加一条 `calendar-cell`、每遇到新月份再追加一条 `month-label`，且循环体内还会对 `uniqueDays` 做一次线性扫描（`:191-196`）。峰值内存量为估算（需实测），迭代次数上界由输入完全决定（静态确定）。
- **描述**：一份数百字节的 JSON（`{"startDate":"0001-01-01","endDate":"9999-12-31"}` + 空 `data` 即可，`:68` 只在「数据为空且缺一个日期」时才报错）就能让 `draw` 迭代约 365 万次。每条 `calendar-cell` 是 `group+rect` 两个元素，文本约 120–150 B，仅 SVG 字符串即 ≥ 450 MB；叠加 `SvgBuilder` 的每个元素对象与属性表后量级更高，服务端渲染接口上等同于可控 OOM/长阻塞（单次 `draw` 同步执行，无取消点）。若 `data` 的日期也铺满该区间，`:191` 的线性扫描会让复杂度变成 O(天数 × 去重天数)，实际表现为挂死。
- **建议**：在 `:152` 之后加区间上限（例如 `dayCount > 3 * 366` 直接抛 `chartInvalidValue("endDate", "日期区间过大")`，或按 `cellSize`/画布宽度反推允许的周数），并把 `uniqueDays/totals` 换成 `HashMap<Int64, Float64>` 聚合，去掉 `:131-146` 与 `:191-196` 两处线性查找。

### [严重][存量] 校准曲线的 Y 轴方向反了：`LinearScale` 的 top/bottom 参数传反，整图上下镜像

- **位置**：`f_chart/src/CalibrationChart.cj:130`（`let yScale = LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)`）
- **来源**：存量（`git blame -L 127,132` → `ee0b54af0d 2026-11-08`）
- **判据**：review-checklist §11（契约与实现 / 与规格冲突）+ §10（正确性）
- **证据**：静态确定 —— `LinearScale` 的形参语义写在 `f_chart/src/ChartScale.cj:22`（「`topPixel` 对应最大值，`bottomPixel` 对应最小值」）与 `:41`（`bottomPixel - (value-min)/span*(bottomPixel-topPixel)`）；传 `(plot.bottom(), plot.y)` 会让 `min` 落在 `plot.y`（顶部）、`max` 落在 `plot.bottom()`（底部）。已提交的渲染产物同样印证：`f_chart/charts/M096-calibration.svg` 中 y 刻度 `0` 在 `y=74`（绘图区顶部）、`0.2` 在 `y=145.6`；对照 `M083-candlestick.svg` 是 `0` 在 `y=432`（底部）、`100` 在 `y=108`。
- **描述**：`M96 calibration` 的 Y 轴「实际频率」越大越靠下，校准曲线与 `:151-158` 的对角线一起被上下翻转；对用户而言是「模型在高概率段系统性高估/低估」的错误结论，不是排版瑕疵。同模块另有多处相同写法（`BlandAltmanChart.cj:149`、`LiftChart.cj:135`、`LearningCurveChart.cj:196`、`EcdfChart.cj:145`、`LassoPathChart.cj:157`、`ManhattanChart.cj:166`、`VolcanoChart.cj:157`、`PdpChart.cj:133`、`GainChart.cj:126`），属同一根因的批量复制；`LiftChart` 的产物 `M094-lift.svg` 也是 `0.5` 在顶部、`3` 在底部。
- **建议**：本文件改为 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`（与 `CandlestickChart.cj:145`、`BarRenderer.cj:91` 一致）；更彻底的做法是把 `LinearScale` 改成 `LinearScale(min, max, plot: ChartRect, vertical: Bool)` 之类的工厂，从签名上消除 top/bottom 传反的可能，并在 `ChartScale` 上补一条方向断言用例。范围外提示：上述 9 个别文件同模式需一并修，改完必须重新生成 `charts/` 产物复核。

### [一般][存量] `calibration.binCount` 只校验、不参与绘制，README / spec 承诺的「分箱」没有实现

- **位置**：`f_chart/src/CalibrationChart.cj:31-37`（校验后丢弃）、`:69`（直接对原始点排序后连线）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现 / 读了不用）+ §1（读入不使用的配置字段）
- **证据**：静态确定 —— 承诺源：`f_chart/doc/chart-json-spec.md:2004`「专属字段：`diagonal`（默认 true）、`binCount`（可选）」、`f_chart/README.md:2191`「绘制方式：将预测概率分箱，横轴为平均预测值、纵轴为实际正例率」；缺失证据：`binCount` 在全模块只出现在 `CalibrationChart.cj:31-37` 的校验里（`grep -rn "binCount" f_chart` 无其他命中），`points` 直接来自 `series[0].data` 原始 `{x,y}`，没有任何按桶求均值/求正例率的代码。
- **描述**：调用方按文档传 `binCount: 10` 会得到与不传时完全相同的图；同时 `binCount` 传 0/负数会抛异常，传正整数无效果——「有校验 = 有效果」的错觉。文档描述的能力实际是「把点连成折线」，与「分箱校准」语义不同，读图者会把稀疏点的抖动误读为校准偏差。
- **建议**：要么实现分箱（按 `binCount`（缺省 10）等宽切 `[0,1]`，每桶取 `x` 均值与 `y` 均值，空桶跳过），要么删掉该字段与 README/spec 描述，改成「数据即已分箱的中心点」。二者都需同步 `doc/chart-json-spec.md:2004`。

### [一般][存量] `legend.orient` 解析后从未使用；`legend.position` 的 `left` / `right` 落到 `legendY = 0`，图例画到画布顶边

- **位置**：`f_chart/src/ChartConfig.cj:96`（字段）、`:106`（解析）；`f_chart/src/ChartFrame.cj:76-84`（只处理 `top` / `bottom`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（接线缺失）+ §13（文档与实现不符）
- **证据**：静态确定 —— `grep -rn "orient" f_chart/src` 只命中 `ChartConfig.cj:96/106` 的定义与赋值，`ChartFrame.drawLegend`（`:134-166`）只用 `itemGap` / `markerSize`，始终横向排布；`legendY` 初始为 `0.0`（`:75`），只有 `position == "top"` / `"bottom"` 两个分支会赋值，`"left"` / `"right"` 保持 0，图例于是画在 `y = 0`（画布顶边，与标题重叠，且不参与 `plot` 的留白计算）。承诺源：`f_chart/doc/chart-json-spec.md:72-73`（`position` = `top`/`bottom`/`left`/`right`，`orient` = `horizontal`/`vertical`）、`f_chart/README.md:274`（`show` / `position` / `orient` / `itemGap` / `markerSize`）。
- **描述**：两个公开配置项一个静默失效、一个半实现；`position: "left"` 的图例压住标题，`orient: "vertical"` 完全没有效果，且不会报错。
- **建议**：短期在 `ChartLegend.parse` 里对 `position` 做取值校验（非 `top`/`bottom` 直接抛 `chartInvalidValue`，与 `weekStart`、`scaleBy` 的既有做法一致），并给 `left`/`right` 在 `ChartFrame` 里留出 `left`/`right` 边距 + 竖排绘制；`orient` 要么实现（竖排时按 `marker + 4 + 文本高` 累加）要么从解析、README 与 spec 三处一起删掉。

### [一般][存量] `ChartFrame` 不校验绘图区宽高为正，画布小或刻度标签过宽时产生负宽高/反向坐标

- **位置**：`f_chart/src/ChartFrame.cj:85-91`（`left` / `right` / `bottom` / `plot` 直接相减）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界差一 / 数值边界）+ §10（正确性）
- **证据**：静态确定 —— `ChartConfig.parse` 只校验 `width > 0 && height > 0`（`ChartConfig.cj:182-184`），而 `ChartFrame` 的 `left = padding.left + yLabelWidth`、`right = padding.right + rightLabelWidth`、`top`/`bottom` 都可由**输入**放大：`yLabelWidth` 在调用方由 `chartTextWidth(chartFormatTick(tick, labelFormat))` 求出（如 `CalibrationChart.cj:115-121`、`CandlestickChart.cj:131-137`），`labelFormat` 是用户可传的任意模板。只要 `width < left + right`，`plot.width` 即为负；`plot.height` 同理（`title` 为空 + `legend.position == "bottom"` + `xLabelHeight` 48 时更容易触发）。
- **描述**：负 `plot.width` 会传进 `BandScale`（`ChartScale.cj:57` → `bandWidth` 为负，`CandlestickChart.cj:166` 的 `bodyWidth` 随之为负，输出 `width` 为负的 `<rect>`，SVG 规范下该矩形不渲染）和 `LinearScale`（起止像素颠倒，整图镜像）。目前没有任何异常或钳制，问题以「空白图 / 图形错位」的形式静默出现。
- **建议**：`:91` 之后判断 `plot.width < 1.0 || plot.height < 1.0` 时抛 `chartInvalidValue("width", "画布过小，无法容纳标题与刻度")`（与 tui 版「最小 20×8，低于下限抛 ChartException」的约定对齐，见 `README.md:3098`），或在绘图区宽高不足时退回最小边距。

### [轻微][存量] §1 死代码：3 个 `ChartJson` 方法、1 个未使用 import、2 个只写字段

- **位置**：`f_chart/src/ChartJson.cj:53-55`（`has`）、`f_chart/src/ChartJson.cj:141-143`（`requiredObject`）、`f_chart/src/ChartJson.cj:203-205`（`childPath`）、`f_chart/src/ChartFrame.cj:18`（`import std.collection.ArrayList`）、`f_chart/src/ChartScale.cj:49-50,55-56`（`BandScale.endPixel` / `count`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（无调用者 / 未使用 import / 读了不用）
- **证据**：静态确定 —— `grep -rn "childPath\|requiredObject" f_chart` 只命中定义行；`grep -rn "\.has(" f_chart` 零命中（`ChartJson` 是 `internal` 类，方法随之对外不可达）；`ChartFrame.cj` 内 `ArrayList` 仅出现在 `:18` 的 import（文件内全用原生数组）；`BandScale` 的 `count` 只在 `:56` 赋值、`endPixel` 只在 `:57` 参与一次计算后再无读取（`grep -rn "\.count" f_chart/src/ChartScale.cj` 仅 `:56`）。
- **描述**：属于演进残留，不影响行为，但会让下一位读者误以为 `ChartJson` 支持这些形态（尤其是 `requiredObject`，与 `object(name)` 的差别只在「缺失时报错」）。
- **建议**：删除 3 个方法与未使用 import；`BandScale` 的 `endPixel`/`count` 若保留就补 `bandEnd()` 之类的读取方，否则降级为 `init` 局部变量。

### [轻微][存量] §2 重复逻辑：`colorRange` 校验块在 6 个图表里逐字复制

- **位置**：`f_chart/src/CalendarHeatmapChart.cj:111-127`、`f_chart/src/CartogramChart.cj:112-128`（本部分两处）；同形复制另见 `ChoroplethChart.cj:108`、`HeatFlameChart.cj:135`、`HeatMap.cj:109`、`NetworkHeatmapChart.cj:131`（范围外）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制：同一错误消息 + 同一循环）
- **证据**：静态确定 —— `grep -rn "至少需要两个颜色" f_chart/src` 命中 6 个文件，6 处的结构完全一致：`root.stringArray("colorRange", default: [...])` → `size < 2` 抛 `"至少需要两个颜色"` → `for (i in 0..size)` 逐个 `SvgColor.tryParse` → `"非法颜色 ..."`。差异仅在默认色板与第 3 个参数（默认值）。
- **描述**：同一语义的 6 份实现，任一处调整（例如允许 1 色、改成按 `#rgb` 简写展开、错误消息带候选值）都会漂移；`"非法颜色"` 字符串在模块内共出现 11 次，漂移面更大。
- **建议**：抽 `internal func chartColorRange(root: ChartJson, default: Array<String>): Array<String>` 放到 `ChartJson.cj` 或 `ChartScale.cj` 同层，默认色板作为参数传入；6 处改为一行调用，并补一个「1 色报错 / 非法色报错」的共用用例。

### [轻微][存量] §2 重复逻辑：`legendVisible` + `legendNames/legendColors` + `maxYLabelWidth`/`xLabelHeight` 样板在图表间反复照抄

- **位置**：`f_chart/src/CalendarHeatmapChart.cj:156,174-180`、`f_chart/src/CalibrationChart.cj:115-128,142-148`、`f_chart/src/CandlestickChart.cj:131-142,157-163`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（跨文件复制：输入-输出-副作用相同）
- **证据**：静态确定 —— 三处 `maxYLabelWidth` 循环（列表格式化刻度 → `chartTextWidth` → `maxFloat`）与 `xLabelHeight` 三元表达式（`fontSize + 12` / `48`）逐行同构；`legendVisible = config.legend.show && !seriesName.isEmpty()` 与随后的 `if (legendVisible) { [x] } else { Array<String>() }` 成对出现 3 次（模块内同类写法见 `LiftChart.cj:117-153`、`BlandAltmanChart.cj:156-163` 等）。
- **描述**：这类样板决定「图例是否显示」「Y 轴标签留多宽」，是本模块布局一致性的关键；散落复制后一旦某图调整（例如长标签换行、图例改为右侧），各图行为就会不一致——本轮 `legend.position` 支持面不足（见上一条「一般」）正是这种漂移的后果。
- **建议**：把 `legendVisible`、`[name]/[color]` 组装收进 `ChartFrame`（如 `frame.drawSeriesLegend(kit, seriesName, color)`），把 `maxYLabelWidth` + `xLabelHeight` 收成 `ChartFrame.yLabelWidth(ticks, format)` 与 `ChartFrame.axisLabelHeight(axis)`；差异（单系列 vs 多系列）用参数表达，不要新起一层抽象。

### [轻微][存量] 共享辅助类缺少入参校验：`drawLegend` 可能除零、`colorAt` 负索引、`padding`/`fontSize` 允许负值

- **位置**：`f_chart/src/ChartFrame.cj:153`（`colors[index % colors.size]`）、`f_chart/src/ChartTheme.cj:54-60`（`index % this.palette.size`）、`f_chart/src/ChartConfig.cj:39-45`（`padding` 未校验）、`f_chart/src/ChartTheme.cj:44`（`fontSize` 未校验）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 空集合）+ §10（正确性）
- **证据**：待确认 —— `drawLegend` 只在 `names.isEmpty()` 时提前返回（`:135`），`colors` 为空而 `names` 非空时 `index % 0` 会抛算术异常；仓内 3 处调用（`CalendarHeatmapChart.cj:180`、`CalibrationChart.cj:148`、`CandlestickChart.cj:163`）都按「成对传空/成对传 1 个」使用，因此当前不可达，属防御性缺口。`colorAt` 对负 `index` 取模得到负下标（仓颉数组负下标越界），仓内调用点（`CalibrationChart.cj:144,160`、`CandlestickChart.cj:159`）均为 0，但同模块 `ChordChart.cj:183`、`AlluvialChart.cj:207,248` 传入的是查找/映射结果，拼错输入即有风险。`ChartPadding.parse` 与 `ChartTheme.parse` 对负数不报错（`padding: -100` 会让 `plot` 大于画布，`fontSize: -1` 会写出 `font-size="-1"`）。
- **描述**：四处都是「值域假设」没有落到代码里；其中 `padding`/`fontSize` 是用户可直接控制的 JSON 字段，负值只产生畸形 SVG 而不报错。
- **建议**：`drawLegend` 增 `if (colors.isEmpty()) { return }` 或改成 `colors[index % colors.size]` 前判空；`colorAt` 用 `abs(index) % size`（或 `if (index < 0) { 0 }`）；`ChartPadding.parse` / `ChartTheme.parse` 对 `top/right/bottom/left`、`fontSize` 加 `>= 0`（`fontSize > 0`）校验并抛 `chartInvalidValue`。

### [轻微][存量] `bulletNumber` 与 `volcanoNumber` 只差一个负数检查，且蜡烛图复用「bullet」命名的辅助函数

- **位置**：`f_chart/src/BulletChart.cj:233-243`（`bulletNumber`）、`f_chart/src/VolcanoChart.cj:228-234`（`volcanoNumber`）、调用点 `f_chart/src/CandlestickChart.cj:74-77`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改边界 / 只改类型名的重复）
- **证据**：静态确定 —— 两个函数逐行对齐：`json.required(field)` → `!(isInt || isDecimal)` 抛 `"期望数字"` → `jsonNumberValue(...)`；唯一差异是 `bulletNumber` 多一段 `number < 0.0` 抛 `"数值不能为负"`。`CandlestickChart` 的 `open/high/low/close` 四个字段全走 `bulletNumber`。
- **描述**：行为差异（是否允许负数）藏在名字里而不是参数里；命名把「子弹图的辅助函数」扩散到蜡烛图，读 `CandlestickChart.cj:74` 时无法判断为什么叫 bullet。
- **建议**：合并为 `chartRequiredNumber(json, field, itemPath, allowNegative: Bool)`（或 `nonNegative!: Bool = true`），放回 `ChartJson.cj`；两个旧函数删除，调用点改用具名参数。

### [轻微][存量] README 把 `InvalidJson` 列为本模块会抛出的类别，但 `Chart.draw` 只接收 `JsonObject`，该类别永远不产生

- **位置**：`f_chart/src/ChartException.cj:22-23`（`InvalidJson` 定义）、`f_chart/src/Chart.cj:35`（`draw(data: JsonObject)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— 承诺源 `f_chart/README.md:41`「输入不合法时抛 `ChartException`，`kind` 区分 `InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`」；缺失证据：`grep -rn "InvalidJson" f_chart/src` 只命中 `ChartException.cj:23,33,43`（定义、`==`、`toString`），模块内没有任何构造点，因为 JSON 文本解析发生在 `f_data`、由调用方完成。
- **描述**：`ChartErrorKind` 是公开枚举（对外契约，**不判死代码**），但文档让使用者以为可以直接接住 `InvalidJson` 做「JSON 语法错误」分支；实际拿到的只会是调用方自己解析 JSON 时抛的异常，两处错误语义不同源。
- **建议**：README 该行补一句「`InvalidJson` 供调用方在解析 `f_data` JSON 文本失败时复用本枚举」；或给 `Chart` 增加一个 `draw(text: String)` 重载，把解析失败映射为 `InvalidJson`。

### [轻微][存量] 画廊测试只断言 `contains("<svg")`，渲染回归（如本轮 Y 轴翻转）无法被捕获

- **位置**：`f_chart/src/ChartGallery_test.cj:31-39`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可测试性）+ §14.1（半成品覆盖）
- **证据**：静态确定 —— `save()` 的全部断言是 `@Assert(svg.contains("<svg"))`，之后直接 `File.writeTo`；107 个 `@TestCase`（与 `:26-27` 注释的「107 个 SVG」一致，实测 `charts/*.svg` 也是 107 个）没有任何几何/元素位置断言。配套的 `CalibrationChart_test.cj:58-63` 也只数 `class="calibration-line"` / `class="calibration-point"` 的个数，因此「Y 轴反向」这类整图镜像在 6 个点的用例里完全测不出。
- **描述**：画廊的角色是「人能打开看」，不是回归防线；一旦有人改 `LinearScale` 参数或 `ChartFrame` 边距，CI 全绿而图已经画反（本轮 `M096` 即为此例）。同时 `save()` 会往仓库工作目录写 107 个文件，测试带副作用。
- **建议**：至少对每张图加一条「关键图元坐标单调性」断言（例如「y 值更大的点其 `cy` 更小」），或对 3–5 张代表图做带容差的关键坐标快照；`save()` 改为写临时目录并按环境变量开关。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下均无改前/改后基线，**不进 `tasks.md`**。

### [堆内存] 日历热力图改「按需聚合 + 复用中间结果」，避免逐格分配

- **现状**：`CalendarHeatmapChart.draw` 为每个自然日分配：一条 `calendar-cell`（`group` + `rect` 两个 SVG 元素对象 + 属性表）、一次 `ChartTime.partsOfDays` 返回的 `Array<Int64>`（`:204`）、一次 `chartFormatTick`/`chartTextWidth` 之外的字符串拼接；`dayList`、`valueList`、`uniqueDays`、`totals` 四个 `ArrayList` 与最终 `toArray()` 副本同时存活到函数结束。
- **方案**：`uniqueDays/totals` 改 `HashMap<Int64, Float64>`（顺带去掉 `:131-146` 与 `:191-196` 的两次线性扫描）；`partsOfDays` 只在「月份可能变化」时调用（当前是每天一次）；`dayList/valueList` 改为在解析循环里直接聚合，不再保留原始数组。
- **预期**：365 天输入下，`uniqueDays/totals` 的扫描从 `365×unique` 降到 365 次哈希查找；`partsOfDays` 调用次数从 365 降到约 12；中间 `Array` 副本少 2 份。具体字节数与耗时降幅待实测。
- **代价**：`HashMap` 迭代顺序不确定，但月份标签只依赖按天递增的遍历顺序，不影响输出确定性（`deterministic` 用例可护住）。
- **验证**：同输入（1 年 / 10 年两档）跑 `cjpm test -O2` 前后对照 `cjprof heap` 与 `getAllocatedHeapSize()`，同时断言 SVG 输出逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sortLiftPoints` 用插入排序处理任意长度的曲线点

- **现状**：`f_chart/src/LiftChart.cj:203-218` 是手写插入排序，最坏 O(n²) 且每次交换都写 `ArrayList` 下标；`CalibrationChart.cj:69` 与 `LiftChart` 都用它排序 `series[0].data`，而该数组长度不受限（JSON 数组大小即输入）。
- **方案**：改用 std 的稳定排序（`sort` 传比较器，按 `[0]` 升序），或在解析阶段就按 x 有序插入（仅在需要时）。
- **预期**：n=10k 时比较次数从约 2.5×10⁷（含 10⁷ 次下标写入）降到 O(n log n)。
- **代价**：需确认 std 排序的稳定性与 null 语义；`sortLiftPoints` 是 `internal` 且被两个图表复用，改名或下沉到 `ChartScale.cj` 时注意命名（`sortLiftPoints` 用在 calibration 上语义不符）。
- **验证**：`cjpm bench -O2` 对 1k / 10k / 100k 点各 5 轮取中位数；同时断言排序结果与旧实现逐元素相同（含 x 相等的稳定性）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 区域/日期去重统一用哈希集合，替代二次扫描

- **现状**：`CartogramChart.cj:83-87` 对每个 `regions[i].id` 线性回扫已收集区域（O(n²)）；`CalendarHeatmapChart.cj:131-146` 同样对 `uniqueDays` 线性回扫。
- **方案**：前者用 `HashSet<String>` 判重（保留原错误消息与 `regions[i].id` 路径），后者并入上面的 `HashMap` 聚合。
- **预期**：n 个区域时判重从 n²/2 次字符串比较降到 n 次哈希；地图区域数通常几十，收益主要在日历热力图与大地图两条路径。
- **代价**：哈希集合多一份 `String` 引用（量级远小于原数组）；`HashSet` 的迭代顺序不会被使用者感知（判重只做存在性判断）。
- **验证**：`cjpm bench -O2`，输入 100 / 1k / 10k 区域；断言重复 id 的错误路径与错误消息完全不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 日历热力图的耗时与内存由 `dayCount` 主导，1 年数据在整图耗时中占绝对多数 | `f_chart/src/CalendarHeatmapChart.cj:183-216` | 1 年 / 10 年两档输入的端到端耗时、峰值 RSS、SVG 字节数 | 固定 JSON、`-O2` 跑 5 轮取中位数；`cjprof heap` + 输出文件大小对照 |
| 2 | `chartTextWidth` 在图例项多、刻度多时被重复计算（`drawLegend` 每项算两次）构成可观自耗时 | `f_chart/src/ChartFrame.cj:142-164` | 自耗时占比 | `cjprof record` 跑 50 个图例项的图，看 `chartTextWidth` self time |
| 3 | 本部分函数内临时对象（`ArrayList`、`StringBuilder`、`Candle`、`ChartConfig` 树）适合 local mode 改造以降峰值内存 | `CandlestickChart.cj:65-87`、`CalendarHeatmapChart.cj:129-146` | 改前改后峰值内存（`getUsedHeapSize()` / RSS）、`getAllocatedLocalObjectSize()` | 需 `--experimental --enable-local-mode`，同输入 `-O2` 对照；注意 std 集合是否有 local 构造重载、`ChartConfig` 会随 `ChartFrame` 存活到函数末尾，逃逸需逐个核对 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/BulletChart_test.cj` | .cj | ✅ | 取 `bulletNumber` 与 `bulletRangeColor` 的语义，见「轻微」重复逻辑条 |
| 2 | `src/CalendarHeatmapAlias_test.cj` | .cj | ✅ | 与 `CalendarHeatmapChart_test` 4 个用例近乎重复（同一 sample），测试准备代码，按 §2 误报边界不单列 |
| 3 | `src/CalendarHeatmapChart.cj` | .cj | ✅ | 见「严重」OOM 条、“轻微”重复逻辑条 |
| 4 | `src/CalendarHeatmapChart_test.cj` | .cj | ✅ | 覆盖 90 格 / 默认区间 / 星期下标 / 颜色分档 / 各类非法输入，无越界断言 |
| 5 | `src/CalibrationChart.cj` | .cj | ✅ | 见「严重」Y 轴翻转、「一般」`binCount` 两条 |
| 6 | `src/CalibrationChart_test.cj` | .cj | ✅ | 只断言元素个数与文本包含，测不出镜像 |
| 7 | `src/CandlestickChart.cj` | .cj | ✅ | `LinearScale` 用法正确（对照证据）；复用 `bulletNumber`；样板重复见「轻微」条 |
| 8 | `src/CandlestickChart_test.cj` | .cj | ✅ | 涨跌/标签数/非法 high、low、缺 close 覆盖完整 |
| 9 | `src/CartogramChart.cj` | .cj | ✅ | id 判重 O(n²)、`colorRange` 校验复制，见「轻微」/优化方案 |
| 10 | `src/CartogramChart_test.cj` | .cj | ✅ | 质心缺省、非法 path/centroid、空 regions 均有覆盖 |
| 11 | `src/Chart.cj` | .cj | ✅ | `public interface Chart`，纯函数契约；`InvalidJson` 语义问题见「轻微」条 |
| 12 | `src/ChartConfig.cj` | .cj | ✅ | `legend.orient` 死配置、「一般」条主证据；padding 未校验 |
| 13 | `src/ChartException.cj` | .cj | ✅ | `ChartErrorKind` 全枚举 + `path` 前缀语义与测试一致 |
| 14 | `src/ChartException_test.cj` | .cj | ✅ | 3 个用例均与 `ChartException.cj:66` 的拼装逻辑一致 |
| 15 | `src/ChartFrame.cj` | .cj | ✅ | `plot` 负宽高、「轻微」样板重复、死 import |
| 16 | `src/ChartGallery_test.cj` | .cj | ✅ | 107 个 `@TestCase` 与注释的 107 个产物一致；断言过弱见「轻微」条 |
| 17 | `src/ChartJson.cj` | .cj | ✅ | 3 个死方法；`pathOf` / `int` / `number` 边界已核对 |
| 18 | `src/ChartScale.cj` | .cj | ✅ | `LinearScale` 方向语义（「严重」条判据）、`chartNiceTicks` 1000 次 guard、`BandScale` 只写字段 |
| 19 | `src/ChartSvgKit.cj` | .cj | ✅ | 所有图元方法在模块内均有调用；`fillOpacity` 只在 `<1` 时写出（语义正确） |
| 20 | `src/ChartTheme.cj` | .cj | ✅ | `colorAt` 负索引、`fontSize` 未校验；默认调色板为只读共享 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单不含 `.md`，README / `doc/**` 仅作 §13/§14 的**承诺源**引用，不计入本部分覆盖统计）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：Y 轴翻转、`plot` 负宽高；设计：`legend` 配置与 `ChartFrame` 职责脱节（orient 解析在 Config、排布逻辑在 Frame 却不读）；语言特性：`Array` 引用语义共享默认调色板已核对为只读、`Option` 均已显式分支；安全性：`path`/文本/颜色均经 `f_svg` 的 `escapeSvgAttribute`/`escapeSvgText`（`f_svg/src/SvgElement.cj:424,705-718`）转义，未发现注入面 |
| §1 死代码 | 6 | 逐个搜过本部分全部 `private`/`internal` 符号与字段：`ChartJson.has/requiredObject/childPath`、`ChartFrame` 的 `ArrayList` import、`BandScale.endPixel/count` 共 6 处无引用；`ChartErrorKind.InvalidJson` 因枚举 `public` 且顶层可达**不判**（只记录，见「轻微」条）；`ChartLegend.orient` 是解析后不使用，记在「一般」条而非死代码 |
| §2 重复逻辑 | 2 | 同文件两两比对 16 个函数体 + 跨文件按错误消息/字面量搜：`colorRange` 校验 6 份、legend/轴宽样板 3 份，各合并为 1 条；`bulletNumber`/`volcanoNumber` 合并为 1 条轻微；`CalendarHeatmapAlias_test` 与 `CalendarHeatmapChart_test` 的相同 sample 按「测试准备代码」误报边界不计 |
| §3 空实现 | 0 | 逐个函数体检查：无空体、无 `TODO`/`FIXME`；`case None => ()` 均对应「可选字段缺省」的正常语义，不是吞异常 |
| §4 栈溢出 | 0 | 本部分 12 个实现文件无递归、无间接递归、无自引用结构遍历（`grep "func "` 44 个函数，调用链均为一层） |
| §5 OOM | 1 | 命中 `CalendarHeatmapChart` 的日期区间无上限（「严重」条）；其余 `stringArray/numberArray` 只按已在内存的 JSON 数组等长物化，未见按报文头预分配或全局只增容器 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，本部分不产生热点结论；日历循环、`chartTextWidth` 重复计算、排序复杂度均写入「待验证假设」与优化方案 |
| §6.2 大粒度锁 | 0 | 本部分 12 个实现文件无 `synchronized` / `Mutex` / 锁对象（`grep` 零命中） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池，全部为同步纯函数调用 |
| §6.4 低效算法 | 3 | 命中 3 处结构性低效（日历两次线性扫描、`sortLiftPoints` 插入排序、cartogram id 二次扫描），因缺输入规模与耗时占比，按规则写入「优化可行性方案 / 待验证假设」而不算「发现」 |
| §7 降堆内存方案 | 1 | 日历热力图聚合与去副本（无基线） |
| §8 降 CPU 方案 | 2 | 排序、哈希去重（均无基线） |
| §9 local mode 可行性 | 0 | 本部分函数内确有大量短生命周期对象，但 `ChartConfig`/`ChartFrame`/`Candle` 为引用类型且随函数存活，std 集合是否有 local 构造重载未逐个核对，且无改前改后峰值数据 → 只进「待验证假设 #3」 |
| §11 现有代码的 BUG（存量） | 2 | 本轮读到的 4 个图表 + 6 个公共设施的边界/空值逐一核对：命中 Y 轴翻转、`plot` 负宽高；另核对 `dayList[0]`（`:76`,`:85`）在空数据下确实被 `:68` 挡住、`points[0]`（`CalibrationChart.cj:71`）被 `:53-55` 挡住、`candleArray[0]`（`CandlestickChart.cj:103`）被 `:62-64` 挡住，均安全 |
| §12 并发安全与锁粒度 | 0 | 全部状态为调用内新建（`ChartConfig`/`ChartTheme`/`ChartPadding`/各 `ArrayList`），唯一跨调用共享的是 `CHART_DEFAULT_PALETTE`（`ChartTheme.cj:18-21`），全模块只有读取、无元素写入，线程安全；`Chart` 实现类无成员字段 |
| §14 功能完备性与 README 覆盖 | 2 | 命中 `binCount` 未实现、`legend.orient`/`position` 接线缺失；本部分 public 声明（`Chart`、`ChartException`、`ChartErrorKind`、`CalendarHeatmapChart`、`CandlestickChart`、`CartogramChart`、`CalibrationChart`）均能在 `README.md` 的图表表（M44/M61/M83/M96）与 `Chart` 接口段落（`:34-60`）中检索到，未发现「public API 完全无文档」 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完；本部分不含 `.md`，§13 仅用外部 README/spec 作承诺源引用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 3 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

这 20 个文件是整个模块的「公共底座 + 4 个中等复杂度图表 + 一个 107 图的画廊」。公共底座（`ChartException`、`ChartJson`、`ChartScale`、`ChartTheme`）实现克制、错误路径统一、`Option` 处理规范，`ChartSvgKit` 把属性拼装收在一处并复用 `f_svg` 的转义，安全面是干净的；死代码与重复逻辑都只有少量演进残留，没有结构性腐化。

阻塞项有两条，都是存量：一是 `calendar-heatmap` 的日期区间完全没有上限，几百字节输入可驱动 365 万次图元生成（服务端渲染场景下即 OOM/长阻塞），需要先加拒绝路径再谈性能；二是 `calibration` 的 Y 轴上下镜像，且同模式在 9 个兄弟图表里复制（本部分只对 `CalibrationChart` 记一条），这是「静默画错」而非「画得不好看」，应优先修，修完必须重新生成 `charts/` 产物人工复核。`binCount` 与 `legend.orient`/`position` 属于「文档承诺、代码未接线」，按 §14 记一般，可与文档修订一起排期。

其余轻微项（死代码、`colorRange` 校验 6 份复制、legend/轴宽样板、共享辅助类的值域校验）可择机清理。性能层面本轮没有 profile 与 bench 数据，所有复杂度类观察（日历线性扫描、插入排序、cartogram 判重）只作为优化方案与待验证假设，不建议在补数据前进入修复清单。存量缺陷本部分共 12 条，是否纳入修复待用户决定。
