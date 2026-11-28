# f_chart 模块审查报告

> **模块第 5/37 部分**：只覆盖 `files/f_chart.part5.txt` 列出的 20 个文件，全部是 `f_chart/doc/spec/add-f-chart-{calendar-alias,calendar-heatmap,calibration,candlestick,cartogram,chord}/` 下的 `.md`（proposal / design / spec delta / tasks）。本部分 0 个 `.cj`、20 个 `.md`；`src/**` 与其余 spec 目录由同模块其他子轮产出。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，`git diff` 为空 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮专项「渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑」。本部分无代码，做法是把每条 requirement / scenario 当契约，逐条到实现与仓库自带样例 SVG 取证（`CalendarHeatmapChart.cj`、`CalibrationChart.cj`、`CandlestickChart.cj`、`CartogramChart.cj`、`ChordChart.cj` 及共享件 `ChartScale` / `ChartFrame` / `ChartTime` / `HeatFlameChart` / `BulletChart`）。
- **报告版本**：v1（第 5/37 部分）

## 发现

### [严重][存量] #1 校准曲线 spec 的轴语义与实现相反：x、y 两轴同时取反，整幅图相对规格旋转 180°

- **位置**：`f_chart/doc/spec/add-f-chart-calibration/specs/chart-rendering/spec.md:16`（对角线「连接左下角与右上角」）、`:30`（轴「默认包含 0 到 1」）；实现 `f_chart/src/CalibrationChart.cj:129-130`（属其他子轮文件）；样例 `f_chart/charts/M096-calibration.svg`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `LinearScale` 的契约写在类注释里：「`topPixel` 对应最大值，`bottomPixel` 对应最小值」（`ChartScale.cj:23`），`scale()` 为 `bottomPixel - (v-min)/span*(bottomPixel-topPixel)`（`ChartScale.cj:38-45`）。正确用法是 x 传 `(plot.right(), plot.x)`、y 传 `(plot.y, plot.bottom())`（`CandlestickChart.cj:145` 即此写法，`plot` 的 `y` 是上边界，见 `ChartFrame.cj:91`）。`CalibrationChart.cj:129-130` 传的却是 `LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())` 与 `LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)`，两个轴同时取反。仓库提交的样例印证：`M096-calibration.svg` 里 y 轴刻度 `0` 在 `y=74px`（顶）、`1` 在 `y=432px`（底）；x 轴刻度 `0` 在 `x=776px`（右）、`1` 在 `x=56px`（左）；首点 `(0.05, 0.08)` 画在 `cx=740.008 cy=102.64`（右上）。
- **描述**：spec 要求对角线「左下—右上」、轴「0 到 1」，实物是 180° 旋转（0 在右上、1 在左下）。因为两端点互换，对角线线段自身仍是同一条，看起来「没问题」；但数据点被转到对角线另一侧：规格里「实际频率 > 预测概率（在对角线上方，说明模型低估）」的点，画出来落在线下方，高估/低估判读整体反过来（`proposal.md:5` 明确这对结论是校准图的用途）。现有用例只数元素个数（`CalibrationChart_test.cj:61-62` 断言 1 条 line、6 个 point），没有任何坐标断言，所以测试全绿。
- **建议**：`CalibrationChart.cj:129-130` 改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)` / `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`，并补一条坐标断言（`(0,0)` 落在 `plot` 左下、`(1,1)` 落在右上）。**归属提示**：修法落在 `src/CalibrationChart.cj`（其他子轮文件），本部分的取证点是 spec 的两行契约与样例 SVG，合并时请只计一次。

### [一般][存量] #2 校准曲线 README 承诺「将预测概率分箱」，design 与实现都说 `binCount` 不参与绘制

- **位置**：`f_chart/doc/spec/add-f-chart-calibration/design.md:5`（「`binCount` 仅做正数校验，不影响绘制（数据已分箱）」）；对照 `f_chart/README.md:2191`、`f_chart/src/CalibrationChart.cj:31-37`、`:56-69`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」、§1「读了不用」
- **证据**：静态确定 —— `binCount` 只在 `CalibrationChart.cj:31-37` 做一次 `value < 1.0 || value != floor(value)` 校验，全文件不再引用；数据点直接来自 `series[0].data` 的 `x`/`y`（`56-69`），随后 `sortLiftPoints` 排序，没有分箱、也没有按箱取均值。README 写「绘制方式：将预测概率分箱，横轴为平均预测值、纵轴为实际正例率」（`2191`）。design 与实现一致，README 与实现相反。
- **描述**：用户按 README 传入未分箱的原始 `(预测概率, 标签)` 并设 `binCount = 10`，期望 10 个箱，实际得到「每个样本一个点」的折线；`binCount` 合法时完全无声。这是「看起来生效、实际不生效」的开关，比缺功能更难发现（图仍能画出来，只是形状与预期不同）。
- **建议**：二选一 —— (a) 按 `binCount` 均分概率区间、箱内取均值（缺省按 sqrt(n) 定箱数）；(b) 保留现状并把 `README.md:2191` 改成「数据须由调用方预先分箱；`binCount` 仅做正数校验，不影响绘制」。

### [一般][存量] #3 日历热力图 spec 的「`date` MUST 为 `YYYY-MM-DD`」只有形态校验，`2026-02-30` 被静默顺延成 `2026-03-02`

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:39`（校验 requirement）；实现 `f_chart/src/ChartTime.cj:27-40`（属其他子轮文件）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「边界校验缺失 / 输入被静默改写」
- **证据**：静态确定 —— `parseDays` 只检查 `bytes.size < 10`、两个 `-` 位置、以及 `month < 1 || month > 12 || day < 1 || day > 31`（`ChartTime.cj:31-37`），随后直接进 `daysFromCivil`（`ChartTime.cj:59-71`），没有月长与闰年校验。按该函数算法复算：`2026-02-30` 的 `doy` 比 `02-28` 多 2 天，等价于 `2026-03-02`；`2026-04-31` 等价于 `2026-05-01`。`CalendarHeatmapChart` 拿天数直接算网格（`CalendarHeatmapChart.cj:56`、`:183-216`），既不报错也不与输入字符串对账。
- **描述**：spec 把「`date` MUST 为 `YYYY-MM-DD`」当校验契约，实现只做到「形如 + 数字在区间内」。两种后果：范围覆盖到被顺延的月份时，`2026-02-30` 的值静默画进 3 月 2 日那格；范围只到 2 月时，报错文案是「日期 2026-03-02 超出 startDate/endDate 范围」（`CalendarHeatmapChart.cj:98`），用户按自己填的 `2026-02-30` 对不上。同一套 `ChartTime.parseDays` 被全部时间轴图复用，影响面不止日历图。
- **建议**：`parseDays` 增加月长校验（用 `partsOfDays(daysFromCivil(y,m,d))` 反算三元组与输入比对，一次整数运算），不合法抛 `chartInvalidValue(path, "日期不存在")`；或在 spec 里明确只做形态校验、月内越界按顺延处理，去掉 `MUST 为 YYYY-MM-DD` 的强表述。

