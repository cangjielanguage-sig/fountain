# f_chart 模块审查报告（模块第 20/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个 `.md`，0 个 `.cj`；覆盖 `doc/spec/add-f-chart-{scatter,sequence,shap,slope,spiral,stacked-area}` 六个已完成变更的四件套）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局正确性、坐标与数值边界、死代码、重复逻辑（本部分无源码，故按「每条 requirement / scenario 当契约，逐条到实现取证」，并反向核查实现侧的边界与重复实现）
- **报告版本**：v1

## 发现

> 与已产出部分的重叠：SHAP 的顶层 `features` 字段「文档写了、实现不接」已由 `f_chart.part2.md` #4（README 视角）与 `f_chart.part3.md` #13（`doc/chart-json-spec.md` 视角）报为【一般】。本部分的归档 `design.md:9` / `proposal.md:8,10` 是同一根因的第三、四处文档落点，**不重复统计**，合并时把这两处一并删除或接线即可。

### [一般][存量] `SpiralChart` 未校验 `maxRadius` 为正，小画布下半径取负导致整幅螺旋翻转 180°

- **位置**：`f_chart/src/SpiralChart.cj:110-113`（`maxRadius = min(w-pad, h-pad-40)/2 - 30`）；`f_chart/src/ChartConfig.cj:182`（只校验 `width > 0 && height > 0`）；`f_chart/src/ChartConfig.cj:22-25`（四边默认 padding 24）；对照 `f_chart/src/RadarChart.cj:88-91`（同类几何量有 `radius <= 0` 守卫）
- **来源**：存量（快照模式无基线；`git log -1 -- src/SpiralChart.cj` = `df565a19e feat(f_chart): M84 螺旋图`，几何常量自引入后未再改动）
- **判据**：review-checklist §11「边界差一 / 缺少边界校验」——配置层放行任意正数画布，几何层却假设半径为正；同模块 `RadarChart` 对同一类量做了显式守卫，属同类实现的判定漂移
- **证据**：静态确定 —— 取默认 padding，`height = 100` 时 `maxRadius = min(w-48, 12)/2 - 30 = -24`；`spiralPoint`（`SpiralChart.cj:164-177`）直接用 `radius * cos/sin`，负半径等价于把每个点旋转 180°（`cos(θ)·(-r) = cos(θ+180)·r`）。`width/height` 只要求 `> 0`，故该输入合法可达
- **描述**：默认 `startAngle = -90` 的语义是「首点从正上方起旋」，半径取负后首点落到正下方，整条路径与所有 `spiral-label` 一起被镜像，且外圈可能越出画布；不崩溃、不报错，只输出一张与文档描述方向相反的图。除 `height ≤ 148` 外，`width ≤ 108` 同样触发（等于边界时半径为 0，全部点叠在圆心）
- **建议**：在 `SpiralChart.draw` 计算完 `maxRadius` 后加与雷达图一致的守卫：`if (maxRadius <= 0.0) { throw chartInvalidValue("width", "画布太小，无法绘制螺旋图") }`；同时把画布下限写进 `add-f-chart-spiral/specs/chart-rendering/spec.md` 的「螺旋校验」，并补一条小画布用例

### [轻微][存量] 四个归档 `design.md` 的布局常量与实现已脱节（行高、文字偏移、留白宽度、半径与标签距离）

- **位置**：
  - `f_chart/doc/spec/add-f-chart-sequence/design.md:7`（「消息区…行高 40」）、`:12`（「文本在中点上方 6px」）↔ `f_chart/src/SequenceChart.cj:114-118`（`rowHeight = min(40, available/messages.size)`，自适应收缩）、`:142`（`y - 8.0`）
  - `f_chart/doc/spec/add-f-chart-shap/design.md:19`（「特征名最大文本宽度 + 12px」）↔ `f_chart/src/ShapChart.cj:110`（`maxFeatureWidth + 16.0`）
  - `f_chart/doc/spec/add-f-chart-slope/design.md:11`（「右侧预留 64px 用于系列名称」）↔ `f_chart/src/SlopeChart.cj:133-136`（`rightLabelWidth: maxLabelWidth + 16.0`，随名称长度变化）
  - `f_chart/doc/spec/add-f-chart-spiral/design.md:14`（「`maxRadius` 为短边的一半减 40px」）、`:20`（「周期标签放在点外侧 10px」）↔ `f_chart/src/SpiralChart.cj:110-113`（`min(w-pad, h-pad-40)/2 - 30`）、`:147-148`（沿半径外推 12px）
