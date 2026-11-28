# f_chart 模块审查报告

> **模块第 16/37 部分**（只覆盖 `files/f_chart.part16.txt` 列出的 20 个 `.md`：`paired-line` / `parallel` / `pareto` / `pdp` / `percent-bar` / `percent-stacked-bar` 六个特性的 proposal / design / spec / tasks。这六个规格描述的 6 个实现文件（`PairedLineChart.cj`、`ParallelCoordinatesChart.cj`、`ParetoChart.cj`、`PdpChart.cj`、`PercentBarChart.cj`、`PercentStackedBarChart.cj`，以及共用的 `BarRenderer.cj` / `ChartFrame.cj` / `ChartScale.cj` / `ChartConfig.cj`）是为核对 §13 一致性读的**证据**，不计入本部分文件统计。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（模块共 251 个 `.cj` + 444 个 `.md`；本部分 0 个 `.cj` + 20 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分没有代码文件，因此执行方式是：**把六个规格当验收口径，逐条回到实现取证**（class 名 / 校验错误类型 / 归一化公式 / 坐标换算 / 留白比例），再对涉及的实现片段做 §1 死代码、§2 重复逻辑的机械检查。
- **报告版本**：v1（第 16/37 部分）

## 发现

### [严重][存量] #1 PDP 的 Y 轴被上下画反：预测值越大越靠下

