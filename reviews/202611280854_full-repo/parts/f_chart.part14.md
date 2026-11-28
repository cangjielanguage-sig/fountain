# f_chart 模块审查报告

> **模块第 14/37 部分** —— 本报告只覆盖 `files/f_chart.part14.txt` 列出的 20 个文件：`doc/spec/` 下 6 个已归档变更（`add-f-chart-line` 2 份、`add-f-chart-lollipop` 4 份、`add-f-chart-manhattan` 4 份、`add-f-chart-module` 4 份、`add-f-chart-mosaic` 4 份、`add-f-chart-network-heatmap` 2 份）。本部分 **0 个 `.cj`**；为把每条条款落到实现行号，取证时另读了 `src/{LineChart,LollipopChart,ManhattanChart,MosaicChart,NetworkHeatmapChart,ChartScale,ChartTheme,ChartTime,ChartConfig,ChartException,Chart,ForestChart}.cj` 与 `ChartGallery_test.cj` 的片段。这些 `.cj` 属 `src/**` 子轮，只作证据引用，不占本部分文件覆盖统计。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，`git diff` 为空 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮专项「渲染 / 布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑」。本部分全为归档 OpenSpec 文档，按 checklist §13 的归档条款核对「当时结论是否自洽」，并用 `git log` 确认文档与实现是否同一提交，避免把后续代码演进误判成文档过期。
- **报告版本**：v1（第 14/37 部分）

## 发现

### [一般][存量] #1 曼哈顿图 proposal 承诺的 `manhattan-chromosome` 染色体名标注无验收条款、无实现

- **位置**：`f_chart/doc/spec/add-f-chart-manhattan/proposal.md:12`（承诺）；同变更 `specs/chart-rendering/spec.md:5-12`（无对应 Requirement）、`design.md:13-18`（无对应图元）
- **来源**：存量（快照无基线；`git log` 显示 `proposal.md` 与 `ManhattanChart.cj` 同属提交 `77980d72c`，即归档时既已不一致）
- **判据**：review-checklist §14.1「承诺了但没实现」（承诺源 + 缺失证据双证）、§13「归档变更的结论不自洽」
- **证据**：静态确定 —— 全仓检索 `manhattan-chromosome` 只在 `proposal.md:12` 命中，`f_chart/src/` 与 `*_test.cj` 零命中（`.worktrees/` 副本不计）；`ManhattanChart.cj:134-147` 生成的是数值 nice ticks，`:222` 走 `drawXAxisNumeric(kit, xTicks, xScale, xTickLabels)`，全图没有任何"染色体名"文本；`design.md:18` 反而写"改为按显示位置生成 nice ticks"，说明设计阶段已经放弃染色体名，却没有回写 proposal / 补一条"被裁剪"的说明。
- **描述**：proposal 把"染色体名称以 `manhattan-chromosome` 文本标注"列为本次变更的输出之一，spec 的验收面与实现都没有它。按 proposal 写 CSS（`.manhattan-chromosome { … }`）或做文本断言的下游使用者必然落空；归档 `openspec validate` 只校验 spec，不会发现 proposal 多承诺了一层。
- **建议**：二选一并写进 spec。保留：补 Requirement「每组染色体起始处 MUST 输出 `class="manhattan-chromosome"` 文本，内容为该染色体名」并实现；裁剪：删掉 `proposal.md:12` 该句，并在 `design.md:18` 记明"横轴改为数值刻度，不再标注染色体名"。

### [一般][存量] #2 曼哈顿图两处视觉契约与实现不符：配色是调色板轮转而非两色交替，阈值线标注是数值而非「阈值」

