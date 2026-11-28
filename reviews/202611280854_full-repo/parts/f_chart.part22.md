# f_chart 模块审查报告（第 22/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个文件，全部为 `doc/spec/**` 下的 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：本轮按 dispatch 表覆盖 f_chart 专项（渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑）在**文档侧**的落点：归档 spec 四件套与实现的契约一致性（§13 / §14）、跨文档重复逻辑（§2）、文档点名符号是否真实存在（§1 反向核对）
- **报告版本**：v1（分部分报告，供主 Agent 合并进 `f_chart_v2.md`）

> 本部分清单只含 6 个已归档变更的 spec 文档（survival / swarm / swimlane / tag-cloud / timeline / treemap）。按 checklist §13 误报边界，`doc/spec/<已归档变更>/` 以「当时结论是否自洽」为准，故下文只报**文档自相矛盾**与**文档承诺 vs 现有实现不符**两类，不要求归档文档追平后续演进。对应实现文件（`SurvivalChart.cj`、`SwarmChart.cj`、`SwimlaneChart.cj`、`TimelineChart.cj`、`TreemapChart.cj`、`WordCloudChart.cj`）分属第 34/35/36 部分，本部分只把它们当取证材料，纯代码缺陷不在此计数量。

## 发现

### [一般][存量] treemap：承诺「叶子节点必须有 value」，实现允许缺失并按 0 静默处理

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/proposal.md:10`（承诺）；`f_chart/src/TreemapChart.cj:88-99`（value 可选解析）、`:159-172`（叶子缺 value → 0.0）、`:200-207`（零面积仍输出 cell）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13（规格与实现漂移）/ §11（错误处理缺失、失败路径当成功）
- **证据**：静态确定 —— proposal 写「叶子节点必须有 `value`，内部节点值由子节点求和」；`TreemapChart.cj:88-99` 中 `value` 走 `match (json.value("value")) { case None => None<Float64> }`，只有「存在但 ≤ 0」才抛 `InvalidValue`，缺失不抛；`nodeValue` 对无 value 的叶子返回 `0.0`，父节点 `total` 不含它，`ratio = 0` 后仍进入 `layoutNode` 叶子分支画出宽或高为 0 的矩形。测试 `TreemapChart_test.cj:56-74` 只覆盖「四个叶子都有 value」与「负值被拒」，无缺 value 用例
- **描述**：按文档写「内部节点带 name、叶子带 value」时少写一个 `value`，该节点会退化为 0 面积（肉眼不可见），它的兄弟节点则均分整块面积；若整棵树都没有 value，`total <= 0` 直接 `return`，输出一张只有背景和标题的空图，全程无异常。使用者拿到的是「成功但内容缺失」的 SVG，比报错更难排查
- **建议**：在构建树时对「无子节点且 `value == None`」抛 `chartInvalidValue("${itemPath}.value", "叶子节点必须提供 value")`；或在解析两遍之后统一校验（第一遍建节点、第二遍挂父子，此时已知谁是叶子）。若确实允许省略，则须在 proposal 与 `chart-json-spec.md` 中写明「缺失视为 0 / 不绘制」并补测试

### [一般][存量] treemap：proposal 声称 `squarify` 布局，design 与实现都是 slice-and-dice，仓内无 squarify 算法

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/proposal.md:11`（「使用 `squarify` 布局（按面积分配矩形）」）；`f_chart/doc/spec/add-f-chart-treemap/design.md:11`（「沿较长边按比例切分」）；`f_chart/src/TreemapChart.cj:118-121`、`:226-243`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13（文档承诺与实现相反）/ §14.1（承诺了但没实现）
- **证据**：静态确定 —— 全仓 grep `squarify` 只命中三处字符串与 README/规范文案（`README.md:101`、`README_en.md:101`、`doc/chart-json-spec.md:1318`、`src/TreemapChart.cj:118`、`src/TreemapChart_test.cj:42`、`src/ChartGallery_test.cj:792`），无任何按行布局（row-based）计算长宽比、挑选最优切分点的实现；`layoutNode`（`:226-243`）每次比较 `remainingWidth >= remainingHeight` 后把**全部**子节点沿同一轴按 `ratio` 切开，这正是 slice-and-dice，与 design.md:11 的描述一致
- **描述**：proposal 与 design 对同一能力给出两个不同算法名，而实现站在 design 一侧。对外宣称 `tiling: "squarify"` 时，用户预期的是长宽比接近 1 的块（squarify 的核心价值），实际得到的是细长条，尤其子节点数量多、比例悬殊时几乎不可读。这不是「文档写错一个词」，而是把一种布局算法挂上了另一种算法的名字
- **建议**：二选一并对齐三处文档——(a) 把 `tiling` 取值改为 `slice`（或 `slice-dice`），proposal/README/`chart-json-spec.md` 同步改名，并把「squarify 布局」从 M34 描述中删除；(b) 真正实现 squarify（按行装箱、最小化最大长宽比），再保留当前 `tiling` 名。改名前须用户确认是否影响下游按 `tiling` 值编写的配置