- **位置**：`f_chart/src/PdpChart.cj:133`（`let yScale = LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)`）
- **来源**：存量（快照模式无基线；`git blame` 不可用的前提下按范围界定文件的约定记存量）
- **判据**：review-checklist §11「契约与实现不符」+ §10「正确性」（坐标换算方向）
- **证据**：静态确定 —— `LinearScale.init(minValue, maxValue, topPixel, bottomPixel)` 的注释写明「`topPixel` 对应最大值，`bottomPixel` 对应最小值」（`f_chart/src/ChartScale.cj:22`），`scale(v) = bottomPixel - (v-min)/span*(bottomPixel-topPixel)`（`ChartScale.cj:41`）。PDP 把 `plot.bottom()` 传成 `topPixel`、`plot.y` 传成 `bottomPixel`，于是 `scale(yMax)` 落在 `plot.bottom()`、`scale(yMin)` 落在 `plot.y`，Y 轴自下而上递减。同模块 `yScale = LinearScale(..., plot.y, plot.bottom())` 的正确写法有 36 处（如 `f_chart/src/LineChart.cj:178`、`f_chart/src/ParetoChart.cj:122`），反序写法只有 10 处（`PdpChart` 以及 `VolcanoChart` / `LiftChart` / `EcdfChart` / `GainChart` / `CalibrationChart` / `BlandAltmanChart` / `LassoPathChart` / `LearningCurveChart` / `ManhattanChart`，均属范围外）。`frame.drawYAxis` 用同一个 `scale` 定位刻度文本（`ChartFrame.cj:172`），所以刻度与折线一起翻转。
- **描述**：PDP 曲线的语义是「特征取值 → 预测均值」，读者靠曲线上升/下降判断边际效应方向。当前实现把 y 轴整体镜像：预测值 0.62 画在底部、0.12 画在顶部，刻度文本也自顶向下递减，等于把「随年龄上升」画成「随年龄下降」。`PdpChart_test.cj` 只统计 `class="pdp-line"` / `pdp-point` 的个数与文本，没有任何坐标断言（`PdpChart_test.cj:60-80`），所以测试全绿。
- **建议**：改为 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`；同时给 `LinearScale` 增加 `static func vertical(min, max, top, bottom)` 之类的具名构造，把「第一个像素参数是最大值所在像素」固化下来，避免再次按直觉传参。补一条断言「x 递增时首点 y > 末点 y（对上升数据）」的用例。

### [一般][存量] #2 平行坐标：单侧显式范围 + 数据整体越界时误抛 `InvalidValue`，与自身「钳制到 [0,1]」的契约冲突

- **位置**：`f_chart/src/ParallelCoordinatesChart.cj:144-171`（范围解析），触发点在 `152-167`
- **来源**：存量
- **判据**：review-checklist §11「边界 / 契约与实现不符」；规格见 `doc/spec/add-f-chart-parallel/specs/chart-rendering/spec.md:23-25`（「`parallelNormalize` MUST … 钳制到 `[0,1]`」）
- **证据**：静态确定 —— 缺省侧用数据极值补齐（`144-151`），随后只要 `explicitMax <= explicitMin` 且**不是两侧都显式**（`153`），就走 `159-167`：`explicitMax == explicitMin` 才扩边，否则抛「维度范围必须递增」。构造输入 `dimensions:[{name:"A", max:10}]` + 某行 `[20]`：`explicitMin = 20`、`explicitMax = 10`，两个 `isSome()` 不成立、`20 != 10` ⇒ 抛 `InvalidValue`。对称地只给 `min:10` 而数据全为 1 时同样抛错。
- **描述**：`parallelNormalize` 明确设计成越界值钳到 0/1（`ParallelCoordinatesChart.cj:271-283`，测试 `ParallelCoordinatesChart_test.cj:66-71` 也断言 `-5 → 0`、`15 → 1`），说明「数据可以落在显式范围之外」是被接受的语义；但范围解析阶段会把这种正常输入整图拒绝。用户只固定上界（常见：`max` 取业务上限）而样本恰好全部超限时，拿不到钳制后的图，只能先自己裁剪数据。同一分支还有一个更隐蔽的变体：只给 `min: 5`、数据全为 5 时 `explicitMax == explicitMin` 成立，走 `159-161` 把范围改成 4.5–5.5——显式给的 `min: 5` 被静默改写，用户指定的边界值直接丢失。
- **建议**：只有「两侧都显式且 `max <= min`」才抛 `InvalidValue`；单侧显式时用该侧值 + 数据另一侧极值组成范围（越界交给 `parallelNormalize` 钳制），即把 `152-167` 改成 `if (bothExplicit && max <= min) throw; if (explicitMax == explicitMin) 扩边`。补一条「只给 max、数据全部超限仍能出图」的用例。

### [一般][存量] #3 画布只有「宽高 > 0」校验，平行坐标硬编码边距在窄画布上把绘图区算成负数

- **位置**：`f_chart/src/ChartConfig.cj:180-184`（仅 `width/height <= 0` 报错）；`f_chart/src/ParallelCoordinatesChart.cj:194-202`（固定 `+60 / -20 / +64 / -40` 边距）
- **来源**：存量
- **判据**：review-checklist §11「边界」+ §10「正确性」（坐标与边界）
- **证据**：静态确定 —— `width = 100`、默认 `padding = 24` 时：`left = 24 + 60 = 84`、`right = 100 - 24 - 20 = 56` ⇒ `step = (right - left)/(n-1)` 为负（`198-202`），维度轴自右向左排；`height = 100` 时 `top = 88`、`bottom = 36` ⇒ `bottom < top`。`ChartConfig.parse` 只要求 `> 0`（`ChartConfig.cj:182`），`ChartFrame` 侧同样只做减法（`ChartFrame.cj:91`），也没有 `plot.width > 0` 断言。
- **描述**：画布尺寸来自 JSON（`width` / `height` 用户可传），`width < 128` 或 `height < 152`（默认 `padding = 24` 时）就能构造出负宽/负高绘图区：轴方向反转、`left/right` 互换后 `x` 坐标全错，但既不报错也不抛异常，输出一张语义错误的 SVG。嵌入式小卡片（如 96×96 缩略图）很容易踩到。
- **建议**：在 `ChartConfig.parse` 里加最小可用尺寸（如 `width >= 160 && height >= 120`，或按 `padding.left + padding.right + 最小绘图区宽` 校验）并抛 `InvalidValue`；平行坐标改用 `ChartFrame.plot` 矩形而不是自己减常量，并在算完 `plot` 后断言宽高为正。

### [一般][存量] #4 `percent-bar` 规格写「`yAxis.max` MUST 固定为 100」，设计与实现都允许显式覆盖

- **位置**：规格 `doc/spec/add-f-chart-percent-bar/specs/chart-rendering/spec.md:16`；实现 `f_chart/src/BarRenderer.cj:379-391`（`resolvePercentRange`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移 / 文档承诺与实现相反」
- **证据**：静态确定 —— 实现 `let maximum = match (axis.max) { case Some(value) => value; case None => 100.0 }`（`BarRenderer.cj:384-387`），即显式 `yAxis.max` 优先；同一变更的 `design.md:9`（「`resolvePercentRange` 返回 `[0, 100]`，除非显式 `min` / `max`」）与 `proposal.md:11`（「显式 `yAxis.min/max` 可覆盖」）都与规格的 MUST 相反。`PercentBarChart_test.cj` 没有任何关于 y 轴范围的断言（`PercentBarChart_test.cj:53-114`）。
- **描述**：规格是对外验收口径。下游若照规格实现（例如测试断言「百分比条 y 轴恒为 0–100」），一旦数据里带 `yAxis.max: 200`，实际输出是 0–200 的轴，各段占比被压到一半高度，「100% 横条」的前提不成立；同一变更包内两份文档互相矛盾，读者无法判断哪个是契约。
- **建议**：二选一并同步三处 —— 要么把规格改成「缺省 0–100，显式 `min`/`max` 可覆盖，此时百分比语义由调用方负责」，要么让 `resolvePercentRange` 忽略 `axis.min/max`（或对显式值抛 `InvalidValue`）。补一条「不给 yAxis → 轴上限 100」的用例把契约钉住。

### [一般][存量] #5 PDP 规格同时要求「轴 MUST 覆盖全部数据」与「显式 min/max MUST 按给定值」，实现按后者且全链路无裁剪

- **位置**：规格 `doc/spec/add-f-chart-pdp/specs/chart-rendering/spec.md:23-30`；实现 `f_chart/src/PdpChart.cj:82-103`（取值）与 `156-180`（画线/画点）
- **来源**：存量
- **判据**：review-checklist §13「规格自洽性」+ §11「缺少边界处理」
- **证据**：静态确定 —— 两条 MUST 在「显式范围不覆盖数据」时不可能同时成立；实现选择后者（`Some(value) => value`，`82-97`），`LinearScale.scale` 对域外值线性外推（`ChartScale.cj:41`，无 clamp），`kit.path` / `kit.circle` 也没有任何裁剪（`f_chart/src/` 内 `grep clipPath/clip-path` 零命中）。例：`xAxis.min = 30` 而首点 `x = 20`，该点 x 像素落在 `plot.x` 左侧，画在 y 轴刻度文字上，折线穿出绘图区。
- **描述**：规格把「覆盖全部数据」写成无条件 MUST，用户按规格给 `min/max` 收紧视野时，越界点不会被裁掉而是溢到坐标轴外，SVG 观感错乱；同时「覆盖全部数据」这条验收项在显式范围下永远无法满足，属于不可实现的承诺。
- **建议**：规格改成「未给 `min`/`max` 时轴范围覆盖全部数据并留 3% / 8% 余量；给出时以显式值为准，域外数据点裁剪到绘图区（或按 `clamp` 落在边界上）」。实现侧若选裁剪，可在 `SvgBuilder` 分组上补 `clip-path`（需 `f_svg` 支持），否则在 `scale` 后钳制到 `[plot.y, plot.bottom()]`。

### [轻微][存量] #6 帕累托的「总和必须大于 0」守卫是死代码，且与 `paretoCumulative` 内的同条件校验重复

- **位置**：`f_chart/src/ParetoChart.cj:91-93`（`if (maxValue <= 0.0) { throw … }`）；`maxValue` 在 `87-90` 求出，上一行 `84` 已调用 `paretoCumulative`
- **来源**：存量
- **判据**：review-checklist §1「恒假分支 / 不可达语句」+ §2「重复逻辑（同一错误文案）」
- **证据**：静态确定 —— 值在 `60-62` 已校验 `value < 0.0` 即抛错，故 `sortedValues` 全部 ≥ 0，于是 `Σ = 0 ⟺ max = 0`；`paretoCumulative` 在 `225-227` 对 `total <= 0.0` 抛出与 `92` 完全相同的 `chartInvalidValue("series[0].data", "总和必须大于 0")`，且它在 `84` 行就已执行 ⇒ `91` 的条件永不为真。
- **描述**：重复守卫让读者以为「`paretoCumulative` 可能不校验」，也掩盖了「全零输入在哪一行失败」；后续若把累计函数改成允许全零（返回全 0），`91-93` 会突然变成唯一守卫，语义随改动漂移。
- **建议**：删掉 `91-93` 的 `if` 分支（保留 `87-90` 求 `maxValue`，`:94` 的 `resolveYRange` 还要用），让「总和必须大于 0」只在 `paretoCumulative` 内维护；或反过来让 `paretoCumulative` 只算数、由 `draw` 统一校验一次。

### [轻微][存量] #7 帕累托右轴刻度手写，未复用 `ChartFrame.drawYAxisRight`，导致右轴无刻度线、`labelFormat` 不生效

- **位置**：`f_chart/src/ParetoChart.cj:171-179`；可复用实现 `f_chart/src/ChartFrame.cj:245-276`
- **来源**：存量
- **判据**：review-checklist §2「重复逻辑（框架已有同一能力，调用点又写一遍）」
- **证据**：静态确定 —— `ChartFrame` 已提供 `drawYAxisRight(kit, ticks, scale, axis)`：画刻度短线（`249-252`）、刻度文本（`253-259`）、右轴线（`262-265`）、轴标题（`266-275`），文本走 `chartFormatTick(tick, axis.labelFormat)`；帕累托在 `171-179` 内联 `for (tick in [0.0, 20.0, … 100.0])` 只画 `percent-label` 文本，没有刻度线与右轴线，也不读 `labelFormat`。`rightLabelWidth: 42.0`（`119`）是为这段内联代码留的，与 `drawYAxisRight` 的 `plot.right() + 8` 布局不同。
- **描述**：两条右轴代码并存 ⇒ 视觉不一致（帕累托右轴「悬空」）、次级刻度不可配置（`tickCount` / `labelFormat` 对右轴无效）；后续改右轴样式要改两处。
- **建议**：用 `frame.drawYAxisRight(kit, chartNiceTicks(0.0, 100.0, config.yAxis.tickCount), percentScale, config.yAxis)` 替换 `171-179`，并把 `rightLabelWidth` 统一成 `maxPercentLabelWidth + 12`。

### [轻微][存量] #8 轴范围校验与手写排序在多处重复：51 处同文案校验、10+ 处同形插入排序、平行坐标 x 坐标表达式两处

- **位置**：轴校验 —— `f_chart/src/PairedLineChart.cj:103-105`、`f_chart/src/ParetoChart.cj:194-196`、`f_chart/src/PdpChart.cj:98-103`、`f_chart/src/BarRenderer.cj:388-390` 与 `417-421`（模块内 `grep "必须小于"` 共 52 行，其中 51 行是 `xAxis/yAxis.min 必须小于 …max`，另 1 行是 `GaugeChart` 的 `startAngle/endAngle`）；排序 —— `f_chart/src/ParetoChart.cj:207-215` 与 `f_chart/src/LiftChart.cj:203-217`（模块内 `var j = i` 同形插入排序 10+ 处）；x 坐标 —— `f_chart/src/ParallelCoordinatesChart.cj:204-208` 与 `245-249`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制 / 换控制流」
- **证据**：静态确定 —— 轴校验是完全相同的「`if (maximum <= minimum) throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")`」，只是参数名在 `xAxis` / `yAxis` 间切换；`paretoOrder` 与 `sortLiftPoints` 是同一段插入排序，仅比较字段（`values[order[j]]` vs `sorted[j][0]`）和方向（`>` vs `<`）不同；平行坐标里 `let x = if (dimensionCount == 1) {(left+right)/2.0} else {left + Float64(index) * step}` 在轴循环与折线循环各写一遍。
- **描述**：51 份同文案校验意味着轴错误语义有 51 个独立演化点（改文案或改判定要改 51 处，漏改就出现同类输入不同报错）；插入排序是 O(n²) 且各自维护，`paretoOrder` 的稳定性/降序语义与 `sortLiftPoints` 的升序语义靠人记；平行坐标重复表达式一旦有一处改了（例如改成按 `plot` 矩形算），另一处就会错位。
- **建议**：把范围解析收进 `ChartAxis`（`resolve(min, max, padRatio)` 返回 `[min, max]` 并统一抛错）；排序抽一个 `stableSortIndices` 工具或改用标准库排序（`std.sort` 的可用签名以本地文档为准）；平行坐标先把 `xs: Array<Float64>` 预计算一次，轴与折线共用。

