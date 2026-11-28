# f_chart 模块审查报告

> **模块第 15/37 部分**（本报告只覆盖 `files/f_chart.part15.txt` 列出的 20 个文件：`doc/spec/` 下 6 个变更 —— `add-f-chart-network-heatmap` 后半 2 份（spec / tasks）、`add-f-chart-node-link` 4 份、`add-f-chart-nomogram` 4 份、`add-f-chart-offline-flame` 4 份、`add-f-chart-org` 4 份、`add-f-chart-paired-line` 2 份（design / proposal）。本部分 **0 个 `.cj`**；为把文档条款落到行号，取证时另读了 `src/{NetworkHeatmapChart,NodeLinkChart,NomogramChart,OfflineFlameChart,OrgChart,PairedLineChart,FlameChart,ChartFrame,ChartConfig,ChartTheme,ChartScale,ChartJson,BulletChart}.cj` 与对应 `*_test.cj` 的片段，这些 `.cj` 归属 `src/**` 子轮，只作证据引用、不占本部分文件覆盖统计。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分文件全是归档 OpenSpec 变更文档，按 checklist §13 的归档豁免（`doc/spec/<已归档变更>/` 只要求"当时结论是否自洽"）执行，并把每条 Requirement / Scenario / Design 条款落到实现行：节点-链接三布局与力导向参数、列线图行高规格化、离线火焰子树与深度截断、组织图槽位/居中/连线几何、配对连线坐标与纵轴范围。**豁免不覆盖本部分的"规格 vs 实现"偏差**：6 个变更的 spec / design 与对应 `src/*.cj` 同属一个提交且此后未再改动（`git log -1`：`804b8c1db` node-link、`1b697d0a0` nomogram、`ad6deecda` offline-flame、`a0dad8a1c` org、`1ea3e056b` network-heatmap、`d95aa1957` paired-line），所以偏差是同一变更内的缺陷，不是"旧文档过期"。
- **报告版本**：v1（第 15/37 部分）

## 发现

### [一般][存量] #1 两张树图的「环检测」契约不成立：组织图完全没有检测，离线火焰图的检测守卫不可达，脱离根的环节点被静默错位/丢弃

- **位置**：
  - `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md:39`（`parent` 指向存在的节点且**不存在环** MUST）、`f_chart/doc/spec/add-f-chart-org/design.md:5`（"从根做深度遍历检测环并计算 `depth`"）
  - `f_chart/doc/spec/add-f-chart-offline-flame/design.md:5`（"校验唯一根、父值不小于子值之和、**检测环**"）
  - 对照实现：`f_chart/src/OrgChart.cj:108-122`（只校验 `roots.size == 1`）、`:218-223`（`orgAssignDepth` 无深度上限、无访问集合）、`:136-139`（对 `nodeArrayValue` 全量按 `depth`/`slot` 平移）；`f_chart/src/OfflineFlameChart.cj:176-200`（`validateValues` / `assignDepth` 的环守卫是 `depth > total`）、`:151`、`:163`、`:217-248`（只从 `selected` 子树布局与绘制）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「缺少边界校验」、§1「恒假分支/不可达守卫」、§13「规格与实现漂移」
- **证据**：静态确定 —— 两个图都按"每个节点最多一个 `parent`"挂接，再从唯一根向下走：任何环都必然与根不连通，遍历永远到不了。因此 `OfflineFlameChart.cj:177` 的 `depth > total`（`total = parsed.size`）**恒不成立**，是不可达守卫；`OrgChart.cj` 连这个守卫都没有。`OrgChart_test.cj:199-209` 的 `rejectsCycle` 用的是"2 个节点互指、没有根"，命中 `roots.size != 1` 这条前置校验（`OrgChart.cj:120-122`）后抛 `InvalidValue`，**环检测从未被这条用例执行到**，所以测试全绿掩盖了缺口；`OfflineFlameChart_test.cj` 无环用例。
- **描述**：`{ "id": "r", "parent": null }` + `{ "id": "a", "parent": "b" }` + `{ "id": "b", "parent": "a" }` 这种输入满足 spec 的全部校验条款（`nodes` 非空、id 唯一、`parent` 存在、恰好一个根），但组织图会把 a/b 画在 `depth = 0`、`slot = 0.0` 的坐标上（`OrgChart.cj:136-139` 对未参与布局的节点也赋坐标），即根所在行最左侧、没有任何连线、根为独子时与根完全重合；离线火焰图更彻底，a/b 不属于 `selected` 子树，`drawNode` 根本不会访问（`:163`），5 个节点的输入只输出 3 个 `offline-flame-node`，无异常、无日志。两种后果都是"输入合法、产物静默错"。
- **建议**：把"连通性"写成可判定的条款并实现——遍历后统计 `visited` 数量，`visited != nodes.size` 即抛 `chartInvalidValue("nodes", "存在与根不连通的节点（可能构成环）")`；`OfflineFlameChart.cj:176-200` 的 `depth > total` 守卫改成等价的 `visited` 判定或删除（保留就是恒假分支）。测试补"有根 + 孤立环"与"有根 + 非环不连通子图"两个用例，`OrgChart_test.cj:199-209` 的现有用例保留为"无根"场景并改名，避免继续冒充环检测。

### [一般][存量] #2 节点-链接图 spec 的「`links` MUST 非空」没有实现，空 `links` 静默产出零连线图

