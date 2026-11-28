# f_chart 模块审查报告（模块第 19/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个 `.md`，0 个 `.cj`；覆盖 `doc/spec/add-f-chart-{roc,rose,sankey,sankey-alias,scatter-matrix,scatter}` 六个已完成变更的归档文档，其中 `add-f-chart-roc` 的 `spec.md`/`tasks.md` 与 `add-f-chart-scatter` 的 `design.md`/`proposal.md` 是本部分实际承担的切片）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：文档与实现一致性、规格自洽性、功能完备性（本部分无源码；渲染/布局/坐标边界/OOM 等专项通过「文档承诺 → 实现反查」逐条核对）
- **报告版本**：v1

## 发现

### [一般][存量] 桑基图别名规格把「以 `<svg` 开头」写成硬契约，与实际输出（以 `<?xml …?>` 开头）相反，验收测试已悄悄降级为 `contains`

- **位置**：`f_chart/doc/spec/add-f-chart-sankey-alias/specs/chart-rendering/spec.md:12`（「THEN 返回以 `<svg` 开头的字符串」）；验收侧 `f_chart/src/SankeyAlias_test.cj:58`（`@Assert(svg.contains("<svg"))`）
- **来源**：存量（快照模式无基线。`git log -1 -- f_chart/doc/spec/add-f-chart-sankey-alias/specs/chart-rendering/spec.md` 与 `git log -1 -- f_chart/src/SankeyAlias_test.cj` 同为 `d6fea8c96`，说明规格与验收同日写成，非后续漂移）
- **判据**：review-checklist §13「文档承诺与实现相反」；§14.1「验收条件弱于承诺」
- **证据**：静态确定 —— `SankeyChart.draw` 末行走 `builder.toSvgString()`（`f_chart/src/SankeyChart.cj:261`），`SvgBuilder` 来自 `fountain::f_svg`；`f_svg/src/SvgWriter.cj:34` 的默认选项 `xmlDeclaration!: Bool = true`，`f_svg/src/SvgBuilderM7_test.cj:73` 直接断言默认输出 `startsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")`。因此返回值**永不可能**以 `<svg` 开头
- **描述**：规格给出的是一条可被下游直接写成断言的字符串契约，实现却稳定输出 XML 声明前缀。任何按 spec 写 `startsWith("<svg")` 的调用方/一致性测试都会失败；同一变更里的验收测试用了更宽的 `contains`，把这条错误的契约「验过去了」，所以问题在变更提交时未被发现。`spec.md:9-12` 的场景名是「别名绘制」，本意是验证复用 `SankeyChart`，改用 `contains` 或 `startsWith("<?xml")` 都不影响其验证目的
- **建议**：把 `spec.md:12` 改为「返回包含 `<svg` 根元素的字符串」（若确实想锁定前缀，则写 `<?xml version="1.0" encoding="UTF-8"?>`），并同步 `SankeyAlias_test.cj:58` 为与规格一致的断言（`startsWith` 或 `contains` 二选一，两边口径必须相同）

### [轻微][存量] 玫瑰图规格对「零值扇区」的两条要求互相矛盾，其中「每项一个扇区」与实现相反

- **位置**：`f_chart/doc/spec/add-f-chart-rose/specs/chart-rendering/spec.md:7`（「MUST 为 `series[0].data` 的每一项绘制一个 `rose-slice`」）、`:30`（「每个**非零**扇区 MUST 输出 `rose-label`」）、`:32-35`（场景「`data` 有 4 项 → 4 个 `rose-label`」）；实现 `f_chart/src/RoseChart.cj:122`（`if (slice.value > 0.0 && radius > 0.0)` 才画扇区与标签）
- **来源**：存量（规格与 `RoseChart.cj` 同为 `ab330b605`）
- **判据**：review-checklist §13「规格自洽 / 规格与实现漂移」；§14.1「只做了一半的分支——规格未覆盖零值输入」
- **证据**：静态确定 —— 同一条规格内，「每项一个扇区」与「标签只给非零扇区」互相冲突（若允许零值，则扇区数 ≠ 项数）；实现把零值项整体跳过（扇区与标签都不画），既不满足 `:7`，也让 `:35` 的「4 项 4 标签」在含零值时失效。`RoseChart_test.cj` 只有全零拒绝用例（`:123` 起），没有「含 0 且有正值」的用例
- **描述**：零值在份额数据里很常见（某品类 0 销量）。按 `:7` 实现应输出一个退化扇区，按实现则不输出，两者对「`rose-slice` 数量 == `data` 长度」这一最容易被下游断言的契约给出相反答案；`:35` 的场景也没声明「4 项均大于 0」这一前提
- **建议**：`spec.md:7` 补「`value` 为 0 的项不绘制扇区」，`:32-35` 场景前提补「4 项均大于 0」，并新增一个「`[0, 3, 5]` → 2 个 `rose-slice` + 2 个 `rose-label`」的场景把行为锁死

