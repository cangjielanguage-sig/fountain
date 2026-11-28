# f_chart 模块审查报告（第 24/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/doc/spec/`（本部分 20 个 `.md`、0 个 `.cj`：volcano / waffle / waterfall / waterfall-alias / word-cloud / word-network 六个归档变更的规格四件套）
- **基线**：工作区快照，`git diff` 为空；HEAD `f309f0b55`（dispatch 记 `120fd2542`，其上另有 review 过程文件提交）。本部分文档行 blame 全部落在 2026-11-08 / 11-09 的 `c532fcc444`、`ad72309e44`、`18e02a32a1` 等提交 ⇒ 所有问题来源均为**存量**
- **审查重点**：f_chart 专项（渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑）。本部分只有归档规格文档，落点为 §13 文档一致性 / §14 完备性，另以 `f_chart/src` 的对应实现与测试作为「文档验收口径是否被满足」的取证对象；归档变更按「当时结论是否自洽」核对，不因与当前实现不同而自动判错
- **报告版本**：v1（分部分，由主 Agent 合并进 `docs/review/2026-11-28/f_chart_v2.md`）

## 发现

### [一般][存量] 瀑布图 `xAxis.labels` 必须与数据等长，设计文档却把它描述成"按索引取值、取不到就回退"

- **位置**：`f_chart/doc/spec/add-f-chart-waterfall/design.md:5`（`仅接受一个系列。每项解析 name（缺省用 xAxis.labels[i]）、value、type…`）；验收口径处 `f_chart/doc/spec/add-f-chart-waterfall/specs/chart-rendering/spec.md:28-49`（「瀑布图轴范围与校验」「瀑布图类型校验」两节均无 `xAxis.labels` 条目）
- **来源**：存量（`git blame -L 3,6` → `c532fcc444` 2026-11-08）
- **判据**：review-checklist §13「规格与实现漂移：`doc/spec/**` 的验收口径与当前实现不一致」+ §14.1「承诺了但没实现 / 半成品」的反向（实现了但没承诺）
- **证据**：静态确定 —— 实现 `f_chart/src/WaterfallChart.cj:71-77` 在 `labels` 非空且 `labels.size != items.size` 时 `throw chartInvalidValue("xAxis.labels", "标签长度 … 与数据长度 … 不一致")`；而 `WaterfallChart.cj:106-110` 又保留了 `index < labels.size` 的回退分支，正是设计文档描述的那种宽松语义
- **描述**：设计文档的措辞（"缺省用 `xAxis.labels[i]`"）暗示 `labels` 是可选的前缀数组，缺位处回退为序号；实现却先做等长强校验，只要长度不等就直接失败。按文档只给 3 个 label 配 5 个数据项的使用者会拿到 `InvalidValue`。同时该实现里的回退分支只有在 `labels` 完全为空时才可达，属于文档与实现各说一套。规格（spec.md）与 README 的 M16 章节（`f_chart/README.md:721-748`）都没有这条约束，缺陷只暴露在运行期
- **建议**：二选一并写入 spec 的校验需求——(a) 保留强校验，在 spec「瀑布图轴范围与校验」增加一条「`xAxis.labels` 非空时长度 MUST 等于 `data` 长度，否则 `InvalidValue`」；(b) 改成文档描述的前缀语义，删掉 `WaterfallChart.cj:72-77` 的等长检查。二者都要同步 README

### [一般][存量] 词云设计声称靠"绘图区裁剪"缓解越界，渲染实现没有任何裁剪

