# f_chart 模块审查报告（模块第 11/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（全模块 251 个 `.cj` + 444 个 `.md`；本部分 20 个 `.md`）
- **本部分覆盖**：`doc/spec/add-f-chart-{gantt,gauge,grouped-bar,heat-flame,heat-map,heatmap}` 六个已归档变更的 proposal / design / spec / tasks
- **基线**：工作区快照（sts/1.3.x，无 diff）
- **审查重点**：图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分报告，供主 Agent 合并；不含 `docs/review/` 模块报告）

> 说明：本部分 20 个文件全部是已归档变更的规格文档（`.md`），按 checklist §13 误报边界，归档变更按「当时结论是否自洽」核对，**不要求与当前实现逐字一致**；但凡文档声明的是对外 JSON 契约或渲染行为，则与实现做「承诺源 → 实现」对照，出现偏差即报。本部分不重复审查 `.cj`（由同模块其他子轮覆盖），代码侧顺带发现只列「范围外提示」。

## 发现

### [一般][存量] heat-map 规格与设计对「最小值的点取首色」冲突，非零最小值取不到首色

- **位置**：`f_chart/doc/spec/add-f-chart-heat-map/specs/chart-rendering/spec.md:30`（"最小值的点 MUST 取首色，最大值 MUST 取末色"）／`f_chart/doc/spec/add-f-chart-heat-map/design.md:10`（"比例 `value / maxValue`"）／实现 `f_chart/src/HeatMap.cj:156`
- **来源**：存量（快照模式，无基线可 diff）
- **判据**：§13 规格与实现漂移 + 文档内部矛盾；§11 契约与实现不符
- **证据**：静态确定 —— 归一化口径是 `ratio = value / maxValue`（`HeatMap.cj:156`），`heatFlameColor` 只在 `ratio == 0` 返回 `colorRange[0]`（`HeatFlameChart.cj:264-272`）。因此只要最小点的 value > 0，最小点 ratio = min/max ≠ 0，取到的是首色与中色之间的插值色，而不是首色；spec 的同一条 Scenario（"点值为最小值或最大值 → 分别使用首色与末色"）在 min > 0 时不成立。现有用例 `f_chart/src/HeatMap_test.cj:91` 之所以通过，是因为把最小值取成了 0。
- **建议**：二选一并统一：①保留 spec 语义，实现改 `ratio = (value - minValue) / (maxValue - minValue)`（`maxValue == minValue` 时取 0.5，与 heatmap 的口径对齐）；②保留 design 语义，把 spec 改成"按 value/maxValue 归一化，首色仅在 value 为 0 时出现"，并补一条 min > 0 的 Scenario。

### [一般][存量] gauge 阈值色带在「最后一个阈值 < max」时留下未着色扇区

- **位置**：`f_chart/doc/spec/add-f-chart-gauge/specs/chart-rendering/spec.md:28-31`（多个阈值要求依次覆盖 `[0,60]`、`[60,85]`、`[85,100]`）／`f_chart/doc/spec/add-f-chart-gauge/design.md:22`（"色带按阈值从 `min` 依次绘制到各阈值"）／实现 `f_chart/src/GaugeChart.cj:136-149`
- **来源**：存量（快照模式）
- **判据**：§11 契约与实现不符（边界条件缺失）；§13 规格未定义末段行为
- **证据**：静态确定 —— 阈值分支用 `bandStart = startAngle` 起步，循环体内每段画 `bandStart → 阈值角度`，循环结束即停（`GaugeChart.cj:137-148`），没有任何「最后阈值 → `endAngle`」的收尾段。spec 的覆盖要求只在"最后一个阈值恰好等于 max"（示例 60/85/100）时成立；用户给 `thresholds = [60, 85]`、`max = 100` 时，85–100 这一段完全不画（无阈值分支才画满量程，`GaugeChart.cj:128-135`），仪表盘出现白色空洞，读图直接误解量程。
- **建议**：循环结束后补一段 `bandStart → endAngle`（颜色取末阈值色或主题底色）；同时在 spec 增加 Scenario「最后阈值小于 max 时末段填充到 max」，把语义固定下来。

### [一般][存量] gantt 依赖校验只查 id 是否存在：重复 id 静默覆盖、自依赖被放过，依赖线会连错行