- **位置**：`f_chart/doc/spec/add-f-chart-manhattan/specs/chart-rendering/spec.md:7`、`design.md:15`（配色）；`design.md:17`（阈值线标签）；对照 `f_chart/src/ManhattanChart.cj:213`、`:195-201`、`f_chart/src/ChartTheme.cj:18-21`、`:54-59`
- **来源**：存量（快照无基线；文档与实现同属提交 `77980d72c`）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§11「语义与命名 / 注释不符」
- **证据**：静态确定 —— `spec.md:7` 要求"颜色 MUST 按染色体顺序在两种主题色之间交替"，`design.md:15` 写"按染色体索引奇偶在主题前两色间交替"；实现是 `config.theme.colorAt(chromosomeIndex)`，而 `ChartTheme.colorAt` 是 `palette[index % palette.size]`，默认 `CHART_DEFAULT_PALETTE` 有 10 色。结果是第 1/2/3 条染色体依次取蓝 / 橙 / 红，第 11 条才回到第 1 色，不存在"奇偶两色交替"。阈值线一处：`design.md:17` 写"右端标注 `阈值`"（反引号内是字面量），实现 `195-201` 输出的是 `chartFormatTick(value, config.yAxis.labelFormat)`（默认 `"{value}"`，`ChartConfig.cj:62`），即阈值数值，类名 `manhattan-threshold-label`。
- **描述**：配色一条是 spec 级 MUST 与实现相反：按 spec 写的视觉回归（第 2、4、6 条同色）在当前默认主题下会失败，反之按实现写的断言无法在 spec 找到依据。阈值标签一条是 design 与实现的文案差异；若 `阈值` 想表达"标注阈值（值）"，则现状可接受，但文档用反引号写成了字面量，无法唯一判定。数据正确性不受影响。
- **建议**：配色二选一——实现改 `config.theme.colorAt(chromosomeIndex % 2)`（贴合"交替"），或把 `spec.md:7` / `design.md:15` 改成"按染色体索引轮转主题调色板"（贴合当前实现，且 10 色区分度更好）。阈值标签同理：实现补 `阈值` 前缀，或 design 改成"右端标注阈值数值"。改完在 `ManhattanChart_test.cj` 补一条颜色/标签断言钉住。

### [一般][存量] #3 棒棒糖图纵轴两条 MUST 互斥，`yAxis.min > 0` 时茎基线被外推到绘图区之外

- **位置**：`f_chart/doc/spec/add-f-chart-lollipop/specs/chart-rendering/spec.md:30`、`design.md:10`；对照 `f_chart/src/LollipopChart.cj:112-131`、`:187`、`:198-201`、`f_chart/src/ChartScale.cj:36-43`
- **来源**：存量（快照无基线；文档与实现同属提交 `3a0b00e1f`）
- **判据**：review-checklist §11「契约与实现不符」「缺少边界校验」、§13「规格与实现漂移」
- **证据**：静态确定 —— `spec.md:30` 同一条里两条 MUST 无法同时满足："纵轴范围 MUST 包含 0" 与 "`yAxis.min` / `yAxis.max` 给出时 MUST 按给定值"；`yAxis.min = 2` 时没有裁决优先级。`design.md:10` 用"范围至少包含 0；`yAxis.min` / `yAxis.max` 可覆盖"暗示覆盖优先，但没写覆盖后基线取哪。实现选了覆盖优先（`LollipopChart.cj:124-131` 直接采用给定值，缺省时 `dataMin/dataMax` 以 0 初始化以保证含 0），而 `:187` 无条件 `yScale.scale(0.0)` 作基线。`LinearScale.scale` 是纯线性外推、无钳制（`ChartScale.cj:36-43`）：`yMin = 2` 时 `scale(0)` 落在 `plot.bottom()` 之下，`chart` 也没有任何 `clipPath`（`ChartFrame.cj` / `ChartSvgKit.cj` 检索 `clip` 无命中），茎线（`198-201`）从 x 轴标签区画到数据点。
- **描述**：合法输入（为了放大 4.0–5.0 的转化率区间而设 `yAxis.min > 0`）会得到"茎从画布下方长出来、穿过类目标签"的图，既无异常也无裁剪；`yAxis.max < 0` 时对称地向上溢出。这是本部分唯一"输入合法、图形错误"的条目。
- **建议**：把 spec 两条合并成可判定的一条：「未显式给 `yAxis.min` 时下界取 `min(0, 数据最小值)`；显式给定时基线取 `clamp(0, yMin, yMax)`」；实现侧 `baseline = yScale.scale(clamp(0.0, yMin, yMax))`，并补 `yAxis.min > 0`、`yAxis.max < 0` 两个用例。

