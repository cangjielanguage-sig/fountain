# f_chart 模块审查报告（模块第 23/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个 `.md`，0 个 `.cj`；覆盖 `doc/spec/add-f-chart-{treemap,tui,tui-flame,violin,violin-box,volcano}` 六个已完成变更的四件套文档）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染 / 布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑（本部分无源码，专项改为「按文档承诺反查实现」：树图权重与 value 语义、TUI 画布/坐标轴/抽稀、火焰图递归布局与层高、小提琴 KDE 采样与字段位置、火山图阈值线）
- **报告版本**：v1

## 发现

### [一般][存量] 小提琴 / 小提琴箱线的 `bandwidth`、`showBox`、`showOutliers` 未标注位于 `series[0]`，按文档写在根级会被静默忽略

- **位置**：`f_chart/doc/spec/add-f-chart-violin/proposal.md:12`（「`bandwidth` 可选，缺省用 Silverman 规则」）、`f_chart/doc/spec/add-f-chart-violin/specs/chart-rendering/spec.md:39`（「`bandwidth` MUST 大于 0」）、`f_chart/doc/spec/add-f-chart-violin-box/proposal.md:11`（「`bandwidth` 控制核密度带宽；`showBox` 默认 true；`showOutliers` 默认 true」）、`f_chart/doc/spec/add-f-chart-violin-box/specs/chart-rendering/spec.md:35`（`bandwidth` 取值域）；实现 `f_chart/src/ViolinChart.cj:101-110`、`f_chart/src/ViolinBoxChart.cj:101-110`（三字段均从 `seriesJson` 读取，错误路径写作 `series[0].bandwidth`）
- **来源**：存量（`git log -1` → `750e7acb3`「feat(f_chart): M20 小提琴图」、`34f6f9119`「feat(f_chart): M46 小提琴箱线图」，文档与实现同批提交，非后续漂移）
- **判据**：review-checklist §13（配置项位置与源码不符）+ §11「错误处理缺失：配置被读却从未生效」
- **证据**：静态确定 —— 两份 proposal 在列举 `series[0].data` 之后直接用无路径字段名列出 `bandwidth` / `showBox` / `showOutliers`，规格的需求文本同样只有裸字段名；实现只查 `series[0]`。JSON 解析对未知键不报错（`ChartJson` 只按名取值），因此写 `{"type":"violin","bandwidth":0.2,...}` 时根级键被丢弃，`seriesJson.number` 返回 `None` 走 `defaultBandwidth`
- **描述**：使用者按文档在图表根级设置 `bandwidth: 0.05` 或 `showBox: false`，既不报错也不生效，输出仍是 Silverman 带宽 + 叠加箱体，属于「配置静默失效」；排查时没有任何日志或异常指向该字段
- **建议**：三处文档统一改为 `series[0].bandwidth` / `series[0].showBox` / `series[0].showOutliers`，并在 spec 的校验需求里补一句「未知层级上的这三个字段 MUST 被忽略（或 MUST 抛 `InvalidValue`，二选一写明）」，避免继续出现「写了不生效」

