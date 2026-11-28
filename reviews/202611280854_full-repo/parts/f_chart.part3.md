# f_chart 模块审查报告（模块第 3/37 部分）

> **本报告只覆盖 `files/f_chart.part3.txt` 列出的 20 个 `.md`**：`doc/chart-json-spec.md`、`doc/f_chart模块设计.md`，以及 `doc/spec/add-f-chart-{alluvial,arc,area,bar,bland-altman}/` 五套归档变更四件套。`README.md` / `README_en.md` 与其他 `doc/spec/**`、`src/**` 由其余 36 个子轮产出；模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（模块合计 251 个 `.cj` / 444 个 `.md`；**本部分** 0 个 `.cj` / 20 个 `.md`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空 ⇒ 全部问题来源记「存量」）。取证：`git log -1 -- doc/chart-json-spec.md` = `ef80c7456`（2026-11-08），`doc/f_chart模块设计.md` = `fbe98f1f1`（2026-11-09），`git status --porcelain f_chart/doc` 为空。
- **审查重点**：渲染/布局算法与坐标边界在文档侧的一致性、OOM 与资源上限、死引用形式的死代码、重复维护的映射表、文档-实现漂移
- **报告版本**：v1（分报告，只统计本部分；不写 `docs/review/` 下的模块报告）

## 发现

### [一般][存量] #1 规范 §2.5 / §2.6 的三个通用字段在实现层没有读取点：`annotations`、`series[].label`、`series[].opacity`

- **位置**：`f_chart/doc/chart-json-spec.md:36`（`annotations`，交叉引用还写错成「见 2.5」，实际在 §2.6）、`:111-120`（§2.6 四类注解 `text/line/band/point` 字段表）、`:103`（`series[].opacity` 默认 1）、`:109`（`series[].label` 对象）；`f_chart/doc/f_chart模块设计.md:87`（信封表同样列 `annotations` 默认 `[]`）；`chart-json-spec.md:251`（M1 把 `series[].label` 列为柱状图能力）
- **来源**：存量（快照模式无基线，两文件分别最后改动于 2026-11-08 / 11-09）
- **判据**：review-checklist §3「公开契约承诺有行为 / 开关打开后走进空分支」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `grep -rn "annotation" f_chart/src f_svg/src` = 0 命中（`markLine` / `referenceLine` 同样 0）；`grep -rn 'number("opacity"' src/*.cj` 只有 `AreaChart.cj:283` 与 `StackedAreaChart.cj:250`，都是读 `areaStyle.opacity`，没有任何图读 series 级 `opacity`；`grep -rn '"position"' src/*.cj` 只命中 `ChartConfig.cj:105`（legend），`series[].label.position` / `.format` 无解析点
- **描述**：规范把 `annotations` 定义为「所有图共用」的第 2 节字段，给出四种注解的坐标、终点、文本、颜色、虚线；实际任何图都不读它，按文档写参考线/参考带会**不报错、不出图**——这类静默失败比抛 `InvalidValue` 更难排查。`series[].label`（`{"show":true,"position":"top","format":"{value}"}`）与 `series[].opacity` 同属「通用 series 字段表里有、代码里没有」，其中 `label` 还被写进 M1 专属字段
- **建议**：(a) 在 `ChartConfig` 统一读 `annotations`，由图实现经 `ChartFrame`（已有比例尺与轴）落图；`series.label` / `opacity` 在 `ChartSeries` 解析层读；(b) 从 §2.5 / §2.6 与 `f_chart模块设计.md:87` 删除并注明「暂不支持」；(c) 折中：保留字段但解析到非空即抛 `UnsupportedChart`，把静默变成显式失败。顺手把 `:36` 的「见 2.5」改成「见 2.6」

### [一般][存量] #2 M17 直方图的 `bins` 三项描述全错：默认不是 10、不接受上界数组、`normalize` 未实现

- **位置**：`f_chart/doc/chart-json-spec.md:758`；实现 `f_chart/src/HistogramChart.cj:166-186`（`resolveBinCount`）
- **来源**：存量
- **判据**：review-checklist §13「API / 默认值与源码不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `Some(value)` 分支要求 `isInt || isDecimal`，否则抛「期望正整数」（`:168-171`），数组形态直接被拒；`None` 分支是 `Int64(sqrt(Float64(sampleSize)))`（`:179`），不是常量 10；`grep -rn normalize src/HistogramChart.cj` 零命中（同名键只出现在 `ConfusionMatrixChart` 的 `normalize: "row"`，语义不同）
- **描述**：照文档传 `"bins": [150,160,170]` 会得到 `series[0].bins: 期望正整数`；不写 `bins` 时期望 10 个箱、实际 `floor(sqrt(n))`（20 个样本 → 4 个箱，与同节示例的 `"bins": 8` 也不一致）。`normalize` 写了默认 false 但无实现，想要频率密度只能外部换算
- **建议**：改成「`series[].bins`：正整数分箱数，缺省 `floor(sqrt(n))`，最小 1；不支持上界数组」；删除 `normalize` 或实现（实现时同步 `yAxis.title` 语义与示例）