- **来源**：存量（快照模式无基线；`git log -1` 显示四处 `design.md` 与其实现文件各自落在同一提交——`a1dc954e9`(sequence)、`1b1f1fe43`(shap)、`f60ff4be4`(slope)、`df565a19e`(spiral)——说明写文档时即未与实现对齐，不是后续实现漂移）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」——四处都是可复算的字面常量，文档与代码两边位置都能点名，不是措辞差异
- **证据**：静态确定 —— 逐个比对上述行号的字面量：40 vs `min(40, …)`、6 vs `8.0`、12 vs `16.0`、64 vs `maxLabelWidth + 16.0`、40/10 vs `- 30`/`12`
- **描述**：按 `design.md` 复算会得到与实现不同的坐标与留白，维护者据此核对布局（或据此写快照断言）必然对不上；`sequence` 的行高还与校验口径冲突——文档写固定 40，实现为「消息放不下时压缩行高」，后者才是不溢出画布的行为。视觉后果都不大，但四处同源，说明归档后没有回写设计
- **建议**：按实现回写这五处常量（`sequence` 另外补一句「消息数超出可用高度时行高等比压缩，下限为 0」）；若认为 `design.md` 应保留「设计意图」，则在其顶部标注「常量以实现为准」并给出实现文件行号

### [轻微][存量] 堆叠面积图 `design.md` 引用了不存在的 `ChartFrame.drawGrid`，实现也未绘制网格

- **位置**：`f_chart/doc/spec/add-f-chart-stacked-area/design.md:20`（「y 轴复用 `drawYAxis` / `drawGrid`」）；`f_chart/src/ChartFrame.cj` 的方法清单只有 `drawBackground:94` / `drawTitle:98` / `drawLegend:134` / `drawYAxis:168` / `drawXAxis:204` / `drawYAxisRight:245` / `drawXAxisNumeric:278`；`f_chart/src/StackedAreaChart.cj:152`（只调 `drawYAxis`）
- **来源**：存量（快照模式无基线；`design.md` 与 `StackedAreaChart.cj` 同属 `faf081dc7 feat(f_chart): M15 堆叠面积图`）
- **判据**：review-checklist §13「示例 / 文档引用不存在的 API」——`drawGrid` 在全仓零命中，属悬空 API 名
- **证据**：静态确定 —— `grep -rn "drawGrid" f_chart/src f_chart/doc` 无命中；`ChartFrame.cj` 的 `func draw` 定义只有上述七个
- **描述**：按设计文档去找 `drawGrid` 会直接扑空；同时堆叠面积图确实没有水平网格线，读者无法判断是「文档写错」还是「网格线漏画」。对照 `AreaChart`、`LineChart` 同样只调 `drawYAxis`，可见这是模块统一的「无网格」风格，而非本图缺失
- **建议**：`design.md:20` 改为「y 轴复用 `drawYAxis`（本模块不绘制网格线）」；若确实需要网格，则先在 `ChartFrame` 新增 `drawGrid` 并在多图统一接入，不要只改这一张图

### [轻微][存量] 同文件内两份同语义实现：堆叠面积图的累计被算两遍，散点图的轴范围函数逐行同构

- **位置**：
  - `f_chart/src/StackedAreaChart.cj:157-187`（`draw` 里用 `groupIndexesOf` + `uniqueGroupCount` + 每类目 `cums` 重算 lower/upper 层）↔ `:310-328`、`:331-339`、`:347-377`（`stackedAreaBounds` 内部把同一套累计再算一遍）
  - `f_chart/src/ScatterChart.cj:205-226`（`resolveXRange`）↔ `:228-249`（`resolveYRange`）：两个函数体逐行对齐，只有取值字段（`point.x` / `point.y`）与错误路径（`"xAxis.min"` / `"yAxis.min"`）不同