- **位置**：`f_chart/doc/spec/add-f-chart-word-cloud/design.md:30`（`估算宽度与真实字体宽度存在偏差，长词可能轻微越界；通过货架换行与绘图区裁剪缓解。`）
- **来源**：存量（`git blame -L 28,32` → `18e02a32a1` 2026-11-09）
- **判据**：review-checklist §13「文档承诺与实现相反」+ §11「语义与注释 / 文档不符」
- **证据**：静态确定 —— `f_chart/src/WordCloudChart.cj` 全文 grep `clip` 零命中，`draw` 里没有 `clipPath` / `clip-rect`；换行判断在 `WordCloudChart.cj:143` 写作 `if (cursorX > frame.plot.x && cursorX + boxWidth > frame.plot.right())`，行首位置时 `cursorX == frame.plot.x`，条件恒假，单个超宽词直接越过 `plot.right()` 继续绘制（`156-172`），旋转词更甚（`boxWidth = fontSize`、`boxHeight = chartTextWidth(...)`，`133-142`）
- **描述**：文档的"缓解"由货架换行 + 绘图区裁剪两条组成，第二条在实现中不存在。后果是：一个词宽超过绘图区宽度时必定溢出 `viewBox`，且会连带把同行后续词推出画布；词云这类"用户给的词长度不可控"的图表，这是稳定可复现的视觉缺陷，不是概率问题
- **建议**：要么在 spec/design 明确"超宽词缩字号或直接跳过"并在 `WordCloudChart.cj:143` 之前加宽度上界判断，要么真的加 `<clipPath>` 裁剪；同时修正 design.md:30 的措辞，避免文档承诺不存在的机制

### [一般][存量] 词网络规格用"规模通常较小"代替数量上界，force 布局是无上界的 80 轮 O(n²) + 每轮 O(m·n) 线性查找

- **位置**：`f_chart/doc/spec/add-f-chart-word-network/design.md:30`（`力导向迭代在节点较多时计算量为 O(80n²)，与 M62 一致；词网络规模通常较小。`）；`design.md:9-11`（数据模型三条规定只约束非空、唯一、正数，无条数上限）
- **来源**：存量（blame 同属 2026-11-09 归档提交）
- **判据**：review-checklist §5「OOM / 无界容器」、§6.4「低效算法（热点里反复线性 `contains`）」；`perf §3.1`
- **证据**：静态确定（复杂度面）—— `f_chart/src/WordNetworkChart.cj:199-234` 每轮 `for (left in 0..n) for (right in left+1..n)`，共 80 轮；同一轮内 `214-216` 对每条连线调用两次 `findWordNode`（`171-178` 线性扫描），绘制阶段 `143-145` 再对每条连线调用两次，故单次 `draw` 为 `80·(n²/2 + m·n) + 2m` 次字符串比较。延迟与峰值内存的影响**需实测**（见待验证假设 #1）
- **描述**：规格仅以"通常较小"作口头约束，既没有 `nodes` / `links` 条数上限，也没有拒绝路径。n=2000、m=2000 时仅斥力一项就是约 1.6 亿次距离计算（不含查找），耗时与输出时长完全由调用方输入决定；这与同模块其他图表"数据项数只影响输出长度"的性质不同，属于二次增长
- **建议**：在 spec 的校验需求里给出上限（如 `nodes` ≤ 500、`links` ≤ 2000，超出抛 `InvalidValue`），并把 design.md:30 的"通常较小"改成可验收的常量；实现侧把 `findWordNode` 换成 `HashMap<String, Int64>` 一次性建索引（见优化方案 [CPU]）

### [一般][存量] `WordNetworkChart.runWordForce` 与 `NodeLinkChart.runForce` 是逐行复制的同一算法，复制时把 `charge` 参数化丢了