### [一般][存量] #3 `areaStyle` 默认透明度写成 0.2，实现是 Area 0.3 / StackedArea 0.6

- **位置**：`f_chart/doc/chart-json-spec.md:108`（§2.5 `{"opacity":0.2}`）、`:623`（M14「默认 0.2」）；实现 `f_chart/src/AreaChart.cj:283,291`（0.3）、`f_chart/src/StackedAreaChart.cj:250`（0.6）
- **来源**：存量
- **判据**：review-checklist §13「默认值与源码不符」、§2「同一语义多处给出不同值」
- **证据**：静态确定 —— `AreaChart.resolveOpacity` 两处都是 `0.3`；`StackedAreaChart` 同名逻辑 `0.6`；本部分归档设计 `doc/spec/add-f-chart-area/design.md:20` 与 `proposal.md:11` 也写 0.3，与源码一致、与规范相反
- **描述**：三份材料三个数。使用者按规范以为「不写就是 0.2」，实际 M14 更浓、M15 更浓，做视觉回归时对不上样例
- **建议**：§2.5 改为「由图决定：`area` 0.3、`stacked-area` 0.6」，或统一默认值并同步代码与 `charts/` 基线

### [一般][存量] #4 M18 核密度图 `fill` 默认写成 true，实现默认 false

- **位置**：`f_chart/doc/chart-json-spec.md:779`；实现 `f_chart/src/DensityChart.cj:89`
- **来源**：存量
- **判据**：review-checklist §13「默认值与源码不符」
- **证据**：静态确定 —— `json.bool("fill", default: false)`，`DensitySeries` 持有该值决定是否填充曲线下区域
- **描述**：按规范省略 `fill` 应得填充密度曲线，实际只有描边；示例显式写了 `"fill": true/false`，所以样例长期掩盖了这个默认值错误
- **建议**：规范改默认 `false`；若产品上希望默认填充，则改代码并同步示例与基线

### [一般][存量] #5 M31 饼图的 `innerRadius` 字段不存在，只有 `donut` 支持内半径

- **位置**：`f_chart/doc/chart-json-spec.md:1248`；实现 `f_chart/src/PieChart.cj`（全文 `innerRadius` 零命中）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「字段在源码找不到」
- **证据**：静态确定 —— `grep -rn innerRadius f_chart/src` 只命中 `DonutChart.cj`、`GaugeChart.cj`、`SunburstChart.cj`；`PieChart` 的专属字段只解析了 `startAngle` 与 `showPercent`
- **描述**：规范给饼图列 `innerRadius`（默认 0），暗示 `pie` 传该键可成环形；实际被忽略，`pie` 永远实心，`donut` 的 0.55 又无法从 `pie` 触发。使用者会以为两个图只差一个参数
- **建议**：M31 删掉 `innerRadius`，改「需要环形请用 `donut`（默认 0.55）」；或 `PieChart` 读同名键并复用 `DonutChart` 的弧路径

### [一般][存量] #6 M36 桑基图的 `iterations`（默认 32）没有任何实现

- **位置**：`f_chart/doc/chart-json-spec.md:1367`；实现 `f_chart/src/SankeyChart.cj:159-160`
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§1「读了不用的死配置」
- **证据**：静态确定 —— 全模块 `grep -rn iterations f_chart` = 0 命中（含测试）；`SankeyChart` 只解析 `nodeWidth`（16）、`nodeGap`（12），布局是一次固定计算
- **描述**：这是会直接影响布局结果的字段：使用者调大 `iterations` 期望更稳的分层，实际无任何效果也不报错；规范把它与 `nodeWidth`/`nodeGap` 并列，可信度看起来一样
- **建议**：删除该字段；若确有迭代布局计划，spec 标「未实现」并在收到该键时抛 `UnsupportedChart`

### [一般][存量] #7 M37 帕累托图的 `cumulativeFormat` 未实现，右轴刻度硬编码为 0–100 步长 20 的整数百分比

- **位置**：`f_chart/doc/chart-json-spec.md:1615`；实现 `f_chart/src/ParetoChart.cj:171-177`
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「配置项无效」
- **证据**：静态确定 —— `for (tick in [0.0, 20.0, 40.0, 60.0, 80.0, 100.0])` 固定数组 + `"${Int64(tick)}%"`，既不读 `cumulativeFormat`，也不读 `yAxis.labelFormat` / `tickCount`；全模块 `grep cumulativeFormat` = 0 命中
- **描述**：规范承诺「`cumulativeFormat` 默认 `{value}%`」，改成 `{value} %` 或小数都不会生效；累计轴同时绕过了通用 `tickCount` / `labelFormat`，两条路都堵死
- **建议**：实现 `cumulativeFormat`（复用 `chartFormatTick` 的 `{value}` 占位替换）与 `tickCount`；或删字段并写明「累计轴固定 6 档整数百分比」