- **位置**：`f_chart/doc/spec/add-f-chart-node-link/specs/chart-rendering/spec.md:49`（"`nodes` MUST 非空且 id 唯一；**`links` MUST 非空**"）；对照 `f_chart/src/NodeLinkChart.cj:74-78`（只校验 `nodes` 空）、`:109-135`（`links` 只做逐项校验，无 `isEmpty` 判断）、`:157-165`（`edges` 为空 ⇒ 0 条 `node-link-edge`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.1「只做了一半的分支」、§3（校验条款缺实现）
- **证据**：静态确定 —— `root.requiredArray("links")` 只在字段缺失时抛 `MissingField`（`ChartJson.cj:61-66`、`152-154`），`"links": []` 会走空列表分支；随后 `edges` 为空、`maxValue = 0.0`，绘制循环一次都不进。测试侧只覆盖了 `nodes` 为空（`NodeLinkChart_test.cj:174-187`，且该用例 `links` 也是空，异常来自 `nodes`），其余 `"links": []` 出现处（`:180`、`:204`）都在 `nodes` 为空或 `type` 不匹配的用例里，断言的不是 `links`。
- **描述**：`{"nodes":[{"id":"a"}],"links":[]}` 这类输入按 spec 应抛 `ChartException`，实际返回一张只有孤立节点、无任何连线的图。规格与实现各说一套，按 spec 写的验收用例会失败、按实现写的会通过；下游如果依赖"links 非空"做布局假设（例如力导向的有效性）则会拿到一张无意义的图。
- **建议**：二选一并同步两边。要拒绝就在 `:110` 之后加 `if (linkItems.isEmpty()) { throw chartInvalidValue("links", "至少需要一条链接") }` 并补用例（`nodes` 非空 + `links` 空）；若产品上确实需要"只有节点的图"，把 `spec.md:49` 改成"`links` MUST 存在，允许为空数组"，并在 design 里说明此时力导向退化为环形布局。

### [一般][存量] #3 列线图的核心能力（变量取值→分值→总分→风险）没有实现，`points` 解析后被丢弃

- **位置**：`f_chart/doc/spec/add-f-chart-nomogram/proposal.md:5`（"把多个预测变量的取值折算为分值，再通过总分刻度映射到事件风险，让……从变量读数得到风险估计"）、`:11`（`variables` 为 `[{name, range, points}]`）；`f_chart/doc/spec/add-f-chart-nomogram/design.md:12`（"`points` 保留在解析结果中，用于后续扩展；当前不额外绘制刻度"）；对照 `f_chart/src/NomogramChart.cj:71-75`（`points` 只校验递增，未传入 `NomogramVariable`）、`:23-33`（`NomogramVariable` 只有 `name`/`rangeMin`/`rangeMax`）、`:137-158`（变量行只画整条水平线 + 两端 `range` 标注）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现」「半成品」、§13「规格与实现漂移」、§1「读了不用」（解析结果被丢弃）
- **证据**：静态确定 —— 全仓检索 `points` 在 `NomogramChart.cj` 里只有 `:71-74` 的解析与递增校验，之后无任何读取；`NomogramVariable` 的字段列表（`:23-33`）不含 `points`，因此 design 所说"保留在解析结果中"与实际不符。`spec.md:7` 只要求"为每个变量绘制一条刻度尺，并在两端标注 `range` 的最小/最大值"——规格本身把 `points` 刻度裁掉了，所以实现与 spec 一致、与 proposal 承诺不一致。
- **描述**：列线图之所以能把"变量读数"变成"风险估计"，靠的是每个变量自己的 `points` 标尺（例如年龄 40→62 分、血压 120→45 分），再把各变量得分相加落到总分/风险行。当前产物只有一排"range 起止值"的水平线，读图者无法得到任何分值，`risk` 刻度的横坐标也只依赖 `totalPoints`，与变量无关。这是一处被 design 明确写成"后续扩展"的半成品，属于"承诺了但没实现"，而不是可接受的裁剪（proposal 的 Why 段就是这条能力的唯一理由）。
- **建议**：要么把 `points` 落到实处——`NomogramVariable` 增加 `pointsMin/pointsMax` 字段，变量行按 `nomogramPosition(value, range[0], range[1])` 画刻度并在上方标 `points` 端点值（`nomogramPosition` 已有、可直接复用，`NomogramChart.cj:242-254`），同时补 spec Requirement；要么从 `proposal.md:5` 删掉"折算为分值/得到风险估计"的表述，把 change 描述改为"变量区间刻度尺 + 风险点位示意"，并在 design 记明"变量→分值映射未实现"。两者都要求同步改 `design.md:12` 的"保留在解析结果中"——现状是这句话为假。

### [一般][存量] #4 组织图 design 声称"布局整体在 plot 内居中"，实现只有平移没有缩放/裁剪，6 个叶子或 6 层即把节点移出画布

- **位置**：`f_chart/doc/spec/add-f-chart-org/design.md:13`（"`gapX` / `gapY` 取 `levelGap * 0.5`，布局整体在 plot 内居中"）、`:10-12`（槽位与坐标公式）；对照 `f_chart/src/OrgChart.cj:128-139`（`maxX`/`maxY` 只取正向最大、`dx = plot.x + (plot.width - maxX)/2`、`dy` 同构）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」「语义与注释不符」、§13「规格与实现漂移」
- **证据**：静态确定（几何推导）—— 默认 `width=800 / height=480`、`padding=24`（`ChartConfig.cj:22-25`、`:167-168`），`ChartFrame(config,false,0,0)` 得到 plot = (24, 24, 752, 432)（`ChartFrame.cj:85-91`）。默认 `nodeWidth=140 / nodeHeight=48 / levelGap=80`（`OrgChart.cj:61-63`）：
  - `vertical` 6 个叶子：`maxX = 5*(140+40)+140 = 1040 > 752` ⇒ `dx = 24 + (752-1040)/2 = -120`，最左节点 x 从 0 挪到 −120，整列落到 viewBox 左侧之外；
  - `vertical` 6 层（depth 5）：`maxY = 5*(48+80)+48 = 688 > 432` ⇒ `dy = 24 + (432-688)/2 = -104`，根节点 rect 的 y 为 −104，完全在 viewBox 上界之外（SVG 根视口默认裁剪，见 `SvgBuilder` 输出的 `<svg width height viewBox="0 0 800 480">`）；
  - `horizontal` 同构：depth 5 时 `maxX = 5*220+140 = 1240 > 752` ⇒ `dx = -220`。
  现有测试的样例特意放大到 900×560（`OrgChart_test.cj:43-48`）且只有 3 个叶子，正好落在可容纳区间内，因此没有任何用例碰到越界。