### [一般][存量] #4 日历热力图按天物化且区间无上限：`[startDate, endDate]` 每天都出一个矩形，配置抄错一位即可放大到数十 MB

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:7`（「MUST 为 `[startDate, endDate]` 内的每一天绘制一个 `calendar-cell`」）；实现 `f_chart/src/CalendarHeatmapChart.cj:153-154`、`:183-216`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界物化 / 缺少拒绝路径」
- **证据**：静态确定（规模按代码常量推算）—— `dayCount = endDays - startDays + 1` 完全由两个日期入参决定（`153`），随后 `for (offset in 0..dayCount)` 逐日输出 `rect` + 可能的 `month-label`（`183-216`），全程没有上限、没有分页、没有「区间过大」分支；spec 也没定义上限。日期解析接受 4 位年（`ChartTime.cj:31`），`startDate=0001-01-01`、`endDate=9999-12-31` 合法 ⇒ `dayCount ≈ 3.65e6`。按样例实测密度（`charts/M044-calendar-heatmap.svg`：90 格 / 10747 字节 ≈ 119 字节每格）外推，最终 SVG 约 **430 MB**，`StringBuilder` 扩容峰值再乘 1.5–2 倍。
- **描述**：规模与数据量脱钩、只由配置字符串驱动：`startDate`/`endDate` 打错一位（`2099` 写成 `2999`）就是 36 万格 ≈ 43 MB 输出，而 `draw` 把整份 SVG 拼在内存里返回（`builder.toSvgString()`）。数据只有 6 条也毫无保护作用，正是 §5 里最难被「按数据量压测」发现的一类。当前定级为一般（默认范围取数据 min/max，只有显式给极端区间才触发），但一旦触发就是数百 MB 级的单次分配。
- **建议**：spec 与实现同时加硬上限（如 `dayCount <= 366 * 10`，超出抛 `chartInvalidValue("endDate", "区间过大，最多 N 天")`，N 走 `ChartConfig` 可配）；要支持长区间就改成按月聚合或分页产出多份 SVG，而不是逐日矩形。

### [轻微][存量] #5 蜡烛图 design 写「实体宽度取 `bandWidth * 0.6`」，实现另有 18px 上限

- **位置**：`f_chart/doc/spec/add-f-chart-candlestick/design.md:15`；对照 `f_chart/src/CandlestickChart.cj:166`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 默认值与源码不符」
- **证据**：静态确定 —— 实现是 `let bodyWidth = minFloat(band.bandWidth * 0.6, 18.0)`（`CandlestickChart.cj:166`），design 只写了 `bandWidth * 0.6`。样例 `charts/M083-candlestick.svg` 绘图区宽约 720、4 根蜡烛 ⇒ `bandWidth ≈ 180`、`0.6 × 180 = 108`，实际实体宽度 18。
- **描述**：18px 上限是为「蜡烛很少时别变成大方块」加的，但文档没写；读 design 的人按 0.6 推算会差 6 倍，也无法从规格判断「宽蜡烛」的视觉预期。
- **建议**：design 改为 `min(bandWidth * 0.6, 18px)`；若 18 也打算可调，补进 spec 字段表。

### [轻微][存量] #6 蜡烛图 proposal 声称新增内部 `candlestickRange(items)`，仓库里没有这个符号

- **位置**：`f_chart/doc/spec/add-f-chart-candlestick/proposal.md:12`；对照 `add-f-chart-candlestick/tasks.md:5`、`f_chart/src/CandlestickChart.cj:103-108`、`:196-198`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「指向不存在的结构」
- **证据**：静态确定 —— `grep -rn "candlestickRange" f_chart/src` 无命中；`CandlestickChart.cj` 只有 `candlestickUp`（`196-198`）一个 internal 函数，纵轴范围在 `draw` 内联算（`103-108` 的 `dataMin`/`dataMax`/`span` + 5% 留白）。同变更的 `tasks.md:5` 也只写「`candlestickUp` / `CandlestickChart` 实现并转绿」。
- **描述**：proposal 的 Impact 段承诺两个内部函数，实际落了一个；`tasks.md` 与代码一致，说明是 proposal 写完没回改。归档文本与代码对不上会让后来者去找一个不存在的扩展点。
- **建议**：删掉 `candlestickRange` 那句；或真的补一个 `internal func candlestickRange(candles: Array<Candle>): Array<Float64>` 把 `103-108` 抽出并加单测（能直接测 5% 留白边界）。

### [轻微][存量] #7 同一变更内 `binCount` 的约束自相矛盾：proposal 写「正奇数」，design / spec / 实现是「正整数」

- **位置**：`f_chart/doc/spec/add-f-chart-calibration/proposal.md:11`；对照 `add-f-chart-calibration/design.md:5`、`add-f-chart-calibration/specs/chart-rendering/spec.md:39`、`f_chart/src/CalibrationChart.cj:33-34`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— proposal：「`binCount`（可选，正奇数校验）」；design：「仅做正数校验」；spec：「提供 `binCount` 时 MUST 为正整数」，场景只覆盖 `binCount = 0`；实现 `value < 1.0 || value != floor(value)`，`4` 与 `3` 没有任何区别。
- **描述**：归档四件套对同一字段给了两种约束，读者无法判断偶数是否合法。由于 `binCount` 目前不参与绘制（见 #2），这条矛盾暂时只在文字层，但会直接变成用例分歧。
- **建议**：统一为「正整数」，补一条 `binCount = 2.5` 或 `-1` 的非法场景，别只测 `0`。

### [轻微][存量] #8 变形地图的 `colorRange` 只生效前 3 个颜色，第 4 色起被静默丢弃，spec / design 都没写色数上限

- **位置**：`f_chart/doc/spec/add-f-chart-cartogram/specs/chart-rendering/spec.md:35`、`add-f-chart-cartogram/design.md:23`；对照 `f_chart/src/CartogramChart.cj:119-128`、`f_chart/src/HeatFlameChart.cj:271-272`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「只处理部分输入」、§13「文档未写约束」
- **证据**：静态确定 —— `heatFlameColor` 在 `colors.size >= 3` 时直接 `heatmapColor(value, colors[0], colors[1], colors[2])`（`HeatFlameChart.cj:271-272`），其余元素只被 `SvgColor.tryParse` 校验过（`CartogramChart.cj:119-128`）就再没用到；`size == 2` 走两色插值，`size == 1` 返回单色。spec 与 design 都只要求「至少两个合法颜色」，没有上限或「多余颜色被忽略」的说明。
- **描述**：同一字段名在日历图是 N 档离散映射（`calendarColor` 用 `floor(ratio * size)` 分档，`CalendarHeatmapChart.cj:253-268`），在变形地图是 3 停靠点线性插值。用户给 5 个颜色、期望 5 档业务配色，实际只生效前 3 个且不报错。
- **建议**：spec / design 写明「只支持 2 或 3 个颜色」；实现里对 `size > 3` 抛 `chartInvalidValue`（比静默截断更容易被发现）；要支持 N 色则把插值改成按 `size` 均分的多段。

### [轻微][存量] #9 日历热力图的「校验」requirement 少于实现三条：`series` 数量、`weekStart` 非法值、空数据且无显式范围

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:39`；对照 `f_chart/src/CalendarHeatmapChart.cj:35`、`:68-70`、`:103-106`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「只做了一半的分支」、§13「文档承诺不完整」
- **证据**：静态确定 —— 实现在 `seriesItems.size != 1`（`35`）、`dayList.isEmpty() && (startText.isNone() || endText.isNone())`（`68-70`）、`weekStart != "mon" && != "sun"`（`103-106`）三处都抛 `InvalidValue`；spec 的校验 requirement（`39`）只列 date / value / 范围倒置 / 越界 / colorRange / cellSize / series 缺失 / type 八项，这三条都没写，也没有对应 Scenario。相邻约束只落一半：`series` 缺失写 `MissingField`，`series` 多于 1 个却没写。
- **描述**：spec 是使用者写用例与集成测试的依据；按 spec 写的用例集覆盖不到这三条，实现回归（例如允许 2 个系列后静默只画第一个）不会被契约层发现。
- **建议**：`39` 的 MUST 列表补「`series` MUST 恰好 1 个」「`weekStart` MUST 取 `mon` / `sun`」「未给 `startDate`/`endDate` 时 `data` MUST 非空」，各配一个 Scenario。

