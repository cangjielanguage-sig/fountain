# f_chart 模块审查报告

> **模块第 1/37 部分**（本报告只覆盖 `files/f_chart.part1.txt` 列出的 1 个文件：`README.md`。`README_en.md` 在第 2 部分，`src/**` 与 `doc/**` 由后续子轮产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 1 个 `.md`，共 1 个文件）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分唯一文件是中文 README，上述代码维度不适用；实际执行 checklist §13（文档与实现一致性）与 §14（功能完备性 / README 覆盖）：把 README 的接口契约、默认值、错误语义、数据形状、里程碑与样例清单逐项对照 `src/` 的公开声明与解析代码。
- **报告版本**：v1（第 1/37 部分）

## 发现

### [一般][存量] M19 箱线图声称按 1.5 IQR 求须与异常点，实现只画入参五数，1.5 IQR 在 `box-scatter` 里

- **位置**：`f_chart/README.md:878`（M19 `boxplot` 绘制方式）；对照 `f_chart/src/BoxPlotChart.cj:95-132`、`f_chart/src/BoxScatterChart.cj:263-284`
- **来源**：存量（快照模式无基线；`git blame` 该段属 2026-11 的图表批量提交）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— `BoxPlotChart` 从 JSON 读 `min` / `q1` / `median` / `q3` / `max` 五个必填数字（`95-107`），只校验单调性 `min <= q1 <= median <= q3 <= max`，`outliers` 是可选数组、逐项读入（`109-121`）；须线直接连到入参 `min` / `max`（`203-219`），全文件无 `1.5`、无 `iqr`、无栅栏计算（`grep -n "1\.5\|iqr" BoxPlotChart.cj` 只命中 `strokeWidth: 1.5`）。真正的 1.5 IQR 只出现在 `BoxScatterChart.cj:271-284`（`lowFence = q1 - 1.5 * iqr`，被 `box-scatter` 与 `violin-box` 复用）。
- **描述**：README 把 `box-scatter` 的统计规则错挂到 `boxplot` 上。按文档理解，用户给原始样本即可自动得到"1.5 IQR 内的须 + 须外异常点"；实际 `boxplot` 会先因缺少 `min` / `q1` / `median` / `q3` / `max` 抛 `MissingField`，补上五数后也不会重新判定须端，`outliers` 里的点原样当异常点画。反过来，若用户按 `box-scatter` 的心智给 `boxplot` 传超栅栏的 `min` / `max`，也不会被任何检查拦住。
- **建议**：把 M19 文案改成"直接使用输入五数概括绘制箱体与须、端帽，异常点由 `outliers` 显式提供，不做 1.5 IQR 栅栏校验；需要自动判定请用 `box-scatter` / `violin-box`"，并在此处交叉引用 M45 / M46。

### [一般][存量] `Chart` 契约只承诺 SVG，8 个 TUI 图表却返回 ANSI，README 仍称可"按统一接口替换或注入"

- **位置**：`f_chart/README.md:2884`；`f_chart/src/Chart.cj:24`、`f_chart/src/Chart.cj:32`；`f_chart/src/tui/BarChart.cj:25-27`（其余 7 个 `Tui*Chart` 同构）
- **来源**：存量（`git blame`：README:2884 → `0494ee8108` 2026-11-09；`src/Chart.cj:24` → `53aed4b9ca` 2026-11-08）
- **判据**：review-checklist §11「契约与实现不符」+ §13「文档与实现一致」
- **证据**：静态确定 —— `Chart` 接口 KDoc 两处写明"输出是完整的 SVG 文档字符串""把 JSON 图表描述绘制为 SVG"（`Chart.cj:24`、`32`）；而 `TuiBarChart.draw` 返回 `TuiBarRenderer.render(...)`，输出是以 `\u{1B}[0m\n` 收尾的 ANSI 串（`TuiColor.cj:24`、`TuiCanvas.cj:178-200`）。README:2884 写"8 个类都实现 `fountain::f_chart.Chart`，因此可以按统一接口调用、替换或注入"，未提返回格式不同。
- **描述**：调用方若按接口语义持有 `let c: Chart = TuiBarChart()` 并把返回值写进 `.svg`，得到的是带转义序列的终端字符画；反之把 SVG 图替换成 TUI 图做"注入"时输出格式静默变化，编译期与运行期都没有提示。这是接口契约层面的不一致，不是措辞问题：`Chart` 的 KDoc 对整个模块生效，而 8 个实现违反它。
- **建议**：二选一，需用户拍板——(a) 保留现状，把 `Chart.cj` 的 KDoc 改为"返回序列化结果，SVG 或 ANSI 由实现约定"，并在 README:2884 明写 TUI 返回 ANSI、不可与 SVG 图互换落盘；(b) 拆契约：新增 `TuiChart` 接口（仅复用 JSON 解析），让 `Chart` 只约束 SVG 实现。