### [一般][存量] 树图 `value` 语义与 spec 不符：叶子缺 `value` 静默按 0 处理，内部节点自带 `value` 被静默覆盖

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/specs/chart-rendering/spec.md:16`（「内部节点值 MUST 等于子节点值之和」）、`:34`（「叶子 `value` MUST 大于 0」）；实现 `f_chart/src/TreemapChart.cj:88-99`（`value` 缺失 → `None`，只有提供了值才校验 `> 0`）、`:159-171`（`nodeValue`：叶子 `None` → `0.0`；内部节点忽略自身 `value`，直接累加子节点）
- **来源**：存量（`git log -1` → `98ea2dd7c`「feat(f_chart): M34 矩形树图」）
- **判据**：review-checklist §14.1（承诺了校验但没实现）+ §11「空值未处理、静默失败」
- **证据**：静态确定 —— spec 把「叶子 `value` MUST 大于 0」写在「树图校验」需求里，且场景只覆盖了「悬空 parent」「非法 tiling」；`TreemapChart_test.cj` 的 8 条用例里没有「叶子缺 value」这一条（`grep -n "value" src/TreemapChart_test.cj` 只命中 `:47-50` 的正常值、`:104` 的负值、`:85/:124/:156` 的其它场景）。实现侧 `:88` 的 `case None => None<Float64>` 之后没有任何兜底校验，`:163` 直接返回 `0.0`
- **描述**：`{"id":"a","name":"a","parent":"root"}`（漏写 `value`）不会抛 `InvalidValue`，该叶子得到 0 权重、0 面积矩形，与「叶子值必须大于 0」的契约相反；同一条规则对内部节点也不成立——内部节点写了 `value: 500`、子节点和为 100 时，输入值被静默丢弃，输出按 100 计算，规格里「内部节点值 MUST 等于子节点值之和」读起来像是校验，实际是「忽略并重算」，两种理解对用户可见结果不同
- **建议**：`parse` 之后加一次「叶子必须有值」的校验（`node.children.isEmpty() && node.value.isNone()` → `chartInvalidValue("${itemPath}.value", "叶子节点必须提供 value")`），spec `:16` 改写为「内部节点的 `value` MUST 被忽略，绘制值取子节点之和」，并补两个用例（叶子缺 value、内部节点 value 与子节点和不一致）

### [轻微][存量] 树图标签的显示条件（`width > 40 && height > 18`）未进 spec，`treemap-label` 的 MUST 与实现不一致

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/specs/chart-rendering/spec.md:25-30`（「每个叶子 MUST 输出 `class="treemap-label"` 名称文本」、场景「4 个叶子 → 4 个 `treemap-label`」）；实现 `f_chart/src/TreemapChart.cj:208-218`（仅当 `width > 40.0 && height > 18.0` 才写标签）
- **来源**：存量（`98ea2dd7c`，spec 与实现同批）
- **判据**：review-checklist §13（spec 验收口径与实现不一致）
- **证据**：静态确定 —— 像素阈值硬编码在实现里，spec 与 design 均无该条件；默认 800×480 下 4 个叶子每格约 200×100，场景能过，所以测试没有暴露差异
- **描述**：叶子多到每格 ≤ 40×18 时实现不输出任何 `treemap-label`，按 spec 字面可判成缺陷；反过来，验收方也无法从规格知道「小格不出标签」是有意设计（同类文档 `add-f-chart-tui-flame/design.md:32` 就把「窄块跳过标签」写清楚了）
- **建议**：spec 的标签需求补一句「矩形宽 > 40 且高 > 18 时 MUST 输出 `treemap-label`，否则 MUST NOT 输出」，并加一个「大量小叶子 → 0 个标签」的场景

### [轻微][存量] TUI 横轴「类目标签抽稀」在 spec 中是 MUST、在 design 中是不可执行的公式、在 tasks 中已勾选完成，但代码里没有任何抽稀

