# f_chart 模块审查报告（第 17/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个文件，全部为 `doc/spec/**` 归档变更文档，无 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑（本部分落在归档四件套的**规格层面**：验收口径是否自洽、是否与实现一致、承诺的符号/测试是否存在）
- **报告版本**：v1（与同日抽样版 `docs/review/2026-11-28/f_chart.md` 无合并关系，由主 Agent 合并为 `f_chart_v2.md`）

## 发现

### [严重][存量] 象形图图标数量没有上限，`value` / `unit` 可把输出放大到任意规模

- **位置**：
  - `f_chart/doc/spec/add-f-chart-pictogram/specs/chart-rendering/spec.md:21`（"MUST 为每个数据项输出 `pictogramCount(value, unit)` 个 `pictogram-icon`"）
  - `f_chart/doc/spec/add-f-chart-pictogram/design.md:5`（`pictogramCount = ceil(value / unit)`，只有 `value <= 0` 才返回 0）
  - 实现（范围外、供合并去重）：`f_chart/src/PictogramChart.cj:123`（`let iconCount = pictogramCount(item.value, unit)`）、`f_chart/src/PictogramChart.cj:125`（`while (drawn < iconCount)`）、`f_chart/src/PictogramChart.cj:145`（`pictogramCount`）
- **来源**：存量（快照模式无基线；`git log` 显示 `design.md` 与 `PictogramChart.cj` 同属 `213900cf3` 2026-11-08 "feat(f_chart): M74 象形图"）
- **判据**：review-checklist §5（无界容器 / 按不可信长度预分配 / 无拒绝路径）＋ §11（边界未处理）；f_chart 专项「OOM、资源与内存」
- **证据**：静态确定 —— 规格对 `unit` 只要求 `> 0`、对 `value` 只要求 `>= 0`（`spec.md:44`），两者都直接来自 chart JSON；`pictogramCount` 无上限、绘制循环也不截断，`PictogramChart.cj` 全文没有数量上限常量，`ChartConfig.cj:182` 对画布只校验 `width/height > 0`，没有任何数据量/尺寸上限
- **描述**：`value=1000000`、`unit=0.001` 这种完全合法的输入会得到 `ceil(1e9)` 个图标，每个图标是一条 200–300 字符的 `<path>`，单张 SVG 可达数百 GB 量级；`value=1e7`、`unit=1` 也有约 10⁷ 条 path（GB 级）。JSON 请求体可以很小（`"value": 1000000` 只有十几个字节），因此不存在「报文大才会触发」的自然门槛。只要 chart JSON 来自请求体 / 模型输出（`Chart.draw(data: JsonObject)` 是公开契约，库侧无法假设可信），就是一个渲染线程被长时间占满直至 OOM 的入口。设计文档还明确写了「超出绘图区高度的内容不额外缩放」（`design.md:12`），即不做任何降采样，放大了后果。
- **建议**：在 `spec.md:44` 的校验清单增加「单个数据项的图标数 MUST ≤ N（建议 500–1000）」与超限行为（抛 `ChartException(InvalidValue)`，或按 `unit` 自动放大并给出提示）；`design.md:5` 补上限常量与拒绝规则；实现侧在 `pictogramCount` 返回后校验，避免进入绘制循环。仅限制 `columns` 不解决问题（列数只影响换行，不限制总数）。

### [一般][存量] `pr` / `probability` 规格的校验清单漏掉「`series` 必须恰好 1 个」

- **位置**：
  - `f_chart/doc/spec/add-f-chart-pr/specs/chart-rendering/spec.md:42`（Requirement: PR 校验，42–49 行只写了 x/y、baseline、data 非空、series 缺失、type 不匹配）
  - `f_chart/doc/spec/add-f-chart-probability/specs/chart-rendering/spec.md:37`（Requirement: 概率图校验，37–44 行同样只有 data、series 缺失、type 不匹配）
  - 实现（范围外）：`f_chart/src/PrChart.cj:45`、`f_chart/src/ProbabilityChart.cj:39`（`seriesItems.size != 1` → `InvalidValue`）