- **位置**：`f_chart/doc/spec/add-f-chart-word-network/design.md:3`（`同时复用已沉淀的力导向迭代思路与 nodeLinkWidth`）、`design.md:20`（`与 M62 相同的确定性参数`）；实现 `f_chart/src/WordNetworkChart.cj:191-235` 对 `f_chart/src/NodeLinkChart.cj:218-263`
- **来源**：存量（`WordNetworkChart.cj` 与 `NodeLinkChart.cj` 均早于本轮快照；blame 显示各自在 11 月归档提交中引入）
- **判据**：review-checklist §2「重复逻辑：只改类型名 / 换控制流」——两个函数体逐行对齐，差异仅 `NodeLinkNode`→`WordNetworkNode`、`edges`→`links`、`findNode`→`findWordNode`；「差异是业务要求就不是重复」在这里不成立，因为设计文档自己写的是"相同参数"
- **证据**：静态确定 —— 两处同为 `for (iteration in 0..80)`、`sqrt(dx*dx+dy*dy)+0.01`、`(distance - linkDistance) * 0.05`、回中系数 `0.01`；唯一实质差异是斥力项：M62 写作 `force = charge / (distance * distance)`（`NodeLinkChart.cj:233`，`charge` 来自 `root.number("charge", default: -300.0)`，`NodeLinkChart.cj:72`），词网络写作硬编码 `-300.0 / (distance * distance)`（`WordNetworkChart.cj:205`），且 `WordNetworkChart.draw` 没有读取 `charge`
- **描述**：同一套布局算法存在两份实现，后续调参（迭代轮数、阻尼、回中系数）必须改两处，已经出现第一处漂移：文档说"与 M62 相同的确定性参数"，但 M62 的斥力强度是可配置项，词网络把它写死。使用者按文档预期传 `charge` 会被静默忽略（不报错、不生效），属于契约与实际能力不符
- **建议**：抽成模块内共享函数（如 `runDeterministicForce(points, edges, plot, linkDistance, charge)`，节点坐标通过结构或回调暴露），放在 `f_chart/src` 的 util 层；若暂不抽取，至少给 `WordNetworkChart` 补 `charge` 字段并在 design/spec 写明两者参数一致

### [轻微][存量] 火山图标签"截断到 10 个字符 + 省略号"未写入规格，长标签的验收结果与规格字面不一致

- **位置**：`f_chart/doc/spec/add-f-chart-volcano/specs/chart-rendering/spec.md:42-49`（要求"显著项提供 `label` 时 MUST 输出 … 文本"，场景用 5 字符的 `GENE2`）
- **来源**：存量（`git blame -L 42,49` → `ad72309e44` 2026-11-08）
- **判据**：review-checklist §13「验收口径与实现不一致」+ §11「语义与命名 / 注释不符」
- **证据**：静态确定 —— `f_chart/src/VolcanoChart.cj:212-219` 先调 `volcanoLabelText(point.label, 10)`（`237-248`：超过 10 个 rune 时返回前 10 个字符 + `…`），再写 `volcano-label` 文本；规格与 README M92 章节（`f_chart/README.md:2051-2060`）都没有截断约定
- **描述**：`label` 为 `BRCA1-AS1-LONG` 这类基因名（>10 字符）时，SVG 里出现的是截断文本。规格场景恰好只用了 5 字符标签，所以单测通过、文档也没暴露这个行为；使用者按规格断言"SVG 包含 label"会失败
- **建议**：在「火山图标签」需求里补一句"`label` 超过 10 个字符时 MUST 截断并以 `…` 结尾"，并加一条 >10 字符的验收场景；若截断并非本意，则去掉 `volcanoLabelText` 的 limit

### [轻微][存量] 华夫图设计说"`series` 数量不为 1 抛 `InvalidValue`"，实现里 `series: []` 抛的是 `MissingField`

