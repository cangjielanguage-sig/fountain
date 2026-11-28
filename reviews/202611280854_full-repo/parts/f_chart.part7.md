# f_chart 模块审查报告

> **模块第 7/37 部分**。本报告只覆盖 `files/f_chart.part7.txt` 列出的 20 个文件：`doc/spec/add-f-chart-{contour,control,correlation,decision-tree,density,differential-flame}` 六个变更的 spec / tasks / design / proposal（`contour` 的两份给的是 spec + tasks，design/proposal 在第 6 部分；`differential-flame` 的两份是 design + proposal）。`src/**` 的 251 个 `.cj` 与其余 `doc/**` 由其他子轮产出，合并时以主 Agent 为准。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件，481 行）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：图表渲染 / 布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 7/37 部分）

## 取证方式

本部分 20 个文件全是规格与设计文档，因此执行方式是「**以文档为契约、回源码取证**」：把每份 `spec.md` 的 MUST/SHALL 与 `design.md` 的算法描述逐条落到 `src/ContourChart.cj`、`ControlChart.cj`、`CorrelationMatrixChart.cj`、`DecisionTreeChart.cj`、`DensityChart.cj`、`DifferentialFlameChart.cj` 的对应语句（含被复用的 `FlameChart.cj`、`HeatmapChart.cj`、`Histogram2DChart.cj` 的 `heatColor`、`ChartJson.cj` 的 `jsonNumberValue`、`ChartFrame.cj`），同时按 §1–§12 机械过一遍这 6 个实现文件，只把**以本次读到的文档条款为契约**的偏差计入本部分统计。

**跨部分去重**：`add-f-chart-contour/specs/chart-rendering/spec.md:25`（`levels` 为正整数或递增数组、`interpolate` 为 `linear` / `nearest`）与 `ContourChart.cj:111-114`（`interpolate` 只校验不生效）、`:247-265`（`levels` 数组只取 `items.size`）的对应关系，已由**第 6 部分 #7** 记录（其证据源含 `add-f-chart-contour/proposal.md:11`）。本部分只在 FILE COVER 说明里注明这是同一根因的规格侧证据，**不重复计数**。

## 发现

### [一般][存量] #1 相关矩阵的 `method` 字段是「接受但不生效」的空开关：校验了枚举，输出与 pearson/spearman 完全无关

- **位置**：`f_chart/doc/spec/add-f-chart-correlation/proposal.md:10`（「`method` 取 `pearson` / `spearman`」）、`f_chart/doc/spec/add-f-chart-correlation/specs/chart-rendering/spec.md:34`（「`method` MUST 为合法枚举」）；实现：`f_chart/src/CorrelationMatrixChart.cj:81-84`
- **来源**：存量（快照模式，无基线可比；`git log -1 -- src/CorrelationMatrixChart.cj` 为 M27 引入）
- **判据**：review-checklist §14.1「接线缺失 / 半成品」、§1「读了不用」、§13「规格与实现漂移」
- **证据**：静态确定（搜索证据）——`grep -rn "method" f_chart/src/CorrelationMatrixChart.cj` 只命中 3 行：读值（`:81`）、比较（`:82`）、抛异常（`:83`）；`method` 是 `let` 局部量，此后整个 `draw` 没有任何分支、传参或取色依赖它，`matrix` 的解析（`:51-74`）、配色（`:137`）与数值文本（`:144`）都只看单元格值。`CorrelationMatrixChart_test.cj:135` 也只断言「非法 method 抛错」，没有任何「pearson 与 spearman 输出不同」的用例（也不可能通过）。同一字段在 `doc/chart-json-spec.md:1089` 被列为「专属字段」，`README.md:1206` 的示例也带着 `"method": "pearson"`。
- **描述**：字段名与文档语义（`pearson` / `spearman` 是两种相关系数算法）会让使用者以为「传 spearman 就会按秩相关重算」。实际因为 `series[0].data` 本身就要求是已算好的 n×n 系数方阵（`:46-80`），这张图**不可能**自己重算任何统计量，`method` 也就永远无法生效；它既不影响颜色、不影响文本、也不进任何标注（连图例/副标题都不写）。属于「静默降级」：用户改了这个字段，SVG 逐字节相同，而校验又会因为拼错（`kendall`）直接报错，进一步强化「这个字段有用」的错觉。
- **建议**：二选一——(a) 承认它是元数据：把 `method` 纳入输出（如标题后缀或 `<desc>` 标注「spearman」），并在 `proposal.md` / `chart-json-spec.md` 写明「仅作标注，不做计算」；(b) 若确认无用，删除字段与 `:81-84` 的校验，同步清理 README 示例。推荐 (a)，成本最低且保留既有输入兼容。