### [轻微][存量] #9 配对连线的图例只有一种颜色，图元却按受试者逐项换色

- **位置**：`f_chart/src/PairedLineChart.cj:143-149`（`legendColors = [config.theme.colorAt(0)]`）对照 `156-164`（`colorAt(index)`）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 语义一致性」
- **证据**：静态确定 —— 图例只注册 `[seriesName]` 与 `[colorAt(0)]`（`143-149`），连线/圆点/标签逐项用 `config.theme.colorAt(index)`（`156`、`163-164`），`colorAt` 按调色板取模（`ChartTheme.cj:54-59`），因此 4 个受试者会有 4 种颜色，图例标记恒为调色板第一色。
- **描述**：图例颜色与任何一条线都对不上，读者会以为「图例色 = 某条特定曲线」，实践中经常被当成 bug 反馈；而这项颜色语义在规格里没有约束，属于实现自定的表现。
- **建议**：二选一 —— 图例按受试者逐项列出（姓名 + `colorAt(i)`），或所有连线统一 `colorAt(0)`、让图例真正代表系列色。

### [轻微][存量] #10 平行坐标：最大值刻度画在维度名之上（间距 16px），最右维度名与刻度超出画布被裁

- **位置**：`f_chart/src/ParallelCoordinatesChart.cj:213-233`（维度名 `y = top - 10`，最大值 `y = top - 26`）；右边距 `195`（`right = width - padding.right - 20.0`）
- **来源**：存量
- **判据**：review-checklist §10「可读性」+ §11「边界」（坐标与边界）
- **证据**：静态确定 —— 同一个 `x`、`anchor: "middle"` 下，`dimension-label` 基线在 `top - 10`（`213-219`），最大值 `dimension-tick` 基线在 `top - 26`（`227-233`），默认 `fontSize = 12`（`ChartTheme.cj:28`）时两者只隔 16px，且 `ChartSvgKit.text` 统一用 `dominant-baseline: middle`（`ChartSvgKit.cj:111`），即两行中心相距 16px，`theme.fontSize` 超过 16 就重叠，且「最大值」排在维度名上方，读起来像维度名属于下一条轴。最右轴 `x = width - padding.right - 20`，名称与刻度居中后向右伸出 `textWidth/2`，4 个汉字（48px）就超出 20px 右边距，被 `viewBox` 裁掉。
- **描述**：轴头信息层级倒置 + 右端文本溢出，是纯坐标常量问题（左侧留 60、右侧只留 20），在默认 4 维度示例下不显现，换成 `["温度","湿度","气压","风速","降水量"]` 这类长名称或多维度时就会裁字。
- **建议**：维度名放 `top - 26`、最大值放 `top - 8`（或把最大值放进绘图区顶部）；`right` 改为 `width - padding.right - max(20, 最右维度名宽 / 2)`，`left` 同理按最左名称宽度预留。