- **位置**：`f_chart/doc/spec/add-f-chart-tui/specs/chart-tui/spec.md:60`（「类目标签过多时 MUST 通过抽稀避免重叠」）、`f_chart/doc/spec/add-f-chart-tui/design.md:36`（「按 `ceil(n / 可用列数 × 2)` 抽稀」）、`f_chart/doc/spec/add-f-chart-tui/tasks.md:7`（1.5「覆盖……横轴标签与抽稀」已 `[x]`）；实现 `f_chart/src/tui/TuiFrame.cj:183-201`（逐类目画 `┬` 与标签，仅按 `bandWidth >= 2` 整片跳过、`maxWidth: bandWidth` 截断）
- **来源**：存量（`git log -1` → `f4e27a68c`「feat(f_chart): 新增 M1-M7 TUI 子包」）
- **判据**：review-checklist §14.1（承诺了但没实现）+ §13（提交记录与产物不符）
- **证据**：静态确定 —— `grep -rn "抽稀\|stride\|thinning\|labelStep\|everyN" src/tui/` 零命中；`TuiFrame_test.cj` 同样没有抽稀相关断言。design 的公式 `ceil(n / 可用列数 × 2)` 量纲也不成立：它是「每 N 个取 1」的步长还是「保留比例」无法从上下文判定（`n=100`、60 列时得 4，按步长会只剩 25 个标签，按比例则语义相反）
- **描述**：类目过密时实际行为是「带宽 <2 全部不画标签」，既不重叠也无法读到任何类目名，与 spec 的「抽稀后仍保留部分标签」不同；tasks 1.5 声称覆盖抽稀，让后来者以为该能力已交付
- **建议**：二选一并写进 spec：①实现步长抽稀（`step = ceil(n / 可用列数)`，每 `step` 个类目画一个标签），design 的公式改为 `step = ceil(n / 可用列数)`；②承认现状，把 spec `:60` 改成「类目带宽 < 2 列时 MUST 不输出类目标签」，并修正 tasks 1.5 的表述

### [轻微][存量] TUI 火焰图 design「每层至少 1 行」与 spec「层数超出可用行数抛 `InvalidValue`」是两条互斥规则

- **位置**：`f_chart/doc/spec/add-f-chart-tui-flame/design.md:21`（`rowsPerDepth = min(frameHeight, floor(plot.height / (maxDepth + 1)))`，「至少 1」）、`f_chart/doc/spec/add-f-chart-tui-flame/specs/chart-tui-flame/spec.md:71-74`（「层数超出绘图区可用行数 → 抛 `ChartException`，`kind` 为 `InvalidValue`」）；实现 `f_chart/src/tui/TuiFlameChart.cj:75-80`（`fitRows < 1` 直接抛）
- **来源**：存量（`git log -1` → `0494ee810`「feat(f_chart): 新增 TUI 真彩火焰图」）
- **判据**：review-checklist §13（同一变更的 design 与 spec 对同一错误路径口径相反）
- **证据**：静态确定 —— 按 design 的「至少 1」，`plot.height < maxDepth + 1` 时每层压到 1 行继续画（`drawBox` 的 `top` 会落到绘图区之外并被 `bottom = min(..., plot.bottom())` 截断）；按 spec 则必须抛错。两处没有一句话说明优先级，实现选择了抛错
- **描述**：维护者按 design 复算会认为 24 行终端 + 30 层节点仍应输出（部分层被裁掉），按 spec 则应拿到异常；这类分歧会直接影响用户对「输入合法/非法」的判断，也会让测试断言二义
- **建议**：design `:21` 改为「`fitRows = floor(plot.height / (maxDepth + 1))`；`fitRows < 1` 时抛 `InvalidValue`（见 spec 场景「层数超出可用行数」）」，删掉「至少 1」

### [轻微][存量] 小提琴的 KDE 采样点数在 `violin` design 写 40、在 `violin-box` design 写 41，实现是 41

- **位置**：`f_chart/doc/spec/add-f-chart-violin/design.md:12`（「在 y 轴绘图范围内取 40 个采样点」）、`f_chart/doc/spec/add-f-chart-violin-box/design.md:12`（「取 41 个采样点」）；实现 `f_chart/src/ViolinChart.cj:176-177`（`for (step in 0..=40)` + `/ 40.0`，即 41 个点）、`f_chart/src/ViolinBoxChart.cj:177-178`
- **来源**：存量（`750e7acb3` / `34f6f9119`，两份 design 由同一模板复制）
- **判据**：review-checklist §2「近似重复：同一模板复制后数值漂移」
- **证据**：静态确定 —— `0..=40` 含两端共 41 个采样，`violin` design 的「40 个」少算一个端点；两份文档描述的是同一套 `gaussianKde` 轮廓算法（`violin-box/design.md:5` 明写「复用」），却给出不同点数
- **描述**：按 40 点复算轮廓会得到与实现不同的密度折线（采样步长 `(max-min)/39` vs `/40`），在极值处尤其明显；文档之间自相矛盾也让「哪个是对的」无从判断
- **建议**：`violin/design.md:12` 改为「取 41 个采样点（`0...=40`，步长 `(max-min)/40`）」，与 `violin-box` 统一