### [轻微][存量] 玫瑰图 `design.md` 的 `maxRadius` 口径（绘图区短边 45%）与实现（短边一半再减 20px）不等价

- **位置**：`f_chart/doc/spec/add-f-chart-rose/design.md:9`（「`maxRadius` 取绘图区短边的 45%」）；实现 `f_chart/src/RoseChart.cj:113-116`
- **来源**：存量（同为 `ab330b605`）
- **判据**：review-checklist §13「文档与实现不一致」——两边都是可复算的几何常量，不是措辞差异
- **证据**：静态确定 —— 实现为 `min(width - padL - padR, height - padT - padB - 40.0) / 2.0 - 20.0`；默认 padding 四边 24（`f_chart/src/ChartConfig.cj:22-25`）。代入 README 的 600×600 示例：短边 `min(552, 512) = 512`，实现得 `236px`，45% 为 `230.4px`；换 400×400 则实现 `136px`、45% 为 `140.4px`（偏差随画布尺寸变号）
- **描述**：`design.md` 写的是比例常量（45%），实现是「一半 + 固定内缩 20px」再加 40px 底部预留，二者只在某个特定尺寸附近偶然接近。按文档复算半径会得到与输出不一致的数值，也会让后续「按设计调比例」的人改错参数
- **建议**：把 `design.md:9` 改为「`maxRadius = min(内容宽, 内容高 − 40) / 2 − 20`；约为绘图区短边的一半」，或把实现改为 `0.45 × 短边` 并同步几何断言（后者会改已有 SVG 输出，优先改文档）

### [轻微][存量] 散点图 `design.md` 对 `symbol` 与 time 轴的描述与实现四处不符（漏 `none`、非法值静默回落、`diamond` 实为全对角线、time 轴也收数字）

- **位置**：`f_chart/doc/spec/add-f-chart-scatter/design.md:5`（「`x` 按 `xAxis.type` 解析（time → `ChartTime.parseDays`，否则数字）」）、`:13`（「`symbolSize` 作为直径；`circle` 半径为一半，`square`/`diamond` 用边长。class 固定 `symbol`」）；实现 `f_chart/src/ScatterChart.cj:162-167`、`:189-194`、`f_chart/src/ChartSvgKit.cj:179-192`
- **来源**：存量（`design.md` 与 `ScatterChart.cj` 同为 `81b0dc647`）
- **判据**：review-checklist §13「文档与实现不一致」；§14.1「枚举新 case 没有分支 / 静默兜底未文档化」
- **证据**：静态确定 ——
  1. `ScatterChart.cj:165` 有 `case "none" => ()`（`symbol: "none"` 时完全不画点），`design.md:13` 只列 circle/square/diamond；
  2. `:166` 的兜底 `case _ =>` 把任何未知 `symbol` 静默画成圆点，文档与规格都没有「非法值应报错」的约定；
  3. `ChartSvgKit.cj:179-192` 的 `diamond` 用 `±size/2` 四点，`symbolSize` 是**全对角线长度**，实际边长是 `size/√2`，与 `:13` 的「`diamond` 用边长」相反（square 才是边长，`ChartSvgKit.cj:174`）；
  4. `ScatterChart.cj:189-194`：time 轴下 `x` 为数字时直接走 `jsonNumberValue`，文档只写了 `parseDays`。
  另外 `:9` 的 `LinearScale(min,max,right,left)` 参数顺序与实现 `ScatterChart.cj:128` 一致（不是文档错），但该顺序本身会把 x 轴镜像，见「总评·范围外提示」