### [一般][存量] #8 M70 圆堆积图的 `padding` 与通用画布 `padding` 是同一个 JSON 键，示例会同时改掉画布内边距

- **位置**：`f_chart/doc/chart-json-spec.md:29`（§2 通用 `padding` 默认 24、作用于画布）、`:1420`（M70 专属 `padding`「圆间距，默认 2」）、`:1428`（示例 `"padding": 2`）；实现 `f_chart/src/ChartConfig.cj:187`（`ChartPadding.parse(root.value("padding"))`）、`f_chart/src/CirclePackingChart.cj:55`（`root.number("padding", default: 2.0)`）
- **来源**：存量
- **判据**：review-checklist §13「同一字段两种语义」、§11「语义与命名不符」；字段命名冲突属设计缺陷
- **证据**：静态确定 —— 同一个根级键被读两次：先按信封解析为画布 `ChartPadding`（默认 24），再被圆堆积当作圆间距（默认 2）。因此 M70 示例的 `"padding": 2` 会同时把画布边距从 24 压到 2
- **描述**：规范先用通用表把 `padding` 定义成画布内边距，又在 M70 重定义为圆间距，默认值不同、作用域不同，代码各读一次。用户想「保持画布边距 24、只把圆排紧」在现有字段下做不到；示例本身已经改小边距却没有一句说明。这是本部分唯一一条会改变**布局结果**的字段冲突
- **建议**：M70 换独立键（如 `circlePadding`），代码读新键并保留一版旧键兼容告警；§2 通用字段表加一句「各图专属字段与通用字段同名时，必须显式说明覆盖关系」

### [一般][存量] #9 M34 矩形树图声明 `tiling` 可取 `slice`，实现直接拒绝

- **位置**：`f_chart/doc/chart-json-spec.md:1318`（`squarify` / `slice`，默认 `squarify`）；实现 `f_chart/src/TreemapChart.cj:118-121`
- **来源**：存量
- **判据**：review-checklist §13「枚举值与实现不符」、§14.1「只处理部分输入」
- **证据**：静态确定 —— `let tiling = root.string("tiling", default: "squarify")` 之后 `if (tiling != "squarify") { throw chartInvalidValue("tiling", "目前仅支持 squarify") }`
- **描述**：规范把 `slice` 与 `squarify` 并列为可选值，照文档写 `"tiling": "slice"` 会直接拿到 `InvalidValue`。这与 #6 的静默忽略不同，是"文档允许、实现拒绝"，用户会先怀疑自己的 JSON 写错
- **建议**：规范删掉 `slice`（或标「未实现」）；若计划支持，实现 `slice` 分支并在 spec 的 tasks 里留 Red 用例

### [轻微][存量] #10 M60 流向图正文写 `flows: [{from, to, …}]`，同节示例写 `source` / `target`

- **位置**：`f_chart/doc/chart-json-spec.md:2467`（正文）对照 `:2481-2482`（示例）；实现 `f_chart/src/FlowMapChart.cj:117-124`
- **来源**：存量
- **判据**：review-checklist §13「示例与正文冲突」、§1「同一语义两种写法」
- **证据**：静态确定 —— 实现先取 `source`，缺失时回落 `requiredString("from")`；`target` 同理回落 `"to"`。两种写法都能跑，但错误路径报的是 `flows[i].source`
- **描述**：同一小节正文与示例对同一字段给出两个名字，读者不知道以哪个为准；虽然实现兼容，但 §1 约定「同一语义只用一个字段名」在这里被打破，且 `links` 体系用的是 `source/target`，`flows` 用 `from/to` 会让跨图复用 JSON 的人踩坑
- **建议**：正文统一为 `source` / `target` 并注明 `from/to` 为兼容别名（或在下一大版本移除别名）

### [轻微][存量] #11 类型索引里 `scatter-matrix` 标 `C`、`mosaic` 标 `M`，与 §5 正文和实现都相反

- **位置**：`f_chart/doc/chart-json-spec.md:166`（M30 `C`）、`:169`（M33 `M`）；对照 `:1166`（M30「样本行 `number[][]`」）、`:1300`（M33「`data` 与 `xAxis.labels` 等长」）；实现 `f_chart/src/ScatterMatrixChart.cj:27`（`rows: Array<Array<Float64>>`）、`f_chart/src/MosaicChart.cj:58-61`（逐 series 读平铺数组）
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 与实现不符」；§3 代号定义 `C = number[]`、`M = number[][]`
- **证据**：静态确定 —— M30 实现是二维数组（表里写 `C`）；M33 是"每系列一维"（表里写 `M`）
- **描述**：按 §3 约定准备数据的人会把两个图的数据结构搞反，第一次调用就报 `InvalidValue`
- **建议**：两处代号互换；若想保留「mosaic 是矩阵转置」的意思，在 §3 加说明，不要让单图代号与定义冲突