- **来源**：存量（快照模式无基线；`StackedAreaChart.cj` 属 `faf081dc7`、`ScatterChart.cj` 属 `81b0dc647 feat(f_chart): M6 散点图`，均无后续修改）
- **判据**：review-checklist §2「重复逻辑 / 只改字段名的复制」——两处都是「输入-输出-副作用」完全一致的实现，第二处仅换了字段名
- **证据**：静态确定 —— `stackedAreaBounds` 的循环体（`354-376`）与 `draw` 的循环体（`171-187`）逐句对应：同样的 `cums` 归零、同样的 `groupIndexes` 下标、同样的 `lower/upper` 递推；`resolveXRange` / `resolveYRange` 的差异只有 `point.x`↔`point.y` 与最后一个入参字符串
- **描述**：累计规则（重置时机、组下标、含 0 的范围）现在写了两份，任何一处修正（例如「负值组单独向下累计」）都必须同步改另一处，否则轴范围与面积路径会不一致——这正是「重复逻辑导致的行为漂移」的典型入口。散点图那份的漂移风险更低（当前行为一致），但同样让 `lineRange` 的调用被摊平成两份
- **建议**：`StackedAreaChart` 抽 `stackedAreaLayers(groups, values, count): (bounds, lower, upper)`，`draw` 只调用一次，`stackedAreaBounds` 作为它的薄包装保留给测试；`ScatterChart` 抽 `resolveLineRange(rangeAxis, series, pick: (ScatterPoint) -> Float64, path: String)` 或直接把 x/y 合成 `resolveRanges` 一次返回两个数组

### [轻微][存量] 螺旋图 `spec.md` 的坐标公式在 `count == 1` 时除零，与同一文件的校验条款冲突

- **位置**：`f_chart/doc/spec/add-f-chart-spiral/specs/chart-rendering/spec.md:16`（角度 `startAngle + direction * turns * 360 * i / (count - 1)`）；同文件 `:39`（只要求 `data` 非空，故 `count == 1` 合法）；实现 `f_chart/src/SpiralChart.cj:173`（`divisor = count > 1 ? count-1 : 1`）
- **来源**：存量（快照模式无基线；`spec.md` 与 `SpiralChart.cj` 同属 `df565a19e`）
- **判据**：review-checklist §13「规格与实现漂移 / 规格自洽性」——同一份 spec 允许的输入落在自己给出的公式定义域之外（分母为 0）
- **证据**：静态确定 —— `:39` 的 MUST 只约束「恰好 1 个系列、`data` 非空」，`count = 1` 满足；`:16` 的分母此时为 0，公式无定义。实现侧已用 `divisor` 兜底，单个数据点返回 `[maxRadius*cos(startAngle), maxRadius*sin(startAngle)]`
- **描述**：`spec.md` 是合并后要长期留存的行为契约，读者照公式实现（或照公式断言单点场景）会得到 `NaN`，与实现的单点行为不一致；这也是本部分唯一一处「规格自身不自洽」而非「规格落后于实现」
- **建议**：`:16` 的分母改为 `max(count - 1, 1)`（与 `design.md:11` 的写法一致），并补一条「`data` 只有 1 项时返回半径 `maxRadius`、角度 `startAngle`」的场景

### [轻微][存量] 散点图的 `symbol: "none"` 能力既未进 spec 也未进 README，且无测试覆盖

- **位置**：`f_chart/src/ScatterChart.cj:162-167`（`case "none" => ()`，显式 no-op 分支）；`f_chart/doc/spec/add-f-chart-scatter/specs/chart-rendering/spec.md:30`（只声明 `circle/square/diamond`）；`f_chart/README.md:1149`（绘制方式未提形状取值）与 `:1153-1168`（示例只有 `symbolSize`）；`f_chart/src/ScatterChart_test.cj:52`（只断言 `class="symbol"` 计数，无形状用例）
- **来源**：存量（快照模式无基线；`ScatterChart.cj` 属 `81b0dc647`）
- **判据**：review-checklist §14.2「公开 API / 输出面未文档化」——series 级 `symbol` 是 JSON 契约的一部分，`none` 是分支里唯一没有文档与用例的取值
- **证据**：静态确定 —— `grep -rn '"symbol"' f_chart/README.md` 仅 `:677-678`（折线图示例，`circle`/`square`），无 `none`；`grep -n "symbol" ScatterChart_test.cj` 仅 `:52` 一处计数断言
- **描述**：`none` 会让该系列一个点都不画（连 `class="symbol"` 都没有），使用者按 spec 的取值枚举不可能知道这个能力；反过来，若 `none` 只是「未知值落到默认圆点」的旧写法残留，则它是死分支。两种可能都需要作者确认，但目前没有任何文档或测试表达意图
- **建议**：确认语义后在 `spec.md:30`、「散点图多系列样式」下补 `none`（「不绘制符号，仅保留图例/标签」）并加一个形状用例；若确认无用途，删除该分支，让未知 `symbol` 落到默认圆点（与 `case _` 一致）

> 存量 6 条（一般 1、轻微 5），是否纳入修复待用户决定；`features` 一条同源问题见本节开头说明，已计在 `part2.md` #4 / `part3.md` #13。

