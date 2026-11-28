# f_chart 模块审查报告（模块第 21/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个 `.md`，0 个 `.cj`；覆盖 `doc/spec/add-f-chart-{stacked-area,stacked-bar,stem-leaf,streamgraph,sunburst,survival}` 六个已完成变更的文档）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染 / 布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑（本部分无源码，专项通过文档承诺反查实现核对：范围、堆叠/基线公式、叶位与钳制、扇环角度与可达性、置信带与删失）
- **报告版本**：v1

## 发现

### [一般][存量] 旭日图 `spec.md` 要求「每个非根节点都出扇环」，实现在「一个根 + 另一段父链成环」时静默丢节点

- **位置**：`f_chart/doc/spec/add-f-chart-sunburst/specs/chart-rendering/spec.md:7`（MUST 为根节点之外的每个节点绘制 `sunburst-arc`）；`f_chart/src/SunburstChart.cj:99-117`（只收集 `parent == null` 的根，`roots.size == 1` 即放行，随后只对 `roots[0]` 调 `resolveTotals` / `sortChildren` / `assignAngles`）、`:150-176`（`resolveTotals` 只沿根下钻）、`:212-249`（`drawNode` 只沿根下钻）
- **来源**：存量（快照模式无基线；`git log -1` 显示 `spec.md` 与 `SunburstChart.cj` 同属 `ed978a37b`「feat(f_chart): M69 旭日图」，是写文档时即未覆盖该输入，不是后续实现漂移）
- **判据**：review-checklist §13（spec 的 MUST 与实现相反）+ §11「静默丢失 / 错误处理缺失」
- **证据**：静态确定 —— spec 的校验清单（`:39`）只要求 `nodes` 非空、id 唯一、恰好一个根、`parent` 指向存在的节点。输入
  `A{id:"a",parent:null,value:1}`、`B{id:"b",parent:"c"}`、`C{id:"c",parent:"b"}` 全部满足：`roots` 只有 A、`roots.size == 1` 通过；B、C 没有 `parent == null`，也不会被访问，`depth` 与 `total` 保持构造时的 0，`drawNode` 从 A 出发遍历不到它们。整条链路没有任何抛错点（`resolveTotals` 的 `depth > total` 兜底只对已访问节点生效）
- **描述**：结果是一张「只有背景与标题、零个 `sunburst-arc`」的 SVG，用户既看不到 B/C，也拿不到异常提示；若 A 还有其它子树，B/C 则无声消失，比例计算也把它们排除在 `nodes.size` 之外。这与 spec 的 MUST 直接相反，也与 `SunburstChart_test.cj` 的「六个扇环」用例口径不一致（该测试只覆盖树形输入，没有环/不可达节点用例）
- **建议**：在构造父子关系之后、计算总量之前加一次可达性校验：从唯一根做 BFS/DFS，访问计数必须等于 `nodes.size`，否则抛 `chartInvalidValue("nodes", "存在无法从根到达的节点（父链成环或断链）")`；同时补一个 `rejectsUnreachableCycle` 用例，并在 `spec.md:39` 的校验清单里写明「所有节点 MUST 可从根到达」

### [轻微][存量] 茎叶图 `spec.md` 缺 `leafDigits` 上限与「叶钳制」两条可观察规则