### [轻微][存量] #11 四个实现文件里的 `import std.math.*` 未被使用

- **位置**：`f_chart/src/PairedLineChart.cj:19`、`f_chart/src/ParetoChart.cj:19`、`f_chart/src/PdpChart.cj:19`、`f_chart/src/ParallelCoordinatesChart.cj:19`
- **来源**：存量
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 四个文件内 `abs(` / `floor(` / `ceil(` / `pow(` / `log10(` / `sqrt(` / `isNaN` / `isInf` 全部零命中；用到的 `minFloat` / `maxFloat` 是本包自建函数（`f_chart/src/BarRenderer.cj:454-468`），`formatSvgNumber` 来自 `fountain::f_svg`（各自文件 `:21` 单独 import）。
- **描述**：多余的 wildcard import 让「这文件用了哪些数学能力」失去信号，也让模块级依赖图看起来比实际宽；不影响运行。
- **建议**：删除这 4 行（若后续用到再按需 `import std.math.{abs, ...}`）。

### [轻微][存量] #12 `percent-bar` 任务清单声称测试覆盖「归一化」，实际测试没有任何归一化 / 固定 100 轴断言

- **位置**：`doc/spec/add-f-chart-percent-bar/tasks.md:3`（「写 `PercentBarChart_test.cj`（柱数、图例、归一化、校验）」）对照 `f_chart/src/PercentBarChart_test.cj:53-114`
- **来源**：存量
- **判据**：review-checklist §14「承诺了但没实现 / 半成品」（任务清单已勾选，承诺的覆盖不存在）
- **证据**：静态确定 —— 测试只有 5 个用例：`class="bar"` 计数 12（`54-57`）、三条图例文本（`59-66`）、类目标签（`69-74`）、type 不匹配（`77-94`）、系列长度不一致（`97-114`）。没有任何用例断言「同类目三段高度和等于绘图区高」「y 轴上限是 100」或「负数按 abs 归一化」，而这两点正是 `percent-stacked-bar` / `percent-bar` 与普通堆叠柱的唯一差别（`BarRenderer.cj:163-200`）。
- **描述**：任务清单已勾选，`percent-bar` 的核心语义（归一化到 100%）实际处于无测试状态；`resolvePercentRange`（`private`，`BarRenderer.cj:379`）与 `percentStackedValue`（`internal`，`BarRenderer.cj:441-447`）本可直接单测，也没有覆盖。若归一化公式被改错（例如漏 `abs`、除以未取模的和），现有测试照样全绿。
- **建议**：补两条用例 —— (a) 直接断言 `percentStackedValue(3.0, 12.0) == 25.0` 与 `(-3.0, 12.0) == 25.0`；(b) 对 4×3 示例断言四个类目各自的段高之和等于 `plot` 高（可用 rect 的 `height` 求和或对比 y 轴上限 100）。