- **位置**：`f_chart/doc/spec/add-f-chart-gantt/specs/chart-rendering/spec.md:23-35`（"`dependsOn` 中的 id MUST 解析为其他任务"）／实现 `f_chart/src/GanttChart.cj:63-66`、`156-178`
- **来源**：存量（快照模式）
- **判据**：§11 边界/契约不符；§14 规格缺验收口径（无重复 id、无自依赖的 Scenario）
- **证据**：静态确定 —— `taskIndex[tasks[index].id] = index`（`GanttChart.cj:63-66`）对重复 id 是后者覆盖前者，且 `parseTasks`（同文件 `184-210`）没有唯一性校验；后续 `taskIndex[dependency]` 取到的是最后一条同 id 任务，依赖折线（`156-177`）因此指向错误行，而"悬空依赖"检查（`68-75`）只做 `contains`，重复 id 与自依赖都能通过。spec 只描述了"指向不存在的 id → InvalidValue"，没有任何一条覆盖这两种输入。
- **建议**：解析阶段用 `HashMap` 检测 id 重复并抛 `chartInvalidValue("tasks[i].id", …)`；`dependsOn` 命中自身 id 同样抛 `InvalidValue`（对应 spec 的"其他任务"）；spec 补两条 Scenario，让契约可测。

### [轻微][存量] gantt「进度 0–1 MUST 叠加子条」与实现 `progress > 0` 不一致

- **位置**：`f_chart/doc/spec/add-f-chart-gantt/specs/chart-rendering/spec.md:16`／实现 `f_chart/src/GanttChart.cj:141`
- **来源**：存量（快照模式）
- **判据**：§13 文档与实现不一致（边界表述）
- **证据**：静态确定 —— spec 写"`progress` 为 0–1 时 MUST 叠加 `class="progress"` 的子条"，实现条件是 `task.progress > 0.0`，`progress = 0` 时不输出子条。后果仅是 `progress=0` 时缺少宽度为 0 的空矩形，视觉无差异，但验收口径与文档相反。
- **建议**：spec 改为"`0 < progress ≤ 1`"，或在 Scenario 中明确 `progress = 0` 不产生 `progress` 元素。

### [轻微][存量] gauge 中心数值的样式描述（标题字号 + 加粗）与实现不符

- **位置**：`f_chart/doc/spec/add-f-chart-gauge/design.md:27`（"中心数值使用标题字号加粗色"）／实现 `f_chart/src/GaugeChart.cj:162-169`、`f_chart/src/ChartSvgKit.cj:95-117`
- **来源**：存量（快照模式）
- **判据**：§13 文档与实现不一致
- **证据**：静态确定 —— 实现取 `valueSize = config.theme.fontSize + 12.0`（默认 12 + 12 = 24），而配置里的标题字号是 `titleFontSize`（默认 18，`ChartConfig.cj:192`）；颜色用 `config.theme.textColor` 而非 `titleColor`；`ChartSvgKit.text` 的形参只有 `size / color / anchor / className / rotate`，没有 `font-weight`，实现也没有写 `font-weight` 属性。三项（字号来源、颜色来源、"加粗"）都与 design 不一致。
- **建议**：design 改成与实际一致（"数值字号 = 主题字号 + 12，颜色取主题文字色"），或实现改用 `titleFontSize` / `titleColor` 并为 `kit.text` 增加 weight 形参；不要让设计文档承诺一个 API 表达不了的样式。

### [轻微][存量] gauge 未限定角度跨度，超过 360° 时单段圆弧无法表达

- **位置**：`f_chart/doc/spec/add-f-chart-gauge/design.md:21`（`large-arc-flag` 按 `abs(end - start) > 180` 判定）／`f_chart/doc/spec/add-f-chart-gauge/specs/chart-rendering/spec.md:43-46`（只校验 `startAngle < endAngle`）／实现 `f_chart/src/GaugeChart.cj:198-225`
- **来源**：存量（快照模式）
- **判据**：§13 规格未定义上界 + §11 边界校验缺失
- **证据**：静态确定 —— `gaugeArcPath` 用一条 `A` 命令画外弧、一条画内弧；SVG 单条椭圆弧最多描述 360°，跨度 ≥ 360° 时端点重合或需要多段才能描出。当前只校验 `startAngle < endAngle`（`GaugeChart.cj:47-49`），对 `startAngle = -120, endAngle = 300`（跨度 420°）既不报错也画不对：`largeArc` 置 1 也只能画到约 359.99°，端点重合时退化为不可见/极窄扇段，而指针角度却按 420° 线性映射，指针与色带脱节。design 只讨论了 ±180° 的 `large-arc-flag`，没有讨论跨度上界。
- **建议**：校验 `endAngle - startAngle <= 360` 并抛 `chartInvalidValue`（推荐，语义最清晰）；若确需 > 360° 的螺线，则按每 ≤180° 分段生成多段 `A` 命令，并在 spec 补对应 Scenario。