- **位置**：`f_chart/doc/spec/add-f-chart-stem-leaf/specs/chart-rendering/spec.md:25`（只写「`leafDigits` MUST 为非负整数」）、`:5-12`（分组需求未提钳制）；`f_chart/doc/spec/add-f-chart-stem-leaf/design.md:7`（design 有钳制规则）；`f_chart/src/StemLeafChart.cj:77-80`（`rawDigits > 6.0` 抛 `InvalidValue`，文案「叶位数必须为 0 到 6 的整数」）、`:157-159`（`stemLeafRows` 同样 `> 6` 拒绝）、`:181-187`（leaf 先 `round` 再钳到 `[0, 10^digits-1]`）
- **来源**：存量（`git log -1` → `e52c6e3db`「feat(f_chart): M22 茎叶图」，spec 与实现同批）
- **判据**：review-checklist §13（API / 参数取值域与源码不符）+ §14.1（实现中的硬校验未进规格）
- **证据**：静态确定 —— spec 的验收口径允许任意非负整数（`leafDigits: 7` 合规），实现直接 `InvalidValue`；反向地，实现支持的 0–6 上限在 spec 与 `doc/chart-json-spec.md:854` 都没有记载。钳制同理：`59.96` 在 `stemUnit=10` / `leafDigits=1` 下 `leaf = round(9.96) = 10` 被压回 `9`，输出 `5|9`，与 59.90–59.94 不可区分，这是用户可见的精度损失，但只写在 design 与 `tasks.md` 1.1 的用例名里
- **描述**：按 spec 传 7 位叶会被拒，且错误文案与 spec 冲突；使用者也无法从规格得知「四舍五入进位到 10 的叶会被压回 9」这一取值规则。上限本身合理（`leafCount = 10^leafDigits` 决定叶串宽度），问题只是规格没写
- **建议**：`spec.md:25` 改为「`stemUnit` MUST 大于 0；`leafDigits` MUST 为 0–6 的整数（上限来自 `10^leafDigits` 的叶串宽度）」，并在「茎叶分组」下补一条「叶进位到 `10^digits` 时 MUST 钳到 `10^digits-1`」及示例 `59.96 → 5|9`

### [轻微][存量] 主题河流图 `design.md` 两处描述与实现相反（null 处理、wiggle 边界）

- **位置**：`f_chart/doc/spec/add-f-chart-streamgraph/design.md:5`（「解析 `series[].data` 为等长数值数组，忽略 `null`」）、`:10`（wiggle 平滑「边界复制」）；`f_chart/src/StreamgraphChart.cj:73-78`（非 int/decimal 一律 `chartInvalidValue`，null 会抛错）、`:240-251`（首末列直接 `smoothed.add(baseline[index])`，不是邻点复制后的加权值）
- **来源**：存量（`git log -1` → `1f0666faa`「feat(f_chart): M82 主题河流图」）
- **判据**：review-checklist §13（文档与实现相反）
- **证据**：静态确定 —— `[1, null, 3]` 在 `StreamgraphChart.cj:74` 进入 `else` 分支抛 `InvalidValue`；`smoothed[0] == baseline[0]`，而「边界复制」按 `(b0+2b0+b1)/4` 计算会得到不同数值。spec 侧写的是「等长数值数组」（`specs/chart-rendering/spec.md:30`），与实现一致，故出问题的只是 design
- **描述**：维护者按 design 会认为 null 可作缺测透传，实际直接失败；按「边界复制」复算 wiggle 基线的首末列会得到与实现不一致的数值（差 `(b1-b0)/4`），影响首末两条色带的上下界与 y 轴范围
- **建议**：`design.md:5` 改为「null 视为非法数值，抛 `InvalidValue`」；`:10` 改为「首末列保留 `symmetry` 原值，内部列按 `(b[x-1]+2b[x]+b[x+1])/4` 平滑」

### [轻微][存量] 堆叠面积图的 null 语义空缺，且与堆叠柱状图相反

- **位置**：`f_chart/doc/spec/add-f-chart-stacked-area/specs/chart-rendering/spec.md:28-35`（校验需求只写「数值非法 MUST 抛 `InvalidValue`」）；`f_chart/src/StackedAreaChart.cj:69-79`（`entry.kind.isNull` → `values.add(0.0)`）；`f_chart/src/StackedAreaChart_test.cj:90-104`（`treatsNullAsZero` 断言 null 按 0 堆叠）；对照 `f_chart/doc/spec/add-f-chart-stacked-bar/specs/chart-rendering/spec.md:23-30`（「`null` 段 MUST 跳过」）
- **来源**：存量（`faf081dc7`「feat(f_chart): M15 堆叠面积图」与 `62253cca5`「feat(f_chart): M3 堆叠柱状图」两批文档，快照模式无基线）
- **判据**：review-checklist §13（契约缺口）+ §2「近似重复：同一模板复制后边界判断漂移」
- **证据**：静态确定 —— spec 未出现 null 字样；实现把 null 记为 0 并参与累加，stacked-bar 的 spec 明确跳过 null。两边 spec 的需求文本结构相同，属同一模板复制后语义漂移
- **描述**：同一份数据 `[10, null, 30]` 在 `stacked-area` 里第三个类目总量包含 0（面积带在 null 处贴到前一层顶边），在 `stacked-bar` 里则少一段柱；使用者从 spec 无法判断哪种行为，也无法解释两图差异。另一层歧义：若把 null 视作「数值非法」，实现反而违反了 `:30` 的 MUST
- **建议**：`spec.md` 的校验需求补一句 null 的确定语义（建议与 stacked-bar 对齐为「跳过」，或明确「按 0 累加」），并在 `proposal.md` 的字段说明里同步