### [一般][存量] survival：置信带的 `n` 文档称「样本数」，实现固定取「该系列点数」，且无对应输入字段

- **位置**：`f_chart/doc/spec/add-f-chart-survival/specs/chart-rendering/spec.md:30`、`:37-40`；`f_chart/src/SurvivalChart.cj:196`、`:198`、`:209`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13（API / 参数 / 默认值与源码不符）/ §11（语义与命名、注释不符）
- **证据**：待确认 —— 静态可确定「实现取点数」：`let count = Int64(series.points.size)` 后传给 `survivalConfidence(...)`；`grep -rn "sampleSize\|样本数" f_chart/src f_chart/doc/spec/add-f-chart-survival` 在 `SurvivalChart.cj` 与 survival spec 内零命中字段名，说明**没有任何输入项能让调用方指定样本量**。缺的是作者意图：`n` 到底应当等于点数还是业务样本量
- **描述**：spec 用「样本数」描述公式，场景又写「`survival` 为 0.5、样本数为 100」；但 JSON 里不存在样本量字段，渲染时 `n = 该系列 data 数组长度`。Kaplan-Meier 场景里一条曲线常有 5–10 个时点却对应上百例样本，此时 `sqrt(S(1−S)/n)` 被点数放大，置信带明显宽于统计真实值（点数少时更窄），band 的宽度语义随「画了几个点」漂移。使用者按文档「样本数」理解时无处可传该值
- **建议**：明确 `n` 的口径并写进 spec：若维持「点数」，把文档改为「n 为该系列数据点个数」并在场景里改写为「2 个时点」这类可核对的表述；若要用真实样本量，新增可选字段（如 `series[].atRisk` 或 `sampleSize`）并在 `SurvivalChart` 中按点取值，缺省回落到点数

### [一般][存量] swarm：spec / proposal 未声明「仅支持 1 个系列」，实现硬拒第二个系列

- **位置**：`f_chart/doc/spec/add-f-chart-swarm/proposal.md:10`；`f_chart/doc/spec/add-f-chart-swarm/specs/chart-rendering/spec.md:23-25`、`:34`；`f_chart/src/SwarmChart.cj:50-52`
- **来源**：存量（快照模式）
- **判据**：review-checklist §14.1（能力边界未文档化，文档写 `series[]` 而实现只吃 1 个）/ §13（契约与实现不符）
- **证据**：静态确定 —— proposal 用 `series[].data`（复数）描述数据形状；spec 的「蜂群数据形状」只规定嵌套/扁平与「每组不得为空」，校验清单列了 `jitter`、`side`、`series` 缺失、`type` 不匹配，**没有**系列数量约束；实现 `if (seriesItems.size != 1) { throw chartInvalidValue("series", "蜂群图仅支持 1 个系列") }`
- **描述**：按 proposal 写两个系列（例如「对照组 / 处理组各一组点」）会直接拿到 `InvalidValue`，而 spec、proposal 都没有这条约束，报错信息 `series` 也不指向文档里任何一句。design.md:5「与 `ViolinChart` 一致」是唯一的间接线索，但要读者自己去读另一个图表的设计文档才能推断
- **建议**：在 spec 的「蜂群数据形状」加一条 `series` MUST 恰为 1 项（多组数据 MUST 用 `data` 的嵌套数组表达），proposal 把 `series[].data` 改为 `series[0].data`；若要放开多系列，则按系列着色并在图例中区分