### [一般][存量] #2 决策树「父节点槽位」文档自相矛盾：spec 要求「子节点槽位平均值」，design 与实现是「首末子节点中点」，3 个以上、子树宽度不均时两者不同

- **位置**：`f_chart/doc/spec/add-f-chart-decision-tree/specs/chart-rendering/spec.md:25`（「父节点槽位 MUST 等于子节点槽位平均值」）vs `f_chart/doc/spec/add-f-chart-decision-tree/design.md:11`（「父节点取子节点槽位中点」）；实现：`f_chart/src/DecisionTreeChart.cj:327-329`
- **来源**：存量（快照模式，无基线可比；两条文档与实现在同一次 M99 提交内）
- **判据**：review-checklist §13「规格与实现漂移」、§11「与规格冲突」、§10「正确性：布局算法」
- **证据**：静态确定 —— `decisionAssignSlots` 用 `(children[0].slot + children[last].slot) / 2.0` 定父槽位，即**首末子节点中点**，不是全部子节点槽位的算术平均。构造可复现的反例：某节点有 3 个子节点，槽位分别为 `0`、`1`、`3.5`（第三个子树占 2–5 号叶子），平均值 = `(0+1+3.5)/3 ≈ 1.50`，实现给 `(0+3.5)/2 = 1.75`，偏差 0.25 个槽位 ≈ 40px（槽宽 `nodeWidth + gap` = 160，`:346`）。现有用例 `DecisionTreeChart_test.cj:94 centersParent` 只覆盖「两个叶子子节点」，此时平均值与中点恒等，所以这条 MUST 从未被验证；`README.md:2262` 写的是「内部节点居中于子节点」，与 design 一致、与 spec 的「平均值」不一致。
- **描述**：三份文档对同一布局规则给了两种定义，验收口径（spec）与实现（design + README）不一致。影响有二：其一，若有人照 spec 补测试，会被判成实现错误；其二，「平均值」在子树宽度不均时才是视觉居中（父节点正对子节点包围盒中心），「首末中点」会偏向叶子多的一侧。当前实现不会崩溃也不会重叠（同层槽位区间不相交，已推演），所以是布局精度与契约问题，不是结构性错误。
- **建议**：把 `spec.md:25` 改成与实现一致的措辞——「父节点槽位 MUST 取**首末**子节点槽位的中点（等价于子节点包围盒中心）」；若确实想要「平均值」，则改 `:327-329` 为对所有 `children` 求平均，并补一条「3 个子节点、子树宽度 1:1:4」的坐标断言。

### [一般][存量] #3 差分火焰图的「根 `value2` 为 0 时退回 `value1`」无法生效：回退只改了分母，宽度仍按 `value2` 算，整图渲染为空白