- **描述**：居中只对"比绘图区小"的布局等价于在 plot 内摆放；一旦布局大于 plot，`dx`/`dy` 变负，节点被推到标题区或画布外，且没有缩放、没有裁剪路径、没有警告。汇报关系图最常见的就是"部门多、层级深"，默认参数下 6 个叶子就触发，所以这不是极端输入。design 的"整体在 plot 内居中"这句话在实现里并不成立。
- **建议**：design 补一条明确取舍并落到实现："布局超出 plot 时按 `min(1, plot.width/maxX, plot.height/maxY)` 等比缩放（节点尺寸同步缩放或仅缩放间距），或裁剪到 plot 并给出 `org-node` 溢出标记"；同时把 `maxX/maxY` 改为同时取 `max(0, ...)` 与考虑 `nodeWidth` 的最小值，避免负偏移。补两个用例：6 叶子、6 层，断言所有 `org-node` 的 x∈[plot.x, plot.right()]、y∈[plot.y, plot.bottom()]。

### [一般][存量] #5 组织图「父节点居中」有三种口径：spec 写"子节点中心平均值"、design 写"槽区间中点"、实现取"首末子节点中点"，叶子数不均时三者互不相等

- **位置**：`f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md:25`（"父节点中心 MUST 等于其子节点中心的**平均值**"）、`:27-30`（Scenario：两个子节点槽位 0 与 1 ⇒ 父节点槽位 0.5）；`f_chart/doc/spec/add-f-chart-org/design.md:9-10`（"`leafCount(node)`…自上而下分配 `[start, end)` 槽区间；节点的槽位中心为 `(start + end - 1) / 2`"）；对照 `f_chart/src/OrgChart.cj:235-237`（`node.slot = (first + last) / 2.0`，`first`/`last` 是首个/末个子节点的槽位）
- **来源**：存量（快照模式下无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」；§2（同一算法三份口径）
- **证据**：静态确定（几何推导）—— 设某节点两个子节点的子树分别占叶子槽 {0,1}（槽位 `(0+1)/2 = 0.5`）与 {2,3,4}（槽位 `(2+4)/2 = 3`）：
  - 实现 `(first+last)/2 = 1.75`；spec 的"平均值" `(0.5+3)/2 = 1.75` —— 两者相同；
  - design 的区间中点 `(start + end - 1)/2 = (0 + 5 - 1)/2 = 2` —— 与实现差 0.25。
  
  再设三个子节点占 {0,1}/{2}/{3}（槽位 0.5 / 2 / 3）：实现 `(0.5+3)/2 = 1.75`、平均值 `5.5/3 ≈ 1.8333`、区间中点 `(0+4-1)/2 = 1.5` —— **三者互不相等**。spec 的 Scenario 只取"槽位 0 与 1"，此时三种算法同为 0.5，无法区分，因此测试（`OrgChart_test.cj:89-92` 只断言 `root.slot == 0.5`）不能证伪任何一方。
- **描述**：同一个布局不变式被写成三份：spec 要求算术平均、design 要求占位区间中心、实现取首末子节点中点。子树等宽时三者重合（默认的均匀树看不出来），叶子数不均时三者给出三个不同坐标；也就是说无论按哪份文档写验收，都能抓到另外两份的问题——spec 的 MUST 被实现违反（三子节点例），design 的公式也不等于实现（两子节点不均例）。后果是父节点相对其子树跨度的偏移量不确定，连线 `M…V…H…V` 的对称性随之漂移。
- **建议**：统一成一条可实现、视觉稳定的口径，推荐"首末子节点中点"（= 子树跨度中心，父节点不会偏出自己子树）：①`spec.md:25` 改为"父节点槽位 MUST 等于其**首、末子节点槽位的算术中点**"；②Scenario 换成子树叶子数不均的例子（2+3 个叶子 → 父节点槽位 1.75）；③`design.md:9-10` 的 `[start,end)` 与 `(start+end-1)/2` 换成游标 + 首末中点（两者只在子树槽连续且首末对齐时等价，否则差 0.25，见 #10）；④`OrgChart_test.cj` 补一个"2+3 叶子"用例锁死口径。

### [一般][存量] #6 两张树图的递归深度完全由输入决定，文档既没给节点数/深度上限，也没提栈风险

- **位置**：`f_chart/doc/spec/add-f-chart-org/design.md:5`（"从根做深度遍历检测环并计算 `depth`"）；`f_chart/doc/spec/add-f-chart-offline-flame/design.md:5`（深度遍历 + 环检测）、`:15`（"仍递归遍历以计算布局"）；对照 `f_chart/src/OrgChart.cj:218-238`（`orgAssignDepth` / `orgAssignSlots` 双递归）、`f_chart/src/OfflineFlameChart.cj:176-200`、`:202-215`、`:217-248`（`validateValues` / `assignDepth` / `layoutNode` / `drawNode` 四趟递归）。design:9 的 `leafCount` 在实现里并不存在，另记 #10
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归」（深度由输入决定、无深度计数、无迭代改写）、§5「拒绝路径缺失」
- **证据**：需实测 —— 递归层数上界 = 树高（等于 `nodes` 数量，spec 未设上限），这一点静态可定；**具体多少层溢出取决于平台默认栈大小与单帧大小，需要实测**（按铁律不定严重）。同一形状在 `FlameChart.cj:111-112` 已经存在（`validateValues`/`assignDepth`），说明这是模块级共性而非本变更独有。
- **描述**：形如 5000 个节点首尾相接的单链（合法输入，`value` 递减即可）会让四趟递归各压 5000 层，最坏情况是 `StackOverflow`（崩溃），而不是"图慢一点"。文档层面完全没有"`nodes` 数量上限 / 树高上限"的条款，实现照着文档写也不会想到加拒绝路径，故按 §5 的判据这里缺的是"上限写在哪里"。
- **建议**：在 `specs/chart-rendering/spec.md` 的校验条款里加"`nodes` 数量 MUST ≤ N（建议 2000）且树高 MUST ≤ M（建议 64）"，超限抛 `InvalidValue`；实现侧把 `orgAssignDepth` / `orgAssignSlots` / `layoutNode` 改为显式栈迭代，`drawNode` 改为按深度分层的队列遍历（顺带消除深链的重复递归）。堆栈阈值实测后再决定 N/M 取值。

### [轻微][存量] #7 列线图只规定了"行高 = 绘图区高 / 行数"，没有规定行内文本的偏移上限，变量到 29 个左右刻度标签就与下一行重叠