### [轻微][存量] #10 `calendar-alias` 的 spec delta 复述 `calendar-heatmap` 的契约，且已出现漂移（`weekday-label` 数量只在 alias 侧有要求）

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-alias/specs/chart-rendering/spec.md:14-22`；对照 `add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:28-39`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（需求复制）」
- **证据**：静态确定 —— alias spec 的「颜色分档」（`14-17`）与 heatmap spec 的「日历颜色分档」（`28-35`）是同一条契约；alias 的「类型不匹配 → `UnsupportedChart`」（`19-22`）是 heatmap 校验 requirement（`39`）里同一句的复述。同时 alias spec 的文档示例（`9-12`）要求「输出 4 个 `weekday-label`」，而 `grep -rn "weekday-label" doc/spec/add-f-chart-calendar-heatmap/` 无命中，heatmap spec 全文没有这个 class；实现固定输出 4 条（`CalendarHeatmapChart.cj:218-233`）。
- **描述**：M106 是「复用 M44」的里程碑，delta 里再声明一遍同样的行为，等于同一契约有两份权威文本；现在已经不同步——星期标签数量的要求只存在于 alias 一侧。改 M44 行为时若只更新 heatmap spec，alias spec 会变成过期契约。样例侧是好的：`cmp charts/M044-calendar-heatmap.svg charts/M106-calendar-heatmap.svg` 无差异（均 10747 字节），确实复用了同一实现。
- **建议**：alias spec 只保留「M106 复用 `CalendarHeatmapChart`，与 M44 同类型同渲染规则」一条，颜色分档 / 类型不匹配 / 标签数量都改成引用 heatmap spec 的路径，避免两份文本各自演化。

### [轻微][存量] #11 蜡烛图四个价格经 `bulletNumber` 解析，被隐式加上「不能为负」；spec 只要求「数字型」

- **位置**：`f_chart/doc/spec/add-f-chart-candlestick/specs/chart-rendering/spec.md:39`；对照 `f_chart/src/CandlestickChart.cj:74-77`、`f_chart/src/BulletChart.cj:234-243`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「契约与实现不符」、§11「语义与命名不符」
- **证据**：静态确定 —— `open`/`high`/`low`/`close` 全由 `bulletNumber` 解析（`CandlestickChart.cj:74-77`），该函数除「必须是数字」外还带 `if (number < 0.0) throw chartInvalidValue(..., "数值不能为负")`（`BulletChart.cj:239-241`）；非负约束来自子弹图自己的规格。蜡烛图 spec 的校验只写「MUST 提供数字型 `open`、`high`、`low`、`close`」。价格区间校验本身与 spec 一致（`CandlestickChart.cj:78-83`）。
- **描述**：负价格/负价差在真实数据里存在（2020-04 WTI 结算价为负，价差与基差序列更是常态）。传 `{"open": -1, ...}` 会在解析阶段抛 `InvalidValue: 数值不能为负`，与 spec 的「数字型即可」相反，用户无法从规格推出这条限制；`CandlestickChart_test.cj` 全为正数，没有覆盖。
- **建议**：改用无符号约束的解析（`volcanoNumber`，`VolcanoChart.cj:228-234`，实践上只校验「数字」），或把 `bulletNumber` 拆成 `requireNumber` + `requireNonNegative`；若确实要禁止负价，就在 spec 校验 requirement 里显式写「四个价格 MUST 为非负数字」。

## 优化可行性方案

本部分只有 `.md`，没有可执行代码，也没有改前 / 改后测量数据，**不提出任何性能或内存方案**。审查中看到的三个复杂度线索（日历图同日求和与逐格查找、逐格拼 SVG 串、和弦图 `findNode` 重复线性查找、校准图插入排序）因缺少自耗时占比，按铁律全部只写进「待验证假设」，不在此处包装成结论。

### [堆内存] 无

- 本部分无 `.cj`；#4 的区间无上限是缺陷（OOM 面），不是「还能更省」的优化项，已计入「发现」。

### [CPU] 无

- 同上。相关代码属其他子轮文件，其收益必须以 `cjprof` / `cjpm bench` 对照为前提，本部分不预置数字。

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 日历图「同日求和」是先线性查重再线性累加（O(U²)），逐格取值又对 `uniqueDays` 线性扫描（O(D·U)）；长区间 + 多数据项时可能成为 `draw` 主耗时 | `f_chart/src/CalendarHeatmapChart.cj:131-146`、`:191-196` | 该段自耗时占 `draw` 的比例及随 D/U 的增长曲线 | `cjprof record` 跑 `startDate=2016-01-01,endDate=2025-12-31`（D≈3653）+ 5000 条数据，再跑 D=365 对照；与 `HashMap<Int64, Float64>` 版本同输入中位数对比 |
| 2 | 逐格拼 SVG 字符串的分配峰值（`StringBuilder` 扩容 + 最终 `toString`）显著大于图元本身，长区间下是 OOM 的先到点 | `f_chart/src/CalendarHeatmapChart.cj:164-216` | `getAllocatedHeapSize()` 峰值与 RSS 峰值 | 同 SDK、`-O2`，跑 365 天与 3653 天两档，记录 `getAllocatedHeapSize()` / `getUsedHeapSize()` / RSS 与输出长度 |
| 3 | 和弦图每次 `draw` 对每条链接再调 3 次 `findNode`（`170`、`171`、`183`），整体 O(L·N) 字符串比较；节点上百、链接上千时占可观比例 | `f_chart/src/ChordChart.cj:107-108`、`:170-183`、`:204-211` | `findNode` 自耗时占比与总调用次数 | `cjprof record` 跑 N=200、L=2000；与「建一次 `HashMap<String, Int64>` 索引」的同输入中位数对比 |
| 4 | 校准图对原始点做插入排序（`sortLiftPoints`，`LiftChart.cj:203-216` 为 `O(n²)` 洗牌式插入），README 又暗示按样本量入图（每次预测一个点），样本上万时排序可能压过绘制 | `f_chart/src/CalibrationChart.cj:69` | 排序段自耗时占比、n=1k/1w/5w 的耗时曲线 | `cjpm bench` 或分段计时，n 取 1k/1w/5w 三档，与稳定排序（`sort` by x）对照 |

## 文件覆盖

> 与 `files/f_chart.part5.txt` 一一对应（该文件 20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-calendar-alias/specs/chart-rendering/spec.md` | .md | ✅ | 90 格 / 3 月标签 / 4 星期标签与实现一致（`dayCount=90`，`CalendarHeatmapChart.cj:153-216`）；与 M44 契约重复见 #10 |
| 2 | `f_chart/doc/spec/add-f-chart-calendar-alias/tasks.md` | .md | ✅ | 6 项全勾选；`CalendarHeatmapAlias_test.cj` 存在；README `M1–M106 全部完成`（`README.md:176`）可对上 |
| 3 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/design.md` | .md | ✅ | 行列公式、`calendarWeekday` 3/4、`calendarColor` 分档、`一/三/五/日` 标签均与实现一致 |
| 4 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/proposal.md` | .md | ✅ | `cellSize` 14、`weekStart` mon、`colorRange` ≥2 与 `CalendarHeatmapChart.cj:103-128` 一致；`partsOfDays` 存在（`ChartTime.cj:48`） |
| 5 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md` | .md | ✅ | 单元格 / 星期 / 颜色三条可对上；校验清单不全见 #9，日期语义见 #3，区间无上限见 #4 |
| 6 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/tasks.md` | .md | ✅ | 4 项勾选，所列函数与文件均存在 |
| 7 | `f_chart/doc/spec/add-f-chart-calibration/design.md` | .md | ✅ | 轴缺省 `[min(0,min),max(1,max)]`、2px 折线 / 3.5px 点、`#9e9e9e` 虚线（`CalibrationChart.cj:145-185`）一致；`binCount` 不分箱说明与实现一致、与 README 冲突（#2） |
| 8 | `f_chart/doc/spec/add-f-chart-calibration/proposal.md` | .md | ✅ | class 名与实现一致；`binCount` 写「正奇数」与 spec / 实现冲突（#7） |
| 9 | `f_chart/doc/spec/add-f-chart-calibration/specs/chart-rendering/spec.md` | .md | ✅ | 折线 / 点 / 对角线数量可对上；轴方向与实物相反（#1） |
| 10 | `f_chart/doc/spec/add-f-chart-calibration/tasks.md` | .md | ✅ | 4 项勾选，文件均存在；「全量测试通过」无法静态复核 |
| 11 | `f_chart/doc/spec/add-f-chart-candlestick/design.md` | .md | ✅ | 校验、轴、影线、涨跌配色（`#e53935`/`#43a047`，5% 留白）与实现一致；实体宽度漏 18px 上限（#5） |
| 12 | `f_chart/doc/spec/add-f-chart-candlestick/proposal.md` | .md | ✅ | class 名与实现一致；`candlestickRange` 不存在（#6） |
| 13 | `f_chart/doc/spec/add-f-chart-candlestick/specs/chart-rendering/spec.md` | .md | ✅ | 影线 / 实体 / 涨跌 / 范围 / 校验均可对上；负价约束缺失见 #11 |
| 14 | `f_chart/doc/spec/add-f-chart-candlestick/tasks.md` | .md | ✅ | 4 项勾选，`candlestickUp` + 图类与代码一致 |
| 15 | `f_chart/doc/spec/add-f-chart-cartogram/design.md` | .md | ✅ | `cartogramScale` 两条分支（`CartogramChart.cj:173-189`）、transform 三段式（`156-158`）逐字一致；配色色数上限缺失（#8） |
| 16 | `f_chart/doc/spec/add-f-chart-cartogram/proposal.md` | .md | ✅ | `scaleBy` 默认 sqrt、默认蓝色梯度、class 名与实现一致 |
| 17 | `f_chart/doc/spec/add-f-chart-cartogram/specs/chart-rendering/spec.md` | .md | ✅ | 「最大值返回 1」成立；`path` 至少两点由 `pathCentroid` 兜住（`ChoroplethChart.cj:204-206` 要求 ≥4 个数字）；色数上限见 #8 |
| 18 | `f_chart/doc/spec/add-f-chart-cartogram/tasks.md` | .md | ✅ | 4 项勾选，`cartogramScale` 存在且被生产代码调用（`CartogramChart.cj:154`） |
| 19 | `f_chart/doc/spec/add-f-chart-chord/design.md` | .md | ✅ | 角度分配（`ChordChart.cj:126-144`）、14px 描边（`165`）、`chordWidth` 曲线（`184`）、透明度 0.35（`185`）、标签外移 16px（`190-191`）一致；实现另有 `total > 0` / `padAngle` 上限校验，design 未提（摘要性质，不判） |
| 20 | `f_chart/doc/spec/add-f-chart-chord/proposal.md` | .md | ✅ | 默认 `padAngle` 0.02 / `showLabels` false、三个 class 名与实现一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