### [轻微][存量] #13 平行坐标 design 说「相等就扩边」，spec 说「显式 min == max 抛错」，实现按 spec

- **位置**：`doc/spec/add-f-chart-parallel/design.md:5-6`（「若仍相等，min -= 0.5、max += 0.5」）对照 `doc/spec/add-f-chart-parallel/specs/chart-rendering/spec.md:41-44`（「某维度 `min` 等于 `max` → `InvalidValue`」）与 `f_chart/src/ParallelCoordinatesChart.cj:152-158`
- **来源**：存量
- **判据**：review-checklist §13「规格自洽性」
- **证据**：待确认 —— 实现与 spec、测试（`ParallelCoordinatesChart_test.cj:110-124` 断言双显式 `min=5,max=5` 抛 `InvalidValue`）一致；design 的「仍相等」在字面上既可能指「推导后相等」，也可能指「任何情况相等」，缺一句限定，读者按 design 会预期自动扩边。
- **描述**：同一变更包内三份文档（design / spec / test）对同一输入给出两种预期，属于「归档规格自洽性」问题；不影响当前实现正确性。
- **建议**：design 补一句「仅当范围由数据推导且推导后相等时扩 ±0.5；两侧都显式且相等则抛 `InvalidValue`（见 spec 场景）」，与 spec / 测试对齐。

### [轻微][存量] #14 `percent-bar` 提案写成「100% 横条」，设计与规格及实现都是纵向堆叠