- **来源**：存量（`git log`：`add-f-chart-pr` 为 `afb917d1e` M48 PR 曲线，`add-f-chart-probability` 为 `8035c9460` M42 概率图）
- **判据**：review-checklist §2（近似重复：同一模板的校验条目在一处少一条约束，属"行为漂移"）＋ §13（规格与实现不一致）
- **证据**：静态确定 —— 同批次的 `pie` spec:34 与 `qq` spec:30 都写了「`series` MUST 恰好 1 个」，`pr` / `probability` 的同类段落没有；两份实现都强制 1 个系列并抛 `InvalidValue`，两份 spec 的验收场景里也没有多系列用例
- **描述**：规格自称是实现的验收基线，但按它写用例不会覆盖「多条 series」这条已实现的错误分支；反过来，使用者按 spec 理解会以为多系列合法。四份 spec 的校验段是同一模板复制出来的，`pr` / `probability` 两份在复制时漏了这条边界，属于典型的近似重复导致的口径漂移。
- **建议**：在两份 spec 的校验段补「`series` MUST 恰好 1 个」，并各加一条「两条 series → `ChartException`，`kind = InvalidValue`」的场景；若产品上确实要支持多系列，则改实现而不是改文档。

### [轻微][存量] `pie` 规格未定义 0 值扇区，与「每个数据项都输出扇区/标签」的措辞冲突

- **位置**：`f_chart/doc/spec/add-f-chart-pie/specs/chart-rendering/spec.md:7`（"按数值占比把圆周分成扇区，每个扇区输出 `pie-slice`"）、`:16`（"每个扇区 MUST 输出 `pie-label`"）、`:34`（只拒绝负值与总和为 0）；实现（范围外）：`f_chart/src/PieChart.cj:117`（`if (sweep > 0.0)` 才画路径与标签）
- **来源**：存量（`git log`：`0921e273c` "feat(f_chart): M31 饼图"）
- **判据**：review-checklist §11（空值/零值边界）＋ §13（规格与实现漂移）
- **证据**：静态确定 —— `[10, 0, 5]` 通过 `spec.md:34` 的全部校验（无负值、总和 > 0），按 `:7` 应有 3 个 `pie-slice`、按 `:16` 应有 3 个 `pie-label`；实现跳过 0 值扇区，实际只有 2 个。`:9-12` 的 scenario「4 个类别 → 4 个 `pie-slice`」在含 0 值时不成立。
- **描述**：0 值数据项是图表里很常见的输入（某类目本期为 0），规格既没写"跳过"，也没写"输出零面积扇区"，验收口径因此二义；现有测试（`PieChart_test.cj:62`）只用正值数据，掩盖了这一点。
- **建议**：在 `spec.md` 的扇区要求里显式写「`value` 为 0 的数据项不生成 `pie-slice` 与 `pie-label`」，并补一条含 0 值的 scenario；这同时把实现的 `sweep > 0.0` 分支变成有文档依据的行为。

### 范围外提示（不计入本轮统计）

- `f_chart/doc/chart-json-spec.md:307` 写「`yAxis.max` 固定为 100」，与 `add-f-chart-percent-stacked-bar` spec:21「显式 `yAxis.min` / `yAxis.max` 可覆盖」及实现 `BarRenderer.cj:379`（`resolvePercentRange` 读取 `axis.max`）矛盾，需由覆盖该文件的部分处理。
- `f_chart/doc/chart-json-spec.md:1248` 把 `innerRadius`（默认 0）列为 `pie` 专属字段，但 `PieChart.cj` 全文不读该字段（只有 `DonutChart.cj:73` 使用），属于文档承诺与实现不一致。

## 优化可行性方案

### [CPU] `pr` / `probability` 的排序从插入排序改为 O(n log n)

- **现状**：`add-f-chart-pr/design.md:6` 明确规定「稳定插入排序按 x 升序」；`PrChart.cj:197-212` 与 `ProbabilityChart.cj:156-171` 都是插入排序实现，单次 `draw` 调用一次，n = 数据点数（来自 chart JSON，除报文大小外无其它约束），最坏 O(n²) 次比较与元素搬移。
- **方案**：改用标准库排序（实现前先按 `cangjie-doc-lookup` 核对 `std.sort` 的稳定性与签名；`pr` 需要稳定排序，等 x 的点必须保持输入顺序），排序后仍复用现有的点数组，不改绘图路径。
- **预期**：复杂度从 O(n²) 降到 O(n log n)；端到端收益取决于排序在渲染总耗时中的占比，未测前不给百分比。
- **代价**：`pr` 的稳定性若标准库不保证，需要自行带索引排序（`(x, 原索引)` 比较）以避免等 x 点重排；`probability` 只需数值排序，代价更低。
- **验证**：`cjpm bench -O2`，同输入 n=1e3 / 1e4 / 1e5，各跑多轮取中位数与离散程度，与改前对照；同时用 `cjprof record` 确认 `sortPoints` / `sortValues` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序在 1e4–1e5 个工作点时会成为 PR/概率图渲染的主要耗时 | `f_chart/doc/spec/add-f-chart-pr/design.md:6`、`f_chart/src/PrChart.cj:197`、`f_chart/src/ProbabilityChart.cj:156` | 排序自耗时占比、端到端耗时随 n 的增长曲线 | `cjprof record` 渲染 1e3/1e4/1e5 点的 PR 图各 20 次，取 self time |
| 2 | 象形图的逐图标字符串拼接（每次 10+ 次 `formatSvgNumber` + 连接）在中大规模下分配量偏高 | `f_chart/src/PictogramChart.cj:130`、`f_chart/src/PictogramChart.cj:153` | 每千图标分配字节数、峰值 RSS | 渲染 1e4 / 1e5 图标，`cjprof heap` + `getAllocatedHeapSize()` + RSS |
| 3 | 大量 `ArrayList → toArray()` 拷贝在多图批量渲染时有可见分配占比 | `f_chart/src/PieChart.cj:84`、`f_chart/src/BarRenderer.cj:112` | 单次 `draw` 的分配量与 GC 次数 | 批量渲染 1000 张同构图表，记录分配总量与 GC 停顿 |