### [轻微][存量] 数据形状代号两处错位：`scatter-matrix` 标 `C`（实为 `M`）、`mosaic` 标 `M`（实为 `C`）

- **位置**：`f_chart/README.md:1284`（M30「数据形状：`C`」）、`f_chart/README.md:1429`（M33「数据形状：`M`」）；对照 `f_chart/src/ScatterMatrixChart.cj:77-101`、`f_chart/src/MosaicChart.cj:58-73`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 与实现不符」（形状代号表定义：`C = number[]`、`M = number[][]`，README:279）
- **证据**：静态确定 —— `ScatterMatrixChart` 遍历 `series[].data` 的每个元素，元素必须是数组，否则抛「期望数值数组」（`82-84`），行内数字个数还必须等于 `variables` 数（`95-99`）⇒ 形状是 `number[][]`，即 `M`。`MosaicChart` 的每个 `series[].data` 是扁平数字数组（`61-72` 逐项要求 `isInt || isDecimal`，负数直接拒绝），多系列按列堆叠（`139-160`），长度校验在 `82-89` ⇒ 形状是"多系列各持 `number[]`"，即 `C`；README 自己的 M33 示例（`1440-1441`）也正是两组扁平数组。
- **描述**：形状代号是读者判断"要不要写嵌套数组"的第一入口，两处刚好互换，会让人给 `mosaic` 写 `[[...]]`（被当成非数字拒绝）或给 `scatter-matrix` 写 `number[]`（抛「期望数值数组」），而示例又是对的，读起来自相矛盾。
- **建议**：两处代号互换；若确实想表达"`mosaic` 的 `series` 语义是矩阵的转置"，请在代号表里加一句说明，而不是让单图代号与定义冲突。

### [轻微][存量] 「其他公开 API」小节结构未完成：承诺按「模块级 / 类型」分组，只有一条模块级 bullet

- **位置**：`f_chart/README.md:3155-3159`（EOF）
- **来源**：存量（`git blame`：`f624bf2faa` 2026-11-11）
- **判据**：review-checklist §13「关键段落缺失」、§14.2「缺关键段落」
- **证据**：静态确定 —— `3157` 行写"以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）"，`3159` 行只有一条 bullet「模块级：ChartErrorKind（enum）」，随后文件结束（`wc -l` = 3159，`tail -c 400` 确认无后续段落）。既没有"类型"分组，也没有 `ChartErrorKind` 的 4 个成员、`ChartException.kind` / `path` 任何条目；同模块英文版结尾同构（同样只列 "Module level: `ChartErrorKind`"），可排除中文版被截断。
- **描述**：该节是读者查找"M0 之外还有哪些公开契约"的入口，现在是半截清单：`Chart`、`ChartException`、`ChartErrorKind` 与 `TuiCellChart` 四个公开契约只落了一个名字，且这个名字下面没有成员。`ChartException` 的构造参数、`kind` / `path` 字段只能从正文散文反推。
- **建议**：补成两段——"模块级：`ChartErrorKind`（`InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`）"与"类型：`ChartException`（`kind: ChartErrorKind`、`path: String`，`path` 非空时消息前缀 `path: `）、8 个 `Tui*Chart` 与 `TuiCellChart`"；或删掉该节，把 `ChartErrorKind` 并回 M0。

### [轻微][存量] 「测试总数 1168（TUI 76）」与源码注解计数不符（1173 / 81）