- **位置**：`f_chart/doc/spec/add-f-chart-waffle/design.md:20`（`series 数量不为 1、data 为空、value 为负或总和为 0 抛 InvalidValue`）；对照 `f_chart/doc/spec/add-f-chart-waffle/specs/chart-rendering/spec.md:42-54`（「华夫图校验」未区分"缺失"与"数量不对"）
- **来源**：存量（blame → 2026-11-08/09 归档提交）
- **判据**：review-checklist §13「API / 错误码与源码不符」+ §11「契约与实现不符」
- **证据**：静态确定 —— `f_chart/src/WaffleChart.cj:54-56`：`if (seriesItems.isEmpty()) throw chartMissingField("series")`；`57-59` 才在 `size != 1` 时抛 `InvalidValue`。同一形状在 `WaterfallChart.cj:53-58` 与 `VolcanoChart.cj:57-62` 重复出现，只有瀑布图的 spec 显式写了"`series` 缺失 MUST 抛 `MissingField`"（`add-f-chart-waterfall/specs/chart-rendering/spec.md:44`）
- **描述**：空数组在语义上既不是"缺失"也不是"数量不为 1"，实现统一归到 `MissingField`。按 design 只处理 `InvalidValue` 的调用方会漏掉这一支；三张图的错误 kind 口径也因此不一致（瀑布图文档化了、华夫图没文档化、火山图两者都没写）
- **建议**：在 spec 里统一把"字段缺失 / 空数组 / 数量不为 1"三种情形的 `kind` 写清楚（建议保留实现现状：缺失与空数组 → `MissingField`，数量 >1 → `InvalidValue`），并据此修正 `add-f-chart-waffle/design.md:20` 的措辞

### [轻微][存量] 瀑布图柱宽 8px 下限与 y 轴单侧留白，与设计的"`bandWidth * 0.55`""留 5% 余量"不符

- **位置**：`f_chart/doc/spec/add-f-chart-waterfall/design.md:16`（`柱宽 bandWidth * 0.55`）、`design.md:23`（`y 范围覆盖 0 与所有 start/end，留 5% 余量`）
- **来源**：存量（`git blame -L 3,6` → `c532fcc444` 2026-11-08；实现同批提交）
- **判据**：review-checklist §13「文档与实现不一致」；渲染正确性：柱宽超过 band 会互相重叠
- **证据**：静态确定 —— `f_chart/src/WaterfallChart.cj:179` 为 `maxFloat(band.bandWidth * 0.55, 8.0)`；`218-242` 的 `resolveYRange` 只在 `dataMin < 0` / `dataMax > 0` 时才乘 1.05，贴 0 的一侧余量为 0
- **描述**：`bandWidth = plotWidth / n`，绘图区宽 700px 时 n ≳48 起 `0.55·bandWidth < 8`，柱宽被抬到 8px 而 band 只有 <14.5px，柱与柱开始重叠、连接器落点也随之错位；文档没有这个下限。y 轴"留 5% 余量"实际只对远离 0 的一侧生效，全正数据的柱子顶端以上有留白、底部 0 无留白，与"覆盖 0 … 留 5% 余量"的整体表述有出入
- **建议**：design 补写"柱宽不小于 8px"与"0 侧不留余量"的取舍，或在实现里把下限改成 `minFloat(band.bandWidth * 0.55, band.bandWidth)` 并对超密数据给出提示；y 轴措辞改成"远离 0 的一侧留 5%"

### [轻微][存量] 华夫图 `cells` 只有"正整数"约束，没有上界，实现按 `cells` 线性生成矩形

- **位置**：`f_chart/doc/spec/add-f-chart-waffle/specs/chart-rendering/spec.md:44`（`cells 与 columns MUST 为大于 0 的整数`）、`add-f-chart-waffle/design.md:20`
- **来源**：存量（blame → 2026-11-08/09 归档提交）
- **判据**：review-checklist §5「OOM：按不可信长度生成 / 全量物化」+ §14 完备性（缺限制条件段落）
- **证据**：静态确定（线性关系）—— `f_chart/src/WaffleChart.cj:41-50` 仅校验 `>= 1` 且为整数，`119-138` 循环写 `cells` 个 `<rect>`；`cells` 是根级配置字段，没有上限校验。峰值内存与 SVG 字节数**需实测**（见待验证假设 #2）
- **描述**：`cells: 1000000` 会生成 100 万个 `<rect>` 并整串累积在 `SvgBuilder` 里，SVG 文本量级约数十 MB，且图例、字号计算全部照常执行；规格既然把 `cells` 定为"总格数"这一可配置量，就应给出上界，否则用户只能在 OOM / 浏览器卡死时才发现
- **建议**：spec 增加"`cells` MUST 在 1..4096 之间"（或与 `columns` 的乘积上限），实现里补一条 `InvalidValue` 拒绝路径；同时在 README 的 M73 章节写明上限