### [一般][存量] #4 马赛克图「列总和 MUST 大于 0」口径不明，零列静默产出零宽单元与重叠标签

- **位置**：`f_chart/doc/spec/add-f-chart-mosaic/specs/chart-rendering/spec.md:34`、`design.md:5`；对照 `f_chart/src/MosaicChart.cj:94-101`、`:156-177`、`MosaicChart_test.cj:118-133`
- **来源**：存量（快照无基线；文档与实现同属提交 `60c08fa90`）
- **判据**：review-checklist §11「缺少边界校验」「语义与命名 / 注释不符」、§13「规格与实现漂移」
- **证据**：静态确定 —— `spec.md:34` 的校验清单写"列总和 MUST 大于 0"，`design.md:5` 写"值必须非负，列总和大于 0"，两处都没有说"每一列"还是"所有列合计"。实现只校验合计：`94` 求 `totals` 后 `97-98` 累加，`99-101` 仅在 `grandTotal <= 0.0` 时抛 `InvalidValue`（文案仍是"列总和必须大于 0"）；`:156` `columnWidth = totals[column] / grandTotal * plotWidth`，某列全 0 时宽度为 0，`158-171` 仍按系列数输出该列的 `width=0` 矩形，`:172-178` 的 `mosaic-label` 落在 `cursorX + 0/2`，与相邻列标签挤在同一坐标附近。`MosaicChart_test.cj:118-133` 的 `rejectsZeroTotal` 只覆盖"所有列全 0"。
- **描述**：合法输入（例如第 3 类两个系列都是 0）会得到"少一列可见单元 + 标签重叠"的图；按 spec 写"某列合计为 0 → 抛 InvalidValue"的用例会失败，按实现写"合计为 0 才抛"的用例会通过，验收口径取决于解释。
- **建议**：在 spec / design 明确写成"任意一列的合计 MUST 大于 0"，实现加逐列校验并抛 `chartInvalidValue("series", "第 N 列合计必须大于 0")`；若产品上允许空列，则明确"合计为 0 的列不输出单元与标签，宽度 0 且后续列紧邻"，并补一个"4 列含 1 个零列"的用例钉住。

### [一般][存量] #5 网络热力图只约定 N×N 矩阵、不设节点数上限，平方放大后没有拒绝路径

- **位置**：`f_chart/doc/spec/add-f-chart-network-heatmap/design.md:5-6`、`:10`、`proposal.md:11`；对照 `f_chart/src/NetworkHeatmapChart.cj:43`、`:80`、`:182-204`
- **来源**：存量（快照无基线；文档与实现同属提交 `1ea3e056b`）
- **判据**：review-checklist §5「平方级增长」「按不可信长度预分配」、§14.1「契约要求但无拒绝路径」
- **证据**：静态确定（放大关系）+ 需实测（峰值字节）—— `design.md:6` 要求"`series[0].data` 必须为 N×N 数值矩阵，N 等于节点数"，`:10` 要求绘图区按 N 等分；实现只校验方阵与阶数一致（`80-100`）、`nodes` 非空（`43`），**没有任何上限**，随后 `182-192` 双层循环输出 order² 个 `network-heatmap-cell`，`showValues` 为 true 时 `193-203` 再输出 order² 个文本。N=1000（JSON 约 3 万字符）→ 10⁶ 个矩形，按每段 `<rect …/>` 约 90–120 B 估算，仅最终 SVG 字符串就 90–120 MB，`SvgBuilder` 扩容期间还要再翻一份；N=3000 → 9×10⁶ 个矩形，1 GB 量级。
- **描述**：输入体积与输出体积是平方关系，"小输入放大成大输出"。文档层没有任何"上限 / 分批 / 拒绝"条款，照 spec 实现也不会想到加保护。是否升为严重取决于 `nodes` 是否来自外部请求，文档没声明输入信任边界，故按"库调用方可控"记一般，峰值数据列入待验证假设 #1。
- **建议**：在 design / spec 加常量上限（例如 `order <= 200`，对应 4 万个单元）并在超限时抛 `chartInvalidValue("nodes", "节点数超过 N 上限")`；同时在 design 注明"图元数 = N²，`showValues` 时文本再乘 1"。若确需大矩阵，另开"降采样 / 分块"需求，而不是放开上限。