- **位置**：`doc/spec/add-f-chart-percent-bar/proposal.md:5`；对照 `doc/spec/add-f-chart-percent-bar/design.md:5-9`、`doc/spec/add-f-chart-percent-bar/specs/chart-rendering/spec.md:7`、`f_chart/src/PercentBarChart.cj:21`
- **来源**：存量（快照模式无基线；`git log -1` 为 `ea449b929 feat(f_chart): M75 百分比条`）
- **判据**：review-checklist §13「文档自相矛盾 / 承诺与实现相反」
- **证据**：静态确定 —— 提案 Why 段写「把每个类目的构成压缩为一根 100% 横条……需要横向比较构成的场景」；同一变更的设计写「直接调用 `BarRenderer.render(data, "percent-bar", BarMode.PercentStacked)`」并称「其余行为完全一致」，规格写「每个类目归一化到 100%，**纵向**堆叠各系列」，实现注释写「每个类目一根 100% 柱」（纵向），四处对方向的描述提案独占一种
- **描述**：提案是后续维护者理解该图的第一入口。若有人按「横条」去补一个水平 100% 堆叠实现，会与 `BarMode.PercentStacked` 的布局（`BarRenderer.cj:163-200`，`stackedBarX` 为纵向柱的 x 定位）冲突；按提案写文档或测试同样会得到相反预期
- **建议**：`proposal.md:5` 改为「每个类目一根归一化到 100% 的竖柱」，Why 段场景改为「比较各类目的构成比例」；确需横向版本时另开变更，并在 design 里写清与 `PercentStacked` 的差异

### [轻微][存量] #15 帕累托规格要求「标签长度 MUST 与数据一致」，实现允许省略标签并回退序号

- **位置**：`doc/spec/add-f-chart-pareto/specs/chart-rendering/spec.md:39`；对照 `f_chart/src/ParetoChart.cj:66-83`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 规格写「标签长度 MUST 与数据一致」，无「可省略」例外；实现 `:67` 的条件是 `if (!labels.isEmpty() && labels.size != values.size)`，`xAxis.labels` 缺省（长度 0）时不校验，并在 `:78-82` 回退为 `1..n` 序号标签
- **描述**：按规格写一致性用例「4 个数据 + 0 个标签 → `InvalidValue`」会失败，实现正常出图。实现更宽松、对使用者无害，但验收口径对不上，后续按规格补测试会误判为回归
- **建议**：`spec.md:39` 改为「`xAxis.labels` 给出时长度 MUST 与 `data` 一致，缺省时以序号 1..n 作为类别标签」，与 `:78-82` 的回退逻辑对齐

## 优化可行性方案