### [轻微][存量] heat-flame 的 `colorRange` 元素个数口径三处不一致，4 色以上被静默丢弃

- **位置**：`f_chart/doc/spec/add-f-chart-heat-flame/proposal.md:12`（"`colorRange` 为 `[冷, 热]` 或 `[冷, 中, 热]`"）／`f_chart/doc/spec/add-f-chart-heat-flame/specs/chart-rendering/spec.md:35`（"`colorRange` MUST 至少两个合法颜色"）／`f_chart/doc/spec/add-f-chart-heat-flame/design.md:16`（"三个及以上颜色：复用 `heatmapColor(ratio, c0, c1, c2)`"）／实现 `f_chart/src/HeatFlameChart.cj:271-272`
- **来源**：存量（快照模式）
- **判据**：§13 文档与实现口径不一致
- **证据**：静态确定 —— proposal 限定 2 或 3 色；spec 只要求 ≥2、不设上限；design 说 ≥3 时取前三色；实现 `if (colors.size >= 3) { return heatmapColor(value, colors[0], colors[1], colors[2]) }`，其余颜色无提示地丢弃。
- **描述**：同一字段在三份文档里给了三个取值范围。按 spec 字面，传 4 色是合法输入，实现与 design 只使用前 3 色，第 4 色起静默失效；使用者按「多色渐变」配置时既拿不到预期配色，也拿不到任何错误。
- **建议**：把 spec 收敛为「2 或 3 色，多于 3 色时只使用前三色」并同步 proposal；或对 `size > 3` 抛 `InvalidValue`（显式拒绝优于静默截断）。选定后三处一起改。

### [轻微][存量] heat-flame 校验 Requirement 列了 6 条 MUST，只给 1 个验收场景

- **位置**：`f_chart/doc/spec/add-f-chart-heat-flame/specs/chart-rendering/spec.md:47-54`
- **来源**：存量（快照模式）
- **判据**：§14 验收口径缺失
- **证据**：静态确定 —— 第 49 行一次列出「`nodes` 非空 / id 唯一 / `parent` 指向存在节点 / 恰好一个根 / `value > 0` / 父节点 value 不小于子节点 value 之和」六条 MUST，其下只有「未知父节点」一个 Scenario。
- **描述**：另外五条约束没有场景，等于没有验收依据。重复 id、两个根、`value = 0`、父值小于子值之和这四类输入在规格层无期望行为，重构时最容易静默退化（例如父值校验写成 `>` 而非 `>=` 之和）。本次实测口径下 `HeatFlameChart.cj` 的 `validateValues` 有对应校验，但规格并未把它固化成可回归的验收条目。
- **建议**：按约束逐条补 Scenario（每种输入 → `ChartException(InvalidValue)`，并写出报错字段路径），至少覆盖「重复 id」「两个根」「`value = 0`」「父值 < 子值之和」四条。

### [轻微][存量] heat-map proposal 记录的产出文件 `HeatMapChart.cj` 在仓库中不存在

- **位置**：`f_chart/doc/spec/add-f-chart-heat-map/proposal.md:26`／实现 `f_chart/src/HeatMap.cj:37`
- **来源**：存量（快照模式）
- **判据**：§13 路径失效 / §14 能力未接入（索引与实际文件名不一致）
- **证据**：静态确定 —— proposal 的 Impact 写「新增 `src/HeatMapChart.cj`、`src/HeatMapChart_test.cj`」；`f_chart/src` 下实际是 `HeatMap.cj` / `HeatMap_test.cj`，类名仍为 `public class HeatMapChart`（`HeatMap.cj:37`），全目录无 `HeatMapChart.cj`。
- **描述**：文件名与类名不一致本身可接受（同目录另有 `HeatmapChart.cj` 承载矩阵热力图），但 proposal 记录的路径不存在，追溯变更会指向空文件。叠加 `heat-map` 与 `heatmap` 两个变更只差一个连字符、类名 `HeatMapChart` / `HeatmapChart` 只差大小写，排障与检索容易被带偏。
- **建议**：把 proposal 的 Impact 改为 `src/HeatMap.cj` / `src/HeatMap_test.cj`，并在模块 README 的类型表里写明 `heat-map`（地理散点）与 `heatmap`（矩阵）的区别。

