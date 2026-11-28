# f_chart 模块审查报告（模块第 2/37 部分）

> **模块第 2/37 部分**（分报告）。本部分只覆盖 `f_chart/README_en.md` 一个文件；
> 同模块其余文件见 `parts/f_chart.part1.md`、`part3+`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（模块合计 251 个 `.cj` / 444 个 `.md`；**本部分** 0 个 `.cj` / 1 个 `.md）
- **本部分范围**：`f_chart/README_en.md`（3156 行、108 KB，121 个代码块，其中 110 个是 JSON 示例，覆盖 102 个实现文件 / 107 个里程碑小节）
- **基线**：工作区快照（`git diff` 为空，master 与 sts/1.3.x 同一提交），所有问题来源均为「存量」；本文件最后提交 `7b1f9dbee6`（2026-11-11）
- **审查重点**：文档一致性（§13）、功能完备性与 README 覆盖（§14）、示例可用性；渲染/布局算法、OOM、并发在代码侧取证，不占本部分统计
- **报告版本**：v1（模块分报告；不写 `docs/review/` 下的模块报告）

## 发现

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

## 优化可行性方案

> 本部分唯一文件是英文 README，没有可改的 `.cj`，因此**堆内存 0 条 / CPU 0 条**。核对时读到的 `pathCentroid`（`ChoroplethChart.cj:176`）对每个 region 做一次全路径字符扫描，输入规模是 region 数 × 路径点数、只在 `draw` 时跑一次，没有 profile 数据，不构成优化项；性能类结论一律见「待验证假设」。

### [维护性] 用一条单测把「文档字段表 ↔ 源码解析键」双向锁死

- **现状**：`README_en.md` 3156 行、110 个 JSON 示例、169 个源码解析键，全靠人工同步。本轮机械比对就抓到 10 个字段漏文档（#7）、3 处字段有文档无实现（#2、#3、#4）、1 处能力过描述（#1）——都是"改了代码没改文档"的同一根因
- **方案**：新增 `f_chart/src/ChartDocs_test.cj`：①断言 README 里 102 个 `f_chart/src/*.cj` 路径都存在（本轮 102/102 通过）；②用 `JsonValue.fromStr` 解析全部 110 个 ` ```json ` 块（本轮 0 个坏块），断言 `type` 在支持集合内；③提取源码全部 `<field>("…")` 字段名与 README 全文求差集，非空即失败（本轮会精确报出 #7 的 10 个）；④反向维护一份"已文档化但实现忽略"的白名单（`series[].label`、`lane`、`features`、combo 的 `area`），新条目必须显式登记，逼作者二选一（接线或删文档）
- **预期**：把 #1–#4、#7 从"下轮人工发现"变成提交即红；102 个实现文件与 102 条附录条目目前是人肉维持的不变量，可交由测试守护
- **代价**：约 100-150 行测试 + 一份白名单；字段名提取用正则，动态拼键需白名单；测试从"只依赖 src"变成"依赖仓库根文件"，只打包 `src` 的发布流程需跳过该用例
- **验证**：`cd f_chart && cjpm test` 全绿；人为删掉 README 里一个字段名，用例应精确报出该字段
- **证据状态**：`无基线（新增能力，非性能项，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 实跑用例数为 1173（TUI 81），文档 1168/76 已过期 | `f_chart/README_en.md:176` | 一次完整测试运行的 summary | WSL Ubuntu `source cangjie.sh` 后 `cd f_chart && cjpm test`，记录总数与 TUI 子包分段 |
| 2 | `charts/` 下 107 个 SVG 与当前源码一致（文档称改动会出现在 `git diff`） | `f_chart/README_en.md:191` | 重新生成后的 diff 是否为空 | `cjpm test --skip-build` 后 `git status charts/`，应为 0 改动 |
| 3 | M45/M46/M88/M89 改成嵌套数组后渲染 3 组 | `README_en.md:1115`、`:1133`、`:1035`、`:1053` | 改前/改后分组元素计数 | 两版 JSON 各生成一次，比较分组 `<rect>`/`<circle>` 数量与 x 轴标签数 |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part2.txt` 一一对应（本部分清单只有 1 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/README_en.md` | .md | ✅ | 3156 行逐段读完（含附录 5.1–5.11 与 TUI 附录）；与 `README.md` 做了标题/条目数/代码块键序列的机械比对；102 个实现路径、110 个 JSON 块、181 个示例键逐个回查 `src/` |

合计：`.cj` 0 个 / `.md` 1 个 / 共 1 个，全部读完。
（`README.md`、`doc/**` 与全部 `.cj` 属其他部分，仅作对照取证，不占本部分统计。）

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 13 条（严重 0 / 一般 7 / 轻微 6），是否纳入修复待用户决定。

## 总评

`README_en.md` 的**结构与覆盖度扎实**：3156 行、139 个标题与中文版逐节对齐，102 个实现文件与 102 条附录条目一一对应，110 个 JSON 示例全部是合法 JSON，181 个示例键全部能在源码里找到解析点，107 个样例 SVG 与状态表完全吻合，相对链接零失效——"漏掉整张图/整节内容"这类硬伤不存在。

风险集中在**文档与代码的最后一段距离**，而且是同一个模式：文档写了、实现没接，且不报错。三处"能力不存在"（combo 的 `area`、柱顶数值标签 `series[].label`、甘特图泳道 `lane`）与三处"字段不存在但示例带着"（SHAP `features`、M33 形状码、分布类多组标签）都会让使用者拿到与预期不同的图或直接吃异常，其中 `area` 与 `series[].label` 是文档自己反复承诺（字段表 + 图说明 + 规格文档）却完全没有实现的，建议优先二选一：接线或删文档。反向问题是 10 个已实现配置项（`legendTextColor`、`upColor`/`downColor`、`shade`/`std` 等）在 README 里查不到，导致 M97 的 ±SD 带这类"正文提到效果、没给字段"的能力实际无法使用。

错误语义（#6）值得单独排期：它会让调用方按文档写的 `catch (ChartException)` 漏接 `f_data::JsonException`，是唯一会在生产环境表现为"未捕获异常"的一条。其余为过期计数、形状码、质心近似、英文缺一条别名、API 小节残段与 `--skip-build` 语义，属随手可改的精度问题。

本部分无 `.cj` 代码，未对渲染/布局算法、OOM、内存做独立判定（由同模块其他部分覆盖）；未跑构建与测试，凡涉及运行时结论均已降级为「待验证假设」。

## 范围外提示（不计入本部分统计）

- `f_chart/src/tui/TuiFrame.cj:71-73`：`width < 20 || height < 8` 统一抛 `path: "width"`，高度越界时调用方会去改宽度（README 的"最小 20×8"承诺本身成立，只是异常路径不准）。
- `f_chart/src/ChartScale.cj:94-95`：`chartNiceTicks` 用 `floor/ceil` 扩展首末刻度但调用方未把轴域扩到 `[start, stop]`，越界刻度画到画布外——产物证据：`charts/M001-bar.svg` 里 `300` 的刻度标签在 `y="-25.14"`（负坐标、不可见），属坐标/边界类缺陷，建议并入对应 `.cj` 部分的发现。
- `f_chart/src/ChoroplethChart.cj:195-197`：坐标解析失败时 `catch (_: Exception) { () }` 静默丢弃该数字（与 #10 同函数，属代码侧问题）。
- `f_chart/src/BoxScatterChart.cj:82-89`：扁平 `data` 时多余 `xAxis.labels` 被静默忽略且不校验（文档侧记为 #5，代码侧是否该抛错待合并时定）。