### [轻微][存量] #12 `symbol` 列出 `triangle`，实现没有该形状，会静默画成圆点

- **位置**：`f_chart/doc/chart-json-spec.md:106`；实现 `f_chart/src/LineChart.cj:447-451`（`ScatterChart` / `ComboChart` 同构）
- **来源**：存量
- **判据**：review-checklist §13「枚举值与实现不符」、§14.1「开关打开后走进等价分支」
- **证据**：静态确定 —— `drawSymbol` 的 `match` 只有 `none` / `square` / `diamond`，其余落 `case _ => circle`；全模块 `grep triangle src` 仅在 `Histogram2DChart_test` 的 `shape` 键命中；本部分 `doc/f_chart模块设计.md:116` 列的正是 `circle / square / diamond / none`（无 triangle），与代码一致
- **描述**：写 `"symbol": "triangle"` 不报错、画出来是圆点，视觉验收时会被当成样式 bug 追查
- **建议**：§2.5 删 `triangle`；若要支持，在 `ChartSvgKit` 加图元并补 `match` 分支与断言

### [轻微][存量] #13 规范里的 `shap.features` 与 `gantt.tasks[].lane` 仍是幻影字段

- **位置**：`f_chart/doc/chart-json-spec.md:2115`（M101 `features: string[]`）、`:2123`（示例顶层 `features`）、`:2142`（M8 `tasks: [{…, lane?, …}]`）
- **来源**：存量
- **判据**：review-checklist §13「示例引用实现不读取的字段」、§14.1
- **证据**：静态确定 —— `ShapChart` 只从 `series[0].data[i].feature` 取特征名（`:66` `requiredString("feature")`），全文无 `features`；`GanttChart` 全文 `lane` 零命中，行标签取 `task.name`（`:148`）
- **描述**：`features` 被描述成"排序依据"，实际顺序完全来自数据数组；`lane` 被写进每个 task，实际泳道划分不存在。两处都是"照文档写、效果不出现"
- **建议**：两处从规范删除并进「待实现」清单；若保留 `features` 作排序来源，需在 `ShapChart` 接线并校验 `features.size == data.size`

### [轻微][存量] #14 `donut` 的 `startAngle` / `showPercent` 与 `network-heatmap` 的 `showValues` / `cellGap` 未登记进规范

- **位置**：`f_chart/doc/chart-json-spec.md:1274`（M32 只列 `innerRadius` / `centerText`）、`:1215`（M68 只列 `nodes` / `colorRange`）；实现 `f_chart/src/DonutChart.cj:78-79`、`f_chart/src/NetworkHeatmapChart.cj:143-144`
- **来源**：存量
- **判据**：review-checklist §14.2「公开配置项未文档化」
- **证据**：静态确定 —— `DonutChart` 读 `startAngle`（0）与 `showPercent`（true）；`NetworkHeatmapChart` 读 `showValues`（false）与 `cellGap`（1），四项都能改变输出
- **描述**：读者无法从任何文档得知环形图可调起始角、可关百分比，网络热力图可显示数值、可调格间距，只能读源码
- **建议**：补齐四个字段（带默认值），或写「其余字段同 M31 / M43」让读者跳转

### [轻微][存量] #15 设计文档两处过期：目录树里的 `ChartSpec.cj` 不存在、里程碑表缺 M68，且未列 `ChartTime.cj` / `BarRenderer.cj`

- **位置**：`f_chart/doc/f_chart模块设计.md:39`（`ChartSpec.cj  通用信封（internal）`）、`:36-52`（目录树）、`:210-211`（`M66` 之后直接 `M69`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」「文档过期」；§1 的"死引用"形态
- **证据**：静态确定 —— `ls f_chart/src | grep ChartSpec` 无结果，实际为 `ChartConfig.cj`（`ChartConfig.parse`），本部分 `doc/spec/add-f-chart-bar/design.md:8` 也写 `src/ChartConfig.cj`；同文档 `:295-296` 用的又是 `ChartConfig`；`M68 网络热力图 / NetworkHeatmapChart.cj` 在正文表与别名表都没有，而 `chart-json-spec.md:204` 与 `src/NetworkHeatmapChart.cj` 都存在
- **描述**：目录树是新人定位基础设施的第一入口，`ChartSpec.cj` 会让人去搜一个不存在的文件（文档侧死引用）；缺 M68 会让里程碑表与规范索引（108 行）对不上
- **建议**：`ChartSpec.cj` → `ChartConfig.cj`，补 `ChartTime.cj` / `BarRenderer.cj`（或改成"基础设施清单"表）；在 M66 与 M69 之间补 M68，并在表头注明别名 M67/M86/M87/M104/M106 见下表

### [轻微][存量] #16 通用轴范围规则「按数据范围留 5% 余量」只对曲线类成立，柱/面积默认包含 0，规范未区分