- **位置**：`f_chart/doc/spec/add-f-chart-nomogram/design.md:6`（"行高为绘图区高度除以行数"）、`:11`（"左端标注 `range[0]`，右端标注 `range[1]`"）；对照 `f_chart/src/NomogramChart.cj:136`（`y = plot.y + (index + 0.5) * rowHeight`）、`:144`/`:152`（刻度文本基线 `y + fontSize + 2`）、`:201`（风险标签基线 `riskY + fontSize + 4`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」、§13（design 未定义行数增大时的退化行为）
- **证据**：静态确定（几何）—— 默认 `fontSize = 12`（`ChartTheme.cj:28`）、绘图区高 424（无标题时 480 − 24 − 32），`rowHeight = 424/(n+2)`；刻度文本基线相对行线固定偏移 14，`rowHeight < 14` 即 `n+2 > 30.3`，也就是 **29 个变量以上**，第 k 行的刻度文本会和第 k+1 行的水平线/文本压在一起。风险标签固定偏移 16 落在底部内边距内（最大约 +10，padding.bottom=24），不会出画布，只是会与最后一行刻度挤在一起。
- **描述**：行高被设计成自适应的，行内文本偏移却是固定像素，两者在变量较多时冲突；`risk` 风险标签同理。文档没有"超过 N 行时缩小字号 / 隔行标注 / 增加画布高度"的退化条款，使用者按 design 理解会以为布局始终可读。
- **建议**：design 补一条："行高低于 `fontSize * 1.6` 时，刻度标签改为隔行标注或整体缩小字号至最小 8px；仍不足则在 `nomogram-tick` 上加类名交由外部隐藏"，实现侧把固定偏移换成 `min(rowHeight - 2, fontSize + 2)`，并补一个 40 变量的用例断言相邻基线间距 ≥ 行高。

### [轻微][存量] #8 design 里的内部函数公式缺了实现中的边界分支，力导向的默认值与 `charge` 符号约定也没记载

- **位置**：`f_chart/doc/spec/add-f-chart-node-link/design.md:21`（`nodeLinkWidth`："`value <= 0` 或 `maxValue <= 0` 时返回 1；否则 `1 + 3 * sqrt(value / maxValue)`"）、`f_chart/doc/spec/add-f-chart-node-link/proposal.md:11`（"`linkDistance`、`charge` 控制力导向参数"）；`f_chart/doc/spec/add-f-chart-nomogram/design.md:22`（`nomogramPosition`："返回 `(value - min) / (max - min)`，结果夹到 0–1"）；对照 `f_chart/src/NodeLinkChart.cj:281-282`（多一层 `minFloat(ratio, 1.0)`）、`:68-72`（`linkDistance` 默认 100、`charge` 默认 −300）、`:144`（`abs(charge)`）、`f_chart/src/NomogramChart.cj:243-245`（`maxValue <= minValue` 直接返回 0）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§11「语义与命名 / 注释不符」
- **证据**：静态确定 —— 三处都能逐字对照：①`nodeLinkWidth(15, 10)` 按 design 公式得 4.674，实现返回 4（`value > maxValue` 在 `draw` 里不可达，但函数是 `internal` 单测入口，`NodeLinkChart_test.cj:190-194` 只测了 0 与 1 两个端点）；②`linkDistance = 100`、`charge = -300` 两个默认值在两份文档里都没写，且 `abs(charge)` 让正负号失去意义（传 `300` 与 `-300` 结果相同），design §1 只说"斥力 `charge / distance²`"，没交代符号被折叠；③`nomogramPosition` 在 `max <= min` 时返回 0（design 公式此处是除零），虽然 `totalPoints` 已强制递增、`draw` 内不可达，但同样是文档没写的分支。
- **描述**：三条都不会让现有调用方出错（不可达或只影响内部单测），但会让"照文档写单测/照文档调参"的人得出相反结论：按 design 断言 `nodeLinkWidth(15, 10) == 4.674` 会失败，按 proposal 传 `charge: 300` 以为会吸引、实际仍是斥力。默认值缺失则让"同一份 JSON 在文档与实现间不一致"这类问题无法核对。
- **建议**：`design.md:21` 公式改成 `1 + 3 * sqrt(min(1, value / maxValue))`；`design.md:22` 补"`max <= min` 时返回 0"；`proposal.md:11` 补默认值（`linkDistance` 100、`charge` −300，内部取绝对值，符号不影响结果）并说明 `charge` 越大斥力越强；`NodeLinkChart_test.cj` 增加 `nodeLinkWidth(15, 10) == 4` 的钳制用例。

### [一般][存量] #9 offline-flame「复用火焰图规则」实为 60 行解析 + 4 个私有函数逐行复制

- **位置**：`f_chart/doc/spec/add-f-chart-offline-flame/proposal.md:28`（"复用 `flameColorIndex` 与火焰图树构建规则"）；`f_chart/src/OfflineFlameChart.cj:50-110`（解析 + 挂树 + 唯一根校验）vs `f_chart/src/FlameChart.cj:50-111`；`f_chart/src/OfflineFlameChart.cj:167-215` vs `f_chart/src/FlameChart.cj:158-204`
- **来源**：存量（proposal 与实现同属提交 `ad6deecda`，此后未改动）
- **判据**：§2 重复逻辑（同一形态、只改类型名）；§13「文档与实现不符」
- **证据**：静态确定 —— 逐段比对：①`draw` 里 `nodes` 解析、`parent` 挂接、`roots.size != 1` 校验在两侧逐行一致（`FlameChart.cj:53-109` / `OfflineFlameChart.cj:53-109`），仅 `FlameNode` → `OfflineFlameNode`；②`findNode` / `validateValues` / `assignDepth` / `layoutNode` 四个私有函数体逐行同构（仅返回类型、异常消息换行位置不同）；③`drawNode` 是裁剪变体。真正共用的只有 `flameColorIndex`（`FlameChart.cj:252`）
- **描述**：三套规则各存两份——父值 ≥ 子值之和（容差 `1e-6`）、环守卫 `depth > total`、宽度归一化 `value / rootValue * plotWidth`。`FlameChart` 侧后来加入的 `colorBy` / `orientation` 分支在 offline-flame 里完全不存在，说明两份已经开始分叉；proposal 的"复用"会让后人以为改一处即可，实际改一处只生效一半。
- **建议**：抽内部公共能力（如 `buildFlameTree(items) -> (nodes, root)` + `layoutFlameColumn(node, x, rootValue, width)`）供两图共用；若不抽，把 proposal:28 改成"按火焰图规则重写，规则变更需两处同步"，并在两个文件的函数头互相注明，避免误判复用面。