### [轻微][存量] 小提琴 design 用 `bandWidth * 0.4` 表示「槽宽」，与同一文档的 KDE「带宽」`bandwidth` 同名不同义

- **位置**：`f_chart/doc/spec/add-f-chart-violin/design.md:11`（「对每组计算带宽（显式或 Silverman）」）、`:13`（「轮廓最大半宽为 `bandWidth * 0.4`」）、`:18`（「箱宽 `bandWidth * 0.1`」）；对照 `f_chart/doc/spec/add-f-chart-violin-box/design.md:12`（同一规则写作「最大半宽为槽宽的 0.4 倍」）；实现 `f_chart/src/ViolinChart.cj:170-172`（`band.bandWidth * 0.4`，`band` 是 `BandScale`）
- **来源**：存量（`750e7acb3`）
- **判据**：review-checklist §13（术语与源码不一致，易误实现）+ 可读性
- **证据**：静态确定 —— 同一文档前两行刚用「带宽」指 KDE `bandwidth`（可由 `series[0].bandwidth` 覆盖），下一行却用视觉上几乎相同的 `bandWidth` 指类别槽宽；`violin-box` 的 design 已改用「槽宽」，说明命名确实有歧义
- **描述**：实现者若把 `bandWidth` 读成 KDE 带宽，`bandwidth = 0.05` 时轮廓半宽只有 0.02px，图会退化成一条竖线且不报错；这类误读成本高、排查困难
- **建议**：`violin/design.md:13`、`:18` 统一改为「槽宽的 0.4 / 0.1 倍（`BandScale.bandWidth`）」，与 `violin-box/design.md:12` 的措辞对齐

### [轻微][存量] TUI 柱状图 spec「`bar` 单系列占满类目带」与 design「柱宽 = `bandWidth × 0.6`」、实现 0.6 倍带宽矛盾

- **位置**：`f_chart/doc/spec/add-f-chart-tui/specs/chart-tui/spec.md:76`（「`bar` 单系列占满类目带」）、`f_chart/doc/spec/add-f-chart-tui/design.md:56`（「柱宽：`max(1, floor(bandWidth × 0.6))`」）；实现 `f_chart/src/tui/TuiBarRenderer.cj:195`（`floor(band.bandWidth * 0.6)`）
- **来源**：存量（`f4e27a68c`）
- **判据**：review-checklist §13（文档内部口径不一致）
- **证据**：静态确定 —— 单系列的柱宽是带宽的 60%，不是「占满」；spec 的上下句是「`bar` 单系列占满类目带，`grouped-bar` 在类目带内并排」，正确语义应是「独占整个带、不切槽位」
- **描述**：读者可能据此实现「柱宽 = 带宽」，与 design 的 0.6 冲突，输出柱体偏宽并挤压相邻类目；测试里没有柱宽断言，两种实现都能过
- **建议**：spec 改为「`bar` MUST 独占整个类目带（不切槽位），柱宽由 design 的 `0.6 × 带宽` 决定」，避免「占满」被理解为满宽

## 优化可行性方案