- **位置**：`f_chart/doc/chart-json-spec.md:2720`；实现 `f_chart/src/BarRenderer.cj:394-415`（正值域下界固定 0、上界 `dataMax * 1.05`）、`f_chart/src/AreaChart.cj:355-365`（含 0）、`f_chart/src/LineChart.cj:457-478`（`lineRange` 真正的双向 5%）
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、§11「与规格冲突」；§2「同一规则两套口径」
- **证据**：静态确定 —— 同一句通用规则在 `line`/`scatter` 成立、在 `bar`/`area` 不成立；柱/面积的设计文档给的是另一套（`doc/spec/add-f-chart-bar/design.md:49-52`：下界 `min(0, 数据最小值)`；`add-f-chart-area/design.md:16`：取 0 与极值的并集）
- **描述**：全正数据下规范让人预期下界 `dataMin*0.95`，实际柱/面积是 0（数据 100–110 时柱子几乎等高）。这是"坐标与数值边界"描述错误，也让规范与自己各图的设计文档矛盾
- **建议**：拆成两类并写清适用范围——类目柱/面积/堆叠「默认含 0 基线」；XY 曲线/散点「双向 5% 余量」；两条都保留"全为 `null` 时 `[0,1]`"兜底

### [轻微][存量] #17 字段命名约定自相矛盾："节点关系一律 `nodes` / `links`"，但流程图 / 决策树 / 泳道图用 `edges`

- **位置**：`f_chart/doc/chart-json-spec.md:13`（约定 2）、`f_chart/doc/f_chart模块设计.md:128`（同款约定）；违反处 `:2065`（决策树）、`:2164`（流程图）、`:2241`（泳道图「`edges` 同流程图」）
- **来源**：存量
- **判据**：review-checklist §2「同一语义只用一个字段名」正是规范自立的规则；§13「自相矛盾」
- **证据**：静态确定 —— 同文件前后矛盾，无需对照实现；实现按 `edges` 解析（`src/Flowchart.cj:199`、`src/DecisionTreeChart.cj:130`、`src/SwimlaneChart.cj:149`）
- **描述**：把桑基图的 `links` 搬到流程图会得到空边或 `MissingField`。这不是实现缺陷，是契约层命名分裂，且规范自己没给例外说明
- **建议**：§1 约定 2 补例外（`edges` 用于带标签的有向边、`links` 用于带权重流量），或统一改名并在各图注明兼容别名

### [轻微][存量] #18 规范未给任何计数型字段上限或拒绝路径，`cells` / `turns` / `tickCount` / `bins` 全是无界用户输入

- **位置**：`f_chart/doc/chart-json-spec.md:410`（`cells` 默认 100）、`:727`（`turns`）、`:86`（`tickCount`）、`:758`（`bins`）；§7「校验规则」（`:2699-2714`）只列结构与数值合法性
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度预分配 / 无界容器」「必须有量化判据与拒绝路径」；§13「关键段落缺失：限制条件缺失」
- **证据**：静态确定（文档侧）—— 规范全文没有这些字段的上限；实现侧抽查 `src/WaffleChart.cj:41-49` 只校验"≥1 的整数"，`cells` 直接决定循环次数与 `rect` 数量（`:123-125`）
- **描述**：输出体积与这几个字段线性相关，`cells=10^6` 会生成 10^6 个矩形并拼进同一个字符串。规范不告诉使用者"多大安全"，实现也没有上限，等于把 OOM 面留给调用方猜。这是文档层唯一可判定的"资源与内存"缺口
- **建议**：§7 增加「资源上限」小节（如 `cells ≤ 10000`、`tickCount ≤ 50`、`bins ≤ 1000`，超限 `InvalidValue`），实现按同一上界校验。**范围外提示**：`WaffleChart.cj:41-49` 目前无上限，属代码侧 OOM 面，留给 `.cj` 部分确认

## 优化可行性方案

本部分只有 `.md`，没有可执行的分配 / 循环 / 布局代码，**堆内存 0 条、CPU 0 条**。核对时读到的 `SankeyChart` 布局、`PieChart` 弧路径、`ChartFrame` 边距计算等实现均属其他子轮文件；scope 也未提供 f_chart 的 `cjprof` / `cjpm bench` 数据，任何"热点 / 降内存"结论都不成立，故不预置方案。

### [堆内存] 无

- 本部分无 `.cj`，没有可测量的内存契约。

### [CPU] 无