### [轻微][存量] 堆叠面积图「含负值」场景的断言单侧，锁不住「顺序累加」这一语义

- **位置**：`f_chart/doc/spec/add-f-chart-stacked-area/specs/chart-rendering/spec.md:19-26`；实现 `f_chart/src/StackedAreaChart.cj:175-187`（组内顺序累加，负值不单独起栈）、`:347-377`（`stackedAreaBounds` 取累计过程中的极值）；测试 `f_chart/src/StackedAreaChart_test.cj:80-88`（断言 `bounds[0] == -10.0`）
- **来源**：存量（`faf081dc7`「feat(f_chart): M15 堆叠面积图」；快照模式无基线）
- **判据**：review-checklist §13（`doc/spec` 验收口径不足以锁定实现）
- **证据**：静态确定 —— 场景只要求「下界不超过 -10」，任何把下界取到 -30、-1000 的实现同样通过；而实现的实际语义是 20 与 -30 顺序累加得 -10（测试断言等式），与堆叠柱状图「正值、负值分别从 0 起栈」正好相反
- **描述**：读者很容易把该场景理解成「负值单独成栈，下界应为 -30」，从而把正确实现判成 bug、或把改成 -30 的回归判成通过；场景本身也无法发现下界被过度放大的缺陷
- **建议**：场景改为「同组 20 与 -30 顺序累加得 -10，`y` 下界 = -10 × 1.05」，并补一句「堆叠面积不做正负分离堆叠，与 `stacked-bar` 不同」

### [轻微][存量] 堆叠柱状图场景标题「两组三系列」与正文「2 个系列、3 个类目」矛盾

- **位置**：`f_chart/doc/spec/add-f-chart-stacked-bar/specs/chart-rendering/spec.md:9-12`
- **来源**：存量（`62253cca5`「feat(f_chart): M3 堆叠柱状图」；快照模式无基线）
- **判据**：review-checklist §13（同一场景内自相矛盾，验收时无法判断该造 2×3 还是 3×2 的数据）
- **证据**：静态确定 —— 标题写「两组三系列」，正文写「输入 2 个系列、3 个类目」，期望「6 个 `class="bar"`」
- **描述**：6 段在两个读法下都成立，但「组」在堆叠语境里指 `stack` 分组（堆叠柱没有分组概念），标题是复制分组柱模板的残留，会误导构造用例
- **建议**：标题改为「两系列三类目」，或直接删掉「组」字

### [轻微][存量] 堆叠柱状图 `design.md` 的柱宽公式漏了 0.95 截断与 `barWidth > 0` 校验

- **位置**：`f_chart/doc/spec/add-f-chart-stacked-bar/design.md:9`（「柱宽：`series[0].barWidth ?? bandWidth * 0.6`，所有段共用」）；`f_chart/src/BarRenderer.cj:126-130`（`minFloat(stackedWidth, band.bandWidth * 0.95)`）、`:259-265`（`barWidth <= 0` 抛 `InvalidValue`）
- **来源**：存量（`62253cca5`「feat(f_chart): M3 堆叠柱状图」；快照模式无基线）
- **判据**：review-checklist §13（文档给出的布局公式与实现不一致）
- **证据**：静态确定 —— design 的公式没有上限，实现会静默截断到 `0.95 × bandWidth`；`barWidth <= 0` 的抛错分支在 design / spec 中均无记载
- **描述**：按 design 传 `barWidth: bandWidth * 2` 时实际柱宽只有 `0.95 × bandWidth`，视觉与入参不符且无提示；传 0 或负数则直接 `InvalidValue`。这类「静默截断 + 未记载校验」会让按文档调参的人反复试错
- **建议**：`design.md:9` 补「实际柱宽 = `min(series[0].barWidth ?? bandWidth*0.6, bandWidth*0.95)`；`barWidth <= 0` 抛 `InvalidValue`」

> 存量 7 条（一般 1、轻微 6），是否纳入修复待用户决定。

## 优化可行性方案