- **描述**：`symbol: "none"` 是「隐藏点、只留轴」的常用手段，文档没写等于不可发现；未知值静默成圆点则会让拼写错误（如 `"squar"`）静默产出错图。`diamond` 的尺寸语义写反，按文档给 `symbolSize=10` 会以为是 10px 边长，实际渲染的对角线 10px、边长约 7.07px
- **建议**：`design.md:13` 改为「`symbolSize` 为外接框尺寸：circle 半径 `size/2`，square 边长 `size`，diamond 对角线 `size`；`none` 不绘制」，并补一条「未知 `symbol` 抛 `InvalidValue`」的约定（实现侧加校验）；`:5` 补「time 轴也接受数字时间戳」

### [轻微][存量] ROC 规格未写明 `auc` 的挂载层级，也未把「`series` 恰好 1 个」写成需求

- **位置**：`f_chart/doc/spec/add-f-chart-roc/specs/chart-rendering/spec.md:25`（「提供 `auc` 时 MUST 输出 1 个 `roc-auc` 文本」）、`:37-39`（校验清单：x/y 0–1、`data` 非空、`series` 缺失、`type` 不符）；实现 `f_chart/src/RocChart.cj:79`（`seriesJson.number("auc")`，即 `series[0].auc`）、`:45-47`（`seriesItems.size != 1` → `InvalidValue`）
- **来源**：存量（规格与 `RocChart.cj` 同为 `0bd79883f`）
- **判据**：review-checklist §13「文档未覆盖实现的硬校验」；§14.1「配置项被读取却未说明挂载位置」
- **证据**：静态确定 —— `spec.md` 全文无「系列数 / 恰好 1 个」表述，实现明确抛错；`auc` 只在 `series[0]` 读取，写在顶层既不生效也不报错（`ChartConfig`/`ChartJson` 不做未知键校验）。`README.md:1925` 的示例写在 `series[0]` 里（正确），说明正确写法只存在于示例、不存在于契约文本
- **描述**：同一批规格里玫瑰图写了「`series` MUST 恰好 1 个」（`add-f-chart-rose/.../spec.md:39`），ROC 漏了；使用者按 spec 传多系列（如多模型对比）会直接拿到 `InvalidValue`，把 `auc` 写在顶层则静默无标注
- **建议**：`spec.md:23-25` 明写「`series[0].auc`」，`spec.md:37-39` 补「`series` MUST 恰好 1 个，否则 `InvalidValue`」，并补一条多系列拒绝用例

### [轻微][存量] 散点矩阵规格未定义 `variables` 与样本行数上限，输出规模是 O(n²·rows)，无任何拒绝路径

- **位置**：`f_chart/doc/spec/add-f-chart-scatter-matrix/specs/chart-rendering/spec.md:7`（按变量数绘制 n×n 单元）、`:9-12`（3 变量 9 行 → 3 个 `diag-label` + 54 个 `matrix-point`）；实现 `f_chart/src/ScatterMatrixChart.cj:149-170`（n² 个 `matrix-cell`）、`:171-207`（n(n−1)·rows 个 `matrix-point`）
- **来源**：存量（规格与 `ScatterMatrixChart.cj` 同为 `23aa7b2c4`）
- **判据**：review-checklist §5「OOM / 拒绝路径」判据项「最坏输入规模 × 单元素内存 ≈ 峰值，有没有大小上限」；§14.1「限制条件缺失」
- **证据**：静态确定（复杂度与图元数）；峰值内存绝对值需实测 —— 图元数为 `n² + n(n−1)·rows`，规格既未声明 `variables` 上限也未声明行数上限，实现亦无上限校验。10 变量 × 2000 行 ≈ 100 + 180 000 个 `<circle>`，再乘单图元约 90~120 字节即 16~22 MB 的 SVG 字符串
- **描述**：这是「规格没写限制、实现也不设限」的典型组合：使用者按 spec 认为任意变量数都支持，实际 10 变量 × 2000 行就要拼出约 18 万个 `<circle>`、20 变量 × 2000 行则到 76 万个（数十 MB 级字符串，`f_chart` 全模块无流式写出，见 `SvgBuilder.toSvgString`）。当前无实测峰值数据，故不按「严重」定级
- **建议**：`spec.md` 的「散点矩阵数据」下补一条限制（如「`variables` ≤ 12 且样本行 ≤ 5000，超出抛 `InvalidValue`，建议经分面拆分」），实现侧加同名校验；若要支持更大规模，需先做分页/子矩阵能力，属独立变更