### [一般][存量] treemap：design 的校验清单漏掉「节点不在根之下」，实现静默丢弃整棵子树

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/design.md:5-7`、`:19-21`；`f_chart/src/TreemapChart.cj:103-117`、`:146`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（错误处理缺失 / 失败路径当成功）、§13（校验口径与实现不符）
- **证据**：静态确定 —— design 只要求「按 id 建立节点，校验 id 唯一与 parent 存在」「恰好一个根」；实现按 `parent` 把子节点挂到父节点（`:104-114`），只有 `parent` 为空者进 `roots`（`:112`），再判 `roots.size != 1`（`:115-117`）。因此「A.parent=B、B.parent=A、另有独立根 R」这种输入：两个环上节点都有 parent、都有存在的 parent，校验全过、`roots.size == 1` 也过，但布局从 `R` 递归（`:146`），A/B **既不报错也不出现在 SVG 里**，其 value 也不计入任何面积
- **描述**：父链成环时节点被无声吞掉，图看起来「正常但少了一块」；由于面积总和由根递归算出，兄弟块会按比例放大，读者看不出缺失。design 没定义「不可达节点」的处理，实现选择了最不易察觉的一种
- **建议**：挂完父子后从根做一次可达性遍历（或并查集），凡未访问到的节点抛 `chartInvalidValue("nodes", "节点 ${id} 不在根节点的层级内（可能存在环）")`；同时在 design §1 补一条「所有节点 MUST 从根可达」的校验条目

### [轻微][存量] swimlane：design 只写单侧预留，实现两侧各留一份，节点区比文档窄 90/30px

- **位置**：`f_chart/doc/spec/add-f-chart-swimlane/design.md:5-6`；`f_chart/src/SwimlaneChart.cj:169`、`:227`、`:233`、`:229-230`、`:235-236`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13（布局参数与文档不符）
- **证据**：静态确定 —— design 写「左侧预留 90px 写泳道名」「顶部预留 30px 写泳道名」；实现 `laneLabelWidth = if (horizontal) 90.0 else 30.0`，而可用长度取 `contentWidth = plot.width - laneLabelWidth * 2.0`（:227）、`contentHeight = plot.height - laneLabelWidth * 2.0`（:233），即横向左右各 90px、纵向上下各 30px
- **描述**：文档读者会认为横向泳道的节点区宽 `plot.width - 90`，实际是 `plot.width - 180`，图的右半侧固定留白 90px。调整泳道名宽度时按文档只改一侧预留，会得到文档没描述过的居中偏移
- **建议**：design 改为「首尾各预留 90px（横向）/ 上下各 30px（纵向），节点在剩余区间内等距分布」，或把实现改成只让 `laneLabelWidth` 占首侧、尾侧仅留 `plot` 自身的 padding

### [轻微][存量] swimlane：实现额外输出 `swimlane-divider` 与 `swimlane-arrow`，proposal 的 class 清单未登记

- **位置**：`f_chart/doc/spec/add-f-chart-swimlane/proposal.md:12`、`design.md:7`、`:15-17`；`f_chart/src/SwimlaneChart.cj:180`、`:196`、`:265`、`:295`
- **来源**：存量（快照模式）
- **判据**：review-checklist §14.2（公开输出未文档化，点名符号）
- **证据**：静态确定 —— proposal 列出的 class 为 `swimlane-lane` / `swimlane-label` / `swimlane-node` / `swimlane-node-label` / `swimlane-edge`（5 个）；实现额外产出 `swimlane-divider`（每条泳道的分隔线，:180、:196）与 `swimlane-arrow`（每条边的箭头三角，:265、:295）。spec 只按「3 条边 → 3 个 `swimlane-edge`」计数，箭头是独立的第三个 path，不在计数口径内
- **描述**：下游要改箭头颜色或隐藏分隔线时，文档里查不到这两个 class；按「每条边一个元素」写 CSS 或后处理（例如给 `.swimlane-edge` 加 marker）时会发现箭头是另一条 path，样式不跟随
- **建议**：proposal:12 的 class 清单补 `swimlane-divider`、`swimlane-arrow`，并说明箭头是与边同色的独立 path（若改为 `<marker>` 引用，需同步改文档与测试计数）

### [轻微][存量] timeline：design 写「首尾各留 40px」，实现为 48px，轴线端点另留 20px 未记录

- **位置**：`f_chart/doc/spec/add-f-chart-timeline/design.md:10`、`:9`；`f_chart/src/TimelineChart.cj:101-105`、`:106-107`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13（布局参数与实现不符）
- **证据**：静态确定 —— design「事件 x 坐标在 plot 内等距分布，首尾各留 40px」；实现 `let left = plot.x + 48.0` / `let right = plot.right() - 48.0`，轴线为 `plot.x + 20.0` → `plot.right() - 20.0`
- **描述**：差 8px 本身无关紧要，但它说明这张图的边距常量没有单一来源：轴线留 20、事件留 48，文档写 40，三处不一致。后续有人按文档调边距会同时改错两处
- **建议**：design 写成「轴线端点各留 20px、事件端点各留 48px」，或把这些数字提为具名常量并在 design 里引用常量名而非字面量

### [轻微][存量] survival：spec 只定义「series 缺失 → MissingField」，未覆盖「series 存在但为空数组」

- **位置**：`f_chart/doc/spec/add-f-chart-survival/specs/chart-rendering/spec.md:44`；`f_chart/src/SurvivalChart.cj:56-60`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（错误种类与语义不符）、§13（校验口径缺失）
- **证据**：静态确定 —— spec 校验条目为「`series` 缺失抛 `MissingField`」；实现先 `root.requiredArray("series")`（缺失才抛 MissingField），随后对空数组显式 `throw chartMissingField("series")`，即「字段存在但为空」也被报成 `MissingField`
- **描述**：`{"type":"survival","series":[]}` 属于「字段在、内容非法」，却被报成「缺少必填字段」，调用方按 `kind` 分支处理（缺失→补默认值、非法→改数据）时会走错分支。文档也没告诉使用者空数组应当得到什么
- **建议**：spec 补一条「`series` 为空数组抛 `InvalidValue`」，实现把 `:58-60` 改为 `chartInvalidValue("series", "至少需要一个系列")`（与本模块其它图表空数组的 `InvalidValue` 口径一致）

### [轻微][存量] treemap：为单测新增的 `treemapWeights` 未接入布局，与布局内的比例计算重复

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/proposal.md:27`；`f_chart/src/TreemapChart.cj:231`、`:248-264`；`f_chart/src/TreemapChart_test.cj:64-74`
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（同语义换算两处实现）、§14.1（接线缺失）
- **证据**：静态确定 —— 全仓 grep `treemapWeights` 只有三处：定义 `TreemapChart.cj:248`、测试 `TreemapChart_test.cj:66`、proposal 与 tasks 的文案；渲染路径一次都没调用它，布局在 `:231` 自行写 `nodeValue(child) / total`。两者语义都是「值 → 占比」，只有 `treemapWeights` 多了「≤0 抛错 / 总和 ≤0 抛错」的校验
- **描述**：`computesWeights` 用例断言的是这条**不参与绘制**的辅助函数的归一化，面积是否正确分配完全没被覆盖——`layoutNode` 里切片比例算错、或切轴后算错，测试照样全绿。两处比例换算长期并存，校验规则也只挂在无人调用的那份上
- **建议**：布局改为调用 `treemapWeights(children.map(nodeValue))` 取得 ratios（顺带复用 ≤0 校验），或删掉该函数、把测试改成断言 `treemap-cell` 的 `width`/`height` 与面积比例（后者能真正覆盖布局）

