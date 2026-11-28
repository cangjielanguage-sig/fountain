# f_chart 模块审查报告

> **模块第 9/37 部分**（本报告只覆盖 `files/f_chart.part9.txt` 列出的 20 个文件，全部是 `f_chart/doc/spec/add-f-chart-*` 下的变更文档：dumbbell 的 `specs/chart-rendering/spec.md` / `tasks.md`，ecdf / error-bar / flame / flow-map 的 `design.md` / `proposal.md` / `specs/chart-rendering/spec.md` / `tasks.md`，以及 flowchart 的 `design.md` / `proposal.md`。`src/**`、模块 README 与其余 `doc/**` 由其他子轮产出，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（dispatch 记录为 `120fd2542`；`git rev-parse --short HEAD` 实测 `f309f0b55`，`git status --porcelain f_chart` 为空 ⇒ 无 diff 可比，所有问题来源记「存量」）
- **审查重点**：本轮指定「渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑」。本部分无代码，实际执行的是把每份 `spec.md` 的 Requirement/Scenario 与 `design.md` 的算法描述当验收契约，逐条回读对应实现（`DumbbellChart.cj`、`EcdfChart.cj`、`ErrorBarChart.cj`、`FlameChart.cj`、`FlowMapChart.cj`、`Flowchart.cj`，支撑语义取 `ChartFrame.cj` / `ChartScale.cj` / `ChartConfig.cj` / `ChartException.cj`），判 §13 文档一致性、§14 功能完备性；读实现时撞见的源码问题按「范围外提示」单列，不计入本部分统计。
- **报告版本**：v1（第 9/37 部分）

## 发现

### [严重][存量] #1 ECDF 阶梯线整体左移一档，按图读出的分位数系统性偏移一个秩

- **位置**：`f_chart/doc/spec/add-f-chart-ecdf/design.md:11`（阶梯路径定义）；实现 `f_chart/src/EcdfChart.cj:171-186`
- **来源**：存量（`git log -1 -- f_chart/src/EcdfChart.cj` → `2845ac7dc` 2026-11-08 "feat(f_chart): M90 累积频率图"；快照模式无 diff）
- **判据**：review-checklist §13「规格与实现漂移」、§11「与规格冲突（渲染数据错误）」
- **证据**：静态确定 —— design 定义「首点从 `(x0, 0)` 起，先垂直跃升到 `(x0, 1/n)`，再水平到 `(x1, 1/n)`，依次推进」。实现先 `M x0 yBase`、`V y1`（`:172-177`），随后循环体是「`H x_pos` → `V y_{pos+1}`」（`:178-185`），即垂直跃升发生在 `x_pos` 而不是 `x_{pos+1}`。以 spec 的三个观测 `[3,1,2]`（points = `(x0,1/3),(x1,2/3),(x2,1)`）展开，生成的 `d` 为 `M x0 yBase V y1 H x0 V y2 H x1 V y3 H x2`。旁证：`:180` 的 `let y = yScale.scale(points[position][1])` 自始至终未被使用，正是这段错位的残留。
- **描述**：曲线在 `x0` 处就升到 `2/n`（并经停 `1/n`），水平段画在 `2/n` 上覆盖 `[x0,x1]`，顶部水平段从 `x1` 延伸到 `x2` 而非从 `x2` 开始。ECDF 的唯一读法是「横轴取 x、纵轴读累积比例」，整体左移一档等于把每个分位数读高一个秩；两条曲线对比时中位数、P95 等读数都会偏。用例只断言 `ecdf-line` 条数（`EcdfChart_test.cj:53-56`）与 `ecdfPoints` 的数值（`:67-86`），对 `d` 属性零断言，所以测试全绿也暴露不出。
- **建议**：把跃升移到下一个观测值处——循环体改为先 `V y_{pos+1}` 再 `H x_{pos+1}`（末端补 `H` 到最后一个有效 x 即可），即目标 `d` 形如 `M x0 yBase V y1 H x1 V y2 H x2 V y3`；并在 `EcdfChart_test.cj` 增加一条对 path `d` 的几何断言（`V y(1/n)` 之后紧跟 `H x1`），锁住阶梯口径。