- **位置**：`f_chart/README.md:176`
- **来源**：存量（`git blame`：`0494ee8108` 2026-11-09）
- **判据**：review-checklist §13「文档过期」
- **证据**：静态确定（源码侧注解计数）—— `grep -rn "@TestCase" f_chart/src --include=*.cj` = 1173 条，其中 `src/*.cj` 1092、`src/tui/*.cj` 81；TUI 按文件分布为 `TuiBarChart_test` 10、`TuiCanvas_test` 9、`TuiCellChart_test` 3、`TuiComboChart_test` 7、`TuiConfig_test` 2、`TuiFlameChart_test` 15、`TuiFrame_test` 5、`TuiGallery_test` 8、`TuiGroupedBarChart_test` 4、`TuiLineChart_test` 5、`TuiPercentStackedBarChart_test` 4、`TuiScatterChart_test` 5、`TuiStackedBarChart_test` 4，无 `@Disable` / `@Skip`。README 写"1168，含 TUI 76"，差值 5 且正好全部落在 TUI（1168−76=1092 与根包一致）。测试运行器的实际计数需 `cjpm test` 复核（本轮不跑构建，故"全部通过"一句记 `待确认`）。
- **描述**：状态表末尾的验收数字已陈旧，读者会拿它当"当前基线"，与源码不符；同一句"全部通过"也无法从静态材料证实。
- **建议**：用最近一次 `cjpm test` 的原始输出更新总数与 TUI 子数，并注明 SDK 版本与日期；或改为"用例数见 CI 报告"，避免每加一个用例就改文档。

### [轻微][存量] `ChartErrorKind.InvalidJson` 被列为 `draw` 的失败类别，但模块内没有任何抛出点

- **位置**：`f_chart/README.md:41`（M0 错误语义）；对照 `f_chart/src/ChartException.cj:23,33,43`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档承诺与实现不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全模块 `InvalidJson` 只出现 3 次，全部在 enum 自身：定义（`23`）、`==` 分支（`33`）、`toString` 分支（`43`）；`grep -rn "InvalidJson" f_chart/src`（排除测试）无第四处，也没有任何以 `ChartErrorKind.InvalidJson` 构造的 `ChartException`。JSON 文本解析由 `f_data` 负责（`f_data/src/json/JsonValue.cj` 的 `fromStr`），它抛的不是 `ChartException`。
- **描述**：`draw` 的入参已经是 `JsonObject`，"文本无法解析"在这个入口不可能发生；README 却把 `InvalidJson` 与另外三个 kind 并列为 `draw` 的失败类别，调用方照此写 `case InvalidJson` 是死分支，也容易误以为 `draw` 接受字符串。
- **建议**：在 M0 注明"`InvalidJson` 属于 `JsonValue.fromStr` 阶段的失败类别，`f_chart` 自身不会抛出"，或直接从 `draw` 的错误清单中移除该值。

### [轻微][存量] README 主题字段表漏了 `legendTextColor`

- **位置**：`f_chart/README.md:273`；对照 `f_chart/src/ChartTheme.cj:32,48`、`f_chart/src/ChartFrame.cj:160`
- **来源**：存量（`git blame`：README:273 → `0494ee8108` 2026-11-09）
- **判据**：review-checklist §14.2「公开配置项未文档化」
- **证据**：静态确定 —— `ChartTheme` 有 8 个可配字段，`legendTextColor` 默认取 `textColor`（`ChartTheme.cj:32`，解析在 `48`），并被 `ChartFrame.cj:160` 用于图例文字颜色；README 的 `theme` 单元格只枚举到 `background / palette / fontFamily / fontSize / textColor / axisColor / gridColor` 七个。
- **描述**：README 是模块主入口，字段表被当作全集使用；漏掉后使用者只能靠阅读源码或试错发现该字段，且会把"图例文字颜色不可配"当成限制。
- **建议**：字段表补 `legendTextColor`（默认 `textColor`），或把该单元格改成"完整字段见 `doc/chart-json-spec.md` 的主题表"。