- **位置**：`f_chart/doc/spec/add-f-chart-differential-flame/design.md:6`（「宽度以 `value2` 为基准；根 `value2` 为 0 时退回 `value1`」）；实现：`f_chart/src/DifferentialFlameChart.cj:157-158`（`rootWidth` 回退）、`:214-222`（`layoutNode` 里 `node.width = node.value2 / rootWidth * plotWidth`）
- **来源**：存量（`git blame -L 155,158 -- f_chart/src/DifferentialFlameChart.cj` → `3d6219c484`，2026-11-08「feat(f_chart): M54 差分火焰图」）
- **判据**：review-checklist §11「契约与实现不符」、§13「规格与实现漂移」、§10「正确性：边界」
- **证据**：静态确定 —— 回退只发生在一处：`rootWidth = if (rootNode.value2 > 0.0) { rootNode.value2 } else { rootNode.value1 }`。但每个节点的矩形宽度由 `node.value2 / rootWidth * plotWidth` 决定，**分子仍是 `value2`**。而 `validateValues`（`:185-202`）保证 `child2 之和 ≤ node.value2 + 1e-6`，配合 `:93-98` 的「值不能为负、至少一个大于 0」，可推出：**根 `value2 == 0` ⇒ 全树 `value2` 之和被压在 1e-6 容差内**（非负且逐层父不小于子和）。于是 `rootWidth > 0`（取 `value1`）时，全树 `width ≈ 0`（最大约 `1e-6 / value1 × plotWidth` 像素），`drawNode`（`:236-240`）画出的矩形宽 0，标签因 `node.width > chartTextWidth(...) + 6.0`（`:242`）永不进入，最终 SVG 里只剩背景与标题。
- **描述**：这正是回退想覆盖的场景——「新版本里这条路径完全消失了」（`value2` 全 0、`value1` 大于 0）。此时用户得到一张空白图，而不是文档承诺的「按旧版本宽度展示」。测试 `DifferentialFlameChart_test.cj` 的 11 个用例（`drawsNodes` … `deterministic`）没有一条构造 `value2 == 0` 的根，所以既有绿灯掩盖了这条路径。由于没有任何异常，调用方也无法感知「图是空的」，属于静默的错误输出。
- **建议**：把宽度基准下沉到节点级——`layoutNode` 增加一个 `basis: Float64` 参数（`value2` 或回退后的 `value1`），宽度改为 `node.width = (if (rootNode.value2 > 0.0) node.value2 else node.value1) / rootWidth * plotWidth`；或者干脆在解析阶段统一：根 `value2 == 0` 时把所有节点的 `value2` 视作 `value1`（此时 `delta` 也应为 0，颜色走中性色）。补一条「根 `value2 = 0` 时至少 1 个 `diff-flame-node` 宽度大于 0」的断言。

### [轻微][存量] #4 核密度图设计说「每个系列在各自 `[min-3h, max+3h]` 上取 100 段」，实现对所有系列共用一条全局网格

- **位置**：`f_chart/doc/spec/add-f-chart-density/design.md:9`；实现：`f_chart/src/DensityChart.cj:105-124`（各系列 min/max 只用于求全局并集）、`:141-151`（峰值扫描）、`:244-248`（绘制）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 两处 101 点采样都是 `x = xMin + (xMax - xMin) * step / 100`，`xMin/xMax` 是所有系列 `[min-3h, max+3h]` 的**并集**（`:113-124`），各系列的 `dataMin/dataMax` 在算出 `left/right` 后即丢弃，从未参与采样。故「每个系列在自己的支撑区间上取 100 段」只在单系列时成立。
- **描述**：多系列时曲线在全局区间上被统一采样，采样点密度低于文档描述（区间更宽、段数不变），极端情况下列区间很宽的系列会把窄区间系列的分辨率拉低。行为本身是合理的（共享 x 轴必须共享采样），只是文档描述与实现不一致，会误导后续做「按系列加密采样」的人。
- **建议**：把 `design.md:9` 改为「全局 x 范围取各系列 `[min-3h, max+3h]` 的并集，并在该范围上统一取 100 段（101 点）」；若确实要按系列采样，则绘制与峰值扫描需各自用自己的区间，且 x 轴刻度仍按并集。

### [轻微][存量] #5 决策树设计说「叶子…加 8px 圆角」，实现对内部节点也加圆角

- **位置**：`f_chart/doc/spec/add-f-chart-decision-tree/design.md:16`；实现：`f_chart/src/DecisionTreeChart.cj:258-265`（`radius: 8.0` 无条件传入）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不一致」
- **证据**：静态确定 —— 同一处 `kit.rect` 调用同时服务叶子与内部节点，只有 `fill` / `textColor` / `className` 按 `node.leaf` 分支，`radius` 是常量 `8.0`；因此内部节点也是圆角矩形。
- **描述**：纯视觉描述偏差，不影响布局与坐标。列出是因为该句把「圆角」写成了叶子的识别特征（与 `#e8f5e9` 填充、深色文字并列），照文档实现的人会以为内部节点是直角。
- **建议**：文档改为「所有节点 8px 圆角；叶子另外用 `#e8f5e9` 填充与深色文字区分」，或实现里按 `node.leaf` 传 `0.0 / 8.0`。

### [轻微][存量] #6 相关矩阵「元素在 [-1,1]」的 MUST 带 ±1e-6 容差，文档未写

