# f_chart 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（695 个文件：251 个 .cj + 444 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 37 个分部分报告合并：`parts/f_chart.part1..37.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [一般][存量] M7 组合图文档声称支持「面积（area）系列」，实现只认 6 种类型，`area` 直接抛 `UnsupportedChart`

- **位置**：`f_chart/README_en.md:2847`（`bar, line, scatter and area series are mixed ...`）；中文同源 `f_chart/README.md:2860`；与本文档自己的状态表 `f_chart/README_en.md:74`（`bar/line/scatter in any combination`，无 area）矛盾
- **来源**：存量（`7b1f9dbee6`，2026-11-11）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」
- **证据**：静态确定 —— `f_chart/src/ComboChart.cj:238-271` 的 `match (seriesType)` 只有 `bar`/`grouped-bar`、`stacked-bar`/`percent-stacked-bar`、`line`、`scatter` 四类分支，`case _`（`:272-277`）抛 `ChartException(kind: UnsupportedChart, "组合图不支持系列类型 …")`；内部枚举 `ComboKind`（`:23-26`）只有 `Bar`/`Line`/`Scatter`，没有面积系列的表示。`ComboChart.cj` 全文搜 `"area"` 零命中
- **描述**：照附录写 `{"type":"combo","series":[{"type":"area",…}]}` 会得到"组合图不支持系列类型 area"异常，与文档描述正相反。同一条描述在中英文两版都存在，且与状态表冲突，属成文口径漂移
- **建议**：二选一并两版同步：①把附录描述改成「bar / line / scatter（含 grouped / stacked / percent-stacked 柱）」；②在 `ComboKind` 增 `Area` 并补齐 `match` 与渲染分支。`doc/chart-json-spec.md` 的 combo 小节同步

### [一般][存量] `series[].label` 与「可在柱顶显示数值」在实现中不存在：字段被忽略，柱族一个 `<text>` 都不画

- **位置**：`f_chart/README_en.md:276`（通用字段表把 `label` 列为 `series` 项）、`:300`（M1「values can be shown on top of the bars」）、`:362`（M4「percentage labels can be shown on top of the bars」）；承诺源加强：`f_chart/doc/chart-json-spec.md:109`（`{"show":true,"position":"top","format":"{value}"}`）、`:251`（bar 专属字段 `series[].label`）
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「API / 配置与源码不符」
- **证据**：静态确定 —— ①全仓非测试代码搜 `bool("label")` / `object("label")` / `value("label")` 零命中；`"label"` 只作为节点或点级字段出现（`DecisionTreeChart.cj:91`、`Flowchart.cj:173`、`SwimlaneChart.cj:124`、`VolcanoChart.cj:83`、`InfluenceChart.cj:78` 等），没有一处按系列级配置读取；②`f_chart/src/BarRenderer.cj` 全文（59-241 行为绘制段）不含 `text` 字样，也没有任何文本节点写入，柱族（`BarChart`/`GroupedBarChart`/`StackedBarChart`/`PercentStackedBarChart`/`PercentBarChart`）都不画数值；③产物侧复核：`charts/M001-bar.svg` 的全部 `<text>` 只有标题、刻度与轴标题，柱顶无数值
- **描述**：这是"文档里有、实现里没有"的字段：用户加 `"label": {"show": true}` 不会报错，也不会有任何效果——静默失效比报错更难排查。M4 的百分比标签同理
- **建议**：要么在 `BarRenderer` 实现（读 `series[].label`，按 `position`/`format` 在柱顶或柱内写 `<text>`，负值柱放柱底，格式化复用 `ChartScale.cj:108` 的 `chartFormatTick` 语义），要么把字段表与 M1/M4 描述一并删除，并同步 `doc/chart-json-spec.md:109`、`:251`

### [一般][存量] 甘特图示例的 `lane` 与 `yAxis.labels` 实现从未读取，示例静默降级为「一行一个任务名」

- **位置**：`f_chart/README_en.md:2342`（`yAxis.labels`）、`:2344-2348`（每个任务的 `"lane"`）；承诺源同样见 `f_chart/doc/chart-json-spec.md:2141`（`tasks: [{…, lane?, …}]`）
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「示例引用实现不处理的字段」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `f_chart/src/GanttChart.cj` 全文搜 `lane` 与 `yAxis` 均为 0 命中（除 `ChartConfig.parse` 的通用解析）；行高按任务数均分（`:125-126`），行标签取 `task.name`（`:147-152` 的 `kit.text(..., task.name, …)`），行序即 `tasks` 数组顺序
- **描述**：示例同时给 5 个 `yAxis.labels`（Requirements/Design/…）和 5 个 `lane`，读者会认为甘特图按泳道分组、行标题取泳道名。实际左侧显示的是任务全名（"Requirements research"…），两个字段被无声忽略且不报错
- **建议**：二选一——①在 `GanttChart` 接线：按 `lane` 分组行、行标题取 `yAxis.labels[laneIndex]`，`lane` 不在 `labels` 中时报 `InvalidValue`；②从两版 README 与规格删掉 `lane`/`yAxis.labels`，Drawing 段写清"行标签取 `tasks[].name`、行序按数组顺序"，并说明 `progress`/`dependsOn` 的行内语义

### [一般][存量] SHAP 图示例的顶层 `features` 是幻影字段，特征名只从 `data[].feature` 取

- **位置**：`f_chart/README_en.md:2312`；同一字段也出现在 `f_chart/doc/chart-json-spec.md:2123`
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「示例引用实现不存在的字段」、§14.1
- **证据**：静态确定 —— `f_chart/src/ShapChart.cj` 全文搜 `features` 零命中；特征名来自 `series[0].data[i].feature`（`ShapChart.cj:66`），缺失即 `MissingField`、重复即 `InvalidValue`（`:70-74`），排序按绝对值降序
- **描述**：示例同时给顶层 `"features": [...]` 与 `data[].feature`，前者完全无效。使用者只改 `features` 而漏改 `data[].feature` 时渲染结果不变、也不报错，排障成本高
- **建议**：删掉两处文档的顶层 `features`；若确实想用 `features` 定顺序，就在 `ShapChart` 接线并校验 `features.size == data.size`

### [一般][存量] 分布类示例（M45/M46/M88/M89）平铺数据配 3 个类目标签，只渲染第 1 组，其余标签静默丢弃

- **位置**：`f_chart/README_en.md:1112`+`:1115`（M45 box-scatter）、`:1130`+`:1133`（M46 violin-box）、`:1032`+`:1035`（M88 raincloud，标题 `Score distribution by group`）、`:1050`+`:1053`（M89 dot-strip，`Small samples per group`）；示例与 `f_chart/src/ChartGallery_test.cj:1063-1090` 同源
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「示例与实现语义不符」、§11「输入被静默丢弃」
- **证据**：静态确定 —— 分组单位是 **series**，不是 `data` 的嵌套层级：`RaincloudChart.cj:105-112` 与 `DotStripChart.cj:92-99` 按 series 下标取 `config.xAxis.labels[index]`；`BoxScatterChart.cj:82-89` 的扁平分支只用 `labels[0]` 且不校验标签数，而同一文件的嵌套分支（`:79-84`）会抛"标签长度与分组数不一致"；`ViolinBoxChart.cj:91-92` 同构。只有 `data[0].kind.isArray` 时才会按组展开
- **描述**：示例是"1 个 series + 10~12 个平铺数值 + 3 个类目标签"，实际画出 1 个箱体/1 朵云/1 列点，标签只取到 "Group A"；另外两个标签无声消失，用户会误以为数据被分成了三组。同一批图里 M20 violin（`:907-911`）与 M21 swarm（`:926-929`）用嵌套数组表示多组，写法正确，说明是这两节的示例没跟上
- **建议**：把四个示例改成嵌套数组（`data: [[...],[...],[...]]`），或补一句「扁平 `data` 表示单组，多组用 `number[][]` 且与 `xAxis.labels` 等长」；`:278` 的数据形状码说明补上这种"`C` 可写成 `number[][]`"的情形。代码侧建议 `BoxScatterChart` 在 `labels.size > 1` 且扁平数据时报错（见「范围外提示」）

### [一般][存量] 错误语义把 JSON 文本解析失败算进 `ChartException`，`InvalidJson` 库内永不产生，TUI 示例漏接 `JsonException`

- **位置**：`f_chart/README_en.md:41`（`Invalid input raises ChartException; kind distinguishes InvalidJson / …`）、`:3094-3103`（TUI 错误处理示例只 `catch (error: ChartException)`，而 `JsonValue.fromStr(json)` 写在 `try` 内）；中文 `f_chart/README.md:41`、`:3097-3106`
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「API / 错误契约与源码不符」、§11「错误处理缺失」
- **证据**：静态确定 —— ①`f_chart/src` 全量搜 `InvalidJson` 只有 3 处：枚举定义（`ChartException.cj:23`）、`==`（`:33`）、`toString`（`:43`），无任何 `kind: ChartErrorKind.InvalidJson` 的构造点；②`f_chart` 无 JSON 文本入口（非测试代码搜 `fromStr` 零命中），`Chart.draw` 入参已是 `JsonObject`（`Chart.cj:35`）；③文本解析在 `f_data`，失败抛 `f_data::JsonException`（`f_data/src/json/JsonValue.cj:156`、`:70-76`），与 `ChartException`（`ChartException.cj:57` 继承 `f_base.BaseException`）无继承关系
- **描述**：按 TUI 示例写 `try { … draw(JsonValue.fromStr(json).asObject()) } catch (error: ChartException)`，畸形 JSON 会抛 `JsonException` 直接穿透；同时 `kind == InvalidJson` 的分支永远进不去。文档把"文本解析失败"和"图表语义校验失败"混成一类，使用者据此写的错误处理会漏一条真实失败路径
- **建议**：①README 改为「`draw` 只抛 `MissingField` / `InvalidValue` / `UnsupportedChart`；JSON 文本错误由 `f_data::JsonException` 抛出，需单独捕获」；②TUI 示例改成 `catch (error: Exception)` 或在 `try` 外先解析；③`doc/f_chart模块设计.md` 同步；④`InvalidJson` 要么删掉（对外 API，需用户拍板），要么给 `f_chart` 增文本入口并真正抛出

### [一般][存量] 10 个已实现的 JSON 配置项在 README（中英两版）中完全没有出现

- **位置**：`f_chart/README_en.md:272`（theme 行只列 7 个键）、`:276`（series 行）、各图附录小节；实现：`ChartTheme.cj:48`（`legendTextColor`）、`CalibrationChart.cj:31`（`binCount`）、`HeatmapChart.cj:108`、`NetworkHeatmapChart.cj:144`（`cellGap`）、`ManhattanChart.cj:43`（`chromosomeGap`）、`VolcanoChart.cj:51-52`（`upColor`/`downColor`）、`LearningCurveChart.cj:47`（`shade`）、`SurvivalChart.cj:102`（`showCensors`）、`ControlChart.cj:77`（`sigma`）、`LearningCurveChart.cj:81`（`series[].std`）
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §14.2「公开 API / 关键配置未文档化」、§13「配置项与源码不符」
- **证据**：静态确定 —— 机械提取源码全部 `string/number/int/bool/array/value("…")` 字段名共 169 个，逐一在 `README_en.md` 全文检索，上述 10 个零命中，`README.md` 同样零命中。`legendTextColor` 不是死配置：`ChartFrame.cj:160`（SVG 图例文字）与 `tui/TuiFrame.cj:160`（TUI 图例文字）都在用，默认跟随 `textColor`
- **描述**：`f_chart` 的"API"就是 JSON 字段，字段名不进文档等于能力不可发现。具体影响：M96 校准分箱数、M43/M68 格子间隙、M93 染色体间距、M92 火山图双色、M97 的 ±SD 带（正文写了 "optional ±standard-deviation band" 却既没给字段名、示例里也没写 → 实际无法使用）、M49 删失标记开关、M38 控制限标准差倍数、图例文字颜色
- **建议**：把 10 个键补进对应图的附录小节；`theme` 行补 `legendTextColor`（注明默认跟随 `textColor`），`series` 行补 `std`；M97 示例补 `"shade": true` 与 `"std": [...]`，M92 补 `upColor`/`downColor`，M49 补 `showCensors`。纯文档改动

### [轻微][存量] 状态段「Test count 1168（含 76 个 TUI 用例）」已过期，当前声明计数为 1173 / 81

- **位置**：`f_chart/README_en.md:176`（`README.md:176` 同）
- **来源**：存量（`7b1f9dbee6`；中文行 `0494ee8108`）
- **判据**：review-checklist §13「文档过期」
- **证据**：待确认（未跑 `cjpm test`，按用例声明计）—— `grep -c '^\s*@TestCase$'`：`src` 合计 1173、`src/tui` 81；非 TUI 部分 1173−81=1092，与文档 1168−76=1092 完全吻合，说明只差 TUI 新增的 5 个用例（`5fd6e5a65` 引入 `TuiCellChart` 后未回填）。`@Test` 类 123 个，无 `@Ignore`/`@Skip`。"all passing" 属运行时结论，本部分未跑构建，不判定
- **描述**：这是全文唯一的覆盖度硬数字，现在偏低 5 个 TUI 用例，读者会误判覆盖率变化
- **建议**：按 `cjpm test` 实跑结果回填，或改为「1100+ 用例，TUI 子包 80+」这类不写死绝对值的表述；保留绝对数时在 CI 加一步校验

### [轻微][存量] M33 马赛克图数据形状码标成 `M`（`number[][]`），实现读的是每个 series 的 `number[]`

- **位置**：`f_chart/README_en.md:1423`
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「文档与实现不符」
- **证据**：静态确定 —— `MosaicChart.cj:57-77` 逐 series 取 `data` 并要求元素为数字（`number[]`），类别数由 `xAxis.labels` 或各 series 长度决定（`:78-84`）；README 自己的示例（`:1433-1436`）就是 2 个 series × 4 个数字，不是矩阵
- **描述**：`M` 会让使用者传 `[[…],[…]]` 期待一个矩阵，结果直接抛"期望数字"
- **建议**：改成 `C`（多 series）；若确实想支持矩阵输入，则实现 `number[][]` 并同步示例

### [轻微][存量] 分区图「区域名标注在质心」实为顶点算术平均，凹多边形会落到区域外

- **位置**：`f_chart/README_en.md:2602`
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「描述与实现不符」
- **证据**：静态确定 —— `ChoroplethChart.cj:176-218` 的 `pathCentroid` 把路径中所有数字两两成对求算术平均（`:210-217`），不是面积质心，且把 `M` 起点与闭合重复点一起计入，权重偏向重复顶点；README 的 `regions[].path` 示例带 `Z` 闭合（`:2614-2617`），闭合点通常与起点重合
- **描述**：L 形、带洞等凹区域的名字可能被画到形状之外，视觉上像"标签跑到别的省"；矩形示例看不出问题，所以长期未暴露
- **建议**：文档改为"标签取路径顶点均值（近似质心）"；如需精确，改用多边形面积质心公式并保留退化路径回退

### [轻微][存量] 英文 README 的 M36 缺「别名 M67」一条，与中文版不同步

- **位置**：`f_chart/README_en.md:1494-1498`（M36 只有 Implementation / Data shape / Drawing 三条）
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「`README_en.md` 与 `README.md` 不同步」
- **证据**：静态确定 —— `f_chart/README.md:1505` 有「别名：M67 也使用 `sankey`，复用 `SankeyChart`。」；逐里程碑比对条目数：102 个小节中仅 M36 一处差 1 条（4 vs 3），标题层级 139/139、代码块 121/121、JSON 键序列一致
- **描述**：英文读者在 M36 不知道 M67 是别名里程碑；状态表 `:134` 虽写了 "M67 Sankey alias"，但正文缺与 M16/M35/M44/M102 对等的说明
- **建议**：在 `:1498` 后补 `- Alias: M67 also uses \`sankey\` and reuses \`SankeyChart\`.`；中文版无需改

### [轻微][存量] 「Other public API」小节是残段：只列 `ChartErrorKind`，尾部 11 个空行，`ChartException` 没有声明条目

- **位置**：`f_chart/README_en.md:3141-3156`；中文 `f_chart/README.md:3155-3159`
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §14.2「公开 API 未文档化」、§13「关键段落缺失」
- **证据**：静态确定 —— 小节自称"列出上文未展开的声明"，实际只有一条 `- Module level: ChartErrorKind (enum)`；`ChartException` 是 public 类（`ChartException.cj:57`），`init(message, kind!, path!)`（`:61-69`）与 `public let kind` / `path`（`:58-59`）没有声明式条目，只有正文散落描述；文件末尾 11 个空行（`README_en.md:3146-3156`）像生成器输出被截断
- **描述**：想自行构造或包装 `ChartException` 的使用者查不到构造签名（`kind`/`path` 都是带默认值的命名参数），只能读源码；作为"完整 API 清单"既不完整，也不像有意为之
- **建议**：补 `ChartException`（构造签名 + 字段语义 + `path` 拼进 message 的规则，可直接用 `ChartException.cj:51-69` 的注释），清掉尾部空行；若该节由脚本生成，修生成器并加"生成结果非空"检查

### [轻微][存量] 样例「重新生成」只给 `cjpm test --skip-build`，可能沿用旧测试二进制

- **位置**：`f_chart/README_en.md:188`、`:3134`（`README.md` 同）
- **来源**：存量（`7b1f9dbee6`）
- **判据**：review-checklist §13「命令/示例可能不可用」
- **证据**：待确认 —— 本环境没有 cjpm 文档（`~/.autocode/cj` 不存在），无法确认 `--skip-build` 是否跳过测试二进制重编译；若确实跳过，改完 `src/` 后执行该命令只会用旧二进制重写 `charts/`
- **描述**：文档把它写成 Regenerate 的唯一命令，而 `charts/*.svg` 进 git 做视觉回归；一旦语义是"不重编译"，回归基线会被旧产物覆盖且看不出差异
- **建议**：确认语义后二选一——写成 `cjpm test`，或写成 `cjpm build && cjpm test --skip-build`

> 本部分 13 条发现全部为存量（快照模式无 diff）：一般 7 条、轻微 6 条，是否纳入修复待用户决定。

<!-- 第 3 部分 -->

### [一般][存量] #1 规范 §2.5 / §2.6 的三个通用字段在实现层没有读取点：`annotations`、`series[].label`、`series[].opacity`

- **位置**：`f_chart/doc/chart-json-spec.md:36`（`annotations`，交叉引用还写错成「见 2.5」，实际在 §2.6）、`:111-120`（§2.6 四类注解 `text/line/band/point` 字段表）、`:103`（`series[].opacity` 默认 1）、`:109`（`series[].label` 对象）；`f_chart/doc/f_chart模块设计.md:87`（信封表同样列 `annotations` 默认 `[]`）；`chart-json-spec.md:251`（M1 把 `series[].label` 列为柱状图能力）
- **来源**：存量（快照模式无基线，两文件分别最后改动于 2026-11-08 / 11-09）
- **判据**：review-checklist §3「公开契约承诺有行为 / 开关打开后走进空分支」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `grep -rn "annotation" f_chart/src f_svg/src` = 0 命中（`markLine` / `referenceLine` 同样 0）；`grep -rn 'number("opacity"' src/*.cj` 只有 `AreaChart.cj:283` 与 `StackedAreaChart.cj:250`，都是读 `areaStyle.opacity`，没有任何图读 series 级 `opacity`；`grep -rn '"position"' src/*.cj` 只命中 `ChartConfig.cj:105`（legend），`series[].label.position` / `.format` 无解析点
- **描述**：规范把 `annotations` 定义为「所有图共用」的第 2 节字段，给出四种注解的坐标、终点、文本、颜色、虚线；实际任何图都不读它，按文档写参考线/参考带会**不报错、不出图**——这类静默失败比抛 `InvalidValue` 更难排查。`series[].label`（`{"show":true,"position":"top","format":"{value}"}`）与 `series[].opacity` 同属「通用 series 字段表里有、代码里没有」，其中 `label` 还被写进 M1 专属字段
- **建议**：(a) 在 `ChartConfig` 统一读 `annotations`，由图实现经 `ChartFrame`（已有比例尺与轴）落图；`series.label` / `opacity` 在 `ChartSeries` 解析层读；(b) 从 §2.5 / §2.6 与 `f_chart模块设计.md:87` 删除并注明「暂不支持」；(c) 折中：保留字段但解析到非空即抛 `UnsupportedChart`，把静默变成显式失败。顺手把 `:36` 的「见 2.5」改成「见 2.6」

### [一般][存量] #2 M17 直方图的 `bins` 三项描述全错：默认不是 10、不接受上界数组、`normalize` 未实现

- **位置**：`f_chart/doc/chart-json-spec.md:758`；实现 `f_chart/src/HistogramChart.cj:166-186`（`resolveBinCount`）
- **来源**：存量
- **判据**：review-checklist §13「API / 默认值与源码不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `Some(value)` 分支要求 `isInt || isDecimal`，否则抛「期望正整数」（`:168-171`），数组形态直接被拒；`None` 分支是 `Int64(sqrt(Float64(sampleSize)))`（`:179`），不是常量 10；`grep -rn normalize src/HistogramChart.cj` 零命中（同名键只出现在 `ConfusionMatrixChart` 的 `normalize: "row"`，语义不同）
- **描述**：照文档传 `"bins": [150,160,170]` 会得到 `series[0].bins: 期望正整数`；不写 `bins` 时期望 10 个箱、实际 `floor(sqrt(n))`（20 个样本 → 4 个箱，与同节示例的 `"bins": 8` 也不一致）。`normalize` 写了默认 false 但无实现，想要频率密度只能外部换算
- **建议**：改成「`series[].bins`：正整数分箱数，缺省 `floor(sqrt(n))`，最小 1；不支持上界数组」；删除 `normalize` 或实现（实现时同步 `yAxis.title` 语义与示例）

### [一般][存量] #3 `areaStyle` 默认透明度写成 0.2，实现是 Area 0.3 / StackedArea 0.6

- **位置**：`f_chart/doc/chart-json-spec.md:108`（§2.5 `{"opacity":0.2}`）、`:623`（M14「默认 0.2」）；实现 `f_chart/src/AreaChart.cj:283,291`（0.3）、`f_chart/src/StackedAreaChart.cj:250`（0.6）
- **来源**：存量
- **判据**：review-checklist §13「默认值与源码不符」、§2「同一语义多处给出不同值」
- **证据**：静态确定 —— `AreaChart.resolveOpacity` 两处都是 `0.3`；`StackedAreaChart` 同名逻辑 `0.6`；本部分归档设计 `doc/spec/add-f-chart-area/design.md:20` 与 `proposal.md:11` 也写 0.3，与源码一致、与规范相反
- **描述**：三份材料三个数。使用者按规范以为「不写就是 0.2」，实际 M14 更浓、M15 更浓，做视觉回归时对不上样例
- **建议**：§2.5 改为「由图决定：`area` 0.3、`stacked-area` 0.6」，或统一默认值并同步代码与 `charts/` 基线

### [一般][存量] #4 M18 核密度图 `fill` 默认写成 true，实现默认 false

- **位置**：`f_chart/doc/chart-json-spec.md:779`；实现 `f_chart/src/DensityChart.cj:89`
- **来源**：存量
- **判据**：review-checklist §13「默认值与源码不符」
- **证据**：静态确定 —— `json.bool("fill", default: false)`，`DensitySeries` 持有该值决定是否填充曲线下区域
- **描述**：按规范省略 `fill` 应得填充密度曲线，实际只有描边；示例显式写了 `"fill": true/false`，所以样例长期掩盖了这个默认值错误
- **建议**：规范改默认 `false`；若产品上希望默认填充，则改代码并同步示例与基线

### [一般][存量] #5 M31 饼图的 `innerRadius` 字段不存在，只有 `donut` 支持内半径

- **位置**：`f_chart/doc/chart-json-spec.md:1248`；实现 `f_chart/src/PieChart.cj`（全文 `innerRadius` 零命中）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「字段在源码找不到」
- **证据**：静态确定 —— `grep -rn innerRadius f_chart/src` 只命中 `DonutChart.cj`、`GaugeChart.cj`、`SunburstChart.cj`；`PieChart` 的专属字段只解析了 `startAngle` 与 `showPercent`
- **描述**：规范给饼图列 `innerRadius`（默认 0），暗示 `pie` 传该键可成环形；实际被忽略，`pie` 永远实心，`donut` 的 0.55 又无法从 `pie` 触发。使用者会以为两个图只差一个参数
- **建议**：M31 删掉 `innerRadius`，改「需要环形请用 `donut`（默认 0.55）」；或 `PieChart` 读同名键并复用 `DonutChart` 的弧路径

### [一般][存量] #6 M36 桑基图的 `iterations`（默认 32）没有任何实现

- **位置**：`f_chart/doc/chart-json-spec.md:1367`；实现 `f_chart/src/SankeyChart.cj:159-160`
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§1「读了不用的死配置」
- **证据**：静态确定 —— 全模块 `grep -rn iterations f_chart` = 0 命中（含测试）；`SankeyChart` 只解析 `nodeWidth`（16）、`nodeGap`（12），布局是一次固定计算
- **描述**：这是会直接影响布局结果的字段：使用者调大 `iterations` 期望更稳的分层，实际无任何效果也不报错；规范把它与 `nodeWidth`/`nodeGap` 并列，可信度看起来一样
- **建议**：删除该字段；若确有迭代布局计划，spec 标「未实现」并在收到该键时抛 `UnsupportedChart`

### [一般][存量] #7 M37 帕累托图的 `cumulativeFormat` 未实现，右轴刻度硬编码为 0–100 步长 20 的整数百分比

- **位置**：`f_chart/doc/chart-json-spec.md:1615`；实现 `f_chart/src/ParetoChart.cj:171-177`
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「配置项无效」
- **证据**：静态确定 —— `for (tick in [0.0, 20.0, 40.0, 60.0, 80.0, 100.0])` 固定数组 + `"${Int64(tick)}%"`，既不读 `cumulativeFormat`，也不读 `yAxis.labelFormat` / `tickCount`；全模块 `grep cumulativeFormat` = 0 命中
- **描述**：规范承诺「`cumulativeFormat` 默认 `{value}%`」，改成 `{value} %` 或小数都不会生效；累计轴同时绕过了通用 `tickCount` / `labelFormat`，两条路都堵死
- **建议**：实现 `cumulativeFormat`（复用 `chartFormatTick` 的 `{value}` 占位替换）与 `tickCount`；或删字段并写明「累计轴固定 6 档整数百分比」

### [一般][存量] #8 M70 圆堆积图的 `padding` 与通用画布 `padding` 是同一个 JSON 键，示例会同时改掉画布内边距

- **位置**：`f_chart/doc/chart-json-spec.md:29`（§2 通用 `padding` 默认 24、作用于画布）、`:1420`（M70 专属 `padding`「圆间距，默认 2」）、`:1428`（示例 `"padding": 2`）；实现 `f_chart/src/ChartConfig.cj:187`（`ChartPadding.parse(root.value("padding"))`）、`f_chart/src/CirclePackingChart.cj:55`（`root.number("padding", default: 2.0)`）
- **来源**：存量
- **判据**：review-checklist §13「同一字段两种语义」、§11「语义与命名不符」；字段命名冲突属设计缺陷
- **证据**：静态确定 —— 同一个根级键被读两次：先按信封解析为画布 `ChartPadding`（默认 24），再被圆堆积当作圆间距（默认 2）。因此 M70 示例的 `"padding": 2` 会同时把画布边距从 24 压到 2
- **描述**：规范先用通用表把 `padding` 定义成画布内边距，又在 M70 重定义为圆间距，默认值不同、作用域不同，代码各读一次。用户想「保持画布边距 24、只把圆排紧」在现有字段下做不到；示例本身已经改小边距却没有一句说明。这是本部分唯一一条会改变**布局结果**的字段冲突
- **建议**：M70 换独立键（如 `circlePadding`），代码读新键并保留一版旧键兼容告警；§2 通用字段表加一句「各图专属字段与通用字段同名时，必须显式说明覆盖关系」

### [一般][存量] #9 M34 矩形树图声明 `tiling` 可取 `slice`，实现直接拒绝

- **位置**：`f_chart/doc/chart-json-spec.md:1318`（`squarify` / `slice`，默认 `squarify`）；实现 `f_chart/src/TreemapChart.cj:118-121`
- **来源**：存量
- **判据**：review-checklist §13「枚举值与实现不符」、§14.1「只处理部分输入」
- **证据**：静态确定 —— `let tiling = root.string("tiling", default: "squarify")` 之后 `if (tiling != "squarify") { throw chartInvalidValue("tiling", "目前仅支持 squarify") }`
- **描述**：规范把 `slice` 与 `squarify` 并列为可选值，照文档写 `"tiling": "slice"` 会直接拿到 `InvalidValue`。这与 #6 的静默忽略不同，是"文档允许、实现拒绝"，用户会先怀疑自己的 JSON 写错
- **建议**：规范删掉 `slice`（或标「未实现」）；若计划支持，实现 `slice` 分支并在 spec 的 tasks 里留 Red 用例

### [轻微][存量] #10 M60 流向图正文写 `flows: [{from, to, …}]`，同节示例写 `source` / `target`

- **位置**：`f_chart/doc/chart-json-spec.md:2467`（正文）对照 `:2481-2482`（示例）；实现 `f_chart/src/FlowMapChart.cj:117-124`
- **来源**：存量
- **判据**：review-checklist §13「示例与正文冲突」、§1「同一语义两种写法」
- **证据**：静态确定 —— 实现先取 `source`，缺失时回落 `requiredString("from")`；`target` 同理回落 `"to"`。两种写法都能跑，但错误路径报的是 `flows[i].source`
- **描述**：同一小节正文与示例对同一字段给出两个名字，读者不知道以哪个为准；虽然实现兼容，但 §1 约定「同一语义只用一个字段名」在这里被打破，且 `links` 体系用的是 `source/target`，`flows` 用 `from/to` 会让跨图复用 JSON 的人踩坑
- **建议**：正文统一为 `source` / `target` 并注明 `from/to` 为兼容别名（或在下一大版本移除别名）

### [轻微][存量] #11 类型索引里 `scatter-matrix` 标 `C`、`mosaic` 标 `M`，与 §5 正文和实现都相反

- **位置**：`f_chart/doc/chart-json-spec.md:166`（M30 `C`）、`:169`（M33 `M`）；对照 `:1166`（M30「样本行 `number[][]`」）、`:1300`（M33「`data` 与 `xAxis.labels` 等长」）；实现 `f_chart/src/ScatterMatrixChart.cj:27`（`rows: Array<Array<Float64>>`）、`f_chart/src/MosaicChart.cj:58-61`（逐 series 读平铺数组）
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 与实现不符」；§3 代号定义 `C = number[]`、`M = number[][]`
- **证据**：静态确定 —— M30 实现是二维数组（表里写 `C`）；M33 是"每系列一维"（表里写 `M`）
- **描述**：按 §3 约定准备数据的人会把两个图的数据结构搞反，第一次调用就报 `InvalidValue`
- **建议**：两处代号互换；若想保留「mosaic 是矩阵转置」的意思，在 §3 加说明，不要让单图代号与定义冲突

### [轻微][存量] #12 `symbol` 列出 `triangle`，实现没有该形状，会静默画成圆点

- **位置**：`f_chart/doc/chart-json-spec.md:106`；实现 `f_chart/src/LineChart.cj:447-451`（`ScatterChart` / `ComboChart` 同构）
- **来源**：存量
- **判据**：review-checklist §13「枚举值与实现不符」、§14.1「开关打开后走进等价分支」
- **证据**：静态确定 —— `drawSymbol` 的 `match` 只有 `none` / `square` / `diamond`，其余落 `case _ => circle`；全模块 `grep triangle src` 仅在 `Histogram2DChart_test` 的 `shape` 键命中；本部分 `doc/f_chart模块设计.md:116` 列的正是 `circle / square / diamond / none`（无 triangle），与代码一致
- **描述**：写 `"symbol": "triangle"` 不报错、画出来是圆点，视觉验收时会被当成样式 bug 追查
- **建议**：§2.5 删 `triangle`；若要支持，在 `ChartSvgKit` 加图元并补 `match` 分支与断言

### [轻微][存量] #13 规范里的 `shap.features` 与 `gantt.tasks[].lane` 仍是幻影字段

- **位置**：`f_chart/doc/chart-json-spec.md:2115`（M101 `features: string[]`）、`:2123`（示例顶层 `features`）、`:2142`（M8 `tasks: [{…, lane?, …}]`）
- **来源**：存量
- **判据**：review-checklist §13「示例引用实现不读取的字段」、§14.1
- **证据**：静态确定 —— `ShapChart` 只从 `series[0].data[i].feature` 取特征名（`:66` `requiredString("feature")`），全文无 `features`；`GanttChart` 全文 `lane` 零命中，行标签取 `task.name`（`:148`）
- **描述**：`features` 被描述成"排序依据"，实际顺序完全来自数据数组；`lane` 被写进每个 task，实际泳道划分不存在。两处都是"照文档写、效果不出现"
- **建议**：两处从规范删除并进「待实现」清单；若保留 `features` 作排序来源，需在 `ShapChart` 接线并校验 `features.size == data.size`

### [轻微][存量] #14 `donut` 的 `startAngle` / `showPercent` 与 `network-heatmap` 的 `showValues` / `cellGap` 未登记进规范

- **位置**：`f_chart/doc/chart-json-spec.md:1274`（M32 只列 `innerRadius` / `centerText`）、`:1215`（M68 只列 `nodes` / `colorRange`）；实现 `f_chart/src/DonutChart.cj:78-79`、`f_chart/src/NetworkHeatmapChart.cj:143-144`
- **来源**：存量
- **判据**：review-checklist §14.2「公开配置项未文档化」
- **证据**：静态确定 —— `DonutChart` 读 `startAngle`（0）与 `showPercent`（true）；`NetworkHeatmapChart` 读 `showValues`（false）与 `cellGap`（1），四项都能改变输出
- **描述**：读者无法从任何文档得知环形图可调起始角、可关百分比，网络热力图可显示数值、可调格间距，只能读源码
- **建议**：补齐四个字段（带默认值），或写「其余字段同 M31 / M43」让读者跳转

### [轻微][存量] #15 设计文档两处过期：目录树里的 `ChartSpec.cj` 不存在、里程碑表缺 M68，且未列 `ChartTime.cj` / `BarRenderer.cj`

- **位置**：`f_chart/doc/f_chart模块设计.md:39`（`ChartSpec.cj  通用信封（internal）`）、`:36-52`（目录树）、`:210-211`（`M66` 之后直接 `M69`）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」「文档过期」；§1 的"死引用"形态
- **证据**：静态确定 —— `ls f_chart/src | grep ChartSpec` 无结果，实际为 `ChartConfig.cj`（`ChartConfig.parse`），本部分 `doc/spec/add-f-chart-bar/design.md:8` 也写 `src/ChartConfig.cj`；同文档 `:295-296` 用的又是 `ChartConfig`；`M68 网络热力图 / NetworkHeatmapChart.cj` 在正文表与别名表都没有，而 `chart-json-spec.md:204` 与 `src/NetworkHeatmapChart.cj` 都存在
- **描述**：目录树是新人定位基础设施的第一入口，`ChartSpec.cj` 会让人去搜一个不存在的文件（文档侧死引用）；缺 M68 会让里程碑表与规范索引（108 行）对不上
- **建议**：`ChartSpec.cj` → `ChartConfig.cj`，补 `ChartTime.cj` / `BarRenderer.cj`（或改成"基础设施清单"表）；在 M66 与 M69 之间补 M68，并在表头注明别名 M67/M86/M87/M104/M106 见下表

### [轻微][存量] #16 通用轴范围规则「按数据范围留 5% 余量」只对曲线类成立，柱/面积默认包含 0，规范未区分

- **位置**：`f_chart/doc/chart-json-spec.md:2720`；实现 `f_chart/src/BarRenderer.cj:394-415`（正值域下界固定 0、上界 `dataMax * 1.05`）、`f_chart/src/AreaChart.cj:355-365`（含 0）、`f_chart/src/LineChart.cj:457-478`（`lineRange` 真正的双向 5%）
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、§11「与规格冲突」；§2「同一规则两套口径」
- **证据**：静态确定 —— 同一句通用规则在 `line`/`scatter` 成立、在 `bar`/`area` 不成立；柱/面积的设计文档给的是另一套（`doc/spec/add-f-chart-bar/design.md:49-52`：下界 `min(0, 数据最小值)`；`add-f-chart-area/design.md:16`：取 0 与极值的并集）
- **描述**：全正数据下规范让人预期下界 `dataMin*0.95`，实际柱/面积是 0（数据 100–110 时柱子几乎等高）。这是"坐标与数值边界"描述错误，也让规范与自己各图的设计文档矛盾
- **建议**：拆成两类并写清适用范围——类目柱/面积/堆叠「默认含 0 基线」；XY 曲线/散点「双向 5% 余量」；两条都保留"全为 `null` 时 `[0,1]`"兜底

### [轻微][存量] #17 字段命名约定自相矛盾："节点关系一律 `nodes` / `links`"，但流程图 / 决策树 / 泳道图用 `edges`

- **位置**：`f_chart/doc/chart-json-spec.md:13`（约定 2）、`f_chart/doc/f_chart模块设计.md:128`（同款约定）；违反处 `:2065`（决策树）、`:2164`（流程图）、`:2241`（泳道图「`edges` 同流程图」）
- **来源**：存量
- **判据**：review-checklist §2「同一语义只用一个字段名」正是规范自立的规则；§13「自相矛盾」
- **证据**：静态确定 —— 同文件前后矛盾，无需对照实现；实现按 `edges` 解析（`src/Flowchart.cj:199`、`src/DecisionTreeChart.cj:130`、`src/SwimlaneChart.cj:149`）
- **描述**：把桑基图的 `links` 搬到流程图会得到空边或 `MissingField`。这不是实现缺陷，是契约层命名分裂，且规范自己没给例外说明
- **建议**：§1 约定 2 补例外（`edges` 用于带标签的有向边、`links` 用于带权重流量），或统一改名并在各图注明兼容别名

### [轻微][存量] #18 规范未给任何计数型字段上限或拒绝路径，`cells` / `turns` / `tickCount` / `bins` 全是无界用户输入

- **位置**：`f_chart/doc/chart-json-spec.md:410`（`cells` 默认 100）、`:727`（`turns`）、`:86`（`tickCount`）、`:758`（`bins`）；§7「校验规则」（`:2699-2714`）只列结构与数值合法性
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度预分配 / 无界容器」「必须有量化判据与拒绝路径」；§13「关键段落缺失：限制条件缺失」
- **证据**：静态确定（文档侧）—— 规范全文没有这些字段的上限；实现侧抽查 `src/WaffleChart.cj:41-49` 只校验"≥1 的整数"，`cells` 直接决定循环次数与 `rect` 数量（`:123-125`）
- **描述**：输出体积与这几个字段线性相关，`cells=10^6` 会生成 10^6 个矩形并拼进同一个字符串。规范不告诉使用者"多大安全"，实现也没有上限，等于把 OOM 面留给调用方猜。这是文档层唯一可判定的"资源与内存"缺口
- **建议**：§7 增加「资源上限」小节（如 `cells ≤ 10000`、`tickCount ≤ 50`、`bins ≤ 1000`，超限 `InvalidValue`），实现按同一上界校验。**范围外提示**：`WaffleChart.cj:41-49` 目前无上限，属代码侧 OOM 面，留给 `.cj` 部分确认

<!-- 第 4 部分 -->

### [一般][存量] #1 Bland-Altman 复用子弹图的 `bulletNumber`，负数测量值被当成非法输入拒绝

- **位置**：`f_chart/doc/spec/add-f-chart-bland-altman/specs/chart-rendering/spec.md:39`（契约）；`f_chart/src/BlandAltmanChart.cj:68-69`（调用点）；`f_chart/src/BulletChart.cj:239-241`（拒绝逻辑）
- **来源**：存量（`git blame -L 68,69` = `4af5d9450b 2026-11-08`；快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」、§2「跨层复制 / 语义漂移」
- **证据**：静态确定 —— spec 的 Bland-Altman 校验只写「每项 MUST 提供数字型 `x` 与 `y`」，没有任何非负约束；实现却调用 `BulletChart` 的 `bulletNumber`（`BlandAltmanChart.cj:68-69`），该函数除「必须是数字」外还带 `if (number < 0.0) throw chartInvalidValue(..., "数值不能为负")`（`BulletChart.cj:239-241`），而子弹图的非负约束来自它自己的规格（`add-f-chart-bullet/specs/chart-rendering/spec.md:34`「`value`、`target` MUST 为非负数字」）。`grep -rn "bulletNumber" f_chart/src` 只有 `BulletChart.cj` 定义与 `BlandAltmanChart.cj:68,69` 两处调用，无第三个消费者。
- **描述**：Bland-Altman 的输入是两种方法对同一对象的成对测量值，测量值本身可以为负（温度、对数比值、收支差额、z 分数）。传 `{"x": -1.2, "y": 0.8}` 会在解析阶段抛 `ChartException(InvalidValue, "series[0].data[0].x 数值不能为负")`，与 spec 写的「数字型即可」相反，用户无法从规格推出这条限制。现有测试 `BlandAltmanChart_test.cj:39-56` 的样例全为正数，也没有负数用例，因此这条偏移没有被用例挡住。
- **建议**：给 `ChartJson` 加一个只做「必填 + 数字 + 有限」的通用读取（如 `requiredNumberField(json, field, path)`），Bland-Altman 改用它；`bulletNumber` 保留非负判断但改名为 `bulletNonNegativeNumber` 之类，避免名字暗示「通用数字读取」。同时在 `add-f-chart-bland-altman` 的 spec 里补一条「负数测量对」的 scenario。

### [一般][存量] #2 「读取必填数字字段」在 4 个图里各写一遍，规则已开始分叉

- **位置**：`f_chart/src/BulletChart.cj:233-243`（`bulletNumber`，额外要求非负）、`f_chart/src/BoxPlotChart.cj:241-247`（`requiredNumber`，无额外约束）、`f_chart/src/BoxScatterChart.cj:214-226`（`parseValues`，逐元素同规则）、`f_chart/src/BubbleChart.cj:121-123`（内联 `jsonNumberValue(pointJson.required(...))`）、`f_chart/src/BlandAltmanChart.cj:68-69`（复用 `bulletNumber`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」「近似重复」，判据要求点名语义差异
- **证据**：静态确定 —— 五处代码的输入-输出-副作用都是「`ChartJson` + 字段名 + 路径 → `Float64`，缺失抛 `MissingField`、类型不符抛 `InvalidValue`」，差别只有两处：`bulletNumber` 多了 `>= 0` 判断（`BulletChart.cj:239`），`parseValues` 作用于数组元素而不是具名字段。底层 `jsonNumberValue`（`ChartJson.cj:215-227`）本身已经做了「非数字 → InvalidValue」「NaN/Inf → InvalidValue」。
- **描述**：同一语义被复制 4 份、另被跨图复用 1 处后已经开始漂移——#1 就是 `bulletNumber` 的非负语义被别处复用造成的错误拒绝；`BoxPlotChart.requiredNumber` 与 `BoxScatterChart.parseValues` 的报错文案也不一致（前者 `"期望数字"`，后者同样 `"期望数字"` 但路径拼接方式不同），后续任何一处收紧（例如统一拒绝 Inf）都不会同步到其余四处。
- **建议**：在 `ChartJson` 上补两个方法：`func requiredNumber(name: String): Float64`（字段级）与 `func numberItems(name: String): Array<Float64>`（数组级），内部都走 `jsonNumberValue`；各图只保留自己真正的业务约束（子弹图非负、箱线图五数单调），删除 4 个包装函数。

### [一般][存量] #3 手写插入排序在 `f_chart` 里复制了 8 份，箱线散点每组都要 O(n²)

- **位置**：`f_chart/src/BoxScatterChart.cj:245-260`（`sortValues`）；同实现另见 `ViolinChart.cj:271-287`、`ViolinBoxChart.cj:298-313`、`SwarmChart.cj:218-233`、`RaincloudChart.cj:320-333`、`ProbabilityChart.cj:156-171`、`QQChart.cj:156-171`、`StemLeafChart.cj:160-174`（内联在茎叶图解析函数里）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 跨文件复制」、§6.4「低效算法（双层循环做排序）」、§11「重复实现导致行为漂移」
- **证据**：静态确定 —— `grep -rn "sorted\[j\] < sorted\[j - 1\]" f_chart/src` 命中 8 个文件，函数体逐行一致（拷贝到 `ArrayList` → 从 `i=1` 起向前冒泡移位 → `toArray()`），只有所属类型名不同。`add-f-chart-box-scatter/design.md:12` 只写「组内排序后用 `quantileSorted` 取 Q1 / 中位数 / Q3」，没有说明排序算法，也没有数据规模上限。
- **描述**：`BoxScatterChart` 的每组样本都走 `sortValues`（`BoxScatterChart.cj:163`），复杂度 O(n²)、含 `ArrayList` 拷贝。散点叠加箱线的图本身鼓励大样本（每组上千点才看得出分布），n = 10 000 时比较次数约 5×10⁷ 量级；同时这套排序被 8 处复制，任何一处修正（例如改成稳定排序、处理 NaN）都要改 8 遍。
- **建议**：抽成模块内单一工具（放 `ChartScale.cj` 或新建 `ChartSort.cj`）：`internal func sortedFloats(values: Array<Float64>): Array<Float64>`，实现用 `sort` 的 `Float64` 比较，8 处调用点全部替换；`quantileSorted` 的入参不变。等价性用例需覆盖：重复值、负数、单元素、全相等。
- **说明**：这条的**重复逻辑部分**是静态确定的；「它是不是热点」没有 profile 数据，见「待验证假设」#1。

### [一般][存量] #4 连续轴范围计算有 3 套实现，留白规则互相不一致

- **位置**：`f_chart/src/BoxPlotChart.cj:249-264` 与 `f_chart/src/BoxScatterChart.cj:228-243`（两份逐字相同的 `resolveYRange`，两侧都加 5% 留白）；同族实现另见 `ViolinChart.cj:254`、`ViolinBoxChart.cj:281`、`SwarmChart.cj:201`；`f_chart/src/LineChart.cj:457-478`（`lineRange`，只给一侧显式边界时另一侧**不留白**）；`f_chart/src/BlandAltmanChart.cj:87-110`（第三次实现：x 轴 5%、y 轴 8% 留白）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 换算复制」，并要求点名语义差异
- **证据**：静态确定 —— 三套规则的差异可以逐条列出：(a) `resolveYRange`（`BoxPlotChart.cj:249-264` 与 `BoxScatterChart.cj:228-243` 完全一致）在 `yAxis.min` 只给一侧时，另一侧仍按 `0.05 × span` 留白；(b) `lineRange`（`LineChart.cj:466-473`）只给一侧时另一侧直接取数据极值，不留白；(c) `BlandAltmanChart` 内联版对 x 用 `0.05`、对 y 用 `0.08`。`BubbleChart` 走的是 (b)（`BubbleChart.cj:148-149`），`BoxScatterChart` 走的是 (a)。
- **描述**：同一份 `xAxis.min` / `yAxis.min` 配置在不同图类型上得到不同的绘图区范围，Bubble（连续双轴散点）与 Bland-Altman（同为连续双轴）在同一数据下画出的点位置不一致；`add-f-chart-bubble/design.md:11` 写「复用 `drawXAxisNumeric` 与 `drawYAxis`」，即设计上是复用轴能力，但范围计算并没复用。
- **建议**：把 `lineRange` 提成唯一入口，用参数显式表达差异：`chartAxisRange(dataMin, dataMax, axisMin, axisMax, padRatio, path)`；`BoxPlot` / `BoxScatter` / `Violin*` / `Swarm` 的 `resolveYRange` 删除后统一调用（留白比 0.05），Bland-Altman 传 0.05 / 0.08。差异参数化后，行为差异就变成可读的常量而不是隐式约定。

### [一般][存量] #5 `bulletRangeColor` 用取模轮转，第 7 个区间起颜色回到最浅，违反「由浅到深」的规格

- **位置**：`f_chart/doc/spec/add-f-chart-bullet/specs/chart-rendering/spec.md:7`、`f_chart/doc/spec/add-f-chart-bullet/design.md:16`（契约）；`f_chart/src/BulletChart.cj:246-249`（实现）
- **来源**：存量（`git blame -L 246,249` = `a7273653af 2026-11-08`；快照模式无基线可比）
- **判据**：review-checklist §13「文档承诺与实现不符」、§11「语义与命名不符」
- **证据**：静态确定 —— spec 要求「颜色 MUST 由 `bulletRangeColor` 按区间序号返回由浅到深的灰色」，design 写死色阶「从 `#efefef` 到 `#d0d0d0`」；实现是 6 元素数组 `["#efefef","#e0e0e0","#d0d0d0","#c0c0c0","#b0b0b0","#a0a0a0"]` 后用 `shades[index % shades.size]`（`BulletChart.cj:247-248`）。`ranges` 只要求「非空、全为正数且严格递增」（`BulletChart.cj:75-95`），个数无上限。
- **描述**：两处不一致：一是色阶终点是 `#a0a0a0` 而不是文档写的 `#d0d0d0`；二是第 7 个区间（index=6）取模回到 `#efefef`（最浅），第 8 个又变成 `#e0e0e0`。于是「越靠右的区间底色越深」的视觉编码在 7 段以上会反向，读者会把最大区间误读成最小背景。子弹图通常 3–5 段，但配置没有上限，也没有校验或截断。
- **建议**：改为「用区间序号在固定色阶上插值/取整」且对 `index >= shades.size` 收敛到最深色（`shades[min(index, shades.size - 1)]`），并把 design 的终点色与实现对齐；或在 `ranges` 校验里加上「最多 N 段」并同步 spec。

### [一般][存量] #6 Bland-Altman 右端界限标签只预留固定 52px，数值位数一多就溢出画布右边

- **位置**：`f_chart/doc/spec/add-f-chart-bland-altman/specs/chart-rendering/spec.md:30`（「在右端标注数值」）；`f_chart/src/BlandAltmanChart.cj:144-147`（`rightLabelWidth: 52.0`）、`f_chart/src/BlandAltmanChart.cj:211-217`（文本起点 `plot.right() + 6.0`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」、§13「文档承诺与实现不符」（承诺标注数值，实际可能画到画布外）
- **证据**：静态确定（按模块自带的宽度估算函数推算）—— `ChartFrame` 用 `right = padding.right + rightLabelWidth` 算绘图区右边界（`ChartFrame.cj:86,91`），默认 `padding.right = 24`（`ChartConfig.cj:23`），所以留给标签的横向空间是 `24 + 52 - 6 = 70px`；标签文本由 `${label} ${chartFormatTick(...)}` 拼成（`BlandAltmanChart.cj:213`），`label` 是「均值/下限/上限」两个汉字。按 `chartTextWidth`（`ChartScale.cj:113-123`，CJK 记 1em、其余 0.56em，标签字号 `fontSize - 1 = 11`）估算：`下限 -1.234` ≈ 2×11 + 7×6.16 ≈ 65px（勉强放下），`下限 -1234.567` ≈ 2×11 + 11×6.16 ≈ 90px，超出 20px 即被画布裁掉；用户自定义 `yAxis.labelFormat`（`ChartConfig.cj:80` 默认 `{value}`，可任意加前后缀）时必然溢出。`grep -rn "clip" f_chart/src --include=*.cj` 在生产代码中无 `clipPath`，越界内容不会被裁成绘图区内，而是被 SVG 视口裁掉。
- **描述**：规格要求「在右端标注数值」，实现把一个与数据无关的常量 52 当成标签宽度上界，于是测量值量级一大（Bland-Altman 差值常见几十到几百）或换 `labelFormat`，标注文字末端就跑出 `width` 之外，右侧数值不可读。三个标签还共用同一固定基准，无法按各自宽度调整。
- **建议**：改为先把三条标签文本格式化好，用 `chartTextWidth` 取最大值动态传入 `rightLabelWidth`（形如 `max(width) + 12`），再建 `ChartFrame`；或退一步，把标签放到绘图区内部右下角并加背景，避免依赖右外边距。

### [一般][存量] #7 显式轴范围小于数据时，图元无裁剪地画到绘图区之外

- **位置**：`f_chart/src/BulletChart.cj:184-213`（区间条 / 值条 / 目标线按 `xScale.scale` 直接定位）；`f_chart/src/BlandAltmanChart.cj:184-192`（散点、以及 `drawLimit` 的三条参考线）；`f_chart/src/BoxPlotChart.cj:233-235`（`outliers`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 越界」、§13「坐标与边界」
- **证据**：静态确定（几何）+ 待确认（契约）—— `BulletChart` 的 `max` 取 `xAxis.max`（`BulletChart.cj:126-129`）后直接 `xScale.scale(item.value)`（`194`）、`xScale.scale(item.target)`（`204`）、区间条右端 `xScale.scale(upper)`（`183`），没有任何 `min/max` 夹取；`xAxis.max = 100`、`value = 120` 时 `valueX < frame.plot.x`，矩形左边界越过 y 轴刻度文字区。`BlandAltmanChart` 对 `yAxis.min/max` 同理（`yScale.scale(pair.diff)`），散点与参考线会画到标题或 x 轴刻度上。整模块 SVG 输出无 `clipPath`（`grep -rn "clip"` 只命中 `tui/TuiCanvas.cj` 的文本截断）。规格未规定「越界数据应裁剪还是应报错」，故契约层面记 `待确认`。
- **描述**：`xAxis.max` / `yAxis.min` 是公开配置（`ChartConfig.cj:75-76`），用户常用它做「固定刻度对齐」。一旦数据超过显式范围，图元就叠到轴标签、标题、图例上，视觉上像渲染错位；子弹图尤其容易，因为 `target` 常大于当前上限。
- **建议**：二选一并写进 spec——(a) 生成 `clipPath`（`SvgBuilder` 加 `clipRect`）把绘图区形状包起来；(b) 在 `*Scale.scale` 返回后统一夹取到 `[plot.x, plot.right()]` / `[plot.y, plot.bottom()]`，并在 spec 补一条「超范围值被裁剪」的 scenario。同时给 `xAxis.max < max(value, target, ranges.last)` 的子弹图加校验或告警。

### [轻微][存量] #8 箱线图箱宽多了一条「不超过 0.9 槽宽」的上限，`design.md` 未记载

- **位置**：`f_chart/doc/spec/add-f-chart-boxplot/design.md:9`（「箱宽 `bandWidth * 0.5`，最小 12」）；`f_chart/src/BoxPlotChart.cj:197`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」
- **证据**：静态确定 —— 实现是 `minFloat(maxFloat(band.bandWidth * 0.5, 12.0), band.bandWidth * 0.9)`，多一层 `0.9 × bandWidth` 上限；design 只写「最小 12」。
- **描述**：类目数一多（`bandWidth` 小于约 13.3）时，实际箱宽等于 `0.9 × bandWidth` 而不是 design 承诺的「最小 12」，两文档对同一场景给出不同预期；上限本身是合理的（避免箱体盖住相邻类目），只是没写。
- **建议**：design 改成「箱宽 `bandWidth * 0.5`，夹取到 `[min(12, 0.9×bandWidth), 0.9×bandWidth]`」，并说明上限是为了留出相邻类目间隙。

### [轻微][存量] #9 子弹图目标线高度：`design.md` 写「行顶 20% 到 80%」，实现是区间条高度的 70%

- **位置**：`f_chart/doc/spec/add-f-chart-bullet/design.md:18`；`f_chart/src/BulletChart.cj:205-213`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」
- **证据**：静态确定 —— 实现把目标线从 `centerY - rangeHeight / 2.0` 画到 `centerY + rangeHeight / 2.0`，`rangeHeight = bandWidth * 0.7`（`178`），即行高的 70%、居中；design 的「20% → 80%」是行高的 60%。
- **描述**：差异只有 10% 行高，但两处口径不一致，按 design 实现会得到更短的目标线；文档读者无法判断哪个是准的。
- **建议**：design 改为「从 `centerY - 0.35×bandWidth` 到 `centerY + 0.35×bandWidth`（与区间色带同高）」，或把实现改成 0.2/0.8 并同步。

### [轻微][存量] #10 气泡图 `design.md` 承诺「填充透明度 0.6、同色描边」，实现与 SVG 工具层都不支持

- **位置**：`f_chart/doc/spec/add-f-chart-bubble/design.md:9`；`f_chart/src/BubbleChart.cj:212-215`；`f_chart/src/ChartSvgKit.cj:123-137`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现相反」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `BubbleChart` 画点只有 `kit.circle(x, y, radius, fill: color, className: "bubble")`，无透明度、无描边；`ChartSvgKit.circle` 的签名只有 `fill!` 与 `className!`（`ChartSvgKit.cj:123-128`），函数体只写 `fill`（`135`），没有 `fill-opacity` / `stroke`，因此当前工具层**无法**表达 design 承诺的样式（`rect` 有 `fillOpacity` 参数，`circle` 没有）。
- **描述**：气泡互相重叠时，design 的 0.6 透明 + 同色描边是区分叠加层次的关键手段；实际输出是不透明实心圆，重叠区域完全遮挡，图上「哪里更密」看不出来。属于设计承诺未落地，而不是渲染参数写错。
- **建议**：给 `ChartSvgKit.circle` 补 `stroke!: ?String = None`、`strokeWidth!: Float64 = 0.0`、`fillOpacity!: Float64 = 1.0`（与 `rect` 对齐），`BubbleChart` 传 `fillOpacity: 0.6` 与 `stroke: color`；若决定不支持，就把 design 第 9 行改成实际样式。

### [轻微][存量] #11 气泡图未把 `xAxis.labelRotate` 计入底部留白，旋转标签会压到轴标题/画布边缘

- **位置**：`f_chart/src/BubbleChart.cj:177`；对照 `f_chart/src/BoxPlotChart.cj:169-173`、`f_chart/src/BoxScatterChart.cj:129-133`、`f_chart/src/BlandAltmanChart.cj:138-142`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 布局」、§13「同类实现不一致」
- **证据**：静态确定 —— 气泡图固定传 `config.theme.fontSize + 12.0`（默认 12 → 24px）作为 `xLabelHeight`；其余同族图都按 `if (config.xAxis.labelRotate == 0.0) fontSize + 12.0 else 48.0` 预留。`ChartFrame.drawXAxisNumeric` 在旋转时把标签放在 `plot.bottom() + 10`、`anchor: "end"`（`ChartFrame.cj:297-309`），需要约 48px 的竖直空间。
- **描述**：`labelRotate` 是公开配置（`ChartConfig.cj:79`），气泡图开了旋转后只有 24px 底部空间，标签会与 `xAxis.title`（`plot.bottom() + fontSize + 14`）重叠并可能超出画布。`add-f-chart-bubble/design.md:11` 声称「复用 `drawXAxisNumeric` 与 `drawYAxis`」，但留白没有跟着复用同一规则。
- **建议**：把这段「按是否旋转决定 xLabelHeight」的判断抽成 `ChartFrame` 的静态辅助（如 `ChartFrame.xLabelHeight(config)`），四处调用点统一；气泡图改为调用它。

### [轻微][存量] #12 `CalendarHeatmapAlias_test` 注释写「七个星期标签」，与断言 4 及 proposal 冲突

- **位置**：`f_chart/src/CalendarHeatmapAlias_test.cj:71`；对照 `f_chart/doc/spec/add-f-chart-calendar-alias/proposal.md:8`（「4 个星期标签」）、`CalendarHeatmapAlias_test.cj:76`（断言 `== 4`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」（注释即文档）
- **证据**：静态确定 —— 注释是「三个月与七个星期标签」，同一用例下一行断言 `count(svg, "class=\"weekday-label\"") == 4`；实现侧 `CalendarHeatmapChart` 固定输出 4 条星期标签（`CalendarHeatmapChart.cj:223-233`，`for (position in 0..4)`，取周一/三/五/日或周日/二/四/六）。
- **描述**：日历热力图是 7 行 × N 列的网格，注释里的「七个星期」大概是「七行」的口误；但对读注释的人来说，它和断言、和 proposal 的「4 个星期标签」同时对不上，会怀疑到底该断言 4 还是 7。
- **建议**：注释改成「三个月与四个星期标签（网格 7 行，只标注 4 行）」。

### [轻微][存量] #13 `calendar-alias/design.md` 称别名测试方式与 M104 一致，但 M104（`tag-cloud`）没有 `*Alias_test.cj`

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-alias/design.md:8`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符 / 指向不存在的结构」
- **证据**：静态确定 —— `ls f_chart/src | grep -i alias` 只有 4 个：`CalendarHeatmapAlias_test.cj`、`FunnelAlias_test.cj`（M86）、`SankeyAlias_test.cj`（M67）、`WaterfallAlias_test.cj`（M87）；`doc/chart-json-spec.md:241` 的 M104 是 `tag-cloud` / `WordCloudChart.cj`，对应测试是 `TagCloud_test.cj`（`grep -rln "tag-cloud" f_chart/src` 命中 `TagCloud_test.cj`、`WordCloudChart.cj`、`ChartGallery_test.cj`）。
- **描述**：design 用「与 M86/M87/M104 的别名测试方式一致」来说明本测试的定位，但三个参照物里 M104（`tag-cloud`）并没有独立别名测试，仓库里第 4 个 `*Alias_test` 对应的是 M67（`sankey`）。参照清单错了一项，按它去核对会找不到对应文件。
- **建议**：把 M104 换成 M67，写成「与 M67/M86/M87 的别名测试方式一致」。

### [轻微][存量] #14 子弹图 proposal 声称新增的 `bulletRange` 函数不存在，区间校验被内联

- **位置**：`f_chart/doc/spec/add-f-chart-bullet/proposal.md:13`；实现 `f_chart/src/BulletChart.cj:73-95`
- **来源**：存量（`git blame -L 73,95` = `a7273653af 2026-11-08`；快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 指向不存在的符号」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `grep -rn "bulletRange\b" f_chart/src` 只命中 `bulletRangeColor`，`bulletRange` 既无定义也无调用；proposal 写「新增内部 `bulletRangeColor` 与 `bulletRange`（校验并返回排序后的区间上界）」，实际「非空 + 正数 + 严格递增」三项校验全部内联在 `draw` 的 `ranges` 解析循环里（`BulletChart.cj:73-95`），无法脱离完整 JSON 单测。
- **描述**：文档读者会去找一个不存在的函数；更实质的损失是 proposal 当初抽出该函数的目的（可单独单测区间校验）落空，`[50, 50, 100]` 这类负向用例只能通过整图渲染触发。
- **建议**：二选一——按 proposal 抽出 `internal func bulletRange(json: ChartJson, itemPath: String): Array<Float64>` 并把 `73-95` 搬进去，或把 proposal 该行改成「区间校验内联于 `BulletChart.draw`」。

<!-- 第 5 部分 -->

### [严重][存量] #1 校准曲线 spec 的轴语义与实现相反：x、y 两轴同时取反，整幅图相对规格旋转 180°

- **位置**：`f_chart/doc/spec/add-f-chart-calibration/specs/chart-rendering/spec.md:16`（对角线「连接左下角与右上角」）、`:30`（轴「默认包含 0 到 1」）；实现 `f_chart/src/CalibrationChart.cj:129-130`（属其他子轮文件）；样例 `f_chart/charts/M096-calibration.svg`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `LinearScale` 的契约写在类注释里：「`topPixel` 对应最大值，`bottomPixel` 对应最小值」（`ChartScale.cj:23`），`scale()` 为 `bottomPixel - (v-min)/span*(bottomPixel-topPixel)`（`ChartScale.cj:38-45`）。正确用法是 x 传 `(plot.right(), plot.x)`、y 传 `(plot.y, plot.bottom())`（`CandlestickChart.cj:145` 即此写法，`plot` 的 `y` 是上边界，见 `ChartFrame.cj:91`）。`CalibrationChart.cj:129-130` 传的却是 `LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())` 与 `LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)`，两个轴同时取反。仓库提交的样例印证：`M096-calibration.svg` 里 y 轴刻度 `0` 在 `y=74px`（顶）、`1` 在 `y=432px`（底）；x 轴刻度 `0` 在 `x=776px`（右）、`1` 在 `x=56px`（左）；首点 `(0.05, 0.08)` 画在 `cx=740.008 cy=102.64`（右上）。
- **描述**：spec 要求对角线「左下—右上」、轴「0 到 1」，实物是 180° 旋转（0 在右上、1 在左下）。因为两端点互换，对角线线段自身仍是同一条，看起来「没问题」；但数据点被转到对角线另一侧：规格里「实际频率 > 预测概率（在对角线上方，说明模型低估）」的点，画出来落在线下方，高估/低估判读整体反过来（`proposal.md:5` 明确这对结论是校准图的用途）。现有用例只数元素个数（`CalibrationChart_test.cj:61-62` 断言 1 条 line、6 个 point），没有任何坐标断言，所以测试全绿。
- **建议**：`CalibrationChart.cj:129-130` 改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)` / `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`，并补一条坐标断言（`(0,0)` 落在 `plot` 左下、`(1,1)` 落在右上）。**归属提示**：修法落在 `src/CalibrationChart.cj`（其他子轮文件），本部分的取证点是 spec 的两行契约与样例 SVG，合并时请只计一次。

### [一般][存量] #2 校准曲线 README 承诺「将预测概率分箱」，design 与实现都说 `binCount` 不参与绘制

- **位置**：`f_chart/doc/spec/add-f-chart-calibration/design.md:5`（「`binCount` 仅做正数校验，不影响绘制（数据已分箱）」）；对照 `f_chart/README.md:2191`、`f_chart/src/CalibrationChart.cj:31-37`、`:56-69`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」、§1「读了不用」
- **证据**：静态确定 —— `binCount` 只在 `CalibrationChart.cj:31-37` 做一次 `value < 1.0 || value != floor(value)` 校验，全文件不再引用；数据点直接来自 `series[0].data` 的 `x`/`y`（`56-69`），随后 `sortLiftPoints` 排序，没有分箱、也没有按箱取均值。README 写「绘制方式：将预测概率分箱，横轴为平均预测值、纵轴为实际正例率」（`2191`）。design 与实现一致，README 与实现相反。
- **描述**：用户按 README 传入未分箱的原始 `(预测概率, 标签)` 并设 `binCount = 10`，期望 10 个箱，实际得到「每个样本一个点」的折线；`binCount` 合法时完全无声。这是「看起来生效、实际不生效」的开关，比缺功能更难发现（图仍能画出来，只是形状与预期不同）。
- **建议**：二选一 —— (a) 按 `binCount` 均分概率区间、箱内取均值（缺省按 sqrt(n) 定箱数）；(b) 保留现状并把 `README.md:2191` 改成「数据须由调用方预先分箱；`binCount` 仅做正数校验，不影响绘制」。

### [一般][存量] #3 日历热力图 spec 的「`date` MUST 为 `YYYY-MM-DD`」只有形态校验，`2026-02-30` 被静默顺延成 `2026-03-02`

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:39`（校验 requirement）；实现 `f_chart/src/ChartTime.cj:27-40`（属其他子轮文件）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「边界校验缺失 / 输入被静默改写」
- **证据**：静态确定 —— `parseDays` 只检查 `bytes.size < 10`、两个 `-` 位置、以及 `month < 1 || month > 12 || day < 1 || day > 31`（`ChartTime.cj:31-37`），随后直接进 `daysFromCivil`（`ChartTime.cj:59-71`），没有月长与闰年校验。按该函数算法复算：`2026-02-30` 的 `doy` 比 `02-28` 多 2 天，等价于 `2026-03-02`；`2026-04-31` 等价于 `2026-05-01`。`CalendarHeatmapChart` 拿天数直接算网格（`CalendarHeatmapChart.cj:56`、`:183-216`），既不报错也不与输入字符串对账。
- **描述**：spec 把「`date` MUST 为 `YYYY-MM-DD`」当校验契约，实现只做到「形如 + 数字在区间内」。两种后果：范围覆盖到被顺延的月份时，`2026-02-30` 的值静默画进 3 月 2 日那格；范围只到 2 月时，报错文案是「日期 2026-03-02 超出 startDate/endDate 范围」（`CalendarHeatmapChart.cj:98`），用户按自己填的 `2026-02-30` 对不上。同一套 `ChartTime.parseDays` 被全部时间轴图复用，影响面不止日历图。
- **建议**：`parseDays` 增加月长校验（用 `partsOfDays(daysFromCivil(y,m,d))` 反算三元组与输入比对，一次整数运算），不合法抛 `chartInvalidValue(path, "日期不存在")`；或在 spec 里明确只做形态校验、月内越界按顺延处理，去掉 `MUST 为 YYYY-MM-DD` 的强表述。

### [一般][存量] #4 日历热力图按天物化且区间无上限：`[startDate, endDate]` 每天都出一个矩形，配置抄错一位即可放大到数十 MB

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:7`（「MUST 为 `[startDate, endDate]` 内的每一天绘制一个 `calendar-cell`」）；实现 `f_chart/src/CalendarHeatmapChart.cj:153-154`、`:183-216`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界物化 / 缺少拒绝路径」
- **证据**：静态确定（规模按代码常量推算）—— `dayCount = endDays - startDays + 1` 完全由两个日期入参决定（`153`），随后 `for (offset in 0..dayCount)` 逐日输出 `rect` + 可能的 `month-label`（`183-216`），全程没有上限、没有分页、没有「区间过大」分支；spec 也没定义上限。日期解析接受 4 位年（`ChartTime.cj:31`），`startDate=0001-01-01`、`endDate=9999-12-31` 合法 ⇒ `dayCount ≈ 3.65e6`。按样例实测密度（`charts/M044-calendar-heatmap.svg`：90 格 / 10747 字节 ≈ 119 字节每格）外推，最终 SVG 约 **430 MB**，`StringBuilder` 扩容峰值再乘 1.5–2 倍。
- **描述**：规模与数据量脱钩、只由配置字符串驱动：`startDate`/`endDate` 打错一位（`2099` 写成 `2999`）就是 36 万格 ≈ 43 MB 输出，而 `draw` 把整份 SVG 拼在内存里返回（`builder.toSvgString()`）。数据只有 6 条也毫无保护作用，正是 §5 里最难被「按数据量压测」发现的一类。当前定级为一般（默认范围取数据 min/max，只有显式给极端区间才触发），但一旦触发就是数百 MB 级的单次分配。
- **建议**：spec 与实现同时加硬上限（如 `dayCount <= 366 * 10`，超出抛 `chartInvalidValue("endDate", "区间过大，最多 N 天")`，N 走 `ChartConfig` 可配）；要支持长区间就改成按月聚合或分页产出多份 SVG，而不是逐日矩形。

### [轻微][存量] #5 蜡烛图 design 写「实体宽度取 `bandWidth * 0.6`」，实现另有 18px 上限

- **位置**：`f_chart/doc/spec/add-f-chart-candlestick/design.md:15`；对照 `f_chart/src/CandlestickChart.cj:166`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 默认值与源码不符」
- **证据**：静态确定 —— 实现是 `let bodyWidth = minFloat(band.bandWidth * 0.6, 18.0)`（`CandlestickChart.cj:166`），design 只写了 `bandWidth * 0.6`。样例 `charts/M083-candlestick.svg` 绘图区宽约 720、4 根蜡烛 ⇒ `bandWidth ≈ 180`、`0.6 × 180 = 108`，实际实体宽度 18。
- **描述**：18px 上限是为「蜡烛很少时别变成大方块」加的，但文档没写；读 design 的人按 0.6 推算会差 6 倍，也无法从规格判断「宽蜡烛」的视觉预期。
- **建议**：design 改为 `min(bandWidth * 0.6, 18px)`；若 18 也打算可调，补进 spec 字段表。

### [轻微][存量] #6 蜡烛图 proposal 声称新增内部 `candlestickRange(items)`，仓库里没有这个符号

- **位置**：`f_chart/doc/spec/add-f-chart-candlestick/proposal.md:12`；对照 `add-f-chart-candlestick/tasks.md:5`、`f_chart/src/CandlestickChart.cj:103-108`、`:196-198`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「指向不存在的结构」
- **证据**：静态确定 —— `grep -rn "candlestickRange" f_chart/src` 无命中；`CandlestickChart.cj` 只有 `candlestickUp`（`196-198`）一个 internal 函数，纵轴范围在 `draw` 内联算（`103-108` 的 `dataMin`/`dataMax`/`span` + 5% 留白）。同变更的 `tasks.md:5` 也只写「`candlestickUp` / `CandlestickChart` 实现并转绿」。
- **描述**：proposal 的 Impact 段承诺两个内部函数，实际落了一个；`tasks.md` 与代码一致，说明是 proposal 写完没回改。归档文本与代码对不上会让后来者去找一个不存在的扩展点。
- **建议**：删掉 `candlestickRange` 那句；或真的补一个 `internal func candlestickRange(candles: Array<Candle>): Array<Float64>` 把 `103-108` 抽出并加单测（能直接测 5% 留白边界）。

### [轻微][存量] #7 同一变更内 `binCount` 的约束自相矛盾：proposal 写「正奇数」，design / spec / 实现是「正整数」

- **位置**：`f_chart/doc/spec/add-f-chart-calibration/proposal.md:11`；对照 `add-f-chart-calibration/design.md:5`、`add-f-chart-calibration/specs/chart-rendering/spec.md:39`、`f_chart/src/CalibrationChart.cj:33-34`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— proposal：「`binCount`（可选，正奇数校验）」；design：「仅做正数校验」；spec：「提供 `binCount` 时 MUST 为正整数」，场景只覆盖 `binCount = 0`；实现 `value < 1.0 || value != floor(value)`，`4` 与 `3` 没有任何区别。
- **描述**：归档四件套对同一字段给了两种约束，读者无法判断偶数是否合法。由于 `binCount` 目前不参与绘制（见 #2），这条矛盾暂时只在文字层，但会直接变成用例分歧。
- **建议**：统一为「正整数」，补一条 `binCount = 2.5` 或 `-1` 的非法场景，别只测 `0`。

### [轻微][存量] #8 变形地图的 `colorRange` 只生效前 3 个颜色，第 4 色起被静默丢弃，spec / design 都没写色数上限

- **位置**：`f_chart/doc/spec/add-f-chart-cartogram/specs/chart-rendering/spec.md:35`、`add-f-chart-cartogram/design.md:23`；对照 `f_chart/src/CartogramChart.cj:119-128`、`f_chart/src/HeatFlameChart.cj:271-272`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「只处理部分输入」、§13「文档未写约束」
- **证据**：静态确定 —— `heatFlameColor` 在 `colors.size >= 3` 时直接 `heatmapColor(value, colors[0], colors[1], colors[2])`（`HeatFlameChart.cj:271-272`），其余元素只被 `SvgColor.tryParse` 校验过（`CartogramChart.cj:119-128`）就再没用到；`size == 2` 走两色插值，`size == 1` 返回单色。spec 与 design 都只要求「至少两个合法颜色」，没有上限或「多余颜色被忽略」的说明。
- **描述**：同一字段名在日历图是 N 档离散映射（`calendarColor` 用 `floor(ratio * size)` 分档，`CalendarHeatmapChart.cj:253-268`），在变形地图是 3 停靠点线性插值。用户给 5 个颜色、期望 5 档业务配色，实际只生效前 3 个且不报错。
- **建议**：spec / design 写明「只支持 2 或 3 个颜色」；实现里对 `size > 3` 抛 `chartInvalidValue`（比静默截断更容易被发现）；要支持 N 色则把插值改成按 `size` 均分的多段。

### [轻微][存量] #9 日历热力图的「校验」requirement 少于实现三条：`series` 数量、`weekStart` 非法值、空数据且无显式范围

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:39`；对照 `f_chart/src/CalendarHeatmapChart.cj:35`、`:68-70`、`:103-106`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「只做了一半的分支」、§13「文档承诺不完整」
- **证据**：静态确定 —— 实现在 `seriesItems.size != 1`（`35`）、`dayList.isEmpty() && (startText.isNone() || endText.isNone())`（`68-70`）、`weekStart != "mon" && != "sun"`（`103-106`）三处都抛 `InvalidValue`；spec 的校验 requirement（`39`）只列 date / value / 范围倒置 / 越界 / colorRange / cellSize / series 缺失 / type 八项，这三条都没写，也没有对应 Scenario。相邻约束只落一半：`series` 缺失写 `MissingField`，`series` 多于 1 个却没写。
- **描述**：spec 是使用者写用例与集成测试的依据；按 spec 写的用例集覆盖不到这三条，实现回归（例如允许 2 个系列后静默只画第一个）不会被契约层发现。
- **建议**：`39` 的 MUST 列表补「`series` MUST 恰好 1 个」「`weekStart` MUST 取 `mon` / `sun`」「未给 `startDate`/`endDate` 时 `data` MUST 非空」，各配一个 Scenario。

### [轻微][存量] #10 `calendar-alias` 的 spec delta 复述 `calendar-heatmap` 的契约，且已出现漂移（`weekday-label` 数量只在 alias 侧有要求）

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-alias/specs/chart-rendering/spec.md:14-22`；对照 `add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md:28-39`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（需求复制）」
- **证据**：静态确定 —— alias spec 的「颜色分档」（`14-17`）与 heatmap spec 的「日历颜色分档」（`28-35`）是同一条契约；alias 的「类型不匹配 → `UnsupportedChart`」（`19-22`）是 heatmap 校验 requirement（`39`）里同一句的复述。同时 alias spec 的文档示例（`9-12`）要求「输出 4 个 `weekday-label`」，而 `grep -rn "weekday-label" doc/spec/add-f-chart-calendar-heatmap/` 无命中，heatmap spec 全文没有这个 class；实现固定输出 4 条（`CalendarHeatmapChart.cj:218-233`）。
- **描述**：M106 是「复用 M44」的里程碑，delta 里再声明一遍同样的行为，等于同一契约有两份权威文本；现在已经不同步——星期标签数量的要求只存在于 alias 一侧。改 M44 行为时若只更新 heatmap spec，alias spec 会变成过期契约。样例侧是好的：`cmp charts/M044-calendar-heatmap.svg charts/M106-calendar-heatmap.svg` 无差异（均 10747 字节），确实复用了同一实现。
- **建议**：alias spec 只保留「M106 复用 `CalendarHeatmapChart`，与 M44 同类型同渲染规则」一条，颜色分档 / 类型不匹配 / 标签数量都改成引用 heatmap spec 的路径，避免两份文本各自演化。

### [轻微][存量] #11 蜡烛图四个价格经 `bulletNumber` 解析，被隐式加上「不能为负」；spec 只要求「数字型」

- **位置**：`f_chart/doc/spec/add-f-chart-candlestick/specs/chart-rendering/spec.md:39`；对照 `f_chart/src/CandlestickChart.cj:74-77`、`f_chart/src/BulletChart.cj:234-243`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「契约与实现不符」、§11「语义与命名不符」
- **证据**：静态确定 —— `open`/`high`/`low`/`close` 全由 `bulletNumber` 解析（`CandlestickChart.cj:74-77`），该函数除「必须是数字」外还带 `if (number < 0.0) throw chartInvalidValue(..., "数值不能为负")`（`BulletChart.cj:239-241`）；非负约束来自子弹图自己的规格。蜡烛图 spec 的校验只写「MUST 提供数字型 `open`、`high`、`low`、`close`」。价格区间校验本身与 spec 一致（`CandlestickChart.cj:78-83`）。
- **描述**：负价格/负价差在真实数据里存在（2020-04 WTI 结算价为负，价差与基差序列更是常态）。传 `{"open": -1, ...}` 会在解析阶段抛 `InvalidValue: 数值不能为负`，与 spec 的「数字型即可」相反，用户无法从规格推出这条限制；`CandlestickChart_test.cj` 全为正数，没有覆盖。
- **建议**：改用无符号约束的解析（`volcanoNumber`，`VolcanoChart.cj:228-234`，实践上只校验「数字」），或把 `bulletNumber` 拆成 `requireNumber` + `requireNonNegative`；若确实要禁止负价，就在 spec 校验 requirement 里显式写「四个价格 MUST 为非负数字」。

<!-- 第 6 部分 -->

### [严重][存量] #1 `CirclePackingChart` 的四个树遍历都是无深度上限的递归，深度等于节点数，长链输入必崩

- **位置**：`f_chart/src/CirclePackingChart.cj:112`（`resolveTotals(rootNode, 0, nodes.size)`）、`:146-168`（`resolveTotals`）、`:170-188`（`sortChildren`）、`:190-219`（`layoutChildren`）、`:221-240`（`drawNode`）；相关条款：`f_chart/doc/spec/add-f-chart-circle-packing/specs/chart-rendering/spec.md:34` 的校验清单未限制节点数或层级深度
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归：深度由输入决定」
- **证据**：静态确定 —— 递归深度上界由输入决定且代码中没有任何常量上限：`nodes` 数组长度不限（`:60-64` 只判非空），校验只要求「恰好一个根 + parent 存在」（`:108-110`），因此 `[{root}, {a,parent:root}, {b,parent:a}, …]` 这种 N 级链是完全合法的输入；`resolveTotals` / `sortChildren` / `layoutChildren` / `drawNode` 各自沿 `children` 递归一层。传进去的第三参 `total: Int64` 实际是 `nodes.size`，守卫 `depth > total`（`:147`、`:171`、`:197`）只能拦住「深度 > 节点数」，对链状输入等于没有上限。`layoutChildren`/`drawNode` 每帧还带 5 个参数与多次 `Float64` 运算，栈帧不小。具体在 N 等于多少时爆栈取决于 SDK 默认线程栈大小，需实测，但「无上限」这一点是静态确定的。
- **描述**：这是本部分唯一会导致进程崩溃的路径。用户只要把层级图的输入摊平成一条链（组织架构、目录树、BOM 展开都会出现深链），`draw` 就会在 `resolveTotals` 或 `drawNode` 里抛栈溢出；由于 `draw` 没有捕获，异常会穿透到调用方。同一份数据用 `sum` 之外的任何字段都不影响——校验阶段（`:96-110`）不会因为深链报错，错误要等到递归时才发生，定位成本高。
- **建议**：把 `resolveTotals`/`sortChildren` 改成显式栈（`ArrayList<(node, depth)>` 后序遍历），`layoutChildren`/`drawNode` 用队列做广度遍历；同时在解析阶段加一条显式上限（如 `maxDepth` 默认 64，超过抛 `InvalidValue` 并在 spec 里写明），让「太深」变成可诊断的输入错误而不是崩溃。

### [一般][存量] #2 `ComboChart` 左右轴的柱组从同一 band 起点起画，双轴柱互相重叠

- **位置**：`f_chart/src/ComboChart.cj:498-501`（`drawBars` 分别画左右两组）、`:516-522`（两组各自 `slot = band.bandWidth / groupCount` 且都从 `band.bandStart(index)` 起步）；契约见 `f_chart/doc/spec/add-f-chart-combo/design.md:9`（「每组占一个子槽」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「与规格冲突」、§10「正确性：坐标与边界」
- **证据**：静态确定 —— `drawBarGroups` 的 x 计算是 `band.bandStart(index) + groupIndex * slot + (slot - barWidth) / 2.0`，`slot = band.bandWidth / groups.size`，两个调用（`drawBarGroups(..., leftGroups, ..., leftScale, false)` 与 `(..., rightGroups, ..., rightScale, true)`）传入的 `band` 是同一个；左组 `groupCount = leftGroups.size`、右组 `groupCount = rightGroups.size`，两者都从 `bandStart(index)` 开始铺满整个 band。于是左轴第 0 组与右轴第 0 组的 x 区间完全重合（宽度都取 `bandWidth / 各自组数` 的 0.6）。
- **描述**：`series[].axis` 对柱类系列是允许的（`design.md:5,9` 与 spec 的「双轴」需求），一旦用户给两个 bar 系列分别标 `left` / `right`，两组柱子就叠在同一位置：后画的右轴柱直接盖住左轴柱，读图时只能看到一组，而且盖住哪个取决于系列顺序。折线/散点因为有各自的 `scale`，不会出现这个问题，所以这个缺陷只在「双轴 + 柱」组合下触发。
- **建议**：把左右柱组当作同一个子槽序列排布——先算出 `leftGroups.size + rightGroups.size` 的总组数，再按 `groupIndex` 全局递增分配 slot（左组在前、右组在后）；或者给两组各分半个 band。补一条断言「左右各一个 bar 系列时，两类柱的 x 区间不相交」的测试。

### [一般][存量] #3 `ComboChart` 堆叠组内所有分段都用组内首系列的颜色，同组的多段柱无法区分

- **位置**：`f_chart/src/ComboChart.cj:562-565`（`case None => config.theme.colorAt(group.series[0].paletteIndex)`）；对照 `:197-203`（图例按 `series[index]` 逐系列取色）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符 / 契约与实现不符」、§10「正确性」
- **证据**：静态确定 —— 堆叠分支的循环变量是 `item`（`for (item in group.series)`），但取色用的是 `group.series[0].paletteIndex`，与 `item` 无关；`ComboSeries.paletteIndex` 在解析时就是系列下标（`:242,250`）。因此一个含 3 个系列的 `stacked-bar` 组，3 段全部拿到第 1 个系列的颜色，而图例显示 3 种颜色。单系列分支（`:530-533`）用 `group.series[0]` 是对的（此时只有一个元素），说明这是写错变量而非有意为之。
- **描述**：堆叠柱的核心信息是「同一条柱子里各段的比例」，颜色全同后视觉上退化成一根纯色柱，段与段之间也没有描边（`kit.rect` 的 `stroke` 默认 `None`，`ChartSvgKit.cj:42`），单凭图形无法区分段，必须回头看数值。百分比堆叠柱同理。
- **建议**：改为 `config.theme.colorAt(item.paletteIndex)`；`ComboSeries` 已有该字段，无需改结构。补一条断言「同组 3 段的 `fill` 互不相同」的测试。

### [一般][存量] #4 `ComboChart` 折线/散点的缺省色硬编码 `#4e79a7`，与图例的调色板取色不一致

- **位置**：`f_chart/src/ComboChart.cj:630-634`（`flushLine` 的 `case None => "#4e79a7"`）、`:651-654`（`drawScatters` 同样的硬编码）；对照 `:197-203` 与 `ChartTheme.cj:54-58`、`:18-21`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性：图例与图形一致性」
- **证据**：静态确定 —— 图例颜色由 `series[index].color` 或 `config.theme.colorAt(index)` 决定（`palette` 默认 `#4e79a7, #f28e2b, #e15759, …`，`ChartTheme.cj:19`）；折线与散点的缺省色是字面量 `#4e79a7`。第 0 个系列恰好等于 `palette[0]`，所以单系列示例测不出来；从第 1 个系列起图例是 `#f28e2b`、线却是 `#4e79a7`，多个无线色的 line 系列则全部画成同一种蓝。
- **描述**：同一张图里「图例说有橙色系列」而图上没有橙色，属于典型的图例/图形错位，会让读者把两条线看成同一条。自定义 `theme.palette` 时连第 0 个系列也会错。
- **建议**：`flushLine`/`drawScatters` 增加 `config` 参数，缺省值改成 `config.theme.colorAt(item.paletteIndex)`，与 `drawBarGroups` 的取色路径统一（可顺手把「系列取色」抽成一个 `comboSeriesColor(config, item)`，三处共用）。

### [一般][存量] #5 `ComboChart` 左轴范围无条件包含 0，与设计「柱参与时才包含 0」不符，纯折线的图被压扁

- **位置**：`f_chart/src/ComboChart.cj:364-365`（`dataMin` / `dataMax` 初始化为 `0.0`）、`:404-412`、`:437-444`；契约见 `f_chart/doc/spec/add-f-chart-combo/design.md:17`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「与规格冲突」
- **证据**：静态确定 —— `design.md:17` 写「柱参与时范围包含 0」，而实现把 `dataMin`/`dataMax` 的初值设成 `0.0`（`:364-365`），后面对 line/scatter 只做 `minFloat`/`maxFloat`（`:415-436`），`hasBar` 分支（`:440-443`）再补一次 0 完全没有意义（初值已经是 0）。结果：只有 line 系列、数值 100–200 的图，`lineRange` 收到 `dataMin = 0`、`dataMax = 200`，加 5% padding 后轴范围是 `[-10, 210]`，数据只占约 45% 高度。
- **描述**：设计意图是「有柱才从 0 起，纯折线按数据范围留 5%」，实现把这条规则变成了全局规则。对仪表盘里「叠加图只有线」的用法（`combo` 允许单 line 系列）会明显损失可读性，而且因为 `lineRange` 会再加 5% padding，负方向还多出一段没有意义的空白。
- **建议**：把初值改成 `dataMin = Float64.MAX` / `dataMax = -Float64.MAX`（或先收集完再取极值），保留 `:440-443` 的 `hasBar` 补 0；`hasData == false` 时仍返回 `[0.0, 1.0]`。

### [一般][存量] #6 `CirclePackingChart` 网格排布让角格子圆越出父圆，违反 spec「父圆 MUST 包住其子圆」

- **位置**：`f_chart/src/CirclePackingChart.cj:203-216`（`columns`/`rows`/`cellWidth`/`cellHeight`/`maxRadius` 与子圆圆心计算）；契约见 `f_chart/doc/spec/add-f-chart-circle-packing/specs/chart-rendering/spec.md:7`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§10「正确性：几何边界」
- **证据**：静态确定（纯几何推导）—— 子圆半径被钳到 `min(cellWidth, cellHeight) / 2 - padding`（`:214-216`），子圆心在 `(col+0.5)·cellWidth` 的格心（`:212-213`）。当 `columns ≥ 2 且 rows ≥ 2` 时，角格心到父圆心的距离是 `sqrt((R - cw/2)² + (R - ch/2)²)`；取最坏情形 `cw = ch = R`（4 个等大子节点，`columns = rows = 2`）时距离为 `R/√2 ≈ 0.707R`，子圆半径上限 `R/2 - p`，外接半径 ≈ `1.207R - p > R`。代入测试样例的尺度（`CirclePackingChart_test.cj:43-44`：640×640、`padding 2`、根总量 310 ⇒ `R ≈ 0.45×608 ≈ 273`）：4 个等大子节点时角格心距圆心 ≈ 193，子圆半径 ≈ 134.5，外接 ≈ 327.5，越出父圆约 55px。现有样例根下只有 2 个子节点（1 行网格）恰好不触发。
- **描述**：圆堆积图的语义就是「父圆面积 = 子圆面积之和，且父圆包住子圆」；现在只要某个父节点有 3 个以上子节点（2×2 网格，其中 2 个是角格），角上的子圆就会溢出到父圆外，与兄弟父圆互相压盖。测试只数 `circle-packing-circle` 个数（`CirclePackingChart_test.cj:60-62`），所以这条 MUST 从未被验证。
- **建议**：把子圆限制在父圆内——按 `最大内接矩形` 缩小 `cellWidth/cellHeight`（边长取 `R·√2/(1+√2)` 量级，或直接按 `sqrt(2)·R/(cols+1)` 收紧），或对每个角格再乘一次 `1/sqrt(2)` 的半径折扣；同时补一条测试：对每个子圆断言 `dist(center, parentCenter) + childRadius <= parentRadius + ε`。

### [一般][存量] #7 等高线的两个专属字段没接线：`interpolate` 校验后完全不生效，`levels` 数组只当计数器用

- **位置**：`f_chart/src/ContourChart.cj:111-114`（`interpolate` 只做取值校验，此后全文无引用）、`:247-265`（`levels` 为数组时只返回 `items.size`，元素值丢弃）；承诺源：`f_chart/README.md:1267`、`f_chart/doc/chart-json-spec.md:1140`、`f_chart/doc/spec/add-f-chart-contour/proposal.md:11`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现 / 半成品」、§1「读了不用」
- **证据**：静态确定（搜索证据）—— `grep -rn "interpolate" f_chart/src`（排除测试）只有 `ContourChart.cj:111-113` 三行：读值、比较、抛异常，之后既没有分支也没有传参给绘制逻辑；`bands` 的计算（`:158-161`）与单元格矩形（`:162-179`）都只看 `contourLevel`，与 `interpolate` 无关。`levels` 数组分支（`:250-256`）只 `return items.size`，`items` 的数值既没校验递增也没参与分层——尽管同一函数的错误文案写着「期望正整数或递增数组」（`:258`）。而 `doc/chart-json-spec.md:1140` 把两者列为「专属字段」（`levels`：等值线层级数**或显式数组**；`interpolate`：`linear` / `nearest`），README:1267 的示例也带着 `"interpolate": "linear"`。
- **描述**：用户传 `interpolate: "nearest"` 得到与 `linear` 完全相同的 SVG（因为没有插值环节，单元格就是离散色块），传 `levels: [0, 10, 25, 60]` 得到的是「4 个等宽分档」，而不是按 0/10/25/60 分档。两个字段都是「写了不生效」的静默降级，最坏情况下用户以为改了配色分档、实际图没变。测试也只覆盖了「非法值要抛」（`ContourChart_test.cj:100-113`），没有行为断言。
- **建议**：二选一——(a) 实现：`interpolate == "nearest"` 时按最近网格点取 band（`linear` 走当前逻辑），`levels` 为数组时用元素作为阈值、校验严格递增；(b) 若短期不做，把两字段从 README / `chart-json-spec.md` 移除，或降级为「仅校验、无效」并在文档里注明，`levels` 数组分支直接拒绝（避免「接受但不生效」）。

### [一般][存量] #8 节点 id 去重与 `findNode` 在模块内各写一遍（本部分命中 3 个图），且都是 O(n²) 线性扫描

- **位置**：`f_chart/src/ChordChart.cj:82-86` + `:204-211`、`f_chart/src/CirclePackingChart.cj:74-78` + `:137-144`、`f_chart/src/ChoroplethChart.cj:82-86`、`f_chart/src/ChordChart.cj:107-113`（每链接两次 `findNode`）+ `:170-183`（画带时再来三次）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改类型名 / 字面量复制）」、§6.4「热点 `contains` / `indexOf`」
- **证据**：静态确定（搜索证据）—— `grep -rn "private func findNode" f_chart/src` 命中 **14** 处：`AlluvialChart:275`、`ArcChart:196`、`ChordChart:204`、`CirclePackingChart:137`、`DifferentialFlameChart:176`、`FlameChart:158`、`HeatFlameChart:181`、`HiveChart:215`、`IcicleChart:157`、`NodeLinkChart:184`、`OfflineFlameChart:167`、`SunburstChart:141`、`TreemapChart:150`、`tui/TuiFlameChart:144`，函数体逐行同构，只有元素类型和返回类型不同（`Int64` 返回 -1 / `?T` 返回 None 两种风格）。`grep -rn "id 重复"` 命中 **≥19** 个图表文件，环内都是「`for (existing in nodes) if (existing.id == id) throw`」，仅名词不同（节点 / 区域）。
- **描述**：同一套「id 唯一 + 按 id 找节点」在两个文件里都退化成 O(n²)：解析 N 个节点时逐个线性比对已有节点，建链接时每条链接再扫两遍（`ChordChart.cj:107-108`），画带时对同一条链接又扫三遍（`:170,171,183`）。这类图（和弦、桑基、火焰）的节点数常有几百到几千，重复逻辑同时带来「改一处漏一处」的维护风险——现在已经分叉成两种返回约定，新增图很容易沿用错的那种。
- **建议**：在模块内加一个共享工具（如 `chartNodeIndex<T>`：`HashMap<String, Int64>`，提供 `add(id, path, noun)` 与 `require(id, path)`），供各节点类图共用；`findNode` 的 14 份实现按「先改本部分命中的 3 个、再逐步收敛」的节奏替换。合并时保留两种语义差异点：错误文案里的名词（节点 / 区域）与「找不到是抛异常还是返回 None」，用参数显式表达。

### [一般][存量] #9 `pathCentroid` 把 SVG 弧线标志位和小数指数当坐标，还静默吞掉解析失败，标签位置会偏

- **位置**：`f_chart/src/ChoroplethChart.cj:176-203`（逐字节取数 + `catch (_: Exception) { () }`）；契约见 `f_chart/doc/spec/add-f-chart-choropleth/design.md:16`、`specs/chart-rendering/spec.md:30`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 解析」、§3「`catch` 静默吃掉异常」
- **证据**：静态确定 —— 扫描器把「数字 / `.` / `-`」都当数字起点（`:182`），后续只接受数字与 `.`（`:187`），因此：①`A 5 5 0 0 1 10 10`（圆弧，画圆角区域常用）里的 `rot` 与两个 flag `0 0 1` 会被当成坐标，7 个数字按两两配对得 (5,5)、(0,0)、(1,10)（末位 10 落单丢弃），质心由真实的 (10,10) 偏到 ≈(2,5)；②SVG 允许指数记法，`1e-5` 会被拆成 `1` 与 `-5` 两个数，配对关系整体错位；③`Float64.parse` 失败（例如孤立 `.`）进 `catch` 后 `()` 直接丢弃（`:194-198`），既不报错也不计数，质心在无提示的情况下偏一点。
- **描述**：这条路径只在 `showLabels` 为真时影响标签坐标，但输出的是「标签画在区域外/压在边界上」这类肉眼可见的错误，而且用户在 JSON 里写的是完全合法的 SVG path（`README.md:2624-2627` 的示例就是 `M … L … Z` 折线，暂时碰不到弧，但设计文档没限制 path 语法）。同一实现还被 `f_chart/src/CartogramChart.cj:94`、`f_chart/src/FlowMapChart.cj:98` 复用，含弧路径的底图会在三张图上一起偏。同一条链路上 `path.toArray()` 与每个数字一次 `String.fromUtf8` 也带来多余分配。
- **建议**：改成状态机解析——只取命令字母后的坐标对，识别 `A/a` 命令跳过 5 个参数中的前 2 个（rx/ry）与后 1 个（x/y），flag 只吃单字符；支持 `e/E` 指数；`Float64.parse` 失败时抛 `InvalidValue`（与 `:204-206` 的「至少两个坐标点」保持同一错误等级），不要空 `catch`。

### [轻微][存量] #10 `drawBarGroups` 的 `right` 形参从未使用，`labelCount()` 是无意义包装

- **位置**：`f_chart/src/ComboChart.cj:504-512`（`right: Bool`）、`:217-219`（`labelCount`）、`:210`（调用点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「死代码：读了不用 / 无调用者的间接层」
- **证据**：静态确定 —— `drawBarGroups` 函数体（`:513-581`）只引用 `groups`、`kit`、`config`、`band`、`labelCount`、`scale`，`right` 没有任何出现；`labelCount(labels)` 唯一实现是 `labels.size`，唯一调用点是 `drawBars(..., labelCount(labels), ...)`，而调用方手上就有 `labels`/`band.count`。
- **描述**：说明「左右两组」这条信息在函数内完全丢失了——与第 #2 条同源：函数不知道自己在画哪一侧，也就无法与另一侧共享子槽。
- **建议**：删除 `right` 形参（或在修 #2 时真正用它做槽位分配）；`labelCount()` 直接用 `labels.size`。

### [轻微][存量] #11 孤立节点（无任何链接）在 `ChordChart` 里得到 0 角度弧，与 spec「分段后仍有正角度」不符

- **位置**：`f_chart/src/ChordChart.cj:126-144`（`span = node.total / total * available`）、`:161-168`（照常输出 `chord-arc`）；契约见 `f_chart/doc/spec/add-f-chart-chord/specs/chart-rendering/spec.md:34`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 空集合」、§13「规格与实现漂移」
- **证据**：静态确定 —— `total` 只累加被链接引用到的节点（`:119-120`），完全没有链接的节点 `total == 0`，于是 `span == 0`、`startAngle == endAngle`（`:139-142`），`chordArcPath` 生成起终点重合的退化弧（`A r r 0 0 1` 同点），视觉上什么都不画；`showLabels` 打开时该节点的标签仍落在 `midAngle` 上。spec 只校验了 `padAngle * nodes.size < 2π`（`:133-135`），没有校验「每个节点至少有一条链接」。
- **描述**：`nodes` 用来声明图例/标签集合，`links` 决定流量，两者不一致时（典型：某个类别本季度没有交易）图不会报错，但会少一块弧且无法解释。spec 的措辞「分段后仍有正角度」在数学上要求每个 `span > 0`，实现只保证了总可用角为正。
- **建议**：在 `padAngle` 校验旁补一条「每个节点 `total > 0`，否则抛 `InvalidValue`（文案指明哪个节点没有链接）」；若希望容忍孤立节点，则在 spec 里把「正角度」改成「总角度为正，孤立节点输出零长度弧」并说明渲染表现。

### [轻微][存量] #12 `ContourChart.indexOf` 未命中时返回 0，把「找不到」伪装成「第 0 个坐标」

- **位置**：`f_chart/src/ContourChart.cj:238-245`（`0`）；调用点 `:94-95`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「`case None => ()` 式兜底把错误吃掉」、§11「错误处理缺失或静默」
- **证据**：静态确定 —— `indexOf` 遍历不到时直接 `0`，而不是抛异常或返回 `Option`；`values[position]` 随即写入 `yIndex * xs.size + xIndex` 的第 0 列。调用点依赖「`xs`/`ys` 由同一批 `points` 去重而来，`x`/`y` 必定命中」这个隐含前提，但前提是靠浮点 `==` 维持的，一旦 `uniqueSorted` 的相等判定与 `indexOf` 不一致（例如 `-0.0` 与 `0.0`、或将来换成 NaN/精度归一化），数据会静默落到错误的网格单元，重复坐标检测（`:97-99`）也会误报。
- **描述**：这是「不可达兜底返回值」的典型形态：今天不会触发，但一旦触发就是错位的色块，没有任何信号。
- **建议**：返回 `?Int64`，调用点 `match` 未命中时抛 `chartInvalidValue("series[0].data", "网格坐标无法定位")`；顺带把去重与查下标合成一趟 `HashMap<Float64, Int64>` 构建。

### [轻微][存量] #13 `uniqueSorted` 去重与排序都是 O(n²)，网格点数上千后解析阶段明显

- **位置**：`f_chart/src/ContourChart.cj:211-236`（去重双层 `for` + 插入排序）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §6.4「热点里对 `Array` 反复 `contains`」「每请求排序」
- **证据**：静态确定（复杂度）—— 去重对每个点线性扫描已收集的 `unique`（`:216-221`），排序用插入排序（`:226-234`），对 P 个点合计 O(P²)；同一函数的 `points.size == xs.size * ys.size` 校验（`:84`）说明 P 就是完整网格规模，`50×50` 网格即 2500 次外层 × 平均 1250 次内层。
- **描述**：低效算法本身可静态认定，但「解析阶段是否已成为端到端热点」没有测量数据（`ContourChart` 的典型网格规模未知），故只按轻微记录，收益进「待验证假设」。
- **建议**：一次性把 `x`/`y` 放进 `HashMap<Float64, Unit>` 去重 + `xs.sort()`；或直接按「点到 (行, 列)」的 `HashMap<Int64, Float64>` 建网格，免去 `uniqueSorted` 与 `indexOf` 两趟。

### [轻微][存量] #14 `colorRange` 超过 3 个颜色时多出的颜色被静默丢弃，最大值拿不到「末色」

- **位置**：`f_chart/src/ChoroplethChart.cj:103-119`（只校验 `size >= 2`）、`:152-154`（统一走 `heatFlameColor`）；`f_chart/src/HeatFlameChart.cj:271-272` → `f_chart/src/HeatmapChart.cj:225-248`（只取 `colors[0..2]`）；契约见 `f_chart/doc/spec/add-f-chart-choropleth/specs/chart-rendering/spec.md:21`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `heatFlameColor` 在 `colors.size >= 3` 时固定调用 `heatmapColor(value, colors[0], colors[1], colors[2])`（`HeatFlameChart.cj:271-272`），`heatmapColor` 的签名只有 low/mid/high 三个位置参数，`ratio == 1.0` 时返回 `high == colors[2]`；`ChoroplethChart` 侧没有对 `colorRange.size > 3` 做任何限制或提示。于是传 `["#e8f1fb","#7fb3d5","#1f4e79","#0b2545"]` 时，最大值取到 `#1f4e79` 而非末色 `#0b2545`，第 4 个颜色全程未被使用。
- **描述**：影响面限于「调用方传 4 色以上」的输入（README:2621 与 spec 示例都是 3 色），但 spec 明确写「最小值 MUST 取首色，最大值 MUST 取末色」，与实现不一致；同模块其他图（如热力图）也共用 `heatFlameColor`，配色语义不统一时容易误判。
- **建议**：要么在 `:107-109` 把上限收紧到 2–3 并给出明确文案（「colorRange 支持 2 或 3 个颜色」），要么在 `heatFlameColor` 里对 N 色做均匀分段插值（N-1 段线性插值），让「末色 = 最大值」在任何长度下成立。

### [轻微][存量] #15 `ConfusionMatrixChart` 单元格边长有 1px 下限，画布偏窄时网格会溢出绘图区

- **位置**：`f_chart/src/ConfusionMatrixChart.cj:110-115`（`maxFloat(min(...), 1.0)` 与 `gridX/gridY` 居中）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」
- **证据**：静态确定 —— `cellSize = max(min(gridWidth/N, gridHeight/N), 1.0)`。当标签很长或画布很窄（`plot.width - rowLabelWidth < N`）时 `gridWidth` 可能小于 `N` 甚至为负，`min(...)` 为负后被抬到 1.0，`totalSize = N` 反而大于 `gridWidth`，`gridX = plot.x + rowLabelWidth + (gridWidth - totalSize)/2` 把网格推到 `rowLabelWidth` 左侧、盖住行标签并越出画布；`gridY` 同理可能盖住列标签/标题。
- **描述**：`ChartConfig` 只校验 `width/height > 0`（`ChartConfig.cj:182-184`），没有最小尺寸约束，所以窄画布是可达输入；此时输出仍是合法 SVG，只是内容压在一起，属于可诊断性差的降级。
- **建议**：`cellSize` 下限改为 `0`，并在 `gridWidth`/`gridHeight <= 0` 时抛 `InvalidValue`（「画布不足以容纳 N×N 矩阵与标签」）；或按 `N` 自动缩字号/截断标签。

### [轻微][存量] #16 分级统计地图的校验清单漏了 `id` 必填且唯一

- **位置**：`f_chart/doc/spec/add-f-chart-choropleth/specs/chart-rendering/spec.md:44`（校验清单）；对照 `f_chart/doc/spec/add-f-chart-choropleth/proposal.md:10`（字段列表）、`f_chart/src/ChoroplethChart.cj:81-86`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档缺关键约束」、§14.1「规格漏项导致按文档造数据被拒」
- **证据**：静态确定 —— `spec.md:44` 只写「每项 MUST 有字符串 `path` 与数字 `value`」，实现 `:81` 用 `json.requiredString("id")` 且 `:82-86` 对重复 `id` 抛 `InvalidValue`；`proposal.md:10` 的元素形状里确实有 `id`。
- **描述**：照 `spec.md:44` 的清单构造不带 `id` 的 `regions` 会直接抛错，验收方与实现方对同一输入结论相反；重复 id 的拒绝也没有任何规格依据。
- **建议**：`spec.md:44` 补「每项 MUST 有唯一的字符串 `id`」，并加一条「重复 id → `InvalidValue`」的场景。

### [轻微][存量] #17 和弦规格的「比例」口径与设计/实现不一致（每条链接被计两次）

- **位置**：`f_chart/doc/spec/add-f-chart-chord/specs/chart-rendering/spec.md:7`（规格）；对照 `f_chart/doc/spec/add-f-chart-chord/design.md:9-12`（设计）、`f_chart/src/ChordChart.cj:119-120`（双向累加）、`:126-144`（按 `Σ 节点总量` 分配）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移：验收口径不可复现」
- **证据**：静态确定 —— 每条链接的 `value` 同时累加到 `source` 与 `target` 的 `total`（`:119-120`），分母 `total = Σ 节点总量`（`:126-129`）因此是总流量的 2 倍。规格写「占**全部总流量**的比例」，按字面「两个节点 + 一条链接」场景下每个节点应占 100%，实现给出 50%。
- **描述**：行为本身是对的（只有用 `Σ 节点总量` 作分母才能把可用角度填满），错的是 `spec.md:7` 的文字：它把「节点总量」说成了「总流量」。按规格写的验收用例会算出相反结论，测不出问题时也说不清是实现错还是用例错。
- **建议**：`spec.md:7` 改为「弧长按该节点总量（作为 source/target 的 `value` 之和）占所有节点总量之和的比例分配」，与 `design.md:9-12` 统一措辞，并补一条单链接场景断言「两个节点各占 50%」。

### [轻微][存量] #18 组合图「六种系列类型」中 `bar` 与 `grouped-bar` 实现完全等价

- **位置**：`f_chart/doc/spec/add-f-chart-combo/specs/chart-rendering/spec.md:7`；实现 `f_chart/src/ComboChart.cj:238`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档描述的能力颗粒度与实现不符」、§2「只改名字的重复分支」
- **证据**：静态确定 —— `:238` 是 `case "bar" | "grouped-bar"` 同一分支，两者都产生 `ComboKind.Bar` 与空 `stack`；是否并列只取决于同组系列个数（`:471`、`:516-522`），与类型名无关。
- **描述**：规格把两者列为两种类型，实际只有 5 种语义。用户只写一个 `grouped-bar` 系列时得到的是普通柱，与「分组柱」的预期不符，也无法通过类型名强制并列。
- **建议**：文档注明 `grouped-bar` 是 `bar` 的别名（分组行为由系列数量与 `stack` 决定），或让 `grouped-bar` 强制独占一组以产生稳定的并列语义；后者需补一条「单 `grouped-bar` 系列仍占满子槽」的用例。

<!-- 第 7 部分 -->

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

<!-- 第 8 部分 -->

### [一般][存量] #1 哑铃图 design 声称"网格与横轴刻度由 ChartFrame 绘制"，实现把横向比例尺当纵坐标用，网格线画到绘图区外与画布外

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/design.md:11`；对照 `f_chart/src/DumbbellChart.cj:133,152`、`f_chart/src/ChartFrame.cj:168-178`
- **来源**：存量（快照模式无基线）；`git log -S "drawYAxis(kit, ticks, xScale)"` 未追（只读审阅），按快照统一记存量
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符 / 契约与实现不符」
- **证据**：静态确定 —— `ChartFrame.drawYAxis(kit, ticks, scale)` 的 `scale.scale(tick)` 结果被直接当 **y** 用（`ChartFrame.cj:172`，随后 `174-177` 画 `(plot.x, y) → (plot.right(), y)` 横线、`179-186` 在 `plot.x - 8` 处写刻度文本）。哑铃图的 y 轴是类目 `BandScale`（`DumbbellChart.cj:132`），唯一的 `LinearScale` 是横向的 `xScale`（`133`：`LinearScale(min, max, plot.right(), plot.x)`），但 `152` 仍然 `frame.drawYAxis(kit, ticks, xScale)`。已入库样例 `f_chart/charts/M077-dumbbell.svg` 复现：网格线 y 依次为 73.44 / 213.952 / 354.464 / **494.976 / 635.488 / 776**，绘图区实际是 74–432、画布高 480，即 3 条落在绘图区外、其中 2 条整条在画布外；同时左侧出现两套标签——类目名（`A 团队` 等，`DumbbellChart.cj:168-178`）与数值刻度 `0/20/40/60/80/100`（`ChartFrame.cj:179-186`）都贴在 `x = 65.44`。
- **描述**：design 只写了"网格与横轴刻度由 `ChartFrame` 绘制"，没有写清横向类目图的网格方向与所用比例尺；实现照字面调用了纵向 API，结果是坐标轴装饰错位（数据图元 `dumbbell-line` / `dumbbell-low` / `dumbbell-high` 本身位置正确）。按 §13 的归档口径，这不是"文档过期"，而是文档口径与绘制行为在归档当时就不自洽：读者按 design 无法推出"网格应垂直于数值轴"。
- **建议**：design 补一句"横向类目图的数值轴在底部，网格为等值竖线；纵轴仅类目标签、不设数值刻度"；实现侧（源码归对应子轮）改为新增 `drawXGrid(kit, ticks, xScale)` 画竖线，或直接删掉 `152` 的 `drawYAxis` 调用。
- **范围外提示**：`DumbbellChart.cj:152` 是实质缺陷（全模块仅此一处把 `xScale` 传给 `drawYAxis`，已用 `grep -rn "frame.drawYAxis(" src` 排除复用模式），源码不在本部分清单，留给覆盖该文件的子轮定级。

### [一般][存量] #2 环形图 design 规定"白色内孔 + 主题文本色"，主题背景可配成深色时中心文本不可读

- **位置**：`f_chart/doc/spec/add-f-chart-donut/design.md:9-11`；对照 `f_chart/src/DonutChart.cj:141-154`、`f_chart/src/ChartTheme.cj:25,38`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移 / 关键段落缺失」、§11「边界未处理」
- **证据**：静态确定 —— design 写"外半径…内半径 = 外半径 × `innerRadius`""先按饼图方式绘制扇区，再画**白色**内孔圆，最后绘制 `centerText`""中心文本…颜色取主题文本色"。实现内孔硬编码 `fill: "#ffffff"`（`DonutChart.cj:143`），中心文本取 `config.theme.textColor`（`150`），扇区百分比标签再硬编码 `#333333`（`133`）。而主题背景与文本色是用户可配项：`ChartTheme.cj:25` 默认 `background = "#ffffff"`，`:38` 从输入的 `theme.background` 读取。
- **描述**：内孔用白色实心圆代替"挖洞"（背景色/透明），在 `theme.background` 非白（深色仪表盘是环形图的典型场景）时会出现白斑；若同时配深色主题的浅色 `textColor`，中心文本正好落在白圆上，对比度反转成不可读。design 只承诺"白色内孔 + 主题文本色"，没有规定二者在非白主题下的组合规则，属口径缺失。
- **建议**：design 改为"内孔填充取 `theme.background`（或环形扇区改用 `fill-rule: evenodd` 的复合路径真正挖空）"，并补一句"中心文本与背景的对比由主题负责"；实现侧把 `143` 的 `#ffffff` 换成 `config.theme.background`、`133` 的 `#333333` 换成主题色。
- **范围外提示**：`DonutChart.cj:143,133` 的硬编码颜色是实质缺陷，源码不在本部分清单。

### [一般][存量] #3 豆图 spec 要求"圆心 MUST 位于所属类目带内"，但 `jitter` 只校验非负、无上界，偏移可整条越出类目带

- **位置**：`f_chart/doc/spec/add-f-chart-dot-strip/specs/chart-rendering/spec.md:7`（另见 `:16`、`:32-39`）；对照 `f_chart/src/DotStripChart.cj:74-77,172,188-191`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」；边界校验缺失见 §10「正确性」
- **证据**：静态确定 —— spec 的 Requirement 写"圆心 MUST 位于所属类目带内，水平偏移 MUST 由 `dotStripOffset` 决定"；`dotStripOffset` 返回 `(fraction * 2 - 1) * jitter * bandwidth`（`DotStripChart.cj:191`），而 `jitter` 校验只有 `jitter < 0.0` 一条（`:75`）。取 `jitter = 0.5` 时 `|offset|` 可达 `0.5 * bandwidth`，圆心正好压在带边界；`jitter = 1.0` 时偏移等于一整条带宽，圆心落到相邻类目带内。spec 的 Scenario 只覆盖 `jitter = 0.15`（`:20`），因此现有测试与实现都不暴露该冲突。
- **描述**：Requirement 承诺的"带内"不是实现能保证的性质，取决于用户传入的 `jitter`；文档没有给上界，等于把一条不可满足的约束写成了验收标准。使用者按 spec 认为"点一定落在本列"会在 `jitter ≥ 0.5` 时拿到越界渲染。
- **建议**：二选一并同步两边——(a) spec 增加"`jitter` MUST 在 `[0, 0.5]`，越界抛 `InvalidValue`"，实现补校验；(b) 把 Requirement 改成"圆心水平偏移不超过 `jitter × 类目带宽`"，不再承诺带内。推荐 (a)，与 `dotSize` 半径叠加后的视觉重叠也更可控。
- **范围外提示**：`DotStripChart.cj:75` 缺少 `jitter` 上界是实质缺陷，源码不在本部分清单。

### [一般][存量] #4 差分火焰图 spec 允许根 `value2 = 0` 却未定义宽度基准，该输入下所有节点宽度为 0、整图空白

- **位置**：`f_chart/doc/spec/add-f-chart-differential-flame/specs/chart-rendering/spec.md:7`、`:40`；对照 `f_chart/src/DifferentialFlameChart.cj:96,157,216`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移 / 边界口径缺失」、§11「边界未处理」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 校验只拒绝"两者都为 0"：`if (value1 <= 0.0 && value2 <= 0.0) throw`（`:96`），所以根节点 `{value1: 100, value2: 0}` 是合法输入（纯回退版本）。宽度公式是 `node.width = node.value2 / rootWidth * plotWidth`（`:216`），`rootWidth` 在 `rootNode.value2 <= 0` 时退回 `value1`（`:157`）——只换了分母，分子仍是 `value2 = 0`；又因为 `validateValues` 保证子节点 `value2` 之和不超过父节点，根为 0 时全部后代 `value2` 也是 0，于是所有 `diff-flame-node` 宽度为 0，标签还额外被 `node.width > chartTextWidth(...) + 6.0`（`:242`）挡掉，输出只剩背景与标题。`DifferentialFlameChart_test.cj:58` 只统计 `class="diff-flame-node"` 出现次数，零宽矩形数量仍为 6，测试红不了。
- **描述**：spec 的 Requirement 把宽度定义为 `value2 / 根节点 value2`，校验又主动允许根 `value2 = 0`，两个条款在边界上互相矛盾；design（`add-f-chart-differential-flame/design.md:6`，清单外）写了"根 `value2` 为 0 时退回 `value1`"，但该约定既没进 spec，实现也没有把分子一起退回，承诺落空。
- **建议**：spec 补 Requirement"根 `value2` 为 0 时 MUST 以 `value1` 作为归一基准（分子分母同时切换）"，并在 Scenario 里给一条"根 `value2 = 0 → 输出宽度按 `value1` 分配的节点"；或让校验直接拒绝根 `value2 = 0` 并写明 `kind`。实现侧修 `:157/:216`（源码归对应子轮）。

### [一般][存量] #5 环形图整块复制饼图扇区绘制，`showPercent: false` 在环形图上退化成"不显示任何标签"

- **位置**：`f_chart/doc/spec/add-f-chart-donut/design.md:10`（"先按饼图方式绘制扇区"）；对照 `f_chart/src/DonutChart.cj:100-140`、`f_chart/src/PieChart.cj:107-149`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（重复逻辑 / 只改类名 / 近似重复含边界判断缺失）、§11（契约与实现不符）、§14.1（只做了一半的分支）
- **证据**：静态确定 —— 两段逐行对齐：`centerX = width/2`、`centerY = height/2 + 10`、`radius = min(w-padL-padR, h-padT-padB-40)/2 - 20`、`angle = -90.0 + startAngle`、起终点三角函数 + `A r r 0 largeArc 1` 拼串、`stroke #ffffff` 全部相同；差异只有三处：className（`donut-slice` vs `pie-slice`）、标签半径（`radius*(1+innerRadius)/2` vs `radius*0.65`）、标签文本分支 —— 饼图是 `if (showPercent) formatPercent(...) else slices[index].name`（`PieChart.cj:135-139`），环形图是 `if (showPercent) { formatPercent(...) }`（`DonutChart.cj:124-137`）**没有 else**。
- **描述**：`startAngle` / `showPercent` 被一并从饼图抄入（`DonutChart.cj:78-79`），但 donut 的 proposal / design / spec 与 README 的 M32 章节都没有这两个字段。同名字段在两图语义不同：饼图关掉百分比后改显示类目名，环形图关掉后一个标签都不显示，使用者无从预期；复制也让描边、字号、外半径公式今后必须两处同步改。
- **建议**：把"扇区路径 + 标签位置策略"抽成公共辅助（或让环形图直接复用饼图的绘制函数），差异用参数传入；`showPercent: false` 在环形图上明确定义（显示类目名或明确不支持）；把 `startAngle` / `showPercent` 写进 donut 的 design 与 spec delta。

### [一般][存量] #6 哑铃图拒绝负值 `low` / `high`，与 design 的"只要求数字"不符

- **位置**：`f_chart/doc/spec/add-f-chart-dumbbell/design.md:5`（"两者均必须为数字"）、`design.md:20`（校验清单）；对照 `f_chart/src/DumbbellChart.cj:70-71`、`f_chart/src/BulletChart.cj:238-241`
- **来源**：存量（快照模式无基线；`bulletNumber` 复用自 M76 子弹图）
- **判据**：review-checklist §11（契约与实现不符）、§13（文档与实现不一致）
- **证据**：静态确定 —— `bulletNumber` 除"必填 + 数字"外还有 `if (number < 0.0) throw chartInvalidValue(..., "数值不能为负")`（`BulletChart.cj:238-241`，注释只写"缺失抛 MissingField，类型不符抛 InvalidValue"）；`DumbbellChart.cj:70-71` 用它读 `low` / `high`，而 design 的"数据"节只要求数字、"校验"节列出的抛错条件也不含负值。
- **描述**：哑铃图是成对测量对比（前后得分、两期指标、温差、盈亏、相对基准差），负值天然合法；当前实现把 `low = -3` 判成 `InvalidValue`，且错误文案"数值不能为负"是子弹图的约束，调用方无法从哑铃图文档推出这一限制。
- **建议**：哑铃图改用只校验"必填 + 数字"的读取（`jsonNumberValue(json.required("low"), ...)`），把非负约束留在子弹图；若产品上确需非负，在 design 的数据/校验两节写明，并在 `spec.md` 补 `InvalidValue` 的 Scenario。

### [轻微][存量] #7 环形图 spec 的"4 个类别 → 4 个 donut-slice"与"零占比扇区被跳过"的实现不符

- **位置**：`f_chart/doc/spec/add-f-chart-donut/specs/chart-rendering/spec.md:9-12`、`:32-34`；对照 `f_chart/src/DonutChart.cj:108-110`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 扇区只在 `if (sweep > 0.0)` 时输出（`DonutChart.cj:110`），`sweep = fractions[index] * 360.0`；而校验只要求"数值非负且总和大于 0"（spec `:34`，实现 `:66-72` 与 `pieFractions`），`[3, 3, 3, 0]` 是合法输入却只输出 3 个 `donut-slice`，与 Scenario 的"4 个类别 → 4 个 `donut-slice`"冲突。内孔 `donut-hole` 无条件绘制（`:141`），所以该 Scenario 的"1 个 hole"始终成立。
- **描述**：Scenario 写的是"data 有 4 个 `{name,value}`"，未限定四值均正；实现按占比裁掉了 0 值类别。视觉上跳过 0 值合理，问题在文档把边界口径留成空白，测试也就无法据此覆盖零值。
- **建议**：Scenario 改为"`data` 有 4 个**正** `value` → 输出 4 个 `donut-slice`"，Requirement 补一句"占比为 0 的类别不绘制扇区（也不绘制标签）"。

### [轻微][存量] #8 豆图 design 的抖动公式与实现差一个相位常量，按文档复算得不到实现的偏移

- **位置**：`f_chart/doc/spec/add-f-chart-dot-strip/design.md:14`；对照 `f_chart/src/DotStripChart.cj:189`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」
- **证据**：静态确定 —— 文档写"用 `sin(index * 12.9898) * 43758.5453` 取小数部分映射到 `[-1, 1]`"，实现是 `sin(Float64(index) * 12.9898 + 4.1414) * 43758.5453`（`:189`），多一个 `+ 4.1414`。spec 只约束偏移落在 `±jitter × bandwidth`（`spec.md:16`）和"不同索引偏移不同"，两者对该相位都不敏感，所以用例不会失败，文档却无法用来复现点位。
- **描述**：确定性抖动是本图唯一影响坐标的算法，文档给出的公式是被当作规格引用的；相位差异会让按文档重写渲染（或写对照测试）的人算出不同点位。
- **建议**：文档补上 `+ 4.1414`（说明是去相关的相位偏移），或实现去掉该常量；任选其一并保持单测对具体数值的断言。

### [轻微][存量] #9 点密度地图 proposal 只写"`regions` 为底图路径"，实际元素必须是 `{path}` 对象

- **位置**：`f_chart/doc/spec/add-f-chart-dot-density-map/proposal.md:10`；对照 `f_chart/doc/spec/add-f-chart-dot-density-map/specs/chart-rendering/spec.md:7`、`f_chart/src/DotDensityMapChart.cj:67-75`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例 / 字段形状与实现不符」、§14.2「公开字段未文档化」
- **证据**：静态确定 —— 实现逐个要求 `item.kind.isObject`（否则抛 `InvalidValue("regions[i]", "期望区域对象")`，`:69-71`），再用 `json.requiredString("path")` 取值（`:73`）；proposal 与 spec 都只说"底图路径"，没有写出元素形态与必填键名。按文档写 `"regions": ["M0 0 L100 0 ..."]` 会被判为"期望区域对象"。
- **描述**：`regions` 是本图唯一的可选结构字段，形状写不清会让使用者第一步就撞错；同目录的 `points` 反而写明了 `{x, y, weight?}`（`proposal.md:10`），两份字段的描述精度不一致。
- **建议**：proposal 与 spec 都改成"`regions` 的元素为 `{path}`，`path` 为必填 SVG path 字符串；缺 `path` 抛 `MissingField`"，并给一个最小样例。

### [轻微][存量] #10 豆图 proposal 把 `jitter` / `dotSize` 写成图表级"专属字段"，实际按系列读取，顶层同名键被静默忽略

- **位置**：`f_chart/doc/spec/add-f-chart-dot-strip/proposal.md:11`；对照 `f_chart/doc/spec/add-f-chart-dot-strip/design.md:5`、`f_chart/src/DotStripChart.cj:74-81`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档与代码不一致」、§11「语义与命名不符」
- **证据**：静态确定 —— `json.number("jitter", default: 0.15)` 与 `json.number("dotSize", default: 7.0)` 的 `json` 是 `series[i]` 的对象（`DotStripChart.cj:57,74,78`），与同目录 design 的"每系列解析 `data`、`jitter`、`dotSize`"（`design.md:5`）一致；`ChartConfig.parse` 不校验未知字段（`grep -n "未知\|unknown" ChartConfig.cj` 无命中），所以顶层写 `"jitter": 0.3` 既不生效也不报错。
- **描述**：proposal 与 design 对同一组字段的层级说法不一致，读者按 proposal（"专属字段"通常理解为图表级）配置会得到"配置写了但图没变"的静默失败。
- **建议**：proposal 改成"`series[i].jitter`（水平抖动比例，默认 0.15）、`series[i].dotSize`（点直径，默认 7），按系列独立配置"。

### [轻微][存量] #11 文档未覆盖两个实现的可见细节：`symbolSize` 默认 8、环形图百分比标签类名 `pie-label`

- **位置**：`f_chart/doc/spec/add-f-chart-dot/specs/chart-rendering/spec.md:23-25`、`f_chart/doc/spec/add-f-chart-donut/proposal.md:12`；对照 `f_chart/src/DotChart.cj:173-176`、`f_chart/src/DonutChart.cj:135`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2「公开字段 / 类名未文档化」
- **证据**：静态确定 —— 点图 spec 只写"`series[].symbolSize` 控制点直径"，未给默认值，实现默认 `8.0`（`DotChart.cj:173`）且半径取 `symbolSize / 2`（`:131`）；环形图 proposal 枚举了三个类名 `donut-slice` / `donut-hole` / `center-text`（`proposal.md:12`），实现里扇区百分比标签用的是 `class="pie-label"`（`DonutChart.cj:135`），该目录两份文档均未提及。
- **描述**：类名与默认值是这两张图对外可观察契约（CSS 定制、快照比对都依赖它）；`pie-label` 复用了饼图类名，对环形图使用者是"没写在文档里的隐式契约"，按 proposal 写样式会漏掉标签。
- **建议**：点图 spec 补"`symbolSize` 默认 8，圆半径 = `symbolSize / 2`"；环形图 proposal 的类名清单补 `pie-label`（或让实现改用 `donut-label` 并在文档同步，二者择一）。

### [轻微][存量] #12 点图、哑铃图与横向条形图三处复制同一套"横向数值轴 + 类目行"布局样板

- **位置**：`f_chart/doc/spec/add-f-chart-dot/design.md:5`（"与 M11 相同"）；对照 `f_chart/src/DotChart.cj:105-148`、`f_chart/src/DumbbellChart.cj:132-179`、`f_chart/src/HorizontalBarChart.cj:103-153`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（跨层复制 / 只改类型名）
- **证据**：静态确定 —— 三处的 `for (tick in ticks) { kit.line(x, plot.y, x, plot.bottom(), grid) }`、`baseline = xScale.scale(0.0)`、`slot = band.bandWidth / max(series.size, 1)`、`y = band.bandStart(index) + seriesIndex*slot (+ slot/2)`、`plot.x - 8.0` 处的类目标签、`drawXAxisNumeric` 收尾逐行同型；差异只有图元（`rect` / `stem+circle` / `dumbbell-line+两端点`）与是否画 baseline。
- **描述**：复制尚未造成数据错误，但已经分叉出一次错误 —— #1 的 `drawYAxis` 误用正是在复制时选错轴方法；后续调轴距、网格规则、类目标签位置要改三处，容易继续分叉。
- **建议**：在 `ChartFrame` 上抽"横向数值轴 + 类目行"装配（画网格 → 算 `slot` → 类目标签 → `drawXAxisNumeric`），图元留给各图回调；抽取前把三处差异（是否画 baseline、系列数上限、标签宽度来源）显式参数化，避免把差异藏进复制品。

<!-- 第 9 部分 -->

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

<!-- 第 10 部分 -->

### [严重][存量] 森林图/增益图坐标轴方向反转：像素参数顺序与 `LinearScale` 语义相反

- **位置**：`f_chart/src/GainChart.cj:125-126`（x、y 两个比例尺）、`f_chart/src/ForestChart.cj:183`（单位比例尺）
- **来源**：存量（快照模式无基线；`git blame` 无 diff 可比）
- **判据**：review-checklist §13（规格与实现漂移）+ §11（渲染结果错误）；对照 `f_chart/src/ChartScale.cj:22-43` 的 `LinearScale` 契约「`topPixel` 对应最大值、`bottomPixel` 对应最小值」
- **证据**：静态确定 —— `LinearScale(min, max, topPixel, bottomPixel)` 中 `scale(max) = topPixel`。`GainChart` 传 `(plot.x, plot.right)` 使 x 最大值落在左边界，传 `(plot.bottom, plot.y)` 使 y 最小值落在顶边；`ForestChart` 传 `(plot.x, plot.right)` 使 `position=0`（即 `lower`）落在右边界。已提交产物与算式一致：`f_chart/charts/M095-gain.svg` 里 y 轴刻度 `0` 在 `y=74`、`1` 在 `y=432`（纵向翻转），`gain-baseline` 从 `(776,74)` 画到 `(56,432)`（右上→左下）；`f_chart/charts/M050-forest.svg` 里刻度 `0.1` 在 `x=696`、`10` 在 `x=73`（横向镜像）
- **描述**：`add-f-chart-gain/specs/chart-rendering/spec.md:16` 要求对角线「连接左下角与右上角」，实现画成右上到左下；两轴刻度文字也自左向右递减。森林图同样把 `lower` 画在 `upper` 右侧，对数轴刻度自右向左递减。两图对使用者呈现的是镜像/翻转的数据位置，属于输出错误而不是风格差异：`GainChart` 是 180° 旋转（两轴同时反向），`ForestChart` 是水平镜像。现有测试只统计 `class="..."` 出现次数（`GainChart_test.cj:58-76`、`ForestChart_test.cj:64-99`），未断言任何坐标，故长期未被发现
- **建议**：按 `LinearScale` 契约改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)` 与 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`（x 轴正确写法可参照 `GanttChart.cj:105`）；同时给两个测试各加一条坐标断言（如「`x=0` 的点 cx 小于 `x=1` 的点」），否则同类回归仍会漏过

### [严重][存量] 流程图自动布局按固定层距排布，4 层以上整体画出画布

- **位置**：`f_chart/src/Flowchart.cj:252-260`（`layoutNodes` 两个分支都用 `level * (maxNodeSize + 90.0)` 与 `plot` 尺寸无关的固定步长）
- **来源**：存量
- **判据**：review-checklist §11（布局边界/坐标越界）+ `add-f-chart-flowchart/specs/chart-rendering/spec.md:30`（`layout` 为 `vertical` 时按入边深度自上而下分层）
- **证据**：静态确定 —— 默认画布 800×480、`padding` 24（`ChartConfig.cj:22-25`、`ChartConfig.cj:167-168`），无标题时 `plot.height = 432`，纵向层距 `maxNodeHeight + 90 = 138`；第 4 层节点中心 `y = 24 + 3×138 + 24 = 462`，节点下沿 486 > 480。仓库自带画布产物同现象：`f_chart/charts/M009-flowchart.svg`（900×520，6 节点）中第 4 层节点在 `y=552`、第 5 层在 `y=712`，即 6 个节点有 3 个完全落在画布外
- **描述**：`vertical` / `horizontal` 两个分支都只按层号乘常量步长定位，从不按 `plot.height` / `plot.width` 或层数缩放，也没有把画布尺寸自适应放大。任何深度 ≥4 的链式流程（含库自带的 M9 示例）都会被裁掉后半段；出现环时 `levels` 在 n 轮松弛中继续增长（`Flowchart.cj:219-228`），坐标会更远，问题同样表现为「节点静默消失」而不是报错
- **建议**：先算出最大层号，令层距 = `min(maxNodeHeight + 90, plot.height / (maxLevel + 1))`，或按 `maxLevel` 反推所需画布高度并同步 `viewBox`；对 `maxLevel` 设上限并在超限时抛 `InvalidValue`，避免靠画布裁剪掩盖

### [一般][存量] 森林图 `yAxis.labels` 只做长度校验，从不参与绘制

- **位置**：`f_chart/src/ForestChart.cj:103-108`（校验）与 `f_chart/src/ForestChart.cj:209-215`（绘制时用的是 `row.label`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用：配置读入后无效果）+ §14（接线缺失）
- **证据**：静态确定 —— 全文件仅此处读取 `config.yAxis.labels`，随后行标签固定取 `row.label`；`ForestChart_test.cj:47` 的样例把 `yAxis.labels` 与数据 `label` 写成同一组文字，所以测试无法暴露
- **描述**：调用方按 `doc/chart-json-spec.md:83`（`labels` 为类目轴标签）传入自定义 `yAxis.labels` 时，只会在长度不符时收到异常，长度相符时标签被静默丢弃；`add-f-chart-forest/design.md:11` 又写「行标签取数据 `label`」，两处约定不一致
- **建议**：二选一——要么按 `yAxis.labels[rowIndex]` 绘制并让数据 `label` 只做缺省回退，要么删掉这段校验并在 `design.md` / `chart-json-spec.md` 明确「森林图行标签只取数据 `label`，`yAxis.labels` 忽略」

### [一般][存量] 甘特图 `lane` 字段未解析、`yAxis.labels` 未使用，规格与样例却都要求

- **位置**：`f_chart/src/GanttChart.cj:184-210`（`parseTasks` 只读 id/name/start/end/progress/dependsOn/color）、`f_chart/src/GanttChart.cj:125-135`（行高按任务数均分，标签取 `task.name`）
- **来源**：存量
- **判据**：review-checklist §14（承诺了但没实现，需双证）
- **证据**：静态确定 —— 承诺源：`f_chart/doc/spec/add-f-chart-gantt/design.md:5`「每个任务解析 id/name/start/end/progress/dependsOn/lane/color」、`f_chart/doc/spec/add-f-chart-gantt/proposal.md:10`「顶层 `tasks`：{…, lane?, color?}」，且 `f_chart/src/ChartGallery_test.cj:193-200` 的官方样例每个任务都带 `lane`；缺失证据：`grep -rn "lane" f_chart/src/GanttChart.cj f_chart/src/GanttChart_test.cj` 无命中
- **描述**：`lane` 被文档当作行分组/泳道语义，实现完全忽略，所有任务按数组顺序一行一个；同样地 `yAxis.labels`（样例里给了 `["需求","设计","开发","测试","上线"]`）也没有任何读取点，左侧标签只能用 `task.name`。使用者按文档给 `lane` 分组，得到的是未分组的平铺结果且无任何提示
- **建议**：要么实现 `lane`（按 lane 分组、lane 名作为分组标题或行标签，同类任务共行）、并在缺少 `name` 时回退到 `yAxis.labels[index]`；要么从 `design.md` / `proposal.md` / `chart-json-spec.md` 删除 `lane` 与示例中的该字段，避免继续误导

### [一般][存量] 流程图边端点偏移取 `min(宽,高)/2`，横向边的箭头被节点覆盖

- **位置**：`f_chart/src/Flowchart.cj:285-290`（`startOffset` / `endOffset`）
- **来源**：存量
- **判据**：review-checklist §11（坐标计算与实际边界不符）
- **证据**：静态确定 —— 默认矩形节点 120×48，`min(120,48)/2 + 2 = 26`；横向连边时节点半宽是 60，连线起点与箭头终点都落在节点内部 34px 处，而节点在边之后绘制（`Flowchart.cj:145-159`）且带不透明填充（`Flowchart.cj:316`、`346`），故 26px 连线与整个箭头被遮住。`layout` 为 `horizontal` 或 `manual` 横向摆放时触发；纵向边不受影响（24+2 恰好等于半高）
- **描述**：形状边界偏移应当按连边方向求交（矩形取 `|ux|*w/2 + |uy|*h/2` 形式，菱形/椭圆另算），现在取短边一半，宽扁节点上的横向边显示为「无箭头、线贴着节点内部」
- **建议**：按单位向量与包围盒求交计算偏移量（至少矩形：`|ux|*(w/2) + |uy|*(h/2)`），或按 `shape` 分派到各自的边界函数；补一条横向布局的坐标断言

### [一般][存量] 漏斗图 `gap` 与可用宽度无下限校验，可生成负尺寸图元

- **位置**：`f_chart/src/FunnelChart.cj:80-83`（`gap` 只判非负）、`f_chart/src/FunnelChart.cj:108-112`（`maxWidth` 与 `stageHeight` 直接相除）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 / 负值进入几何计算）
- **证据**：静态确定 —— 4 阶段、`gap=200` 时 `stageHeight = (342 - 600)/4 = -64.5`，`kit.rect` 收到负 `height`（SVG 中负宽高为错误值，元素不渲染）；`width=200` 时 `maxWidth = 200 - 24 - 24 - 120 = 32`，`width=150` 时直接为负，阶段条反向
- **描述**：`gap` 只校验 `< 0`，没有 `gap * (n-1) < 可用高度` 的约束；`maxWidth` 也未校验 `> 0`。后果是图元静默消失或反向绘制，而不是明确报错
- **建议**：校验 `stageHeight > 0`（否则抛 `InvalidValue`，路径 `gap`），并对 `maxWidth <= 0` 抛 `InvalidValue`（路径 `width`）；测试补 `gap` 过大与画布过窄两个用例

### [一般][存量] 甘特图任务 id 重复时静默覆盖

- **位置**：`f_chart/src/GanttChart.cj:63-66`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失，重复键静默覆盖）
- **证据**：静态确定 —— `taskIndex[tasks[index].id] = index` 直接赋值，无 `contains` 检查；对照 `Flowchart.cj:92-97` 对重复节点 id 抛 `InvalidValue`，同类输入两种处理
- **描述**：两条任务共用同一 `id` 时后者覆盖前者，`dependsOn` 指向该 id 时只会连到后一条，前一条既拿不到依赖也收不到依赖，且没有任何报错；`add-f-chart-gantt/proposal.md:12` 只约定了「`dependsOn` 指向不存在的任务 id 时抛 `InvalidValue`」，未覆盖重复 id
- **建议**：构造 `taskIndex` 时检测重复并抛 `chartInvalidValue("tasks[i].id", "任务 id 重复")`，与流程图保持一致；补一条重复 id 用例

### [轻微][存量] 漏斗图 proposal 与 design/通用规格/实现三处矛盾（「梯形」「从大到小」均未实现）

- **位置**：`f_chart/doc/spec/add-f-chart-funnel/proposal.md:10`（「按值从大到小绘制梯形阶段」）
- **来源**：存量
- **判据**：review-checklist §13（文档内部与实现不一致）；§14（承诺未实现）
- **证据**：静态确定 —— `design.md:5` 写「阶段从上到下按输入顺序排列」、`design.md:9-11` 写「矩形 class `funnel-stage`」，`specs/chart-rendering/spec.md:7` 只要求「宽度与数值成正比」，`f_chart/doc/chart-json-spec.md:1341` 也是「按数组顺序从上到下」；`FunnelChart.cj:110-117` 画的是输入顺序的 `rect`，无排序、无梯形
- **描述**：四份文档三种说法：proposal 说排序 + 梯形，design/通用规格/实现是输入顺序 + 矩形。照 proposal 写用例的调用方会得到「顺序相同、形状不同」的结果
- **建议**：以 `design.md` 为准修正 proposal（改为「按输入顺序绘制矩形阶段条」），或若确实需要梯形则改实现并在 spec 里加「梯形」要求；两者只能留一个

### [轻微][存量] 流程图 spec 场景「4 项节点 → 4 个 `class="node"`」与菱形 class 要求冲突

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/specs/chart-rendering/spec.md:11-12` 与 `:19-26`
- **来源**：存量
- **判据**：review-checklist §13（规格自相矛盾，场景不可验收）
- **证据**：静态确定 —— `Flowchart.cj:326` 对 `diamond` 输出 `class="node node-diamond"`，字面不含 `class="node"`；`Flowchart_test.cj:58` 因此只能断言「4 节点里 3 个 `class="node"` + 1 个 `node node-diamond`
- **描述**：同一条 spec 的「四个节点」场景与「节点形状」需求互斥：只要含菱形节点，场景断言就失效。写成验收用例时会误判失败
- **建议**：把场景改为「输出 4 个含 `node` class 的节点，其中菱形节点为 `node node-diamond`」，并在 spec 中明确 class 组合规则（`node` 恒有，形状 class 叠加）

### [轻微][存量] 森林图权重全为 0 时返回 8，违反 spec「权重为 0 MUST 返回 6」

- **位置**：`f_chart/src/ForestChart.cj:257-260`（`maxWeight <= 0.0` 先返回 8.0）
- **来源**：存量
- **判据**：review-checklist §13（MUST 未落实）
- **证据**：静态确定 —— `specs/chart-rendering/spec.md:25`「`forestMarkerSize` MUST 在权重为 0 时返回 6」；单条数据 `weight: 0`（或多条全 0）时 `maxWeight = 0`，函数在 `weight <= 0.0` 分支之前先命中 `maxWeight <= 0.0` 返回 8
- **描述**：唯一边界差异：显式给了 `weight: 0` 却按「无权重」显示 8px，与 spec 的 MUST 相反；`design.md:16` 的措辞（「无权重时 8；权重 0 时 6」）也没说明 `maxWeight = 0` 时算哪一种
- **建议**：把 `maxWeight <= 0.0` 的判断下移到 `weight <= 0.0` 之后，或在 spec 里补一句「全部权重为 0 时视为无权重」；补一条全零权重用例

### [轻微][存量] 死代码/未使用项 3 处

- **位置**：`f_chart/src/GainChart.cj:71-74`、`f_chart/src/Flowchart.cj:185`、`f_chart/src/FunnelChart.cj:19`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 无调用者的参数 / 未使用 import）
- **证据**：静态确定 —— ① `var span = rangeMax - rangeMin` 及其 `if` 修正后再无任何读取（`grep -n "span" GainChart.cj` 仅 71-73 三行）；② `parseEdges(root: ChartJson, nodes: Array<FlowNode>)` 函数体（186-205 行）从不引用 `nodes`，唯一调用点 `Flowchart.cj:89` 传了它；③ `FunnelChart.cj` 内无任何 `std.math` 符号（`sqrt/abs/round/pow/log/ceil/floor/minFloat/maxFloat` 均无命中）
- **描述**：`span` 是想给「零跨度」兜底但坐标计算改用 `rangeMin/rangeMax` 之后忘了删；`nodes` 参数是签名演进残留；`std.math.*` 是复制模板 import
- **建议**：删掉 `span` 三行、`parseEdges` 的 `nodes` 形参与调用点实参、`FunnelChart.cj` 的 `import std.math.*`

### [轻微][存量] `ChartTime.parseDays` 只校验 `day <= 31`，非法日期被静默归一化

- **位置**：`f_chart/src/ChartTime.cj:35-37`
- **来源**：存量
- **判据**：review-checklist §11（输入校验不严导致静默数据漂移）
- **证据**：静态确定 —— `2026-02-31` 通过 `month 1..12 / day 1..31` 检查，`daysFromCivil(2026, 2, 31)` 按 `doy` 公式会算出 3 月 3 日，不抛异常；`add-f-chart-gantt/design.md:5` 把日期解析完全托付给该函数
- **描述**：甘特图任务的起止日期写错（月份天数不匹配）时不会报错，而是被静默挪到相邻日期，`end <= start` 的校验也可能因此改变结论。另 `parseDays` 忽略时间部分，与文档「可带时间部分，忽略时间」（`ChartTime.cj:21`）一致，不算问题
- **建议**：按 `(year, month)` 校验当月天数（闰年 2 月 29），越界抛 `chartInvalidValue(path, "日期不存在")`；补 `2026-02-31`、`2024-02-29`、`2025-02-29` 三条用例

### [轻微][存量] 跨文件重复：`xLabelHeight` 计算块 3 处逐字重复，`ForestChart.position` 重写了比例尺归一化

- **位置**：`f_chart/src/ForestChart.cj:157-161`、`f_chart/src/GainChart.cj:118-122`、`f_chart/src/GanttChart.cj:99-103`；`f_chart/src/ForestChart.cj:221-227`
- **来源**：存量
- **判据**：review-checklist §2（换文件复制的同语义片段）
- **证据**：静态确定 —— 三处 `xLabelHeight` 均为 `if (labelRotate == 0.0) { fontSize + 12.0 } else { 48.0 }`，仅上下文不同；`ForestChart.position()` 的 `(value - min) / (max - min)` 与 `LinearScale.scale` 的归一化部分同义，只是输出 0–1
- **描述**：轴标签高度常量（12 / 48）散落在各图，改一处不会同步；`position` 与 `LinearScale` 两套归一化并存，是上一条「像素参数顺序颠倒」得以在森林图单独出现的原因之一
- **建议**：把 `xLabelHeight` 提为 `ChartAxis` 的方法或 `ChartFrame` 的静态计算；`ForestChart` 直接用两个 `LinearScale`（x 用对数变换后的值构造）替代自写 `position`

### [轻微][存量] 甘特图依赖箭头的 class 与 design 不一致（`dependency` vs `dependency-arrow`）

- **位置**：`f_chart/doc/spec/add-f-chart-gantt/design.md:16`；实现 `f_chart/src/GanttChart.cj:171`、`f_chart/src/GanttChart.cj:176`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（class / 选择器契约与文档不符）
- **证据**：静态确定 —— `design.md:16`「从依赖任务条的右端到当前任务条的左端画三段折线（水平-垂直-水平），末端画三角箭头；class `dependency`」，读作折线与箭头共用该 class；实现折线为 `className: "dependency"`（`:171`），箭头为 `className: "dependency-arrow"`（`:176`）。`add-f-chart-gantt/specs/chart-rendering/spec.md:25` 只约束折线的 `class="dependency"`，未约束箭头
- **描述**：按设计文档写样式或后处理（`querySelectorAll('.dependency')`）只能命中折线，箭头靠内联 `fill` 上色，主题替换、高亮、导出时箭头会被漏掉
- **建议**：`design.md:16` 补明「折线 `dependency`、箭头 `dependency-arrow`」；若要统一选择器，则箭头改为同一 class，并在样式中同时给 `stroke` 与 `fill`

### [轻微][存量] 流程图 spec 未记录 `horizontal` 布局、`rect`/`round` 形状与有环输入口径

- **位置**：`f_chart/doc/spec/add-f-chart-flowchart/specs/chart-rendering/spec.md:19-35`；实现 `f_chart/src/Flowchart.cj:252-260`（horizontal）、`Flowchart.cj:329-330`（round）、`Flowchart.cj:345-346`（默认 rect）、`Flowchart.cj:219-228`（层级松弛）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）+ §14.1（规格覆盖面不足）
- **证据**：静态确定 —— 同一 spec 的形状需求（`:19-21`）只列 `diamond`/`ellipse`/`parallelogram`/`document`，布局需求（`:30`）只列 `vertical`/`manual`；实现另有 `case "round"`、默认 `rect` 分支与 `layout == "horizontal"`，`f_chart/README.md:76` 也写「六种形状」，说明实现口径是 6 种形状 + 3 种布局。有环输入时 `levels` 在 n 轮松弛中最多增长到 O(n)（与严重 #2 同源），spec 对环未作任何约定
- **描述**：按 spec 写验收只能覆盖一半形状与竖向布局，横向布局与圆角矩形属「文档外能力」；回退边（如「驳回 → 重新提交」）是流程图常见结构，规格既不说支持也不说拒绝，实现既不报错也不保证落在画布内
- **建议**：spec 补全 6 种形状与三种 `layout`；对环明确口径，建议在层级松弛前做 DFS 环检测并抛 `InvalidValue`，与严重 #2 的「层号上限」一起修

<!-- 第 11 部分 -->

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

<!-- 第 12 部分 -->

### [一般][存量] #1 直方图默认分箱数：design 写 `round(sqrt(n))`，实现是截断，全函数无 `round`

- **位置**：`f_chart/doc/spec/add-f-chart-histogram/design.md:5`；对照 `f_chart/src/HistogramChart.cj:167-186`（`179` 行 `Int64(sqrt(Float64(sampleSize)))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与实现不符」
- **证据**：静态确定 —— `design.md:5` 写 `bins` 缺省为 `max(1, round(sqrt(n)))`；`resolveBinCount` 的缺省分支只有一次截断转换，随后 `if (approx < 1) 1`，函数体内无 `round`。同批 `proposal.md:10` 只写「按样本量的平方根取整」（未定舍入），`README.md:836` 与 `README_en.md:832` 都写 `floor(sqrt(n))`，与实现一致、与 design 相反
- **描述**：`n = 8` 时 `round` 得 3 箱、截断得 2 箱；`n = 15` 时 4 对 3。默认分箱会改变柱数、柱宽与每箱频数，按 design 写验收用例必然失败；`HistogramChart_test.cj` 中缺省分箱路径无用例，漂移不会被测试发现
- **建议**：`design.md:5` 改为 `max(1, floor(sqrt(n)))`（与两版 README、实现一致）；若确实要 `round`，则改实现并补 `n = 8` 的缺省分箱用例，二选一

### [一般][存量] #2 横向柱高缺少 design 承诺的 24px 上限

- **位置**：`f_chart/doc/spec/add-f-chart-horizontal-bar/design.md:8`；对照 `f_chart/src/HorizontalBarChart.cj:114`、`121-125`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺的默认值与实现不符」
- **证据**：静态确定 —— design 写「柱高 `min(24, bandWidth * 0.6)`」；实现 `slot = band.bandWidth / max(series.size, 1)`，`requested = barWidth ?? slot * 0.6`，`barHeight = minFloat(requested, slot * 0.95)`，文件内无字面量 `24`
- **描述**：设计意图是「类别少时柱也不超过 24px」，实现只保证不超过行高的 95%。单系列 5 类目（默认画布）时 `slot * 0.6` 在 40px 量级，约为设计值的 1.6 倍；`README.md:396` 的示例恰好传 `barWidth: 24`，把差异掩盖了
- **建议**：实现补 `minFloat(minFloat(requested, slot * 0.95), 24.0)`，或把 design 改成「默认 `slot * 0.6`、上限 `slot * 0.95`、显式 `barWidth` 优先」并说明取消定值的原因

### [一般][存量] #3 显式 `xAxis.min > 0`（或 `max < 0`）时，横柱的 0 基线落在绘图区外，柱越界且方向反转

- **位置**：`f_chart/src/HorizontalBarChart.cj:113`（`let baseline = xScale.scale(0.0)`）、`242-266`（显式 min/max 优先）；对照 `f_chart/src/BarRenderer.cj:115-122`（同类图对基线做了钳制）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界越界」「契约与实现不符」；§2（同一规则两处实现、只有一处钳制 ⇒ 行为漂移）
- **证据**：静态确定 —— `LinearScale.scale` 是纯线性映射（`ChartScale.cj:23-43`），`resolveRange` 在 `axis.min` 存在时直接返回该值、不检查 0 是否在区间内。设 `xAxis.min = 10`、数据 20–30：`baseline = scale(0.0)` 落在 `plot.right()` 之外，`left = min(baseline, valueX) = valueX`、`width = |valueX - baseline|`，矩形从数值位置向右跨出绘图区。`BarRenderer.cj:115-121` 的同规则是 `range[0] > 0 → baseline 取 range[0]`、`range[1] < 0 → 取 range[1]`，把基线钳在区内
- **描述**：`design.md:12` 同时承诺「x 范围包含 0」与「显式 min/max 优先」，两条在 `min > 0` 时互相冲突；实现选了后者又没兜底。只画 10–300 这一段以放大差异是条形图常见用法，产出却方向错误、越出绘图区 —— 本部分唯一会让人读错数据的缺陷
- **建议**：按 `BarRenderer` 钳制基线（`range[0] > 0 → range[0]`，`range[1] < 0 → range[1]`，否则 0），并补 `min > 0`、`max < 0` 两个用例；该规则建议抽到 `ChartScale` 共用（`DotChart.cj:113`、`ComboChart.cj:527` 也是裸 `scale(0.0)`，属范围外提示）

### [一般][存量] #4 分箱数没有上界：`bins` 直接决定分配量

- **位置**：`f_chart/src/HistogramChart.cj:167-177`（只校验 `>= 1` 且为整数）、`247-251`（按 `binCount` 建 `ArrayList<Int64>`）；`f_chart/src/Histogram2DChart.cj:224-233`、`289-291`（按 `binsX * binsY` 建数组）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」
- **证据**：静态确定（分配量可由输入直接算出）—— `bins` 只做 `raw < 1.0 || raw != floor(raw)` 校验，无上限、无与样本量的关系约束。一维 `bins = 1e8` ⇒ `1e8 × 8 B ≈ 800 MB`（`ArrayList` 扩容期还要翻倍）；`1e9` ⇒ 8 GB。二维 `[50000, 50000]` ⇒ `2.5e9` 槽 ≈ 20 GB。`Int64(raw)` 对超 `Int64` 范围的浮点也无防护
- **描述**：两份 spec 只写「`bins`（两个）正整数」（`histogram/specs/.../spec.md:30`、`histogram2d/specs/.../spec.md:25`），没有任何上限或与样本量匹配的约束；一个数据点即可触发巨额分配（数据量与分配量解耦）。二维另有溢出面：`binsX * binsY` 超过 `Int64` 上限（各约 3.04e9）会溢出为负，`0..(负数)` 得到空 `counts`，随后 `countAt` 的 `yIndex * binsX + xIndex` 越界
- **建议**：两处加常量上限（如 1024）并写进 spec；二维用 `binsX > 上限 / binsY` 的形式做乘法前比较，避免溢出

### [一般][存量] #5 冰柱图环检测恒不成立，成环节点被静默丢弃

- **位置**：`f_chart/src/IcicleChart.cj:166-169`（`validateValues` 的 `if (depth > total) throw`）、`182-185`（`assignDepth` 同款）、`94-111`（只有根可达的子树被遍历）；同构代码 `f_chart/src/FlameChart.cj:167-195`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒假分支」、§11「错误处理静默」「失败路径当成功」
- **证据**：静态确定 —— 每个节点只有一个 `parent`，`id` 重复被 `:70-74` 拒绝、父节点不存在被 `:100-102` 拒绝；恰好一个根时可达树深度 `≤ n-1 < total`，`depth > total` 永不成立。真正的环（A.parent=B、B.parent=A 外加正常根）不在这棵树上，`roots.size == 1` 照样通过，`validateValues(rootNode, ...)` 只走根子树
- **描述**：输入 `[{id:"r",parent:null,value:10},{id:"a",parent:"b",value:1},{id:"b",parent:"a",value:1}]` 返回一份「少两个节点」的合法 SVG：无异常、无日志、无缺口提示，而 `"节点关系存在环"` 这条错误信息永远不会抛出。两处恒假分支给维护者「已经防住」的错觉
- **建议**：建树后断言 `已挂载数 + roots.size == parsed.size`，差额即环/孤立组件并抛 `chartInvalidValue("nodes", "节点关系存在环")`；删掉 `depth > total` 两处伪校验

### [一般][存量] #6 冰柱图四层递归全部无深度上限，深链输入爆栈

- **位置**：`f_chart/src/IcicleChart.cj:166-180`、`182-190`、`192-200`、`202-244`（`241-243` 递归）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归」（仓颉不保证尾调用优化）
- **证据**：静态确定（递归无出口条件）+ 需实测（崩溃阈值）—— 四个函数都只按 `child` 递归，唯一上界 `depth > total` 如 #5 所述永不触发；深度 = 树深 = `nodes` 长度，无常量上限、无迭代化
- **描述**：冰柱/火焰图的数据是调用栈或目录树，深链是正常形态。万级退化链会连续四次深递归（校验 → 定深 → 布局 → 绘制），栈空间按最坏一次计；爆栈是进程级崩溃
- **建议**：建树改 BFS（顺带完成环检测与定深），`layoutNode` 与 `drawNode` 改显式栈迭代，保持先父后子与子节点从左累加的顺序不变

### [一般][存量] #7 渲染尺寸参数只有下界没有上界：`cellGap` / `barWidth` 能产生负宽、负高矩形

- **位置**：`f_chart/src/HeatmapChart.cj:108-111`（`cellGap` 只校验 `>= 0`）、`157-162`（`cellWidth - cellGap` / `cellHeight - cellGap`）；`f_chart/src/HorizontalBarChart.cj:183`（`barWidth` 原样读入）、`121-125`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」
- **证据**：静态确定 —— `ChartSvgKit.rect`（`ChartSvgKit.cj:36-55`）把 `width` / `height` 直接交给 `SvgBuilder.rect`，不钳制。`cellGap = 200`、5 列时 `cellWidth ≈ 140`，单元格 `width = -60`，`showValues` 的文字锚点落在负尺寸矩形中心；`"barWidth": -5` 时 `barHeight = -5`
- **描述**：spec 的承诺是单向的（`heatmap/specs/.../spec.md:39` 只写「`cellGap` MUST 非负」，`horizontal-bar` 的 spec 完全没提 `barWidth`）。负尺寸矩形在 SVG 下不被渲染 ⇒ 整图空白或某根柱消失，且无异常可查
- **建议**：`cellGap` 钳到 `min(cellWidth, cellHeight) * 0.5` 或超限抛 `InvalidValue`；`barWidth` 要求 `> 0 && <= slot`。`HiveChart.cj:64-67` 的 `nodeRadius` 同样只有下界

### [一般][存量] #8 冰柱图与火焰图整份复制，design 却声称「共享树构建/宽度分配/校验/配色」

- **位置**：`f_chart/doc/spec/add-f-chart-icicle/design.md:5`；代码 `f_chart/src/IcicleChart.cj:49-155`、`157-204` 对照 `f_chart/src/FlameChart.cj:50-156`、`158-204`
- **来源**：存量（两文件同为 2026 版权头、同批次落地）
- **判据**：review-checklist §2「只改类型名」形态 —— 函数体逐行对齐，仅类型名与一个默认值不同
- **证据**：静态确定 —— 把 `FlameNode` 统一成占位名后 `diff`：`draw` 主体 107 行只差两行（`ChartConfig.parse` 的 `"flame"`/`"icicle"`、`orientation` 默认 `bottom-up`/`top-down`）；`findNode` / `validateValues` / `assignDepth` / `layoutNode` 完全相同（仅一处 `throw` 换行差异）；`drawNode` 同构
- **描述**：design 明写「冰柱图与火焰图共享树构建、宽度分配、校验与配色规则，仅默认方向相反」，实现没有共享任何代码。后果是同一缺陷修两遍（#5 / #6 就是双份），且两份已出现格式级漂移，后续修一处漏一处的概率高
- **建议**：抽 `internal` 共享实现（共享节点类型 + 树构建/校验/宽度分配 + 可配置默认 orientation），两图只保留 `drawNode` 差异；`flameColorIndex`、`heatColor` 已是共享函数，沿用同一落点

### [轻微][存量] #9 频数轴会出现 0.5 步长刻度

- **位置**：`f_chart/doc/spec/add-f-chart-histogram/specs/chart-rendering/spec.md:19-21`；代码 `f_chart/src/HistogramChart.cj:85-90`、`141`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格口径与实现不一致」
- **证据**：静态确定 —— `yRange = [0, maxCount*1.05]`，`chartNiceTicks(0, 2.1, 5)`：`rawStep = 0.42` → `magnitude = 0.1`、`normalized = 4.2` → `step = 0.5`，刻度为 `0, 0.5, 1, 1.5, 2, 2.5`
- **描述**：spec 要求「y 轴 MUST 从 0 开始表示频数」，频数是整数，但浮点上界走 nice ticks 后标签出现 0.5 / 1.5 / 2.5。数据正确、观感失真
- **建议**：频数轴单独取整数步长（`step` 向上取整且 ≥ 1），或 `yRange` 上界取整；spec 同步写「频数刻度取整数」

### [轻微][存量] #10 蜂巢图「各组布置在圆周上」在单分组时不成立

- **位置**：`f_chart/doc/spec/add-f-chart-hive/specs/chart-rendering/spec.md:7`、`f_chart/doc/spec/add-f-chart-hive/design.md:10`；代码 `f_chart/src/HiveChart.cj:153-168`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格 MUST 与实现相反」
- **证据**：静态确定 —— `groupNames.size == 1` 时 `angle = 0` 且 `clusterX/Y` 直接取 `plot.centerX/Y`，即绘图区中心而非半径 `0.32 * 短边` 的圆周上；`README.md:1704`（「簇心沿大圆周分布」）同样无例外说明
- **描述**：单分组时是一个居中团簇，规格文字读起来是「永远在圆周上」。实现的选择合理，但文档缺该例外，无法据此写断言
- **建议**：spec / design / README 三处补「单分组时簇心置于绘图区中心」

### [轻微][存量] #11 蜂巢图 design 说「空值归入空字符串分组」，显式 `null` 实际抛异常

- **位置**：`f_chart/doc/spec/add-f-chart-hive/design.md:5`；`f_chart/src/HiveChart.cj:93`；`f_chart/src/ChartJson.cj:68-84`、`208-213`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现不符」、§11「空值未处理」
- **证据**：待确认（「空值」是否含 JSON `null`）+ 静态确定（代码路径）—— `json.string(groupField, default: "")` 只在键**缺失**时返回默认值；键存在且为 `null` 时走 `jsonStringValue`，非字符串即抛 `InvalidValue("期望字符串")`。模块内 `IcicleChart.cj:76-86` 对 `parent` 显式区分 `isNull`，`ChartJson.number` 也把 `null` 视为 `None`，说明「null 视为空」已有先例
- **描述**：真实数据里 `group` 为 `null` 比键缺失更常见（左连接、可选标签）。若「空值」包含 `null`，则整图因一个 `null` 失败而不是落进空分组
- **建议**：`HiveChart.cj:93` 先判 `isNull` 再取默认值，或把 design 改成「缺失/空串归入空分组；显式 `null` 抛 `InvalidValue`」，并在 spec 校验条款写一句

### [轻微][存量] #12 分箱数的整数校验（含相同文案）在两个文件里各写一遍

- **位置**：`f_chart/src/HistogramChart.cj:170-176` 与 `f_chart/src/Histogram2DChart.cj:225-231`；兜底另见 `HistogramChart.cj:234-236`、`Histogram2DChart.cj:265-267`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制 / 只改形参名」
- **证据**：静态确定 —— 两段均为「非 `Int`/`Decimal` → `"期望正整数"`；`raw < 1.0 || raw != floor(raw)` → `"分箱数必须为正整数"`；`Int64(raw)`」，逐行同构
- **描述**：目前行为一致、无漂移；但 #4 的上限校验要同时加到三处，漏一处就出现「一维拦住、二维放过」
- **建议**：抽 `internal func parseIntBinCount(value: JsonValue, path: String): Int64`（或 `ChartJson` 增加 `positiveInt`），上限与文案收进去

### [轻微][存量] #13 热力图同一段带宽算了两遍（`cellWidth` 与 `BandScale.bandWidth`）

- **位置**：`f_chart/src/HeatmapChart.cj:129-131`、`157`、`202`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— `BandScale` 的 `bandWidth = (end - start) / count`（`ChartScale.cj:51-58`），此处 `start = plot.x`、`end = plot.right()`，故 `columnBand.bandWidth == cellWidth`；单元格用前者、列标签用后者
- **描述**：当前恒等、无缺陷；一旦 `ChartFrame` 的 `width` 与 `right() - x` 之间引入留白（例如加右侧图例列），单元格与列标签即错位，且不易在截图里发现
- **建议**：删掉 `cellWidth`，统一用 `columnBand.bandWidth`；y 方向同理

### [轻微][存量] #14 四份规格的校验清单漏掉实现里已有的硬约束

- **位置**：`f_chart/doc/spec/add-f-chart-heatmap/specs/chart-rendering/spec.md:37-39`；`f_chart/doc/spec/add-f-chart-histogram2d/specs/chart-rendering/spec.md:23-25`；`f_chart/doc/spec/add-f-chart-horizontal-bar/specs/chart-rendering/spec.md:5-7`；`f_chart/doc/spec/add-f-chart-icicle/proposal.md:10`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」/ §14「承诺面不完整」
- **证据**：静态确定 —— ① 热力图 `HeatmapChart.cj:35-37` 拒绝多系列、`:59-61` 拒绝空行，spec 只写「矩阵非空且每行长度一致」；② 二维直方图 `Histogram2DChart.cj:83-85` 拒绝多系列、`:92-94` 拒绝空 `data`，spec 校验条只列 `bins`/点/`shape`；③ 条形图 `HorizontalBarChart.cj:207-216` 强制 `data` 长度等于 `yAxis.labels` 长度，spec 场景隐含但未声明；④ 冰柱图 `IcicleChart.cj:88-90` 要求 `value > 0`，proposal 只描述字段形状
- **描述**：四条约束都有明确抛错、属对外可观察行为，规格没写 ⇒ 读者无法据此写用例，也无法判断「多系列是否合法」
- **建议**：补进对应 `spec.md` 的校验 Requirement（含 `kind`），或在 proposal 的「What Changes」点名

<!-- 第 13 部分 -->

### [严重][存量] #1 四个图型的 x/y 轴方向与文档轴语义相反：整图被镜像，样例 SVG 已镜像提交

- **位置**：
  - 规格侧（本部分文件）：`f_chart/doc/spec/add-f-chart-lift/specs/chart-rendering/spec.md:23-30`（提升图轴）、`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:5-12`（学习曲线折线）、`f_chart/doc/spec/add-f-chart-lasso-path/specs/chart-rendering/spec.md:5-12`（LASSO 路径）、`f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md:5-12`（影响点）、`f_chart/doc/spec/add-f-chart-line/design.md:7-12`（比例尺约定）
  - 实现侧（交叉核对用，属其他部分）：`f_chart/src/LiftChart.cj:134-135`、`f_chart/src/LassoPathChart.cj:156-157`、`f_chart/src/LearningCurveChart.cj:195-196`、`f_chart/src/InfluenceChart.cj:138-139`
  - 产物侧：`f_chart/charts/M094-lift.svg`、`M097-learning-curve.svg`、`M098-lasso-path.svg`、`M041-influence.svg`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」+ §11「契约与实现不符」
- **证据**：静态确定 —— `LinearScale` 的语义写在 `f_chart/src/ChartScale.cj:22`：「`topPixel` 对应最大值，`bottomPixel` 对应最小值」，`scale()`（`:36-43`）为 `bottomPixel - (v-min)/span*(bottomPixel-topPixel)`，即 min→`bottomPixel`、max→`topPixel`。因此水平轴要"向右递增"必须传 `(plot.right(), plot.x)`，垂直轴要"向上递增"必须传 `(plot.y, plot.bottom())`；`LineChart.cj:177-178` 正是这样传的。而 lift / lasso-path / learning-curve 三处传的是 x→`(plot.x, plot.right())`、y→`(plot.bottom(), plot.y)`（两个方向同时取反＝180° 旋转），influence 只把 x 取反、y 正确。样例可直接读出：`M094-lift.svg` 的 x 刻度 `0` 在 `x=736`、`1` 在 `x=56`；`M097-learning-curve.svg` 的 y 刻度 `0` 在 `y=74`、`1` 在 `y=432`；`M041-influence.svg` 的 x 刻度 `0` 在 `x=908`、`0.1` 在 `x=577`。
- **描述**：提升图 x=0 应贴左边、学习曲线 y 越大应越靠上，这是读图前提。当前四个图型坐标框整体反向：提升曲线在 100% 处收于左侧、学习曲线随样本量增加向右下走、LASSO 的 0 系数线画在上方、杠杆图的杠杆值向右递减。由于 `drawXAxisNumeric` / `drawYAxis` 都按 `scale` 摆刻度（`ChartFrame.cj:168-187`、`:278-310`），刻度文字随数据一起反向，图形自洽所以"看不出错"，但结论会被读反。文档的问题是：这 5 份 spec/design 只写"范围覆盖全部数据 + 留 3%/5%/8% 余量"（如 `add-f-chart-lift/specs/chart-rendering/spec.md:25`、`add-f-chart-line/design.md:9-11`），**没有任何一条 requirement / scenario 约束轴方向**，镜像实现能通过全部验收场景，现有测试也只断言 class 计数与文案（`LearningCurveChart_test.cj:56-57,100,115`），不断言坐标。
- **建议**：把四处 `LinearScale` 实参改为 x→`(plot.right(), plot.x)`、y→`(plot.y, plot.bottom())`（与 `LineChart` 对齐）并重生成 `charts/M041/M094/M097/M098`；规格侧在 4 份 `specs/chart-rendering/spec.md` 各补一条 scenario：「WHEN 数据 x 递增 THEN 首点像素 x 严格小于末点像素 x」「WHEN 数据 y 递增 THEN 首点像素 y 严格大于末点像素 y」，把方向变成可回归的契约。
- **备注**：`.cj` 不在本部分清单内，本条按"文档契约与实现不符"立项，修代码时与上述四个图型所属子轮的发现合并，避免重复计数。

### [一般][存量] #2 学习曲线的 `std` 不随 `x` 排序重排，置信带与 y 轴范围按错位索引计算

- **位置**：`f_chart/doc/spec/add-f-chart-learning-curve/design.md:5`（"`std` 与 `data` 等长"）、`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:39`（"`std` 提供时长度 MUST 与 `data` 一致"）；实现 `f_chart/src/LearningCurveChart.cj:80-114`（`std` 按输入顺序收集）、`:112`（只排 `points`）、`:131-134`（轴范围按 `index` 取 `std`）、`:220-245`（置信带按 `position` 取 `std`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— `raw` 逐条 `add([x, y])` 后经 `sortLiftPoints(raw.toArray())` 得到按 x 升序的 `points`（`:112`），`stdValues` 是另一条独立数组（`:80-107`），全程没有跟随同一次置换；`LearningSeries` 只保存两份并行数组（`:24-33`）。随后 `dataMinY/dataMaxY`（`:131-134`）与闭合 path（`:222-235`）都用同一个下标同时索引 `points[i]` 与 `std[i]`。只要输入 data 不是按 x 升序（README 与样例恰好升序，掩盖了问题），第 i 个标准差就落到另一个 x 上。
- **描述**：规格承诺 `std` 与 `data` 逐点等长，读者会理解为"每点的 ±标准差"；排序后这条对应关系丢失。后果两层：(1) 置信带上/下包络取错点，带宽忽宽忽窄甚至交叉；(2) `y ± std` 参与 y 轴范围，轴范围与所有系列的刻度一起偏。`LearningCurveChart_test.cj:85-101` 只断言 `learning-band` 出现 1 次，覆盖不到这层。
- **建议**：把 `std` 与点绑定为一个内部结构（如 `LearningPoint(x, y, std)`）后再排序，或排序时同步置换 `std`；补一条"输入 data 逆序、std 已知"的用例，断言 band 的 y 值与轴范围。

### [一般][存量] #3 冰柱图静默丢弃与根不连通的节点，且"环检测"分支恒不成立

- **位置**：`f_chart/doc/spec/add-f-chart-icicle/specs/chart-rendering/spec.md:5-18`（"MUST 为每个节点绘制一个矩形"+ 七个节点场景）、`:42-54`（校验只要求"父存在 / 恰好一个根"）；实现 `f_chart/src/IcicleChart.cj:94-111`（建树 + 只校验根的个数）、`:166-169` 与 `:182-185`（`depth > total` 判环）、`:192-200`、`:241-243`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空集合 / 边界未处理」、§1「恒真恒假分支」、§13「规格与实现漂移」
- **证据**：静态确定 —— 每节点只有一个 `parentId`，父存在即挂到 `children`（`:96-105`），不满足的只有"根不是恰好 1 个"（`:106-108`）。取 `R(parent=null)`、`A(parent=B)`、`B(parent=A)`：`roots=[R]` 通过校验，`A`/`B` 互为父子、永远遍历不到；`validateValues` / `assignDepth` / `layoutNode` / `drawNode` 都从 `rootNode` 出发（`:110-111`、`:139`、`:151`），于是 A、B 既不出现在 SVG 里也不报错——该输入满足 spec 的全部校验（parent 都存在、恰好一个根、value>0），按 spec 应输出 3 个 `icicle-node`。同时 `depth > total` 的两处判环（`:167`、`:183`）在这种情况下到不了；对"从根可达"的集合，因每节点至多一个父，可达子图必然无环，这两个分支恒为假。
- **描述**：坏输入被"部分渲染 + 不报错"吞掉，用户看到一张少画了节点的图且无任何信号；两处防御代码给出"已做环检测"的错觉。
- **建议**：建树后做一次可达性统计（节点数 vs 遍历点数），不等即抛 `chartInvalidValue("nodes", "存在与根不连通的节点")`；删掉 `validateValues` / `assignDepth` 里恒假的 `depth > total` 判断，或改为基于访问计数的检查。
- **备注**：`.cj` 不在本部分清单内，本条按"文档契约与实现不符"立项，与第 12 部分（`parts/f_chart.part12.md` #5）的同源代码发现合并即可，避免重复计数。

### [一般][存量] #4 时间轴解析既不校验日历合法性也不拒绝尾部多余字符，非法日期被静默归一

- **位置**：`f_chart/doc/spec/add-f-chart-line/design.md:25-27`（"`ChartTime.parseDays` 支持 `YYYY-MM-DD` 与 `YYYY-MM-DDTHH:MM:SS`（忽略时间部分）"）；实现 `f_chart/src/ChartTime.cj:28-39`（只检查长度 ≥10、`-` 位置与 `1..12 / 1..31`）、`:60-71`（`daysFromCivil`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」、§13「文档写 A 实现做 B」
- **证据**：静态确定 —— 长度判断是 `bytes.size < 10`（`:29`），只校验 `bytes[4]`、`bytes[7]` 是 `-`，第 10 位之后的任何内容全部忽略，因此 `"2026-01-01xyz"`、`"2026-01-01T99:99"` 都被接受（文档只声明两种形态）。日期只判 `day <= 31`（`:35`），`"2026-02-31"` 通过后由 `daysFromCivil` 按连续日期处理得到 2026-03-03。
- **描述**：文档把 `YYYY-MM-DD` 当契约，实现却接受"月份内不存在的日"和任意尾缀。时间轴数据来自用户 JSON，无声归一化会把 2 月 31 日画成 3 月 3 日的点，与相邻点的相对位置一起错，且从图上无法看出输入非法。
- **建议**：`parseDays` 增加每月天数校验（含闰年）与"第 10 位之后必须是 `T` 或结束"的判断，非法即抛 `chartInvalidValue(path, "日期不合法")`；文档同步写明"仅接受 `YYYY-MM-DD[T…]`，非法日期报错"。

### [一般][存量] #5 LASSO 路径图单系列时图例被整体隐藏，违反 spec 的 MUST

- **位置**：`f_chart/doc/spec/add-f-chart-lasso-path/specs/chart-rendering/spec.md:14-21`（"MUST 输出每个系列名称的图例文本"）；实现 `f_chart/src/LassoPathChart.cj:154`（`legendVisible = config.legend.show && series.size > 1`）、`:175`（仍无条件调 `drawLegend`）、`f_chart/src/ChartFrame.cj:134-137`（`!legendVisible` 直接 return）；测试 `f_chart/src/LassoPathChart_test.cj:64-69` 只覆盖 4 系列
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「契约与实现不符」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 单系列且 `legend.show` 默认真时 `legendVisible=false`，`ChartFrame` 因此不为图例预留高度，`drawLegend` 在 `:135-136` 提前返回；系列名在整份 SVG 里没有任何输出点（路径与点都不带标签）。spec 的 requirement 不带"多系列才显示"的前提，scenario 用的是两个变量名（`年龄`、`血压`），单系列场景无覆盖。
- **描述**：LASSO 路径图的唯一身份信息就是变量名，单变量输入时用户拿不到"这条线是谁"的提示；同时 `drawLegend` 传入完整 `names`/`colors` 却什么都不画，可见性判断与调用点分散在两处，后续改成 `>= 1` 时容易只改一边。
- **建议**：二选一并写进 spec——(a) 单系列也显示：`154` 改为 `config.legend.show && !series.isEmpty()`，spec 补 scenario；(b) 保持隐藏：spec `:16` 改成"单系列时除外"，并把 `drawLegend` 调用移进 `if (legendVisible)`，让判断与调用同源。

### [轻微][存量] #6 时间轴刻度没有"按天取整"，短跨度时日期标签重复

- **位置**：`f_chart/doc/spec/add-f-chart-line/design.md:27`（"刻度按天取整"）；实现 `f_chart/src/LineChart.cj:151-156`（`chartNiceTicks` 直接作用于天数）、`:365-375`（`formatXTicks`）、`f_chart/src/ChartTime.cj:42-45`（`formatDays` 里 `Int64(days)` 截断）；`f_chart/src/ChartScale.cj:70-105`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 与实现不符」
- **证据**：静态确定 —— `chartNiceTicks` 按 1/2/5×10ⁿ 生成步长，不做整数化；`formatDays` 对小数天数直接 `Int64(days)` 截断。x 数据跨度小于 2 天（如只有 `2026-01-01`、`2026-01-02`）时，5% 余量 + nice 步长会落在 0.5 天这种位置，两个不同刻度被格式化成同一个 `YYYY-MM-DD`。
- **描述**：文档承诺刻度按天对齐，实现只保证"标签是日期字符串"，时间轴会出现两个同文本刻度，跨度越小越容易触发；另外 `Int64()` 对 1970 年以前的负天数向零截断，会整体偏一天。
- **建议**：时间轴刻度改为整数天步长（≥1 天），或对 `formatDays` 结果去重/合并，并对负天数改用向下取整；`design.md:27` 若只是意图描述，改为"刻度按 nice 步长生成、标签取整到天"。

### [轻微][存量] #7 `symbol` 非法取值静默退化为圆点，文档列的四种取值没有被校验

- **位置**：`f_chart/doc/spec/add-f-chart-line/proposal.md:11`（`symbol`（circle/square/diamond/none））；实现 `f_chart/src/LineChart.cj:117`（`string("symbol", default: "circle")`）、`:447-452`（`case _ => circle`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「契约与实现不符」（枚举值无校验）、§11「错误处理静默」
- **证据**：静态确定 —— `drawSymbol` 的 `match` 只有 `"none"` / `"square"` / `"diamond"` 三个精确分支，其余（含拼错的 `"squar"`、`"Circle"`）一律落到 `_ => kit.circle(...)`，全文件无 `chartInvalidValue("symbol", …)`。
- **描述**：其余图型对枚举字段普遍抛 `InvalidValue`（如 `IcicleChart.cj:114-120` 的 `orientation` / `colorBy`），折线图的 `symbol` 是例外：写错不报错、直接变形，用户会以为"diamond 不支持"。
- **建议**：读入后立即校验四值，非法抛 `chartInvalidValue("series[i].symbol", "期望 circle / square / diamond / none")`；`case _` 可保留为 `circle`，但校验前移。

### [轻微][存量] #8 影响图 design 描述的负 Cook 距离分支在公开路径上不可达

- **位置**：`f_chart/doc/spec/add-f-chart-influence/design.md:9-12`（"`cooks <= 0` 或 `maxCooks <= 0` 时返回 4"）、`f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md:14-26`（"等于最大值时返回 12"）；实现 `f_chart/src/InfluenceChart.cj:80-87`（负值抛 `InvalidValue`）、`:202-207`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒真恒假分支」的文档侧对应、§13「文档描述与可观测行为不符」
- **证据**：静态确定 —— 进入 `influenceRadius` 的 `cooks` 只可能来自已通过 `0 <= value` 校验的 `cooksDistance`（`:82-84`）或常量 4（`:159`），`cooks <= 0.0` 只剩 `cooks == 0` 可达，`cooks < 0` 这一半永远走不到。且所有点的 `cooksDistance` 都为 0 时 `maxCooks = 0`，函数返回 4，与 spec「等于样本最大值 → 12」的场景冲突（design `:11` 的退化规则没写进 spec）。单测 `InfluenceChart_test.cj:90,96` 只覆盖 0 与最大值。
- **描述**：design 把"负值返回 4"写成映射规则，读者会以为负 Cook 距离被当作 0 处理，实际是抛错；spec 的"最大值→12"场景在全 0 输入下不成立。两处都给后续维护者留下错误预期。
- **建议**：design `:11` 改成"`cooks == 0` 或 `maxCooks <= 0` 时返回 4（负值在校验阶段已拒绝）"；spec 的 Cook 距离映射 requirement 补"所有距离为 0 时半径取 4"。

### [轻微][存量] #9 两个图型输出了 proposal 清单里没有的 class（`lift-baseline-label`、`lasso-zero`）

- **位置**：`f_chart/doc/spec/add-f-chart-lift/proposal.md:12`（列 3 个 class）、`f_chart/doc/spec/add-f-chart-lasso-path/proposal.md:11`（列 2 个 class）、`f_chart/doc/spec/add-f-chart-lasso-path/design.md:17`（零线只写颜色，未给 class）；实现 `f_chart/src/LiftChart.cj:162-168`、`f_chart/src/LassoPathChart.cj:178-181`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期」、§14.2「公开 API 未文档化」（class 名是样式契约）
- **证据**：静态确定 —— `LiftChart` 在基准虚线右端另画 `className: "lift-baseline-label"` 的文本；`LassoPathChart` 的零线用 `className: "lasso-zero"`。两个 class 在对应 proposal / spec 的 class 清单里都不存在（全仓 grep 只在源码与 SVG 命中）。
- **描述**：class 名是对外样式钩子，下游用它写 CSS / 断言；少列两个 class 会让按文档写样式的人漏掉基准值标签与零线，也让"按 class 计数"的测试漏测。
- **建议**：在两份 proposal 的清单补 `lift-baseline-label`（基准值文本）与 `lasso-zero`（零系数参考线），各加一条 scenario。

### [轻微][存量] #10 折线图 design 对轴余量与类目标签的描述与实现不一致

- **位置**：`f_chart/doc/spec/add-f-chart-line/design.md:7-12`（"y 范围：显式 min/max 优先；否则 min/max 各留 5%"）、`f_chart/doc/spec/add-f-chart-line/proposal.md:10`（类目模式只用数值数组）；实现 `f_chart/src/LineChart.cj:456-478`（`lineRange`：`:468` / `:472` 单侧缺省时不留余量）、`:287-302`（缺省生成 `1..n` 类目标签）、`:304-313`（`xAxis.labels` 长度必须等于每个系列点数）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 关键行为未记录」
- **证据**：静态确定 —— `lineRange` 只给 `axisMax` 时 `minimum` 直接取 `dataMin`（`:468`），只给 `axisMin` 时 `maximum` 取 `dataMax`（`:472`），与"否则两侧各留 5%"的字面不一致；`resolveLabels` 在没给 `xAxis.labels` 时生成 `"1"…"n"`，`validateLengths` 又要求每个系列点数与标签数完全相等，两条行为在 design / proposal 里都没提。
- **描述**：三处都是"用户会踩到但文档没写"的行为：只设 `yAxis.max` 时图形贴边（而非留 5%）、类目轴默认标签是序号而不是数据的 x、多系列长度不一致会抛 `InvalidValue`。按 design 推断会得到错误预期。
- **建议**：design §2 写明"单侧显式时另一侧贴数据、不额外留余量"，§4 补"类目模式缺省标签为 `1..n`、`xAxis.labels` 长度必须与每个系列一致"。

### [轻微][存量] #11 影响图 spec 未声明"恰好 1 个系列"，多系列输入被判非法

- **位置**：`f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md:37-39`（校验 requirement 只写 `x` / `y` / `cooksDistance` / `data` / `series` 缺失）；对照 `f_chart/doc/spec/add-f-chart-lift/specs/chart-rendering/spec.md:32-34`（提升图明写"`series` MUST 恰好 1 个"）；实现 `f_chart/src/InfluenceChart.cj:50-52`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「只做了一半的分支 / 承诺与实现不齐」、§13
- **证据**：静态确定 —— 实现拒绝 `series.size != 1`（"仅支持 1 个系列"，`InvalidValue`），而同批的 lift 图把这条写进了 spec；influence 的 spec 只在 proposal `:10` 用 `series[0].data` 隐含单系列。
- **描述**：按 influence spec 逐条实现，两个系列应当合法（spec 无数量限制），实际抛错，会直接变成用户工单。
- **建议**：influence spec 的校验 requirement 补"`series` MUST 恰好 1 个"，scenario 补"两个系列 → `InvalidValue`"，与 lift 对齐措辞。

### [轻微][存量] #12 冰柱图标签规格场景未说明"节点宽度不足时不输出标签"

- **位置**：`f_chart/doc/spec/add-f-chart-icicle/specs/chart-rendering/spec.md:14-17`（"WHEN 节点 name 为 main THEN SVG 中包含 icicle-label 文本 main"）；实现 `f_chart/src/IcicleChart.cj:227-240`（`if (node.width > chartTextWidth(node.name, fontSize) + 6.0)` 才输出）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」（MUST 级验收场景缺前置条件）
- **证据**：静态确定 —— `spec.md:7` 的 requirement 是"为每个节点绘制矩形"，scenario 对标签无条件断言；实现按"矩形宽度是否容得下文本 + 6px"决定是否画 `icicle-label`。深层或小 value 节点天然宽度不足，因此"每个节点都有标签"并不成立；`IcicleChart_test.cj:66-70` 只断言 `main` / `layout` 两个宽节点，掩盖了差异。
- **描述**：按 scenario 写验收用例（小 value 叶子节点 + 检查标签）会失败；反过来，用户按文档以为标签是保证项，实际图上有节点无标签且无提示。
- **建议**：scenario 补前置条件（"WHEN 节点宽度足以容纳文本 THEN 输出 icicle-label"），或在 requirement 里显式写"标签按可用宽度省略，截断策略见实现"。

### [轻微][存量] #13 学习曲线的 `metric` 字段只做取值校验，对输出零影响（"语义标注"未接线）

- **位置**：`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:28-35`（"`metric` MUST 为 `score` 或 `loss`（默认 `score`），仅用于语义标注，不改变坐标方向"）、`f_chart/doc/spec/add-f-chart-learning-curve/proposal.md:11`（`metric`（`score` / `loss`））；实现 `f_chart/src/LearningCurveChart.cj:43-46`（读出后仅做相等比较，之后不再使用）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」（配置字段无效果）、§14.1「接线缺失」
- **证据**：静态确定 —— 全文件 `metric` 只有两处命中（`:43` 读取、`:44-45` 校验），SVG 里没有任何由 `metric` 派生的文本、`class` 或轴标题回退；`README.md:2212-2229` 的示例也带 `"metric": "score"`，读者会以为它有可见作用。
- **描述**：spec 用"语义标注"描述该字段，实现只把它当合法枚举校验；`loss` 与 `score` 输出完全一致（含 y 轴方向），字段实际上是死配置。这不影响数据正确性，但契约与实现口径不一致。
- **建议**：二选一并写进 spec——(a) 真正做标注（如无显式 `yAxis.title` 时回退为 metric 语义、或在根节点输出 `data-metric`）；(b) 改成"仅做取值校验，供调用方自行解释"，并删掉"语义标注"字样。

### [轻微][存量] #14 单点系列输出只有 `M` 的 path：文档承诺的"折线"在 1 个数据点时不可见

- **位置**：`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:7`、`add-f-chart-lasso-path/specs/chart-rendering/spec.md:7`、`add-f-chart-lift/specs/chart-rendering/spec.md:7`（三处均要求"输出 1 条折线并连接全部数据点"）；实现 `f_chart/src/LearningCurveChart.cj:246-262`、`f_chart/src/LassoPathChart.cj:186-202`、`f_chart/src/LiftChart.cj:171-187`；校验处 `add-f-chart-learning-curve/specs/chart-rendering/spec.md:39`、`add-f-chart-lasso-path/specs/chart-rendering/spec.md:25`、`add-f-chart-lift/specs/chart-rendering/spec.md:34`（只要求 `data` 非空）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格未覆盖的边界」
- **证据**：静态确定 —— 三处路径生成都是 `position == 0 → "M x y"`、其余 `" L x y"`；`data` 只有 1 项时 path 只有一条 `M` 指令，无 `L`、无描边长度，SVG 里 `class="*-line"` 元素存在但不渲染任何线；三个 spec 都允许 `data` 长度为 1。
- **描述**：单点系列（如只有 1 个样本量的评估结果）得到的是一条看不见的"折线" + 1 个圆点，按 class 计数的测试仍会通过。文档既没规定最少点数，也没说明单点退化为散点。
- **建议**：spec 补"`data` 至少 2 点"（并在实现里加 `InvalidValue`），或明确"单点系列只输出圆点、不输出 line"，二者取一并让测试跟着断言。

<!-- 第 14 部分 -->

### [一般][存量] #1 曼哈顿图 proposal 承诺的 `manhattan-chromosome` 染色体名标注无验收条款、无实现

- **位置**：`f_chart/doc/spec/add-f-chart-manhattan/proposal.md:12`（承诺）；同变更 `specs/chart-rendering/spec.md:5-12`（无对应 Requirement）、`design.md:13-18`（无对应图元）
- **来源**：存量（快照无基线；`git log` 显示 `proposal.md` 与 `ManhattanChart.cj` 同属提交 `77980d72c`，即归档时既已不一致）
- **判据**：review-checklist §14.1「承诺了但没实现」（承诺源 + 缺失证据双证）、§13「归档变更的结论不自洽」
- **证据**：静态确定 —— 全仓检索 `manhattan-chromosome` 只在 `proposal.md:12` 命中，`f_chart/src/` 与 `*_test.cj` 零命中（`.worktrees/` 副本不计）；`ManhattanChart.cj:134-147` 生成的是数值 nice ticks，`:222` 走 `drawXAxisNumeric(kit, xTicks, xScale, xTickLabels)`，全图没有任何"染色体名"文本；`design.md:18` 反而写"改为按显示位置生成 nice ticks"，说明设计阶段已经放弃染色体名，却没有回写 proposal / 补一条"被裁剪"的说明。
- **描述**：proposal 把"染色体名称以 `manhattan-chromosome` 文本标注"列为本次变更的输出之一，spec 的验收面与实现都没有它。按 proposal 写 CSS（`.manhattan-chromosome { … }`）或做文本断言的下游使用者必然落空；归档 `openspec validate` 只校验 spec，不会发现 proposal 多承诺了一层。
- **建议**：二选一并写进 spec。保留：补 Requirement「每组染色体起始处 MUST 输出 `class="manhattan-chromosome"` 文本，内容为该染色体名」并实现；裁剪：删掉 `proposal.md:12` 该句，并在 `design.md:18` 记明"横轴改为数值刻度，不再标注染色体名"。

### [一般][存量] #2 曼哈顿图两处视觉契约与实现不符：配色是调色板轮转而非两色交替，阈值线标注是数值而非「阈值」

- **位置**：`f_chart/doc/spec/add-f-chart-manhattan/specs/chart-rendering/spec.md:7`、`design.md:15`（配色）；`design.md:17`（阈值线标签）；对照 `f_chart/src/ManhattanChart.cj:213`、`:195-201`、`f_chart/src/ChartTheme.cj:18-21`、`:54-59`
- **来源**：存量（快照无基线；文档与实现同属提交 `77980d72c`）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§11「语义与命名 / 注释不符」
- **证据**：静态确定 —— `spec.md:7` 要求"颜色 MUST 按染色体顺序在两种主题色之间交替"，`design.md:15` 写"按染色体索引奇偶在主题前两色间交替"；实现是 `config.theme.colorAt(chromosomeIndex)`，而 `ChartTheme.colorAt` 是 `palette[index % palette.size]`，默认 `CHART_DEFAULT_PALETTE` 有 10 色。结果是第 1/2/3 条染色体依次取蓝 / 橙 / 红，第 11 条才回到第 1 色，不存在"奇偶两色交替"。阈值线一处：`design.md:17` 写"右端标注 `阈值`"（反引号内是字面量），实现 `195-201` 输出的是 `chartFormatTick(value, config.yAxis.labelFormat)`（默认 `"{value}"`，`ChartConfig.cj:62`），即阈值数值，类名 `manhattan-threshold-label`。
- **描述**：配色一条是 spec 级 MUST 与实现相反：按 spec 写的视觉回归（第 2、4、6 条同色）在当前默认主题下会失败，反之按实现写的断言无法在 spec 找到依据。阈值标签一条是 design 与实现的文案差异；若 `阈值` 想表达"标注阈值（值）"，则现状可接受，但文档用反引号写成了字面量，无法唯一判定。数据正确性不受影响。
- **建议**：配色二选一——实现改 `config.theme.colorAt(chromosomeIndex % 2)`（贴合"交替"），或把 `spec.md:7` / `design.md:15` 改成"按染色体索引轮转主题调色板"（贴合当前实现，且 10 色区分度更好）。阈值标签同理：实现补 `阈值` 前缀，或 design 改成"右端标注阈值数值"。改完在 `ManhattanChart_test.cj` 补一条颜色/标签断言钉住。

### [一般][存量] #3 棒棒糖图纵轴两条 MUST 互斥，`yAxis.min > 0` 时茎基线被外推到绘图区之外

- **位置**：`f_chart/doc/spec/add-f-chart-lollipop/specs/chart-rendering/spec.md:30`、`design.md:10`；对照 `f_chart/src/LollipopChart.cj:112-131`、`:187`、`:198-201`、`f_chart/src/ChartScale.cj:36-43`
- **来源**：存量（快照无基线；文档与实现同属提交 `3a0b00e1f`）
- **判据**：review-checklist §11「契约与实现不符」「缺少边界校验」、§13「规格与实现漂移」
- **证据**：静态确定 —— `spec.md:30` 同一条里两条 MUST 无法同时满足："纵轴范围 MUST 包含 0" 与 "`yAxis.min` / `yAxis.max` 给出时 MUST 按给定值"；`yAxis.min = 2` 时没有裁决优先级。`design.md:10` 用"范围至少包含 0；`yAxis.min` / `yAxis.max` 可覆盖"暗示覆盖优先，但没写覆盖后基线取哪。实现选了覆盖优先（`LollipopChart.cj:124-131` 直接采用给定值，缺省时 `dataMin/dataMax` 以 0 初始化以保证含 0），而 `:187` 无条件 `yScale.scale(0.0)` 作基线。`LinearScale.scale` 是纯线性外推、无钳制（`ChartScale.cj:36-43`）：`yMin = 2` 时 `scale(0)` 落在 `plot.bottom()` 之下，`chart` 也没有任何 `clipPath`（`ChartFrame.cj` / `ChartSvgKit.cj` 检索 `clip` 无命中），茎线（`198-201`）从 x 轴标签区画到数据点。
- **描述**：合法输入（为了放大 4.0–5.0 的转化率区间而设 `yAxis.min > 0`）会得到"茎从画布下方长出来、穿过类目标签"的图，既无异常也无裁剪；`yAxis.max < 0` 时对称地向上溢出。这是本部分唯一"输入合法、图形错误"的条目。
- **建议**：把 spec 两条合并成可判定的一条：「未显式给 `yAxis.min` 时下界取 `min(0, 数据最小值)`；显式给定时基线取 `clamp(0, yMin, yMax)`」；实现侧 `baseline = yScale.scale(clamp(0.0, yMin, yMax))`，并补 `yAxis.min > 0`、`yAxis.max < 0` 两个用例。

### [一般][存量] #4 马赛克图「列总和 MUST 大于 0」口径不明，零列静默产出零宽单元与重叠标签

- **位置**：`f_chart/doc/spec/add-f-chart-mosaic/specs/chart-rendering/spec.md:34`、`design.md:5`；对照 `f_chart/src/MosaicChart.cj:94-101`、`:156-177`、`MosaicChart_test.cj:118-133`
- **来源**：存量（快照无基线；文档与实现同属提交 `60c08fa90`）
- **判据**：review-checklist §11「缺少边界校验」「语义与命名 / 注释不符」、§13「规格与实现漂移」
- **证据**：静态确定 —— `spec.md:34` 的校验清单写"列总和 MUST 大于 0"，`design.md:5` 写"值必须非负，列总和大于 0"，两处都没有说"每一列"还是"所有列合计"。实现只校验合计：`94` 求 `totals` 后 `97-98` 累加，`99-101` 仅在 `grandTotal <= 0.0` 时抛 `InvalidValue`（文案仍是"列总和必须大于 0"）；`:156` `columnWidth = totals[column] / grandTotal * plotWidth`，某列全 0 时宽度为 0，`158-171` 仍按系列数输出该列的 `width=0` 矩形，`:172-178` 的 `mosaic-label` 落在 `cursorX + 0/2`，与相邻列标签挤在同一坐标附近。`MosaicChart_test.cj:118-133` 的 `rejectsZeroTotal` 只覆盖"所有列全 0"。
- **描述**：合法输入（例如第 3 类两个系列都是 0）会得到"少一列可见单元 + 标签重叠"的图；按 spec 写"某列合计为 0 → 抛 InvalidValue"的用例会失败，按实现写"合计为 0 才抛"的用例会通过，验收口径取决于解释。
- **建议**：在 spec / design 明确写成"任意一列的合计 MUST 大于 0"，实现加逐列校验并抛 `chartInvalidValue("series", "第 N 列合计必须大于 0")`；若产品上允许空列，则明确"合计为 0 的列不输出单元与标签，宽度 0 且后续列紧邻"，并补一个"4 列含 1 个零列"的用例钉住。

### [一般][存量] #5 网络热力图只约定 N×N 矩阵、不设节点数上限，平方放大后没有拒绝路径

- **位置**：`f_chart/doc/spec/add-f-chart-network-heatmap/design.md:5-6`、`:10`、`proposal.md:11`；对照 `f_chart/src/NetworkHeatmapChart.cj:43`、`:80`、`:182-204`
- **来源**：存量（快照无基线；文档与实现同属提交 `1ea3e056b`）
- **判据**：review-checklist §5「平方级增长」「按不可信长度预分配」、§14.1「契约要求但无拒绝路径」
- **证据**：静态确定（放大关系）+ 需实测（峰值字节）—— `design.md:6` 要求"`series[0].data` 必须为 N×N 数值矩阵，N 等于节点数"，`:10` 要求绘图区按 N 等分；实现只校验方阵与阶数一致（`80-100`）、`nodes` 非空（`43`），**没有任何上限**，随后 `182-192` 双层循环输出 order² 个 `network-heatmap-cell`，`showValues` 为 true 时 `193-203` 再输出 order² 个文本。N=1000（JSON 约 3 万字符）→ 10⁶ 个矩形，按每段 `<rect …/>` 约 90–120 B 估算，仅最终 SVG 字符串就 90–120 MB，`SvgBuilder` 扩容期间还要再翻一份；N=3000 → 9×10⁶ 个矩形，1 GB 量级。
- **描述**：输入体积与输出体积是平方关系，"小输入放大成大输出"。文档层没有任何"上限 / 分批 / 拒绝"条款，照 spec 实现也不会想到加保护。是否升为严重取决于 `nodes` 是否来自外部请求，文档没声明输入信任边界，故按"库调用方可控"记一般，峰值数据列入待验证假设 #1。
- **建议**：在 design / spec 加常量上限（例如 `order <= 200`，对应 4 万个单元）并在超限时抛 `chartInvalidValue("nodes", "节点数超过 N 上限")`；同时在 design 注明"图元数 = N²，`showValues` 时文本再乘 1"。若确需大矩阵，另开"降采样 / 分块"需求，而不是放开上限。

### [轻微][存量] #6 曼哈顿图 design 留着两处草稿残句（自问自答 + 半句）

- **位置**：`f_chart/doc/spec/add-f-chart-manhattan/design.md:16`、`:18`
- **来源**：存量（快照无基线；同属提交 `77980d72c`）
- **判据**：review-checklist §10「可读性 / 可维护性」、§13（文档质量）
- **证据**：静态确定（文本）—— `16` 行原文"数据按显示位置排序后绘制折线？不画折线，只画散点。"，把设问和改口都留在结论段；`18` 行原文"x 轴刻度使用显示位置，标签保留原始数值格式不便，改为按显示位置生成 nice ticks。"，"不便"是删改留下的半句，读者无法判断被否掉的是哪种方案。
- **描述**：design 是维护者判断"为什么这样画"的唯一依据；这类残句让"是否画折线""x 轴标签到底是什么"重新变成开放问题，也是 #1 里"染色体标注被静默裁剪"没有被记录下来的同一处上下文。
- **建议**：`16` 行改为"只画散点，不画折线；点按显示位置绘制，不排序"；`18` 行改为"x 轴刻度按显示位置生成 nice ticks，标签为数值（不显示染色体名，见 proposal 裁剪说明）"。

### [轻微][存量] #7 模块设计把计划写成了现状：`ChartScale` 的「对数 / 分段比例尺」与 `testdata/` 黄金文件都不存在

- **位置**：`f_chart/doc/spec/add-f-chart-module/design.md:32`（ChartScale 职责）、`:162`（黄金文件测试策略）
- **来源**：存量（设计属 M0 提交 `53aed4b9c`；`ChartScale.cj` 在 M1 提交 `113c9eaf0` 落地，画廊在 `73c582164` 加入，均未回写设计）
- **判据**：review-checklist §13「文档过期」、§14.1「计划中的能力未落地」
- **证据**：静态确定 —— `ChartScale.cj` 只有 `LinearScale`（`:23`）与 `BandScale`（`:47`）两个比例尺类，检索 `LogScale` / `SegmentScale` / "分段" 零命中；对数轴是在 `ForestChart.cj:110` 用 `axisType == "log"` 内联实现（`:230-243`），没有共享比例尺。测试侧：`f_chart/` 下无 `testdata/` 目录，`src/*_test.cj` 检索 `testdata` / `File.read` 零命中；`ChartGallery_test.cj:24-38` 只把 SVG 写进 `charts/` 并断言 `contains("<svg")`，不构成逐字节或结构比对，`ComboChart_test.cj` 等 5 个"结构复杂"的图也没有黄金文件比对。
- **描述**：按 design 找 `ChartScale` 的对数 / 分段比例尺会找不到；按"黄金文件放 `testdata/`"找回归基线也找不到。前者把"共享基础设施"的范围写大了（真实实现是各图内联），后者让 M7/M9/M10/M36/M85 这些最易回归的图只剩 `contains("<svg")` 级断言。两者都不影响当前产物运行，属文档与工程现状脱节。
- **建议**：design 的目录注释改成"线性 / 带状比例尺（internal；对数轴目前由 ForestChart 内联实现）"；测试策略改为"样例画廊 `charts/` + 关键结构断言"，或按原计划补 `testdata/` 黄金比对（二选一，别让文档悬空）。

### [轻微][存量] #8 网络热力图文档点名复用 `heatmapColor`，实现用的是另一支 `heatFlameColor`

- **位置**：`f_chart/doc/spec/add-f-chart-network-heatmap/design.md:11`、`proposal.md:27`；对照 `f_chart/src/NetworkHeatmapChart.cj:189`、`f_chart/src/HeatFlameChart.cj:260`、`f_chart/src/HeatmapChart.cj:225`
- **来源**：存量（快照无基线；文档与实现同属提交 `1ea3e056b`）
- **判据**：review-checklist §13「API / 配置与源码不符」、§11「语义与注释不符」
- **证据**：静态确定 —— `design.md:11` 写"用 `heatmapColor` 在 `colorRange` 上插值"，`proposal.md:27` 写"复用 `heatmapColor` 与热力图的单元格布局"；实现 `NetworkHeatmapChart.cj:189` 调的是 `heatFlameColor(ratio, colorRange)`（定义在 `HeatFlameChart.cj:260`，签名为 `(ratio, colors: Array<String>)`）。`heatmapColor` 是 `HeatmapChart.cj:225` 的三色版 `(ratio, low, mid, high)`，本图并未调用。
- **描述**：文档点名的助手不是实际使用的那个。维护者按 design 去改 `heatmapColor` 不会影响本图；反过来，本图对 `HeatFlameChart.cj` 的内部函数存在跨图文件依赖，文档里也看不到。属于"复用关系记错"，不影响输出正确性。
- **建议**：把两处文档改成 `heatFlameColor`（并注明它来自 `HeatFlameChart.cj`）；或把"任意长度色带插值"抽到 `ChartSvgKit` / `ChartScale` 一类公共助手，让 heatmap / heat-flame / network-heatmap 共用，但这属实现侧改动，需另开条目。

<!-- 第 15 部分 -->

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

<!-- 第 16 部分 -->

### [严重][存量] #1 PDP 的 Y 轴被上下画反：预测值越大越靠下

- **位置**：`f_chart/src/PdpChart.cj:133`（`let yScale = LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)`）
- **来源**：存量（快照模式无基线；`git blame` 不可用的前提下按范围界定文件的约定记存量）
- **判据**：review-checklist §11「契约与实现不符」+ §10「正确性」（坐标换算方向）
- **证据**：静态确定 —— `LinearScale.init(minValue, maxValue, topPixel, bottomPixel)` 的注释写明「`topPixel` 对应最大值，`bottomPixel` 对应最小值」（`f_chart/src/ChartScale.cj:22`），`scale(v) = bottomPixel - (v-min)/span*(bottomPixel-topPixel)`（`ChartScale.cj:41`）。PDP 把 `plot.bottom()` 传成 `topPixel`、`plot.y` 传成 `bottomPixel`，于是 `scale(yMax)` 落在 `plot.bottom()`、`scale(yMin)` 落在 `plot.y`，Y 轴自下而上递减。同模块 `yScale = LinearScale(..., plot.y, plot.bottom())` 的正确写法有 36 处（如 `f_chart/src/LineChart.cj:178`、`f_chart/src/ParetoChart.cj:122`），反序写法只有 10 处（`PdpChart` 以及 `VolcanoChart` / `LiftChart` / `EcdfChart` / `GainChart` / `CalibrationChart` / `BlandAltmanChart` / `LassoPathChart` / `LearningCurveChart` / `ManhattanChart`，均属范围外）。`frame.drawYAxis` 用同一个 `scale` 定位刻度文本（`ChartFrame.cj:172`），所以刻度与折线一起翻转。
- **描述**：PDP 曲线的语义是「特征取值 → 预测均值」，读者靠曲线上升/下降判断边际效应方向。当前实现把 y 轴整体镜像：预测值 0.62 画在底部、0.12 画在顶部，刻度文本也自顶向下递减，等于把「随年龄上升」画成「随年龄下降」。`PdpChart_test.cj` 只统计 `class="pdp-line"` / `pdp-point` 的个数与文本，没有任何坐标断言（`PdpChart_test.cj:60-80`），所以测试全绿。
- **建议**：改为 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`；同时给 `LinearScale` 增加 `static func vertical(min, max, top, bottom)` 之类的具名构造，把「第一个像素参数是最大值所在像素」固化下来，避免再次按直觉传参。补一条断言「x 递增时首点 y > 末点 y（对上升数据）」的用例。

### [一般][存量] #2 平行坐标：单侧显式范围 + 数据整体越界时误抛 `InvalidValue`，与自身「钳制到 [0,1]」的契约冲突

- **位置**：`f_chart/src/ParallelCoordinatesChart.cj:144-171`（范围解析），触发点在 `152-167`
- **来源**：存量
- **判据**：review-checklist §11「边界 / 契约与实现不符」；规格见 `doc/spec/add-f-chart-parallel/specs/chart-rendering/spec.md:23-25`（「`parallelNormalize` MUST … 钳制到 `[0,1]`」）
- **证据**：静态确定 —— 缺省侧用数据极值补齐（`144-151`），随后只要 `explicitMax <= explicitMin` 且**不是两侧都显式**（`153`），就走 `159-167`：`explicitMax == explicitMin` 才扩边，否则抛「维度范围必须递增」。构造输入 `dimensions:[{name:"A", max:10}]` + 某行 `[20]`：`explicitMin = 20`、`explicitMax = 10`，两个 `isSome()` 不成立、`20 != 10` ⇒ 抛 `InvalidValue`。对称地只给 `min:10` 而数据全为 1 时同样抛错。
- **描述**：`parallelNormalize` 明确设计成越界值钳到 0/1（`ParallelCoordinatesChart.cj:271-283`，测试 `ParallelCoordinatesChart_test.cj:66-71` 也断言 `-5 → 0`、`15 → 1`），说明「数据可以落在显式范围之外」是被接受的语义；但范围解析阶段会把这种正常输入整图拒绝。用户只固定上界（常见：`max` 取业务上限）而样本恰好全部超限时，拿不到钳制后的图，只能先自己裁剪数据。同一分支还有一个更隐蔽的变体：只给 `min: 5`、数据全为 5 时 `explicitMax == explicitMin` 成立，走 `159-161` 把范围改成 4.5–5.5——显式给的 `min: 5` 被静默改写，用户指定的边界值直接丢失。
- **建议**：只有「两侧都显式且 `max <= min`」才抛 `InvalidValue`；单侧显式时用该侧值 + 数据另一侧极值组成范围（越界交给 `parallelNormalize` 钳制），即把 `152-167` 改成 `if (bothExplicit && max <= min) throw; if (explicitMax == explicitMin) 扩边`。补一条「只给 max、数据全部超限仍能出图」的用例。

### [一般][存量] #3 画布只有「宽高 > 0」校验，平行坐标硬编码边距在窄画布上把绘图区算成负数

- **位置**：`f_chart/src/ChartConfig.cj:180-184`（仅 `width/height <= 0` 报错）；`f_chart/src/ParallelCoordinatesChart.cj:194-202`（固定 `+60 / -20 / +64 / -40` 边距）
- **来源**：存量
- **判据**：review-checklist §11「边界」+ §10「正确性」（坐标与边界）
- **证据**：静态确定 —— `width = 100`、默认 `padding = 24` 时：`left = 24 + 60 = 84`、`right = 100 - 24 - 20 = 56` ⇒ `step = (right - left)/(n-1)` 为负（`198-202`），维度轴自右向左排；`height = 100` 时 `top = 88`、`bottom = 36` ⇒ `bottom < top`。`ChartConfig.parse` 只要求 `> 0`（`ChartConfig.cj:182`），`ChartFrame` 侧同样只做减法（`ChartFrame.cj:91`），也没有 `plot.width > 0` 断言。
- **描述**：画布尺寸来自 JSON（`width` / `height` 用户可传），`width < 128` 或 `height < 152`（默认 `padding = 24` 时）就能构造出负宽/负高绘图区：轴方向反转、`left/right` 互换后 `x` 坐标全错，但既不报错也不抛异常，输出一张语义错误的 SVG。嵌入式小卡片（如 96×96 缩略图）很容易踩到。
- **建议**：在 `ChartConfig.parse` 里加最小可用尺寸（如 `width >= 160 && height >= 120`，或按 `padding.left + padding.right + 最小绘图区宽` 校验）并抛 `InvalidValue`；平行坐标改用 `ChartFrame.plot` 矩形而不是自己减常量，并在算完 `plot` 后断言宽高为正。

### [一般][存量] #4 `percent-bar` 规格写「`yAxis.max` MUST 固定为 100」，设计与实现都允许显式覆盖

- **位置**：规格 `doc/spec/add-f-chart-percent-bar/specs/chart-rendering/spec.md:16`；实现 `f_chart/src/BarRenderer.cj:379-391`（`resolvePercentRange`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移 / 文档承诺与实现相反」
- **证据**：静态确定 —— 实现 `let maximum = match (axis.max) { case Some(value) => value; case None => 100.0 }`（`BarRenderer.cj:384-387`），即显式 `yAxis.max` 优先；同一变更的 `design.md:9`（「`resolvePercentRange` 返回 `[0, 100]`，除非显式 `min` / `max`」）与 `proposal.md:11`（「显式 `yAxis.min/max` 可覆盖」）都与规格的 MUST 相反。`PercentBarChart_test.cj` 没有任何关于 y 轴范围的断言（`PercentBarChart_test.cj:53-114`）。
- **描述**：规格是对外验收口径。下游若照规格实现（例如测试断言「百分比条 y 轴恒为 0–100」），一旦数据里带 `yAxis.max: 200`，实际输出是 0–200 的轴，各段占比被压到一半高度，「100% 横条」的前提不成立；同一变更包内两份文档互相矛盾，读者无法判断哪个是契约。
- **建议**：二选一并同步三处 —— 要么把规格改成「缺省 0–100，显式 `min`/`max` 可覆盖，此时百分比语义由调用方负责」，要么让 `resolvePercentRange` 忽略 `axis.min/max`（或对显式值抛 `InvalidValue`）。补一条「不给 yAxis → 轴上限 100」的用例把契约钉住。

### [一般][存量] #5 PDP 规格同时要求「轴 MUST 覆盖全部数据」与「显式 min/max MUST 按给定值」，实现按后者且全链路无裁剪

- **位置**：规格 `doc/spec/add-f-chart-pdp/specs/chart-rendering/spec.md:23-30`；实现 `f_chart/src/PdpChart.cj:82-103`（取值）与 `156-180`（画线/画点）
- **来源**：存量
- **判据**：review-checklist §13「规格自洽性」+ §11「缺少边界处理」
- **证据**：静态确定 —— 两条 MUST 在「显式范围不覆盖数据」时不可能同时成立；实现选择后者（`Some(value) => value`，`82-97`），`LinearScale.scale` 对域外值线性外推（`ChartScale.cj:41`，无 clamp），`kit.path` / `kit.circle` 也没有任何裁剪（`f_chart/src/` 内 `grep clipPath/clip-path` 零命中）。例：`xAxis.min = 30` 而首点 `x = 20`，该点 x 像素落在 `plot.x` 左侧，画在 y 轴刻度文字上，折线穿出绘图区。
- **描述**：规格把「覆盖全部数据」写成无条件 MUST，用户按规格给 `min/max` 收紧视野时，越界点不会被裁掉而是溢到坐标轴外，SVG 观感错乱；同时「覆盖全部数据」这条验收项在显式范围下永远无法满足，属于不可实现的承诺。
- **建议**：规格改成「未给 `min`/`max` 时轴范围覆盖全部数据并留 3% / 8% 余量；给出时以显式值为准，域外数据点裁剪到绘图区（或按 `clamp` 落在边界上）」。实现侧若选裁剪，可在 `SvgBuilder` 分组上补 `clip-path`（需 `f_svg` 支持），否则在 `scale` 后钳制到 `[plot.y, plot.bottom()]`。

### [轻微][存量] #6 帕累托的「总和必须大于 0」守卫是死代码，且与 `paretoCumulative` 内的同条件校验重复

- **位置**：`f_chart/src/ParetoChart.cj:91-93`（`if (maxValue <= 0.0) { throw … }`）；`maxValue` 在 `87-90` 求出，上一行 `84` 已调用 `paretoCumulative`
- **来源**：存量
- **判据**：review-checklist §1「恒假分支 / 不可达语句」+ §2「重复逻辑（同一错误文案）」
- **证据**：静态确定 —— 值在 `60-62` 已校验 `value < 0.0` 即抛错，故 `sortedValues` 全部 ≥ 0，于是 `Σ = 0 ⟺ max = 0`；`paretoCumulative` 在 `225-227` 对 `total <= 0.0` 抛出与 `92` 完全相同的 `chartInvalidValue("series[0].data", "总和必须大于 0")`，且它在 `84` 行就已执行 ⇒ `91` 的条件永不为真。
- **描述**：重复守卫让读者以为「`paretoCumulative` 可能不校验」，也掩盖了「全零输入在哪一行失败」；后续若把累计函数改成允许全零（返回全 0），`91-93` 会突然变成唯一守卫，语义随改动漂移。
- **建议**：删掉 `91-93` 的 `if` 分支（保留 `87-90` 求 `maxValue`，`:94` 的 `resolveYRange` 还要用），让「总和必须大于 0」只在 `paretoCumulative` 内维护；或反过来让 `paretoCumulative` 只算数、由 `draw` 统一校验一次。

### [轻微][存量] #7 帕累托右轴刻度手写，未复用 `ChartFrame.drawYAxisRight`，导致右轴无刻度线、`labelFormat` 不生效

- **位置**：`f_chart/src/ParetoChart.cj:171-179`；可复用实现 `f_chart/src/ChartFrame.cj:245-276`
- **来源**：存量
- **判据**：review-checklist §2「重复逻辑（框架已有同一能力，调用点又写一遍）」
- **证据**：静态确定 —— `ChartFrame` 已提供 `drawYAxisRight(kit, ticks, scale, axis)`：画刻度短线（`249-252`）、刻度文本（`253-259`）、右轴线（`262-265`）、轴标题（`266-275`），文本走 `chartFormatTick(tick, axis.labelFormat)`；帕累托在 `171-179` 内联 `for (tick in [0.0, 20.0, … 100.0])` 只画 `percent-label` 文本，没有刻度线与右轴线，也不读 `labelFormat`。`rightLabelWidth: 42.0`（`119`）是为这段内联代码留的，与 `drawYAxisRight` 的 `plot.right() + 8` 布局不同。
- **描述**：两条右轴代码并存 ⇒ 视觉不一致（帕累托右轴「悬空」）、次级刻度不可配置（`tickCount` / `labelFormat` 对右轴无效）；后续改右轴样式要改两处。
- **建议**：用 `frame.drawYAxisRight(kit, chartNiceTicks(0.0, 100.0, config.yAxis.tickCount), percentScale, config.yAxis)` 替换 `171-179`，并把 `rightLabelWidth` 统一成 `maxPercentLabelWidth + 12`。

### [轻微][存量] #8 轴范围校验与手写排序在多处重复：51 处同文案校验、10+ 处同形插入排序、平行坐标 x 坐标表达式两处

- **位置**：轴校验 —— `f_chart/src/PairedLineChart.cj:103-105`、`f_chart/src/ParetoChart.cj:194-196`、`f_chart/src/PdpChart.cj:98-103`、`f_chart/src/BarRenderer.cj:388-390` 与 `417-421`（模块内 `grep "必须小于"` 共 52 行，其中 51 行是 `xAxis/yAxis.min 必须小于 …max`，另 1 行是 `GaugeChart` 的 `startAngle/endAngle`）；排序 —— `f_chart/src/ParetoChart.cj:207-215` 与 `f_chart/src/LiftChart.cj:203-217`（模块内 `var j = i` 同形插入排序 10+ 处）；x 坐标 —— `f_chart/src/ParallelCoordinatesChart.cj:204-208` 与 `245-249`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制 / 换控制流」
- **证据**：静态确定 —— 轴校验是完全相同的「`if (maximum <= minimum) throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")`」，只是参数名在 `xAxis` / `yAxis` 间切换；`paretoOrder` 与 `sortLiftPoints` 是同一段插入排序，仅比较字段（`values[order[j]]` vs `sorted[j][0]`）和方向（`>` vs `<`）不同；平行坐标里 `let x = if (dimensionCount == 1) {(left+right)/2.0} else {left + Float64(index) * step}` 在轴循环与折线循环各写一遍。
- **描述**：51 份同文案校验意味着轴错误语义有 51 个独立演化点（改文案或改判定要改 51 处，漏改就出现同类输入不同报错）；插入排序是 O(n²) 且各自维护，`paretoOrder` 的稳定性/降序语义与 `sortLiftPoints` 的升序语义靠人记；平行坐标重复表达式一旦有一处改了（例如改成按 `plot` 矩形算），另一处就会错位。
- **建议**：把范围解析收进 `ChartAxis`（`resolve(min, max, padRatio)` 返回 `[min, max]` 并统一抛错）；排序抽一个 `stableSortIndices` 工具或改用标准库排序（`std.sort` 的可用签名以本地文档为准）；平行坐标先把 `xs: Array<Float64>` 预计算一次，轴与折线共用。

### [轻微][存量] #9 配对连线的图例只有一种颜色，图元却按受试者逐项换色

- **位置**：`f_chart/src/PairedLineChart.cj:143-149`（`legendColors = [config.theme.colorAt(0)]`）对照 `156-164`（`colorAt(index)`）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 语义一致性」
- **证据**：静态确定 —— 图例只注册 `[seriesName]` 与 `[colorAt(0)]`（`143-149`），连线/圆点/标签逐项用 `config.theme.colorAt(index)`（`156`、`163-164`），`colorAt` 按调色板取模（`ChartTheme.cj:54-59`），因此 4 个受试者会有 4 种颜色，图例标记恒为调色板第一色。
- **描述**：图例颜色与任何一条线都对不上，读者会以为「图例色 = 某条特定曲线」，实践中经常被当成 bug 反馈；而这项颜色语义在规格里没有约束，属于实现自定的表现。
- **建议**：二选一 —— 图例按受试者逐项列出（姓名 + `colorAt(i)`），或所有连线统一 `colorAt(0)`、让图例真正代表系列色。

### [轻微][存量] #10 平行坐标：最大值刻度画在维度名之上（间距 16px），最右维度名与刻度超出画布被裁

- **位置**：`f_chart/src/ParallelCoordinatesChart.cj:213-233`（维度名 `y = top - 10`，最大值 `y = top - 26`）；右边距 `195`（`right = width - padding.right - 20.0`）
- **来源**：存量
- **判据**：review-checklist §10「可读性」+ §11「边界」（坐标与边界）
- **证据**：静态确定 —— 同一个 `x`、`anchor: "middle"` 下，`dimension-label` 基线在 `top - 10`（`213-219`），最大值 `dimension-tick` 基线在 `top - 26`（`227-233`），默认 `fontSize = 12`（`ChartTheme.cj:28`）时两者只隔 16px，且 `ChartSvgKit.text` 统一用 `dominant-baseline: middle`（`ChartSvgKit.cj:111`），即两行中心相距 16px，`theme.fontSize` 超过 16 就重叠，且「最大值」排在维度名上方，读起来像维度名属于下一条轴。最右轴 `x = width - padding.right - 20`，名称与刻度居中后向右伸出 `textWidth/2`，4 个汉字（48px）就超出 20px 右边距，被 `viewBox` 裁掉。
- **描述**：轴头信息层级倒置 + 右端文本溢出，是纯坐标常量问题（左侧留 60、右侧只留 20），在默认 4 维度示例下不显现，换成 `["温度","湿度","气压","风速","降水量"]` 这类长名称或多维度时就会裁字。
- **建议**：维度名放 `top - 26`、最大值放 `top - 8`（或把最大值放进绘图区顶部）；`right` 改为 `width - padding.right - max(20, 最右维度名宽 / 2)`，`left` 同理按最左名称宽度预留。

### [轻微][存量] #11 四个实现文件里的 `import std.math.*` 未被使用

- **位置**：`f_chart/src/PairedLineChart.cj:19`、`f_chart/src/ParetoChart.cj:19`、`f_chart/src/PdpChart.cj:19`、`f_chart/src/ParallelCoordinatesChart.cj:19`
- **来源**：存量
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 四个文件内 `abs(` / `floor(` / `ceil(` / `pow(` / `log10(` / `sqrt(` / `isNaN` / `isInf` 全部零命中；用到的 `minFloat` / `maxFloat` 是本包自建函数（`f_chart/src/BarRenderer.cj:454-468`），`formatSvgNumber` 来自 `fountain::f_svg`（各自文件 `:21` 单独 import）。
- **描述**：多余的 wildcard import 让「这文件用了哪些数学能力」失去信号，也让模块级依赖图看起来比实际宽；不影响运行。
- **建议**：删除这 4 行（若后续用到再按需 `import std.math.{abs, ...}`）。

### [轻微][存量] #12 `percent-bar` 任务清单声称测试覆盖「归一化」，实际测试没有任何归一化 / 固定 100 轴断言

- **位置**：`doc/spec/add-f-chart-percent-bar/tasks.md:3`（「写 `PercentBarChart_test.cj`（柱数、图例、归一化、校验）」）对照 `f_chart/src/PercentBarChart_test.cj:53-114`
- **来源**：存量
- **判据**：review-checklist §14「承诺了但没实现 / 半成品」（任务清单已勾选，承诺的覆盖不存在）
- **证据**：静态确定 —— 测试只有 5 个用例：`class="bar"` 计数 12（`54-57`）、三条图例文本（`59-66`）、类目标签（`69-74`）、type 不匹配（`77-94`）、系列长度不一致（`97-114`）。没有任何用例断言「同类目三段高度和等于绘图区高」「y 轴上限是 100」或「负数按 abs 归一化」，而这两点正是 `percent-stacked-bar` / `percent-bar` 与普通堆叠柱的唯一差别（`BarRenderer.cj:163-200`）。
- **描述**：任务清单已勾选，`percent-bar` 的核心语义（归一化到 100%）实际处于无测试状态；`resolvePercentRange`（`private`，`BarRenderer.cj:379`）与 `percentStackedValue`（`internal`，`BarRenderer.cj:441-447`）本可直接单测，也没有覆盖。若归一化公式被改错（例如漏 `abs`、除以未取模的和），现有测试照样全绿。
- **建议**：补两条用例 —— (a) 直接断言 `percentStackedValue(3.0, 12.0) == 25.0` 与 `(-3.0, 12.0) == 25.0`；(b) 对 4×3 示例断言四个类目各自的段高之和等于 `plot` 高（可用 rect 的 `height` 求和或对比 y 轴上限 100）。

### [轻微][存量] #13 平行坐标 design 说「相等就扩边」，spec 说「显式 min == max 抛错」，实现按 spec

- **位置**：`doc/spec/add-f-chart-parallel/design.md:5-6`（「若仍相等，min -= 0.5、max += 0.5」）对照 `doc/spec/add-f-chart-parallel/specs/chart-rendering/spec.md:41-44`（「某维度 `min` 等于 `max` → `InvalidValue`」）与 `f_chart/src/ParallelCoordinatesChart.cj:152-158`
- **来源**：存量
- **判据**：review-checklist §13「规格自洽性」
- **证据**：待确认 —— 实现与 spec、测试（`ParallelCoordinatesChart_test.cj:110-124` 断言双显式 `min=5,max=5` 抛 `InvalidValue`）一致；design 的「仍相等」在字面上既可能指「推导后相等」，也可能指「任何情况相等」，缺一句限定，读者按 design 会预期自动扩边。
- **描述**：同一变更包内三份文档（design / spec / test）对同一输入给出两种预期，属于「归档规格自洽性」问题；不影响当前实现正确性。
- **建议**：design 补一句「仅当范围由数据推导且推导后相等时扩 ±0.5；两侧都显式且相等则抛 `InvalidValue`（见 spec 场景）」，与 spec / 测试对齐。

### [轻微][存量] #14 `percent-bar` 提案写成「100% 横条」，设计与规格及实现都是纵向堆叠

- **位置**：`doc/spec/add-f-chart-percent-bar/proposal.md:5`；对照 `doc/spec/add-f-chart-percent-bar/design.md:5-9`、`doc/spec/add-f-chart-percent-bar/specs/chart-rendering/spec.md:7`、`f_chart/src/PercentBarChart.cj:21`
- **来源**：存量（快照模式无基线；`git log -1` 为 `ea449b929 feat(f_chart): M75 百分比条`）
- **判据**：review-checklist §13「文档自相矛盾 / 承诺与实现相反」
- **证据**：静态确定 —— 提案 Why 段写「把每个类目的构成压缩为一根 100% 横条……需要横向比较构成的场景」；同一变更的设计写「直接调用 `BarRenderer.render(data, "percent-bar", BarMode.PercentStacked)`」并称「其余行为完全一致」，规格写「每个类目归一化到 100%，**纵向**堆叠各系列」，实现注释写「每个类目一根 100% 柱」（纵向），四处对方向的描述提案独占一种
- **描述**：提案是后续维护者理解该图的第一入口。若有人按「横条」去补一个水平 100% 堆叠实现，会与 `BarMode.PercentStacked` 的布局（`BarRenderer.cj:163-200`，`stackedBarX` 为纵向柱的 x 定位）冲突；按提案写文档或测试同样会得到相反预期
- **建议**：`proposal.md:5` 改为「每个类目一根归一化到 100% 的竖柱」，Why 段场景改为「比较各类目的构成比例」；确需横向版本时另开变更，并在 design 里写清与 `PercentStacked` 的差异

### [轻微][存量] #15 帕累托规格要求「标签长度 MUST 与数据一致」，实现允许省略标签并回退序号

- **位置**：`doc/spec/add-f-chart-pareto/specs/chart-rendering/spec.md:39`；对照 `f_chart/src/ParetoChart.cj:66-83`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 规格写「标签长度 MUST 与数据一致」，无「可省略」例外；实现 `:67` 的条件是 `if (!labels.isEmpty() && labels.size != values.size)`，`xAxis.labels` 缺省（长度 0）时不校验，并在 `:78-82` 回退为 `1..n` 序号标签
- **描述**：按规格写一致性用例「4 个数据 + 0 个标签 → `InvalidValue`」会失败，实现正常出图。实现更宽松、对使用者无害，但验收口径对不上，后续按规格补测试会误判为回归
- **建议**：`spec.md:39` 改为「`xAxis.labels` 给出时长度 MUST 与 `data` 一致，缺省时以序号 1..n 作为类别标签」，与 `:78-82` 的回退逻辑对齐

<!-- 第 17 部分 -->

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

<!-- 第 18 部分 -->

### [轻微][存量] 雷达图 `design.md` 的几何与校验口径与实现不一致（半径、标签偏移、空 `indicators` 的错误类型）

- **位置**：`f_chart/doc/spec/add-f-chart-radar/design.md:5`（半径 `min(plot.width, plot.height)/2 - 30`）、`:8`（标签「1.0 半径外 14px」）、`:18`（`indicators` 非空否则 `InvalidValue`）；`f_chart/src/RadarChart.cj:88`（`- 36.0`）、`RadarChart.cj:107-126`（标签落在圆周顶点上，仅 `dx ±8` / `dy ∓6`）、`RadarChart.cj:52-55`（空数组抛 `chartMissingField`）
- **来源**：存量（快照模式无基线；`git log` 显示 `design.md` 与 `RadarChart.cj` 由同一提交 `24366dad0` 引入，说明写文档时即未与实现对齐，不是后续实现漂移）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」——文档给出的可复算数值（30px、14px）与代码常量（36.0、8/6）不同，属两边位置都能点名的确定性不符
- **证据**：静态确定 —— `RadarChart.cj:88` 字面量 `36.0`；`107-126` 行 `labelPoint` 与 `point` 同参数（半径 `1.0`），文字坐标只加 `offsetX=±8`、`labelOffsetY=±6`，没有任何沿半径向外的 14px 位移
- **描述**：按 `design.md` 复现会得到比实现大 6px 的绘图半径、并把标签放到圆环之外；实测半径差会让 1.0 圈与标签的间距与文档描述不同（标签实际压在轴端点上，最外圈与文字可能重叠）。第三处是错误契约：空 `indicators` 走 `requiredArray` 后的显式判空分支，抛 `MissingField`，而 design 写「否则 InvalidValue」，按文档写断言的调用方会失败。另有一处文档未覆盖的硬错误：`RadarChart.cj:89-91` 在 `radius <= 0` 时抛 `chartInvalidValue("width", "画布太小…")`，`design.md` / `spec.md` 均未记录画布下限，小画布（如 100×100）会拿到未预期的 `InvalidValue`
- **建议**：把 `design.md:5` 改为 36px、`:8` 改为「标签落在 1.0 半径顶点，水平 ±8px、垂直 ∓6px」、`:18` 区分「缺失/空数组 → `MissingField`，`max <= 0` / 长度不符 → `InvalidValue`」；在 `spec.md` 的「雷达指标轴」下补一条画布下限（`min(plot.width, plot.height) > 72`）的需求或场景

### [轻微][存量] 山脊图 `design.md` 的采样点数比实现少一个（80 vs 81）

- **位置**：`f_chart/doc/spec/add-f-chart-ridge/design.md:10`（「取 80 个采样点」）；`f_chart/src/RidgeChart.cj:154`（`for (step in 0..=80)`，闭区间 81 个点）
- **来源**：存量（同提交 `04d69cecc` 引入）
- **判据**：review-checklist §13「文档与实现不一致」——采样点数决定曲线顶点数与 `densities` 长度，是可复算的确定值
- **证据**：静态确定 —— `0..=80` 为含两端点的 81 次迭代；`points` / `densities` 各 81 项，路径输出 81 个 `L` 段
- **描述**：文档写 80 个点、实现 81 个点（80 段），按文档复算出的顶点间距（`span/79`）与实现（`span/80`）差一个步长；对视觉影响可忽略，但会让「按设计核对曲线采样密度」的后续维护者误判
- **建议**：文档改为「81 个采样点（80 段）」或实现改为 `0..<80`（后者会改变已有 SVG 输出，需同步快照类断言，故优先改文档）

### [轻微][存量] 雨云图输出的 `raincloud-cap` 类名未进入任何文档；`spec.md` 的图元清单还缺 `raincloud-outlier`

- **位置**：`f_chart/doc/spec/add-f-chart-raincloud/specs/chart-rendering/spec.md:7`（只列 box / median / whisker）、`f_chart/doc/spec/add-f-chart-raincloud/proposal.md:12`（列了 outlier，未列 cap）；`f_chart/src/RaincloudChart.cj:301-310`（两条 `raincloud-cap`）、`RaincloudChart.cj:311-314`（`raincloud-outlier`）
- **来源**：存量（同提交 `8f44451ab` 引入）
- **判据**：review-checklist §14.2「公开 API / 输出面未文档化」、§13「文档与实现不一致」——SVG class 是该模块对外的唯一定制面（外部靠它挂 CSS / 后处理），属于对外契约
- **证据**：静态确定 —— 全仓 `grep -rn "raincloud-cap" --include=*.md` 零命中；`.cj` 仅 `RaincloudChart.cj:304`、`:309` 两处输出
- **描述**：箱线须端的横向端帽（`raincloud-cap`）完全不可发现：使用者按 proposal 的类名清单写样式时箱须端帽永远保持默认描边；`spec.md` 的图元清单又比 proposal 少 `raincloud-outlier`，两份文档对同一输出的枚举不一致。注意这两处只是文档缺项，`showBox=false` 时实现确实不输出它们（与 spec 的开关需求一致）
- **建议**：`proposal.md:12` 补 `raincloud-cap`，`spec.md:7` 的 MUST 清单补 `raincloud-outlier` 与两条 `raincloud-cap`

### [轻微][存量] 残差图 `spec.md` / `design.md` 未记录「`series` 必须恰好 1 个」这一硬校验

- **位置**：`f_chart/doc/spec/add-f-chart-residual/specs/chart-rendering/spec.md:34`（校验清单只有 `x`/`y` 数字、`data` 非空、`series` 缺失、`type` 不符）、`f_chart/doc/spec/add-f-chart-residual/design.md:3-5`；`f_chart/src/ResidualChart.cj:45-47`（`seriesItems.size != 1` → `InvalidValue`）
- **来源**：存量（同提交 `0c5ff05eb` 引入）
- **判据**：review-checklist §13「文档与实现不一致」、§14.1「只做了一半的分支 / 文档未覆盖实现中的硬校验」——同一批文档里 `qq/specs/chart-rendering/spec.md:30` 明确写了「`series` MUST 恰好 1 个」，残差图却漏了，属同类需求的口径漂移
- **证据**：静态确定 —— `spec.md` 全文无「系列数 / 恰好 1 个 / 多系列」表述；`ResidualChart.cj:45-47` 明确抛错；`ResidualChart_test.cj` 10 个用例中没有多系列用例（该分支无测试覆盖）
- **描述**：使用者按 spec 的「校验」清单理解契约时，会认为多系列是合法输入（例如同一模型多个残差集）；实际直接抛 `InvalidValue`，只能从源码发现。测试也没覆盖该分支，后续若有人放宽限制不会有失败用例提醒
- **建议**：`spec.md` 的「残差校验」补「`series` MUST 恰好 1 个，否则 `InvalidValue`」，并补一个 `rejectsMultipleSeries` 用例（与 `QQChart_test.cj:146` 对齐）

### [轻微][存量] 山脊图 `spec.md` / `proposal.md` 未标明 `overlap`（及 `bandwidth`）的挂载层级，放在顶层会被静默忽略

- **位置**：`f_chart/doc/spec/add-f-chart-ridge/specs/chart-rendering/spec.md:16`（只写「`overlap` MUST 在 0 到 1 之间」）、`f_chart/doc/spec/add-f-chart-ridge/proposal.md:10`（「`overlap` 控制曲线重叠程度…`bandwidth` 可选」，未说属于 series）；`f_chart/src/RidgeChart.cj:85-96`（只在每个 `series[i]` 对象上读 `bandwidth` / `overlap`）
- **来源**：存量（同提交 `04d69cecc` 引入）
- **判据**：review-checklist §13「文档与实现不一致」——`grep -rn "overlap" f_chart/src/*.cj` 只有 `RidgeChart.cj:93`（series 对象）一处读取；`ChartConfig` 只按名读已知字段，没有未知键校验，因此顶层 `overlap` 既不生效也不报错
- **证据**：静态确定 —— `RidgeChart.cj:63-100` 的循环体对 `item`（series 元素）取 `json`，`json.number("overlap", default: 0.5)`；绘制侧用 `item.overlap`（`:150`）。顶层写入 `"overlap": 1.5` 时 `0-1` 校验不会被触发，全部系列静默使用 0.5
- **描述**：spec 的第二条需求（重叠系数）是该图唯一的专属参数需求，却没说它挂在 `series[i]` 上；按 proposal 的字面读法把 `overlap` 写在顶层是最自然的理解，结果是「配置无效且无告警」，同时「非法重叠抛 `InvalidValue`」的场景在这种写法下永不成立。`README.md:990-993` 的示例写法是对的，所以影响面限于只读 spec/proposal 的使用者与后续维护者
- **建议**：`spec.md:16` 与 `proposal.md:10` 明写「`series[i].overlap`（默认 0.5）」「`series[i].bandwidth`」；若要容忍顶层写法，则在 `RidgeChart.draw` 里做一次根级回退读取并保留同样的 0–1 校验

> 存量 5 条（均为轻微，文档口径类），是否纳入修复待用户决定。

<!-- 第 19 部分 -->

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

<!-- 第 20 部分 -->

> 与已产出部分的重叠：SHAP 的顶层 `features` 字段「文档写了、实现不接」已由 `f_chart.part2.md` #4（README 视角）与 `f_chart.part3.md` #13（`doc/chart-json-spec.md` 视角）报为【一般】。本部分的归档 `design.md:9` / `proposal.md:8,10` 是同一根因的第三、四处文档落点，**不重复统计**，合并时把这两处一并删除或接线即可。

### [一般][存量] `SpiralChart` 未校验 `maxRadius` 为正，小画布下半径取负导致整幅螺旋翻转 180°

- **位置**：`f_chart/src/SpiralChart.cj:110-113`（`maxRadius = min(w-pad, h-pad-40)/2 - 30`）；`f_chart/src/ChartConfig.cj:182`（只校验 `width > 0 && height > 0`）；`f_chart/src/ChartConfig.cj:22-25`（四边默认 padding 24）；对照 `f_chart/src/RadarChart.cj:88-91`（同类几何量有 `radius <= 0` 守卫）
- **来源**：存量（快照模式无基线；`git log -1 -- src/SpiralChart.cj` = `df565a19e feat(f_chart): M84 螺旋图`，几何常量自引入后未再改动）
- **判据**：review-checklist §11「边界差一 / 缺少边界校验」——配置层放行任意正数画布，几何层却假设半径为正；同模块 `RadarChart` 对同一类量做了显式守卫，属同类实现的判定漂移
- **证据**：静态确定 —— 取默认 padding，`height = 100` 时 `maxRadius = min(w-48, 12)/2 - 30 = -24`；`spiralPoint`（`SpiralChart.cj:164-177`）直接用 `radius * cos/sin`，负半径等价于把每个点旋转 180°（`cos(θ)·(-r) = cos(θ+180)·r`）。`width/height` 只要求 `> 0`，故该输入合法可达
- **描述**：默认 `startAngle = -90` 的语义是「首点从正上方起旋」，半径取负后首点落到正下方，整条路径与所有 `spiral-label` 一起被镜像，且外圈可能越出画布；不崩溃、不报错，只输出一张与文档描述方向相反的图。除 `height ≤ 148` 外，`width ≤ 108` 同样触发（等于边界时半径为 0，全部点叠在圆心）
- **建议**：在 `SpiralChart.draw` 计算完 `maxRadius` 后加与雷达图一致的守卫：`if (maxRadius <= 0.0) { throw chartInvalidValue("width", "画布太小，无法绘制螺旋图") }`；同时把画布下限写进 `add-f-chart-spiral/specs/chart-rendering/spec.md` 的「螺旋校验」，并补一条小画布用例

### [轻微][存量] 四个归档 `design.md` 的布局常量与实现已脱节（行高、文字偏移、留白宽度、半径与标签距离）

- **位置**：
  - `f_chart/doc/spec/add-f-chart-sequence/design.md:7`（「消息区…行高 40」）、`:12`（「文本在中点上方 6px」）↔ `f_chart/src/SequenceChart.cj:114-118`（`rowHeight = min(40, available/messages.size)`，自适应收缩）、`:142`（`y - 8.0`）
  - `f_chart/doc/spec/add-f-chart-shap/design.md:19`（「特征名最大文本宽度 + 12px」）↔ `f_chart/src/ShapChart.cj:110`（`maxFeatureWidth + 16.0`）
  - `f_chart/doc/spec/add-f-chart-slope/design.md:11`（「右侧预留 64px 用于系列名称」）↔ `f_chart/src/SlopeChart.cj:133-136`（`rightLabelWidth: maxLabelWidth + 16.0`，随名称长度变化）
  - `f_chart/doc/spec/add-f-chart-spiral/design.md:14`（「`maxRadius` 为短边的一半减 40px」）、`:20`（「周期标签放在点外侧 10px」）↔ `f_chart/src/SpiralChart.cj:110-113`（`min(w-pad, h-pad-40)/2 - 30`）、`:147-148`（沿半径外推 12px）
- **来源**：存量（快照模式无基线；`git log -1` 显示四处 `design.md` 与其实现文件各自落在同一提交——`a1dc954e9`(sequence)、`1b1f1fe43`(shap)、`f60ff4be4`(slope)、`df565a19e`(spiral)——说明写文档时即未与实现对齐，不是后续实现漂移）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」——四处都是可复算的字面常量，文档与代码两边位置都能点名，不是措辞差异
- **证据**：静态确定 —— 逐个比对上述行号的字面量：40 vs `min(40, …)`、6 vs `8.0`、12 vs `16.0`、64 vs `maxLabelWidth + 16.0`、40/10 vs `- 30`/`12`
- **描述**：按 `design.md` 复算会得到与实现不同的坐标与留白，维护者据此核对布局（或据此写快照断言）必然对不上；`sequence` 的行高还与校验口径冲突——文档写固定 40，实现为「消息放不下时压缩行高」，后者才是不溢出画布的行为。视觉后果都不大，但四处同源，说明归档后没有回写设计
- **建议**：按实现回写这五处常量（`sequence` 另外补一句「消息数超出可用高度时行高等比压缩，下限为 0」）；若认为 `design.md` 应保留「设计意图」，则在其顶部标注「常量以实现为准」并给出实现文件行号

### [轻微][存量] 堆叠面积图 `design.md` 引用了不存在的 `ChartFrame.drawGrid`，实现也未绘制网格

- **位置**：`f_chart/doc/spec/add-f-chart-stacked-area/design.md:20`（「y 轴复用 `drawYAxis` / `drawGrid`」）；`f_chart/src/ChartFrame.cj` 的方法清单只有 `drawBackground:94` / `drawTitle:98` / `drawLegend:134` / `drawYAxis:168` / `drawXAxis:204` / `drawYAxisRight:245` / `drawXAxisNumeric:278`；`f_chart/src/StackedAreaChart.cj:152`（只调 `drawYAxis`）
- **来源**：存量（快照模式无基线；`design.md` 与 `StackedAreaChart.cj` 同属 `faf081dc7 feat(f_chart): M15 堆叠面积图`）
- **判据**：review-checklist §13「示例 / 文档引用不存在的 API」——`drawGrid` 在全仓零命中，属悬空 API 名
- **证据**：静态确定 —— `grep -rn "drawGrid" f_chart/src f_chart/doc` 无命中；`ChartFrame.cj` 的 `func draw` 定义只有上述七个
- **描述**：按设计文档去找 `drawGrid` 会直接扑空；同时堆叠面积图确实没有水平网格线，读者无法判断是「文档写错」还是「网格线漏画」。对照 `AreaChart`、`LineChart` 同样只调 `drawYAxis`，可见这是模块统一的「无网格」风格，而非本图缺失
- **建议**：`design.md:20` 改为「y 轴复用 `drawYAxis`（本模块不绘制网格线）」；若确实需要网格，则先在 `ChartFrame` 新增 `drawGrid` 并在多图统一接入，不要只改这一张图

### [轻微][存量] 同文件内两份同语义实现：堆叠面积图的累计被算两遍，散点图的轴范围函数逐行同构

- **位置**：
  - `f_chart/src/StackedAreaChart.cj:157-187`（`draw` 里用 `groupIndexesOf` + `uniqueGroupCount` + 每类目 `cums` 重算 lower/upper 层）↔ `:310-328`、`:331-339`、`:347-377`（`stackedAreaBounds` 内部把同一套累计再算一遍）
  - `f_chart/src/ScatterChart.cj:205-226`（`resolveXRange`）↔ `:228-249`（`resolveYRange`）：两个函数体逐行对齐，只有取值字段（`point.x` / `point.y`）与错误路径（`"xAxis.min"` / `"yAxis.min"`）不同
- **来源**：存量（快照模式无基线；`StackedAreaChart.cj` 属 `faf081dc7`、`ScatterChart.cj` 属 `81b0dc647 feat(f_chart): M6 散点图`，均无后续修改）
- **判据**：review-checklist §2「重复逻辑 / 只改字段名的复制」——两处都是「输入-输出-副作用」完全一致的实现，第二处仅换了字段名
- **证据**：静态确定 —— `stackedAreaBounds` 的循环体（`354-376`）与 `draw` 的循环体（`171-187`）逐句对应：同样的 `cums` 归零、同样的 `groupIndexes` 下标、同样的 `lower/upper` 递推；`resolveXRange` / `resolveYRange` 的差异只有 `point.x`↔`point.y` 与最后一个入参字符串
- **描述**：累计规则（重置时机、组下标、含 0 的范围）现在写了两份，任何一处修正（例如「负值组单独向下累计」）都必须同步改另一处，否则轴范围与面积路径会不一致——这正是「重复逻辑导致的行为漂移」的典型入口。散点图那份的漂移风险更低（当前行为一致），但同样让 `lineRange` 的调用被摊平成两份
- **建议**：`StackedAreaChart` 抽 `stackedAreaLayers(groups, values, count): (bounds, lower, upper)`，`draw` 只调用一次，`stackedAreaBounds` 作为它的薄包装保留给测试；`ScatterChart` 抽 `resolveLineRange(rangeAxis, series, pick: (ScatterPoint) -> Float64, path: String)` 或直接把 x/y 合成 `resolveRanges` 一次返回两个数组

### [轻微][存量] 螺旋图 `spec.md` 的坐标公式在 `count == 1` 时除零，与同一文件的校验条款冲突

- **位置**：`f_chart/doc/spec/add-f-chart-spiral/specs/chart-rendering/spec.md:16`（角度 `startAngle + direction * turns * 360 * i / (count - 1)`）；同文件 `:39`（只要求 `data` 非空，故 `count == 1` 合法）；实现 `f_chart/src/SpiralChart.cj:173`（`divisor = count > 1 ? count-1 : 1`）
- **来源**：存量（快照模式无基线；`spec.md` 与 `SpiralChart.cj` 同属 `df565a19e`）
- **判据**：review-checklist §13「规格与实现漂移 / 规格自洽性」——同一份 spec 允许的输入落在自己给出的公式定义域之外（分母为 0）
- **证据**：静态确定 —— `:39` 的 MUST 只约束「恰好 1 个系列、`data` 非空」，`count = 1` 满足；`:16` 的分母此时为 0，公式无定义。实现侧已用 `divisor` 兜底，单个数据点返回 `[maxRadius*cos(startAngle), maxRadius*sin(startAngle)]`
- **描述**：`spec.md` 是合并后要长期留存的行为契约，读者照公式实现（或照公式断言单点场景）会得到 `NaN`，与实现的单点行为不一致；这也是本部分唯一一处「规格自身不自洽」而非「规格落后于实现」
- **建议**：`:16` 的分母改为 `max(count - 1, 1)`（与 `design.md:11` 的写法一致），并补一条「`data` 只有 1 项时返回半径 `maxRadius`、角度 `startAngle`」的场景

### [轻微][存量] 散点图的 `symbol: "none"` 能力既未进 spec 也未进 README，且无测试覆盖

- **位置**：`f_chart/src/ScatterChart.cj:162-167`（`case "none" => ()`，显式 no-op 分支）；`f_chart/doc/spec/add-f-chart-scatter/specs/chart-rendering/spec.md:30`（只声明 `circle/square/diamond`）；`f_chart/README.md:1149`（绘制方式未提形状取值）与 `:1153-1168`（示例只有 `symbolSize`）；`f_chart/src/ScatterChart_test.cj:52`（只断言 `class="symbol"` 计数，无形状用例）
- **来源**：存量（快照模式无基线；`ScatterChart.cj` 属 `81b0dc647`）
- **判据**：review-checklist §14.2「公开 API / 输出面未文档化」——series 级 `symbol` 是 JSON 契约的一部分，`none` 是分支里唯一没有文档与用例的取值
- **证据**：静态确定 —— `grep -rn '"symbol"' f_chart/README.md` 仅 `:677-678`（折线图示例，`circle`/`square`），无 `none`；`grep -n "symbol" ScatterChart_test.cj` 仅 `:52` 一处计数断言
- **描述**：`none` 会让该系列一个点都不画（连 `class="symbol"` 都没有），使用者按 spec 的取值枚举不可能知道这个能力；反过来，若 `none` 只是「未知值落到默认圆点」的旧写法残留，则它是死分支。两种可能都需要作者确认，但目前没有任何文档或测试表达意图
- **建议**：确认语义后在 `spec.md:30`、「散点图多系列样式」下补 `none`（「不绘制符号，仅保留图例/标签」）并加一个形状用例；若确认无用途，删除该分支，让未知 `symbol` 落到默认圆点（与 `case _` 一致）

> 存量 6 条（一般 1、轻微 5），是否纳入修复待用户决定；`features` 一条同源问题见本节开头说明，已计在 `part2.md` #4 / `part3.md` #13。

<!-- 第 21 部分 -->

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

<!-- 第 22 部分 -->

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

<!-- 第 23 部分 -->

### [一般][存量] 小提琴 / 小提琴箱线的 `bandwidth`、`showBox`、`showOutliers` 未标注位于 `series[0]`，按文档写在根级会被静默忽略

- **位置**：`f_chart/doc/spec/add-f-chart-violin/proposal.md:12`（「`bandwidth` 可选，缺省用 Silverman 规则」）、`f_chart/doc/spec/add-f-chart-violin/specs/chart-rendering/spec.md:39`（「`bandwidth` MUST 大于 0」）、`f_chart/doc/spec/add-f-chart-violin-box/proposal.md:11`（「`bandwidth` 控制核密度带宽；`showBox` 默认 true；`showOutliers` 默认 true」）、`f_chart/doc/spec/add-f-chart-violin-box/specs/chart-rendering/spec.md:35`（`bandwidth` 取值域）；实现 `f_chart/src/ViolinChart.cj:101-110`、`f_chart/src/ViolinBoxChart.cj:101-110`（三字段均从 `seriesJson` 读取，错误路径写作 `series[0].bandwidth`）
- **来源**：存量（`git log -1` → `750e7acb3`「feat(f_chart): M20 小提琴图」、`34f6f9119`「feat(f_chart): M46 小提琴箱线图」，文档与实现同批提交，非后续漂移）
- **判据**：review-checklist §13（配置项位置与源码不符）+ §11「错误处理缺失：配置被读却从未生效」
- **证据**：静态确定 —— 两份 proposal 在列举 `series[0].data` 之后直接用无路径字段名列出 `bandwidth` / `showBox` / `showOutliers`，规格的需求文本同样只有裸字段名；实现只查 `series[0]`。JSON 解析对未知键不报错（`ChartJson` 只按名取值），因此写 `{"type":"violin","bandwidth":0.2,...}` 时根级键被丢弃，`seriesJson.number` 返回 `None` 走 `defaultBandwidth`
- **描述**：使用者按文档在图表根级设置 `bandwidth: 0.05` 或 `showBox: false`，既不报错也不生效，输出仍是 Silverman 带宽 + 叠加箱体，属于「配置静默失效」；排查时没有任何日志或异常指向该字段
- **建议**：三处文档统一改为 `series[0].bandwidth` / `series[0].showBox` / `series[0].showOutliers`，并在 spec 的校验需求里补一句「未知层级上的这三个字段 MUST 被忽略（或 MUST 抛 `InvalidValue`，二选一写明）」，避免继续出现「写了不生效」

### [一般][存量] 树图 `value` 语义与 spec 不符：叶子缺 `value` 静默按 0 处理，内部节点自带 `value` 被静默覆盖

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/specs/chart-rendering/spec.md:16`（「内部节点值 MUST 等于子节点值之和」）、`:34`（「叶子 `value` MUST 大于 0」）；实现 `f_chart/src/TreemapChart.cj:88-99`（`value` 缺失 → `None`，只有提供了值才校验 `> 0`）、`:159-171`（`nodeValue`：叶子 `None` → `0.0`；内部节点忽略自身 `value`，直接累加子节点）
- **来源**：存量（`git log -1` → `98ea2dd7c`「feat(f_chart): M34 矩形树图」）
- **判据**：review-checklist §14.1（承诺了校验但没实现）+ §11「空值未处理、静默失败」
- **证据**：静态确定 —— spec 把「叶子 `value` MUST 大于 0」写在「树图校验」需求里，且场景只覆盖了「悬空 parent」「非法 tiling」；`TreemapChart_test.cj` 的 8 条用例里没有「叶子缺 value」这一条（`grep -n "value" src/TreemapChart_test.cj` 只命中 `:47-50` 的正常值、`:104` 的负值、`:85/:124/:156` 的其它场景）。实现侧 `:88` 的 `case None => None<Float64>` 之后没有任何兜底校验，`:163` 直接返回 `0.0`
- **描述**：`{"id":"a","name":"a","parent":"root"}`（漏写 `value`）不会抛 `InvalidValue`，该叶子得到 0 权重、0 面积矩形，与「叶子值必须大于 0」的契约相反；同一条规则对内部节点也不成立——内部节点写了 `value: 500`、子节点和为 100 时，输入值被静默丢弃，输出按 100 计算，规格里「内部节点值 MUST 等于子节点值之和」读起来像是校验，实际是「忽略并重算」，两种理解对用户可见结果不同
- **建议**：`parse` 之后加一次「叶子必须有值」的校验（`node.children.isEmpty() && node.value.isNone()` → `chartInvalidValue("${itemPath}.value", "叶子节点必须提供 value")`），spec `:16` 改写为「内部节点的 `value` MUST 被忽略，绘制值取子节点之和」，并补两个用例（叶子缺 value、内部节点 value 与子节点和不一致）

### [轻微][存量] 树图标签的显示条件（`width > 40 && height > 18`）未进 spec，`treemap-label` 的 MUST 与实现不一致

- **位置**：`f_chart/doc/spec/add-f-chart-treemap/specs/chart-rendering/spec.md:25-30`（「每个叶子 MUST 输出 `class="treemap-label"` 名称文本」、场景「4 个叶子 → 4 个 `treemap-label`」）；实现 `f_chart/src/TreemapChart.cj:208-218`（仅当 `width > 40.0 && height > 18.0` 才写标签）
- **来源**：存量（`98ea2dd7c`，spec 与实现同批）
- **判据**：review-checklist §13（spec 验收口径与实现不一致）
- **证据**：静态确定 —— 像素阈值硬编码在实现里，spec 与 design 均无该条件；默认 800×480 下 4 个叶子每格约 200×100，场景能过，所以测试没有暴露差异
- **描述**：叶子多到每格 ≤ 40×18 时实现不输出任何 `treemap-label`，按 spec 字面可判成缺陷；反过来，验收方也无法从规格知道「小格不出标签」是有意设计（同类文档 `add-f-chart-tui-flame/design.md:32` 就把「窄块跳过标签」写清楚了）
- **建议**：spec 的标签需求补一句「矩形宽 > 40 且高 > 18 时 MUST 输出 `treemap-label`，否则 MUST NOT 输出」，并加一个「大量小叶子 → 0 个标签」的场景

### [轻微][存量] TUI 横轴「类目标签抽稀」在 spec 中是 MUST、在 design 中是不可执行的公式、在 tasks 中已勾选完成，但代码里没有任何抽稀

- **位置**：`f_chart/doc/spec/add-f-chart-tui/specs/chart-tui/spec.md:60`（「类目标签过多时 MUST 通过抽稀避免重叠」）、`f_chart/doc/spec/add-f-chart-tui/design.md:36`（「按 `ceil(n / 可用列数 × 2)` 抽稀」）、`f_chart/doc/spec/add-f-chart-tui/tasks.md:7`（1.5「覆盖……横轴标签与抽稀」已 `[x]`）；实现 `f_chart/src/tui/TuiFrame.cj:183-201`（逐类目画 `┬` 与标签，仅按 `bandWidth >= 2` 整片跳过、`maxWidth: bandWidth` 截断）
- **来源**：存量（`git log -1` → `f4e27a68c`「feat(f_chart): 新增 M1-M7 TUI 子包」）
- **判据**：review-checklist §14.1（承诺了但没实现）+ §13（提交记录与产物不符）
- **证据**：静态确定 —— `grep -rn "抽稀\|stride\|thinning\|labelStep\|everyN" src/tui/` 零命中；`TuiFrame_test.cj` 同样没有抽稀相关断言。design 的公式 `ceil(n / 可用列数 × 2)` 量纲也不成立：它是「每 N 个取 1」的步长还是「保留比例」无法从上下文判定（`n=100`、60 列时得 4，按步长会只剩 25 个标签，按比例则语义相反）
- **描述**：类目过密时实际行为是「带宽 <2 全部不画标签」，既不重叠也无法读到任何类目名，与 spec 的「抽稀后仍保留部分标签」不同；tasks 1.5 声称覆盖抽稀，让后来者以为该能力已交付
- **建议**：二选一并写进 spec：①实现步长抽稀（`step = ceil(n / 可用列数)`，每 `step` 个类目画一个标签），design 的公式改为 `step = ceil(n / 可用列数)`；②承认现状，把 spec `:60` 改成「类目带宽 < 2 列时 MUST 不输出类目标签」，并修正 tasks 1.5 的表述

### [轻微][存量] TUI 火焰图 design「每层至少 1 行」与 spec「层数超出可用行数抛 `InvalidValue`」是两条互斥规则

- **位置**：`f_chart/doc/spec/add-f-chart-tui-flame/design.md:21`（`rowsPerDepth = min(frameHeight, floor(plot.height / (maxDepth + 1)))`，「至少 1」）、`f_chart/doc/spec/add-f-chart-tui-flame/specs/chart-tui-flame/spec.md:71-74`（「层数超出绘图区可用行数 → 抛 `ChartException`，`kind` 为 `InvalidValue`」）；实现 `f_chart/src/tui/TuiFlameChart.cj:75-80`（`fitRows < 1` 直接抛）
- **来源**：存量（`git log -1` → `0494ee810`「feat(f_chart): 新增 TUI 真彩火焰图」）
- **判据**：review-checklist §13（同一变更的 design 与 spec 对同一错误路径口径相反）
- **证据**：静态确定 —— 按 design 的「至少 1」，`plot.height < maxDepth + 1` 时每层压到 1 行继续画（`drawBox` 的 `top` 会落到绘图区之外并被 `bottom = min(..., plot.bottom())` 截断）；按 spec 则必须抛错。两处没有一句话说明优先级，实现选择了抛错
- **描述**：维护者按 design 复算会认为 24 行终端 + 30 层节点仍应输出（部分层被裁掉），按 spec 则应拿到异常；这类分歧会直接影响用户对「输入合法/非法」的判断，也会让测试断言二义
- **建议**：design `:21` 改为「`fitRows = floor(plot.height / (maxDepth + 1))`；`fitRows < 1` 时抛 `InvalidValue`（见 spec 场景「层数超出可用行数」）」，删掉「至少 1」

### [轻微][存量] 小提琴的 KDE 采样点数在 `violin` design 写 40、在 `violin-box` design 写 41，实现是 41

- **位置**：`f_chart/doc/spec/add-f-chart-violin/design.md:12`（「在 y 轴绘图范围内取 40 个采样点」）、`f_chart/doc/spec/add-f-chart-violin-box/design.md:12`（「取 41 个采样点」）；实现 `f_chart/src/ViolinChart.cj:176-177`（`for (step in 0..=40)` + `/ 40.0`，即 41 个点）、`f_chart/src/ViolinBoxChart.cj:177-178`
- **来源**：存量（`750e7acb3` / `34f6f9119`，两份 design 由同一模板复制）
- **判据**：review-checklist §2「近似重复：同一模板复制后数值漂移」
- **证据**：静态确定 —— `0..=40` 含两端共 41 个采样，`violin` design 的「40 个」少算一个端点；两份文档描述的是同一套 `gaussianKde` 轮廓算法（`violin-box/design.md:5` 明写「复用」），却给出不同点数
- **描述**：按 40 点复算轮廓会得到与实现不同的密度折线（采样步长 `(max-min)/39` vs `/40`），在极值处尤其明显；文档之间自相矛盾也让「哪个是对的」无从判断
- **建议**：`violin/design.md:12` 改为「取 41 个采样点（`0...=40`，步长 `(max-min)/40`）」，与 `violin-box` 统一

### [轻微][存量] 小提琴 design 用 `bandWidth * 0.4` 表示「槽宽」，与同一文档的 KDE「带宽」`bandwidth` 同名不同义

- **位置**：`f_chart/doc/spec/add-f-chart-violin/design.md:11`（「对每组计算带宽（显式或 Silverman）」）、`:13`（「轮廓最大半宽为 `bandWidth * 0.4`」）、`:18`（「箱宽 `bandWidth * 0.1`」）；对照 `f_chart/doc/spec/add-f-chart-violin-box/design.md:12`（同一规则写作「最大半宽为槽宽的 0.4 倍」）；实现 `f_chart/src/ViolinChart.cj:170-172`（`band.bandWidth * 0.4`，`band` 是 `BandScale`）
- **来源**：存量（`750e7acb3`）
- **判据**：review-checklist §13（术语与源码不一致，易误实现）+ 可读性
- **证据**：静态确定 —— 同一文档前两行刚用「带宽」指 KDE `bandwidth`（可由 `series[0].bandwidth` 覆盖），下一行却用视觉上几乎相同的 `bandWidth` 指类别槽宽；`violin-box` 的 design 已改用「槽宽」，说明命名确实有歧义
- **描述**：实现者若把 `bandWidth` 读成 KDE 带宽，`bandwidth = 0.05` 时轮廓半宽只有 0.02px，图会退化成一条竖线且不报错；这类误读成本高、排查困难
- **建议**：`violin/design.md:13`、`:18` 统一改为「槽宽的 0.4 / 0.1 倍（`BandScale.bandWidth`）」，与 `violin-box/design.md:12` 的措辞对齐

### [轻微][存量] TUI 柱状图 spec「`bar` 单系列占满类目带」与 design「柱宽 = `bandWidth × 0.6`」、实现 0.6 倍带宽矛盾

- **位置**：`f_chart/doc/spec/add-f-chart-tui/specs/chart-tui/spec.md:76`（「`bar` 单系列占满类目带」）、`f_chart/doc/spec/add-f-chart-tui/design.md:56`（「柱宽：`max(1, floor(bandWidth × 0.6))`」）；实现 `f_chart/src/tui/TuiBarRenderer.cj:195`（`floor(band.bandWidth * 0.6)`）
- **来源**：存量（`f4e27a68c`）
- **判据**：review-checklist §13（文档内部口径不一致）
- **证据**：静态确定 —— 单系列的柱宽是带宽的 60%，不是「占满」；spec 的上下句是「`bar` 单系列占满类目带，`grouped-bar` 在类目带内并排」，正确语义应是「独占整个带、不切槽位」
- **描述**：读者可能据此实现「柱宽 = 带宽」，与 design 的 0.6 冲突，输出柱体偏宽并挤压相邻类目；测试里没有柱宽断言，两种实现都能过
- **建议**：spec 改为「`bar` MUST 独占整个类目带（不切槽位），柱宽由 design 的 `0.6 × 带宽` 决定」，避免「占满」被理解为满宽

<!-- 第 24 部分 -->

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

<!-- 第 25 部分 -->

### [一般][存量] 冲积图末列节点标签固定画在节点右侧，越出绘图区被裁切

- **位置**：`f_chart/src/AlluvialChart.cj:255`（`node.x + nodeWidth + 4.0`），坐标来源 `AlluvialChart.cj:175-180`
- **来源**：存量（工作区快照无 diff）
- **判据**：review-checklist §11（边界差一 / 布局边界）、§10 正确性
- **证据**：静态确定 —— 末列（`column == stages.size - 1`）由 `:178-179` 得到 `node.x = plot.right - nodeWidth`，标签起点为 `plot.right + 4.0`；`ChartFrame` 只给 `padding.right`（默认 24，`ChartConfig.cj:22`）作为右侧留白（`ChartFrame.cj:85-91`），故标签可用宽度仅 `24 - 4 = 20px`。示例数据里 `"新客"/"老客"` 在 `fontSize - 2 = 10` 时约 20px 已贴边，更长名称（如 `"流失用户"`）必然被 viewBox 裁掉。
- **描述**：多阶段冲积图的最后一列标签一律向右排，超出画布右边界；SVG 默认不裁剪但 viewBox 之外不可见，实际表现是末列标签被切一半或完全不可见。
- **建议**：按列决定锚点——末列用 `anchor: "end"` 画在 `node.x - 4.0`，其余列保持 `"start"`；或在 `ChartFrame` 传入 `rightLabelWidth` 给末列预留文本宽度。

### [一般][存量] 「连续轴范围」有 6 套实现，留白策略互相漂移

- **位置**：
  - `f_chart/src/AreaChart.cj:323-373`（`resolveYRange`：下界不留白、上界 ×1.05）
  - `f_chart/src/BarRenderer.cj:394-424`（`applyAxisRange`：上下界各 ×1.05）
  - `f_chart/src/BoxPlotChart.cj:249-264` 与 `f_chart/src/BoxScatterChart.cj:228-243`（两份逐字节相同：两端各按 `span × 0.05` 留白）
  - `f_chart/src/BlandAltmanChart.cj:95-116`（手写 5% / 8% 留白）
  - `f_chart/src/BulletChart.cj:122-132`（不留白）
  - 对照实现 `f_chart/src/LineChart.cj:457-478`（`lineRange`：两端按 `span × 0.05`，且**一侧显式时另一侧不留白**）
- **来源**：存量
- **判据**：review-checklist §2（换文件复制 + 近似重复导致行为漂移）
- **证据**：静态确定 —— 同一语义「数据范围 → 轴范围 + 5% 留白」出现 6 份，判据差异可枚举：`LineChart.lineRange` 用 `axisMax.isSome()` 抑制对侧留白，`BoxPlot/BoxScatter` 的同名函数缺这两个判断；`AreaChart` 用乘法 1.05 且下界完全不留白；`BarRenderer` 上下界都乘 1.05。
- **描述**：同一份数据在柱状图里负值下方有 5% 余量，在面积图里最低点正好压在轴上；轴留白属对外观感契约，用户切换 `type` 会看到不一致的边界。合并时若只抄一份，很容易把某一图的既有留白改掉。
- **建议**：以 `lineRange`（`LineChart.cj:457`）为唯一实现，落到 `ChartScale.cj`（`internal func axisRange(dataMin, dataMax, axisMin, axisMax, paddingRatio, path)`），各图改为传参；`AreaChart`/`BarRenderer` 的乘法留白改由 `paddingRatio` 表达。合并需附改动前后的轴范围单测（含单侧显式 min/max、常量数据两种边界）。

### [一般][存量] 轴边距与刻度宽度计算在 6 个图各写一遍；气泡图硬编码导致 `labelRotate` 时标签被裁

- **位置**：
  - `maxYLabelWidth` 循环：`AreaChart.cj:141-150`、`BarRenderer.cj:73-82`、`BlandAltmanChart.cj:131-137`、`BoxPlotChart.cj:159-168`、`BoxScatterChart.cj:119-128`、`BubbleChart.cj:167-176`
  - `xLabelHeight` 三元式：`AreaChart.cj:151-155`、`BarRenderer.cj:84-88`、`BlandAltmanChart.cj:138-142`、`BoxPlotChart.cj:169-173`、`BoxScatterChart.cj:129-133`、`BulletChart.cj:147-151`
  - **漂移点**：`BubbleChart.cj:177` 不走三元式，直接传 `config.theme.fontSize + 12.0`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑导致的行为漂移）、§11（与 `xAxis.labelRotate` 契约不符）
- **证据**：静态确定 —— `ChartFrame.drawXAxisNumeric`（`ChartFrame.cj:290-309`）按 `axis.labelRotate` 旋转标签并在 `plot.bottom() + 10.0` 处以 `anchor: "end"` 绘制，需要约 48px；`ChartFrame` 的底部留白完全来自构造参数 `xLabelHeight`（`ChartFrame.cj:87`）。气泡图固定只留 `fontSize + 12 ≈ 22px`，`labelRotate != 0` 时旋转文本落到画布外。
- **描述**：6 份相同代码里唯一漏改的一份（`BubbleChart`）就是出问题的一份；其余 5 图行为一致。触发条件：`type: "bubble"` + `xAxis.labelRotate: 45`（该字段对所有图开放，`ChartConfig.cj:79`）。
- **建议**：把「按 y 刻度算左留白」和「按 rotate 算底留白」收进 `ChartFrame`（例如 `ChartFrame.forAxes(config, legendVisible, yTicks, series…)`），或至少把 `xLabelHeight` 提成 `chartXLabelHeight(config)` 放在 `ChartScale.cj`；`BubbleChart` 改用该函数。

### [一般][存量] Bland-Altman 复用 `bulletNumber`，负的测量值被当成非法输入拒绝

- **位置**：`f_chart/src/BlandAltmanChart.cj:68-69`（调用）、`f_chart/src/BulletChart.cj:233-243`（实现，`number < 0.0` 抛 `InvalidValue "数值不能为负"`）
- **来源**：存量
- **判据**：review-checklist §2（跨图复制被当成通用工具）、§11（契约与实现不符 / 语义与命名不符）
- **证据**：静态确定 —— 该 helper 名为 `bulletNumber`，语义却包含「非负」约束；同 helper 还被 `CandlestickChart.cj:74-77`、`DumbbellChart.cj:70-71`、`PairedLineChart.cj:79-80` 复用。承诺源 `f_chart/doc/chart-json-spec.md:981-999` 只写「`series[0].data` 为成对测量 `{x, y}`」，未限制符号；Bland-Altman 用于两种测量方法的一致性比较，原始测量值取负（温度偏移、对数比、坐标差）是正常输入。
- **描述**：`{x: -1.2, y: -0.8}` 这类合法测量对会被拒绝，报错文案 `series[0].data[0].x: 数值不能为负` 与「Bland-Altman 不接受负数」这一未写进文档的限制都不易排查；哑铃图/配对折线图同类风险。
- **建议**：拆成 `requiredFiniteNumber(json, field, path)`（`BoxPlotChart.cj:241-247` 的 `requiredNumber` 已是这个语义）与 `bulletNonNegativeNumber`；Bland-Altman/哑铃/配对折线改用前者，子弹图/蜡烛图保留非负校验（蜡烛图的 low/high 是否允许负数需用户确认）。是否放宽属契约变更，需用户拍板。

### [轻微][存量] 空 `series` 数组报 `MissingField`，与同模块「空数组 = InvalidValue」的约定不一致

- **位置**：`AreaChart.cj:63-65`、`BarRenderer.cj:56-58`、`BubbleChart.cj:73-75`、`BlandAltmanChart.cj:43-45`、`BoxPlotChart.cj:65-67`、`BoxScatterChart.cj:43-45`、`BulletChart.cj:47-49`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）、§10 契约一致性
- **证据**：静态确定 —— 字段存在但为空时 `chartMissingField("series")` 产出消息「缺少必填字段」，`path` 也指向存在的字段；同模块 `AlluvialChart.cj:69-71`、`ArcChart.cj:94-96` 对空数组抛 `InvalidValue`。测试（如 `AreaChart_test.cj:129-138`）只覆盖真正缺键，未覆盖空数组。
- **建议**：统一成 `chartInvalidValue("series", "至少需要一个系列")`；若认为「空系列在语义上等于缺失」是有意设计，请在 `ChartJson` 注释里写明，并补一条对应用例。

### [轻微][存量] 空 `data` 数组静默通过，输出只有坐标轴的空白图

- **位置**：`AreaChart.cj:77-94`（空 `data` 得到空 `points`）、`AreaChart.cj:312-321`（`validateLengths` 只比较长度，`0 == 0` 通过）、`BarRenderer.cj:272-285`（`parseValues` 返回空数组后无任何非空校验）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）、§3（半成品路径）
- **证据**：静态确定 —— 兄弟图 `BoxPlotChart.cj:79-81`、`BubbleChart.cj:110-112`、`BulletChart.cj:59-61`、`BoxScatterChart.cj:57-59` 都抛「数据不能为空」；这两个图直接渲染空图，调用方拿不到任何失败信号。
- **建议**：`parseCategoryPoints`/`parseContinuousPoints`/`parseValues` 返回后校验 `size > 0`，抛 `chartInvalidValue("${path}.data", "数据不能为空")`。

### [轻微][存量] `AreaChart.resolveYRange` 两个分支恒不成立（不可达）

- **位置**：`f_chart/src/AreaChart.cj:347-352`
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `dataMin` 初值 `0.0`（`:324`），首个数据点赋值 `minFloat(0.0, value) ≤ 0`，其后只做 `minFloat`，故 `dataMin > 0.0` 永不成立；`dataMax` 对称恒 `≥ 0`，故 `dataMax < 0.0` 永不成立。
- **建议**：删除两段，改用注释说明「初值 0 已保证范围跨 0」；`var minimum`（`:353`）同时可降为 `let`。

### [轻微][存量] 未使用的 `import std.math.*`

- **位置**：`AlluvialChart.cj:19`、`BubbleChart.cj:19`、`BubbleChart_test.cj:18`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 三文件内无 `cos/sin/abs/sqrt/floor/ceil/pow/log10` 等 `std.math` 符号；它们用的 `minFloat/maxFloat` 是 `BarRenderer.cj:454-468` 定义的模块内函数。（`ArcChart.cj:21` 用 `cos/sin`，`AreaChart.cj` 不 import 但用模块内 `minFloat`，均无问题。）
- **建议**：删除这三行 import。

### [轻微][存量] `BarRenderer` 的 `case _` 分支缩进断裂

- **位置**：`f_chart/src/BarRenderer.cj:211-239`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 可维护性）
- **证据**：静态确定 —— `for (seriesIndex ...)` 的两层嵌套体（`:212-237`）与 `case _ =>`（`:201`）同列，`}` 收口在 `:238-239`，与文件其余部分（4 空格递进）不一致，容易误读作用域。
- **建议**：跑一次 `cjfmt` 或手工对齐；无行为变化。

### [轻微][存量] 箱线散点图平铺模式只取 `labels[0]`，多余标签被静默忽略

- **位置**：`f_chart/src/BoxScatterChart.cj:87-93`（对照嵌套数组分支 `:79-84` 有长度校验）
- **来源**：存量
- **判据**：review-checklist §11（校验不对称 / 静默丢弃输入）
- **证据**：静态确定 —— `labels.size >= 2` 且数据为扁平数组时，仅 `labels[0]` 作为组名，其余标签既不报错也不参与渲染；同一函数在嵌套分支对 `labels.size != groups.size` 抛 `InvalidValue`。
- **建议**：平铺模式若 `labels.size > 1` 抛 `chartInvalidValue("xAxis.labels", "扁平数据只支持 1 个标签")`。

### [轻微][存量] 面积图面积填充默认透明度 0.3 与规格的 0.2 不符

- **位置**：`f_chart/src/AreaChart.cj:283`（`json.number("opacity", default: 0.3)`）、`AreaChart.cj:291`（`case None => 0.3`）
- **来源**：存量
- **判据**：review-checklist §13（默认值与源码不符，文档承诺侧：`f_chart/doc/chart-json-spec.md:623`「`series[].areaStyle.opacity`（默认 0.2）」）
- **证据**：静态确定 —— 两处默认值均为 `0.3`，规格写 `0.2`；`AreaChart_test.cj:55-64` 只断言显式 `0.25` 生效，未覆盖默认值。
- **建议**：确认期望值后二者取一（改代码或改规格）；若改代码，同步 `f_chart/README.md` 的 `area` 小节。

### [轻微][存量] 同文件/同族函数的重复实现（标签生成、长度校验、排序、高度比例）

- **位置**：
  - `AreaChart.cj:295-321` 与 `BarRenderer.cj:287-313`：`resolveLabels` + `validateLengths` 算法与错误文案（「数据长度 X 与 xAxis.labels 长度 Y 不一致」）完全一致，仅元素类型（`Array<LinePoint>` / `Array<?Float64>`）不同
  - `BoxPlotChart.cj:249-264` 与 `BoxScatterChart.cj:228-243`：`resolveYRange` 逐字节相同
  - `ArcChart.cj:205-211`（`sequentialOrder`）与 `ArcChart.cj:216-219`（`arcNodeOrder` 的身份下标前缀）重复；`ArcChart.cj:220-228` 与 `BoxScatterChart.cj:250-258` 是同一插入排序的两份实现
  - `AlluvialChart.cj:168-174`：`alluvialHeights`（`:286-303`）内部已求和并算 `usable`，调用方再求一次 `sumTotals`、再算一次 `usable`，`heights[i] = totals[i] * scale` 与 `scale = usable / sumTotals` 是同一公式的两遍
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 同语义多份）
- **证据**：静态确定 —— 上述四组逐行比对，输入-输出-副作用一致，差异点已在上一条「轴范围」中单列。
- **建议**：`validateLengths` 改接 `Array<Int64>` 长度列表，与 `resolveLabels` 一起放 `ChartScale.cj`；`AlluvialChart` 让 `alluvialHeights` 直接返回 `(heights, scale)`，删掉调用方的重复求和；`sequentialOrder` 用 `arcNodeOrder` 的参数化版本（`sort: Bool`）替代。

<!-- 第 26 部分 -->

### [严重][存量] 日历热力图按用户给的日期区间逐日生成图元，3.65M 天区间无拒绝路径

- **位置**：`f_chart/src/CalendarHeatmapChart.cj:152`（`dayCount`）、`:154`（`weekCount`）、`:183-216`（逐日循环，每天一次 `kit.rect`）
- **来源**：存量（快照模式无基线；`git blame` 指向 `ee0b54af0d 2026-11-08` 之前的历史行）
- **判据**：review-checklist §5（OOM：无界容器 / 无拒绝路径）+ §11（边界）
- **证据**：静态确定 —— `startDays`/`endDays` 来自 `ChartTime.parseDays`（`f_chart/src/ChartTime.cj:27-39`，只要求 4 位年 + 月 1..12 + 日 1..31，允许 `0001-01-01`~`9999-12-31`），`dayCount = endDays - startDays + 1`（`:153`）没有任何上限判断；`:183` 的循环对每一天都追加一条 `calendar-cell`、每遇到新月份再追加一条 `month-label`，且循环体内还会对 `uniqueDays` 做一次线性扫描（`:191-196`）。峰值内存量为估算（需实测），迭代次数上界由输入完全决定（静态确定）。
- **描述**：一份数百字节的 JSON（`{"startDate":"0001-01-01","endDate":"9999-12-31"}` + 空 `data` 即可，`:68` 只在「数据为空且缺一个日期」时才报错）就能让 `draw` 迭代约 365 万次。每条 `calendar-cell` 是 `group+rect` 两个元素，文本约 120–150 B，仅 SVG 字符串即 ≥ 450 MB；叠加 `SvgBuilder` 的每个元素对象与属性表后量级更高，服务端渲染接口上等同于可控 OOM/长阻塞（单次 `draw` 同步执行，无取消点）。若 `data` 的日期也铺满该区间，`:191` 的线性扫描会让复杂度变成 O(天数 × 去重天数)，实际表现为挂死。
- **建议**：在 `:152` 之后加区间上限（例如 `dayCount > 3 * 366` 直接抛 `chartInvalidValue("endDate", "日期区间过大")`，或按 `cellSize`/画布宽度反推允许的周数），并把 `uniqueDays/totals` 换成 `HashMap<Int64, Float64>` 聚合，去掉 `:131-146` 与 `:191-196` 两处线性查找。

### [严重][存量] 校准曲线的 Y 轴方向反了：`LinearScale` 的 top/bottom 参数传反，整图上下镜像

- **位置**：`f_chart/src/CalibrationChart.cj:130`（`let yScale = LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)`）
- **来源**：存量（`git blame -L 127,132` → `ee0b54af0d 2026-11-08`）
- **判据**：review-checklist §11（契约与实现 / 与规格冲突）+ §10（正确性）
- **证据**：静态确定 —— `LinearScale` 的形参语义写在 `f_chart/src/ChartScale.cj:22`（「`topPixel` 对应最大值，`bottomPixel` 对应最小值」）与 `:41`（`bottomPixel - (value-min)/span*(bottomPixel-topPixel)`）；传 `(plot.bottom(), plot.y)` 会让 `min` 落在 `plot.y`（顶部）、`max` 落在 `plot.bottom()`（底部）。已提交的渲染产物同样印证：`f_chart/charts/M096-calibration.svg` 中 y 刻度 `0` 在 `y=74`（绘图区顶部）、`0.2` 在 `y=145.6`；对照 `M083-candlestick.svg` 是 `0` 在 `y=432`（底部）、`100` 在 `y=108`。
- **描述**：`M96 calibration` 的 Y 轴「实际频率」越大越靠下，校准曲线与 `:151-158` 的对角线一起被上下翻转；对用户而言是「模型在高概率段系统性高估/低估」的错误结论，不是排版瑕疵。同模块另有多处相同写法（`BlandAltmanChart.cj:149`、`LiftChart.cj:135`、`LearningCurveChart.cj:196`、`EcdfChart.cj:145`、`LassoPathChart.cj:157`、`ManhattanChart.cj:166`、`VolcanoChart.cj:157`、`PdpChart.cj:133`、`GainChart.cj:126`），属同一根因的批量复制；`LiftChart` 的产物 `M094-lift.svg` 也是 `0.5` 在顶部、`3` 在底部。
- **建议**：本文件改为 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`（与 `CandlestickChart.cj:145`、`BarRenderer.cj:91` 一致）；更彻底的做法是把 `LinearScale` 改成 `LinearScale(min, max, plot: ChartRect, vertical: Bool)` 之类的工厂，从签名上消除 top/bottom 传反的可能，并在 `ChartScale` 上补一条方向断言用例。范围外提示：上述 9 个别文件同模式需一并修，改完必须重新生成 `charts/` 产物复核。

### [一般][存量] `calibration.binCount` 只校验、不参与绘制，README / spec 承诺的「分箱」没有实现

- **位置**：`f_chart/src/CalibrationChart.cj:31-37`（校验后丢弃）、`:69`（直接对原始点排序后连线）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现 / 读了不用）+ §1（读入不使用的配置字段）
- **证据**：静态确定 —— 承诺源：`f_chart/doc/chart-json-spec.md:2004`「专属字段：`diagonal`（默认 true）、`binCount`（可选）」、`f_chart/README.md:2191`「绘制方式：将预测概率分箱，横轴为平均预测值、纵轴为实际正例率」；缺失证据：`binCount` 在全模块只出现在 `CalibrationChart.cj:31-37` 的校验里（`grep -rn "binCount" f_chart` 无其他命中），`points` 直接来自 `series[0].data` 原始 `{x,y}`，没有任何按桶求均值/求正例率的代码。
- **描述**：调用方按文档传 `binCount: 10` 会得到与不传时完全相同的图；同时 `binCount` 传 0/负数会抛异常，传正整数无效果——「有校验 = 有效果」的错觉。文档描述的能力实际是「把点连成折线」，与「分箱校准」语义不同，读图者会把稀疏点的抖动误读为校准偏差。
- **建议**：要么实现分箱（按 `binCount`（缺省 10）等宽切 `[0,1]`，每桶取 `x` 均值与 `y` 均值，空桶跳过），要么删掉该字段与 README/spec 描述，改成「数据即已分箱的中心点」。二者都需同步 `doc/chart-json-spec.md:2004`。

### [一般][存量] `legend.orient` 解析后从未使用；`legend.position` 的 `left` / `right` 落到 `legendY = 0`，图例画到画布顶边

- **位置**：`f_chart/src/ChartConfig.cj:96`（字段）、`:106`（解析）；`f_chart/src/ChartFrame.cj:76-84`（只处理 `top` / `bottom`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（接线缺失）+ §13（文档与实现不符）
- **证据**：静态确定 —— `grep -rn "orient" f_chart/src` 只命中 `ChartConfig.cj:96/106` 的定义与赋值，`ChartFrame.drawLegend`（`:134-166`）只用 `itemGap` / `markerSize`，始终横向排布；`legendY` 初始为 `0.0`（`:75`），只有 `position == "top"` / `"bottom"` 两个分支会赋值，`"left"` / `"right"` 保持 0，图例于是画在 `y = 0`（画布顶边，与标题重叠，且不参与 `plot` 的留白计算）。承诺源：`f_chart/doc/chart-json-spec.md:72-73`（`position` = `top`/`bottom`/`left`/`right`，`orient` = `horizontal`/`vertical`）、`f_chart/README.md:274`（`show` / `position` / `orient` / `itemGap` / `markerSize`）。
- **描述**：两个公开配置项一个静默失效、一个半实现；`position: "left"` 的图例压住标题，`orient: "vertical"` 完全没有效果，且不会报错。
- **建议**：短期在 `ChartLegend.parse` 里对 `position` 做取值校验（非 `top`/`bottom` 直接抛 `chartInvalidValue`，与 `weekStart`、`scaleBy` 的既有做法一致），并给 `left`/`right` 在 `ChartFrame` 里留出 `left`/`right` 边距 + 竖排绘制；`orient` 要么实现（竖排时按 `marker + 4 + 文本高` 累加）要么从解析、README 与 spec 三处一起删掉。

### [一般][存量] `ChartFrame` 不校验绘图区宽高为正，画布小或刻度标签过宽时产生负宽高/反向坐标

- **位置**：`f_chart/src/ChartFrame.cj:85-91`（`left` / `right` / `bottom` / `plot` 直接相减）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界差一 / 数值边界）+ §10（正确性）
- **证据**：静态确定 —— `ChartConfig.parse` 只校验 `width > 0 && height > 0`（`ChartConfig.cj:182-184`），而 `ChartFrame` 的 `left = padding.left + yLabelWidth`、`right = padding.right + rightLabelWidth`、`top`/`bottom` 都可由**输入**放大：`yLabelWidth` 在调用方由 `chartTextWidth(chartFormatTick(tick, labelFormat))` 求出（如 `CalibrationChart.cj:115-121`、`CandlestickChart.cj:131-137`），`labelFormat` 是用户可传的任意模板。只要 `width < left + right`，`plot.width` 即为负；`plot.height` 同理（`title` 为空 + `legend.position == "bottom"` + `xLabelHeight` 48 时更容易触发）。
- **描述**：负 `plot.width` 会传进 `BandScale`（`ChartScale.cj:57` → `bandWidth` 为负，`CandlestickChart.cj:166` 的 `bodyWidth` 随之为负，输出 `width` 为负的 `<rect>`，SVG 规范下该矩形不渲染）和 `LinearScale`（起止像素颠倒，整图镜像）。目前没有任何异常或钳制，问题以「空白图 / 图形错位」的形式静默出现。
- **建议**：`:91` 之后判断 `plot.width < 1.0 || plot.height < 1.0` 时抛 `chartInvalidValue("width", "画布过小，无法容纳标题与刻度")`（与 tui 版「最小 20×8，低于下限抛 ChartException」的约定对齐，见 `README.md:3098`），或在绘图区宽高不足时退回最小边距。

### [轻微][存量] §1 死代码：3 个 `ChartJson` 方法、1 个未使用 import、2 个只写字段

- **位置**：`f_chart/src/ChartJson.cj:53-55`（`has`）、`f_chart/src/ChartJson.cj:141-143`（`requiredObject`）、`f_chart/src/ChartJson.cj:203-205`（`childPath`）、`f_chart/src/ChartFrame.cj:18`（`import std.collection.ArrayList`）、`f_chart/src/ChartScale.cj:49-50,55-56`（`BandScale.endPixel` / `count`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（无调用者 / 未使用 import / 读了不用）
- **证据**：静态确定 —— `grep -rn "childPath\|requiredObject" f_chart` 只命中定义行；`grep -rn "\.has(" f_chart` 零命中（`ChartJson` 是 `internal` 类，方法随之对外不可达）；`ChartFrame.cj` 内 `ArrayList` 仅出现在 `:18` 的 import（文件内全用原生数组）；`BandScale` 的 `count` 只在 `:56` 赋值、`endPixel` 只在 `:57` 参与一次计算后再无读取（`grep -rn "\.count" f_chart/src/ChartScale.cj` 仅 `:56`）。
- **描述**：属于演进残留，不影响行为，但会让下一位读者误以为 `ChartJson` 支持这些形态（尤其是 `requiredObject`，与 `object(name)` 的差别只在「缺失时报错」）。
- **建议**：删除 3 个方法与未使用 import；`BandScale` 的 `endPixel`/`count` 若保留就补 `bandEnd()` 之类的读取方，否则降级为 `init` 局部变量。

### [轻微][存量] §2 重复逻辑：`colorRange` 校验块在 6 个图表里逐字复制

- **位置**：`f_chart/src/CalendarHeatmapChart.cj:111-127`、`f_chart/src/CartogramChart.cj:112-128`（本部分两处）；同形复制另见 `ChoroplethChart.cj:108`、`HeatFlameChart.cj:135`、`HeatMap.cj:109`、`NetworkHeatmapChart.cj:131`（范围外）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制：同一错误消息 + 同一循环）
- **证据**：静态确定 —— `grep -rn "至少需要两个颜色" f_chart/src` 命中 6 个文件，6 处的结构完全一致：`root.stringArray("colorRange", default: [...])` → `size < 2` 抛 `"至少需要两个颜色"` → `for (i in 0..size)` 逐个 `SvgColor.tryParse` → `"非法颜色 ..."`。差异仅在默认色板与第 3 个参数（默认值）。
- **描述**：同一语义的 6 份实现，任一处调整（例如允许 1 色、改成按 `#rgb` 简写展开、错误消息带候选值）都会漂移；`"非法颜色"` 字符串在模块内共出现 11 次，漂移面更大。
- **建议**：抽 `internal func chartColorRange(root: ChartJson, default: Array<String>): Array<String>` 放到 `ChartJson.cj` 或 `ChartScale.cj` 同层，默认色板作为参数传入；6 处改为一行调用，并补一个「1 色报错 / 非法色报错」的共用用例。

### [轻微][存量] §2 重复逻辑：`legendVisible` + `legendNames/legendColors` + `maxYLabelWidth`/`xLabelHeight` 样板在图表间反复照抄

- **位置**：`f_chart/src/CalendarHeatmapChart.cj:156,174-180`、`f_chart/src/CalibrationChart.cj:115-128,142-148`、`f_chart/src/CandlestickChart.cj:131-142,157-163`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（跨文件复制：输入-输出-副作用相同）
- **证据**：静态确定 —— 三处 `maxYLabelWidth` 循环（列表格式化刻度 → `chartTextWidth` → `maxFloat`）与 `xLabelHeight` 三元表达式（`fontSize + 12` / `48`）逐行同构；`legendVisible = config.legend.show && !seriesName.isEmpty()` 与随后的 `if (legendVisible) { [x] } else { Array<String>() }` 成对出现 3 次（模块内同类写法见 `LiftChart.cj:117-153`、`BlandAltmanChart.cj:156-163` 等）。
- **描述**：这类样板决定「图例是否显示」「Y 轴标签留多宽」，是本模块布局一致性的关键；散落复制后一旦某图调整（例如长标签换行、图例改为右侧），各图行为就会不一致——本轮 `legend.position` 支持面不足（见上一条「一般」）正是这种漂移的后果。
- **建议**：把 `legendVisible`、`[name]/[color]` 组装收进 `ChartFrame`（如 `frame.drawSeriesLegend(kit, seriesName, color)`），把 `maxYLabelWidth` + `xLabelHeight` 收成 `ChartFrame.yLabelWidth(ticks, format)` 与 `ChartFrame.axisLabelHeight(axis)`；差异（单系列 vs 多系列）用参数表达，不要新起一层抽象。

### [轻微][存量] 共享辅助类缺少入参校验：`drawLegend` 可能除零、`colorAt` 负索引、`padding`/`fontSize` 允许负值

- **位置**：`f_chart/src/ChartFrame.cj:153`（`colors[index % colors.size]`）、`f_chart/src/ChartTheme.cj:54-60`（`index % this.palette.size`）、`f_chart/src/ChartConfig.cj:39-45`（`padding` 未校验）、`f_chart/src/ChartTheme.cj:44`（`fontSize` 未校验）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 空集合）+ §10（正确性）
- **证据**：待确认 —— `drawLegend` 只在 `names.isEmpty()` 时提前返回（`:135`），`colors` 为空而 `names` 非空时 `index % 0` 会抛算术异常；仓内 3 处调用（`CalendarHeatmapChart.cj:180`、`CalibrationChart.cj:148`、`CandlestickChart.cj:163`）都按「成对传空/成对传 1 个」使用，因此当前不可达，属防御性缺口。`colorAt` 对负 `index` 取模得到负下标（仓颉数组负下标越界），仓内调用点（`CalibrationChart.cj:144,160`、`CandlestickChart.cj:159`）均为 0，但同模块 `ChordChart.cj:183`、`AlluvialChart.cj:207,248` 传入的是查找/映射结果，拼错输入即有风险。`ChartPadding.parse` 与 `ChartTheme.parse` 对负数不报错（`padding: -100` 会让 `plot` 大于画布，`fontSize: -1` 会写出 `font-size="-1"`）。
- **描述**：四处都是「值域假设」没有落到代码里；其中 `padding`/`fontSize` 是用户可直接控制的 JSON 字段，负值只产生畸形 SVG 而不报错。
- **建议**：`drawLegend` 增 `if (colors.isEmpty()) { return }` 或改成 `colors[index % colors.size]` 前判空；`colorAt` 用 `abs(index) % size`（或 `if (index < 0) { 0 }`）；`ChartPadding.parse` / `ChartTheme.parse` 对 `top/right/bottom/left`、`fontSize` 加 `>= 0`（`fontSize > 0`）校验并抛 `chartInvalidValue`。

### [轻微][存量] `bulletNumber` 与 `volcanoNumber` 只差一个负数检查，且蜡烛图复用「bullet」命名的辅助函数

- **位置**：`f_chart/src/BulletChart.cj:233-243`（`bulletNumber`）、`f_chart/src/VolcanoChart.cj:228-234`（`volcanoNumber`）、调用点 `f_chart/src/CandlestickChart.cj:74-77`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改边界 / 只改类型名的重复）
- **证据**：静态确定 —— 两个函数逐行对齐：`json.required(field)` → `!(isInt || isDecimal)` 抛 `"期望数字"` → `jsonNumberValue(...)`；唯一差异是 `bulletNumber` 多一段 `number < 0.0` 抛 `"数值不能为负"`。`CandlestickChart` 的 `open/high/low/close` 四个字段全走 `bulletNumber`。
- **描述**：行为差异（是否允许负数）藏在名字里而不是参数里；命名把「子弹图的辅助函数」扩散到蜡烛图，读 `CandlestickChart.cj:74` 时无法判断为什么叫 bullet。
- **建议**：合并为 `chartRequiredNumber(json, field, itemPath, allowNegative: Bool)`（或 `nonNegative!: Bool = true`），放回 `ChartJson.cj`；两个旧函数删除，调用点改用具名参数。

### [轻微][存量] README 把 `InvalidJson` 列为本模块会抛出的类别，但 `Chart.draw` 只接收 `JsonObject`，该类别永远不产生

- **位置**：`f_chart/src/ChartException.cj:22-23`（`InvalidJson` 定义）、`f_chart/src/Chart.cj:35`（`draw(data: JsonObject)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— 承诺源 `f_chart/README.md:41`「输入不合法时抛 `ChartException`，`kind` 区分 `InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`」；缺失证据：`grep -rn "InvalidJson" f_chart/src` 只命中 `ChartException.cj:23,33,43`（定义、`==`、`toString`），模块内没有任何构造点，因为 JSON 文本解析发生在 `f_data`、由调用方完成。
- **描述**：`ChartErrorKind` 是公开枚举（对外契约，**不判死代码**），但文档让使用者以为可以直接接住 `InvalidJson` 做「JSON 语法错误」分支；实际拿到的只会是调用方自己解析 JSON 时抛的异常，两处错误语义不同源。
- **建议**：README 该行补一句「`InvalidJson` 供调用方在解析 `f_data` JSON 文本失败时复用本枚举」；或给 `Chart` 增加一个 `draw(text: String)` 重载，把解析失败映射为 `InvalidJson`。

### [轻微][存量] 画廊测试只断言 `contains("<svg")`，渲染回归（如本轮 Y 轴翻转）无法被捕获

- **位置**：`f_chart/src/ChartGallery_test.cj:31-39`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可测试性）+ §14.1（半成品覆盖）
- **证据**：静态确定 —— `save()` 的全部断言是 `@Assert(svg.contains("<svg"))`，之后直接 `File.writeTo`；107 个 `@TestCase`（与 `:26-27` 注释的「107 个 SVG」一致，实测 `charts/*.svg` 也是 107 个）没有任何几何/元素位置断言。配套的 `CalibrationChart_test.cj:58-63` 也只数 `class="calibration-line"` / `class="calibration-point"` 的个数，因此「Y 轴反向」这类整图镜像在 6 个点的用例里完全测不出。
- **描述**：画廊的角色是「人能打开看」，不是回归防线；一旦有人改 `LinearScale` 参数或 `ChartFrame` 边距，CI 全绿而图已经画反（本轮 `M096` 即为此例）。同时 `save()` 会往仓库工作目录写 107 个文件，测试带副作用。
- **建议**：至少对每张图加一条「关键图元坐标单调性」断言（例如「y 值更大的点其 `cy` 更小」），或对 3–5 张代表图做带容差的关键坐标快照；`save()` 改为写临时目录并按环境变量开关。

<!-- 第 27 部分 -->

### [一般][存量] 堆叠柱/百分比堆叠柱的所有分段使用同一颜色，与图例不符

- **位置**：`f_chart/src/ComboChart.cj:562-565`（缺省色回退在 564）、`f_chart/src/ComboChart.cj:630-633`（折线缺省色）、`f_chart/src/ComboChart.cj:651-654`（散点缺省色）
- **来源**：存量（快照模式无基线；`git blame` 指向该文件引入 commit）
- **判据**：review-checklist §10（正确性：同一语义的颜色在绘制与图例两处必须一致）/ §11（契约与实现不符）
- **证据**：静态确定 —— 图例在 `ComboChart.cj:197-203` 用**全局系列下标** `config.theme.colorAt(index)` 取色；而 `drawBarGroups` 的多系列分支对所有分段统一回退到 `config.theme.colorAt(group.series[0].paletteIndex)`。同一 stack 组的 `series[0]` 恒定，故 3 个分段得到同一个色值
- **描述**：`stacked-bar` / `percent-stacked-bar` 组内任意多系列未显式写 `color` 时，所有分段渲染成同一种颜色，分段边界不可辨认；同时图例色块按 `colorAt(0..n)` 展开，与图中颜色一一对不上。`line` / `scatter` 的缺省色进一步硬编码 `"#4e79a7"`（632、653），多折线时所有线同色而图例多色
- **建议**：缺省色统一改为 `config.theme.colorAt(item.paletteIndex)`（`ComboSeries.paletteIndex` 已存在，可直接用），删掉 632/653 的字面量；或把「系列 → 颜色」在 `draw()` 里预计算成 `Array<String>` 后传入 `drawBars/drawLines/drawScatters`，保证图例与图形同源

### [一般][存量] `combo` 的 `bar` / `grouped-bar` 丢弃 `stack` 字段，规格示例不堆叠

- **位置**：`f_chart/src/ComboChart.cj:238-243`（第 241 行把 `stack` 固定写成 `""`）；消费者 `f_chart/src/ComboChart.cj:459-471`
- **来源**：存量
- **判据**：review-checklist §11（与规格冲突）；承诺源 `f_chart/doc/chart-json-spec.md:2650`（「同一 `stack` 的柱先堆叠」）与 `:2663-2664`（示例用 `"type": "bar", "stack": "sales"`）
- **证据**：静态确定 —— `parseSeries` 只在 `case "stacked-bar" | "percent-stacked-bar"`（244-251）读取 `json.string("stack")`；`bar`/`grouped-bar` 分支 `ComboSeries(...)` 的第 6 个实参固定 `""`，于是 `buildBarGroups` 里 `item.stack.isEmpty()` 恒真，每个柱系列各占一个 `__single_${index}` 组
- **描述**：规格首例（两个 `type: "bar"` + 同一 `stack: "sales"`）期望堆叠，实际渲染为并排分组柱；用户按文档写 `stack` 得不到任何效果，也不会报错
- **建议**：`bar` 分支改为 `json.string("stack", default: "")` 透传（`grouped-bar` 保持固定空串以区别于堆叠）；同步在 `ComboChart_test` 增加「`bar` + `stack` 应只产生 2 个 rect 区间（堆叠）」用例；若确认设计上 `bar` 不堆叠，则须修规格示例而非代码——两者必须一致

### [一般][存量] `combo` 忽略 `legend.show`，图例无法关闭

- **位置**：`f_chart/src/ComboChart.cj:167`
- **来源**：存量
- **判据**：review-checklist §14.1（配置项被读取却从未使用 / 接线缺失）；承诺源 `f_chart/doc/chart-json-spec.md:71`（`legend.show` 默认 `true`，是通用字段）
- **证据**：静态确定 —— `let legendVisible = series.size > 1`，全文件无 `config.legend.show` 引用（`grep config.legend f_chart/src/ComboChart.cj` 仅命中 ChartFrame 调用）；同模块 `ControlChart.cj:123` 的正确写法是 `config.legend.show && !seriesName.isEmpty()`
- **描述**：多系列 combo 图无法通过 `"legend": {"show": false}` 隐藏图例，且 `position` 之外的配置被静默忽略；与同模块其他图的语义不一致
- **建议**：改为 `config.legend.show && series.size > 1`（`ChartFrame.drawLegend` 内部已有 `legendVisible && names.isEmpty()` 保护，无需再判空）

### [一般][存量] 圆堆积图对含环输入静默丢节点，三处「存在环」守卫不可达

- **位置**：`f_chart/src/CirclePackingChart.cj:108-113`（只校验根数量）、`:146-149`、`:170-173`、`:190-199`（`depth > total` 守卫）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）+ §11（静默数据错误）
- **证据**：静态确定 —— 每个节点只有一个 `parent`，`roots.size == 1` 要求全图恰有一个无父节点；任何环上的节点都有父节点，因此环只可能构成与根不相连的独立分量。`resolveTotals(rootNode, 0, nodes.size)` 只沿根可达子树下钻，深度上界为 `nodes.size - 1 < total`，故 `depth > total` 恒假；环分量既不参与布局也不参与绘制，且不抛错
- **描述**：输入如 `root(parent=null)`、`b(parent=c)`、`c(parent=b)` 时，`b`、`c` 被静默丢弃（不渲染、不计入面积、不报错），用户看到的是「少了两块」的图；三处环检测代码实际是死分支。反例可对比 `DecisionTreeChart.cj:186-189`（用可达节点计数做真检测）
- **建议**：解析阶段用「父链查环」（对每个节点沿 parent 上溯计数，超过 `nodes.size` 即判环）或在 `resolveTotals` 前用 `HashSet` 做访问标记；把 `depth > total` 替换为「可达节点数 != nodes.size」的统一校验，并补一条环输入的负向用例

### [一般][存量] 圆堆积子圆按矩形网格布点，3/5/7 个子节点会溢出父圆

- **位置**：`f_chart/src/CirclePackingChart.cj:203-216`
- **来源**：存量
- **判据**：review-checklist §10（布局算法正确性）
- **证据**：静态确定 —— `columns = ceil(sqrt(count))`、`rows = ceil(count/columns)`，子圆心落在父圆的外接正方形网格中心（212-213），半径上限 `min(cellWidth, cellHeight)/2 - padding`（214-216）。`count = 3` 时 `2×2` 网格：子圆心在 `(±r/2, ±r/2)`，距父圆心 `0.707r`，加半径 `0.5r` 得 `1.207r > r`
- **描述**：子节点数不是完全平方数（3、5、6、7、8…）时，角落子圆有约 20% 半径露出父圆之外，视觉上「圆堆积不嵌套」；现有测试 `CirclePackingChart_test.cj` 的样例每个父节点恰好 2 个子节点（`columns=2, rows=1`），因此测不到
- **建议**：按可用半径做内切约束（子圆心到父圆心的距离 + 子半径 ≤ 父半径 − padding），或改用「按面积排布 + 螺旋/同心环」布点；补一条 3 子节点的几何断言（`hypot(dx,dy) + childR <= parentR`）

### [一般][存量] 树形图递归深度等于树深且无上限，深链输入会栈溢出

- **位置**：`f_chart/src/CirclePackingChart.cj:146`（`resolveTotals`）、`:170`（`sortChildren`）、`:190`（`layoutChildren`）、`:221`（`drawNode`）；`f_chart/src/DecisionTreeChart.cj:301`（`countDecisionNodes`）、`:310`（`decisionAssignDepth`）、`:318`（`decisionAssignSlots`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归）
- **证据**：静态确定（深度无上限）+ 需实测（溢出阈值）—— 递归深度 = 从根到最深叶的层数，节点数与层级完全由 JSON 输入决定，模块内无深度上限、无节点数上限、无迭代改写。`CirclePackingChart` 的 `depth > total` 守卫按上一条已证明恒假，起不到限制作用
- **描述**：输入一条 1 万层的链式 `parent`（或决策树 1 万层 `edges` 链）时，7 个递归函数逐个下钻，栈帧在 `resolveTotals`/`countDecisionNodes` 处耗尽即进程崩溃（Cangjie 不保证尾调用优化，`decisionAssignSlots` 也不是尾递归）
- **建议**：改为显式栈迭代（后序求 total、层序求 depth/slot），或在解析阶段限制层数（如 `maxDepth` 默认 64，超出抛 `InvalidValue`）；同时把 `nodes.size` 上限（如 5000）写进规格与校验

### [一般][存量] `pathCentroid` 把弧命令参数与指数当坐标，弧线地图的标签位置错误

- **位置**：`f_chart/src/ChoroplethChart.cj:176-217`（扫描 182-203，配对 211-216，异常吞掉 194-198）
- **来源**：存量
- **判据**：review-checklist §10（正确性）/ §3（`catch (_: Exception) { () }` 静默吞异常）
- **证据**：静态确定 —— 扫描器把所有「数字串」按出现顺序两两配对求和，不区分命令类型。`A rx ry rot large-arc sweep x y` 会贡献 5 个非坐标数字（`rx, ry, rot, large-arc, sweep`），`M`/`L` 之后的 `Z` 无影响但 `H/V` 只给一个坐标；指数写法 `1e-3` 被切成 `1` 与 `3`
- **描述**：`regions[].path` 使用 `A`（圆弧，地图里用于海岸线/圆角边界很常见）时，标签位置按错误坐标均值计算，可偏出区域甚至落到画布外；`Float64.parse` 失败又被 `catch { () }` 吞掉，非法数字不会报错，只是少一个点，偏差无法察觉
- **建议**：按 SVG path 命令语义解析（`M/L/T` 取 2 个、`H/V` 取 1 个、`C/S/Q` 取 6/4/4、`A` 取 7 并只取末 2 个）；或收窄契约：只接受 `M/L/H/V/Z`，出现其它命令抛 `InvalidValue`。两者都比现在的「数字流近似」可控

### [一般][存量] 等高线图 `levels` 显式数组只取长度，且不校验「递增」

- **位置**：`f_chart/src/ContourChart.cj:110`（调用）、`:247-267`（`resolveLevels`，数组分支 250-256）
- **来源**：存量
- **判据**：review-checklist §14.1（半成品）/ §11（契约与实现不符）；承诺源 `f_chart/doc/spec/add-f-chart-contour/specs/chart-rendering/spec.md:25`（「`levels` MUST 为正整数或递增数组」）、`f_chart/doc/chart-json-spec.md:1140`（「等值线层级数或显式数组」）
- **证据**：静态确定 —— 数组分支只 `return items.size`，元素值从未读取；无任何单调性检查，`[30, 10, 20]` 与 `[1, 2, 3]` 等价
- **描述**：规格承诺「显式层级数组」可用，实际退化为「层级数 = 数组长度」，用户给的阈值（如 `[10, 20, 50]`）被完全忽略，等值线位置仍按 `min/max` 均分；非递增数组也不报错，属于静默错误输出
- **建议**：`resolveLevels` 返回 `Array<Float64>`（显式阈值或按 `min/max` 均分生成），`contourLevel` 改为「落在哪个阈值区间」；数组分支补递增校验（`levels[i] <= levels[i-1]` 即 `InvalidValue`，`path: "levels[i]"`）

### [一般][存量] 三个规格字段「读取/声明但无消费者」：`interpolate`、`method`、`condition`

- **位置**：`f_chart/src/ContourChart.cj:111-114`（`interpolate`）、`f_chart/src/CorrelationMatrixChart.cj:81-84`（`method`）、`f_chart/src/DecisionTreeChart.cj:91-92`（只读 `label`/`leaf`，`condition` 从未读取）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置字段）+ §14.1（接线缺失）；承诺源 `f_chart/doc/chart-json-spec.md:1140`（`interpolate` 控制 `linear`/`nearest`）、`:1089`（`method` 取 `pearson`/`spearman`）、`:2065`（节点字段含 `condition?`）
- **证据**：静态确定 —— `grep -n interpolate f_chart/src` 除 `ContourChart.cj:111-113` 与测试外无命中；`method` 只在 81-84 参与比较后再无引用；`grep -n condition f_chart/src/DecisionTree*.cj` 无命中
- **描述**：`interpolate` 无论取 `linear` 还是 `nearest`，输出 SVG 完全一致（实现按网格点分层着色，根本没有插值分支）；`method` 对着已经算好的相关矩阵没有任何作用，只在取值非法时抛错；决策树的 `condition` 字段被丢弃，节点只显示 `label`。三者都会让使用者以为配置生效
- **建议**：要码就接线——`contour` 至少让 `nearest`/`linear` 在「跨格等值线是否插值切割」上产生可观测差异；`correlation` 既然吃现成矩阵就删掉 `method`（或改为「由原始样本计算」的入口）；`decision-tree` 在节点文本里拼接 `condition`。不实现则从规格与校验里删除，避免「校验通过但无效果」

### [一般][存量] 混淆矩阵/相关矩阵输出量随标签数平方增长，无上限也无拒绝路径

- **位置**：`f_chart/src/ConfusionMatrixChart.cj:128-154`（每个单元 1 个 `rect` + 1 个 `text`）、`f_chart/src/CorrelationMatrixChart.cj:122-152`
- **来源**：存量
- **判据**：review-checklist §5（平方级增长 / 无界容器，判据要求量化）
- **证据**：需实测 —— 输入规模 n（`labels.size`）不受限，输出元素数 = n²（混淆矩阵还额外 n² 个 `confusion-value` 文本）。按每单元约 150–200 字节序列化估算，n = 300 时约 9 万单元（≈15–18 MB），n = 1000 时约 10⁶ 单元（≈150–200 MB），且 `SvgBuilder` 全程在内存里拼字符串，未流式
- **描述**：一个「标签 1000×1000」的矩阵请求即可让单次 `draw` 产出上百 MB 字符串并常驻到返回，触发 OOM 或把上游（HTTP 响应）拖死；没有 `maxLabels` 之类的上限，也没有分块/降采样路径
- **建议**：加显式上限（如 `labels.size <= 200`，超出抛 `InvalidValue`，path `labels`），并在 `showValues` 打开时按 `cellSize` 阈值自动关闭数值文本；长期方案是把矩阵输出改为流式拼接（`SvgBuilder` 之外的 writer）

### [一般][存量] 相关矩阵 `colorRange` 不校验颜色，规格要求的 `InvalidValue` 缺失

- **位置**：`f_chart/src/CorrelationMatrixChart.cj:167-190`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）；承诺源 `f_chart/doc/chart-json-spec.md:2713`（「颜色字符串无法解析 → `InvalidValue`」）
- **证据**：静态确定 —— `resolveColorRange` 只校验「是字符串」「恰好 3 个」，不调用 `SvgColor.tryParse`；同模块 `ChoroplethChart.cj:110-119` 对 `colorRange` 逐个 `tryParse` 并抛错，两处口径不一致
- **描述**：`"colorRange": ["#fff", "oops", "#000"]` 会原样写进 `fill`，SVG 渲染器按无效值处理（多数实现回退为黑色/不绘制），负相关格变成黑块且没有任何错误提示
- **建议**：复用 `ChoroplethChart` 的校验循环（`SvgColor.tryParse` + `chartInvalidValue("colorRange[i]", ...)`），或把它抽成 `ChartTheme`/`ChartJson` 里的公共 `parseColorArray(path, count)`，供两处共用（见重复逻辑条目）

### [轻微][存量] 冗余包装与重复实参

- **位置**：`f_chart/src/ComboChart.cj:210`（调用）、`:217-219`（`labelCount` 仅 `labels.size`）；`f_chart/src/ControlChart.cj:168-179`（三个调用点都传 `frame.plot.right()` 同时作 `right` 与 `labelX`）、`:209-219`（`drawLimitLine` 签名）
- **来源**：存量
- **判据**：review-checklist §10（可读性）/ §1（冗余间接）
- **证据**：静态确定
- **描述**：`labelCount(labels)` 只是 `labels.size` 的一层包装，且与 `drawBarGroups` 的形参同名，读代码时容易误判为另一套语义；`drawLimitLine` 的 `right` 与 `labelX` 永远相等（3 个调用点均传 `frame.plot.right()`），双参数是历史残留
- **建议**：直接传 `labels.size` 并删除 `labelCount`；`drawLimitLine` 去掉 `labelX`，用 `right + 6.0` 定位标签

### [轻微][存量] `ChartTime` 日期校验只覆盖形状与 1..31，非法日期被静默归一化

- **位置**：`f_chart/src/ChartTime.cj:27-39`（范围校验 35-37）、`:52-58`（数字解析）、`:60-71`（`daysFromCivil`）、`:89-96`（`pad`）
- **来源**：存量
- **判据**：review-checklist §11（边界校验缺失、语义与注释不符）
- **证据**：静态确定（月份天数 / 尾随字符）+ 待确认（负年份整除语义、越界切片的运行时行为）
- **描述**：① `2026-02-31` 通过校验，`daysFromCivil` 直接溢出到 3 月，`formatDays` 回显 `2026-03-03`；② 只检查前 10 字节，`"2026-01-01xyz"` 被接受；③ 年份为负（`"-123-05-06"` 能过 `bytes[4]=='-'`）时 `y / 400` 是截断除法而算法要求向下取整，天数会偏一天以上；④ `pad` 对负年份把 `"-1"` 补成 `"00-1"`；⑤ 切片 `text[0..4]` 等按字节下标，若多字节字符恰好跨在 3/5/8/10 边界（如 `"20é-01-01"` 通过两处 `'-'` 检查），切片落在非字符边界的行为需按 `String` 文档确认（本地 `~/.autocode/cj/doc` 不可用，未能查证）
- **建议**：解析前先 `if (text.size < 10) ...`，再用正则/逐字符校验 `0..10` 全为 ASCII 且形如 `\d{4}-\d{2}-\d{2}`；补「按当月天数校验」（用 `civilFromDays(daysFromCivil(...))` 回读比对）与尾部字符校验；负年份用 `floorDiv` 语义

### [轻微][存量] 重复逻辑：id 去重循环与线性查找助手在 5 个文件各写一遍

- **位置**：`f_chart/src/ChordChart.cj:82-86`（id 去重）、`:204-211`（`findNode`）；`f_chart/src/ChoroplethChart.cj:82-86`；`f_chart/src/CirclePackingChart.cj:74-78`、`:137-144`；`f_chart/src/DecisionTreeChart.cj:86-90`、`:281-288`；`f_chart/src/ComboChart.cj:311-319`（类目名线性查找）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的跨文件复制）
- **证据**：静态确定 —— 五处 `for (existing in X) { if (existing.id == id) throw ... }` 结构逐行对齐，仅文案从「节点 id 重复 / 区域 id 重复 / 节点 id 重复」变化；四套线性查找返回 `Int64` 或 `?T` 两种形态
- **描述**：`O(n)` 校验让建图阶段变成 `O(n²)`（下一条的性能线索），且错误文案与 path 规则已经出现漂移（`Chord` 用 `${itemPath}.id`、`CirclePacking` 用 `nodes`、`DecisionTree` 用 `edges`）
- **建议**：在模块内加一个 `ChartGraph` 小工具（`internal`）：`addNode(id, path)` 内部维护 `HashMap<String, Int64>`，同时提供 `index(id): ?Int64`，五个图改用它；错误文案以参数传入，避免行为漂移

### [轻微][存量] 重复逻辑：插入排序、y 轴标签宽度、两位小数格式各有多份

- **位置**：插入排序 `f_chart/src/CirclePackingChart.cj:174-184` 与 `f_chart/src/ContourChart.cj:226-234`；`maxYLabelWidth` 统计 `f_chart/src/ComboChart.cj:143-152`、`f_chart/src/ContourChart.cj:133-142`、`f_chart/src/ControlChart.cj:124-133`；两位小数格式化 `f_chart/src/CorrelationMatrixChart.cj:222-234`（`formatCorrelation`）与 `f_chart/src/ConfusionMatrixChart.cj:229-238`（`confusionText`）
- **来源**：存量
- **判据**：review-checklist §2（换算复制 / 字面量复制）
- **证据**：静态确定 —— 两处插入排序的控制流与临时变量名一致（`while (j > 0 && a[j] >/< a[j-1])`）；三处宽度统计是同一段 `chartTextWidth(chartFormatTick(...)) + maxFloat` 循环；两处小数格式化都是 `round(v*100)` → 拆整数/百分位 → 补零
- **描述**：差异点是业务性的（一边取「深色/浅色阈值」、一边把符号单独处理），因此不建议合并成一个函数；但排序与「标签宽度」这两组没有差异，属于纯复制，后者还各自漏掉了 `labelRotate` 分支（`ComboChart:168-172`、`ControlChart:134-138` 又各写一遍）
- **建议**：排序用 `std.sort`（或在 `ChartScale.cj` 放一个 `sortDescending/​sortAscending` 助手）；「y 轴标签宽度 + x 轴标签高度」抽成 `ChartFrame.measureAxisLabels(config, ticks, axis)`（`ComboChart`/`ContourChart`/`ControlChart` 已有 `ChartFrame` 依赖，落点合规）；`formatCorrelation` 与 `confusionText` 保留两份，但在注释里写清「一个处理符号、一个假定非负」

### [轻微][存量] 相关矩阵在窄画布上算出负的 `size`/`cell`，输出无效尺寸

- **位置**：`f_chart/src/CorrelationMatrixChart.cj:110-120`
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 负值未处理）
- **证据**：静态确定 —— `availableWidth = width - padding.left - padding.right - labelWidth - 16`；`width = 100`（`ChartConfig` 只要求 `> 0`，见 `ChartConfig.cj:182-184`）时 `availableWidth = -28`，`size = min(-28, ...) = -28`，`cell = -28 / order` 为负，`kit.rect` 原样写入 `width="-14px"`（`SvgAuthoringBuilder.cj:115-131` + `SvgNumber.cj:32-48`，写出阶段不校验非负）
- **描述**：负尺寸 rect 在 SVG 规范里是错误值，浏览器不渲染 ⇒ 整图为空白；同模块 `ConfusionMatrixChart.cj:110-112` 用 `maxFloat(..., 1.0)` 做了钳制，口径不一致
- **建议**：`let size = maxFloat(minFloat(availableWidth, availableHeight), 1.0)`，并给 `labelWidth` 加下限校验；或在 `ChartConfig.parse` 里按图类型校验最小画布尺寸

### [轻微][存量] 轴余量与规格默认不一致（8% / 0% vs 5%）

- **位置**：`f_chart/src/ControlChart.cj:102-113`（`span * 0.08`）、`f_chart/src/ContourChart.cj:269-287`（`resolveRange` 完全不加余量）
- **来源**：存量
- **判据**：review-checklist §13/§11（与规格默认冲突）；承诺源 `f_chart/doc/chart-json-spec.md:2720`（「数值轴未给 `min`/`max` 时按数据范围留 5% 余量」）
- **证据**：静态确定 —— `ComboChart` 走 `lineRange`（`LineChart.cj:457-477`，5%），`ControlChart` 自写 8%，`ContourChart` 自写 0%
- **描述**：同为「数值轴自动范围」，三张图留白不同；`contour` 的极值格恰好贴边（等值线被坐标框裁掉一半），`control` 的留白偏大。属默认值漂移，不影响正确性
- **建议**：`ContourChart.resolveRange` 与 `ControlChart` 改用 `lineRange(...)`（已导出、已带 5% 与「一端显式」语义），删除各自的私有实现

<!-- 第 28 部分 -->

### [一般][存量] `ecdf` 的 X/Y 比例尺实参顺序颠倒，整张图被旋转 180°

- **位置**：`f_chart/src/EcdfChart.cj:144-145`
- **来源**：存量（`git blame` 指向 `2845ac7dca`，2026-11-08，早于本轮快照基线）
- **判据**：review-checklist §10（布局算法正确性）/ §11（语义与注释不符）
- **证据**：静态确定 —— `LinearScale` 的构造约定写在 `f_chart/src/ChartScale.cj:22`（「`topPixel` 对应最大值，`bottomPixel` 对应最小值」），`scale()` 实现为 `bottomPixel - (value-min)/span*(bottom-top)`（`ChartScale.cj:36-43`）。正确写法见同模块 `DumbbellChart.cj:133`、`HistogramChart.cj:118`：X 轴传 `(plot.right, plot.x)`，Y 轴传 `(plot.y, plot.bottom)`。EcdfChart 两处都传反：`LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())` 使最小值落在 `plot.right`、最大值落在 `plot.x`；`LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)` 使 yMin 落在顶部。
- **描述**：所有 x 值、y 值、`drawXAxisNumeric`（195）与 `drawYAxis`（164）的刻度位置都用这两个 scale，于是 ECDF 曲线、起始竖线（175）和两轴刻度一起被点对称翻转：累积频率从左上向右下递减，x 轴刻度从右往左递增。现有测试只统计 `class="ecdf-line"` 出现次数（`EcdfChart_test.cj:54-56`）与文本包含关系（60-65），不校验坐标，因此测不到。
- **建议**：改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)` 与 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`；补一条坐标断言用例（如 `yScale.scale(yMax)` 必须等于 `frame.plot.y`）。

### [一般][存量] `ecdf` 阶梯路径缺少最后一段跃升，曲线止于 `(n-1)/n` 而非 1

- **位置**：`f_chart/src/EcdfChart.cj:178-186`（`position + 1 < points.size` 条件在 182 行）
- **来源**：存量（`2845ac7dca`）
- **判据**：review-checklist §11（边界差一 / 与规格冲突）；承诺源 `f_chart/doc/chart-json-spec.md:966`（「实现排序后绘制阶梯累计频率」）
- **证据**：静态确定 —— `ecdfPoints` 返回 `points[i] = (x_i, (i+1)/n)`（`EcdfChart.cj:208-210`）。路径先 `M (x0, yMin)`、`V y_0`，随后每个 `position` 只画 `H x_i` 并在 `position+1 < size` 时补 `V y_{i+1}`。最后一个下标 `n-1` 只画到 `H x_{n-1}`，没有对应的 `V y_n = 1.0`，路径终点为 `(x_last, (n-1)/n)`。
- **描述**：n≥2 时 ECDF 都画不到 100%，曲线顶端恒缺一级台阶（n=1 恰好由开头的 `V firstY` 补上，属侥幸正确）；读图会把最大值处的累计频率低估 `1/n`。
- **建议**：循环结束后补 `path.append(" V ${formatSvgNumber(yScale.scale(points[points.size - 1][1]))}")`；或把循环改为「先 H 到 x_i，再 V 到 y_i」的统一步骤并补上首个 `V`。补一条 `n=3` 的路径断言（末尾 `V` 值等于 `yScale.scale(1.0)`）。

### [一般][存量] `error-bar` 线性/时间 X 轴比例尺实参同向颠倒

- **位置**：`f_chart/src/ErrorBarChart.cj:172`
- **来源**：存量（`git blame` 指向 `7477fb9c22`，2026-11-08 16:59）
- **判据**：review-checklist §10（坐标边界）/ §11（契约与实现不符）
- **证据**：静态确定 —— `LinearScale(xRange[0], xRange[1], frame.plot.x, frame.plot.right())`，与 `ChartScale.cj:22` 的约定相反，也与同模块横向数值轴写法（`DumbbellChart.cj:133`、`BulletChart.cj:154`）相反。类别轴分支不受影响（`BandScale`，174 行），只有 `xAxis.type` 为 `linear`/`time` 时命中。
- **描述**：连续 X 轴下误差线与中心点位置整体镜像（x 越大越靠左），`drawXAxisNumeric`（225）的刻度也反向递增。测试 `supportsNumericX` / `supportsTimeX`（`ErrorBarChart_test.cj:90-125`）只统计元素个数，无法发现。
- **建议**：改为 `LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)`；补一条 `x=10` 必须落在 `x=20` 左侧的坐标断言。

### [一般][存量] `dumbbell` 把 X 比例尺传给 `drawYAxis`，左侧数值刻度与网格线错位越界

- **位置**：`f_chart/src/DumbbellChart.cj:152`
- **来源**：存量（`git blame` 指向 `dd85af4fc7`，2026-11-08 19:53）
- **判据**：review-checklist §10（布局正确性）/ §11（与规格冲突）；承诺源 `f_chart/doc/chart-json-spec.md:502`（哑铃图 `yAxis.type` 为 `category`）
- **证据**：静态确定 —— `ChartFrame.drawYAxis`（`ChartFrame.cj:168-202`）用 `y := scale.scale(tick)` 定位，并固定画在 `plot.x - 8`；第 152 行传入的是第 133 行的水平 `xScale`（值域 → 像素在 `plot.x..plot.right`）。样例 `min=0,max=100` 时刻度 y 落在约 `plot.right..plot.x`（≈776..100），远超 `plot.y..plot.bottom`（≈40..430）。对照同样画横向数值轴的 `HorizontalBarChart.cj:105-112`，它是手工用 `xScale` 画竖网格、不调 `drawYAxis`。
- **描述**：画布左侧出现一串属于 X 轴的数字刻度（位置随机、多数落到绘图区外），同时 `yAxis.grid` 默认 `true`（`ChartConfig.cj:213`）会画出位置无意义的横网格线；168-178 行正确的类目标签与这批错位刻度重叠，输出图形明显破版。测试 `drawsAxes`（`DumbbellChart_test.cj:73-78`）只断言 `svg.contains("100")`，测不到位置。
- **建议**：删除第 152 行；若需要网格，按 `xScale` 画竖线（照 `HorizontalBarChart.cj:105-112`）或改用 `drawXAxisNumeric` 自带的刻度。

### [一般][存量] `donut` 单扇区（100%）用圆弧闭合，起终点重合导致整圆不渲染

- **位置**：`f_chart/src/DonutChart.cj:108-123`（拼路径在 116-119）
- **来源**：存量（`git blame` 指向 `3919464d7d`，2026-11-08 16:29）
- **判据**：review-checklist §10（渲染正确性）/ §11（边界：占比恰为 1）；承诺源 `f_chart/doc/chart-json-spec.md:1272-1274`（「环形图」）
- **证据**：静态确定 —— `fractions[index] * 360.0` 在单数据项时为 `360.0`，`endAngle = angle + 360`，于是 `startX/startY` 与 `endX/endY` 完全相同；SVG 规范中起终点重合的 `A` 弧命令被忽略，剩下的 `M 圆心 L 起点 … Z` 只形成一条退化三角形。
- **描述**：`data` 只有一项（如 `[{"name":"全部","value":100}]`）时，环形图只剩圆心到圆周的一条细线，`donut-hole` 圆也照常画在白底上，用户看到的是空白画布。现有用例 `drawsSlicesAndHole`（`DonutChart_test.cj:59-63`）用 4 个扇区，覆盖不到。同样的写法出现在 `PieChart.cj:114-147`（范围外提示，同一根因）。
- **建议**：`sweep >= 359.999` 时改用整圆：`<circle cx cy r>` + 内孔（或两条 180° 弧）。测试补一条单扇区用例，断言存在 `circle`（或两条 `A` 弧）。

### [一般][存量] `differential-flame` 根节点 `value2=0` 时宽度全部为 0，整图静默空白

- **位置**：`f_chart/src/DifferentialFlameChart.cj:157-158`（`rootWidth` 回退）、`f_chart/src/DifferentialFlameChart.cj:214-222`（宽度只按 `value2` 计算，216 行）
- **来源**：存量（`2845ac7dca` 同批，当前行 blame 为 `dd85af4fc7`）
- **判据**：review-checklist §11（静默失效 / 分支只做了一半）
- **证据**：静态确定 —— 校验允许「`value1>0 且 value2=0`」（93-98 只要求两者非负、至少一个大于 0），并校验 `child2 <= node.value2`（195-198），因此一个「全部删除」的差分树（根 `value1=100,value2=0`）是合法输入。此时 `rootWidth` 回退到 `value1`（157），而 `layoutNode` 的 `node.width = node.value2 / rootWidth * plotWidth`（216）仍用 `value2`，所有节点 width 均为 0；`drawNode` 的标签条件 `width > 文本宽 + 6`（242）也不成立，图上什么都不画，也不报错。
- **描述**：全部帧都减少的差分火焰图输出为空白（仅背景+标题），用户无法区分「没数据」与「全部归零」。
- **建议**：宽度与 `rootWidth` 使用同一口径——要么都用 `max(value1, value2)`（推荐，能画出被删除的宽度并用颜色表达），要么在 `value2=0` 时直接抛 `InvalidValue`。补一条「全部减少」用例断言 rect 宽度之和 > 0。

### [一般][存量] 火焰图四趟递归遍历深度等于节点层数且无上限，深链输入会栈溢出

- **位置**：`f_chart/src/FlameChart.cj:111`（`validateValues`）、`:112`（`assignDepth`）、`:140`（`layoutNode`）、`:152`（`drawNode`），递归体分别在 `:181-183`、`:191-193`、`:200-203`、`:245-247`；`f_chart/src/DifferentialFlameChart.cj:119`、`:120`、`:158`、`:170`，递归体在 `:199-201`、`:209-211`、`:218-221`、`:256-258`
- **来源**：存量（`2845ac7dca`）
- **判据**：review-checklist §4（无界递归：树遍历深度由输入决定）
- **证据**：静态确定（深度无上限）+ 需实测（溢出阈值）—— 递归深度 = 根到最深叶的层数，`nodes` 的层级与个数完全由 JSON 决定；唯一守卫是 `depth > total`（`FlameChart.cj:168`、`DifferentialFlameChart.cj:186`），而 `total = parsed.size`，对一条 N 层链式 `parent` 来说 `depth` 从 0 递增到 N-1，永远不满足 `> total`，守卫不构成深度上限。按每帧约 100–200 B、常见 1 MB 栈估算，约 5k–10k 层即可耗尽，具体阈值需实测。
- **描述**：构造 N 层链的 `nodes`（N 取 1 万即可）时，四个递归函数依次下钻，`validateValues` 先在栈上崩溃（进程级崩溃，非异常）。模块内无 `maxDepth`/节点数上限，`offline-flame` 的 `maxDepth` 也没有出现在这两张图上。
- **建议**：改为显式栈迭代（建树用队列，depth/layout/draw 用后序+层序），或在解析阶段限制层数（如 `maxDepth` 默认 64，超出抛 `InvalidValue`）并给 `nodes.size` 一个上限。测试补一条 2000 层链的用例断言不崩溃。

### [轻微][存量] 轴范围推导与图例装配样板在 6 张图里各写一遍，填充比例已出现漂移

- **位置**：范围推导 `DensityChart.cj:102-138`、`DotChart.cj:216-265`、`DotStripChart.cj:101-123`、`DumbbellChart.cj:90-110`、`EcdfChart.cj:90-104`、`ErrorBarChart.cj:241-289`；图例装配 `DensityChart.cj:212-221`、`DotChart.cj:94-103`、`DotStripChart.cj:158-164`、`EcdfChart.cj:157-163`
- **来源**：存量（各文件引入 commit）
- **判据**：review-checklist §2（换算复制 / 近似重复）
- **证据**：静态确定 —— 六处函数体压成摘要后完全同构：「遍历数据求 min/max → span<=0 时置 1 → 两端按比例外扩 → `axis.min`/`axis.max` 覆盖 → `max<=min` 抛错」，差异只有外扩比例（0.02 / 0.05 / 0.08）与错误路径文案；四处图例装配同构：「逐系列取 name 与 `color ?? colorAt(i)` → `drawLegend`」。
- **描述**：目前外扩比例的差异没有业务依据（同一「留白」语义三种系数），后续改边界规则要同时改六处，容易再漂移；图例装配重复使得「系列颜色是否与图元同源」这类一致性问题要逐图核对（参见 part27 的 ComboChart 颜色不一致问题）。
- **建议**：在 `ChartScale.cj` 增加 `chartAxisRange(dataMin, dataMax, padRatio, axis, path): Array<Float64>`（或返回 struct），在 `ChartFrame` 增加 `drawSeriesLegend(kit, names, colors, visible)`；外扩比例作为显式参数，语义差异参数化而不是复制。合并前先确认六处错误文案/路径是否需要保持各自 `series[0].data` 形式。

### [轻微][存量] `ErrorBarPoint.label` 只写不读，连续轴分支的 `label` 计算是死赋值

- **位置**：`f_chart/src/ErrorBarChart.cj:24`（字段）、`:31`（构造赋值）、`:94`（连续轴分支赋值，之后无读取）
- **来源**：存量（`7477fb9c22`）
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— 全文件 `\.label` 只在 31 行赋值命中（`grep -n "\.label" ErrorBarChart.cj`）；绘制循环 197-220 只用 `point.x/y/low/high`，类目文案统一取 `categoryLabels`（223）。94 行的 `label = chartFormatTick(...)` 之后无任何读取。
- **描述**：`label` 字段对类目轴无用途（类目标签来自 `xAxis.labels`/数据顺序），连续轴写入的格式化文本也从不输出；属于兼容残留，误导读者以为点标签会参与绘制。
- **建议**：删除 `ErrorBarPoint.label` 与 94 行赋值；若确实想画点标签，则在 197-220 里真正使用它并加用例。

### [轻微][存量] `ecdf` 的 `points.isEmpty()` 分支不可达

- **位置**：`f_chart/src/EcdfChart.cj:168-170`
- **来源**：存量（`2845ac7dca`）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— 57-61 行已保证每个 `series[].data` 非空，`ecdfPoints` 仅在 `count == 0` 时返回空（`EcdfChart.cj:205-207`），因此 `points.isEmpty()` 恒假。
- **描述**：防御性分支不会执行，且会让人误以为「空数据是允许的」——实际空数据在 59-61 行就抛错，两处语义矛盾。
- **建议**：删除该分支，或把空数据改成「跳过该系列」并把 59-61 行的报错一并去掉，两处只保留一种语义。

### [轻微][存量] `dot` 允许空 `data`，与其他图「数据不能为空」的契约不一致

- **位置**：`f_chart/src/DotChart.cj:44-48`（只校验 `series` 非空）、`:162-172`（`data` 允许为空数组）
- **来源**：存量（`git blame` 见文件引入 commit）
- **判据**：review-checklist §11（契约不一致 / 缺少边界校验）
- **证据**：静态确定 —— 同批实现均对空数据报 `InvalidValue`：`DensityChart.cj:67-69`、`DonutChart.cj:48-50`、`DotStripChart.cj:60-62`、`EcdfChart.cj:59-61`、`ErrorBarChart.cj:65-67`、`FlameChart.cj:55-57`；DotChart 无此检查，`resolveLabels` 得到 0 个标签（188-203），`BandScale(…, 0)` 的 `bandWidth` 为 0（`ChartScale.cj:57`），最终只画坐标轴与网格后正常返回。
- **描述**：同样的空数据，`dot` 静默输出空图、其他图抛 `ChartException`，调用方按统一错误处理时会漏掉这一类输入。
- **建议**：在 `parseSeries` 后加「任一 `values.isEmpty()` 抛 `chartInvalidValue("series[i].data", "数据不能为空")`」，与其他图对齐；若确认空图是刻意行为，则在规格里写明并补用例。

### [轻微][存量] `dot` 的 stem 基线固定取 0，0 不在 X 范围时限段越出绘图区

- **位置**：`f_chart/src/DotChart.cj:113`（`baseline = xScale.scale(0.0)`）、`:126-129`（从 `baseline` 画到 `valueX`）
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— `resolveRange` 在数据全为正时把 minimum 设为 0（243-247），此时基线正好在 `plot.x`；但用户显式 `xAxis.min > 0`（如 50）时，`xScale.scale(0.0)` 落在 `plot.x` 左侧（`scale` 无裁剪，`ChartScale.cj:36-43`），stem 从绘图区外画进来。
- **描述**：`xAxis.min=50` 之类的输入下，点图的牵引线穿过左边距压到类目标签上；无 `clipPath`，越界部分正常渲染。
- **建议**：基线改为 `maxFloat(xScale.scale(0.0), frame.plot.x)`，或按 `min(max(value, range.min), range.max)` 把基线夹到值域内；与 `HorizontalBarChart.cj:113` 的同类写法一起统一。

### [轻微][存量] `donut` 半径可为负，画布过窄时输出非法路径

- **位置**：`f_chart/src/DonutChart.cj:102-105`（半径公式）、`:141-144`（内孔圆）
- **来源**：存量（`3919464d7d`）
- **判据**：review-checklist §11（边界 / 数值）
- **证据**：静态确定 —— `radius = min(w-left-right, h-top-bottom-40)/2 - 20`，`ChartConfig` 只校验 `width/height > 0`（`ChartConfig.cj:180-184`）。`width=60`（默认 padding 24）时 `min(12, …)/2 - 20 = -14`，`A -14 -14 …` 与 `circle r="-14"` 都是非法 SVG；`innerRadius=0.55` 时内孔半径为负。
- **描述**：小画布输入不报错但产出渲染器无法解释的路径（多数渲染器直接丢弃该元素），用户得到空白环形图。
- **建议**：`radius` 计算后 `if (radius <= 0.0) throw chartInvalidValue("width", "画布过小，无法绘制环形图")`，或把下限夹到 `1.0` 并缩小内孔；`PieChart.cj:109-113` 有同一公式（范围外提示）。

### [轻微][存量] 本部分 10 个测试只统计 class 出现次数，未断言任何坐标，轴方向类缺陷全部漏检

- **位置**：`EcdfChart_test.cj:54-65`、`DumbbellChart_test.cj:73-78`、`ErrorBarChart_test.cj:90-125`、`DotChart_test.cj:41-53`，以及同批其余 `*_test.cj` 的 `count()` 断言
- **来源**：存量
- **判据**：review-checklist §11（测试未覆盖契约）/ §14.1（半成品）
- **证据**：静态确定 —— 本部分 10 个测试文件共用同一 `count(svg, needle)` 助手，断言形式只有「class 出现 N 次」「svg.contains(文本)」「两次输出相等」「SvgParser 可解析」四类，没有任何 `transform`/`x=`/`y=` 数值断言；上面 4 条轴/几何缺陷（EcdfChart 两条、ErrorBarChart、DumbbellChart）因此全部通过。
- **描述**：渲染类图表的契约核心是坐标，当前测试只能保证「元素存在」，无法防住镜像、越界、退化弧。
- **建议**：为每张图补 1-2 条坐标断言（如取 `class="dumbbell-high"` 的 `cx`，断言 high>low 时 `cx` 更大），或引入 SVG 快照测试（`ChartGallery_test.cj` 已有全量渲染入口，可作为快照来源）。

存量缺陷共 14 条（一般 7 / 轻微 7），是否纳入修复待用户决定。

<!-- 第 29 部分 -->

### [严重][存量] `gain` / `forest` 的 `LinearScale` 入参顺序颠倒，整图镜像（坐标轴方向反了）

- **位置**：`f_chart/src/GainChart.cj:125-126`（x、y 两个比例尺都反）、`f_chart/src/ForestChart.cj:183-184`（x 轴反）；同根因另见 `f_chart/src/LiftChart.cj:134-135`（范围外，供合并）
- **来源**：存量（`git blame -L 125,126 GainChart.cj` → `796b46a90` 2026-11-08「feat(f_chart): M95 增益图」）
- **判据**：review-checklist §10（正确性：坐标换算）/ §11（语义与命名、契约不符）
- **证据**：静态确定 —— `LinearScale` 的语义由 `f_chart/src/ChartScale.cj:22-43` 定义：第 3 个实参 `topPixel` 对应**最大值**、第 4 个 `bottomPixel` 对应最小值（`scale(v) = bottomPixel - (v-min)/span*(bottomPixel-topPixel)`）。同模块正确写法见 `f_chart/src/BarRenderer.cj:91`（y：`plot.y, plot.bottom()` ⇒ 大值在上）与 `f_chart/src/GanttChart.cj:105`（x：`plot.right(), plot.x` ⇒ 时间向右递增）。`GainChart` 写成 `LinearScale(xMin, xMax, plot.x, plot.right())` ⇒ xMax 落在左侧，`LinearScale(yMin, yMax, plot.bottom(), plot.y)` ⇒ yMax 落在**下方**，两轴同时反向，整图相当于旋转 180°
- **描述**：`gain` 图的样本比例轴从左到右递减、捕获比例轴从上到下递增，数据点、折线、对角基准线、刻度标签全部镜像；典型输入（`x:1.0, y:1.0`）画在左下角而非右上角，读图会得出相反结论。`forest` 的 `unitScale`（183 行）同构，置信区间、无效线与刻度整体左右翻转（0.1 画在右端、10 画在左端）。现有用例（`GainChart_test.cj`、`ForestChart_test.cj`）只数 `class` 出现次数，没有任何坐标断言，因此测不到
- **建议**：`GainChart` 改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)`、`LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`；`ForestChart` 的 `unitScale` 改为 `LinearScale(0.0, 1.0, frame.plot.right(), frame.plot.x)`。同时给 `LinearScale` 的构造参数改名（`maxPixel` / `minPixel`）并补一条几何断言用例（如「x=最大值 的像素 > x=最小值 的像素」），避免同类复制再犯

### [严重][存量] `heat-flame` 四个递归函数深度由输入决定且无上限，深链输入栈溢出

- **位置**：`f_chart/src/HeatFlameChart.cj:190-204`（`validateValues`）、`:206-214`（`assignDepth`）、`:216-224`（`layoutNode`）、`:226-256`（`drawNode`，递归在 `:253-255`）；调用点 `:127-128`、`:165`
- **来源**：存量（`git blame -L 190,193 HeatFlameChart.cj` → `4c9b402e3c` 2026-11-08）
- **判据**：review-checklist §4（无界递归：深度由输入决定）
- **证据**：静态确定（深度无上限）+ 需实测（溢出阈值）—— 递归深度 = 从根到最深叶的层数 = 最长 `parent` 链长度，上界是 `nodes` 数组长度，而 `nodes` 长度完全由 JSON 输入决定，模块内既无节点数上限也无层数上限，四个函数都不是迭代改写。唯一的守卫 `depth > total`（191、207）按本报告下一条已证明恒假，起不到限制作用
- **描述**：输入一条 1 万层、每层单子节点的 `parent` 链（合法输入：根 + 逐层 `parent` 指向上一层，`value` 递增即可通过 `validateValues` 的和校验）时，`validateValues` 先在 1 万层深度处耗尽栈帧，进程直接崩溃而不是抛 `ChartException`；`layoutNode` / `drawNode` 同深度。仓颉不保证尾调用优化，三个函数也都不是尾递归
- **建议**：改为显式栈迭代（后序算和、层序算 depth/x/width、层序绘制），或在解析阶段限制层数（如 `maxDepth` 默认 64）与节点数（如 5000），超限抛 `chartInvalidValue`，并把上限写进 `doc/chart-json-spec.md`；同根因的 `FlameChart.cj:167-206`、`DifferentialFlameChart.cj:185-224` 应一并修

### [一般][存量] `gain` 文档承诺的 `baseline` 字段未被读取，对角基准线未必等于 y=x

- **位置**：`f_chart/src/GainChart.cj:147-152`（基准线固定取绘图区对角）；承诺源 `f_chart/doc/chart-json-spec.md:1982`（「专属字段：`baseline`（对角线）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现）/ §11（契约与实现不符）
- **证据**：静态确定 —— `grep -n "baseline" f_chart/src/GainChart.cj` 只命中 `className: "gain-baseline"`（151），全文件无 `root.number("baseline")`；`LiftChart.cj:30-33` 有对应的解析与正数校验，可作对照
- **描述**：用户写 `"baseline": 0.5` 不会有任何效果也不报错。另外基准线固定画 `(xMin,yMin)→(xMax,yMax)`，只在两轴范围相同时才等价于 y=x；而 `xAxis.min/max` 与 `yAxis.min/max` 可分别覆盖（75-90），两者不等时这条「无技能基准线」位置错误，增益图的核心判读依据失真
- **建议**：解析并校验 `baseline`（正数），基准线画 `(xMin, baseline)→(xMax, baseline)` 或按 `y=x` 在各自比例尺下投影；若设计上不打算支持该字段，删除规格里的 `baseline` 描述

### [一般][存量] `forest` 校验了 `yAxis.labels` 长度却不用它渲染，配置被静默忽略

- **位置**：`f_chart/src/ForestChart.cj:103-108`（只做长度校验）、`:209-215`（行标签固定取 `row.label`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（读了不用 / 死配置字段）+ §14.1（接线缺失）
- **证据**：静态确定 —— `config.yAxis.labels` 全文件仅出现在 103-106 的校验里；绘制时 210 行传入的是 `row.label`。`ForestChart_test.cj:47` 的样例里 `yAxis.labels` 与 `data[].label` 恰好同名同序，掩盖了差异
- **描述**：用户想用 `yAxis.labels` 重命名或缩短行标签（长研究名常用缩写）时毫无效果，只会因长度不一致收到一条报错；字段语义「校验但不生效」属于半接线
- **建议**：绘制时优先用 `config.yAxis.labels[rowIndex]`（非空时），为空再回退 `row.label`；或按 §13 把该字段从 forest 小节删掉，只保留 `data[].label`

### [一般][存量] `forestLogTicks` 无迭代上限，`logBase` 接近 1 时刻度数爆炸

- **位置**：`f_chart/src/ForestChart.cj:236-254`（指数区间 242-243，循环 245-251）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.4（低效算法：循环次数由入参放大）/ §11（缺少边界校验）
- **证据**：静态确定 —— 循环次数 = `floor(log(max)/log(base)) - ceil(log(min)/log(base)) + 1`，只校验 `base > 1.0`（237）。取 `min=0.1, max=10, base=1.0000001` 得约 4.6e7 次 `pow` + 比较；同模块的 `chartNiceTicks`（`ChartScale.cj:98-103`）有 `guard < 1000` 上限，本函数没有
- **描述**：`{"xAxis":{"type":"log","logBase":1.0000001}}` 这类看似合法的配置会让单次 `draw` 卡住数十秒（每次还会向 `ticks` 追加元素，刻度数同时膨胀到千万级，标签绘制也随之后移）；无拒绝路径，只能靠调用方超时
- **建议**：给 `logBase` 加下限（如 `>= 1.01`，否则 `chartInvalidValue`），并给循环加与 `chartNiceTicks` 一致的 `guard` 上限（如 1000）；两者都触发时抛明确异常

### [一般][存量] `forest` 对数轴不校验自定义刻度值，非正刻度导致 `SvgException` 泄漏

- **位置**：`f_chart/src/ForestChart.cj:128-130`（只校验 `xMin`/`dataMin`）、`:135-147`（`config.xAxis.values` 直接当刻度）、`:221-227`（`forestLogPosition` 取 `log(value)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理 / 契约不符）；契约源 `f_chart/src/Chart.cj:33`（`@throws ChartException 输入结构或数值不合法时抛出`）
- **证据**：静态确定 —— 输入 `{"xAxis":{"type":"log","values":[0,1,10]}}` 时 `position(0, …)` 计算 `log(0) = -inf`，`unitScale.scale(-inf) = +inf`，随后 `drawXAxisNumeric` → `kit.text` → `formatSvgNumber` 在 `f_svg/src/SvgNumber.cj:33-35` 抛 `SvgException`（不是 `ChartException`）
- **描述**：前端只按 `ChartException` 捕获时会漏掉这条路径，异常类型从 `SvgException` 冒出，错误信息也不带 `xAxis.values[i]` 路径，无法定位到具体刻度
- **建议**：解析 `xAxis.values` 后逐项校验（`isLog` 时要求 `> 0`），抛带下标的 `chartInvalidValue("xAxis.values[i]", …)`；或在 `position()` 内对 `value <= 0` 直接抛 `chartInvalidValue`

### [一般][存量] `gantt` 重复 `task.id` 静默覆盖，依赖箭头指向错误任务

- **位置**：`f_chart/src/GanttChart.cj:63-66`（建 `taskIndex` 时无查重）、`:67-76`（依赖校验只查存在性）
- **来源**：存量
- **判据**：review-checklist §11（静默数据错误）/ §10（缺少边界校验）
- **证据**：静态确定 —— `taskIndex[tasks[index].id] = index` 后写覆盖前写，无 `contains` 判断也无报错；同模块 `Flowchart.cj:91-97` 对节点 id 做了重复校验，`HeatFlameChart.cj:78-82` 同样做校验，只有 `gantt` 漏掉
- **描述**：两个任务同名 `id` 时，所有 `dependsOn` 指向它都会解析到**后一个**任务，依赖折线与箭头连到错误行；后一个任务的任务条还会覆盖前一个的进度渲染，用户无法从输出看出输入有歧义
- **建议**：建索引前用 `if (taskIndex.contains(id)) throw chartInvalidValue("tasks[${index}].id", "任务 id 重复")`，与 `Flowchart` 保持一致；补一条重复 id 的负向用例

### [一般][存量] `gantt` 未实现规格承诺的 `lane`，全部任务挤在单列

- **位置**：`f_chart/src/GanttChart.cj:184-210`（`parseTasks` 不读 `lane`）、`:125-154`（`rowHeight = plot.height / tasks.size`，单列排布）；承诺源 `f_chart/doc/chart-json-spec.md:2142`（`tasks: [{…, lane?, color?}]`）与 `:2151-2157`（示例 `lane` 分组为「需求/设计/开发/测试/上线」）
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现 / 只做了一半）
- **证据**：静态确定 —— `grep -n "lane" f_chart/src/GanttChart.cj` 零命中；`GanttTask`（23-49）无 `lane` 字段；行位置完全由数组下标决定（129、161）
- **描述**：规格示例（5 个任务分 5 条泳道）按当前实现会变成 5 行逐行排列、泳道标签（`yAxis.labels`）也不出现，与文档图意不符；用户按文档组织数据得不到对应视觉结构
- **建议**：`parseTasks` 读入 `lane`，用「lane → 行号」映射决定 `centerY`（无 `lane` 时回退数组下标），并在规格中明确 `lane` 多任务同行的行高分配规则；若不实现则应从规格删除 `lane` 与示例

### [一般][存量] `gauge` 阈值未覆盖到 `max` 时留下空白扇段

- **位置**：`f_chart/src/GaugeChart.cj:136-149`（循环只画 `[bandStart, bandEnd]`，无收尾段）
- **来源**：存量
- **判据**：review-checklist §10（渲染完整性）/ §11（契约与实现不符）
- **证据**：静态确定 —— `bandStart` 从 `startAngle` 起，每次 `bandEnd = gaugeAngleForValue(threshold.value, …)` 后 `bandStart = bandEnd`；循环结束后不再画 `[last, endAngle]`。`thresholds` 只要求严格递增且 `<= max`（64-69），不要求末项等于 `max`；规格 `doc/chart-json-spec.md:2577-2599` 也未要求
- **描述**：`thresholds: [{value:60},{value:85}]`（max=100）时 85–100 区间没有任何色带，仪表盘出现缺口；缺口宽度随量程变化，容易被误读成「数据缺失」
- **建议**：循环后补一段 `gaugeArcPath(…, bandStart, endAngle)`，用最后一个阈值色或统一的「超阈值色」填充；或在解析时要求 `末项 value == max`，否则抛 `chartInvalidValue`

### [一般][存量] `heat-flame` 环/不可达节点被静默丢弃，两处「存在环」守卫恒不可达

- **位置**：`f_chart/src/HeatFlameChart.cj:111-128`（建树 + 只校验根数量）、`:190-193` 与 `:206-209`（`depth > total` 守卫）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）+ §11（静默数据错误）
- **证据**：静态确定 —— 每个节点只有一个 `parent`，`roots.size == 1` 要求全图恰有一个无父节点；环上每个节点都有父节点，因此环必然是**与根不相连的独立分量**，`validateValues`/`assignDepth` 只沿根可达子树下钻，深度上界 `<= nodes.size - 1 < total`，`depth > total` 恒假。环分量既不参与布局与绘制，也不报错
- **描述**：输入 `root(parent=null)`、`b(parent=c)`、`c(parent=b)` 时 `b`、`c` 整块消失（不渲染、不计入 `validateValues` 的子节点和校验），用户看到「少了两块」而没有任何提示；两处环检测代码实际是死分支
- **建议**：解析阶段用父链查环（沿 `parent` 上溯计数，超过 `nodes.size` 判环）或用 `HashSet` 做访问标记，并在建树后校验「可达节点数 == nodes.size」，不满足抛 `chartInvalidValue`；把 `depth > total` 换成这条可达性校验，同时补一条环输入用例

### [一般][存量] `funnel` 层高可为负，矮画布 + 多阶段生成非法 rect 与重叠文本

- **位置**：`f_chart/src/FunnelChart.cj:105-117`（`top`/`bottom`/`stageHeight` 计算，矩形在 113-117）
- **来源**：存量
- **判据**：review-checklist §11（边界：负数尺寸）/ §10（缺少边界校验）
- **证据**：静态确定 —— `top = padding.top + 60`、`bottom = height - padding.bottom - 30`、`stageHeight = (bottom - top - gap*(n-1)) / n`；只有 `width/height > 0`（`ChartConfig.cj:182-183`）与 `gap >= 0`（81-83）被校验，`stageHeight <= 0` 无校验。例：`height=100`（padding 默认 24）⇒ `bottom-top = 46-84 = -38`，3 个阶段时 `stageHeight ≈ -14.7`
- **描述**：`rect` 高度为负（SVG 渲染器按无效/反向处理，多数浏览器丢弃），阶段名与转化率文本挤在同一位置或落到画布外；用户只看到空白漏斗
- **建议**：计算后校验 `stageHeight > 0`（并给出「画布高度不足或阶段过多」的路径化错误），或按阶段数自适应压缩 `gap` / 缩小 60px 的头部预留

### [一般][存量] 地图类（`flow-map` / `heat-map`）的 viewBox、底图、标题绘制整段重复

- **位置**：`f_chart/src/FlowMapChart.cj:62-75` ↔ `f_chart/src/HeatMap.cj:43-56`（viewBox 解析与校验逐行同构）；`FlowMapChart.cj:161-191` ↔ `HeatMap.cj:122-152`（背景矩形 + 标题 + `regions[].path` 底图绘制）；`FlowMapChart.cj:77-101` ↔ `HeatMap.cj:62-77`（regions 解析，前者多 id 去重与质心计算）
- **来源**：存量
- **判据**：review-checklist §2（跨层/跨文件复制：同一套校验与绘制散落多处）
- **证据**：静态确定 —— 两段 viewBox 代码除变量作用域外完全一致（`size != 4 || [2] <= 0 || [3] <= 0` 判定与三条错误文案相同）；底图段同样顺序调用 `kit.rect/viewBox` → `kit.text(title)` → 遍历 `regions` 画 `#f0f0f0` 填充 + `#cccccc` 描边的 path
- **描述**：新增地图类型（`choropleth` / `cartogram` / `dot-density-map`）时又要复制一遍，改一处漏一处；例如后来 `choropleth` 已经用了另一套；同时「regions 必须至少一个」「id 去重」「质心缓存」只有 `flow-map` 有，`heat-map` 无，行为已经漂移
- **建议**：抽 `MapCanvas`（内部 `viewBox` 解析 + `drawBaseMap(kit, regions)` + `drawTitle`）到 `ChartFrame.cj` 或新 `MapSupport.cj`，`flow-map` 仅保留 flows 部分；regions 解析统一成 `Array<MapRegion>`（id/name/path/center 可选，按需计算质心）

### [一般][存量] 火焰图三处实现逐行同构（`heat-flame` / `flame` / `differential-flame`）

- **位置**：`f_chart/src/HeatFlameChart.cj:64-128`（节点解析 + 建树 + 校验调用）与 `:181-256`（findNode / validateValues / assignDepth / layoutNode / drawNode）；对照 `f_chart/src/FlameChart.cj:58-112`、`:158-248`；`f_chart/src/DifferentialFlameChart.cj:176-224`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名：`FlameNode` → `HeatFlameNode`）
- **证据**：静态确定 —— `validateValues`（HeatFlameChart 190-204 vs FlameChart 167-184）、`assignDepth`（206-214 vs 186-194）、`layoutNode`（216-224 vs 196-204）除节点类型与字段外逐行一致；`drawNode` 仅在 `colorBy`/`ratio` 取值上不同；`findNode` 只有返回类型不同
- **描述**：三份（含 `OfflineFlameChart` / `TuiFlameChart` 变体）同构代码各自维护，`validateValues` 的环检测、`layoutNode` 的宽度累加、`drawNode` 的标签阈值判断任何一处修 bug 都要改三遍；本文上一条的栈溢出与静默丢节点缺陷也因此同时存在于三处
- **建议**：抽「火焰树模型 + 布局」到 `FlameLayout.cj`（`parseFlameNodes` / `validateFlameTree` / `layoutFlame`），颜色与绘制差异以策略参数（`heatField` / `ratioSource` / `colorMode`）传入；`heat-flame` 只保留热力取色

### [一般][存量] `gain` 与 `lift` 曲线主体逐行同构，已出现行为漂移

- **位置**：`f_chart/src/GainChart.cj:30-61`（series 校验 + `{x,y}` 解析）↔ `f_chart/src/LiftChart.cj:34-65`；`GainChart.cj:154-180`（折线 + 点）↔ `LiftChart.cj:170-196`；同用 `volcanoNumber` / `sortLiftPoints`
- **来源**：存量
- **判据**：review-checklist §2（只改图名 / 字面量复制）
- **证据**：静态确定 —— 两段 series 解析除错误文案里的「增益图/提升图」外完全一致；折线路径拼接与散点循环（`M … L …` + `circle 3.5`）除 class 名（`gain-line`/`lift-line`）外一致。差异只有基线画法（对角 vs 水平 `baseline`）、右留白（`LiftChart.cj:130-133` 传 `rightLabelWidth: 40.0`）与 y 轴留白策略
- **描述**：同一能力的两个图各写 150 行，已经漂移：`lift` 有基线数值标签与右留白，`gain` 没有；`lift` 的 y 范围带 8% 留白，`gain` 强制两轴同一范围。后续修比例尺（本报告第一条）要改两处、容易漏
- **建议**：抽 `LineSeriesRenderer`（series 解析 + 比例尺 + 折线/点 + 轴），把「基线类型（水平/对角）」「轴范围策略」「右留白」作为参数；参照已有的 `BarRenderer.cj` 分层

### [轻微][存量] `heatFlameColor` 两个分支不可达，且只使用前三个颜色

- **位置**：`f_chart/src/HeatFlameChart.cj:260-283`（`colors.isEmpty()` 261-263、`colors.size == 1` 274-276）；调用点 `HeatFlameChart.cj:134-136`、`HeatMap.cj:108-110`、`CartogramChart.cj:116-118`、`ChoroplethChart.cj:107-109`、`ConfusionMatrixChart.cj:127`（字面量 2 色）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）/ §11（静默忽略入参）
- **证据**：静态确定 —— 五个调用点在调用前都保证 `colorRange.size >= 2`（含字面量 `["#e3f2fd","#0d47a1"]`），故 `isEmpty` 与 `size == 1` 两条分支不可达；`size >= 3` 时只取 `colors[0..2]`（272），第 4 个及以后的颜色被静默丢弃
- **描述**：色阶函数名义上支持 0/1/2/3+ 色，实际只有 2 色与 3 色两种生效；调用方传 4 色（如 `calendar-heatmap` 风格的分级色）时不会报错但也不会生效，排查成本高
- **建议**：把契约收窄为「至少 2 色，取前 3 色，>3 抛 `chartInvalidValue`」并在文档写明，删掉两条不可达分支；若确需 N 色分段，改为按 `ratio*(n-1)` 选相邻两色插值

### [轻微][存量] `gain` 的 `span` 计算后从未使用

- **位置**：`f_chart/src/GainChart.cj:71-74`
- **来源**：存量
- **判据**：review-checklist §1（局部变量赋值后不读）
- **证据**：静态确定 —— `grep -n "span" f_chart/src/GainChart.cj` 仅命中 71/72/73 三行；后续 `xMin/xMax` 直接用 `rangeMin/rangeMax`（75-90），`span` 未参与任何表达式
- **描述**：读代码时会误以为坐标范围经过 `span` 修正，实际是纯残留；`LiftChart.cj:85-96` 的 `ySpan` 才是真正参与留白计算的写法
- **建议**：删除 71-74；若本意是「数据范围为 0 时扩成 1」，应改为把 `rangeMin/rangeMax` 按 `span` 扩展，而不是算完丢弃

### [轻微][存量] `Flowchart.parseEdges` 的 `nodes` 参数未使用

- **位置**：`f_chart/src/Flowchart.cj:185-206`（签名在 185），调用点 `:89`
- **来源**：存量
- **判据**：review-checklist §1（无读取的参数）
- **证据**：静态确定 —— 函数体只使用 `root.array("edges")` 与 `json.requiredString`，`nodes` 零引用；节点存在性校验在 `draw` 里用 `idMap` 另做（98-105）
- **描述**：参数暗示「解析边时需要节点信息」，与实现不符；也让人误以为边解析已做端点校验
- **建议**：删掉该参数（调用点同步改），或把 98-105 的端点校验移进来使用它

### [轻微][存量] `FunnelChart` 的 `import std.math.*` 未使用

- **位置**：`f_chart/src/FunnelChart.cj:19`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 全文无 `abs/sqrt/minFloat/maxFloat/pow/log/ceil/floor/sin/cos/round` 调用（`funnelConversion` 只用四则运算，`values[position] / maxValue * maxWidth` 同理）
- **描述**：多余的 import 会掩盖真实依赖，`cjlint` 也会报
- **建议**：删除该行

### [轻微][存量] 数值类型判定与 `jsonNumberValue` 重复（`funnel` / `gauge`）

- **位置**：`f_chart/src/FunnelChart.cj:62-66`、`f_chart/src/GaugeChart.cj:103-107`
- **来源**：存量
- **判据**：review-checklist §2（同一校验两遍，语义相同）
- **证据**：静态确定 —— 两处都先 `if (!(value.kind.isInt || value.kind.isDecimal)) throw chartInvalidValue(…, "期望数字")`，紧接着调用 `jsonNumberValue(value, …)`，而后者（`f_chart/src/ChartJson.cj:215-227`）做的就是同一判定 + 有限数判定
- **描述**：同一条规则两套文案（「期望数字」/「期望数字」一致，但错误路径是否带有限数校验取决于走哪条），后续改文案容易只改一处；`GaugeChart` 的错误文案还写成「数值必须是数字」
- **建议**：删掉显式 `kind` 判断，直接 `jsonNumberValue`；文案统一放在 `ChartJson.cj`

### [轻微][存量] `Flowchart` 未校验 `layout` / `shape` 枚举，未知值静默回退

- **位置**：`f_chart/src/Flowchart.cj:108`（`layout` 任意字符串）、`:320-346`（`shape` 的 `case _ =>` 回退矩形）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验，静默回退）/ §13（`horizontal` 未进规格）
- **证据**：静态确定 —— `layout` 只与 `"manual"`、`"horizontal"` 比较，其它值一律走垂直分层；`shape` 只匹配 `diamond/ellipse/round/parallelogram/document`，未知值画普通矩形。规格 `doc/chart-json-spec.md:2164` 列了 6 种 `shape`，未提 `horizontal`
- **描述**：拼写错误（`"HORIZONTAL"`、`"diamnod"`）不报错也不提示，图静默变成另一种形态，排障只能靠肉眼比对
- **建议**：解析时校验枚举并抛 `chartInvalidValue("nodes[i].shape", "期望 rect/round/diamond/ellipse/parallelogram/document")`、`("layout", "期望 vertical/horizontal/manual")`；把 `horizontal` 补进规格

### [轻微][存量] `gauge` 未限制角度跨度 ≤ 360°，超过时弧段语义失真

- **位置**：`f_chart/src/GaugeChart.cj:45-49`（只校验 `startAngle < endAngle`）、`:197-225`（`gaugeArcPath` 单段 `A` 命令）
- **来源**：存量
- **判据**：review-checklist §11（边界校验缺失）
- **证据**：静态确定 —— `endAngle - startAngle` 无上限，`gaugeArcPath` 用一个 `A rx ry 0 largeArc 1 …` 表达整段；SVG 圆弧命令单段最多表达 360°，跨度更大时实际绘制角度小于配置值，`largeArc`（208）也只有 0/1 两种
- **描述**：`startAngle:-400, endAngle:400`（跨度 800°）时图形与指针位置不再对应配置角度，且指针可落在色带之外，读者无法判断真实刻度
- **建议**：校验 `endAngle - startAngle <= 360`（超出抛 `chartInvalidValue`），或将跨度限制在 `(0, 360]` 并文档化

### [轻微][存量] `gauge` 静默忽略多余的 series 与 data 项

- **位置**：`f_chart/src/GaugeChart.cj:83-110`（只取 `seriesItems[0]` 与 `dataItems[0]`）
- **来源**：存量
- **判据**：review-checklist §11（静默丢弃输入）/ §14.1（只处理部分输入）
- **证据**：静态确定 —— 无 `seriesItems.size != 1` 校验（对照 `FunnelChart.cj:39-41`、`ForestChart.cj:58-60`、`GainChart.cj:35-37` 都有），`dataItems.size` 也只判非空
- **描述**：多系列或多数据点时，除第一个外全部被丢弃且无提示；同一份数据换到 `funnel`/`forest` 会报「仅支持 1 个系列」，契约不一致
- **建议**：加 `seriesItems.size == 1` 与 `dataItems.size == 1` 的校验，错误文案与其它单值图统一；若确实要支持多指针，应显式实现而不是静默截断

<!-- 第 30 部分 -->

### [严重][存量] 分箱数无上界，按不可信数值预分配数组 → OOM；乘积溢出时抛非契约异常

- **位置**：`f_chart/src/HistogramChart.cj:167-186`（`resolveBinCount`）、`f_chart/src/HistogramChart.cj:248-251`（按 `binCount` 逐个 `add(0)`）；`f_chart/src/Histogram2DChart.cj:111-123`（`bins` 解析）、`f_chart/src/Histogram2DChart.cj:288-291`（`0..(binsX * binsY)`）
- **来源**：存量（快照模式，`f_chart` 与 `120fd2542` 无差异）
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）
- **证据**：静态确定 —— `resolveBinCount` 只校验 `raw >= 1.0 && raw == floor(raw)`，`parseBinCount` 只校验 `raw < 1.0 || raw != floor(raw)`，两者都无上限；随后直接用该值向上取整地预分配 `Int64` 单元
- **描述**：`bins` 来自图表 JSON 配置（调用方/用户可控）。单个 `Int64` 占 8 字节：`bins=1e8` 一次分配 800MB；`binsX=binsY=1e5` 时 `binsX*binsY=1e10` 项 ≈ 80GB，必然 OOM。另外 `Histogram2DChart.cj:289` 的乘积与 `Int64(raw)` 转换都可能溢出：仓颉默认整数溢出策略是 `@OverflowThrowing`（`docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md:88`），溢出会抛非 `ChartException` 的异常，调用方若按契约只捕 `ChartException` 就会直接失败。
- **建议**：在 `parseBinCount` / `resolveBinCount` 增加硬上限（如单轴 ≤ 1000、`binsX*binsY` ≤ 10000），超限抛 `chartInvalidValue`；乘积前先做上限比较，避免依赖溢出行为；分配改用 `Array<Int64>(n, repeat: 0)` 并确认 `n` 已经过上限校验。

### [一般][存量] 轴范围覆盖数据范围后，图元未按有效范围重算也未裁剪，绘制溢出绘图区

- **位置**：`f_chart/src/HistogramChart.cj:118`（`xScale` 用 `xRange`）与 `:147-161`（柱起点用 `bins.minimum`）；`f_chart/src/Histogram2DChart.cj:166-167`（scale 用 `xRange`/`yRange`）与 `:180-181`、`:194-211`（格坐标用 `result.xMin`/`result.yMin`）；`f_chart/src/HorizontalBarChart.cj:113`（`baseline = xScale.scale(0.0)`）与 `:129-139`；`f_chart/src/LassoPathChart.cj:178-181`（零线 `yScale.scale(0.0)`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释/契约不符、越界绘制）、§10 正确性
- **证据**：静态确定 —— `ChartSvgKit.rect/path/line` 不做裁剪（`ChartSvgKit.cj:36-72`、`:194`）；`SvgBuilder` 对 `clip-path` 只做 `url(...)` 引用校验（`SvgBuilder.cj:317-321`），本部分各图也没有任何裁剪调用；几何量来自数据范围，坐标映射来自可能被 `xAxis.min/max`、`yAxis.min/max` 覆盖的有效范围
- **描述**：例：`histogram` 数据 1..8、`xAxis.min = 5` 时，第 1、2 箱起点 `bins.minimum=1` 经 `xScale` 映射到 `plot.x` 左侧，柱子画进 y 轴标签区甚至画布外；`2d-histogram` 同理（先按数据范围分箱，再用被覆盖的轴范围映射）。`HorizontalBarChart` 固定以 0 为基线，`xAxis.min > 0` 时基线落在 `plot.x` 左侧，所有柱子横向溢出；`LassoPathChart` 的 0 参考线在 `yAxis.min > 0` 时画到绘图区下方，压住 x 轴刻度。这四个图元都会出现在最终 SVG 里，只是位置错误，用户难以判断是数据错还是渲染错。
- **建议**：几何量统一由有效范围推导（分箱/单元格起点用 `xRange[0]`、`yRange[0]`，或把数据裁剪到有效范围内再分箱）；基线/零线取 `clamp(scale(0.0), plot.x, plot.right())`；如需保留溢出可见性，改为显式 clipPath。

### [一般][存量] LearningCurveChart 只对点排序，标准差数组未同步，误差带错位

- **位置**：`f_chart/src/LearningCurveChart.cj:112`（`sortLiftPoints(raw.toArray())`）、`:80-114`（`std` 按 JSON 顺序收集）、`:220-237`（band 用 `item.points[position]` 配 `item.std[position]`）
- **来源**：存量
- **判据**：review-checklist §11（数据错位）、§2（近似重复导致的行为漂移）
- **证据**：静态确定 —— 排序只发生在 `raw` 上，`stdValues` 全程未参与排序，长度校验（`:87-89`）只比 size
- **描述**：规格（`doc/chart-json-spec.md:2025-2031`）只要求 `data` 为 `{x,y}`，未要求按 x 升序。输入乱序时 `points` 被重排而 `std` 保持原序，`shade: true` 画出的上下界与对应点不匹配，`dataMinY/dataMaxY`（`:131-134`）也随之算错。现有用例 `drawsBand` 的数据本身有序，测不出该问题。
- **建议**：把 `(x, y, std)` 作为一条记录一起排序（或对索引数组排序后同时取 points/std），保证 `std` 与点严格配对。

### [一般][存量] 几何参数缺少取值校验，可产生负宽高矩形（SVG 非法，图元静默消失）

- **位置**：`f_chart/src/HeatmapChart.cj:108-111`（`cellGap` 只校验非负）、`f_chart/src/HeatmapChart.cj:157-161`（`cellWidth - cellGap`）；`f_chart/src/HorizontalBarChart.cj:121-139`（`barWidth` 未校验，`barHeight = minFloat(requested, slot*0.95)`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定 —— `cellGap` 无上界，`barWidth` 连 `> 0` 都没判；`ChartSvgKit.rect` 直接把参数写给 `SvgBuilder.rect`（`SvgAuthoringBuilder.cj:115-132`），后者原样 `svgPx(width/height)` 输出，无绝对值/夹取
- **描述**：5 列 800px 画布配 `cellGap: 200` 时 `cellWidth` 已远小于 200（`cellWidth - cellGap < 0`）；`barWidth: -24` 时 `barHeight` 为负。SVG 规范中负 `width`/`height` 非法，浏览器直接丢弃该 `<rect>`，表现是"数据有、图上没有"，且无异常提示。
- **建议**：`cellGap` 上限取 `min(cellWidth, cellHeight) / 2`（按实际列/行数算），`barWidth` 要求 `> 0` 且 `≤ slot`，越界抛 `chartInvalidValue`；`ChartSvgKit.rect` 可加一道 `width/height >= 0` 断言式检查。

### [一般][存量] IcicleChart 四层递归深度由输入决定，无深度上限

- **位置**：`f_chart/src/IcicleChart.cj:166-180`（`validateValues`）、`:182-190`（`assignDepth`）、`:192-200`（`layoutNode`）、`:202-244`（`drawNode`，`:241-243` 递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归，深度由输入决定）
- **证据**：静态确定（无任何深度上限/迭代兜底）；崩溃阈值需实测
- **描述**：递归深度 = 树高，树高的上界 = `nodes` 条数（JSON 输入，未限制条数）。仓颉不保证尾调用优化，且 `drawNode` 自身 8 个参数、每帧还带 `String`/`IcicleNode` 引用，深链（数万层）会先爆栈再谈堆。`assignDepth` 的 `depth > total` 守卫只是"深度不超过节点数"，不是栈保护。
- **建议**：改为显式栈迭代（先算出 depth 与 x 偏移，再顺序绘制），或引入深度上限常量（如 512）并在建树阶段抛明确异常。

### [一般][存量] IcicleChart 环检测恒不触发，成环节点被静默丢弃

- **位置**：`f_chart/src/IcicleChart.cj:94-111`（建树 + `roots.size != 1` 校验）、`:167-169`、`:183-185`（`depth > total` 守卫）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支/死守卫）、§11（静默丢数据）
- **证据**：静态确定 —— 从唯一根 DFS 的树最大深度为 `total-1`，`depth > total` 永不成立；环状父子关系（A.parent=B、B.parent=A）不产生无父节点，`roots.size` 仍为 1，也无法从根到达
- **描述**：最小复现：`root` + `a(parent=b)` + `b(parent=a)`。`roots.size == 1` 通过，`validateValues(root)` 碰不到 a/b，`layoutNode/drawNode` 也不会访问它们 ⇒ 三个节点只画出一个，没有异常。注释承诺的"节点关系存在环"错误路径不可达。
- **建议**：建 `children` 后先做一次父链环检测（每节点沿 `parentId` 走并计数，超 `nodes.size` 即判环），发现环抛 `chartInvalidValue`；同时删除两处恒假的 `depth > total` 守卫，避免误以为已有环保护。

### [一般][存量] M17 直方图规格与实现不符：`bins` 上界数组不支持、默认值不同、`normalize` 完全未实现

- **位置**：`f_chart/src/HistogramChart.cj:167-186`（只接受单个正整数，默认 `sqrt(n)`）、`:48-165`（`draw` 内无 `normalize` 读取，全文件 `grep -c normalize` = 0）
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）、§14（承诺了但没实现）
- **证据**：静态确定 —— 承诺源 `doc/chart-json-spec.md:758`：「`series[].bins`（分箱数或上界数组，默认 10）、`series[].normalize`（是否转为频率密度，默认 false）」；缺失证据：`HistogramChart.cj:170-177` 对非数字抛 "期望正整数"，`:179` 默认取 `sqrt(sampleSize)`，全文件无 `normalize`
- **描述**：照文档传 `bins: [0,10,20,30]` 会抛 `InvalidValue`；传 `normalize: true` 被静默忽略，输出仍是频数柱，但使用者按文档理解会读成密度——属于"不报错但口径错"。默认值 10 与实现的 `sqrt(n)` 也不一致（20 个样本时 4 箱 vs 文档 10 箱）。
- **建议**：二选一——实现上界数组（`bins: number[]` 走另一分支，`Array<Float64>` 边界）与 `normalize`（`count / (n * width)`）；或修改规格删掉这两项并把默认值写成 `sqrt(n)`。`normalize` 若保留，`computeHistogram`（`:230-263`）需接收归一化开关。

### [一般][存量] LassoPathChart 与 LearningCurveChart 的绘制骨架逐段重复

- **位置**：`f_chart/src/LassoPathChart.cj:38-214` 与 `f_chart/src/LearningCurveChart.cj:40-275`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名/换字段的重复逻辑）
- **证据**：静态确定 —— 两文件同构段落逐一对应：series 解析（`volcanoNumber` 取 x/y + `raw.add`）→ `sortLiftPoints` → min/max 与 3%/5% padding → `xMin/xMax/yMin/yMax` 校验 → ticks/tickLabels → `maxYLabelWidth` → `xLabelHeight` → `ChartFrame` → `LinearScale` → `SvgBuilder`/`ChartSvgKit` → legend 数组 → 折线 `M/L` 拼接 → 点 `circle` → `drawXAxisNumeric`
- **描述**：约 100 行同语义代码两份，真正的差异只有两处：是否画 `std` 带（LearningCurve `:80-114,220-237`）、默认系列名来源（`variables[i]` vs 序号）；连 `legendVisible` 条件都写成同一个 `series.size > 1`。第 3 条发现（std 未同步排序）正是这种复制粘贴后的局部改动遗漏。
- **建议**：抽 internal 的「XY 多系列折线管线」（解析 `{x,y}` 序列 → 范围 → 轴 → frame → legend → path/points），差异用参数表达（`std` 可选、默认名回调、图元 class 前缀不同）；落点放 `f_chart` 内部 util 文件，保持同包可见性。

### [一般][存量] `resolveLabels` 在 8 个图表中重复，其中两份仅错误文案不同

- **位置**：`f_chart/src/HeatmapChart.cj:206-221` 与 `CorrelationMatrixChart.cj:192-207`（逐行相同，仅 `"矩阵维度"` / `"矩阵阶数"` 不同）；同语义变体：`AreaChart.cj:295`、`BarRenderer.cj:287`、`DotChart.cj:188`、`HorizontalBarChart.cj:190`、`LineChart.cj:287`、`StackedAreaChart.cj:262`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 两份 `(labels, count, path)` 版本函数体一致（空则生成 `1..count`，非空则校验长度），6 份 `(labels, series)` 版本是"取最长序列长度生成 `1..n`"的同一逻辑
- **描述**：同一"缺省类别标签"策略散落 8 处，任何一处改默认格式（如改成 `"类别 1"`）都会产生不一致；错误消息也被复制成两份文案，未来容易漏改。
- **建议**：抽 `chartResolveLabels(labels, count, path, mismatchMessage)` 与 `chartGenerateLabels(count)` 到 f_chart 内部 util，各图调用并显式传文案；`(labels, series)` 版本先算 longest 再复用 `chartResolveLabels`。

### [轻微][存量] `HiveLink.value` 解析并校验后从不读取

- **位置**：`f_chart/src/HiveChart.cj:41-51`（字段与构造）、`:119-123`（解析 + `> 0` 校验）、`:193-199`（绘制只用 `source/target`，`strokeWidth: 1.2` 固定）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置字段）
- **证据**：静态确定 —— 全文件无 `link.value` / `.value` 读取，字段只在构造时赋值
- **描述**：规格 `doc/chart-json-spec.md:1550-1575` 的示例给了 `value`，但未说明语义，实现也没有映射到线宽/透明度。使用者以为权重会体现，实际所有连线等粗。
- **建议**：待确认设计意图——若要表达权重，按 `value/maxValue` 映射 `strokeWidth`（如 0.8~3.0）；若不需要，删除字段与校验，避免误导。

### [轻微][存量] LearningCurveChart 的 `metric` 校验后完全未使用

- **位置**：`f_chart/src/LearningCurveChart.cj:43-46`
- **来源**：存量
- **判据**：review-checklist §1（死配置字段）
- **证据**：静态确定 —— `metric` 只参与 `!= "score" && != "loss"` 判断，之后无任何引用
- **描述**：规格 `doc/chart-json-spec.md:2027` 只列出该字段、未写效果，因此无法断定"应有行为"（横轴标注？loss 轴反向？）——记为待确认；但当前状态是"接受参数、无任何作用"，容易让使用者误以为图已按 loss 语义渲染。
- **建议**：明确语义并接线（如 `metric == "loss"` 时轴标题/方向变化），或在规格中标注"仅作元数据、不影响渲染"。

### [轻微][存量] 恒假分支与等价冗余分支

- **位置**：`f_chart/src/HeatmapChart.cj:90-92`（`!hasValue`：每行非空必已赋值，不可达）；`f_chart/src/Histogram2DChart.cj:188-192`（循环内 `frequency > 0` 保证 `maxCount > 0`，else 恒不可达）；`f_chart/src/HistogramChart.cj:180-184`（`sqrt(sampleSize) < 1` 恒假，`sampleSize ≥ 1`）；`f_chart/src/HistogramChart.cj:210`（`maxCount > 0` 恒真）；`f_chart/src/HorizontalBarChart.cj:49-53`（`if (!labels.isEmpty()) labels else Array<String>()`，两支等价）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支、兼容残留）
- **证据**：静态确定 —— 上游均有"空数组即抛"的前置校验（`HeatmapChart.cj:59-61`、`HistogramChart.cj:67-69`、`Histogram2DChart.cj:92-94`）
- **描述**：五处分支不改变行为，只增加阅读成本；`Histogram2DChart.cj:188-192` 与 `HistogramChart.cj:210` 的 else 值（`0.0` / `1.0`）从未被使用，若将来有人调整上游校验而不改这里，会出现静默错误值。
- **建议**：删除不可达分支或改为断言；`HorizontalBarChart.cj:49-53` 直接写 `let labels = config.yAxis.labels`。

### [轻微][存量] "主题字号减常数"未做下限保护，可输出 0/负 `font-size`

- **位置**：`f_chart/src/InfluenceChart.cj:168`（`fontSize - 2.0`）、`f_chart/src/IcicleChart.cj:227`、`f_chart/src/HiveChart.cj:206`（`minFloat(fontSize - 2.0, nodeRadius * 0.9)`）、`f_chart/src/LiftChart.cj:165`（`fontSize - 1.0`）
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— `ChartTheme.parse`（`ChartTheme.cj:44`，范围外）对 `fontSize` 无下限校验，默认 12 但可配 0/1/负数；`nodeRadius` 只要 `> 0`（`HiveChart.cj:65-67`）即可
- **描述**：`theme.fontSize: 1` 时上列各处得到 -1/0，SVG `font-size` 为负非法（属性被忽略，文本按默认字号渲染），表现为标签突然变大或重叠。影响仅限文字观感，故定为轻微。
- **建议**：统一用 `maxFloat(1.0, fontSize - k)`；根因修复在 `ChartTheme.parse` 增加 `fontSize >= 1.0` 校验（属其他部分）。

### [轻微][存量] HorizontalBarChart 接受空数据数组，静默输出空图

- **位置**：`f_chart/src/HorizontalBarChart.cj:158-188`（`parseSeries` 不校验 `data` 非空）、`:190-205` + `:126-143`（生成 0 个标签、0 根柱）
- **来源**：存量
- **判据**：review-checklist §11（契约与同模块其他图表不一致）
- **证据**：静态确定 —— 同模块其余图表都有 `数据不能为空` 校验（如 `HistogramChart.cj:67-69`、`HeatmapChart.cj:45-47`、`InfluenceChart.cj:64-66`），本文件没有；`BandScale` 对 `count <= 0` 返回 `bandWidth = 0`（`ChartScale.cj:57`），不会抛错
- **描述**：`series: [{ "data": [] }]` 会渲染一张只有标题和坐标轴的空白图，调用方无法区分"没数据"与"数据全为 null"。
- **建议**：与同模块一致，`values.isEmpty()` 时抛 `chartInvalidValue("series[i].data", "数据不能为空")`。

### [轻微][存量] 测试辅助 `count` / `draw` 在 106/110 个测试文件中逐字重复

- **位置**：本部分 10 个测试文件 `HeatMap_test.cj:28-36`、`HeatmapChart_test.cj:28-36`、`Histogram2DChart_test.cj:28-36`、`HistogramChart_test.cj:28-36`、`HiveChart_test.cj:28-36`、`HorizontalBarChart_test.cj:29-37`、`IcicleChart_test.cj:28-36`、`InfluenceChart_test.cj:29-37`、`LassoPathChart_test.cj:28-36`、`LearningCurveChart_test.cj:28-36`
- **来源**：存量
- **判据**：review-checklist §2（同一函数体复制）
- **证据**：静态确定 —— `grep -l "private func count(svg: String, needle: String): Int64" *_test.cj` 命中 106 个文件，函数体完全一致（`while (let Some(index) <- svg.indexOf(needle, from))` 计数）；`private func draw(json: String)` 亦为每文件一段同构包装
- **描述**：单文件内无重复，属跨测试文件的模板复制；`needle.toArray().size` 每轮还新建数组，纯测试开销。合并建议需保留"测试类各自持有 `draw` 类型"的差异。
- **建议**：抽 `f_chart` 测试公共文件（如 `TestSvgSupport.cj`）提供 `svgCount(svg, needle)`，各测试类只保留 `draw` 包装；这是测试可维护性改进，不影响生产代码。

### [轻微][存量] 手写 SVG "M/L" 折线拼接在 20 个文件中重复

- **位置**：本部分 `f_chart/src/Histogram2DChart.cj:327-340`（`hexagonPath`）、`LassoPathChart.cj:186-202`、`LearningCurveChart.cj:221-238` 与 `:246-255`、`LiftChart.cj:171-180`
- **来源**：存量
- **判据**：review-checklist §2（字面量/结构复制）
- **证据**：静态确定 —— `grep 'append("M ${formatSvgNumber'` 在 `f_chart/src` 命中 20 个文件、26 处，模式统一为"首点 `M x y`、其余 ` L x y`、末尾可选 ` Z`"
- **描述**：`ChartSvgKit` 只有 `path(d)`（`ChartSvgKit.cj:194`），没有"点序列 → d"的封装，于是每个折线图各写一遍。任何格式调整（如改成相对坐标、加精度控制）需要改 26 处。
- **建议**：给 `ChartSvgKit` 增加 `polyline(points, close!, className!)` 或 `chartPathData(points, close)` 纯函数，先替换本部分 4 处，再逐步收敛其余图表。

### [轻微][存量] 通用排序工具寄生在具体图表文件 `LiftChart.cj`

- **位置**：`f_chart/src/LiftChart.cj:203-218`（`sortLiftPoints`）
- **来源**：存量
- **判据**：review-checklist §2（落点分层）/ §10 设计合理性
- **证据**：静态确定 —— 被 6 个其他图表调用：`CalibrationChart.cj:69`、`GainChart.cj:61`、`PdpChart.cj:62`、`LassoPathChart.cj:80`、`LearningCurveChart.cj:112`，加上 `LiftChart.cj:65` 自身
- **描述**：一个与 lift 语义无关的"按 x 稳定排序"函数定义在某个图表文件里，其他图表反向依赖它；查找时需要先知道它藏在 `LiftChart.cj`。排序算法本身是插入排序，复杂度问题见「优化可行性方案」。
- **建议**：移到 f_chart 内部 util 文件并改名（如 `sortPointsByX`），保留 `internal` 可见性以兼容现有调用。

### [轻微][存量] IcicleChart 支持 `frameHeight`，但 M53 规格未记录

- **位置**：`f_chart/src/IcicleChart.cj:121-124`（读取并校验 `frameHeight`，默认 18.0）；（对照）`doc/chart-json-spec.md:2299` 的 M53 专属字段只列 `orientation`、`colorBy`，同名字段在 M52 火焰图（`doc/chart-json-spec.md:2275`）有记录
- **来源**：存量
- **判据**：review-checklist §13 / §14.2（公开配置项未文档化）
- **证据**：静态确定 —— 代码读取该字段，M53 小节（`doc/chart-json-spec.md:2297-2320`）正文与示例均无 `frameHeight`
- **描述**：使用者按 M53 文档无法知道可以调层高；而调了又确实生效，属于文档覆盖缺口（不是实现缺陷）。
- **建议**：在 M53 小节的"专属字段"补齐 `frameHeight`（默认 18，且会被 `plot.height/(maxDepth+1)` 上限压缩，见 `IcicleChart.cj:131-138`）。

<!-- 第 31 部分 -->

### [一般][存量] `MosaicChart` 绕开 `ChartFrame` 自绘标题与图例，`legend.show` / `legend.position` / `markerSize` / `itemGap`、`title.subtext` / `title.align` 全部失效（图例关不掉）

- **位置**：`f_chart/src/MosaicChart.cj:120-129`（标题）、`:138-152`（图例）；对照 `f_chart/src/ChartFrame.cj:98-132`（`drawTitle`）、`:134-166`（`drawLegend`）
- **来源**：存量（本部分全部文件在快照内无 diff）
- **判据**：review-checklist §2「跨层复制 / 换控制流导致的行为漂移」+ §13「配置与实现不符」
- **证据**：静态确定 —— ①`MosaicChart.draw` 全文没有 `legendVisible` 变量，图例循环 `for (index in 0..series.size)` 无条件执行，只读 `config.theme.colorAt` 与硬编码的 `10.0` / `14.0` / `18.0`；②`config.legend.show`、`position`、`markerSize`、`itemGap` 在文件内零命中（本部分其余 9 张图都经 `ChartFrame` 出标题，其中 `LineChart:159`、`LollipopChart:149`、`ManhattanChart:160`、`NetworkHeatmapChart:149`、`PairedLineChart:125` 还按 `legend.show` 计算了 `legendVisible`）；③标题只读 `config.title`，`title.subtext` / `title.align` 零命中，且基线取 `padding.top + titleFontSize`，与 `ChartFrame.cj:114` 的 `padding.top + titleFontSize / 2.0` 相差半个字号
- **描述**：`doc/chart-json-spec.md:31`、`:67-75` 把 `legend` 定位为通用字段（`show` 默认 true、"是否显示"），`ChartFrame` 是其余 9 张图的统一实现。马赛克图自己写了一份，于是 `"legend": {"show": false}` 画出来仍有图例、`position: "bottom"` 仍在顶部、`markerSize` / `itemGap` 改动无效、副标题直接丢失。这类"配置静默失效"比报错更难排查：用户会以为参数位置写错了
- **建议**：改用 `ChartFrame`：`let legendVisible = config.legend.show && !(series.isEmpty())`（或在单系列无名时隐藏），`frame.drawBackground/drawTitle/drawLegend` 三步替换 120-152 行；标题的 `top` 预留改为 `ChartFrame` 的 `plot.y` 计算（`MosaicChart.cj:133` 的 `padding.top + 64.0` 也一并交给 frame）。回归用例补 `legend.show=false` 断言 `count(svg, "legend-item") == 0`

### [一般][存量] `NetworkHeatmapChart` 的 `cellGap` 只校验下界，`cellGap ≥ 单元格边长` 时生成负宽矩形，整格静默消失

- **位置**：`f_chart/src/NetworkHeatmapChart.cj:144-147`（仅 `cellGap < 0.0` 抛错）、`:186-192`（`cellWidth - cellGap` / `cellHeight - cellGap` 直接作为 `kit.rect` 的宽高）
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 缺少边界校验」、§5「无拒绝路径」
- **证据**：静态确定 —— `order` 由 `nodes` 数量决定（`:63`），`cellWidth = frame.plot.width / Float64(order)`（`:160`）；`cellGap` 无上界，`kit.rect(x, y, cellWidth - cellGap, ...)` 在 `cellGap > cellWidth` 时为负值。SVG 1.1 规定 `width`/`height` 负值为错误值，元素不被渲染
- **描述**：`nodes` 20 个（默认 800×480 画布、`plot.width ≈ 700`）时 `cellWidth ≈ 35`，用户给 `cellGap: 40` 想"格子之间留白多一点"，得到的是 400 个负宽 rect：整张图只剩轴与标签，无任何异常提示。`showValues` 的文本定位 `x + (cellWidth - cellGap) / 2.0`（`:195`）同时变成负偏移，数值文字也跟着错位
- **建议**：校验 `cellGap < min(cellWidth, cellHeight)`，越界抛 `chartInvalidValue("cellGap", "单元格间隙必须小于单元格边长 ${min}")`；或把间隙按比例解释（`cellGap` 视为占比 0..1）并夹到 `[0, 0.9]`。注意 `cellWidth` 依赖 `frame.plot`，校验必须放在 `ChartFrame` 构造之后

### [一般][存量] `LineChart` / `LollipopChart` 不校验 `series[].color`，非法颜色直出 `fill` 属性

- **位置**：`f_chart/src/LineChart.cj:115`（`json.string("color")` 后直接进 `drawSeries` → `kit.path(..., stroke: color)`）、`f_chart/src/LollipopChart.cj:82`（同上 → `:198-202` 的 `kit.line` / `kit.circle`）
- **来源**：存量
- **判据**：review-checklist §13「API / 配置与源码不符」+ `doc/chart-json-spec.md:2713`（"颜色字符串无法解析 → `InvalidValue`，`path` 例 `series[0].color`"）
- **证据**：静态确定 —— 两处只做 `json.string("color")`，文件内 `SvgColor` 零命中；同模块 `NetworkHeatmapChart.cj:133-142` 对 `colorRange` 是逐个 `SvgColor.tryParse` 并抛 `InvalidValue` 的，说明校验能力现成、只是这两张图没接。属性转义由 `SvgWriter` 负责（`f_svg/src/SvgAuthoringBuilder.cj:255-259` 注释），因此**不构成注入**，但 `fill="chartreuse2"` 这类拼写错误会原样进入 SVG 并被渲染器忽略，系列退化成黑色
- **描述**：规格把颜色校验列为通用规则，10 张图里只有网络热力图执行；调用方拿到的是"图能出来、颜色不对"的结果，与"非法输入必须抛 `InvalidValue`"的契约相反
- **建议**：在 `ChartJson` 增加 `color(name: String): ?String`（内部 `SvgColor.tryParse`，失败抛 `chartInvalidValue(pathOf(name), "非法颜色 ${text}")`），`LineChart:115`、`LollipopChart:82` 改用它；`theme.palette` 的解析（`ChartTheme.cj:39-42`）可复用同一入口

### [一般][存量] `OrgChart` 没有真正的环检测：存在合法根时，环内节点被静默混入布局（叠在同一槽位）并画出互指连线

- **位置**：`f_chart/src/OrgChart.cj:108-122`（只用"根数量 == 1"间接兜底）、`:125`（`orgLayout`）、`:152-202`（绘制）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失 / 静默失效」；意图源：`f_chart/src/OrgChart_test.cj:197-215`（`rejectsCycle`）+ `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md`（"`parent` 指向存在的节点且不存在环"）
- **证据**：静态确定 —— 自环/双节点环在**没有其它根**时确实会抛错，但抛的是 `:120-122` 的"必须恰好有一个根节点"（环内节点都有父节点，`roots` 为空，走 `roots.size != 1` 分支）。若输入为 `[{id:"r",parent:null},{id:"a",parent:"b"},{id:"b",parent:"a"}]`：`a`、`b` 各自挂到对方 `children`（`:113`），`roots` 只有一个 `r`，校验通过；`orgAssignDepth/orgAssignSlots` 从 `r` 出发（`:250-252`）只访问 `r`，`a`/`b` 的 `depth`/`slot` 保持初值 0（`:28-29`），最终三者画在同一坐标，并输出两条 `org-link` 互指
- **描述**：契约要求"不存在环"必须报错，实现只在"没有根"这一种形态下偶然报错，错误文案还指向根数量而非环，排查成本高；其余形态产出重叠节点，属于静默数据错误。现有用例 `rejectsCycle` 恰好只覆盖了无根形态，因此测试是绿的
- **建议**：在 `:108-122` 之后加一次可达性校验：从 `roots[0]` 走一遍并计数，`visited != nodes.size` 时抛 `chartInvalidValue("nodes", "节点关系存在环或存在不可达节点")`；或沿用 `OfflineFlameChart` 的深度上界思路（但需注意那份实现本身不可达，见下条）。补用例：`root + 双节点环` 应抛 `InvalidValue`

### [一般][存量] `LollipopChart` 在显式 `yAxis.min > 0` 时把茎线的 0 基线画到绘图区之外

- **位置**：`f_chart/src/LollipopChart.cj:124-138`（`yMin` 取显式值）、`:187`（`baseline = yScale.scale(0.0)`）、`:193-202`（从 `baseline` 画到 `y`）
- **来源**：存量
- **判据**：review-checklist §11「边界 / 坐标越界」、§10「正确性」；规格侧张力见 `f_chart/doc/spec/add-f-chart-lollipop/specs/chart-rendering/spec.md`（"茎从 0 基线到该值" 与 "`yAxis.min` 给出时 MUST 按给定值" 互斥）
- **证据**：静态确定 —— `LinearScale.scale` 为 `bottomPixel - (value - min)/span * (bottomPixel - topPixel)`（`ChartScale.cj:41`），`min > 0` 时 `scale(0) > bottomPixel`。取 `yAxis.min: 2`、数据 `[4.2, 3.6]`：`dataMin` 从 0 起算（`:112-113`）故 `yMax=4.2`、`yMin=2`，`(0-2)/2.2 = -0.909`，`scale(0)` 落在 `plot.bottom()` 下方约 `0.91 × plot.height` 处，茎线整根从绘图区外穿入
- **描述**：茎的起点溢出 x 轴下方，压到刻度标签与轴标题区域（`frame.drawXAxis` 在 `plot.bottom()+6` 起画标签），画布边缘还会被裁掉一截，视觉上像"数据从空气中长出来"。默认（不给 min）时 `dataMin` 从 0 起算（`:112-113`），所以正常路径不受影响，属边界配置触发
- **建议**：`baseline` 改为 `yScale.scale(clamp(0.0, yMin, yMax))`，即 `if (yMin > 0.0) frame.plot.bottom() else if (yMax < 0.0) frame.plot.y else yScale.scale(0.0)`；或在 `:124-131` 直接校验 `yAxis.min <= 0 <= yAxis.max`（与"纵轴范围 MUST 包含 0"一致）后抛 `InvalidValue`。二选一需在 `doc/chart-json-spec.md` 的 M79 小节写明

### [一般][存量] 刻度不做范围裁剪：显式 `axis.values`（以及 `chartNiceTicks` 的 floor/ceil 扩展）落在轴域外时，刻度线/网格/标签画到绘图区外

- **位置**：`f_chart/src/LineChart.cj:137-141` + `:151-155`、`f_chart/src/LollipopChart.cj:139-143`、`f_chart/src/ManhattanChart.cj:134-143`、`f_chart/src/PairedLineChart.cj:106-110`（四张图均把 `config.*Axis.values` 原样交给 `frame.drawYAxis` / `drawXAxisNumeric`，无过滤）
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 越界」、§10「正确性」
- **证据**：静态确定 —— `ChartFrame.drawYAxis`（`ChartFrame.cj:168-202`）对每个 tick 直接 `scale.scale(tick)` 后画 `line` 与 `text`，无 `min/max` 过滤；`chartNiceTicks`（`ChartScale.cj:94-95`）用 `floor(min/step)*step` / `ceil(max/step)*step` 扩展首末刻度，返回值本身就可能越出 `[min,max]`。`yAxis.values` 是 `doc/chart-json-spec.md` 2.4 小节（`xAxis` / `yAxis`）记载的通用字段，四张图都无"必须落在轴域内"的校验
- **描述**：`yAxis: {"values": [0, 50, 100]}` 配数据 1..2（轴域约 0.95..2.05）时，`0`、`50`、`100` 三个刻度的网格线与标签分别画在 `plot` 下方、下方更远处与上方，坐标出现负值或超出画布，SVG 本身合法但视觉上是"轴外的孤立数字"。同源问题在 `chartNiceTicks` 侧（`ChartScale.cj`，属其它部分）已由 part2 的「范围外提示」记录，本部分记的是**四张图都缺裁剪/校验**
- **建议**：抽一个 `chartClipTicks(ticks, min, max)`（或给 `ChartFrame` 加 `range` 参数），过滤 `min - eps <= t <= max + eps` 的刻度；对显式 `values` 越界抛 `chartInvalidValue("yAxis.values[i]", "刻度必须落在轴范围内")`。两条路径的取舍需在 `doc/chart-json-spec.md` 写明

### [轻微][存量] `OfflineFlameChart` 的两处"环检测"不可达（死代码），而真正的环仍被静默丢弃

- **位置**：`f_chart/src/OfflineFlameChart.cj:177-179`（`validateValues` 的 `depth > total`）、`:193-195`（`assignDepth` 的同款判断）
- **来源**：存量
- **判据**：review-checklist §1「恒假分支 / 不可达语句」、§3「错误被静默吞掉」
- **证据**：静态确定 —— 每个节点只有一个 `parentId`（`:77-87`），`:96-106` 把它挂进唯一父节点的 `children`，因此结构必然是有向森林；`validateValues/assignDepth` 都只从 `roots[0]`（`:110`）/`selected`（`:121`）出发，沿 `children` 下行，**单亲森林从根出发不可能回到已访问节点**，`depth` 严格等于路径深度且 ≤ 节点数，`depth > total` 恒假。旁证：`OrgChart.cj:218-238` 的同构递归完全没有这层判断
- **描述**：两段"节点关系存在环"的异常实际永不抛出；而 `[{id:"r",parent:null},{id:"a",parent:"b"},{id:"b",parent:"a"}]` 这类输入会通过 `:107-109` 的单根校验，`a`/`b` 既不报错也不绘制。规格只要求"恰好一个树根"，所以行为不算违约，但代码里两处"环检测"会误导后续维护者以为已覆盖
- **建议**：删除两处 `depth/total` 参数（连同 `total` 形参），改为在 `:107-109` 之后用"可达计数 == `parsed.size`"一次性判定环/不可达并抛 `chartInvalidValue("nodes", ...)`；或在注释里写明"单亲森林无环，环只会表现为不可达节点，故此处不做深度保护"

### [轻微][存量] 重复逻辑：图例名称/颜色数组在两处逐行同构构建

- **位置**：`f_chart/src/LineChart.cj:190-199` 与 `f_chart/src/LollipopChart.cj:175-184`
- **来源**：存量
- **判据**：review-checklist §2「同语义、不同文件复制」
- **证据**：静态确定 —— 两段都是 `names.add(series[i].name)` + `colors.add(match (color) { Some(c) => c; None => theme.colorAt(i) })` + `names.toArray()/colors.toArray()`，差异只有列表变量名（`series` 元素类型分别为 `LineSeries` / `LollipopSeries`）
- **描述**：同一"系列名 + 解析后颜色"的推导写了两遍，颜色解析规则（显式优先、否则 `colorAt(index)`）一旦变化（例如加调色板越界告警）要改两处
- **建议**：在 `ChartTheme` 或 `ChartFrame` 上提供 `resolveColors(count, colors: Array<?String>): Array<String>`，两张图各传一次 `Option` 数组；不建议上泛型，参数用 `Array<?String>` 即可

### [轻微][存量] 重复逻辑：染色体"首次出现顺序"去重在一个文件里写了两遍，且 `draw` 侧再按顺序线性回查 → O(n·c)

- **位置**：`f_chart/src/ManhattanChart.cj:205-210`（`chromosomeOrder` 构建）与 `:243-248`（`manhattanPositions` 内 `order` 构建）；回查在 `:211-213` + `:228-235`
- **来源**：存量
- **判据**：review-checklist §2「同文件两两比对」、§6.4「热点 `contains` / 线性查找」
- **证据**：静态确定 —— 两段循环体完全一致（`if (!order.contains(chromosome)) { order.add(chromosome) }`）；`chromosomeIndexOf` 对每个点再线性扫一遍 `order`，`order.contains` 也是线性，整体 `O(n·c)`（c = 染色体数，人类 24 + 性染色体，量级固定，故只记为轻微）
- **描述**：`manhattanPositions` 内部已经算出了分组顺序却不返回，调用方只能重建一遍再做反查；`chromosomeIndexOf` 未命中时返回 `0`（`:234`）而不是报错，把"顺序表与点集不同步"的编码错误伪装成"第 0 号染色体颜色"
- **建议**：让 `manhattanPositions` 返回 `(positions, order)`（或加一个 `ManhattanLayout` 小结构），`draw` 直接用返回的 `order`；反查改成一次性建 `HashMap<String, Int64>`，把 `chromosomeIndexOf` 的兜底改成 `-1` 并在调用处断言

### [轻微][存量] 重复逻辑：节点 id 唯一性与 id→节点查找在 4 个文件里各写一份，均为 O(n²)

- **位置**：去重循环 `f_chart/src/NetworkHeatmapChart.cj:55-59`、`f_chart/src/NodeLinkChart.cj:88-92`、`f_chart/src/OfflineFlameChart.cj:71-75`、`f_chart/src/OrgChart.cj:88-92`；查找函数 `NodeLinkChart.cj:184-191`（返回 `Int64`，未命中 `-1`）、`OfflineFlameChart.cj:167-174`（返回 `?Node`）、`OrgChart.cj:208-215`（返回 `Option<OrgNode>`）、`ManhattanChart.cj:228-235`（同型，见上条）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名的复制 / 复制导致语义漂移」（四段去重同构，三份查找的未命中语义分别是 `-1` / `None` / `None`）
- **证据**：静态确定 —— 四段去重循环逐行同构（`for (existing in nodes) { if (existing.id == id) throw chartInvalidValue(..., "节点 id 重复") }`），三份 `findNode` 除返回类型外一致；`NodeLinkChart` 还在 `:122-127`、`:158-159`、`:243-244` 重复调用 `findNode`（力导向里每轮每条边两次）
- **描述**：同一份"id 唯一 + id 索引"的契约复制了 4 次，错误文案一致但未命中语义不一致，调用方（`NodeLinkChart.cj:158`）拿 `-1` 直接做下标，一旦上游校验被改动就是越界崩溃；同时 4 处都是线性扫描（性能面见「优化可行性方案」）
- **建议**：在 `ChartJson`（或新增 `ChartNodes` 工具）提供 `buildIndex(nodes)` 返回 `HashMap<String, Int64>`，去重与查找都走它，未命中统一抛 `chartInvalidValue`；四个图改为"建索引一次 + 取值"

### [轻微][存量] 重复逻辑：三个小工具分别重写了 `chartTextWidth`、`maxFloat`、`jsonNumberValue` 的语义

- **位置**：`f_chart/src/OrgChart.cj:266-286`（`orgFitLabel` 内的字宽模型）、`f_chart/src/NomogramChart.cj:236-238`（`maxNameWidthOf`，实为 `maxFloat`）；数值读取侧 `NomogramChart.cj:96-99`（`jsonNumberValue`）、`ManhattanChart.cj:77-78`（`volcanoNumber`，`VolcanoChart.cj:228-234`）、`PairedLineChart.cj:79-80`（`bulletNumber`，`BulletChart.cj:233-243`）
- **来源**：存量
- **判据**：review-checklist §2「换算复制 / 字面量复制」
- **证据**：静态确定 —— `orgFitLabel:274-278` 的 `rune.position() >= 0x2E80 ? fontSize : fontSize * 0.56` 与 `ChartScale.cj:113-123` 的 `chartTextWidth` 逐字相同；`maxNameWidthOf` 与 `std.math.maxFloat` 语义相同（`NomogramChart` 未导入 `std.math`，因此自写了一份）；`volcanoNumber` 的"kind 检查 + jsonNumberValue"与 `jsonNumberValue`（`ChartJson.cj:215-227`，内含同样的 kind 检查）重复，`bulletNumber` 是它再加一次非负判断
- **描述**：字宽模型有两份实现，改 CJK 阈值时极易只改一处，导致"边距按新模型算、截断按旧模型算"，标签越界；数值读取三份实现里，`volcanoNumber` 的类型预检是纯冗余（`jsonNumberValue` 已经抛同样的 `InvalidValue`），而 `bulletNumber` 多出的非负约束被 `PairedLineChart` 继承（其 delta 规格确实要求非负，属隐式耦合：子弹图的规则泄漏到配对图）
- **建议**：`orgFitLabel` 用 `chartTextWidth` 做累加与判定（或抽出 `chartFitLabel(text, maxWidth, fontSize)` 放 `ChartScale.cj`，`DecisionTree/Swimlane/Timeline` 三处调用点一并受益，属其它部分）；`maxNameWidthOf` 删掉改用 `maxFloat` 并补 `import std.math.*`；`volcanoNumber` 收敛为 `jsonNumberValue(json.required(field), ...)`；`bulletNumber` 改名 `nonNegativeNumber` 并移到 `ChartJson` 附近，避免"配对图依赖子弹图"

### [轻微][存量] 校验口径与 `chart-json-spec.md` 不一致：空数据的三张图抛异常、`NodeLinkChart` 不校验空 `links`

- **位置**：`f_chart/src/ManhattanChart.cj:64-66`、`f_chart/src/PairedLineChart.cj:67-69`、`f_chart/src/MosaicChart.cj:99-101`（空数据抛 `InvalidValue`）；`f_chart/src/NodeLinkChart.cj:109-135`（`links` 为空数组时不报错）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；`doc/chart-json-spec.md:2722`（"空数据：仍输出带标题与坐标框的 SVG，不抛异常；仅当结构缺失才抛 `MissingField`"）、`:2699-2714`（校验规则表）
- **证据**：静态确定 —— 三处 `isEmpty()` 分支直接 `throw chartInvalidValue(..., "数据不能为空"/"列总和必须大于 0")`；`LineChart`/`LollipopChart` 面对 `data: []` 则正常输出空图（`LineChart.cj:287-302` 生成空标签、`:335-338` 在 `!hasData` 时回落到 `[0,1]`，之后照常画坐标框）。反向：`NodeLinkChart` 用 `requiredArray("links")` 只保证字段存在，`:110-114` 对空数组不设分支，最终画出"一堆孤立节点"
- **描述**：同一份通用规格里"空数据不抛异常"是明确规则，而各图自己的 delta 规格（manhattan / paired-line 均为"`data` MUST 非空"）与它冲突，实现各自选了一边。对使用者表现为：换张图、同样的空数组，有时拿到空图、有时拿到 `ChartException`。`links` 空数组则相反——delta 规格写"`links` MUST 非空"，实现没校验
- **建议**：先定口径（建议以 `chart-json-spec.md:2722` 为准，允许空图），再统一：三处删掉 `isEmpty` 抛错分支（保留 `grandTotal <= 0` 这类"有数据但无法绘制"的判断），`NodeLinkChart` 补 `if (linkItems.isEmpty()) throw chartInvalidValue("links", "至少需要一条链接")`；两版 README 与三份 delta 规格同步

### [轻微][存量] `NomogramChart` 的 `variables[].points` 只做递增校验、不参与绘制

- **位置**：`f_chart/src/NomogramChart.cj:71-74`（`points` 读出后仅做两次比较）、`:75`（`NomogramVariable(name, range[0], range[1])` — 结构里没有 `points` 字段）、`:134-159`（每行刻度尺固定占满 `plot.x → plot.right()`）
- **来源**：存量
- **判据**：review-checklist §14.1「半成品 / 承诺了但只做一半」；承诺源 `f_chart/doc/chart-json-spec.md:1853`（`variables: [{name, range, points}]`）与 `f_chart/doc/spec/add-f-chart-nomogram/proposal.md:5`（"把多个预测变量的取值折算为分值"）
- **证据**：静态确定 —— `points` 在 `:71-74` 之后零引用（`:110` 起只用 `variable.rangeMin/rangeMax`）；`NomogramVariable`（`:23-33`）只有 `name/rangeMin/rangeMax`。而同文件的 `risk` 是按 `totalPoints` 归一化定位的（`:192-194`），说明"折算成总分"的能力只做在了风险轴那一侧
- **描述**：列线图的读法是"变量值 → 该变量的分值刻度 → 累加成总分 → 查风险"，现在每个变量的刻度尺长度都一样（都铺满绘图区），`points: [0,100]` 与 `points: [0,60]` 画出来完全相同，读者无法换算出分值。当前 delta 规格只要求"校验 `points` 递增"，因此**不算违约**，但与 proposal 与字段表的意图有落差，需规格负责人确认这是有意的简化
- **建议**：二选一并写进 `doc/chart-json-spec.md` 的 M51 小节：①按 `points[1] / maxPointsTotal` 决定每行刻度尺的长度（`NomogramVariable` 加 `pointsMin/pointsMax`，`draw` 里用 `plot.width * points[1]/maxPoints`），同时把"总分"行改为各变量分值上限之和；②在字段表注明"`points` 仅用于校验，渲染不使用"，并从 proposal 删掉"折算为分值"的表述

### [轻微][存量] `OrgChart` 的父槽位取"首末子节点中点"，3 个以上子节点且子树宽度不均时不等于子节点中心均值

- **位置**：`f_chart/src/OrgChart.cj:235-237`
- **来源**：存量
- **判据**：review-checklist §10「正确性（布局算法）」；意图源 `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md`（"父节点中心 MUST 等于其子节点中心的平均值"）
- **证据**：静态确定 —— `slot = (children[0].slot + children.last.slot) / 2.0`。子槽位由叶子游标连续分配（`:226-238`），若三个子节点的槽位为 `1.5`（宽子树）、`4`、`6`，父槽位得 `3.75`，而三者中心均值是 `3.83`
- **描述**：两子节点时两者恒等（故现有用例 `centersParent` 通过）；≥3 子节点且子树宽度不均时父节点会偏向宽子树一侧，连线出现斜折，视觉上是"树没对齐"，不影响连线拓扑
- **建议**：改为 `sum(child.slot) / children.size`（真正的均值，也是同类 tidy-tree 的常规做法）；补一个"三子节点 + 宽度不均子树"的槽位断言用例

### [轻微][存量] `ManhattanChart` 的染色体配色走调色板循环，而非"两种主题色交替"

- **位置**：`f_chart/src/ManhattanChart.cj:211-213`（`config.theme.colorAt(chromosomeIndex)`）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」——证据等级**待确认**：该要求只写在已归档的 delta 规格（`doc/spec/add-f-chart-manhattan/specs/chart-rendering/spec.md`"颜色 MUST 按染色体顺序在两种主题色之间交替"），当前 `doc/chart-json-spec.md` 的 M93 小节未约定配色
- **证据**：静态确定（行为）/ 待确认（是否仍要求）—— `colorAt` 为 `palette[index % size]`（`ChartTheme.cj:54-60`），默认 10 色调色板，因此 11 号染色体开始与 1 号同色；文件内没有"两两交替"的取模或奇偶分支
- **描述**：曼哈顿图的通行画法是相邻染色体深浅交替，便于肉眼分辨边界。现在 24 条染色体得到 10 种颜色循环，相邻染色体可能撞色，读者会误判分组边界。若归档规格已被当前规格取代，本条可直接关闭
- **建议**：`let color = config.theme.colorAt(chromosomeIndex % 2)`（或 `if (chromosomeIndex % 2 == 0) theme.colorAt(0) else theme.colorAt(1)`），并把这条写进 `doc/chart-json-spec.md` 的 M93 小节，避免下次又漂移

### [轻微][存量] 通用折线类型声明在具体图表文件里，被 3 张无关图跨文件复用

- **位置**：`f_chart/src/LineChart.cj:24-32`（`LinePoint`）、`:35-43`（`LinePixel`）、`:46-69`（`LineSeries`）；使用方 `f_chart/src/AreaChart.cj:25,34,222-270,420-442`、`f_chart/src/ComboChart.cj:596-609`、`f_chart/src/RadarChart.cj:141,220`
- **来源**：存量
- **判据**：review-checklist §10「设计合理性（职责划分 / 依赖方向）」
- **证据**：静态确定 —— 三个类型都是 `internal` 且定义在 `LineChart.cj`，`LineSeries` 只被 `LineChart` 自己用（`grep` 全 module：仅 `LineChart.cj` 命中），`LinePoint`/`LinePixel` 被 Area/Combo/Radar 引用
- **描述**：`AreaChart` 等要依赖"折线图"这个具体文件的内部类型，改名或拆分 `LineChart.cj` 会波及三张图；`LineSeries` 却没有跨文件使用，放在这里更无必要
- **建议**：把 `LinePoint`/`LinePixel` 移到 `ChartScale.cj` 或新建 `ChartPoints.cj`（同包内部共享类型），`LineSeries` 留在 `LineChart.cj`

<!-- 第 32 部分 -->

### [严重] PictogramChart 图标数量由不可信输入放大，循环无上限

- **位置**：`f_chart/src/PictogramChart.cj:123-139`（`while (drawn < iconCount)` 循环）、`f_chart/src/PictogramChart.cj:145-150`（`pictogramCount`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（按不可信值放大输出、无拒绝路径）
- **证据**：静态确定 —— `unit` 只校验 `> 0`（`:47-50`），`value` 只校验 `>= 0`（`:88-90`），`iconCount = Int64(ceil(value / unit))`，随后该值直接决定 `while` 迭代次数，每次迭代都向 `SvgBuilder` 追加一个 `SvgPath` 元素。
- **描述**：`value` 与 `unit` 都是 JSON 里的用户输入，比值无任何上限。以 `{"value": 1000000, "unit": 0.000001}`（约 60 字节输入）为例，`iconCount = 1e12`：循环 10^12 次、向 DOM 追加 10^12 个路径元素，必然长时间不返回并 OOM；`columns` 只影响排布，不构成上限（`:51-55`）。`unit` 极小值完全合法（只判 `> 0`），因此这是一条"一个字段即可触发的拒绝服务路径"，而不是理论边界。
- **建议**：加显式上限（如 `MAX_ICONS = 10000`）并在超限时抛 `chartInvalidValue("unit", "图标数量超过上限")`；或按画布可容纳格数（`columns × 可用行数`）截断并对截断给出标注。

### [一般] PieChart 单扇区 100% 时扇区不可见

- **位置**：`f_chart/src/PieChart.cj:113-130`（`angle` / `endAngle` / `largeArc` / 弧路径拼接）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 退化输入未处理）；SVG 1.1 §F.6.5.4「若弧的起点与终点相同，等价于完全省略该弧段」
- **证据**：静态确定 —— 只有一个类目时 `fractions[0] = 1.0`，`sweep = 360.0`，`endAngle = angle + 360`；`startX/startY` 与 `endX/endY` 只差 `cos/sin` 在 `1e-16` 量级的浮点噪声，而 `formatSvgNumber` 按 6 位小数裁剪（`f_svg/src/SvgNumber.cj:39-48`），两者格式化后是完全相同的数字串，弧段按规范被省略，路径退化为 `M 圆心 L 端点 Z` 的零面积图形。
- **描述**：`{"type":"pie","series":[{"data":[{"name":"A","value":1}]}]}` 输出 SVG 里 `pie-slice` 元素存在但不可见（画布上只剩一条从圆心到圆周的线），用户会认为图表渲染失败。两个 50% 扇区、四个扇区等常规输入不受影响，`PieChart_test.cj` 也没有单扇区用例。
- **建议**：`sweep >= 359.999` 时改用两个半圆弧（或直接输出 `<circle>`），并补一条"单类目 100%"用例断言可见扇区。同源代码：`DonutChart.cj:108-115` 是同一份写法（范围外提示，未计入本部分统计）。

### [一般] 画布尺寸只校验 > 0，饼图半径可为负、平行坐标绘图区可反转

- **位置**：`f_chart/src/PieChart.cj:109-112`、`f_chart/src/ParallelCoordinatesChart.cj:194-197`；根因在 `f_chart/src/ChartConfig.cj:182-184`（只判 `width/height > 0`，属其他部分，仅作根因引用）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 → 非法几何值）
- **证据**：静态确定（算式可复现），渲染后果需实测（不同渲染器对非法半径的容错不同）
- **描述**：
  - 饼图：默认 `padding = 24` 时 `radius = min(w-48, h-88)/2 - 20`，因此 `w < 88` 或 `h < 128` 时 `radius < 0`，路径写出 `A -14 -14 ...`。SVG 规定半径为负属错误，元素不渲染 → 整张饼图静默消失。
  - 平行坐标：`right - left = w - 128`、`bottom - top = h - 152`，`w < 128` 或 `h < 152` 时 `step` 与 `bottom - top` 为负，维度轴从右往左排、归一化方向翻转，输出是镜像/倒置的图。
  - 同一根因下，`ChartFrame`（`ChartFrame.cj:91` 的 `plot` 宽高）也会为负，本部分 Pareto / PDP / PR / Probability / QQ 的 `rect`、`line`、`circle` 坐标随之非法。
- **建议**：`ChartConfig.parse` 增加最小画布校验（例如 `width >= 200 && height >= 150`，或按 padding + 轴标签宽度动态判断），或在各图对 `radius` / `plot.width` / `plot.height` 取 `max(0.0, ...)` 并对退化情形给出明确异常。

### [一般] PdpChart / PrChart 的 x 轴被镜像（数值从右向左增大）

- **位置**：`f_chart/src/PdpChart.cj:132`、`f_chart/src/PrChart.cj:130`
- **来源**：存量
- **判据**：review-checklist §11（语义与实现不符）
- **证据**：静态确定 —— `LinearScale.scale` 的公式是 `bottomPixel - (v-min)/span*(bottomPixel-topPixel)`（`f_chart/src/ChartScale.cj:36-43`）。传入 `(plot.x, plot.right())` 时 `scale(min) = plot.right()`、`scale(max) = plot.x`，即最小值落在右端。同模块 15 张图用的是 `(plot.right(), plot.x)`（如 `ProbabilityChart.cj:110`、`QQChart.cj:110`、`LineChart.cj:177`），该写法 `scale(min) = plot.x`，方向正确。
- **描述**：PDP 的特征值（`x`）与 PR 的召回率（`x`）都会左高右低显示；`drawXAxisNumeric` 用同一个 `xScale` 定位刻度（`ChartFrame.cj:291-307`），所以刻度标签也随之为倒序（如从左到右 70、60、…、20）。图表内部自洽（点、线、刻度一致倒置），因此现有用例（只数图元个数、只查字符串）全部通过，问题不会被测试发现。
- **建议**：改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)`；补一条断言"首刻度像素 < 末刻度像素"的用例。范围外提示：`RocChart.cj:123`、`VolcanoChart.cj:156`、`ManhattanChart.cj:165`、`ResidualChart.cj:112`、`SurvivalChart.cj:168` 等 15 个文件采用同一写法，建议由主 Agent 合并为一条模块级问题。

### [一般] `cumulativeFormat` 文档化但实现里被硬编码取代

- **位置**：`f_chart/src/ParetoChart.cj:171-179`（`"${Int64(tick)}%"`）；承诺源 `f_chart/doc/chart-json-spec.md:1615`
- **来源**：存量
- **判据**：review-checklist §14.1（接线缺失：配置项从未被读取）/ §13（文档与实现不符）
- **证据**：静态确定 —— 全仓 grep `cumulativeFormat` 只命中 `doc/chart-json-spec.md:1615` 一处，`src/` 内零引用；右侧百分比标签固定写 `Int64(tick)%`，也不走 `chartFormatTick`。
- **描述**：文档声明 `cumulativeFormat`（默认 `{value}%`），用户按文档传 `"cumulativeFormat": "{value} %"` 或 `"{value} pct"` 时不会有任何效果，也不会报错（被静默忽略），属于"读了不用"的契约缺失。
- **建议**：`let cumulativeFormat = root.string("cumulativeFormat", default: "{value}%")`，用 `chartFormatTick(tick, cumulativeFormat)` 出标签；或者删除文档字段并写明百分比标签固定格式。

### [一般] `pie.innerRadius` 文档化但 PieChart 完全不读取

- **位置**：`f_chart/src/PieChart.cj:42-151`（无 `innerRadius` 读取）；承诺源 `f_chart/doc/chart-json-spec.md:1248`
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现）/ §13
- **证据**：静态确定 —— `innerRadius` 在 `src/` 只出现在 `DonutChart.cj:73-75,126,142` 与 `GaugeChart.cj:116`，`PieChart` 内零命中；`draw` 只用 `centerX/centerY/radius` 画实心扇区。
- **描述**：文档把 `innerRadius`（默认 0）列为 `pie` 的专属字段，实现忽略该字段：用户对 `pie` 传 `0.5` 期望得到环形图，实际得到实心饼图，且无告警。默认值 0 恰好与实心实现一致，所以只有显式传参的用户会踩到。
- **建议**：`pie` 读取并按比例挖空（与 `DonutChart` 复用同一段逻辑），或把文档改成"仅 `donut` 支持 `innerRadius`"。

### [一般] QQChart 与 ProbabilityChart 整段复制，只改类型名与 class 前缀

- **位置**：`f_chart/src/QQChart.cj:31-194` vs `f_chart/src/ProbabilityChart.cj:31-194`；`QQChart.cj:156-193` vs `ProbabilityChart.cj:156-193`（`sortValues`、`resolveRange` 完全相同）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 字面量的复制）
- **证据**：静态确定 —— `diff` 两段 164 行代码只有 5 处不同：`ChartConfig.parse` 的类型串（`qq` / `probability`）、系列数量校验的错误文案、`qq-line` → `probability-line`、`qq-point` → `probability-point`；`sortValues`（16 行）与 `resolveRange`（21 行）逐字相同。连类注释都一致（两文件 `:23-27`）。规范自己也承认"`probability` 与 QQ 图同形"（`doc/chart-json-spec.md:1729`）。
- **描述**：两份实现共享 90% 以上语义，任何一侧的修复（例如上面第 3、4 条的画布与轴问题、后续加 `innerRadius`/分位数算法调整）都只改一半，形成行为漂移；测试也各写一套，漂移不会立刻暴露。这是"表现形式相同的重复"，不是两个需要独立演进的能力。
- **建议**：抽 `internal class QqPlotRenderer { static func render(data, expectedType, classPrefix): String }`，两个 Chart 退化为参数转发——与 M75/M4 用 `BarRenderer.render(data, "percent-bar"|"percent-stacked-bar", BarMode.PercentStacked)` 的既有做法一致；差异点（类型串、文案、class 前缀）显式参数化。

### [轻微] 两个只写不读的字段

- **位置**：`f_chart/src/PieChart.cj:24-32`（`PieSlice.value`，写于 `:80`，全文只读 `slices[index].name` `:138`）；`f_chart/src/ParallelCoordinatesChart.cj:37-46`（`ParallelSeriesData.name`，构造于 `:123`，`:133/:238/:242` 只用 `rows` 与 `color`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— 两个文件内 grep 字段名，`PieSlice.value`、`ParallelSeriesData.name` 只出现在构造与声明处，无任何读取点；两个类都是 `internal`，成员不可对外访问。
- **描述**：`PieChart` 的占比计算另用平行数组 `values`（`:63,84`），`PieSlice.value` 纯冗余；`ParallelCoordinatesChart` 的系列名既不进图例也不进任何标注，`name` 解析后即丢弃（同时 `:94` 的 `name` 局部量只用于构造）。
- **建议**：`PieSlice` 只保留 `name`；`ParallelSeriesData` 删 `name`（若将来要做图例再按需补回）。

### [轻微] 插入排序在 9 处重复实现

- **位置**：`f_chart/src/ParetoChart.cj:202-217`（`paretoOrder`，降序下标）、`f_chart/src/PrChart.cj:197-212`（`sortPoints`，按 `x` 升序）、`f_chart/src/QQChart.cj:156-171` 与 `f_chart/src/ProbabilityChart.cj:156-171`（`sortValues`，Float64 升序）、`LiftChart.cj:203-218`（`sortLiftPoints`，被本部分 `PdpChart.cj:62` 复用）、`BoxScatterChart.cj:245`、`SwarmChart.cj:218`、`ViolinBoxChart.cj:298`、`ViolinChart.cj:271`（均为 `sortValues`）
- **来源**：存量
- **判据**：review-checklist §2（换算/算法复制）
- **证据**：静态确定 —— 9 个函数体都是"`for (i in 1..size) { j=i; while (j>0 && cmp(a[j], a[j-1])) swap; j-- }"的同一插入排序，只差比较键（`values[...]` / `sorted[j].x` / `sorted[j][0]`）与升降方向。
- **描述**：算法一致但实现散落 9 处：一处修正（例如改成稳定排序或换 O(n log n)）无法覆盖其余；`PdpChart` 跨文件复用 `LiftChart` 的 `sortLiftPoints`，也让"PDP 依赖 Lift"这种无意义耦合固化。
- **建议**：抽 `internal func chartSortDoubles(values: Array<Float64>, descending!: Bool = false): Array<Float64>` 与 `chartSortIndices(values: Array<Float64>, descending!: Bool = false): Array<Int64>` 放 `ChartScale.cj`（同层工具），`sortPoints`/`sortLiftPoints` 用索引版本；合并前先列出差异（升降序、比较键、稳定性），把差异显式参数化。复杂度问题见「待验证假设」第 1 条。

### [轻微] 测试 `count` helper 在 106 个 `*_test.cj` 中逐字复制，且每次命中分配数组

- **位置**：本部分 10 个测试文件的 `count`：`PairedLineChart_test.cj:28-36`、`ParallelCoordinatesChart_test.cj:28-36`、`ParetoChart_test.cj:29-37`、`PdpChart_test.cj:28-36`、`PercentBarChart_test.cj:28-36`、`PercentStackedBarChart_test.cj:29-37`、`PictogramChart_test.cj:28-36`、`PieChart_test.cj:29-37`、`PrChart_test.cj:28-36`、`ProbabilityChart_test.cj:28-36`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制，跨文件）+ §8（每次命中的无谓分配）
- **证据**：静态确定 —— 全模块 `grep "private func count(svg: String, needle: String): Int64"` 命中 106 个文件，函数体逐字相同（108 处 `from = index + needle.toArray().size`，无第二种写法）。
- **描述**：`needle.toArray()` 每命中一次就把 needle 复制成一个字节数组，只为取长度；单测里 `count` 被反复调用（每张图 3–6 次、每次扫整段 SVG），是纯浪费的分配。106 份副本也意味着改判定逻辑要改 106 处。测试准备代码本身通常不判重复，但"同一 9 行函数复制 106 份且带反模式分配"已超出可读性展开的范畴。
- **建议**：抽到模块内测试工具文件（如 `ChartTestUtil.cj`，`internal func countOccurrences(haystack: String, needle: String): Int64`），内部预取 `needle.size`；顺带把 `draw(json)` 包装同质化（本部分 10 个 `draw` 也只有类名不同）。

### [轻微] PictogramChart 未知 icon 名静默当 path 输出

- **位置**：`f_chart/src/PictogramChart.cj:153-190`（`case _ => icon`）
- **来源**：存量
- **判据**：review-checklist §3（静默降级，无兜底提示）
- **证据**：静态确定 —— `icon` 只校验非空（`:44-46`），除 `circle`/`square`/`person` 外一律原样作为 `d` 属性值；`SvgBuilder.attr` 的转义由 `SvgWriter` 负责（`f_svg/src/SvgAuthoringBuilder.cj:255-259`，不会造成注入），但拼错的形状名会形成非法路径。
- **描述**：`"icon": "persn"` 这类拼写错误不会报错、不会落日志，输出里每个图标都是一个空路径元素（`pictogram-icon` 计数正常、画面全空），排查成本高；文档把"或 SVG path 字符串"写成同一字段，用户无法区分"名字拼错"与"路径写错"。
- **建议**：仅当字符串以路径命令（`M`/`m`/`L`/`C`/`Z` 等）开头才按原始 path 处理，否则抛 `chartInvalidValue("icon", "未知图标")`。

### [轻微] ParetoChart 的"总和必须大于 0"校验重复，关闭累计线时仍做无效计算

- **位置**：`f_chart/src/ParetoChart.cj:91-93` 与 `f_chart/src/ParetoChart.cj:225-227`（同一句文案 `"总和必须大于 0"` 两处）；`:84`（`showCumulative` 尚未读取就调用 `paretoCumulative`）
- **来源**：存量
- **判据**：review-checklist §2（同一错误文案复制）/ §1（无效计算）
- **证据**：静态确定 —— `paretoCumulative` 在 `total <= 0.0` 时抛同文案异常，`draw` 内 `maxValue <= 0.0` 再抛一次；`let showCumulative = root.bool(...)` 在 `:85` 才读取，而 `:84` 已经算完累计值。
- **描述**：两处同义校验的触发顺序不同（`total` 与 `max`），错误路径重复；`showCumulative: false` 的图仍付出一次 O(n) 累计计算与一次 `sortedValues.toArray()` 拷贝。
- **建议**：只保留 `paretoCumulative` 内的校验（或先算 `total` 再分流），把 `paretoCumulative` 调用移进 `if (showCumulative)` 分支。

### [轻微] ParallelCoordinatesChart 允许 `data` 为空数组，与同模块校验口径不一致

- **位置**：`f_chart/src/ParallelCoordinatesChart.cj:96-125`（`data` 元素逐个解析，未校验非空）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验；同类图口径不一致）
- **证据**：静态确定 —— `json.requiredArray("data")` 后直接 `for (row in dataArray.getItems())`，空数组得到 `rows = []`，继续参与维度推断（`hasData` 保持 `false`，范围退化为 0–1）并输出空图；本部分 Pareto（`:49-51`）、Pie（`:59-61`）、PR（`:56-58`）、Probability（`:50-52`）、PDP（`:46-48`）对空 `data` 一律抛 `chartInvalidValue`。
- **描述**：同一份数据形状在 6 张图里有 5 张拒绝、1 张接受，调用方无法用统一规则做前置校验；空输入得到"合法但空白"的 SVG，比抛错更难排查。
- **建议**：补 `if (dataArray.getItems().isEmpty()) { throw chartInvalidValue("${path}.data", "数据不能为空") }`，与其余图对齐。

<!-- 第 33 部分 -->

### [严重][存量] 残差图 / ROC 图 x 轴方向镜像（`LinearScale` 参数顺序与其文档语义相反）

- **位置**：`f_chart/src/RocChart.cj:123`、`f_chart/src/ResidualChart.cj:112`
- **来源**：存量（快照模式无基线；两行均在本部分文件内，`git blame` 只能追到快照提交）
- **判据**：review-checklist §11（契约与实现不符、语义与注释不符）、§10 正确性
- **证据**：静态确定 —— `ChartScale.cj:22` 的注释写明「`topPixel` 对应最大值，`bottomPixel` 对应最小值」，`scale()`（`ChartScale.cj:36-43`）按 `bottomPixel - t*(bottomPixel-topPixel)` 计算。设 `plot.x=60`、`plot.right()=560`：
  - 传 `(plot.x, plot.right())` ⇒ `topPixel=60`、`bottomPixel=560`，`scale(min)=560`（右）、`scale(max)=60`（左）⇒ **值越小越靠右**；
  - 传 `(plot.right(), plot.x)` ⇒ `scale(min)=60`（左）、`scale(max)=560`（右）⇒ 正常方向。
  同模块 `LineChart.cj:177`、`AreaChart.cj:158`、`ScatterChart.cj:128`、`RidgeChart.cj:129` 都用后者；`ResidualChart.cj:112`、`RocChart.cj:123` 用前者。
- **描述**：这两张图的数值 x 轴自右向左递增：ROC 的假阳性率 0 落在右边界、1 落在左边界，曲线与对角参考线整体左右镜像；残差图的「拟合值」轴同样反向。刻度线（`ChartFrame.drawXAxisNumeric`，`ChartFrame.cj:291-309`）用同一个比例尺，因此标签也跟着反向，输出不会报错、只是读图结论被反向。`RocChart_test.cj:60-65` 只统计元素个数，覆盖不到方向。
- **建议**：两处改为 `LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)`；或给 `LinearScale` 增加一个具名构造（`horizontal(min, max, left, right)`）把方向收敛到一处，避免同类调用继续按「x 在前」猜参数。改完补一条断言坐标的用例（如 `x=0` 的元素 `x` 坐标应等于 `plot.x`）。
- **范围外提示**：`grep "let xScale = LinearScale("` 在非 `tui` 代码命中 30 处，两种参数顺序各 15 处，属同一系统性写法分歧，其余 13 处（`PrChart`、`EcdfChart`、`CalibrationChart`、`LiftChart`、`GainChart`、`SurvivalChart`、`VolcanoChart`、`ManhattanChart`、`PdpChart`、`LearningCurveChart`、`LassoPathChart`、`InfluenceChart`、`BlandAltmanChart`）不在本部分，未计入统计。

### [一般][存量] ROC 对角参考线用 y 比例尺映射 x 值

- **位置**：`f_chart/src/RocChart.cj:147-148`
- **来源**：存量
- **判据**：review-checklist §11（边界/语义错配）
- **证据**：静态确定 —— 端点写成 `xScale.scale(xRange[0]), yScale.scale(xRange[0])` 与 `xScale.scale(xRange[1]), yScale.scale(xRange[1])`，第二个坐标把 **x 域**的值喂给了 **y 比例尺**。
- **描述**：x、y 轴范围相同（默认 0–1）时刚好正确；一旦用户写 `"yAxis": {"min": 0, "max": 2}` 或 `"xAxis": {"min": -0.1}`，参考线端点就落在错误的 y 上（例如从 y=0 拉到 y=1，而非 0 拉到 2），不再是「y=x」参考线。这是配置可触发的静默错图。
- **建议**：端点改为 `(xScale.scale(xRange[0]), yScale.scale(yRange[0]))` → `(xScale.scale(xRange[1]), yScale.scale(yRange[1]))`，并补一条 `yAxis.max ≠ xAxis.max` 的用例断言端点 y 坐标。

### [一般][存量] 雷达图忽略 `legend.show` 配置

- **位置**：`f_chart/src/RadarChart.cj:63`
- **来源**：存量
- **判据**：review-checklist §14（配置项被读取却未生效）、§11（契约不符）
- **证据**：静态确定 —— `let legendVisible = series.size > 1`，未与 `config.legend.show` 相与；同模块 `RaincloudChart.cj:148`、`ResidualChart.cj:93`、`RocChart.cj:106`、`ScatterChart.cj:111` 都写成 `config.legend.show && …`。
- **描述**：传 `"legend": {"show": false}` 且有两个以上系列时，图例依然输出；`legend.position` 等配置也被部分绕过（`ChartFrame` 只在 `legendVisible` 为真时生效）。用户无法关闭图例。
- **建议**：改为 `let legendVisible = config.legend.show && series.size > 1`；补一条 `legend.show=false` + 双系列的用例，断言 `class="legend"` 计数为 0。

### [一般][存量] 玫瑰图画布过小时静默输出空图

- **位置**：`f_chart/src/RoseChart.cj:113-122`
- **来源**：存量
- **判据**：review-checklist §11（静默失效）、§3（开关打开走进空分支）
- **证据**：静态确定 —— `maxRadius = minFloat(width-…, height-…-40.0)/2.0 - 20.0` 可能为负；循环里 `if (slice.value > 0.0 && radius > 0.0)` 不满足就什么也不画，函数照常返回完整 SVG（只有背景与标题）。
- **描述**：`width`/`height` 较小时（例如 120×120，减去 padding 与 40 的固定留白后 `maxRadius < 0`），得到一张没有任何扇区、也没有任何报错的图，调用方无法区分「数据为空」与「画布太小」。同模块 `RadarChart.cj:88-91` 对同类情形明确 `throw chartInvalidValue("width", "画布太小…")`，两者行为不一致。
- **建议**：`maxRadius <= 0.0` 时抛出与雷达图一致的 `ChartException(InvalidValue)`；若要保留「空图」语义，至少在返回前给出可观测信号并在文档写明。

### [一般][存量] 桑基图垂直布局与连线偏移没有上限约束

- **位置**：`f_chart/src/SankeyChart.cj:193-215`（层高与 y 起点）、`f_chart/src/SankeyChart.cj:226-234`（出/入边偏移累加）
- **来源**：存量
- **判据**：review-checklist §11（边界越界）、§10 正确性（布局算法）
- **证据**：静态确定 —— 每层 `totalHeight = nodeGap*(k-1) + Σ max(throughput/maxThroughput*maxNodeHeight, 6.0)`，`y = top + (plotHeight - totalHeight)/2.0`；`totalHeight > plotHeight` 时 `y < top`，最后一个节点 `y + height` 必然超过 `bottom`，代码没有任何裁剪或缩放。同一层节点数 `k` 越大越严重（每个节点至少 6px + 12px 间距，`plotHeight=300` 时 `k>16` 即溢出）。第二条：`outOffsets/inOffsets` 按 `strokeWidth+1` 单调累加，且 `strokeWidth = max(link.value/maxFlow*22, 1)` 与节点高度无关，节点出边多时连线带宽总和可远超节点矩形高度。
- **描述**：节点数较多的单层场景下，节点会画到标题区或画布外、互相压盖；连线从节点框外起笔，看起来像连到了相邻节点。输出仍是合法 SVG，不会报错。
- **建议**：`totalHeight > plotHeight` 时按 `plotHeight/totalHeight` 等比压缩（或按层内最大阈值截断并给出「已省略」标记）；出/入边偏移改为按 `node.height / ΣstrokeWidth` 归一化后再定位中心线。补一条「单层 30 节点」的用例断言所有 `rect` 的 `y+height <= plot.bottom()`。

### [一般][存量] 散点图 / 散点矩阵对空 `data` 静默通过，与同模块其余图表契约不一致

- **位置**：`f_chart/src/ScatterChart.cj:75-88`（`parsePoints` 不过滤空数组，`ScatterChart.cj:175-203`）、`f_chart/src/ScatterMatrixChart.cj:77-104`
- **来源**：存量
- **判据**：review-checklist §14（只做了一半的分支 / 契约漂移）、§3（空数据当合法）
- **证据**：静态确定 —— 两处只调 `json.requiredArray("data")`，随后 `for (item in …getItems())`，空数组不产生任何行为；`ScatterChart.cj:221-247` 的 `resolveXRange/resolveYRange` 用 `hasData=false` 兜底成 0–1。对照：`RaincloudChart.cj:71-73`、`ResidualChart.cj:55-57`、`RocChart.cj:56-58`、`RidgeChart.cj:72-74`、`RoseChart.cj:61-63`、`ScatterMatrixChart.cj` 之外的同类图都抛 `chartInvalidValue(…, "数据不能为空")`。
- **描述**：同一份 JSON 契约下，`"data": []` 在 5 张图里是 `InvalidValue`，在散点图/散点矩阵里是「成功但空图」。调用方若靠异常判断数据质量问题，会漏掉这两类。`SankeyChart` 的 `links: []` 同样允许（只画节点），是否属于同类问题需产品确认。
- **建议**：两个 `data` 解析入口补 `if (items.isEmpty()) throw chartInvalidValue("${path}.data", "数据不能为空")`；`links` 若允许为空，请在 `doc/chart-json-spec.md` 明写。

### [一般][存量] 数值轴前置样板在多个图表中整段复制（含 47 处 `xLabelHeight` 字面重复）

- **位置**：`f_chart/src/ResidualChart.cj:78-113`、`f_chart/src/RocChart.cj:91-124`、`f_chart/src/ScatterChart.cj:92-129`；`xLabelHeight` 片段另见 `f_chart/src/RaincloudChart.cj:153-157`、`ResidualChart.cj:104-108`、`RocChart.cj:117-121`、`ScatterChart.cj:122-126`
- **来源**：存量
- **判据**：review-checklist §2（换控制流/跨文件复制、字面量复制）
- **证据**：静态确定 —— 三段代码逐行同构：`xTicks/yTicks = config.*Axis.values.isEmpty() ? chartNiceTicks(...) : ...` → `xLabels` 循环 → `maxYLabelWidth` 循环 → `xLabelHeight = if (labelRotate == 0.0) { fontSize+12.0 } else { 48.0 }` → `ChartFrame(config, legendVisible, maxYLabelWidth+12.0, xLabelHeight)` → 两个 `LinearScale` → `SvgBuilder/ChartSvgKit/drawBackground/drawTitle`，只有变量名与是否有 `time` 轴分支不同。`grep "labelRotate == 0.0"` 在模块内命中 47 个文件，全部是同一段 if-else。
- **描述**：同一套边距/刻度/比例尺装配逻辑散落 47 处，已经出现漂移：`xLabelHeight`、`maxYLabelWidth+12.0`、`legendVisible` 的判定在各图之间不同（见上文雷达图条目），任何一次边距调整都要改 47 个文件且必然漏改。不是「为可读性刻意展开」——它是 300 行级的同构复制。
- **建议**：在 `ChartFrame`（或新 `ChartAxisKit`）里加一个 `internal func numericAxes(config, xRange, yRange): (Array<Float64>, Array<Float64>, Array<String>, ChartFrame)` 之类的入口，把刻度、标签宽度、`xLabelHeight`、`plot` 一次算完；先迁移本部分 3 张图，再按同样方式收敛其余 44 处。差异点（time 轴格式化、`legend.show` 组合）作为参数显式传入，不要靠复制保留。

### [轻微][存量] 插入排序在 4 处换类型复制

- **位置**：`f_chart/src/RocChart.cj:188-203`、`f_chart/src/RaincloudChart.cj:320-335`（另有 `f_chart/src/PrChart.cj:197-212`、`f_chart/src/SurvivalChart.cj:275-290`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 四段函数体逐行一致，仅元素类型（`RocPoint`/`Float64`/`PrPoint`/`SurvivalPoint`）与比较字段（`.x`/自身/`.x`/`.time`）不同；`RocChart.sortPoints` 与 `PrChart.sortPoints` 连参数名、临时变量名都相同。
- **描述**：目前四份实现等价、无行为漂移，但「稳定 + 确定性」这一约定靠四份手写代码各自维持，新增点集类型时会继续复制第五份。
- **建议**：抽一个模块内 `internal func stableSortBy<T>(items: ArrayList<T>, less: (T, T) -> Bool): Array<T>`（保持插入排序实现即可，语义无变化），四处改为传比较器。不要顺手换标准库排序——先证 `std.sort` 在当前 SDK 下的稳定性，否则会改变同 x 重复点的输出顺序、破坏「确定性」用例。

### [轻微][存量] 散点矩阵读入系列名却从不使用，且不画图例

- **位置**：`f_chart/src/ScatterMatrixChart.cj:25`、`30`、`75`、`104`
- **来源**：存量
- **判据**：review-checklist §1（读了不用）、§14（能力接线缺失）
- **证据**：静态确定 —— `grep -n "name" ScatterMatrixChart.cj` 只有定义（25/30）、赋值（75/104）四处，无任何读取点；整个文件没有 `drawLegend` 调用，多系列时颜色与系列名无法对应。
- **描述**：多系列散点矩阵会给每组点不同颜色，但既没有图例也没有标签，读者无法判断颜色归属；`name` 字段是纯死字段。
- **建议**：补 `frame.drawLegend`（或矩阵下方自绘图例）把 `name`/`color` 用起来；若确定不支持多系列，则在解析处直接拒绝 `series.size > 1` 并删掉 `name` 字段。

### [轻微][存量] 玫瑰图错误文案与判据不符

- **位置**：`f_chart/src/RoseChart.cj:88-90`
- **来源**：存量
- **判据**：review-checklist §11（语义与注释/文案不符）
- **证据**：静态确定 —— `if (maxValue <= 0.0) throw chartInvalidValue(…, "数值总和必须大于 0")`，判断的是**最大值**，不是总和。
- **描述**：`[0, 0, 5]` 这类数据总和 > 0 但前两个扇区被静默跳过，报错文案又声称校验的是总和，误导调用方去排查数据求和。
- **建议**：文案改为「最大值必须大于 0」；若确实要拦「全零」，现有判据已覆盖，无需改逻辑。

### [轻微][存量] 雷达图重复计算同一个标签坐标

- **位置**：`f_chart/src/RadarChart.cj:102-107`
- **来源**：存量
- **判据**：review-checklist §2（同文件内同输入同输出的重复计算）
- **证据**：静态确定 —— `point` 与 `labelPoint` 调用参数完全相同（`centerX, centerY, radius, 1.0, index, indicators.size`），随后只用 `labelPoint`。
- **描述**：每绘制一个指标多算一次 `cos/sin`，属可删的重复计算与冗余变量，不影响输出。
- **建议**：删掉 `labelPoint`，直接用 `point`（或把轴端点与标签锚点合并成一次局部变量）。

### [轻微][存量] 测试只统计元素个数，坐标方向与数值无法被覆盖

- **位置**：`f_chart/src/RocChart_test.cj:60-65`、`f_chart/src/ScatterChart_test.cj:41-53`、`f_chart/src/RadarChart_test.cj:55-56`（11 个测试文件同一模式）
- **来源**：存量
- **判据**：review-checklist §10（可测试性）、§11（缺陷未被用例拦住）
- **证据**：静态确定 —— 断言全部形如 `count(svg, "class=\"roc-point\"") == 6`、`svg.contains("女装")`，没有一条断言 `x`/`y` 坐标、刻度顺序或数值区间；上文 x 轴镜像、对角线错位两条缺陷因此全绿。
- **描述**：现有用例能守住「有没有画」和「参数校验」，守不住「画在哪」。这正是本轮两条渲染缺陷存活的直接原因。
- **建议**：每个图表补 1–2 条坐标断言（用 `SvgParser.parse` 取 `circle`/`line` 的 `cx`/`x1` 属性，断言最小值的像素小于最大值），优先补 `RocChart`（x∈[0,1] 边界固定，最容易断言）。

### [轻微][存量] 测试辅助 `draw` / `count` 在 11 个测试文件各写一份

- **位置**：`f_chart/src/RadarChart_test.cj:25-37`、`f_chart/src/RaincloudChart_test.cj:24-36`、`f_chart/src/ScatterMatrixChart_test.cj:24-36` 等 11 处
- **来源**：存量
- **判据**：review-checklist §2（字面量/实现复制）
- **证据**：静态确定 —— 每个测试类的 `private func draw`（一行 `XxxChart().draw(JsonValue.fromStr(json).asObject())`）与 `private func count(svg, needle)`（`indexOf` 循环计数）逐行相同；`grep -rn "func count(svg: String, needle: String)"` 在模块内命中 106 个文件。
- **描述**：测试基础设施被复制 106 份，任何一处修 bug（例如 `count` 用 `needle.toArray().size` 每次重新编码字符串）都要改 106 个地方。属测试代码重复，不影响产品行为。
- **建议**：在 `f_chart/src/testutil`（或测试目录下的 `ChartTestSupport.cj`）提供 `internal func chartCount(svg: String, needle: String)` 与 `internal func drawChart(chart: Chart, json: String)`，各测试文件改为引用。

<!-- 第 34 部分 -->

### [一般][存量] 时序图自调用消息（`from == to`）没有箭头，只剩零长度线段

- **位置**：`f_chart/src/SequenceChart.cj:125-140`（箭头两个分支），`:121-123`
- **来源**：存量（`a1dc954e9`，2026-11-08 `feat(f_chart): M10 时序图`，工作区无改动）
- **判据**：review-checklist §11「边界 / 空集合未处理」、§13「文档承诺与实现不符」
- **证据**：静态确定 —— `toX > fromX` 与 `toX < fromX` 两个分支都不覆盖 `toX == fromX`；`kit.line` 在两点相同时输出 `M x y L x y`，SVG 里不可见。README:2398 明确写「消息为带箭头的水平线」，而 `SequenceChart_test.cj:196` 自己就用 `{"from": "u", "to": "u"}` 且只断言可解析，说明该输入被允许但没有任何可见图形
- **描述**：UML 时序图的自调用是常规写法。当前输入不报错、不警告，参与者生命线上的这段消息只剩一行压在 lifeline 上的标签，读者会误判消息不存在。`messages[].from/to` 也没有任何校验禁止自调用
- **建议**：`toX == fromX` 时画自环（例如向右折返的 `H` 形折线 + 箭头），或至少画一个小回环箭头；同时在 spec 的 `sequence` 小节说明自调用的绘制方式

### [一般][存量] 时序图 `messages[].type` 只认 `return`：spec 承诺的 `async` 无差别渲染，非法值静默接受

- **位置**：`f_chart/src/SequenceChart.cj:124`（`dashed` 判定）、`:208`（`json.string("type", default: "sync")`）；承诺源 `f_chart/doc/chart-json-spec.md:2194`
- **来源**：存量
- **判据**：review-checklist §14.1「只做了一半的分支：枚举新 case 没有分支」、§11「语义与注释不符」
- **证据**：静态确定 —— spec:2194 写「`type` 取 `sync` / `async` / `return`」，但全文件搜 `async` 零命中（只有 `:208` 的默认值 `"sync"` 与 `:124` 的 `== "return"`）；`sync` 与 `async` 生成的 SVG 完全一致，`"bogus"` 之类取值也不报 `InvalidValue`
- **描述**：文档把 `async` 列为可取值，调用方按文档区分同步/异步调用后拿到的图完全一样，属于承诺功能未落地；非法取值被当作 `sync` 处理，错误被推迟到看图时才发现
- **建议**：要么实现 `async` 的差异化（开放式箭头 / 平行双线），要么把 spec 收窄为 `sync` / `return`；同时对 `type` 做白名单校验，非法值抛 `chartInvalidValue("messages[i].type", ...)`

### [一般][存量] 旭日图：环状引用的节点被静默丢弃，而两处「节点关系存在环」守卫实际不可达

- **位置**：`f_chart/src/SunburstChart.cj:99-113`（建树 + `roots.size != 1`）、`:151-153`、`:179-181`（两处 `depth > total` 守卫）
- **来源**：存量（`ed978a37b`，2026-11-08）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达语句」、§11「数据丢失 / 错误处理缺失」、§4「环检测」
- **证据**：静态确定 —— 每个节点最多一个 `parent`，所以从唯一根出发的 `children` 图必然无环，`depth` 最大为 `nodes.size - 1`，`depth > nodes.size` 恒不成立（`total` 参数名是"节点数"，语义是节点计数而非深度上限）。真正的环（如 `a.parent=c`、`c.parent=a` 再加一个独立根）不产生第二个根，`roots.size == 1` 通过，环内节点既不在 `roots` 也不在任何根的子树里，`resolveTotals`/`drawNode` 都碰不到它们
- **描述**：输入含环时既不报错也不提示，图上少掉整块层级数据（数据丢失）；注释声称的「节点关系存在环」保护永远不触发，读者会误以为已经防住。孤立分量同理（只可能由环产生，因为其它孤立节点会成为第二个根而被 `:111` 拦下）
- **建议**：建树后统计「从根可达的节点数」与 `nodes.size` 比较，不等即抛 `chartInvalidValue("nodes", "节点关系存在环或存在不可达节点")`；随后删掉 `:151` / `:179` 两处不可达守卫（或改成固定的深度上限常量，用于防栈溢出，见下条）

### [一般][存量] 旭日图只有根节点时输出空图（无扇环、无提示）

- **位置**：`f_chart/src/SunburstChart.cj:221`（`if (node.depth > 0)`）、`:124-125`
- **来源**：存量（`ed978a37b`）
- **判据**：review-checklist §11「边界 / 空集合未处理」、§14.1「半成品」
- **证据**：静态确定 —— 单节点（`parent: null` + `value > 0`）能通过全部校验（`:155-165` 走叶子分支，`totalDepth` 返回 0，`:124` 兜底为 1），但 `drawNode` 对 `depth == 0` 直接跳过绘制，于是 SVG 里只有背景和标题。`SunburstChart_test.cj:80-93` 正好用这种单节点输入测 `innerRadius` 校验，却没有任何用例断言它画出了东西
- **描述**：合法输入得到"看起来渲染失败"的空图，用户无从判断是数据问题还是实现问题；对单层数据（只有一个汇总值）这是唯一可能的形状，属于功能缺口
- **建议**：`depth == 0` 且无子节点时画一个整圆环（`0 → 2π`）并标注名称；或在校验阶段直接拒绝并给出明确消息，二者取一，不要静默输出空图

### [一般][存量] 茎叶图行布局无裁剪 / 无换列：行数一多就画出画布之外；README 承诺的「长行自动换列」未实现

- **位置**：`f_chart/src/StemLeafChart.cj:104`（`rowHeight`）、`:112-140`（逐行 `y += rowHeight`）、`:126-138`（叶拼成一条 `StringBuilder`）；承诺源 `f_chart/README.md:942`
- **来源**：存量（`e52c6e3db`）
- **判据**：review-checklist §13「文档承诺与实现不符」、§14.1「承诺了但没实现」、§11「布局越界」
- **证据**：静态确定 —— `y` 只增不减，没有与 `config.height` 比较（`config.height` 只用于 `viewBox` 与背景，`:83-90`），没有分列、没有 clipPath；叶只在一个 `StringBuilder` 里用空格连接后单次 `kit.text`，全文件搜 `column` / `clip` 零命中。README:942 写「长行自动换列」
- **描述**：`stemUnit` 小或数据跨度大时（例如 0–10000、`stemUnit=10` 产生上千行），后面的行落在 viewBox 之外被渲染器裁掉，用户只能看到前十几行且不知道还有数据；单个茎上的叶很多时也会横向冲出画布。README 描述的换列能力完全不存在，两条问题叠加使这张图在真实数据下基本不可用
- **建议**：按 `config.height` 计算可容纳行数，超出按列分栏（README 承诺的换列）或按比例压缩行高并给出省略提示；叶按可用宽度分块输出；实现后在 README 与 spec 写明「行数/叶数超限时的行为」

### [一般][存量] 极端但合法的数值在后续运算中溢出，抛出的不是 `ChartException`

- **位置**：`f_chart/src/SpiralChart.cj:41-45`（只校验 `turns > 0`）、`:174`（`turns * 360.0 * index`）、`:121-122`；`f_chart/src/SunburstChart.cj:167-174`（`sum += child.total`）、`:206-208`；`f_chart/src/StemLeafChart.cj:180-181`（`Int64(floor(...))` / `Int64(round(...))`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」「边界越界」；契约源 `f_chart/README.md:255`「任何结构或数值问题都以 `ChartException` 抛出」
- **证据**：静态确定（异常类型可推导）—— `ChartJson.cj:223-225` 只拦 `NaN`/`Inf`，`1e308` 这类有限值放行；`turns = 1e308` 时 `turns * 360.0` 溢出为 `Inf`，再乘 `Float64(0)` 得 `NaN`，`cos(NaN)` 使坐标变 `NaN`，`f_svg/src/SvgNumber.cj:33-35` 的 `formatSvgNumber` 对非有限值抛 `SvgException`；旭日图两个 `1e308` 叶子求和为 `Inf`，`assignAngles` 里 `Inf / Inf` 得 `NaN`，同样落到 `SvgException`；茎叶图 `Int64(1e307)` 触发溢出异常（语言文档 `docs/dev-guide/source_zh_cn/basic_data_type/integer.md`「数值类型之间的转换」注意段：「根据默认的溢出策略将抛出异常」）
- **描述**：调用方按 README 只 `catch ChartException`，遇到上述输入会漏出 `SvgException` / 数值溢出异常直接冒泡，图既不返回也不按契约失败；同时对 `turns`、`yAxis` 数值、茎叶值都缺少量级上限，错误信息里也拿不到是哪个字段越界
- **建议**：在 `ChartConfig.parse` 与各图专属字段处统一加上限（如 `abs(v) <= 1e12`）并抛 `chartInvalidValue`；`SpiralChart` 对 `turns` 增加 `isInf()/isNaN()` 与合理上限（如 ≤ 1000）；茎叶图在做 `Int64` 转换前校验 `stem` 落在 `Int64` 安全区间。更彻底的做法是在 `draw` 外层把 `SvgException` 包装成 `ChartException(InvalidValue)`，保证 README 承诺的单一异常类型

### [一般][存量] 茎叶图参数校验重复三遍，且两处规则不一致

- **位置**：`f_chart/src/StemLeafChart.cj:59-61` 与 `:151-153`（`"数据不能为空"`）、`:73-80` 与 `:154-159`（`stemUnit` / `leafDigits` 同文案）
- **来源**：存量（`e52c6e3db`）
- **判据**：review-checklist §2「跨层复制 / 近似重复：一块少了边界判断」、§11「语义漂移风险」
- **证据**：静态确定 —— 三条错误消息文本完全相同；`draw` 侧 `leafDigits` 还额外校验 `rawDigits != floor(rawDigits)`（`:78`），helper 侧拿到的是已转好的 `Int64`，只校验 `[0, 6]`，两侧规则并不等价；`stemUnit` 判断（`:74` vs `:154`）逐字重复
- **描述**：改一处漏一处就会出现"`draw` 放行、helper 抛错"或反之的行为漂移；`stemLeafRows` 是 `internal` 且被测试直接调用（`StemLeafChart_test.cj:41`）做了防御，`draw` 里的同一套校验就是纯冗余
- **建议**：只保留 `stemLeafRows` 内的校验（它是唯一入口，测试也走它），`draw` 侧删掉重复判断；或反过来把校验抽成 `validateStemLeafOptions(stemUnit, rawDigits)` 一处实现、两侧共用

### [一般][存量] 通用原语被反复手写：插入排序（本部分 4 处 / 全模块 22 处）、唯一性检查 2 处 O(n²)、分组去重线性查找

- **位置**：本部分 4 处插入排序 `f_chart/src/ShapChart.cj:179-187`、`StemLeafChart.cj:164-172`、`SunburstChart.cj:183-191`、`SurvivalChart.cj:280-288`；O(n²) 唯一性检查 `ShapChart.cj:70-74`、`SunburstChart.cj:78-82`；`SunburstChart.cj:141-148`（`findNode` 线性查找）、`StackedAreaChart.cj:313-320`（`groupIndexesOf` 线性查找）
- **来源**：存量
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改类型名 / 字面量复制）」、§6.4「热点里反复 `contains` / 双层循环做去重」
- **证据**：静态确定 —— 全模块 `grep "while (j > 0"` 命中 22 个文件，比较键分别是 `Float64`、`Int64`、`SurvivalPoint.time`、`node.total`，升降序与稳定性假设各写一遍；`ShapChart` 与 `SunburstChart` 的重复检查是同一个"遍历已收集列表 + 字符串相等"结构，只是错误文案不同（"特征 … 重复" / "节点 id 重复"）
- **描述**：同一份排序/去重语义复制 20+ 次，任何一次改动（例如改成稳定排序、加并列处理）都要人工同步；`ShapChart`/`SunburstChart` 的去重是 O(n²) 字符串比较，`n` 由输入特征数/节点数决定，上万条时会成为可见耗时（占比未测，见「待验证假设」）
- **建议**：在 `ChartScale.cj`（或新的 `ChartSort.cj`）提供 `stableSortBy` 与 `indexOfUnique`；去重改用 `HashMap<String, Int64>`（`SequenceChart.cj:63-69` 已经是正确写法，可直接复用该模式）；`SunburstChart` 建 `HashMap<String, SunburstNode>` 后 `findNode` 变 O(1)

### [一般][存量] 堆叠面积图把分组结果算两遍，颜色解析也写两遍

- **位置**：`f_chart/src/StackedAreaChart.cj:104`（`stackedAreaBounds` 内部调 `groupIndexesOf` + `uniqueGroupCount`）、`:157-158`（draw 里再调一次）、`:142-150` 与 `:189-192`（同一套 color 解析）
- **来源**：存量
- **判据**：review-checklist §2「同文件内两两比对函数体的输入-输出-副作用」「同一输入重复计算」、§6.4
- **证据**：静态确定 —— `groupIndexesOf(groups)` 与 `uniqueGroupCount(...)` 的入参完全相同（`:104` 与 `:157-158` 都是 `groups.toArray()`），`StackedAreaChart.cj:310-339` 两函数均无副作用，结果必然一致；颜色：`:146-149` 生成 `colors` 数组后，`:189-192` 又对每个 series 重做同一个 `match`
- **描述**：`groupIndexesOf` 是 O(S²) 线性查找（`:313-320`），`stackedAreaBounds` 里还要按 `groupCount` 维护累计数组，等于把同一份分组信息算两遍；颜色解析重复则让"改配色规则"需要同时改两处，且两处容易漂移（`SurvivalChart.cj:268-273` 的 `colorOf` 已经是抽好的写法）
- **建议**：在 `draw` 里先算 `groupIndexes` / `groupCount` 并以参数传入 `stackedAreaBounds`（或让 `stackedAreaBounds` 返回 `(bounds, groupIndexes, groupCount)`）；颜色统一走 `colorOf` 式辅助函数（见「优化可行性方案」）

### [一般][存量] 生存曲线置信带是直线折线，与阶梯状主曲线几何不一致

- **位置**：`f_chart/src/SurvivalChart.cj:195-215`（band 路径）、对照 `:228-244`（`survival-line` 的阶梯构造）
- **来源**：存量
- **判据**：review-checklist §11「语义与实现不符」、渲染一致性
- **证据**：静态确定 —— band 用 `M` + 逐点 `L` 直接连接每个时间点的上下界，主曲线则对相邻两点插入 `(x_i, y_{i-1})` 形成水平-垂直台阶；两者在同一时刻的边界不重合，band 会在每个区间内斜穿阶梯
- **描述**：开启 `confidence: true` 后，置信区间看起来像普通折线带，与 KM 曲线的阶梯语义矛盾，读者会误读"生存率在区间内线性下降"；在台阶陡降处 band 与曲线的间隙最明显
- **建议**：band 的上/下界都按主曲线的方式生成台阶路径（每个 `time_i` 输出 `L x_i y_upper(prev)` + `L x_i y_upper(i)`），下界逆序回描后闭合

### [一般][存量] 螺旋图与茎叶图自绘标题，通用字段 `title.subtext` / `title.align` 被静默忽略

- **位置**：`f_chart/src/SpiralChart.cj:97-106`、`f_chart/src/StemLeafChart.cj:93-102`；承诺源 `f_chart/doc/chart-json-spec.md:44`（`subtext` 通用字段）、`ChartFrame.cj:98-130`（统一实现含副标题与对齐）
- **来源**：存量
- **判据**：review-checklist §14.1「接线缺失 / 通用能力未接入」、§13「文档承诺与实现不符」
- **证据**：静态确定 —— 两处都手写 `kit.text(config.title, anchor: "middle")`，无 `config.subtitle`、无 `config.titleAlign`；全模块另有 14 个文件同样自绘（`PieChart.cj`、`DonutChart.cj`、`SankeyChart.cj` 等，`grep "config.title.isEmpty()"` 全模块 17 个文件），属跨部分同源问题
- **描述**：spec §2.1 把 `subtext` 定义为通用字段，用户给 `spiral` / `stem-leaf` 配了副标题后图上什么都不出现，且没有任何告警；`align` 同样失效，标题永远居中。这类"通用字段局部失效"最难排查
- **建议**：两图改用 `ChartFrame`（`ChartFrame(config, false, 0.0, 0.0)` 后调 `drawTitle`），保留各自的文本排版；若必须自绘，至少复用 `ChartFrame.drawTitle` 的副标题/对齐分支

### [轻微][存量] 生存曲线置信区间把"数据点个数"当样本量

- **位置**：`f_chart/src/SurvivalChart.cj:196`（`count = points.size`）、`:198`、`:209`
- **来源**：存量
- **判据**：review-checklist §11「注释与实现语义」、统计口径待确认
- **证据**：待确认 —— 代码注释（`:293`）声明是"二项近似"，spec:1794 只写「是否画置信带」，没有规定置信区间的算法与样本量口径；KM 的方差应基于每个时间点的风险集人数（或 Greenwood 公式），而这里用的是整条曲线的点数，且对所有时间点共用
- **描述**：同一系列里早期时间点（风险集大）与晚期时间点（风险集小）的区间宽度完全相同，晚期区间被显著低估；由于没有规格，只能作提示，不能定为错误
- **建议**：明确口径：若坚持二项近似，至少按时间点传入风险集人数；若无法获得，spec 应写明"置信带为示意，非统计推断"

### [轻微][存量] 画布过小时螺旋图半径可为负，生成非法 `r` 值

- **位置**：`f_chart/src/SpiralChart.cj:110-113`、`:146`
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 越界」
- **证据**：静态确定 —— `maxRadius = min(width - padL - padR, height - padT - padB - 40.0) / 2.0 - 30.0`，`width/height` 只校验 `> 0`（`ChartConfig.cj:182`）；默认 `padding` 为 24（`ChartConfig.cj:22-25`），`width = height = 100` 时 `min(52.0, 12.0)/2.0 - 30.0 = -24.0`，即高度小于约 148 时 `maxRadius` 即为负，`spiralPoint` 之后的点坐标全部落在圆心另一侧
- **描述**：`maxRadius` 为负时 `spiralPoint`（`:175`）的半径随序号从负数开始增大，所有点落到圆心另一侧、且最大偏移只有 `|maxRadius|`（上例 24px），整张图缩成圆心附近的镜像小团；`distance` 也随之变小，标签被 `1 + 12/distance` 推到离点 12px 处，文字互相重叠。不崩溃，但输出已无信息量
- **建议**：`maxRadius <= 0` 时抛 `chartInvalidValue("width", "画布过小，无法绘制螺旋图")`，或对 `maxRadius` 设下限（如 ≥ 20）后再计算

### [轻微][存量] SHAP 图的 `features` 字段在 spec 与 README 示例里出现，实现从不读取

- **位置**：`f_chart/src/ShapChart.cj:38-79`（全文件无 `features`）；承诺源 `f_chart/doc/chart-json-spec.md:2115`、`f_chart/README.md:2316`
- **来源**：存量
- **判据**：review-checklist §13「API / 配置与源码不符」、§1「读了不用 / 死配置」
- **证据**：静态确定 —— 全文件搜 `features` 零命中（只有测试样例 JSON 里带着）；特征名实际来自 `series[0].data[].feature`
- **描述**：文档把 `features` 写成专属字段，用户按文档维护这份数组后它完全不参与渲染；两处数据源（`features` 与 `data[].feature`）不一致时也没有任何校验，容易让人以为顺序/子集受 `features` 控制
- **建议**：要么删掉 spec 与 README 里的 `features`（推荐，避免双数据源），要么把它实现为"特征白名单/排序"，并与 `data[].feature` 做一致性校验

### [轻微][存量] 时序图行高压缩到 25px 以下时，备注框与下一行消息标签重叠

- **位置**：`f_chart/src/SequenceChart.cj:114-118`（`rowHeight` 下限无约束）、`:141-147`（标签在 `y - 8`）、`:148-163`（备注框在 `y + 5`、高 20）
- **来源**：存量
- **判据**：review-checklist §11「布局越界 / 重叠」
- **证据**：静态确定 —— `rowHeight = minFloat(40.0, available / messages.size)`，消息多时可为 5–10px，而单条消息纵向占用约 `8 + 20 + 5 = 33px`；没有裁剪、折行或省略逻辑
- **描述**：消息条数多（约 `available/33` 以上）时，备注便签会压到下一条消息的文本上，`note` 与 `text` 都不可读；这是排版降级而非崩溃
- **建议**：`rowHeight` 设下限（如 24px）并在超限时按比例缩减字号或省略备注，或在备注存在时给该行分配更高行高

### [轻微][存量] 两处测试断言偏弱：一条恒真、一条由无关元素满足

- **位置**：`f_chart/src/StackedBarChart_test.cj:59-61`、`f_chart/src/SequenceChart_test.cj:94`
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符」、测试有效性
- **证据**：静态确定 —— `StackedBarChart_test.cj:59-60` 用同样入参调 `stackedBarX` 两次再断言相等，属同义反复（真正有效的是 `:62` 与 `band.center(0) - 15.0` 的比较）；`SequenceChart_test.cj:94` 断言 `count(svg, "stroke-dasharray") >= 2`，但每个参与者的 lifeline 本来就带 `dash: "4 4"`（`SequenceChart.cj:108`），两个参与者即已满足，消息虚线失效也不会被发现
- **描述**：前者删掉也不影响覆盖，后者给了"返回消息虚线已实现"的假保证；`type: "return"` 的虚线行为实际没有有效用例
- **建议**：`SequenceChart_test` 改为断言 `class="message"` 那条线的 `stroke-dasharray`（例如统计同时含 `message` 与 `stroke-dasharray` 的片段，或解析 SVG 后按 class 取属性）；删除 `:59-60` 的恒真断言

### [轻微][存量] 主题河流图图例恒为可见，单系列/空名时白占 26px

- **位置**：`f_chart/src/StreamgraphChart.cj:162`（`ChartFrame(config, true, ...)`）；对照 `f_chart/src/SlopeChart.cj:132`
- **来源**：存量
- **判据**：review-checklist §11「同类实现不一致」
- **证据**：静态确定 —— `SlopeChart` 用 `config.legend.show && series.size > 1`，`StackedAreaChart.cj:112` 用「非单系列空名」，`StreamgraphChart` 直接传 `true`；`ChartFrame.cj:76-83` 在 `legendVisible` 为真时把 `top` 增加 26px，`drawLegend`（`:135`）在 `names` 为空时直接 return，标题区因此留白
- **描述**：只有一个系列（或系列都没 `name`）时，图上多出一段空白，且与同模块其它多系列图表的行为不一致，属观感问题
- **建议**：改为 `config.legend.show && series.size > 1`，与 `SlopeChart` 对齐

> 存量缺陷共 17 条（一般 11 / 轻微 6），是否纳入修复待用户决定。

<!-- 第 35 部分 -->

### [严重][存量] 矩形树图切分错误：面积不按权重，约 38% 画布空白

- **位置**：`f_chart/src/TreemapChart.cj:230`（`let childWidth = width * ratio`）、`:238`（`let childHeight = height * ratio`），循环 `:230-243`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（与规格/README 冲突）+ §6.4（算法实现与声明不符）
- **证据**：静态确定 —— 已入库渲染产物 `f_chart/charts/M034-treemap.svg` 实测（`width=760,height=480`，绘图区 672×352 = 236 544 px²）：
  - `lib`（值 260）329.66×352 = 116 040 px²
  - `bin`（值 120）152.15×111.16 = 16 913 px²
  - `log`（值 90）114.11×99.62 = 11 368 px²
  - `cache`（值 60）76.08×39.85 = 3 031 px²
  - 值比 260:120 ≈ 2.17:1，面积比 116 040:16 913 ≈ 6.86:1；四格合计仅 147 352 px²，**37.7% 绘图区为空白**
- **描述**：切分时子块宽/高用**父级全尺寸**乘「占父级总值的比例」，而不是用「占剩余面积的比例」；用掉一条边后另一个方向仍按全尺寸算，导致先画的子块吃掉几乎整个矩形、后面的子块只剩窄条，且剩余空间不再分配。treemap 的唯一编码方式就是「面积 ∝ 数值」，该实现使面积失真 3 倍以上并留下大片空白，直接违背 `README.md:1450`「层级节点按权重铺满父矩形」。
- **建议**：按剩余量递归：维护 `remainingValue`（未分配子节点值之和）与 `remainingWidth/remainingHeight`，每次 `ratio = nodeValue(child) / remainingValue`，并沿当前较长边切分（squarify 的 strip 版）；补充「面积 = 值 × 单位面积」的几何断言测试（见轻微 #4）。

### [严重][存量] 时间线 `group` 着色哈希溢出抛 ArithmeticException（非 ChartException）

- **位置**：`f_chart/src/TimelineChart.cj:209`（`hash = hash * 31 + Int64(rune.position())`，函数 `eventColor` `:204-214`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界/数值溢出）+ §10（异常契约）
- **证据**：静态确定 —— `f_chart/cjpm.toml` 的 `compile-option = "--dy-std -O2"` 未设 `--int-overflow`，默认 `throwing`（文档 `cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/compile_options.md:233-239`：「指定固定精度整数运算的溢出策略，默认为 throwing…溢出时会抛出异常」）。按 `hash_n ≈ c·31ⁿ/30` 估算：ASCII（c≈100）第 12 个字符后 hash ≈ 2.6e18，第 13 个字符乘 31 即 > 9.22e18；汉字（c≈20000）第 12 个字符后 ≈ 5.2e17，第 13 个字符同样溢出。即 **group 名约 13 个字符就触发**
- **描述**：`events[].group` 是普通字符串标签（`doc/chart-json-spec.md:2221` 明确 `group?`）。名字稍长（如「2026年第一季度营销活动」13 字）时 `hash * 31` 整数溢出，抛 `ArithmeticException`；`Chart.draw` 契约只承诺 `ChartException`（`Chart.cj:33`、`README.md:41`），调用方按 `ChartException` 捕获会漏掉，整个渲染线程异常退出。第 211 行 `config.theme.colorAt(abs(hash))` 在 `Int64.MinValue` 上还会二次溢出/产生负下标（`ChartTheme.colorAt` 用 `index % palette.size`，负数取模仍为负）。
- **建议**：逐步取模，照抄同模块已有写法 `f_chart/src/FlameChart.cj:258`（`hash = (hash * 31 + Int64(byte)) % 1000003`），再 `colorAt(hash)`；或改用 `&*`/`&+` 回绕运算符并显式取 `abs` 前的掩码。补一个 13+ 字符 group 的用例。

### [严重][存量] 矩形树图递归深度由输入决定，深链会栈溢出；`nodeValue` 使每层重复遍历子树

- **位置**：`f_chart/src/TreemapChart.cj:191`（`layoutNode` 递归 `:234`、`:239`）、`:159-172`（`nodeValue` 递归 `:168`）、`:174-189`（`sortChildren` 比较器内 `:181` 反复调 `nodeValue`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4（无界递归）+ §6.4（重复计算）
- **证据**：静态确定 —— 递归深度 = 父子链长度，代码无深度计数、无迭代化、无访问集合；仓颉不保证尾调用优化。按 1 万层链估算：`nodes` 数组 1 万条（JSON ≈ 0.8 MB，完全可解析）即可达 1 万层，`layoutNode` 每帧含 6 个 `Float64` 形参 + 局部变量（数百字节量级）⇒ 数 MB 级栈占用，超过常见线程栈（具体字节数按 SDK/平台待确认）
- **描述**：两处递归叠加：`layoutNode` 每层调用 `nodeValue(node)` 重算整棵子树之和，深链上总代价 O(depth²)；`sortChildren` 的插入排序比较器也每次重算 `nodeValue`。深链既可能先爆栈，也会在爆栈前先表现为二次复杂度耗时。
- **建议**：一次后序遍历把 `value` 缓存进 `TreemapNode`（加 `var total: Float64`），排序前预计算排序键；`layoutNode` 改为显式栈迭代（节点 + 矩形入栈），或加深度上限（如 64 层）超限抛 `InvalidValue`。

### [一般][存量] `TreemapChart` 用实例字段保存绘制状态，违反 `Chart` 纯函数契约

- **位置**：`f_chart/src/TreemapChart.cj:46`（`private var leafIndex: Int64 = 0`）、`:141`（`this.leafIndex = 0`）、`:201-202`（`colorAt(this.leafIndex)` / `this.leafIndex++`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）+ §12.1（共享可变状态）
- **证据**：静态确定 —— `Chart` 契约写明「实现必须保持纯函数语义：不修改 `data`，同一输入产生确定性输出」（`f_chart/src/Chart.cj:24-25`）；本实现在 `draw` 中写 `this.leafIndex`
- **描述**：`draw` 不是纯函数：①同一实例被并发调用时两个线程共享 `leafIndex++`，颜色分配互相污染（确定性输出被破坏）；②`draw` 中途抛异常后实例状态遗留（下次 `draw` 虽会重置，但重入调用会错乱）；③仓内无共享实例的用例，宿主持有单例时才会暴露 ⇒ 并发后果 **待确认**（缺：下游是否缓存 Chart 实例）
- **建议**：`leafIndex` 作为 `layoutNode` 的入参/返回（`func layoutNode(..., leafIndex: Int64): Int64`），或把整个绘制状态收进 `draw` 内的局部 `var`；顺便删掉这个字段。

### [一般][存量] 矩形树图静默丢节点：父链成环、叶子缺 `value` 均无提示

- **位置**：`f_chart/src/TreemapChart.cj:104-117`（只校验 `roots.size == 1`）、`:159-164`（叶子无 `value` 时返回 `0.0`）、`:222-224`（`total <= 0.0` 直接 `return`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失/静默）+ §14.1（规格要求未校验）
- **证据**：静态确定 —— 构造 `root(parent:null)` + `a(parent:"b")` + `b(parent:"a")`：`roots` 仍只有 `root`，校验通过，`a/b` 既不是根也不在 `root` 子树中，`layoutNode` 遍历不到，**不绘制、不报错**。规格要求「叶子必须有 `value`」（`doc/chart-json-spec.md:1318`），但缺失时按 0 处理，子块面积为 0 被静默跳过
- **描述**：两种输入错误都表现为「图少了几块」，使用者得不到任何错误信号，且与同文件对重复 id / 悬空 parent 的严格校验（`:71-75`、`:107-111`）不一致。
- **建议**：解析阶段对叶子强制 `value`（缺失即 `InvalidValue`）；布局前做一次可达性遍历，`visited.size != parsed.size` 时抛 `InvalidValue("nodes", "存在环或不可达节点")`。

### [一般][存量] 火山图 y 轴上下翻转，阈值区与着色区自相矛盾

- **位置**：`f_chart/src/VolcanoChart.cj:157`（`LinearScale(axisMinY, axisMaxY, frame.plot.bottom(), frame.plot.y)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（与规格/注释冲突；渲染方向错误）
- **证据**：静态确定 —— `LinearScale` 自述「`topPixel` 对应最大值，`bottomPixel` 对应最小值」（`f_chart/src/ChartScale.cj:22`），此处把 `plot.bottom()` 当 `topPixel` 传入。已入库产物 `f_chart/charts/M092-volcano.svg` 实测：刻度 `0` 在 y≈-5.8（画布顶），`5` 在 y≈495.8（画布底）；`GENE1`(y=4.1) 圆心 cy=405，`GENE3`(y=0.8) 圆心 cy=74；p 阈值线在 y=124.6
- **描述**：数值越大越靠下，y 轴刻度自上而下递增，与 `README.md:2055`「纵轴为 -log10(p)」及全模块其余图（如 M020 violin 的 0 在 y=432、150 在 y=56）相反。结果是红色「上调」点落在 p 阈值线**下方**、灰色「不显著」点落在线**上方**，同一张图里颜色语义与视觉分区互相冲突，读者会把显著性判反。
- **建议**：改为 `LinearScale(axisMinY, axisMaxY, frame.plot.y, frame.plot.bottom())`；补一个断言「高 y 点 cy 更小」的用例（见轻微 #4）。

### [一般][存量] 华夫图 `cells` / `columns` 无上界：输出体积按格数线性放大，网格可溢出画布

- **位置**：`f_chart/src/WaffleChart.cj:41-50`（只校验 `>= 1` 且为整数）、`:97-107`（`rows`、`cellSize`、`gridWidth`）、`:120-138`（按 `cells` 循环出矩形）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（OOM，须量化）+ §11（缺边界校验）
- **证据**：静态确定 + 输出体积实测 —— 已入库 `f_chart/charts/M073-waffle.svg` 为 100 格 13 963 B，约 **140 B/格**；`cells: 1000000`（20 字节 JSON）⇒ SVG 字符串 ≈ 140 MB，`toSvgString()` 再整体复制一次 ⇒ 峰值 ~280 MB；`cells: 10000000` ⇒ GB 级，必然 OOM 或长时间阻塞。同一处 `columns: 10000` 时 `cell` 被 `maxFloat(..., 1.0)` 钳到 1 px，`gridWidth = 10000 + 2×9999 ≈ 3×columns` px，远超画布，图整体不可见（`WaffleChart.cj:99-107`）
- **描述**：`cells` 只是「总格数」样式参数（默认 100），实现把它当作渲染元素个数且无上限、无「画布能容纳多少格」的钳制。若图表 JSON 来自外部/用户配置（`待确认`），这是一个 7 个数量级的放大面；即使配置可信，误写 `cells: 100000` 也会产出 14 MB SVG。
- **建议**：给 `cells`（如 ≤ 10000）与 `columns`（如 ≤ 200）显式上限并在超限时抛 `InvalidValue`；或按 `plot` 尺寸反推最大可容纳格数 `floor(plot.width/最小格宽) × floor(plot.height/最小格高)` 后钳制，并在 SVG 里注明已降采样。

### [一般][存量] 矩形树图/华夫图自绘标题与图例，绕过 `ChartFrame` 且行为漂移（`subtext`、`align` 丢失）

- **位置**：`f_chart/src/TreemapChart.cj:131-140`（自绘标题）、`f_chart/src/WaffleChart.cj:140-168`（自绘图例）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（跨文件复制同一布局规则导致行为漂移）+ §11（契约不符）
- **证据**：静态确定 —— `ChartFrame.drawTitle`（`f_chart/src/ChartFrame.cj:98-132`）处理 `titleAlign`、`subtitle`，基线为 `padding.top + titleFontSize/2`；`TreemapChart` 固定 `anchor: "middle"`、基线 `padding.top + titleFontSize`，且完全不读 `config.subtitle`/`config.titleAlign`。已入库产物对照：M034 标题 y=42，M092/M016 标题 y=33。`WaffleChart` 自绘图例的换行阈值、色块尺寸（`:150-158`）与 `ChartFrame.drawLegend`（`:134-166`）另一套，且预留高度 28 与 `ChartFrame` 的 26（`:79`、`:88`）不一致
- **描述**：规格承诺 `title.subtext` 与 `title.align` 对全图生效（`doc/chart-json-spec.md:43-44`），矩形树图静默忽略；同一标题在两种图里高度差 9 px。属「重复逻辑导致的行为漂移」，后续修 `ChartFrame` 也修不到这两张图。
- **建议**：`TreemapChart` 改用 `ChartFrame` + `frame.drawTitle(kit)`（绘图区用 `frame.plot` 再内缩即可）；`WaffleChart` 改用 `frame.drawLegend` 或在 `ChartFrame` 中加「带数值/可换行」的可选参数，避免第三套图例布局。

### [一般][存量] 单系列图表把「输入解析 + 数值工具」整段复制到 4 个文件（逐字节相同）

- **位置**：
  - `parseValues`：`f_chart/src/SwarmChart.cj:187-199`、`f_chart/src/ViolinBoxChart.cj:267-279`、`f_chart/src/ViolinChart.cj:240-252`（`diff` 结果逐字节相同）
  - `resolveYRange`：`SwarmChart.cj:201-216`、`ViolinBoxChart.cj:281-296`、`ViolinChart.cj:254-269`（逐字节相同）
  - `sortValues`（插入排序）：`SwarmChart.cj:218-233`、`ViolinBoxChart.cj:298-313`、`ViolinChart.cj:271-286`（逐字节相同）
  - 「series 必须为长度 1 的对象 + 嵌套/扁平分组」前导块：`SwarmChart.cj:45-99`、`ViolinChart.cj:45-99`、`ViolinBoxChart.cj:45-99`（`diff` 仅差类型名 `SwarmGroup`/`ViolinGroup`/`ViolinBoxGroup` 与错误文案里的图名前缀）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（「只改类型名」/「字面量复制」）
- **证据**：静态确定 —— `sed` 取段后 `diff` 三次均无差异（parseValues/sortValues/resolveYRange）；前导块 `diff` 仅 3 处类型名 + 1 处文案差异
- **描述**：同一套「只允许一个系列、嵌套数组与扁平数组二选一、标签长度校验、5% padding 的 y 范围」规则在 4 个文件各写一遍，任何一处修（例如给 `resolveYRange` 加 `isNaN` 校验、把插入排序换成标准排序）都要改 4 遍，现实是已经出现漂移：`BoxScatterChart.cj` 的同名私有函数也是同一份拷贝。范围外的 `ProbabilityChart.cj:156`、`QQChart.cj:156` 的 `sortValues` 同体。
- **建议**：在 `f_chart/src` 内新增包内工具（如 `ChartSeries.cj`：`chartParseSeries`、`chartValues`、`chartResolveYRange`、`chartSortValues`），落点遵守「通用能力留在本模块 util」；`SwarmGroup/ViolinGroup/ViolinBoxGroup` 三个只有 `name+values` 的类可合并为一个 `NamedValues`。

### [一般][存量] 小提琴图与「小提琴+箱线图」的核密度轮廓绘制 47 行逐字节相同

- **位置**：`f_chart/src/ViolinChart.cj:165-211` 与 `f_chart/src/ViolinBoxChart.cj:166-212`（`diff` 仅差 `className: "violin"` / `"violin-box-violin"`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复 → 行为漂移风险）
- **证据**：静态确定 —— 两段 `sed` 后 `diff` 只有第 45 行 className 不同；两图 90% 的 `draw` 主体（解析、y 范围、坐标框、图例、KDE 采样 41 点、路径拼接）同样对齐，差异点仅：`showOutliers`/须线与端帽、箱宽 0.1 vs 0.12、`quantileSorted` vs `boxScatterBounds`
- **描述**：`violin` 是 `violin-box` 关闭箱线与异常值的特例，现在是两份实现：`violin-box` 的采样点数、填充透明度、路径拼接方式一旦修改，`violin` 不会同步。两图测试也只覆盖各自的 class 名，漂移无法被发现。
- **建议**：把「组解析 + KDE 轮廓 path」抽成包内函数（如 `chartViolinPath(group, center, maxHalf, yScale, bandwidth): String`），两图共用；或让 `ViolinChart` 内部委托 `ViolinBoxChart` 的绘制步骤并传 `showBox=false, showOutliers=false`（需先把 className 参数化，避免破坏已入库 SVG 的 `class` 契约）。

### [一般][存量] `tiling` 只实现 `squarify`，规格承诺的 `slice` 直接报错

- **位置**：`f_chart/src/TreemapChart.cj:118-121`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现）
- **证据**：静态确定 —— 承诺源 `doc/chart-json-spec.md:1318`「专属字段：`tiling`（`squarify` / `slice`，默认 `squarify`）」；实现 `if (tiling != "squarify") { throw chartInvalidValue("tiling", "目前仅支持 squarify") }`，全仓搜 `"slice"` 在 `f_chart/src` 无命中
- **描述**：按规格写 `"tiling": "slice"` 的调用方会收到 `InvalidValue`。要么补实现（slice-and-dice 只需按单一方向切分，代码量很小），要么把规格改成只列 `squarify`。
- **建议**：补 `slice` 分支（沿长边单方向顺序切分），或在 `doc/chart-json-spec.md` 与 README 中删掉 `slice` 并说明「仅支持 squarify」。

### [轻微][存量] 未使用的通配 import `std.math.*`

- **位置**：`f_chart/src/SwimlaneChart.cj:19`、`f_chart/src/TreemapChart.cj:19`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 两个文件内搜 `abs(|floor(|ceil(|round(|sqrt(|pow(|log10(|minFloat(|maxFloat(` 均无命中，文件内只有 `Float64` 算术
- **描述**：通配 import 不报错但会扩大名字解析面，也掩盖真实依赖。
- **建议**：删除这两行。

### [轻微][存量] 泳道名不做截断，长名压到节点区

- **位置**：`f_chart/src/SwimlaneChart.cj:182-189`（横向泳道名）、`:198-206`（纵向泳道名）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性/渲染边界）
- **证据**：静态确定 —— 横向预留 `laneLabelWidth = 90.0`（`:169`），但泳道名直接用 `kit.text(...)` 全量输出，没有 `orgFitLabel`；同文件的节点标签用了截断（`:319`）
- **描述**：泳道名超过约 7 个汉字就画进节点区，与节点矩形重叠；同一张图里节点标签会省略、泳道标签不会，规则不一致。
- **建议**：泳道名套 `orgFitLabel(lane.name, laneLabelWidth - 16.0, fontSize)`。

### [轻微][存量] 瀑布图标签优先规则写了两遍，`starts/ends` 该用 `let`

- **位置**：`f_chart/src/WaterfallChart.cj:106-111`（`defaultName` 用 `labels[index]`）与 `:132-135`（`axisLabels` 又用 `labels[position]` 覆盖 `points[position].name`）；`:118-119`（`var starts` / `var ends` 从未重新赋值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同一规则复制）+ §1（`let`/`var` 惯用法，轻微）
- **证据**：静态确定 —— 两处都表达「xAxis.labels 优先于 item.name」；`starts`/`ends` 只调 `.add()`，可变性只需容器内部可变
- **描述**：规则改一处漏一处就会导致刻度名与柱名不一致；`var` 让读者以为会被整体重新赋值。
- **建议**：`axisLabels` 直接用 `points[position].name`（保留 `name` 缺省即用 `labels[index]` 的既有规则），删除重复循环；两处改 `let`。

### [轻微] 本部分测试只断言 class 名出现次数，几何/方向类缺陷零覆盖

- **位置**：`f_chart/src/TreemapChart_test.cj:59-61`、`f_chart/src/VolcanoChart_test.cj:65`、`f_chart/src/SwarmChart_test.cj:51`、`f_chart/src/SwimlaneChart_test.cj:68-69`、`f_chart/src/WaterfallChart_test.cj:63-66`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可测试性）+ 本报告严重 #1、#3 与一般 #3 均因此未被发现
- **证据**：静态确定 —— 测试全部用 `count(svg, "class=\"...\"")` 计数或 `contains(text)`，没有任何 `<rect>` 坐标/面积、`cy` 相对顺序的断言
- **描述**：本报告列出的「面积不按权重」「y 轴翻转」都能在保持 class 计数不变的前提下存在，因此测试通过不代表渲染正确。
- **建议**：为 treemap 加「面积比 ≈ 值比（误差 ≤ 1%）」「所有子块面积之和 == 绘图区面积」；为 volcano 加「y 更大的点 cy 更小」；为 waffle 加「cells 超上限抛 InvalidValue」。
- **备注**：`f_chart/src/WaterfallAlias_test.cj` 与本模块 `WaterfallChart_test.cj` 高度重复，但已核对为设计约定（`README.md:726`「别名：M87 也使用 `waterfall`，复用 `WaterfallChart`」、`doc/spec/add-f-chart-calendar-alias/design.md:13`「别名里程碑的预期冗余」），**不计入重复逻辑问题**。

<!-- 第 36 部分 -->

### [一般][存量] 百分比堆叠把负值静默丢弃，整列可能什么都不画

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:200-222`（`positive` 只累加 `value > 0.0`，随后 `if (value <= 0.0 || positive <= 0.0) { continue }`）、`f_chart/src/tui/ComboChart.cj:303-325`（同一逻辑的第二份）
- **来源**：存量（快照模式无基线；两段均在快照提交内，`git blame` 追到 `f4e27a68c5` 2026-11-09）
- **判据**：review-checklist §11（数据静默丢失 / 语义与命名不符）、§10 正确性
- **证据**：静态确定 —— 非百分比路径显式维护 `negativeBase`（`TuiBarRenderer.cj:230-234`）来堆负值，百分比路径却直接 `continue`：负值既不进 `positive` 分母，也不产生任何柱体；当某类目全为负值时 `positive == 0`，该列完全没有输出。
- **描述**：`"type":"percent-stacked-bar"` 且数据含负值（如 `[30, -20, 50]`）时，渲染结果只含正值的相对占比（30/80、50/80），负值那一层凭空消失，且没有异常、没有日志；同一份数据在 `"type":"stacked-bar"` 下会正常画出负向柱。调用方无法从输出判断数据被丢弃，属静默错图。现有用例 `TuiBarChart_test.cj` / `TuiComboChart_test.cj` 只喂正数与 null，覆盖不到。
- **建议**：先定口径再改代码——① 若要支持正负混排：`positive += abs(value)`、负值走 `negativeBase` 并按 `abs/positive` 归一化（与 `stacked` 分支结构一致）；② 若不支持：在 `canvas()` 解析阶段对 `PercentStacked` 的负值直接 `throw chartInvalidValue("series.data", "百分比堆叠不支持负值")`。两条都比当前「默默丢」好；改完补一条含负值的用例，断言输出行数与分母口径。

### [一般][存量] 组合图堆叠槽位只按 `stack` 分组、不看 `axis`，跨轴同组系列共用一个比例尺

- **位置**：`f_chart/src/tui/ComboChart.cj:244-259`（分组键 `key = stack.isEmpty() ? name : stack`，未拼 axis）、`f_chart/src/tui/ComboChart.cj:280-282`（`let scale = if (first.rightAxis) { rightScale } else { leftScale }`）、`f_chart/src/tui/ComboChart.cj:229-243`（percent 槽位按 `mode == "percent"` 全并）
- **来源**：存量
- **判据**：review-checklist §11（配置可触发的静默错图）、§10 正确性（布局算法）
- **证据**：静态确定 —— 解析阶段只校验「`axis: right` 必须有 `yAxis2`」（`ComboChart.cj:97-100`），没有校验「同一 stack 组必须同轴」；`buildBarSlots` 合并条件只有 `existing.mode == "stacked" && existing.key == key`，把左右轴的同名/同 stack 系列并进一个槽位；`drawBars` 之后整槽统一用 `first.rightAxis` 决定比例尺，后续成员一律按该比例尺投影。
- **描述**：`[{name:"占比", type:"stacked-bar", stack:"s", data:[10,20]}, {name:"占比", type:"stacked-bar", stack:"s", axis:"right", data:[3000,4000]}]` 这类输入会被接受，但第二个系列按左轴（0–20 量级）投影 3000 → 严重超出绘图区后被 `clampTuiRow` 贴到边界，结果是「一根贴顶的柱」而不是右轴比例下的柱。`percent` 槽位同理（所有 `percent-stacked-bar` 不分轴合并）。输出仍是合法字符画，不报错。
- **建议**：分组键改为 `"${axis}:${key}"`（`axis` 取 `left`/`right`），或在 `buildBarSlots` 前直接拒绝「同 stack 键跨轴」的组合并给出 `chartInvalidValue("series.axis", …)`；percent 槽位同样按轴拆开。补一条左右轴同 stack 的用例，断言两个槽位列不重叠。

### [一般][存量] TUI 画布尺寸只有下限没有上限，`TuiCanvas` 按 `width × height` 直接预分配

- **位置**：`f_chart/src/ChartConfig.cj:180-184`（只校验 `width > 0 && height > 0`）、`f_chart/src/tui/TuiCanvas.cj:33-43`（`while (index < width * height) { list.add(TuiCell()) }` → `toArray()`）、`f_chart/src/tui/TuiFrame.cj:71-73`（只校验 `< 20 / < 8`）
- **来源**：存量
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）、§11（缺少边界校验）
- **证据**：静态确定 —— 分配量 = `Int64(width) * Int64(height)` 个 `TuiCell` 对象（每个含 2 个 `String` 引用 + 1 个 `Bool`，对象头另计），再加一次 `ArrayList → Array` 的等长指针数组拷贝（`TuiCanvas.cj:42`，`toArray` 语义见 `std/collection/collection_package_class.md` 「func toArray(): Array<T>」）。全链路没有任何上限常量或配置项；`ChartConfig` 是 `Chart` 公共接口的唯一入口，外部可传任意 `width/height`。
- **描述**：`{"type":"bar","width":20000,"height":20000}`（合法 JSON、通过全部校验）会尝试构造 4×10⁸ 个 `TuiCell`，按每对象 ≥24B 估算即 ≥9.6GB，单次请求直接 OOM；`width*height` 在 Int64 上溢出时按仓颉默认策略（`docs/dev-guide/source_zh_cn/reflect_and_annotation/anno.md:88`「默认采取抛出异常」）抛 `ArithmeticException`，同样是一次请求打崩。仓内现有调用方 `fprobe/src/tui/ChartPanel.cj:77-96` 用终端尺寸（有界），所以实际风险取决于宿主；**若 JSON 的 width/height 来自终端用户或 LLM 输出，本条应升级为「严重」**。
- **建议**：在 `ChartConfig.parse` 或 `TuiFrame.init` 增加上限（例如 TUI 场景 `width ≤ 500 && height ≤ 200`，与终端现实尺寸同阶），超限抛 `chartInvalidValue`；`TuiCanvas` 内部对 `width*height` 做乘法前的除法校验，避免溢出。

### [一般][存量] `tuiStripAnsi` 遇到孤立 ESC（后一字节不是 `[`）进入死循环

- **位置**：`f_chart/src/tui/TuiColor.cj:59-75`，关键在 `else` 分支 `70-72`：`let start = index; while (index < bytes.size && bytes[index] != 0x1B) { index++ }`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 死循环）、§10 正确性
- **证据**：静态确定 —— 进入 `else` 的条件是「`bytes[index]` 不是 ESC，或 ESC 后没有 `[`，或 ESC 是最后一个字节」；当 `bytes[index]` 本身就是 0x1B 时，内层 `while` 的首次判断即为假，`index` 一步都不前进，`builder.append(bytes[start..index])` 追加空串，外层 `while (index < bytes.size)` 于是永久自旋。`0x1B` 后跟 `[` 但序列里没有 `m` 时还有第二个问题：`62-67` 会吞掉其后全部文本（`index` 直接到 `bytes.size`）。
- **描述**：任何含孤立 ESC 的文本（JSON 里写 `"\u001b"` 做标题、或标签里混入控制字符）都会让 `tuiStripAnsi` / `tuiPlainLines` 永久挂死。当前 `tuiStripAnsi` 只被测试（`TuiBarChart_test.cj:47` 等）与 `tuiPlainLines`（`TuiColor.cj:81`）调用，生产渲染路径（`TuiCanvas.render`）不经过它，所以定为「一般」；但它是 `internal` 工具，宿主一旦拿它清洗用户文本就会挂死。
- **建议**：`else` 分支前补 `if (bytes[index] == 0x1B) { index++; continue }`（跳过孤立 ESC），并把「ESC 后无 `[`」与「CSI 无 `m`」都按「跳过一个字节」处理；补一条 `tuiStripAnsi("a\u{1B}b") == "ab"` 的用例，避免以后再靠人眼。

### [一般][存量] 词云 `rotate: -90` 的词条沿基线向上生长，溢出为它预留的行盒

- **位置**：`f_chart/src/WordCloudChart.cj:133-142`（`angle != 0` 时 `boxWidth = fontSize`、`boxHeight = chartTextWidth(...)`）、`f_chart/src/WordCloudChart.cj:163-171`（`kit.text(anchorX, cursorY, …, rotate: angle)`，默认 `anchor: "start"`、`dominant-baseline: middle`）
- **来源**：存量
- **判据**：review-checklist §11（坐标越界）、§10 正确性（布局算法）
- **证据**：静态确定 —— SVG 的 `rotate(a)` 正值顺时针；文本基线方向为局部 +x。`-90°` 把 +x 映射为屏幕 `(0,-1)`，即文字从 `cursorY` **向上**排布，占据 `[cursorY - textWidth, cursorY]`；而布局按 `[cursorY, cursorY + boxHeight]` 记账（`rowHeight`、`cursorY + boxHeight > plot.bottom()` 的裁剪判断都基于后者）。`+90°` 才是向下排布、与记账一致。
- **描述**：配置显式允许 `-90`（`WordCloudChart.cj:64` 校验集合为 `{0, 90, -90}`），但 `-90` 的词条会画到自己行盒之外：首行直接顶到 `plot.y` 以上（进入标题区甚至 `y < 0`），其余行压到上一行的词上——而词云本来的取舍就是「靠盒不重叠」。`boxHeight` 的取值同时参与换行/裁剪，所以底部的溢出判断对 `-90` 完全失效。现有用例 `WordCloudChart_test.cj:75-77` 只统计 `rotate(90 ` 出现 3 次，`-90` 没有任何坐标断言。
- **建议**：`-90` 时锚点取盒底 `cursorY + boxHeight`（或改用 `text-anchor: end`），使文字向上排满同一盒；两条分支统一写成一个局部 `textAnchorY`。补一条 `rotate:[-90]` 的用例，断言输出里该 `text` 的 `y` 等于行盒底部坐标。

### [轻微][存量] 堆叠柱的累积/归一化逻辑在 TuiBarRenderer 与 TuiComboChart 各写一份

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:196-249`（`drawStacked` 的类目循环）与 `f_chart/src/tui/ComboChart.cj:301-351`（`drawBars` 的 `else` 分支）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/跨文件复制）
- **证据**：静态确定 —— 两段逐行同构：`positive` 汇总 → `positiveBase/negativeBase` → `isPercent/ slot.mode == "percent"` 决定归一化 → `from/to` → 两次 `clampTuiRow` → `tuiFillColumn(…, tuiSeriesSymbol(idx))`。差异只有三点：模式用 `enum BarMode` 还是 `String`、外层是「类目 → 系列」还是「槽位 → 类目 → 槽位成员」、符号下标取 `seriesIndex` 还是 `slot.indexes[index]`。上文「负值静默丢弃」因此也存在两份（已合并成一条）。
- **描述**：这一份逻辑已经出现「一处有 `isPercent()` 辅助、另一处靠字符串比较」的表示分歧；本次修负值口径必须同时改两处，漏一处就是两张图行为不一致。不是「为可读性刻意展开」——单段 50 行以上。
- **建议**：在 `TuiChartCommon` 抽 `internal func tuiStackSpan(mode: TuiStackMode, values: Array<?Float64>, from: Int64, to: Int64): Array<(Float64, Float64)>`（返回该区间每层的 `from/to`），调用方只负责取颜色/符号与画列；先迁移 `TuiBarRenderer`，再让 combo 复用。

### [轻微][存量] 「系列数与 labels 对齐」的校验三份、图例名/色收集四份

- **位置**：校验：`f_chart/src/tui/TuiBarRenderer.cj:78-87`、`f_chart/src/tui/ComboChart.cj:111-120`、`f_chart/src/tui/LineChart.cj:45-54`（三处错误文案字面相同：「数据长度必须与 xAxis.labels 一致」）；图例收集：`TuiBarRenderer.cj:105-110`、`ComboChart.cj:166-171`、`LineChart.cj:66-71`、`ScatterChart.cj:44-49`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换类型名）
- **证据**：静态确定 —— 三处都是「`count = max(series.size)` → `tuiResolveLabels(config, count)` → 逐系列 `if (item.values.size != labels.size) throw chartInvalidValue("series.data", "数据长度必须与 xAxis.labels 一致")`」，只有取值字段名（`values` / `points`）不同；四处图例收集都是「`for (item in series) { names.add(item.name); colors.add(item.color) }` + `tuiLegendVisible`」。`TuiChartCommon.cj:36-45` 已经有 `tuiResolveLabels`，说明作者本来就在收敛，只差最后一层。
- **描述**：目前三处等价、无行为漂移，但三处的 `count` 初值写法不同：`TuiBarRenderer` 用 `series[0].values.size`，`ComboChart`/`LineChart` 用 `1`，后续任何一处放宽（例如允许缺省末尾值）都会变成三套契约。属可维护性，不影响当前输出。
- **建议**：`TuiChartCommon` 加 `internal func tuiAlignedLabels(config: ChartConfig, sizes: Array<Int64>): Array<String>`（内部做 max + 全等校验 + 统一错误文案）与 `tuiLegendEntries(series)`；四处直接替换。

### [轻微][存量] 区间夹取函数 4 份实现（`clampTuiRow` / `clampTuiColumn` / `clampWordCoordinate` / `TuiFrame.clampRow`）

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:260-268`、`f_chart/src/tui/LineChart.cj:153-161`、`f_chart/src/WordNetworkChart.cj:237-245`（本部分内三份；范围外另有 `f_chart/src/tui/TuiFrame.cj:239-247`、`f_chart/src/NodeLinkChart.cj:265-275`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 只改边界方法名）
- **证据**：静态确定 —— 四段函数体完全一致：`if (value < min) min else if (value > max) max else value`；差异只有参数类型（`Int64` vs `Float64`）与边界取 `plot.right()/bottom()` 还是直接传 `minimum/maximum`。
- **描述**：同一语义四份实现，新增图型时继续复制第五份；其中 `clampTuiRow`（`TuiBarRenderer`）与 `clampTuiColumn`（`LineChart`）分居两个文件，靠 import 包内可见互相借用，命名也不统一（`Row`/`Column` 表达的是坐标轴，不是夹取语义）。
- **建议**：在 `TuiChartCommon` 提供 `internal func clampInt64(value, minimum, maximum)` 与 `internal func clampFloat64(...)`（或两个 `@Overload`），四处改为调用；跨包外两处可在合并报告里一并列出。

### [轻微][存量] `TuiBarSeries.stack` 解析后从未被读取（死字段）

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:27`（字段声明）、`33`（构造函数赋值）、`73`（`json.string("stack", default: "")`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置字段）
- **证据**：静态确定 —— `grep -rn "\.stack" f_chart/src/tui` 只命中 `ComboChart.cj:43/245`（另一个类 `TuiComboSeries`）与 `TuiBarRenderer.cj:33`；`TuiBarSeries.stack` 在全仓（排除 `.worktrees`）没有任何读取点。`drawStacked` 对同图所有系列一律堆进同一列，从不看该字段。
- **描述**：柱状图族接受 `series[].stack`（与 combo、SVG 版一致）但 TUI 实现静默忽略：写 `"stack":"a"` / `"stack":"b"` 的两组系列仍会被堆到一根柱上，用户以为按组分开。当前 SVG 版 `BarRenderer.render(…, BarMode.Stacked)` 同样不分堆叠组，所以更像「字段尚未接线」而不是单侧漂移。
- **建议**：二选一——① 删掉字段与 `json.string("stack", …)`，并在 `doc/chart-json-spec.md` 写明 TUI/`stacked-bar` 不支持分组；② 按 `stack` 拆多个堆叠组（与 combo 的 `buildBarSlots` 对齐），同时补 SVG 版。不要保持「解析了但不用」。

### [轻微][存量] 柱宽下限 1 列，在系列/类目数接近绘图区列数时柱体互相覆盖

- **位置**：`f_chart/src/tui/TuiBarRenderer.cj:163-164`（`slotWidth = band.bandWidth / slotCount`；`barWidth = max(floor(slotWidth * 0.6), 1)`）与 `f_chart/src/tui/ComboChart.cj:276-277`（同型）
- **来源**：存量
- **判据**：review-checklist §11（边界/数值）、§10 正确性（渲染布局）
- **证据**：静态确定 —— `slotWidth = band.bandWidth / slotCount`，`barWidth = max(floor(slotWidth * 0.6), 1)`，所以只要 `slotWidth < 1` 就有 `barWidth(1) > slotWidth`，相邻槽位的 `x` 间距不足 1 列，`tuiFillColumn` 后写覆盖先写。两个触发面：① 60 列画布（`plot` 约 50 列）配 60 个系列时 `slotWidth ≈ 50/60 ≈ 0.83`，全部柱压进同一两列，只剩最后一个系列的符号；② 60 个类目时 `bandWidth ≈ 0.83`，柱宽 1 列同样跨类目重叠。
- **描述**：极端参数（类目数或系列数 ≥ 绘图区列数）下柱状图退化成「一列色块」，且跨类目的柱也会互相覆盖；没有降级策略（省略类目、强制堆叠）也不报错。这不是性能问题，是可视结果失真，属边界补强。
- **建议**：`slotWidth < 1` 时按比例丢弃/合并（例如最多渲染 `floor(bandWidth)` 个槽位并在标题区标注「已省略 N 个系列」），或直接 `throw chartInvalidValue("width", "绘图区过窄，无法容纳 N 个系列")`；`bandWidth < 1` 时同理处理类目。补一条 60 系列 × 60 列的用例断言不会所有柱重叠在同一列。

### [轻微][存量] 词云不校验「词盒 vs 绘图区」，超宽首词越界、超高首词直接输出空图

- **位置**：`f_chart/src/WordCloudChart.cj:133-150`
- **来源**：存量
- **判据**：review-checklist §11（边界越界 / 静默失效）、§3（失败路径当成功）
- **证据**：静态确定 —— 换行条件 `if (cursorX > frame.plot.x && cursorX + boxWidth > frame.plot.right())` 要求「不是本行第一个词」，因此单行首个词 `boxWidth > plot.width` 时永远不换行，直接画到 `plot.right()` 之外（只能靠 SVG viewBox 裁掉）；高度方向 `if (cursorY + boxHeight > frame.plot.bottom()) { break }` 在首词就成立时立刻跳出，输出只有背景与标题——按 `ChartFrame` 的边距算式（`ChartFrame.cj:67-91`：`top = padding.top(24) + titleFontSize+6`，`bottom = padding.bottom(24) + 0`），`height=120` 且带标题时 `plot.height = 120-48-24 = 48 < maxFontSize(默认 64)`，第一个词就会被跳过。
- **描述**：同一张图在「画布够大」时正常，缩到词盒放不下就变成一张空图，调用方无法区分「词表为空」「画布太小」「全部词被裁掉」；越界词条则是渲染到画布外的不可见文本（不计入可见结果却计入 `word-cloud-word` 计数，测试仍会通过）。
- **建议**：进入循环前算 `requiredMin = minFontSize`（含 `chartTextWidth` 的最长词）并与 `plot` 宽高比较，不满足时抛 `chartInvalidValue("width"/"maxFontSize", "画布无法容纳词云")`；单行首词超宽时按 `plot.width` 截断（`tuiTruncate` 同款语义）或缩小字号重排。补一条 `height=120` 的小画布用例，断言抛异常而不是返回空图。

### [轻微][存量] 词云 `type` 别名的三元表达式含恒等分支，且 `type` 被解析两次

- **位置**：`f_chart/src/WordCloudChart.cj:41-43`
- **来源**：存量
- **判据**：review-checklist §1（恒真分支 / 重复读取）、§10 可读性
- **证据**：静态确定 —— `let expectedType = if (chartType == "tag-cloud") { "tag-cloud" } else { "word-cloud" }`，真分支等于 `chartType` 本身，等价于 `chartType == "tag-cloud" ? chartType : "word-cloud"`；紧接着 `ChartConfig.parse(data, expectedType)` 内部又 `requiredString("type")` 重读同一字段（`ChartConfig.cj:171`）。
- **描述**：意图是「`tag-cloud` 是 `word-cloud` 的别名」（`TagCloud_test.cj` 直接构造 `WordCloudChart` 验证这一点），但写法让人以为两个分支都要算，别名机制也只在这一处内联。不影响行为。
- **建议**：改为 `if (chartType == "tag-cloud") { chartType } else { "word-cloud" }` 并加一行注释说明别名来源；若模块已有别名约定（见 `TagCloud_test.cj`、`FunnelAlias_test.cj`），把「接受别名」的判断收敛到一处 helper，`draw` 里只保留一行。

> **范围外提示（不计入统计）**：`f_chart/src/tui/TuiText.cj:65` 的 `tuiPadRight` 全仓无引用；`f_chart/src/tui/TuiFrame.cj:43/47` 的 `TuiRect.centerX/centerY` 无引用（`TuiFrame` 内部只有 `clampRow` 在用）。两者不在本部分文件清单内，留给对应部分处理。

<!-- 第 37 部分 -->

### [严重][存量] 画布尺寸与层高直接由 JSON 数值转 Int64，无上界校验 → 巨量分配 OOM / 溢出异常逃出 `ChartException` 契约

- **位置**：`f_chart/src/tui/TuiFrame.cj:74`（`let width = Int64(config.width)` / `:75` `Int64(config.height)`）、`f_chart/src/tui/TuiFlameChart.cj:73`（`TuiCanvas(Int64(config.width), Int64(config.height))`）、`f_chart/src/tui/TuiFlameChart.cj:81`（`Int64(floor(configuredHeight))`
- **来源**：存量（快照模式无基线；相关行属 2026 TUI 首版，全仓仅此一份实现）
- **判据**：review-checklist §5「按不可信长度预分配」+ §11「契约与实现不符」；`integer.md:137`（`D:/docs/work/cangjie/cangjie-doc/cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/integer.md`）明确「类型转换时可能发生溢出……否则根据默认的溢出策略将抛出异常」
- **证据**：静态确定 —— `ChartConfig.cj:182` 只校验 `width <= 0.0 || height <= 0.0`，全模块（`grep "MAX\|上限" f_chart/src/tui/*.cj` 无命中）没有任何上界；`TuiCanvas` 构造函数按 `width * height` 逐个 `add(TuiCell())`
- **描述**：`{"width": 100000, "height": 100000}` 这类合法 JSON 会通过全部校验，随后分配 10^10 个 `TuiCell`（每格 2 个 String 引用 + Bool，数十字节量级），直接触发堆耗尽；`{"width": 1e30}` 则在 `Int64(...)` 处按默认溢出策略抛 `OverflowException`。`Chart.draw` 的契约（`Chart.cj:33`「@throws ChartException 输入结构或数值不合法时抛出」）要求调用方只需处理 `ChartException`，此处会泄漏其它异常类型。所有 TUI 图表共用同一路径（`TuiBarChart`/`TuiLineChart` 等同样先建 `TuiFrame` 再建 `TuiCanvas`），本部分以火焰图为代表位置
- **建议**：在 `ChartConfig` 或 `TuiFrame` 构造里加常量上限（例如 `width <= 1000 && height <= 500`，超出抛 `chartInvalidValue("width"/"height", …)`），并把 `Int64(...)` 转换移到位阶校验之后；`frameHeight` 同样先判 `<= 上限` 再取整

### [一般][存量] 火焰图的环检测分支不可达，含环输入被静默丢弃而不是报错

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:173`（`if (depth > total)`）、`:191`（同）、`:153`（`resolveRoot`）
- **来源**：存量（`FlameChart.cj:167-194` 有完全相同的实现，属同一设计）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达语句」+ §11「错误处理缺失或静默」
- **证据**：静态确定 —— 每个节点只有单一 `parentId`（`parseNodes:123-133`），把 `parentId` 连成有向边后图是「森林 + 若干环」；`roots.size == 1` 时环必然不在根的可达子树内，`validateTree`/`assignDepth`/`layoutNode` 只沿 `children` 自根下探，永远走不到环，因此 `depth > total`（`total = nodes.size`，合法树最大深度只能是 `nodes.size - 1`）恒为假
- **描述**：`nodes` 中若存在一个根加一组互指的节点（例如 `a.parent=b, b.parent=a`），三个校验函数都不会抛「节点关系存在环」，环内节点既不进 `boxes` 也不占深度，最终渲染出一张缺少这些节点的图且无任何提示。这条 `throw` 是唯一对外承诺的环错误，实际不可达
- **建议**：装配完 `children` 后按「已访问集合」做一次显式遍历（或直接校验「每个节点从根可达且访问次数为 1」），环/不可达节点抛 `chartInvalidValue("nodes", "存在环或孤立节点")`；同时删掉 `depth > total` 这两处死分支

### [一般][存量] 树递归的三处实现深度完全由输入决定，无固定上限

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:172-188`（`validateTree`）、`:190-198`（`assignDepth`）、`:200-225`（`layoutNode`，此函数连 `depth` 判据都没有）
- **来源**：存量
- **判据**：review-checklist §4「无界递归：深度由输入决定」+「尾递归不能当保险」
- **证据**：静态确定 —— 递归深度 = 输入树的链长，唯一「上限」是 `depth > total`（`total = nodes.size`），即链长 N 允许 N 层调用，常量层面没有任何截断
- **描述**：`nodes` 是一条 10^4 量级的长链时，三个函数各需要等量栈帧（`layoutNode` 每帧还有 `Float64`/`Int64` 局部量），可触发栈溢出崩溃，且崩溃点是 panic 而非 `ChartException`。正常火焰数据链深通常只有数百层，故定为「一般」，但输入若来自外部（profile 文件、LLM 生成）即等同严重
- **建议**：装配阶段先算层深并设常量上限（例如 256/512），超限抛 `chartInvalidValue("nodes", "层级过深")`；或把 `validateTree`/`assignDepth`/`layoutNode` 改为显式栈迭代

### [一般][存量] 节点名、标题、轴标签原样进入 ANSI 输出，未过滤控制字符 → 终端转义注入与行结构破坏

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:264-267`（`canvas.putText(..., box.node.name, ...)`）、`f_chart/src/tui/TuiFrame.cj:124-126`（`config.title`/`config.subtitle`）、`f_chart/src/tui/TuiFrame.cj:190-199`（类目标签）
- **来源**：存量
- **判据**：review-checklist §10「安全性：外部输入未校验」；`TuiCanvas.putText:96-106` / `render:178-201` 只按 `tuiRuneWidth` 排布，符号字符串原样 append
- **证据**：静态确定 —— 颜色走 `tuiAnsiForeground` 的 `SvgColor.parse` 再拼 RGB（`TuiColor.cj:28-35`，无注入面），但文本路径整条链上没有任何 `0x1B`/`\n`/`\r` 过滤（`grep` 全包只命中 ANSI 生成与 `tuiStripAnsi` 两处）
- **描述**：`{"name": "\u001b[2J\u001b[H"}` 或内含 `\n` 的节点名/标题会原样写进返回串：前者可在渲染方的终端清屏、改光标、写 OSC 序列；后者会撑破「每行恰好 width」的行模型（`TuiFlameChart_test` 断言的 25 行随之失效）。同时 `tuiDisplayWidth` 把 ESC 当 1 列，截断与居中都会错位
- **建议**：在 `TuiCanvas.putText`（或 `tuiTruncate` 入口）统一剔除 `U+0000–U+001F`、`U+007F`、`U+009B`，或把控制字符替换为 `?`；该修法同时覆盖柱/线/散点等其它 TUI 图

### [一般][存量] 火焰图节点解析与校验逻辑与 SVG 版 `FlameChart` 逐行重复

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:99-198`（`parseNodes` / `findNode` / `resolveRoot` / `validateTree` / `assignDepth`）对照 `f_chart/src/FlameChart.cj:53-124`、`:158-194`
- **来源**：存量
- **判据**：review-checklist §2「跨文件复制：只改类型名」——两处 `parseNodes` 的字段校验顺序、错误文案（`"节点 id 重复"`、`"父节点 ${parentId} 不存在"`、`"必须恰好有一个根节点"`、`"节点 ${node.id} 的值小于子节点之和"`、`"期望字符串或 null"`、`"节点值必须大于 0"`）、容差常量 `1e-6` 完全一致；`validateTree` 与 `validateValues` 除函数名外逐字相同
- **证据**：静态确定 —— 已逐段比对两个文件体量（本部分 `:99-198` vs `FlameChart.cj:53-124` + `:158-194`），差异仅在 `maxDepth` 写法（`if` 表达式 vs `for + if`）
- **描述**：同一份 JSON 契约维护两份实现，已出现的漂移是「TUI 版用 `for + if` 求 maxDepth、SVG 版用三元式」；上文两条缺陷（环检测失效、递归无上限）也因此在两处同时存在，修一处不改另一处就会行为分叉
- **建议**：把 `parseNodes` / `resolveRoot` / 环与深度校验提到 `fountain::f_chart` 的 internal 助手（与 `FlameNode`、`flameColorIndex` 同包），TUI 与 SVG 共用；`layoutNode` 保持各自实现（一个是列区间、一个是像素区间，属真实差异）

### [轻微][存量] 死代码：`tuiPadRight` 与 `TuiRect.centerX/centerY` 无任何调用者

- **位置**：`f_chart/src/tui/TuiText.cj:65-78`（`tuiPadRight`）、`f_chart/src/tui/TuiFrame.cj:43-49`（`TuiRect.centerX` / `centerY`）
- **来源**：存量
- **判据**：review-checklist §1「`internal` 按本包及子包内无调用者判」
- **证据**：静态确定 —— `grep -rn "tuiPadRight" f_chart/src` 只命中定义行；`grep -rn "centerX()\|centerY()" f_chart/src/tui` 只命中 `TuiFrame.cj:43/47` 两处定义（`ArcChart.cj:127` 等命中是 SVG 侧 `ChartRect.centerX()`，不同类型）
- **描述**：`TuiRect` 本身被 `LineChart.cj:153`、`TuiBarRenderer.cj:260`、`TuiFrame` 使用，但两个取中心点的辅助从未被调用；`tuiPadLeft` 有调用（`TuiFrame.cj:174`），`tuiPadRight` 没有
- **建议**：删除三处；若确定要保留给后续按宽度补空白的场景，改成有调用方的公共助手并补用例

### [轻微][存量] 未使用的 import：`TuiText.cj:18`

- **位置**：`f_chart/src/tui/TuiText.cj:18`（`import std.collection.ArrayList`）
- **来源**：存量
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 文件内只用到 `StringBuilder`、`Rune`（prelude），无 `ArrayList` 出现
- **描述**：多余 import，`cjlint` 会报未使用
- **建议**：删除该行

### [轻微][存量] `TuiFrame` 尺寸校验的错误路径固定写 `"width"`，无法定位到真正越界的字段

- **位置**：`f_chart/src/tui/TuiFrame.cj:71-73`（`config.height < 8.0` 也抛 `chartInvalidValue("width", …)`）、`:103-105`（`plotHeight < 1` 也报 `width`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」；`ChartException.path` 是调用方定位字段的唯一线索
- **证据**：静态确定 —— 两个 `if` 都覆盖宽高两个条件，`path` 实参恒为 `"width"`
- **描述**：`{"width": 80, "height": 5}` 报 `path="width"`，使用者会去改宽度而不是高度；绘图区过小同理
- **建议**：拆成两个分支分别报 `"width"` / `"height"`；绘图区不足时用 `"height"`（TUI 下几乎总是行数不够）或 `"size"`

### [轻微][存量] 图例配置只部分生效：`position` 除 `"bottom"` 外一律当顶部，`orient`/`itemGap`/`markerSize` 被忽略

- **位置**：`f_chart/src/tui/TuiFrame.cj:88-99`（`position != "bottom"` ⇒ 占顶部行）、`:147-164`（游标步长硬编码 `+2`、色块固定 `"■"`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」；`ChartConfig.cj:105-108` 接受任意 `position` 字符串且不校验取值
- **证据**：静态确定 —— `ChartLegend` 有 `position`/`orient`/`itemGap`/`markerSize` 四个字段，`TuiFrame` 只读 `position` 且只区分 `"bottom"`
- **描述**：`"legend": {"position": "right"}` 会静默变成顶部横向图例；`itemGap`/`markerSize` 写多少都不影响输出。用户按 SVG 版经验配置会得到不一致结果，且没有任何告警
- **建议**：在 `TuiFrame` 构造处对不支持的取值抛 `chartInvalidValue("legend.position", "TUI 仅支持 top / bottom")`，或按 `orient` 实现左右分栏；`itemGap` 至少接到游标步长上

### [轻微][存量] `tuiRuneWidth` 用单一阈值 `0x2E80` 判宽字符，半角片假名与组合符宽度算错

- **位置**：`f_chart/src/tui/TuiText.cj:21-27`
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 语义与命名不符」（函数注释「CJK/全角按 2 列，其余按 1 列」）
- **证据**：静态确定 —— `rune.position() >= 0x2E80` 这一段覆盖了 U+FF61–U+FF9F（半角片假名，终端实际 1 列）与 U+FFE0 起的一部分符号，同时对 U+0300 起的组合符（实际 0 列）返回 1
- **描述**：标签里出现半角片假名时 `tuiDisplayWidth` 高估 1 列/字，`tuiTruncate` 会提前截断、`putText(align: "middle")` 居中偏左；组合符则会占掉一格并把后续字符整体推后。普通中英混排（模块主要用例）不受影响
- **建议**：按 East Asian Width 分类表实现 `tuiRuneWidth`（至少排除 `0xFF61-0xFFDC`、把 `U+0300-036F`/`U+200B-200F` 记 0）；若暂不做，在 `TuiText.cj` 头注释里写明该近似只保证 BMP 汉字的宽度

### [轻微][存量] 测试断言弱于用例名，无法证明被测行为

- **位置**：`f_chart/src/tui/TuiPercentStackedBarChart_test.cj:66-80`（`skipsZeroTotal`）、`f_chart/src/tui/TuiScatterChart_test.cj:91`（`handlesNegativeY`）
- **来源**：存量
- **判据**：review-checklist §3「有没有用例覆盖」的反面——用例在，但不校验声明的行为
- **证据**：静态确定 —— `skipsZeroTotal` 输入为 `[10,0]`，第一位非零必然画柱，`@Assert(...contains("█"))` 对「零和类目被跳过」无鉴别力；`handlesNegativeY` 的 `contains("-5") || contains("0")` 中 `"0"` 几乎必然命中（轴刻度含 0）
- **描述**：两条用例即使实现回退成「零和类目不跳过」「负值不绘制」也会通过，回归无保护
- **建议**：`skipsZeroTotal` 改为断言纯文本中第二列区域（B 类目）没有任何柱体符号；`handlesNegativeY` 断言 `-5` 刻度存在且负值点位于 0 行下方

### [轻微][存量] 两个测试文件逐字复制 `count` 辅助，且循环内重复 `toArray()`

- **位置**：`f_chart/src/tui/TuiLineChart_test.cj:29-37`、`f_chart/src/tui/TuiScatterChart_test.cj:29-37`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」；差别仅在所在文件
- **证据**：静态确定 —— 两个函数体逐行一致，`from = index + needle.toArray().size` 每轮重新分配字节数组
- **描述**：测试辅助重复，匹配逻辑（子串重叠、多字节 needle）以后只需修一处会漏另一处
- **建议**：提到 `TuiCanvas_test` 同包的 internal 测试助手（例如 `TuiTestSupport.cj`）并改为 `from = index + needle.size`（`String.size` 即字节长度，无需 `toArray`）

> 范围外提示（不计入统计）：`TuiFlameChart` 是 public `Chart` 实现，仓内唯一使用方是 `TuiGallery_test`/`TuiFlameChart_test`；`fprobe/src/tui/ChartPanel.cj:84-87` 的 TUI 分发只支持 `bar`/`line`，未接火焰图（对外 API 本身不算缺陷，仅提示接线现状）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

> 本部分唯一文件是英文 README，没有可改的 `.cj`，因此**堆内存 0 条 / CPU 0 条**。核对时读到的 `pathCentroid`（`ChoroplethChart.cj:176`）对每个 region 做一次全路径字符扫描，输入规模是 region 数 × 路径点数、只在 `draw` 时跑一次，没有 profile 数据，不构成优化项；性能类结论一律见「待验证假设」。

### [维护性] 用一条单测把「文档字段表 ↔ 源码解析键」双向锁死

- **现状**：`README_en.md` 3156 行、110 个 JSON 示例、169 个源码解析键，全靠人工同步。本轮机械比对就抓到 10 个字段漏文档（#7）、3 处字段有文档无实现（#2、#3、#4）、1 处能力过描述（#1）——都是"改了代码没改文档"的同一根因
- **方案**：新增 `f_chart/src/ChartDocs_test.cj`：①断言 README 里 102 个 `f_chart/src/*.cj` 路径都存在（本轮 102/102 通过）；②用 `JsonValue.fromStr` 解析全部 110 个 ` ```json ` 块（本轮 0 个坏块），断言 `type` 在支持集合内；③提取源码全部 `<field>("…")` 字段名与 README 全文求差集，非空即失败（本轮会精确报出 #7 的 10 个）；④反向维护一份"已文档化但实现忽略"的白名单（`series[].label`、`lane`、`features`、combo 的 `area`），新条目必须显式登记，逼作者二选一（接线或删文档）
- **预期**：把 #1–#4、#7 从"下轮人工发现"变成提交即红；102 个实现文件与 102 条附录条目目前是人肉维持的不变量，可交由测试守护
- **代价**：约 100-150 行测试 + 一份白名单；字段名提取用正则，动态拼键需白名单；测试从"只依赖 src"变成"依赖仓库根文件"，只打包 `src` 的发布流程需跳过该用例
- **验证**：`cd f_chart && cjpm test` 全绿；人为删掉 README 里一个字段名，用例应精确报出该字段
- **证据状态**：`无基线（新增能力，非性能项，不进 tasks）`

<!-- 第 3 部分 -->

本部分只有 `.md`，没有可执行的分配 / 循环 / 布局代码，**堆内存 0 条、CPU 0 条**。核对时读到的 `SankeyChart` 布局、`PieChart` 弧路径、`ChartFrame` 边距计算等实现均属其他子轮文件；scope 也未提供 f_chart 的 `cjprof` / `cjpm bench` 数据，任何"热点 / 降内存"结论都不成立，故不预置方案。

### [堆内存] 无

- 本部分无 `.cj`，没有可测量的内存契约。

### [CPU] 无

- 同上。若后续子轮在 `SankeyChart`（布局遍数）或各图刻度/路径生成上取得自耗时占比，须按 `perf §6.1` 补齐工具、输入规模与对照后再立项。

<!-- 第 4 部分 -->

> 不是缺陷，是「还能更好」。两条都**没有**改前/改后测量数据，因此只作方案登记，不改写成收益结论。

### [堆内存] Bland-Altman 同一批测量对在内存里存了 3 份

- **现状**：`BlandAltmanChart.draw` 同时持有 `pairs: ArrayList<BlandAltmanPair>`（每项 2 个 `Float64` 字段的对象）、`rawPairs: ArrayList<Array<Float64>>`（每项一个 2 元素 `Float64` 数组），随后 `pairs.toArray()` 与 `rawPairs.toArray()` 各再复制一份（`BlandAltmanChart.cj:59-75`）；`blandAltmanStats` 内部又建 `diffs: ArrayList<Float64>`（`226-232`）。即 n 个测量对 → 约 3n 个 `Float64` 值 + 2n 个对象头 + 4 次容器扩容复制，且 `pairs` / `rawPairs` 在整段绘制期间都存活。
- **方案**：`blandAltmanStats` 直接吃 `ArrayList<BlandAltmanPair>`（`diff` 字段已在），删掉 `rawPairs`；`pairs` 用 `toArray()` 后的数组传给 `stats`，不保留两份表示。
- **预期**：n 个测量对的常驻对象数从约 2n 降到 n（少一半容器与对象头），临时分配从 4 次容器复制降到 1 次。
- **代价**：`blandAltmanStats` 的签名变化影响其单元测试（`BlandAltmanChart_test.cj:83-107` 目前直接传 `Array<Array<Float64>>`），需同步改用新入参；语义不变。
- **验证**：同一份 10 万点输入连续渲染 100 次，比较 `getAllocatedHeapSize()` 峰值与稳定态 RSS，同时断言 SVG 输出字节完全一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 8 份插入排序合并成一次 `O(n log n)` 排序

- **现状**：`BoxScatterChart.sortValues`（`245-260`）等 8 处实现都是插入排序，复杂度 `O(n²)`；`BoxScatterChart` 对每个分组各排一次（`163`），组内样本数由用户数据决定，无上限。
- **方案**：抽 `internal func sortedFloats(values: Array<Float64>): Array<Float64>`，8 处替换；排序基元换成标准库排序，`quantileSorted` 语义（最近秩取下标）不变。
- **预期**：单组 n 个样本的比较次数从 `n²/4` 量级降到 `n log n`，n = 10 000 时约 3 个数量级的比较次数差；由于整个 `draw` 还包含 SVG 字符串拼接，端到端收益需实测。
- **代价**：输出必须逐字节可复现（SVG 是快照资产），需确认稳定排序后重复值顺序不影响任何 class 序列；`quantileSorted` 的取值口径不允许变化。
- **验证**：`cjpm bench -O2`，同一份 JSON（含 1/10/100 组 × 10/1000/10000 样本）跑改前改后，取中位数与 P95；再比对 107 个快照 SVG 的 diff 为空。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

本部分只有 `.md`，没有可执行代码，也没有改前 / 改后测量数据，**不提出任何性能或内存方案**。审查中看到的三个复杂度线索（日历图同日求和与逐格查找、逐格拼 SVG 串、和弦图 `findNode` 重复线性查找、校准图插入排序）因缺少自耗时占比，按铁律全部只写进「待验证假设」，不在此处包装成结论。

### [堆内存] 无

- 本部分无 `.cj`；#4 的区间无上限是缺陷（OOM 面），不是「还能更省」的优化项，已计入「发现」。

### [CPU] 无

- 同上。相关代码属其他子轮文件，其收益必须以 `cjprof` / `cjpm bench` 对照为前提，本部分不预置数字。

<!-- 第 6 部分 -->

> 不是缺陷，是"还能更好"。全部缺改前基线，只作为下一轮补数据的候选。

### [堆内存] `confusionNormalize` 对 `none` 模式也整表复制，矩阵在绘制期存在 3 份副本

- **现状**：`draw` 里每行先 `ArrayList<Float64>` 再 `toArray()`（`ConfusionMatrixChart.cj:71-86`），得到 `matrix`；随后 `rawMatrix = matrix.toArray()`（`:89`）；`confusionNormalize` 无论模式都会新建 `rows × cols` 的 `ArrayList` 并 `toArray()`（`:192-199`），`none` 模式完全可以直接返回入参。N×N 的 `Float64` 装箱数组在 N=100 时是 1e4 个元素 × 3 份。
- **方案**：`none` 模式在 `confusionNormalize` 开头直接 `return matrix`；行构造改成先取 `cells.size` 再填 `Array<Float64>(n, repeat: 0.0)`，去掉 `ArrayList → toArray` 的中转；`rawMatrix` 与 `displayMatrix` 合并为一个变量。
- **预期**：绘制期矩阵副本从 3 份降到 1–2 份，减少 O(N²) 的临时分配；峰值内存与 GC 次数下降。
- **代价**：几乎没有语义变化（`none` 返回入参后调用方不得原地修改，当前调用方只读）。
- **验证**：对 N=100/500 的矩阵连续 `draw` 1e4 次，比较 `getAllocatedHeapSize()` 增量与 RSS 稳态（`mem §1.2`）；同时断言归一化输出与原实现逐元素一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 节点 id 去重与 `findNode` 改一次建索引，替掉 3 处 O(n²) 去重与每条链接 5 次线性查找

- **现状**：`ChordChart.cj:82-86`（解析期 O(n²)）、`:107-113` 与 `:170-183`（每条链接 5 次线性 `findNode`）；`CirclePackingChart.cj:74-78`、`:137-144`；`ChoroplethChart.cj:82-86`。输入规模：和弦/桑基类图常见 10²–10³ 节点与链接。
- **方案**：解析时用 `HashMap<String, Int64>` 同时完成去重与建索引，后续按 id 取下标 O(1)；`ChordChart` 的链接解析直接保存 `sourceIndex`/`targetIndex`，画带时不再回查（`ChordLink` 增加两个 `Int64` 字段）。
- **预期**：解析与绘制从 O(n²)/O(m·n) 降到 O(n+m)；具体占比未知，需要 profile 才能给端到端数字。
- **代价**：多一个 `HashMap`（O(n) 内存）；`findNode` 的 `?T` 版本若保留需维持两种语义。
- **验证**：`cjpm bench -O2` 对照 200/1000/5000 节点的和弦图 `draw`，记录中位数与 P95，并断言 SVG 输出逐字节一致（当前实现是确定性的）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ComboChart` 每次 `draw` 把柱组重复构建 4 次

- **现状**：`buildBarGroups` 在 `resolveAxisRange`（`ComboChart.cj:376`，左右各一次即 2 次）与 `drawBars`（`:498-499`，再 2 次）里各调一遍，一次 `draw` 共 4 次构建，每次都重新扫全部系列并新建 `ComboBarGroup`/`ArrayList`。
- **方案**：在 `draw` 开头构建一次 `leftGroups`/`rightGroups`，作为参数传给 `resolveAxisRange` 与 `drawBars`；顺带让 `drawBarGroups` 拿到全局槽位信息（与缺陷 #2 的修法同源）。
- **预期**：组合图绘制期少 3 次 O(series) 扫描与相应分配；系列数少时收益有限。
- **代价**：`resolveAxisRange` 签名变化（内部方法，无对外影响）。
- **验证**：`cjpm bench -O2` 对照 20 系列 × 50 类目的 `draw`，看中位数变化是否超出噪声（<5% 不做）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 7 部分 -->

> 不是缺陷，是"还能更好"。本部分无改前基线，全部只作为下一轮补数据的候选。

### [CPU] 核密度图把同一组密度值算了两遍，可复用峰值扫描的结果

- **现状**：`DensityChart.draw` 先对每个系列的 101 个 `x` 求一次 `gaussianKde`（`DensityChart.cj:141-151`，只为拿 `maxDensity`），随后 `drawDensity` 对**同一个** `xMin/xMax` 再求一遍（`:244-248`）；每次 `gaussianKde` 对全部样本做一遍 `exp`（`:272-283`）。规模：`2 × 101 × Σn_i` 次 `exp`，单系列 1e4 个样本即约 2×10^6 次。
- **方案**：在峰值扫描阶段把每个系列的 101 个 `Float64` 密度存进 `ArrayList<Array<Float64>>`（101×系列数，量级 KB），`drawDensity` 直接复用；两处 `x` 完全同源（都由 `xMin/xMax` 线性生成），无精度差异。
- **预期**：`exp` 调用减半，绘制阶段 CPU 约降一半（**仅本函数内**，端到端占比未知）。
- **代价**：多保留 `101 × 系列数` 个 `Float64` 峰值（可忽略）；`drawDensity` 签名改为接收密度数组，失去「独立重算」的自校验性（可用断言替代）。
- **验证**：`cjpm bench -O2`，10 系列 × 1e4 样本的 `draw`，改前改后各 10 轮取中位数与 P95，并断言 SVG 逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 8 部分 -->

本部分只有变更 spec 文档，没有可执行代码，也没有改前 / 改后测量数据，**不提出任何性能或内存方案**（避免把"文档措辞"包装成优化项）。

### [堆内存] 无

- 本部分无 `.cj`，spec 中也未包含可测量的内存契约。

### [CPU] 无

- 同上。若后续子轮在 `src/**` 命中渲染热点，其结论须带 `cjprof` / `cjpm bench`（`-O2`）数据，本部分不预置假设。

<!-- 第 9 部分 -->

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

<!-- 第 10 部分 -->

### [堆内存] 增益图每个数据点一个 2 元素 `Array<Float64>`

- **现状**：`GainChart.cj:48-61` 先把每点存成 `Array<Float64>`（`[x, y]`，2 元素堆对象 + 外层 `ArrayList`），再经 `sortLiftPoints` 复制一份 `ArrayList` 后 `toArray()`；n 个点约 2n 个小数组 + 2 个指针数组常驻到绘制结束
- **方案**：改用 `struct GainPoint { let x: Float64; let y: Float64 }`（值类型，`Array<GainPoint>` 一次分配），排序后不再复制
- **预期**：n=10⁴ 时少约 2×10⁴ 次小对象分配与约 1.6×10⁵ 字节头开销（按 8 字节头 + 2×8 字节载荷粗算），峰值分配量随 n 线性下降；对 SVG 字符串长度无影响
- **代价**：`sortLiftPoints` 为 `LiftChart` 共享函数，需保留旧重载或同步改 `LiftChart`；改动后 `GainChart` 与 `LiftChart` 的数据结构要一致演进
- **验证**：同输入（1k / 1万 / 10万点）跑 `cjpm bench -O2` 对照 `getAllocatedHeapSize()` 与 RSS，中位数取 5 轮
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sortLiftPoints` 用插入排序处理增益/提升曲线

- **现状**：`f_chart/src/LiftChart.cj:203-218` 为插入排序，最坏 O(n²)；`GainChart.cj:61` 每次绘制都调用一次，输入是调用方给的完整点集
- **方案**：换成标准库排序（按 `x` 升序），保留「相等 `x` 保持原顺序」的稳定语义
- **预期**：n=10⁴ 且逆序输入时比较次数从约 5×10⁷ 降到约 1.3×10⁵；端到端收益取决于排序在总耗时中的占比（未测）
- **代价**：需确认 std 排序为稳定排序，否则同 `x` 的点绘制顺序会变（影响折线形状）
- **验证**：`cjpm bench -O2`，输入 1k/1万/10万、正序/逆序/随机三种分布，对照 `GainChart.draw` 总耗时与 `sortLiftPoints` 分段计时
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 11 部分 -->

本部分 20 个文件全部为规格文档，自身没有运行期堆分配与 CPU 开销，**无方案**（0 条）。文档中出现的复杂度线索属代码文件，已放「待验证假设」，不计入优化方案统计。

<!-- 第 12 部分 -->

> 本部分无 profile / bench 数据，以下三条均为「无基线（待验证）」，**不进 `todo.md` / `tasks.md`**。

### [CPU] 蜂巢图 / 冰柱图的节点 id 查找是线性扫描，整体 O(n²)

- **现状**：`HiveChart` 建节点时逐个比对 id（`87-91`，O(n²)），每条链接校验两端各调一次 `findNode`（`113-118`），绘制时再各调一次（`194-195`），`findNode` 全表扫描（`215-222`）⇒ O(n² + m·n)。`IcicleChart` 建树时每个有父节点的节点调一次 `findNode`（`98`，扫描 `157-164`）⇒ O(n²)。n、m 由输入决定，典型规模 10²–10⁴
- **方案**：解析阶段建 `HashMap<String, Int64>`（id → 下标），重复 id 在插入时抛错，后续全部 O(1) 查表
- **预期**：O(n²) → O(n + m)；n = 5000、m = 10000 时比较次数由约 5×10⁷ 降到 1.5×10⁴ 量级（复杂度推导，非实测收益）
- **代价**：多一个 map（与节点数组同量级）；`HashMap` 迭代顺序不参与输出，不影响确定性
- **验证**：`cjpm bench -O2` 跑 n ∈ {100, 1000, 5000, 10000}，取中位数与离散程度；断言 `draw` 输出逐字节不变（可复用现有确定性用例）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 热力图每格重复解析三个颜色字符串

- **现状**：`HeatmapChart.cj:156` 每格调用 `heatmapColor`，后者在 `:233-235` 对 low/mid/high 各做一次 `SvgColor.tryParse`；200×200 矩阵 ⇒ 120 000 次解析，而颜色在一次渲染内不变
- **方案**：`draw` 内解析一次，新增 `heatmapColorOf(ratio, low: SvgColor, mid: SvgColor, high: SvgColor)`，原 `heatmapColor` 保留给 `DifferentialFlameChart` / `HeatFlameChart`
- **预期**：解析次数由 `3×rows×cols` 降到 3；端到端降幅取决于解析在渲染总耗时中的占比（未测）
- **代价**：多一个 `internal` 函数，无 API 变更
- **验证**：`cjprof record` 渲染 200×200 热力图，看 `SvgColor.tryParse` / `heatmapColor` 自耗时占比；`cjpm bench -O2` 改前后中位数对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 渲染前的数据多留一份副本：`toArray()` 与双重容器

- **现状**：`HeatmapChart` 用 `ArrayList<Array<Float64>>` 存矩阵（每行一次 `toArray()`，`68-88`），行数组与 `ArrayList` 底层数组同时存活到 `draw` 结束；`HistogramChart` 把输入先收进 `ArrayList<Float64>` 再 `toArray()`（`70-82`）；`Histogram2DChart` 同理（`95-107`、`288-310`）。峰值约为「原始 JSON 数字 + 解析副本 + 分箱数组」三份并存
- **方案**：`values` 用 `Array` 一次分配（先取 `items.size` 再填充），省掉扩容期临时容量；`HeatmapChart` 改一维 `Array<Float64>` + `rowCount * columnCount` 索引，去掉每行小数组的对象头
- **预期**：`ArrayList` 扩容峰值约降 30–50%，热力图再省 `rowCount` 个数组对象。**缺改前 `getAllocatedHeapSize()` / RSS 基线，不能写成确定收益**
- **代价**：一维索引牺牲可读性（可与 #13 一并做）；分箱数组无法省掉
- **验证**：同输入（10 万数字矩阵 / 100 万样本直方图）多轮 `draw`，对比 `getAllocatedHeapSize()`、`getUsedHeapSize()`、RSS 的稳态与峰值；`-O2`、同机器
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 13 部分 -->

> 本部分只有规格文档，没有独立实现与基线，因此不产出堆内存 / CPU 方案。文档里能看出的实现侧改进线索（插入排序、路径字符串拼接）按铁律降级到「待验证假设」，不进 `todo.md` / `tasks.md`。

- 优化方案（堆内存 / CPU）：0 / 0。

<!-- 第 14 部分 -->

> 本部分 20 个文件全为归档规格文档，没有可测量对象（无函数、无数据结构、无生命周期）。堆内存 / CPU 方案与 local mode 改造均**不提出**：任何收益数字只能来自 `src/**`，属其他子轮，写在这里就是无基线猜测。唯一有量化意义的放大面已作为 #5 记录，其峰值数据列入待验证假设 #1。

<!-- 第 15 部分 -->

> 本部分 20 个文件全为归档规格文档，没有可测量对象（无函数、无数据结构、无生命周期）。堆内存 / CPU 方案与 local mode 改造均**不提出**：任何数字都只能来自 `src/**`，属其他子轮；按铁律，无基线数字写在这里就是猜测。文中的上限类建议（#4 缩放、#6 节点数/树高上限）属于契约缺陷修复，已计入「发现」，不重复统计为优化方案；#9 的公共树构建抽取是**缺陷级重复**的修法，同样计入「发现」。

<!-- 第 16 部分 -->

本部分（20 个 `.md`）没有可以写成「带基线的优化方案」的条目：涉及的实现片段全部缺少改前基线（无 `cjprof` / `cjpm bench -O2` 数据），按铁律一律降到「待验证假设」，不进 `tasks.md`。补到数据后可优先评估的两条已在下一节列出（`paretoOrder` 的 O(n²)、平行坐标逐行字符串拼接），此处不重复。

<!-- 第 17 部分 -->

### [CPU] `pr` / `probability` 的排序从插入排序改为 O(n log n)

- **现状**：`add-f-chart-pr/design.md:6` 明确规定「稳定插入排序按 x 升序」；`PrChart.cj:197-212` 与 `ProbabilityChart.cj:156-171` 都是插入排序实现，单次 `draw` 调用一次，n = 数据点数（来自 chart JSON，除报文大小外无其它约束），最坏 O(n²) 次比较与元素搬移。
- **方案**：改用标准库排序（实现前先按 `cangjie-doc-lookup` 核对 `std.sort` 的稳定性与签名；`pr` 需要稳定排序，等 x 的点必须保持输入顺序），排序后仍复用现有的点数组，不改绘图路径。
- **预期**：复杂度从 O(n²) 降到 O(n log n)；端到端收益取决于排序在渲染总耗时中的占比，未测前不给百分比。
- **代价**：`pr` 的稳定性若标准库不保证，需要自行带索引排序（`(x, 原索引)` 比较）以避免等 x 点重排；`probability` 只需数值排序，代价更低。
- **验证**：`cjpm bench -O2`，同输入 n=1e3 / 1e4 / 1e5，各跑多轮取中位数与离散程度，与改前对照；同时用 `cjprof record` 确认 `sortPoints` / `sortValues` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 18 部分 -->

本部分为 20 个 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无基线即不成立）。源码侧的算法线索见「总评·范围外提示」，交由对应源文件部分取证与统计。

<!-- 第 19 部分 -->

本部分 20 个文件全是 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无改前基线 + 改后对照即不成立）。文档中出现的算法线索（散点矩阵 n² 图元、桑基分层轮数、`indexOfNode` 线性查找）已按铁律移入「待验证假设」，不计入本部分统计。

<!-- 第 20 部分 -->

本部分 20 个文件全为 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无改前基线也无改后对照）。唯一与代码相关的性能线索是发现 #4 的「累计被算两遍」，量化数据缺失，已放入「待验证假设」，不作为方案。

<!-- 第 21 部分 -->

本部分为 20 个 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无基线即不成立）。核对时读到的源码侧算法线索见「总评·范围外提示」，交由对应源文件部分取证与统计。

<!-- 第 22 部分 -->

> 本部分只有文档，无运行期代码，不产生可度量的堆内存 / CPU 收益方案。相关性能线索写在「待验证假设」，且因为实现文件不在本部分清单内，不在本报告给改造建议。

（无）

<!-- 第 23 部分 -->

本部分为 6 个已归档变更的文档，不含可执行代码，也没有任何改前/改后性能基线；堆内存、CPU、local mode 三类方案均不成立（0 条）。文档层面的可执行改进已按缺陷写入上节建议，不重复计数。

<!-- 第 24 部分 -->

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

<!-- 第 25 部分 -->

### [CPU] 两处手写插入排序改为 O(n log n) 排序

- **现状**：`f_chart/src/ArcChart.cj:220-228`（按关联总流量对节点下标做插入排序，n = `nodes` 个数）与 `f_chart/src/BoxScatterChart.cj:250-258`（对每组样本值做插入排序，n = 该组点数），样本量直接来自用户 JSON，无上限校验；n = 10k 时比较次数约 5×10⁷。
- **方案**：`ArcChart` 侧排序「下标数组 + 比较器 `totals[j] > totals[j-1]`」（保持稳定），`BoxScatter` 侧对 `values` 的副本排序；两者都用标准库稳定排序替代手写内循环。
- **预期**：复杂度从 O(n²) 降到 O(n log n)，10k 样本比较次数从约 5×10⁷ 降到约 1.3×10⁵；单次 `draw` 的排序段耗时可忽略。
- **代价**：需确认标准库排序的比较器签名与「相等元素保持原序」语义（`arcNodeOrder` 的平票顺序会影响节点角度，属可见输出）；`BoxScatter` 仍需保留一份输入副本（排序不能改原数组）。
- **验证**：`cjpm bench -O2`，1k / 10k / 50k 三档，`ArcChart` 与 `BoxScatterChart` 各取中位数与离散度；`arcNodeOrder` 平票用例的 SVG 输出需与改动前逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 冲积图按阶段分桶，去掉「每列扫全量节点」

- **现状**：`f_chart/src/AlluvialChart.cj:154-163` 对每个阶段列扫描全部节点（`O(stages × nodes)`），并每列新建 `members`/`totals` 两个 `ArrayList` 与 `heights` 数组。
- **方案**：解析节点时一次性把 `nodeIndex` 追加进 `Array<ArrayList<Int64>>`（长度 = `stages.size`），列循环直接取桶；`totals`/`heights` 仍按列分配，但不再扫全量。
- **预期**：节点遍历从 `stages × nodes` 降到 `nodes`（stages=10、nodes=10k 时 10 万 → 1 万次比较），并少建 `stages` 个 `members` 集合。
- **代价**：`stages` 数量在解析期才确定，需要把 `nodeIndex` 编号与建桶顺序对齐（当前 `nodeIndex` 只用于错误路径文案）。
- **验证**：`cjpm bench -O2` 对比 10 阶段 × 10k 节点输入的 `draw` 中位数；输出 SVG 必须逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] Bland-Altman 去掉 `rawPairs` 这份重复数据

- **现状**：`f_chart/src/BlandAltmanChart.cj:59-75` 每个测量点构造 `Array<Float64>`（2 元素）存入 `rawPairs`，再 `toArray()` 复制一次，交给 `blandAltmanStats`（`:222-243`）重算 `y - x`；而 `pairs` 里已经存了同一个 `diff`。n = 10k 时多出 1 万个 2 元素数组 + 2 次列表复制 + 1 万次减法。
- **方案**：`blandAltmanStats` 改接 `Array<BlandAltmanPair>`（或直接接 `Array<Float64>` 的 diff 列表），删掉 `rawPairs`；同步 `BlandAltmanChart_test.cj:83/93/102` 的三处调用。
- **预期**：每张图少 n 个短数组与 1 次 `ArrayList → Array` 复制；峰值内存下降量随 n 线性，n=10k 时约 1 万个对象。
- **代价**：改一个 `internal` 函数签名与 3 个测试调用；无对外契约变化。
- **验证**：同输入 10k 点循环 100 次，对比 `getAllocatedHeapSize()` 与进程 RSS；SVG 输出逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 26 部分 -->

> 不是缺陷，是「还能更好」。以下均无改前/改后基线，**不进 `tasks.md`**。

### [堆内存] 日历热力图改「按需聚合 + 复用中间结果」，避免逐格分配

- **现状**：`CalendarHeatmapChart.draw` 为每个自然日分配：一条 `calendar-cell`（`group` + `rect` 两个 SVG 元素对象 + 属性表）、一次 `ChartTime.partsOfDays` 返回的 `Array<Int64>`（`:204`）、一次 `chartFormatTick`/`chartTextWidth` 之外的字符串拼接；`dayList`、`valueList`、`uniqueDays`、`totals` 四个 `ArrayList` 与最终 `toArray()` 副本同时存活到函数结束。
- **方案**：`uniqueDays/totals` 改 `HashMap<Int64, Float64>`（顺带去掉 `:131-146` 与 `:191-196` 的两次线性扫描）；`partsOfDays` 只在「月份可能变化」时调用（当前是每天一次）；`dayList/valueList` 改为在解析循环里直接聚合，不再保留原始数组。
- **预期**：365 天输入下，`uniqueDays/totals` 的扫描从 `365×unique` 降到 365 次哈希查找；`partsOfDays` 调用次数从 365 降到约 12；中间 `Array` 副本少 2 份。具体字节数与耗时降幅待实测。
- **代价**：`HashMap` 迭代顺序不确定，但月份标签只依赖按天递增的遍历顺序，不影响输出确定性（`deterministic` 用例可护住）。
- **验证**：同输入（1 年 / 10 年两档）跑 `cjpm test -O2` 前后对照 `cjprof heap` 与 `getAllocatedHeapSize()`，同时断言 SVG 输出逐字节一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sortLiftPoints` 用插入排序处理任意长度的曲线点

- **现状**：`f_chart/src/LiftChart.cj:203-218` 是手写插入排序，最坏 O(n²) 且每次交换都写 `ArrayList` 下标；`CalibrationChart.cj:69` 与 `LiftChart` 都用它排序 `series[0].data`，而该数组长度不受限（JSON 数组大小即输入）。
- **方案**：改用 std 的稳定排序（`sort` 传比较器，按 `[0]` 升序），或在解析阶段就按 x 有序插入（仅在需要时）。
- **预期**：n=10k 时比较次数从约 2.5×10⁷（含 10⁷ 次下标写入）降到 O(n log n)。
- **代价**：需确认 std 排序的稳定性与 null 语义；`sortLiftPoints` 是 `internal` 且被两个图表复用，改名或下沉到 `ChartScale.cj` 时注意命名（`sortLiftPoints` 用在 calibration 上语义不符）。
- **验证**：`cjpm bench -O2` 对 1k / 10k / 100k 点各 5 轮取中位数；同时断言排序结果与旧实现逐元素相同（含 x 相等的稳定性）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 区域/日期去重统一用哈希集合，替代二次扫描

- **现状**：`CartogramChart.cj:83-87` 对每个 `regions[i].id` 线性回扫已收集区域（O(n²)）；`CalendarHeatmapChart.cj:131-146` 同样对 `uniqueDays` 线性回扫。
- **方案**：前者用 `HashSet<String>` 判重（保留原错误消息与 `regions[i].id` 路径），后者并入上面的 `HashMap` 聚合。
- **预期**：n 个区域时判重从 n²/2 次字符串比较降到 n 次哈希；地图区域数通常几十，收益主要在日历热力图与大地图两条路径。
- **代价**：哈希集合多一份 `String` 引用（量级远小于原数组）；`HashSet` 的迭代顺序不会被使用者感知（判重只做存在性判断）。
- **验证**：`cjpm bench -O2`，输入 100 / 1k / 10k 区域；断言重复 id 的错误路径与错误消息完全不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 27 部分 -->

> 不是缺陷，是「还能更好」。本部分**没有任何 profile / bench 数据**，因此以下全部为 `无基线（待验证，不进 tasks）`。

### [堆内存] 等高线网格的三份中间表示合一

- **现状**：`ContourChart.draw` 同时持有 `points`（`ArrayList<ContourPoint>`，每点一个 class 对象：3 个 Float64 + 对象头）、`xs`/`ys`（去重排序后的坐标）、`values`（`Float64[xs*ys]`，初值 NaN）、`bands`（`Int64[xs*ys]`），另有 `dataArray.getItems()` 由 JSON 侧持有的原始项列表。一个 100×100 网格（10⁴ 点）约 4 份 O(n) 结构并存
- **方案**：解析时直接把 `(x, y, value)` 写入以 `xs`/`ys` 排序后下标为键的 `Float64` 数组（先收集 `x`/`y` 到 `ArrayList` → 排序去重 → 第二遍填值），删掉 `ContourPoint` 与 `bands`（`contourLevel` 就地计算或在画线时算两次）
- **预期**：峰值对象数从 ≈4n 降到 ≈2n（`points` 与 `bands` 消失），10⁴ 点时省约 2×10⁴ 个对象/约 0.5–1 MB（量级估算，未测）
- **代价**：需要两遍遍历（当前也是一遍建点 + 一遍填值），代码结构调整；错误信息里的 `series[0].data[i]` 下标要保留（改成先校验后填充）
- **验证**：`getAllocatedHeapSize()` 差值 + 峰值 RSS，输入 20×20 / 100×100 / 200×200 三档，`-O2`
- **证据状态**：`无基线（待验证）`

### [堆内存] 圆堆积节点改为紧凑表示

- **现状**：每个 `CirclePackingNode` 是 class（`id`/`name`/`parentId`/`ownValue`/`children` ArrayList + 4 个可变数值字段），children 又是 `ArrayList` ⇒ 每节点 2 个堆对象 + 一个数组
- **方案**：解析后立刻转成「下标 + 平行数组」（`ids: Array<String>`、`parentIdx: Array<Int64>`、`childrenStart/childrenCount: Array<Int64>` 的 CSR 结构），布局字段放 `Array<Float64>`；`id` 只用于查父与重复校验，布局完成后即可释放
- **预期**：节点数 n 时堆对象从 ≈2n 降到 2 个数组（约 6n×8 字节 + 字符串本身），n = 5000 时省约 10⁴ 个对象
- **代价**：CSR 构建需要一次计数 + 一次填充，可读性下降；递归改迭代后可读性反而更好
- **验证**：n = 1000/5000 两档的峰值内存与 `draw` 耗时对照
- **证据状态**：`无基线（待验证）`

### [CPU] 等高线网格构建是 O(n²)：线性查重 + 插入排序 + 线性定位

- **现状**：`uniqueSorted`（`ContourChart.cj:211-236`）对每个点线性扫 `unique` 查重、再做插入排序；`indexOf`（238-245）对每个点再线性扫 `xs`/`ys`。n 个点 ⇒ 约 3n² 次比较；100×100 网格（10⁴ 点）≈ 3×10⁸ 次比较
- **方案**：`ArrayList` → 排序 + 去重（O(n log n)），再用 `HashMap<Float64, Int64>` 建立坐标→下标，第二遍 O(n) 填值
- **预期**：n = 10⁴ 时比较次数从 10⁸ 量级降到 10⁵ 量级；按比较成本估算可把网格构建阶段降到原来的 1–2%（需实测）
- **代价**：`HashMap` 以 Float64 为键要处理 `-0.0`/精度（当前 `==` 语义相同）；额外 O(n) 哈希表内存
- **验证**：`cjpm bench -O2` 同输入（20×20/50×50/100×100）对照 `draw` 中位数与 P95；`cjprof` 看 `uniqueSorted`/`indexOf` 自耗时占比
- **证据状态**：`无基线（待验证）`

### [CPU] 决策树根检测与边标签查找是 O(n·e) / O(e²)

- **现状**：`DecisionTreeChart.cj:168-181` 用「对每个节点遍历所有节点的所有子节点」判根（O(n·e)）；`decisionEdgeLabel`（291-298）在画每条边时全表扫 `edges`（O(e²)）
- **方案**：根检测改用 `parentCounts` 已有的数组（`edges` 分支里已算出），或在解析时维护 `HashSet<String> hasParent`；边标签用 `HashMap<(source,target), String>`（可拼 `source + "\u0000" + target` 作键）预建
- **预期**：n = e = 2000 时，根检测从 4×10⁶ 次降到 2×10³，边标签从 4×10⁶ 降到 2×10³
- **代价**：多一个哈希表（O(e) 内存）；键拼接产生临时字符串
- **验证**：`cjpm bench -O2`，n = 200/1000/3000 的 `draw` 中位数
- **证据状态**：`无基线（待验证）`

### [CPU] 和弦图每条链接重复线性查节点下标

- **现状**：`ChordChart.cj:107-108` 每条链接查 2 次、`:170-171` 画链接时再查 2 次、`:183` 再查 1 次 ⇒ 每条链接 5 次 O(nodes) 线性扫描；nodes = links = 500 时约 1.25×10⁶ 次字符串比较
- **方案**：解析节点时建 `HashMap<String, Int64>`（与「重复 id 校验」共用，见重复逻辑条目），`ChordLink` 直接存 `sourceIndex/targetIndex`
- **预期**：字符串比较次数降到 O(nodes + links)；大图（500 节点/链接）可省掉绝大部分建图比较
- **代价**：`ChordLink` 结构变化（`String` → `Int64`），`findNode` 可删
- **验证**：`cjpm bench -O2`，nodes = links = 100/500/2000 的 `draw` 中位数
- **证据状态**：`无基线（待验证）`

### [CPU] 组合图每次 draw 重建 4 次堆叠分组

- **现状**：`buildBarGroups` 在 `resolveAxisRange`（`ComboChart.cj:117`、`:129`，左右轴各一次）与 `drawBars`（`:498-499`，左右各一次）里被调用 4 次，每次都重新遍历 series 并在 `groups` 上线性找同 `stack` 的组（O(s²)）
- **方案**：在 `draw` 里算一次 `leftGroups`/`rightGroups`，作为参数传给 `resolveAxisRange` 与 `drawBarGroups`
- **预期**：分组构建从 4 次降为 1 次；series 数 s 的时间从 4·O(s²) 降到 O(s²)，s = 50 时省约 7.5×10³ 次比较（绝对量很小，属「顺带清理」）
- **代价**：函数签名变长；`drawBars` 的结构需要调整
- **验证**：`cjpm bench -O2`，series = 10/50 的中位数对照（噪声内可忽略）
- **证据状态**：`无基线（待验证）`

<!-- 第 28 部分 -->

> 不是缺陷，是"还能更好"。以下均无改前/改后对照数据，`证据状态` 一律为「无基线」，不进 `tasks.md`。

### [CPU] 火焰图建树与 id 查重是 O(n²)

- **现状**：`FlameChart` / `DifferentialFlameChart` 各有一处「每解析一个节点就线性扫已解析列表查重」（`FlameChart.cj:71-75`、`DifferentialFlameChart.cj:74-78`）和一处「每个节点线性找父节点」（`FlameChart.cj:99`、`DifferentialFlameChart.cj:107`），合计约 `n²` 次字符串比较（`findNode` 见 `FlameChart.cj:158-165`）。火焰图典型规模 2k–50k 节点。
- **方案**：解析时用 `HashMap<String, FlameNode>` 同时承担查重与父查找（一次 `add` 前 `contains`，建树时直接 `map[parentId]`），把 `parsed` 数组保留仅用于遍历。
- **预期**：比较次数从 `n(n-1)` 降到 `2n`；n=20k 时从约 4 亿次字符串比较降到 4 万次量级（按复杂度估算，未测）。
- **代价**：多一个 `HashMap`（n 个 entry，约 `n×48B`）；内存微增，行为不变。
- **验证**：`cjpm bench -O2` 或对 `draw()` 做分段计时，输入 2k / 10k / 50k 节点，比较改前改后中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `density` 的核密度被算了两遍，每系列 202×n 次 `exp`

- **现状**：`DensityChart` 先对 101 个采样点求 `maxDensity`（`DensityChart.cj:140-151`），再在 `drawDensity` 里对同样的 101 个点重算一遍（`244-248`）。每次 `gaussianKde` 遍历全部 n 个值并调用 `exp`（`272-283`），即单系列 `2×101×n` 次 `exp`，3 系列、n=10k 时约 606 万次。
- **方案**：在 140-151 的循环里把每系列的 101 个密度值存进 `Array<Float64>`（或 `Array<Array<Float64>>`），`drawDensity` 直接复用并按 `xScale`/`yScale` 映射，去掉第二次 `gaussianKde`。
- **预期**：该图的 `exp` 调用与 KDE 遍历量减半（按复杂度估算，未测）。
- **代价**：每系列多 101 个 `Float64`（约 0.8KB），需把 `drawDensity` 的入参从 `series`+`bandwidth` 改成密度数组。
- **验证**：`cjprof record` 看 `gaussianKde` 自耗时占比与 `draw()` 总耗时；输入 3 系列 × 10k 值，改前改后中位数对照。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ecdf` 依赖的 `sortRaincloud` 是插入排序，最坏 O(n²)

- **现状**：`ecdfPoints`（`EcdfChart.cj:201-212`）调用 `sortRaincloud`（`RaincloudChart.cj:320-341`，范围外文件），实现为插入排序：对随机输入平均 n²/4 次比较与搬移。ECDF 的输入就是原始数值数组，n 可达 10⁴–10⁵。
- **方案**：把 `sortRaincloud` 的实现改为 `std.sort`（或 `Array.sort` 稳定排序）；插入排序只在 n<32 的小数组上保留（小数组上更快且无分配）。ECDF 侧可顺带删除「先复制到 `ArrayList` 再 `toArray`」的一次拷贝。
- **预期**：n=10k 随机输入从约 2500 万次比较降到约 13 万次；n=100k 时差距两个数量级以上（复杂度估算，未测）。
- **代价**：排序稳定性若变化会影响等值点的绘制顺序（同值点在同一 x，帧位置一致，视觉无差），需保留「确定性」用例；该函数被 `RaincloudChart` 共用，需同步回归。
- **验证**：`cjpm bench -O2`，输入 1k / 10k / 100k 随机与升序/降序数组，比较中位数；跑 `RaincloudChart_test`、`ViolinChart_test` 回归。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `ecdf` 为每个点物化 `[x, cumulative]` 双元素数组

- **现状**：`ecdfPoints` 返回 `Array<Array<Float64>>`，每点 2 个 `Float64` 数组（约 2 个对象 + 16B 数据，外加 `ArrayList` 扩容），n=100k 时约 20 万个短命数组；`draw` 随后逐点读 `points[i][0/1]`（`EcdfChart.cj:178-186`）即丢弃。
- **方案**：`ecdfPoints` 改为只返回排序后的 `Array<Float64>`（或直接返回 `points` 的 `x` 与 `i/n` 两个标量序列），绘制时在循环里用 `Float64(i+1)/n` 现算累计值；`draw` 内不再持有中间二维结构。
- **预期**：每系列减少约 `2n` 次小对象分配；n=100k 时峰值临时堆下降约 10–15MB 量级（按对象布局估算，未测）。
- **代价**：`ecdfPoints` 是 `internal` 且被 `EcdfChart_test.cj:70-86` 直接断言，签名变化需同步测试；`RaincloudChart` 不受影响。
- **验证**：`getAllocatedHeapSize()` 与 RSS，改前改后各跑 200 次 `draw()`（n=100k），比较分配总量与峰值。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 29 部分 -->

### [CPU] `heat-flame` / `flow-map` 的 O(n²) 查重与查找、三处手写插入排序

- **现状**：`HeatFlameChart.cj:78-82` 每节点对 `parsed` 全表查重、`:115`（`findNode`，实现 181-188）每节点再线性找父节点 ⇒ 约 2×n²/2 次字符串比较，n=10k 时约 1e8 次。`FlowMapChart.cj:91-95` regions 去重 O(R²)、`:125-130` 每条 flow 两次 `findRegion`（225-232）再在绘制循环 `:196-197` 重复两次 ⇒ O(F·R)。`FlowMapChart.cj:234-249`、`HeatMap.cj:167-182`、`LiftChart.cj:203-218` 为插入排序，逆序输入最坏 O(n²)
- **方案**：一轮收集后建 `HashMap<String, Int64>`（id → 下标/对象），查重与父节点解析都走 O(1)；排序改用 `std.sort`（仓库已有用法：`f_llm/src/channel/ChannelMediator.cj:19` `import std.sort.*`），稳定序需求用「值 + 原下标」比较器保证
- **预期**：n=10k 的节点/流输入，比较次数从 ~1e8 降到 ~1e4，排序从 O(n²) 降到 O(n log n)；端到端收益取决于图表数据规模（未测）
- **代价**：`HashMap` 额外 O(n) 堆内存；排序改为稳定版需要额外比较键；`flow-map` 的 `findRegion` 需改成索引表后同步 `regions[...]` 访问
- **验证**：`cjpm bench -O2`，同一份 JSON 分别取 1k / 10k / 50k 节点（及 1k / 5k flows），比较改前改后中位数与 P95
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 排序前的整表第三次复制

- **现状**：`FlowMapChart.sortFlows`（234-249）与 `HeatMap.sortByValue`（167-182）都把 `ArrayList` 先 `toArray()`（1 份），再逐项 `add` 进新 `ArrayList`（第 2 份），最后再 `toArray()`（第 3 份）；同一批引用同时在 3 个等长容器里存活到函数返回。`FlowMapChart.cj:136-157` 每条 flow 的 `points` 也是 `ArrayList` → `toArray()` 双份
- **方案**：直接用 `Array` 承载并就地排序（或 `std.sort` 于 `Array`），删除中间 `ArrayList` 与首尾两次 `toArray()`；`points` 先按 `pointItems.size` 一次分配再填
- **预期**：峰值少 2×n 个引用槽（n 为 flow/point 数，10k 规模约 160 KB）与 2 次整表 GC 扫描；收益量级小，属「顺手清理」
- **代价**：需保证排序稳定性与现有绘制顺序一致（同值元素按输入顺序叠放）；改动局限在这两个函数
- **验证**：`getAllocatedHeapSize()` 包住单次 `draw`（同输入 10k 点），改前改后各跑 5 轮取中位数；同时核对 SVG 输出与改前逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 30 部分 -->

> 以下均为"还能更好"，不是缺陷。本部分没有改前基线数据，全部标 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] `sortLiftPoints` 用插入排序，被 7 个图表共用

- **现状**：`LiftChart.cj:203-218` 为插入排序，最坏 O(n²)：n=10k 时约 5×10⁷ 次比较 + 同量级 `ArrayList` 读写；调用方 6 个图表 + 自身，输入规模 = series 内点数（`LiftChart.cj:65`、`CalibrationChart.cj:69`、`GainChart.cj:61`、`PdpChart.cj:62`、`LassoPathChart.cj:80`、`LearningCurveChart.cj:112`）
- **方案**：移到内部 util 并改为 O(n log n) 稳定排序（归并，或 `std.sort` 的稳定版本；用 x 比较，等值时保持原序）
- **预期**：n ≥ 1k 时排序段从平方级降到 n log n；n=10k 约降两个数量级（排序段内部，不含端到端）
- **代价**：需确认标准库排序的稳定性语义（先查 `std.sort` 文档）；等值 x 的顺序必须不变，否则路径/带子的画法会变
- **验证**：`cjpm bench -O2`，同输入 n=1k/10k/50k，取中位数与离散度；对照改前改后
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] HiveChart / IcicleChart 的 O(n²) 查重与线性查父

- **现状**：`HiveChart.cj:87-91` 每加一个节点都线性扫已有节点查重（O(n²)）；`:113-118` 每条 link 两次 `findNode` 线性扫描（O(n·m)）；`:129-144` 分组按名字线性查重（O(n·g)）。`IcicleChart.cj:70-74` 同样 O(n²)，`:98-101` 每个节点线性 `findNode` 找父
- **方案**：一次遍历建 `Dictionary<String, Int64>`（id → 下标），查重、找父、找 link 端点全部 O(1)；分组用 `Dictionary<String, Int64>` 映射到组下标
- **预期**：建图从 O(n²+n·m) 降到 O(n+m)；1k 节点 + 1k 链接量级收益明显，小图无感
- **代价**：多一个字典的内存（n 项）；插入顺序仍需保持，分组数组遍历顺序不能变（用下标数组维持原序）
- **验证**：`cjpm bench -O2`，节点 1k/5k/20k（链式与星形两种分布），记录端到端耗时中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] HeatmapChart 每个单元格重复解析三个颜色字符串

- **现状**：`HeatmapChart.cj:156` 在 `row × column` 双层循环内调用 `heatmapColor`，后者在 `:233-235` 对 low/mid/high 各做一次 `SvgColor.tryParse`（字符串解析 + 对象分配），末尾还 `toString()` 生成新字符串；100×100 矩阵 = 3 万次解析 + 1 万次格式化
- **方案**：在 `draw` 循环外解析一次 `SvgColor`（并保留一个接 `SvgColor` 的 internal 重载），循环内只做通道插值与字符串拼接；颜色字符串可复用同一 `StringBuilder`
- **预期**：颜色解析次数 3N → 3；解析段 CPU 与年轻代分配随之下降（端到端占比未测）
- **代价**：`heatmapColor(ratio, low, mid, high)` 是 internal 且被 `HeatmapChart_test.cj:100-102` 直接调用，需保留原签名或同步改测试
- **验证**：`cjprof record` 看 `parseHeatmapColor`/`SvgColor.tryParse` 自耗时占比；`cjpm bench` 100×100、500×500 矩阵对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] HeatmapChart 的矩阵用 `ArrayList<Array<Float64>>`，行对象与整表拷贝各一份

- **现状**：`HeatmapChart.cj:48-89` 每行先建 `ArrayList<Float64>` 再 `row.toArray()` 存入外层 `ArrayList`，最后一次 `matrix[r][c]` 访问；行数 R 时多 R 个 `Array` 对象头，且每行发生一次全量复制（峰值时旧 `ArrayList` 与 `Array` 同时在世）
- **方案**：改用单块 `Array<Float64>(R*C, repeat: 0.0)` 平铺存储，读取用 `r*C + c`；行长度校验改为对平铺索引取模校验
- **预期**：堆对象数 R+1 → 1；峰值少一次 R×C 的浮点复制（R=C=1000 约 8MB）
- **代价**：索引计算替代二维下标，可读性下降；越界从"行数组越界"变成"平铺偏移越界"，需保留现有报错路径文案
- **验证**：多轮渲染下 `getAllocatedHeapSize()` 与 RSS 对照，配 `getUsedHeapSize()` 峰值；同输入 100×100、1000×1000
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 31 部分 -->

> 不是缺陷，是"还能更好"。本部分**没有任何 profile / bench 数据**，以下全部为「无基线（待验证）」，不进 `tasks.md`。

### [CPU]（O1）力导向布局的复杂度是 80 × N² + 80 × |E| × 2 × N

- **现状**：`NodeLinkChart.cj:227` 固定 80 轮；每轮先 `for (left in 0..nodes.size) for (right in left+1..nodes.size)` 做一次全对斥力（`:228-241`，`N(N-1)/2` 次 `sqrt`），再对每条边调用 `findNode` 两次（`:242-244`，每次线性扫 `N`）做 id→下标映射；绘制阶段 `:158-159` 又为每条边调用两次 `findNode`
- **方案**：进入 `runForce` 前一次性把 `links` 映射成 `Array<(Int64, Int64, Float64)>`（`HashMap<String, Int64>` 建索引），此后每轮只按下标取值；斥力可用 Barnes-Hut 四叉树近似，但属算法替换，建议先做索引化这一档
- **预期**：像素级等价（同一迭代顺序、同样的浮点加法顺序），仅去掉 `80 × |E| × 2 × N` 次字符串比较；收益随 `|E|·N` 增长，需实测
- **代价**：改动局限于 `NodeLinkChart.runForce` 与 `draw` 的边绘制；不改变输出（前提是保持原有的节点遍历顺序）
- **验证**：`cjpm bench -O2` 同一输入（N=200 / |E|=800 与 N=800 / |E|=3000 两档）取中位数与离散度，`cjprof record` 看 `findNode` 的 self time 占比
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU]（O2）4 处节点 id 去重与 4 处 id→节点查找都是线性扫描

- **现状**：`NetworkHeatmapChart.cj:55-59`、`NodeLinkChart.cj:88-92`、`OfflineFlameChart.cj:71-75`、`OrgChart.cj:88-92` 的重复 id 检测为 `n(n-1)/2` 次字符串比较；`OfflineFlameChart.cj:99`（每个节点一次）、`OrgChart.cj:112`（每个节点一次）在装配父子关系时再做一次全表扫描 → 解析阶段整体 O(n²)
- **方案**：建 `HashMap<String, Int64>` 索引，去重与查找都 O(1)；`NodeLinkChart` 的 `findNode`（`:184-191`）一并改索引
- **预期**：解析阶段从 O(n²) 降到 O(n)；N=10k 时字符串比较次数从 5×10⁷ 量级降到 10⁴ 量级（推算值，需实测）
- **代价**：多一个 `HashMap`（与 `nodes` 同生命周期，O(n) 额外内存，可接受）；错误文案与抛错时机不变
- **验证**：`cjpm bench -O2`，输入 1k / 5k / 10k 节点，测端到端 `draw` 时间与分配量
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU]（O3）`NetworkHeatmapChart` 每个单元格都重新解析一次颜色字符串

- **现状**：`NetworkHeatmapChart.cj:133-142` 已经用 `SvgColor.tryParse` 校验过 `colorRange`，但绘制时 `:190` 调 `heatFlameColor(ratio, colorRange)` → `HeatFlameChart.cj:271-282` 内部再次 `parseHeatFlameColor`（≥3 色走 `heatmapColor`，同样逐个解析）。N×N 单元格 → `N²` 次（3 色时约 `3N²` 次）字符串解析
- **方案**：在 `:126-142` 的校验循环里把结果存成 `Array<SvgColor>`（或预计算的 `RGB` 三元组），绘制时用「预解析颜色 + ratio」的内插函数；`heatFlameColor` 保持现有签名供 `HeatFlameChart` 使用
- **预期**：N=100 时省掉约 3 万次颜色解析；`tryParse` 单次成本需实测后换算端到端占比
- **代价**：`NetworkHeatmapChart` 需要新写一个"已解析调色板"的内插小函数（约 15 行），内插公式必须与 `heatFlameColor` 完全一致，需加等价性用例（同一 `ratio` 输出同一字符串）
- **验证**：`cjprof record` 对比改前改后 `SvgColor.tryParse` 的 self time 占比；`cjpm bench` 100×100 与 200×200 两档
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存]（O4）`ManhattanChart` 同时持有 4 份 O(n) 数组

- **现状**：`ManhattanChart.cj:67-69` 建 `points`（`ManhattanPoint`，含 `x/y/chromosome`）、`xs`（`Array<Float64>`）、`chromosomes`（`Array<String>`，与点的 `chromosome` 是同一批引用），`:89` 再由 `manhattanPositions` 复制出 `positions`（`Array<Float64>`，`:249-252` 先完整复制 `xs` 再改写）。峰值约 `n × (对象头 + 2×8 + 8) + 2 × n × 8 + n × 8`，随点数线性增长，全部活到函数结束
- **方案**：`manhattanPositions` 直接在 `xs` 的副本上原地改写（已如此），把 `points` 的 `x` 改为"不单独存 x，读 `positions[index]`"；或让 `manhattanPositions` 接收 `ArrayList<ManhattanPoint>` 并只返回偏移后的坐标，省掉 `chromosomes`（`points[i].chromosome` 已在）
- **预期**：省 1～2 份 n 元素数组（`n=10⁶` 时约 8～16 MB）；峰值占比需实测
- **代价**：`ManhattanPoint.x` 变成"原始 x"，绘制时用 `positions[index]`，可读性略降；`manhattanPositions` 是 `internal` 且被测试直接调用（`ManhattanChart_test.cj:77,87`），签名变更需同步用例
- **验证**：`getAllocatedHeapSize()` + RSS 多轮绘制 10 万/50 万/100 万点的稳态对照（`-O2`，同输入）
- **证据状态**：无基线（待验证，不进 tasks）

### [local mode] 结论：本部分不推荐

- **现状**：每张图的 `draw` 都产生大量"函数内创建、函数内丢弃"的临时对象（`LinePoint`/`LinePixel`/`ManhattanPoint`、各种 `ArrayList`、`StringBuilder` 片段），纸面上符合 local region 的适用形态
- **卡点**：①返回值是 `String`（SVG 全文），而 `SvgBuilder` 的图元树全程参与构造，逃逸链贯穿整个 `draw`，用 `exclave` 只能救最外层，收益被稀释；②`Chart` 接口签名 `draw(data: JsonObject): String` 无法标注 mode 重载，改造要动接口与全部 100+ 实现（跨部分）；③所有线程共用的 `cjLocalRegionMaxSize` 是新的 OOM 面，大图（10 万点）容易先撞 `LocalRegionOutOfMemoryError`
- **结论**：在拿到"峰值内存对照"之前不作为方案提出；若要评估，先在单张图的"中间点数组"上做局部试点（`LinePoint`/`ManhattanPoint` 的分配量占峰值比例需先测）
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 32 部分 -->

### [CPU] `normalQuantile` 每次调用分配 4 个系数数组

- **现状**：`f_chart/src/QQChart.cj:220-235` 在函数体内构造 `a`（6 元素）、`b`（5）、`c`（6）、`d`（4）四个 `Array<Float64>`；`qqTheoryQuantiles`（`:197-209`）对每个样本调用一次 `normalQuantile`，因此 `n` 个样本 = `4n` 次小数组分配（n=10k → 4 万次；n=100k → 40 万次），且 `ProbabilityChart` 走同一条路径。
- **方案**：把 4 个数组提为文件级 `let QQ_ACKLAM_A/B/C/D`（只读常量，构造一次），函数内按名引用。
- **预期**：每张 QQ / probability 图少 `4n` 次分配与对应 GC 压力；分配次数按 `n` 线性下降（具体端到端降幅需测）。
- **代价**：约 168 B 常驻；无常量语义变化，系数拼写必须逐字核对（现有单测只校验 0.5 / 0.975 两个点，建议补 `p=0.001`、`p=0.999` 的边界值）。
- **验证**：`cjpm bench -O2` 同输入对照 `n = 1k / 10k / 100k` 的 `draw` 中位数与离散度，或用 `cjprof heap` 看分配次数；不接受单次最快值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `sortValues` 的 array → ArrayList → array 双拷贝

- **现状**：`f_chart/src/QQChart.cj:156-171`、`f_chart/src/ProbabilityChart.cj:156-171`、`f_chart/src/PrChart.cj:197-212` 都把入参 `Array` 逐元素复制进 `ArrayList`，排序后再 `toArray()`；调用点本身已先做过 `values.toArray()`（`QQChart.cj:72`、`ProbabilityChart.cj:72`），因此同一份数据在峰值时存在 3 份（原 ArrayList 内部数组、副本 Array、排序用 ArrayList 内部数组）。
- **方案**：排序函数直接接收 `Array<Float64>` / `Array<PrPoint>` 并在其副本上原地排序，去掉 ArrayList 中转；若 std 提供 `Array.sort`/`sortBy` 优先复用。
- **预期**：每张图少 1–2 次 n 元素分配（n=10k `Float64` 约 80 KB，`PrPoint` 引用数组约 80 KB）。
- **代价**：原地排序会改变入参数组顺序，需确认调用方不再使用原顺序（当前调用点都是刚拷出的局部副本，安全）；语义（稳定性）需与现实现对齐。
- **验证**：同输入下 `getAllocatedHeapSize()` 峰值与 `draw` 耗时对照，多轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 平行坐标每行的多次中间复制

- **现状**：`f_chart/src/ParallelCoordinatesChart.cj:104-120` 每行先用 `ArrayList<Float64>` 累积再 `toArray()`，`:123` 再 `rows.toArray()`，`:86` 的 `series` 也是 `ArrayList`；`values` 的扩容副本与 `toArray()` 副本同时存活，峰值约为最终数据的 2–3 倍。
- **方案**：维度数已知（`dimensionCount`），直接 `Array<Float64>(dimensionCount, repeat: 0.0)` 按索引写入，长度不符再抛错；`series`/`rows` 改为按输入长度预分配的数组。
- **预期**：`n` 行 × `m` 维少 1 份中间副本（约 `n·m·8 B`），峰值内存按行数线性下降。
- **代价**：需要先取长度再写入，代码略增；错误路径文案不变。
- **验证**：`n = 1k / 10k` 行、`m = 4` 维时的峰值 heap 与 RSS 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 33 部分 -->

### [堆内存] 去掉图表装配阶段的中间 `ArrayList` 副本

- **现状**：每张图在 `draw` 里至少保留 2–4 份同长度集合：`RaincloudChart.cj:105-113`（`labels`）+ `172-177`（`names`、`colors`）→ 再 `toArray()` 传给 `drawLegend/drawXAxis`；`ResidualChart.cj:88-91`、`126-131` 同型；`ScatterMatrixChart.cj:108-117` 把 `allRows.toArray()` 放在 `for (index in 0..variableCount)` **循环内**，每列都重新物化一次行数组（O(变量数 × 样本数) 次指针拷贝）。
- **方案**：`ScatterMatrixChart.cj:116` 把 `allRows.toArray()` 提到循环外；`names/colors/labels` 改为在需要时直接按下标取值（或让 `drawLegend` 接受 `Array<String>` 之外的只读视图），避免 `ArrayList → Array` 的一次性拷贝。
- **预期**：单次绘制减少 2–3 个与输入等长的临时数组；`ScatterMatrix` 在 10 变量 × 1000 样本时省去 9 次行数组拷贝。对象数与字节量需按上述输入实测。
- **代价**：`ChartFrame.drawLegend` 签名若改会波及全模块 40+ 调用点；只做「提前 `toArray`」这一步零风险。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 单次 `draw` 的分配采样，同输入同并发，取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 排序与路径拼接的重复实现收敛

- **现状**：`RocChart.cj:188-203` / `RaincloudChart.cj:320-335`（及范围外 `PrChart.cj:197`、`SurvivalChart.cj:275`）是插入排序，最坏 O(n²)；`Raincloud.drawBox` 每次绘制都对整组数据排一次序。路径字符串用 `StringBuilder` 逐点拼接的写法在 `RadarChart.cj:147-154`、`RadarChart.cj:236-243`、`RaincloudChart.cj:244-253`、`RidgeChart.cj:169-181`、`RidgeChart.cj:186-200`、`RocChart.cj:153-162` 各写一遍（其中 `RidgeChart` 在同一组 `points/densities` 上算了两遍 `y` 并拼两个 `StringBuilder`）。
- **方案**：① 排序收敛为一个 `stableSortBy`，若确认 `std.sort` 在当前 SDK 下稳定则换 O(n log n)（**先用 `cangjie-doc-lookup` 核对 `std.sort` 签名与稳定性，未核对前不要动**）；② `RidgeChart` 的 area/line 合并为一次遍历：先算 `Array<Float64> ys`，area 路径 = line 路径 + 两条回到 baseline 的 `L`；③ 模块内加 `ChartPathBuilder`（`moveTo/lineTo/close`）替换 6 处手写 `"M … L …"`。
- **预期**：`RidgeChart` 每行少一遍 `O(samples)` 浮点运算与一次 `StringBuilder` 增长；点集 n > 1000 时排序从 O(n²) 降到 O(n log n)。收益比例需实测。
- **代价**：换排序实现会改变同值元素的相对顺序（若不稳定），会破坏「确定性」用例；`ChartPathBuilder` 增加一层间接。
- **验证**：`cjpm bench -O2`，输入取 `RocChart` 100/1000/5000 点、`RidgeChart` 4 系列 × 80 采样、`Raincloud` 12/1000 值；同时用现有 `deterministic` 用例做等价性回归（同输入两次输出必须逐字节相同）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 34 部分 -->

### [堆内存] 堆叠面积图改为逐系列流式累计，去掉 `2 × S × C` 的层数组

- **现状**：`StackedAreaChart.cj:159-187` 预分配 `lowerLayers` 与 `upperLayers` 两个 `S × C` 的 `Float64` 数组（`S` = 系列数、`C` = 类目数），共 `2·S·C·8` 字节常驻到 `draw` 结束；`S=50`、`C=2000` 时约 1.6 MB，`S=200`、`C=10000` 时约 32 MB
- **方案**：只保留每组一个 `cums[groupCount][C]` 与当前系列的 `lower/upper` 两个长度 `C` 的数组，按系列顺序"算 lower/upper → 画 path → 累加进 cums"，即把 `:188-238` 的绘制循环上移进 `:175-187` 的累计循环
- **预期**：该结构的峰值内存从 `2SC` 降到 `2C + G·C`（`G` = 分组数，通常为 1–3），常见场景下降约 50%–95%（按上述规模估算），GC 压力同步下降
- **代价**：循环结构调整，绘制与累计耦合在同一循环；语义不变（同一 `stack` 内的累计顺序保持系列输入序），需要补一个"分组 ≥ 2 且含负值"的回归用例
- **验证**：`cjpm bench -O2` 同输入（S=50/C=2000 与 S=200/C=5000 两组）对照 `getAllocatedHeapSize()` 峰值与 RSS，取多轮中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 茎叶图去掉数据的三份副本

- **现状**：`StemLeafChart.cj:62-71` 收集 `ArrayList<Float64>` → `toArray()` 一份拷贝；`stemLeafRows:160-163` 再复制一份做插入排序；`:181-197` 又把每个值转成 `Int64` 存进 `leaves` 数组。三个结构同时存活到 `draw` 结束，`n` 个值时约 `24n` 字节（不含对象头与 `ArrayList` 扩容余量）
- **方案**：在 `stemLeafRows` 内直接对入参数组排序（调用方已 `toArray()`，无需再保护），叶只在拼字符串时按需转换、不再单独存 `Int64` 数组（或把 `leaves` 改为 `ArrayList<Int64>` 按茎大小精确分配，避免每个茎一个满额数组）
- **预期**：峰值对象数从 3 份降到 1–2 份，`n=100k` 时省约 1.6 MB 常驻与一次全量复制
- **代价**：`stemLeafRows` 变为"会修改入参数组"，需在注释与测试里写明；`StemLeafRow.leaves` 类型若是 `Array<Int64>` 仍要保留，收益主要来自前两项
- **验证**：同输入（10 万随机值，5 个不同 `stemUnit`）对照 `getAllocatedHeapSize()` 峰值与 GC 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 主题河流图的分层路径从 O(S²·C) 降到 O(S·C)

- **现状**：`StreamgraphChart.cj:188-214` 对每个 `layer` 都从 `baseline` 重新累加 `0..layer` 的系列值，且正向、反向各算一遍：内层循环次数约 `2 · Σ_{l=0..S-1} l · C = S(S-1)·C`，即系列数的平方；`S=200`、`C=1000` 时约 4000 万次浮点加法
- **方案**：先按列算一次前缀和（`prefix[l][c]`，或直接在列循环里维护长度 `S` 的累加数组），两个方向的 path 都直接读 `prefix`；同时把 `:106-113` 的 `totals` 与 `:118-127` 的累计范围合并到同一遍扫描
- **预期**：浮点加法从 `S(S-1)C` 降到 `S·C`（`S=200` 时约 200 倍），`draw` 的 CPU 时间在系列多、列少时明显下降（端到端占比未测）
- **代价**：增加一个 `S × C` 的 `Float64` 缓冲（`S=200`、`C=1000` 约 1.6 MB），可用"每列累加数组 + 单遍输出"避免；需要保证与现实现的浮点累加顺序一致，避免路径端点出现 1e-16 级差异
- **验证**：`cjpm bench -O2`，输入 S∈{10, 50, 200}、C=1000，比较 `draw` 中位数与输出 SVG 的路径坐标逐字节一致性
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 旭日图建树与索引用 `HashMap` 替代 O(n²) 线性查找

- **现状**：`SunburstChart.cj:78-82` 每个节点对已收集列表做一次全量比较（O(n²) 字符串比较），`:100-110` 每个节点调一次 `findNode`（`:141-148`，O(n) 线性查找），建树整体 O(n²)；n=5000 时约 2500 万次字符串比较
- **方案**：一次遍历建 `HashMap<String, Int64>`（id → 下标）同时完成重复检测，第二次遍历用该表 O(1) 取父节点；`findNode` 可删除（`SequenceChart.cj:63-69` 已是这种写法）
- **预期**：建树从 O(n²) 降到 O(n)，n=5000 时字符串比较次数下降约 4 个数量级；`sortChildren` 的插入排序在大扇出节点上仍是 O(k²)，可一并换稳定排序（见「发现」#8 与本表末条）
- **代价**：多一个 `HashMap`（n 条约 50–80 字节/条），内存换 CPU；`HashMap` 迭代序不影响输出（建树顺序仍按 `nodes` 数组）
- **验证**：`cjpm bench -O2`，输入 100 / 1000 / 5000 个节点（宽树与深链各一组），比较 `draw` 中位数与输出一致性
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 螺旋图每点算两次、每点两个临时数组

- **现状**：`SpiralChart.cj:117-128` 与 `:137-158` 对同一批 `index` 各调用一次 `spiralPoint`（`:164-178`），每次返回一个新的 `Array<Float64>`；即 `2n` 次三角函数对与 `2n` 个双元素数组，`n` 为数据点数
- **方案**：第一遍把 `[x, y]` 存入两个 `ArrayList<Float64>`（或一次算出的 `Array<Float64>` 对），画点与标签直接复用；`spiralPoint` 改为写输出参数（或返回 `struct` 值类型）避免数组分配
- **预期**：三角函数调用减半、临时数组从 `2n` 降到 0–1 个；`n=10k` 时省约 20k 次 `cos/sin` 与 20k 次分配
- **代价**：多一个长度 `n` 的坐标缓存（`2·8·n` 字节），绘制循环需要 index 对齐；语义不变
- **验证**：`cjpm bench -O2`，`n ∈ {1k, 10k}` 对照 `draw` 中位数与输出 SVG 一致性
- **证据状态**：`无基线（待验证，不进 tasks）`

> 共享原语（22 处插入排序、O(n²) 去重）换成 `HashMap`/标准排序的收益同样缺少基线，统一列在「待验证假设」，不单独估算比例。

<!-- 第 35 部分 -->

> 以下均无改前/改后基线，只登记为下一轮补数据的候选，不进修复清单。

### [CPU] `sortValues` 插入排序 + 树图比较器内重算子节点和

- **现状**：`sortValues` 在 4 处实现为插入排序（`SwarmChart.cj:218`、`ViolinBoxChart.cj:298`、`ViolinChart.cj:271`、范围外 `BoxScatterChart.cj:245`），输入是用户 JSON 里的原始数值序列，元素个数无上限；treemap 的 `sortChildren` 是插入排序且比较时调 `nodeValue`（`TreemapChart.cj:179-187`），单次比较 O(子树)
- **方案**：改为标准库排序（预计算排序键），`nodeValue` 结果缓存到节点
- **预期**：插入排序最坏 O(n²)；1 万点乱序输入时比较次数从 ~5×10⁷ 降到 ~1.3×10⁵ 量级（理论值，未测）
- **代价**：需要一次额外数组（n 个 `Float64` 键）；排序稳定性若被依赖需显式指定
- **验证**：`cjpm bench -O2` 同输入（1k/10k 随机与升序两种分布）对照中位数与 P95；`cjprof record` 看 `sortValues`/`nodeValue` 自耗时占比
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 泳道图/树图按 id 线性查找，整体 O(n²)

- **现状**：`SwimlaneChart` 重复 id 检查 `:91-95`、`:114-118` 对每条记录线性扫已有列表；每条边两次 `findSwimNode`（`:241-242`），`findSwimNode` 自身 O(n)（`:341-348`）⇒ 建图阶段 O(n² + n·e)。`TreemapChart.findNode`（`:150-157`）对每个节点线性扫一次 ⇒ O(n²)
- **方案**：解析时建 `HashMap<String, Int64>` 索引（id → 序号），重复检查与端点解析都走哈希
- **预期**：5 千节点/1.5 万边时比较次数从 ~7×10⁷ 降到 ~2×10⁴（理论值，未测）
- **代价**：多一份 id 索引（~n 个字符串引用），生命周期限于 `draw`
- **验证**：构造 5k 节点、15k 边的泳道图，`cjpm bench -O2` 对照构建耗时；确认输出 SVG 逐字节相同
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 点图逐点生成独立 `<g>`，SVG 缓冲随点数线性膨胀

- **现状**：`ChartSvgKit.circle`（`ChartSvgKit.cj:123-137`）每点 `group()` + `circle` + `class` + `fill` + `end()`，每点约 100-200 B 文本；`SwarmChart` 每组 `sortValues` + `swarmOffsets` 各分配一个 `ArrayList` 副本（`:166-167`），`ViolinChart/ViolinBoxChart` 每组 41 个采样固定分配 2 个 `ArrayList` + `StringBuilder`（`:174-185`）
- **方案**：同色同 class 的点合并为一个 `<path>`（`M cx cy m -r 0 a r r 0 1 0 2r 0 ...` 的圆点 path），减少元素数与字符串拼接次数；`sortValues` 直接在入参数组的副本上原地排序，去掉一次 `ArrayList→Array` 复制
- **预期**：1 万点 swarm 的 SVG 文本从 ~1.5 MB 降到 ~0.6 MB（按 150 B/点估算，未实测）；GC 分配次数同比例下降
- **代价**：`class` 语义从 `circle` 变成 `path`，若下游 CSS 依赖 `circle` 选择器会失效；需同步已入库 `charts/*.svg`
- **验证**：同输入（1k/10k 点）前后对比 SVG 字节数与 `getAllocatedHeapSize()` 峰值；浏览器渲染时间对照
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 36 部分 -->

### [堆内存] `TuiCanvas` 去掉 `ArrayList → toArray` 的一次性中转

- **现状**：`TuiCanvas.cj:36-42` 先 `while (index < width*height) { list.add(TuiCell()) }` 建 `ArrayList<TuiCell>`，再 `list.toArray()` 复制成 `Array<TuiCell>`；峰值同时持有 ArrayList 的底层指针数组与新 `Array`（`toArray` 返回新数组，见 `std/collection/collection_package_class.md:2618`）。80×24 = 1920 个引用 ≈ 15KB 峰值浪费；300×100 = 30000 → ≈ 240KB。
- **方案**：直接用 `Array<TuiCell>(Int64(width * height), { _ => TuiCell() })`（构造签名见 `docs/dev-guide/source_zh_cn/basic_data_type/array.md:46`；同一文档 `:39` 明确 `repeat` 形式**不拷贝**引用，因此不能写 `repeat: TuiCell()`）。
- **预期**：单次绘制少一次 O(w·h) 指针数组拷贝，峰值分配量减半（对象数不变）；大画布一次性请求的瞬时峰值下降最明显。
- **代价**：零语义变化；`Array` 的闭包初始化每元素一次调用，与现在 `while + add` 的调用次数相同。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 单次 `drawCells` 的分配采样，输入 80×24 / 200×60 两档，各取 10 轮中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 词网络：用 `HashMap` 索引替代全部线性 `findWordNode`，并给力导向加规模上限

- **现状**：`WordNetworkChart.cj:199-227` 每轮（共 80 轮）对每条链接做 2 次 `findWordNode` 线性扫描（`215-216`），渲染阶段再对每条链接做 2 次（`144-145`）；`findWordNode` 是 O(N) 字符串比较（`171-178`）。总比较次数 ≈ `80 × 2 × L × N + 2 × L × N`，N=300、L=1000 时约 4.8×10⁷ 次字符串比较；另有 `81-85` 的重复 id 校验是 O(N²)。
- **方案**：解析阶段建 `HashMap<String, Int64>`（id → 下标），`WordNetworkLink` 里直接存 `sourceIndex/targetIndex`；`81-85` 的重复校验改为「`contains` + 插入」一次完成；`runWordForce` 保留 O(N²/2) 的排斥循环（那是算法本身），但迭代次数改为常量上限 + 节点数分档（如 `min(80, max(20, 4000/N))`）。
- **预期**：链接相关比较从 `O(80·L·N)` 降到 `O(80·L)`，N=300/L=1000 时减少约 4.8×10⁷ 次比较；具体端到端降幅需实测（排斥循环仍是 O(80·N²)，Amdahl 上限受它约束）。
- **代价**：`WordNetworkLink` 结构变化（`f_chart` 内部类，无对外契约）；迭代次数按节点数调整会改变大图的布局收敛结果（图会「更团」），需产品确认是否接受。
- **验证**：`cjpm bench -O2`，输入 50/300/1000 节点 × 3 倍链接，记录单次 `draw` 耗时中位数与 P95；同时比对现有 `WordNetworkChart_test.cj` 的节点/连线计数用例输出不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 词云排序从插入排序换成 `std.sort`（先确认稳定性）

- **现状**：`WordCloudChart.cj:197-212` 手写插入排序，最坏 O(n²)（词表本身按权重逆序时），并且先 `ArrayList → toArray` 复制一次；词云常见输入是几百到几千词，n=2000 时移动量可达 2×10⁶ 次。
- **方案**：改用 `std.sort` 按键排序的稳定降序重载：`sort<WordCloudWord, Float64>(arr, key: { w => w.weight }, stable: true, descending: true)`（签名与参数语义见 `std/sort/sort_package_api/sort_package_funcs.md:6-22`，`stable`/`descending` 默认均为 false，必须显式传）。
- **预期**：n=2000 时比较次数从 ~2×10⁶ 降到 ~2×10⁴ 量级；端到端收益取决于排序在 `draw` 中的占比（未测）。
- **代价**：必须先核实当前 SDK 下 `sort` 的稳定性与「相等元素保持输入顺序」一致（现有 `wordCloudOrder` 的注释承诺稳定）；若不稳定需在比较器里带原始下标做 tie-break。
- **验证**：`cjpm bench -O2`，词表 100/1000/5000 三档，同输入取中位数；再用「全部同权重」用例断言输出顺序与改造前逐字节相同。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 37 部分 -->

### [CPU] 节点装配用 `ArrayList` 线性查找，整体 O(n²) → `HashMap` 索引

- **现状**：`parseNodes` 对每个新节点与已解析列表逐个比 `id`（`TuiFlameChart.cj:117-121`），`resolveRoot` 又对每个节点 `findNode` 全表线性扫描（`:144-151`、`:158`）。n = `nodes` 条数，每条约 2n 次字符串比较，n=10^4 时约 2×10^8 次比较 + 指针追逐
- **方案**：`parseNodes` 内维护 `HashMap<String, FlameNode>` 同时完成去重与建表；`resolveRoot` 改为单次哈希查找。`FlameNode` 定义在 `fountain::f_chart`（`FlameChart.cj:24`），助手可放同包供 SVG/TUI 共用（与上条重复逻辑同一落点）
- **预期**：复杂度从 O(n²) 降到 O(n)。收益随 n 放大，n≤100 时可忽略
- **代价**：多一份 `HashMap` 的常驻内存（约 n 个 entry，画完即释放）；`HashMap` 插入顺序不影响 `children` 顺序（仍按 `nodes` 数组顺序 `add`），渲染结果不变
- **验证**：`cjpm bench -O2`，同一份 1k/10k/50k 节点 JSON，各跑 30 轮取中位数；`cjprof record` 确认 `findNode`/`parseNodes` 的 self time 占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 画布按 `width × height` 逐格 new `TuiCell`，每次 `draw` 产生 width×height 个短命对象

- **现状**：`TuiCanvas` 构造为每个格子 `ArrayList.add(TuiCell())`（`TuiCanvas.cj:36-42`）；80×24 默认尺寸即 1920 个对象 + 1 个 `Array<TuiCell>`，每个 `TuiCell` 含 2 个 `String` 引用与 1 个 `Bool`。火焰图在 `draw` 内建一次即随返回值丢弃
- **方案**：改为「符号 `Array<String>` + 颜色 `Array<String>` + 标志位 `Array<Bool>`」三平行数组，或把 `TuiCell` 改成 `struct`（值类型可直接内联进 `Array`，省掉 1920 次堆分配与指针跳转）
- **预期**：每帧堆分配次数从 O(width×height) 降到 O(1)（3 个数组），GC 压力同比例下降；峰值内存不变（仍是 width×height 个槽位）
- **代价**：`cellSymbols()`/`plainLines()`/`render()` 三个访问点都要跟着改索引方式；`struct` 语义下 `cell.symbol = ...` 需改为数组赋值
- **验证**：多轮 `draw` 后 `getAllocatedHeapSize()` 增量与 GC 次数对比（改前/改后各 10^4 次绘制，`-O2`，同输入）；RSS 稳态对照
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README:176 的"全部通过"是否仍成立 | `f_chart/README.md:176` | 最近一次全量测试结果 | 在 `f_chart` 跑 `cjpm test`（本轮禁止跑构建），记录用例数与失败数 |
| 2 | 107 份 SVG 是否都能被 XML 解析器接受 | `f_chart/charts/*.svg` | 解析器校验结果 | `xmllint --noout charts/*.svg`，或用 `SvgParser` 批量回读（未见批量回读用例） |
| 3 | README 与 `README_en.md` 是否存在同源漂移（本部分只审中文版） | `f_chart/README_en.md` | 英文版逐段比对结果 | 属第 2 部分范围；本轮仅以结尾段落作旁证，未做全量对照 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 实跑用例数为 1173（TUI 81），文档 1168/76 已过期 | `f_chart/README_en.md:176` | 一次完整测试运行的 summary | WSL Ubuntu `source cangjie.sh` 后 `cd f_chart && cjpm test`，记录总数与 TUI 子包分段 |
| 2 | `charts/` 下 107 个 SVG 与当前源码一致（文档称改动会出现在 `git diff`） | `f_chart/README_en.md:191` | 重新生成后的 diff 是否为空 | `cjpm test --skip-build` 后 `git status charts/`，应为 0 改动 |
| 3 | M45/M46/M88/M89 改成嵌套数组后渲染 3 组 | `README_en.md:1115`、`:1133`、`:1035`、`:1053` | 改前/改后分组元素计数 | 两版 JSON 各生成一次，比较分组 `<rect>`/`<circle>` 数量与 x 轴标签数 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 层级图（treemap / sunburst / flame / org）递归深度随 `nodes` 链增长，深链会先爆栈 | `chart-json-spec.md:1318`、`:1397`、`:2271` | 实现是否递归、深度上界 | 构造 1k / 10k / 20k 层单链 `nodes` 调 `draw`，记录是否栈溢出与崩溃栈深（`cjprof` 栈采样） |
| 2 | 单次 `draw` 把整份 SVG 拼成 `String`，大点集下峰值内存与图元数线性增长 | `chart-json-spec.md:8`（返回完整 SVG 字符串） | 峰值 RSS / `getAllocatedHeapSize()` | `scatter` 输入 10k / 100k / 1M 点各跑 10 轮，记录峰值与 GC 后回落值，取中位数与离散度 |
| 3 | `cells` 无上限导致耗时与内存线性爆炸（见 #18） | `chart-json-spec.md:410`、`src/WaffleChart.cj:41-49` | 10^5 / 10^6 格的实际耗时与峰值 | `cells=10^5,10^6,10^7` 各跑一次，记录墙钟时间与峰值内存，定位失败点 |
| 4 | 绘图区左边距按"刻度文本最大宽度"估算，CJK 标签下可能重叠或溢出 | `doc/spec/add-f-chart-bar/design.md:45-46`、`src/BarRenderer.cj:83` | CJK 标签的实测布局 | 用 20 个 CJK 类目 + 6 位数值画柱图，导出 SVG 后复核 `tick-label` 的 `x` 是否越过绘图区左边界、相邻标签是否重叠 |

<!-- 第 4 部分 -->

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 箱线散点的插入排序在大样本下成为热点 | `f_chart/src/BoxScatterChart.cj:163,245-260` | 排序自耗时占 `draw` 的比例、n 的分布 | `cjprof record` 跑单组 1k / 10k / 100k 样本的 `box-scatter` 渲染各 100 次，看 `sortValues` self time 占比 |
| 2 | Bland-Altman 右端标签的动态宽度计算不会带来可观开销 | `f_chart/src/BlandAltmanChart.cj:144-147` | 三条 `chartTextWidth` 调用的耗时（相对整图） | 分段计时，10 万点场景对比加/不加预计算的 `draw` 耗时 |
| 3 | 气泡图多系列 + 千级点数时，`bubbleRadius` 与标签文本是主要分配源 | `f_chart/src/BubbleChart.cj:206-226` | 每轮分配字节数、GC 次数 | `cjprof heap` + 分配量计数，输入 5 系列 × 2000 点 |

<!-- 第 5 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 日历图「同日求和」是先线性查重再线性累加（O(U²)），逐格取值又对 `uniqueDays` 线性扫描（O(D·U)）；长区间 + 多数据项时可能成为 `draw` 主耗时 | `f_chart/src/CalendarHeatmapChart.cj:131-146`、`:191-196` | 该段自耗时占 `draw` 的比例及随 D/U 的增长曲线 | `cjprof record` 跑 `startDate=2016-01-01,endDate=2025-12-31`（D≈3653）+ 5000 条数据，再跑 D=365 对照；与 `HashMap<Int64, Float64>` 版本同输入中位数对比 |
| 2 | 逐格拼 SVG 字符串的分配峰值（`StringBuilder` 扩容 + 最终 `toString`）显著大于图元本身，长区间下是 OOM 的先到点 | `f_chart/src/CalendarHeatmapChart.cj:164-216` | `getAllocatedHeapSize()` 峰值与 RSS 峰值 | 同 SDK、`-O2`，跑 365 天与 3653 天两档，记录 `getAllocatedHeapSize()` / `getUsedHeapSize()` / RSS 与输出长度 |
| 3 | 和弦图每次 `draw` 对每条链接再调 3 次 `findNode`（`170`、`171`、`183`），整体 O(L·N) 字符串比较；节点上百、链接上千时占可观比例 | `f_chart/src/ChordChart.cj:107-108`、`:170-183`、`:204-211` | `findNode` 自耗时占比与总调用次数 | `cjprof record` 跑 N=200、L=2000；与「建一次 `HashMap<String, Int64>` 索引」的同输入中位数对比 |
| 4 | 校准图对原始点做插入排序（`sortLiftPoints`，`LiftChart.cj:203-216` 为 `O(n²)` 洗牌式插入），README 又暗示按样本量入图（每次预测一个点），样本上万时排序可能压过绘制 | `f_chart/src/CalibrationChart.cj:69` | 排序段自耗时占比、n=1k/1w/5w 的耗时曲线 | `cjpm bench` 或分段计时，n 取 1k/1w/5w 三档，与稳定排序（`sort` by x）对照 |

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 和弦图解析/绘制是热点（每条链接 5 次线性 `findNode` + 解析期 O(n²) 去重） | `f_chart/src/ChordChart.cj:82-86,107-113,170-183` | 自耗时占比、n/m 规模 | `cjprof record` 跑 1000 节点 / 3000 链接的 `draw` ×1000，`cjprof report` 看 `findNode` self time |
| 2 | `combo` 的 4 次 `buildBarGroups` 有可观开销 | `f_chart/src/ComboChart.cj:376,498-499` | 绘制耗时占比 | `cjpm bench -O2` 对照 20 系列 × 50 类目，改前改后各 10 轮取中位数 |
| 3 | 等高线 `uniqueSorted` 的 O(P²) 在大网格下明显 | `f_chart/src/ContourChart.cj:211-236` | P 的实际分布、解析耗时占比 | 用 50×50 / 200×200 网格各跑 100 次 `draw`，分段计时解析段 vs 绘制段 |
| 4 | 圆堆积的插入排序在宽树（根下数百子节点）下可见 | `f_chart/src/CirclePackingChart.cj:174-184` | 兄弟节点数上限、耗时占比 | 构造根下 500 子节点的输入，`cjpm bench -O2` 对照 `sort` 前后 |
| 5 | `pathCentroid` 的逐字节 `toArray()` + 每数字一次 `String.fromUtf8` 在区域多时占解析时间 | `f_chart/src/ChoroplethChart.cj:176-203` | 区域数 × 路径长度、耗时占比 | 500 个区域各 200 段 path 的输入跑 `cjprof`，看 `pathCentroid` self time |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 密度图的 KDE 是 `draw` 的主耗时（`101 × n × 系列` 次 `exp`，且算两遍） | `f_chart/src/DensityChart.cj:141-151,244-248` | `gaussianKde` 自耗时占比、样本规模 | `cjprof record` 跑 10 系列 × 1e4 样本 `draw` ×100，`cjprof report` 看 `gaussianKde` self time |
| 2 | 决策树解析/布局里的线性查找是 O(n²)（每条边 2 次 `findDecisionNode`、根判定是三层循环、`decisionEdgeLabel` 每次画边全表扫） | `f_chart/src/DecisionTreeChart.cj:124-129,141-153,168-181,236` | 节点/边规模分布、耗时占比 | 构造 500/2000 节点树，`cjpm bench -O2` 对照「`findDecisionNode` 换 `HashMap` 」的前后中位数 |
| 3 | 差分火焰图每节点一次 `chartTextWidth`（`drawNode:242`）在数千节点时进入热点 | `f_chart/src/DifferentialFlameChart.cj:242` | 单次文本测量开销、节点数 | 3000 节点栈跑 `cjprof`，看 `chartTextWidth` self time |
| 4 | 等高线大网格的 `uniqueSorted`（O(P²) 去重 + 插入排序）与逐点 `indexOf` 在解析段占比可观 | `f_chart/src/ContourChart.cj:211-245`（第 6 部分 #13 同源） | P 的实际分布、解析段耗时 | 50×50 / 200×200 网格各 100 次 `draw`，分段计时解析 vs 绘制 |

<!-- 第 8 部分 -->

> 本部分不含代码，未提出性能假设（0 条）。下表三条属"需要实测才能确认的视觉/行为/稳定性猜测"，不是性能结论，也不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 深色主题（`theme.background` 非白）下环形图内孔白斑与中心文本对比度反转的实际可读性影响面 | `f_chart/src/DonutChart.cj:143,150` | 主题背景与 `textColor` 的取值分布、实际渲染截图 | 用 `theme: {background: "#1e1e1e", textColor: "#eeeeee"}` 跑 M032 用例并导出 SVG，目视 + 对比度计算（WCAG） |
| 2 | 其它横向类目图（`BarRenderer` 等未调用 `drawYAxis` 的图）是否也存在"数值轴网格缺失 / 位置错"的视觉缺陷 | `f_chart/src/BarRenderer.cj:113` 等 | 各图样例 SVG 的网格与刻度坐标实测 | 批量解析 `f_chart/charts/M*.svg` 中 `class="grid"` 的端点，按绘图区边界统计越界比例 |
| 3 | 差分火焰的深链输入（如 1 万层单链）在 `layoutNode` / `drawNode` 无深度保护递归下是否栈溢出 | `f_chart/src/DifferentialFlameChart.cj:214-259` | 单帧大小、平台栈上限、首个崩溃深度 | 构造 1k / 5k / 10k / 50k 层单链 `nodes` 调 `draw`，记录是否 `StackOverflow` 与首个失败深度 |

<!-- 第 9 部分 -->

> 本部分不含代码，未提出性能结论。下表用于下一轮补数据，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ECDF 插入排序在 1e4+ 样本下成为渲染热点 | `f_chart/src/EcdfChart.cj:202`、`RaincloudChart.cj:320-335` | 排序自耗时占 `draw` 的比例 | `cjprof record` 渲染 1k/1e4/1e5 样本 ECDF，看 self time |
| 2 | 火焰图 O(n²) 去重/查找在节点数上万时显著 | `f_chart/src/FlameChart.cj:71-75,99` | 耗时随 n 的增长曲线 | `cjpm bench -O2`，n=1k/10k/50k 单链与宽树各一组 |
| 3 | 流程图 4 层以上越界的实际裁切比例（缺陷 6 的量化） | `f_chart/src/Flowchart.cj:248-261` | 不同层数/节点高度下超出 plot 的节点数 | 生成 3–8 层的图，解析 SVG 的 `node` 外接矩形与 `viewBox` 比较 |
| 4 | `horizontal` 布局箭头被遮的实际可见性 | `f_chart/src/Flowchart.cj:285-296` | 箭头顶点的实际坐标与节点边界 | 两节点 120×48 + `horizontal` 导图目视，并比对 `edge-arrow` 顶点 |

<!-- 第 10 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 增益/提升图的排序是绘制耗时主项（n ≥ 1万、逆序输入时） | `f_chart/src/LiftChart.cj:203-218` | `sortLiftPoints` 自耗时占比 | `cjprof record` 跑 `GainChart.draw`，输入 1万/10万点，看 self time |
| 2 | 流程图分层松弛 O(节点数 × 边数) 在大图上成为瓶颈 | `f_chart/src/Flowchart.cj:219-228` | 节点/边规模与自耗时占比 | 构造 500 节点/1000 边与 5000 节点/10000 边两组输入，分段计时 `layoutNodes` |
| 3 | SVG 字符串拼接在大点数时主导增益图耗时与分配 | `f_chart/src/GainChart.cj:154-171` | `StringBuilder` 增长次数与单次绘制耗时 | 同上输入下对比「只解析 + 只排序 + 只拼接」三段计时 |

<!-- 第 11 部分 -->

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

<!-- 第 12 部分 -->

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HiveChart.findNode` 的 O(n·m) 扫描是蜂巢图渲染的主要 CPU 项 | `f_chart/src/HiveChart.cj:113-118, 194-195, 215-222` | 自耗时占比、调用路径 | `cjprof record` 跑 n=5000 / m=10000 的 `draw` 200 次，看 `findNode` self time 占比 |
| 2 | 冰柱图深链输入会在「万级」深度爆栈 | `f_chart/src/IcicleChart.cj:166-244` | 崩溃临界深度、单帧栈占用 | 生成 1k / 5k / 10k / 20k 层退化链逐级 `draw`，记录首次栈溢出的深度（同 SDK、默认栈大小） |
| 3 | `bins` 取 10³–10⁴ 量级时，分箱数组的分配与清零成为端到端主要耗时 | `f_chart/src/HistogramChart.cj:247-251`；`f_chart/src/Histogram2DChart.cj:289-291` | 分配量、单次耗时、GC 次数 | 固定 100 个数据点，`bins` 取 16 / 1024 / 65536 / 1e6，分段计时并记 `getAllocatedHeapSize()` 与 GC 次数 |
| 4 | 颜色解析占热力图渲染耗时的显著比例 | `f_chart/src/HeatmapChart.cj:225-248` | `SvgColor.tryParse` 自耗时占比 | `cjprof record` 渲染 200×200 矩阵 20 次，取占比中位数 |

<!-- 第 13 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sortLiftPoints` 是插入排序（O(n²)），Lift / LassoPath / LearningCurve 三个图型共用；点数上千后排序可能成为 `draw()` 的主耗时 | `f_chart/src/LiftChart.cj:202-218`（被 `:65`、`LassoPathChart.cj:80`、`LearningCurveChart.cj:112` 调用） | n 从 100 到 10000 时的排序耗时与占 `draw()` 的比例 | `cjpm bench -O2` 生成 100 / 1000 / 10000 点的 `{x,y}` 输入，对 `draw()` 计时取中位数与离散度；或用 `cjprof record` 看 `sortLiftPoints` self time |
| 2 | 每个数据点用 `StringBuilder` 追加 `" L x y"` 生成 path，大 n 下字符串分配可能主导 GC；LASSO / 学习曲线 / 提升 / 折线四者同构 | `f_chart/src/LassoPathChart.cj:186-202`、`LearningCurveChart.cj:221-262`、`LiftChart.cj:171-187`、`LineChart.cj:411-431` | 单次 `draw()` 的分配字节数与 GC 次数 | `getAllocatedHeapSize()` 前后差值 + `cjprof heap`，输入 1k / 10k 点，各跑 200 次取中位数 |

<!-- 第 14 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 网络热力图 N×N 输出的峰值内存与耗时（#5 的量化） | `f_chart/src/NetworkHeatmapChart.cj:182-204` | N=200 / 500 / 1000 时的 SVG 字节数、`getAllocatedHeapSize()` 峰值、单次 `draw` 耗时中位数 | `cjpm bench -O2` 跑三档 N 各 30 轮取中位数；同时记录 `svg.size` 与分配量差值 |
| 2 | 曼哈顿图按染色体分组的线性查找是否成为热点 | `f_chart/src/ManhattanChart.cj:205-210`（`chromosomeOrder.contains`）、`:238-247`（`manhattanPositions` 内再扫一遍） | 位点数 10⁵–10⁶、染色体数 ≤ 25 时该循环在 `draw` 内的自耗时占比 | `cjprof record` 跑 GWAS 规模输入，看 `ManhattanChart.draw` 内该循环是否 > 5%；锁竞争不适用（纯单线程） |

<!-- 第 15 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 组织图 / 离线火焰图的递归在单链输入下的实际溢出深度（#6 的量化） | `f_chart/src/OrgChart.cj:218-238`、`f_chart/src/OfflineFlameChart.cj:176-248` | 触发 `StackOverflow` 的最小树高；平台默认栈大小 | 生成链高 1k / 2k / 5k / 10k 的单链 `nodes`，`cjpm bench -O2`（或直接 `cjpm run` 用例）逐档跑 `draw`，记录崩溃/正常与耗时；同机记录栈大小配置 |
| 2 | 节点-链接图力导向的耗时构成（80 轮 × O(n²) 斥力 + 每轮每条边两次 O(n) `findNode`） | `f_chart/src/NodeLinkChart.cj:227-262`、`:243-244` | n = 200/500/1000、\|E\| = 2n 时的自耗时占比 | `cjprof record` 跑三档规模的 `draw`（每档 30 次取中位数），看 `runForce` 自耗时占比是否 > 5%；若集中在 `findNode`，改 id→索引映射后同环境复测 |

<!-- 第 16 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `paretoOrder` 的手写插入排序在类目数上千后退化为 O(n²) 热点（n=10⁴ 约 10⁸ 次比较） | `f_chart/src/ParetoChart.cj:207-215` | 不同 n 下的单次耗时与自耗时占比 | `cjpm bench -O2` 跑 n = 10²/10³/10⁴ 的 pareto 输入，记录中位数与离散度；必要时 `cjprof record` 看 `paretoOrder` self time |
| 2 | 平行坐标每行用 `StringBuilder` + `formatSvgNumber` 逐点拼 `d`，在「行数 × 维度数」大时成为 CPU/分配热点 | `f_chart/src/ParallelCoordinatesChart.cj:242-264` | 分配量与耗时占比 | 固定 10 维、行数 10³→10⁵ 递增，`cjprof record` + `getAllocatedHeapSize()` 差分 |
| 3 | 六个图表都全量物化输入（`ArrayList` 逐项 + `toArray()` 拷贝）并一次性生成整段 SVG 字符串，无输入上限，超大输入会先抬 RSS 再 OOM | `f_chart/src/ParallelCoordinatesChart.cj:96-125`、`f_chart/src/ParetoChart.cj:52-83`、`f_chart/src/PairedLineChart.cj:70-83` | 峰值 RSS / 堆占用随 n 的曲线与容器 limit | 逐步放大行数/类目数到 OOM 边界，记录 `getUsedHeapSize()`、RSS 与输出 SVG 字节数，给出「n 多大时峰值 = limit」 |

<!-- 第 17 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序在 1e4–1e5 个工作点时会成为 PR/概率图渲染的主要耗时 | `f_chart/doc/spec/add-f-chart-pr/design.md:6`、`f_chart/src/PrChart.cj:197`、`f_chart/src/ProbabilityChart.cj:156` | 排序自耗时占比、端到端耗时随 n 的增长曲线 | `cjprof record` 渲染 1e3/1e4/1e5 点的 PR 图各 20 次，取 self time |
| 2 | 象形图的逐图标字符串拼接（每次 10+ 次 `formatSvgNumber` + 连接）在中大规模下分配量偏高 | `f_chart/src/PictogramChart.cj:130`、`f_chart/src/PictogramChart.cj:153` | 每千图标分配字节数、峰值 RSS | 渲染 1e4 / 1e5 图标，`cjprof heap` + `getAllocatedHeapSize()` + RSS |
| 3 | 大量 `ArrayList → toArray()` 拷贝在多图批量渲染时有可见分配占比 | `f_chart/src/PieChart.cj:84`、`f_chart/src/BarRenderer.cj:112` | 单次 `draw` 的分配量与 GC 次数 | 批量渲染 1000 张同构图表，记录分配总量与 GC 停顿 |

<!-- 第 18 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| — | 无 | — | 本部分无性能承诺或性能描述，文档中的采样点数（48 / 81）为固定常量，不随输入增长，不存在「文档宣称的性能结论待验证」的场景 | — |

<!-- 第 19 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 散点矩阵的输出成本随 `variables² × rows` 增长，n≥10 后单次 `draw` 的耗时与峰值内存可观（规格未设上限，见发现 #6） | `f_chart/src/ScatterMatrixChart.cj:171-207` | 绝对耗时、峰值 RSS、SVG 长度随 n 的曲线 | `cjpm bench -O2`，variables 取 5/10/20/40、rows 固定 1000，每档 5 轮取中位数；同时记录 `draw` 返回串长度与 `getUsedHeapSize()` |
| 2 | 桑基图节点/链接规模大时 `indexOfNode`（每次线性扫节点表）在链接校验、端点映射、流量带绘制三处重复调用，可能占自耗时显著比例 | `f_chart/src/SankeyChart.cj:101`、`:119`、`:138-139`、`:224-225` | 该函数在 `draw` 内的自耗时占比与调用次数 | `cjprof record` 跑 V=200 / E=2000 的合成桑基图，看 `indexOfNode` self time 占比与累计调用次数（静态上为 O(V·E)，但未测实际占比） |

<!-- 第 20 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 合并两份累计实现（`draw` 内联 vs `stackedAreaBounds`）可省掉一次 O(series×category) 遍历 | `f_chart/src/StackedAreaChart.cj:171-187`、`:347-377` | 该遍历在 `draw` 自耗时中的占比 | `cjprof record` 跑 `stacked-area`，series=20、category=200，渲染 200 次，看两段循环的 self time 占比；低于噪声（约 5%）则只做去重、不承诺收益 |

<!-- 第 21 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| — | 无 | — | 本部分文档不含性能承诺；提到的常量（叶位数上限 6、透明度 0.85/0.15、5% 余量）都不随输入增长，不存在「文档宣称的性能结论待验证」 | — |

<!-- 第 22 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | treemap 布局的子树值被重复求和，深树 / 多子节点时呈 O(k²·subtree) 量级：`sortChildren` 用插入排序并每次比较都调 `nodeValue`（递归整棵子树），`layoutNode` 又对每个子节点再算一次 | `f_chart/src/TreemapChart.cj:174-189`、`:221-231` | 不同节点数（100 / 1k / 10k）与不同分支因子下的绘制耗时占比 | `cjpm bench -O2` 对同一 `nodes` 输入计时，再 `cjprof record` 看 `nodeValue` self time 占比；先做「预计算 value 缓存 + O(k log k) 排序」的前后对照 |
| 2 | 深链形态的 treemap 输入（每层单子节点、深度 = 节点数）会让递归 `nodeValue` / `layoutNode` 深度达到节点数量级，可能触发栈溢出 | `f_chart/doc/spec/add-f-chart-treemap/design.md:7`、`:12`；`f_chart/src/TreemapChart.cj:159-172`、`:191-244` | 实际崩溃深度阈值（与默认线程栈大小相关），以及业务侧允许的最大层级 | 构造 1k / 5k / 10k 层链式 `nodes` 调 `draw`，记录首次抛 `StackOverflowError` 的深度；按官方文档核对默认栈大小后给出安全上界，超限改为显式栈迭代 |

<!-- 第 23 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 火焰图布局用递归实现（`layoutNode` / `validateTree` / `assignDepth`），递归深度上界 = `nodes.size`，深链输入（如 5 万层）会耗尽线程栈，而 design 只写了「递归分配」未提深度上限 | `f_chart/src/tui/TuiFlameChart.cj:172-225`、`doc/spec/add-f-chart-tui-flame/design.md:20` | 默认栈大小、单帧字节数、崩溃临界深度 | 构造 1k / 1万 / 5万层链式 `nodes`，在 80×24 下逐个跑 `TuiFlameChart().draw`，记录首个崩溃深度与异常类型（若为 `StackOverflowError` 则升级为缺陷） |

<!-- 第 24 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 词网络 force 布局在 n≥500 时单次 `draw` 进入百毫秒级，且耗时主要来自 O(n²) 斥力与 `findWordNode` | `f_chart/src/WordNetworkChart.cj:199-234` | 单次 `draw` 分段耗时与自耗时占比 | 构造 n=100/500/2000 的确定性 JSON，`cjpm bench -O2` 跑 20 轮取中位数；再用 `cjprof record` 分离 `runWordForce` / `findWordNode` |
| 2 | 华夫图 `cells` 取 1e5 时 SVG 字节数与峰值堆内存线性增长，到 1e6 会触发长 GC 或 OOM | `f_chart/src/WaffleChart.cj:119-138` | `svg.length()`、`getAllocatedHeapSize()`、GC 次数 | 对 `cells=100/1000/10000/100000` 各跑 10 次，记录长度与峰值，拟合线性系数 |
| 3 | 词云货架布局在真实 CJK 字体下，`chartTextWidth`（`rune >= 0x2E80` 记 1em）与浏览器实际宽度偏差导致重叠而非仅仅越界 | `f_chart/src/ChartScale.cj:113-123`、`WordCloudChart.cj:133-147` | 估算宽度 vs 渲染宽度的偏差分布 | 用固定词表生成 SVG，headless 浏览器量 `getBBox()`，对比 `chartTextWidth`，统计最大偏差与重叠次数 |
| 4 | 瀑布图点数 >46 时柱宽被 8px 下限撑开，柱与柱重叠且连接器落点偏离柱边 | `f_chart/src/WaterfallChart.cj:179`、`201-212` | 重叠像素量与视觉可读性阈值 | 生成 n=20/50/100/200 的瀑布图，量 `bandWidth` 与 `barWidth` 比值，并截图核对重叠 |

<!-- 第 25 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序在万级样本下成为 `draw` 的主要耗时 | `ArcChart.cj:220-228`、`BoxScatterChart.cj:250-258` | 自耗时占比、n 的拐点 | `cjprof record` 跑 1k/10k 点，`cjpm bench -O2` 取中位数 |
| 2 | 节点 id 去重（`O(n²)`）与每条链接 `findNode`（`O(n·m)`）在万级输入下拖慢 | `AlluvialChart.cj:104-108`、`AlluvialChart.cj:218-219`、`ArcChart.cj:83-87`、`ArcChart.cj:155-156` | 输入规模与耗时曲线 | 造 10k 节点 / 20k 链接输入，分段计时解析段与绘制段 |
| 3 | 冲积图每阶段重建 `members`/`totals`/`heights` 与重复求和带来可观的短生命周期分配 | `AlluvialChart.cj:154-174` | 分配量、峰值占比 | `getAllocatedHeapSize()` 前后对照，10 阶段 × 10k 节点 |
| 4 | local mode 对解析期临时对象（`AreaSeries`/`BubblePoint`/`BulletItem` 等）有峰值内存收益 | `AreaChart.cj:222-274`、`BubbleChart.cj:113-127`、`BulletChart.cj:62-98` | 改前/改后峰值内存（`getUsedHeapSize()` + RSS） | 需 `--experimental --enable-local-mode` 编译对照，同输入同并发；注意 `cjLocalRegionMaxSize` 上限与工具链支持 |
| 5 | 气泡图半径只按「全图 size 极值 + 每系列半径区间」映射，跨系列同 size 半径不同，是否与规格预期一致 | `BubbleChart.cj:136-147`、`BubbleChart.cj:209-211` | 规格确认（尺寸归一化是否应跨系列统一） | 与需求方确认后补一条多系列同 size 的用例 |

<!-- 第 26 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 日历热力图的耗时与内存由 `dayCount` 主导，1 年数据在整图耗时中占绝对多数 | `f_chart/src/CalendarHeatmapChart.cj:183-216` | 1 年 / 10 年两档输入的端到端耗时、峰值 RSS、SVG 字节数 | 固定 JSON、`-O2` 跑 5 轮取中位数；`cjprof heap` + 输出文件大小对照 |
| 2 | `chartTextWidth` 在图例项多、刻度多时被重复计算（`drawLegend` 每项算两次）构成可观自耗时 | `f_chart/src/ChartFrame.cj:142-164` | 自耗时占比 | `cjprof record` 跑 50 个图例项的图，看 `chartTextWidth` self time |
| 3 | 本部分函数内临时对象（`ArrayList`、`StringBuilder`、`Candle`、`ChartConfig` 树）适合 local mode 改造以降峰值内存 | `CandlestickChart.cj:65-87`、`CalendarHeatmapChart.cj:129-146` | 改前改后峰值内存（`getUsedHeapSize()` / RSS）、`getAllocatedLocalObjectSize()` | 需 `--experimental --enable-local-mode`，同输入 `-O2` 对照；注意 std 集合是否有 local 构造重载、`ChartConfig` 会随 `ChartFrame` 存活到函数末尾，逃逸需逐个核对 |

<!-- 第 27 部分 -->

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 等高线网格构建（`uniqueSorted` + `indexOf`）是 `contour` 的主要 CPU 开销 | `f_chart/src/ContourChart.cj:211-245` | 自耗时占比 | `cjprof record` 跑 `ContourChart_test` 的 100×100 网格样本，看 `uniqueSorted`/`indexOf` self time |
| 2 | 和弦图 `findNode` 是 links 规模上的热点 | `f_chart/src/ChordChart.cj:204-211` | 自耗时占比与 links 规模拐点 | `cjpm bench -O2`，links = 100/500/2000，对比「线性查」与「HashMap」两版 |
| 3 | 决策树根检测的 `n×e` 扫描在 n ≥ 1000 时开始主导 | `f_chart/src/DecisionTreeChart.cj:168-181` | 自耗时占比 | `cjprof` 跑 1000 节点链/星形两种拓扑，看该循环 self time |
| 4 | 圆堆积/决策树在 3000+ 层输入下栈溢出 | `CirclePackingChart.cj:146,170,190,221`、`DecisionTreeChart.cj:301,310,318` | 实际可承受深度（依赖线程栈大小） | 生成 depth = 500/1000/2000/5000 的链式输入跑 `draw`，记录崩溃点；同时给出默认线程栈大小 |

<!-- 第 28 部分 -->

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `gaussianKde` 是 `density` 图的主要自耗时点 | `f_chart/src/DensityChart.cj:272-283` | 自耗时占比、调用次数 | `cjprof record` 渲染 3 系列 × 10k 值，统计 `gaussianKde`/`draw` 占比 |
| 2 | 火焰图 O(n²) 查重在建树阶段占比超过 50% | `f_chart/src/FlameChart.cj:71-75,99`；`DifferentialFlameChart.cj:74-78,107` | 建树 vs 布局 vs 序列化分段耗时 | 分段计时 + `cjpm bench -O2`，输入 2k/10k/50k 节点 |
| 3 | `sortRaincloud` 插入排序在 n≥10k 时主导 `ecdf` 耗时 | `f_chart/src/EcdfChart.cj:202`；`RaincloudChart.cj:320` | 排序耗时占比、不同分布的差异 | `cjprof` + 随机/升序/降序各 10k、100k 输入 |
| 4 | ECDF 路径逐点 `formatSvgNumber` 字符串拼接是第二大开销 | `f_chart/src/EcdfChart.cj:171-186` | 字符串构造占比 | `cjprof record`，n=100k 单系列 |
| 5 | 火焰图 `rect`/`text` 的 SVG 序列化（`toSvgString`）占比可观 | `f_chart/src/FlameChart.cj:226-244` | 序列化耗时占比 | `cjprof`，5k 节点；对照 `builder` 与最终字符串长度 |

<!-- 第 29 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `heat-flame` 建树的 O(n²) 查重/查找在 n≥10k 时成为单次 `draw` 的主要耗时 | `f_chart/src/HeatFlameChart.cj:78-82,115` | 自耗时占比、调用次数 | 生成 10k 节点 JSON，`cjprof record` 跑 100 次 `draw`，看 `findNode` 与 id 比较的 self time |
| 2 | `flow-map` 的 O(F·R) 线性查找 + 插入排序在 F=5k、R=1k 时可感知 | `f_chart/src/FlowMapChart.cj:125-130,196-197,234-249` | F·R 规模下的单次耗时占比 | 生成 1k 区域 × 5k 流的 JSON，分段计时 `parse` / `sortFlows` / `draw` |
| 3 | 单次 `draw` 的临时分配（`StringBuilder` + 多层 `ArrayList`）在 10k 数据点时造成明显 GC 抖动 | 本部分全部 `draw` | 每次分配字节数、GC 次数 | `getAllocatedHeapSize()` 前后差 + `cjprof heap`，同输入跑 5 轮 |
| 4 | 2 色 `colorRange` 时每个节点 2 次 `SvgColor.tryParse`（`heatFlameColor` 277-278）在 10k 节点下可测 | `f_chart/src/HeatFlameChart.cj:271-282` | 解析耗时占比 | 微基准：10k 次 `heatFlameColor` 调用，对照预解析后的插值实现 |

> 4 条均无改前基线，仅作下一轮补数据清单，不计入模块统计，不进 `todo.md` / `tasks.md`。

<!-- 第 30 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `heatmapColor` 的重复颜色解析是热力图主要 CPU 段 | `f_chart/src/HeatmapChart.cj:156`、`:233-235` | 自耗时占比 | `cjprof record` 渲染 1000×1000 矩阵，取 `SvgColor.tryParse` 与 `heatmapColor` 的 self time |
| 2 | 插入排序在万级点数的系列上已有可感知开销 | `f_chart/src/LiftChart.cj:203-218` | 排序段耗时与占比 | `cjpm bench -O2`，n=1k/10k/50k，单独计时排序前后 |
| 3 | HiveChart 在千级节点/链接时 O(n²) 建图成为瓶颈 | `f_chart/src/HiveChart.cj:87-144` | 建图段耗时 | 5k 节点 + 5k 链接 profile，量 `findNode` 调用次数与累计耗时 |
| 4 | IcicleChart 深链的实际爆栈阈值 | `f_chart/src/IcicleChart.cj:192-244` | 崩溃深度 | 生成 1k/5k/10k 层链式 `nodes`，逐级试渲染，记录首个崩溃深度与平台栈大小 |
| 5 | 矩阵/点数组适合 local mode，能降峰值内存 | `f_chart/src/HeatmapChart.cj:48-89`、`f_chart/src/Histogram2DChart.cj:95-109` | 峰值内存与逃逸结论 | 开启 `--experimental --enable-local-mode` 后对比 `getUsedHeapSize()` 峰值与 `getAllocatedLocalObjectSize()`；确认 `matrix`/`points` 不逃逸出 `draw` |

<!-- 第 31 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 力导向布局在 N≥500 时成为主耗时（80 轮 × N² 对计算） | `f_chart/src/NodeLinkChart.cj:227-241` | 自耗时占比、端到端 `draw` 时间随 N 的曲线 | `cjprof record` 跑 N=100/300/800 各 30 轮，`cjpm bench -O2` 取中位数 |
| 2 | `findNode` 在边数 `E` 大时占比超过斥力项（`80 × E × 2 × N` 次字符串比较） | `f_chart/src/NodeLinkChart.cj:242-254` | `findNode` self time 占比 | 同上场景，固定 N=500、E=500/2000 两档对比 |
| 3 | 曼哈顿图 100 万点时的峰值内存与 `positions` 复制占比 | `f_chart/src/ManhattanChart.cj:67-89` | 峰值 RSS、`getAllocatedHeapSize()`、各数组占比 | 生成 10 万/50 万/100 万点 JSON，`-O2` 多轮绘制取峰值 |
| 4 | 网络热力图 100×100 时颜色解析占比可观 | `f_chart/src/NetworkHeatmapChart.cj:182-205` | `SvgColor.tryParse` self time 占比 | `cjprof record` 跑 50×50 / 100×100 / 200×200，统计 `tryParse` 调用次数与耗时 |

<!-- 第 32 部分 -->

> 无性能测试数据支撑，不作为缺陷，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序 O(n²) 在类目数 5k+ 时成为 `draw` 主要耗时（Pareto 排序 + 累计） | `ParetoChart.cj:202`、`PrChart.cj:197`、`QQChart.cj:156` | 函数自耗时占比、n 与耗时曲线 | `cjprof record` 跑 pareto / pr，输入 1k / 5k / 20k 条，`-O2`，同机对照 |
| 2 | 每张图把整棵 `SvgBuilder` DOM 与输出串全量物化，峰值内存 ≈ 图元数 × 单元素开销 | 本部分全部 `draw`（如 `PictogramChart.cj:99-140`、`QQChart.cj:117-153`） | 峰值 heap/RSS 与图元计数 | 1 万点散点/1 万图标各跑 100 次，取 `getAllocatedHeapSize()` 峰值与 RSS 中位数 |
| 3 | 106 份 `count` helper 的 O(n·m) 扫描占测试总时长可观比例 | 本部分 10 个 `*_test.cj` 的 `count` | 测试总耗时、`count` 调用次数与单次扫描长度 | 对 `f_chart` 跑 `cjpm test` 分段计时，统计 `count` 调用总数与平均 SVG 长度 |

<!-- 第 33 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 核密度采样是雨云图/山脊图的绘制热点（每图 `48×n`、`81×n` 次 `exp`） | `RaincloudChart.cj:234-239`、`RidgeChart.cj:154-162` | 自耗时占比 | `cjprof record` 绘制 12 组 × 1000 值的雨云图与 20 系列山脊图，取 `gaussianKde` self time |
| 2 | 桑基图 `indexOfNode` 的线性查找在节点/链接数增大后成为主要耗时（O(n·m)） | `SankeyChart.cj:101`、`118-121`、`137-139`、`223-225`、`264-271` | 实际耗时随 n、m 的曲线 | 构造 200 节点 / 1000 链接输入，分段计时 `draw` 前后半段 |
| 3 | 插入排序在 ROC 点数 > 1000 时成为瓶颈 | `RocChart.cj:188-203` | n = 100/1000/5000 的单次耗时 | `cjpm bench -O2`，同输入取中位数与 P95 |
| 4 | 路径 `StringBuilder` 拼接占单次绘制 CPU 的比例 | `RadarChart.cj:146-159`、`RocChart.cj:153-162` | self time 占比 | `cjprof record` 跑 200 点散点/ROC，看 `StringBuilder.append` 占比 |

<!-- 第 34 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 主题河流图 `S²·C` 累加在系列多时成为主要 CPU 段 | `f_chart/src/StreamgraphChart.cj:188-214` | 自耗时占比、调用路径 | `cjprof record` 跑 S=200/C=1000 的 `draw`，100 次取中位数 |
| 2 | 旭日图 `findNode` + 去重的 O(n²) 在 n≥2000 时可见 | `f_chart/src/SunburstChart.cj:78-82`、`:141-148` | 每阶段耗时占比 | `cjprof record` 跑 n=5000 宽树；分段计时建树 vs 绘制 |
| 3 | 22 处插入排序在 n≥10k 时拖慢 `draw` | `ShapChart.cj:179-187`、`StemLeafChart.cj:164-172`、`SurvivalChart.cj:280-288`、`SunburstChart.cj:183-191` | 排序耗时占比 | `cjpm bench -O2`，n∈{1k,10k,100k} 对照 std 排序 |
| 4 | 堆叠面积图 `2·S·C` 层数组是峰值内存主项 | `StackedAreaChart.cj:159-170` | `getAllocatedHeapSize()` 峰值、RSS 曲线 | S=50/C=2000 与 S=200/C=10000 两组各跑 20 轮 |
| 5 | 螺旋图 `2n` 次分配带来可测 GC 抖动 | `SpiralChart.cj:117-158` | 分配速率、GC 次数 | `cjprof heap` 或 `getAllocatedHeapSize()` 增量，n=10k |
| 6 | `draw` 内临时 `StringBuilder`/数组适合 local mode | `ShapChart.cj:130-167`、`SpiralChart.cj:116-128`、`StemLeafChart.cj:126-132` | 改前/改后峰值内存 | 先按 `mem §1` 排除长期引用，再开 `--enable-local-mode` 对照 `getUsedHeapSize()` 峰值；注意 `draw` 返回 `String`、多数临时对象在返回前不再逃逸，但 `cjLocalRegionMaxSize` 是新的 OOM 面 |
| 7 | 旭日图深链（深度≈节点数）会在某个 n 上栈溢出 | `f_chart/src/SunburstChart.cj:150-176`、`:178-196`、`:198-210`、`:212-249` | 触发溢出的最小深度、单帧栈占用 | 构造 500 / 2000 / 5000 / 10000 层链式 `nodes`，逐步跑 `draw` 记录首个崩溃深度；`ulimit -s` 与 SDK 默认栈大小一并记录 |

<!-- 第 35 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sortValues` 插入排序是点图（swarm/violin/violin-box/box-scatter）主耗时 | `SwarmChart.cj:218` 等 4 处 | 自耗时占比、输入规模 | `cjprof record` 跑 1k/10k 点随机输入，比对 `sortValues` self time |
| 2 | treemap 深链上 `nodeValue` 重复计算使布局呈 O(depth²) | `TreemapChart.cj:159-243` | depth=100/1k/10k 的分段耗时 | 加毫秒埋点跑三种深链，画 depth-耗时曲线 |
| 3 | 单点 SVG 体积约 150 B，点图输出是主要内存占用 | `ChartSvgKit.cj:123`、`SwarmChart.cj:170` | 每点字节数与峰值 RSS | 1k/10k 点时测 `toSvgString()` 长度与 `getAllocatedHeapSize()` 峰值 |
| 4 | `cells` 放大到 1e6 时华夫图渲染进入秒级并触发 GC 抖动 | `WaffleChart.cj:120-138` | 端到端耗时、GC 次数 | 固定 `cells` 梯度（1e3/1e4/1e5/1e6）跑 `cjpm bench -O2`，记录中位数与 GC 计数 |

<!-- 第 36 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 力导向布局的 `findWordNode` 线性扫描是词网络绘制的主要耗时 | `WordNetworkChart.cj:199-227`、`144-145` | 自耗时占比（相对 `sqrt`/浮点运算） | `cjprof record` 绘制 300 节点 / 1000 链接的词网络，看 `findWordNode` 与 `String.==` 的 self time |
| 2 | 插入排序在词云词数 > 1000 后成为瓶颈 | `WordCloudChart.cj:202-210` | n = 100/1000/5000 的单次耗时 | `cjpm bench -O2`，固定 6 字符词、随机权重，取中位数与离散度 |
| 3 | `TuiCanvas` 的 `TuiCell` 网格分配（含 `toArray` 副本）占单次绘制分配量的大头 | `TuiCanvas.cj:36-42` | 单次 `draw` 的分配字节数与 GC 次数 | 200×60 画布下 `getAllocatedHeapSize()` 前后差 + `cjprof heap`，跑 10 轮取中位数 |
| 4 | 高系列密度柱状图的覆盖写会退化成「一列」，实际业务中是否会遇到 | `TuiBarRenderer.cj:163-184` | 真实图表的系列/类目分布 | 统计 fprobe/下游实际提交的 chart JSON 中 `series.size` 与 `labels.size` 的分位数（P50/P99） |

<!-- 第 37 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 大节点量下 `parseNodes`/`findNode` 的 O(n²) 是绘制主耗时 | `f_chart/src/tui/TuiFlameChart.cj:117`、`:145` | 自耗时占比、n 的拐点 | `cjprof record` 跑 1k/10k/50k 节点三档，与总耗时对比；再看改 `HashMap` 后中位数 |
| 2 | 每帧 width×height 个 `TuiCell` 是主要分配源 | `f_chart/src/tui/TuiFlameChart.cj:73`（`TuiCanvas` 构造） | 每次 draw 的分配字节与 GC 次数 | `getAllocatedHeapSize()` 前后差值 × 绘制次数；`cjprof heap` 看 `TuiCell` 占比 |
| 3 | 深链（≥10^4）才会栈溢出，正常火焰数据不触发 | `f_chart/src/tui/TuiFlameChart.cj:172`、`:190`、`:200` | 实际崩溃深度、线程栈上限 | 构造 1k/5k/10k/20k 层链逐档跑 `draw`，记录首个崩溃档位；对照 SDK 线程默认栈大小文档 |
| 4 | 图例/轴标签的 `tuiDisplayWidth` 重复扫描在长标签下可测 | `f_chart/src/tui/TuiText.cj:43`、`:66`、`:82` | 单次 `draw` 内 `runes()` 遍历次数与耗时 | 分段计时 `tuiDisplayWidth` 累计耗时占比（标签 ≥ 64 列时） |

## 文件覆盖

> 与 `files/f_chart.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/README.md` | .md | ✅ | — |
| 2 | `f_chart/README_en.md` | .md | ✅ | — |
| 3 | `f_chart/doc/chart-json-spec.md` | .md | ✅ | — |
| 4 | `f_chart/doc/f_chart模块设计.md` | .md | ✅ | — |
| 5 | `f_chart/doc/spec/add-f-chart-alluvial/design.md` | .md | ✅ | — |
| 6 | `f_chart/doc/spec/add-f-chart-alluvial/proposal.md` | .md | ✅ | — |
| 7 | `f_chart/doc/spec/add-f-chart-alluvial/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 8 | `f_chart/doc/spec/add-f-chart-alluvial/tasks.md` | .md | ✅ | — |
| 9 | `f_chart/doc/spec/add-f-chart-arc/design.md` | .md | ✅ | — |
| 10 | `f_chart/doc/spec/add-f-chart-arc/proposal.md` | .md | ✅ | — |
| 11 | `f_chart/doc/spec/add-f-chart-arc/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 12 | `f_chart/doc/spec/add-f-chart-arc/tasks.md` | .md | ✅ | — |
| 13 | `f_chart/doc/spec/add-f-chart-area/design.md` | .md | ✅ | — |
| 14 | `f_chart/doc/spec/add-f-chart-area/proposal.md` | .md | ✅ | — |
| 15 | `f_chart/doc/spec/add-f-chart-area/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 16 | `f_chart/doc/spec/add-f-chart-area/tasks.md` | .md | ✅ | — |
| 17 | `f_chart/doc/spec/add-f-chart-bar/design.md` | .md | ✅ | — |
| 18 | `f_chart/doc/spec/add-f-chart-bar/proposal.md` | .md | ✅ | — |
| 19 | `f_chart/doc/spec/add-f-chart-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 20 | `f_chart/doc/spec/add-f-chart-bar/tasks.md` | .md | ✅ | — |
| 21 | `f_chart/doc/spec/add-f-chart-bland-altman/design.md` | .md | ✅ | — |
| 22 | `f_chart/doc/spec/add-f-chart-bland-altman/proposal.md` | .md | ✅ | — |
| 23 | `f_chart/doc/spec/add-f-chart-bland-altman/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 24 | `f_chart/doc/spec/add-f-chart-bland-altman/tasks.md` | .md | ✅ | — |
| 25 | `f_chart/doc/spec/add-f-chart-box-scatter/design.md` | .md | ✅ | — |
| 26 | `f_chart/doc/spec/add-f-chart-box-scatter/proposal.md` | .md | ✅ | — |
| 27 | `f_chart/doc/spec/add-f-chart-box-scatter/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 28 | `f_chart/doc/spec/add-f-chart-box-scatter/tasks.md` | .md | ✅ | — |
| 29 | `f_chart/doc/spec/add-f-chart-boxplot/design.md` | .md | ✅ | — |
| 30 | `f_chart/doc/spec/add-f-chart-boxplot/proposal.md` | .md | ✅ | — |
| 31 | `f_chart/doc/spec/add-f-chart-boxplot/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 32 | `f_chart/doc/spec/add-f-chart-boxplot/tasks.md` | .md | ✅ | — |
| 33 | `f_chart/doc/spec/add-f-chart-bubble/design.md` | .md | ✅ | — |
| 34 | `f_chart/doc/spec/add-f-chart-bubble/proposal.md` | .md | ✅ | — |
| 35 | `f_chart/doc/spec/add-f-chart-bubble/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 36 | `f_chart/doc/spec/add-f-chart-bubble/tasks.md` | .md | ✅ | — |
| 37 | `f_chart/doc/spec/add-f-chart-bullet/design.md` | .md | ✅ | — |
| 38 | `f_chart/doc/spec/add-f-chart-bullet/proposal.md` | .md | ✅ | — |
| 39 | `f_chart/doc/spec/add-f-chart-bullet/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 40 | `f_chart/doc/spec/add-f-chart-bullet/tasks.md` | .md | ✅ | — |
| 41 | `f_chart/doc/spec/add-f-chart-calendar-alias/design.md` | .md | ✅ | — |
| 42 | `f_chart/doc/spec/add-f-chart-calendar-alias/proposal.md` | .md | ✅ | — |
| 43 | `f_chart/doc/spec/add-f-chart-calendar-alias/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 44 | `f_chart/doc/spec/add-f-chart-calendar-alias/tasks.md` | .md | ✅ | — |
| 45 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/design.md` | .md | ✅ | — |
| 46 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/proposal.md` | .md | ✅ | — |
| 47 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 48 | `f_chart/doc/spec/add-f-chart-calendar-heatmap/tasks.md` | .md | ✅ | — |
| 49 | `f_chart/doc/spec/add-f-chart-calibration/design.md` | .md | ✅ | — |
| 50 | `f_chart/doc/spec/add-f-chart-calibration/proposal.md` | .md | ✅ | — |
| 51 | `f_chart/doc/spec/add-f-chart-calibration/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 52 | `f_chart/doc/spec/add-f-chart-calibration/tasks.md` | .md | ✅ | — |
| 53 | `f_chart/doc/spec/add-f-chart-candlestick/design.md` | .md | ✅ | — |
| 54 | `f_chart/doc/spec/add-f-chart-candlestick/proposal.md` | .md | ✅ | — |
| 55 | `f_chart/doc/spec/add-f-chart-candlestick/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 56 | `f_chart/doc/spec/add-f-chart-candlestick/tasks.md` | .md | ✅ | — |
| 57 | `f_chart/doc/spec/add-f-chart-cartogram/design.md` | .md | ✅ | — |
| 58 | `f_chart/doc/spec/add-f-chart-cartogram/proposal.md` | .md | ✅ | — |
| 59 | `f_chart/doc/spec/add-f-chart-cartogram/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 60 | `f_chart/doc/spec/add-f-chart-cartogram/tasks.md` | .md | ✅ | — |
| 61 | `f_chart/doc/spec/add-f-chart-chord/design.md` | .md | ✅ | — |
| 62 | `f_chart/doc/spec/add-f-chart-chord/proposal.md` | .md | ✅ | — |
| 63 | `f_chart/doc/spec/add-f-chart-chord/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 64 | `f_chart/doc/spec/add-f-chart-chord/tasks.md` | .md | ✅ | — |
| 65 | `f_chart/doc/spec/add-f-chart-choropleth/design.md` | .md | ✅ | — |
| 66 | `f_chart/doc/spec/add-f-chart-choropleth/proposal.md` | .md | ✅ | — |
| 67 | `f_chart/doc/spec/add-f-chart-choropleth/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 68 | `f_chart/doc/spec/add-f-chart-choropleth/tasks.md` | .md | ✅ | — |
| 69 | `f_chart/doc/spec/add-f-chart-circle-packing/design.md` | .md | ✅ | — |
| 70 | `f_chart/doc/spec/add-f-chart-circle-packing/proposal.md` | .md | ✅ | — |
| 71 | `f_chart/doc/spec/add-f-chart-circle-packing/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 72 | `f_chart/doc/spec/add-f-chart-circle-packing/tasks.md` | .md | ✅ | — |
| 73 | `f_chart/doc/spec/add-f-chart-combo/design.md` | .md | ✅ | — |
| 74 | `f_chart/doc/spec/add-f-chart-combo/proposal.md` | .md | ✅ | — |
| 75 | `f_chart/doc/spec/add-f-chart-combo/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 76 | `f_chart/doc/spec/add-f-chart-combo/tasks.md` | .md | ✅ | — |
| 77 | `f_chart/doc/spec/add-f-chart-confusion-matrix/design.md` | .md | ✅ | — |
| 78 | `f_chart/doc/spec/add-f-chart-confusion-matrix/proposal.md` | .md | ✅ | — |
| 79 | `f_chart/doc/spec/add-f-chart-confusion-matrix/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 80 | `f_chart/doc/spec/add-f-chart-confusion-matrix/tasks.md` | .md | ✅ | — |
| 81 | `f_chart/doc/spec/add-f-chart-contour/design.md` | .md | ✅ | — |
| 82 | `f_chart/doc/spec/add-f-chart-contour/proposal.md` | .md | ✅ | — |
| 83 | `f_chart/doc/spec/add-f-chart-contour/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 84 | `f_chart/doc/spec/add-f-chart-contour/tasks.md` | .md | ✅ | — |
| 85 | `f_chart/doc/spec/add-f-chart-control/design.md` | .md | ✅ | — |
| 86 | `f_chart/doc/spec/add-f-chart-control/proposal.md` | .md | ✅ | — |
| 87 | `f_chart/doc/spec/add-f-chart-control/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 88 | `f_chart/doc/spec/add-f-chart-control/tasks.md` | .md | ✅ | — |
| 89 | `f_chart/doc/spec/add-f-chart-correlation/design.md` | .md | ✅ | — |
| 90 | `f_chart/doc/spec/add-f-chart-correlation/proposal.md` | .md | ✅ | — |
| 91 | `f_chart/doc/spec/add-f-chart-correlation/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 92 | `f_chart/doc/spec/add-f-chart-correlation/tasks.md` | .md | ✅ | — |
| 93 | `f_chart/doc/spec/add-f-chart-decision-tree/design.md` | .md | ✅ | — |
| 94 | `f_chart/doc/spec/add-f-chart-decision-tree/proposal.md` | .md | ✅ | — |
| 95 | `f_chart/doc/spec/add-f-chart-decision-tree/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 96 | `f_chart/doc/spec/add-f-chart-decision-tree/tasks.md` | .md | ✅ | — |
| 97 | `f_chart/doc/spec/add-f-chart-density/design.md` | .md | ✅ | — |
| 98 | `f_chart/doc/spec/add-f-chart-density/proposal.md` | .md | ✅ | — |
| 99 | `f_chart/doc/spec/add-f-chart-density/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 100 | `f_chart/doc/spec/add-f-chart-density/tasks.md` | .md | ✅ | — |
| 101 | `f_chart/doc/spec/add-f-chart-differential-flame/design.md` | .md | ✅ | — |
| 102 | `f_chart/doc/spec/add-f-chart-differential-flame/proposal.md` | .md | ✅ | — |
| 103 | `f_chart/doc/spec/add-f-chart-differential-flame/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 104 | `f_chart/doc/spec/add-f-chart-differential-flame/tasks.md` | .md | ✅ | — |
| 105 | `f_chart/doc/spec/add-f-chart-donut/design.md` | .md | ✅ | — |
| 106 | `f_chart/doc/spec/add-f-chart-donut/proposal.md` | .md | ✅ | — |
| 107 | `f_chart/doc/spec/add-f-chart-donut/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 108 | `f_chart/doc/spec/add-f-chart-donut/tasks.md` | .md | ✅ | — |
| 109 | `f_chart/doc/spec/add-f-chart-dot-density-map/design.md` | .md | ✅ | — |
| 110 | `f_chart/doc/spec/add-f-chart-dot-density-map/proposal.md` | .md | ✅ | — |
| 111 | `f_chart/doc/spec/add-f-chart-dot-density-map/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 112 | `f_chart/doc/spec/add-f-chart-dot-density-map/tasks.md` | .md | ✅ | — |
| 113 | `f_chart/doc/spec/add-f-chart-dot-strip/design.md` | .md | ✅ | — |
| 114 | `f_chart/doc/spec/add-f-chart-dot-strip/proposal.md` | .md | ✅ | — |
| 115 | `f_chart/doc/spec/add-f-chart-dot-strip/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 116 | `f_chart/doc/spec/add-f-chart-dot-strip/tasks.md` | .md | ✅ | — |
| 117 | `f_chart/doc/spec/add-f-chart-dot/design.md` | .md | ✅ | — |
| 118 | `f_chart/doc/spec/add-f-chart-dot/proposal.md` | .md | ✅ | — |
| 119 | `f_chart/doc/spec/add-f-chart-dot/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 120 | `f_chart/doc/spec/add-f-chart-dot/tasks.md` | .md | ✅ | — |
| 121 | `f_chart/doc/spec/add-f-chart-dumbbell/design.md` | .md | ✅ | — |
| 122 | `f_chart/doc/spec/add-f-chart-dumbbell/proposal.md` | .md | ✅ | — |
| 123 | `f_chart/doc/spec/add-f-chart-dumbbell/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 124 | `f_chart/doc/spec/add-f-chart-dumbbell/tasks.md` | .md | ✅ | — |
| 125 | `f_chart/doc/spec/add-f-chart-ecdf/design.md` | .md | ✅ | — |
| 126 | `f_chart/doc/spec/add-f-chart-ecdf/proposal.md` | .md | ✅ | — |
| 127 | `f_chart/doc/spec/add-f-chart-ecdf/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 128 | `f_chart/doc/spec/add-f-chart-ecdf/tasks.md` | .md | ✅ | — |
| 129 | `f_chart/doc/spec/add-f-chart-error-bar/design.md` | .md | ✅ | — |
| 130 | `f_chart/doc/spec/add-f-chart-error-bar/proposal.md` | .md | ✅ | — |
| 131 | `f_chart/doc/spec/add-f-chart-error-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 132 | `f_chart/doc/spec/add-f-chart-error-bar/tasks.md` | .md | ✅ | — |
| 133 | `f_chart/doc/spec/add-f-chart-flame/design.md` | .md | ✅ | — |
| 134 | `f_chart/doc/spec/add-f-chart-flame/proposal.md` | .md | ✅ | — |
| 135 | `f_chart/doc/spec/add-f-chart-flame/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 136 | `f_chart/doc/spec/add-f-chart-flame/tasks.md` | .md | ✅ | — |
| 137 | `f_chart/doc/spec/add-f-chart-flow-map/design.md` | .md | ✅ | — |
| 138 | `f_chart/doc/spec/add-f-chart-flow-map/proposal.md` | .md | ✅ | — |
| 139 | `f_chart/doc/spec/add-f-chart-flow-map/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 140 | `f_chart/doc/spec/add-f-chart-flow-map/tasks.md` | .md | ✅ | — |
| 141 | `f_chart/doc/spec/add-f-chart-flowchart/design.md` | .md | ✅ | — |
| 142 | `f_chart/doc/spec/add-f-chart-flowchart/proposal.md` | .md | ✅ | — |
| 143 | `f_chart/doc/spec/add-f-chart-flowchart/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 144 | `f_chart/doc/spec/add-f-chart-flowchart/tasks.md` | .md | ✅ | — |
| 145 | `f_chart/doc/spec/add-f-chart-forest/design.md` | .md | ✅ | — |
| 146 | `f_chart/doc/spec/add-f-chart-forest/proposal.md` | .md | ✅ | — |
| 147 | `f_chart/doc/spec/add-f-chart-forest/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 148 | `f_chart/doc/spec/add-f-chart-forest/tasks.md` | .md | ✅ | — |
| 149 | `f_chart/doc/spec/add-f-chart-funnel-alias/design.md` | .md | ✅ | — |
| 150 | `f_chart/doc/spec/add-f-chart-funnel-alias/proposal.md` | .md | ✅ | — |
| 151 | `f_chart/doc/spec/add-f-chart-funnel-alias/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 152 | `f_chart/doc/spec/add-f-chart-funnel-alias/tasks.md` | .md | ✅ | — |
| 153 | `f_chart/doc/spec/add-f-chart-funnel/design.md` | .md | ✅ | — |
| 154 | `f_chart/doc/spec/add-f-chart-funnel/proposal.md` | .md | ✅ | — |
| 155 | `f_chart/doc/spec/add-f-chart-funnel/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 156 | `f_chart/doc/spec/add-f-chart-funnel/tasks.md` | .md | ✅ | — |
| 157 | `f_chart/doc/spec/add-f-chart-gain/design.md` | .md | ✅ | — |
| 158 | `f_chart/doc/spec/add-f-chart-gain/proposal.md` | .md | ✅ | — |
| 159 | `f_chart/doc/spec/add-f-chart-gain/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 160 | `f_chart/doc/spec/add-f-chart-gain/tasks.md` | .md | ✅ | — |
| 161 | `f_chart/doc/spec/add-f-chart-gantt/design.md` | .md | ✅ | — |
| 162 | `f_chart/doc/spec/add-f-chart-gantt/proposal.md` | .md | ✅ | — |
| 163 | `f_chart/doc/spec/add-f-chart-gantt/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 164 | `f_chart/doc/spec/add-f-chart-gantt/tasks.md` | .md | ✅ | — |
| 165 | `f_chart/doc/spec/add-f-chart-gauge/design.md` | .md | ✅ | — |
| 166 | `f_chart/doc/spec/add-f-chart-gauge/proposal.md` | .md | ✅ | — |
| 167 | `f_chart/doc/spec/add-f-chart-gauge/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 168 | `f_chart/doc/spec/add-f-chart-gauge/tasks.md` | .md | ✅ | — |
| 169 | `f_chart/doc/spec/add-f-chart-grouped-bar/design.md` | .md | ✅ | — |
| 170 | `f_chart/doc/spec/add-f-chart-grouped-bar/proposal.md` | .md | ✅ | — |
| 171 | `f_chart/doc/spec/add-f-chart-grouped-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 172 | `f_chart/doc/spec/add-f-chart-grouped-bar/tasks.md` | .md | ✅ | — |
| 173 | `f_chart/doc/spec/add-f-chart-heat-flame/design.md` | .md | ✅ | — |
| 174 | `f_chart/doc/spec/add-f-chart-heat-flame/proposal.md` | .md | ✅ | — |
| 175 | `f_chart/doc/spec/add-f-chart-heat-flame/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 176 | `f_chart/doc/spec/add-f-chart-heat-flame/tasks.md` | .md | ✅ | — |
| 177 | `f_chart/doc/spec/add-f-chart-heat-map/design.md` | .md | ✅ | — |
| 178 | `f_chart/doc/spec/add-f-chart-heat-map/proposal.md` | .md | ✅ | — |
| 179 | `f_chart/doc/spec/add-f-chart-heat-map/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 180 | `f_chart/doc/spec/add-f-chart-heat-map/tasks.md` | .md | ✅ | — |
| 181 | `f_chart/doc/spec/add-f-chart-heatmap/design.md` | .md | ✅ | — |
| 182 | `f_chart/doc/spec/add-f-chart-heatmap/proposal.md` | .md | ✅ | — |
| 183 | `f_chart/doc/spec/add-f-chart-heatmap/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 184 | `f_chart/doc/spec/add-f-chart-heatmap/tasks.md` | .md | ✅ | — |
| 185 | `f_chart/doc/spec/add-f-chart-histogram/design.md` | .md | ✅ | — |
| 186 | `f_chart/doc/spec/add-f-chart-histogram/proposal.md` | .md | ✅ | — |
| 187 | `f_chart/doc/spec/add-f-chart-histogram/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 188 | `f_chart/doc/spec/add-f-chart-histogram/tasks.md` | .md | ✅ | — |
| 189 | `f_chart/doc/spec/add-f-chart-histogram2d/design.md` | .md | ✅ | — |
| 190 | `f_chart/doc/spec/add-f-chart-histogram2d/proposal.md` | .md | ✅ | — |
| 191 | `f_chart/doc/spec/add-f-chart-histogram2d/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 192 | `f_chart/doc/spec/add-f-chart-histogram2d/tasks.md` | .md | ✅ | — |
| 193 | `f_chart/doc/spec/add-f-chart-hive/design.md` | .md | ✅ | — |
| 194 | `f_chart/doc/spec/add-f-chart-hive/proposal.md` | .md | ✅ | — |
| 195 | `f_chart/doc/spec/add-f-chart-hive/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 196 | `f_chart/doc/spec/add-f-chart-hive/tasks.md` | .md | ✅ | — |
| 197 | `f_chart/doc/spec/add-f-chart-horizontal-bar/design.md` | .md | ✅ | — |
| 198 | `f_chart/doc/spec/add-f-chart-horizontal-bar/proposal.md` | .md | ✅ | — |
| 199 | `f_chart/doc/spec/add-f-chart-horizontal-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 200 | `f_chart/doc/spec/add-f-chart-horizontal-bar/tasks.md` | .md | ✅ | — |
| 201 | `f_chart/doc/spec/add-f-chart-icicle/design.md` | .md | ✅ | — |
| 202 | `f_chart/doc/spec/add-f-chart-icicle/proposal.md` | .md | ✅ | — |
| 203 | `f_chart/doc/spec/add-f-chart-icicle/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 204 | `f_chart/doc/spec/add-f-chart-icicle/tasks.md` | .md | ✅ | — |
| 205 | `f_chart/doc/spec/add-f-chart-influence/design.md` | .md | ✅ | — |
| 206 | `f_chart/doc/spec/add-f-chart-influence/proposal.md` | .md | ✅ | — |
| 207 | `f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 208 | `f_chart/doc/spec/add-f-chart-influence/tasks.md` | .md | ✅ | — |
| 209 | `f_chart/doc/spec/add-f-chart-lasso-path/design.md` | .md | ✅ | — |
| 210 | `f_chart/doc/spec/add-f-chart-lasso-path/proposal.md` | .md | ✅ | — |
| 211 | `f_chart/doc/spec/add-f-chart-lasso-path/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 212 | `f_chart/doc/spec/add-f-chart-lasso-path/tasks.md` | .md | ✅ | — |
| 213 | `f_chart/doc/spec/add-f-chart-learning-curve/design.md` | .md | ✅ | — |
| 214 | `f_chart/doc/spec/add-f-chart-learning-curve/proposal.md` | .md | ✅ | — |
| 215 | `f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 216 | `f_chart/doc/spec/add-f-chart-learning-curve/tasks.md` | .md | ✅ | — |
| 217 | `f_chart/doc/spec/add-f-chart-lift/design.md` | .md | ✅ | — |
| 218 | `f_chart/doc/spec/add-f-chart-lift/proposal.md` | .md | ✅ | — |
| 219 | `f_chart/doc/spec/add-f-chart-lift/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 220 | `f_chart/doc/spec/add-f-chart-lift/tasks.md` | .md | ✅ | — |
| 221 | `f_chart/doc/spec/add-f-chart-line/design.md` | .md | ✅ | — |
| 222 | `f_chart/doc/spec/add-f-chart-line/proposal.md` | .md | ✅ | — |
| 223 | `f_chart/doc/spec/add-f-chart-line/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 224 | `f_chart/doc/spec/add-f-chart-line/tasks.md` | .md | ✅ | — |
| 225 | `f_chart/doc/spec/add-f-chart-lollipop/design.md` | .md | ✅ | — |
| 226 | `f_chart/doc/spec/add-f-chart-lollipop/proposal.md` | .md | ✅ | — |
| 227 | `f_chart/doc/spec/add-f-chart-lollipop/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 228 | `f_chart/doc/spec/add-f-chart-lollipop/tasks.md` | .md | ✅ | — |
| 229 | `f_chart/doc/spec/add-f-chart-manhattan/design.md` | .md | ✅ | — |
| 230 | `f_chart/doc/spec/add-f-chart-manhattan/proposal.md` | .md | ✅ | — |
| 231 | `f_chart/doc/spec/add-f-chart-manhattan/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 232 | `f_chart/doc/spec/add-f-chart-manhattan/tasks.md` | .md | ✅ | — |
| 233 | `f_chart/doc/spec/add-f-chart-module/design.md` | .md | ✅ | — |
| 234 | `f_chart/doc/spec/add-f-chart-module/proposal.md` | .md | ✅ | — |
| 235 | `f_chart/doc/spec/add-f-chart-module/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 236 | `f_chart/doc/spec/add-f-chart-module/tasks.md` | .md | ✅ | — |
| 237 | `f_chart/doc/spec/add-f-chart-mosaic/design.md` | .md | ✅ | — |
| 238 | `f_chart/doc/spec/add-f-chart-mosaic/proposal.md` | .md | ✅ | — |
| 239 | `f_chart/doc/spec/add-f-chart-mosaic/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 240 | `f_chart/doc/spec/add-f-chart-mosaic/tasks.md` | .md | ✅ | — |
| 241 | `f_chart/doc/spec/add-f-chart-network-heatmap/design.md` | .md | ✅ | — |
| 242 | `f_chart/doc/spec/add-f-chart-network-heatmap/proposal.md` | .md | ✅ | — |
| 243 | `f_chart/doc/spec/add-f-chart-network-heatmap/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 244 | `f_chart/doc/spec/add-f-chart-network-heatmap/tasks.md` | .md | ✅ | — |
| 245 | `f_chart/doc/spec/add-f-chart-node-link/design.md` | .md | ✅ | — |
| 246 | `f_chart/doc/spec/add-f-chart-node-link/proposal.md` | .md | ✅ | — |
| 247 | `f_chart/doc/spec/add-f-chart-node-link/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 248 | `f_chart/doc/spec/add-f-chart-node-link/tasks.md` | .md | ✅ | — |
| 249 | `f_chart/doc/spec/add-f-chart-nomogram/design.md` | .md | ✅ | — |
| 250 | `f_chart/doc/spec/add-f-chart-nomogram/proposal.md` | .md | ✅ | — |
| 251 | `f_chart/doc/spec/add-f-chart-nomogram/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 252 | `f_chart/doc/spec/add-f-chart-nomogram/tasks.md` | .md | ✅ | — |
| 253 | `f_chart/doc/spec/add-f-chart-offline-flame/design.md` | .md | ✅ | — |
| 254 | `f_chart/doc/spec/add-f-chart-offline-flame/proposal.md` | .md | ✅ | — |
| 255 | `f_chart/doc/spec/add-f-chart-offline-flame/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 256 | `f_chart/doc/spec/add-f-chart-offline-flame/tasks.md` | .md | ✅ | — |
| 257 | `f_chart/doc/spec/add-f-chart-org/design.md` | .md | ✅ | — |
| 258 | `f_chart/doc/spec/add-f-chart-org/proposal.md` | .md | ✅ | — |
| 259 | `f_chart/doc/spec/add-f-chart-org/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 260 | `f_chart/doc/spec/add-f-chart-org/tasks.md` | .md | ✅ | — |
| 261 | `f_chart/doc/spec/add-f-chart-paired-line/design.md` | .md | ✅ | — |
| 262 | `f_chart/doc/spec/add-f-chart-paired-line/proposal.md` | .md | ✅ | — |
| 263 | `f_chart/doc/spec/add-f-chart-paired-line/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 264 | `f_chart/doc/spec/add-f-chart-paired-line/tasks.md` | .md | ✅ | — |
| 265 | `f_chart/doc/spec/add-f-chart-parallel/design.md` | .md | ✅ | — |
| 266 | `f_chart/doc/spec/add-f-chart-parallel/proposal.md` | .md | ✅ | — |
| 267 | `f_chart/doc/spec/add-f-chart-parallel/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 268 | `f_chart/doc/spec/add-f-chart-parallel/tasks.md` | .md | ✅ | — |
| 269 | `f_chart/doc/spec/add-f-chart-pareto/design.md` | .md | ✅ | — |
| 270 | `f_chart/doc/spec/add-f-chart-pareto/proposal.md` | .md | ✅ | — |
| 271 | `f_chart/doc/spec/add-f-chart-pareto/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 272 | `f_chart/doc/spec/add-f-chart-pareto/tasks.md` | .md | ✅ | — |
| 273 | `f_chart/doc/spec/add-f-chart-pdp/design.md` | .md | ✅ | — |
| 274 | `f_chart/doc/spec/add-f-chart-pdp/proposal.md` | .md | ✅ | — |
| 275 | `f_chart/doc/spec/add-f-chart-pdp/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 276 | `f_chart/doc/spec/add-f-chart-pdp/tasks.md` | .md | ✅ | — |
| 277 | `f_chart/doc/spec/add-f-chart-percent-bar/design.md` | .md | ✅ | — |
| 278 | `f_chart/doc/spec/add-f-chart-percent-bar/proposal.md` | .md | ✅ | — |
| 279 | `f_chart/doc/spec/add-f-chart-percent-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 280 | `f_chart/doc/spec/add-f-chart-percent-bar/tasks.md` | .md | ✅ | — |
| 281 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/design.md` | .md | ✅ | — |
| 282 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/proposal.md` | .md | ✅ | — |
| 283 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 284 | `f_chart/doc/spec/add-f-chart-percent-stacked-bar/tasks.md` | .md | ✅ | — |
| 285 | `f_chart/doc/spec/add-f-chart-pictogram/design.md` | .md | ✅ | — |
| 286 | `f_chart/doc/spec/add-f-chart-pictogram/proposal.md` | .md | ✅ | — |
| 287 | `f_chart/doc/spec/add-f-chart-pictogram/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 288 | `f_chart/doc/spec/add-f-chart-pictogram/tasks.md` | .md | ✅ | — |
| 289 | `f_chart/doc/spec/add-f-chart-pie/design.md` | .md | ✅ | — |
| 290 | `f_chart/doc/spec/add-f-chart-pie/proposal.md` | .md | ✅ | — |
| 291 | `f_chart/doc/spec/add-f-chart-pie/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 292 | `f_chart/doc/spec/add-f-chart-pie/tasks.md` | .md | ✅ | — |
| 293 | `f_chart/doc/spec/add-f-chart-pr/design.md` | .md | ✅ | — |
| 294 | `f_chart/doc/spec/add-f-chart-pr/proposal.md` | .md | ✅ | — |
| 295 | `f_chart/doc/spec/add-f-chart-pr/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 296 | `f_chart/doc/spec/add-f-chart-pr/tasks.md` | .md | ✅ | — |
| 297 | `f_chart/doc/spec/add-f-chart-probability/design.md` | .md | ✅ | — |
| 298 | `f_chart/doc/spec/add-f-chart-probability/proposal.md` | .md | ✅ | — |
| 299 | `f_chart/doc/spec/add-f-chart-probability/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 300 | `f_chart/doc/spec/add-f-chart-probability/tasks.md` | .md | ✅ | — |
| 301 | `f_chart/doc/spec/add-f-chart-qq/design.md` | .md | ✅ | — |
| 302 | `f_chart/doc/spec/add-f-chart-qq/proposal.md` | .md | ✅ | — |
| 303 | `f_chart/doc/spec/add-f-chart-qq/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 304 | `f_chart/doc/spec/add-f-chart-qq/tasks.md` | .md | ✅ | — |
| 305 | `f_chart/doc/spec/add-f-chart-radar/design.md` | .md | ✅ | — |
| 306 | `f_chart/doc/spec/add-f-chart-radar/proposal.md` | .md | ✅ | — |
| 307 | `f_chart/doc/spec/add-f-chart-radar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 308 | `f_chart/doc/spec/add-f-chart-radar/tasks.md` | .md | ✅ | — |
| 309 | `f_chart/doc/spec/add-f-chart-raincloud/design.md` | .md | ✅ | — |
| 310 | `f_chart/doc/spec/add-f-chart-raincloud/proposal.md` | .md | ✅ | — |
| 311 | `f_chart/doc/spec/add-f-chart-raincloud/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 312 | `f_chart/doc/spec/add-f-chart-raincloud/tasks.md` | .md | ✅ | — |
| 313 | `f_chart/doc/spec/add-f-chart-residual/design.md` | .md | ✅ | — |
| 314 | `f_chart/doc/spec/add-f-chart-residual/proposal.md` | .md | ✅ | — |
| 315 | `f_chart/doc/spec/add-f-chart-residual/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 316 | `f_chart/doc/spec/add-f-chart-residual/tasks.md` | .md | ✅ | — |
| 317 | `f_chart/doc/spec/add-f-chart-ridge/design.md` | .md | ✅ | — |
| 318 | `f_chart/doc/spec/add-f-chart-ridge/proposal.md` | .md | ✅ | — |
| 319 | `f_chart/doc/spec/add-f-chart-ridge/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 320 | `f_chart/doc/spec/add-f-chart-ridge/tasks.md` | .md | ✅ | — |
| 321 | `f_chart/doc/spec/add-f-chart-roc/design.md` | .md | ✅ | — |
| 322 | `f_chart/doc/spec/add-f-chart-roc/proposal.md` | .md | ✅ | — |
| 323 | `f_chart/doc/spec/add-f-chart-roc/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 324 | `f_chart/doc/spec/add-f-chart-roc/tasks.md` | .md | ✅ | — |
| 325 | `f_chart/doc/spec/add-f-chart-rose/design.md` | .md | ✅ | — |
| 326 | `f_chart/doc/spec/add-f-chart-rose/proposal.md` | .md | ✅ | — |
| 327 | `f_chart/doc/spec/add-f-chart-rose/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 328 | `f_chart/doc/spec/add-f-chart-rose/tasks.md` | .md | ✅ | — |
| 329 | `f_chart/doc/spec/add-f-chart-sankey-alias/design.md` | .md | ✅ | — |
| 330 | `f_chart/doc/spec/add-f-chart-sankey-alias/proposal.md` | .md | ✅ | — |
| 331 | `f_chart/doc/spec/add-f-chart-sankey-alias/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 332 | `f_chart/doc/spec/add-f-chart-sankey-alias/tasks.md` | .md | ✅ | — |
| 333 | `f_chart/doc/spec/add-f-chart-sankey/design.md` | .md | ✅ | — |
| 334 | `f_chart/doc/spec/add-f-chart-sankey/proposal.md` | .md | ✅ | — |
| 335 | `f_chart/doc/spec/add-f-chart-sankey/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 336 | `f_chart/doc/spec/add-f-chart-sankey/tasks.md` | .md | ✅ | — |
| 337 | `f_chart/doc/spec/add-f-chart-scatter-matrix/design.md` | .md | ✅ | — |
| 338 | `f_chart/doc/spec/add-f-chart-scatter-matrix/proposal.md` | .md | ✅ | — |
| 339 | `f_chart/doc/spec/add-f-chart-scatter-matrix/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 340 | `f_chart/doc/spec/add-f-chart-scatter-matrix/tasks.md` | .md | ✅ | — |
| 341 | `f_chart/doc/spec/add-f-chart-scatter/design.md` | .md | ✅ | — |
| 342 | `f_chart/doc/spec/add-f-chart-scatter/proposal.md` | .md | ✅ | — |
| 343 | `f_chart/doc/spec/add-f-chart-scatter/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 344 | `f_chart/doc/spec/add-f-chart-scatter/tasks.md` | .md | ✅ | — |
| 345 | `f_chart/doc/spec/add-f-chart-sequence/design.md` | .md | ✅ | — |
| 346 | `f_chart/doc/spec/add-f-chart-sequence/proposal.md` | .md | ✅ | — |
| 347 | `f_chart/doc/spec/add-f-chart-sequence/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 348 | `f_chart/doc/spec/add-f-chart-sequence/tasks.md` | .md | ✅ | — |
| 349 | `f_chart/doc/spec/add-f-chart-shap/design.md` | .md | ✅ | — |
| 350 | `f_chart/doc/spec/add-f-chart-shap/proposal.md` | .md | ✅ | — |
| 351 | `f_chart/doc/spec/add-f-chart-shap/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 352 | `f_chart/doc/spec/add-f-chart-shap/tasks.md` | .md | ✅ | — |
| 353 | `f_chart/doc/spec/add-f-chart-slope/design.md` | .md | ✅ | — |
| 354 | `f_chart/doc/spec/add-f-chart-slope/proposal.md` | .md | ✅ | — |
| 355 | `f_chart/doc/spec/add-f-chart-slope/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 356 | `f_chart/doc/spec/add-f-chart-slope/tasks.md` | .md | ✅ | — |
| 357 | `f_chart/doc/spec/add-f-chart-spiral/design.md` | .md | ✅ | — |
| 358 | `f_chart/doc/spec/add-f-chart-spiral/proposal.md` | .md | ✅ | — |
| 359 | `f_chart/doc/spec/add-f-chart-spiral/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 360 | `f_chart/doc/spec/add-f-chart-spiral/tasks.md` | .md | ✅ | — |
| 361 | `f_chart/doc/spec/add-f-chart-stacked-area/design.md` | .md | ✅ | — |
| 362 | `f_chart/doc/spec/add-f-chart-stacked-area/proposal.md` | .md | ✅ | — |
| 363 | `f_chart/doc/spec/add-f-chart-stacked-area/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 364 | `f_chart/doc/spec/add-f-chart-stacked-area/tasks.md` | .md | ✅ | — |
| 365 | `f_chart/doc/spec/add-f-chart-stacked-bar/design.md` | .md | ✅ | — |
| 366 | `f_chart/doc/spec/add-f-chart-stacked-bar/proposal.md` | .md | ✅ | — |
| 367 | `f_chart/doc/spec/add-f-chart-stacked-bar/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 368 | `f_chart/doc/spec/add-f-chart-stacked-bar/tasks.md` | .md | ✅ | — |
| 369 | `f_chart/doc/spec/add-f-chart-stem-leaf/design.md` | .md | ✅ | — |
| 370 | `f_chart/doc/spec/add-f-chart-stem-leaf/proposal.md` | .md | ✅ | — |
| 371 | `f_chart/doc/spec/add-f-chart-stem-leaf/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 372 | `f_chart/doc/spec/add-f-chart-stem-leaf/tasks.md` | .md | ✅ | — |
| 373 | `f_chart/doc/spec/add-f-chart-streamgraph/design.md` | .md | ✅ | — |
| 374 | `f_chart/doc/spec/add-f-chart-streamgraph/proposal.md` | .md | ✅ | — |
| 375 | `f_chart/doc/spec/add-f-chart-streamgraph/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 376 | `f_chart/doc/spec/add-f-chart-streamgraph/tasks.md` | .md | ✅ | — |
| 377 | `f_chart/doc/spec/add-f-chart-sunburst/design.md` | .md | ✅ | — |
| 378 | `f_chart/doc/spec/add-f-chart-sunburst/proposal.md` | .md | ✅ | — |
| 379 | `f_chart/doc/spec/add-f-chart-sunburst/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 380 | `f_chart/doc/spec/add-f-chart-sunburst/tasks.md` | .md | ✅ | — |
| 381 | `f_chart/doc/spec/add-f-chart-survival/design.md` | .md | ✅ | — |
| 382 | `f_chart/doc/spec/add-f-chart-survival/proposal.md` | .md | ✅ | — |
| 383 | `f_chart/doc/spec/add-f-chart-survival/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 384 | `f_chart/doc/spec/add-f-chart-survival/tasks.md` | .md | ✅ | — |
| 385 | `f_chart/doc/spec/add-f-chart-swarm/design.md` | .md | ✅ | — |
| 386 | `f_chart/doc/spec/add-f-chart-swarm/proposal.md` | .md | ✅ | — |
| 387 | `f_chart/doc/spec/add-f-chart-swarm/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 388 | `f_chart/doc/spec/add-f-chart-swarm/tasks.md` | .md | ✅ | — |
| 389 | `f_chart/doc/spec/add-f-chart-swimlane/design.md` | .md | ✅ | — |
| 390 | `f_chart/doc/spec/add-f-chart-swimlane/proposal.md` | .md | ✅ | — |
| 391 | `f_chart/doc/spec/add-f-chart-swimlane/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 392 | `f_chart/doc/spec/add-f-chart-swimlane/tasks.md` | .md | ✅ | — |
| 393 | `f_chart/doc/spec/add-f-chart-tag-cloud/design.md` | .md | ✅ | — |
| 394 | `f_chart/doc/spec/add-f-chart-tag-cloud/proposal.md` | .md | ✅ | — |
| 395 | `f_chart/doc/spec/add-f-chart-tag-cloud/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 396 | `f_chart/doc/spec/add-f-chart-tag-cloud/tasks.md` | .md | ✅ | — |
| 397 | `f_chart/doc/spec/add-f-chart-timeline/design.md` | .md | ✅ | — |
| 398 | `f_chart/doc/spec/add-f-chart-timeline/proposal.md` | .md | ✅ | — |
| 399 | `f_chart/doc/spec/add-f-chart-timeline/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 400 | `f_chart/doc/spec/add-f-chart-timeline/tasks.md` | .md | ✅ | — |
| 401 | `f_chart/doc/spec/add-f-chart-treemap/design.md` | .md | ✅ | — |
| 402 | `f_chart/doc/spec/add-f-chart-treemap/proposal.md` | .md | ✅ | — |
| 403 | `f_chart/doc/spec/add-f-chart-treemap/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 404 | `f_chart/doc/spec/add-f-chart-treemap/tasks.md` | .md | ✅ | — |
| 405 | `f_chart/doc/spec/add-f-chart-tui-flame/design.md` | .md | ✅ | — |
| 406 | `f_chart/doc/spec/add-f-chart-tui-flame/proposal.md` | .md | ✅ | — |
| 407 | `f_chart/doc/spec/add-f-chart-tui-flame/specs/chart-tui-flame/spec.md` | .md | ✅ | — |
| 408 | `f_chart/doc/spec/add-f-chart-tui-flame/tasks.md` | .md | ✅ | — |
| 409 | `f_chart/doc/spec/add-f-chart-tui/design.md` | .md | ✅ | — |
| 410 | `f_chart/doc/spec/add-f-chart-tui/proposal.md` | .md | ✅ | — |
| 411 | `f_chart/doc/spec/add-f-chart-tui/specs/chart-tui/spec.md` | .md | ✅ | — |
| 412 | `f_chart/doc/spec/add-f-chart-tui/tasks.md` | .md | ✅ | — |
| 413 | `f_chart/doc/spec/add-f-chart-violin-box/design.md` | .md | ✅ | — |
| 414 | `f_chart/doc/spec/add-f-chart-violin-box/proposal.md` | .md | ✅ | — |
| 415 | `f_chart/doc/spec/add-f-chart-violin-box/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 416 | `f_chart/doc/spec/add-f-chart-violin-box/tasks.md` | .md | ✅ | — |
| 417 | `f_chart/doc/spec/add-f-chart-violin/design.md` | .md | ✅ | — |
| 418 | `f_chart/doc/spec/add-f-chart-violin/proposal.md` | .md | ✅ | — |
| 419 | `f_chart/doc/spec/add-f-chart-violin/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 420 | `f_chart/doc/spec/add-f-chart-violin/tasks.md` | .md | ✅ | — |
| 421 | `f_chart/doc/spec/add-f-chart-volcano/design.md` | .md | ✅ | — |
| 422 | `f_chart/doc/spec/add-f-chart-volcano/proposal.md` | .md | ✅ | — |
| 423 | `f_chart/doc/spec/add-f-chart-volcano/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 424 | `f_chart/doc/spec/add-f-chart-volcano/tasks.md` | .md | ✅ | — |
| 425 | `f_chart/doc/spec/add-f-chart-waffle/design.md` | .md | ✅ | — |
| 426 | `f_chart/doc/spec/add-f-chart-waffle/proposal.md` | .md | ✅ | — |
| 427 | `f_chart/doc/spec/add-f-chart-waffle/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 428 | `f_chart/doc/spec/add-f-chart-waffle/tasks.md` | .md | ✅ | — |
| 429 | `f_chart/doc/spec/add-f-chart-waterfall-alias/design.md` | .md | ✅ | — |
| 430 | `f_chart/doc/spec/add-f-chart-waterfall-alias/proposal.md` | .md | ✅ | — |
| 431 | `f_chart/doc/spec/add-f-chart-waterfall-alias/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 432 | `f_chart/doc/spec/add-f-chart-waterfall-alias/tasks.md` | .md | ✅ | — |
| 433 | `f_chart/doc/spec/add-f-chart-waterfall/design.md` | .md | ✅ | — |
| 434 | `f_chart/doc/spec/add-f-chart-waterfall/proposal.md` | .md | ✅ | — |
| 435 | `f_chart/doc/spec/add-f-chart-waterfall/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 436 | `f_chart/doc/spec/add-f-chart-waterfall/tasks.md` | .md | ✅ | — |
| 437 | `f_chart/doc/spec/add-f-chart-word-cloud/design.md` | .md | ✅ | — |
| 438 | `f_chart/doc/spec/add-f-chart-word-cloud/proposal.md` | .md | ✅ | — |
| 439 | `f_chart/doc/spec/add-f-chart-word-cloud/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 440 | `f_chart/doc/spec/add-f-chart-word-cloud/tasks.md` | .md | ✅ | — |
| 441 | `f_chart/doc/spec/add-f-chart-word-network/design.md` | .md | ✅ | — |
| 442 | `f_chart/doc/spec/add-f-chart-word-network/proposal.md` | .md | ✅ | — |
| 443 | `f_chart/doc/spec/add-f-chart-word-network/specs/chart-rendering/spec.md` | .md | ✅ | — |
| 444 | `f_chart/doc/spec/add-f-chart-word-network/tasks.md` | .md | ✅ | — |
| 445 | `f_chart/src/AlluvialChart.cj` | .cj | ✅ | — |
| 446 | `f_chart/src/AlluvialChart_test.cj` | .cj | ✅ | — |
| 447 | `f_chart/src/ArcChart.cj` | .cj | ✅ | — |
| 448 | `f_chart/src/ArcChart_test.cj` | .cj | ✅ | — |
| 449 | `f_chart/src/AreaChart.cj` | .cj | ✅ | — |
| 450 | `f_chart/src/AreaChart_test.cj` | .cj | ✅ | — |
| 451 | `f_chart/src/BarChart.cj` | .cj | ✅ | — |
| 452 | `f_chart/src/BarChart_test.cj` | .cj | ✅ | — |
| 453 | `f_chart/src/BarRenderer.cj` | .cj | ✅ | — |
| 454 | `f_chart/src/BlandAltmanChart.cj` | .cj | ✅ | — |
| 455 | `f_chart/src/BlandAltmanChart_test.cj` | .cj | ✅ | — |
| 456 | `f_chart/src/BoxPlotChart.cj` | .cj | ✅ | — |
| 457 | `f_chart/src/BoxPlotChart_test.cj` | .cj | ✅ | — |
| 458 | `f_chart/src/BoxScatterChart.cj` | .cj | ✅ | — |
| 459 | `f_chart/src/BoxScatterChart_test.cj` | .cj | ✅ | — |
| 460 | `f_chart/src/BubbleChart.cj` | .cj | ✅ | — |
| 461 | `f_chart/src/BubbleChart_test.cj` | .cj | ✅ | — |
| 462 | `f_chart/src/BulletChart.cj` | .cj | ✅ | — |
| 463 | `f_chart/src/BulletChart_test.cj` | .cj | ✅ | — |
| 464 | `f_chart/src/CalendarHeatmapAlias_test.cj` | .cj | ✅ | — |
| 465 | `f_chart/src/CalendarHeatmapChart.cj` | .cj | ✅ | — |
| 466 | `f_chart/src/CalendarHeatmapChart_test.cj` | .cj | ✅ | — |
| 467 | `f_chart/src/CalibrationChart.cj` | .cj | ✅ | — |
| 468 | `f_chart/src/CalibrationChart_test.cj` | .cj | ✅ | — |
| 469 | `f_chart/src/CandlestickChart.cj` | .cj | ✅ | — |
| 470 | `f_chart/src/CandlestickChart_test.cj` | .cj | ✅ | — |
| 471 | `f_chart/src/CartogramChart.cj` | .cj | ✅ | — |
| 472 | `f_chart/src/CartogramChart_test.cj` | .cj | ✅ | — |
| 473 | `f_chart/src/Chart.cj` | .cj | ✅ | — |
| 474 | `f_chart/src/ChartConfig.cj` | .cj | ✅ | — |
| 475 | `f_chart/src/ChartException.cj` | .cj | ✅ | — |
| 476 | `f_chart/src/ChartException_test.cj` | .cj | ✅ | — |
| 477 | `f_chart/src/ChartFrame.cj` | .cj | ✅ | — |
| 478 | `f_chart/src/ChartGallery_test.cj` | .cj | ✅ | — |
| 479 | `f_chart/src/ChartJson.cj` | .cj | ✅ | — |
| 480 | `f_chart/src/ChartScale.cj` | .cj | ✅ | — |
| 481 | `f_chart/src/ChartSvgKit.cj` | .cj | ✅ | — |
| 482 | `f_chart/src/ChartTheme.cj` | .cj | ✅ | — |
| 483 | `f_chart/src/ChartTime.cj` | .cj | ✅ | — |
| 484 | `f_chart/src/Chart_test.cj` | .cj | ✅ | — |
| 485 | `f_chart/src/ChordChart.cj` | .cj | ✅ | — |
| 486 | `f_chart/src/ChordChart_test.cj` | .cj | ✅ | — |
| 487 | `f_chart/src/ChoroplethChart.cj` | .cj | ✅ | — |
| 488 | `f_chart/src/ChoroplethChart_test.cj` | .cj | ✅ | — |
| 489 | `f_chart/src/CirclePackingChart.cj` | .cj | ✅ | — |
| 490 | `f_chart/src/CirclePackingChart_test.cj` | .cj | ✅ | — |
| 491 | `f_chart/src/ComboChart.cj` | .cj | ✅ | — |
| 492 | `f_chart/src/ComboChart_test.cj` | .cj | ✅ | — |
| 493 | `f_chart/src/ConfusionMatrixChart.cj` | .cj | ✅ | — |
| 494 | `f_chart/src/ConfusionMatrixChart_test.cj` | .cj | ✅ | — |
| 495 | `f_chart/src/ContourChart.cj` | .cj | ✅ | — |
| 496 | `f_chart/src/ContourChart_test.cj` | .cj | ✅ | — |
| 497 | `f_chart/src/ControlChart.cj` | .cj | ✅ | — |
| 498 | `f_chart/src/ControlChart_test.cj` | .cj | ✅ | — |
| 499 | `f_chart/src/CorrelationMatrixChart.cj` | .cj | ✅ | — |
| 500 | `f_chart/src/CorrelationMatrixChart_test.cj` | .cj | ✅ | — |
| 501 | `f_chart/src/DecisionTreeChart.cj` | .cj | ✅ | — |
| 502 | `f_chart/src/DecisionTreeChart_test.cj` | .cj | ✅ | — |
| 503 | `f_chart/src/DensityChart.cj` | .cj | ✅ | — |
| 504 | `f_chart/src/DensityChart_test.cj` | .cj | ✅ | — |
| 505 | `f_chart/src/DifferentialFlameChart.cj` | .cj | ✅ | — |
| 506 | `f_chart/src/DifferentialFlameChart_test.cj` | .cj | ✅ | — |
| 507 | `f_chart/src/DonutChart.cj` | .cj | ✅ | — |
| 508 | `f_chart/src/DonutChart_test.cj` | .cj | ✅ | — |
| 509 | `f_chart/src/DotChart.cj` | .cj | ✅ | — |
| 510 | `f_chart/src/DotChart_test.cj` | .cj | ✅ | — |
| 511 | `f_chart/src/DotDensityMapChart.cj` | .cj | ✅ | — |
| 512 | `f_chart/src/DotDensityMapChart_test.cj` | .cj | ✅ | — |
| 513 | `f_chart/src/DotStripChart.cj` | .cj | ✅ | — |
| 514 | `f_chart/src/DotStripChart_test.cj` | .cj | ✅ | — |
| 515 | `f_chart/src/DumbbellChart.cj` | .cj | ✅ | — |
| 516 | `f_chart/src/DumbbellChart_test.cj` | .cj | ✅ | — |
| 517 | `f_chart/src/EcdfChart.cj` | .cj | ✅ | — |
| 518 | `f_chart/src/EcdfChart_test.cj` | .cj | ✅ | — |
| 519 | `f_chart/src/ErrorBarChart.cj` | .cj | ✅ | — |
| 520 | `f_chart/src/ErrorBarChart_test.cj` | .cj | ✅ | — |
| 521 | `f_chart/src/FlameChart.cj` | .cj | ✅ | — |
| 522 | `f_chart/src/FlameChart_test.cj` | .cj | ✅ | — |
| 523 | `f_chart/src/FlowMapChart.cj` | .cj | ✅ | — |
| 524 | `f_chart/src/FlowMapChart_test.cj` | .cj | ✅ | — |
| 525 | `f_chart/src/Flowchart.cj` | .cj | ✅ | — |
| 526 | `f_chart/src/Flowchart_test.cj` | .cj | ✅ | — |
| 527 | `f_chart/src/ForestChart.cj` | .cj | ✅ | — |
| 528 | `f_chart/src/ForestChart_test.cj` | .cj | ✅ | — |
| 529 | `f_chart/src/FunnelAlias_test.cj` | .cj | ✅ | — |
| 530 | `f_chart/src/FunnelChart.cj` | .cj | ✅ | — |
| 531 | `f_chart/src/FunnelChart_test.cj` | .cj | ✅ | — |
| 532 | `f_chart/src/GainChart.cj` | .cj | ✅ | — |
| 533 | `f_chart/src/GainChart_test.cj` | .cj | ✅ | — |
| 534 | `f_chart/src/GanttChart.cj` | .cj | ✅ | — |
| 535 | `f_chart/src/GanttChart_test.cj` | .cj | ✅ | — |
| 536 | `f_chart/src/GaugeChart.cj` | .cj | ✅ | — |
| 537 | `f_chart/src/GaugeChart_test.cj` | .cj | ✅ | — |
| 538 | `f_chart/src/GroupedBarChart.cj` | .cj | ✅ | — |
| 539 | `f_chart/src/GroupedBarChart_test.cj` | .cj | ✅ | — |
| 540 | `f_chart/src/HeatFlameChart.cj` | .cj | ✅ | — |
| 541 | `f_chart/src/HeatFlameChart_test.cj` | .cj | ✅ | — |
| 542 | `f_chart/src/HeatMap.cj` | .cj | ✅ | — |
| 543 | `f_chart/src/HeatMap_test.cj` | .cj | ✅ | — |
| 544 | `f_chart/src/HeatmapChart.cj` | .cj | ✅ | — |
| 545 | `f_chart/src/HeatmapChart_test.cj` | .cj | ✅ | — |
| 546 | `f_chart/src/Histogram2DChart.cj` | .cj | ✅ | — |
| 547 | `f_chart/src/Histogram2DChart_test.cj` | .cj | ✅ | — |
| 548 | `f_chart/src/HistogramChart.cj` | .cj | ✅ | — |
| 549 | `f_chart/src/HistogramChart_test.cj` | .cj | ✅ | — |
| 550 | `f_chart/src/HiveChart.cj` | .cj | ✅ | — |
| 551 | `f_chart/src/HiveChart_test.cj` | .cj | ✅ | — |
| 552 | `f_chart/src/HorizontalBarChart.cj` | .cj | ✅ | — |
| 553 | `f_chart/src/HorizontalBarChart_test.cj` | .cj | ✅ | — |
| 554 | `f_chart/src/IcicleChart.cj` | .cj | ✅ | — |
| 555 | `f_chart/src/IcicleChart_test.cj` | .cj | ✅ | — |
| 556 | `f_chart/src/InfluenceChart.cj` | .cj | ✅ | — |
| 557 | `f_chart/src/InfluenceChart_test.cj` | .cj | ✅ | — |
| 558 | `f_chart/src/LassoPathChart.cj` | .cj | ✅ | — |
| 559 | `f_chart/src/LassoPathChart_test.cj` | .cj | ✅ | — |
| 560 | `f_chart/src/LearningCurveChart.cj` | .cj | ✅ | — |
| 561 | `f_chart/src/LearningCurveChart_test.cj` | .cj | ✅ | — |
| 562 | `f_chart/src/LiftChart.cj` | .cj | ✅ | — |
| 563 | `f_chart/src/LiftChart_test.cj` | .cj | ✅ | — |
| 564 | `f_chart/src/LineChart.cj` | .cj | ✅ | — |
| 565 | `f_chart/src/LineChart_test.cj` | .cj | ✅ | — |
| 566 | `f_chart/src/LollipopChart.cj` | .cj | ✅ | — |
| 567 | `f_chart/src/LollipopChart_test.cj` | .cj | ✅ | — |
| 568 | `f_chart/src/ManhattanChart.cj` | .cj | ✅ | — |
| 569 | `f_chart/src/ManhattanChart_test.cj` | .cj | ✅ | — |
| 570 | `f_chart/src/MosaicChart.cj` | .cj | ✅ | — |
| 571 | `f_chart/src/MosaicChart_test.cj` | .cj | ✅ | — |
| 572 | `f_chart/src/NetworkHeatmapChart.cj` | .cj | ✅ | — |
| 573 | `f_chart/src/NetworkHeatmapChart_test.cj` | .cj | ✅ | — |
| 574 | `f_chart/src/NodeLinkChart.cj` | .cj | ✅ | — |
| 575 | `f_chart/src/NodeLinkChart_test.cj` | .cj | ✅ | — |
| 576 | `f_chart/src/NomogramChart.cj` | .cj | ✅ | — |
| 577 | `f_chart/src/NomogramChart_test.cj` | .cj | ✅ | — |
| 578 | `f_chart/src/OfflineFlameChart.cj` | .cj | ✅ | — |
| 579 | `f_chart/src/OfflineFlameChart_test.cj` | .cj | ✅ | — |
| 580 | `f_chart/src/OrgChart.cj` | .cj | ✅ | — |
| 581 | `f_chart/src/OrgChart_test.cj` | .cj | ✅ | — |
| 582 | `f_chart/src/PairedLineChart.cj` | .cj | ✅ | — |
| 583 | `f_chart/src/PairedLineChart_test.cj` | .cj | ✅ | — |
| 584 | `f_chart/src/ParallelCoordinatesChart.cj` | .cj | ✅ | — |
| 585 | `f_chart/src/ParallelCoordinatesChart_test.cj` | .cj | ✅ | — |
| 586 | `f_chart/src/ParetoChart.cj` | .cj | ✅ | — |
| 587 | `f_chart/src/ParetoChart_test.cj` | .cj | ✅ | — |
| 588 | `f_chart/src/PdpChart.cj` | .cj | ✅ | — |
| 589 | `f_chart/src/PdpChart_test.cj` | .cj | ✅ | — |
| 590 | `f_chart/src/PercentBarChart.cj` | .cj | ✅ | — |
| 591 | `f_chart/src/PercentBarChart_test.cj` | .cj | ✅ | — |
| 592 | `f_chart/src/PercentStackedBarChart.cj` | .cj | ✅ | — |
| 593 | `f_chart/src/PercentStackedBarChart_test.cj` | .cj | ✅ | — |
| 594 | `f_chart/src/PictogramChart.cj` | .cj | ✅ | — |
| 595 | `f_chart/src/PictogramChart_test.cj` | .cj | ✅ | — |
| 596 | `f_chart/src/PieChart.cj` | .cj | ✅ | — |
| 597 | `f_chart/src/PieChart_test.cj` | .cj | ✅ | — |
| 598 | `f_chart/src/PrChart.cj` | .cj | ✅ | — |
| 599 | `f_chart/src/PrChart_test.cj` | .cj | ✅ | — |
| 600 | `f_chart/src/ProbabilityChart.cj` | .cj | ✅ | — |
| 601 | `f_chart/src/ProbabilityChart_test.cj` | .cj | ✅ | — |
| 602 | `f_chart/src/QQChart.cj` | .cj | ✅ | — |
| 603 | `f_chart/src/QQChart_test.cj` | .cj | ✅ | — |
| 604 | `f_chart/src/RadarChart.cj` | .cj | ✅ | — |
| 605 | `f_chart/src/RadarChart_test.cj` | .cj | ✅ | — |
| 606 | `f_chart/src/RaincloudChart.cj` | .cj | ✅ | — |
| 607 | `f_chart/src/RaincloudChart_test.cj` | .cj | ✅ | — |
| 608 | `f_chart/src/ResidualChart.cj` | .cj | ✅ | — |
| 609 | `f_chart/src/ResidualChart_test.cj` | .cj | ✅ | — |
| 610 | `f_chart/src/RidgeChart.cj` | .cj | ✅ | — |
| 611 | `f_chart/src/RidgeChart_test.cj` | .cj | ✅ | — |
| 612 | `f_chart/src/RocChart.cj` | .cj | ✅ | — |
| 613 | `f_chart/src/RocChart_test.cj` | .cj | ✅ | — |
| 614 | `f_chart/src/RoseChart.cj` | .cj | ✅ | — |
| 615 | `f_chart/src/RoseChart_test.cj` | .cj | ✅ | — |
| 616 | `f_chart/src/SankeyAlias_test.cj` | .cj | ✅ | — |
| 617 | `f_chart/src/SankeyChart.cj` | .cj | ✅ | — |
| 618 | `f_chart/src/SankeyChart_test.cj` | .cj | ✅ | — |
| 619 | `f_chart/src/ScatterChart.cj` | .cj | ✅ | — |
| 620 | `f_chart/src/ScatterChart_test.cj` | .cj | ✅ | — |
| 621 | `f_chart/src/ScatterMatrixChart.cj` | .cj | ✅ | — |
| 622 | `f_chart/src/ScatterMatrixChart_test.cj` | .cj | ✅ | — |
| 623 | `f_chart/src/SequenceChart.cj` | .cj | ✅ | — |
| 624 | `f_chart/src/SequenceChart_test.cj` | .cj | ✅ | — |
| 625 | `f_chart/src/ShapChart.cj` | .cj | ✅ | — |
| 626 | `f_chart/src/ShapChart_test.cj` | .cj | ✅ | — |
| 627 | `f_chart/src/SlopeChart.cj` | .cj | ✅ | — |
| 628 | `f_chart/src/SlopeChart_test.cj` | .cj | ✅ | — |
| 629 | `f_chart/src/SpiralChart.cj` | .cj | ✅ | — |
| 630 | `f_chart/src/SpiralChart_test.cj` | .cj | ✅ | — |
| 631 | `f_chart/src/StackedAreaChart.cj` | .cj | ✅ | — |
| 632 | `f_chart/src/StackedAreaChart_test.cj` | .cj | ✅ | — |
| 633 | `f_chart/src/StackedBarChart.cj` | .cj | ✅ | — |
| 634 | `f_chart/src/StackedBarChart_test.cj` | .cj | ✅ | — |
| 635 | `f_chart/src/StemLeafChart.cj` | .cj | ✅ | — |
| 636 | `f_chart/src/StemLeafChart_test.cj` | .cj | ✅ | — |
| 637 | `f_chart/src/StreamgraphChart.cj` | .cj | ✅ | — |
| 638 | `f_chart/src/StreamgraphChart_test.cj` | .cj | ✅ | — |
| 639 | `f_chart/src/SunburstChart.cj` | .cj | ✅ | — |
| 640 | `f_chart/src/SunburstChart_test.cj` | .cj | ✅ | — |
| 641 | `f_chart/src/SurvivalChart.cj` | .cj | ✅ | — |
| 642 | `f_chart/src/SurvivalChart_test.cj` | .cj | ✅ | — |
| 643 | `f_chart/src/SwarmChart.cj` | .cj | ✅ | — |
| 644 | `f_chart/src/SwarmChart_test.cj` | .cj | ✅ | — |
| 645 | `f_chart/src/SwimlaneChart.cj` | .cj | ✅ | — |
| 646 | `f_chart/src/SwimlaneChart_test.cj` | .cj | ✅ | — |
| 647 | `f_chart/src/TagCloud_test.cj` | .cj | ✅ | — |
| 648 | `f_chart/src/TimelineChart.cj` | .cj | ✅ | — |
| 649 | `f_chart/src/TimelineChart_test.cj` | .cj | ✅ | — |
| 650 | `f_chart/src/TreemapChart.cj` | .cj | ✅ | — |
| 651 | `f_chart/src/TreemapChart_test.cj` | .cj | ✅ | — |
| 652 | `f_chart/src/ViolinBoxChart.cj` | .cj | ✅ | — |
| 653 | `f_chart/src/ViolinBoxChart_test.cj` | .cj | ✅ | — |
| 654 | `f_chart/src/ViolinChart.cj` | .cj | ✅ | — |
| 655 | `f_chart/src/ViolinChart_test.cj` | .cj | ✅ | — |
| 656 | `f_chart/src/VolcanoChart.cj` | .cj | ✅ | — |
| 657 | `f_chart/src/VolcanoChart_test.cj` | .cj | ✅ | — |
| 658 | `f_chart/src/WaffleChart.cj` | .cj | ✅ | — |
| 659 | `f_chart/src/WaffleChart_test.cj` | .cj | ✅ | — |
| 660 | `f_chart/src/WaterfallAlias_test.cj` | .cj | ✅ | — |
| 661 | `f_chart/src/WaterfallChart.cj` | .cj | ✅ | — |
| 662 | `f_chart/src/WaterfallChart_test.cj` | .cj | ✅ | — |
| 663 | `f_chart/src/WordCloudChart.cj` | .cj | ✅ | — |
| 664 | `f_chart/src/WordCloudChart_test.cj` | .cj | ✅ | — |
| 665 | `f_chart/src/WordNetworkChart.cj` | .cj | ✅ | — |
| 666 | `f_chart/src/WordNetworkChart_test.cj` | .cj | ✅ | — |
| 667 | `f_chart/src/tui/BarChart.cj` | .cj | ✅ | — |
| 668 | `f_chart/src/tui/ComboChart.cj` | .cj | ✅ | — |
| 669 | `f_chart/src/tui/GroupedBarChart.cj` | .cj | ✅ | — |
| 670 | `f_chart/src/tui/LineChart.cj` | .cj | ✅ | — |
| 671 | `f_chart/src/tui/PercentStackedBarChart.cj` | .cj | ✅ | — |
| 672 | `f_chart/src/tui/ScatterChart.cj` | .cj | ✅ | — |
| 673 | `f_chart/src/tui/StackedBarChart.cj` | .cj | ✅ | — |
| 674 | `f_chart/src/tui/TuiBarChart_test.cj` | .cj | ✅ | — |
| 675 | `f_chart/src/tui/TuiBarRenderer.cj` | .cj | ✅ | — |
| 676 | `f_chart/src/tui/TuiCanvas.cj` | .cj | ✅ | — |
| 677 | `f_chart/src/tui/TuiCanvas_test.cj` | .cj | ✅ | — |
| 678 | `f_chart/src/tui/TuiCellChart.cj` | .cj | ✅ | — |
| 679 | `f_chart/src/tui/TuiCellChart_test.cj` | .cj | ✅ | — |
| 680 | `f_chart/src/tui/TuiChartCommon.cj` | .cj | ✅ | — |
| 681 | `f_chart/src/tui/TuiColor.cj` | .cj | ✅ | — |
| 682 | `f_chart/src/tui/TuiComboChart_test.cj` | .cj | ✅ | — |
| 683 | `f_chart/src/tui/TuiConfig_test.cj` | .cj | ✅ | — |
| 684 | `f_chart/src/tui/TuiFlameChart.cj` | .cj | ✅ | — |
| 685 | `f_chart/src/tui/TuiFlameChart_test.cj` | .cj | ✅ | — |
| 686 | `f_chart/src/tui/TuiFrame.cj` | .cj | ✅ | — |
| 687 | `f_chart/src/tui/TuiFrame_test.cj` | .cj | ✅ | — |
| 688 | `f_chart/src/tui/TuiGallery_test.cj` | .cj | ✅ | — |
| 689 | `f_chart/src/tui/TuiGroupedBarChart_test.cj` | .cj | ✅ | — |
| 690 | `f_chart/src/tui/TuiLineChart_test.cj` | .cj | ✅ | — |
| 691 | `f_chart/src/tui/TuiPercentStackedBarChart_test.cj` | .cj | ✅ | — |
| 692 | `f_chart/src/tui/TuiPointCommon.cj` | .cj | ✅ | — |
| 693 | `f_chart/src/tui/TuiScatterChart_test.cj` | .cj | ✅ | — |
| 694 | `f_chart/src/tui/TuiStackedBarChart_test.cj` | .cj | ✅ | — |
| 695 | `f_chart/src/tui/TuiText.cj` | .cj | ✅ | — |

合计：`.cj` 251 个 / `.md` 444 个 / 共 695 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：错误语义漏 `JsonException`（#6）、示例标签被丢弃（#5）、两个幻影字段（#3/#4）；设计：附录与状态表对 combo 口径不一致（#1）；可读性：「Other public API」残段（#12）；安全性：示例无凭据、无注入面，无相关表述 |
| §1 死代码 | 0 | 文档无源码可判。对文档承诺的符号做了机械核对：102 个实现路径全部存在、181 个 JSON 键全部能在 `src` 找到对应字面量、110 个 JSON 块全部可解析。`ChartErrorKind.InvalidJson` 库内永不产生（记入 #6），但属对外可达 public 枚举值，按硬原则一不判死代码 |
| §2 重复逻辑 | 0 | 文档必然逐图展开，不构成代码重复；只对 4 组"同语义不同写法"的描述两两比对（M45/M46/M88/M89），差异是数据形态而非文案，已记 #5，不按重复计数 |
| §3 空实现 | 0 | 文档无空段落；「Other public API」是内容缺失（#12），不是空实现承诺 |
| §4 栈溢出 | 0 | 纯文档；treemap/circle-packing 的 "recursive layout" 是算法描述，不诱导无界递归 |
| §5 OOM | 0 | 文档未承诺容量上限，示例规模为个位到几十条，无"整文件读入"类建议 |
| §6.1 热点瓶颈 | 0 | 本部分无代码、无 profile/bench 数据，不产生热点结论 |
| §6.2 大粒度锁 | 0 | 文档不涉及锁 |
| §6.3 并发串行 | 0 | 文档未提线程模型；`Chart` 的纯函数语义只在 `Chart.cj:20-26` 注释里，README 未展开，但无相反承诺 |
| §6.4 低效算法 | 0 | 抽查 8 条算法描述（直方图 `floor(sqrt(n))` 分箱、华夫图 100 格/10 列、Silverman 带宽、控制图 ±3σ、螺旋 3 圈/-90°、流图 wiggle/zero/symmetry、柱宽 60%、面积 0.3）均与实现一致，无相反表述 |
| §7 降堆内存方案 | 0 | 本部分无 `.cj`，无可测对象 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档未涉及 local mode，无收益可测 |
| §11 现有代码的 BUG（存量） | 0 | 本部分范围只有 `.md`；代码仅作取证。核对中撞见的代码侧问题（`TuiFrame` 越界报成 `width`、`BoxScatterChart` 缺标签校验、`ChartScale` 刻度越界）记入「范围外提示」，不占统计 |
| §12 并发安全与锁粒度 | 0 | 文档未声明线程安全/可并发；实现无静态可变状态，未见与文档冲突的并发表述 |
| §14 功能完备性与 README 覆盖 | 5 | #1（combo area）、#2（`series[].label`）、#3（gantt `lane`）、#4（shap `features`）、#7（10 个配置项）；正向核对：102 个实现文件 ↔ 102 条附录条目一一对应，107 个样例与状态表 M1–M106+M93b 吻合，107 个 SVG 均带 `xmlns`，两处 `doc/` 链接有效 |
| 文件覆盖（§13 等） | 1/1 | 清单 1 个文件已读完；§13 命中 13（本部分全部发现都落在文档一致性维度，逐条给了两边行号） |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无控制流与外部输入，代码层正确性/语言特性不适用。正确性：契约与实现不符（#1 / #2 / #9 / #16）；设计：`padding` 同键二义（#8）。可读性未发现结构问题（11 节 + 索引 + 逐图小节可用）；安全性未发现凭据、注入面或危险示例 |
| §1 死代码 | 0 | 本部分无 `.cj`，不判代码死代码。做的是反向「文档声明是否有实现引用」核查：`annotations`、`series[].label`、`series[].opacity`、`histogram.normalize`、`pie.innerRadius`、`sankey.iterations`、`pareto.cumulativeFormat`、`symbol=triangle`、`shap.features`、`gantt.lane` 共 10 项在 `src/` 无读取点，按「承诺未实现」记入 §14（#1 #2 #5 #6 #7 #12 #13）。文档侧的悬空文件引用 `ChartSpec.cj`（`f_chart模块设计.md:39`）经 `ls` + `grep` 确认不存在，计入 §13 发现 #15，不重复统计 |
| §2 重复逻辑 | 3 | 把「同一字段/默认值在多处出现」的 14 组（`padding`、`areaStyle.opacity`、`bins`、`innerRadius`、`startAngle`、`nodeWidth`、`nodeGap`、`colorRange`、`showValues`、`title.fontSize`、`legend.position` 等）两两比对：命中 3 组漂移——`areaStyle.opacity` 规范 0.2 / 归档 0.3 / 代码 0.3·0.6（#3）、`flows` 端点键正文 `from/to` 与示例 `source/target`（#10）、类型→文件→形状映射表在 `chart-json-spec.md:135-243` 与 `f_chart模块设计.md:140-245` 各维护一份并已漂移（#11 / #15）；其余口径一致。5 套 change 目录的 proposal/spec/design/tasks 同模板复制属 OpenSpec 格式要求，按误报边界不报 |
| §3 空实现 | 0 | 本部分无函数体。`annotations` 在实现层等价于"收下不处理"，但属"字段未接线"而非空函数，按 §14.1 记在 #1，避免两类重复统计 |
| §4 栈溢出 | 0 | 文档未声明递归算法或深度上限，没有可判的承诺；层级图深度由 `nodes` 链决定这一面只能到实现取证，已列入待验证假设 #1 |
| §5 OOM | 1 | #18：`cells` / `turns` / `tickCount` / `bins` 无上限、无拒绝路径文档；放大路径在代码侧（`WaffleChart.cj:41-49`），已标范围外提示 |
| §6.1 热点瓶颈 | 0 | scope 未提供 f_chart 的 `cjprof` / `cjpm bench` 数据，本部分也无代码可定位，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 文档不涉及锁；`Chart` 契约声明纯函数 |
| §6.3 并发串行 | 0 | 不适用（无任务提交与等待） |
| §6.4 低效算法 | 0 | 文档级复杂度承诺只有直方图 `sqrt(n)` 分箱（与代码一致，见 #2 的默认值问题，非复杂度问题）与桑基固定遍数；未发现"文档声明 O(n) 实际 O(n²)"的相反表述 |
| §7 降堆内存方案 | 0 | 无 `.cj`、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数；图表返回值必然逃逸（整份 SVG 字符串），不满足逃逸检查前提 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无 `.cj`。核对时撞见的代码层唯一冲突（`CirclePackingChart.cj:55` 与 `ChartConfig.cj:187` 共用根级 `padding` 键）已按文档字段二义记入 §13 发现 #8，不重复计入；另核对过 `min >= max` 在 `BarRenderer.cj:414`、`LineChart.cj:474` 均有 `InvalidValue`（规范 `:2714` 成立），空数据兜底 `[0,1]` 成立（`BarRenderer.cj:372-375`） |
| §12 并发安全与锁粒度 | 0 | 规范与 `Chart` 接口（`src/Chart.cj:22-27`）声明"纯函数、不依赖全局可变状态、确定性输出"；机械核对：`grep "^var \|static var" src/*.cj` 零命中，无顶层可变状态，声明与实现一致 |
| §14 功能完备性与 README 覆盖 | 8 | #1（`annotations` / `series.label` / `series.opacity`）、#2（`normalize`）、#5（`pie.innerRadius`）、#6（`sankey.iterations`）、#7（`pareto.cumulativeFormat`）、#9（`treemap.tiling=slice`）、#13（`shap.features` / `gantt.lane`）、#14（`donut` / `network-heatmap` 四字段未登记）。反向核对：§4 索引的 105 个唯一 `type` 全部能在 `src/` 找到对应解析；列出的实现文件逐个 `test -f` 全部存在；主题 10 色、`legend` 五项默认、轴 `tickCount=5` / `logBase=10` / `labelFormat={value}` / `grid` 默认与 `ChartTheme.cj`、`ChartConfig.cj:59-108` 一致。README 覆盖度属第 1、2 部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；5 套归档变更按「当时结论是否自洽」核对，未发现自相矛盾（其与当前实现的差异不计为文档缺陷） |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 命中 #1（负数被拒，正确性/契约）。安全性无外部输入注入面：所有数据经 `ChartJson` 类型校验，SVG 由 `f_svg` 构造器转义；设计上 spec→实现一一对应，无分层问题（纯函数库） |
| §1 死代码 | 0 | 本部分无 `.cj`；对本部分文档所指的 6 个实现文件逐个核对了 `internal` 符号引用：`blandAltmanStats` / `boxScatterBounds` / `bubbleRadius` / `bulletNumber` / `bulletRangeColor` 均被生产代码调用（非仅测试），`BlandAltmanPair` / `BoxScatterGroup` / `BulletItem` / `BubblePoint` / `BubbleSeries` 均在 `draw` 中使用；未发现 `return` 后同层语句或未使用 `import`（`std.math.*` 各文件都用到 `minFloat`/`maxFloat`/`abs`/`sqrt`）。死代码的完整判定留给包含 `src/**` 的子轮 |
| §2 重复逻辑 | 3 | #2（数值字段读取 4 处实现 + 1 处跨图复用）、#3（插入排序 8 份）、#4（轴范围 3 套）。已两两比对这 6 个实现文件的 `draw` 主体摘要：Bland-Altman / BoxPlot / BoxScatter / Bubble / Bullet 的「读取 series → 校验 → 求范围 → 取色 → 建 frame → 画图」骨架相似但字段与图形不同，不构成同语义实现 |
| §3 空实现 | 0 | 逐文件检查：无 `TODO` / `FIXME` / `UnsupportedException`；`BoxPlotChart.cj:124` 的 `case None => ()` 是可选字段 `outliers` 缺失的正常分支，`BubbleChart.cj:106` 同理（`sizeRange` 可选），均非吞异常 |
| §4 栈溢出 | 0 | 6 个实现文件无递归；`quantileSorted`、`swarmOffsets`、`sortValues`、`blandAltmanStats` 均为单层循环，深度不随输入增长 |
| §5 OOM | 0 | 无全局容器、无缓存、无 `Array(n, repeat:)` 预分配；所有容器规模 = 输入规模。Bland-Altman 的 3 份副本是常数倍（3n 个 `Float64`），已归入「优化可行性方案 · 堆内存」，不构成 OOM 面 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`scope.md` 的「已有性能资料」只有 `docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md`，不含本模块 profile。热点结论全部降级为「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 6 个实现文件无锁、无 `synchronized`、无原子类型；`draw` 全部是局部状态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池调用 |
| §6.4 低效算法 | 1 | #3 的插入排序（`O(n²)`，复杂度静态确定）；是否成热点缺数据，收益归「待验证假设」#1，不单列缺陷 |
| §7 降堆内存方案 | 1 | 「Bland-Altman 三份副本」，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 「8 份插入排序合并为 `O(n log n)`」，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 未评估为方案：`draw` 返回 `String`（必然逃逸），中间对象（`ArrayList`、`SvgBuilder` 缓冲）在函数内创建但被 builder 持有到末尾；缺少峰值内存基线，且 `f_chart` 目前未启用 `--enable-local-mode`，收益无法证明，故只写结论不列方案 |
| §11 现有代码的 BUG（存量） | 5 | #1（负数被拒）、#5（色阶取模）、#6（标签溢出）、#7（越界不裁剪）、#11（旋转标签留白）。已核对这 6 个实现文件的边界与空值：空 `data`、单元素组、全相等值、`span = 0`（Bland-Altman `87-94`、BoxScatter `229-230`）、`max <= min` 均有显式处理，未发现除上述之外的差一或除零 |
| §12 并发安全与锁粒度 | 0 | `Chart` 契约声明「纯函数语义」（`Chart.cj:24-26`），6 个实现类只有 `let` 字段（`init` 后不可变）与 `draw` 内局部变量，无静态可变状态、无单例、无回调注册；并发调用互不共享可变数据，线程封闭成立 |
| §13 文档一致性（.md） | 7 | #5、#8、#9、#10、#12、#13、#14（另 #1、#6、#7 兼具规格漂移性质）。已逐条把 proposal/design/spec delta 的字段名、默认值、class 名、计数场景与实现对齐；`tasks.md` 只核对产物文件是否存在，测试是否真跑过记 `待确认` |
| §14 功能完备性与 README 覆盖 | 1 | 5 个图类型（`bland-altman` / `box-scatter` / `boxplot` / `bubble` / `bullet`）都在 `ChartConfig.parse(data, "<type>")` 处校验类型且类已实现，`Chart` 由调用方直接实例化（模块无注册表），不存在「注册了没人用」；命中 #14（proposal 声称的 `bulletRange` 未实现），其余 proposal 列出的 class 名逐个在实现中命中；M106 复用 M44 与 `doc/chart-json-spec.md:243` 一致 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4（归属见下，不重复计数） | 正确性：#1（轴方向）、#3（日期语义）、#4（区间规模）；设计：#10（同一契约两份文本）。语言特性 / 可读性 / 安全性未命中：本部分无代码，无值-引用语义与注入面可核；六份文档结构（Why → What Changes → Capabilities → Impact）一致 |
| §1 死代码 | 0 | 本部分无 `.cj`。文档点名的内部符号逐个搜定义，全部存在且被生产代码引用：`ChartTime.partsOfDays`（`ChartTime.cj:48`）、`calendarWeekday` / `calendarColor`（`CalendarHeatmapChart.cj:239`、`253`）、`candlestickUp`（`CandlestickChart.cj:196`）、`cartogramScale`（`CartogramChart.cj:173`）、`chordArcPath` / `chordWidth`（`ChordChart.cj:215`、`233`）。唯一不存在的 `candlestickRange` 按 §13 记入 #6（文档指向不存在符号，不是源码死代码） |
| §2 重复逻辑 | 1 | #10（alias spec 复述 heatmap spec 的颜色分档 / 类型不匹配，且已漂移）。另逐一比对了 `ChartTime.parseDays` 在各图的复用方式：属共享工具复用，不是复制实现，不判 |
| §3 空实现 | 0 | 无函数体可查。最接近的是 `binCount` 只校验不生效，按「承诺未实现 / 读了不用」归入 #2（§14），避免同一根因两处计数 |
| §4 栈溢出 | 0 | 文档描述的渲染路径全是迭代（日历图 `for (offset in 0..dayCount)`、和弦图 `for (node in nodes)` / `for (link in links)`、变形地图 `for (region in regions)`），无递归、无自引用结构；`daysFromCivil` / `civilFromDays` 为常数深度整数运算 |
| §5 OOM | 1 | #4（日历图按天物化、区间无上限）。其余四图的规模都受输入项数约束（`data` / `regions` / `nodes` / `links` 长度）且先做非空校验，未发现与数据量脱钩的放大面 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，任何热点结论不成立；四个候选写进「待验证假设」#1–#4，不进统计 |
| §6.2 大粒度锁 | 0 | 本部分无代码；被审文档对应的 `draw` 全为单次调用的纯计算，无锁、无临界区可评 |
| §6.3 并发串行 | 0 | 无 `spawn`、无任务提交；文档也未承诺并行渲染 |
| §6.4 低效算法 | 0 | 读到三处复杂度可判的写法（日历图 O(U²)/O(D·U)、和弦图 O(L·N)、校准图插入排序 O(n²)），复杂度静态可判但缺耗时占比，按 §6.1 要求降级为「待验证假设」#1/#3/#4，不单列缺陷 |
| §7 降堆内存方案 | 0 | 无代码、无基线；#4 属缺陷（上限缺失），不是「还能更省」，已在「发现」计数 |
| §8 降 CPU 方案 | 0 | 同上；相关实现属其他子轮文件，无基线不出方案 |
| §9 local mode 可行性 | 0 | 本部分无函数可改造；日历图逐日临时对象、和弦图角度分配虽短生命周期，但无逃逸分析与峰值内存对照，只能留待有数据的轮次 |
| §11 现有代码的 BUG（存量） | 1 | #1（校准曲线轴方向反转，判据「契约与实现不符」）。#3 的根因在 `ChartTime`，按「spec 承诺 vs 实现」归到 §13 统计，不重复计入 |
| §12 并发安全与锁粒度 | 0 | 被审文档对应的 `draw` 状态全在局部（`ChordNode.total` / `angle`、`CartogramRegion` 均为 `draw` 内新建），无共享可变状态；文档也未声明线程安全契约 |
| §13 文档一致性 | 5 | #3（`date` 语义）、#5（18px 上限）、#6（`candlestickRange` 不存在）、#7（正奇数 vs 正整数）、#11（负价约束）。反向核对通过的项：日历图 `row/week` 公式与 `calendarWeekday` mon=3 / sun=4、`calendarColor` 端点；校准图 `[min(0,min),max(1,max)]`、2px/3.5px/`#9e9e9e` 虚线；蜡烛图 5% 留白、`close >= open`、`#e53935`/`#43a047`；变形地图 `sqrt(100/400)=0.5`、transform 三段式、默认三色；和弦图 `padAngle/2`、14px、`chordWidth`、16px |
| §14 功能完备性与 README 覆盖 | 3 | #2（README 承诺分箱、实现未分箱）、#8（变形地图静默丢弃第 4 色起）、#9（日历图校验清单少于实现）。六份 tasks 的勾选项在代码/文档里都能找到产物；README 的 M44 / M106 条目（`README.md:111`、`174`、`2819-2824`）与 `M1–M106` 收尾声明（`176`）已核对 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`files/f_chart.part5.txt` 20 行与本表逐行对应 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | #2（左右柱重叠，坐标）、#3（堆叠取色变量用错）、#4（图例与图形配色不一致）。设计维度：六份 design/proposal 与实现的职责划分一致，`Chart` 纯函数契约未被破坏（无静态可变状态）；语言特性：`?Float64`/`match`、`Array<Array<Float64>>`、`Float64` 装箱使用得当，未见值/引用语义误用；安全性：本部分无外部输入注入面（输入是结构化 JSON，无 SQL/命令/路径拼接），无凭据；可读性：`ComboChart` 的 `labelCount()`、`drawBarGroups` 的 `right` 形参见 #10 |
| §1 死代码 | 1 | #10：`drawBarGroups` 的 `right` 形参在函数体内零引用（`ComboChart.cj:504-512` vs `:513-581`）；`labelCount()` 只 `return labels.size`，属无意义间接层。其余逐个检查：`ChordNode`/`ChordLink`/`ChordNode.total..midAngle`、`chordArcPath`/`chordWidth`（测试 `ChordChart_test.cj:99-109` 引用，属「仅测试使用的 internal」= 可见性建议，不判死代码）、`CirclePackingNode` 全部字段（`total/x/y/radius` 均在布局与绘制中被读）、`circlePackingRadius`（同文件 + 测试）、`ChoroplethRegion` 六字段（全部被读）、`pathCentroid`（同文件 + 测试）、`confusionNormalize`/`confusionText`（同文件 + 测试）、`ContourPoint`、`contourLevel`（同文件 + 测试）、`ComboKind`/`ComboSeries`/`ComboBarGroup` 的每个字段均被读；`ComboSeries.symbolSize`/`smooth`/`symbol` 在散点/折线绘制中被读。不可达语句：6 个 `draw` 的 `return`/`throw` 后无同层语句；未使用的 `import` 未发现（`std.math.*`、`formatSvgNumber`、`SvgColor` 均有引用）。对外可达 public（6 个 `public class` 与 `public init`/`draw`）不判 |
| §2 重复逻辑 | 1 | #8：`findNode` 14 份同构实现（含同模块 `tui/TuiFlameChart.cj:144`）、「id 唯一」循环 ≥19 处，差异只在元素类型、错误名词与返回约定（-1 / `None`）。同文件内其余函数已两两比对：`ChordChart` 的 2 个解析循环（节点/链接）字段不同、不构成重复；`ComboChart` 的 `parseValues` 与 `parseScatterPoints` 输入形状不同（`number｜null` vs `{x,y}`）；`ContourChart` 的 `resolveLevels`/`resolveRange`/`uniqueSorted`/`indexOf` 语义互不重叠；`CirclePackingChart` 的 `resolveTotals`/`sortChildren`/`layoutChildren` 都是「递归 + 守卫」，但分别做求和/排序/定位，合并只会增加分支 |
| §3 空实现 | 1 | #12：`indexOf` 未命中返回 0 的兜底；另有 `ChoroplethChart.cj:194-198` 的 `catch (_: Exception) { () }`（并入 #9 取证）。6 个 `draw` 均无空分支、无 `TODO`/`FIXME`、无 `UnsupportedException` 占位（`ComboChart.cj:270-275` 的 `UnsupportedChart` 是契约要求的未知类型拒绝） |
| §4 栈溢出 | 1 | #1：`CirclePackingChart` 四条递归链，深度 = 树深 = 输入节点链长，无常量上限。其余 5 个图逐函数确认无自递归/间接递归（`ChordChart`、`ChoroplethChart`、`ComboChart`、`ConfusionMatrixChart`、`ContourChart` 全为循环） |
| §5 OOM | 0 | 逐个核对分配点：`ContourChart.cj:87-90` 的 `xs.size * ys.size` 预分配发生在 `points.size == xs.size * ys.size` 校验（`:84`）之后，规模受输入自身约束，不存在「按报文字段放大预分配」；`ComboChart`/`ConfusionMatrix`/`Chord` 都只按输入元素数建集合，无全局缓存、无只增不减容器、无「循环内 `result = result + part`」；`draw` 返回单个 SVG 串，`StringBuilder`/`Append` 增长与输出规模同阶。`CirclePackingChart` 的递归每层只持有已有节点对象，不产生随深度倍增的临时对象。故未成立 OOM 缺陷（规模上限缺失本身已在 #1 讨论） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，六份文档也没有性能承诺；不成立「发现」，相关线索（和弦 `findNode`、`combo` 重复建组、等高线去重）全部降级到「待验证假设」1–5 |
| §6.2 大粒度锁 | 0 | 6 个实现文件内无 `synchronized`、无 `Mutex`、无锁内 I/O（`grep -n "synchronized\|Mutex\|spawn"` 零命中）；`draw` 每次调用只操作局部对象 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池使用，不存在「提交后立即 get」或并发度=1 的配置 |
| §6.4 低效算法 | 1 | #13：`uniqueSorted` 去重 + 插入排序 O(P²)（复杂度静态确定，占比待测）；#8 里的 O(n²) 去重与 O(m·n) 查找归入 §2 统计，不重复计数。`CirclePackingChart:174-184` 的插入排序、`ComboChart` 的 4 次建组作为同源线索列入待验证假设 2/4 |
| §7 降堆内存方案 | 0 | 缺陷侧 0 条；方案侧 1 条（`confusionNormalize` 对 `none` 也整表复制），因无基线只进「优化可行性方案」，不计缺陷 |
| §8 降 CPU 方案 | 0 | 缺陷侧 0 条；方案侧 2 条（id 索引化、`combo` 建组复用），同样无基线 |
| §9 local mode 可行性 | 0 | 6 个 `draw` 的临时对象（节点表、矩阵、网格、SVG 串）都随返回值或成员结构逃逸到函数外（`SvgBuilder` 持有输出、`ArrayList` 被返回/存储），不满足 `@ local!` 的逃逸约束；且无峰值内存基线，不写改造建议 |
| §11 现有代码的 BUG（存量） | 3 | #9（`pathCentroid` 解析弧标志/指数 + 空 `catch`）、#11（零流量节点退化弧）、#15（`cellSize` 下限导致网格溢出）。另核对了：`ChordChart` 的 `padAngle` 累计（`cursor` 每节点消耗 `span + padAngle`，末节点回到起点，无累积漂移）、`chordWidth` 的 `ratio` 已被 `maxValue` 保证 ≤1、`confusionText` 的两位小数四舍五入（`round(value*100)`，`:233-237`）、`contourLevel` 的上下钳制、`ComboChart` 的 `validateLengths` 长度校验与 `parseScatterPoints` 的越界校验，均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态可列：6 个类只有 `public init()`、没有实例字段（`ChordChart`/`ChoroplethChart`/`ComboChart`/`ConfusionMatrixChart`/`ContourChart`/`CirclePackingChart` 均无实例字段），`draw` 的所有中间结构都是局部变量；`internal class ChordNode` 等只在单次调用内构造并传递，无线程间发布路径。`CHART_DEFAULT_PALETTE` 是 `let` 常量但类型为 `Array<String>`（可变数组，`ChartTheme.cj:19`），当前无写入点，且是 `internal`；作为「可变全局」的潜在风险记录在此，不判缺陷（无写路径） |
| §13 文档一致性 | 6 | #5（`combo` 范围含 0）、#6（`circle-packing` 父圆包住子圆）、#14（`choropleth` 最值取末色）、#16（`choropleth` 校验清单漏 `id`）、#17（`chord` 比例口径）、#18（`combo` 类型计数夸大）。反向核对通过的项：六份 design 的公式与常量（`k = 0.45·min/√total`、`sqrt(value)*scale`、`band = floor(...)×levels` 钳制、`heatFlameColor(ratio, ["#e3f2fd","#0d47a1"])`、`normalize` 三模式、`padding` 默认 2、`levels` 默认 8、`showValues` 默认 true、`showLabels` 默认 false、`padAngle` 默认 0.02）在源码中逐条命中；class 名（`chord-arc`/`chord-ribbon`/`chord-label`/`choropleth-region`/`choropleth-label`/`circle-packing-circle`/`circle-packing-label`/`confusion-cell`/`confusion-value`/`confusion-label`/`contour-cell`/`contour-line`/`bar`/`line`/`symbol`）全部存在 |
| §14 功能完备性与 README 覆盖 | 1 | #7（`interpolate` / `levels` 数组承诺未实现）。另核对：六图在 `README.md` 均有独立小节（`1671` chord、`2609` choropleth、`1558` circle-packing、`2856` combo、`2110` confusion-matrix、`1253` contour），`type` 字符串与 `ChartConfig.parse` 的 `expectedType` 一致；六个 `tasks.md` 全部勾选且对应文件存在（无「任务勾了但文件缺失」） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；20 个 `.md` 全部逐行读完（合计 495 行） |

### 第 7 部分

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

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | #6（哑铃图把合法的负值判为非法，属契约/正确性问题）；其余边界与坐标口径问题归入 §13 / §14 计数，不重复；无外部输入解析、无凭据、无注入面 |
| §1 死代码 | 0 | 20 个文件均为 `.md`，无可执行声明。机械动作改为"文档内是否留有未兑现的承诺"：逐份核对 5 个变更的 `tasks.md` 勾选与 `src/*_test.cj` 是否存在（6 个测试文件均存在），未发现"勾了但无产物"；`doc/spec/**` 属归档变更，不判"过期文档=死代码" |
| §2 重复逻辑 | 2 | #5（环形图逐行复制饼图扇区绘制，差异只有 class / 标签半径 / `showPercent` 分支）、#12（点图、哑铃图与 `HorizontalBarChart` 的轴与类目行样板三处同型）。机械动作：①逐份比对 5 份 `spec.md` 的 Requirement 与 Scenario（differential-flame 3+2、donut 4+4、dot-density 4+6、dot-strip 4+5、dot 3+3），五个变更的验收语义互不重叠；②把 6 个实现的 15 个方法按"输入-输出-副作用"两两比对，并把 `DonutChart` 对 `PieChart`、`DotChart`/`DumbbellChart` 对 `HorizontalBarChart` 的同型段落逐行对照 —— 前者命中 #5，后者命中 #12。四份 spec 都重复出现"`type` 不匹配抛 `UnsupportedChart`"这类通用验收句，但各属独立变更的验收快照，合并会破坏变更历史，按 §2 误报边界不判重复 |
| §3 空实现 | 0 | 6 份 `tasks.md` 无 `TODO`/`FIXME` 占位；5 份 `spec.md` 的 Scenario 均有对应实现分支（除 #4 的边界缺口，已单列）；`Regions` 缺省分支 `case None => ()`（`DotDensityMapChart.cj:76`）属 spec 明确允许的"无底图"语义，不是空实现 |
| §4 栈溢出 | 0 | 文档未承诺任何递归深度。核对实现：`validateValues` / `assignDepth` 有 `depth > total` 保护，但 `layoutNode` / `drawNode`（`DifferentialFlameChart.cj:214-259`）没有，递归深度等于树深、由输入决定；缺栈帧大小与崩溃深度数据，按铁律只进「待验证假设 #3」 |
| §5 OOM | 0 | spec 未声明任何数据规模上限，也没有"全量物化"承诺；本部分无代码可判。是否该给 `nodes` / `points` 加上限属源码子轮判定，本部分不臆断 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分也无代码；不提出热点结论（见「待验证假设」，3 条均非性能结论） |
| §6.2 大粒度锁 | 0 | 无代码、无线程同步面 |
| §6.3 并发串行 | 0 | 同上 |
| §6.4 低效算法 | 0 | 同上。文档中的复杂度描述只有 `dotStripOffset` 的 O(1) 抖动与 `dotDensityRadius` 的 O(1) 半径换算，均无隐藏嵌套 |
| §7 降堆内存方案 | 0 | 无代码、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数，local region 候选无从谈起；文档也未提及 local mode |
| §11 现有代码的 BUG（存量） | 3 | 为核对文档承诺读了 6 个实现与 `ChartFrame` / `PieChart` / `HorizontalBarChart` / `BulletChart`，确认 3 条存量缺陷：#1（横向轴传 `drawYAxis`，样例 `charts/M077-dumbbell.svg` 复现）、#4（根 `value2 = 0` 零宽）、#6（`bulletNumber` 的非负约束外溢到哑铃图）。`DonutChart.cj:133/143` 硬编码颜色、`DotStripChart.cj:75` 缺 `jitter` 上界留在 #2 / #3 的取证与「范围外提示」，源码归覆盖 `src/**` 的子轮 |
| §12 并发安全与锁粒度 | 0 | `Chart.draw` 在 `Chart.cj:24-25` 被声明为纯函数语义（不改 `data`、同输入确定性输出），6 份文档未声明任何共享状态或线程安全契约不同；无共享可变状态可判 |
| §14 功能完备性与 README 覆盖 | 3 | #7（spec 承诺 4 扇区、实现跳过零值）、#9（`regions` 元素形态与 `path` 键未文档化）、#11（`symbolSize` 默认值、`pie-label` 类名未文档化）。反向核对成立项：6 个 `type` 字符串（`donut` / `differential-flame` / `dot` / `dot-density-map` / `dot-strip` / `dumbbell`）在 `src/*.cj` 均有 `ChartConfig.parse(data, "<type>")` 入口并在 `ChartGallery_test.cj` 有样例；`innerRadius` 0.55、`radius` 3、`jitter` 0.15、`dotSize` 7 四个文档默认值与实现常量逐一相等 |
| §13 文档一致性 | 7 | #1（渲染坐标口径）、#2（内孔与文本配色组合）、#3（"带内"承诺无上界支撑）、#4（根 `value2 = 0` 宽度基准缺失）、#6（"只要求数字"与实际非负约束不符）、#8（抖动公式相位）、#10（字段层级）。#5 / #12 属实现重复，#7 / #9 / #11 属"该写没写"，分别计入 §2 与 §14，不在此重复。按 §13 归档口径，`doc/spec/**` 只核"当时结论是否自洽"，故全部按口径缺口而非"过期"定级 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件。清单外补充阅读：`add-f-chart-differential-flame/{design,proposal}.md`、`PieChart.cj`、`HorizontalBarChart.cj`、`BulletChart.cj`、`ChartJson.cj`、`ChartConfig.cj`、`HeatmapChart.cj`、6 个 `*_test.cj` 与已入库样例 `charts/M077-dumbbell.svg`，均不计入覆盖数 |

### 第 9 部分

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

### 第 10 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 正确性：严重 #1/#2（坐标方向、布局越界）、一般 #4（负尺寸）；可读性：轻微 #6（重复常量）；安全性：仅处理 JSON 数值与字符串，无注入面、无凭据，0 命中 |
| §1 死代码 | 3 | 逐个核对本部分涉及的 5 个类与其私有成员：`FlowNode/FlowEdge/ForestRow/GanttTask` 全部字段有读取点，`parseNodes/parseEdges/layoutNodes/drawEdge/drawNode/parseTasks/position/forestLogTicks/forestMarkerSize` 均有调用者；命中的是 `GainChart` 死变量、`parseEdges` 死参数、`FunnelChart` 未用 import（轻微 #4）。`public` 类 `Flowchart/ForestChart/FunnelChart/GainChart/GanttChart` 对外可达，不判 |
| §2 重复逻辑 | 1 | 已把 5 个 `draw` 主体压成「输入 → 输出 → 副作用」比对：结构相似但字段与 class 名不同（业务差异），不合并；真正的同语义重复是 `xLabelHeight` 块 ×3 与 `position` 对 `LinearScale` 的重写（轻微 #6）。`GainChart` 复用 `sortLiftPoints`/`volcanoNumber` 属于合理复用 |
| §3 空实现 | 0 | 5 个 `draw` 均有完整实现；`Flowchart.cj:203` 的 `case None => ()` 对应「edges 可选」，`ChartSvgKit` 的 `match` 空分支均为可选参数分支，均非吞异常；无 `TODO` / `UnsupportedException` |
| §4 栈溢出 | 0 | 无递归：`layoutNodes` 用 n 轮松弛而非 DFS，`sortLiftPoints` 为迭代插入排序，`ChartTime` 为纯算术；环检测缺失只影响坐标（已并入严重 #2），不产生栈增长 |
| §5 OOM | 0 | 无全局可变容器（仅 `CHART_DEFAULT_PALETTE` 常量）；单次 `draw` 的分配量与输入条数线性，`chartNiceTicks` 有 `guard < 1000`；无按报文长度预分配。缺少点数上限属产品取舍，列入优化与假设，不定为缺陷 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，未把「排序 O(n²)」「分层松弛 O(V·E)」写成结论，仅进「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分实现无锁、无临界区 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无队列 |
| §6.4 低效算法 | 1 | 线索命中 2 处（插入排序、分层松弛），因无测量数据只作「待验证假设」，不计入发现；`forestLogTicks` 指数循环有上下界，不构成低效 |
| §7 降堆内存方案 | 1 | 增益图每点小数组（见优化方案第一节）；森林图 `rows` 为必要中间结构，无多余副本 |
| §8 降 CPU 方案 | 1 | 排序改标准库（见优化方案第二节）；其余无基线 |
| §9 local mode 可行性 | 0 | 本部分实现产出的是逃逸的 SVG `String`，中间对象（`ArrayList`/点数组）生命周期与返回值同长，`local` 无法覆盖；且需 `--experimental`，收益无法用峰值内存证明，不列为可行 |
| §11 现有代码的 BUG（存量） | 7 | 逐条核对了 5 个 `draw` 的空集合、除零、越界与重复键：`series` 空/多系列（已校验）、`data` 空（已校验）、`xMax<=xMin`（已校验）、`rowHeight` 除零（rows 非空已保证）、`tasks` 空（已校验）；命中的是严重 #1/#2、一般 #1-#5（另见轻微 #3 权重边界、#5 日期校验） |
| §12 并发安全与锁粒度 | 0 | 5 个图表类只有 `init() {}` 与 `draw`，无成员状态，`draw` 只读入参并返回新字符串，天然线程封闭；`LinearScale`/`ChartFrame` 为每次调用新建的局部对象 |
| §13 文档一致性 | 6 | 逐条核对 spec/design/proposal 引用的符号与行为：`ChartSvgKit.ellipse`、`ChartTime.parseDays/formatDays`、`chartNiceTicks`、`ChartFrame.drawXAxisNumeric`、`LinearScale`、`forestLogPosition/forestLogTicks/forestMarkerSize`、`funnelConversion` 全部存在且签名一致；命中的是严重 #1（对角线方向）、轻微 #1（proposal 自相矛盾）、轻微 #2（场景与 class 冲突）、轻微 #3（权重 0 的 MUST）、轻微 #7（依赖箭头 class）、轻微 #8（流程图规格未覆盖 horizontal/rect/round/有环） |
| §14 功能完备性与 README 覆盖 | 3 | `lane` 未实现（一般 #2）、`yAxis.labels` 只校验不生效（一般 #1）、流程图规格覆盖面不足（轻微 #8），均给了「承诺源 + 缺失证据」双证；README 覆盖属模块其他部分，本部分不重复判定 |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_chart.part10.txt` 行数一致，无遗漏 |

### 第 11 部分

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

### 第 12 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 4 条（#3 坐标越界、#5 静默丢节点、#6 无界递归、#9 频数刻度失真）。本部分无 `.cj` 入口，分层设计、值/引用语义、注入与凭据维度不适用（文档只描述单图 JSON 结构，无拼串、无凭据）。可读性：5 份 `design.md` + 5 份 `spec.md` 结构统一，未发现结构性缺陷 |
| §1 死代码 | 1 | #5（`IcicleChart.cj:167-169`、`183-185` 的 `depth > total` 恒假分支；`FlameChart.cj` 同款）。做法：对「文档承诺的校验分支」逐个推可达性。未做 6 个 `.cj` 的全部 `private`/`internal` 符号全仓引用搜索（属 `src/**` 子轮），本维度只保证「文档承诺对应的分支」已判定；另逐个 grep 验证了文档引用的 20 余个符号与全部 CSS class 均存在（`heatmapColor`/`computeHistogram`/`histogram2DCounts`/`heatColor`/`flameColorIndex`/`BandScale`/`LinearScale`/`chartNiceTicks`/`chartFormatTick`/`drawXAxisNumeric`/`drawYAxis`/`heatmap-cell`/`histogram-bar`/`hive-*`/`icicle-*` 等） |
| §2 重复逻辑 | 3 | #8（冰柱图 vs 火焰图整份复制，diff 只差类型名与默认方向）、#12（分箱整数校验逐行同构）、#13（热力图带宽两种算法）；另在 #3 记了 `BarRenderer` 与 `HorizontalBarChart` 的 0 基线规则重复且行为漂移。`HistogramChart`/`Histogram2DChart`/`HeatmapChart`/`HiveChart`/`HorizontalBarChart` 之间无同语义实现（退化处理相似但坐标系与输出 class 不同，属独立演进）；各变更的 `proposal.md`/`tasks.md` 结构重复属 OpenSpec 模板，不判 |
| §3 空实现 | 0 | 逐条比对 5 份 in-scope spec 的 18 条 Requirement 与实现，无空函数体、无 `TODO`/`FIXME`、无占位异常；`Histogram2DChart.cj:124` 的 `case None => ()` 是可选字段缺失的正常分支，不是吞错；5 份 `tasks.md` 全部 `[x]` 且所指文件/测试存在 |
| §4 栈溢出 | 1 | #6。判定依据「递归深度 = 输入树深、无常量上限」；崩溃层数 `需实测`，已列假设 #2，未据此提高严重度 |
| §5 OOM | 1 | #4，已量化：一维 `1e8 bins` ≈ 800 MB、`1e9` ≈ 8 GB；二维 `[50000,50000]` ≈ 20 GB，并有 `binsX*binsY` 溢出路径。资源释放/句柄维度不适用（无文件、连接、CFFI） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据。`findNode` 的 O(n·m)、颜色逐格解析只作线索，已降级为优化方案 + 假设 #1/#4 |
| §6.2 大粒度锁 | 0 | 6 个实现均无锁、无 `synchronized`、无共享可变状态；`Chart` 契约要求纯函数（`Chart.cj:27-35`），`draw` 全用局部变量 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池调用；渲染是单线程同步流程 |
| §6.4 低效算法 | 0 | 已识别两处线索（`HiveChart`/`IcicleChart` 线性 id 查找），无占比数据，按铁律不记为缺陷，改为优化方案 + 假设 #1 |
| §7 降堆内存方案 | 1 | 一条 `[堆内存]` 方案（`ArrayList` 扩容峰值 + 每行小数组），`无基线（待验证）`。未提池化：无生命周期证据 |
| §8 降 CPU 方案 | 2 | 两条 `[CPU]` 方案（id 查表、颜色预解析），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 已核约束、结论不可行：6 个 `draw` 的中间结构（`HistogramBins` / `Histogram2DResult` / `HiveNode` / `IcicleNode`）跨函数传递、经 `children` 回填，`IcicleNode` 还被 `drawNode` 递归持有，属明显逃逸；且需 `--experimental`，无前后峰值数据，不建议排期 |
| §11 现有代码的 BUG（存量） | 6 | #3（基线越界）、#4（分箱无上界）、#5（环检测恒假 + 静默丢节点）、#6（无界递归）、#7（负尺寸矩形）、#9（频数刻度）。均由文档条款顺带核对实现命中，未做全仓考古 |
| §12 并发安全与锁粒度 | 0 | 无线程共享路径：6 个类均只有空 `init()`、无字段，`draw` 中间态全为局部变量；`Chart` 契约声明纯函数（`Chart.cj:27-35`），无锁可谈粒度 |
| §14 功能完备性与 README 覆盖 | 1 | #14（spec 校验清单缺 4 条实现已强制的约束）。其余双向核对完成：18 条 Requirement 均有实现分支，`proposal.md` 承诺的 11 个字段（`bins`/`shape`/`groupField`/`nodeRadius`/`clusterGap`/`orientation`/`colorBy`/`frameHeight`/`colorRange`/`showValues`/`cellGap`）全部可解析；六种图在 README 均有独立小节（`README.md:380`/`832`/`998`/`1307`/`1700`/`2506`），`type` 字符串与实现逐一对应 |
| §13 文档一致性 | 6 | #1、#2、#9、#10、#11、#14，以及 #3 的附带项（design「x 范围包含 0」未被保证）。其余 Requirement / Scenario / Design 条款逐条核对一致 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`add-f-chart-heatmap` 的 design/proposal 在第 11 部分、`add-f-chart-icicle` 的 spec/tasks 在第 13 部分，本部分不含 |

### 第 13 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 4（#1 轴方向、#2 `std` 错位、#3 节点丢弃、#4 日期解析），可读性 1（#9 文档 class 清单不全）；设计 / 语言特性不适用（本部分无 `.cj`）。安全性做了反向核对：6 组文档未引入凭据、注入或外部路径写入，渲染入参只来自 JSON |
| §1 死代码 | 2 | 本部分无 `.cj`，未做 private / internal / protected 符号搜索（属各 `.cj` 子轮）。计入 2 条：`IcicleChart` 的两处 `depth > total` 在"单父 + 单根"约束下恒为假（#3），`LearningCurveChart.metric` 读出后不再使用（#13）。另外机械核对了文档引用到的 14 个符号（`IcicleChart` / `InfluenceChart` / `InfluencePoint` / `influenceRadius` / `LassoPathChart` / `LearningCurveChart` / `LiftChart` / `LineChart` / `sortLiftPoints` / `BandScale` / `LinearScale` / `drawXAxisNumeric` / `parseDays` / `formatDays`）——`grep` 全部在 `src/` 命中，无过期引用；5 份 `tasks.md` 共 20 条任务全部 `[x]`，引用的 5 个 `*_test.cj` 与 `ChartTime.cj` 都存在 |
| §2 重复逻辑 | 0 | 逐条比对 5 份 `specs/chart-rendering/spec.md` 的 requirement 与 scenario：learning-curve 与 lasso-path 的"按 x 升序连接 + 逐点圆点"、lift 与 lasso-path 的"轴范围覆盖全部数据"措辞相近，但边界（3% / 5% / 8% 余量、是否含基线、是否单系列）各不相同，属各变更的独立 delta，合并会抹掉差异，按 checklist §2 误报边界不判重复。实现侧的跨图复用（`sortLiftPoints`、`volcanoNumber` 被三张图借用）属 `.cj`，只作提示 |
| §3 空实现 | 0 | 6 组文档承诺的 class（`icicle-node/label`、`influence-point/label`、`lasso-line/point`、`learning-line/point/band`、`lift-line/point/baseline`、`line/symbol`）在 `src/` 都有实际输出路径；20 份文档中无 `TODO` / `FIXME` / `UnsupportedException` 占位。`metric` 的"仅校验"按 §1/§14 归类，不在此重复计数 |
| §4 栈溢出 | 0 | 文档侧未承诺递归，也未写节点数 / 树深上限。相关线索（`IcicleChart` 的四趟按树深递归）已在第 12 部分（`parts/f_chart.part12.md` #6）立项，本部分不重复；建议规格补"`nodes` 规模上限"或"树深上限"，使递归深度变成常量 |
| §5 OOM | 0 | 6 组文档均未声明数据规模上限，也未承诺流式/分页；本部分无分配路径。文档可补"单图点数上限"建议，但无基线不单列 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，不提出热点结论；两条线索已进「待验证假设」#1 / #2 |
| §6.2 大粒度锁 | 0 | 6 个图型均为单次同步 `draw()`，文档未描述任何锁或共享 writer |
| §6.3 并发串行 | 0 | 同上，无 `spawn` / 批处理语义可核对 |
| §6.4 低效算法 | 0 | 文档未承诺复杂度；实现侧 `sortLiftPoints` 为插入排序（潜在 O(n²)），无输入规模数据，按铁律只进「待验证假设」#1 |
| §7 降堆内存方案 | 0 | 本部分无实现、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档未提及 local mode；无函数级临时对象峰值数据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 4 | 逐份核对 6 组文档的校验清单 / 轴范围 / 排序 / 解析断言与实现：#1（轴方向）、#2（`std` 错位）、#3（节点丢弃）、#4（日期解析）为存量缺陷；其余边界（空 `series`、空 `data`、非数字、负值、长度不符、`type` 不匹配）实现与文档一致（`ChartConfig.cj:166-176` 抛 `UnsupportedChart`） |
| §12 并发安全与锁粒度 | 0 | 六个图型的 `draw()` 只操作局部对象与 `ChartConfig` 快照，无共享可变状态、无惰性初始化、无跨线程发布；文档也未声明线程安全契约 |
| §14 功能完备性与 README 覆盖 | 3 | #7（`symbol` 枚举未校验）、#11（influence 未声明单系列）、#13（`metric` 无可见作用）。反向核对：6 个 `type` 值（`icicle` / `influence` / `lasso-path` / `learning-curve` / `lift` / `line`）都在 `ChartConfig.parse` 的入参校验中落地，README 均有对应小节（`README.md:664` 折线图、`1862` 影响图、`2138` 提升图、`2212` 学习曲线、`2232` LASSO、`2506` 冰柱图），样例 SVG 齐全；另记一句提示——`doc/spec/` 下 108 份 `chart-rendering` delta 没有合并后的 capability spec（`openspec/specs/` 只有 5 个无关能力），跨图型的轴/图例约定只能靠人工比对，这是仓库约定层面的问题，不作发现计数 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；§13 另命中 8 条（#1、#4、#5、#6、#8、#9、#10、#12），与上表 §11 / §14 条目互有交叉，统计按主根因归类，不重复计数 |

### 第 14 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 契约与行为不符 5 条（#1–#5），可读性 1 条（#6），文档与工程现状不符 2 条（#7、#8）。本部分无 `.cj`：值/引用语义、`Option` 惯用法、分层与依赖方向只在文档条款层面核对（`Chart.cj` 接口、`ChartException` 四类 kind、`cjpm.toml` 依赖三项均已对上）；无外部输入拼串、无凭据、无敏感数据，安全性不适用 |
| §1 死代码 | 0 | 20 个文件全为 `.md`，无声明可判。对实现侧只做"文档点名符号是否存在"的检索：`manhattanPositions`、`mosaicColumnTotals`、`ChartTime`、`ChartSvgKit.circle`、`ChartFrame.drawXAxisNumeric` 均存在；`manhattan-chromosome` 零命中（属缺失，#1）；`heatmapColor` 存在但不是本图用的那个（#8）。未对 `src/**` 的 `private` / `internal` 符号做引用统计——那属其他子轮 |
| §2 重复逻辑 | 0 | 已逐对比较 6 个 change 的文档：`proposal.md` 的 "New Capabilities / 无" 段落、5 份 spec 里"`type` 不匹配 → `UnsupportedChart`"条款属 OpenSpec 模板与逐变更契约要求，不判重复；4 份 design 的"数据 / 布局 / 校验"三段结构相同但内容各异；`add-f-chart-module/design.md:80-92` 的信封字段表注明"详见 `chart-json-spec.md`"，不构成第二份真相来源 |
| §3 空实现 | 0 | 5 份 spec 的每条 Requirement 都带可判定 Scenario；4 份 tasks 全部 `[x]` 且指向的源文件 / 测试文件都存在（已逐一检索）；无 `TODO` / `FIXME` / 占位章节。`network-heatmap/design.md` 缺"校验"小节是结构差异，校验条款在同 change 的 spec 里，实现有对应抛错（`NetworkHeatmapChart.cj:80-146`） |
| §4 栈溢出 | 0 | 文档只描述单趟流程：分组累加偏移（`manhattan/design.md:9-11`）、双层矩阵遍历（`network-heatmap/design.md:10`）、单层堆叠（`mosaic/design.md:9-10`），无递归 / 自引用结构描述。实现侧递归（若有）属其他子轮 |
| §5 OOM | 1 | #5（N×N 输出无上限，已按 90–120 B/矩形估算到 N=1000 / 3000 的 100 MB / 1 GB 量级；精确峰值列待验证假设 #1）。`cellGap` 过大导致负尺寸矩形属实现侧，part12 已报同源问题，此处不重复计 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分无运行时代码。唯一复杂度线索（`ManhattanChart.cj:205-210`、`:238-247` 的 `contains` 线性分组）已列入待验证假设 #2，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 6 个 change 的文档均不涉及锁；`Chart.draw` 契约明确纯函数、不依赖全局可变状态（`add-f-chart-module/design.md:57`） |
| §6.3 并发串行 | 0 | 文档无 `spawn` / `Future` / 线程池 / 定时任务描述 |
| §6.4 低效算法 | 0 | 已核 `manhattanPositions` 是"每组扫全量点"的 O(n·k)（k = 染色体数，通常 ≤ 25），没有耗时占比与 n 的拐点数据，按铁律只进待验证假设 #2；其余文档只描述比例换算与等分，无嵌套扫描 |
| §7 降堆内存方案 | 0 | 文档无"持有什么、多大、活多久"的可测对象（未引入缓存、队列、注册表）。不产出无基线方案 |
| §8 降 CPU 方案 | 0 | 同上；比例换算与字符串拼接都在实现侧，属其他子轮 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象描述；`Chart.draw` 的输出必须作为 `String` 返回（逃逸），local mode 的"函数返回即释放"前提不成立，且无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 5 | #1–#5，均为"文档契约与实现行为不符"或"契约自身矛盾"，每条都给了实现行号与同一提交的 `git log` 依据。只在本轮读到的文档涉及处取证，未做全仓考古 |
| §12 并发安全与锁粒度 | 0 | 文档未描述共享可变状态；纯函数契约（`add-f-chart-module/design.md:57-58`）排除"跨请求共享"路径。锁粒度无可谈对象 |
| §14 功能完备性与 README 覆盖 | 3 | #1（proposal 承诺的 `manhattan-chromosome` 无实现、无验收条款）、#5（契约要求 N² 输出但无拒绝路径）、#7（`testdata/` 黄金文件测试策略未落地）。README 覆盖本部分不涉及（`README.md` / `README_en.md` 在其他子轮） |
| §13 文档一致性 | 5 | #2（配色与阈值标签）、#3（纵轴两条 MUST 互斥）、#4（列总和口径）、#7（ChartScale 职责与黄金文件）、#8（`heatmapColor` 命名）。其余 Requirement / Scenario / Design 条款逐条核对一致：`ChartErrorKind` 四值、`draw` 签名、依赖方向、`mosaicColumnTotals` 入口、曼哈顿位置公式与测试断言 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.cj`，不含未读项 |

### 第 15 部分

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

### 第 16 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 #1 #3 #5；设计/文档口径 #4 #13 #14 #15；可读性 #9 #10；语言特性 #2（`Option` 单侧缺省与显式值混用）；安全性无命中；安全性与分层不适用（无 I/O、无外部注入面、纯内存 SVG 生成） |
| §1 死代码 | 2 | 逐个核对本部分涉及的 6 个实现的 `internal` 符号（`PairedItem`、`ParallelDimension`、`ParallelSeriesData`、`paretoOrder`、`paretoCumulative`、`parallelNormalize`、`percentStackedValue`、`stackedBarX`、`groupedBarX`、`BarSeries`、`BarMode`、`BarRenderer.render`、`ChartRect` 的 `right`/`bottom`/`centerX`/`centerY`）均有调用者；`return`/`throw` 后同层语句逐个看过，命中 #6（`ParetoChart.cj:91-93` 不可达）与 #11（未使用 import）。`public` 类成员属对外契约，不判 |
| §2 重复逻辑 | 2 | 按「输入-输出-副作用」压行比对了 6 个 `draw` 主体与各自 helper：命中 #7（右轴手写 vs `drawYAxisRight`）、#8（51 处同文案轴校验 / 10+ 处插入排序 / 平行坐标 x 表达式）。`percent-bar` 与 `percent-stacked-bar` 的「逐行对齐」属刻意别名，已在设计里声明，不算重复 |
| §3 空实现 | 0 | 六个 `draw` 均有完整实现；`PercentStacked` 分支的 `continue`（`BarRenderer.cj:177-179`）是 `total <= 0` 的有意跳过，设计文档已写明，不是空实现 |
| §4 栈溢出 | 0 | 本部分涉及的代码无递归：`paretoOrder` / `sortLiftPoints` 为迭代插入排序，`parallelNormalize` 为纯算术，折线生成是单层 `for` |
| §5 OOM | 0 | 无全局容器、无按报文字段预分配、无跨请求缓存；内存与输入行数/类目数成正比且用后即弃。缺峰值数据，定量结论进待验证假设 #3 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，`paretoOrder` 与平行坐标字符串拼接只能进待验证假设 #1 #2，不写成缺陷 |
| §6.2 大粒度锁 | 0 | 全链路无锁、无共享可变状态（`SvgBuilder` / `ChartSvgKit` 均为单次调用内新建） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池，纯同步计算 |
| §6.4 低效算法 | 0 | 静态可见的复杂度隐患只有 `paretoOrder` 插入排序（O(n²)），因无输入规模与耗时数据，按规则降为待验证假设 #1，不列为发现 |
| §7 降堆内存方案 | 0 | 可想的点（`rows.toArray()` 双份、`ArrayList` 预分配）都缺基线，无「改前/改后」对照，不能写成方案 |
| §8 降 CPU 方案 | 0 | 同上，缺 `cjpm bench -O2` 对照 |
| §9 local mode 可行性 | 0 | 无函数内大临时结构可作为受益对象；`draw` 的产物（SVG 字符串）必然逃逸，local region 改造不成立，且无峰值内存对照数据 |
| §11 现有代码的 BUG（存量） | 3 | 本轮读到的 6 个 `draw` 边界/空值/坐标路径全过了一遍：命中 #1（Y 轴反向）、#3（画布无最小尺寸）、#5（显式范围不裁剪）。`before`/`after` 非负、series 数量、data 非空、行长度、标签长度、type 判别均已核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 六个图表类只有 `draw(data)` 一个入口，全部状态是局部变量；`ChartConfig` / `ChartTheme` / `SvgBuilder` 均在 `draw` 内新建，无线程共享路径，无锁可谈 |
| §14 功能完备性与 README 覆盖 | 1 | 六个特性的代码入口、class 名、错误类型均已接线，无 TODO / `UnsupportedException`；命中 #12（任务清单声称的归一化测试缺失）。README 覆盖归第 1/2 部分，本部分不重复判 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 逐份对照实现取证，结论见「文件覆盖」表 |

### 第 17 部分

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

### 第 18 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分 20 个 `.md` 无执行代码；已逐条复算文档中的可验证数值（QQ 四分位四点、雷达 2×5=10 symbol、雨云 12 点/1 箱/2 须、山脊 4/4/4、残差 6 点），并核对渲染侧实现，未发现文档承诺与行为相反之处 |
| §1 死代码 | 0 | 文档无声明可判死代码。反向做了「文档点名符号是否真实存在」检查：`qqTheoryQuantiles` / `normalQuantile` / `qqFitLine` / `ridgeAmplitude` / `residualXRange` / `residualYRange` / `clamp01` / `gaussianKde` / `defaultBandwidth` / `boxScatterBounds` / `swarmOffsets` / `chartNiceTicks` / `LinearScale` / `ChartFrame` 全部在 `f_chart/src/*.cj` 命中且有调用者，无失效引用 |
| §2 重复逻辑 | 0 | 六组文档的 `## ADDED Requirements` / `Capabilities` 段落属 OpenSpec 文件格式要求，需求正文语义互不相同，不判重复；同文件中无两段同义描述。源码侧三处插入排序（见总评「范围外提示」）不在本部分文件清单内，不占用本部分统计 |
| §3 空实现 | 0 | 文档无函数体；「承诺的图元」逐类 grep 均有输出点（`qq-point`/`radar-area`/`symbol`/`raincloud-*`/`ridge-*`/`residual-*`/`roc-*`），无 TODO / 占位 / 空分支承诺 |
| §4 栈溢出 | 0 | 文档描述的算法（核密度采样、插入排序、分位计算）在实现中均为定长循环或单层循环，无递归、无用户可控深度 |
| §5 OOM | 0 | 文档未承诺无界容器；采样点数固定（雨云 48、山脊 81），数据点数只在输出图元数量上线性增长，无「按不可信长度预分配」的文档承诺 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，也无性能承诺，热点结论不成立；未写入待验证假设（文档不引入新的性能断言） |
| §6.2 大粒度锁 | 0 | 文档无并发 / 锁语义，`f_chart` 渲染路径为「入参构造 → 输出字符串」，无 `synchronized` |
| §6.3 并发串行 | 0 | 同上，文档未描述任务提交或并行度配置 |
| §6.4 低效算法 | 0 | 文档未描述复杂度；实现中的插入排序（O(n²)）属源码线索，无基线不判定，见「范围外提示」 |
| §7 降堆内存方案 | 0 | 本部分无运行时对象生命周期；无基线，按铁律不写方案 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档无函数内临时大对象描述；无改前改后峰值内存数据，按 §9 只能停留在假设，故不列 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无源码；核对文档时读到的实现边界（空 `series`/空 `data`/单系列约束/轴范围/`peak <= 0` 早退）已逐个与文档比对，除发现 #1–#5 的口径差异外未发现实现侧缺陷 |
| §12 并发安全与锁粒度 | 0 | `f_chart` 的 `Chart` 实现均为无状态（`public class XChart <: Chart` + `init()` 空构造，每次 `draw` 局部变量），文档也未承诺线程安全，无共享可变状态可指认 |
| §14 功能完备性与 README 覆盖 | 2 | 命中发现 #3（`raincloud-cap` 未进任何 `.md`）、#4（残差图多系列约束未写）；其余 public 图表类（`QQChart`/`RadarChart`/`RaincloudChart`/`ResidualChart`/`RidgeChart`/`RocChart`）均在 `README.md` 有独立小节与示例 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无跳过；§13 一致性命中 5 条（发现 #1–#5，均轻微） |

### 第 19 部分

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

### 第 20 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性：#1（负半径导致输出方向错误）。设计/语言特性/可读性无问题；安全性方面本部分不涉及注入或敏感数据（JSON 经 `ChartJson` 取值，无拼接执行） |
| §1 死代码 | 0 | 本部分无 `.cj`。为核对 spec 通读了 6 个实现文件，其 `internal` 符号逐个全仓搜过引用：`spiralPoint`（draw + `SpiralChart_test.cj:87,95,103`）、`shapOrder`（draw + `ShapChart_test.cj:100,113`）、`stackedAreaBounds`（draw + `StackedAreaChart_test.cj:59,71,82`）、`groupIndexesOf`/`uniqueGroupCount`（draw 与 `stackedAreaBounds`）均有调用者；读到的 `return`/`throw` 后无同层语句，`if (labels.isEmpty())` 分支可达；`symbol == "none"` 分支由输入可达（其「无文档」问题记 §14 #6，不按死代码计） |
| §2 重复逻辑 | 2 | #4：`StackedAreaChart` 累计两遍、`ScatterChart` 轴范围两函数逐行同构。已把 6 个实现的函数体按「输入→输出→副作用」两两比对：`SequenceChart.parseParticipants/parseMessages`、`ShapChart` 排序与判重、`SlopeChart`/`SpiralChart` 的解析块差异大于共性（字段集、错误类型、默认值都不同），不判重复 |
| §3 空实现 | 0 | 无空函数体、无 TODO/FIXME、无 `catch {}`；`case "none" => ()` 是有意的 no-op 策略，问题在「未文档化」而非「空实现」，见 §14 #6 |
| §4 栈溢出 | 0 | 6 个实现全无递归：`spiralPoint` 为纯算术，`shapOrder` 为插入排序双层循环，`stackedAreaBounds` 为三维有界循环；无自引用结构、无深度拷贝 |
| §5 OOM | 0 | 唯一全量物化是最终 SVG 字符串与 `ArrayList→Array` 的等长副本，规模 = 数据点数，属渲染 API 固有；6 个 `draw` 均无跨调用容器、无缓存、无全局注册表，单次调用结束即可回收。spec 未承诺输入上限，故不按「无拒绝路径」计缺陷 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，也无任何性能承诺；不进发现，线索见「待验证假设」#1 |
| §6.2 大粒度锁 | 0 | 6 个实现无 `synchronized`、无 Mutex、无 I/O |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无批处理/队列 |
| §6.4 低效算法 | 0 | 循环均为 O(n) 或 O(n×series)；`shapOrder` 的 O(k²) 与判重 O(k²) 中 k 为特征数（spec 示例 4 项），无规模证据，不成立 |
| §7 降堆内存方案 | 0 | 本部分无代码主体；6 个实现均无长期持有结构，无「还能省」的量化对象可写 |
| §8 降 CPU 方案 | 0 | 同上；唯一线索（#4 的重复累计）缺基线，已降级为待验证假设 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象（输出为唯一逃逸串），且无前后峰值内存数据，按约束只能是假设，本部分不列 |
| §11 现有代码的 BUG（存量） | 1 | #1。其余边界已核对并有保护：散点空 `data` → 默认 `[0,1]` 域（`ScatterChart.cj:221-224`）、SHAP 全零 → `[-1,1]`（`ShapChart.cj:94-95`）、斜率 `span<=0` → 1.0（`SlopeChart.cj:98-101`）、堆叠面积全零 → `max = min+1`（`StackedAreaChart.cj:299-304`）、序列消息为空 → 行高 40（`SequenceChart.cj:114-118`） |
| §12 并发安全与锁粒度 | 0 | 6 个 `Chart` 实现均无成员可变状态（只有 `public init() {}`），`draw` 全部用局部变量与局部 `SvgBuilder`，无共享路径；无锁可谈 |
| §13 文档一致性（含规格自洽性） | 3 | #2（五处布局常量）、#3（`drawGrid` 悬空）、#5（`spiralPoint` 公式除零）；另有 `shap.features` 的归档文档落点，与 `part2.md` #4 / `part3.md` #13 同源，不计入本部分。其余场景逐条复算通过（spiral 首末点、shap 排序、slope 长度校验、sequence 虚线） |
| §14 功能完备性与 README 覆盖 | 1 | #6（`symbol: "none"` 未文档化且无测试）。正向核对：6 个 `type` 在 README 均有里程碑条（`:73` scatter、`:77` sequence、`:82` stacked-area、`:145` slope、`:151` spiral、`:169` shap）与专节示例（`:1145`、`:2394`、`:701`、`:596`、`:798`、`:2308`），`README_en.md` 同步；公开 API 无漏登 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；`add-f-chart-stacked-area` 本身只有 `design.md` + `proposal.md`（无 spec delta / tasks），清单如此，非漏读 |

### 第 21 部分

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

### 第 22 部分

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

### 第 23 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无源码，正确性体现为「文档承诺 vs 实现」：命中 2 条一般（发现 #1 配置静默失效、#2 value 语义）；无网络 / 凭据 / 注入类内容，安全性无命中 |
| §1 死代码 | 0 | 本部分无 `.cj`；反向核对文档引用的符号是否真实存在：`TuiFlameChart`、`tuiContrastColor`、7 个 TUI 图表类、`ChartConfig.parse(defaultWidth/defaultHeight)`、`treemapWeights`、`ViolinBoxChart` 均在 `src/` 命中，无一「文档引用不存在的符号」 |
| §2 重复逻辑 | 1 | 同族文档重复描述同一 KDE 轮廓流程，`violin` 写 40 点、`violin-box` 写 41 点（发现 #6），属模板复制后的数值漂移；其余重复内容（7 个 TUI 类各自的 design 段）差异是业务要求，不判重复 |
| §3 空实现 | 0 | 文档无 `TODO`/占位/`UnsupportedException` 承诺；逐条核对 tasks 声明的产物（`M052-flame*.tui.txt` 5 份、各 `_test.cj`、README TUI 类表）全部存在 |
| §4 栈溢出 | 0 | 火焰图递归布局的深度上界由 `nodes.size` 决定，缺少栈大小数据，已转待验证假设 #1，不按缺陷计 |
| §5 OOM | 0 | 文档未承诺全量物化；TUI 侧只有 20×8 下限、无上限（`width: 100000` 会分配等量 `TuiCell`），但本部分无量化输入与内存数据，不入缺陷 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，本部分为文档，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 文档未描述任何锁或临界区 |
| §6.3 并发串行 | 0 | 无 `spawn` / 队列 / 批处理描述 |
| §6.4 低效算法 | 0 | design 的 `ceil(n / 可用列数 × 2)` 是抽稀规则而非复杂度问题，已并入发现 #4 |
| §7 降堆内存方案 | 0 | 无运行时代码，无基线，方案无法量化，按铁律不写 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时对象，不适用 |
| §11 现有代码的 BUG（存量） | 0 | 本部分不含 `.cj`；核对到的两处实现相反（value 语义、字段位置）按文档口径记入 §13/§14，避免与源码部分重复计数 |
| §12 并发安全与锁粒度 | 0 | 文档未声明线程模型；TUI 渲染为「入参 → 字符串」的纯函数路径，无共享可变状态 |
| §13 文档一致性 | 5 | 发现 #1、#5、#6、#7、#8；另外核对了 ANSI 转义格式、80×24 缺省值、`TuiFrame(config, 0)` 语义、`showBox` 默认值、火山图阈值默认值 1 / 1.3，均与实现一致 |
| §14 功能完备性与 README 覆盖 | 3 | 发现 #2、#3、#4（承诺的校验/标签条件/抽稀未落地或未写全）；proposal 声明的类与样例文件均已接线 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无跳过 |

### 第 24 部分

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

### 第 25 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 3（标签越界、空 data、空 series 语义）、设计 1（跨图复用 `bulletNumber`）、可读性 1（缩进）、语言特性 1（恒 `var`/死分支并入轻微项）；无外部输入拼接、无安全性问题 |
| §1 死代码 | 2 | 已逐文件过 `return/throw/break/continue` 后续语句、逐个 `private` 函数搜全仓引用（`stageIndexOf`/`findNode`/`determineContinuous`/`flushSegment`/`drawSymbol`/`drawLimit`/`requiredNumber`/`sortValues` 等均有调用）、`internal` 符号在本模块搜引用（`alluvialHeights`/`arcNodeOrder`/`bulletRangeColor`/`bubbleRadius`/`blandAltmanStats`/`boxScatterBounds` 等均有调用或测试引用）；`public` 的 `AlluvialChart`/`ArcChart`/`AreaChart`/`BarChart`/`BlandAltmanChart`/`BoxPlotChart`/`BoxScatterChart`/`BubbleChart`/`BulletChart` 均为对外 `Chart` 实现，不判死代码。命中：恒假分支（`AreaChart.cj:347-352`）、未使用 import（3 处） |
| §2 重复逻辑 | 4 | 已把本部分 9 个图的 `draw` 与 20 余个私有函数压成「输入→输出→副作用」两两比对；命中 4 组：轴范围 6 份、轴边距 6 份、标签生成/长度校验 2 份、插入排序/顺序数组/冲积图求和各 2 份 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`（全部分文件 grep 无命中）、无 `catch {}`；`case None => ()` 仅用于可选字段正常缺失（`point.y`/`outliers`/`series.color`），属语义正确的兜底 |
| §4 栈溢出 | 0 | 本部分无递归：`draw` 全是单层/双层循环，无自引用结构遍历；`findNode`/`stageIndexOf` 为线性查找 |
| §5 OOM | 0 | 输入来自已解析 JSON，容器规模 ∝ 输入；无按报文头预分配、无全局只增容器、无「全量提交任务」。输出经 `SvgBuilder` 全量拼接属既有设计，未超本部分判据 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点结论不成立；排序与幂等查找已列入待验证假设 1–3 |
| §6.2 大粒度锁 | 0 | 本部分无线程共享状态、无锁 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无单消费者队列 |
| §6.4 低效算法 | 2 | 插入排序 O(n²)（`ArcChart.cj:220-228`、`BoxScatterChart.cj:250-258`）与每阶段扫全量节点 O(stages×nodes)（`AlluvialChart.cj:154-163`）：复杂度可静态判定，但缺耗时占比 → 只进优化方案（无基线）与待验证假设，不作为缺陷 |
| §7 降堆内存方案 | 1 | `BlandAltmanChart.rawPairs` 重复数据（优化方案 3）；其余 `toArray()` 复制属既有风格、量级小，无基线不下结论 |
| §8 降 CPU 方案 | 2 | 排序换 O(n log n)、冲积图按阶段分桶；均无基线 |
| §9 local mode 可行性 | 0 | 本部分无「函数内大对象且不逃逸」的强证据，也无峰值内存数据；仅作为待验证假设 4，不写成建议 |
| §11 现有代码的 BUG（存量） | 6 | 本部分 9 个 `draw` 的边界（空数组、单元素、常量数据、负值、越界坐标）逐个核对；命中 6 条：标签越界、空 `data`、空 `series` 语义、`bulletNumber` 负值、平铺标签丢弃、`labelRotate` 底留白不足 |
| §12 并发安全与锁粒度 | 0 | `Chart` 实现无字段、无静态可变状态，`BarRenderer` 全 `static func` 且只用局部变量；实例可并发复用。`BarMode`/`BarSeries` 均为不可变值，无线程共享路径 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 9 个 public 图类型均能在 `f_chart/README.md` 里程碑表（M1/M14/M19/M26/M45/M63/M66/M76/M91）与 JSON 小节中检索到；`word-network` 的 spec/tasks 承诺项在 `WordNetworkChart.cj` 全部落地（含 README M103 登记） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 2 个均与实现对（spec 一致，tasks 全部完成），跨文件规格 `doc/chart-json-spec.md` 仅作承诺源引用（属其它部分覆盖） |

### 第 26 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：Y 轴翻转、`plot` 负宽高；设计：`legend` 配置与 `ChartFrame` 职责脱节（orient 解析在 Config、排布逻辑在 Frame 却不读）；语言特性：`Array` 引用语义共享默认调色板已核对为只读、`Option` 均已显式分支；安全性：`path`/文本/颜色均经 `f_svg` 的 `escapeSvgAttribute`/`escapeSvgText`（`f_svg/src/SvgElement.cj:424,705-718`）转义，未发现注入面 |
| §1 死代码 | 6 | 逐个搜过本部分全部 `private`/`internal` 符号与字段：`ChartJson.has/requiredObject/childPath`、`ChartFrame` 的 `ArrayList` import、`BandScale.endPixel/count` 共 6 处无引用；`ChartErrorKind.InvalidJson` 因枚举 `public` 且顶层可达**不判**（只记录，见「轻微」条）；`ChartLegend.orient` 是解析后不使用，记在「一般」条而非死代码 |
| §2 重复逻辑 | 2 | 同文件两两比对 16 个函数体 + 跨文件按错误消息/字面量搜：`colorRange` 校验 6 份、legend/轴宽样板 3 份，各合并为 1 条；`bulletNumber`/`volcanoNumber` 合并为 1 条轻微；`CalendarHeatmapAlias_test` 与 `CalendarHeatmapChart_test` 的相同 sample 按「测试准备代码」误报边界不计 |
| §3 空实现 | 0 | 逐个函数体检查：无空体、无 `TODO`/`FIXME`；`case None => ()` 均对应「可选字段缺省」的正常语义，不是吞异常 |
| §4 栈溢出 | 0 | 本部分 12 个实现文件无递归、无间接递归、无自引用结构遍历（`grep "func "` 44 个函数，调用链均为一层） |
| §5 OOM | 1 | 命中 `CalendarHeatmapChart` 的日期区间无上限（「严重」条）；其余 `stringArray/numberArray` 只按已在内存的 JSON 数组等长物化，未见按报文头预分配或全局只增容器 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，本部分不产生热点结论；日历循环、`chartTextWidth` 重复计算、排序复杂度均写入「待验证假设」与优化方案 |
| §6.2 大粒度锁 | 0 | 本部分 12 个实现文件无 `synchronized` / `Mutex` / 锁对象（`grep` 零命中） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池，全部为同步纯函数调用 |
| §6.4 低效算法 | 3 | 命中 3 处结构性低效（日历两次线性扫描、`sortLiftPoints` 插入排序、cartogram id 二次扫描），因缺输入规模与耗时占比，按规则写入「优化可行性方案 / 待验证假设」而不算「发现」 |
| §7 降堆内存方案 | 1 | 日历热力图聚合与去副本（无基线） |
| §8 降 CPU 方案 | 2 | 排序、哈希去重（均无基线） |
| §9 local mode 可行性 | 0 | 本部分函数内确有大量短生命周期对象，但 `ChartConfig`/`ChartFrame`/`Candle` 为引用类型且随函数存活，std 集合是否有 local 构造重载未逐个核对，且无改前改后峰值数据 → 只进「待验证假设 #3」 |
| §11 现有代码的 BUG（存量） | 2 | 本轮读到的 4 个图表 + 6 个公共设施的边界/空值逐一核对：命中 Y 轴翻转、`plot` 负宽高；另核对 `dayList[0]`（`:76`,`:85`）在空数据下确实被 `:68` 挡住、`points[0]`（`CalibrationChart.cj:71`）被 `:53-55` 挡住、`candleArray[0]`（`CandlestickChart.cj:103`）被 `:62-64` 挡住，均安全 |
| §12 并发安全与锁粒度 | 0 | 全部状态为调用内新建（`ChartConfig`/`ChartTheme`/`ChartPadding`/各 `ArrayList`），唯一跨调用共享的是 `CHART_DEFAULT_PALETTE`（`ChartTheme.cj:18-21`），全模块只有读取、无元素写入，线程安全；`Chart` 实现类无成员字段 |
| §14 功能完备性与 README 覆盖 | 2 | 命中 `binCount` 未实现、`legend.orient`/`position` 接线缺失；本部分 public 声明（`Chart`、`ChartException`、`ChartErrorKind`、`CalendarHeatmapChart`、`CandlestickChart`、`CartogramChart`、`CalibrationChart`）均能在 `README.md` 的图表表（M44/M61/M83/M96）与 `Chart` 接口段落（`:34-60`）中检索到，未发现「public API 完全无文档」 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完；本部分不含 `.md`，§13 仅用外部 README/spec 作承诺源引用 |

### 第 27 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 17 | 与下列专项为同一批条目（正确性 11、可读性 4、契约/安全 2），不重复计入模块统计；安全性方面唯一外部输入是 JSON 与 `path` 字符串，颜色/文本都经 `SvgWriter` 转义，未发现注入面 |
| §1 死代码 | 1 | 机械过：20 个文件的 `import` 全部逐个核对有使用（`CorrelationMatrixChart_test` 未引 `std.math`，其余 `abs`/`min` 均有调用）；全部 `private`/`internal` 符号（`labelCount`、`bodyScale`、`findNode`、`resolveTotals`、`sortChildren`、`layoutChildren`、`drawNode`、`uniqueSorted`、`indexOf`、`resolveLevels`、`resolveRange`、`resolveColorRange`、`resolveLabels`、`drawLimitLine`、`findDecisionNode`、`decisionEdgeLabel`、`countDecisionNodes`、`decisionAssignDepth`、`decisionAssignSlots`、`decisionTreeLayout`、`parseIntOrThrow`、`daysFromCivil`、`civilFromDays`、`pad`、`chordArcPath`、`chordWidth`、`pathCentroid`、`circlePackingRadius`、`contourLevel`、`confusionNormalize`、`confusionText`、`controlMean`、`controlStdDev`、`resolveControlLimits`、`correlationColor`、`formatCorrelation`、`heatFlameColor`、`flameColorIndex`、`orgFitLabel`、`percentStackedValue`）全仓搜索均有调用者；`ChartTime.partsOfDays` 由 `CalendarHeatmapChart.cj:204` 使用，非死代码；无 `return`/`throw` 之后的同层语句。唯一命中是 #4 的三处恒假 `depth > total` |
| §2 重复逻辑 | 2 | 同文件内两两比对 10 个实现的函数体（输入-输出-副作用摘要）：`drawBarGroups` 单/多系列两分支差异是业务性的（百分比归一化）不判重复；`flushLine` 与 `LineChart` 同名函数同源但不属本部分；跨文件按「相同错误文案 / 字面量 / 正则」搜出 #14、#15 两组。测试文件的 `draw`/`count` 助手在 10 个文件重复，属「测试准备代码」误报边界，未计入 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`（`grep -rn "TODO\|FIXME\|Unsupported" f_chart/src` 仅命中 `UnsupportedChart` kind）；`public init() {}` 是无状态构造，合理。唯一命中是 `pathCentroid` 的 `catch (_: Exception) { () }`（并入 #7） |
| §4 栈溢出 | 1 | 逐函数检查递归：`resolveTotals`/`sortChildren`/`layoutChildren`/`drawNode`/`countDecisionNodes`/`decisionAssignDepth`/`decisionAssignSlots` 深度由输入决定（#6）；`collectXmlText` 类跨模块递归不在本部分；其余图表全为循环，无递归 |
| §5 OOM | 1 | 逐文件核对「全量物化/按不可信长度预分配/无界容器」：`Chord`/`CirclePacking`/`DecisionTree`/`Contour` 的容器规模与输入点数线性（无平方级），不判；`ConfusionMatrix`/`CorrelationMatrix` 输出 n²（#10）成立 |
| §6.1 热点瓶颈 | 0 | 本轮无 `cjprof`/`cjpm bench`/分段计时数据，热点结论一律降级为 4 条「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁对象（`grep -rn "synchronized\|Mutex\|Atomic"` 无命中） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/通道；`draw` 是纯同步计算 |
| §6.4 低效算法 | 3 | 静态可判的复杂度问题 3 组（`Contour` 网格 O(n²)、`DecisionTree` 根检测 O(n·e)、`Chord` 每链接线性查），全部写入「优化可行性方案（无基线）」而非缺陷 |
| §7 降堆内存方案 | 2 | 见「堆内存」两条；`clear()` 不归还物理内存、`ArrayList.toArray()` 拷贝等假象已按 `mem §3.2` 逐条排除 |
| §8 降 CPU 方案 | 5 | 见「CPU」五条，全部 `无基线（待验证）`；未给任何百分比结论 |
| §9 local mode 可行性 | 0 | 不成立：布局结果（节点坐标/SVG 字符串）要逃逸出函数，`SvgBuilder` 与 `ChartConfig` 为跨模块对象；且无改前/改后峰值内存数据，只能停留在此结论 |
| §11 现有代码的 BUG（存量） | 17 | 本轮读到的 10 个实现 + 10 个测试全部按边界/空值/错误处理/契约逐条核对；17 条发现全为存量（快照模式无 diff），其中 11 条为一般、6 条为轻微 |
| §12 并发安全与锁粒度 | 0 | 9 个 `*Chart` 均为无字段的 `public class`（仅 `public init() {}`），`draw` 的全部状态是局部变量；`ChartTime` 全是 `static` 纯函数。不存在跨线程共享路径，无需同步手段 |
| §14 功能完备性与 README 覆盖 | 4 | 承诺源全部落在 `doc/chart-json-spec.md` 与 `doc/spec/**`（本部分无 `.md` 清单项）：`bar`+`stack`（#2）、`legend.show`（#3）、`levels` 数组（#8）、`interpolate`/`method`/`condition`（#9）。README 覆盖核对交由包含 `f_chart/doc/**` 的部分 |
| 文件覆盖（§13 等） | 20/20 | 无 `f_chart/src` 外的文件被漏读；`.md` 本部分为 0 个 |

### 第 28 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 6 条（Ecdf ×2、ErrorBar、Dumbbell、Donut、DiffFlame）+ 设计 1 条（轴范围样板）；语言特性上均为「局部 `ArrayList` + `toArray` 惯用法」，无值/引用语义误用；安全性已核对：所有 JSON 文本/路径经 `SvgElement.escapeSvgText`/`escapeSvgAttribute`（`f_svg/src/SvgElement.cj:705-725`）转义，`kit.path` 的 `d` 属性同样走属性转义，无注入面；无硬编码凭据 |
| §1 死代码 | 2 | 已逐个搜引用：`gaussianKde`/`defaultBandwidth`（`DensityChart.cj:272,286`）另有 Raincloud/Ridge/Violin/ViolinBox 4 处调用；`differentialColor`、`dotDensityRadius`、`dotStripOffset`、`ecdfPoints`、`flameColorIndex`（另有 CirclePacking/Hive/Icicle/NodeLink/OfflineFlame/Sunburst/WordNetwork/tui 调用）；`DensitySeries`/`DiffFlameNode`/`DotSeries`/`DotDensityPoint`/`DotStripGroup`/`DumbbellItem`/`EcdfSeries`/`FlameNode` 均只在本文件使用但都被构造与读取，非死代码；`findNode`/`validateValues`/`assignDepth`/`layoutNode`/`drawNode`/`parseSeries`/`resolveLabels`/`validateLengths`/`resolveRange`/`indexOfLabel`/`resolveYRange`/`resolveXRange`/`drawDensity` 全部有调用者。命中 2 条：`ErrorBarPoint.label` 只写不读、`EcdfChart.cj:168` 不可达分支。public 的 10 个 `Chart` 实现与 `draw`/`init` 对外可达，不判；本部分无 `protected` 声明；未发现未使用 import（逐个核对 `std.math.*` 的 `exp/sqrt/pow/minFloat/maxFloat/cos/sin/floor/abs` 均有使用） |
| §2 重复逻辑 | 2 | 已把本部分 10 个实现文件的函数体压成「输入→输出→副作用」摘要两两比对：命中 2 条 —— `FlameChart` 与 `DifferentialFlameChart` 的解析/建树/`validateValues`/`assignDepth`/`layoutNode`/`drawNode` 近逐行重复（差异只是单值 vs `value1`/`value2`），记入「重复逻辑」条；六处轴范围推导 + 四处图例装配同构，记入「轴范围样板」条。测试里的 `count(svg, needle)`/`draw(json)` 助手 10 份重复按 checklist §2 误报边界（测试准备代码）不计；`DonutChart.cj:66-68` 与 `pieFractions`（`PieChart.cj:155-171`）的负值校验重复，随「负半径」条一并说明，未单独计数 |
| §3 空实现 | 0 | 逐文件核对：10 个 `Chart` 实现的 `draw` 均有实际解析与绘制逻辑；无 `TODO`/`FIXME`/`UnsupportedException`/空 `catch`；`match` 的 `case None => ()` 均为可选字段缺省（如 `DotDensityMapChart.cj:76` 无 regions、`DotChart.cj:134` 空值跳过），属正常可选语义；仅 `EcdfChart.cj:168` 是恒假分支，已归 §1 |
| §4 栈溢出 | 1 | 只命中火焰图两张（见「递归深度」条）；其余 8 张图无递归：`DensityChart`/`DotChart`/`DumbbellChart`/`EcdfChart`/`ErrorBarChart` 全为单层循环，`DonutChart`/`DotDensityMapChart`/`DotStripChart` 无自调用，`sortRaincloud` 为迭代 |
| §5 OOM | 0 | 逐图核算峰值：所有容器规模都是「输入元素数 × 常数」——`DensityChart` 额外 101 元素网格、`EcdfChart` 每点 2 个 `Float64` 数组（已列优化方案）、火焰图每节点 1 个类实例 + 子数组；无按报文字段预分配、无全局/静态容器、无缓存、无 `spawn`，`chartNiceTicks` 有 `guard < 1000` 上限（`ChartScale.cj:98-103`）。最坏输入 100k 点时临时堆在 10MB 量级，远低于默认堆，故不判 OOM（量化见「堆内存」方案） |
| §6.1 热点瓶颈 | 0 | 本模块无 bench/profile 数据（`scope.md` 未提供，本轮也未跑构建），热点结论不成立；已把 5 条疑似热点写入「待验证假设」，注明缺哪种数据与采法 |
| §6.2 大粒度锁 | 0 | 本部分代码无 `synchronized`/`Mutex`/`Atomic`，无锁可判 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/队列，全为单线程同步绘制 |
| §6.4 低效算法 | 2 | 命中 2 条：火焰图 `n²` 查重（`FlameChart.cj:71-75,99`）、`sortRaincloud` 插入排序（`EcdfChart.cj:202` 间接使用）；因无耗时数据，已降级为「优化可行性方案（CPU，无基线）」+ 待验证假设 #2/#3，不作为缺陷计数 |
| §7 降堆内存方案 | 1 | `ecdf` 的二维点数组物化（无基线）；其余图临时对象数与输入同阶且生命周期与 `draw()` 一致，无长期持有，不另列 |
| §8 降 CPU 方案 | 3 | 火焰图 `HashMap` 建树、`density` KDE 复用、`ecdf` 排序改 `std.sort`；均无基线 |
| §9 local mode 可行性 | 0 | 各 `draw()` 内确有大量短生命周期 `ArrayList`/`StringBuilder`，但收益口径是**峰值内存**，本轮无 `getUsedHeapSize`/RSS 前后对照，且 `Chart` 输出字符串必然逃逸（`exclave`），收益无法证明 ⇒ 不列为方案，仅作为后续可测项（需 `--experimental --enable-local-mode` + 峰值内存对照） |
| §11 现有代码的 BUG（存量） | 7 | 逐函数核对了空集合/空值/边界：`points[0]`/`groupArray[0].values[0]`/`items[0]` 之前均有非空校验（`ErrorBarChart.cj:65-67`、`DotStripChart.cj:46-62`、`DumbbellChart.cj:58-60`），`values[0]` 前有 `data` 非空（`DensityChart.cj:67-69`）；命中 7 条（Ecdf 轴反转、Ecdf 末段、ErrorBar X 轴、Dumbbell drawYAxis、Donut 100%、DiffFlame 全零宽、火焰图递归） |
| §12 并发安全与锁粒度 | 0 | 10 个图类只有 `init` 与 `draw`，字段为零（`DensityChart` 等的系列类型为每次调用内构造的局部对象），无可变共享状态；`Config`/`Theme` 为只读局部实例 ⇒ 线程封闭成立，无需同步。无锁粒度议题 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分清单无 `.md`，README/规格覆盖核对留给含 `README.md` 的部分；实现侧无未接线字段：`DonutChart` 的 `innerRadius`/`centerText`/`startAngle`/`showPercent`、`FlameChart` 的 `orientation`/`colorBy`/`frameHeight`、`DifferentialFlameChart` 的 `colorRange`/`frameHeight`、`DotStripChart` 的 `jitter`/`dotSize`、`DotDensityMapChart` 的 `viewBox`/`radius` 均被读取并使用（与 `doc/chart-json-spec.md:168-2415` 的字段表一致）。唯一能力差异：`donut` 没有「显示扇区名称」选项（`PieChart` 有 `showPercent=false` 分支），规格未承诺，记待确认、不计入统计 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；本部分不含 `.md`，故 §13 文档一致性 0 条 |

### 第 29 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4（比例尺镜像、对数刻度异常类型、gantt 重复 id、funnel 负层高）+ 渲染完整性 1（gauge 缺口）+ 可读性 1（未用 import）；无安全问题（SVG 属性转义由 `f_svg` 负责，范围外） |
| §1 死代码 | 6 | 已逐个 private/internal 符号全模块 grep：`flowMapWidth`/`forestLog*`/`funnelConversion`/`gaugeAngleForValue` 等均有调用者（部分仅测试，属可见性建议，未计）；命中 = 不可达环守卫（HeatFlame 190-193/206-209）、`heatFlameColor` 两分支、`span`、`parseEdges` 未用参数、未用 import、`ForestChart` 的 `yAxis.labels` 死配置 |
| §2 重复逻辑 | 5 | 已对 10 个实现文件的函数体做「输入-输出-副作用」两两比对：地图骨架（viewBox/底图/regions）、火焰图三实现、gain↔lift 曲线、三处插入排序 + 四处 colorRange 校验、数值类型校验两遍。测试文件里 20 份 `count()` 辅助按 §2 误报边界不报 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch { () }`；`match` 的 `case None => ()` 均为可选字段正常缺省 |
| §4 栈溢出 | 1 | `heat-flame` 四个递归（本报告第 2 条）；本部分其余图表无递归（`flowchart` 分层为迭代，`gantt`/`gauge`/`funnel` 无递归） |
| §5 OOM | 0 | 所有容器规模与输入线性、无全局缓存/注册表；`funnel`/`gauge` 容器由 `series[0].data` 长度决定；递归爆栈归 §4，非堆问题 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点不成立；已列入「待验证假设」1-4 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 共享可变状态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 任务提交 |
| §6.4 低效算法 | 1 | `forestLogTicks` 迭代次数随 `logBase→1` 爆炸（已按无基线上限论证，属算法+校验）；O(n²) 查重/查找与插入排序因缺测量数据只进优化方案与假设 |
| §7 降堆内存方案 | 1 | 排序前整表第三次复制（见优化方案，无基线） |
| §8 降 CPU 方案 | 1 | HashMap 索引 + `std.sort`（见优化方案，无基线） |
| §9 local mode 可行性 | 0 | 所有 `draw` 返回 `String`，节点数组/临时 `ArrayList` 虽在函数内创建，但经 `SvgBuilder` 与返回值逃逸；且无峰值内存数据，改造不成立 |
| §11 现有代码的 BUG（存量） | 22 | 本部分全部 22 条发现均为存量（快照基线 `120fd2542`，逐条 `git blame` 抽查为 2026-11-08 的模块提交） |
| §12 并发安全与锁粒度 | 0 | 各 `Chart` 实现类无字段（`public init() {}`），`draw` 内状态全为局部变量、不修改入参，符合 `Chart.cj:25-30` 的纯函数契约；无线程共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | `gain.baseline` 未实现、`gantt.lane` 未实现；本部分无 `.md`，文档覆盖由其它部分负责，此处仅引用 `doc/chart-json-spec.md` 作承诺源 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个 `.cj` 全部读完；无 `.md`，§13 不适用（规格对照见 §14） |

**范围外提示**：`FlowMapChart.cj:98` 依赖 `pathCentroid`，该函数把 SVG 弧命令参数当坐标平均（根因在 `ChoroplethChart.cj:176-217`，已由 part27 单列）。`regions[].path` 含 `A`/`H`/`V` 时，缺省 `points` 的 flow 端点会落在错误位置；本文未重复计数，修 `pathCentroid` 时一并覆盖 `flow-map`。

### 第 30 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：#2、#3、#4、#5、#6；设计合理性：#8（重复骨架）、#17（工具函数错位）；可读性/可维护性：#12（恒假分支）、#15/#16（模板重复）；安全性：无外部字符串直接进 SVG 属性（数值经 `formatSvgNumber`、文案仅在 `<text>` 内且 `SvgBuilder` 负责转义），未命中注入类问题 |
| §1 死代码 | 4 | 逐个 `private`/`internal` 符号全仓搜引用（20 个 `private` 方法、17 个 `internal` 类型/函数均已核对，除下文列出的字段与分支外均有调用者）；命中：`HiveLink.value` 未读、`metric` 未用、5 处恒假/等价分支、Icicle 两处恒假守卫。对外可达 `public`（`*Chart.draw`）不判 |
| §2 重复逻辑 | 5 | 已两两比对本部分 10 个 `draw` 与全部私有方法：`resolveLabels` 8 份、LassoPath/LearningCurve 骨架、`count`/`draw` 测试模板 106 处、`M/L` 路径 26 处、`sortLiftPoints` 错位分层 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；测试里的 `try/catch` 均断言 `ChartErrorKind`，空分支 `case None => ()` 均为可选字段缺省（`bins`/`std`/`color`），语义合法 |
| §4 栈溢出 | 1 | 仅 IcicleChart 四个递归函数（#5）；其余图表均为循环实现，无自引用结构、无递归打印/比较 |
| §5 OOM | 1 | 分箱数无上界（#1）；矩阵/节点数组规模与输入 JSON 同阶，不构成放大，未单列 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据，热点结论不成立；5 条候选已全部降级到「待验证假设」，无一条写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无并发容器 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池；全部为单次同步渲染 |
| §6.4 低效算法 | 2 | 插入排序 `sortLiftPoints`、Hive/Icicle 的 O(n²) 查重查父；因缺耗时占比，按规则放进优化方案（无基线），不计入缺陷 |
| §7 降堆内存方案 | 1 | HeatmapChart 矩阵扁平化（无基线） |
| §8 降 CPU 方案 | 3 | 稳定排序、字典索引化、颜色解析外提（均无基线） |
| §9 local mode 可行性 | 0 | 无改前改后峰值内存数据，`matrix`/`points` 是否逃逸未验证；只写进「待验证假设 #5」，不写成建议 |
| §11 现有代码的 BUG（存量） | 6 | 本部分 20 个文件全部为存量：#2、#3、#4、#6、#14，加上 #1 的上界缺失。所有结论均给出触发输入或前置校验缺失点 |
| §12 并发安全与锁粒度 | 0 | 10 个 `Chart` 实现均无成员字段，`draw` 的全部状态是局部变量；`HiveNode`/`IcicleNode`/`Point2D` 等在每次调用内新建，无线程共享路径（线程封闭成立），因此无共享可变状态、无锁粒度问题 |
| §14 功能完备性与 README 覆盖 | 2 | `normalize` 承诺未实现（#7）；`frameHeight` 代码支持但 M53 规格未记录（#18）。其余 10 个类型字符串与 `doc/chart-json-spec.md:147-243` 的映射逐项一致 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完；本部分无 `.md`，文档一致性以 `doc/chart-json-spec.md` 对应小节（147/323/756/906/1188/1550/1701/1957/2025/2043/2297）作对照 |

### 第 31 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 6（#1 配置失效、#2 负宽矩形、#3 颜色未校验、#4 环漏检、#5 基线越界、#6 刻度越界）；设计 1（#16 类型跨图复用）；可读性 1（手工下标计数器 `nodeIndex++`/`rowIndex++` 等在 8 个文件重复，归入 #11 的"小工具重复"表述，不单列）；语言特性 0（`Option` 全部有显式分支、`Array`/`ArrayList` 语义正确、无强制解包）；安全性 0（属性/文本转义由 `SvgWriter` 负责，`series[].color` 只产生非法属性值、不构成注入，见 #3） |
| §1 死代码 | 2 | ①`OfflineFlameChart.cj:177-179,193-195` 两处 `depth > total` 不可达（#7）。②`NodeLinkChart.cj:196-202` 的 `placeManual` 中 `case None => 0.0` 两处分支不可达——`:97-104` 已对 `layout == "manual"` 缺 `x`/`y` 抛 `MissingField`，`:138-139` 又保证只有 manual 才进 `placeManual`，故 `manualX/manualY` 必为 `Some`。②与 #7 同类（"结构与上游校验已排除的分支"），位置单列、不另计严重度。其余机械核对：15 个 `internal` 类型（`LinePoint/LinePixel/LineSeries/LollipopSeries/ManhattanPoint/MosaicSeries/NetworkHeatmapNode/NodeLinkNode/NodeLinkEdge/NomogramVariable/NomogramRisk/OfflineFlameNode/OrgNode/OrgSlotCursor/PairedItem`）逐个全仓搜引用，均有调用者（`LineSeries` 仅本文件用，非死代码）；10 个 `internal` 函数（`lineRange/nodeLinkWidth/manhattanPositions/mosaicColumnTotals/nomogramPosition/orgFitLabel/orgAssignDepth/orgAssignSlots/orgLayout/findOrgNode`）均有非测试调用者，`chromosomeIndexOf` 亦在 `draw` 内使用；`private` 函数逐个确认被本文件调用（`LineChart` 10 个、`NodeLinkChart` 5 个、`OfflineFlameChart` 5 个、`NomogramChart` 3 个）；`return`/`continue` 后无同层语句；10 个图的 `import` 逐条核对无未使用（`OrgChart.cj` 未 `import std.math` 但用 `maxFloat`，与同模块 `AreaChart`/`ErrorBarChart`/`ResidualChart` 同写法且模块已有编译产物，按隐式导入处理，不作问题） |
| §2 重复逻辑 | 5 | #8（图例名/色）、#9（染色体顺序）、#10（id 去重+查找）、#11（字宽/`maxFloat`/数值读取）、#1（头部绘制与 `ChartFrame` 并存）。已两两比对：本部分 10 张图的 `draw` 主体（解析→校验→比例尺→builder→绘制）形态相似但数据结构、校验规则、图元序列各不相同，不判重复；测试文件里的 `draw()`/`count()` 辅助按检查表属"测试准备代码"，不判 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}` 静默吞异常（20 个文件 `grep -n "catch"` 零命中）；`public init() {}` 是 `Chart` 实现的无状态构造，接口无成员要求初始化，属合理空构造；`NomogramChart.drawName` 等小函数均有实际绘制行为。`NomogramChart` 的 `points` 只读不用归入 #13（§14），不算空实现 |
| §4 栈溢出 | 2 | `OfflineFlameChart.cj:176-215`（`validateValues`/`assignDepth`/`layoutNode`/`drawNode` 四段递归）与 `OrgChart.cj:218-238`（`orgAssignDepth`/`orgAssignSlots`）的递归深度均等于树深，只由 `nodes` 条数约束，无常量上限（#7 已指出 `depth > total` 那层保护不可达）。因单帧只含少量标量、达到溢出所需深度（万级链）未实测，按证据分级不判严重；建议给 `nodes` 条数设上限或改显式栈（设计变更，未列入优化方案） |
| §5 OOM | 0 | 逐个文件核对：无按报文长度 `Array(n, repeat:)` 预分配（`cellWidth/cellHeight/rowHeight` 均为除法）；无全局/静态容器（`CHART_DEFAULT_PALETTE` 为常量）；无缓存；`MosaicChart` 的 `valuesMatrix` 与 `ManhattanChart` 的 `xs/chromosomes/positions` 都是 O(n) 且随函数结束释放，峰值 ≈ 输入 JSON 的常数倍；唯一的"无界"是大点数导致的线性增长，属输入规模问题，已列入待验证假设 #3 |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile / bench 数据（`scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`，与图表渲染无关）。力导向、id 查找、颜色解析、曼哈顿数组复制四条线索全部降级为「优化可行性方案（无基线）」+「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件 `synchronized`/`Mutex`/`ReentrantLock` 零命中，无锁 |
| §6.3 并发串行 | 0 | `spawn`/`Future`/线程池零命中；`Chart` 为纯函数式 `draw`，无内部并发 |
| §6.4 低效算法 | 0（转为方案） | 命中形态 5 处（力导向 O(80·N²)、`findNode` O(E·N)、id 去重 O(n²)、染色体 `contains`+线性回查 O(n·c)、每格重复解析颜色），但缺"实际耗时占比"，按检查表要求不计为发现，全部写入「优化可行性方案」的 CPU 三条（O1/O2/O3）与待验证假设 #1/#2/#4 |
| §7 降堆内存方案 | 1 | 只有 `ManhattanChart` 的四份数组可合并（方案 O4）；其余图的对象数 ≈ 图元数，无中间副本可删。`clear()`/`gc()` 类假象未出现在本部分 |
| §8 降 CPU 方案 | 3 | 力导向索引化、id 查找索引化、颜色预解析（O1/O2/O3）；均为无基线待验证 |
| §9 local mode 可行性 | 1 | 已按 5 条约束逐条评估（逃逸 / 接口 mode 重载 / local region 上限 / 数据口径 / 实验特性），结论"不推荐、需先做局部峰值对照"，未写成优化建议 |
| §11 现有代码的 BUG（存量） | 13 | 16 条发现中属"读到的现有代码缺陷"的是 #1～#7、#9、#11～#15（#8/#10/#16 是重复逻辑与设计问题，已计入 §2 / §10 行）。已逐条核对：边界（空数组、单元素、负值、越界坐标、未命中下标返回 `-1`）、空值（`Option` 分支全覆盖，无强制解包）、错误处理（无 `catch`，错误均带 `path`）、资源（无文件/句柄/原生内存）、并发（无共享状态）、契约（对照 `chart-json-spec.md` §7 校验表逐条比对） |
| §12 并发安全与锁粒度 | 0 | 每张图的全部状态都是 `draw` 内的局部对象（`ArrayList`/`Array`/值类型 `ChartConfig`），无字段级共享；`public class XxxChart <: Chart` 无成员变量，`draw` 可被多线程并发调用（每个调用独立分配），线程封闭可证明；`ChartTheme.palette` 是 `var` 但只在 `parse` 期写入后只读，无发布后写入 |
| §14 功能完备性与 README 覆盖 | 4 | #1（`legend.*`/`title.subtext` 失效）、#13（`points` 未接）、#12（空 `links` 未校验）、#5（`yAxis.min>0` 与"茎从 0 基线起"互斥）。README 覆盖正向核对：10 个公开类名在 `f_chart/README.md` 与 `README_en.md` 各命中 1 次，在 `doc/chart-json-spec.md`/`doc/f_chart模块设计.md`/`doc/spec/` 合计命中 4–13 次，无"公开 API 未文档化"；10 个测试文件均存在且被 `files/` 清单收录 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 行全部读完（4551 行）；本部分无 `.md`，§13 的文档侧判定改由「代码 ↔ `doc/chart-json-spec.md`」对照完成，命中 6 条（#1、#3、#6、#12、#13、#15） |

### 第 32 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#2 #3 #4；设计：`PdpChart` 复用 `LiftChart`/`VolcanoChart` 的 helper（命名与归属不符，已在 #9 建议中提及）；语言特性 / 可读性：无额外命中；安全性：`pictogram.icon` 原样进入 `d` 属性但由 `SvgWriter` 转义（`SvgAuthoringBuilder.cj:255-259`），无注入 |
| §1 死代码 | 1 | `PieSlice.value`、`ParallelSeriesData.name` 只写不读（#8）；已逐个核对本部分全部 `internal` / `private` 符号：`parallelNormalize`、`paretoOrder`、`paretoCumulative`、`pictogramCount`、`pictogramIconPath`、`pieFractions`、`formatPercent`、`qqTheoryQuantiles`、`normalQuantile`、`qqFitLine` 均有调用者（含跨文件），`resolveYRange` / `sortPoints` / `sortValues` / `resolveRange` 均为本文件内被调用；`public class *Chart` 属对外 API，不判 |
| §2 重复逻辑 | 4 | #7 QQ/Probability 整段复制、#9 插入排序 9 处、#10 测试 helper 106 份、#12 同一错误文案两处；另已核对 `PercentBarChart` 与 `PercentStackedBarChart` 为文档声明的别名（`doc/spec/add-f-chart-percent-bar/design.md:9`），不算缺陷 |
| §3 空实现 | 1 | #11 未知 icon 静默降级为 path；本部分无空函数体、无 `TODO`/`FIXME`，无 `catch {}` 吞异常 |
| §4 栈溢出 | 0 | 本部分无递归（`normalQuantile` 为多项式逼近、`qqFitLine`/排序均为迭代）；无自引用结构遍历 |
| §5 OOM | 1 | #1 图标数按 `value/unit` 无界放大；其余图表的容器规模均与输入数组长度同阶，未见按报文字段预分配 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，热点结论不成立，已列入「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池使用 |
| §6.4 低效算法 | 0 | 插入排序 O(n²) 是大 n 下的疑点，但无耗时数据，降级进「待验证假设」#1；`paretoOrder` 之外的复杂度均为 O(n·m) 且与输入同阶 |
| §7 降堆内存方案 | 2 | 排序双拷贝、平行坐标行复制（均标注 `无基线`） |
| §8 降 CPU 方案 | 1 | `normalQuantile` 系数数组提升为常量（`无基线`）；测试 `count` 的 `needle.toArray()` 并入 #10 |
| §9 local mode 可行性 | 0 | 不适用：`docs/LocalMode.md:442` 已判定 f_chart「SVG DOM → toSvgString 是最大临时区，但要 local 化必须先全链 local 化 f_svg/f_xml，且 Chart.draw 是接口实现，当前不做」；`docs/LocalMode-O2-Plan.md:124` 亦判定 f_chart 小对象收益为负。无峰值内存前后数据，不提出改造 |
| §11 现有代码的 BUG（存量） | 3 | #2 单扇区弧退化、#3 画布无下限导致负半径/反转、#4 x 轴镜像；已逐函数核对边界（空数组、单元素、全零、负值、NaN 输入路径），其余分支均有显式校验 |
| §12 并发安全与锁粒度 | 0 | 本部分每个 `*Chart` 都是无字段（仅 `init() {}`）的纯函数式 `draw`，全部状态为局部变量；已确认模块内无全局 `var` / 静态可变成员、`chartTextWidth` 等 helper 无缓存表，故无共享可变状态 |
| §14 功能完备性与 README 覆盖 | 2 | #5 `cumulativeFormat`、#6 `pie.innerRadius` 均"文档承诺、实现未接线"；其余公开类型（`PercentBarChart`、`PercentStackedBarChart`、`PictogramChart`、`PieChart`、`PrChart`、`ProbabilityChart`、`QQChart`、`ParetoChart`、`PdpChart`、`ParallelCoordinatesChart`）在 `README.md` 与 `doc/chart-json-spec.md` 均有条目 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单无 `.md`；文档侧只做了与实现对齐的抽查（`doc/chart-json-spec.md:1248`、`:1615`、`:1729`），`doc/**` 的成篇审查归其他部分 |

### 第 33 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：x 轴镜像、对角线错配、桑基越界；设计：3 处手绘标题绕过 `ChartFrame`、散点矩阵无图例；语言特性：`Option` 均用 `match` 显式展开，未发现静默丢弃；安全性：本部分所有数值经 `formatSvgNumber`、所有文本经 `ChartSvgKit.text → SvgBuilder.text`（`f_svg/src/SvgAuthoringBuilder.cj:186` 注明「转义由 `SvgWriter` 负责」），无手拼属性/文本，未发现注入面 |
| §1 死代码 | 1 | 已逐个检查 `private`（`parseIndicators`/`parseSeries`/`radarPoint`/`polygonPath`/`drawCloud`/`drawBox`/`residualRange`/`resolveXRange`/`sortPoints`/`resolveRange`/`indexOfNode`/`parsePoints`/`resolveXRange`/`resolveYRange` = 14 个）与 `internal`（`clamp01`/`sortRaincloud`/`ridgeAmplitude`/`roseRadius`/`sankeyLayers`/`residualXRange`/`residualYRange`/`columnRange` = 8 个）全部有调用者（全仓 `grep -w`，排除 `.worktrees`）；命中 1 条：`MatrixSeriesData.name` 读了不用。`public` 图表类对外可达，不判 |
| §2 重复逻辑 | 3 | 已两两比对 20 个文件里 40 余个函数体的「输入-输出-副作用」：命中数值轴前置样板（含 47 处 `xLabelHeight`）、插入排序 4 份、路径 `M/L` 拼接 6 处；测试辅助 `draw/count` 11 份计入 #13 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`、无 `catch (_:Exception){}`；`case None => ()` 均为可选字段正常缺失（`bandwidth`/`auc`/`color`），`case "none" => ()` 是 symbol 关闭的显式无操作 |
| §4 栈溢出 | 0 | 本部分无递归：`sankeyLayers` 是「外层 `nodeCount` 轮 + 内层边数」的双层循环（`SankeyChart.cj:284-296`），深度恒定，无自引用结构遍历 |
| §5 OOM | 0 | 未发现按不可信长度预分配或无界容器：所有集合长度均与输入数组同阶，绘制结束即释放；`SvgBuilder` 全量拼串是 SVG 输出的固有形态，未按 §5 判缺陷（降内存方案见优化方案） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/bench 数据，热点不成立；已把核密度采样、`indexOfNode`、插入排序、路径拼接 4 项列入待验证假设 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`draw` 内所有状态均为局部变量，无 `synchronized`/`Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池调用 |
| §6.4 低效算法 | 2 | 静态复杂度可判的两处：插入排序 O(n²)（4 份，见 #8）、桑基 `indexOfNode` 线性查找 × 每链接 2 次（O(n·m)，见 #5 描述与待验证假设 #2）；`ScatterMatrixChart.cj:116` 的循环内 `toArray()` 计入优化方案。均未给「已变热点」的结论 |
| §7 降堆内存方案 | 1 | 中间 `ArrayList`/`toArray` 副本，证据状态 `无基线` |
| §8 降 CPU 方案 | 1 | 排序与路径拼接收敛，证据状态 `无基线` |
| §9 local mode 可行性 | 0 | 各 `draw` 的临时对象（`points`/`densities`/`StringBuilder`）生命周期确实限于函数内，但 `draw` 返回的 `String` 与 `JsonObject` 入参逃逸，且没有峰值内存数据，按 checklist §9「没有前后峰值数据只能是待验证假设」未列为方案 |
| §11 现有代码的 BUG（存量） | 6 | 已核对本部分所有边界：空数组（`series`/`data`/`nodes`/`links`）、单元素数组（`boxScatterBounds` 在 n=1 时返回全同值，`GaussianKde` 用 `defaultBandwidth` 兜底）、除零（`maxValue`/`maxFlow`/`span` 均有兜底）、`Option` 展开；命中 x 轴镜像、对角线错配、图例配置被忽略、小画布静默空图、桑基越界、空 `data` 契约漂移 |
| §12 并发安全与锁粒度 | 0 | 本部分无全局 `var`、无静态可变字段、无单例：`SankeyNode` 的 `var layer/throughput/x/y/height` 是每次 `draw` 内新建的局部图元，无跨线程共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | 本部分无 `.md`，无法做文档对照（模块 README 在其他部分）；命中：散点矩阵无图例（`name` 未接线）、`RadarChart` 的 `legend.show` 配置未接线 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分无 `.md`，§13 不适用 |

### 第 34 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 9 条（#1 / #3 / #4 / #5 / #6 / #10 / #12 / #13 / #15），#2 属 §14.1、#14 属 §13；设计上 `draw` 统一走 `ChartConfig.parse` + `ChartSvgKit`，分层正常；语言特性使用 `Option`/`match` 惯用，未发现 `mut` 误用；文本均经 `kit.text → SvgBuilder` 转义（`f_svg/src/SvgElement.cj:705-716`），本部分无注入面 |
| §1 死代码 | 3 | 逐个核对本部分 20 个 internal 类型/函数（`Participant`、`SequenceMessage`、`ShapContribution`、`shapOrder`、`SlopeSeries`、`SpiralDatum`、`spiralPoint`、`StackedAreaSeries`、`groupIndexesOf`、`uniqueGroupCount`、`stackedAreaBounds`、`StemLeafRow`、`stemLeafRows`、`StreamSeries`、`streamBaseline`、`SunburstNode`、`sunburstArcPath`、`SurvivalPoint`、`SurvivalSeries`、`survivalConfidence`）全仓引用，均有调用者；`public` 类 `SequenceChart` 等对外可达不判；命中 3 处不可达判定：`SunburstChart.cj:151`、`:179` 两处 `depth > total`（发现 #3）与 `:201` 的 `total <= 0.0`（叶子 total 已校验 > 0），后两处并入 #3 |
| §2 重复逻辑 | 3 | 同文件两两比对 10 个源文件共 31 个函数体：`StackedAreaChart` 的分组/颜色重复（#9）、`StemLeafChart` 三重复制校验（#7）、跨文件排序/去重原语重复（#8）；另核对 10 个测试文件的 `draw`/`count` 辅助函数与 47 个文件里的同一 `labelRotate` 判定片段，测试准备代码属误报边界，布局片段已并入 #8 的统计口径但不单独计条 |
| §3 空实现 | 0 | 20 个文件无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`StackedBarChart.draw` 是单行委托（非空实现） |
| §4 栈溢出 | 1 | 旭日图 4 个递归函数（`resolveTotals`/`sortChildren`/`assignAngles`/`drawNode`）深度 = 树高，上界为 `nodes.size - 1`（无固定常量）；按 n=5000 深链估算约 5000 帧，实际溢出阈值需实测（待验证假设 #7）；其余 9 个图无递归 |
| §5 OOM | 0 | 无全局容器、无缓存、无按报文头预分配；所有数组长度来自已解析的 `series[].data`（`Array` 长度即输入规模），`StackedArea` 的 `2SC` 与 `StemLeaf` 的 3 副本属"可优化"而非 OOM 面（已量化为优化方案） |
| §6.1 热点瓶颈 | 0 | 本轮无 bench/profile 数据，未把任何"看起来慢"的路径写成缺陷；全部候选进「待验证假设」并注明采集方式（#1–#3 为 CPU，#4–#5 为内存/分配，#6–#7 为 local mode 与栈深度） |
| §6.2 大粒度锁 | 0 | 20 个文件无 `synchronized`/`Mutex`/原子操作 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无批次提交 |
| §6.4 低效算法 | 4 | 已计入发现 #8（O(n²) 去重/线性查找/插入排序）与优化方案（`Streamgraph` O(S²C)、`Sunburst` O(n²)、螺旋 2n 次三角函数）；因缺占比数据，性能结论不写成缺陷 |
| §7 降堆内存方案 | 2 | `StackedArea` 层数组、`StemLeaf` 三副本，均标注 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | `Streamgraph` 前缀和、`Sunburst` 哈希索引、`Spiral` 单遍计算；均标注 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | `draw` 内确有大量短生命周期临时对象，但无改前/改后峰值内存数据，且 `draw` 返回 `String`、临时对象生命周期跨越整个函数；只能列为待验证假设 #6，不写成方案 |
| §11 现有代码的 BUG（存量） | 17 | 本部分 20 个文件的边界、空值、错误路径、布局、契约逐条核对；17 条全部为存量（工作区快照，无 diff） |
| §12 并发安全与锁粒度 | 0 | 10 个 `Chart` 实现均为无状态类（仅 `init()`，无成员字段），`SunburstNode` 等可变对象都是 `draw` 内局部构造，不跨线程共享；无共享路径可指，故不判不安全 |
| §14 功能完备性与 README 覆盖 | 4 | 10 个图类型在 `README.md` / `README_en.md` / `doc/chart-json-spec.md` 均已登记（逐个 grep 命中）；命中 3 条承诺缺失：`sequence` 的 `async`（#2）、`stem-leaf` 的自动换列（#5）、通用 `title.subtext` 对 `spiral`/`stem-leaf` 失效（#11）；另 1 条 §13 文档漂移：SHAP 的 `features` 字段被实现忽略（#14） |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_chart.part34.txt` 一一对应，无遗漏；`chart-json-spec.md` / `README.md` 仅作承诺源交叉核对，不计入本部分文件数 |

### 第 35 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：treemap 面积切分、volcano y 翻转、treemap 环/缺值静默；设计：`leafIndex` 实例状态破坏纯函数契约；可读性：标题/图例绕过 ChartFrame、泳道名不截断。安全性：本部分只把数字/字符串写进 SVG，转义由 `f_svg` 负责，未发现注入面 |
| §1 死代码 | 1 | 逐个 `private`/`internal` 符号全仓搜引用：`swarmOffsets`(7)、`findSwimLane`(2)、`findSwimNode`(5)、`eventColor`(3)、`nodeValue`(5)、`sortChildren`(8)、`quantileSorted`(7)、`volcanoNumber/Category/LabelText`、`waffleCellCounts`、`waterfallSpan/Bounds/Color` 均有调用者；`treemapWeights` 仅 `TreemapChart_test.cj:66` 使用，属「仅测试使用」→ 只记可见性信息（internal 已是测试可达的最小可见性），不算死代码；`return` 后无同层语句；命中项为 2 处未使用通配 import（轻微 #1） |
| §2 重复逻辑 | 3 | 已把 9 个源文件与 9 个测试文件的函数体压成「输入→输出→副作用」两两比对：命中 parseValues/resolveYRange/sortValues 三函数逐字节复制（一般 #6）、violin/violin-box 轮廓块逐字节复制（一般 #7）、标题与图例自绘（一般 #5）；`WaterfallAlias_test` 已核对为设计约定不计；`kit.*` 薄封装属刻意分层，不算重复 |
| §3 空实现 | 0 | 逐个 `catch` / 空分支检查：本部分无 `catch`，无空函数体，无 TODO；`case None => ()` 均为可选字段正常缺省；`peak <= 0` / `total <= 0` 的提前返回有语义（分别为无密度、无值），但后者静默丢叶已并入一般 #2 |
| §4 栈溢出 | 1 | treemap 的 `layoutNode`/`nodeValue`/`sortChildren` 递归深度＝输入父子链长度、无上限、无环检测（严重 #3）；其余图均为单层循环，无自引用结构 |
| §5 OOM | 1 | waffle `cells` 放大（一般 #4，已量化 140 B/格）；其余图为「输入元素数 ↔ 输出元素数」同阶（1 点 1 图元），无全量物化、无按报文头预分配、无全局容器 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 cjprof/bench 数据，`sortValues`、`nodeValue`、逐点 SVG 三条线索全部降级为待验证假设 #1/#2/#3，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享容器；`ChartSvgKit`/`ChartFrame` 均为每次 `draw` 新建对象 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 Future、无线程池 |
| §6.4 低效算法 | 2 | 插入排序 O(n²)（`sortValues` ×4）与 id 线性查找 O(n²) 已进「优化可行性方案（无基线）」；treemap 面积切分属算法错误，记在严重 #1 |
| §7 降堆内存方案 | 1 | 逐点 `<g>` 合并为 path（优化方案 [堆内存]，无基线）；`ArrayList→Array` 副本可去 |
| §8 降 CPU 方案 | 2 | 排序复杂度、id 索引（均无基线）；无 profile 数据故不进修复清单 |
| §9 local mode 可行性 | 0 | 本部分临时对象是「每组一个 `ArrayList` + 每采样一个 `Float64`」，峰值远小于 JSON/SVG 缓冲；且 `Chart` 契约要求返回 `String`（逃逸），local region 无收益面，不成立 |
| §11 现有代码的 BUG（存量） | 6 | 已核对边界/空值/错误处理：treemap 面积（严重 #1）、timeline hash 溢出（严重 #2）、treemap 递归（严重 #3）、`leafIndex` 契约（一般 #1）、treemap 环与缺值（一般 #2）、volcano y 翻转（一般 #3）；其余边界（空 series、空组、标签长度、负值、带宽 0、除零）均有显式校验，`chartNiceTicks` 有 1000 次上限与 NaN/Inf 保护 |
| §12 并发安全与锁粒度 | 1 | 唯一共享可变状态是 `TreemapChart.leafIndex`（一般 #1）；其余 Chart 实现为「每次 draw 全局部变量」，无静态/全局可变状态，无锁 |
| §14 功能完备性与 README 覆盖 | 2 | `tiling: slice` 未实现（一般 #8）；treemap 忽略 `title.subtext`/`title.align`（一般 #5）；`group`、`showBox`、`showOutliers`、`bandwidth`、`cells`、`columns`、`direction`、`orientation` 等文档字段均已接线 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单只有 `.cj`，无 `.md`；文档一致性用范围外 `README.md`/`doc/chart-json-spec.md` 作承诺源交叉核对（见范围外提示） |

**范围外提示**（只记一句，未展开、不计入统计）：
1. `doc/chart-json-spec.md:838` 写 `jitter`「默认自动」，`SwarmChart.cj:101` 实为固定 `0.3`。
2. `README.md:2427` 称时间线「事件按时间排布」，`TimelineChart.cj` 从不解析 `date`、按数组下标等距放置（乱序输入时图上时序错乱，是否要求调用方预排序待确认）。
3. `ChartFrame.drawYAxis`（`ChartFrame.cj:168-202`）把 `chartNiceTicks` 超出数据范围的刻度照样画出，已入库 SVG 里出现画布外刻度（M020 `200` 在 y=-69、M092 `0` 在 y=-5.8）。
4. 同一「y 轴翻转」写法还出现在 `BlandAltmanChart.cj:149`、`CalibrationChart.cj:130`、`EcdfChart.cj:145`、`GainChart.cj:126`、`LassoPathChart.cj:157`，应由对应部分统一复核。

### 第 36 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：负值丢弃、跨轴共尺、`-90` 溢出、画布无上限、孤立 ESC 死循环；可读性：#12 与 #7/#8 的命名不统一（`clampTuiRow` vs `clampWordCoordinate`）；设计：渲染器职责清晰（parse→frame→draw 三段），但 `TuiBarRenderer.canvas` 单函数 100 行、`TuiComboChart.draw` 140 行，属可读性偏弱未单列；语言特性：`Option<?Float64>` 全部 `match` 展开，无 `getOrThrow` 滥用，`ArrayList` 索引赋值合法；安全性：所有文本经 `ChartSvgKit.text → SvgBuilder.text`、颜色经 `SvgColor.parse` 校验（`TuiColor.cj:30`），无手拼属性，未发现注入面；资源：本部分无文件句柄/原生内存，全部 GC 托管 |
| §1 死代码 | 1 | 已逐个搜索：`private`（`markContinuation`、`findWordNode`、`placeWordRing`、`runWordForce`、`clampWordCoordinate`、`drawSideBySide`、`drawStacked`、`isPercent`、`drawLines`、`isSupportedComboKind`、`buildBarSlots`、`drawBars`、`drawOverlays`、`buildCanvas`）全部有调用者；`internal` 顶层函数 21 个（`tuiSeriesColor`/`tuiResolveLabels`/`tuiValueRange`/`tuiTicks`/`tuiTickLabelWidth`/`tuiLegendVisible`/`tuiSeriesSymbol`/`tuiFillColumn`/`tuiMinInt64`/`tuiMaxInt64`/`tuiAnsiReset`/`tuiAnsiForeground`/`tuiContrastColor`/`tuiStripAnsi`/`tuiPlainLines`/`clampTuiRow`/`clampTuiColumn`/`wordCloudFontSize`/`wordCloudOrder`/`wordNetworkRadius`/`wordNetworkRingPoint`）在 `f_chart` 内均有引用（`tuiStripAnsi`/`tuiPlainLines` 仅测试 → 可见性建议，不判死代码）；`public` 图表类与 `TuiCellChart` 接口对外可达，不判。命中 1 条：`TuiBarSeries.stack` 读了不用 |
| §2 重复逻辑 | 3 | 已两两比对 20 个文件里 40 余个函数体的「输入-输出-副作用」：命中堆叠累积两份（#6）、系列长度校验三份 + 图例收集四份（#7）、区间夹取四份（#8）；另核对 `cellSymbols`/`plainLines`/`render` 三种输出形态不构成重复，测试辅助 `draw`/`count` 属误报边界（刻意展开的测试准备代码），未计 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`、无 `catch (_: Exception) {}`；`catch` 仅 `TuiColor.cj:32`（转抛 `chartInvalidValue`）与 `TuiColor.cj:49`（颜色无法解析时兜底返回 `#ffffff`，函数注释已说明其用途是保证标签可读）；`case None => ()` 均为可选字段正常缺失（`axis.min/max`、`?Float64` 数据点、`rotate` 缺省） |
| §4 栈溢出 | 0 | 本部分无递归：`wordCloudOrder` 是双层 `while` 插入排序（`WordCloudChart.cj:202-210`）、`runWordForce` 是固定 80 轮的双层循环（`WordNetworkChart.cj:199-234`）、`drawLine` 是 Bresenham `while(true)` 但每步必推进 `currentX/currentY` 且坐标已 clamp（`TuiCanvas.cj:126-140`），均无深度随输入增长的调用链 |
| §5 OOM | 1 | 命中画布尺寸无上限（#3）。其余集合（`words`/`nodes`/`links`/`series`/`cells` 行数组）长度均与输入同阶，绘制结束即释放；`tuiTicks` 返回的 `axis.values` 也无条数上限（`ChartConfig.cj:82` 整段读入，`ChartConfig.cj:85-87` 只把 `tickCount` 抬到 ≥ 2），但内存量级远小于画布、且为一次性数组，未单独成条 |
| §6.1 热点瓶颈 | 0 | `scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`（通用），未提供本模块 profile/bench；热点不成立，已把力导向查找、插入排序、画布分配 3 项列入待验证假设（另 1 项核实柱状图参数分布） |
| §6.2 大粒度锁 | 0 | 本部分无锁：无 `synchronized`/`Mutex`/`Atomic`，所有状态是 `draw` 内的局部对象 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/通道；本部分 9 个 `draw`（词云、词网络、bar/grouped/stacked/percent-stacked/line/scatter/combo）与 2 个 `drawCells` 均为同步纯计算 |
| §6.4 低效算法 | 2 | 静态复杂度可判的两处：插入排序 O(n²)（`WordCloudChart.cj:197-212`）、力导向里 `O(80·L·N)` 的线性查找（`WordNetworkChart.cj:199-227`）；二者均无耗时数据，只进「优化可行性方案（CPU）」与待验证假设，不按缺陷统计 |
| §7 降堆内存方案 | 1 | `TuiCanvas` 的 `ArrayList → toArray` 中转，证据状态 `无基线` |
| §8 降 CPU 方案 | 2 | 词网络索引化、词云排序换 `std.sort`，证据状态均 `无基线` |
| §9 local mode 可行性 | 0 | 本部分唯一函数内大对象是 `TuiCanvas.cells`（`TuiCell` 网格）：逃逸检查通过（只被 `TuiCanvas` 持有，`TuiCanvas` 在 `canvas()/draw()` 内结束生命周期，不返回、不入成员/全局），理论上可做 local region；但 `TuiCell` 是可变引用类型（`var symbol/color/continuation`），需要 local 构造函数与 `split` 级工具链支持，且没有峰值内存前后对照 —— 按 checklist §9「没有前后峰值数据只能是待验证假设」，未列为方案，也不进待验证假设表（缺的是改造前置条件而非测量项） |
| §11 现有代码的 BUG（存量） | 5 | 已核对本部分所有边界：空 `series`/`data`/`words`/`nodes`（均有 `InvalidValue`/`MissingField`）、单元素（`nodes[0].weight`、`ordered[0].weight` 前已校验非空）、除零（`maxWeight-maxWeight`、`maxValue<=0`、`palette` 空、`positive<=0`、`slotWidth` 均有兜底或分支）、`Option` 展开、`clamp` 上下界（`plot` 至少 1×1 由 `TuiFrame.cj:103-105` 保证）；命中负值丢弃、跨轴共尺、画布无上限、孤立 ESC、`-90` 溢出 |
| §12 并发安全与锁粒度 | 0 | 无全局 `var`、无静态可变字段、无单例、无注册表：`WordNetworkNode` 的 `var x/y`、`TuiCell` 的 `var symbol/color/continuation` 都是每次 `draw` 内新建的局部图元，无线程共享路径；`TuiBarRenderer`/`TuiCanvas` 等无字段状态（`static func` 只做纯计算），按「线程封闭」判安全 |
| §14 功能完备性与 README 覆盖 | 2 | 本部分无 `.md`，无法做 README 对照（模块 README/doc 在其他部分）；命中：`TuiBarSeries.stack` 接线缺失（#9）、`TuiCellChart` 只有 `TuiBarChart`/`TuiLineChart` 两个实现（`grep` 确认，其余 TUI 图只能走 ANSI）。后者无承诺源（接口注释只说宿主需要时可用），未按缺陷计，仅记录为信息 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分无 `.md`，§13 不适用 |

### 第 37 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 #2（环静默丢弃）、#1（尺寸边界）；安全性 #4（控制字符）；设计 #5（双实现）；可读性/语言特性并入 #7 #8 #9 |
| §1 死代码 | 2 | 已逐个符号搜引用：`TuiFlameBox`/`TuiPoint`/`TuiPointSeries`/`TuiRect` 主体、`TuiFrame` 全部私有方法均有调用；命中 `tuiPadRight`、`TuiRect.centerX/centerY`（本包无引用）+ 未用 import。`public` 的 `TuiFlameChart` 对外可达，不判 |
| §2 重复逻辑 | 2 | 已两两比对本部分 6 个实现的函数体摘要：命中 `TuiFlameChart` 与 `FlameChart`（SVG）解析/校验整段复制、两个测试文件 `count` 复制；`tuiPadLeft`/`tuiPadRight` 仅 append 顺序不同，已并入死代码条目（右侧版本无调用者），未单列 |
| §3 空实现 | 0 | 无空函数体、无 TODO/FIXME；`TuiPointCommon.cj:110` 的 `case None => ()` 是可选 `y` 缺失的合法分支（缺失即断线，有 `breaksOnNull` 用例），不是吞错；`tuiContrastColor` 的 `catch` 有显式降级并与注释一致（该文件不在本部分） |
| §4 栈溢出 | 1 | 见 #3；`validateTree`/`assignDepth`/`layoutNode` 三处递归均无常量上限，已给出可达深度推导（= 输入链长） |
| §5 OOM | 1 | 见 #1；本部分唯一无界分配点是 `width × height` 画布（`boxes` 数量上界为 `nodes.size`，受 #1 同一尺寸/数量约束） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 的已有资料只有 `docs/LocalMode*.md`），热点结论不成立，已转「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁、无共享状态 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/队列，纯同步计算 |
| §6.4 低效算法 | 2 | 线性查找 O(n²)（已写入 CPU 方案）、`needle.toArray()` 在循环内重复分配（并入 #12）；均已按「无基线只能待验证」处理，不作为缺陷统计 |
| §7 降堆内存方案 | 1 | `TuiCanvas` 逐格对象 → 平行数组 / `struct`，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 节点装配 O(n²) → `HashMap`，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内用完且不逃逸」的大缓冲区：`TuiCanvas` 格子数组作为返回值逃逸，`FlameNode` 树虽在 `draw` 内建完即弃但含 `var` 字段（非 `Copyable`，需 local 构造 + mode 重载），且缺峰值内存基线；按 checklist §9 只能列待验证，不写成方案 |
| §11 现有代码的 BUG（存量） | 4 | #1 #2 #3 #4 均为存量；已核对的边界：空 `nodes`（`:101-103` 抛）、`parent: null` 与缺省（`:123-133` 同义）、`value <= 0`（`:135-137`）、子节点和超父值（`:180-184`）、`maxDepth + 1` 恒 ≥ 1（`:65-76`）、`configuredRows` 为 0 时回落 `fitRows`（`:81-86`）、`drawBox` 的 `right <= left`/`bottom < top` 早退（`:253-255`）、`TuiFrame` 行号与 `height` 自洽（`:93-119` 已逐分支推导） |
| §12 并发安全与锁粒度 | 0 | 本部分所有类型都是 `draw` 内新建的局部对象，无 static/全局/单例/注册表；`Chart` 契约要求纯函数语义（`Chart.cj:24-25`），无共享可变状态可竞争 |
| §14 功能完备性与 README 覆盖 | 1 | `TuiFlameChart` 与 `doc/f_chart模块设计.md:291` 登记一致；本部分无 README/`doc/**`。仅提示（范围外）：`fprobe/src/tui/ChartPanel.cj:84-87` 的 TUI 分发未接火焰图 |
| 文件覆盖（§13 等） | 13/13 | 与 `files/f_chart.part37.txt` 一一对应，无遗漏、无未读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 19 |
| 一般 | 192 |
| 轻微 | 243 |
| 其中存量 | 440 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只覆盖 `f_chart/README.md`（3159 行），它是整个模块的对外契约：接口签名、错误语义、公共字段、M1–M106 的 JSON 结构与 TUI 子包说明。**文档主体质量高**——里程碑与实现一一对应，示例里的每个 `type` 字符串在 `src/` 都有入口，版本号、依赖树、默认画布/内边距/图例开关、TUI 尺寸下限、样例文件数量等可机械核对的项全部对得上，说明作者在持续维护这份 README。

风险集中在"描述得比实现更聪明"：

- 一般项 **#1**：M19 箱线图声称按 1.5 IQR 求须与异常点，实际只画入参五数，真正的 1.5 IQR 在 `box-scatter` / `violin-box`。这会直接影响使用者是否自己算栅栏，建议优先改文案并加交叉引用。
- 一般项 **#2**：`Chart` 接口 KDoc 只承诺 SVG，8 个 TUI 类却返回 ANSI，而 README 说它们可"按统一接口替换或注入"。接口契约层面的不一致，需在"改 KDoc"与"拆接口"之间做一次决策。
- 轻微项 **#3 / #4** 属"索引级"错误：两个数据形状代号互换、末尾公开 API 清单在 EOF 处半截，修正成本极低，但会直接影响读者写对 JSON 与查找 API。
- 轻微项 **#5–#9** 属陈旧与过度承诺：测试计数与源码注解差 5 条（全在 TUI）、`InvalidJson` 无抛出点、"任何数值问题都会抛"对 `path` 不成立、`legendTextColor` 未进字段表、`.tui.txt` 是否含 ANSI 在同一文档里自相矛盾（实测含真彩序列）。改动都是几行文字。

本部分没有任何 `.cj`，因此**图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、并发安全**这些专项未在本轮取证，不能据此对模块整体下结论；它们由包含 `src/**` 的其余 36 个子轮负责。

存量缺陷共 9 条（一般 2 / 轻微 7），是否纳入修复待用户决定；本报告只读文件，未做任何修改。

**第 2 部分**：`README_en.md` 的**结构与覆盖度扎实**：3156 行、139 个标题与中文版逐节对齐，102 个实现文件与 102 条附录条目一一对应，110 个 JSON 示例全部是合法 JSON，181 个示例键全部能在源码里找到解析点，107 个样例 SVG 与状态表完全吻合，相对链接零失效——"漏掉整张图/整节内容"这类硬伤不存在。

风险集中在**文档与代码的最后一段距离**，而且是同一个模式：文档写了、实现没接，且不报错。三处"能力不存在"（combo 的 `area`、柱顶数值标签 `series[].label`、甘特图泳道 `lane`）与三处"字段不存在但示例带着"（SHAP `features`、M33 形状码、分布类多组标签）都会让使用者拿到与预期不同的图或直接吃异常，其中 `area` 与 `series[].label` 是文档自己反复承诺（字段表 + 图说明 + 规格文档）却完全没有实现的，建议优先二选一：接线或删文档。反向问题是 10 个已实现配置项（`legendTextColor`、`upColor`/`downColor`、`shade`/`std` 等）在 README 里查不到，导致 M97 的 ±SD 带这类"正文提到效果、没给字段"的能力实际无法使用。

错误语义（#6）值得单独排期：它会让调用方按文档写的 `catch (ChartException)` 漏接 `f_data::JsonException`，是唯一会在生产环境表现为"未捕获异常"的一条。其余为过期计数、形状码、质心近似、英文缺一条别名、API 小节残段与 `--skip-build` 语义，属随手可改的精度问题。

本部分无 `.cj` 代码，未对渲染/布局算法、OOM、内存做独立判定（由同模块其他部分覆盖）；未跑构建与测试，凡涉及运行时结论均已降级为「待验证假设」。

**第 3 部分**：这 20 份文档的**骨架质量很高**：`doc/spec/` 下 5 套归档变更逐条都能在 `src/` 找到对应实现，`alluvialHeights([1,1],100,10)=[45,45]`、弧半径 0.35 短边、控制点公式、`sd` 分母 `n-1`、面积透明度 0.3、柱宽 0.6 等可机械核对的数值全部对得上；规范的 105 个唯一 type 与实现逐个对齐，108 行索引里列出的实现文件一个不缺，主题调色板、图例与轴默认值也与 `ChartTheme` / `ChartConfig` 完全一致。问题不在结构，而在 `chart-json-spec.md` 自称「唯一字段真相」之后**缺少与代码的同步机制**。

风险集中在四类：

1. **字段只存在于文档**（一般 5 / 轻微 1）：`annotations`（整块能力，含 `series[].label` / `opacity`，#1）、`pie.innerRadius`（#5）、`sankey.iterations`（#6）、`pareto.cumulativeFormat`（#7）、`histogram.normalize`（#2 的一部分）、`shap.features` / `gantt.lane`（#13）都会「收下不报错、什么也不做」。其中 `annotations` 还同时写在设计文档的信封表里——调用方按文档写参考线拿不到图也不会得到异常，这是本部分最值得排期的一类。
2. **默认值写错**（一般 3）：`areaStyle.opacity` 0.2 vs 0.3/0.6（#3）、`density.fill` true vs false（#4）、直方图 `bins` 10 vs `floor(sqrt(n))`（#2 的另一部分）。单项影响小，但规范是字段真相，错一个默认值就会让自建图与样例对不上，而 `charts/` 视觉基线会掩盖它（样例都显式写了参数）。
3. **文档允许、实现拒绝**（一般 2）：`treemap.tiling=slice`（#9）、`bins` 上界数组（#2 的第三部分）——这两处会直接抛 `InvalidValue`，比静默失效更容易被误判成"自己写错了 JSON"。
4. **字段语义冲突与过期**（一般 1 / 轻微 8）：`padding` 在通用表与 M70 之间一 key 两义（#8，示例本身就把画布边距从 24 改成了 2，这是唯一会改变布局结果的条目）；轴范围通用规则与柱/面积实现相反（#16）；`links` 与 `edges` 两套命名并存且规范自相矛盾（#17）；索引里两个形状代号互换（#11）；`flows` 正文与示例端点键不一致（#10）；`symbol=triangle` 静默降级成圆（#12）；`donut` / `network-heatmap` 四个可调字段未登记（#14）；设计文档的 `ChartSpec.cj` 已改名、里程碑表漏 M68（#15）；计数型字段没有上限章节（#18）。

没有阻塞项：以上都不改代码也能通过现有测试（这正是它们长期存在的原因），也没有发现会导致崩溃、数据错误或 OOM 的文档承诺本身。建议后续给 `chart-json-spec.md` 加一层机械校验（从 `src/` 的 `root.*("key")` / `seriesJson.*("key")` 抽取字段与默认值，与规范表格 diff），并优先修 #1 / #2 / #8——这三条决定用户"按规范写能不能跑"。

本部分无 `.cj`，因此**渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑、并发安全**这些专项未在本轮取证，不能据此对模块整体下结论；它们由包含 `src/**` 的其余 36 个子轮负责。

**范围外提示**：`src/WaffleChart.cj:41-49` 的 `cells` 无上限（OOM 面，见 #18）；`src/HeatmapChart.cj:192-196` 自行绘制 y 轴标题，可能与 `ChartFrame.drawYAxis`（`src/ChartFrame.cj:192-195`）重复输出（待确认，未展开）。

**第 4 部分**：本部分是 5 个新增图类型的 OpenSpec 记录与 1 个别名里程碑的收尾文档，规格颗粒度不错：requirement 与 scenario 写到了 class 名、计数、默认值和异常 `kind`，逐条对照实现后大部分都成立（`[1,3,5,7,10]` 的五数与 `quantileSorted` 的最近秩口径、`jitter` 默认 0.15、`sizeRange` 默认 `[4,30]`、子弹图横轴覆盖规则、日历 90 格 / 3 月份 / 4 星期都能对上）。真正的风险不在「文档写得对不对」，而在文档背后那层被复用的实现：

- **契约面**：Bland-Altman 借用了子弹图的数字读取，把「非负」这条不相干约束带进了测量值场景（#1），这是本轮唯一的「合法输入被拒」类缺陷；#7 的越界不裁剪则取决于尚未写清的裁剪契约。
- **结构面**：数字字段校验 4 处实现、插入排序 8 份、轴范围 3 套（#2/#3/#4），是同一种「复制粘贴再微调」的痕迹，已经产生过一次语义漂移（#1），后续每次收紧都会漏。
- **呈现面**：#5 的色阶取模回绕、#6 的固定 52px 标签预留属于会直接影响读图的坐标/边界问题，建议排在 #1 之后修。

没有阻塞项（无崩溃、无数据损坏、无并发/内存风险），上述 7 条一般项建议随下次 `f_chart` 迭代一并处理；7 条轻微项多是 design 文本与实现的 10% 级偏差、参照清单笔误或未落地的内部函数，可批量核对后一次性修文档。存量 14 条，是否纳入修复待用户决定。本部分未跑构建与测试（`tasks.md` 的「全量测试通过」只能静态核对产物存在），性能结论全部停留在假设层。

**第 5 部分**：本部分 20 份文件是 6 个变更（日历图、日历别名、校准曲线、蜡烛图、变形地图、和弦图）的归档四件套。**归档质量整体不错**：六份 design 的算法描述（网格行列公式、sqrt 缩放、`padAngle/2` 间隙、`chordWidth` 曲线、5% 留白、transform 三段式）与实现逐条对得上，`tasks.md` 的红绿流程也说明这些图是按 TDD 落地的；样例 `charts/M044` / `M106` 字节级相同，印证「M106 复用 M44」。

风险集中在三处：

- **阻塞项 #1**：校准曲线的 x、y 两轴同时取反，实际输出相对 spec 的「左下—右上」语义旋转 180°，把「高估 / 低估」的解读整个反过来；样例 SVG 的刻度与首点坐标是最硬的证据，而用例只数元素个数所以全绿。同一写法在 `Gain` / `Ecdf` / `BlandAltman` / `LassoPath` 四个图上重复出现，建议作为一轮独立的「数值轴方向」专项修，每图补坐标断言。
- **契约类 #2 / #3 / #4**：`binCount` 只校验不生效而 README 承诺分箱；日期只做形态校验，`2026-02-30` 静默变成 3 月 2 日；日历图区间无上限，配置抄错一位就能把 SVG 撑到几十上百 MB。三条都会让用户拿到与预期不同的结果，或直接放大内存占用。
- **归档漂移 #5–#11**：未文档化的 18px 上限、`candlestickRange` 不存在、`binCount` 两种约束、`colorRange` 色数上限缺失、校验清单漏项、alias spec 双份契约、蜡烛图隐式禁负价。单条都很轻，但都是「按文档做会踩到实现」的类型，适合一次性清理。

本部分没有任何 `.cj`，图表渲染算法本身的正确性、OOM 实测、死代码与重复实现、并发安全**只在「文档 vs 实现」这一侧取证**，不能据此对模块整体下结论；`src/**` 的判定由其余子轮负责。存量缺陷共 11 条（严重 1 / 一般 3 / 轻微 7），是否纳入修复待用户决定；本报告只读文件，未做任何修改。

**第 6 部分**：本部分覆盖的六个图种（和弦、分级统计、圆堆积、组合、混淆矩阵、等高线）在文档侧写得相当扎实：每份 `spec.md` 都给了可判定的 MUST 与具体场景，「数据形状 → 归一化 → 布局 → 文本 → 校验」的分节也和代码一一对应，六份 `tasks.md` 的红绿流程说明这些图是按 TDD 落地的。逐条核对后，**实现侧的校验面基本没有漏项**（类型判别、必填字段、方阵/网格完整性、id 唯一、父子存在、颜色合法性都有对应抛错；规格文本本身的漏项见 #16），坐标换算（`LinearScale` 方向、`band.center`、`lineRange` 5% 留白、`contourLevel` 钳制）也没有算错。

问题集中在两类：

- **几何/渲染的边界**：圆堆积的子圆会越出父圆（#6，直接违反 spec 的 MUST）、双轴柱组起点重合导致重叠（#2）、堆叠段同色（#3）、图例与折线配色脱节（#4）。这四条都只能靠看图发现，现有测试只数 class 个数，断言不到几何与颜色，所以长期未被捕获。建议优先补「几何不变量」与「颜色唯一性」两类断言。
- **「接受但不生效」的输入**：等高线的 `interpolate` 与 `levels` 数组（#7）是唯一有文档承诺却完全没有实现路径的项，属于会误导使用者的静默降级，应当在本轮就定下来（实现或撤文档）。

**阻塞项**只有 #1（`CirclePackingChart` 递归无深度上限导致的栈溢出）。它不影响常规示例，但深链输入是真实存在的（目录树、组织架构），而 `draw` 无捕获、进程直接崩，建议本轮修掉并加 `maxDepth` 上限。

其余为可排期项：#5（纯折线被压到 0 起点）与 #9（质心解析）影响可读性但不出错；#8 的 14 份 `findNode` 是模块级技术债，按「本部分 3 个先收敛」推进即可。文档措辞层面还有 3 条轻微：#16（校验清单漏 `id`）会让照文档造数据的人直接被拒，#17（比例口径）与 #18（类型计数）属同一类「文字比实现走得远」的漂移——这三条改文档即可，不必动代码，但应趁本轮一并收掉，否则下一轮重审还会重新命中。三条优化方案全部缺改前基线，本轮只作为下一轮补数据的候选，未写成收益结论。

存量缺陷共 18 条（严重 1 / 一般 8 / 轻微 9），是否纳入修复待用户决定；本报告只读文件，未做任何修改，也未跑构建。

**第 7 部分**：本部分覆盖的六个图种（等高线、控制图、相关矩阵、决策树、核密度、差分火焰）在文档侧属于「规格可判定」的一档：每份 `spec.md` 都给了 MUST + 具体场景（甚至给了可复算的数字，如控制图 mean=5/σ=2/UCL=11、KDE 在 0 处 0.3989、3×3 网格 4 个单元），`design.md` 则把公式、常量、class 名写到可以照着实现的程度。逐条核对后，**数值与几何公式基本没有算错**——控制限的 ±3σ 与 n−1 分母、等值线的 `floor(...)*levels` 钳制、Silverman 带宽与 1.05 y 轴余量、决策树 160px 槽距与 114px 层距、差分配色中性与双向插值，全部与源码一致；`tasks.md` 的红绿流程也真实对应到测试类。

问题落在两类：

- **文档自相矛盾 / 与实现不同步**（#2、#4、#5、#6）：最值得修的是 #2——决策树「父节点槽位」在 spec 里是「子节点平均值」、在 design 与 README 里是「首末子节点中点」，实现在 3 个以上且子树宽度不均时会给出不同坐标，现有用例只测 2 个子节点，因此这条 MUST 从未被验证。#4/#5/#6 属描述精度问题，改动只在文档侧。
- **「接受但不生效」的输入**（#1）：相关矩阵的 `method` 与第 6 部分记录的 `interpolate` / `levels` 数组是同一类问题——字段被校验、被示例使用、被列进「专属字段」，但对输出零影响。因为图表本身不接受原始样本（只接受已算好的系数方阵），`method` 根本没有计算入口，建议显式降级为元数据而不是保留假开关。

**阻塞项为 0**。#3 是唯一会产出错误结果的路径（差分火焰图在「新版本该路径全消失」时整图空白），但既不崩溃也不影响其他图，按一般排期修即可；它值得优先处理的原因是**静默**：没有任何异常，调用方无法区分「图是空的」与「数据没问题」。

与相邻部分的重叠已做去重：等高线的 `interpolate` / `levels`（第 6 部分 #7）与 `uniqueSorted` 复杂度（第 6 部分 #13）不重复计数；决策树 / 差分火焰图的递归深度无上限与第 6 部分 #1 同源，因文件不在本部分清单，只作范围外提示，未计入统计。

存量缺陷共 7 条（一般 3 / 轻微 4），是否纳入修复待用户决定。

**第 8 部分**：本部分覆盖 `f_chart/doc/spec/` 下 6 个新增图表的变更文档（20 个 `.md`，合计 463 行）。这些 spec 写得比多数项目的设计文档更可验收：每份都是"Requirement + WHEN/THEN Scenario"结构，字段名、类名、默认值、错误 `kind` 基本都能在实现里一一对上（`innerRadius` 0.55、`radius` 3、`jitter` 0.15、`dotSize` 7、`#e53935` / `#4a90d9` 颜色、5px/6px 端点半径、8% 轴余量全部核对通过），`tasks.md` 的勾选也与 `src/*_test.cj` 的实际存在一致。

风险集中在**边界条款没写透**与**复制粘贴带出的口径漂移**，前者恰好落在本轮重点（坐标与边界）上：

- 一般项 #1 最值得先改：哑铃图 design 只写"网格与横轴刻度由 `ChartFrame` 绘制"，实现把横向 `xScale` 传给纵向 API，样例 `M077-dumbbell.svg` 里一半网格线跑到绘图区外、两条整条在画布外，左侧还叠了两套标签。这是典型的"按文档看没问题、按文档做就出错"，实际修复在源码侧，文档要补的是"横向类目图的网格方向与比例尺"。
- 一般项 #2 / #3 / #4 是同类问题：内孔颜色与中心文本色的组合在非白主题下不可读（#2）、`jitter` 无上界使"圆心在类目带内"无法保证（#3）、根 `value2 = 0` 时宽度基准未定义导致整图空白（#4）。#5 / #6 则是"复制粘贴带出的两套口径"：环形图整块复制饼图绘制后，`showPercent: false` 从"显示类目名"退化成"不显示"（#5）；哑铃图把子弹图的"非负"约束一并复制进来，拒绝原本合法的负值（#6）。这五条都建议先定契约（给约束并校验 / 降低承诺 / 抽公共实现），改动都在几行文档 + 一处校验或分支。
- 轻微项 #7–#12 属字段与类名覆盖不全 + 样板重复：零值扇区、抖动公式的相位常量、`regions` 的元素形态、`jitter` / `dotSize` 的层级、`symbolSize` 默认值与 `pie-label` 类名，以及点图/哑铃图/横向条形图三处同型的布局代码。修正成本低，但都是使用者第一步就会碰到的地方。

本部分没有 `.cj`，但为核对文档承诺回读了 6 个实现：**重复逻辑与存量缺陷**已按 §2 / §11 取证（#5 / #12、#1 / #4 / #6）；**死代码、OOM、并发安全、性能热点**仍未在本轮取证——它们只能在覆盖 `src/**` 的子轮判定，本报告不据此对模块整体下结论；**栈溢出**只列了待验证假设 #3，等实测数据再定级。

存量缺陷共 12 条（一般 6 / 轻微 6），是否纳入修复待用户决定；本报告只读文件，未做任何源码修改。

**第 9 部分**：本部分覆盖 `f_chart/doc/spec/` 下 6 个新增图表的变更文档（20 个 `.md`）。文档形态统一（Requirement + WHEN/THEN Scenario + design/proposal/tasks 四件套），字段名、类名、默认值、错误 `kind` 绝大多数能与实现逐项对上：ECDF 的 2% 余量与 `(i+1)/n`、误差线的 8% 余量与「0.3×槽宽、最长 12px」端帽、流向图的 `1+4·sqrt(v/max)`、流程图 6 种形状、火焰图的 `frameHeight` 18 与双向 y 公式全部核对通过；6 个 `tasks.md` 的勾选与 6 个 `*_test.cj` 的存在一致。文档不是"写完就扔"的，这一点值得肯定。

风险集中在两处：

1. **唯一一条严重的渲染正确性问题出自 ECDF**：design 的阶梯定义与实现的循环顺序差一档，曲线在每个观测点都高一级、水平段整体左移，按图读分位数会系统性偏移；用例只数线条与断言 `ecdfPoints` 的数值，路径几何零覆盖。这条同时说明"文档写对了、实现没照做"的情形确实存在，验收口径需要落到 SVG 属性级断言上。
2. **校验类条款普遍比实现窄或比实现宽**：哑铃图（文档宽、实现窄，负值被拒）、误差线（实现多一条"恰好 1 个系列"）、火焰图（文档漏了"全可达"，环上节点被静默丢弃）、流程图（承诺箭头与边界相交，实际按短边半径截断，`horizontal` 下箭头整段消失）。这类漂移不会让测试变红，但会让使用者照文档写用例时踩空。

轻微项集中在设计文档的数值口径（层距 90、首点 y=0、字节累加散列）与验收落点（"范围"用例只数元素）。修法都只有几行，但建议与上一条合并处理：要么改文档、要么改代码，不要留成"文档说 A、代码做 B、测试只测 C"的三方状态。

存量缺陷 13 条（严重 1 / 一般 5 / 轻微 7；另有 11 条源码「范围外提示」不计入），是否纳入修复待用户决定；本报告只读文件，未做任何修改。

**第 10 部分**：这 6 份变更文档的完成度不低：每条 spec 要求都能在实现里找到落点，`tasks.md` 的 `[x]` 与代码一一对应，校验路径（缺失字段、类型不符、区间倒置、负数、悬空边/依赖）也基本齐备，命名与 class 约定前后一致。主要风险集中在**坐标与布局**而不是文档措辞：森林图与增益图的比例尺像素参数与 `LinearScale` 契约相反，导致轴方向反转（增益图整体 180° 旋转，有已提交 SVG 佐证）；流程图自动布局用固定层距，库自带的 6 节点示例就有 3 个节点落在画布外。这两条属于必须修的输出错误，且现有测试只统计 class 次数、没有任何坐标断言，是它们长期存活的直接原因——建议修复时同步补坐标断言，否则同类回归还会复发。文档侧的问题（`lane` 承诺未实现、`yAxis.labels` 空转、漏斗图 proposal 的「梯形/排序」、权重 0 的边界 MUST、依赖箭头 class、流程图规格漏记布局与形状）属口径不统一，排期修正即可；性能方面本部分没有可复核的测量数据，排序复杂度与分层松弛只作为下一轮补数据的假设，不作为结论。

**第 11 部分**：本部分 20 个归档规格文档整体自洽：class 名、默认值（`radius` 24、`cellGap` 1、`showValues` false、角度 −120/120、量程 0/100）、坐标与布局公式（分组柱 `slot`/`barWidth`/居中、热火焰图宽度归一化、热力图单元格 `cellGap/2` 内缩）与实现逐项对得上，tasks 勾选项也都有真实产物，没有"承诺了但没实现"的能力。

风险集中在**规格未定义的边界与字段口径分叉**，且每一处都直接对应一个可复现的渲染缺陷：gauge 最后一个阈值小于 max 时色带留空（#2）；gantt 重复 id / 自依赖未被拒绝导致依赖线连错行（#3）；heat-map 的"最小点取首色"与 `value/maxValue` 归一化互斥，非零最小值取色不符（#1）。三条都不是崩溃级，但对使用者是"图看起来对、实际读错"的错误，属应排期修复的一类。

轻微九条分为两组，可随一轮文档整理批量收口：**口径分叉**（gauge 阈值下界 `(min, max]` vs「超出量程」，#12；heat-flame `colorRange` 允许 2/3/≥2 三种说法且 4 色以上静默截断，#7；gauge 数值字号/加粗，#5；gantt `progress=0` 表述，#4；gauge 角度跨度 >360°，#6）与**验收场景缺失 / 表述笔误**（heat-flame 六条约束只给 1 个场景，#8；heat-map 缺 `viewBox` / `regions` 契约，#10；heat-map proposal 文件名 `HeatMapChart.cj` 不存在，#9；grouped-bar 场景标题「两组三系列」与正文互换，#11）。它们不会立刻崩，但会让下一轮按 spec 补测试的人写出与实现相反的断言。

性能与内存方面没有可下的结论：本部分没有 profile 或基准数据，O(n²) 查重与插入排序只作为待验证假设登记，未计入缺陷。

**第 12 部分**：本部分覆盖 6 个图表变更的 20 份 spec 文档。文档整体质量高：`spec delta` 的 Requirement 与 Scenario 有可判定的 THEN（类名计数、`kind` 取值、默认半径），`proposal` 的字段清单与 `design` 的公式基本能直接对上实现，5 份 `tasks.md` 全部完成且能追到测试文件，没有「文档写了、代码没有」的空承诺。

风险集中在三处：

- **边界与上界**（#3 / #4 / #7）：渲染对「合法但极端」的参数只做单向校验。`bins` 无上界，一个数据点即可打出 GB 级分配；`xAxis.min > 0` 时横柱的 0 基线落在绘图区外、柱方向反了（`BarRenderer` 有钳制、横柱漏了）；`cellGap` / `barWidth` 能产出负尺寸矩形，SVG 静默不渲染。建议优先修 #3 与 #4。
- **规格与实现漂移**（#1 / #2 / #9 / #10 / #11 / #14）：六处文档口径落后或漏项。改文档几行即可，但 #1 会让按 design 写的验收用例失败，#14 会让 spec 无法覆盖实现已强制的约束。
- **结构重复**（#8）：冰柱图与火焰图 240 行级整份复制，而设计文档声称共享；#5 / #6 两条缺陷因此在两份代码里各存一份。这是本部分唯一「改一次要改两处」的系统性风险，建议列可排期的重构。

三条性能方案与四条待验证假设均无基线，不进修复清单。无 `严重` 项：未发现可稳定复现的崩溃路径（栈溢出需深链输入，层数待实测）、未发现并发问题（渲染是纯函数、无共享状态）、未发现数值算错（#3 是坐标放置错）。

本报告只读文件，未修改任何源码，未跑构建。

范围外提示：`FlameChart.cj:167-204` 与冰柱图同源的递归/环检测/复制问题属其他部分覆盖范围，合并时请去重；`NetworkHeatmapChart.cj` 复用 `heatmap-cell` / `heatmap-value` 类名，其规格属第 11/13 部分。

**第 13 部分**：这 20 份文档的结构质量在模块内属上游：每个变更都有 spec delta（requirement + scenario）、design 给出坐标与配色参数、tasks 留了红绿过程，`design` 里的半径映射、线宽、点径、留白比例、class 名与实现基本逐项对得上。

真正的问题出在**文档没有覆盖的维度**：spec 只写"轴范围覆盖全部数据 + 留 X% 余量"，从不约束方向，于是 lift / learning-curve / lasso-path / influence 四个图型把 `LinearScale` 的 `topPixel` / `bottomPixel` 传反、整图镜像，全部验收场景与只数 class 的单测依然通过，`charts/` 里已提交的样例 SVG 也是镜像版本——这是本部分唯一应先修的阻塞项（#1）。其次是学习曲线的 `std` 排序错位（#2）与冰柱图静默丢节点（#3），都属于"跑得通、图画错"且被样例数据掩盖。

其余命中都是"少写一句"级别（日期合法性、刻度取整、class 清单、单系列图例、单点系列、标签省略条件、`metric` 无效果），不影响按文档起步，但会让使用者在边角输入上得到与预期不同的结果，建议随对应图型一起补齐。本部分没有实现文件，故不产出栈溢出、OOM、并发与性能结论；两条性能线索缺基线，只留在「待验证假设」里并提供采集方法。

**第 14 部分**：本部分覆盖 6 个变更的 20 份归档文档（折线、棒棒糖、曼哈顿、模块契约、马赛克、网络热力图）。**文档主体是可用的**：`line` 与 `module` 两个变更的条款几乎逐条能对上实现（混合形状抛 `InvalidValue`、缺测分段、`Q` 曲线、四类 `kind`、接口签名、依赖方向都对得上）；`lollipop` / `mosaic` 的计数类 Scenario（茎与圆头数、8 个单元、4 个标签）也与测试一致。问题集中在"归档时没有把实现取舍回写文档"这一类，且 #1–#5 全部与实现在同一提交引入，不是后来代码演进造成的过期。

风险分三层：

- **会画错图**（#3，一般）：棒棒糖图两条 MUST 互斥，`yAxis.min > 0` 时茎基线被外推到绘图区外、穿过类目标签。这是本部分唯一"输入合法、图形错误"的条目，建议优先修；修法（基线钳制）与 `HorizontalBarChart` 同源，可复用。
- **契约与实现各说一套**（#1 / #2 / #4，一般）：曼哈顿图的染色体标注承诺没有落地、配色与阈值标签两处与文档不符；马赛克的"列总和"到底是每列还是合计没写清，导致零列静默产出零宽单元与重叠标签。都会让按文档写的验收 / 视觉回归失败，但不影响其它图。
- **放大面**（#5，一般）：网络热力图按契约必须输出 N² 个图元，文档没有上限也没有拒绝路径，1000 节点就是 10⁶ 个矩形。是否算严重取决于 `nodes` 是否来自外部请求，文档没声明，故记一般，数据列入待验证假设。

没有任何 `严重` 项：本部分无运行时代码，未发现崩溃、数据计算错误或并发路径。性能与内存只有两条待验证假设（N² 输出峰值、曼哈顿分组查找），均无基线，不进修复清单。文档侧另有三条轻微项（草稿残句、设计把计划写成现状、`heatmapColor` 命名漂移），属于下一轮顺手清理的范围。

存量缺陷共 8 条（一般 5 / 轻微 3），是否纳入修复待用户决定；本报告只读文件，未修改任何源码，未跑构建（文档类审查，无可执行验证面）。

**第 15 部分**：本部分覆盖 6 个变更的 20 份归档文档（网络热力图后半、节点-链接、列线图、离线火焰图、组织图、配对连线）。**文档的可判定性整体高于同模块前几部分**：计数类 Scenario（16 个单元、5 个节点/5 条连线、3 条变量尺/4 个风险刻度、5/7/1/3 个 `offline-flame-node`、6 个节点/5 条连线）逐条能与测试断言对上；`paired-line` 的 19 行 design 与 177 行实现几乎一一对应，是本部分质量最好的一份；`network-heatmap` 的三条 Requirement 全部有实现与测试支撑。

风险集中在四类：

- **校验条款写进了 MUST、实现没跟上**（#1 / #2，一般）：两张树图的"不存在环 / 检测环"都没有真正的检测路径——组织图完全没有，离线火焰图的 `depth > total` 守卫恒假；而组织图的环测试用"无根图"误通过，掩盖了缺口。空 `links` 同理：spec 要求非空，实现接受。这类问题的共同后果是"输入合法、产物静默错"，且都能被现有测试放过。
- **能力承诺大于实现**（#3，一般）：列线图的核心（变量取值 → 分值 → 总分 → 风险）只有第一条链路的起点，`points` 解析后即被丢弃，proposal 的 Why 段因此名不副实。这是本部分唯一"功能层面"的缺口，需要产品口径决策，不宜只改文档糊过去。
- **坐标与边界**（#4 / #5，一般；#7，轻微）：组织图的"居中"在布局超过绘图区时会变成负偏移，默认参数下 6 个叶子或 6 层就让节点出画布，而现有测试把样例放大到 900×560 恰好避开；"父节点居中"被写成三种口径（spec 平均 / design 区间中点 / 实现首末中点），叶子数不均时给出三个不同坐标。列线图则是行高自适应、行内文本偏移固定，29 个变量起刻度文本互相压叠。这些都属"合法输入 → 图不好看/画错位置"，不崩溃但要修。
- **同一套规则两份实现/两份口径**（#9 一般；#8 / #10 / #11 / #12 轻微）：offline-flame 号称复用火焰图的树构建，实际整段复制了 `draw` 的解析段与四个私有函数（已开始分叉：`colorBy`/`orientation` 只存在于火焰图侧）；`leafCount`、`linkDistance`/`charge` 默认值、`name` 缺省、`risk` 非空这些条款在文档与实现之间各有一处没对齐，单条影响都很小，但会让"照文档写测试"的人得出相反结论。

`严重` 为 0：本部分无运行时代码，未发现崩溃、并发或数据计算错误；#6 的栈溢出风险因缺平台栈阈值实测，按铁律只定`一般`并列入待验证假设。性能与内存只有两条待验证假设（递归溢出深度、力导向耗时构成），均无基线，不进修复清单。修复优先级建议：#1（静默丢数据）> #9（会持续放大的重复）> #2/#5（口径二选一）> #4/#7（布局边界）> 其余文档措辞。

**范围外提示**（`.cj` 属其他子轮，只记一句）：`OrgChart.cj:108-122/218-223`、`OfflineFlameChart.cj:176-200` 是 #1 的实现侧；`OrgChart.cj:128-139` 是 #4；`OrgChart.cj:235-237` 是 #5；`NodeLinkChart.cj:109-135` 是 #2；`NomogramChart.cj:71-75/23-33` 是 #3；`NomogramChart.cj:144/201` 与 `ChartTheme.cj:28` 是 #7；`NodeLinkChart.cj:68-72/144/281` 与 `NomogramChart.cj:243-245` 是 #8；`OfflineFlameChart.cj:50-215` vs `FlameChart.cj:50-204` 是 #9；`PairedLineChart.cj:78` 是 #11；`NomogramChart.cj:85-87` 是 #12；`FlameChart.cj:111-112` 与 `NodeLinkChart.cj:243-244` 分别与 #6、待验证假设 #2 同源。

存量缺陷共 12 条（一般 7 / 轻微 5），是否纳入修复待用户决定；本报告只读文件，未修改任何源码，未跑构建（文档类审查，无可执行验证面；实现行号均来自现场阅读与 `grep`）。

**第 16 部分**：本部分是六个图表特性的规格包（配对连线、平行坐标、帕累托、PDP、百分比条、百分比堆叠）。文档与实现的**基本吻合度很高**：class 名、错误类型（`MissingField` / `InvalidValue` / `UnsupportedChart`）、归一化公式、留白比例、堆叠起点都能逐条对上，任务清单与仓库里的测试文件也一一对应，没有发现「承诺了但没实现」的功能缺口。

风险集中在三处：

1. **PDP 的 Y 轴方向（#1，严重）** —— `LinearScale` 的 `topPixel` 参数被传成 `plot.bottom()`，曲线与刻度整体上下翻转。这是本部分唯一的阻塞项：图能生成、测试全绿（只数 class 不校验坐标），但表达的趋势方向是反的。同一写法在模块内还有 9 个图表（Volcano/Lift/Ecdf/Gain/Calibration/BlandAltman/LassoPath/LearningCurve/Manhattan），修的时候建议一起改，并把参数名固化成 `maxPixel` 或加具名工厂，避免再靠记忆传参。
2. **平行坐标的边界处理（#2 #3）** —— 单侧显式范围遇到越界数据会整图报错，与本文件自己的钳制契约冲突；画布尺寸又只校验 `> 0`，硬编码的 `60/20/64/40` 边距在窄画布上会把绘图区算成负数。两者都属于「输入合法但输出无意义」，建议在范围解析与 `ChartConfig` 两处各补一道判定。
3. **规格与实现的口径漂移（#4 #5 #13 #14 #15）** —— `percent-bar` 的「y 轴 MUST 固定 100」被实现与设计同时否定，提案还把纵向柱写成「100% 横条」；PDP 规格里「轴覆盖全部数据」与「显式 min/max 优先」互斥且没有裁剪兜底；平行坐标 design 的扩边规则与 spec 场景不一致；帕累托规格的标签长度要求比实现严。这些是归档规格的自洽性问题，不影响当前运行，但下游照规格写断言会踩空。

其余 10 条轻微问题（#6 不可达守卫、#7 右轴重复实现、#8 51 处同文案校验与手写排序、#9 图例配色、#10 平行坐标轴头布局、#11 未使用 import、#12 缺失的归一化测试、#13 design/spec 口径不一致、#14 percent-bar 提案方向、#15 帕累托标签口径）属于可维护性与观感层面，可以排期处理。性能与内存方面没有可下的结论：本部分涉及的代码路径没有 profile/bench 数据，`paretoOrder` 的 O(n²) 与全量物化只能作为下一轮补数据的假设。

**第 17 部分**：本部分是 6 个图表的归档四件套（proposal / design / spec / tasks）中的 20 份文档。文档质量整体较高：需求以 `MUST`/`SHALL` + scenario 写出，类名、内部助手名、异常类型、class 名、默认值与当前实现逐项对得上，tasks 勾选项对应的测试文件也都存在，没有空章节和失效符号。真正需要排期的是**象形图的图标数量无上限**——它不是文档措辞问题，而是一条能从 10 字节输入放大到 GB 级输出的 OOM 路径，规格与设计都没有给出拒绝或降采样规则，属阻塞项。其余两条（`pr` / `probability` 漏记单系列约束、`pie` 的 0 值扇区二义）是规格作为验收基线的完整性缺口，改动只在文档侧，风险低。另有两条落在 `doc/chart-json-spec.md` 的文档与实现冲突（百分堆叠的 y 轴上限、饼图 `innerRadius`），已标为范围外提示，交由对应部分处理。存量共 3 条，是否纳入修复待用户决定。

**第 18 部分**：这 20 个文件是 6 个已完成变更（M13 雷达、M23 QQ、M24 山脊、M40 残差、M47 ROC、M88 雨云）的归档规格，整体质量高于常见「写完就丢」的变更文档：每条需求都带可验证场景，场景里的计数与数值（分位点、图元数量、振幅公式、余量比例）都能与当前实现逐项对上，`tasks.md` 声明的用例在对应 `*_test.cj` 里确实存在。没有承诺未实现、空实现、占位 TODO 或失效引用，不存在阻塞项。

5 条发现全部是文档口径类：`design.md` 的几何常量（30px vs 36px、14px vs ±8/∓6px）与采样点数（80 vs 81）在实现里对不上，且与实现同一提交引入，说明是「文档随手写的数」而非后续漂移；`spec.md` 侧有两处契约漏项——雨云的 `raincloud-cap` 类名在任何 `.md` 里都搜不到、残差图漏写「仅 1 个系列」但实现会抛错，前者影响样式定制，后者会让按文档理解契约的使用者踩坑；山脊图的 `overlap` 没写挂载层级，写在顶层会被静默忽略且 0–1 校验不触发（README 示例是对的，故影响有限）。建议按条更新文档，不需要改实现；若希望「顶层 `overlap` 也能用」，则是实现侧的小改动，需单独评估。

存量 5 条，均为轻微，是否纳入修复待用户决定。

**范围外提示**（不在本部分 20 个文件内，不占用统计，交由对应源文件部分取证）：

1. 插入排序在 `f_chart/src/QQChart.cj:156-171`（`sortValues`）、`f_chart/src/RaincloudChart.cj:320-335`（`sortRaincloud`）两处函数体逐行相同（仅函数名不同），`f_chart/src/RocChart.cj:188-203`（`sortPoints`）是同一算法换元素类型与比较键——属 §2「只改类型名」型重复，建议抽 `sortFloat64Asc(values: Array<Float64>)` 复用；O(n²) 在大样本系列上是否构成热点需 `cjprof` 数据，当前无可测基线。
2. `f_chart/src/RocChart.cj:145-151` 的对角线用 `xRange` 端点同时映射 x 与 y（`yScale.scale(xRange[0])`），当调用方把 `yAxis.min` 设为大于 0（如 0.4）时线段会画到绘图区外（`f_chart` 全模块无 `clipPath`），可能压到标题/轴标签；`README.md:1919-1920` 的示例用 0–1 不会触发，属显式轴范围下的边界问题，建议改用 `max(xRange[0], yRange[0])`..`min(xRange[1], yRange[1])` 裁剪端点。

**第 19 部分**：这 20 个文件是 6 个已完成变更（M6 散点、M30 散点矩阵、M36/M67 桑基与别名、M47 ROC、M72 玫瑰）的归档规格。整体质量中上：每条需求都带可验证场景，场景中的计数与数值（散点矩阵 3 标签 + 54 点、玫瑰 4 扇区、桑基链式 5 级分层、AUC 文本）绝大多数能与当前实现对账，`design.md` 点名的内部辅助函数与复用面（`roseRadius`、`sankeyLayers`、`columnRange`、`lineRange`、`ChartSvgKit` 点形状）都真实存在且有调用者，`tasks.md` 的勾选项与测试文件对得上，没有承诺未实现、占位 TODO 或失效引用。

风险集中在「契约细节与边界未定义」而非功能缺失：一条真正会让人踩坑的是桑基别名规格把「以 `<svg` 开头」写成硬契约（实现永远输出 `<?xml …?>` 前缀），而它自己的验收测试用了更宽的 `contains` 把这条错误验了过去——这是本部分唯一建议优先改的条目。其余六条是文档口径类：玫瑰图零值扇区在规格内部自相矛盾且与实现相反、`maxRadius` 的 45% 与实现公式不等价、散点图 `symbol` / time 轴的四处描述偏差、ROC 漏写 `series` 数量与 `auc` 层级、散点矩阵缺规模上限、桑基图未定义有环输入。均不需要动渲染算法，改文档 + 补边界校验即可。

存量 7 条，是否纳入修复待用户决定。

**范围外提示**（不在本部分 20 个文件内，不占用统计，交由对应源文件部分取证）：

1. `f_chart/src/ScatterChart.cj:128` 把 `LinearScale(min, max, topPixel, bottomPixel)` 的像素入参写成 `(frame.plot.right(), frame.plot.x)`（ROC/散点矩阵等多处都是 `(左, 右)`，见 `RocChart.cj:123`），x 轴数据方向被镜像；`add-f-chart-scatter/design.md:9` 照抄了 `LinearScale(min,max,right,left)`，说明文档与实现是同一个错误，改代码时需同步改文档。
2. `f_chart/src/RocChart.cj:145-151` 的对角线两端用 `yScale.scale(xRange[0])` / `scale(xRange[1])`，当 `yAxis.min/max` 与 x 轴不同（如 `yAxis.min=0.4`）时线段端点落在绘图区外且不构成 45° 基准线——第 18 部分已作为范围外提示记录，此处仅提示同一问题在 `add-f-chart-roc/specs/chart-rendering/spec.md:14-16` 的需求里没有任何裁剪约定（该需求只说「输出 1 条 `roc-diagonal` 虚线」）。

**第 20 部分**：这 20 份归档四件套整体可用：每条 requirement 都能落到实现的具体类名、错误类型与常量上，可复算的场景（spiral 首末点 `[0,-25]`/`[0,-100]`、shap 绝对值降序、slope 长度校验、sequence 的 `stroke-dasharray`）逐一复算均吻合，没有发现「spec 承诺了但整块能力缺失」的情况——唯一的承诺缺口 `shap.features` 已由 `part2` / `part3` 记录，本部分只补了两处归档文档落点。

需要排期的只有一条：**#1 螺旋图负半径**。它是本部分唯一影响输出正确性的点，触发条件是小画布（默认 padding 下 `height ≤ 148` 或 `width ≤ 108`）这种完全合法的输入，后果是整幅图翻转 180° 且可能越界，而同模块 `RadarChart` 已有同类守卫，修复成本极低（三行 + 一条用例 + spec 补一句画布下限）。

其余五条是文档与维护性问题：#2 的五处常量说明归档后没有回写设计（改文档即可，不动代码）；#3 的 `drawGrid` 是悬空 API 名，需明确「本模块不画网格」；#5 是 spec 自身在 `count == 1` 时不自洽，属长期契约瑕疵；#4 的两处同语义复制目前行为一致，但累计规则写两遍是后续漂移的入口，建议在改动 `stacked-area` 之前先合并；#6 需要作者确认 `symbol: "none"` 是能力还是残留，再决定补文档还是删分支。

存量共 6 条（一般 1、轻微 5），是否纳入修复待用户决定。

**第 21 部分**：这 20 个文件是 6 个已完成变更（M15 堆叠面积、M3 堆叠柱、M22 茎叶、M82 主题河流、M69 旭日、M49 生存曲线）的规格与设计记录，主体质量好：核心公式（累计范围、正负分离堆叠、茎叶 `floor/round` 与钳制、三基线平滑、扇环内外弧、KM 阶梯与二项置信带）都能与当前实现逐项对上，class 名、默认值、错误类型也基本一致；`tasks.md` 声明的用例在对应 `*_test.cj` 里确实存在。没有空实现、占位 TODO 或失效引用。

唯一需要排期修的是旭日图的可达性缺口（#1）：spec 的 MUST 与实现相反，且属于「静默少画」而非报错，用户很难自查；修法是校验阶段加一次可达性计数，属于低风险改动，但要注意别把「合法森林」误杀（当前 spec 已要求恰好单根）。其余 6 条都是文档口径问题，按条更新文档即可，不必动实现：茎叶图的 `leafDigits` 上限与叶钳制只写在 design 里（#2）；主题河流 design 的 null 与 wiggle 边界已被实现超越（#3）；堆叠面积的 null 语义空缺且与堆叠柱相反（#4）；负值场景的断言单侧、锁不住「顺序累加」（#5）；堆叠柱的场景标题残留「组」、design 柱宽漏截断与校验（#6、#7）。

存量 7 条（一般 1、轻微 6），是否纳入修复待用户决定。

**范围外提示**（不在本部分 20 个文件内，不占用统计，交由对应源文件部分取证）：

1. 插入排序在三处逐行同构，仅元素类型/比较键不同：`f_chart/src/StemLeafChart.cj:164-172`（`Array<Float64>`）、`f_chart/src/SurvivalChart.cj:280-288`（`Array<SurvivalPoint>` 按 `time`）、`f_chart/src/SunburstChart.cj:182-192`（`ArrayList<SunburstNode>` 按 `total` 降序）。属 §2「只改类型名」型重复，可抽一个带比较键的 `sortStable`；O(n²) 是否成热点需 `cjprof` 与输入规模数据，当前无基线。
2. `f_chart/src/SunburstChart.cj:224-226`（`:225` 调用）复用 `flameColorIndex`（定义在 `FlameChart.cj:252`），同函数还被 `IcicleChart` / `HiveChart` / `CirclePackingChart` / `NodeLinkChart` / `WordNetworkChart` / `OfflineFlameChart` / `TuiFlameChart` 引用——跨 9 个文件（含 `FlameChart.cj` 自身）共用的取色哈希挂在 `FlameChart.cj` 里，命名与位置都应按「共享工具」重新安置（如 `ChartTheme`），否则任一图表重命名都会牵动一片。
3. `f_chart/doc/chart-json-spec.md:854` 的茎叶图小节与本部分 #2 同源：同样只写「`leafDigits`（叶位数，默认 1）」，未记 0–6 上限与钳制规则；该文件不属于本部分清单。

**第 22 部分**：这 20 个文件是 6 个已归档变更的四件套，整体质量在文档侧属于「结构完整、可核对」：每个 requirement 都带 Scenario，class 名、默认值、校验分支基本能在实现里逐一落位，tag-cloud 这种「别名不新增类」的决策也执行得很干净，survival 的置信区间数字（0.402 / 0.598）与实现公式完全对得上。

主要风险集中在 **treemap** 一份三件套上，而且是三种不同性质的问题：(1) 承诺「叶子必须有 value」但实现按 0 静默处理，产出「成功但少块」的图；(2) 把 slice-and-dice 挂上了 `squarify` 的名字，proposal 与 design 自相矛盾，下游按名字预期长宽比会落空；(3) 校验清单漏掉「节点不在根之下」，环上的子树被无声吞掉。这三条都不会抛异常，排查成本高于崩溃类缺陷，建议排在前面处理（其中 (2) 涉及对外 `tiling` 取值，需先确认下游是否依赖）。

swarm 的「仅支持 1 个系列」是典型的「实现比文档更严」，改文档即可收敛；survival 的 `n` 口径（点数 vs 样本量）需要作者拍板，属于统计语义问题而非笔误。swimlane 与 timeline 的两处边距漂移、treemap 的颜色轮转描述属于轻微的文档-实现不同步，可以按批随下次改文档一起修。

本部分无性能类缺陷：没有基线就不写热点、不给改造建议，仅把 treemap 的重复子树求和与深链递归列为待验证假设，供第 35 部分实测。存量 12 条（一般 5 / 轻微 7）默认只报不修，是否纳入修复待用户决定。

**第 23 部分**：本部分是 f_chart 六个已完成变更（treemap、TUI 子包、TUI 火焰图、violin、violin-box、volcano）的四件套文档，整体结构统一、验收场景可读，字段默认值（`bandwidth`/`showBox`/`showOutliers`/`frameHeight`/阈值 1 与 1.3）与实现基本对得上，无空实现、无死链、无凭据类内容。

风险集中在「文档承诺与实现的口径差」而不是性能：两条一般项都是「用户按文档配置会静默不生效」——小提琴族的 `bandwidth`/`showBox`/`showOutliers` 实际位于 `series[0]` 而文档只写裸字段名；树图的 `value` 契约（叶子必须 > 0）没有对应校验，缺值被当成 0 画出零面积格子。这两条建议排期修文档 + 补校验/用例，成本很低。六条轻微项是同一模板复制造成的数值与措辞漂移（40 vs 41 采样点、`bandWidth` 同名不同义、`bar`「占满」vs 0.6 倍、火焰图层高「至少 1」vs 抛错、`treemap-label` 的 40×18 阈值、抽稀公式不可执行且未实现）。其中 tasks 里把「抽稀」勾成已完成这一条，会误导后续维护者，建议同步修正归档记录。

存量合计 8 条（一般 2、轻微 6），是否纳入修复待用户决定；本部分无阻塞项，无性能类结论（无基线，相关猜测已列入待验证假设）。

**第 24 部分**：本部分 20 个文件全部是 `doc/spec/` 下的归档变更规格（volcano / waffle / waterfall / waterfall-alias / word-cloud / word-network 六套），四件套结构完整，proposal 声明的类型、class 名、内部函数与测试文件都能在 `f_chart/src` 找到对应，`tasks.md` 的勾选也与测试用例对得上——没有"承诺了但没落地"的空壳条目，`doc/spec` 与 README 里程碑表也没有版本口径冲突。

主要风险集中在**验收口径的细节缺失**，而不是规格写错：`xAxis.labels` 的等长强校验（发现 1）、`label` 10 字符截断（发现 5）、`series` 为空时的 `MissingField`（发现 6）都是"实现有行为、规格没条文"，使用者按文档写会撞到未记载的拒绝或截断。这类偏差单看代码不像 bug、单看文档也读不出，是本模块最容易在升级时变成兼容性问题的地方，建议排期补齐 spec 条文（不涉及行为变更的，只改文档）。

四条 [一般] 里，实质缺陷是词云的"裁剪"承诺不存在（发现 2）与词网络的规模无上界（发现 3），后者还叠加了 `runWordForce` 与 `runForce` 的整段复制（发现 4）——复制时丢掉 `charge` 参数化已经造成首个行为漂移，后续调参必然继续分叉。词网络与词云都属于"用户给的词量/词长不可控"的图表，这两条建议优先处理。

无严重项，无阻塞项。存量 8 条，是否纳入修复待用户决定（其中发现 1、2、6 只改文档即可闭合，发现 3、4、8 涉及代码）。性能类结论（词网络延迟、华夫图内存、词云估算偏差、瀑布柱重叠）均无基线，只写在待验证假设里，不进 `tasks.md`。

**第 25 部分**：本部分 9 个图（冲积、弧线、面积、柱、Bland-Altman、箱线、箱线散点、气泡、子弹）结构高度同构：解析 → 校验 → 范围 → 布局 → `SvgBuilder` 输出，全部无状态、无线程共享，无空实现与递归，输入校验覆盖度在图表库里属于较好水平（五数顺序、`ranges` 严格递增、`sizeRange`、`jitter`、`labelRotate` 都有对应校验与用例）。

没有严重项，阻塞级问题为零。真正需要排期的是三类「同构带来的漂移」：

1. **轴范围与轴边距各写 6 份，已经漂了**——`AreaChart` 与 `BarRenderer` 的负值留白不同，`BubbleChart` 漏掉 `labelRotate` 的底留白。这类问题单看任一文件都像对的，必须横向比对才暴露，建议在下一轮把 `axisRange` / `xLabelHeight` / `yLabelWidth` 收进 `ChartScale`/`ChartFrame`，并用「同一数据集换 `type`」的对照用例锁住边界。
2. **跨图复用 helper 夹带了私有语义**——`bulletNumber` 的「非负」限制被 Bland-Altman、哑铃、配对折线继承。这是本部分唯一会让合法数据被拒绝的问题，且报错文案指向字段而不是「不支持负数」，排查成本高，建议优先处理（是否放宽需用户拍板）。
3. **渲染边界的最后 20px**——冲积图末列标签越界、气泡/散点标签可越出画布。属于确定性布局缺陷，改法明确、风险低，可与上面两项一起排。

优化空间集中在两处 O(n²) 手写排序与冲积图每阶段全量扫描，复杂度可静态判定，但收益没有测量数据，按纪律只进「优化可行性方案（无基线）」与「待验证假设」。

**第 26 部分**：这 20 个文件是整个模块的「公共底座 + 4 个中等复杂度图表 + 一个 107 图的画廊」。公共底座（`ChartException`、`ChartJson`、`ChartScale`、`ChartTheme`）实现克制、错误路径统一、`Option` 处理规范，`ChartSvgKit` 把属性拼装收在一处并复用 `f_svg` 的转义，安全面是干净的；死代码与重复逻辑都只有少量演进残留，没有结构性腐化。

阻塞项有两条，都是存量：一是 `calendar-heatmap` 的日期区间完全没有上限，几百字节输入可驱动 365 万次图元生成（服务端渲染场景下即 OOM/长阻塞），需要先加拒绝路径再谈性能；二是 `calibration` 的 Y 轴上下镜像，且同模式在 9 个兄弟图表里复制（本部分只对 `CalibrationChart` 记一条），这是「静默画错」而非「画得不好看」，应优先修，修完必须重新生成 `charts/` 产物人工复核。`binCount` 与 `legend.orient`/`position` 属于「文档承诺、代码未接线」，按 §14 记一般，可与文档修订一起排期。

其余轻微项（死代码、`colorRange` 校验 6 份复制、legend/轴宽样板、共享辅助类的值域校验）可择机清理。性能层面本轮没有 profile 与 bench 数据，所有复杂度类观察（日历线性扫描、插入排序、cartogram 判重）只作为优化方案与待验证假设，不建议在补数据前进入修复清单。存量缺陷本部分共 12 条，是否纳入修复待用户决定。

**第 27 部分**：本部分 9 张图 + 日期工具的共性结构是「读 JSON → 校验 → 算布局 → 拼 SVG」，没有任何成员字段、锁、异步与 I/O：并发安全与资源生命周期这两个维度天然干净（§12 命中 0，句柄/连接类问题不存在）。主要风险集中在三处：

1. **组合图与规格/图例的偏离**（#1/#2/#3）。颜色回退用 `group.series[0].paletteIndex`、`bar` 分支丢弃 `stack`、`legend.show` 未接线，三者都是「配置/文档承诺了但输出不是那个样子」，且测试恰好都没有覆盖（`ComboChart_test` 只用 `stacked-bar` 与单色柱）。这是本部分最值得先修的一批——改动小、影响直接可见。
2. **树形图的输入健壮性**（#4/#5/#6）。圆堆积的环检测是死代码、环节点被静默丢弃，子圆网格越界，7 个递归函数深度等于树深且无上限。决策树侧的环处理是正确的（用可达计数），可把同一套校验抽出来复用；递归要么改迭代，要么加显式层数上限。
3. **矩阵类图的规模与校验**（#10/#11/#16）。输出随标签数平方增长且无上限，`colorRange` 又不校验颜色，和 `ChoroplethChart` 的成熟写法形成反差；同时 `CorrelationMatrixChart` 在窄画布上会算出负尺寸。

没有阻塞项：没有主路径崩溃、没有数据竞争、没有无界常驻增长。`ContourChart` 的 `levels`/`interpolate`（#8/#9）与 `pathCentroid` 的弧命令（#7）属于「功能说不完整」，建议与规格同步收敛——要么实现，要么从校验里删掉，避免「配置通过但输出不变」的误导。性能方面本轮无任何测量数据，5 条优化方案与 4 条待验证假设都只是复杂度线索，需下一轮用 `cjpm bench -O2` / `cjprof` 补基线后再决定是否进任务清单。

**第 28 部分**：本部分代码风格一致、校验普遍到位：每张图都先做字段存在性/类型/数值范围校验（含 `jsonNumberValue` 的有限性检查），错误路径统一走 `ChartException` 带 JSON 路径；10 个图类无可变状态，线程安全按构造即成立；没有空实现、没有吞异常、没有无界全局容器。资源与内存面上没有 OOM 风险点，只有 KDE 双算、火焰图 `n²` 查重、插入排序三处可优化（均无基线，不进修复清单）。

真正的问题集中在**渲染几何**，而不是数据校验：`ecdf` 与 `error-bar` 把 `LinearScale` 的 `topPixel/bottomPixel` 传反（图形整体镜像），`ecdf` 还缺最后一级阶梯，`dumbbell` 把 X 比例尺喂给 `drawYAxis` 导致左侧刻度错位越界，`donut` 单扇区因弧起终点重合而不渲染。这四类都属于「SVG 合法、测试全绿、肉眼一看就错」，根因是测试只统计 class 出现次数、从不校验坐标——这也是本部分最值得先补的基础设施（一条坐标断言就能防住上面 4 条中的 3 条）。`differential-flame` 的全零宽回退是同一类「静默空白」问题。火焰图两张的递归深度只受节点数约束，深链输入会崩进程，建议与 `offline-flame` 的 `maxDepth` 语义对齐。

按处置建议排序：坐标/轴类 5 条（Ecdf ×2、ErrorBar、Dumbbell、Donut）优先，改动小、影响直观；火焰图递归与 `DiffFlame` 宽度口径次之（需补负向用例）；重复逻辑（火焰图两文件、六处轴范围）与测试补强可排期，属结构性改善。存量 14 条是否纳入修复，待用户在门禁决定，本报告不代为取舍。

**范围外提示**（不计入本部分统计）：同批把 `LinearScale` 实参写反的还有 `BlandAltmanChart.cj:148-149`、`CalibrationChart.cj:129-130`、`GainChart.cj:125-126`、`LearningCurveChart.cj:195-196`、`LiftChart.cj:134-135`、`ManhattanChart.cj:165-166`、`LassoPathChart.cj:156-157`、`InfluenceChart.cj:138-139`、`PdpChart.cj:132-133`、`PrChart.cj:130-131`、`ResidualChart.cj:112-113`、`RocChart.cj:123-124`、`SurvivalChart.cj:168-169`；`PieChart.cj:114-147` 与 `DonutChart` 共用同一段扇区绘制代码（含 100% 退化），`PieChart.cj:109-113` 也有负半径公式。

**第 29 部分**：本部分 10 个图整体结构清晰：解析-校验-布局-绘制四段分明，错误文案带 JSON 路径，类目/数值比例尺基本统一走 `Chart`/`ChartFrame`/`ChartSvgKit`，边界校验在多数图上做得比同类库更细（`gauge` 量程、`forest` CI 顺序、`heat-flame` 子节点和校验）。

真正需要先处理的是两类系统性问题：

1. **坐标换算错误**（严重）：`GainChart` 两轴、`ForestChart` 的 x 轴把 `LinearScale` 的 `topPixel/bottomPixel` 写反，输出整图镜像；这类缺陷不影响异常与计数类用例，只能靠坐标断言发现，建议连同 `LinearScale` 的参数命名一起修，并补几何断言。
2. **递归无深度上限**（严重）：`heat-flame` 四个递归函数深度等于输入链长，深链 JSON 直接崩溃进程；同根因还在 `flame` / `differential-flame`，应统一抽布局工具并加上限。

其次是「文档承诺、代码不读」的静默失效：`gain.baseline`、`gantt.lane`、`forest` 的 `yAxis.labels`，以及 `gauge` 阈值末段未补满、`funnel` 负层高这类渲染完整性问题；`gantt` 重复 id 会画出错误依赖，属静默数据错误。

可维护性方面，地图骨架、三份火焰图、`gain`/`lift` 曲线与三处手写插入排序构成明显的复制扩散，是后续修 bug 漏改的主要来源；这些与 O(n²) 查找一起建议在比例尺与递归两项修完后排期。

本部分存量 22 条（严重 2 / 一般 12 / 轻微 8），是否纳入修复待用户决定；两条严重项建议优先确认。优化方案与待验证假设均无改前/改后对照数据，本轮不作为结论。

**第 30 部分**：本部分 10 个图表实现风格高度统一：都走 `ChartConfig.parse` 校验 `type`、都有"缺字段/类型/负值/空集合"的显式异常和对应测试，`draw` 无成员状态、无线程共享，因此没有并发与句柄资源面的风险；数值到 SVG 的格式化统一走 `formatSvgNumber`，也没有注入面。真正的阻塞项只有一个：**分箱数无上界**，一个字段就能把进程打到 OOM，`binsX*binsY` 溢出时还会退化成越界崩溃（#1），建议优先修。其次是两类"图会画错但不报错"的问题：轴范围被 `min/max` 覆盖后图元不裁剪、不重算（#2），以及 LearningCurveChart 只排序点不排序 `std`（#3）——前者影响面广（4 个图表），后者只在乱序输入下出现，现有用例都覆盖不到，建议各补一条边界用例。IcicleChart 的递归与失效环检测（#5、#6）属于输入极端才会触发，可排期处理。重复逻辑方面最值得动手的是 LassoPath/LearningCurve 的绘制骨架（#9），#3 就是复制后漏改的直接后果；`resolveLabels`、测试 `count`、`M/L` 拼接属于"改一次要改 N 处"的维护成本，可随下次改动顺带收敛。规格漂移集中在 M17 直方图（#7），需要产品或用户拍板是补实现还是改文档。

范围外提示（不计入本部分统计）：`ChartFrame.drawXAxis`（`ChartFrame.cj:204-243`）与 `drawXAxisNumeric`（`:278-322`）几乎逐行相同；`ChartTheme.parse`（`ChartTheme.cj:44`）未校验 `fontSize` 下限，是 #13 的根因。

**第 31 部分**：本部分 10 张图的**骨架质量整齐**：`ChartConfig` 统一解析信封、`ChartFrame` 统一坐标框、`ChartScale` 统一比例尺与刻度、`ChartSvgKit` 统一图元与 class 命名，因此没有一张图出现"完全没校验"或"结构对不上"的硬伤；数值解析全部经 `jsonNumberValue` 兜住 `NaN`/`Inf`，测试覆盖也基本按"正常 + 每种错误各一条"展开（10 个测试文件 94 个 `@TestCase`）。除 `MosaicChart` 外，其余 9 张图都复用了 `ChartFrame`，说明分层是被遵守的。

风险集中在三处：

1. **绕开通用层的那一张图**（`MosaicChart`，一般 #1）：自己画标题和图例，于是 `legend.show` 关不掉、`position`/`markerSize`/`itemGap`/`subtext`/`align` 全部静默失效。这类"配置写了没效果"是本部分最容易被用户当成 bug 报上来的问题，修法也最便宜（换回 `ChartFrame` 三个调用）。
2. **边界配置触发越界绘制**（一般 #2/#5/#6）：负宽矩形、0 基线落到轴外、刻度画到轴外，三者都是"输入合法但几何越界"，代码里没有任何拒绝路径或裁剪。共同点是**没有一张图把"画之前先确认坐标落在 plot 内"当成不变量**，建议统一加一层裁剪/校验，而不是逐图打补丁。
3. **重复实现导致的语义分叉**（轻微 #8～#11）：图例名色推导、染色体顺序、节点 id 索引、字宽模型、数值读取各有一到四份副本。其中 `findNode` 返回 `-1` 被直接当下标用（`NodeLinkChart.cj:158`）、`chartTextWidth` 与 `orgFitLabel` 两套字宽是最容易在后续改动里变成真 BUG 的两处。

`OrgChart` 的环检测（一般 #4）值得单独排期：现有用例之所以是绿的，是因为它恰好只测了"没有根"这一形态；有合法根时环节点会被叠画在同一坐标，属于"静默产出错误图"。

性能与内存方面本部分**没有任何测量数据**，因此不给结论：四条线索（力导向 80×N²、id 线性查找、每格颜色解析、曼哈顿四份数组）全部写成"无基线待验证"的优化方案与假设，下一轮补 `cjprof record` 与 `cjpm bench -O2` 后再决定是否进 `tasks.md`。local mode 按五条约束评估后判定为"不推荐"，理由是 SVG 字符串全程逃逸 + `Chart` 接口无法做 mode 重载。

未跑构建与测试（只读审查），所有涉及运行时耗时的判断均已降级；`OrgChart.cj` 使用 `maxFloat` 而未显式 `import std.math`，因同模块另有三处同写法且模块已有编译产物，未按编译错误处理。

**第 32 部分**：本部分代码整体结构统一：每张图都是"`ChartConfig.parse` → 逐项校验 → 建 `SvgBuilder` → 落图元"的线性流程，错误路径基本都用 `chartInvalidValue(path, 文案)` 带出精确字段路径，测试覆盖了计数、类型判别和主要非法输入，可读性好。风险集中在三处：

1. **唯一阻塞项是 `PictogramChart` 的图标数放大**（#1）：一个 `unit` 字段即可把 60 字节输入变成 10^12 次循环与同量 DOM，属可直接打挂进程的路径，建议优先修。
2. **一组"看着对、其实反了/没了"的渲染缺陷**（#2 单扇区 100% 空白、#3 小画布负半径与反转、#4 PDP/PR x 轴镜像）：都源于几何算式缺少退化分支，且测试只断言图元个数与字符串包含，坐标与可见性完全没有校验——这也是这批问题能长期存在的原因。建议补"坐标断言"类用例（首末刻度像素位置、单类目/单点/全零输入）。
3. **契约层面的两处文档漂移**（#5 `cumulativeFormat`、#6 `pie.innerRadius`）和**一份整段复制的实现**（#7 QQ/Probability）：前者让按文档配置的用户静默失效，后者让后续修复天然只改一半，属于必须排期的技术债但不阻塞发布。

死代码（2 个只写字段）与重复逻辑（插入排序 9 份、测试 helper 106 份）量级清楚、影响可控，可随下次触碰文件时顺手收敛；插入排序的复杂度与全量 SVG 物化的峰值内存都还缺测量数据，本轮只作为「待验证假设」登记，不构成缺陷。

**第 33 部分**：这 9 张图的整体结构是健康的：输入校验密集（每个字段都有 `path` 级定位与 `ChartException` 分类）、无递归、无全局可变状态、无锁，`draw` 基本满足 `Chart` 契约要求的纯函数语义；测试覆盖面在「参数校验」维度上相当扎实（每图 6–10 条用例，缺字段/错类型/越界/确定性都有）。

风险集中在两处：

1. **坐标方向**。`LinearScale` 的 `(topPixel, bottomPixel)` 参数顺序与其文档语义（`topPixel`=最大值）要求 x 轴必须反着传，而模块内 30 处调用各写一半。本部分的 `RocChart.cj:123`、`ResidualChart.cj:112` 落在错误的一半上，ROC 曲线与残差图整体左右镜像；测试只看元素个数，完全拦不住。这是本轮唯一建议优先修的阻塞项，且应连带把另外 13 处同类调用一起核对（范围外提示）。
2. **契约漂移**。同一份 JSON 在 9 张图里有 3 种「空数据」处理（抛 `InvalidValue`、抛 `MissingField`、静默出空图）、2 种图例开关语义（看 `legend.show` 与只看系列数）、3 套标题绘制（`ChartFrame.drawTitle` 与 3 处手写且忽略 `subtitle`/`titleAlign`）。这些单独看都是「轻微」，合起来意味着调用方无法对 `f_chart` 建立统一预期，建议在合并后的模块报告里作为一条「契约统一」专项排期。

其余（桑基越界、玫瑰图小画布、插入排序与轴样板重复）可排期处理：桑基与玫瑰属边界补强，重复样板属 47 文件级的收敛工作，收益是可维护性而非性能。所有性能相关结论本轮均无基线，只进了「待验证假设」，不作为缺陷计入统计。

**第 34 部分**：这 10 个图类型的输入校验与 SVG 组装整体是扎实的：解析全部走 `ChartJson`（路径化错误信息）、坐标计算统一用 `LinearScale`/`BandScale`、文本全部经过 `f_svg` 转义、测试覆盖了主要校验分支与确定性，没有发现数据竞争或崩溃级缺陷。

主要风险集中在三处。第一是**边界与布局**：`stem-leaf` 的行/列完全不做画布约束（README 承诺的换列不存在），`sunburst` 对单节点输入输出空图、对环状引用静默丢节点，`sequence` 自调用消息没有箭头——这些都不是数据错误，但会让"按文档用"的用户拿到错误或空白的图。第二是**错误契约不完整**：极大但有限的数值会在下游溢出成 `NaN`/`Int64` 溢出，抛出 `SvgException` 或数值异常，与 README:255「任何数值问题都以 `ChartException` 抛出」冲突，调用方的统一 `catch` 会漏。第三是**通用原语重复**：22 处手写插入排序、多处 O(n²) 去重/查找、`StackedArea` 重复算分组，目前规模下影响有限，但已成为行为漂移的来源（`StemLeaf` 已有三份不完全一致的校验）。

没有阻塞项：全部 17 条为存量，严重度均在"一般/轻微"，可排期处理；建议优先做 `stem-leaf` 布局与 `ChartException` 契约收敛（改动小、用户可感知），排序/去重原语与堆内存优化放到性能预算里按「优化可行性方案」的验证方式推进——这些方案的收益目前都还没有基线，不能当结论用。本部分未覆盖的同模块其他图表也存在同一问题（模块内共 17 个文件自绘标题，其中本部分 2 个），合并时建议按根因合并成模块级条目。

**第 35 部分**：9 个图实现里，Swimlane、Timeline（除 `group` 着色）、Violin、ViolinBox、Volcano（除轴方向）、Waffle（除规模上限）、Waterfall 的结构与校验都整齐：空输入、类型不符、重复 id、悬空引用、非法枚举、非数值元素都有显式 `ChartException`，`chartNiceTicks`/`gaussianKde`/`defaultBandwidth`/`quantileSorted` 这些共享工具对 NaN、Inf、零方差都做了保护，本部分未见静默吞异常与资源泄漏面。

阻塞项集中在 `TreemapChart`：面积切分算法与「面积 ∝ 数值」的核心语义不符（实测 6.9:1 的面积比对应 2.17:1 的值比、38% 画布空白），并且递归深度不设限、父链成环/叶子缺值静默丢节点、用实例字段存绘制状态破坏 `Chart` 纯函数契约——这一张图建议整体重写布局与状态管理，其余问题可排期。`TimelineChart` 的 `group` 哈希溢出是第二处必修项：13 个字符的标签就会抛非 `ChartException`，属于随时会被真实数据踩到的崩溃。第三类可排期问题是 `ViolinChart`/`ViolinBoxChart` 与三个数值工具的整段复制，以及 treemap/waffle 绕过 `ChartFrame` 造成的标题、图例行为漂移——这类问题不修不会出错，但会让后续每一处修改都要改 3-4 遍。

性能侧本部分没有 profile 或 bench 数据，故只登记 3 条优化候选与 4 条待验证假设，未写成缺陷。

**第 36 部分**：本部分（词云 / 词网络 + 7 个 TUI 图表及其公共层）是「纯计算 + 自绘字符网格」的形态：没有全局可变状态、没有锁、没有递归、没有资源句柄，所有输入都走 `ChartJson` 的带路径校验，非法输入基本都能抛 `InvalidValue`/`MissingField`；`TuiCellChart` 的「逐单元格 vs ANSI 逐行一致」断言也是同类项目里少见的扎实写法。基础质量明显高于平均水平，本部分没有阻塞级缺陷。

风险集中在三处：

1. **数值口径不统一**。百分比堆叠对负值的处理与普通堆叠不同（静默丢弃），而 combo 复制了同一份逻辑，于是「同一份数据换一个 `type` 就少一层柱」。这条与下一条是本部分最值得先修的：它不报错、不崩溃，只让读图结论错。
2. **组合图的槽位分组只看 `stack` 不看 `axis`**，左右轴同组时整槽按首系列的比例尺投影，属于「配置可触发的静默错图」；现有用例根本没有跨轴组合，测试拦不住。
3. **边界与资源**。TUI 画布 `width×height` 没有任何上限，`Chart` 是对外接口，一次超大尺寸请求就能把进程打到 OOM；词云的 `-90` 旋转与「盒 vs 绘图区」两处只在极端参数下暴露，属可排期的边界补强。`tuiStripAnsi` 的死循环只影响测试工具链，但改起来只要一行。

可排期的还有重复逻辑收敛（堆叠累积两份、长度校验三份、夹取四份）：它们的收益是可维护性——本次修「负值口径」必须同时改两处，已经能说明问题。所有性能结论（插入排序、力导向线性查找、画布分配）本轮都没有 `-O2` 前后对照，只进了「优化可行性方案（无基线）」与「待验证假设」，不作为缺陷统计。

**第 37 部分**：本部分是 TUI 渲染层的最后一组文件：`TuiFrame` 的坐标推导（标题/副标题/图例/轴标题与 `height` 的配平）逐分支核对后是自洽的，`TuiPointCommon` 的三路解析与 `null` 语义、火焰图的列区间取整与裁剪都写得干净，测试密度也高于模块平均水平（13 个文件里 7 个是用例，负例覆盖到位）。

真正的阻塞项只有一条：画布尺寸从 JSON 一路无校验地转成 `Int64` 再按 `width × height` 分配，既是 OOM 面也是 `ChartException` 契约的漏口，建议按「严重」优先修。第二梯队是火焰图的树校验——环检测分支实际不可达、含环输入静默丢节点、递归深度由输入决定，这三件事同源，且因为解析/校验逻辑与 SVG 版 `FlameChart` 整段复制而在两处同时存在，合并助手后一次修完最划算。控制字符未过滤属于终端输出层的普遍问题（`TuiCanvas` 一处修、全体受益），单独排期即可。

其余 7 条轻微项（两个死符号、一个多余 import、错误 path 固定写 `width`、图例配置半生效、`tuiRuneWidth` 近似、两条弱断言、测试辅助复制）都是清理级别，不阻塞发布。两条优化方案均无改前基线，只能等下一轮补 `cjprof`/分配量数据后再决定是否进任务清单。