### [轻微][存量] 「任何结构或数值问题都以 ChartException 抛出」是绝对表述，区域 `path` 的非法数字实际被静默跳过

- **位置**：`f_chart/README.md:255`（错误语义）；对照 `f_chart/src/ChoroplethChart.cj:193-206`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档承诺与实现不符」；`catch` 形态本身见 §3
- **证据**：静态确定 —— `pathCentroid` 逐 token 调 `Float64.parse`，失败走 `catch (_: Exception) { () }`（`194-198`），只在最终解析到的数字不足 4 个时才抛 `InvalidValue`（`204-206`）。因此 `regions[].path` 里出现 `M 420 abc L 560 190` 这类非法数字 token 不会报错，`draw` 仍返回完整 SVG，只是质心（进而标签位置）按剩余数字计算。
- **描述**：README 的"任何结构或数值问题都以 ChartException 抛出，不会返回空串或半成品"对大多数图成立，但对 path 数值 token 不成立；使用者会以为错误路径一定被拒绝，从而把"标签飘到错误位置"当成渲染 bug 而非输入问题。
- **建议**：文档改成"结构性错误、缺失字段与不可用数值抛 `ChartException`；`path` 按容错方式解析，非法坐标 token 会被跳过"；或让 `pathCentroid` 对非法 token 直接抛 `chartInvalidValue`（需同步改对应测试）。
- **范围外提示**：`ChoroplethChart.cj:194-198` 的 `catch (_: Exception) { () }` 本身是 §3「静默吞异常」候选，`ChoroplethChart.cj` 属后续子轮文件，不在本部分统计，留给对应子轮判定。

### [轻微][存量] 样例文件"纯文本（ANSI 已剥离）"与实际文件、README 其他段落相互矛盾

- **位置**：`f_chart/README.md:3150`；对照 `f_chart/README.md:197`、`f_chart/README.md:2909`、`f_chart/README.md:3126`；证据文件 `f_chart/charts/*.tui.txt`
- **来源**：存量（`git blame`：README:3150 → `31cd0965ab` 2026-11-09；README:197 → `0494ee8108` 2026-11-09）
- **判据**：review-checklist §13「文档承诺与实现相反」
- **证据**：静态确定 —— `charts/` 下 12 个 `.tui.txt` 全部含 ESC 字节：`M001-bar.tui.txt` 有 18 行含 `\x1b`，其中 18 处是 `\x1b[38;2;` 24 位真彩序列；`M052-flame*.tui.txt` 有 14–24 行。同一份 README 在 197/3126 行两次写"全部保留 ANSI 24 位真彩颜色"，2909 行写"写入文件时转义序列会保留，需纯文本时自行剥离"，只有 3150 行写"纯文本（ANSI 已剥离）"。
- **描述**：读者按 3150 行把样例当纯文本做 diff / 文本回归，会得到带控制字符的结果；若照它建立"纯文本基线"，视觉回归会误判。三处相反陈述中 3150 行是唯一与文件不符的一条。
- **建议**：删除 3150 行的"（ANSI 已剥离）"，改为"文件保留 ANSI 真彩序列，需要纯文本请自行剥离 `\u{1B}[…m`"；更好的做法是把这段并入 3121 的"样例与回归"，只保留一处事实源（见优化方案 1）。

## 优化可行性方案

> 本部分只有 `README.md`，没有可执行代码，也没有改前 / 改后数据，**不提出性能或内存方案**（避免把"文档措辞"包装成优化项）。

### [文档结构] TUI 样例/回归段落收敛为单一事实源

- **现状**：同一批 `.tui.txt` 文件、同一条 `cjpm test --skip-build` 命令在 `README.md:193-198` 与 `README.md:3121-3150` 两处重复叙述；两处已经漂移出事实冲突（发现 9 的 ANSI 表述）。
- **方案**：保留 3121 段的完整表述，193-198 段只留一句"TUI 样例与回归见文末附录"，删除重复的文件清单与命令。
- **预期**：消除同类漂移的复发点；本轮已实证重复叙述会分叉。
- **代价**：阅读动线略变（前文需跳转一次）。
- **验证**：`grep -n "tui.txt\|cjpm test --skip-build" README.md` 应只剩一处主叙述 + 一处指引。
- **证据状态**：`无基线（文档类，验证方式为上述 grep 比对，不进 tasks）`