**范围外提示**（一句，不计入本部分统计）：与 #1 同一写法（`LinearScale` 两轴像素参数颠倒、整图 180° 旋转）的还有 `GainChart.cj:125-126`、`EcdfChart.cj:144-145`、`BlandAltmanChart.cj:148-149`、`LassoPathChart.cj:156-157`，建议并入对应子轮复核。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4（归属见下，不重复计数） | 正确性：#1（轴方向）、#3（日期语义）、#4（区间规模）；设计：#10（同一契约两份文本）。语言特性 / 可读性 / 安全性未命中：本部分无代码，无值-引用语义与注入面可核；六份文档结构（Why → What Changes → Capabilities → Impact）一致 |
| §1 死代码 | 0 | 本部分无 `.cj`。文档点名的内部符号逐个搜定义，全部存在且被生产代码引用：`ChartTime.partsOfDays`（`ChartTime.cj:48`）、`calendarWeekday` / `calendarColor`（`CalendarHeatmapChart.cj:239`、`253`）、`candlestickUp`（`CandlestickChart.cj:196`）、`cartogramScale`（`CartogramChart.cj:173`）、`chordArcPath` / `chordWidth`（`ChordChart.cj:215`、`233`）。唯一不存在的 `candlestickRange` 按 §13 记入 #6（文档指向不存在符号，不是源码死代码） |
| §2 重复逻辑 | 1 | #10（alias spec 复述 heatmap spec 的颜色分档 / 类型不匹配，且已漂移）。另逐一比对了 `ChartTime.parseDays` 在各图的复用方式：属共享工具复用，不是复制实现，不判 |
| §3 空实现 | 0 | 无函数体可查。最接近的是 `binCount` 只校验不生效，按「承诺未实现 / 读了不用」归入 #2（§14），避免同一根因两处计数 |
| §4 栈溢出 | 0 | 文档描述的渲染路径全是迭代（日历图 `for (offset in 0..dayCount)`、和弦图 `for (node in nodes)` / `for (link in links)`、变形地图 `for (region in regions)`），无递归、无自引用结构；`daysFromCivil` / `civilFromDays` 为常数深度整数运算 |
| §5 OOM | 1 | #4（日历图按天物化、区间无上限）。其余四图的规模都受输入项数约束（`data` / `regions` / `nodes` / `links` 长度）且先做非空校验，未发现与数据量脱钩的放大面 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，任何热点结论不成立；四个候选写进「待验证假设」#1–#4，不进统计 |
| §6.2 大粒度锁 | 0 | 本部分无代码；被审文档对应的 `draw` 全为单次调用的纯计算，无锁、无临界区可评 |
| §6.3 并发串行 | 0 | 无 `spawn`、无任务提交；文档也未承诺并行渲染 |
| §6.4 低效算法 | 0 | 读到三处复杂度可判的写法（日历图 O(U²)/O(D·U)、和弦图 O(L·N)、校准图插入排序 O(n²)），复杂度静态可判但缺耗时占比，按 §6.1 要求降级为「待验证假设」#1/#3/#4，不单列缺陷 |
| §7 降堆内存方案 | 0 | 无代码、无基线；#4 属缺陷（上限缺失），不是「还能更省」，已在「发现」计数 |
| §8 降 CPU 方案 | 0 | 同上；相关实现属其他子轮文件，无基线不出方案 |
| §9 local mode 可行性 | 0 | 本部分无函数可改造；日历图逐日临时对象、和弦图角度分配虽短生命周期，但无逃逸分析与峰值内存对照，只能留待有数据的轮次 |
| §11 现有代码的 BUG（存量） | 1 | #1（校准曲线轴方向反转，判据「契约与实现不符」）。#3 的根因在 `ChartTime`，按「spec 承诺 vs 实现」归到 §13 统计，不重复计入 |
| §12 并发安全与锁粒度 | 0 | 被审文档对应的 `draw` 状态全在局部（`ChordNode.total` / `angle`、`CartogramRegion` 均为 `draw` 内新建），无共享可变状态；文档也未声明线程安全契约 |
| §13 文档一致性 | 5 | #3（`date` 语义）、#5（18px 上限）、#6（`candlestickRange` 不存在）、#7（正奇数 vs 正整数）、#11（负价约束）。反向核对通过的项：日历图 `row/week` 公式与 `calendarWeekday` mon=3 / sun=4、`calendarColor` 端点；校准图 `[min(0,min),max(1,max)]`、2px/3.5px/`#9e9e9e` 虚线；蜡烛图 5% 留白、`close >= open`、`#e53935`/`#43a047`；变形地图 `sqrt(100/400)=0.5`、transform 三段式、默认三色；和弦图 `padAngle/2`、14px、`chordWidth`、16px |
| §14 功能完备性与 README 覆盖 | 3 | #2（README 承诺分箱、实现未分箱）、#8（变形地图静默丢弃第 4 色起）、#9（日历图校验清单少于实现）。六份 tasks 的勾选项在代码/文档里都能找到产物；README 的 M44 / M106 条目（`README.md:111`、`174`、`2819-2824`）与 `M1–M106` 收尾声明（`176`）已核对 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`files/f_chart.part5.txt` 20 行与本表逐行对应 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分 20 份文件是 6 个变更（日历图、日历别名、校准曲线、蜡烛图、变形地图、和弦图）的归档四件套。**归档质量整体不错**：六份 design 的算法描述（网格行列公式、sqrt 缩放、`padAngle/2` 间隙、`chordWidth` 曲线、5% 留白、transform 三段式）与实现逐条对得上，`tasks.md` 的红绿流程也说明这些图是按 TDD 落地的；样例 `charts/M044` / `M106` 字节级相同，印证「M106 复用 M44」。