- **位置**：`f_chart/doc/spec/add-f-chart-correlation/design.md:5`、`f_chart/doc/spec/add-f-chart-correlation/specs/chart-rendering/spec.md:34`；实现：`f_chart/src/CorrelationMatrixChart.cj:66`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「边界差一」
- **证据**：静态确定 —— 判定式是 `value < -1.000001 || value > 1.000001`，因此 `1.0000005` 这类越界值会通过校验并被 `correlationColor` 归到 `high`（`value > 0.33`）分支；文档写的是闭区间 `[-1,1]`，且未提容差。有限性由 `jsonNumberValue`（`ChartJson.cj:223-225`）保证，这一点与文档的「元素有限」一致。
- **描述**：影响很小（浮点误差场景下容差是必要的），但契约与实现不等价：上游如果把系数四舍五入后带出 `1.0000004` 的漂移，会静默通过而不是报错。属于「文档没写清的宽松边界」。
- **建议**：文档补一句「允许 ±1e-6 的浮点容差」，或把实现改成严格 `[-1,1]` 并在超界时抛 `InvalidValue`（现有用例 `rejectsOutOfRange` 用 1.5，两者都能过）。

### [轻微][存量] #7 差分火焰图的树校验/布局是 `FlameChart` 的整段复制，且已开始漂移

- **位置**：`f_chart/doc/spec/add-f-chart-differential-flame/design.md:5`（「与火焰图相同的树构建与校验」）；实现：`f_chart/src/DifferentialFlameChart.cj:176-259`（`findNode` / `validateValues` / `assignDepth` / `layoutNode` / `drawNode`）vs `f_chart/src/FlameChart.cj:151-247`（同构的五段）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改类型名 / 近似重复）」
- **证据**：静态确定 —— 两边的 `validateValues`（环守卫 `depth > total` + 「父不小于子和」+ 递归）、`assignDepth`、`layoutNode`（`childX += child.width` 顺序铺排）逐行同构，差异只有元素类型名（`FlameNode` / `DiffFlameNode`）、字段数（差分图多 `value1`，`value2` 对应火焰图的 `value`）与错误文案。漂移已经出现：差分图的求和校验把 `value1`/`value2` 两路一起比（`:195-198`），火焰图只有 `value` 一路（`FlameChart.cj:174-181`），且差分图额外有 `value1/value2` 非负校验（`:93-98`）。
- **描述**：design 把「与火焰图相同」当作契约，等于承认这是有意的复制；但 100 行级的结构复制意味着以后任何一条栈图校验规则（如新增最大深度上限、环检测方式变化）都要改两处，且两处已经不对称——差分图允许 `value2 = 0`（只要 `value1 > 0`，`DifferentialFlameChart.cj:93-98`），火焰图要求每个节点值严格大于 0（`FlameChart.cj:85-88`），因此火焰图不会出现 `value / rootValue` 的零分母，差分图必须自己补 `rootWidth` 回退（补得不完整，见 #3）。这是可维护性问题，不是当前的功能缺陷。
- **建议**：抽一个 `internal func` 级别的通用树骨架（如 `flameTreeValidate(nodes, edgesOf, valueOf)` 或泛型 `FlameLikeNode` 接口），两图只保留自己的取值函数与绘制回调；若短期不做，至少在 `design.md:5` 把「相同的树构建与校验」改成「与火焰图保持一致的校验规则（当前为复制实现，改动需同步两处）」，并在两处代码互相加一行交叉引用注释。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分无改前基线，全部只作为下一轮补数据的候选。

### [CPU] 核密度图把同一组密度值算了两遍，可复用峰值扫描的结果