本部分为 20 个 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无基线即不成立）。核对时读到的源码侧算法线索见「总评·范围外提示」，交由对应源文件部分取证与统计。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| — | 无 | — | 本部分文档不含性能承诺；提到的常量（叶位数上限 6、透明度 0.85/0.15、5% 余量）都不随输入增长，不存在「文档宣称的性能结论待验证」 | — |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-stacked-area/specs/chart-rendering/spec.md` | .md | ✅ | 累加/分组/图例与 `StackedAreaChart.cj:96-238` 一致；null 语义与负值场景见发现 #4、#5 |
| 2 | `f_chart/doc/spec/add-f-chart-stacked-area/tasks.md` | .md | ✅ | 4 项均 `[x]`；点名的 `stackedAreaBounds` 存在（`StackedAreaChart.cj:347`）；`tasks` 提到的「缺测」「确定性」在 `spec.md` 无对应需求（并入 #4） |
| 3 | `f_chart/doc/spec/add-f-chart-stacked-bar/design.md` | .md | ✅ | x 公式、正/负段 `from→to`、class 名与 `BarRenderer.cj:124-162` 一致；柱宽漏截断与校验（#7） |
| 4 | `f_chart/doc/spec/add-f-chart-stacked-bar/proposal.md` | .md | ✅ | `type`、`BarRenderer` 新增 `Stacked` 模式、新增文件均与实现一致（`BarRenderer.cj:42`、`StackedBarChart.cj:25-30`） |
| 5 | `f_chart/doc/spec/add-f-chart-stacked-bar/specs/chart-rendering/spec.md` | .md | ✅ | 同 x、正负堆叠、范围按正/负总和、null 跳过、`bar-negative` 与实现逐条一致；场景标题见 #6 |
| 6 | `f_chart/doc/spec/add-f-chart-stacked-bar/tasks.md` | .md | ✅ | 7 项均 `[x]`；`stackedBarX` 存在（`BarRenderer.cj:450`）并被 `BarRenderer.cj:132` 调用 |
| 7 | `f_chart/doc/spec/add-f-chart-stem-leaf/design.md` | .md | ✅ | 茎/叶公式、排序、行高、class 名与 `StemLeafChart.cj:146-204` 一致；钳制规则仅此处有（#2） |
| 8 | `f_chart/doc/spec/add-f-chart-stem-leaf/proposal.md` | .md | ✅ | 默认值 `stemUnit=10` / `leafDigits=1` 与 `:73-77` 一致；`stemLeafRows` 存在且被 `:81` 调用 |
| 9 | `f_chart/doc/spec/add-f-chart-stem-leaf/specs/chart-rendering/spec.md` | .md | ✅ | 分组与渲染需求成立；参数域与钳制缺项（#2） |
| 10 | `f_chart/doc/spec/add-f-chart-stem-leaf/tasks.md` | .md | ✅ | 4 项均 `[x]`；分组/排序/渲染/叶钳制/参数/校验在 `StemLeafChart_test.cj` 均有对应用例 |
| 11 | `f_chart/doc/spec/add-f-chart-streamgraph/design.md` | .md | ✅ | 基线三模式与 `streamBaseline`（`:229-254`）一致；null 与 wiggle 边界描述不符（#3） |
| 12 | `f_chart/doc/spec/add-f-chart-streamgraph/proposal.md` | .md | ✅ | `baseline` 默认 `wiggle`、三取值、0.85 透明度、`streamBand` class 均与实现一致 |
| 13 | `f_chart/doc/spec/add-f-chart-streamgraph/specs/chart-rendering/spec.md` | .md | ✅ | 三条需求（带、基线、校验含 labels 长度/`baseline` 取值/`type`）与 `StreamgraphChart.cj:43-104` 逐条一致 |
| 14 | `f_chart/doc/spec/add-f-chart-streamgraph/tasks.md` | .md | ✅ | 4 项均 `[x]`；色带/基线/校验在 `StreamgraphChart_test.cj` 有对应用例 |
| 15 | `f_chart/doc/spec/add-f-chart-sunburst/design.md` | .md | ✅ | 0.45 外半径、`innerRadius` 内孔、环宽按最大深度、-π/2 起算、名称散列取色均与 `SunburstChart.cj:117-137`、`:253-276` 一致（环宽分母对应 `totalDepth`，`:124-125`） |
| 16 | `f_chart/doc/spec/add-f-chart-sunburst/proposal.md` | .md | ✅ | 节点字段、`innerRadius=0.2`、`sort=value`、两个 class 名与实现一致；文件与 `sunburstArcPath` 均存在 |
| 17 | `f_chart/doc/spec/add-f-chart-sunburst/specs/chart-rendering/spec.md` | .md | ✅ | 排序、标签、校验（id 唯一/单根/父存在/叶值>0/`innerRadius` 0–0.95）与实现一致；「每个非根节点出弧」见 #1 |
| 18 | `f_chart/doc/spec/add-f-chart-sunburst/tasks.md` | .md | ✅ | 4 项均 `[x]`；扇环/路径/标签/排序/校验在 `SunburstChart_test.cj` 有对应用例，但无环或不可达节点用例（#1） |
| 19 | `f_chart/doc/spec/add-f-chart-survival/design.md` | .md | ✅ | 稳定排序、x `[0, maxTime*1.02]`、y `[0,1]`、阶梯线两段式、二项置信公式、`+` 删失标记与 `SurvivalChart.cj:53-308` 逐项一致（`n` 取点数与 `:196-198` 一致） |
| 20 | `f_chart/doc/spec/add-f-chart-survival/proposal.md` | .md | ✅ | `confidence=false`、`showCensors=true`、4 个 class 名与实现一致；`survivalConfidence` 存在且被 `:198`、`:209` 调用 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 本部分 20 个 `.md` 无执行代码；逐条复算了文档中的可验证数值（堆叠累计 20→-10、`100×1.05`、`-totals/2` 对称基线、5%/1.02/0.45/0.6 比例、置信 `1.96·sqrt(S(1-S)/n)`、`59.96` 的叶钳制），并核对渲染实现，命中 1 条实现侧静默丢节点（#1）；其余为文档口径问题 |
| §1 死代码 | 0 | 文档无声明可判死代码。反向做了「文档点名符号是否真实存在」检查：`stackedAreaBounds`、`groupIndexesOf`、`uniqueGroupCount`、`stackedBarX`、`groupedBarX`、`stemLeafRows`、`streamBaseline`、`sunburstArcPath`、`survivalConfidence` 全部在 `f_chart/src/*.cj` 命中且有调用者或测试引用，6 个 `*_test.cj` 也都在仓内，无失效引用 |
| §2 重复逻辑 | 1 | 六组文档的 `## ADDED Requirements` / `Capabilities` 结构属 OpenSpec 格式要求，需求正文互不相同；逐对比较后唯一语义漂移是同一模板下的 null 处理（stacked-area 记 0 vs stacked-bar 跳过），已并入 #4。源码侧插入排序多处重复不在本部分清单内，见「范围外提示」 |
| §3 空实现 | 0 | 6 个目录内 grep `TODO` / `FIXME` / `待实现` / `暂不` 无命中（唯一 `后续` 命中是 `survival/design.md:16` 的「每个后续点」，非占位）；proposal 声明的类与内部函数均有实现与测试 |
| §4 栈溢出 | 0 | 文档描述的递归只有旭日图 `resolveTotals` / `drawNode`，实现以 `depth > nodes.size` 兜底，可达深度受节点数约束；茎叶/河流/生存均为单层循环。文档本身无递归描述 |
| §5 OOM | 0 | 文档未承诺无界容器或按不可信长度预分配；叶串宽度上界由 `leafDigits ≤ 6` 限制（该上限未写进 spec，见 #2），其余图形状均随输入线性增长 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，也无性能承诺，热点结论不成立；未写入待验证假设 |
| §6.2 大粒度锁 | 0 | `f_chart` 渲染路径为「入参构造 → 输出字符串」，无锁、无 I/O、无共享缓存；文档无并发语义 |
| §6.3 并发串行 | 0 | 文档未描述任务提交、批大小或并行度配置 |
| §6.4 低效算法 | 0 | 文档未描述复杂度；实现中的插入排序（`StemLeafChart.cj:164-172`、`SurvivalChart.cj:280-288`、`SunburstChart.cj:182-192`）属源码线索，无基线不判定，见「范围外提示」 |
| §7 降堆内存方案 | 0 | 本部分无运行时对象生命周期；无基线，按铁律不写方案 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档无函数内临时大对象描述；无改前改后峰值内存数据，按 §9 只能是假设，故不列 |
| §11 现有代码的 BUG（存量） | 1 | 命中 #1（旭日图静默丢节点）。核对文档时读到的其它边界：堆叠图长度校验（`StackedAreaChart.cj:87-94`、`BarRenderer.cj:304-313`）、`resolveYRange` 的退化区间处理（`:299-304`）、`stemUnit` 的 NaN/Inf 校验（`StemLeafChart.cj:74`）、生存曲线空 `data` 与时间/生存率范围（`SurvivalChart.cj:73-93`）均已与文档对齐，未发现新缺陷 |
| §12 并发安全与锁粒度 | 0 | 六个 `Chart` 实现均为无状态类（`init()` 空构造 + `draw` 内局部变量），文档也未承诺线程安全，无线程共享路径可指认 |
| §14 功能完备性与 README 覆盖 | 0 | 六份 proposal / tasks 点名的能力（堆叠面积、堆叠柱 `Stacked` 模式、茎叶文本行、主题河流色带、旭日扇环、生存阶梯线与置信带）均有实现与测试，未发现「承诺但未实现」；README 是否收录这 6 个 `type` 不在本部分文件清单内，交由 README 所属部分核对 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完；§13 一致性命中 7 条（#1–#7） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 个文件是 6 个已完成变更（M15 堆叠面积、M3 堆叠柱、M22 茎叶、M82 主题河流、M69 旭日、M49 生存曲线）的规格与设计记录，主体质量好：核心公式（累计范围、正负分离堆叠、茎叶 `floor/round` 与钳制、三基线平滑、扇环内外弧、KM 阶梯与二项置信带）都能与当前实现逐项对上，class 名、默认值、错误类型也基本一致；`tasks.md` 声明的用例在对应 `*_test.cj` 里确实存在。没有空实现、占位 TODO 或失效引用。

唯一需要排期修的是旭日图的可达性缺口（#1）：spec 的 MUST 与实现相反，且属于「静默少画」而非报错，用户很难自查；修法是校验阶段加一次可达性计数，属于低风险改动，但要注意别把「合法森林」误杀（当前 spec 已要求恰好单根）。其余 6 条都是文档口径问题，按条更新文档即可，不必动实现：茎叶图的 `leafDigits` 上限与叶钳制只写在 design 里（#2）；主题河流 design 的 null 与 wiggle 边界已被实现超越（#3）；堆叠面积的 null 语义空缺且与堆叠柱相反（#4）；负值场景的断言单侧、锁不住「顺序累加」（#5）；堆叠柱的场景标题残留「组」、design 柱宽漏截断与校验（#6、#7）。

存量 7 条（一般 1、轻微 6），是否纳入修复待用户决定。

**范围外提示**（不在本部分 20 个文件内，不占用统计，交由对应源文件部分取证）：

1. 插入排序在三处逐行同构，仅元素类型/比较键不同：`f_chart/src/StemLeafChart.cj:164-172`（`Array<Float64>`）、`f_chart/src/SurvivalChart.cj:280-288`（`Array<SurvivalPoint>` 按 `time`）、`f_chart/src/SunburstChart.cj:182-192`（`ArrayList<SunburstNode>` 按 `total` 降序）。属 §2「只改类型名」型重复，可抽一个带比较键的 `sortStable`；O(n²) 是否成热点需 `cjprof` 与输入规模数据，当前无基线。
2. `f_chart/src/SunburstChart.cj:224-226`（`:225` 调用）复用 `flameColorIndex`（定义在 `FlameChart.cj:252`），同函数还被 `IcicleChart` / `HiveChart` / `CirclePackingChart` / `NodeLinkChart` / `WordNetworkChart` / `OfflineFlameChart` / `TuiFlameChart` 引用——跨 9 个文件（含 `FlameChart.cj` 自身）共用的取色哈希挂在 `FlameChart.cj` 里，命名与位置都应按「共享工具」重新安置（如 `ChartTheme`），否则任一图表重命名都会牵动一片。
3. `f_chart/doc/chart-json-spec.md:854` 的茎叶图小节与本部分 #2 同源：同样只写「`leafDigits`（叶位数，默认 1）」，未记 0–6 上限与钳制规则；该文件不属于本部分清单。