### [一般][存量] #2 哑铃图 spec 只要求「数字型 `low`/`high`」，实现借 `bulletNumber` 额外拒绝负值

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/specs/chart-rendering/spec.md:34`；`f_chart/src/DumbbellChart.cj:70-71`；`f_chart/src/BulletChart.cj:233-243`
- **来源**：存量（`git log -1 -- f_chart/src/DumbbellChart.cj` → `dd85af4fc` 2026-11-08 "M77 哑铃图"）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— spec 的校验条款只写「每个数据项 MUST 提供**数字型** `low` 与 `high`」，四个 Scenario 都不涉及符号；实现把解析交给子弹图的 `bulletNumber`，该函数在 `number < 0.0` 时抛 `InvalidValue`「数值不能为负」（`BulletChart.cj:239-241`）。`grep "负" DumbbellChart_test.cj` 无命中，这条约束既没进文档也没被用例固定。
- **描述**：哑铃图的典型输入就是前后两次测量的差值（利润 −3 → +8、温差 −2 → +5），跨 0 是常态。当前实现把这类合法数据判为 `InvalidValue`，且错误文案来自子弹图（「数值不能为负」），使用者无法判断这是哑铃图规则还是辅助函数副作用。同批的 `ErrorBarChart.cj:111-113` 用 `jsonNumberValue`（允许负值），两图对同一「数字型」语义口径不一致。
- **建议**：哑铃图改用 `jsonNumberValue(json.required("low"/"high"), …)` 自行解析，spec 补一句「负数合法」；若确实只支持非负，则在 spec 的 Requirement 与 Scenario 里写明 `InvalidValue`，并让错误文案归属哑铃图。

### [一般][存量] #3 火焰图规范承诺「每个节点一个 `flame-node`」，与根不连通的环节点被静默丢弃

- **位置**：`f_chart/doc/spec/add-f-chart-flame/specs/chart-rendering/spec.md:7`、`:44`；实现 `f_chart/src/FlameChart.cj:95-113`
- **来源**：存量（`git log -1 -- f_chart/src/FlameChart.cj` → `8d5231aa8` 2026-11-08 "M52 火焰图"）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「只做了一半的分支」、§11「数据被静默丢弃」
- **证据**：静态确定 —— 挂接阶段只按 `parentId` 建 `children` 链（`:95-106`），随后仅校验 `roots.size != 1`（`:107-109`）；`validateValues` / `assignDepth` / `layoutNode` / `drawNode` 全部从 `rootNode` 递归（`:111-112`、`:140`、`:152-154`）。输入「一个正常根 `R` + `A.parent=B`、`B.parent=A`」时 `roots` 只有 `R`，单根校验通过，`A`/`B` 既不在 `roots` 也不在 `R` 的子树里 ⇒ 不做 value 校验、不参与布局、不画矩形。`:167-170` 的 `depth > total` 环守卫对这条路径是空转：单父指针结构下从根可达即不可能成环。
- **描述**：结果是「输入合法、输出少节点」——SVG 里既没有这两个节点的 `flame-node`，也没有异常或日志。spec 的校验清单（`:44`）没有「全部节点可达/无环」这一条，四个 Scenario 也不覆盖；`FlameChart_test.cj` 无环用例（`grep "环\|cycle"` 无命中）。
- **建议**：spec 校验条款补「每个节点 MUST 能沿 `parent` 链到达唯一根（图无环且全可达），否则 `InvalidValue`」并加 Scenario；实现侧在 `:111` 前统计可达节点数与 `nodes.size` 比较（源码归对应子轮）。

### [一般][存量] #4 流向地图 proposal 承诺「带箭头的路径」，实现只有无箭头的 `<path>`

- **位置**：`f_chart/doc/spec/add-f-chart-flow-map/proposal.md:5`；实现 `f_chart/src/FlowMapChart.cj:213-220`
- **来源**：存量（`git log -1 -- f_chart/src/FlowMapChart.cj` → `b4c32432b` 2026-11-08 "M60 流向地图"）
- **判据**：review-checklist §13「承诺与实现不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— proposal 的 Why 用「在区域底图上用**带箭头**的路径表达人口、物流或资金在节点间的迁移量与方向」定义该图能力；实现该段只输出 `<g class="flow-map-path"><path d=… fill="none" stroke=… stroke-width=… stroke-opacity="0.6"/></g>`，循环内无任何三角形/marker 绘制。全仓 `grep -n "marker\|arrow" f_chart/src/*.cj` 只命中图例 `markerSize` 与 Flowchart / Gantt / Sequence / Swimlane 的箭头，FlowMapChart 零命中，`ChartSvgKit` 也没有 marker 相关 API。
- **描述**：spec（`specs/chart-rendering/spec.md:7`）只要求输出 `<path>`，实现照 spec 做，但 proposal 描述的「方向」信息在产物里不存在——两端区域质心连直线时无法区分 A→B 与 B→A。文档内部（proposal vs spec）也不一致，按 proposal 验收会判失败。
- **建议**：二选一并同步——(a) 在 `:195-221` 末端按最后一段方向补三角形（几何可复用 `Flowchart.cj:292-295`），并把「箭头」写进 spec 的 Requirement；(b) 若有意省略，把 proposal 的措辞改成「折线路径」，并在 spec 明确「不画箭头，方向由源/目标语义表达」。

### [一般][存量] #5 流程图 `horizontal` 布局下箭头整段被目标节点盖住，与 design「边到节点边界、末端画箭头」不符

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/design.md:15`；实现 `f_chart/src/Flowchart.cj:285-296`、`:145-159`、`:316`
- **来源**：存量（`git log -1 -- f_chart/src/Flowchart.cj` → `b69df3563` 2026-11-08 "M9 流程图"）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符（几何）」
- **证据**：静态确定 —— 端点偏移写成 `minFloat(sourceWidth, sourceHeight) / 2.0 + 2.0`（`:285-286`），与连线方向无关；默认节点 120×48 时偏移恒为 26。`layout: horizontal` 的连线沿 x 方向，节点在 x 向的半宽是 60，箭头基点落在目标中心左侧 26px（节点内部 34px）；绘制顺序是边先（`:145-154`）、节点后（`:155-159`），节点填充不透明（`:316` 取主题背景，`none` 也回落 `#ffffff`），箭头三角（`:292-295`）被完全遮住。垂直布局下偏移 26 与半高 24 只差 2px，箭头恰好露头，因此现有用例（只覆盖默认 vertical 与 `manual`）发现不了。
- **描述**：`horizontal` 是 proposal 明确支持的三种布局之一（`proposal.md:12`），在该模式下方向信息（箭头）在合法配置下完全不出现；`manual` 布局的斜向边同样会侵入节点矩形。design 承诺的「从源节点边界到目标节点边界」实际是「按短边半径截断」。
- **建议**：design 补「端点偏移按连线方向与节点矩形求交（水平边用 `宽/2`、垂直边用 `高/2`，diamond 按菱形边界）」；实现侧改为方向感知求交，并给 `horizontal` 加一条断言 `edge-arrow` 顶点落在节点外的用例。

### [一般][存量] #6 流程图层距实为 `maxNodeHeight + 90`，四层图即越出画布且无压缩

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/design.md:13`；实现 `f_chart/src/Flowchart.cj:252-259`
- **来源**：存量（快照模式无基线；实现同上 `b69df3563`）
- **判据**：review-checklist §13「默认值与文档不符」、§11「边界/越界」
- **证据**：静态确定 —— design 写「每层节点在绘图区内水平均分，**垂直层距 90**」；实现 `centersY = plot.y + level * (maxNodeHeight + 90) + height/2`（`:257`），横向布局同理用 `maxNodeWidth + 90`（`:253`）。默认 48 高 ⇒ 实际层距 138。`ChartFrame` 对该图传入 `yLabelWidth = 0`、`xLabelHeight = 0`（`:107`），plot = `(24, 24, 752, 432)`（`ChartFrame.cj:91`），level 3 的中心 y = 24 + 414 + 24 = 462、底边 486，已超出画布 480；`:248-261` 既未按 plot 高度压缩层距，也未裁剪或缩放。
- **描述**：四层流程（开始→判断→处理→结束）是最小可用图，默认画布下最后一层直接被裁掉。文档的 90 与实现的 138 相差 53%，按 design 复算布局的人会得到不同结果。
- **建议**：层距改为 `maxNodeHeight + gap`，`gap` 由层数与 plot 高度反算（`gap = min(90, (plot.height - Σ层高) / max(1, levelCount-1))`）；并补一条「4 层节点全部落在 plot 内」的用例。

### [轻微][存量] #7 流程图 design「节点先于边绘制（边在下）」自相矛盾，实现是边先画

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/design.md:19`；实现 `f_chart/src/Flowchart.cj:145-159`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— 同一句前半句「节点先于边绘制」与括号「（边在下）」在 SVG「后画覆盖先画」语义下互斥；实现先 `for (edge in edges) drawEdge(...)`（`:145-154`）再 `for (...) drawNode(...)`（`:155-159`），即边在下、节点在上，与括号一致、与前半句相反。
- **描述**：绘制顺序决定节点填充是否遮住进入节点的线段与箭头，写反会放大上一条（箭头被遮）的现象。该句后半的形状映射（rect/round → 矩形、diamond/parallelogram/document → path、ellipse → `<ellipse>`）与 `:320-347` 逐项一致，只有顺序写反。
- **建议**：改为「先画边、后画节点（边在节点之下），保证节点填充遮住进入节点的线段」。

### [轻微][存量] #8 火焰图 design 对 `flameColorIndex` 的描述（字节累加取模）与实现的 31 乘子散列不符

- **位置**：`f_chart/doc/spec/add-f-chart-flame/design.md:19`；实现 `f_chart/src/FlameChart.cj:252-261`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」
- **证据**：静态确定 —— design 写「`flameColorIndex` **累加名称字节值**后取模调色板长度」，实现是 `hash = (hash * 31 + Int64(byte)) % 1000003`，最后 `hash % paletteSize`（`:256-260`）。两者对同一名称给不同下标（`"main"` 的字节和为 425，散列值不同）。spec（`spec.md:35`）只要求「由 `flameColorIndex(name, paletteSize)` 决定且对相同名称稳定」，对算法不敏感，故用例只比较两次调用相等。
- **描述**：名称配色是火焰图唯一按名称派生的视觉属性，design 是唯一说明来源；按文档复算或移植配色会得到另一套颜色。`% 1000003` 这个中间模数文档完全未提，读者无法判断是否存在溢出保护。
- **建议**：design 改写为实际算法（含中间模数的用途）；或在 `FlameChart_test.cj` 对 `"main"` 断言具体下标，锁住契约。

### [轻微][存量] #9 ECDF design「首点从 `(x0, 0)` 起」与实现从 y 轴下界起不符

- **位置**：`f_chart/doc/spec/add-f-chart-ecdf/design.md:11`；实现 `f_chart/src/EcdfChart.cj:105-108`、`:172-176`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「默认值与源码不符」
- **证据**：静态确定 —— 实现起点写 `M x0 ${yScale.scale(yMin)}`，`yMin` 取 `yAxis.min`、缺省 0.0；同目录 spec 又允许「`yAxis.min/max` 给出时 MUST 按给定值」（`spec.md:25`）。`yAxis.min = 0.2` 时曲线从 0.2 起而非 0。
- **描述**：design 的 `0` 只在默认配置下成立；按文档实现会覆盖 `yAxis.min` 或画出轴外竖线。与上一条（阶梯错位）同处一句描述，但根因不同：这条是起点口径，那条是循环顺序。
- **建议**：改为「首点从 `(x0, y 轴下界)` 起（缺省 0）」，并注明与 `yAxis.min` 的关系。

### [轻微][存量] #10 误差线 spec 的校验清单缺「`series` 恰好 1 个」，实现据此拒绝多系列

- **位置**：`f_chart/doc/spec/add-f-chart-error-bar/specs/chart-rendering/spec.md:39`；实现 `f_chart/src/ErrorBarChart.cj:51-53`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「该写没写」、§13「规格与实现漂移」
- **证据**：静态确定 —— spec 只列 `low <= high`、`y ∈ [low, high]`、`data` 非空、`series` 缺失 → `MissingField`、类型不符 → `UnsupportedChart`；实现 `seriesItems.size != 1` 时抛 `InvalidValue`「误差线图仅支持 1 个系列」。同批 dumbbell 的 spec（`spec.md:34`）明确写了「`series` MUST 恰好 1 个」，两处写法不一致。
- **描述**：传两个系列（多组均值对比是误差线图常见用法）会拿到文档里没有的 `InvalidValue`；proposal 用 `series[0].data` 暗示单系列，但 spec 的验收条款没有承接。
- **建议**：spec 补「`series` MUST 恰好 1 个，否则 `InvalidValue`」+ Scenario；`ErrorBarChart_test.cj` 同步补用例。

### [轻微][存量] #11 哑铃图 tasks 声称用例覆盖「范围」，实际范围计算零断言，spec 的轴刻度 Scenario 无落点

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/tasks.md:3`；`.../specs/chart-rendering/spec.md:27-30`；`f_chart/src/DumbbellChart_test.cj:73-93`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14「验收口径缺失」、§13「Scenario 与用例不符」
- **证据**：静态确定 —— tasks 1.1 写「（连线、端点、**范围**、校验）」；对应「范围」的 `computesDefaultRange`（`:82-93`）只有 `count(..., "dumbbell-line") == 1`，未断言任何轴范围；`drawsAxes`（`:73-78`）只做 `svg.contains("100")` 整串包含判断，`"0"` 更是任意数字串都能命中。spec 的 Scenario「`xAxis.min` 0 / `xAxis.max` 100 → 输出轴刻度包含 0 与 100」因此无法证伪。
- **描述**：范围计算（`DumbbellChart.cj:90-110`，含 `max < min` 抛错、`max == min` 自动 ±1 扩展）目前零覆盖，后续重构无保护。
- **建议**：改为断言 `tick-label` 文本集合包含 `0` 与 `100`，并补 `max == min` / `max < min` 两条用例。

### [轻微][存量] #12 哑铃图 spec 未记载实现的两个错误分支（`series` 为空 → `MissingField`、`xAxis.max < min` → `InvalidValue`）

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/specs/chart-rendering/spec.md:32-44`；实现 `f_chart/src/DumbbellChart.cj:45-50`、`:104-106`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「该写没写」、§13「规格与实现漂移」
- **证据**：静态确定 —— spec 写「`series` MUST 恰好 1 个」，但实现把「空数组」判成 `MissingField`、「长度 ≠ 1」判成 `InvalidValue`，两种 kind 不同且文档只覆盖了后者；`xAxis.max < xAxis.min` 时抛 `InvalidValue`（`:104-106`），spec 的轴范围 Requirement（`:23-30`）只描述相等时自动扩展，未提倒置。
- **描述**：按 spec 写边界用例的人会预期「空 `series` = `InvalidValue`」，实际拿到 `MissingField`；倒置范围的行为也没有验收条款。`data[].name` 字段只在 README 示例（`README.md:571`）出现，spec 未记载，spec 读者不知道可以用它覆盖类目标签。
- **建议**：spec 校验条款区分「缺失 → `MissingField`」与「数量 ≠ 1 → `InvalidValue`」，补 `xAxis.max < min` 的 Scenario，并在数据形状里列出 `data[].name`（缺省为序号）。

### [轻微][存量] #13 流向地图 design 列出的 region `name` 解析后从不绘制

- **位置**：`f_chart/doc/spec/add-f-chart-flow-map/design.md:5`；实现 `f_chart/src/FlowMapChart.cj:96`、`:99`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用」、§13「设计描述与实现作用不符」
- **证据**：静态确定 —— `name` 只在 `FlowMapRegion` 构造时存入（`:96`、`:99`），全文件无 `region.name` / `name` 的渲染引用（`grep -n "\.name" FlowMapChart.cj` 只命中赋值处）。design 把 `name` 列为解析产物并给出 `default: id` 的兜底，暗示它会被使用。
- **描述**：区域名称是流向地图的主要可读性来源（否则只有色块）；字段被接受但无任何效果，属于「文档/契约暗示了能力、实现未接线」。若设计上不打算画标签，应在 design 写明「`name` 仅供调用方/后续版本使用，不参与渲染」。
- **建议**：要么在 region 质心处补 `flow-map-label` 文本，要么从 design 的解析结构里删掉 `name`（或注明未使用）。

## 范围外提示（源码问题，不计入本部分统计）

> 以下是在核对文档承诺时撞见的实现缺陷，源文件不在本部分清单，只记一句，定级与修复归覆盖 `src/**` 的子轮。

- `f_chart/src/DumbbellChart.cj:152`：`frame.drawYAxis(kit, ticks, xScale)` 把横向比例尺当纵向用（全模块仅此一处），数值刻度贴在 `plot.x - 8`、y 取 x 像素值，`0..100` 的刻度大多落在绘图区外，且无纵向网格。
- `f_chart/src/EcdfChart.cj:180`：`let y = yScale.scale(points[position][1])` 计算后从未使用（与 #1 同源）。
- `f_chart/src/EcdfChart.cj:167-170`：`if (points.isEmpty()) { continue }` 在 `data` 非空已校验（`:59-61`）的前提下恒假。
- `f_chart/src/FlameChart.cj:167-204`：`validateValues` / `assignDepth` / `layoutNode` / `drawNode` 四层递归，深度 = 节点链长且无独立上限（`depth > total` 的上限就是节点数），长链输入（万级）仍有栈溢出面。
- `f_chart/src/FlameChart.cj:71-75`、`:99`、`:158-165`：id 去重与 `findNode` 均为线性扫描，建树 O(n²)。
- `f_chart/src/Flowchart.cj:185`：`parseEdges(root, nodes)` 的 `nodes` 形参在函数体内从未使用（§1 读了不用）。
- `f_chart/src/Flowchart.cj:108`、`:252-260`：`layout` 非法值（如 `"horizonal"`）静默按 `vertical` 渲染，无校验无告警。
- `f_chart/src/ErrorBarChart.cj:24`、`:94`、`:100`、`:120`：`ErrorBarPoint.label` 写入后从不读取（§1 死字段）。
- `f_chart/src/FlowMapChart.cj:234-249`、`f_chart/src/RaincloudChart.cj:320-335`、`f_chart/src/HeatMap.cj:167-180`：三处逐行同构的插入排序，仅元素类型不同（§2 重复逻辑）。
- `f_chart/src/ErrorBarChart.cj:241-264` 与 `:266-289`：`resolveYRange` / `resolveXRange` 逐行对齐，仅字段名与 8% / 5% 余量不同（§2 重复逻辑）。
- `f_chart/src/DumbbellChart.cj:19`、`EcdfChart.cj:19`、`FlameChart.cj:19`：`import std.math.*` 未见使用（三者只调用 `BarRenderer.cj:454,462` 的本地 `minFloat` / `maxFloat`，`grep -E "sqrt\(|pow\(|abs\(|floor\(|ceil\(|log10\("` 无命中）。

## 优化可行性方案

> 本部分无 `.cj`，以下方案针对核对文档时读到的实现，均无改前/改后基线，按规则只登记不排期。

### [CPU] ECDF 排序从插入排序换为标准库排序

- **现状**：`ecdfPoints`（`EcdfChart.cj:201-212`）调用 `sortRaincloud`（`RaincloudChart.cj:320-335`），后者是插入排序 O(n²)；ECDF 的输入规模就是样本数，生产上常见 1e4–1e5。
- **方案**：改用 `std.sort`（`sort` / `ArrayList.sort`）或对 `Array<Float64>` 原地排序；`ecdfPoints` 同时避免 `Array<Array<Float64>>` 的两层物化。
- **预期**：n=1e5 时比较次数从 ~5e9 量级降到 ~1.7e6 量级（复杂度推算，非实测收益）。
- **代价**：排序稳定性无影响（只用于取次序）；无 API 变化。
- **验证**：`cjpm bench -O2`，同输入逆序 1e5 样本，取中位数与离散度，对照现实现。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 火焰图 / 流向地图的线性查找改哈希索引

- **现状**：`FlameChart.cj:71-75` 逐个节点线性去重、`:99` 每个节点 `findNode` 线性查找 ⇒ 建树 O(n²)；`FlowMapChart.cj:91-95`、`:125-129`、`:196-197` 每条 flow 对 regions 做 2–4 次线性查找 ⇒ O(F×R)。
- **方案**：建 `HashMap<String, Int64>` 一次性索引（`Flowchart.cj:91-97` 已是这种写法，可直接参照），重复 id 由 `contains` 判定。
- **预期**：建树降到 O(n)、流量查找降到 O(F+R)；节点数 1e4、flow 1e3/region 1e2 时收益最明显（量级推算）。
- **代价**：多一份索引内存（O(n)/O(R)）；非法输入的错误路径需保持原 `path` 文案。
- **验证**：`cjpm bench -O2` 跑 1k/10k/50k 节点与 F=1k/R=200 的流向图，比较中位数与 P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 本部分不含代码，未提出性能结论。下表用于下一轮补数据，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ECDF 插入排序在 1e4+ 样本下成为渲染热点 | `f_chart/src/EcdfChart.cj:202`、`RaincloudChart.cj:320-335` | 排序自耗时占 `draw` 的比例 | `cjprof record` 渲染 1k/1e4/1e5 样本 ECDF，看 self time |
| 2 | 火焰图 O(n²) 去重/查找在节点数上万时显著 | `f_chart/src/FlameChart.cj:71-75,99` | 耗时随 n 的增长曲线 | `cjpm bench -O2`，n=1k/10k/50k 单链与宽树各一组 |
| 3 | 流程图 4 层以上越界的实际裁切比例（缺陷 6 的量化） | `f_chart/src/Flowchart.cj:248-261` | 不同层数/节点高度下超出 plot 的节点数 | 生成 3–8 层的图，解析 SVG 的 `node` 外接矩形与 `viewBox` 比较 |
| 4 | `horizontal` 布局箭头被遮的实际可见性 | `f_chart/src/Flowchart.cj:285-296` | 箭头顶点的实际坐标与节点边界 | 两节点 120×48 + `horizontal` 导图目视，并比对 `edge-arrow` 顶点 |

## 文件覆盖

> 与 `files/f_chart.part9.txt` 一一对应（该文件 20 行，全部为 `.md`）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-dumbbell/specs/chart-rendering/spec.md` | .md | ✅ | 连线/端点/范围/校验逐条核对；见 #2（负值口径）、#11（轴刻度 Scenario 无落点）、#12（错误分支缺失）；`max == min` 自动 ±1 与实现一致 |
| 2 | `f_chart/doc/spec/add-f-chart-dumbbell/tasks.md` | .md | ✅ | 4 项全 `[x]`，`DumbbellChart_test.cj` 存在；"范围"用例覆盖不足见 #11 |
| 3 | `f_chart/doc/spec/add-f-chart-ecdf/design.md` | .md | ✅ | 2% 两侧余量、y 轴缺省 0–1、2px 折线、不画点、图例按系列名均与实现一致；见 #1（阶梯错位）、#9（首点起点） |
| 4 | `f_chart/doc/spec/add-f-chart-ecdf/proposal.md` | .md | ✅ | `ecdfPoints` 存在且被 `EcdfChart_test.cj:70,83` 引用；Impact 所列两文件均存在 |
| 5 | `f_chart/doc/spec/add-f-chart-ecdf/specs/chart-rendering/spec.md` | .md | ✅ | `ecdfPoints` 的 `[x_i,(i+1)/n]` 与场景已由用例断言；轴覆盖、空数据、类型不符成立；阶梯几何与实现不符见 #1 |
| 6 | `f_chart/doc/spec/add-f-chart-ecdf/tasks.md` | .md | ✅ | 4 项全 `[x]`；用例覆盖计算/单点/空数据/类型，未覆盖 path 几何 |
| 7 | `f_chart/doc/spec/add-f-chart-error-bar/design.md` | .md | ✅ | 模型、类目定位、`parseDays`、`low<=y<=high`、8% 余量、0.3×槽宽且≤12px、3px 中心点逐项与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-error-bar/proposal.md` | .md | ✅ | `type` / 类名 / 默认类目轴 / 复用 `BandScale`+`LinearScale`+`ChartFrame`/`ChartTime` 与实现一致 |
| 9 | `f_chart/doc/spec/add-f-chart-error-bar/specs/chart-rendering/spec.md` | .md | ✅ | 4 线 8 帽 4 点、标签顺序、未知类目、`linear`/`time` 轴、边界倒置、中心越界均成立；见 #10（缺"恰好 1 个系列"） |
| 10 | `f_chart/doc/spec/add-f-chart-error-bar/tasks.md` | .md | ✅ | 4 项全 `[x]`；`ErrorBarChart_test.cj` 存在并覆盖绘制/校验 |
| 11 | `f_chart/doc/spec/add-f-chart-flame/design.md` | .md | ✅ | 两遍扫描、id/父/单根/`value>0`/子和校验、`frameHeight` 18、双向 y 公式均一致；见 #8（配色算法） |
| 12 | `f_chart/doc/spec/add-f-chart-flame/proposal.md` | .md | ✅ | `orientation`/`colorBy`/`frameHeight` 默认值、两个类名、`flameColorIndex` 均与实现一致 |
| 13 | `f_chart/doc/spec/add-f-chart-flame/specs/chart-rendering/spec.md` | .md | ✅ | 节点数/标签/方向/配色稳定/未知父/多根成立；"每节点一个矩形"在环输入下失效，见 #3 |
| 14 | `f_chart/doc/spec/add-f-chart-flame/tasks.md` | .md | ✅ | 4 项全 `[x]`；`FlameChart_test.cj` 覆盖节点/方向/配色/树校验，无环用例 |
| 15 | `f_chart/doc/spec/add-f-chart-flow-map/design.md` | .md | ✅ | `pathCentroid`、`points` 优先、0.6 透明度、`1+4·sqrt(v/max)`、升序覆盖、`from`/`to` 别名均一致；`name` 不绘制见 #13 |
| 16 | `f_chart/doc/spec/add-f-chart-flow-map/proposal.md` | .md | ✅ | `viewBox` 四元组、1–5px 线宽、两个类名、Impact 文件均存在；"带箭头"未实现见 #4 |
| 17 | `f_chart/doc/spec/add-f-chart-flow-map/specs/chart-rendering/spec.md` | .md | ✅ | 路径/宽度/底图/校验四组成立；`flowMapWidth(0)=1` 与"`value` MUST 大于 0"分属函数契约与输入校验，不冲突 |
| 18 | `f_chart/doc/spec/add-f-chart-flow-map/tasks.md` | .md | ✅ | 4 项全 `[x]`；`FlowMapChart_test.cj` 覆盖路径/宽度/底图/校验 |
| 19 | `f_chart/doc/spec/add-f-chart-flowchart/design.md` | .md | ✅ | 解析/分层/定位/形状逐条核对；见 #5（端点与箭头）、#6（层距）、#7（绘制顺序）；"循环依赖在迭代上限内稳定"实为每轮 +1 到上限，环输入会把节点推到绘图区外且无 Scenario |
| 20 | `f_chart/doc/spec/add-f-chart-flowchart/proposal.md` | .md | ✅ | 6 种 `shape`、3 种 `layout`、箭头与边标签均已实现，`ChartSvgKit` 已有 `ellipse` |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无 `.cj`。文档侧的正确性缺口已归入 §11（#1）、§13（#5–#9）、§14（#2–#4、#10–#13），不重复计入；文档不处理外部输入、无凭据、无注入面 |
| §1 死代码 | 0 | 20 个文件均为 `.md`，无可执行声明。机械动作改为核"文档承诺是否有产物"：6 个 `*_test.cj` 全部存在、5 个 `tasks.md` 的 4 项均 `[x]`；`ecdfPoints` / `flameColorIndex` / `flowMapWidth` 三个"内部函数"均存在且被非测试代码调用（`EcdfChart.cj:167`、`FlameChart.cj:217`、`FlowMapChart.cj:218`）。源码侧死字段/死局部/未用 import 记在「范围外提示」 |
| §2 重复逻辑 | 0 | 逐份比对本部分 6 份 `spec.md` 的 Requirement/Scenario 语义集合，互不重叠；共用句（"`type` 不匹配抛 `UnsupportedChart`"）属各变更独立验收快照，按 §2 误报边界不判重复。源码侧三处同构插入排序与两份同构 `resolve*Range` 记在「范围外提示」 |
| §3 空实现 | 0 | 各 `tasks.md` 无 `TODO`/`FIXME`；6 份 `spec.md` 的 Scenario 均有实现分支（#3 是"合法输入下分支缺失"，非空实现）；`Flowchart` 的 `case None => ()`（无 edges）与 `FlowMapChart` 的 `points` 缺省分支都是有语义的省略 |
| §4 栈溢出 | 0 | 文档未承诺递归深度与规模上限。实现侧 `FlameChart` 四层递归无独立深度上限（`depth > total` 的上限即节点数），属源码问题，见「范围外提示」与待验证假设 #2 |
| §5 OOM | 0 | 五份 spec 都未声明数据规模上限，也没有"全量物化"承诺；本部分无代码可判，是否给 `nodes`/`flows`/`data` 加上限归源码子轮 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/`cjpm bench` 数据，本部分也无代码；不提出热点结论，相关猜测进待验证假设 #1、#2 |
| §6.2 大粒度锁 | 0 | 无代码、无线程同步面；6 份文档均未声明线程安全契约 |
| §6.3 并发串行 | 0 | 同上；`Chart.draw` 在 `Chart.cj:24-27` 被声明为纯函数语义，无并发执行要求 |
| §6.4 低效算法 | 0 | 文档描述的都是 O(1)/O(n) 换算（`flameColorIndex` 单遍、`flowMapWidth` 开方、`pathCentroid`）；源码侧 O(n²) 建树/插入排序按规则降为「优化可行性方案（无基线）」与待验证假设，不计缺陷 |
| §7 降堆内存方案 | 0 | 无代码、无基线；`ecdfPoints` 的两层 `Array<Array<Float64>>` 物化未量化，未立方案 |
| §8 降 CPU 方案 | 2 | 见「优化可行性方案」两条（排序、哈希索引），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分无函数，local region 候选无从谈起；文档亦未提及 local mode |
| §11 现有代码的 BUG（存量） | 1 | #1（ECDF 阶梯错位，渲染数据错误）。其他读到的实现缺陷（哑铃图 `drawYAxis` 误用、火焰图递归与 O(n²)、流程图死形参、死字段等）不在本部分清单，记「范围外提示」，不重复计入 |
| §12 并发安全与锁粒度 | 0 | `Chart` 契约声明纯函数，6 份文档未声明共享状态；无共享可变状态可判 |
| §13 文档一致性 | 6 | #1（ECDF 阶梯）、#5（流程图端点/箭头）、#6（层距）、#7（绘制顺序）、#8（配色算法）、#9（ECDF 起点）——其中 #1 同时计入 §11；#6 按布局越界定为一般，其余为轻微 |
| §14 功能完备性与 README 覆盖 | 7 | #2（负值约束未登记）、#3（校验缺"全可达"）、#4（箭头未实现）、#10（缺"恰好 1 个系列"）、#11（验收落点缺失）、#12（错误分支缺失）、#13（`name` 未接线）；反向核对成立项：6 个 `type` 字符串在 `src/*.cj` 均有 `ChartConfig.parse(data, "<type>")`，`frameHeight` 18、ECDF 2%、误差线 8% 与 12px 帽宽上限、`1+4·sqrt` 线宽公式四个默认值与实现常量逐一相等 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；支撑阅读的 `ChartFrame.cj` / `ChartScale.cj` / `ChartConfig.cj` / `ChartException.cj` / `BulletChart.cj` / `RaincloudChart.cj` / `HeatMap.cj` 不计入覆盖数 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

## 总评

本部分覆盖 `f_chart/doc/spec/` 下 6 个新增图表的变更文档（20 个 `.md`）。文档形态统一（Requirement + WHEN/THEN Scenario + design/proposal/tasks 四件套），字段名、类名、默认值、错误 `kind` 绝大多数能与实现逐项对上：ECDF 的 2% 余量与 `(i+1)/n`、误差线的 8% 余量与「0.3×槽宽、最长 12px」端帽、流向图的 `1+4·sqrt(v/max)`、流程图 6 种形状、火焰图的 `frameHeight` 18 与双向 y 公式全部核对通过；6 个 `tasks.md` 的勾选与 6 个 `*_test.cj` 的存在一致。文档不是"写完就扔"的，这一点值得肯定。

风险集中在两处：

1. **唯一一条严重的渲染正确性问题出自 ECDF**：design 的阶梯定义与实现的循环顺序差一档，曲线在每个观测点都高一级、水平段整体左移，按图读分位数会系统性偏移；用例只数线条与断言 `ecdfPoints` 的数值，路径几何零覆盖。这条同时说明"文档写对了、实现没照做"的情形确实存在，验收口径需要落到 SVG 属性级断言上。
2. **校验类条款普遍比实现窄或比实现宽**：哑铃图（文档宽、实现窄，负值被拒）、误差线（实现多一条"恰好 1 个系列"）、火焰图（文档漏了"全可达"，环上节点被静默丢弃）、流程图（承诺箭头与边界相交，实际按短边半径截断，`horizontal` 下箭头整段消失）。这类漂移不会让测试变红，但会让使用者照文档写用例时踩空。

轻微项集中在设计文档的数值口径（层距 90、首点 y=0、字节累加散列）与验收落点（"范围"用例只数元素）。修法都只有几行，但建议与上一条合并处理：要么改文档、要么改代码，不要留成"文档说 A、代码做 B、测试只测 C"的三方状态。

存量缺陷 13 条（严重 1 / 一般 5 / 轻微 7；另有 11 条源码「范围外提示」不计入），是否纳入修复待用户决定；本报告只读文件，未做任何修改。