### [轻微][存量] heat-map spec 未记录 `viewBox` 与 `regions` 的契约

- **位置**：`f_chart/doc/spec/add-f-chart-heat-map/specs/chart-rendering/spec.md:37-49`／`f_chart/doc/spec/add-f-chart-heat-map/proposal.md:10`／实现 `f_chart/src/HeatMap.cj:46-54`、`:63-77`
- **来源**：存量（快照模式）
- **判据**：§14 契约缺失面 / §13 承诺与实现对照
- **证据**：静态确定 —— spec 的「热力地图校验」只覆盖 `points` / `value` / `radius` / `type`；proposal 只说「`viewBox` 为 `[x, y, w, h]`」「`regions` 为底图路径」；实现强制 `size == 4` 且 `w > 0`、`h > 0`（否则 `chartInvalidValue`），缺省时回落到 `config.width/height`，`regions` 缺省为空数组。
- **描述**：`viewBox` 是该图唯一的坐标系入口，长度不对或宽高非正会直接抛异常，但规格既没写这条拒绝路径，也没写缺省行为；`regions` 可缺省同样没有承诺。使用者按 spec 无法判断「不传 `viewBox`」是合法还是错误。
- **建议**：在「热力地图校验」补两条 ——「`viewBox` 提供时 MUST 为 4 个数字且 `w > 0, h > 0`，否则 `InvalidValue`；缺省取 `width` / `height`」「`regions` 可缺省，缺省时只绘制热力点」。

### [轻微][存量] grouped-bar spec 的场景标题与正文对不上（「两组三系列」vs「2 个系列、3 个类目」）

- **位置**：`f_chart/doc/spec/add-f-chart-grouped-bar/specs/chart-rendering/spec.md:9`（标题）、`:11`（WHEN 子句）
- **来源**：存量（快照模式）
- **判据**：§13 文档表述与验收内容不一致（可读性）
- **证据**：静态确定 —— 标题写「两组三系列」，正文写「输入 2 个系列、3 个类目」。柱数 6 在两种读法下都成立（2×3 与 3×2），断言不会变红。
- **描述**：同一场景里「组 / 类目」与「系列」互换。因为断言只是数 6 个 `rect`，错误被测试掩盖，只会让后来读 spec 的人把「按系列数均分槽位」理解反（design 的分槽公式按系列数切分类目槽位）。
- **建议**：标题改为「两个系列、三个类目」，并在正文补一条「同类目内两柱 `x` 差 ≥ `barWidth`」把「不重叠」量化，而不是只断言 `x` 不同。

### [轻微][存量] gauge 阈值下界口径三处不一致：`(min, max]` / 「超出量程」/ `<= previous`

- **位置**：`f_chart/doc/spec/add-f-chart-gauge/design.md:11`／`f_chart/doc/spec/add-f-chart-gauge/specs/chart-rendering/spec.md:48-51`／实现 `f_chart/src/GaugeChart.cj:55`、`:64-66`
- **来源**：存量（快照模式）
- **判据**：§13 文档与实现边界不一致
- **证据**：静态确定 —— design 写「每项 `value` 必须严格递增且落在 `(min, max]`」；spec 的验收句只写「阈值序列不是严格递增，或超出量程」；实现以 `var previous = min` 起步、`if (value <= previous)` 判递增，等价于拒绝 `value <= min`。
- **描述**：按 spec 字面，min=0 时 `thresholds = [0, 60]` 属于「严格递增且在量程内」应当通过；按 design 与实现，`0` 不在 `(min, max]`，直接抛 `InvalidValue`。而「从量程下限开始分段」正是使用者最容易写出的输入，口径相反会让用例与实现互相打架。
- **建议**：把 spec 的「超出量程」改为「不在 `(min, max]` 内（`<= min` 或 `> max`）」，与该文件「多个阈值」场景（60/85/100）的分段语义对齐；若要支持从 `min` 起的分段，则改 design 与实现，两者只能留一个口径。