### [轻微][存量] #6 曼哈顿图 design 留着两处草稿残句（自问自答 + 半句）

- **位置**：`f_chart/doc/spec/add-f-chart-manhattan/design.md:16`、`:18`
- **来源**：存量（快照无基线；同属提交 `77980d72c`）
- **判据**：review-checklist §10「可读性 / 可维护性」、§13（文档质量）
- **证据**：静态确定（文本）—— `16` 行原文"数据按显示位置排序后绘制折线？不画折线，只画散点。"，把设问和改口都留在结论段；`18` 行原文"x 轴刻度使用显示位置，标签保留原始数值格式不便，改为按显示位置生成 nice ticks。"，"不便"是删改留下的半句，读者无法判断被否掉的是哪种方案。
- **描述**：design 是维护者判断"为什么这样画"的唯一依据；这类残句让"是否画折线""x 轴标签到底是什么"重新变成开放问题，也是 #1 里"染色体标注被静默裁剪"没有被记录下来的同一处上下文。
- **建议**：`16` 行改为"只画散点，不画折线；点按显示位置绘制，不排序"；`18` 行改为"x 轴刻度按显示位置生成 nice ticks，标签为数值（不显示染色体名，见 proposal 裁剪说明）"。

### [轻微][存量] #7 模块设计把计划写成了现状：`ChartScale` 的「对数 / 分段比例尺」与 `testdata/` 黄金文件都不存在

- **位置**：`f_chart/doc/spec/add-f-chart-module/design.md:32`（ChartScale 职责）、`:162`（黄金文件测试策略）
- **来源**：存量（设计属 M0 提交 `53aed4b9c`；`ChartScale.cj` 在 M1 提交 `113c9eaf0` 落地，画廊在 `73c582164` 加入，均未回写设计）
- **判据**：review-checklist §13「文档过期」、§14.1「计划中的能力未落地」
- **证据**：静态确定 —— `ChartScale.cj` 只有 `LinearScale`（`:23`）与 `BandScale`（`:47`）两个比例尺类，检索 `LogScale` / `SegmentScale` / "分段" 零命中；对数轴是在 `ForestChart.cj:110` 用 `axisType == "log"` 内联实现（`:230-243`），没有共享比例尺。测试侧：`f_chart/` 下无 `testdata/` 目录，`src/*_test.cj` 检索 `testdata` / `File.read` 零命中；`ChartGallery_test.cj:24-38` 只把 SVG 写进 `charts/` 并断言 `contains("<svg")`，不构成逐字节或结构比对，`ComboChart_test.cj` 等 5 个"结构复杂"的图也没有黄金文件比对。
- **描述**：按 design 找 `ChartScale` 的对数 / 分段比例尺会找不到；按"黄金文件放 `testdata/`"找回归基线也找不到。前者把"共享基础设施"的范围写大了（真实实现是各图内联），后者让 M7/M9/M10/M36/M85 这些最易回归的图只剩 `contains("<svg")` 级断言。两者都不影响当前产物运行，属文档与工程现状脱节。
- **建议**：design 的目录注释改成"线性 / 带状比例尺（internal；对数轴目前由 ForestChart 内联实现）"；测试策略改为"样例画廊 `charts/` + 关键结构断言"，或按原计划补 `testdata/` 黄金比对（二选一，别让文档悬空）。

### [轻微][存量] #8 网络热力图文档点名复用 `heatmapColor`，实现用的是另一支 `heatFlameColor`