本部分为 6 个已归档变更的文档，不含可执行代码，也没有任何改前/改后性能基线；堆内存、CPU、local mode 三类方案均不成立（0 条）。文档层面的可执行改进已按缺陷写入上节建议，不重复计数。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 火焰图布局用递归实现（`layoutNode` / `validateTree` / `assignDepth`），递归深度上界 = `nodes.size`，深链输入（如 5 万层）会耗尽线程栈，而 design 只写了「递归分配」未提深度上限 | `f_chart/src/tui/TuiFlameChart.cj:172-225`、`doc/spec/add-f-chart-tui-flame/design.md:20` | 默认栈大小、单帧字节数、崩溃临界深度 | 构造 1k / 1万 / 5万层链式 `nodes`，在 80×24 下逐个跑 `TuiFlameChart().draw`，记录首个崩溃深度与异常类型（若为 `StackOverflowError` 则升级为缺陷） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-treemap/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #2、#3（value 语义、标签条件） |
| 2 | `f_chart/doc/spec/add-f-chart-treemap/tasks.md` | .md | ✅ | 4 条任务全 `[x]`，产物存在；未覆盖「叶子缺 value」 |
| 3 | `f_chart/doc/spec/add-f-chart-tui-flame/design.md` | .md | ✅ | 见发现 #5（层高与异常互斥）、待验证 #1（递归） |
| 4 | `f_chart/doc/spec/add-f-chart-tui-flame/proposal.md` | .md | ✅ | 声明的 `M052-flame.tui.txt` 等 5 个样例均存在 |
| 5 | `f_chart/doc/spec/add-f-chart-tui-flame/specs/chart-tui-flame/spec.md` | .md | ✅ | 校验/配色/尺寸三条需求与实现一致，唯 `:71-74` 与 design 冲突 |
| 6 | `f_chart/doc/spec/add-f-chart-tui-flame/tasks.md` | .md | ✅ | 11 条全 `[x]`，`TuiColor.tuiContrastColor`、测试文件均已落地 |
| 7 | `f_chart/doc/spec/add-f-chart-tui/design.md` | .md | ✅ | 见发现 #4（抽稀）、#8（柱宽）；`:19` 的 `TuiFrame(config, 0)` 与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-tui/proposal.md` | .md | ✅ | 7 个类名与 `src/tui/*.cj` 的 `public class` 一一对应 |
| 9 | `f_chart/doc/spec/add-f-chart-tui/specs/chart-tui/spec.md` | .md | ✅ | 见发现 #4、#8；尺寸 / ANSI / 错误语义与实现一致 |
| 10 | `f_chart/doc/spec/add-f-chart-tui/tasks.md` | .md | ✅ | 见发现 #4（1.5 抽稀已勾选但未实现） |
| 11 | `f_chart/doc/spec/add-f-chart-violin-box/design.md` | .md | ✅ | 见发现 #6（41 点，正确） |
| 12 | `f_chart/doc/spec/add-f-chart-violin-box/proposal.md` | .md | ✅ | 见发现 #1（字段位置） |
| 13 | `f_chart/doc/spec/add-f-chart-violin-box/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #1；箱体/端帽/异常值计数与实现一致 |
| 14 | `f_chart/doc/spec/add-f-chart-violin-box/tasks.md` | .md | ✅ | 4 条全 `[x]`，产物存在 |
| 15 | `f_chart/doc/spec/add-f-chart-violin/design.md` | .md | ✅ | 见发现 #6、#7 |
| 16 | `f_chart/doc/spec/add-f-chart-violin/proposal.md` | .md | ✅ | 见发现 #1 |
| 17 | `f_chart/doc/spec/add-f-chart-violin/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #1；`showBox` 默认 true 与实现一致 |
| 18 | `f_chart/doc/spec/add-f-chart-violin/tasks.md` | .md | ✅ | 4 条全 `[x]`，产物存在 |
| 19 | `f_chart/doc/spec/add-f-chart-volcano/design.md` | .md | ✅ | 阈值线/分类/轴留白与 `VolcanoChart.cj` 一致；spec delta 不在本部分 |
| 20 | `f_chart/doc/spec/add-f-chart-volcano/proposal.md` | .md | ✅ | 字段名与实现一致；spec delta 与 tasks 属其它部分 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无源码，正确性体现为「文档承诺 vs 实现」：命中 2 条一般（发现 #1 配置静默失效、#2 value 语义）；无网络 / 凭据 / 注入类内容，安全性无命中 |
| §1 死代码 | 0 | 本部分无 `.cj`；反向核对文档引用的符号是否真实存在：`TuiFlameChart`、`tuiContrastColor`、7 个 TUI 图表类、`ChartConfig.parse(defaultWidth/defaultHeight)`、`treemapWeights`、`ViolinBoxChart` 均在 `src/` 命中，无一「文档引用不存在的符号」 |
| §2 重复逻辑 | 1 | 同族文档重复描述同一 KDE 轮廓流程，`violin` 写 40 点、`violin-box` 写 41 点（发现 #6），属模板复制后的数值漂移；其余重复内容（7 个 TUI 类各自的 design 段）差异是业务要求，不判重复 |
| §3 空实现 | 0 | 文档无 `TODO`/占位/`UnsupportedException` 承诺；逐条核对 tasks 声明的产物（`M052-flame*.tui.txt` 5 份、各 `_test.cj`、README TUI 类表）全部存在 |
| §4 栈溢出 | 0 | 火焰图递归布局的深度上界由 `nodes.size` 决定，缺少栈大小数据，已转待验证假设 #1，不按缺陷计 |
| §5 OOM | 0 | 文档未承诺全量物化；TUI 侧只有 20×8 下限、无上限（`width: 100000` 会分配等量 `TuiCell`），但本部分无量化输入与内存数据，不入缺陷 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分为文档，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 文档未描述任何锁或临界区 |
| §6.3 并发串行 | 0 | 无 `spawn` / 队列 / 批处理描述 |
| §6.4 低效算法 | 0 | design 的 `ceil(n / 可用列数 × 2)` 是抽稀规则而非复杂度问题，已并入发现 #4 |
| §7 降堆内存方案 | 0 | 无运行时代码，无基线，方案无法量化，按铁律不写 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时对象，不适用 |
| §11 现有代码的 BUG（存量） | 0 | 本部分不含 `.cj`；核对到的两处实现相反（value 语义、字段位置）按文档口径记入 §13/§14，避免与源码部分重复计数 |
| §12 并发安全与锁粒度 | 0 | 文档未声明线程模型；TUI 渲染为「入参 → 字符串」的纯函数路径，无共享可变状态 |
| §13 文档一致性 | 5 | 发现 #1、#5、#6、#7、#8；另外核对了 ANSI 转义格式、80×24 缺省值、`TuiFrame(config, 0)` 语义、`showBox` 默认值、火山图阈值默认值 1 / 1.3，均与实现一致 |
| §14 功能完备性与 README 覆盖 | 3 | 发现 #2、#3、#4（承诺的校验/标签条件/抽稀未落地或未写全）；proposal 声明的类与样例文件均已接线 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分是 f_chart 六个已完成变更（treemap、TUI 子包、TUI 火焰图、violin、violin-box、volcano）的四件套文档，整体结构统一、验收场景可读，字段默认值（`bandwidth`/`showBox`/`showOutliers`/`frameHeight`/阈值 1 与 1.3）与实现基本对得上，无空实现、无死链、无凭据类内容。

风险集中在「文档承诺与实现的口径差」而不是性能：两条一般项都是「用户按文档配置会静默不生效」——小提琴族的 `bandwidth`/`showBox`/`showOutliers` 实际位于 `series[0]` 而文档只写裸字段名；树图的 `value` 契约（叶子必须 > 0）没有对应校验，缺值被当成 0 画出零面积格子。这两条建议排期修文档 + 补校验/用例，成本很低。六条轻微项是同一模板复制造成的数值与措辞漂移（40 vs 41 采样点、`bandWidth` 同名不同义、`bar`「占满」vs 0.6 倍、火焰图层高「至少 1」vs 抛错、`treemap-label` 的 40×18 阈值、抽稀公式不可执行且未实现）。其中 tasks 里把「抽稀」勾成已完成这一条，会误导后续维护者，建议同步修正归档记录。

存量合计 8 条（一般 2、轻微 6），是否纳入修复待用户决定；本部分无阻塞项，无性能类结论（无基线，相关猜测已列入待验证假设）。