本部分（20 个 `.md`）没有可以写成「带基线的优化方案」的条目：涉及的实现片段全部缺少改前基线（无 `cjprof` / `cjpm bench -O2` 数据），按铁律一律降到「待验证假设」，不进 `tasks.md`。补到数据后可优先评估的两条已在下一节列出（`paretoOrder` 的 O(n²)、平行坐标逐行字符串拼接），此处不重复。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `paretoOrder` 的手写插入排序在类目数上千后退化为 O(n²) 热点（n=10⁴ 约 10⁸ 次比较） | `f_chart/src/ParetoChart.cj:207-215` | 不同 n 下的单次耗时与自耗时占比 | `cjpm bench -O2` 跑 n = 10²/10³/10⁴ 的 pareto 输入，记录中位数与离散度；必要时 `cjprof record` 看 `paretoOrder` self time |
| 2 | 平行坐标每行用 `StringBuilder` + `formatSvgNumber` 逐点拼 `d`，在「行数 × 维度数」大时成为 CPU/分配热点 | `f_chart/src/ParallelCoordinatesChart.cj:242-264` | 分配量与耗时占比 | 固定 10 维、行数 10³→10⁵ 递增，`cjprof record` + `getAllocatedHeapSize()` 差分 |
| 3 | 六个图表都全量物化输入（`ArrayList` 逐项 + `toArray()` 拷贝）并一次性生成整段 SVG 字符串，无输入上限，超大输入会先抬 RSS 再 OOM | `f_chart/src/ParallelCoordinatesChart.cj:96-125`、`f_chart/src/ParetoChart.cj:52-83`、`f_chart/src/PairedLineChart.cj:70-83` | 峰值 RSS / 堆占用随 n 的曲线与容器 limit | 逐步放大行数/类目数到 OOM 边界，记录 `getUsedHeapSize()`、RSS 与输出 SVG 字节数，给出「n 多大时峰值 = limit」 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-paired-line/specs/chart-rendering/spec.md` | .md | ✅ | 连线/端点/标签/时间点/校验五项与 `PairedLineChart.cj` 逐条对上；仅图例配色未约束（见 #9） |
| 2 | `f_chart/doc/spec/add-f-chart-paired-line/tasks.md` | .md | ✅ | 四项全勾；测试文件存在且覆盖连线/端点/标签/三时间点/缺 after/type，无坐标断言 |
| 3 | `f_chart/doc/spec/add-f-chart-parallel/design.md` | .md | ✅ | 维度解析、扩边、布局公式与实现一致；「相等扩边」口径与 spec 冲突（见 #13） |
| 4 | `f_chart/doc/spec/add-f-chart-parallel/proposal.md` | .md | ✅ | `type`、`dimensions[].{name,min,max}`、`parallel-line` / `dimension-axis` 与实现一致 |
| 5 | `f_chart/doc/spec/add-f-chart-parallel/specs/chart-rendering/spec.md` | .md | ✅ | 归一化/钳制、行长度、type 校验与实现一致；范围解析见 #2 |
| 6 | `f_chart/doc/spec/add-f-chart-parallel/tasks.md` | .md | ✅ | 四项全勾；`ParallelCoordinatesChart_test.cj` 覆盖轴/折线/归一化/行长度/范围/缺失/类型 |
| 7 | `f_chart/doc/spec/add-f-chart-pareto/design.md` | .md | ✅ | 稳定降序、累计百分比、左计数右百分比轴与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-pareto/proposal.md` | .md | ✅ | `type`、默认 `showCumulative`、三个 class 与实现一致 |
| 9 | `f_chart/doc/spec/add-f-chart-pareto/specs/chart-rendering/spec.md` | .md | ✅ | 降序/累计最后一项 100/开关/非负/长度校验与实现一致；右轴实现见 #7；标签可省略口径见 #15 |
| 10 | `f_chart/doc/spec/add-f-chart-pareto/tasks.md` | .md | ✅ | 四项全勾；测试覆盖柱数/累计线/排序/累计/负值/长度/缺失/类型 |
| 11 | `f_chart/doc/spec/add-f-chart-pdp/design.md` | .md | ✅ | 3% / 8% 留白、2px / 3.5px 与实现一致；未提 Y 轴方向（见 #1） |
| 12 | `f_chart/doc/spec/add-f-chart-pdp/proposal.md` | .md | ✅ | `feature` 字段、`pdp-line` / `pdp-point` / `pdp-feature` 与实现一致 |
| 13 | `f_chart/doc/spec/add-f-chart-pdp/specs/chart-rendering/spec.md` | .md | ✅ | 曲线/标注/校验与实现一致；两条轴要求互斥（见 #5） |
| 14 | `f_chart/doc/spec/add-f-chart-pdp/tasks.md` | .md | ✅ | 四项全勾；测试覆盖曲线/标注/轴标题/空数据/type，无坐标与方向断言 |
| 15 | `f_chart/doc/spec/add-f-chart-percent-bar/design.md` | .md | ✅ | 「直接调 `BarRenderer.render(..., PercentStacked)`、仅 type 串不同」与实现逐字一致；y 轴口径与 spec 相反（见 #4） |
| 16 | `f_chart/doc/spec/add-f-chart-percent-bar/proposal.md` | .md | ✅ | 复用 `BarRenderer`、数据形状、显式 min/max 可覆盖，与实现一致；Why 段「横条」与纵向实现相反（见 #14） |
| 17 | `f_chart/doc/spec/add-f-chart-percent-bar/specs/chart-rendering/spec.md` | .md | ✅ | 复用归一化、12 柱 + 3 图例、长度校验与实现一致；`yAxis.max` MUST 100 与实现相反（见 #4） |
| 18 | `f_chart/doc/spec/add-f-chart-percent-bar/tasks.md` | .md | ✅ | 四项全勾；声称覆盖「归一化」，测试缺该断言（见 #12） |
| 19 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/design.md` | .md | ✅ | `total = Σabs`、`total <= 0` 跳过、段从 0 累计、class 固定 `bar`，与 `BarRenderer.cj:163-200` 一致 |
| 20 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/proposal.md` | .md | ✅ | 新增模式分支、默认 0–100 可覆盖、复用主题/图例/校验，与实现一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。（另读 `src/` 的 6 个实现 + 4 个共用文件 + 5 个测试文件作为 §13 取证，不在本部分清单内。）

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 #1 #3 #5；设计/文档口径 #4 #13 #14 #15；可读性 #9 #10；语言特性 #2（`Option` 单侧缺省与显式值混用）；安全性无命中；安全性与分层不适用（无 I/O、无外部注入面、纯内存 SVG 生成） |
| §1 死代码 | 2 | 逐个核对本部分涉及的 6 个实现的 `internal` 符号（`PairedItem`、`ParallelDimension`、`ParallelSeriesData`、`paretoOrder`、`paretoCumulative`、`parallelNormalize`、`percentStackedValue`、`stackedBarX`、`groupedBarX`、`BarSeries`、`BarMode`、`BarRenderer.render`、`ChartRect` 的 `right`/`bottom`/`centerX`/`centerY`）均有调用者；`return`/`throw` 后同层语句逐个看过，命中 #6（`ParetoChart.cj:91-93` 不可达）与 #11（未使用 import）。`public` 类成员属对外契约，不判 |
| §2 重复逻辑 | 2 | 按「输入-输出-副作用」压行比对了 6 个 `draw` 主体与各自 helper：命中 #7（右轴手写 vs `drawYAxisRight`）、#8（51 处同文案轴校验 / 10+ 处插入排序 / 平行坐标 x 表达式）。`percent-bar` 与 `percent-stacked-bar` 的「逐行对齐」属刻意别名，已在设计里声明，不算重复 |
| §3 空实现 | 0 | 六个 `draw` 均有完整实现；`PercentStacked` 分支的 `continue`（`BarRenderer.cj:177-179`）是 `total <= 0` 的有意跳过，设计文档已写明，不是空实现 |
| §4 栈溢出 | 0 | 本部分涉及的代码无递归：`paretoOrder` / `sortLiftPoints` 为迭代插入排序，`parallelNormalize` 为纯算术，折线生成是单层 `for` |
| §5 OOM | 0 | 无全局容器、无按报文字段预分配、无跨请求缓存；内存与输入行数/类目数成正比且用后即弃。缺峰值数据，定量结论进待验证假设 #3 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，`paretoOrder` 与平行坐标字符串拼接只能进待验证假设 #1 #2，不写成缺陷 |
| §6.2 大粒度锁 | 0 | 全链路无锁、无共享可变状态（`SvgBuilder` / `ChartSvgKit` 均为单次调用内新建） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池，纯同步计算 |
| §6.4 低效算法 | 0 | 静态可见的复杂度隐患只有 `paretoOrder` 插入排序（O(n²)），因无输入规模与耗时数据，按规则降为待验证假设 #1，不列为发现 |
| §7 降堆内存方案 | 0 | 可想的点（`rows.toArray()` 双份、`ArrayList` 预分配）都缺基线，无「改前/改后」对照，不能写成方案 |
| §8 降 CPU 方案 | 0 | 同上，缺 `cjpm bench -O2` 对照 |
| §9 local mode 可行性 | 0 | 无函数内大临时结构可作为受益对象；`draw` 的产物（SVG 字符串）必然逃逸，local region 改造不成立，且无峰值内存对照数据 |
| §11 现有代码的 BUG（存量） | 3 | 本轮读到的 6 个 `draw` 边界/空值/坐标路径全过了一遍：命中 #1（Y 轴反向）、#3（画布无最小尺寸）、#5（显式范围不裁剪）。`before`/`after` 非负、series 数量、data 非空、行长度、标签长度、type 判别均已核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 六个图表类只有 `draw(data)` 一个入口，全部状态是局部变量；`ChartConfig` / `ChartTheme` / `SvgBuilder` 均在 `draw` 内新建，无线程共享路径，无锁可谈 |
| §14 功能完备性与 README 覆盖 | 1 | 六个特性的代码入口、class 名、错误类型均已接线，无 TODO / `UnsupportedException`；命中 #12（任务清单声称的归一化测试缺失）。README 覆盖归第 1/2 部分，本部分不重复判 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 逐份对照实现取证，结论见「文件覆盖」表 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 15 条（严重 1 / 一般 4 / 轻微 10），是否纳入修复待用户决定。