### [堆内存] / [CPU]

- 本部分无 `.cj`，README 未包含可测量的内存或 CPU 契约，故 0 条。若后续子轮在 `src/**` 发现渲染热点，其结论须带 `cjprof` / `cjpm bench` 数据，本部分不预置假设。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README:176 的"全部通过"是否仍成立 | `f_chart/README.md:176` | 最近一次全量测试结果 | 在 `f_chart` 跑 `cjpm test`（本轮禁止跑构建），记录用例数与失败数 |
| 2 | 107 份 SVG 是否都能被 XML 解析器接受 | `f_chart/charts/*.svg` | 解析器校验结果 | `xmllint --noout charts/*.svg`，或用 `SvgParser` 批量回读（未见批量回读用例） |
| 3 | README 与 `README_en.md` 是否存在同源漂移（本部分只审中文版） | `f_chart/README_en.md` | 英文版逐段比对结果 | 属第 2 部分范围；本轮仅以结尾段落作旁证，未做全量对照 |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part1.txt` 一一对应（该文件仅 1 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/README.md` | .md | ✅ | 3159 行全读；与实现大体一致。问题：#1（M19 1.5 IQR）、#2（Chart/TUI 契约）、#3（M30 / M33 形状代号）、#4（末尾 API 清单）、#5（测试计数）、#6（InvalidJson）、#7（legendTextColor）、#8（错误语义绝对化）、#9（ANSI 表述矛盾） |

合计：`.cj` 0 个 / `.md` 1 个 / 共 1 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 全部是文档侧命中（#1–#9），按 §11 / §13 / §14 归类。本部分无 `.cj`，代码正确性、分层设计、值/引用语义、注入与凭据等维度不适用。文档可读性未发现结构性问题：状态表 + 分组附录的导航可用，锚点（`#附各图绘制方式与-json-结构`、`#附tui-子包用法`）与标题对应，4 个 Markdown 链接目标均存在 |
| §1 死代码 | 0 | 本部分无 `.cj`，无声明可判；改做"文档引用的符号是否存在"的反向核对：README 中 112 个 `"type"` 字面量、181 个 JSON 键、6 个 `f_chart/src/*.cj` 路径全部能在 `src/` 命中，无悬空引用。源码级死代码由第 2–37 部分覆盖 |
| §2 重复逻辑 | 1 | 文档层面命中：TUI 样例/回归两处重复叙述（`README.md:193-198` 与 `README.md:3121-3150`），且已漂移出矛盾（发现 9），合并建议见优化方案 1；本部分无函数体可比对 |
| §3 空实现 | 0 | 本部分无函数体。命中的 `catch` 静默吞异常在 `ChoroplethChart.cj`（范围外），只作发现 8 的取证与提示，不占本部分统计 |
| §4 栈溢出 | 0 | 本部分无代码；README 也未承诺递归深度相关行为，无可核对项 |
| §5 OOM | 0 | 本部分无代码；README 未声明数据规模上限（这一点是否该补属后续子轮对渲染实现的判定，本部分不臆断） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，也未读到代码；不提出热点结论 |
| §6.2 大粒度锁 | 0 | 本部分无代码，无线程同步面 |
| §6.3 并发串行 | 0 | 同上 |
| §6.4 低效算法 | 0 | 同上；README 的复杂度承诺只有"直方图默认 sqrt(n) 分箱"（`836`），与 `HistogramChart.cj` 的 `Int64(sqrt(n))` 一致，无低效承诺 |
| §7 降堆内存方案 | 0 | 无代码、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数，无 local region 候选；README 未提及 local mode |
| §11 现有代码的 BUG（存量） | 1 | 发现 2（`Chart` 接口 KDoc 与其 8 个 TUI 实现不符）按 §11 计入；其余文档与实现不符按 §13 统计，不重复计入 |
| §12 并发安全与锁粒度 | 0 | 本部分无共享状态；README 未声明任何线程安全契约（`Chart` 的"纯函数"约束写在 `src/Chart.cj:24-25`，属代码注释） |
| §13 文档一致性 | 6 | #1（M19 绘制方式）、#3（两处形状代号）、#5（测试计数）、#6（`InvalidJson`）、#8（错误语义绝对化）、#9（ANSI 表述矛盾） |
| §14 功能完备性与 README 覆盖 | 2 | #4（「其他公开 API」清单未完成）、#7（`legendTextColor` 未进字段表）。反向核对（README 承诺 → 实现）均成立：112 个 `"type"` 取值在 `src/` 都能 grep 到；`Chart` 签名（`README:34-36` vs `Chart.cj:27-36`）、`ChartException` 的 `path` 前缀语义（`README:255` vs `ChartException.cj:61-69`）、版本 `1.3.2021`（vs `cjpm.toml`）、依赖树 `f_svg` / `f_data` / `f_base`（vs `cjpm.toml`）、默认画布 800×480 与 `padding` 24（vs `ChartConfig.cj:22-25,167-168`）、`legend.show` 默认真（vs `ChartConfig.cj:94`）、柱宽 60%（vs `BarRenderer.cj:128`）、面积透明度 0.3（vs `AreaChart.cj:283,291`）、TUI 80×24 与最小 20×8（vs `TuiFrame.cj:71-72`）、8 个 TUI 类且仅 `TuiBarChart` / `TuiLineChart` 实现 `TuiCellChart`（vs `src/tui/*.cj`）、`drawCells` 每行恰好 `width` 格且宽字符后半格为空（vs `TuiCanvas.cj:144-159`）、`charts/` 107 个 SVG + 12 个 `.tui.txt`（含 4 个火焰图变体，vs 目录实测与 `ChartGallery_test.cj` 的 107 次 `save(`）均一致；106 个里程碑 − 5 个别名 + M93b = 102，与 102 个 `public class … <: Chart` 一一对应 |
| 文件覆盖（§13 等） | 1/1 | 无缺文件；`README_en.md`、`doc/**` 不在本部分清单内，未审 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0（另列 1 条文档结构优化，无基线） |