## 优化可行性方案

本部分 20 个文件全部为规格文档，自身没有运行期堆分配与 CPU 开销，**无方案**（0 条）。文档中出现的复杂度线索属代码文件，已放「待验证假设」，不计入优化方案统计。

## 待验证假设

> 无测试数据，不进 `todo.md` / `tasks.md`；位置在 `.cj`（本模块其他子轮范围），此处只作为线索登记。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 热火焰图节点关系构建为 O(n²)（逐节点线性查重 + 线性 `findNode`），大节点数时成为渲染主耗时 | `f_chart/src/HeatFlameChart.cj:78-82`、`115`、`181-188` | n 节点的 `draw` 耗时与自耗时占比 | `cjprof record` 渲染 1k / 10k / 50k 节点的火焰图，取自耗时占比；`cjpm bench -O2` 对照 `HashMap` 版本 |
| 2 | 热力地图点排序用手写插入排序（最坏 O(n²)），点数多时劣于标准库排序 | `f_chart/src/HeatMap.cj:167-182` | points 规模与实际耗时 | `cjpm bench -O2`，100 / 1k / 10k 点，记录中位数与离散程度 |
| 3 | 热火焰图递归（校验 / 深度赋值 / 布局 / 绘制）深度等于树高、上界为节点数，深链输入可能栈溢出 | `f_chart/src/HeatFlameChart.cj:190-256` | 崩溃阈值（多深会崩） | 构造 1k / 5k / 10k 层单链节点渲染，记录异常类型与深度 |

### 范围外提示（`.cj`，不计入本部分统计）