- **现状**：`DensityChart.draw` 先对每个系列的 101 个 `x` 求一次 `gaussianKde`（`DensityChart.cj:141-151`，只为拿 `maxDensity`），随后 `drawDensity` 对**同一个** `xMin/xMax` 再求一遍（`:244-248`）；每次 `gaussianKde` 对全部样本做一遍 `exp`（`:272-283`）。规模：`2 × 101 × Σn_i` 次 `exp`，单系列 1e4 个样本即约 2×10^6 次。
- **方案**：在峰值扫描阶段把每个系列的 101 个 `Float64` 密度存进 `ArrayList<Array<Float64>>`（101×系列数，量级 KB），`drawDensity` 直接复用；两处 `x` 完全同源（都由 `xMin/xMax` 线性生成），无精度差异。
- **预期**：`exp` 调用减半，绘制阶段 CPU 约降一半（**仅本函数内**，端到端占比未知）。
- **代价**：多保留 `101 × 系列数` 个 `Float64` 峰值（可忽略）；`drawDensity` 签名改为接收密度数组，失去「独立重算」的自校验性（可用断言替代）。
- **验证**：`cjpm bench -O2`，10 系列 × 1e4 样本的 `draw`，改前改后各 10 轮取中位数与 P95，并断言 SVG 逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 密度图的 KDE 是 `draw` 的主耗时（`101 × n × 系列` 次 `exp`，且算两遍） | `f_chart/src/DensityChart.cj:141-151,244-248` | `gaussianKde` 自耗时占比、样本规模 | `cjprof record` 跑 10 系列 × 1e4 样本 `draw` ×100，`cjprof report` 看 `gaussianKde` self time |
| 2 | 决策树解析/布局里的线性查找是 O(n²)（每条边 2 次 `findDecisionNode`、根判定是三层循环、`decisionEdgeLabel` 每次画边全表扫） | `f_chart/src/DecisionTreeChart.cj:124-129,141-153,168-181,236` | 节点/边规模分布、耗时占比 | 构造 500/2000 节点树，`cjpm bench -O2` 对照「`findDecisionNode` 换 `HashMap` 」的前后中位数 |
| 3 | 差分火焰图每节点一次 `chartTextWidth`（`drawNode:242`）在数千节点时进入热点 | `f_chart/src/DifferentialFlameChart.cj:242` | 单次文本测量开销、节点数 | 3000 节点栈跑 `cjprof`，看 `chartTextWidth` self time |
| 4 | 等高线大网格的 `uniqueSorted`（O(P²) 去重 + 插入排序）与逐点 `indexOf` 在解析段占比可观 | `f_chart/src/ContourChart.cj:211-245`（第 6 部分 #13 同源） | P 的实际分布、解析段耗时 | 50×50 / 200×200 网格各 100 次 `draw`，分段计时解析 vs 绘制 |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part7.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-contour/specs/chart-rendering/spec.md` | .md | ✅ | 4 条需求逐条对 `ContourChart.cj`：3×3→4 个 cell、共享边 `contour-line`、网格完整性均成立；`:25` 的 `levels` 数组 / `interpolate` 未接线与第 6 部分 #7 同根因，本报告不重复计数 |
| 2 | `f_chart/doc/spec/add-f-chart-contour/tasks.md` | .md | ✅ | 流程记录（4 项全勾），无额外实现承诺；`ContourChart_test.cj` 的 10 个用例与所列范围对应 |
| 3 | `f_chart/doc/spec/add-f-chart-control/design.md` | .md | ✅ | 控制限求值顺序、8% 余量、三类参考线、图例条件逐条命中 `ControlChart.cj:72-205`，无偏差 |
| 4 | `f_chart/doc/spec/add-f-chart-control/proposal.md` | .md | ✅ | `center/ucl/lcl/sigma` 与 4 个 class 名均落地；内部函数 `controlMean/controlStdDev/resolveControlLimits` 存在且被调用 |
| 5 | `f_chart/doc/spec/add-f-chart-control/specs/chart-rendering/spec.md` | .md | ✅ | 8 点场景、越限点、均值/样本标准差数值（mean=5、σ=2、UCL=11、LCL=−1）与实现及 `ControlChart_test.cj:102-130` 一致 |
| 6 | `f_chart/doc/spec/add-f-chart-control/tasks.md` | .md | ✅ | 流程记录（4 项全勾） |
| 7 | `f_chart/doc/spec/add-f-chart-correlation/design.md` | .md | ✅ | 方阵/布局/配色阈值/文本四位一致；`[-1,1]` 容差见 #6 |
| 8 | `f_chart/doc/spec/add-f-chart-correlation/proposal.md` | .md | ✅ | `method` 为无效参数，见 #1；`showValues` 默认 true、`colorRange` 三色、两个 class 名均一致 |
| 9 | `f_chart/doc/spec/add-f-chart-correlation/specs/chart-rendering/spec.md` | .md | ✅ | 16 单元、`cell-value` 开关、端点配色均成立；`method` MUST 见 #1 |
| 10 | `f_chart/doc/spec/add-f-chart-correlation/tasks.md` | .md | ✅ | 流程记录（4 项全勾）；所列「配色」用例 `mapsColors` 存在，但只测端值与分段，测不到 `method` |
| 11 | `f_chart/doc/spec/add-f-chart-decision-tree/design.md` | .md | ✅ | 结构/校验/连线/常量（140×44、70、20）与实现一致；父槽位「中点」与 spec 冲突见 #2，圆角见 #5 |
| 12 | `f_chart/doc/spec/add-f-chart-decision-tree/proposal.md` | .md | ✅ | `edges` 优先 + `parent` 回退、4 个 class 名、内部 `decisionTreeLayout` 均落地 |
| 13 | `f_chart/doc/spec/add-f-chart-decision-tree/specs/chart-rendering/spec.md` | .md | ✅ | 节点/分支/校验逐条成立（无环由「可达节点数 == 总数」间接保证）；`:25` 的「平均值」见 #2 |
| 14 | `f_chart/doc/spec/add-f-chart-decision-tree/tasks.md` | .md | ✅ | 流程记录（4 项全勾）；「布局」用例只覆盖 2 个子节点，见 #2 |
| 15 | `f_chart/doc/spec/add-f-chart-density/design.md` | .md | ✅ | 带宽公式（1.06·σ·n^−1/5，σ 取 n−1）、`h≤0→1`、y 轴 1.05、填充 0.25 均与实现一致；采样网格见 #4 |
| 16 | `f_chart/doc/spec/add-f-chart-density/proposal.md` | .md | ✅ | `bandwidth` 默认 Silverman、多系列叠加、`fill`、复用 `drawXAxisNumeric` 均落地；内部 `gaussianKde` 存在 |
| 17 | `f_chart/doc/spec/add-f-chart-density/specs/chart-rendering/spec.md` | .md | ✅ | 公式与 0.3989 用例可复算（1/√(2π)）；`density-line`/`density-area` 计数、非法带宽、空数据均成立 |
| 18 | `f_chart/doc/spec/add-f-chart-density/tasks.md` | .md | ✅ | 流程记录（4 项全勾）；`computesKde`/`usesDefaultBandwidth` 等用例存在 |
| 19 | `f_chart/doc/spec/add-f-chart-differential-flame/design.md` | .md | ✅ | 差值配色、双/三色 `colorRange`、y 轴公式、标签条件一致；`value2=0` 回退见 #3，复制实现见 #7 |
| 20 | `f_chart/doc/spec/add-f-chart-differential-flame/proposal.md` | .md | ✅ | `delta`、按 `value2` 分宽、红增蓝减、两个 class 名均落地（`diff-flame-node` / `diff-flame-label`） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：#1（`method` 无效）、#2（父槽位算法与 spec 不符）、#3（回退失效导致空白图）。设计：六份 design 的职责划分与「文档即契约」一致，`Chart` 仍是无状态纯函数（6 个类只有 `public init()` 与 `draw`），依赖方向为 `doc → ChartFrame/ChartScale/ChartSvgKit`，无反向依赖；语言特性：`?Float64`/`Option<Float64>` + `match` 的默认值求值（`resolveControlLimits`、`resolveLevels`）用法正确，`Array<Float64>` 与 `Float64` 值语义无踩坑（`DecisionNode` 的 `mut` 字段确为布局需要）；可读性：文档结构统一（Why/What/Design §1..§4），命名与源码类名一一对应；安全性：本部分无外部输入注入面（结构化 JSON，无 SQL/命令/路径拼接），无凭据，`ChartException` 文案不含用户数据以外的敏感内容 |
| §1 死代码 | 0 | 本部分无 `.cj`；按「文档承诺的符号是否真实存在且被使用」做了反向核对：`contourLevel`、`controlMean`、`controlStdDev`、`resolveControlLimits`、`ControlLimits`、`correlationColor`、`formatCorrelation`、`gaussianKde`、`defaultBandwidth`、`decisionTreeLayout`、`decisionAssignDepth`、`decisionAssignSlots`、`countDecisionNodes`、`findDecisionNode`、`decisionEdgeLabel`、`differentialColor`、`heatColor` 全部有定义且至少一个非测试引用（`ContourChart.cj:160`、`ControlChart.cj:72-78`、`CorrelationMatrixChart.cj:137,144`、`DensityChart.cj:98,146,247`、`DecisionTreeChart.cj:194,236`、`DifferentialFlameChart.cj:234`）。唯一「读了不用」的是参数级 `method`（`CorrelationMatrixChart.cj:81`），已归 §14 的 #1，不重复计入死代码 |
| §2 重复逻辑 | 1 | #7：差分火焰图与火焰图的五段树处理逐行同构（`DifferentialFlameChart.cj:176-259` vs `FlameChart.cj:151-247`），差异仅类型名与求和字段，且已出现校验漂移。其余：五份 `tasks.md` 是同构模板（Red → `cjpm test --no-run` → 实现 → 全量测试/validate/archive/提交），属流程模板，不判重复；`resolveLabels`（相关矩阵）与 `decisionTreeLayout` 的槽位/标签生成无同语义重叠；`controlMean`/`controlStdDev` 与 `defaultBandwidth` 的均值方差计算相似（都是 Σ/n 与 Σ(x−μ)²/(n−1)），但前者返回 `?` 语义点、后者内联且参与带宽公式，合并收益低于间接层成本，不报 |
| §3 空实现 | 0 | 20 份文档无 `TODO` / `FIXME` / 占位承诺；六份 `tasks.md` 勾选项对应的测试类与源码文件均存在；`method` / `interpolate` 属「参数校验后不生效」，按 §14 与第 6 部分记录，不重复按空实现计 |
| §4 栈溢出 | 0 | 本部分无 `.cj`，不计命中。交叉核对时注意到 `DecisionTreeChart`（`:301-330`、`:250-259`）与 `DifferentialFlameChart`（`:185-222`、`:224-259`）的树遍历递归深度等于树高、`nodes` 长度无上限，与第 6 部分 #1（`CirclePackingChart`）同源；因文件不在本部分清单，按「范围外提示」处理，未计入统计 |
| §5 OOM | 0 | 文档侧无「全量物化 / 按不可信长度预分配」承诺：6 个图都只按输入元素数建集合（`ContourChart.cj:87-90` 的 `xs.size*ys.size` 预分配发生在其自身的网格完整性校验之后）；无全局缓存、无只增不减容器；输出为单个 SVG 串。等高线大网格的内存/CPU 已在第 6 部分讨论 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，文档也无性能承诺；4 条线索（KDE 双算、决策树 O(n²) 查找、差分图文本测量、等高线去重）全部降级到「待验证假设」，不写成结论 |
| §6.2 大粒度锁 | 0 | 6 个实现文件内无 `synchronized` / `Mutex` / 锁内 I/O（`draw` 只操作局部对象），文档也无并发承诺 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；不存在「提交后立即 get」或并发度=1 的配置 |
| §6.4 低效算法 | 0 | 复杂度线索（决策树线性查找、等高线 O(P²)）因无输入规模与耗时占比，按 §6.1 规则放进「待验证假设」2、4，不计为发现；第 6 部分 #13 已记录等高线去重，避免重复 |
| §7 降堆内存方案 | 0 | 本部分无堆持有承诺；密度图复用密度数组的方案主要降 CPU，峰值只多 `101×系列数` 个 `Float64`（KB 级），不单列堆方案 |
| §8 降 CPU 方案 | 0 | 缺陷侧 0 条；方案侧 1 条（KDE 结果复用），因无改前基线只进「优化可行性方案」，不计缺陷 |
| §9 local mode 可行性 | 0 | 6 个 `draw` 的临时结构（点表、矩阵、网格、SVG 串）都随返回值逃逸（`SvgBuilder` 持有输出、`ArrayList` 被返回或存入节点），不满足 `@ local!` 逃逸约束；且无峰值内存基线，不写改造建议 |
| §11 现有代码的 BUG（存量） | 2 | #2（父槽位与 spec 不符，布局精度）、#3（`value2=0` 回退失效 → 空白图）。另核对通过、未单列的项：`controlStdDev` 的 n<2→0 与 n−1 分母（`ControlChart.cj:248-259`）、`resolveControlLimits` 的 `ucl<lcl` / `sigma<0` 拒绝（`:274-292`）、`control` 的越限判定用严格不等（`:199`，与 spec「越出」一致）、`contourLevel` 的上下钳制（`:291-302`）、`ContourChart` 的 NaN 哨兵与重复坐标检测（`:87-108`）、`correlationColor` 的 `[-1/3,1/3]` 中段边界、`formatCorrelation` 的两位小数与负号（`:222-233`）、`defaultBandwidth` 的退化兜底（`DensityChart.cj:303-307`）、`decisionTreeLayout` 同层槽位区间不相交、`DecisionTreeChart` 的多父/多根/不可达拒绝（`:136-189`） |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态可列：`ContourChart`/`ControlChart`/`CorrelationMatrixChart`/`DecisionTreeChart`/`DensityChart`/`DifferentialFlameChart` 均无实例字段，`draw` 的中间结构全是局部变量；`internal class DecisionNode` 等只在单次调用内构造并只在本次遍历中传递，无线程间发布路径。文档也未声明线程安全/非线程安全，无契约冲突 |
| §13 文档一致性 | 4 | #2（spec 与 design 对父槽位定义相反）、#4（密度图采样网格）、#5（圆角范围）、#6（±1e-6 容差）。反向核对通过：控制图的限值求值顺序与 8% 余量、等高线的 `heatColor(band/(levels-1))` 与 3×3→4 单元、相关矩阵的方形取边与 0.5 白字阈值、决策树的 140/44/70/20 常量与 8px 圆角值、密度图的 1.06·σ·n^−0.2 / 1.05 / 0.25、差分火焰图的 y 公式与双/三色 `colorRange`，全部在源码逐条命中；20 个文件里的 class 名（`contour-cell`/`contour-line`/`control-line`/`control-point`/`control-outlier`/`control-center`/`control-ucl`/`control-lcl`/`correlation-cell`/`cell-value`/`matrix-label`/`decision-node`/`decision-leaf`/`decision-edge`/`decision-edge-label`/`density-line`/`density-area`/`diff-flame-node`/`diff-flame-label`）全部存在 |
| §14 功能完备性与 README 覆盖 | 1 | #1：`method` 承诺（`proposal.md:10`、`spec.md:34`、`doc/chart-json-spec.md:1089`、`README.md:1206` 示例）与「校验后不生效」的实现不符。另核对：六图均在 `README.md` 有独立小节（`855` density、`1198` correlation-matrix、`1253` contour、`1785` control、`2254` decision-tree、`2532` differential-flame），`type` 字符串与 `ChartConfig.parse` 的 `expectedType` 一致；六份 `tasks.md` 全部勾选且对应源码/测试文件存在（无「勾了但缺文件」） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；20 个 `.md`（合计 481 行）逐行读完，无「未读」项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