### [轻微][存量] #10 org design 引用的 `leafCount` 在实现里不存在

- **位置**：`f_chart/doc/spec/add-f-chart-org/design.md:9`（"`leafCount(node)`：无子节点返回 1，否则返回子节点之和"）；对照 `f_chart/src/OrgChart.cj:46-48`（`OrgSlotCursor`）、`:226-238`（`orgAssignSlots`）
- **来源**：存量（design 与实现同属提交 `a0dad8a1c`）
- **判据**：§13「文档与实现不符（引用了不存在的符号）」；§1 文档层面的死引用
- **证据**：静态确定 —— 全仓 `grep leafCount` 只命中该 design.md 自身与无关同名标识（`f_email/src/imap/ImapFetch.cj:443` 的方法、`f_chart/src/StemLeafChart.cj:174` 的局部变量），`f_chart/src` 没有名为 `leafCount` 的函数。实现是游标 `cursor.next` 依次给叶子发槽位，父节点取首末子节点槽位中点
- **描述**：按 design 去找 `leafCount` 会扑空；配套的 `[start, end)` 区间与 `(start + end - 1) / 2` 推导在实现里也没有对应物（实现只有 `children[0].slot` 与 `children[last].slot`）。design §2 实际描述的是另一套（未采用的）算法。
- **建议**：按实现重写 §2——"游标 `next` 依次给叶子发槽位；父节点取首末子节点槽位中点"，删掉 `leafCount` 与区间推导，或显式标注为"等价推导，实现用游标"。

### [轻微][存量] #11 paired-line 文档把 `name` 写成必需，实现缺省回退为序号

- **位置**：`f_chart/doc/spec/add-f-chart-paired-line/proposal.md:10`（元素为 `{name, before, after}`）、`design.md:5`（"解析 `series[0].data` 的 `name`、`before`、`after`"）；对照 `f_chart/src/PairedLineChart.cj:78`
- **来源**：存量（同提交 `d95aa1957`）
- **判据**：§13「参数 / 默认值未记载」
- **证据**：静态确定 —— `json.string("name", default: (itemIndex + 1).toString())`，缺 `name` 时用 1 起的序号
- **描述**：文档读起来 `name` 是必需字段，实际可省。`before` / `after` 的非负约束 design:5 写清了，`name` 的可选性与默认值没写，按文档构造的最小输入与实现接受的最小输入不一致。
- **建议**：proposal 的元素形状写 `{name?, before, after}`，注明"缺省为数据项序号（1 起）"。

### [轻微][存量] #12 nomogram 校验 Requirement 漏列「`risk` 非空」

- **位置**：`f_chart/doc/spec/add-f-chart-nomogram/specs/chart-rendering/spec.md:34`；对照 `f_chart/src/NomogramChart.cj:85-87`
- **来源**：存量（同提交 `1b697d0a0`）
- **判据**：§14.1「规格与实现能力不一致（spec 少列）」
- **证据**：静态确定 —— 空 `risk` 数组抛 `InvalidValue("risk", "至少需要一个风险映射点")`，但 spec:34 的校验条款只列了 `variables` 非空、`range`/`points` 递增、`totalPoints` 递增、`risk.points` 落在范围内、`probability` 0–1
- **描述**：按 spec 写的符合性测试不会覆盖该分支；若有人按 spec 另写实现（允许空 `risk`，只画总分线），两版行为就分叉。属于"实现比规格严"，影响面小但会误导验收。
- **建议**：spec:34 补 "`risk` MUST 非空"，场景表加一条空 `risk` → `InvalidValue`。

## 优化可行性方案