### [轻微][存量] 桑基图规格与设计都没有定义「有环输入」，`sankeyLayers` 在环上跑满 `nodeCount` 轮后给出任意层级

- **位置**：`f_chart/doc/spec/add-f-chart-sankey/design.md:5`（「对每条边执行 `layer[target] = max(layer[target], layer[source]+1)`，重复节点数轮以覆盖长链」）、`f_chart/doc/spec/add-f-chart-sankey/specs/chart-rendering/spec.md:32-39`（校验清单只有端点存在、`value > 0`、缺字段、`type`）；实现 `f_chart/src/SankeyChart.cj:284-296`、`:186-215`、`:223-244`
- **来源**：存量（设计文档属 `bec0bdbc3`，与 `SankeyChart.cj` 同批）
- **判据**：review-checklist §13「规格与实现漂移（关键边界未定义）」；§14.1「只处理部分输入」
- **证据**：静态确定 —— `sankeyLayers` 用 `changed` 早退，环（a→b、b→a）下每轮都 `changed`，必然跑满 `nodeCount` 轮，层级可涨到 `nodeCount`；随后 `:186-215` 按 `maxLayer` 分列，`:223-244` 无条件从 source 画到 target，于是「指向右侧无节点」的链接会从右列倒着画回左列。`SankeyChart_test.cj` 只有链式用例（`:71-78`），无环用例
- **描述**：桑基图输入通常来自业务流量数据，回流/重试边很容易成环。规格既没说「输入 MUST 为 DAG」，也没说环时如何降级，实现则静默产出图形错乱的结果（不崩、不报错），属于最难排查的一类问题
- **建议**：`spec.md:32-39` 补「`links` 必须构成 DAG，检测到环抛 `InvalidValue`（path 指向首条成环边）」，实现侧在 `sankeyLayers` 前做一次 DFS/Kahn 检测；若希望容忍环，则在文档里写清「成环边层级钳制到 `max(layer[source], 1)`」并在设计里给示意图

> 存量 7 条（1 条一般 + 6 条轻微，全部为文档契约类），是否纳入修复待用户决定。

## 优化可行性方案