## 文件覆盖

> 与 `files/f_chart.part17.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/specs/chart-rendering/spec.md` | .md | ✅ | 归一化/轴/空类目三条验收口径与实现一致；轴口径与 `chart-json-spec.md:307` 冲突（范围外提示） |
| 2 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/tasks.md` | .md | ✅ | 勾选项与 `BarRenderer` `PercentStacked` / `percentStackedValue` 实际存在一致 |
| 3 | `f_chart/doc/spec/add-f-chart-pictogram/design.md` | .md | ✅ | 布局/形状/校验与实现一致；**图标数量无上限**（见发现 #1） |
| 4 | `f_chart/doc/spec/add-f-chart-pictogram/proposal.md` | .md | ✅ | `PictogramChart`、`pictogramCount`、`pictogramIconPath` 均在仓内存在 |
| 5 | `f_chart/doc/spec/add-f-chart-pictogram/specs/chart-rendering/spec.md` | .md | ✅ | 四条 requirement 与实现逐条对照通过；上限缺失见发现 #1 |
| 6 | `f_chart/doc/spec/add-f-chart-pictogram/tasks.md` | .md | ✅ | 承诺的 `PictogramChart_test.cj` 存在 |
| 7 | `f_chart/doc/spec/add-f-chart-pie/design.md` | .md | ✅ | 起始角、0.65 半径、一位小数百分比均与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-pie/proposal.md` | .md | ✅ | `PieChart`、`pieFractions` 存在；`startAngle` / `showPercent` 默认值与实现一致 |
| 9 | `f_chart/doc/spec/add-f-chart-pie/specs/chart-rendering/spec.md` | .md | ✅ | 0 值扇区二义（见发现 #3） |
| 10 | `f_chart/doc/spec/add-f-chart-pie/tasks.md` | .md | ✅ | `PieChart_test.cj` 存在，覆盖 4 扇区/4 标签 |
| 11 | `f_chart/doc/spec/add-f-chart-pr/design.md` | .md | ✅ | 坐标、基线、AP 与实现一致；插入排序见 CPU 方案 |
| 12 | `f_chart/doc/spec/add-f-chart-pr/proposal.md` | .md | ✅ | `ap` / `baseline` 字段层级未写明（`chart-json-spec.md:1782` 示例给的是 `series[0].ap`，`:1778` 是顶层 `baseline`，实现与示例一致） |
| 13 | `f_chart/doc/spec/add-f-chart-pr/specs/chart-rendering/spec.md` | .md | ✅ | 漏 `series` 恰好 1 个（见发现 #2） |
| 14 | `f_chart/doc/spec/add-f-chart-pr/tasks.md` | .md | ✅ | `PrChart_test.cj` 存在，含 ap 越界用例 |
| 15 | `f_chart/doc/spec/add-f-chart-probability/design.md` | .md | ✅ | 理论分位数/参考线/5% 余量与实现一致；退化跨度走 `padding=1.0` 未写进文档，影响为零 |
| 16 | `f_chart/doc/spec/add-f-chart-probability/proposal.md` | .md | ✅ | 类名、class 名与实现一致；`distribution` / `showLine` 实际在 `series[0]` 读取，proposal 未写层级 |
| 17 | `f_chart/doc/spec/add-f-chart-probability/specs/chart-rendering/spec.md` | .md | ✅ | 漏 `series` 恰好 1 个（见发现 #2） |
| 18 | `f_chart/doc/spec/add-f-chart-probability/tasks.md` | .md | ✅ | `ProbabilityChart_test.cj` 存在 |
| 19 | `f_chart/doc/spec/add-f-chart-qq/design.md` | .md | ✅ | 分位点、Acklam、最小二乘、`4 4` 虚线与实现一致；「钳制到 `(1e-12, 1-1e-12)`」实际只钳端点，因 `p_i ∈ (0,1)` 无影响 |
| 20 | `f_chart/doc/spec/add-f-chart-qq/proposal.md` | .md | ✅ | `normalQuantile` / `qqTheoryQuantiles` 存在；spec/tasks 属第 18 部分 |