### [轻微][存量] treemap：design 说「颜色按系列/深度轮转」，实现按叶子出现顺序全局轮转

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/design.md:13`；`f_chart/src/TreemapChart.cj:46`、`:201-202`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13（文档与实现不一致）
- **证据**：静态确定 —— design「颜色按系列/深度轮转」；实现 `let color = config.theme.colorAt(this.leafIndex); this.leafIndex++`，`leafIndex` 是**实例字段**（`:46`），在 `draw` 开头重置（`:141`）后按叶子遍历顺序递增，与深度、系列都无关
- **描述**：同一层的兄弟节点颜色连续，而跨层同源的分支颜色不相关；读者按「按深度」预期去找配色规律会落空。另外 `leafIndex` 是可变实例状态，`TreemapChart` 作为 `public` 类若被并发复用（同一实例两次 `draw` 交错）颜色会串——这是代码侧问题，留第 35 部分判定
- **建议**：design 改为「颜色按叶子遍历顺序轮转」，或实现改为 `colorAt(depth)` / `colorAt(根下的第一层分支索引)`，使「同一子树同色系」这个语义成立

### [轻微][存量] tag-cloud：spec 用 3 个场景重述词云既有要求，别名需求本身只需一条等价声明

- **位置**：`f_chart/doc/spec/add-f-chart-tag-cloud/specs/chart-rendering/spec.md:5-20`（尤其 `:12-15` 字号边界、`:17-20` 拒绝其它类型）；对照 `f_chart/doc/spec/add-f-chart-word-cloud/specs/chart-rendering/spec.md:1-20`
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（字面量/规则复制，两处需同步）
- **证据**：静态确定 —— tag-cloud 的 4 个场景中：「文档示例（4 个词 → 4 个 `word-cloud-word`）」「字号边界（默认 12/64）」「其他类型仍被拒绝」三条都在复述词云已有的渲染与校验规则（词云 spec 的「文档示例」「字号范围」「非法字号」场景覆盖同一逻辑），而 requirement 正文已经写了「行为与 `word-cloud` 完全一致」，三条场景对它没有新增信息
- **描述**：别名变更的价值在于「不产生第二份实现」，但 spec 侧仍然产生了第二份规则描述。默认字号 12/64 只写在这份 alias spec 里（实现 `WordCloudChart.cj:44-45`），词云 spec 只写「映射到 min/max」——哪天默认值改了，改词云 spec 不会提醒改这份
- **建议**：tag-cloud spec 只保留一条 requirement +「与 `word-cloud` 输出逐字节一致」的场景（用同一份输入跑两种 `type` 断言 SVG 相等），把字号/词数/拒绝类型的断言交回词云 spec

> 存量共 12 条（一般 5 / 轻微 7），是否纳入修复待用户决定。

## 优化可行性方案

> 本部分只有文档，无运行期代码，不产生可度量的堆内存 / CPU 收益方案。相关性能线索写在「待验证假设」，且因为实现文件不在本部分清单内，不在本报告给改造建议。

（无）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | treemap 布局的子树值被重复求和，深树 / 多子节点时呈 O(k²·subtree) 量级：`sortChildren` 用插入排序并每次比较都调 `nodeValue`（递归整棵子树），`layoutNode` 又对每个子节点再算一次 | `f_chart/src/TreemapChart.cj:174-189`、`:221-231` | 不同节点数（100 / 1k / 10k）与不同分支因子下的绘制耗时占比 | `cjpm bench -O2` 对同一 `nodes` 输入计时，再 `cjprof record` 看 `nodeValue` self time 占比；先做「预计算 value 缓存 + O(k log k) 排序」的前后对照 |
| 2 | 深链形态的 treemap 输入（每层单子节点、深度 = 节点数）会让递归 `nodeValue` / `layoutNode` 深度达到节点数量级，可能触发栈溢出 | `f_chart/doc/spec/add-f-chart-treemap/design.md:7`、`:12`；`f_chart/src/TreemapChart.cj:159-172`、`:191-244` | 实际崩溃深度阈值（与默认线程栈大小相关），以及业务侧允许的最大层级 | 构造 1k / 5k / 10k 层链式 `nodes` 调 `draw`，记录首次抛 `StackOverflowError` 的深度；按官方文档核对默认栈大小后给出安全上界，超限改为显式栈迭代 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-survival/specs/chart-rendering/spec.md` | .md | ✅ | 公式与 4 个 class 名与实现一致；n 口径存疑（#3）、空数组未覆盖（#9） |
| 2 | `f_chart/doc/spec/add-f-chart-survival/tasks.md` | .md | ✅ | 4 条任务全勾选，`survivalConfidence` 与测试文件均存在，与勾选状态自洽 |
| 3 | `f_chart/doc/spec/add-f-chart-swarm/design.md` | .md | ✅ | `swarmOffsets` 锯齿+归一化、点半径 3、5% 余量与实现一致；「与 ViolinChart 一致」成立（两者都限 1 系列） |
| 4 | `f_chart/doc/spec/add-f-chart-swarm/proposal.md` | .md | ✅ | `series[].data` 的复数写法与实现单系列限制冲突（#4） |
| 5 | `f_chart/doc/spec/add-f-chart-swarm/specs/chart-rendering/spec.md` | .md | ✅ | 抖动方向/绝对值上界/数据形状/校验均与实现一致；缺系列数量约束（#4） |
| 6 | `f_chart/doc/spec/add-f-chart-swarm/tasks.md` | .md | ✅ | 与 `swarmOffsets`、`SwarmChart_test.cj` 的存在自洽 |
| 7 | `f_chart/doc/spec/add-f-chart-swimlane/design.md` | .md | ✅ | 节点 120×40、三色交替、正交路径与实现一致；预留宽度单双侧不符（#6） |
| 8 | `f_chart/doc/spec/add-f-chart-swimlane/proposal.md` | .md | ✅ | class 清单漏 `swimlane-divider` / `swimlane-arrow`（#7） |
| 9 | `f_chart/doc/spec/add-f-chart-swimlane/specs/chart-rendering/spec.md` | .md | ✅ | 泳道/节点/连线计数与校验场景逐条可在实现中定位，自洽 |
| 10 | `f_chart/doc/spec/add-f-chart-swimlane/tasks.md` | .md | ✅ | 与 `SwimlaneChart.cj` / `_test.cj` 的存在自洽 |
| 11 | `f_chart/doc/spec/add-f-chart-tag-cloud/design.md` | .md | ✅ | 别名决策（读 `type` 后按同名期望类型传入）与 `WordCloudChart.cj:42` 一致；无 `# Design` 一级标题（格式，未计入统计） |
| 12 | `f_chart/doc/spec/add-f-chart-tag-cloud/proposal.md` | .md | ✅ | 与 design 结论一致，未新增源文件（仅 `TagCloud_test.cj`），与仓内现状相符 |
| 13 | `f_chart/doc/spec/add-f-chart-tag-cloud/specs/chart-rendering/spec.md` | .md | ✅ | 别名与默认字号 12/64 成立；3 个场景复述词云规则（#11） |
| 14 | `f_chart/doc/spec/add-f-chart-tag-cloud/tasks.md` | .md | ✅ | 4.2 的「README 里程碑表」已落实（`README.md:172` 有 M104 行） |
| 15 | `f_chart/doc/spec/add-f-chart-timeline/design.md` | .md | ✅ | 交替上下、垂直轴 `x+72`、group 散列取色与实现一致；边距 40 vs 48（#8） |
| 16 | `f_chart/doc/spec/add-f-chart-timeline/proposal.md` | .md | ✅ | 5 个 class 名与 `TimelineChart.cj` 逐一对上 |
| 17 | `f_chart/doc/spec/add-f-chart-timeline/specs/chart-rendering/spec.md` | .md | ✅ | 事件/文本/方向/校验四组场景均可在实现中定位，自洽 |
| 18 | `f_chart/doc/spec/add-f-chart-timeline/tasks.md` | .md | ✅ | 与 `TimelineChart.cj` / `_test.cj` 的存在自洽 |
| 19 | `f_chart/doc/spec/add-f-chart-treemap/design.md` | .md | ✅ | 树构建/切分/颜色/标签四处均有漂移：叶子 value（#1）、squarify 命名（#2）、不可达节点（#5）、颜色轮转（#12） |
| 20 | `f_chart/doc/spec/add-f-chart-treemap/proposal.md` | .md | ✅ | 「叶子必须有 value」「squarify」「treemapWeights 便于单测」三处承诺分别对应 #1 / #2 / #10 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