## 优化可行性方案

### [CPU] 词网络一次性建立 `id → index` 索引，替换两处线性查找

- **现状**：`WordNetworkChart.cj:171-178` 的 `findWordNode` 对 `ArrayList` 线性扫描；调用点三处——校验 `107`/`110`（每条连线 2 次）、force 迭代内 `215-216`（80 轮 × 每条连线 2 次）、绘制 `144-145`（每条连线 2 次）。n=200、m=400 时约 `80×400×200 ≈ 6.4M` 次字符串比较，占单次 `draw` 的可观比例（未测量）
- **方案**：`draw` 解析完 `nodes` 后建 `HashMap<String, Int64>`（同时天然获得重复 id 检测，`81-85` 的 O(n²) 去重也可一并消掉），`WordNetworkLink` 直接存 source/target 下标
- **预期**：查找从 O(n) 降到 O(1)，迭代阶段的字符串比较从 `80·m·n` 降到 `80·m`；对 n=200/m=400 约减少 600 万次比较（按比较次数估算，非耗时）
- **代价**：多一份 `HashMap`（O(n) 内存），`internal` 类型 `WordNetworkLink` 增加两个字段；输出需保持不变（回归用 `WordNetworkChart_test.cj` + `ChartGallery_test.cj` 的 M103 快照）
- **验证**：`cjpm test --skip-build` 全量回归 + `cjpm bench`/分段计时对同一 JSON（n=50/200/500）取中位数与离散度；再用 `cjprof record` 看 `findWordNode` 自耗时占比是否归零
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 给华夫图 `cells` 设上限并对超密输入提前拒绝