合计：`.cj 0` 个 / `.md 20` 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无代码；文档层的正确性按"与实现逐条对照"完成（6 个图表的类名、内部助手、异常类型、默认值、class 名全部命中）。安全性无凭据/注入类表述；`pictogram` 自定义 path 的转义由 `SvgBuilder` 注释声明交由 `SvgWriter` 负责，不单列 |
| §1 死代码 | 0 | `.md` 无不可达语句；改为机械核对"文档点名的每个符号是否仍存在"：`PercentStackedBarChart` / `BarMode.PercentStacked` / `percentStackedValue` / `pictogramCount` / `pictogramIconPath` / `PieChart` / `pieFractions` / `PrChart` / `ProbabilityChart` / `QQChart` / `normalQuantile` / `qqTheoryQuantiles` / `qqFitLine` / `LinearScale` / `ChartFrame.drawXAxisNumeric` 逐个 grep 命中，无失效引用 |
| §2 重复逻辑 | 1 | 五份带校验段的 spec（pictogram / pie / pr / probability + 本部分外的 qq）逐条比对；`pr` / `probability` 两份相对 `pie` / `qq` 少一条「series 恰好 1 个」⇒ 行为漂移（发现 #2）。其余 proposal/design 措辞重复属模板样板，无实质差异，不报 |
| §3 空实现 | 0 | 20 个文件无空章节、无 `TODO`/`FIXME`/`占位` 字样（全文 grep）；`tasks.md` 勾选项对应的测试文件与实现符号均存在 |
| §4 栈溢出 | 0 | 文档涉及的算法只有线性扫描与最小二乘，无递归描述；`pictogramIconPath` 按形状分支展开，无自引用 |
| §5 OOM | 1 | 发现 #1：象形图 `ceil(value/unit)` 无上限，绘制循环按该值生成 path |
| §6.1 热点瓶颈 | 0 | 本轮无 profile / bench 数据，热点结论不成立；排序与分配的猜测已进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无并发/锁描述 |
| §6.3 并发串行 | 0 | 同上 |
| §6.4 低效算法 | 0 | 插入排序 O(n²) 为设计明确选择，缺耗时占比，未定为缺陷，已进「优化可行性方案（无基线）」 |
| §7 降堆内存方案 | 0 | 无独立于缺陷 #1 的可量化方案；`ArrayList → toArray()` 的分配猜测已进待验证假设 |
| §8 降 CPU 方案 | 1 | 排序改 O(n log n)，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分为文档，无函数内临时大对象可评估 |
| §11 现有代码的 BUG（存量） | 1 | 与 §5 同一根因（发现 #1）；另两条规格边界缺口见发现 #2 / #3 |
| §12 并发安全与锁粒度 | 0 | 本部分无线程共享路径描述；图表渲染按每次 `draw` 的局部对象建模 |
| §14 功能完备性与 README 覆盖 | 0 | 六种图表 `percent-stacked-bar` / `pictogram` / `pie` / `pr` / `probability` / `qq` 在 `README.md` 与 `README_en.md` 均检索命中；spec 承诺的类、内部助手、测试文件全部存在，无"承诺未实现" |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完；§13 对照结果见上表说明与「范围外提示」 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 1 |
| 轻微 | 1 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

本部分是 6 个图表的归档四件套（proposal / design / spec / tasks）中的 20 份文档。文档质量整体较高：需求以 `MUST`/`SHALL` + scenario 写出，类名、内部助手名、异常类型、class 名、默认值与当前实现逐项对得上，tasks 勾选项对应的测试文件也都存在，没有空章节和失效符号。真正需要排期的是**象形图的图标数量无上限**——它不是文档措辞问题，而是一条能从 10 字节输入放大到 GB 级输出的 OOM 路径，规格与设计都没有给出拒绝或降采样规则，属阻塞项。其余两条（`pr` / `probability` 漏记单系列约束、`pie` 的 0 值扇区二义）是规格作为验收基线的完整性缺口，改动只在文档侧，风险低。另有两条落在 `doc/chart-json-spec.md` 的文档与实现冲突（百分堆叠的 y 轴上限、饼图 `innerRadius`），已标为范围外提示，交由对应部分处理。存量共 3 条，是否纳入修复待用户决定。