> 本部分 20 个文件全为归档规格文档，没有可测量对象（无函数、无数据结构、无生命周期）。堆内存 / CPU 方案与 local mode 改造均**不提出**：任何数字都只能来自 `src/**`，属其他子轮；按铁律，无基线数字写在这里就是猜测。文中的上限类建议（#4 缩放、#6 节点数/树高上限）属于契约缺陷修复，已计入「发现」，不重复统计为优化方案；#9 的公共树构建抽取是**缺陷级重复**的修法，同样计入「发现」。

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 组织图 / 离线火焰图的递归在单链输入下的实际溢出深度（#6 的量化） | `f_chart/src/OrgChart.cj:218-238`、`f_chart/src/OfflineFlameChart.cj:176-248` | 触发 `StackOverflow` 的最小树高；平台默认栈大小 | 生成链高 1k / 2k / 5k / 10k 的单链 `nodes`，`cjpm bench -O2`（或直接 `cjpm run` 用例）逐档跑 `draw`，记录崩溃/正常与耗时；同机记录栈大小配置 |
| 2 | 节点-链接图力导向的耗时构成（80 轮 × O(n²) 斥力 + 每轮每条边两次 O(n) `findNode`） | `f_chart/src/NodeLinkChart.cj:227-262`、`:243-244` | n = 200/500/1000、\|E\| = 2n 时的自耗时占比 | `cjprof record` 跑三档规模的 `draw`（每档 30 次取中位数），看 `runForce` 自耗时占比是否 > 5%；若集中在 `findNode`，改 id→索引映射后同环境复测 |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part15.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-network-heatmap/specs/chart-rendering/spec.md` | .md | ✅ | 3 条 Requirement 全部成立：N×N 单元 = `NetworkHeatmapChart.cj:182-192`（测试 `NetworkHeatmapChart_test.cj:68` 断言 16 个）、`showValues` 默认 false（`:143`，`:193-203` 输出 value 文本）、校验逐条对应（`nodes` 非空 `:43-45`、id 唯一 `:55-59`、`series` 缺失/空 → `MissingField` `:65-69`、阶数 `:80-85`、非方阵 `:97-102`、元素非数字 `:107-109`、`cellGap` 非负 `:145`、`type` → `UnsupportedChart` `ChartConfig.cj:171-178`）。唯一未覆盖面是 `cellGap` 上界（会产出负宽矩形），已在 part12 #7 / part14 #5 记录，本部分不重复计 |
| 2 | `f_chart/doc/spec/add-f-chart-network-heatmap/tasks.md` | .md | ✅ | 4 项全部 `[x]`；`NetworkHeatmapChart_test.cj` 存在且覆盖单元格数（`:68`）、数值文本（`:93`）、默认不显示（`:99`）与校验用例（`:103-188`） |
| 3 | `f_chart/doc/spec/add-f-chart-node-link/design.md` | .md | ✅ | §1 三布局与 `NodeLinkChart.cj:138-145` 一致（`circular` 半径 0.35 短边 `:206-216`、`manual` 用 `x`/`y` `:193-204`、`force` 80 轮确定性迭代 `:227-262`，无随机数）；§2 半径 8、`group` 散列、名称在圆点下方与 `:166-180` 一致；§3 公式缺 `min(ratio,1)` 钳制，且默认值/`charge` 符号未记载，见 #8 |
| 4 | `f_chart/doc/spec/add-f-chart-node-link/proposal.md` | .md | ✅ | `type`、`nodes`/`links` 形状、三取值 `layout`（默认 `force`，`NodeLinkChart.cj:64-67`）、三个类名与实现一致；`linkDistance`/`charge` 无默认值，见 #8 |
| 5 | `f_chart/doc/spec/add-f-chart-node-link/specs/chart-rendering/spec.md` | .md | ✅ | 计数（5 节点 5 连线）、标签、布局（默认/`manual` 缺坐标 → `MissingField` `:97-104`、非法布局 → `InvalidValue` `:65-67`）、宽度（`:277-283`，测试 `:192-193`）、未知端点/重复 id → `InvalidValue`（`:88-92`、`:122-127`）均成立；`links` 非空未实现，见 #2 |
| 6 | `f_chart/doc/spec/add-f-chart-node-link/tasks.md` | .md | ✅ | 4 项全部 `[x]`；`NodeLinkChart.cj` / `NodeLinkChart_test.cj` / `nodeLinkWidth`（`:277`）均存在 |
| 7 | `f_chart/doc/spec/add-f-chart-nomogram/design.md` | .md | ✅ | §1 行数 = `variables.size + 2`、行高 = 绘图区高/行数、名称右对齐与 `NomogramChart.cj:120-142`、`:226-238` 一致；§3 总分线/风险刻度位置与 `:161-207` 一致；§2 的"`points` 保留在解析结果中"不成立（#3）；§4 缺 `max <= min` 分支（#8）；行高退化未定义（#7） |
| 8 | `f_chart/doc/spec/add-f-chart-nomogram/proposal.md` | .md | ✅ | `type`、`variables`/`totalPoints`/`risk` 形状、三个类名与实现一致；"取值折算为分值/得到风险估计"的能力未实现，见 #3 |
| 9 | `f_chart/doc/spec/add-f-chart-nomogram/specs/chart-rendering/spec.md` | .md | ✅ | 变量尺/总分尺/风险刻度计数、`nomogramPosition` 中点与夹取（`:242-254`，测试 `:77-79`）、五项校验（`:55`、`:68-74`、`:80-82`、`:100-105`）全部成立；规格本身不含 `points` 刻度要求，故与实现一致，但与 proposal 的承诺面不一致（#3）；校验清单漏 `risk` 非空（#12） |
| 10 | `f_chart/doc/spec/add-f-chart-nomogram/tasks.md` | .md | ✅ | 4 项全部 `[x]`；`nomogramPosition`（`:242`）与测试文件存在 |
| 11 | `f_chart/doc/spec/add-f-chart-offline-flame/design.md` | .md | ✅ | §2 子树选择/相对深度/基准归一化与 `OfflineFlameChart.cj:112-121`、`:202-215` 一致；§3 深度截断"仍递归算布局"与 `:151` + `:225-227` 一致；§4 颜色 `flameColorIndex`、宽度足够才写标签与 `:228-244` 一致；§1 的"检测环"守卫不可达，见 #1；递归无上限见 #6 |
| 12 | `f_chart/doc/spec/add-f-chart-offline-flame/proposal.md` | .md | ✅ | `type`、`{id,name,parent,value}`、`root`/`maxDepth` 语义、两个类名与实现一致；"复用 `flameColorIndex` 与火焰图树构建规则"只有前半成立——树构建与四个私有函数是整段复制，见 #9 |
| 13 | `f_chart/doc/spec/add-f-chart-offline-flame/specs/chart-rendering/spec.md` | .md | ✅ | 子树绘制（测试 `:61`、`:81`）、`maxDepth` 0/1 截断（`:97`、`:117`）、非负整数校验（`:124-129`）、宽度归一化（`:209`）成立；缺"与 `root` 连通性"口径，与 #1 同源 |
| 14 | `f_chart/doc/spec/add-f-chart-offline-flame/tasks.md` | .md | ✅ | 4 项全部 `[x]`；`OfflineFlameChart.cj` / `_test.cj` 存在，测试含未知 root、负 `maxDepth`、多根、空节点（`:120-206`） |
| 15 | `f_chart/doc/spec/add-f-chart-org/design.md` | .md | ✅ | §2 槽位/坐标公式与 `OrgChart.cj:241-263` 一致（`vertical`/`horizontal` 两式、`gap = levelGap*0.5`）；§3 连线 `M…V…H…V`、描边白色、标签截断与 `:152-202`、`:266-286` 一致；§1 "检测环"缺失（#1）；§2 `leafCount` 与 `[start,end)` 区间归纳在实现里不存在（#10）；"整体在 plot 内居中"越界失效（#4） |
| 16 | `f_chart/doc/spec/add-f-chart-org/proposal.md` | .md | ✅ | `type`、`nodes` 形状、`layout` 两取值与默认、`nodeWidth 140`/`nodeHeight 48`/`levelGap 80` 三个默认值、三个类名与 `OrgChart.cj:57-63`、`:183-202` 一致；`orgLayout` 存在（`:241`） |
| 17 | `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md` | .md | ✅ | 节点尺寸/标签、连线数量与端点（`:154-172`）、`vertical`/`horizontal` 走向、四项尺寸/布局校验（`:64-78`、`:120-122`）成立；"不存在环"未实现（#1）；"父节点中心 = 子节点中心平均值"与 design、实现三种口径不一致（#5） |
| 18 | `f_chart/doc/spec/add-f-chart-org/tasks.md` | .md | ✅ | 4 项全部 `[x]`；`orgLayout` 与 `OrgChart_test.cj` 存在（测试覆盖 6 节点/6 标签/5 连线、槽位、两方向、缺父、非法布局、零宽）；`rejectsCycle` 用无根图，见 #1 |
| 19 | `f_chart/doc/spec/add-f-chart-paired-line/design.md` | .md | ✅ | §1 `name`/`before`/`after` 且非负（`bulletNumber` `BulletChart.cj:233-243`，用于 `PairedLineChart.cj:79-80`）；§2 `BandScale(plot.x, plot.right(), 2)` 中心（`:130`、`:152-153`）、纵轴覆盖 + 缺省 5%（`:85-102`）、`yAxis.min/max` 覆盖（`:95-105`）；§3 1.5px 斜线、半径 3.5、名称右侧 8px（`:159-172`）；§4 四类校验（`:48-50`、`:57-59`、`:67-69`、`:79-80`）全部成立；`name` 可缺省未记载，见 #11 |
| 20 | `f_chart/doc/spec/add-f-chart-paired-line/proposal.md` | .md | ✅ | `type`、`{name,before,after}` 形状、`xAxis.labels` 缺省 `["前","后"]`（`:43-50`）、三个类名与实现一致；连线/端点/标签计数测试 `PairedLineChart_test.cj:61-74` 与文档一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 5 条（#1 环检测不成立、#2 `links` 非空、#3 分值映射缺失、#4 布局越界、#5 居中口径矛盾），设计 1 条（#9 复制而非复用），可读性/契约精度 1 条（#8）。本部分无 `.cj`：值/引用语义、`Option` 惯用法、`mut` 只在核对文档条款时涉及（`?Float64` 的 `x`/`y`、`?String` 的 `parent`/`root`，实现分支完整）；文档描述的架构为"每图一个 `<Chart>` 实现 + 共用 `ChartFrame`/`ChartSvgKit`"，无分层违规；无外部输入拼串、无凭据、无敏感数据，安全性不适用 |
| §1 死代码 | 0 | 20 个文件全为 `.md`，无声明可判。对文档点名的内部符号做了存在性与引用核对：`nodeLinkWidth`(`NodeLinkChart.cj:277`)、`nomogramPosition`(`NomogramChart.cj:242`)、`orgLayout`(`OrgChart.cj:241`)、`flameColorIndex`(`FlameChart.cj:252`)、`chartTextWidth`(`ChartScale.cj:113`) 均在 `src/` 有调用点或单测；`leafCount` 全仓不存在（只命中 design 自身与无关同名局部变量）→ 记为 #10（文档死引用，不计入代码死代码）；`points` 属于"解析后不读"的读了不用（已并入 #3）。未对本部分之外的 `src/**` 做 private/internal 全量引用统计——那属其他子轮 |
| §2 重复逻辑 | 1 | 已逐对比对 6 个变更的文档：`proposal.md` 的 "Why / What Changes / Capabilities / Impact" 四段信封属 OpenSpec 模板，5 份 `tasks.md` 为同一 4 行模板，均不判重复。实现侧按"同名函数 + 函数体逐行"比对：`OfflineFlameChart` 与 `FlameChart` 的 `draw` 解析段与 `findNode`/`validateValues`/`assignDepth`/`layoutNode` 同构（只改类型名）⇒ #9；`org` 与 `offline-flame` 的"树构建 → 深度 → 布局 → 绘制"四段虽同形，但槽位布局 vs 宽度归一化是不同算法，保留两份正确。同语义写两遍的"父节点居中"按"口径矛盾"记 #5，不重复计 |
| §3 空实现 | 1 | #3（`points` 解析后不参与任何绘制，design 自认"用于后续扩展"）。其余：5 份 `tasks.md` 全部 `[x]` 且指向的源文件/测试文件都存在；文档无 `TODO`/`FIXME` 占位段落；`OfflineFlameChart` 的 `depth > total` 恒假分支已归入 #1，不重复计 |
| §4 栈溢出 | 1 | #6：深度遍历（`orgAssignDepth`/`orgAssignSlots`、`validateValues`/`assignDepth`/`layoutNode`/`drawNode`）层数 = 树高，`nodes` 无上限（`org design.md:5`、`offline design.md:5/15`，实现侧六趟递归）。平台栈大小未现场查证，故只写"需实测"、未定严重；`org` 的 `(first+last)/2` 等非递归逻辑无风险 |
| §5 OOM | 0 | 本部分无"N×N 输出"类条款。网络热力图的 O(N²) 图元放大面其承诺源正是本部分 `network-heatmap/specs/.../spec.md:7-8`，已由 part14 #5 报出（并已有 part12 #7 的实现侧同源条目），按"同一根因合并"不重复计；其余 4 图输出规模与输入同阶（O(nodes)、O(edges)、O(variables)、O(risk)），无全量物化/无界容器条款 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分亦无运行时代码。唯一复杂度线索（力导向 80 轮 × O(n²) + 每轮每条边两次 O(n) `findNode`）已列入待验证假设 #2，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 6 个变更的文档均不涉及锁；`Chart.draw` 契约是纯函数，从 `JsonObject` 到 `String`，无全局可变状态、无共享缓存 |
| §6.3 并发串行 | 0 | 文档无 `spawn` / `Future` / 线程池 / 定时任务描述 |
| §6.4 低效算法 | 0 | 已核 `NodeLinkChart.cj:227-262` 的双重循环与 `:243-244` 的线性查找、`:88-92` 的 O(n²) 重名检查、`OrgChart.cj:88-92` 同款：是否成为瓶颈缺耗时数据，按铁律只进待验证假设 #2。文档内的比例换算（`nomogramPosition`）与槽位中点均为 O(1)/O(n)，无可判定的低效实现 |
| §7 降堆内存方案 | 0 | 文档无"持有什么、多大、活多久"的可测对象（未引入缓存、队列、注册表）；产出无基线方案违反铁律，故不提出 |
| §8 降 CPU 方案 | 0 | 同上；本次唯一可提的 CPU 线索（力导向）缺基线，已放待验证假设 #2，不写成方案 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象描述；`Chart.draw` 的产物必须作为 `String` 返回（逃逸），"函数返回即释放"前提不成立；且无峰值内存数据，只能是猜测 |
| §11 现有代码的 BUG（存量） | 6 | #1–#6，全部给了实现行号与触发输入。取证只限本轮文档涉及处，未做全仓考古（`FlameChart.cj` 只作为"同源"提示引用） |
| §12 并发安全与锁粒度 | 0 | 文档未描述共享可变状态；`Chart` 契约无单例/注册表/回调注册，排除跨请求共享路径；锁粒度无可谈对象 |
| §14 功能完备性与 README 覆盖 | 4 | #3（proposal 承诺的"取值→分值→风险"无实现、spec 无对应 Requirement）、#1（spec/design 承诺环校验无实现）、#2（spec 承诺的 `links` 非空校验缺失）、#12（spec 少列实现已有的 `risk` 非空校验）。README 覆盖不属本部分（`README.md` / `README_en.md` 在其他子轮），未越界判断；6 个 `type` 字面量已确认在 `README.md` 登记 |
| §13 文档一致性 | 7 | #3（design 称 `points` 被保留，实际丢弃）、#4（"整体在 plot 内居中"不成立）、#5（spec「平均值」vs design「区间中点」）、#8（三处公式/默认值不符）、#9（proposal 的"复用"表述与复制实现不符）、#10（design 引用不存在的 `leafCount`）、#11（`name` 缺省未记载）。其余条款逐条落到实现行核对一致：`type` 字面量、类名、默认值（`linkDistance`/`charge` 除外）、`ChartErrorKind` 映射、`maxDepth` 整数判定、`cellGap` 非负、`XxxWidth/Position/Layout` 内部入口 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分覆盖 6 个变更的 20 份归档文档（网络热力图后半、节点-链接、列线图、离线火焰图、组织图、配对连线）。**文档的可判定性整体高于同模块前几部分**：计数类 Scenario（16 个单元、5 个节点/5 条连线、3 条变量尺/4 个风险刻度、5/7/1/3 个 `offline-flame-node`、6 个节点/5 条连线）逐条能与测试断言对上；`paired-line` 的 19 行 design 与 177 行实现几乎一一对应，是本部分质量最好的一份；`network-heatmap` 的三条 Requirement 全部有实现与测试支撑。

风险集中在四类：

- **校验条款写进了 MUST、实现没跟上**（#1 / #2，一般）：两张树图的"不存在环 / 检测环"都没有真正的检测路径——组织图完全没有，离线火焰图的 `depth > total` 守卫恒假；而组织图的环测试用"无根图"误通过，掩盖了缺口。空 `links` 同理：spec 要求非空，实现接受。这类问题的共同后果是"输入合法、产物静默错"，且都能被现有测试放过。
- **能力承诺大于实现**（#3，一般）：列线图的核心（变量取值 → 分值 → 总分 → 风险）只有第一条链路的起点，`points` 解析后即被丢弃，proposal 的 Why 段因此名不副实。这是本部分唯一"功能层面"的缺口，需要产品口径决策，不宜只改文档糊过去。
- **坐标与边界**（#4 / #5，一般；#7，轻微）：组织图的"居中"在布局超过绘图区时会变成负偏移，默认参数下 6 个叶子或 6 层就让节点出画布，而现有测试把样例放大到 900×560 恰好避开；"父节点居中"被写成三种口径（spec 平均 / design 区间中点 / 实现首末中点），叶子数不均时给出三个不同坐标。列线图则是行高自适应、行内文本偏移固定，29 个变量起刻度文本互相压叠。这些都属"合法输入 → 图不好看/画错位置"，不崩溃但要修。
- **同一套规则两份实现/两份口径**（#9 一般；#8 / #10 / #11 / #12 轻微）：offline-flame 号称复用火焰图的树构建，实际整段复制了 `draw` 的解析段与四个私有函数（已开始分叉：`colorBy`/`orientation` 只存在于火焰图侧）；`leafCount`、`linkDistance`/`charge` 默认值、`name` 缺省、`risk` 非空这些条款在文档与实现之间各有一处没对齐，单条影响都很小，但会让"照文档写测试"的人得出相反结论。

`严重` 为 0：本部分无运行时代码，未发现崩溃、并发或数据计算错误；#6 的栈溢出风险因缺平台栈阈值实测，按铁律只定`一般`并列入待验证假设。性能与内存只有两条待验证假设（递归溢出深度、力导向耗时构成），均无基线，不进修复清单。修复优先级建议：#1（静默丢数据）> #9（会持续放大的重复）> #2/#5（口径二选一）> #4/#7（布局边界）> 其余文档措辞。

**范围外提示**（`.cj` 属其他子轮，只记一句）：`OrgChart.cj:108-122/218-223`、`OfflineFlameChart.cj:176-200` 是 #1 的实现侧；`OrgChart.cj:128-139` 是 #4；`OrgChart.cj:235-237` 是 #5；`NodeLinkChart.cj:109-135` 是 #2；`NomogramChart.cj:71-75/23-33` 是 #3；`NomogramChart.cj:144/201` 与 `ChartTheme.cj:28` 是 #7；`NodeLinkChart.cj:68-72/144/281` 与 `NomogramChart.cj:243-245` 是 #8；`OfflineFlameChart.cj:50-215` vs `FlameChart.cj:50-204` 是 #9；`PairedLineChart.cj:78` 是 #11；`NomogramChart.cj:85-87` 是 #12；`FlameChart.cj:111-112` 与 `NodeLinkChart.cj:243-244` 分别与 #6、待验证假设 #2 同源。

存量缺陷共 12 条（一般 7 / 轻微 5），是否纳入修复待用户决定；本报告只读文件，未修改任何源码，未跑构建（文档类审查，无可执行验证面；实现行号均来自现场阅读与 `grep`）。