- `HeatFlameChart.cj:292-296` `mixHeatFlameChannel` 与 `HeatmapChart.cj:250` 起的 `mixHeatmapChannel` 是同一套通道插值（仅名字不同），属 §2 重复逻辑，建议合并到一处（heat-flame 的三色分支已经复用 `heatmapColor`，两色分支却另写一份）。
- 默认三色字面量 `["#ffffcc", "#fd8d3c", "#800026"]` 在 `HeatFlameChart.cj:130-133` 与 `HeatMap.cj:104-107` 各写一份，可提为常量。
- `BarRenderer.cj:211-238` 的 `case _ =>` 分支体整体缩进比外层少 8 个空格（`for` 从第 13 列开始），行为无影响但破坏可读性，疑为重构残留。
- `GanttChart.cj:195-199` 的日期校验依赖 `ChartTime.parseDays`，后者只检查长度 ≥ 10 与前两位分隔符（`ChartTime.cj:28-31`），`2026-01-05xyz` 会被静默接受，属边界校验缺失（列此处供对应子轮取证）。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-gantt/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #3、#4 |
| 2 | `f_chart/doc/spec/add-f-chart-gantt/tasks.md` | .md | ✅ | 勾选项与 `GanttChart.cj` / `GanttChart_test.cj` 存在性一致 |
| 3 | `f_chart/doc/spec/add-f-chart-gauge/design.md` | .md | ✅ | 见发现 #5、#6、#12 |
| 4 | `f_chart/doc/spec/add-f-chart-gauge/proposal.md` | .md | ✅ | 与 design/spec 口径一致（默认量程、角度、阈值色带） |
| 5 | `f_chart/doc/spec/add-f-chart-gauge/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #2、#6、#12 |
| 6 | `f_chart/doc/spec/add-f-chart-gauge/tasks.md` | .md | ✅ | 勾选项与 `GaugeChart.cj` / `_test.cj` 一致；3.1 的"签名 target/release 全部 ELF"无命令可复现，属措辞含糊 |
| 7 | `f_chart/doc/spec/add-f-chart-grouped-bar/design.md` | .md | ✅ | 布局公式（slot / barWidth / 居中）与 `BarRenderer.cj:202-238`、`groupedBarX` 逐项一致 |
| 8 | `f_chart/doc/spec/add-f-chart-grouped-bar/proposal.md` | .md | ✅ | 四种 `BarMode` 与 `BarMode` 枚举一致；`BarChart` 确实改为 `BarMode.Simple` |
| 9 | `f_chart/doc/spec/add-f-chart-grouped-bar/specs/chart-rendering/spec.md` | .md | ✅ | 6 柱、共享 y 轴、图例、校验三条均与实现一致；场景标题与正文不符，见发现 #11 |
| 10 | `f_chart/doc/spec/add-f-chart-grouped-bar/tasks.md` | .md | ✅ | 勾选项与 `GroupedBarChart.cj` / `BarRenderer.cj` 一致 |
| 11 | `f_chart/doc/spec/add-f-chart-heat-flame/design.md` | .md | ✅ | 树规则、热度字段、颜色、0.6 白字阈值与 `HeatFlameChart.cj` 一致；`colorRange` 个数口径见 #7 |
| 12 | `f_chart/doc/spec/add-f-chart-heat-flame/proposal.md` | .md | ✅ | class 名与 `heatFlameColor` 存在性一致；2/3 色口径见 #7 |
| 13 | `f_chart/doc/spec/add-f-chart-heat-flame/specs/chart-rendering/spec.md` | .md | ✅ | 两端色 / 三色中点 / 非数字热度 / 父值约束与实现一致；校验场景仅 1 条，见 #8 |
| 14 | `f_chart/doc/spec/add-f-chart-heat-flame/tasks.md` | .md | ✅ | 勾选项与产物一致 |
| 15 | `f_chart/doc/spec/add-f-chart-heat-map/design.md` | .md | ✅ | 见发现 #1（与 spec 归一化口径冲突） |
| 16 | `f_chart/doc/spec/add-f-chart-heat-map/proposal.md` | .md | ✅ | 默认 radius 24、class 名、`SvgViewBox` 复用与实现一致；Impact 文件名不存在，见 #9 |
| 17 | `f_chart/doc/spec/add-f-chart-heat-map/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #1；`viewBox` / `regions` 契约缺失见 #10 |
| 18 | `f_chart/doc/spec/add-f-chart-heat-map/tasks.md` | .md | ✅ | 勾选项与 `HeatMap.cj` 一致 |
| 19 | `f_chart/doc/spec/add-f-chart-heatmap/design.md` | .md | ✅ | 归一化、三色插值、布局、图例取中色均与 `HeatmapChart.cj` 一致 |
| 20 | `f_chart/doc/spec/add-f-chart-heatmap/proposal.md` | .md | ✅ | 默认蓝梯度（`#f7fbff/#6baed6/#08306b`）、`cellGap` 1、`showValues` false 一致 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分为纯文档，无代码可判；行为类问题按 §11 / §13 / §14 归类，避免重复计数 |
| §1 死代码 | 0 | 文档无符号可判；已核对 6 个变更的 tasks 勾选项均有对应产物（`GanttChart` / `GaugeChart` / `GroupedBarChart`+`BarRenderer` / `HeatFlameChart` / `HeatMapChart` 及各自 `_test.cj` 均在 `f_chart/src/`），无指向不存在文件的条目；文档内无被后续段落完全取代的废弃章节 |
| §2 重复逻辑 | 0 | 已把 6 组 design/proposal/spec 压成「输入→输出→约束」逐条比对：默认 `colorRange` 三色在 heat-flame 与 heat-map 两份规范里重复出现，但归一化口径不同（前者 `heat/maxHeat`、后者 `value/maxValue`），属不同语义，不能合并；通用校验句（`UnsupportedChart` / `MissingField`）是 OpenSpec 增量必需的重复，且各变更边界不同，按「刻意独立演进」不判。同一字段口径分叉（`colorRange` 个数）按口径漂移记在 #7，不计重复。代码侧真重复见「范围外提示」第 1 条 |
| §3 空实现 | 0 | 20 个文件无 `TODO` / `FIXME` / "暂不实现"；spec 的每条 Requirement 都能在实现里找到对应分支 |
| §4 栈溢出 | 0 | 文档层无递归描述；实现侧的树递归（深度上界为节点数）已登记为待验证假设 #3，未在本部分定性 |
| §5 OOM | 0 | 文档没有承诺任何规模上限，实现按输入线性物化（`points` / `nodes` / 矩阵），未发现"全局容器只增不减"型契约；无拒绝路径的缺失未被文档承诺，故不构成 OOM 发现 |
| §6.1 热点瓶颈 | 0 | `scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`，不含 f_chart 渲染基准；无 profile / bench 数据，热点不成立，已转待验证假设 #1、#2 |
| §6.2 大粒度锁 | 0 | 本部分涉及的渲染路径（各 `Chart.draw`）全为局部变量 + 一次性字符串构建，无锁 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理窗口 |
| §6.4 低效算法 | 0 | 文档层无算法描述可判；实现层 O(n²)（节点查重、插入排序）缺测量数据，已列待验证假设 |
| §7 降堆内存方案 | 0 | 无分配量 / 峰值内存基线，按铁律不写成方案 |
| §8 降 CPU 方案 | 0 | 同上，无 `-O2` 改前改后对照 |
| §9 local mode 可行性 | 0 | 渲染为"读 JSON → 拼 SVG 字符串"，中间对象全在 `draw` 内且随返回值逃逸（`String`），未给峰值内存对照，不能下结论 |
| §11 现有代码的 BUG（存量） | 2 | heat-map 取色与 spec 不符（#1）、gauge 尾段空白（#2）；另已核对 gantt 时间轴方向（`LinearScale(minDay, maxDay, right, x)` 使 min 落在左端，正确）、`rowHeight` 除零（tasks 非空）、`gaugeAngleForValue` 的 `max <= min` 兜底，均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 六个 `Chart` 实现均为无共享状态的纯函数（`Chart` 实例无字段，`draw` 内全部局部变量），无可指出的共享路径 |
| §13 文档一致性 | 7 | gauge 中心数值样式（#5）、gauge 角度跨度未定义（#6）、gauge 阈值下界口径（#12）、gantt progress=0 表述（#4）、heat-flame `colorRange` 个数（#7）、heat-map proposal 文件名失效（#9）、grouped-bar 场景标题与正文不符（#11）；其余默认值、class 名、公式逐项核对一致 |
| §14 功能完备性与 README 覆盖 | 3 | gantt 规格缺「重复 id / 自依赖」验收口径，实现静默错连（#3）；heat-flame 六条校验约束只有 1 个场景（#8）；heat-map 缺 `viewBox` / `regions` 契约（#10）。本部分不含 `README.md`（在模块其他子轮），未做 README 符号覆盖对照 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件、无未读项 |