## 总评

本部分是六个图表特性的规格包（配对连线、平行坐标、帕累托、PDP、百分比条、百分比堆叠）。文档与实现的**基本吻合度很高**：class 名、错误类型（`MissingField` / `InvalidValue` / `UnsupportedChart`）、归一化公式、留白比例、堆叠起点都能逐条对上，任务清单与仓库里的测试文件也一一对应，没有发现「承诺了但没实现」的功能缺口。

风险集中在三处：

1. **PDP 的 Y 轴方向（#1，严重）** —— `LinearScale` 的 `topPixel` 参数被传成 `plot.bottom()`，曲线与刻度整体上下翻转。这是本部分唯一的阻塞项：图能生成、测试全绿（只数 class 不校验坐标），但表达的趋势方向是反的。同一写法在模块内还有 9 个图表（Volcano/Lift/Ecdf/Gain/Calibration/BlandAltman/LassoPath/LearningCurve/Manhattan），修的时候建议一起改，并把参数名固化成 `maxPixel` 或加具名工厂，避免再靠记忆传参。
2. **平行坐标的边界处理（#2 #3）** —— 单侧显式范围遇到越界数据会整图报错，与本文件自己的钳制契约冲突；画布尺寸又只校验 `> 0`，硬编码的 `60/20/64/40` 边距在窄画布上会把绘图区算成负数。两者都属于「输入合法但输出无意义」，建议在范围解析与 `ChartConfig` 两处各补一道判定。
3. **规格与实现的口径漂移（#4 #5 #13 #14 #15）** —— `percent-bar` 的「y 轴 MUST 固定 100」被实现与设计同时否定，提案还把纵向柱写成「100% 横条」；PDP 规格里「轴覆盖全部数据」与「显式 min/max 优先」互斥且没有裁剪兜底；平行坐标 design 的扩边规则与 spec 场景不一致；帕累托规格的标签长度要求比实现严。这些是归档规格的自洽性问题，不影响当前运行，但下游照规格写断言会踩空。

其余 10 条轻微问题（#6 不可达守卫、#7 右轴重复实现、#8 51 处同文案校验与手写排序、#9 图例配色、#10 平行坐标轴头布局、#11 未使用 import、#12 缺失的归一化测试、#13 design/spec 口径不一致、#14 percent-bar 提案方向、#15 帕累托标签口径）属于可维护性与观感层面，可以排期处理。性能与内存方面没有可下的结论：本部分涉及的代码路径没有 profile/bench 数据，`paretoOrder` 的 O(n²) 与全量物化只能作为下一轮补数据的假设。