- **位置**：`f_chart/doc/spec/add-f-chart-network-heatmap/design.md:11`、`proposal.md:27`；对照 `f_chart/src/NetworkHeatmapChart.cj:189`、`f_chart/src/HeatFlameChart.cj:260`、`f_chart/src/HeatmapChart.cj:225`
- **来源**：存量（快照无基线；文档与实现同属提交 `1ea3e056b`）
- **判据**：review-checklist §13「API / 配置与源码不符」、§11「语义与注释不符」
- **证据**：静态确定 —— `design.md:11` 写"用 `heatmapColor` 在 `colorRange` 上插值"，`proposal.md:27` 写"复用 `heatmapColor` 与热力图的单元格布局"；实现 `NetworkHeatmapChart.cj:189` 调的是 `heatFlameColor(ratio, colorRange)`（定义在 `HeatFlameChart.cj:260`，签名为 `(ratio, colors: Array<String>)`）。`heatmapColor` 是 `HeatmapChart.cj:225` 的三色版 `(ratio, low, mid, high)`，本图并未调用。
- **描述**：文档点名的助手不是实际使用的那个。维护者按 design 去改 `heatmapColor` 不会影响本图；反过来，本图对 `HeatFlameChart.cj` 的内部函数存在跨图文件依赖，文档里也看不到。属于"复用关系记错"，不影响输出正确性。
- **建议**：把两处文档改成 `heatFlameColor`（并注明它来自 `HeatFlameChart.cj`）；或把"任意长度色带插值"抽到 `ChartSvgKit` / `ChartScale` 一类公共助手，让 heatmap / heat-flame / network-heatmap 共用，但这属实现侧改动，需另开条目。

## 优化可行性方案