本部分覆盖的六个图种（等高线、控制图、相关矩阵、决策树、核密度、差分火焰）在文档侧属于「规格可判定」的一档：每份 `spec.md` 都给了 MUST + 具体场景（甚至给了可复算的数字，如控制图 mean=5/σ=2/UCL=11、KDE 在 0 处 0.3989、3×3 网格 4 个单元），`design.md` 则把公式、常量、class 名写到可以照着实现的程度。逐条核对后，**数值与几何公式基本没有算错**——控制限的 ±3σ 与 n−1 分母、等值线的 `floor(...)*levels` 钳制、Silverman 带宽与 1.05 y 轴余量、决策树 160px 槽距与 114px 层距、差分配色中性与双向插值，全部与源码一致；`tasks.md` 的红绿流程也真实对应到测试类。

问题落在两类：

- **文档自相矛盾 / 与实现不同步**（#2、#4、#5、#6）：最值得修的是 #2——决策树「父节点槽位」在 spec 里是「子节点平均值」、在 design 与 README 里是「首末子节点中点」，实现在 3 个以上且子树宽度不均时会给出不同坐标，现有用例只测 2 个子节点，因此这条 MUST 从未被验证。#4/#5/#6 属描述精度问题，改动只在文档侧。
- **「接受但不生效」的输入**（#1）：相关矩阵的 `method` 与第 6 部分记录的 `interpolate` / `levels` 数组是同一类问题——字段被校验、被示例使用、被列进「专属字段」，但对输出零影响。因为图表本身不接受原始样本（只接受已算好的系数方阵），`method` 根本没有计算入口，建议显式降级为元数据而不是保留假开关。

**阻塞项为 0**。#3 是唯一会产出错误结果的路径（差分火焰图在「新版本该路径全消失」时整图空白），但既不崩溃也不影响其他图，按一般排期修即可；它值得优先处理的原因是**静默**：没有任何异常，调用方无法区分「图是空的」与「数据没问题」。

与相邻部分的重叠已做去重：等高线的 `interpolate` / `levels`（第 6 部分 #7）与 `uniqueSorted` 复杂度（第 6 部分 #13）不重复计数；决策树 / 差分火焰图的递归深度无上限与第 6 部分 #1 同源，因文件不在本部分清单，只作范围外提示，未计入统计。

存量缺陷共 7 条（一般 3 / 轻微 4），是否纳入修复待用户决定。