风险集中在三处：

- **阻塞项 #1**：校准曲线的 x、y 两轴同时取反，实际输出相对 spec 的「左下—右上」语义旋转 180°，把「高估 / 低估」的解读整个反过来；样例 SVG 的刻度与首点坐标是最硬的证据，而用例只数元素个数所以全绿。同一写法在 `Gain` / `Ecdf` / `BlandAltman` / `LassoPath` 四个图上重复出现，建议作为一轮独立的「数值轴方向」专项修，每图补坐标断言。
- **契约类 #2 / #3 / #4**：`binCount` 只校验不生效而 README 承诺分箱；日期只做形态校验，`2026-02-30` 静默变成 3 月 2 日；日历图区间无上限，配置抄错一位就能把 SVG 撑到几十上百 MB。三条都会让用户拿到与预期不同的结果，或直接放大内存占用。
- **归档漂移 #5–#11**：未文档化的 18px 上限、`candlestickRange` 不存在、`binCount` 两种约束、`colorRange` 色数上限缺失、校验清单漏项、alias spec 双份契约、蜡烛图隐式禁负价。单条都很轻，但都是「按文档做会踩到实现」的类型，适合一次性清理。

本部分没有任何 `.cj`，图表渲染算法本身的正确性、OOM 实测、死代码与重复实现、并发安全**只在「文档 vs 实现」这一侧取证**，不能据此对模块整体下结论；`src/**` 的判定由其余子轮负责。存量缺陷共 11 条（严重 1 / 一般 3 / 轻微 7），是否纳入修复待用户决定；本报告只读文件，未做任何修改。