> 范围外提示（不计入本部分统计）：
> 1. `f_chart/src/TreemapChart.cj:233`、`:238` 切轴后仍乘父容器**全额** `width` / `height`，而非剩余宽高；3 个子节点比例 0.5/0.3/0.2 时只填满父矩形 75%，与 design「按比例切分」不符——属第 35 部分（`TreemapChart.cj`）范围。
> 2. `f_chart/src/TreemapChart.cj:46` 的 `private var leafIndex` 为可变实例状态，`public class` 若被并发复用会串色，`draw` 内重置（`:141`）只保证单线程正确——同上属第 35 部分。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 「正确性」落在 #1（叶子 value 缺失静默 0 面积）、#5（不可达节点静默丢弃）；安全性无外部输入拼接、无凭据，文档不涉及。语言特性 / 可读性在纯文档上不适用 |
| §1 死代码 | 0 | 文档无声明可判死代码。反向做了「文档点名符号是否真实存在」核对：`survivalConfidence`（有调用）、`swarmOffsets`（`SwarmChart.cj:167` 及 BoxScatter/Raincloud 复用）、`treemapWeights`（存在但仅测试引用，见 #10）、`findSwimLane`（1 处调用）/ `findSwimNode`（4 处调用）、`TimelineEvent` / `eventColor`（`TimelineChart.cj:116` 调用）均有实体 |
| §2 重复逻辑 | 2 | #10（`treemapWeights` 与 `layoutNode` 内 `nodeValue/total` 两处同语义换算）、#11（tag-cloud spec 复述词云 spec 的规则）。另两两比对了同目录 6 组四件套的措辞，其余为各图表自身规则，无同语义重复 |
| §3 空实现 | 0 | 逐一核对了 6 份 spec 列出的输出 class 与校验分支，均在实现中找到对应语句；未发现「文档承诺、实现为空」的入口（treemap 叶子 value 属校验缺失，已计 #1，未重复计入本行） |
| §4 栈溢出 | 0 | 文档层无递归描述可判；treemap design 的递归求值/递归布局深度上界 = 节点数（用户可控），无实测数据，按铁律列入待验证假设 #2 |
| §5 OOM | 0 | 本部分 20 个文档未涉及全量物化、按不可信长度预分配或无界容器；6 张图的输入规模由 JSON 数组长度决定，文档未承诺流式处理，无「拒绝路径缺失」的承诺落差 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，不构成热点结论；`nodeValue` 重复求和的线索已写入待验证假设 #1（含采集方法与对照方案） |
| §6.2 大粒度锁 | 0 | 文档不涉及锁；6 张图的实现均为纯函数式绘制，无临界区描述 |
| §6.3 并发串行 | 0 | 文档无 spawn / 批量 / 单消费者描述 |
| §6.4 低效算法 | 0 | 文档未规定复杂度；treemap 的插入排序 + 重复子树求和只作假设 #1，未按缺陷计 |
| §7 降堆内存方案 | 0 | 文档无持有结构描述，无基线可量化，按铁律不给方案 |
| §8 降 CPU 方案 | 0 | 同上；对应线索已在假设 #1 |
| §9 local mode 可行性 | 0 | 本部分无函数体，无「函数内创建、函数内用完」的对象可判；迁移收益须峰值内存对照，无数据 |
| §11 现有代码的 BUG（存量） | 3 | 本轮从文档侧取证到 3 处实现侧问题：#1（缺 value 静默）、#5（不可达节点静默）、#9（空数组错误种类）。其余代码缺陷属第 34/35/36 部分，只留范围外提示 2 条 |
| §12 并发安全与锁粒度 | 0 | 文档无共享状态与同步手段描述；唯一并发线索是 `TreemapChart.leafIndex`（可变实例字段），已作范围外提示 2 交第 35 部分判定 |
| §13 文档一致性 | 7 | #2、#3、#6、#8、#12 为参数/算法/颜色口径不符；#1、#9 为校验口径不符；已按 §13 要求给出「文档行号 + 代码行号」双位置 |
| §14 功能完备性与 README 覆盖 | 2 | #4（能力边界未文档化）、#7（输出 class 未登记）。本部分不含 `README.md`，README / public API 覆盖核对属第 36 部分及其它部分，本部分只做 spec 内部完备性 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 个文件是 6 个已归档变更的四件套，整体质量在文档侧属于「结构完整、可核对」：每个 requirement 都带 Scenario，class 名、默认值、校验分支基本能在实现里逐一落位，tag-cloud 这种「别名不新增类」的决策也执行得很干净，survival 的置信区间数字（0.402 / 0.598）与实现公式完全对得上。

主要风险集中在 **treemap** 一份三件套上，而且是三种不同性质的问题：(1) 承诺「叶子必须有 value」但实现按 0 静默处理，产出「成功但少块」的图；(2) 把 slice-and-dice 挂上了 `squarify` 的名字，proposal 与 design 自相矛盾，下游按名字预期长宽比会落空；(3) 校验清单漏掉「节点不在根之下」，环上的子树被无声吞掉。这三条都不会抛异常，排查成本高于崩溃类缺陷，建议排在前面处理（其中 (2) 涉及对外 `tiling` 取值，需先确认下游是否依赖）。

swarm 的「仅支持 1 个系列」是典型的「实现比文档更严」，改文档即可收敛；survival 的 `n` 口径（点数 vs 样本量）需要作者拍板，属于统计语义问题而非笔误。swimlane 与 timeline 的两处边距漂移、treemap 的颜色轮转描述属于轻微的文档-实现不同步，可以按批随下次改文档一起修。

本部分无性能类缺陷：没有基线就不写热点、不给改造建议，仅把 treemap 的重复子树求和与深链递归列为待验证假设，供第 35 部分实测。存量 12 条（一般 5 / 轻微 7）默认只报不修，是否纳入修复待用户决定。