本部分 20 个文件全是 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无改前基线 + 改后对照即不成立）。文档中出现的算法线索（散点矩阵 n² 图元、桑基分层轮数、`indexOfNode` 线性查找）已按铁律移入「待验证假设」，不计入本部分统计。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 散点矩阵的输出成本随 `variables² × rows` 增长，n≥10 后单次 `draw` 的耗时与峰值内存可观（规格未设上限，见发现 #6） | `f_chart/src/ScatterMatrixChart.cj:171-207` | 绝对耗时、峰值 RSS、SVG 长度随 n 的曲线 | `cjpm bench -O2`，variables 取 5/10/20/40、rows 固定 1000，每档 5 轮取中位数；同时记录 `draw` 返回串长度与 `getUsedHeapSize()` |
| 2 | 桑基图节点/链接规模大时 `indexOfNode`（每次线性扫节点表）在链接校验、端点映射、流量带绘制三处重复调用，可能占自耗时显著比例 | `f_chart/src/SankeyChart.cj:101`、`:119`、`:138-139`、`:224-225` | 该函数在 `draw` 内的自耗时占比与调用次数 | `cjprof record` 跑 V=200 / E=2000 的合成桑基图，看 `indexOfNode` self time 占比与累计调用次数（静态上为 O(V·E)，但未测实际占比） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-roc/specs/chart-rendering/spec.md` | .md | ✅ | 四条需求逐条对 `RocChart.cj` 核对：x 升序插入排序、`roc-diagonal` 默认 true + `4 4` 虚线、`AUC = 0.86` 文本、`UnsupportedChart` 均一致；`auc` 层级与系列数未写（发现 #5） |
| 2 | `f_chart/doc/spec/add-f-chart-roc/tasks.md` | .md | ✅ | 4 项均已完成；声明的曲线/对角线/AUC/校验用例在 `RocChart_test.cj` 均有对应（187 行） |
| 3 | `f_chart/doc/spec/add-f-chart-rose/design.md` | .md | ✅ | 校验与绘制顺序一致；`maxRadius` 45% 口径与实现不符（发现 #3）；未记录 `name` 缺省为序号（`RoseChart.cj:73`） |
| 4 | `f_chart/doc/spec/add-f-chart-rose/proposal.md` | .md | ✅ | 类名 `rose-slice` / `rose-label`、`roseType` 双模式、内部 `roseRadius` 均落地（`RoseChart.cj:160`，被 `:121` 与测试引用） |
| 5 | `f_chart/doc/spec/add-f-chart-rose/specs/chart-rendering/spec.md` | .md | ✅ | 半径两条场景数值可复算正确（200×50/100、200×√0.25）；零值扇区语义自相矛盾（发现 #2） |
| 6 | `f_chart/doc/spec/add-f-chart-rose/tasks.md` | .md | ✅ | 4 项均已完成；扇区/半径/标签/校验在 `RoseChart_test.cj` 有对应，缺「含 0 值」用例 |
| 7 | `f_chart/doc/spec/add-f-chart-sankey-alias/design.md` | .md | ✅ | 「不新增注册表/工厂，直接复用 `SankeyChart`」与实现一致（全模块无 `type`→`Chart` 映射表） |
| 8 | `f_chart/doc/spec/add-f-chart-sankey-alias/proposal.md` | .md | ✅ | 「新增 `SankeyAlias_test.cj`、无新增实现文件」属实（该测试 78 行，无对应 Chart 类） |
| 9 | `f_chart/doc/spec/add-f-chart-sankey-alias/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #1（「以 `<svg` 开头」与实现相反） |
| 10 | `f_chart/doc/spec/add-f-chart-sankey-alias/tasks.md` | .md | ✅ | 3 项均已完成；`SankeyAlias_test.cj:56-77` 两个用例与任务描述对应 |
| 11 | `f_chart/doc/spec/add-f-chart-sankey/design.md` | .md | ✅ | 分层公式、吞吐量 `max(sumIn,sumOut)`、贝塞尔带与源色均与实现一致；未定义有环行为（发现 #7） |
| 12 | `f_chart/doc/spec/add-f-chart-sankey/proposal.md` | .md | ✅ | 类名三件套与内部 `sankeyLayers` 均落地并有用例（`SankeyChart_test.cj:71-78`） |
| 13 | `f_chart/doc/spec/add-f-chart-sankey/specs/chart-rendering/spec.md` | .md | ✅ | 六个节点/五条流量/链式分层场景与实现一致（分层结果 0,0,1,2,3,4 复算正确）；环未定义（发现 #7） |
| 14 | `f_chart/doc/spec/add-f-chart-sankey/tasks.md` | .md | ✅ | 4 项均已完成；声明的悬空端点用例存在；无环用例 |
| 15 | `f_chart/doc/spec/add-f-chart-scatter-matrix/design.md` | .md | ✅ | 单元 6px 内边距、点半径 2、`matrix-cell` 浅灰边框均与实现一致；未记录行长度为 0 时 `columnRange` 回落 `[0,1]`（`ScatterMatrixChart.cj:214-216`） |
| 16 | `f_chart/doc/spec/add-f-chart-scatter-matrix/proposal.md` | .md | ✅ | 非对角散点 + 对角标签 + 每单元独立归一化均与实现一致；内部 `columnRange` 存在（`:213`） |
| 17 | `f_chart/doc/spec/add-f-chart-scatter-matrix/specs/chart-rendering/spec.md` | .md | ✅ | 3 变量 9 行 → 3 `diag-label` + 54 `matrix-point` 计数复算正确（6 非对角单元 × 9）；规模上限缺失（发现 #6） |
| 18 | `f_chart/doc/spec/add-f-chart-scatter-matrix/tasks.md` | .md | ✅ | 4 项均已完成；点数/标签/列范围/行长度/校验在 `ScatterMatrixChart_test.cj` 有对应用例 |
| 19 | `f_chart/doc/spec/add-f-chart-scatter/design.md` | .md | ✅ | `lineRange` 5% 余量与显式 min/max 优先属实（`LineChart.cj:464-472`）、`ChartTime.parseDays` 与 `chartNiceTicks`、`drawXAxisNumeric` 均存在；`symbol` / time 轴描述与实现不符（发现 #4） |
| 20 | `f_chart/doc/spec/add-f-chart-scatter/proposal.md` | .md | ✅ | 复用 `lineRange` / `drawXAxisNumeric` / `ChartSvgKit` 点形状属实；`symbol`/`symbolSize` 的默认值（circle / 6.0，见 `ScatterChart.cj:81-82`）未写明，属 §13 轻微，不单列 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分 20 个 `.md` 无可执行代码，无外部输入解析、无凭据、无并发。正确性以「文档可复算数值 vs 实现」核对：玫瑰半径双模式（200×0.5 / 200×√0.25）、桑基链式分层五点、散点矩阵 3×3 单元计数（3 + 54）、ROC 六点 1 折线、AUC 文本格式，全部复算成立；不成立的数值差异已落为发现 #3 |
| §1 死代码 | 0 | 文档无声明可判死代码，改做反向检查「文档点名的符号是否真实存在且被引用」：`roseRadius`（`RoseChart.cj:160`，被 `:121` 与测试引用）、`sankeyLayers`（`:275`，被 `:122` 与测试引用）、`columnRange`（`ScatterMatrixChart.cj:213`，被 `:116` 与测试引用）、`lineRange`、`chartNiceTicks`、`ChartTime.parseDays`/`formatDays`、`ChartFrame.drawXAxisNumeric`、`ChartSvgKit.square`/`diamond` 全部命中，无失效引用；无「文档承诺但不存在的入口」 |
| §2 重复逻辑 | 0 | 无函数体可比对。跨文件检索了同语义句（「`type` 不匹配抛 `UnsupportedChart`」「`series` 缺失抛 `MissingField`」「class 固定 …」），属 OpenSpec 变更模板的固定校验项，六份 spec 各自约束不同图表，不构成重复逻辑；两份 `tasks.md`/`design.md` 的四段式结构同理 |
| §3 空实现 | 0 | 文档无函数体；逐条核对了 6 份 spec 承诺的图元/校验都有真实实现点（`roc-*`、`rose-*`、`sankey-*`、`matrix-*`/`diag-label`、`symbol`），未发现「承诺但无输出」的类名或规则；`case "none" => ()` 是有意的空分支（不出点），非承诺缺失，已按文档缺项计入发现 #4 |
| §4 栈溢出 | 0 | 本部分描述的算法全部是定长/单层循环：`sankeyLayers` 外层固定 `nodeCount` 轮、玫瑰扇区单层、散点矩阵双重循环、ROC 插入排序。无递归、无用户可控深度，未引入栈风险；`SankeyChart` 无递归调用（`indexOfNode` 为迭代） |
| §5 OOM | 1 | 命中发现 #6（散点矩阵 n²·rows 图元、无上限与拒绝路径）。其余：桑基/玫瑰/ROC 的图元数随输入线性增长，`data` 为数组但无「按不可信长度预分配」的文档承诺，未发现无界缓存或全局集合 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，文档也没有性能承诺，热点结论不成立；两条复杂度线索（散点矩阵 n²、桑基 `indexOfNode` 的 O(V·E)）已按铁律写入「待验证假设」，不参与统计 |
| §6.2 大粒度锁 | 0 | 文档无锁描述；被核对的所有 `Chart` 实现均为「入参构造 → 输出字符串」的无状态路径，无 `synchronized`、无共享 writer |
| §6.3 并发串行 | 0 | 文档未描述任务提交、并行度或批大小；实现侧无 `spawn` / `Future` |
| §6.4 低效算法 | 0 | 文档未给复杂度结论。实现侧的插入排序（ROC）与线性查节点（桑基）是否构成瓶颈需 profile，未测得占比，按 §6.1 口径不判为发现（已列待验证假设 #2；插入排序的跨文件重复已由第 18 部分作为范围外提示记录） |
| §7 降堆内存方案 | 0 | 本部分无对象生命周期可谈；散点矩阵的「图元数爆炸」属 §5 拒绝路径问题（发现 #6），不是「省一点内存」的优化方案，故不重复计入 |
| §8 降 CPU 方案 | 0 | 无基线数据（无 `cjpm bench` 对照），按铁律不产出 CPU 方案；线索见待验证假设 #1、#2 |
| §9 local mode 可行性 | 0 | 文档不涉及函数内临时大对象；本部分无「改前改后峰值内存」数据，按 §9 只能停留在假设，故不列 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无源码；核对文档时读到的实现边界（空 `series`/空 `data`/`series` 数量/`value<=0`/`maxValue<=0`/轴范围/端点存在性/行长度/`variables` 空）已逐个与六份文档比对，除已列的文档口径差异外未发现新的实现侧缺陷；范围外但顺带读到的两处实参问题见「总评·范围外提示」 |
| §12 并发安全与锁粒度 | 0 | `RocChart`/`RoseChart`/`SankeyChart`/`ScatterMatrixChart`/`ScatterChart` 均为无状态类（`public class … <: Chart` + 空 `init()`，`draw` 内全为局部变量），文档亦未承诺线程安全，无线程共享路径可指认 |
| §14 功能完备性与 README 覆盖 | 2 | 命中发现 #5（ROC `series` 数量硬校验未入规格）、#6（散点矩阵规模上限缺失）。其余 public 图表类（`RocChart`/`RoseChart`/`SankeyChart`/`ScatterMatrixChart`/`ScatterChart`）在 `README.md` 均有独立小节（`:1909`/`:446`/`:1500`/`:1281`/`:73`）与可解析示例，M 编号（M47/M72/M36+M67/M30/M6）与规格标题一致 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完并逐条对照实现；§13 命中 7 条（发现 #1–#7），其中 #1 为「承诺与实现相反」定一般，其余为几何/枚举/边界口径类定轻微 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 个文件是 6 个已完成变更（M6 散点、M30 散点矩阵、M36/M67 桑基与别名、M47 ROC、M72 玫瑰）的归档规格。整体质量中上：每条需求都带可验证场景，场景中的计数与数值（散点矩阵 3 标签 + 54 点、玫瑰 4 扇区、桑基链式 5 级分层、AUC 文本）绝大多数能与当前实现对账，`design.md` 点名的内部辅助函数与复用面（`roseRadius`、`sankeyLayers`、`columnRange`、`lineRange`、`ChartSvgKit` 点形状）都真实存在且有调用者，`tasks.md` 的勾选项与测试文件对得上，没有承诺未实现、占位 TODO 或失效引用。