## 优化可行性方案

本部分 20 个文件全为 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无改前基线也无改后对照）。唯一与代码相关的性能线索是发现 #4 的「累计被算两遍」，量化数据缺失，已放入「待验证假设」，不作为方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 合并两份累计实现（`draw` 内联 vs `stackedAreaBounds`）可省掉一次 O(series×category) 遍历 | `f_chart/src/StackedAreaChart.cj:171-187`、`:347-377` | 该遍历在 `draw` 自耗时中的占比 | `cjprof record` 跑 `stacked-area`，series=20、category=200，渲染 200 次，看两段循环的 self time 占比；低于噪声（约 5%）则只做去重、不承诺收益 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-scatter/specs/chart-rendering/spec.md` | .md | ✅ | 三条需求与 `ScatterChart.cj` 逐条吻合（`symbol` 类名、x/y 轴 `tick-label` 分别由 `ChartFrame.cj:307`（`drawXAxisNumeric`）与 `:185`（`drawYAxis`）输出、非时间轴字符串 x 走 `jsonNumberValue` 抛 `InvalidValue`、调色板取 `colorAt(index)`）；`symbol: "none"` 未列（见发现 #6） |
| 2 | `f_chart/doc/spec/add-f-chart-scatter/tasks.md` | .md | ✅ | 4 项全勾选；声明的 Red→Green 流程与 `ScatterChart_test.cj` 存在性一致 |
| 3 | `f_chart/doc/spec/add-f-chart-sequence/design.md` | .md | ✅ | 结构（36px 方框、生命线 `4 4`、消息区 +30、末端三角、`note` 便签）与实现一致；行高与文字偏移两处常量失配（见发现 #2） |
| 4 | `f_chart/doc/spec/add-f-chart-sequence/proposal.md` | .md | ✅ | `type`、`participants`/`messages` 字段、返回虚线语义均与 `SequenceChart.cj:56-70,124-128` 一致；`text`/`type`/`dashed`/`note` 的默认值（空串、`sync`、`false`）文档未写但实现有 |
| 5 | `f_chart/doc/spec/add-f-chart-sequence/specs/chart-rendering/spec.md` | .md | ✅ | 四个场景全部可复现：`participant`/`lifeline`/`message` 类名逐处存在，`dash: "5 3"` 经 `ChartSvgKit.cj:89-90` 输出 `stroke-dasharray`，悬空端点抛 `InvalidValue`（`SequenceChart.cj:199-204`） |
| 6 | `f_chart/doc/spec/add-f-chart-sequence/tasks.md` | .md | ✅ | 4 项全勾选，无残留 TODO |
| 7 | `f_chart/doc/spec/add-f-chart-shap/design.md` | .md | ✅ | 数据模型、排序（稳定、绝对值降序）、配色（`#e53935`/`#2196f3`）、`bandWidth * 0.6`、零基线均已核对一致；左侧留白 12px 与实现 16px 不符（发现 #2），顶层 `features` 属已报项（见开头说明） |
| 8 | `f_chart/doc/spec/add-f-chart-shap/proposal.md` | .md | ✅ | `type`/`series[0].data`/排序/配色/校验与实现一致；`features` 的「声明特征顺序 / 缺省回退」未实现（同源已报） |
| 9 | `f_chart/doc/spec/add-f-chart-shap/specs/chart-rendering/spec.md` | .md | ✅ | 六个场景全部成立：4 条 `shap-bar`（2 正 2 负）、顺序 `年龄/血压/BMI/血糖`、1 条 `shap-zero`、每条形 1 个 `shap-label`、空数据 `InvalidValue`、缺 `value` 走 `required` 抛 `MissingField`、空 `feature` 抛 `InvalidValue` |
| 10 | `f_chart/doc/spec/add-f-chart-shap/tasks.md` | .md | ✅ | 1.1–4.2 全勾选；列出的用例在 `ShapChart_test.cj` 均有对应（含 `keepsStableOrder`） |
| 11 | `f_chart/doc/spec/add-f-chart-slope/design.md` | .md | ✅ | 双 `BandScale.center`、5% 留白、2px 线、4px 圆点、右侧 8px 标签均与实现一致；右侧留白 64px 与实现动态值不符（发现 #2） |
| 12 | `f_chart/doc/spec/add-f-chart-slope/proposal.md` | .md | ✅ | 三个类名（`slope-line`/`slope-point`/`slope-label`）与 `yAxis.min`/`max` 覆盖语义均与 `SlopeChart.cj:169-182,102-112` 一致 |
| 13 | `f_chart/doc/spec/add-f-chart-slope/specs/chart-rendering/spec.md` | .md | ✅ | 场景可复现：3 系列 → 3 线 6 点 3 标签；`labels` 长度 ≠ 2、`data` 长度 ≠ 2、`series` 空、`type` 不符分别抛 `InvalidValue`/`MissingField`/`UnsupportedChart`；唯「等距分布在左右两侧」实为 25%/75% 处的两个 band 中心（与 design 一致，措辞可再精确） |
| 14 | `f_chart/doc/spec/add-f-chart-slope/tasks.md` | .md | ✅ | 4 项全勾选 |
| 15 | `f_chart/doc/spec/add-f-chart-spiral/design.md` | .md | ✅ | 角度/半径公式与 `spiralPoint` 一致；`maxRadius`（−40 vs −30）与标签外推（10 vs 12px）两处常量失配（发现 #2）；`value` 线性映射 3–8px、线宽 1.5、`#b0bec5` 均吻合 |
| 16 | `f_chart/doc/spec/add-f-chart-spiral/proposal.md` | .md | ✅ | 默认值 `turns=3`、`startAngle=−90`、`clockwise=true` 与 `SpiralChart.cj:41-46` 一致；三个类名齐全 |
| 17 | `f_chart/doc/spec/add-f-chart-spiral/specs/chart-rendering/spec.md` | .md | ✅ | 首点 `[0,-25]`、末点 `[0,-100]` 按 `spiralPoint(…, 4, 1, -90, true, 100)` 复算吻合；坐标公式的 `count == 1` 除零见发现 #5；校验条款（`turns>0`、单系列、非空、`period` 字符串、`value` 非负）逐条在实现中命中 |
| 18 | `f_chart/doc/spec/add-f-chart-spiral/tasks.md` | .md | ✅ | 4 项全勾选 |
| 19 | `f_chart/doc/spec/add-f-chart-stacked-area/design.md` | .md | ✅ | 类目模式、`null→0`、按 `stack` 分组、路径「下边界反向 + 上边界正向」、`stackedAreaBounds` 语义均与实现一致；累计重复实现见发现 #4，`drawGrid` 悬空见发现 #3 |
| 20 | `f_chart/doc/spec/add-f-chart-stacked-area/proposal.md` | .md | ✅ | `type`、`series[].stack`、`null` 归零、y 轴含 0 均成立；「新增内部纯函数 `stackedAreaBounds` 便于单测」与 `StackedAreaChart_test.cj:59,71,82` 一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性：#1（负半径导致输出方向错误）。设计/语言特性/可读性无问题；安全性方面本部分不涉及注入或敏感数据（JSON 经 `ChartJson` 取值，无拼接执行） |
| §1 死代码 | 0 | 本部分无 `.cj`。为核对 spec 通读了 6 个实现文件，其 `internal` 符号逐个全仓搜过引用：`spiralPoint`（draw + `SpiralChart_test.cj:87,95,103`）、`shapOrder`（draw + `ShapChart_test.cj:100,113`）、`stackedAreaBounds`（draw + `StackedAreaChart_test.cj:59,71,82`）、`groupIndexesOf`/`uniqueGroupCount`（draw 与 `stackedAreaBounds`）均有调用者；读到的 `return`/`throw` 后无同层语句，`if (labels.isEmpty())` 分支可达；`symbol == "none"` 分支由输入可达（其「无文档」问题记 §14 #6，不按死代码计） |
| §2 重复逻辑 | 2 | #4：`StackedAreaChart` 累计两遍、`ScatterChart` 轴范围两函数逐行同构。已把 6 个实现的函数体按「输入→输出→副作用」两两比对：`SequenceChart.parseParticipants/parseMessages`、`ShapChart` 排序与判重、`SlopeChart`/`SpiralChart` 的解析块差异大于共性（字段集、错误类型、默认值都不同），不判重复 |
| §3 空实现 | 0 | 无空函数体、无 TODO/FIXME、无 `catch {}`；`case "none" => ()` 是有意的 no-op 策略，问题在「未文档化」而非「空实现」，见 §14 #6 |
| §4 栈溢出 | 0 | 6 个实现全无递归：`spiralPoint` 为纯算术，`shapOrder` 为插入排序双层循环，`stackedAreaBounds` 为三维有界循环；无自引用结构、无深度拷贝 |
| §5 OOM | 0 | 唯一全量物化是最终 SVG 字符串与 `ArrayList→Array` 的等长副本，规模 = 数据点数，属渲染 API 固有；6 个 `draw` 均无跨调用容器、无缓存、无全局注册表，单次调用结束即可回收。spec 未承诺输入上限，故不按「无拒绝路径」计缺陷 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，也无任何性能承诺；不进发现，线索见「待验证假设」#1 |
| §6.2 大粒度锁 | 0 | 6 个实现无 `synchronized`、无 Mutex、无 I/O |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无批处理/队列 |
| §6.4 低效算法 | 0 | 循环均为 O(n) 或 O(n×series)；`shapOrder` 的 O(k²) 与判重 O(k²) 中 k 为特征数（spec 示例 4 项），无规模证据，不成立 |
| §7 降堆内存方案 | 0 | 本部分无代码主体；6 个实现均无长期持有结构，无「还能省」的量化对象可写 |
| §8 降 CPU 方案 | 0 | 同上；唯一线索（#4 的重复累计）缺基线，已降级为待验证假设 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象（输出为唯一逃逸串），且无前后峰值内存数据，按约束只能是假设，本部分不列 |
| §11 现有代码的 BUG（存量） | 1 | #1。其余边界已核对并有保护：散点空 `data` → 默认 `[0,1]` 域（`ScatterChart.cj:221-224`）、SHAP 全零 → `[-1,1]`（`ShapChart.cj:94-95`）、斜率 `span<=0` → 1.0（`SlopeChart.cj:98-101`）、堆叠面积全零 → `max = min+1`（`StackedAreaChart.cj:299-304`）、序列消息为空 → 行高 40（`SequenceChart.cj:114-118`） |
| §12 并发安全与锁粒度 | 0 | 6 个 `Chart` 实现均无成员可变状态（只有 `public init() {}`），`draw` 全部用局部变量与局部 `SvgBuilder`，无共享路径；无锁可谈 |
| §13 文档一致性（含规格自洽性） | 3 | #2（五处布局常量）、#3（`drawGrid` 悬空）、#5（`spiralPoint` 公式除零）；另有 `shap.features` 的归档文档落点，与 `part2.md` #4 / `part3.md` #13 同源，不计入本部分。其余场景逐条复算通过（spiral 首末点、shap 排序、slope 长度校验、sequence 虚线） |
| §14 功能完备性与 README 覆盖 | 1 | #6（`symbol: "none"` 未文档化且无测试）。正向核对：6 个 `type` 在 README 均有里程碑条（`:73` scatter、`:77` sequence、`:82` stacked-area、`:145` slope、`:151` spiral、`:169` shap）与专节示例（`:1145`、`:2394`、`:701`、`:596`、`:798`、`:2308`），`README_en.md` 同步；公开 API 无漏登 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；`add-f-chart-stacked-area` 本身只有 `design.md` + `proposal.md`（无 spec delta / tasks），清单如此，非漏读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 份归档四件套整体可用：每条 requirement 都能落到实现的具体类名、错误类型与常量上，可复算的场景（spiral 首末点 `[0,-25]`/`[0,-100]`、shap 绝对值降序、slope 长度校验、sequence 的 `stroke-dasharray`）逐一复算均吻合，没有发现「spec 承诺了但整块能力缺失」的情况——唯一的承诺缺口 `shap.features` 已由 `part2` / `part3` 记录，本部分只补了两处归档文档落点。

需要排期的只有一条：**#1 螺旋图负半径**。它是本部分唯一影响输出正确性的点，触发条件是小画布（默认 padding 下 `height ≤ 148` 或 `width ≤ 108`）这种完全合法的输入，后果是整幅图翻转 180° 且可能越界，而同模块 `RadarChart` 已有同类守卫，修复成本极低（三行 + 一条用例 + spec 补一句画布下限）。

其余五条是文档与维护性问题：#2 的五处常量说明归档后没有回写设计（改文档即可，不动代码）；#3 的 `drawGrid` 是悬空 API 名，需明确「本模块不画网格」；#5 是 spec 自身在 `count == 1` 时不自洽，属长期契约瑕疵；#4 的两处同语义复制目前行为一致，但累计规则写两遍是后续漂移的入口，建议在改动 `stacked-area` 之前先合并；#6 需要作者确认 `symbol: "none"` 是能力还是残留，再决定补文档还是删分支。

存量共 6 条（一般 1、轻微 5），是否纳入修复待用户决定。