> 本部分 20 个文件全为归档规格文档，没有可测量对象（无函数、无数据结构、无生命周期）。堆内存 / CPU 方案与 local mode 改造均**不提出**：任何收益数字只能来自 `src/**`，属其他子轮，写在这里就是无基线猜测。唯一有量化意义的放大面已作为 #5 记录，其峰值数据列入待验证假设 #1。

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 网络热力图 N×N 输出的峰值内存与耗时（#5 的量化） | `f_chart/src/NetworkHeatmapChart.cj:182-204` | N=200 / 500 / 1000 时的 SVG 字节数、`getAllocatedHeapSize()` 峰值、单次 `draw` 耗时中位数 | `cjpm bench -O2` 跑三档 N 各 30 轮取中位数；同时记录 `svg.size` 与分配量差值 |
| 2 | 曼哈顿图按染色体分组的线性查找是否成为热点 | `f_chart/src/ManhattanChart.cj:205-210`（`chromosomeOrder.contains`）、`:238-247`（`manhattanPositions` 内再扫一遍） | 位点数 10⁵–10⁶、染色体数 ≤ 25 时该循环在 `draw` 内的自耗时占比 | `cjprof record` 跑 GWAS 规模输入，看 `ManhattanChart.draw` 内该循环是否 > 5%；锁竞争不适用（纯单线程） |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part14.txt` 一一对应，20 行齐全。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-line/specs/chart-rendering/spec.md` | .md | ✅ | 4 条 Requirement 均可对到实现：混合形状 `LineChart.cj:100-106` 抛 `InvalidValue`；缺测在 `398/401` 调 `flushSegment` 形成两段 path（`404-443`）；`smooth` 输出 `Q`（`416-421`）；`symbol: none` 不画符号（`448`）；`time` 轴由 `ChartTime.formatDays` 输出 `YYYY-MM-DD`，满足"刻度含 `2026-01`" |
| 2 | `f_chart/doc/spec/add-f-chart-line/tasks.md` | .md | ✅ | 3 项全 `[x]`；2.1 点名的 `ChartTime`（`ChartTime.cj:25`）、`ChartSvgKit.circle`（`:123`）、`ChartFrame.drawXAxisNumeric`（`:278`）都存在；`LineChart_test.cj` 10 个用例覆盖任务所列 8 类 |
| 3 | `f_chart/doc/spec/add-f-chart-lollipop/design.md` | .md | ✅ | §1/§3 与实现一致（`symbolSize` 默认 8、`<=0` 抛错 `LollipopChart.cj:75-78`；2px 茎 `198-201`；半径 `symbolSize/2` `192`）；§2 纵轴与 spec 互斥，见 #3 |
| 4 | `f_chart/doc/spec/add-f-chart-lollipop/proposal.md` | .md | ✅ | `type`、数据形状、`lollipop-stem` / `lollipop-head`、`symbolSize` 默认 8 与实现一致 |
| 5 | `f_chart/doc/spec/add-f-chart-lollipop/specs/chart-rendering/spec.md` | .md | ✅ | 茎/圆头计数、缺测跳过、`symbolSize>0`、长度校验（`LollipopChart.cj:103-110`）成立；纵轴条款自相矛盾，见 #3 |
| 6 | `f_chart/doc/spec/add-f-chart-lollipop/tasks.md` | .md | ✅ | 3 项全 `[x]`；`LollipopChart.cj` / `LollipopChart_test.cj` 均存在（7 个用例） |
| 7 | `f_chart/doc/spec/add-f-chart-manhattan/design.md` | .md | ✅ | §2 位置公式与 `manhattanPositions`（`238-292`）一致；§3 半径 3px 一致；配色与阈值标签见 #2；草稿残句见 #6 |
| 8 | `f_chart/doc/spec/add-f-chart-manhattan/proposal.md` | .md | ✅ | `type`、`{x,y,chromosome}`、`threshold` / `chromosomeGap`、两个类名成立；`manhattan-chromosome` 未实现，见 #1 |
| 9 | `f_chart/doc/spec/add-f-chart-manhattan/specs/chart-rendering/spec.md` | .md | ✅ | 散点计数、位置公式、阈值线、校验（`MissingField` / 负 gap → `InvalidValue`）成立；配色要求见 #2 |
| 10 | `f_chart/doc/spec/add-f-chart-manhattan/tasks.md` | .md | ✅ | 3 项全 `[x]`；`manhattanPositions` 与 7 个用例存在 |
| 11 | `f_chart/doc/spec/add-f-chart-module/design.md` | .md | ✅ | §3 接口（`Chart.cj:27,35`）、`ChartErrorKind` 四值（`ChartException.cj:21-29`）、`path` 字段（`58`）、依赖（`cjpm.toml:2-4`）一致；§2/§8 的"计划写成现状"见 #7 |
| 12 | `f_chart/doc/spec/add-f-chart-module/proposal.md` | .md | ✅ | 包名、依赖方向、`.modules:63`、根 `cjpm.toml:36` 一致；proposal 未列 `f_base` 属简写，不判 |
| 13 | `f_chart/doc/spec/add-f-chart-module/specs/chart-rendering/spec.md` | .md | ✅ | `draw` 返回完整 SVG、无全局注册表、四类 `kind`、错误带字段路径均成立（`Chart.cj:27-36`、`ChartException.cj:57-73`） |
| 14 | `f_chart/doc/spec/add-f-chart-module/tasks.md` | .md | ✅ | 1.1–5.5 全 `[x]`；1.1–1.4 可从工程文件复核；3.3 的历史计数无法用当前 `chart-json-spec.md` 复核（后续 change 已扩充内容），未单列 |
| 15 | `f_chart/doc/spec/add-f-chart-mosaic/design.md` | .md | ✅ | §2 列宽/列内高度比例与 `MosaicChart.cj:156-171` 一致；§1 "列总和" 口径不明，见 #4 |
| 16 | `f_chart/doc/spec/add-f-chart-mosaic/proposal.md` | .md | ✅ | `type`、`mosaic-cell` / `mosaic-label`、`mosaicColumnTotals`（`MosaicChart.cj:186`）与实现一致 |
| 17 | `f_chart/doc/spec/add-f-chart-mosaic/specs/chart-rendering/spec.md` | .md | ✅ | 单元数（4×2=8）、列总和示例、标签、负值/长度校验成立；零列分支未定义，见 #4 |
| 18 | `f_chart/doc/spec/add-f-chart-mosaic/tasks.md` | .md | ✅ | 3 项全 `[x]`；9 个用例，含 `mosaicColumnTotals` 单测 |
| 19 | `f_chart/doc/spec/add-f-chart-network-heatmap/design.md` | .md | ✅ | `id` 唯一（`56-60`）、N×N 校验（`80-100`）、等分布局与 `cellGap/2`（`163-191`）、全等取 0.5（`187`）、深色白字（`196-199`）、行列 `tick-label`（`211-221`）一致；N 无上限见 #5；`heatmapColor` 见 #8；本文件无"校验"小节，校验在同 change 的 spec（下一部分） |
| 20 | `f_chart/doc/spec/add-f-chart-network-heatmap/proposal.md` | .md | ✅ | `type`、`nodes` 形状、`colorRange` / `showValues` / `cellGap`（`NetworkHeatmapChart.cj:127-146`）、两个类名一致；"复用 `heatmapColor`"见 #8 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 契约与行为不符 5 条（#1–#5），可读性 1 条（#6），文档与工程现状不符 2 条（#7、#8）。本部分无 `.cj`：值/引用语义、`Option` 惯用法、分层与依赖方向只在文档条款层面核对（`Chart.cj` 接口、`ChartException` 四类 kind、`cjpm.toml` 依赖三项均已对上）；无外部输入拼串、无凭据、无敏感数据，安全性不适用 |
| §1 死代码 | 0 | 20 个文件全为 `.md`，无声明可判。对实现侧只做"文档点名符号是否存在"的检索：`manhattanPositions`、`mosaicColumnTotals`、`ChartTime`、`ChartSvgKit.circle`、`ChartFrame.drawXAxisNumeric` 均存在；`manhattan-chromosome` 零命中（属缺失，#1）；`heatmapColor` 存在但不是本图用的那个（#8）。未对 `src/**` 的 `private` / `internal` 符号做引用统计——那属其他子轮 |
| §2 重复逻辑 | 0 | 已逐对比较 6 个 change 的文档：`proposal.md` 的 "New Capabilities / 无" 段落、5 份 spec 里"`type` 不匹配 → `UnsupportedChart`"条款属 OpenSpec 模板与逐变更契约要求，不判重复；4 份 design 的"数据 / 布局 / 校验"三段结构相同但内容各异；`add-f-chart-module/design.md:80-92` 的信封字段表注明"详见 `chart-json-spec.md`"，不构成第二份真相来源 |
| §3 空实现 | 0 | 5 份 spec 的每条 Requirement 都带可判定 Scenario；4 份 tasks 全部 `[x]` 且指向的源文件 / 测试文件都存在（已逐一检索）；无 `TODO` / `FIXME` / 占位章节。`network-heatmap/design.md` 缺"校验"小节是结构差异，校验条款在同 change 的 spec 里，实现有对应抛错（`NetworkHeatmapChart.cj:80-146`） |
| §4 栈溢出 | 0 | 文档只描述单趟流程：分组累加偏移（`manhattan/design.md:9-11`）、双层矩阵遍历（`network-heatmap/design.md:10`）、单层堆叠（`mosaic/design.md:9-10`），无递归 / 自引用结构描述。实现侧递归（若有）属其他子轮 |
| §5 OOM | 1 | #5（N×N 输出无上限，已按 90–120 B/矩形估算到 N=1000 / 3000 的 100 MB / 1 GB 量级；精确峰值列待验证假设 #1）。`cellGap` 过大导致负尺寸矩形属实现侧，part12 已报同源问题，此处不重复计 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分无运行时代码。唯一复杂度线索（`ManhattanChart.cj:205-210`、`:238-247` 的 `contains` 线性分组）已列入待验证假设 #2，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 6 个 change 的文档均不涉及锁；`Chart.draw` 契约明确纯函数、不依赖全局可变状态（`add-f-chart-module/design.md:57`） |
| §6.3 并发串行 | 0 | 文档无 `spawn` / `Future` / 线程池 / 定时任务描述 |
| §6.4 低效算法 | 0 | 已核 `manhattanPositions` 是"每组扫全量点"的 O(n·k)（k = 染色体数，通常 ≤ 25），没有耗时占比与 n 的拐点数据，按铁律只进待验证假设 #2；其余文档只描述比例换算与等分，无嵌套扫描 |
| §7 降堆内存方案 | 0 | 文档无"持有什么、多大、活多久"的可测对象（未引入缓存、队列、注册表）。不产出无基线方案 |
| §8 降 CPU 方案 | 0 | 同上；比例换算与字符串拼接都在实现侧，属其他子轮 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象描述；`Chart.draw` 的输出必须作为 `String` 返回（逃逸），local mode 的"函数返回即释放"前提不成立，且无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 5 | #1–#5，均为"文档契约与实现行为不符"或"契约自身矛盾"，每条都给了实现行号与同一提交的 `git log` 依据。只在本轮读到的文档涉及处取证，未做全仓考古 |
| §12 并发安全与锁粒度 | 0 | 文档未描述共享可变状态；纯函数契约（`add-f-chart-module/design.md:57-58`）排除"跨请求共享"路径。锁粒度无可谈对象 |
| §14 功能完备性与 README 覆盖 | 3 | #1（proposal 承诺的 `manhattan-chromosome` 无实现、无验收条款）、#5（契约要求 N² 输出但无拒绝路径）、#7（`testdata/` 黄金文件测试策略未落地）。README 覆盖本部分不涉及（`README.md` / `README_en.md` 在其他子轮） |
| §13 文档一致性 | 5 | #2（配色与阈值标签）、#3（纵轴两条 MUST 互斥）、#4（列总和口径）、#7（ChartScale 职责与黄金文件）、#8（`heatmapColor` 命名）。其余 Requirement / Scenario / Design 条款逐条核对一致：`ChartErrorKind` 四值、`draw` 签名、依赖方向、`mosaicColumnTotals` 入口、曼哈顿位置公式与测试断言 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.cj`，不含未读项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分覆盖 6 个变更的 20 份归档文档（折线、棒棒糖、曼哈顿、模块契约、马赛克、网络热力图）。**文档主体是可用的**：`line` 与 `module` 两个变更的条款几乎逐条能对上实现（混合形状抛 `InvalidValue`、缺测分段、`Q` 曲线、四类 `kind`、接口签名、依赖方向都对得上）；`lollipop` / `mosaic` 的计数类 Scenario（茎与圆头数、8 个单元、4 个标签）也与测试一致。问题集中在"归档时没有把实现取舍回写文档"这一类，且 #1–#5 全部与实现在同一提交引入，不是后来代码演进造成的过期。