## 模块统计

> 仅统计本部分 20 个文件。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 12 条（全部为存量，快照模式无本次改动），是否纳入修复待用户决定。

## 总评

本部分 20 个归档规格文档整体自洽：class 名、默认值（`radius` 24、`cellGap` 1、`showValues` false、角度 −120/120、量程 0/100）、坐标与布局公式（分组柱 `slot`/`barWidth`/居中、热火焰图宽度归一化、热力图单元格 `cellGap/2` 内缩）与实现逐项对得上，tasks 勾选项也都有真实产物，没有"承诺了但没实现"的能力。

风险集中在**规格未定义的边界与字段口径分叉**，且每一处都直接对应一个可复现的渲染缺陷：gauge 最后一个阈值小于 max 时色带留空（#2）；gantt 重复 id / 自依赖未被拒绝导致依赖线连错行（#3）；heat-map 的"最小点取首色"与 `value/maxValue` 归一化互斥，非零最小值取色不符（#1）。三条都不是崩溃级，但对使用者是"图看起来对、实际读错"的错误，属应排期修复的一类。

轻微九条分为两组，可随一轮文档整理批量收口：**口径分叉**（gauge 阈值下界 `(min, max]` vs「超出量程」，#12；heat-flame `colorRange` 允许 2/3/≥2 三种说法且 4 色以上静默截断，#7；gauge 数值字号/加粗，#5；gantt `progress=0` 表述，#4；gauge 角度跨度 >360°，#6）与**验收场景缺失 / 表述笔误**（heat-flame 六条约束只给 1 个场景，#8；heat-map 缺 `viewBox` / `regions` 契约，#10；heat-map proposal 文件名 `HeatMapChart.cj` 不存在，#9；grouped-bar 场景标题「两组三系列」与正文互换，#11）。它们不会立刻崩，但会让下一轮按 spec 补测试的人写出与实现相反的断言。

性能与内存方面没有可下的结论：本部分没有 profile 或基准数据，O(n²) 查重与插入排序只作为待验证假设登记，未计入缺陷。