- **现状**：`WaffleChart.cj:119-138` 按 `cells` 输出矩形，`cells` 由根级配置决定且无上限；`cells=100000` 时约 10 万个元素节点 + 对应 SVG 文本，全部在 `SvgBuilder` 内长期持有至 `toSvgString()`
- **方案**：spec 与实现同时加上界（建议 4096，覆盖常见 10×10 / 20×10 场景），超限抛 `InvalidValue`；若确有密排需求，改为按类别输出一个 `path`（同色方格合成一条 path）而不是每格一个 `<rect>`
- **预期**：最坏输入的内存与输出字节数被常数夹住；`cells=4096` 时 `<rect>` 数量从"任意"降到 4096，SVG 体量约百 KB 量级（按每元素 ~60-80 字节估算，需实测）
- **代价**：语义变化——现有调用方若依赖 `cells > 4096` 会被拒；合成 path 会改变 DOM 结构（`waffle-cell` class 计数从 N 变 1），影响下游按 class 计数的人
- **验证**：改前改后对 `cells = 100 / 1000 / 100000` 记录 `getAllocatedHeapSize()`、RSS 与 `svg.length()`，确认线性段被截断
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 词网络 force 布局在 n≥500 时单次 `draw` 进入百毫秒级，且耗时主要来自 O(n²) 斥力与 `findWordNode` | `f_chart/src/WordNetworkChart.cj:199-234` | 单次 `draw` 分段耗时与自耗时占比 | 构造 n=100/500/2000 的确定性 JSON，`cjpm bench -O2` 跑 20 轮取中位数；再用 `cjprof record` 分离 `runWordForce` / `findWordNode` |
| 2 | 华夫图 `cells` 取 1e5 时 SVG 字节数与峰值堆内存线性增长，到 1e6 会触发长 GC 或 OOM | `f_chart/src/WaffleChart.cj:119-138` | `svg.length()`、`getAllocatedHeapSize()`、GC 次数 | 对 `cells=100/1000/10000/100000` 各跑 10 次，记录长度与峰值，拟合线性系数 |
| 3 | 词云货架布局在真实 CJK 字体下，`chartTextWidth`（`rune >= 0x2E80` 记 1em）与浏览器实际宽度偏差导致重叠而非仅仅越界 | `f_chart/src/ChartScale.cj:113-123`、`WordCloudChart.cj:133-147` | 估算宽度 vs 渲染宽度的偏差分布 | 用固定词表生成 SVG，headless 浏览器量 `getBBox()`，对比 `chartTextWidth`，统计最大偏差与重叠次数 |
| 4 | 瀑布图点数 >46 时柱宽被 8px 下限撑开，柱与柱重叠且连接器落点偏离柱边 | `f_chart/src/WaterfallChart.cj:179`、`201-212` | 重叠像素量与视觉可读性阈值 | 生成 n=20/50/100/200 的瀑布图，量 `bandWidth` 与 `barWidth` 比值，并截图核对重叠 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-volcano/specs/chart-rendering/spec.md` | .md | ✅ | 5 条需求逐条对照 `VolcanoChart.cj`，见发现 5；阈值线/颜色/分类一致 |
| 2 | `f_chart/doc/spec/add-f-chart-volcano/tasks.md` | .md | ✅ | 4 项 `[x]` 与 `VolcanoChart_test.cj` 的 7 个用例（点/分类/阈值线/标签/两条拒绝）对得上，无占位 |
| 3 | `f_chart/doc/spec/add-f-chart-waffle/design.md` | .md | ✅ | 取整/布局/图例与实现一致；校验段与实现不符，见发现 6 |
| 4 | `f_chart/doc/spec/add-f-chart-waffle/proposal.md` | .md | ✅ | 声明的 `WaffleChart` / `waffleCellCounts` / class 名全部存在 |
| 5 | `f_chart/doc/spec/add-f-chart-waffle/specs/chart-rendering/spec.md` | .md | ✅ | 100 格/不整除/最大余数 三场景与实现一致；`cells` 无上界，见发现 8 |
| 6 | `f_chart/doc/spec/add-f-chart-waffle/tasks.md` | .md | ✅ | 4 项 `[x]` 与测试对得上 |
| 7 | `f_chart/doc/spec/add-f-chart-waterfall-alias/design.md` | .md | ✅ | 别名关系与 `README.md:726` 一致 |
| 8 | `f_chart/doc/spec/add-f-chart-waterfall-alias/proposal.md` | .md | ✅ | `src/WaterfallAlias_test.cj` 存在且只做回归 |
| 9 | `f_chart/doc/spec/add-f-chart-waterfall-alias/specs/chart-rendering/spec.md` | .md | ✅ | 5 柱 / 4 connector 与 `WaterfallAlias_test.cj:60-79` 断言一致 |
| 10 | `f_chart/doc/spec/add-f-chart-waterfall-alias/tasks.md` | .md | ✅ | 2 项 `[x]`，无遗漏 |
| 11 | `f_chart/doc/spec/add-f-chart-waterfall/design.md` | .md | ✅ | 见发现 1、发现 7（labels 语义、柱宽、y 轴余量） |
| 12 | `f_chart/doc/spec/add-f-chart-waterfall/proposal.md` | .md | ✅ | `waterfallSpan` 存在并被 `draw` 调用 |
| 13 | `f_chart/doc/spec/add-f-chart-waterfall/specs/chart-rendering/spec.md` | .md | ✅ | 累计/连接器/范围/校验与实现一致；错误 kind 口径见发现 6 说明 |
| 14 | `f_chart/doc/spec/add-f-chart-waterfall/tasks.md` | .md | ✅ | 4 项 `[x]` 与 `WaterfallChart_test.cj` 的 10 个用例（柱类型/连接器/标签/累计/范围/3 类拒绝/确定性）对得上 |
| 15 | `f_chart/doc/spec/add-f-chart-word-cloud/design.md` | .md | ✅ | 字号映射/排序/旋转与实现一致；裁剪承诺不成立，见发现 2 |
| 16 | `f_chart/doc/spec/add-f-chart-word-cloud/proposal.md` | .md | ✅ | 别名复用已在 README:2741 + `add-f-chart-tag-cloud` 规格落实，无缺口 |
| 17 | `f_chart/doc/spec/add-f-chart-word-cloud/specs/chart-rendering/spec.md` | .md | ✅ | 8 个场景在 `WordCloudChart_test.cj` 均有对应用例（旋转按 `rotate(90 ` 计数 3 验证） |
| 18 | `f_chart/doc/spec/add-f-chart-word-cloud/tasks.md` | .md | ✅ | 9 项 `[x]`，含 README 里程碑表更新，README:170 已存在 |
| 19 | `f_chart/doc/spec/add-f-chart-word-network/design.md` | .md | ✅ | 半径公式 / circular / 绘制顺序与实现一致；规模无上界见发现 3，重复实现见发现 4；`nodes` / `links` 各条校验在 `WordNetworkChart.cj:67-120` 全部落实 |
| 20 | `f_chart/doc/spec/add-f-chart-word-network/proposal.md` | .md | ✅ | 声明的类与复用的 `nodeLinkWidth` / `flameColorIndex` 均存在 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。本部分不含 volcano 的 `design.md` / `proposal.md` 与 word-network 的 `specs/**` / `tasks.md`（不在 `f_chart.part24.txt` 内，由同模块其他部分覆盖，未在此展开）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 本部分 0 个 `.cj`，无并发、注入、类型语义可审；命中的 6 条是"文档验收口径 vs 实现契约"的偏差（发现 1、5、6、7、8 及发现 4 的参数漂移），已分别落在 §11 / §13 行 |
| §1 死代码 | 0 | 文档侧机械核对：把 20 个 `.md` 引用的符号与路径逐个 grep 回源码——`VolcanoChart`、`WaffleChart`、`waffleCellCounts`、`WaterfallChart`、`waterfallSpan`、`WaterfallAlias_test`、`WordCloudChart`、`wordCloudFontSize`、`WordNetworkChart`、`nodeLinkWidth`（`NodeLinkChart.cj:277`）、`flameColorIndex`（`FlameChart.cj:252`）、`ChartFrame.drawXAxis` / `drawYAxis`、`chartTextWidth`（`ChartScale.cj:113`）全部命中且均有调用者；无引用已删除 API 的条目 |
| §2 重复逻辑 | 1 | 发现 4（`runWordForce` 与 `runForce` 逐行复制）。M16/M87 两份文档的"5 柱 / 4 connector"是同语义，但那是别名回归的业务要求，不是重复；5 份 `tasks.md` 的 TDD 模板也属刻意统一，不判 |
| §3 空实现 | 0 | 逐条核对 5 份 `tasks.md` 的 `[x]`：`cjpm test --no-run` 阶段的 Red 项均有对应测试文件，`WordCloudChart` / `WordNetworkChart` / `WaffleChart` / `WaterfallChart` / `VolcanoChart` 的 `draw` 均非空；20 个文件内 `TODO` / `FIXME` 零命中 |
| §4 栈溢出 | 0 | 文档未描述递归结构；对应实现（`runWordForce`、`waffleCellCounts`、`wordCloudOrder`）都是循环，无自递归与间接递归 |
| §5 OOM | 2 | 发现 3（`nodes` / `links` 无上限 + O(n²)）、发现 8（`cells` 无上限 + 按 cells 线性生成元素） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，未提供基线；发现 3 只写复杂度、延迟结论进待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关描述，对应实现为纯函数 `draw`，无临界区 |
| §6.3 并发串行 | 0 | 同上，无 `spawn` / `Future` / 单消费者队列 |
| §6.4 低效算法 | 1 | 发现 3：`findWordNode` 在 80 轮迭代内对每条连线做两次线性查找；`waffleCellCounts` 的最大余数循环是 O(cells·k)，但 k 为类别数、cells 通常 ≤100，未判 |
| §7 降堆内存方案 | 1 | 方案「华夫图 `cells` 设上限」（无基线，待验证） |
| §8 降 CPU 方案 | 1 | 方案「词网络 `id → index` 索引」（无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分无 `.cj`；`f_chart` 未在 `cjpm.toml` 开启 `--enable-local-mode`，且无峰值内存对照数据，方案不成立 |
| §11 现有代码的 BUG（存量） | 5 | 发现 1（labels 强校验与文档回退语义冲突）、3（无界输入）、5（标签截断）、6（错误 kind）、7（柱宽/余量与设计不符）；`waffleCellCounts` 的取整、`waterfallSpan` 的累计、`volcanoCategory` 的三分支、`wordCloudFontSize` 的除零保护均已逐行核对，无逻辑错误 |
| §12 并发安全与锁粒度 | 0 | 文档无并发承诺，实现侧 `Chart.draw` 每次调用新建局部的 `SvgBuilder` / `ArrayList`，无跨调用共享可变状态 |
| §13 文档与代码一致性 | 8 | 全部 8 条发现都属本节；另核对：`chartTextWidth` 的 CJK 1em / 其他 0.56em 与 `ChartScale.cj:113-123` 的 `>= 0x2E80` 判据一致；`rotate(90 x y)` 与 `ChartSvgKit.cj:114-119` 一致；路径与文件名引用（`src/*.cj`、`f_chart/README.md`）全部存在，无死链 |
| §14 功能完备性与 README 覆盖 | 0 | 5 个能力在 README 里程碑表（140/154/159/170/171 行）与章节（473/721/2051/2736/2763 行）均有条目，两个别名在 726 / 2741 行有记录；无"承诺但未实现"；缺口是发现 1 的验收条目，已计入 §13，不重复计 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 行全部逐字读完，无缺行 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分 20 个文件全部是 `doc/spec/` 下的归档变更规格（volcano / waffle / waterfall / waterfall-alias / word-cloud / word-network 六套），四件套结构完整，proposal 声明的类型、class 名、内部函数与测试文件都能在 `f_chart/src` 找到对应，`tasks.md` 的勾选也与测试用例对得上——没有"承诺了但没落地"的空壳条目，`doc/spec` 与 README 里程碑表也没有版本口径冲突。

主要风险集中在**验收口径的细节缺失**，而不是规格写错：`xAxis.labels` 的等长强校验（发现 1）、`label` 10 字符截断（发现 5）、`series` 为空时的 `MissingField`（发现 6）都是"实现有行为、规格没条文"，使用者按文档写会撞到未记载的拒绝或截断。这类偏差单看代码不像 bug、单看文档也读不出，是本模块最容易在升级时变成兼容性问题的地方，建议排期补齐 spec 条文（不涉及行为变更的，只改文档）。

四条 [一般] 里，实质缺陷是词云的"裁剪"承诺不存在（发现 2）与词网络的规模无上界（发现 3），后者还叠加了 `runWordForce` 与 `runForce` 的整段复制（发现 4）——复制时丢掉 `charge` 参数化已经造成首个行为漂移，后续调参必然继续分叉。词网络与词云都属于"用户给的词量/词长不可控"的图表，这两条建议优先处理。

无严重项，无阻塞项。存量 8 条，是否纳入修复待用户决定（其中发现 1、2、6 只改文档即可闭合，发现 3、4、8 涉及代码）。性能类结论（词网络延迟、华夫图内存、词云估算偏差、瀑布柱重叠）均无基线，只写在待验证假设里，不进 `tasks.md`。