风险分三层：

- **会画错图**（#3，一般）：棒棒糖图两条 MUST 互斥，`yAxis.min > 0` 时茎基线被外推到绘图区外、穿过类目标签。这是本部分唯一"输入合法、图形错误"的条目，建议优先修；修法（基线钳制）与 `HorizontalBarChart` 同源，可复用。
- **契约与实现各说一套**（#1 / #2 / #4，一般）：曼哈顿图的染色体标注承诺没有落地、配色与阈值标签两处与文档不符；马赛克的"列总和"到底是每列还是合计没写清，导致零列静默产出零宽单元与重叠标签。都会让按文档写的验收 / 视觉回归失败，但不影响其它图。
- **放大面**（#5，一般）：网络热力图按契约必须输出 N² 个图元，文档没有上限也没有拒绝路径，1000 节点就是 10⁶ 个矩形。是否算严重取决于 `nodes` 是否来自外部请求，文档没声明，故记一般，数据列入待验证假设。

没有任何 `严重` 项：本部分无运行时代码，未发现崩溃、数据计算错误或并发路径。性能与内存只有两条待验证假设（N² 输出峰值、曼哈顿分组查找），均无基线，不进修复清单。文档侧另有三条轻微项（草稿残句、设计把计划写成现状、`heatmapColor` 命名漂移），属于下一轮顺手清理的范围。

存量缺陷共 8 条（一般 5 / 轻微 3），是否纳入修复待用户决定；本报告只读文件，未修改任何源码，未跑构建（文档类审查，无可执行验证面）。