- 同上。若后续子轮在 `SankeyChart`（布局遍数）或各图刻度/路径生成上取得自耗时占比，须按 `perf §6.1` 补齐工具、输入规模与对照后再立项。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 层级图（treemap / sunburst / flame / org）递归深度随 `nodes` 链增长，深链会先爆栈 | `chart-json-spec.md:1318`、`:1397`、`:2271` | 实现是否递归、深度上界 | 构造 1k / 10k / 20k 层单链 `nodes` 调 `draw`，记录是否栈溢出与崩溃栈深（`cjprof` 栈采样） |
| 2 | 单次 `draw` 把整份 SVG 拼成 `String`，大点集下峰值内存与图元数线性增长 | `chart-json-spec.md:8`（返回完整 SVG 字符串） | 峰值 RSS / `getAllocatedHeapSize()` | `scatter` 输入 10k / 100k / 1M 点各跑 10 轮，记录峰值与 GC 后回落值，取中位数与离散度 |
| 3 | `cells` 无上限导致耗时与内存线性爆炸（见 #18） | `chart-json-spec.md:410`、`src/WaffleChart.cj:41-49` | 10^5 / 10^6 格的实际耗时与峰值 | `cells=10^5,10^6,10^7` 各跑一次，记录墙钟时间与峰值内存，定位失败点 |
| 4 | 绘图区左边距按"刻度文本最大宽度"估算，CJK 标签下可能重叠或溢出 | `doc/spec/add-f-chart-bar/design.md:45-46`、`src/BarRenderer.cj:83` | CJK 标签的实测布局 | 用 20 个 CJK 类目 + 6 位数值画柱图，导出 SVG 后复核 `tick-label` 的 `x` 是否越过绘图区左边界、相邻标签是否重叠 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_chart.part3.txt` 一一对应（该文件 20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/chart-json-spec.md` | .md | ✅ | 2723 行全读；§2 通用字段、§3 代号、§4 索引（108 行 / 105 个唯一 type）、§5.1–5.11 逐图专属字段、§7 校验规则逐项回查 `src/`。问题：#1–#14、#16–#18 |
| 2 | `f_chart/doc/f_chart模块设计.md` | .md | ✅ | 317 行全读；接口、信封表、渲染管线、TUI 段与 `ChartConfig.cj`、`ChartFrame.cj`、`tui/*.cj` 对照（TUI 80×24 与最小 20×8 见 `TuiFrame.cj:69`，一致）。问题：#1（`annotations`）、#15 |
| 3 | `f_chart/doc/spec/add-f-chart-alluvial/design.md` | .md | ✅ | 17 行；列高扣 `gap*(n-1)`、节点总量取出入边较大值、带宽透明度 0.35，与 `AlluvialChart.alluvialHeights`（额外对 `usable<=0` 钳 0）一致；归档口径下自洽 |
| 4 | `f_chart/doc/spec/add-f-chart-alluvial/proposal.md` | .md | ✅ | 27 行；`nodeWidth` 14 / `nodeGap` 10 与 class 名一致 |
| 5 | `f_chart/doc/spec/add-f-chart-alluvial/specs/chart-rendering/spec.md` | .md | ✅ | 44 行；`alluvialHeights([1,1],100,10) = [45,45]` 与公式自洽（100−10×1=90，均分 45） |
| 6 | `f_chart/doc/spec/add-f-chart-alluvial/tasks.md` | .md | ✅ | 6 行；归档任务清单 |
| 7 | `f_chart/doc/spec/add-f-chart-arc/design.md` | .md | ✅ | 20 行；半径 0.35 短边（`ArcChart.cj:129`）、控制点 `mid + (center-mid)*arcHeight`（`:159-160`）逐式对上 |
| 8 | `f_chart/doc/spec/add-f-chart-arc/proposal.md` | .md | ✅ | 27 行；`arcHeight` 0.5、`sort` 取值、class 名一致 |
| 9 | `f_chart/doc/spec/add-f-chart-arc/specs/chart-rendering/spec.md` | .md | ✅ | 44 行；`sort` 默认 `none`（`ArcChart.cj:64`）、越界抛 `InvalidValue`（`:60-67`）、排序用例与降序语义自洽 |
| 10 | `f_chart/doc/spec/add-f-chart-arc/tasks.md` | .md | ✅ | 6 行；归档任务清单 |
| 11 | `f_chart/doc/spec/add-f-chart-area/design.md` | .md | ✅ | 26 行；`areaStyle.opacity` 0.3 与实现一致（是规范 #3 的反证）；null 分段、基线钳制、y 含 0 均对上 |
| 12 | `f_chart/doc/spec/add-f-chart-area/proposal.md` | .md | ✅ | 28 行；0.3、默认不画 symbol 与实现一致 |
| 13 | `f_chart/doc/spec/add-f-chart-area/specs/chart-rendering/spec.md` | .md | ✅ | 49 行；混用形状抛 `InvalidValue`（`AreaChart.cj:83-85`）、`fill-opacity` 口径与 `AreaChart.cj:469` 一致 |
| 14 | `f_chart/doc/spec/add-f-chart-area/tasks.md` | .md | ✅ | 6 行；归档任务清单 |
| 15 | `f_chart/doc/spec/add-f-chart-bar/design.md` | .md | ✅ | 92 行；六件套文件均存在（且此处写的是 `ChartConfig.cj`，反证 #15）；柱宽 0.6（`BarRenderer.cj:128`）、负值双向、nice 刻度与实现一致；「最小边距 40」未在 `ChartFrame` 找到对应常量，仅记信息不报 |
| 16 | `f_chart/doc/spec/add-f-chart-bar/proposal.md` | .md | ✅ | 27 行；能力清单与 `src/BarChart.cj`、`BarRenderer.cj` 一致 |
| 17 | `f_chart/doc/spec/add-f-chart-bar/specs/chart-rendering/spec.md` | .md | ✅ | 73 行；`UnsupportedChart`（`ChartConfig.cj:171-178`）、长度校验（`BarRenderer.cj:304`）、无名单系列隐藏图例（`:72`）均成立 |
| 18 | `f_chart/doc/spec/add-f-chart-bar/tasks.md` | .md | ✅ | 29 行；归档任务清单 |
| 19 | `f_chart/doc/spec/add-f-chart-bland-altman/design.md` | .md | ✅ | 22 行；`sd` 分母 `n-1`、`n=1` 时 0、`±1.96sd`（`BlandAltmanChart.cj:243`）、点半径 3.5 一致 |
| 20 | `f_chart/doc/spec/add-f-chart-bland-altman/proposal.md` | .md | ✅ | 26 行；`bland-altman-point/-mean/-limit` class 名与实现一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无控制流与外部输入，代码层正确性/语言特性不适用。正确性：契约与实现不符（#1 / #2 / #9 / #16）；设计：`padding` 同键二义（#8）。可读性未发现结构问题（11 节 + 索引 + 逐图小节可用）；安全性未发现凭据、注入面或危险示例 |
| §1 死代码 | 0 | 本部分无 `.cj`，不判代码死代码。做的是反向「文档声明是否有实现引用」核查：`annotations`、`series[].label`、`series[].opacity`、`histogram.normalize`、`pie.innerRadius`、`sankey.iterations`、`pareto.cumulativeFormat`、`symbol=triangle`、`shap.features`、`gantt.lane` 共 10 项在 `src/` 无读取点，按「承诺未实现」记入 §14（#1 #2 #5 #6 #7 #12 #13）。文档侧的悬空文件引用 `ChartSpec.cj`（`f_chart模块设计.md:39`）经 `ls` + `grep` 确认不存在，计入 §13 发现 #15，不重复统计 |
| §2 重复逻辑 | 3 | 把「同一字段/默认值在多处出现」的 14 组（`padding`、`areaStyle.opacity`、`bins`、`innerRadius`、`startAngle`、`nodeWidth`、`nodeGap`、`colorRange`、`showValues`、`title.fontSize`、`legend.position` 等）两两比对：命中 3 组漂移——`areaStyle.opacity` 规范 0.2 / 归档 0.3 / 代码 0.3·0.6（#3）、`flows` 端点键正文 `from/to` 与示例 `source/target`（#10）、类型→文件→形状映射表在 `chart-json-spec.md:135-243` 与 `f_chart模块设计.md:140-245` 各维护一份并已漂移（#11 / #15）；其余口径一致。5 套 change 目录的 proposal/spec/design/tasks 同模板复制属 OpenSpec 格式要求，按误报边界不报 |
| §3 空实现 | 0 | 本部分无函数体。`annotations` 在实现层等价于"收下不处理"，但属"字段未接线"而非空函数，按 §14.1 记在 #1，避免两类重复统计 |
| §4 栈溢出 | 0 | 文档未声明递归算法或深度上限，没有可判的承诺；层级图深度由 `nodes` 链决定这一面只能到实现取证，已列入待验证假设 #1 |
| §5 OOM | 1 | #18：`cells` / `turns` / `tickCount` / `bins` 无上限、无拒绝路径文档；放大路径在代码侧（`WaffleChart.cj:41-49`），已标范围外提示 |
| §6.1 热点瓶颈 | 0 | scope 未提供 f_chart 的 `cjprof` / `cjpm bench` 数据，本部分也无代码可定位，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 文档不涉及锁；`Chart` 契约声明纯函数 |
| §6.3 并发串行 | 0 | 不适用（无任务提交与等待） |
| §6.4 低效算法 | 0 | 文档级复杂度承诺只有直方图 `sqrt(n)` 分箱（与代码一致，见 #2 的默认值问题，非复杂度问题）与桑基固定遍数；未发现"文档声明 O(n) 实际 O(n²)"的相反表述 |
| §7 降堆内存方案 | 0 | 无 `.cj`、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数；图表返回值必然逃逸（整份 SVG 字符串），不满足逃逸检查前提 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无 `.cj`。核对时撞见的代码层唯一冲突（`CirclePackingChart.cj:55` 与 `ChartConfig.cj:187` 共用根级 `padding` 键）已按文档字段二义记入 §13 发现 #8，不重复计入；另核对过 `min >= max` 在 `BarRenderer.cj:414`、`LineChart.cj:474` 均有 `InvalidValue`（规范 `:2714` 成立），空数据兜底 `[0,1]` 成立（`BarRenderer.cj:372-375`） |
| §12 并发安全与锁粒度 | 0 | 规范与 `Chart` 接口（`src/Chart.cj:22-27`）声明"纯函数、不依赖全局可变状态、确定性输出"；机械核对：`grep "^var \|static var" src/*.cj` 零命中，无顶层可变状态，声明与实现一致 |
| §14 功能完备性与 README 覆盖 | 8 | #1（`annotations` / `series.label` / `series.opacity`）、#2（`normalize`）、#5（`pie.innerRadius`）、#6（`sankey.iterations`）、#7（`pareto.cumulativeFormat`）、#9（`treemap.tiling=slice`）、#13（`shap.features` / `gantt.lane`）、#14（`donut` / `network-heatmap` 四字段未登记）。反向核对：§4 索引的 105 个唯一 `type` 全部能在 `src/` 找到对应解析；列出的实现文件逐个 `test -f` 全部存在；主题 10 色、`legend` 五项默认、轴 `tickCount=5` / `logBase=10` / `labelFormat={value}` / `grid` 默认与 `ChartTheme.cj`、`ChartConfig.cj:59-108` 一致。README 覆盖度属第 1、2 部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；5 套归档变更按「当时结论是否自洽」核对，未发现自相矛盾（其与当前实现的差异不计为文档缺陷） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 18 条（严重 0 / 一般 9 / 轻微 9），是否纳入修复待用户决定；本报告只读文件，未做任何修改。