风险集中在「契约细节与边界未定义」而非功能缺失：一条真正会让人踩坑的是桑基别名规格把「以 `<svg` 开头」写成硬契约（实现永远输出 `<?xml …?>` 前缀），而它自己的验收测试用了更宽的 `contains` 把这条错误验了过去——这是本部分唯一建议优先改的条目。其余六条是文档口径类：玫瑰图零值扇区在规格内部自相矛盾且与实现相反、`maxRadius` 的 45% 与实现公式不等价、散点图 `symbol` / time 轴的四处描述偏差、ROC 漏写 `series` 数量与 `auc` 层级、散点矩阵缺规模上限、桑基图未定义有环输入。均不需要动渲染算法，改文档 + 补边界校验即可。

存量 7 条，是否纳入修复待用户决定。

**范围外提示**（不在本部分 20 个文件内，不占用统计，交由对应源文件部分取证）：

1. `f_chart/src/ScatterChart.cj:128` 把 `LinearScale(min, max, topPixel, bottomPixel)` 的像素入参写成 `(frame.plot.right(), frame.plot.x)`（ROC/散点矩阵等多处都是 `(左, 右)`，见 `RocChart.cj:123`），x 轴数据方向被镜像；`add-f-chart-scatter/design.md:9` 照抄了 `LinearScale(min,max,right,left)`，说明文档与实现是同一个错误，改代码时需同步改文档。
2. `f_chart/src/RocChart.cj:145-151` 的对角线两端用 `yScale.scale(xRange[0])` / `scale(xRange[1])`，当 `yAxis.min/max` 与 x 轴不同（如 `yAxis.min=0.4`）时线段端点落在绘图区外且不构成 45° 基准线——第 18 部分已作为范围外提示记录，此处仅提示同一问题在 `add-f-chart-roc/specs/chart-rendering/spec.md:14-16` 的需求里没有任何裁剪约定（该需求只说「输出 1 条 `roc-diagonal` 虚线」）。