## 总评

本部分只覆盖 `f_chart/README.md`（3159 行），它是整个模块的对外契约：接口签名、错误语义、公共字段、M1–M106 的 JSON 结构与 TUI 子包说明。**文档主体质量高**——里程碑与实现一一对应，示例里的每个 `type` 字符串在 `src/` 都有入口，版本号、依赖树、默认画布/内边距/图例开关、TUI 尺寸下限、样例文件数量等可机械核对的项全部对得上，说明作者在持续维护这份 README。

风险集中在"描述得比实现更聪明"：

- 一般项 **#1**：M19 箱线图声称按 1.5 IQR 求须与异常点，实际只画入参五数，真正的 1.5 IQR 在 `box-scatter` / `violin-box`。这会直接影响使用者是否自己算栅栏，建议优先改文案并加交叉引用。
- 一般项 **#2**：`Chart` 接口 KDoc 只承诺 SVG，8 个 TUI 类却返回 ANSI，而 README 说它们可"按统一接口替换或注入"。接口契约层面的不一致，需在"改 KDoc"与"拆接口"之间做一次决策。
- 轻微项 **#3 / #4** 属"索引级"错误：两个数据形状代号互换、末尾公开 API 清单在 EOF 处半截，修正成本极低，但会直接影响读者写对 JSON 与查找 API。
- 轻微项 **#5–#9** 属陈旧与过度承诺：测试计数与源码注解差 5 条（全在 TUI）、`InvalidJson` 无抛出点、"任何数值问题都会抛"对 `path` 不成立、`legendTextColor` 未进字段表、`.tui.txt` 是否含 ANSI 在同一文档里自相矛盾（实测含真彩序列）。改动都是几行文字。

本部分没有任何 `.cj`，因此**图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、并发安全**这些专项未在本轮取证，不能据此对模块整体下结论；它们由包含 `src/**` 的其余 36 个子轮负责。

存量缺陷共 9 条（一般 2 / 轻微 7），是否纳入修复待用户决定；本报告只读文件，未做任何修改。