## 总评

这 20 份文档的**骨架质量很高**：`doc/spec/` 下 5 套归档变更逐条都能在 `src/` 找到对应实现，`alluvialHeights([1,1],100,10)=[45,45]`、弧半径 0.35 短边、控制点公式、`sd` 分母 `n-1`、面积透明度 0.3、柱宽 0.6 等可机械核对的数值全部对得上；规范的 105 个唯一 type 与实现逐个对齐，108 行索引里列出的实现文件一个不缺，主题调色板、图例与轴默认值也与 `ChartTheme` / `ChartConfig` 完全一致。问题不在结构，而在 `chart-json-spec.md` 自称「唯一字段真相」之后**缺少与代码的同步机制**。

风险集中在四类：

1. **字段只存在于文档**（一般 5 / 轻微 1）：`annotations`（整块能力，含 `series[].label` / `opacity`，#1）、`pie.innerRadius`（#5）、`sankey.iterations`（#6）、`pareto.cumulativeFormat`（#7）、`histogram.normalize`（#2 的一部分）、`shap.features` / `gantt.lane`（#13）都会「收下不报错、什么也不做」。其中 `annotations` 还同时写在设计文档的信封表里——调用方按文档写参考线拿不到图也不会得到异常，这是本部分最值得排期的一类。
2. **默认值写错**（一般 3）：`areaStyle.opacity` 0.2 vs 0.3/0.6（#3）、`density.fill` true vs false（#4）、直方图 `bins` 10 vs `floor(sqrt(n))`（#2 的另一部分）。单项影响小，但规范是字段真相，错一个默认值就会让自建图与样例对不上，而 `charts/` 视觉基线会掩盖它（样例都显式写了参数）。
3. **文档允许、实现拒绝**（一般 2）：`treemap.tiling=slice`（#9）、`bins` 上界数组（#2 的第三部分）——这两处会直接抛 `InvalidValue`，比静默失效更容易被误判成"自己写错了 JSON"。
4. **字段语义冲突与过期**（一般 1 / 轻微 8）：`padding` 在通用表与 M70 之间一 key 两义（#8，示例本身就把画布边距从 24 改成了 2，这是唯一会改变布局结果的条目）；轴范围通用规则与柱/面积实现相反（#16）；`links` 与 `edges` 两套命名并存且规范自相矛盾（#17）；索引里两个形状代号互换（#11）；`flows` 正文与示例端点键不一致（#10）；`symbol=triangle` 静默降级成圆（#12）；`donut` / `network-heatmap` 四个可调字段未登记（#14）；设计文档的 `ChartSpec.cj` 已改名、里程碑表漏 M68（#15）；计数型字段没有上限章节（#18）。

没有阻塞项：以上都不改代码也能通过现有测试（这正是它们长期存在的原因），也没有发现会导致崩溃、数据错误或 OOM 的文档承诺本身。建议后续给 `chart-json-spec.md` 加一层机械校验（从 `src/` 的 `root.*("key")` / `seriesJson.*("key")` 抽取字段与默认值，与规范表格 diff），并优先修 #1 / #2 / #8——这三条决定用户"按规范写能不能跑"。

本部分无 `.cj`，因此**渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑、并发安全**这些专项未在本轮取证，不能据此对模块整体下结论；它们由包含 `src/**` 的其余 36 个子轮负责。

**范围外提示**：`src/WaffleChart.cj:41-49` 的 `cells` 无上限（OOM 面，见 #18）；`src/HeatmapChart.cj:192-196` 自行绘制 y 轴标题，可能与 `ChartFrame.drawYAxis`（`src/ChartFrame.cj:192-195`）重复输出（待确认，未展开）。
