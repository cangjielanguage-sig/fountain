# f_excel 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（122 个文件：79 个 .cj + 43 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 8 个分部分报告合并：`parts/f_excel.part1..8.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] (1) `README_en.md` 的「Known gaps (M1 scope)」整节过期：把已实现的样式与公式写成未实现

- **位置**：`f_excel/README_en.md:536-546`（关键两条 `:538`、`:539`）；对照 `f_excel/README.md:519-531`
- **来源**：存量（`7de0791bd`，工作区无改动）
- **判据**：review-checklist §13「`README_en.md` 与 `README.md` 不同步：两版结论相反」；§14.1「承诺了但没实现 / 实现已存在但文档否认」
- **证据**：静态确定 —— 英文版 `:538` 写「Styles: only date `numFmtId` and a fixed minimal `styles.xml`; fonts / fills / borders / alignment / theme colors are M2」，`:539` 写「Formulas: source and cached value only; no evaluation, no dependency graph」。实现侧有 `src/StylesLite.cj:83-236`（numFmts/fonts/fills/borders/cellXfs/cellStyles 全量解析）、`src/StylePool.cj:123-466`（完整 `styles.xml` 写出）、`src/CalcEngine.cj:100-196`（求值 + 重算）、`src/DependencyGraph.cj`。中文版 `README.md:521-522` 已改写为「theme1.xml 只按 tint 线性插值 / 动态数组只做到函数返回数组」，两版结论相反
- **描述**：英文读者按该节会判断「样式只有日期格式、公式完全不能算」，从而放弃使用或在外层重复实现样式/公式；`README_en.md:26` 与 `:550` 又写 192 条测试全绿，与「公式未实现」自相矛盾。该节是模块对外契约的一部分，不是历史归档，也没有「已过期」标记
- **建议**：以 `README.md:519-531` 为基准整节重译并逐条对齐（保留「紧凑存储 3 MB / 29 MB」「稠密/稀疏」两条中文独有的缺口）；章节标题去掉 `M1 scope`，改为 `Known gaps`；若短期无法同步，至少在英文版顶部标注「out of date, see README.md」

### [一般][存量] (2) 「能力（M1）」标题下混入 M2–M4 能力，同一文件又与「已知缺口（M1 范围）」冲突

- **位置**：`f_excel/README.md:10`（标题）、`:21-24`（样式全量 / 350 函数 / 条件格式 / 时长）、`:519`（缺口标题）
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §13「文档过期：描述的功能已扩展 / 规格与实现漂移」、§14.2「缺关键段落 / 章节口径错位」
- **证据**：静态确定 —— `:21` 声明「`styles.xml` 的 numFmts/fonts/fills/borders/cellXfs/cellStyles；样式池按值去重」、`:22`「350 个函数；共享公式平移；循环引用 `#CIRC!`」、`:24`「13 种 `CfRuleType` / dxfs 解析与写回」，而同一文件 `:519` 的缺口小节标题是「已知缺口（M1 范围）」，`:521-522` 又以「M1 范围」口吻描述样式与公式的残留限制。设计文档第 12 章（`doc/f_excel模块设计.md:2806-2864`）明确把样式/公式排 M2、条件格式排 M4、350 函数排 M3-c
- **描述**：同一份 README 同时声称「M1 能力」与「M1 缺口」，读者无法判断某个 API 是否可用；能力表还漏了 M3 已落地的 `eager=false`、`sharedStringsIndex`、紧凑单元格存储（这些只在「用法」示例与设计第 17 章出现，能力表未列）
- **建议**：标题改为「能力（M1–M4）」或按里程碑拆三张表，每行标注所属里程碑；缺口章节改为「当前已知缺口」，逐项与能力表对应（哪些是永久取舍、哪些是待办）

### [一般][存量] (3) 设计文档 §2.2 / §7.4 / §7.6 仍是设计稿：公开 API、值模型、报告结构都与实现不一致

- **位置**：`f_excel/doc/f_excel模块设计.md:246-328`（§2.2 接口）、`:2224-2242`（§7.4 `CalcValue` / `CalcError`）、`:2332-2358`（§7.6 `CalcOptions` / `CalcReport` / `CalcIssue`）
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例代码不能用」
- **证据**：静态确定 ——
  - §2.2 的 `ExcelDocument` 成员 `properties: DocumentProperties`、`recalculate(...)`、`evaluate(sheet, ref)`、`styleOf(sheet, ref)`、`setStyle(sheet, ref, ...)`、`theme()` 在 `src/ExcelDocument.cj:30-315` 都不存在（该类只有 `sheets` / `sheet` / `sheetAt` / `sheetCount` / `addSheet` / `removeSheet` / `renameSheet` / `date1904` / `warnings` / `write`；`recalculate` / `evaluate` 只挂在 `CalcEngine` 上，`styleOf` 只挂在 `Worksheet` 上）；
  - §2.2 的 `Worksheet` 成员 `columnWidth` / `setColumnWidth` / `rowHeight` / `setRowHeight` 在 `src/Worksheet.cj:27-471` 不存在（`src/` 全文搜这四个名字零命中）；
  - §2.3 写 `RichText` 是 `class` + `runs: Array<TextRun>`，实现是 `struct` + `ArrayList<TextRun>`（`src/RichText.cj:75-80`）；
  - §7.4 写 `CalcValue.Bool` / `Array(...)`、`CalcError` 8 个分支，实现是 `Boolean` / `ArrayValue`、11 个分支（含 `Circular` / `Spill` / `Calc`，`src/CalcValue.cj:85-91`）；
  - §7.6 写 `CalcReport(evaluated, cached, elapsedMs, issues: Array<CalcIssue>)` 与 `CalcOptions(maxIterations, convergence, volatileSeed, writeBack, timeLimitMs)`，实现是 `CalcReport(recalculated, errors, cycles: ArrayList<String>, issues: ArrayList<String>)`（`src/CalcEngine.cj:21-29`），`recalculate` 只有 `sheet` / `writeBack` 两个具名参数（`:141`），`CalcOptions` / `CalcIssue` 在 `src/` 无定义
- **描述**：文档头部（`:3`）声明「v0.15 / 状态：M1–M4 已实施」，正文却保留实施前的 API 与值模型。读者按 §7.6.3 的 `maxIterations > 0` 做循环引用迭代，编译期就会发现参数不存在；按 §2.2 写 `doc.recalculate()` 也编译不过。这类漂移比「写得少」更有害，因为它给出的是错误签名
- **建议**：§2.2 顶部加「设计稿：最终 API 以 README 与 `src/` 声明为准」；§7.4 / §7.6 按实现重写，并把「迭代计算 / 时间上限 / 缓存命中统计」标为未实现（或补实现）；合并报告时与 `part4`（`CalcEngine.cj`）的存量缺陷条目交叉引用

### [一般][存量] (4) 设计文档的读取/写出选项与样式上限与实现不符：平台分档、告警阈值、`columns`/`freezePane` 均未落地

- **位置**：`f_excel/doc/f_excel模块设计.md:447-476`（§2.5，含 `:463` 的 `loadTheme`）、`:649-708`（§2.6.4.1 平台分档 / `lowMemory()`）、`:2883-2898`（§13.1「已定」表）；对照 `f_excel/src/ExcelOptions.cj:21-73`、`src/StylePool.cj:101-120`
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §13「配置项 / 默认值与源码不符」、§14.1「接线缺失：配置项被读取却从未使用」
- **证据**：静态确定 ——
  - `ExcelReadOptions` 没有 `loadTheme` 字段（`ExcelOptions.cj:21-37`），`src/` 全文搜 `loadTheme` 零命中；
  - `SheetWriteOptions` 只有 `dimension` 与 `maxCellStyles`，后者硬编码 `64000`（`ExcelOptions.cj:66-73`），没有 `styleBytesWarnThreshold`、`columns`、`freezePane`，也没有 `defaultMaxCellStyles()` / `defaultStyleWarnBytes()` / `lowMemory()`（`src/` 零命中）；
  - 超限文案只有一版：`StylePool.cj:109-114` 统一提示「Linux 上限 64000，其他平台 8192」，没有 §2.6.4.5 要求的「`maxCellStyles >= 64000` 说 Excel 打不开 / 否则说本平台保护」两版分支
- **描述**：§13.1 把「Linux 64000、其他 8192」「阈值 16 MB / 2 MB」列为**已定事项**，实现却是全平台 64000、无字节告警、无 `lowMemory()`。OHOS 使用者按文档预期 8192 上限与实际行为不符；`README.md:484-487` 又只写 `maxCellStyles = 64000`，与设计文档正面冲突，两份对外文档必有一份误导
- **建议**：以实现为准回填 §2.5 / §2.6.4.1 / §13.1（注明「平台分档与字节告警为设计目标，未实现」），或补 `@When[os]` 与两版文案；`README.md` 的「选项」段补一句「`maxCellStyles` 在所有平台默认 64000，无平台区分」

### [一般][存量] (5) 已知缺口写「theme1.xml 只按 tint 线性插值」，实现完全不读 theme1.xml

- **位置**：`f_excel/README.md:521`；对照 `f_excel/src/Style.cj:183`、`src/StylesLite.cj:259-266`
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §13「描述的功能与实现不符」、§14.1「承诺了但没实现（半成品口径）」
- **证据**：静态确定 —— `src/` 全文搜 `theme1` 零命中；`Color.Theme(theme, tint)` 只在读取时原样保留（`StylesLite.cj:262-266`），写入时把 `tint` 原样写回属性（`StylePool.cj:394-397`），没有 RGB→HLS→RGB 的插值函数。`Style.cj:183` 的注释与实现一致：「读取侧不做『主题色 → RGB』的展开」
- **描述**：文档把「完全没做」写成「做了一半（只按 tint 插值）」。调用方看到 `Color.Theme` 会以为颜色已按 tint 校正，直接用于渲染就会得到错误颜色；设计 §6.5.1 的「必须解析 theme1.xml」与 §6.5.2 的 tint 算法也没有落地记录
- **建议**：缺口条目改为「`theme1.xml` 未解析；`Color.Theme(index, tint)` 原样保留，需渲染方自行解析主题色板并应用 tint」；若短期实现，按设计 §6.5.1 / §6.5.2 补 theme 解析与 tint 单测（§11.6 已列测试点）

### [一般][存量] (6) `ExcelStreamReadOptions.loadRowHeight` 在文档里是可关开关，实现从未读取

- **位置**：`f_excel/README.md:470`；对照 `f_excel/src/ExcelOptions.cj:44`、`src/ExcelSheetStream.cj:314-326`、`src/WorksheetParser.cj:319-322`
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §14.1「配置项被读取却从未使用 / 接线缺失」、§13「配置与源码不符」
- **证据**：静态确定 —— 全仓 `loadRowHeight` 只出现在 `ExcelOptions.cj:44` 的声明与 README；`ExcelSheetStream.streamOptions()` 把流式选项转成 `ExcelReadOptions` 时没用这个字段（`ExcelReadOptions` 也没有对应项），`SheetRowHandler` 无条件解析 `ht`（`WorksheetParser.cj:319-322`），行高总是进 `RowData.height`
- **描述**：开关名叫「是否加载行高」，文档暗示 `false` 可省内存/跳过属性解析，实际设与不设行为完全相同，也不会记 warning。用户按文档关掉后看不到任何效果，只能怀疑库有 bug
- **建议**：要么把开关接到 `SheetRowHandler`（`false` 时不读 `ht`、`RowData.height = None`），要么从 `ExcelStreamReadOptions` 与 README 中删除；不要保留「声明了但无声失效」的配置项（设计 §14.1 第 2 条自己就反对这种形态）

### [一般][存量] (7) `eager=false` + `InputStream` 的 spool 临时文件没有清理路径，README 未说明

- **位置**：`f_excel/README.md:203`；对照 `f_excel/src/ExcelDocument.cj:42-46`、`:319-341`；设计自认在 `doc/f_excel模块设计.md:3068`
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §11「资源不对称：打开未关」、§5「临时文件 / 长期持有」、§14.2「限制与注意事项缺失」
- **证据**：静态确定 —— `init(input, options: eager=false)` 调 `spoolInput(input)` 生成临时文件并把路径存进 `lazyPath`（`ExcelDocument.cj:34`、`:45-46`）；`ExcelDocument` 没有 `close()` / `dispose()` / 析构，`removeIfExists` 只出现在 `spoolInput` 的**失败**分支（`:336`）。设计 §17.5 已写明「`ExcelDocument` 无 `close()`，`InputStream` spool 的临时文件在进程结束前保留」
- **描述**：每读一个 `InputStream`（典型场景：HTTP 上传、消息附件）就在系统临时目录留下一个与源文件等大的 xlsx，长跑服务按请求读会让磁盘无界增长；这对「知识库导入」类批处理尤其明显。README 只说「`InputStream` 输入会先落临时文件」，没写谁负责删、活多久
- **建议**：实现上增加幂等 `ExcelDocument.close()`（仅删除自建 spool 文件，`path` 构造不得删用户文件），懒加载源改为持有可关闭句柄；文档上在 `:203` 补「spool 文件的生命周期：调用 `close()` 删除；未调用则保留到进程结束」

### [一般][存量] (8) 流式读「常驻内存只随 sharedStrings 增长」的口径漏掉建索引前的整部件峰值

- **位置**：`f_excel/README.md:530`（另见 `:311` 的 `sharedStringsIndex` 说明）；设计 `doc/f_excel模块设计.md:3044`；对照 `f_excel/src/ExcelSheetStream.cj:228-235`、`src/SharedStringIndex.cj:45-73`
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §5「一次性物化：整文件读入」、§13「文档与实现口径不一致」
- **证据**：静态确定（路径）+ 需实测（峰值倍数）—— `build()` 里 `zip.read("xl/sharedStrings.xml")` 返回完整 `Array<Byte>` 后才进 `SharedStringIndex.build(bytes)`；`build` 先 `scan(bytes, ...)` 全量扫一遍，再把同一份 `bytes` 写入临时文件，之后才允许释放（`SharedStringIndex.cj:45-48`、`:60`）。索引省的是**打开之后**的常驻，不省 **open 期间**的峰值
- **描述**：README 的「流式读的常驻内存：只有 sharedStrings 随文件增长」容易被读成「开了 `sharedStringsIndex` 就没有大内存项」。实际 100 MB 的 `sharedStrings.xml` 在 open 时至少完整解压一份（叠加 f_zip 解压缓冲），峰值与文件大小成正比；设计 §17.1 的「内存只保留每个 `<si>` 的 offset/length」只描述了稳态
- **建议**：README 该条补「索引模式在 open 期间仍需完整解压 `sharedStrings.xml` 一次，峰值约为该部件大小」；中期把建索引改成流式 scan（边解压边写临时文件 + 记 offset），彻底去掉整部件 `Array<Byte>`

### [一般][存量] (9) 「其他公开 API」段落把类型成员标成模块级，并含截断签名

- **位置**：`f_excel/README.md:546`（`README_en.md:561` 同）
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §13「示例 / 签名不能用」、§14.2「公开 API 未文档化：列出符号却无法定位」
- **证据**：静态确定 —— 该段首行写「模块级：… `public var currentSheet: String =`、`eval`、`formulaAt`、`get`、`public let impl: FnImpl`、`maxArgs`、`minArgs`、`public let now: DateTime`、`number`、`resolver`、`valueAt` …」。其中 `currentSheet` 是 `DocumentResolver` 的成员（`src/CalcEngine.cj:51`），`valueAt` / `sheetExists` / `usedBounds` / `formulaAt` 也在同一个类（`:55-84`），`DocumentResolver` 是 `internal class`；`public var currentSheet: String =` 停在赋值号上、没有初始值，属于被截断的签名
- **描述**：这段像是符号表导出的结果：读者按「模块级」去找 `f_excel.currentSheet` 会找不到，截断项也无法照抄；真正需要文档化的公开成员（如 `CellStyle.withBorder`、`CalcEngine` 的 `document()`）反而没有说明。§14.2 要求的「点名符号 + 说明影响」在这里变成了一份不可用的清单
- **建议**：按「类型 → 成员」重排（`CalcEngine` / `DocumentResolver` / `Evaluator` / `FnEntry` 分组），补齐类型名与可见性；或删掉该段，改为「未在上文展开的公开声明见 `src/` 对应文件」并只保留真正模块级的 `BorderStyle` / `Horizontal` / `PatternType` / `Underline` / `Vertical` 等枚举

### [一般][存量] (10) 文档未声明 `CalcEngine` / `ExcelDocument` / `Worksheet` 的线程安全边界，而求值期会改写实例状态

- **位置**：`f_excel/README.md` 全文（无「线程安全 / 并发」章节）；对照 `f_excel/src/CalcEngine.cj:117-123`、`:141-146`、`:273-276`、`:338-348`；设计仅在 `doc/f_excel模块设计.md:1159` 约定流式 reader
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §12.1「共享可变状态无保护」、§14.2「缺关键段落：限制与注意事项」；本文件铁律「并发默认按会被多线程调用审」
- **证据**：静态确定（状态改写路径）—— `evaluate` 每次重置实例字段 `memo` / `inProgress` / `cycleCells` / `issues` / `evaluator`（`CalcEngine.cj:117-121`），并改写 `resolver.currentSheet`（`:122`）；`recalculate` 同样重置（`:142-146`），在遍历中反复改 `resolver.currentSheet` 并在嵌套求值前后保存/恢复（`:162`、`:273-276`、`:338-348`）。`CalcEngine` 没有任何锁或线程封闭，README 也没有声明「非线程安全」
- **描述**：fountain 是服务端库，`ExcelDocument` / `CalcEngine` 很自然会被当成单例复用。两个线程共用一个 `CalcEngine` 时，后进入者会清空前者的 `memo`/`inProgress`，`currentSheet` 被串改会让 `A1` 这类无表名引用解析到别人的表，甚至把正常公式误判成循环引用。实现可以保持非线程安全（这是合理设计），但**契约必须写出来**，否则调用方没有依据去加锁或按请求新建
- **建议**：README 增加「线程安全」段：`ExcelDocument` / `Worksheet` / `CalcEngine` / `ExcelWriter` 非线程安全，需按请求新建或在外部串行化；`ExcelSheetStream` 同一 reader 不可并发 `next()`（设计 2.7.7 已有，可上移到 README）；`RowReader` 之间可顺序交替

### [轻微][存量] (11) 已知缺口重复两条「富文本」，且与公开 API `setRichText` 的存在矛盾

- **位置**：`f_excel/README.md:524-525`（逐字重复）、`:450-451`（「`RichText` 只读」）、`:237`（列出 `setRichText`）
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §2「重复逻辑：同一结论两处」、§13「文档自相矛盾」
- **证据**：静态确定 —— `:524` 与 `:525` 文本完全相同；`:450` 写「`RichText` 只读」，`:237` 的 API 表却列 `public func setRichText(row, col, value: RichText)`，实现见 `src/Worksheet.cj:279-285`（只写内存模型，不落盘）
- **描述**：重复条目让缺口清单看起来更长；「只读」与 `setRichText` 并存会让读者怀疑方法是否真的生效
- **建议**：删掉重复行；把该条改成「富文本：读可分段；`setRichText` 仅修改内存模型，写出仍平坦化为 `inlineStr`（样式丢失）」

### [轻微][存量] (12) 设计文档 §5.5.4 残留被本节结论推翻的写法与破损表格；§17.4 是空标题

- **位置**：`f_excel/doc/f_excel模块设计.md:1685-1689`（孤立表格行）、`:1693-1703`（用 `Duration.Max.toNanoseconds()` 当上界的旧实现）、`:3061-3063`（§17.4「差异」空标题 + §17.5 同名小节）
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §3「空实现 / 占位」、§2「重复」、§13「文档过期」
- **证据**：静态确定 —— `:1608` 明确写「不能拿 `Duration.Max.toNanoseconds()` 当上界比较——它自己就会抛」，`:1693-1699` 又给出 `let maxNanos = Duration.Max.toNanoseconds()` 的旧代码；`:1685-1689` 以 `---|---|` 开头，是上一个版本表格被删剩的表头分隔行；`:3061` 的 `### 17.4 差异` 下无任何内容，紧接 `### 17.5 差异` 才是真正的表格
- **描述**：同一节里同时存在「正确结论」和「被推翻的旧实现」，实施者按下面的代码抄就会踩到 §5.5.4 已经实测过的 `ArithmeticException`；破损表格在渲染时会把前后段落吞进表格
- **建议**：删除 `:1685-1703` 的旧版内容（保留 `:1607-1683` 的正确写法与双防线说明）；合并 17.4 / 17.5 为一个「差异」小节

### [轻微][存量] (13) 可核对的数字全部对不上：测试数 183/192/227、设计 137/147、函数 350/346/143

- **位置**：`f_excel/README.md:26`（183）与 `:535`（192）；`doc/f_excel模块设计.md:2988`（137）、`:3024`（147）、`:3051-3052`（350 / 147）；`src/FunctionRegistry.cj:415-490` 的函数名单数组
- **来源**：存量（`7de0791bd`）
- **判据**：review-checklist §13「文档过期：数字与当前实现不符」
- **证据**：静态确定 —— 同一份 README 两处测试数不同；`@Test` 属性静态计数 227（30 个 `*_test.cj` 逐文件相加），与 183 / 192 都不符；设计 §15.1 写 M2 共 143 个函数，§17.2 又写「其余为 M2 的 147」，而名单数组为 62 + 51 + 37 + 53 + 62 + 81 = 346（`EXTENDED` 81、`MATH_ENG` 62、`STAT_TEXT` 51、`DYN_FIN` 37、`DIST_DB` 53、`CORE` 62），与「350」差 4
- **描述**：这些数字是使用者判断成熟度的直接依据（「350 个函数」是选型理由之一），四个版本互相矛盾会让整份文档的可信度打折。注：`@Test` 计数不等于实际执行用例数（可能有参数化 / 条件编译），所以这里只能证明「文档之间不一致」，不能断言真实用例数
- **建议**：数字改为由脚本/CI 从 `cjpm test` 与注册表生成后写入，或删掉具体数字改为「覆盖全部公开 API，见 `cjpm test`」；设计文档内部统一 M2 基数（143 或 147 只留一个）

> 本部分存量缺陷 13 条（严重 0 / 一般 10 / 轻微 3），是否纳入修复待用户决定。

<!-- 第 2 部分 -->

### [严重][存量] `f-excel-rich-values`「富文本写出只丢样式」未实现：`setRichText` 后写出会丢文本，且没有承诺的 `RichTextFlattened` 告警

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-rich-values/spec.md:31-39`；
  实现 `f_excel/src/Worksheet.cj:279-285`（`setRichText` 只写 `richTexts` 表）、
  `f_excel/src/Worksheet.cj:271-277`（`richText` 只读该表）、
  写出路径 `f_excel/src/ExcelDocument.cj:365-370`（只遍历 `row.cells` 的 `CellValue`）、
  `f_excel/src/SheetXmlWriter.cj:107-125`（单元格取值只 match `cell.value`）
- **来源**：存量（快照模式；spec 来自 `ee178eb13`，代码与 spec 同期）
- **判据**：review-checklist §14.1「承诺了但没实现」＋ §3「公开契约承诺有行为，实现为空/语义缺失」；
  严重度表「数据丢失」
- **证据**：静态确定 —— ①`setRichText` 只做 `richTexts.add(key(row,col), value)`，**不写 `CellStore`**，
  也不会生成 `CellValue.Text`；②写侧唯一数据源是 `CellStore`（`ExcelDocument.write` → `SheetXmlWriter.writeCell`），
  全仓搜 `richTexts` 只有 `Worksheet.cj:33/276/284` 与读入路径 `ExcelDocument.cj:362-364` 命中，
  **没有任何写出侧读取**；③全仓搜 `RichTextFlattened`（`grep -rn` 覆盖 `.cj` 与全仓非 spec 文件）**零命中**，
  `ExcelWarningKind`（`ExcelException.cj:37-60`）也没有该分支
- **描述**：规格要求「M2 写侧 SHALL 继续写 `inlineStr`（平坦化文本）；富文本样式 SHALL NOT 丢失数据（只丢样式），
  并记一条 `RichTextFlattened` warning」。  实际调用方按契约只给 `setRichText` 时，该格在 `CellStore` 里没有值，
  写出的 worksheet 里**连 `<c>` 元素都不会出现** —— 文本整段丢失，比"只丢样式"严重一档。
  模块自己的用例反向印证了这一点：`M2d_test.cj:119-146` 的 `richTextFlattensOnWrite` 必须先
  `setRichText(...)` **再手工** `setCell("A1", CellValue.Text("粗细"))` 才能读到 `"粗细"`，
  即"平坦化"目前是调用方的责任，不是写侧的实现
- **建议**：二选一并在 spec/README 二选一同步：①写侧在 `writeCell` 遇到 `richTexts` 命中时，
  自建 `CellValue.Text(richText.text())` 并追加 `ExcelWarning(ControlChar.../RichTextFlattened)`（新增枚举值）；
  ②若确定不做，则把该 Requirement 改成"调用方必须在 `setCell` 同时提供平坦文本"，
  并把 `setRichText` 改成私有/内部或在其注释与 README 写清前置条件，同时去掉"记 `RichTextFlattened`"的承诺。
  无论哪条，都要补一条"只调 `setRichText` 就写出"的失败用例

### [严重][存量] `loadSharedStrings = false` 与规格承诺相反：不是"不报错"，而是**每格一条** `SharedStringIndexOutOfRange`，告警数组随单元格数线性增长

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-reader/spec.md:138`、
  `.../specs/f-excel-stream-read/spec.md:176`、`:179-182`、`:216-221`；
  实现 `f_excel/src/ExcelDocument.cj:111-114`（关闭时用 `SharedStringTable.empty()`）、
  `f_excel/src/SharedStringTable.cj:178-183`（空表 `get` 恒 `None`）、
  `f_excel/src/WorksheetParser.cj:486-497`（`None` 分支无条件追加告警）
- **来源**：存量（快照模式）
- **判据**：review-checklist §5「无界容器：随请求/行数增长，GC 后条目仍在」＋ §13「文档与实现相反」；
  严重度表「无界增长导致 OOM」
- **证据**：静态确定 —— 解析器**没有**检查 `options.loadSharedStrings`（全仓 `grep loadSharedStrings`
  只命中 `ExcelDocument.cj:112`、`ExcelSheetStream.cj:228/322`，`WorksheetParser.cj` 零命中），
  因此 `t="s"` 一律进 `sst.get(index)`；空表必返回 `None`，于是每格都 `warnings.add(...)`。
  全仓搜 `loadSharedStrings` 在 `*_test.cj` 中**零命中** —— 这条规格场景从未被用例固化
- **描述**：规格两处把它写成"不查表、不报错"、"所有文本格是 Empty，且没有 `SharedStringIndexOutOfRange`"，
  并进一步承诺"`loadSharedStrings = false` SHALL 把 `sharedStrings` 这一项也降为 0"、
  "内存峰值不随行数增长"。实际行为是：忽略该开关的"静默"语义，改为逐格生成告警对象。
  于是是一张 100 万行 × 10 列全文本表在该模式下会产生 1000 万条 `ExcelWarning`
  （每条含 kind + 中文消息串 + sheet 名，量级估算 ≥100 字节），峰值内存反而达到 GB 级 —— OOM 风险
  恰好出现在规格推荐用来读百万行的那个模式里，与"内存与行数无关"的承诺完全相反
- **建议**：`WorksheetParser` 增加 `sharedStringsDisabled: Bool` 参数（或在 `SharedStringsLookup` 上给
  `disabled` 标志），关闭时直接返回 `CellValue.Empty` 且**不记**告警；同时补规格场景用例
  （`loadSharedStrings = false` + 全是 `t="s"` → 断言 `warnings()` 为空）。若确实想保留提示，
  只允许记一条 summary 级告警（同 `StylesMissing` 的写法，`design.md:535-536`），不得逐格

### [一般][存量] `f-excel-reader`「缺 rels / 无对应 `r:id` → `SheetSkipped`」与实现（`SheetEntryMissing`）不符，且与 `cell-model` 的枚举定义互相矛盾

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-reader/spec.md:35-36`、`:43-46`；
  另一处口径 `.../specs/f-excel-cell-model/spec.md:214`（`SheetSkipped` = `skipSheets` 命中）；
  实现 `f_excel/src/PackageReader.cj:103-114`（两种缺失都记 `SheetEntryMissing`）、
  `f_excel/src/ExcelDocument.cj:145-148`（`SheetSkipped` 只用于 `skipSheets`）；
  既有用例 `f_excel/src/PackageReader_test.cj:86` 断言的也是 `SheetEntryMissing`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `PackageReader` 对"rels 里找不到 `r:id`"和"目标部件不存在"走**同一个**
  `if (partName.isEmpty() || !zip.contains(partName))` 分支，只产出 `SheetEntryMissing`；
  全仓 `SheetSkipped` 只有 `ExcelDocument.cj:147` 一处产出点，条件是 `options.skipSheets`
- **描述**：规格的场景"缺 rels 只丢 sheet … `warnings()` 含 2 条 `SheetSkipped`"按字面执行必然失败；
  调用方按 `kind` 过滤告警（例如"只关心配置跳过"）时也会拿到错误类别。三份文档三种说法
  （reader 两条都叫 `SheetSkipped`、cell-model 表把 `SheetSkipped` 定义为配置跳过、代码全叫 `SheetEntryMissing`）
- **建议**：以代码为准改 reader spec 的两处（`SheetSkipped` → `SheetEntryMissing`），
  并在 cell-model 的枚举表里补一句"rels 缺失/部件缺失统一记 `SheetEntryMissing`"；
  若要区分"rels 缺条目"与"部件不存在"，则新增一个 kind，同时补用例

### [一般][存量] `f-excel-reader`「只有三种致命情况」与实现不符：`workbook.xml.rels`、`sharedStrings.xml` 解析失败同样整体抛异常

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-reader/spec.md:311-322`；
  实现 `f_excel/src/PackageReader.cj:78-82`（`workbook.xml.rels` 解析失败 → 抛）、
  `f_excel/src/ExcelDocument.cj:114-118`（`sharedStrings.xml` 解析失败 → 抛）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13（文档承诺的容错边界与实现不符）、§11「错误处理缺失或静默 / 失败路径被放大」
- **证据**：静态确定 —— 两处都是 `throw ExcelException("...解析失败", e)`，没有降级分支；
  规格明确写"只有「不是有效 ZIP」「缺 `workbook.xml`」「`workbook.xml` 本身解析失败」三种情况 SHALL 抛"
- **描述**：一个坏掉的辅助部件（rels / sharedStrings 任一处 XML 语法错误）会让整本工作簿读不出来，
  这是比规格更严格的失败策略。对"数据救援"场景（用户拿到的正是损坏文件）影响明显：
  规格承诺"能读到单元格值"，实现可能直接拒绝打开
- **建议**：选择一种口径并落地：①沿用宽容策略 —— rels 解析失败退化为"无 rels、所有 sheet `SheetSkipped`"，
  `sharedStrings` 解析失败退化为空表 + 一条 `StylesMissing` 式的 summary 告警（语义最近的是
  `SharedStringIndexOutOfRange` 的汇总，可新增 `SharedStringsUnreadable`）；
  ②承认严格策略，把规格的"三种"改成五种并列出。配套用例要覆盖"坏 rels / 坏 sharedStrings 仍能读出 workbook"

### [一般][存量] `f-excel-roundtrip` 的两项验收证据未落地：`testdata/` 真实生成器样本缺失、openpyxl 自动化不存在，但任务已勾选完成

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-roundtrip/spec.md:89-97`（openpyxl 自动化，
  "缺失时 fail 并提示安装命令，不 skip"）、`:115-134`（4 份真实样本入库 `f_excel/testdata/`、单份 ≤ 20 KB）；
  设计 `.../implement-f-excel-m1/design.md:596-600`（夹具策略）；任务 `.../tasks.md:32-34`（0.6 已勾选）
- **来源**：存量（快照模式）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「文档过期」
- **证据**：静态确定 —— `f_excel/` 下 `ls` 只有 `README.md`/`README_en.md`/`cjpm.toml`/`doc`/`src`/`target`，
  **没有 `testdata/` 目录**；全仓 `grep -rn openpyxl --include=*.py --include=*.cj f_excel`
  零命中（只有 `.md` 提到）；`tasks.md` 0.6「建立 `f_excel/testdata/` …」却标 `[x]`
- **描述**：规格把"别人的前缀与顺序"（Excel / LibreOffice / WPS / openpyxl 各一份真实文件）作为
  解析器健壮性的主要防线，并规定样本缺失时**必须 fail**；实际只保留了"代码即夹具"（`fixtures.cj` 手拼字符串），
  openpyxl 回读退化为 `verification.md` 第 2 节的一次性人工记录（不是可重跑的门禁）。
  后果：真实生成器的命名空间前缀、部件顺序、`xml:space`、空 `<row/>` 等差异没有任何回归覆盖，
  解析器改动无法被 CI 拦住
- **建议**：二选一并同步文档：①补 4 份 ≤20 KB 样本 + 一个可跳过但默认 fail 的外部脚本用例，
  把 0.6/9.4 的勾选变成事实；②明确降级 —— 把 roundtrip spec 的"入库 + 自动化"改成"人工验收（verification.md 记录）"，
  同时把 `tasks.md` 0.6 的 `[x]` 改成"部分完成（仅 fixtures.cj）"，避免后续读者以为已有回归网

### [一般][存量] sheet 名上限口径不一致：规格写「31 字符」，实现按 UTF-8 **字节数**判，中文名 11 字即被误拒

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-reader/spec.md:64`、
  `.../specs/f-excel-writer/spec.md:240`；实现 `f_excel/src/ExcelDocument.cj:230-241`（`:234` `name.toArray().size > 31`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11「边界差一 / 合法输入被拒」、§13「文档与实现不符」
- **证据**：静态确定 —— `String.toArray()` 是 UTF-8 字节序列（同文件 `CellRef.cj:101-129` 直接按 `36u8`/ASCII 判定可佐证）；
  Excel 自身的限制是 31 个**字符**。中文每字 3 字节，故 11 个汉字（33 字节）就会抛
  「sheet 名不得超过 31 个字符」
- **描述**：对外契约（两份 spec 与 README 口径）说的是字符数，实现却按字节，属于"合法输入被误拒"；
  且写入侧 `ExcelWriter` 构造用同一校验，流式写也会被同样限制，错误消息还会把 11 个汉字报成"超过 31 个字符"，
  排查时会指向错误原因
- **建议**：改用 rune 计数（模块内 `SheetXmlWriter.cj:368/378` 的文本/公式上限已经用 `value.runes()` 计数，
  直接复用同一写法）；补"31 个汉字接受、32 个汉字拒绝"的用例，并在 spec 里注明按字符计

### [一般][存量] `f-excel-formula` 的公开类型与实现不符：`evaluate` 返回 `CalcValue`（不是 `CellValue`），`CalcIssue` 类型不存在

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-formula/spec.md:23`（`evaluate` 返回 `CellValue`）、
  `:35`、`:41`（`CalcIssue` / `CalcReport.cycles`）；实现 `f_excel/src/CalcEngine.cj:112`、`:126`
  （`public func evaluate(...): CalcValue`）、`f_excel/src/CalcEngine.cj:21-40`（`CalcReport.issues: ArrayList<String>`）
- **来源**：存量（快照模式；spec 与代码同批 `ee178eb13`）
- **判据**：review-checklist §13「API / 参数 / 返回类型与源码不符」、§11「契约与实现不符」
- **证据**：静态确定 —— 两个 `evaluate` 重载的返回类型都是 `CalcValue`；`CalcReport` 的字段是
  `issues: ArrayList<String>`（`CalcEngine.cj:29`），全仓搜 `CalcIssue`（排除 `.worktrees` 与 `doc/`）
  只命中模块设计文档，`src/` 零命中；返回 `CellValue` 的入口叫 `evaluateCell`（`CalcEngine.cj:131`）
- **描述**：使用者照 spec 写 `let v: CellValue = engine.evaluate("S", "B1")` 编译不过；
  期望拿到结构化 `CalcIssue(kind, ...)` 的错误信息实际只有拼接好的字符串，
  spec 的 `#NAME?` + `CalcIssue` 场景无法按类型断言。`f_excel模块设计.md:2350-2363` 也定义了 `CalcIssue` 类，
  说明是"设计有、实现没做"的类型，而不是 spec 笔误
- **建议**：spec 改为实际签名（`evaluate: CalcValue` / `evaluateCell: CellValue`），并把 `CalcIssue`
  统一成 `issues: ArrayList<String>` 的说明（或反向补 `CalcIssue` 结构体 + `issues` 改类型，属 API 变更需用户拍板）；
  同一处理要同步到模块设计文档 §7 与 `README`

### [轻微][存量] `f-excel-writer` 要求 `ExcelWriteOptions.stringMode`，与 proposal/design 的"不提供"结论及实现三者矛盾

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-writer/spec.md:58-62`；
  相反口径 `.../implement-f-excel-m1/proposal.md:119`（差异 9）、`.../design.md:582`（差异 9）、
  `.../design.md:226-229`（`ExcelWriteOptions` 只有 `date1904`）；实现 `f_excel/src/ExcelOptions.cj:58-63`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档承诺的配置项在源码里不存在」、§2「同一要求在多个文档里重复且已漂移」
- **证据**：静态确定 —— 全仓 `grep stringMode|StringWriteMode` 在 `src/` 零命中；`ExcelWriteOptions` 只有
  一个 `date1904` 字段
- **描述**：spec 说"`ExcelWriteOptions.stringMode` SHALL 只有 `InlineStr`（默认并唯一实现）"，
  听起来是一个真实存在的选项；proposal/design 则明确"不提供该枚举，单值枚举是假选择"。
  读者按 spec 写 `options.stringMode = ...` 直接编译失败
- **建议**：删掉 spec 中的 `stringMode` 提法，改为"文本 SHALL 一律写 `inlineStr`，不提供写出模式开关"，
  并在同一句引用差异 9；避免后续 M2-e 真正加枚举时把这两处再改一遍

### [轻微][存量] `baseline.md` 的"f_excel 自带转义"结论未标注已被取代，与 `design.md`／writer spec／tasks 冲突

- **位置**：`f_excel/doc/spec/implement-f-excel-m1/baseline.md:63-70`（尤其 `:68-70` "`Escaper` 不是 public → `WorksheetXmlWriter` 自带转义"）；
  相反口径 `.../design.md:67-70`、`.../specs/f-excel-writer/spec.md:203-212`、`.../tasks.md:90-93`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档过期：描述的能力已被设计推翻」、§2「字面量复制/结论复制导致漂移」
- **证据**：静态确定 —— `baseline.md:9-19` 的"已被取代"声明只覆盖"没有 openEntry / 没有增量接口"两条，
  没有覆盖 `§3` 末尾这条转义结论；`design.md:70` 明确"`Escaper` 仍为包内私有，但不再需要"，
  writer spec 进一步规定 "f_excel SHALL NOT 自带 XML 转义表"；实现 `SheetXmlWriter.cj` 也确实没有转义表
  （全文件只有 `stripControl`，`grep escape|&amp;|&lt;` 零命中）
- **描述**：同一变更的 baseline 与 design 对"谁负责转义"给出相反结论，baseline 又没有过期标记。
  后续维护者若以 baseline 为依据，很可能在 `SheetXmlWriter` 里加第二套转义表，直接违反 spec
- **建议**：在 `baseline.md:63-70` 加一行"↑ 本节关于转义的结论已被 f_xml v1.2 增量接口取代，见 design §3 / 差异 5"，
  或直接删掉该段；同时统一文件名口径（baseline 用 `WorksheetXmlWriter`，实际是 `SheetXmlWriter`）

### [轻微][存量] `design.md` §7 的 `cellXfs count="4"` 与表内 5 条（`s=0..4`）不一致

- **位置**：`f_excel/doc/spec/implement-f-excel-m1/design.md:543-549`（表：s=0/1/2/3/4）、`:561`（`<cellXfs count="4">…</cellXfs>`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档内部数字不一致；示例照抄会生成非法 styles.xml」
- **证据**：静态确定 —— 表格列了 5 行，XML 片段写 `count="4"`；ECMA-376 中 `cellXfs@count` 必须等于 `xf` 条数
- **描述**：`count` 与条目数不符会让 Excel 报"需要修复"（这正是本设计 §7 反复强调的最常见损坏来源）。
  当前实现已改为 `StylePool` 动态生成（`StylePool.cj:220` 用 `pool.size`），所以没有线上影响，
  但这份 design 仍是 M1 的历史依据，照抄会复现该问题
- **建议**：把 `count="4"` 改成 `count="5"`，或删掉 s=4 那行"预留"（预留项本来就不该进表）

### [轻微][存量] 流式读的 spool 目录回退与缓冲口径：spec/design 写"四级 + 64 KB"，实现只有两级且用 `std.io.copy` 默认缓冲；错误消息也没给承诺的两个出路

- **位置**：规格 `.../specs/f-excel-stream-read/spec.md:26-28`（`spoolDir` → `TMPDIR` → `getTempDirectory()` → `./.fountain_tmp`）、
  `:40-43`（消息 SHALL 含 `spoolDir` 与 `spool = false`）；设计 `.../design.md:494-495`（64 KB 固定缓冲）；
  实现 `f_excel/src/ExcelSheetStream.cj:169-177`（只有 `spoolDir` / `getTempDirectory()` 两级，
  消息只有 `无法创建 spool 临时文件：<dir>`）、`:21`（`import std.io.{InputStream, copy}`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「API / 行为 / 错误消息与文档不符」
- **证据**：静态确定 —— 代码里没有 `TMPDIR`、没有 `.fountain_tmp` 兜底（全文件 `grep TMPDIR|fountain_tmp` 零命中）；
  拷贝走 `std.io.copy`，未传缓冲参数，"64 KB 固定缓冲"不成立
- **描述**：三级兜底缺失意味着"系统临时目录不可写"的环境直接失败，而文档承诺还会退到工作目录下的
  `.fountain_tmp`；错误消息也没告诉调用方改用 `spoolDir` 或 `spool = false` 这两条出路，
  排障成本被转嫁给使用者
- **建议**：要么补两级兜底（`TMPDIR` → 工作目录 `.fountain_tmp`，自动创建）并补消息文案，
  要么把 spec 改成两级、消息改成实际文案；缓冲大小如确有 64 KB 要求，就在 `copy` 处显式传 `Array<Byte>(65536)`，
  否则删掉数字

### [轻微][存量] 文档点名的文件/符号在仓内不存在（含 6 个测试文件名），规格到代码的映射会断

- **位置**：`.../implement-f-excel-m1/design.md:96-97`（`SheetRowSink.cj`）、
  `.../implement-f-excel-m1/baseline.md:66`（`WorksheetXmlWriter`）、
  `.../implement-f-excel-m2/design.md:130-133`（`Styles.cj` / `Ast.cj` / `functions/*.cj`）、
  `.../implement-f-excel-m1/tasks.md:50`（`RowData_test.cj`）、`:90`（`SheetXmlWriter_test.cj`）、
  `:99`（`ExcelDocument_write_test.cj`）、`:127`（`Merge_test.cj`）、`:137`（`ExcelSheetStream_test.cj`）、
  `:173`（`ChannelParity_test.cj`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「链接/路径失效」、§14.1「接线缺失：文档与代码对不上」
- **证据**：静态确定 —— `f_excel/src` 无 `SheetRowSink.cj`（`RowSink` 接口在 `WorksheetParser.cj:52`）、
  无 `Styles.cj`（实际 `StylesLite.cj` 读 + `StylePool.cj` 写）、无 `Ast.cj`（实际 `FormulaAst.cj`）、
  无 `functions/` 子目录（实际扁平 `CalcFunctions*.cj` 12 个文件）；
  上述 6 个测试文件名既无同名文件也**无同名测试类**（`grep -rln "class X"` 零命中），
  相关用例散落在 `CellValue_test` / `Writer_test` / `Worksheet_test` / `StreamRead_test`
  （`channelParityWithDocument`，`StreamRead_test.cj:64`）等文件里。
  反过来 `PackageStructure_test`、`DateFormat_test`、`SharedStringTable_test` 是**测试类名**（分别在
  `RoundTrip_test.cj:135`、`Date_test.cj`、`WorksheetParser_test.cj`），这类引用不算失效
- **描述**：spec/design 是"验收口径"，读者按文件名找不到对应实现与用例，就会误判"没实现"或"没测"。
  M2 design 的文件表与实际布局偏差最大（`Style*.cj` / `Formula*.cj` / `functions/*.cj` 三处都不准）
- **建议**：design §4 与 tasks 的文件名按实际 `src/` 清单校正（或在文件表里加"实施后实际落点"一列）；
  测试名统一到真实文件名 + 类名，例如 `StreamRead_test.channelParityWithDocument`

### [轻微][存量] 收尾产物缺失但任务已勾选：`design.md` §10.1 实测记录仍为占位、承诺的 `doc/build-warnings.md` 不存在、1 万行往返耗时无记录

- **位置**：`.../implement-f-excel-m1/design.md:623-625`（"（实施时回填，见 `tasks.md` 0.3–0.5。）"仍原样）、
  `.../tasks.md:191`（10.4 回填 R1–R4 标 `[x]`）、`:30`（0.5 R3+R4 实测未勾选）、
  `.../proposal.md:97`（承诺新增 `f_excel/doc/build-warnings.md`）、`:101-102`（1 万行 × 10 列往返 `< 5 s` 观测值）、
  `.../tasks.md:184-186`（10.1 `[x]`）；`verification.md` 全文
- **来源**：存量（快照模式）
- **判据**：review-checklist §14.1「半成品 / 证据缺失」、§13「文档过期」
- **证据**：静态确定 —— design §10.1 只有一行占位，无任何结论；`ls f_excel/doc` 只有
  `f_excel模块设计.md` 与 `spec/`，无 `build-warnings.md`；`verification.md` §1 只有用例数，无耗时数据
- **描述**：三条"已勾选但产物不存在"的记录叠在一起，会让验收报告看起来比实际更完整。
  其中 R1（`Float64.toString` 最短往返）与 R3（`File.createTemp` 签名）是编码期实际依赖的结论，
  没留证据就无法在 SDK 升级后复核"当时为什么这么写"
- **建议**：要么补三份产物（R1–R4 结论、build-warnings 处置、往返耗时中位数），要么把对应任务改回 `[ ]`
  并注明"未执行"，同时在 `verification.md` 的"遗留"表里列出

### [轻微][存量] `implement-f-excel-m2` design 的样式上限"平台分档（Linux 64000 / 其他 8192）"没有实现分支

- **位置**：`f_excel/doc/spec/implement-f-excel-m2/design.md:60-61`；实现 `f_excel/src/ExcelOptions.cj:69-70`
  （`public var maxCellStyles: Int64 = 64000`）、`f_excel/src/SheetXmlWriter.cj:51/118`、`f_excel/src/StylePool.cj:102-112`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档承诺的平台行为与实现不符」；`fountain-baseline.md` §5（M2 引入平台分档时须用 `@When`）
- **证据**：静态确定 —— 全模块 `grep -rn "@When" f_excel/src` **零命中**，`maxCellStyles` 恒为 64000，
  无任何平台判定；`baseline.md:89` 明确指出 M2 需要平台分支时"照此写"
- **描述**：设计承诺按平台给不同上限（非 Linux 8192），实现是统一 64000。后果取决于平台：
  在只支持 8192 种样式的 Excel 版本上，超过 8192 的输出文件可能无法完整显示样式；
  但具体哪些平台受影响**需实测**，因此这里只按"文档与实现不一致"报轻微
- **建议**：补齐 `@When[os == "Linux"]` / 取反两支（与 `f_zip.ZipWriterOptions` 同法）并给两个默认值，
  或把 design 改成"统一 64000，不区分平台"，同时把 `SheetWriteOptions` 的注释（`ExcelOptions.cj:69`）
  与实际策略对齐

> **存量 14 条，是否纳入修复待用户决定**（其中 2 条严重、5 条一般、7 条轻微）。

<!-- 第 3 部分 -->

### [一般][存量] #1 M2 规格承诺的 `ExcelDocument.setStyle(sheet, ref, style)` 从未实现，验收却写"规格条目全部有实现"

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-styles/spec.md:25`；验收结论 `f_excel/doc/spec/implement-f-excel-m2/verification.md:39`
- **来源**：存量（快照模式，无基线可比；`git log --oneline -- f_excel/doc/spec/implement-f-excel-m2` 显示该文档随 `97315ade3` 引入后未再改）
- **判据**：review-checklist §13「文档承诺与实现不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 承诺源：spec 第 25 行"`ExcelDocument.setStyle(sheet, ref, style)` SHALL 等价于 `sheet(ref).setStyle(...)`"。缺失证据：`f_excel/src` 全目录搜 `func setStyle` 只有 `Worksheet.cj:296`（签名为 `setStyle(row: Int64, col: Int64, style: CellStyle)`），`ExcelDocument.cj` 无同名方法，仅在 `ExcelDocument.cj:370` 内部读取样式时调用 `sheet.setStyle(...)`；`ExcelDocument` 也没有"按 sheet 名 + 单元格引用写样式"的任何入口。
- **描述**：样式是本模块主要卖点之一，规格给了两个等价入口（工作表级 / 文档级），实现只交付了工作表级。verification §5 仍写"M2-a / M2-b / M2-c / M2-d 的规格条目全部有实现与用例"，属验收结论与事实不符；下游按 spec 调 `doc.setStyle("Sheet1", ref, style)` 会编译失败。
- **建议**：二选一并在归档文档里落定——(a) 补 `public func setStyle(sheet: String, ref: CellRef, style: CellStyle)`（找不到 sheet 时抛 `ExcelException`，与 `Worksheet.setStyle` 委托同一路径）；(b) 若确认设计上不提供文档级入口，删掉 spec 该句并在 verification「与规格的差异」表里记一行。M2 已归档，属"改文档"与"补 API"的取舍，需用户拍板。

### [一般][存量] #2 `StyleOverridesNumberFormat` 告警只存在于规格里；verification 用一个语义不同的告警名顶替了它

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-styles/spec.md:55-56`；验收表 `f_excel/doc/spec/implement-f-excel-m2/verification.md:27`；代码 `f_excel/src/SheetXmlWriter.cj:359`、`f_excel/src/ExcelException.cj:59`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现漂移」、§3「契约承诺的行为不存在」
- **证据**：静态确定 —— spec 要求"同时给 `style` 与 `numberFormat` 时以 `style` 为准，并记一条 `NumberFormatNotSupportedInM1` **之外**的明确 warning（`StyleOverridesNumberFormat`）"。全仓（排除 `.worktrees`）搜 `StyleOverridesNumberFormat` 只命中该 spec 行本身，`ExcelWarningKind`（`ExcelException.cj:37-61`）里没有这个枚举值，也没有任何代码发这条告警；代码在"有 style 时忽略 numberFormat"路径上发的仍是 `NumberFormatNotSupportedInM1`（`SheetXmlWriter.cj:359`）。
- **描述**：两者语义不同——`NumberFormatNotSupportedInM1` 表示"M1 不支持数字格式"，`StyleOverridesNumberFormat` 表示"显式样式覆盖了 numberFormat"。调用方拿到的告警无法区分"你的 numberFormat 因为 M1 限制被丢弃"和"你的 numberFormat 因为被 style 覆盖而失效"，正好是 M1→M2 迁移期最容易踩的一类。verification 第 27 行把"`style` 优先并告警 `NumberFormatNotSupportedInM1`"写成与规格一致的实施，掩盖了这条差异。
- **建议**：在 `ExcelWarningKind` 增加 `StyleOverridesNumberFormat`，在 `SheetXmlWriter` 判定到 `style != None && cell.numberFormat != None` 时发它（保留 `NumberFormatNotSupportedInM1` 给"无 style 但 M1 不认数字格式"的分支）；同步改 verification 的差异表。

### [一般][存量] #3 `maxCellStyles` 的平台分档没有实现，且整文档写出路径根本不接收该选项（选项在主路径上是死配置）

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-styles/spec.md:40`；代码 `f_excel/src/ExcelOptions.cj:70`、`f_excel/src/ExcelDocument.cj:292` 与 `:297`、`f_excel/src/PackageWriter.cj:51-56` 与 `:108`
- **来源**：存量（快照模式）
- **判据**：review-checklist §14.1「接线缺失：配置项被读取却从未使用」、§13「默认值与源码不符」
- **证据**：静态确定 ——
  - spec 写"超过 `SheetWriteOptions.maxCellStyles`（Linux 64000 / 其他 8192）SHALL 抛 `ExcelException`"，`ExcelOptions.cj:69-70` 的注释也照抄了"Linux 64000，其他平台 8192"，但字段初值是常量 `64000`，全模块无 `os`/平台判断，`StylePool.cj:113` 的异常文案也只是把两个数字写进字符串；
  - `ExcelDocument.write(output, options!: ExcelWriteOptions)`（`ExcelDocument.cj:292`）把 `options` 只用来解析 `date1904`，随后 `PackageWriter.write(output, sheetList, base1904, warnings_)`（`:297`）不传任何写出选项；`PackageWriter.write` 的形参表（`:51-56`）没有 options，构造 `SheetXmlWriter` 时也没传 `maxCellStyles`（`:108`），于是永远落到 `SheetXmlWriter.cj:51` 的默认 `64000`；
  - `ExcelWriteOptions`（`ExcelOptions.cj:59-64`）只有 `date1904` 一个字段，调用方即使想调整也无处可设。
- **描述**：结果是"样式池上限"这条保护在 `ExcelDocument.write` 主路径上不可配置：一律 64000，既不能按平台降到 8192 以贴合 Excel 实际接受度，也不能调低做失控样式检测。verification 第 26 行只记了"8192 由调用方按平台设置"，但调用方在整文档写出路径上没有这个入口，该说法不成立。
- **建议**：`SheetWriteOptions` 的默认值改为按平台计算的 `defaultMaxCellStyles()`（Linux 64000 / 其他 8192），并把 `maxCellStyles` 纳入 `ExcelWriteOptions` 后由 `PackageWriter.write` 透传给 `SheetXmlWriter`；或在 README/spec 明写"仅 `ExcelWriter` 路径可配"，删掉"由调用方按平台设置"的表述。

### [一般][存量] #4 M3 规格要求把未实现函数登记进 `CalcReport.unsupportedFunctions`，该字段与登记逻辑都不存在，tasks 4.2 却已勾选

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-formula-ext/spec.md:27-28`；设计 `f_excel/doc/spec/implement-f-excel-m3/design.md:39`；任务 `f_excel/doc/spec/implement-f-excel-m3/tasks.md:31`；代码 `f_excel/src/CalcEngine.cj:21-42`、`f_excel/src/Evaluator.cj:66-74`
- **来源**：存量（快照模式）
- **判据**：review-checklist §14.1「承诺了但没实现」、§3「公开契约承诺有行为，实现为空」
- **证据**：静态确定 —— 承诺源三处（spec"未实现的函数 SHALL 在 `CalcReport.unsupportedFunctions` 中列出并返回 `#NAME?`"；design"缺一个就在 `CalcReport.unsupportedFunctions` 里列出"；tasks 4.2"失败用例：`CalcReport.unsupportedFunctions` 完整列出未实现函数"并已打 `[x]`）。缺失证据：全仓 `*.cj` 搜 `unsupportedFunctions` 零命中；`CalcReport` 只有 `recalculated` / `errors` / `cycles` / `issues` 四个字段（`CalcEngine.cj:22-30`）；未知函数在 `Evaluator.cj:73` 直接返回 `CalcValue.Error(CalcError.Name)`，既不写 `issues` 也不进任何列表（`issues.add` 只出现在 `CalcEngine.cj:333` 解析失败与 `:353` 求值异常）。
- **描述**：`#NAME?` 这一半做到了，可观测性这一半没做。迁移真实工作簿时最常见的需求是"这个文件里哪些函数我还不支持"，现在只能逐格看 `#NAME?`，拿不到汇总；规格把它列为 SHALL，tasks 也勾了，属于归档时未闭合的承诺。
- **建议**：给 `CalcReport` 加 `unsupportedFunctions: ArrayList<String>`（去重、按名排序），在 `Evaluator.cj` 的 `case None` 分支把函数名交给引擎侧收集（可用 `CalcEngine` 现有 `issues` 机制扩展为结构化记录），补一条"未知函数出现在报告里"的用例，再把 spec 措辞与实现对齐。

### [一般][存量] #5 M3 spool 路径收尾缺失：没有 `SpoolForLazy` 告警，`InputStream + eager=false` 每打开一个文档就在临时目录留下一个文件且无回收路径

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-scale/spec.md:18`、设计 `design.md:26`、任务 `tasks.md:19`；实现 `f_excel/src/ExcelDocument.cj:43-46`、`:319-331`；验收自述 `f_excel/doc/spec/implement-f-excel-m3/verification.md:28-29`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11「资源不对称：打开未关」、§13「规格与实现不一致」、§14.1「半成品」
- **证据**：静态确定 ——
  - 告警：spec/design/tasks 都写"`InputStream` 输入 SHALL 自动 spool 并记 `SpoolForLazy`"，全仓（`*.cj` 与 `*.md`）搜 `SpoolForLazy` 只命中这 3 个文档，`ExcelWarningKind`（`ExcelException.cj:37-61`）没有该枚举值，`spoolInput`（`ExcelDocument.cj:319-331`）也不发任何告警（同族只有 `SpoolDisabled`）；
  - 泄漏：`spoolInput` 用 `File.createTemp` 建文件（`:322`），`f_excel/src` 全目录搜 `.delete()` / `deleteFile` / `removeFile` 零命中；`ExcelDocument` 没有 `close()`，`lazyPath` 也没有析构钩子。verification 第 29 行自己承认"会留下临时文件（文档未提供 `close()`），已在 README 标注"。
- **描述**：这是"已知并接受"的泄漏，但代价随进程寿命线性增长：每份走 `InputStream` 的懒加载文档都要把整包（可能 100 MB 级）复制进系统临时目录，长期运行的服务会把 `/tmp` 写满，且失败重试会叠加。把"README 标注"当作闭环不合适——spec 里没有任何"调用方必须自行清理"的契约，API 也不给清理手段。
- **建议**：`ExcelDocument` 增加 `close()`（或实现 `Resource` 语义）删除自己创建的 spool 文件，并让"是否由文档持有该临时文件"成为显式字段（`Path` 入参创建的文档不删）；若坚持不提供 `close()`，则必须加 `SpoolForLazy` 告警 + spec 写明生命周期由调用方负责（但 `File.createTemp` 的路径不对外暴露，调用方无法清理，等于仍需 `close()`）。

### [一般][存量] #6 M3 性能门禁的"达标"结论与自身数据、与 spec 的 SHALL 都矛盾：29 MB 超 20 MB 上限，5 条门禁只实测 1 条

- **位置**：门禁定义 `f_excel/doc/spec/implement-f-excel-m3/design.md:64-70`；硬指标 `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-scale/spec.md:28`；结论 `f_excel/doc/spec/implement-f-excel-m3/verification.md:18`、`:21-23`；任务 `f_excel/doc/spec/implement-f-excel-m3/tasks.md:45`
- **来源**：存量（`git show 331d57032` 当时写"实测 164 MB，未达标、M3 不归档"；`git show 05ae1e96b` 把同一段改成"已达标"，并新增"稀疏/混合表约 29 MB"一句）
- **判据**：review-checklist §13「规格与实现漂移 / 验收口径与当前实现不一致」、§14.1「只做了一半的分支」
- **证据**：静态确定 ——
  - spec 第 28 行是无条件 SHALL："100 万非空单元格的模型内存 SHALL < 20 MB"；verification 第 23 行自报稀疏/混合表 1,000,000 格约 **29 MB**，已超上限 45%；
  - design §7 列 5 条门禁（100 万行流式写 RSS、100 万行流式读 RSS、100 MB 文件 `eager=false` RSS、100 万单元格、350 函数覆盖），verification 第 18 行仍写"100 万行 RSS、100 MB 文件 RSS **未测**"，即 3 条未测、1 条未达标、1 条达标，第 21 行却下结论"7.1 性能门禁：已达标"，tasks 7.1 也打 `[x]`"性能门禁全部达标并记录"；
  - 唯一"达标"的是稠密数值表（1,000×1,000 行优先 `setCellNumber`，RSS +3.0 MB），它恰好是 `CellStore` 的稠密快速路径（`f_excel/src/CellStore.cj:102-135`），不能代表稀疏读入的真实工作簿。
- **描述**：这次归档把"局部最优路径达标"当成了"门禁达标"，且把此前明确记录的"未达标"改写成"已达标 + 边界记在 README"。对下游的实际影响是：设计文档与 README 会让使用者以为 100 万格规模已受控，而稀疏/混合表仍有 29 MB/百万格的量级，叠加 sharedStrings 与样式后更容易触到容器内存上限。
- **建议**：把 verification §7.1 改回"稠密表达标 / 稀疏表 29 MB 未达标"，并在 spec 里给 SHALL 加限定（"稠密数值表 < 20 MB；稀疏表 < X MB"）或把目标改为分档指标；未测的 3 条门禁要么补测要么标"未验证"，tasks 7.1 相应撤销勾选。若确认 29 MB 可接受，就修订 spec 的数字，而不是在验收里放宽口径。

### [一般][存量] #7 M4 求值覆盖未达 spec：`timePeriod` / `aboveAverage` 恒不命中，`Worksheet.matchedRules` 对 `expression` 静默返回空

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m4/specs/f-excel-conditional-format/spec.md:19`；任务 `f_excel/doc/spec/implement-f-excel-m4/tasks.md:10`；代码 `f_excel/src/CfEval.cj:70`、`f_excel/src/Worksheet.cj:179-183`；验收自述 `f_excel/doc/spec/implement-f-excel-m4/verification.md:32`、`:39`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」、§3「`case None => ()` 把语义吃掉」
- **证据**：静态确定 ——
  - spec 第 19 行把 `timePeriod` 列进 SHALL 按 Excel 语义求值的类型；`CfEval.cj` 的 match 没有 `TimePeriod` / `AboveAverage` 分支，统一落到第 70 行 `case _ => return None<CfFormat>`，即"永不命中"；verification 第 39 行承认"`timePeriod` / `aboveAverage` 求值（可解析、可写回，不命中）"，但 spec 未同步修订、tasks 2.3（`timePeriod` 用例）已勾；
  - `Worksheet.matchedRules(row, col)` 的注释就是"值规则命中（**不含 `expression`**，它需要公式引擎）"（`Worksheet.cj:179`），内部传 `None` 给 `matchedRulesWith`（`:182`），而 spec 第 19 行与 proposal 第 18-27 行都把 `matchedRules` 当作完整命中入口（`expression` 也应在内）。公式引擎侧另有 `CalcEngine.matchedRules`（`CalcEngine.cj:250`），两套入口语义不同却同名。
- **描述**：调用方按 spec 用 `Worksheet.matchedRules` 做渲染时，`expression` 规则与 `timePeriod`/`aboveAverage` 规则会**静默**判定为不命中，没有任何告警或返回值提示（`stopIfTrue` 也不会因这些规则生效）。这类漏判在业务上是"该标红的没标红"，且没有可观测信号。
- **建议**：要么在 `Worksheet.matchedRules` 内部委托 `CalcEngine`（需要文档持有引擎引用，或在 `Worksheet` 上注入求值器），要么把 spec 改成"`Worksheet.matchedRules` 只覆盖值规则，公式类规则须走 `CalcEngine.matchedRules`"并在方法注释/README 写明；`timePeriod`/`aboveAverage` 至少应像 `Unknown` 一样在 spec 的"未覆盖"里显式列出，而不是保留 SHALL。

### [一般][存量] #8 M4 写回没有按 `priority` 升序输出，与 spec 的 SHALL 相反

- **位置**：规格 `f_excel/doc/spec/implement-f-excel-m4/specs/f-excel-conditional-format/spec.md:8`；设计 `f_excel/doc/spec/implement-f-excel-m4/design.md:31`；代码 `f_excel/src/SheetXmlWriter.cj:274-304`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现不一致」、§11「语义与注释不符」
- **证据**：静态确定 —— spec"写回 SHALL 在 `mergeCells` 之后按 `priority` 升序输出"；`writeConditionalFormats` 直接 `for (rule in format.rules)`（`SheetXmlWriter.cj:280`）按 `ArrayList` 插入顺序写，函数体内没有任何排序，`f_excel/src` 里 `sort` 只出现在 `Worksheet.matchedRules` 的求值排序（`Worksheet.cj:203-214`）。写入顺序的位置（`mergeCells` 之后）是对的（`SheetXmlWriter.cj:95-99` → `:277`）。
- **描述**：`priority` 是 Excel 决定规则先后与 `stopIfTrue` 语义的显式属性，规则在 XML 里的相对顺序也会影响部分工具（含 Excel 自身在重排时的表现）。解析后原样写回通常无害，但"编程式 `addConditionalFormat` + 写回"路径的顺序完全取决于调用顺序，与 spec 承诺的"按 priority 升序"不一致；verification 也只写了"命中结果按 priority 升序"（求值侧），回避了写回侧。
- **建议**：写回前对 `format.rules` 做一次按 `priority` 的稳定排序副本（不要原地改模型，避免影响 `matchedRules` 的插入顺序语义），或在 spec 中删除"按 priority 升序输出"改为"保持插入顺序"。同时补一条"乱序 priority 写回后仍升序"的断言。

### [一般][存量] #9 缓冲复用设计的数据流图把 `bytes()` 写成"拷贝"，与同文件"返回视图、不是拷贝"的核心前提自相矛盾

- **位置**：`f_excel/doc/spec/reuse-package-writer-buffer/design.md:190-201`（每行"`bytes()拷贝`"），对照 `:29`、`:74`、`:218`、`:249`
- **来源**：存量（快照模式；该变更提交 `7de0791bd`）
- **判据**：review-checklist §13「文档前后不一致」、§11「注释承诺 A、描述 B」
- **证据**：静态确定 —— 同文件第 29 行"`bytes()` … 返回**共享底层存储的视图**，不是拷贝"、第 74 行"退出 → `buffer.bytes()`（底层数组视图；调用方 MUST 在下一次复用前消费）"、第 218 行 T3"断言旧视图**随底层数组变化**"；而数据流图（第 193-200 行）8 条路径全部写成"clear → 写 → `bytes()`**拷贝** → zip.add"。代码侧 `PackageWriter.cj:82-124` 是把 `bytes()` 结果直接交给 `zip.add`，没有拷贝。
- **描述**：这张图是读者最先看的部分，而它恰好否掉了整个变更唯一的正确性前提。按图理解，维护者会以为生成器返回的是独立副本，从而在新增生成器或改造调用方时省掉"复用前必须消费/复制"的约束——一旦出现延迟消费（例如先把视图存进列表、循环结束后再 `zip.add`），已写入的内容会被下一个部件覆盖，产物损坏且不报错。变更本身实现正确，风险在文档误导。
- **建议**：把数据流图的"`bytes()`拷贝"改为"`bytes()` 视图 → zip.add 同步消费"，并在图下补一句"图中每一步都必须在下一 `clear()` 之前完成 `zip.add`"。同时把第 193-200 行与 §D2、T3 的措辞统一。

### [轻微][存量] #10 M3 verification 的状态字段与正文自相矛盾：标题写"进行中 / 变更未归档"，正文写"完成，见归档记录"，"未完成"小节列的全是已完成项

- **位置**：`f_excel/doc/spec/implement-f-excel-m3/verification.md:3`、`:16`、`:19-25`
- **来源**：存量（`git show 05ae1e96b` 归档时只改了条目内容，未改标题与小节名）
- **判据**：review-checklist §13「文档过期」
- **证据**：静态确定 —— 第 3 行"日期：2026-10-31 ｜ 分支：`feature/f_excel` ｜ **变更未归档**"，第 1 行标题带"（进行中）"；第 24 行"7.2 verify + archive：完成，见归档记录"；第 16 行小节名为"## 未完成"，其下 4.1-4.3、5.1-5.2、7.1、7.2、#SPILL! 全部是"已完成"。同一份文档里"未归档"与"已归档"、"未完成"与"已完成"同时成立。
- **描述**：归档状态是 OpenSpec 流程的判据，读者无法从这份文件判断 M3 到底归没归档；第 18 行还留着"100 万行 RSS、100 MB 文件 RSS 未测"，与第 21 行"已达标"直接冲突（该冲突的实质已单列为 #6，这里只记状态字段）。
- **建议**：删除标题的"（进行中）"，把第 3 行改为"变更已归档（`05ae1e96b`）"，"## 未完成"改名为"## 门禁与已知边界"，并把仍未测/未达标的条目单独列出。

### [轻微][存量] #11 M2 的两个前置任务（R5–R8 实测、`f_xml` DOM 覆盖确认）始终未勾选，verification 仍宣告"可归档"

- **位置**：`f_excel/doc/spec/implement-f-excel-m2/tasks.md:8-9`（`- [ ] 0.1` / `- [ ] 0.2`）；结论 `f_excel/doc/spec/implement-f-excel-m2/verification.md:39-40`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「规格与实现漂移 / 验收口径」、§14.1「半成品」
- **证据**：静态确定 —— 0.1 要求"R5–R8 实测（tint 公式、函数对照值来源、Duration 范围、**样式池 64000 性能**），结论回填 design §5"；0.2 要求"确认 `f_xml` DOM 能覆盖 styles.xml 的全部节点；不能则记录缺口并停下询问"。两项均无勾选、无结论回填记录，而 verification 第 39 行写"规格条目全部有实现与用例 …… 可归档"。样式池 64000 的性能与 `f_xml` 覆盖度会直接影响 M2-a 的上限与结构，属未闭合的前置。
- **建议**：补做或明确降级：把 0.1 的 64000 性能实测结论补进 design/verification（哪怕结论是"未测，按内存估算可接受"），把 0.2 的 DOM 覆盖核对结论写一行（覆盖了哪些节点、缺口在哪）；否则删掉这两个前置项，避免归档文档里长期挂着未完成项。

### [轻微][存量] #12 "13 种 `CfRuleType`"与代码的 18 种具名枚举不符（design / spec / verification 三处重复同一错误）

- **位置**：`f_excel/doc/spec/implement-f-excel-m4/design.md:25`、`f_excel/doc/spec/implement-f-excel-m4/specs/f-excel-conditional-format/spec.md:7`、`f_excel/doc/spec/implement-f-excel-m4/verification.md:31`；代码 `f_excel/src/ConditionalFormat.cj:21-40`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「文档与代码不一致（数量/枚举）」
- **证据**：静态确定 —— `CfRuleType` 具名分支 18 个（`CellIs`、`Expression`、`ContainsText`、`NotContainsText`、`BeginsWith`、`EndsWith`、`TimePeriod`、`Top10`、`DuplicateValues`、`UniqueValues`、`ColorScale`、`DataBar`、`IconSet`、`ContainsBlanks`、`NotContainsBlanks`、`ContainsErrors`、`NotContainsErrors`、`AboveAverage`）外加 `Unknown(String)`；三处文档都写"13 种"。verification 同一行紧接着列举了 14 种求值类型，自证 13 这个数字不对。
- **描述**：数字错了不影响行为，但它会让人误判"还剩哪些类型没覆盖"——例如按 13 种去对数，会漏掉 blanks/errors/aboveAverage 这一族（其中 `aboveAverage` 正是未求值的，#7）。
- **建议**：三处统一改为"ECMA-376 的 18 种具名类型 + `Unknown(raw)`"，并在 spec 里点名哪几种只解析不求值（`timePeriod` / `aboveAverage`）。

### [轻微][存量] #13 任务清单点名的文件在仓库里不存在（`Styles.cj`、`ConditionalFormat_test.cj`、`Dxfs_test.cj`、`CfEval_test.cj`）

- **位置**：`f_excel/doc/spec/implement-f-excel-m2/tasks.md:18`；`f_excel/doc/spec/implement-f-excel-m4/tasks.md:5`、`:7`、`:8`
- **来源**：存量（快照模式）
- **判据**：review-checklist §13「链接 / 路径失效」、§14.1「接线缺失」
- **证据**：静态确定 —— M2 任务 1.6 写"实现 `Style.cj` / `StylePool.cj` / `Styles.cj`"，`f_excel/src` 下只有 `Style.cj` / `StylePool.cj` / **`StylesLite.cj`**，无 `Styles.cj`；M4 任务 1.1/1.3/2.1 分别点名 `ConditionalFormat_test`、`Dxfs_test`、`CfEval_test` 三个测试文件，实际条件格式用例全部在 `M4_test.cj`（7 个 `@TestCase`）。
- **描述**：任务清单是回溯实现范围的索引，文件对不上会让后续维护者以为存在独立读取器/独立测试；`StylesLite` 这个命名本身也暗示"精简读取器"，与 spec 要求的完整 `styles.xml` 读取（numFmts/fonts/fills/borders/cellStyleXfs/cellXfs/cellStyles/dxfs）之间的关系值得在文档里说清。
- **建议**：把任务里的文件名改成实际文件（`StylesLite.cj`、`M4_test.cj`），或在 spec 里注明"读取器命名为 `StylesLite`，与 `StylePool`（写侧）分工"。

### [轻微][存量] #14 M3 紧凑单元格的内部结构在三份文档里有三种说法，且都与代码不符

- **位置**：设计 `f_excel/doc/spec/implement-f-excel-m3/design.md:44-52`（"按行号分块（每块 1024 行）"、"`RowBlock: rowIndex + ArrayList<(col, CellValue)>`"）；任务 `tasks.md:37`（"实现行块结构"）；验收 `verification.md:20`（"`CellStore`（单个有序数组 + 二分查找）"）；代码 `f_excel/src/CellStore.cj:24-135`
- **来源**：存量（快照模式；三次描述分别来自 `97315ade3`、`9c95dacbe`、`331d57032`）
- **判据**：review-checklist §13「设计与实现漂移」
- **证据**：静态确定 —— 代码是**列式定宽位打包**：`ByteColumn`（`CellStore.cj:28`）每列用 `Array<Byte>` 按 `CHUNK: Int64 = 4096` 个元素分块（`:24`、`:41-45`），`CellStore` 在稠密模式下只存 `Float64` 列、稀疏模式走 `lowerBound` 二分（`:183-196`）；既没有"1024 行的 `RowBlock`"，也不是"单个有序数组"。
- **描述**：三份文档给出三种互不相同的实现模型，读者无法据此判断内存布局与复杂度。尤其 design 的 `RowBlock` 方案若被后人当作现状去改，会改错结构。
- **建议**：以代码为准重写 design §5（列式定宽打包 + 4096 分块 + 稠密/稀疏双模式），verification 第 20 行的描述同步更正，tasks 5.2 的"行块结构"改为"列式 `CellStore`"。

<!-- 第 4 部分 -->

### [严重][存量] #1 `CELL` 少传 reference 时越界读 `args[1]`，未捕获异常中断整个求值

- **位置**：`f_excel/src/CalcFunctionsDbMisc.cj:514`（`match (args[1])`）；注册处 `f_excel/src/FunctionRegistry.cj:396`（`CELL` 的 `minArgs = 1`）
- **来源**：存量（快照模式无基线；`git blame -L 512,520` → `9c95dacbe2 2026-10-31`）
- **判据**：review-checklist §11「边界越界」「错误处理缺失」、§3「公开契约承诺有行为，实现走到越界路径」
- **证据**：静态确定 —— `Evaluator.eval` 只按 `minArgs/maxArgs` 做数量校验后直接调 `entry.impl(this, args)`（`Evaluator.cj:66-74`），没有 try/catch；`Evaluator.arg` 才做越界保护（`Evaluator.cj:119-124`，越界返回 `Empty`），而 `fnCell` 用的是裸下标 `args[1]`。`CELL` 允许 1 个实参（`FunctionRegistry.cj:396`），所以 `=CELL("row")` 必然 `args.size == 1`。
- **描述**：`=CELL("row")` / `=CELL("address")` 是合法 Excel 写法（reference 可省略，默认取当前单元格）。这里抛 `IndexOutOfBoundsException`，异常沿 `evaluator.eval` → `CalcEngine.lookup:347` → `CalcEngine.evaluate` 一路上抛，整个 `evaluate` 或 `recalculate` 中断，而 `lookup` 在进入求值前已把 key 压入 `inProgress`、改了 `resolver.currentSheet`（`CalcEngine.cj:337-349`），异常路径没有 `finally` 复位，引擎会停在半求值状态。同一个文件里 `fnFormulaText:497`、`fnAreas:291` 也都是裸 `args[0]`，只是注册的 `minArgs` 正好为 1 才没触发。
- **建议**：改用 `ev.arg(args, 1)`，非 `Ref` 时按"当前单元格"降级（需要在 resolver 暴露 `currentCell`）；或在注册表把 `CELL` 的 `minArgs` 提到 2，但那是改契约。顺带把 `fnFormulaText` / `fnAreas` 的裸下标一并换成 `ev.arg`。

### [严重][存量] #2 `SUBSTITUTE` 按字节步进遍历，遇多字节字符切在字符中间抛异常

- **位置**：`f_excel/src/CalcFunctionsExt.cj:646`（`text[i..i + old.size]`）、`:655`（`out += text[i..i + 1]`）、循环 `:645-658`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「边界差一 / 越界」；std 文档 `core_package_structs.md:9383`「区间为 UTF-8 编码后的字节下标范围，起止点必须位于字符边界上」、`:9403`「范围起止点不是字符边界，抛出 `IllegalArgumentException`」
- **证据**：静态确定 —— 未命中分支执行 `out += text[i..i + 1]; i++`，`i` 是字节下标但步长是 1。只要字符串里有 2/3/4 字节字符且未在 `i` 处命中 `old`，就会切在多字节字符内部。例：`=SUBSTITUTE("a中b","b","x",2)` 在 `i=1`（"中"的首字节）就抛 `IllegalArgumentException`。只有 `instance <= 0`（`:639-641` 走 `String.replace`）以及"每个未命中段都恰好落在字符边界"的输入安全，含多字节字符的文本一旦在中间字节未命中就会抛。
- **描述**：第 4 个实参（指定第几次出现）一给，含中文/emoji 的文本就崩在这里，异常同样无人捕获（同 #1 的传播路径）。同文件 `fnReplace:673-678` 已经用 `runesOf` / `runesJoin` 正确处理字符边界，说明这是遗漏而非有意。
- **建议**：按 rune 遍历（`text.runes()` 或 `runesOf` + 逐 rune 比较），输出用 `StringGenerator`（`fnProper:767` 已是该写法）；避免任何按字节下标切串。

### [严重][存量] #3 `EXPAND` 对实参行列数无上限，单条公式即可分配 TB 级数组

- **位置**：`f_excel/src/CalcFunctionsDynFin.cj:170`（唯一校验是 `rows < grid.size`）、分配循环 `:173-185`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「按不可信长度预分配」「无拒绝路径」
- **证据**：静态确定 —— `rows`/`cols` 直接来自实参（`:161-165`），校验只有"不能比原区域小"，没有与 `EXCEL_MAX_ROW` / `EXCEL_MAX_COL`（`CellRef.cj:22-23`）比较；`for r in 0..rows { for c in 0..cols { ... } }` 按实参数量建 `ArrayList<CalcValue>`。对照同批实现：`fnRandArray:455` 有 `rows * cols > 1_048_576` 上限，`CalcEngine.spillArray:212` 有行列上限检查，唯独 `EXPAND` 没有。
- **描述**：`=EXPAND(A1,1000000,1000000)` 需要 10^12 个 `CalcValue`（每格至少 8-16 字节）→ 直接 OOM / 进程被 OOM killer 杀掉。由于求值链上没有大小上限，一个手工构造的 `.xlsx` 就能打到服务端；`recalculate` 里还会继续对结果走 `spillArray`。
- **建议**：进入分配前校验 `rows <= EXCEL_MAX_ROW && cols <= EXCEL_MAX_COL` 且 `rows * cols` 有显式预算上限（可用 `ExcelOptions` 里的上限，避免硬编码），超限返回 `#NUM!`；`fnRandArray` 的 `rows * cols` 也要改成不溢出的比较（`rows > 1_048_576 / cols`）。

### [严重][存量] #4 `NETWORKDAYS.INTL` / `WORKDAY.INTL` 把 weekend 编码当成节假日列表，结果错误

- **位置**：`f_excel/src/CalcFunctionsExt2.cj:515-524`（`holidaySet` 固定读 `args[2]`）；调用点 `f_excel/src/CalcFunctionsDynFin.cj:426`（`fnNetworkdaysIntl`）、`:451`（`fnWorkdayIntl`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§14.1「半成品：只处理部分输入」
- **证据**：静态确定 —— `holidaySet` 实现是 `if (args.size > 2) { numbersOf(ev, args, 2) }`，写死索引 2。`NETWORKDAYS.INTL(start_date, end_date, [weekend], [holidays])` 与 `WORKDAY.INTL(start_date, days, [weekend], [holidays])` 的第 3 个实参是 weekend 编码，holidays 在索引 3；`fnNetworkdaysIntl:423-426` 已经先把 `args[2]` 读成 `weekend`，再调 `holidaySet` 把同一个实参又读成节假日。
- **描述**：两个后果同时发生：真实节假日列表被完全忽略（`args[3]` 从未读取），而 weekend 编码（如 `7`）被当成"序列号 7 是节假日"塞进集合。`=NETWORKDAYS.INTL(A1,A2,7,B1:B5)` 会算出一个既不排除周末 7 定义之外的节假日、又莫名排除第 7 天的数字。`NETWORKDAYS` / `WORKDAY`（非 INT）刚好索引对齐，所以问题只出在 INT 变体上。
- **建议**：`holidaySet(ev, args, index: Int64)` 加索引参数，INT 变体传 3，普通变体传 2；同时补一条用例覆盖 "weekend + holidays 同时给" 的组合。

### [严重][存量] #5 `WORKDAY` / `WORKDAY.INTL` 在负序列号上死循环

- **位置**：`f_excel/src/CalcFunctionsExt2.cj:570-580`（`fnWorkday`）、`f_excel/src/CalcFunctionsDynFin.cj:455-466`（`fnWorkdayIntl`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误路径当成功」、§5「无界增长」、§12.1「有界性」
- **证据**：静态确定 —— 循环体是 `current += step` 后 `match (dateTimeFromSerial(Float64(current), ...))`，`case None => ()` 什么都不做；`remaining` 只在"非周末且非节假日"分支减 1（`:575-577`）。而 `dateTimeFromSerial` 对 `serial < 0` 直接返回 `None`（`DateFormat.cj:119-121`）。因此 `=WORKDAY(0,-3)`：`current` 依次 -1、-2、-3…，永远 `None`，`remaining` 永远不减。
- **描述**：单条公式即可让求值线程 100% CPU 且永不返回；`recalculate` 是同步循环，整个重算/请求被挂死。上界只受 `Int64` 回绕影响，实操上等于无限。`WORKDAY.INTL` 同样问题。
- **建议**：`None` 分支不能再 `()`：返回 `#NUM!`；或在进入循环前校验 `startSerial >= 1`（Excel 序列号下限）与 `startSerial + days` 的范围，同时对迭代次数加硬上限（例如 `abs(days) + 节假日数 * 2 + 7`）做兜底。

### [严重][存量] #6 日期函数不做序列号范围校验，`DateTime.ofEpoch` 的 `ArithmeticException` 直接冒泡

- **位置**：调用 `datePartsOf` 后立即使用的入口：`f_excel/src/CalcFunctionsExt2.cj:349`（`WEEKDAY`）、`:493`（`DAYS360`）、`:541`（`NETWORKDAYS`）、`f_excel/src/CalcFunctionsDynFin.cj:349`（`ISOWEEKNUM`）、`:430`（`NETWORKDAYS.INTL`）、`:457`（`WORKDAY.INTL`）；抛点 `f_excel/src/DateFormat.cj:141`（`DateTime.ofEpoch`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「异常路径」；std 文档 `time_package_structs.md:1057`：`ofEpoch` 在"结果超过日期时间的表示范围"时抛 `ArithmeticException`
- **证据**：静态确定 —— `dateTimeFromSerial` 只挡 `serial < 0`、`NaN/Inf` 与 1900 闰年假日期（`DateFormat.cj:119-124`），不挡上限；`DateTime` 可表示范围是 ±999,999,999 年（`time_package_structs.md:11`），即 `serial` 约 ≥ 3.65e11 天就溢出，`ofEpoch` 抛异常，而 `fnWeekday` 等调用点只 `match` `Some/None`，没有 try/catch。
- **描述**：`=WEEKDAY(10^12)`、`=DAYS360(A1,10^12)` 之类的输入（可由上游算术产生，不必手工输入）会抛出未被捕获的 `ArithmeticException`，中断整个求值（同 #1 的传播路径与脏状态）。Excel 对超范围日期返回 `#NUM!`。
- **建议**：在 `datePartsOf`/`dateTimeFromSerial` 统一加范围校验（如 `1 <= serial <= 2_958_465`，即 9999-12-31），超限返回 `None` 由调用方转 `#NUM!`；`CalcEngine.evaluate` 外层加一层 `try/catch` 兜底成 `#VALUE!`，避免任何 impl 异常打断整个 `recalculate`。

### [严重][存量] #7 `VSTACK` 产出锯齿数组，`INDEX`/`VLOOKUP`/`SUMPRODUCT` 只按首行宽度校验 → 越界

- **位置**：产生锯齿：`f_excel/src/CalcFunctionsDynFin.cj:188-218`（`fnStack` 纵向分支 `:190-195` 直接 `out.add(row)`，不补齐宽度）；消费点：`f_excel/src/CalcFunctionsLookup.cj:104`（`col > grid[0].size` 校验）→ `:113`（`grid[row-1][col-1]`）、`:58` / `:67`（`grid[row][colIndex-1]`）、`f_excel/src/CalcFunctionsExt2.cj:41-51`（`fnSumProduct` 用首行 `cols` 遍历所有行）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「越界」、§10「正确性：边界」
- **证据**：静态确定 —— `VSTACK` 只是把各参数的行依次追加，`=VSTACK(A1:B1,A2)` 得到 `[[a,b],[c]]`（`rows[0].size=2`、`rows[1].size=1`）。`fnIndex` 的边界检查只用 `grid[0].size`，`INDEX(VSTACK(A1:B1,A2),2,2)` 通过检查后执行 `grid[1][1]` → `IndexOutOfBoundsException`。`fnVLookup` 同理（返回 `grid[row][colIndex-1]`）。`fnSumProduct` 用 `cols = grid[0].size` 遍历 `grid[r][c]`，锯齿输入直接越界。`fnTranspose:616` 已用 `if (col < grid[row].size)` 防护，说明其余三处是漏检。
- **描述**：`VSTACK`/`HSTACK` 是公开注册的动态数组函数（`FunctionRegistry.cj:325-326`），Excel 语义要求按最大宽度用 `#N/A` 补齐成矩形。现在既不补齐又没有消费端防护，嵌套调用即可崩（异常同样无人捕获）。
- **建议**：`fnStack` 按目标宽/高补齐 `CalculValue.Empty`（或 `#N/A`，与 Excel 一致）；同时把 `fnIndex`/`fnVLookup`/`fnSumProduct` 的行内取格统一改为 `r < grid.size && c < grid[r].size` 双重校验，越界返回 `#REF!`。

### [一般][存量] #8 `AGGREGATE` 的 options 实参被完全忽略，忽略错误/隐藏行的语义缺失

- **位置**：`f_excel/src/CalcFunctionsDbMisc.cj:204-206`（`let code = ...args[0]`; `let rest = args[2..args.size]`，`args[1]` 从未读取）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「只做了一半的分支」、§11「契约与实现不符」
- **证据**：静态确定 —— 函数体全文没有 `args[1]`；`fnAverage`/`fnSum`/`fnMinMax` 等经 `numbersOf` 传播错误（`FunctionRegistry.cj:489-501` `case Error(e) => return (out, Some(e))`），没有任何"跳过错误值"的路径。
- **描述**：Excel `AGGREGATE(function_num, options, ref1, …)` 的 options 决定是否忽略错误值（2/3/6/7）、隐藏行（1/3/5/7）与嵌套 SUBTOTAL。当前 `=AGGREGATE(4,6,range)` 遇到任一 `#DIV/0!` 就整体返回错误，而按契约应忽略该错误取最大值。`SUBTOTAL`（`:185-201`）同样只有 `code % 100` 的分派，`1-11`（排除隐藏行）与 `101-111`（含隐藏行）被当成同一套逻辑。
- **建议**：解析 options 位并显式传给各聚合函数（至少实现 2/3/6/7 的"忽略错误"）；隐藏行语义需要行可见性信息，若 `Worksheet` 暂不提供，应在 README/注释里声明该限制，而不是静默按"不忽略"处理。

### [一般][存量] #9 一批已注册形参被静默忽略（DAYS360 method、WEEKNUM return_type、ROMAN form、ADDRESS a1）

- **位置**：`f_excel/src/CalcFunctionsExt2.cj:484-492`（`DAYS360` 未读 `args[2]`）、`:364-372`（`WEEKNUM` 未读 `args[1]`）、`f_excel/src/CalcFunctionsMathEng.cj:383-387`（`ROMAN` 未读 `args[1]`）、`f_excel/src/CalcFunctionsDynFin.cj:270-282`（`ADDRESS` 只读 0/1/2/4，`args[3]` 的 a1 标志未读）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「接线缺失：配置项被读取却从未使用 / 形参声明了但没分支」
- **证据**：静态确定 —— 注册表明确给出参数上限（`FunctionRegistry.cj:181` DAYS360 3 个、`:178` WEEKNUM 2 个、`:247` ROMAN 2 个、`:331` ADDRESS 5 个），函数体内对应索引没有任何读取（`grep args\[2\]` / `args\[1\]` / `args\[3\]` 无命中）。
- **描述**：四个函数的第二个/第三个可选参数都与 Excel 契约冲突：`DAYS360(...,TRUE)` 应走欧洲 30/360（当前恒为美式简化规则）、`WEEKNUM(d,2)` 应以周一为周首（当前恒按周日）、`ROMAN(n,1)` 应输出简式（当前恒标准式）、`ADDRESS(r,c,1,FALSE)` 应输出 R1C1（当前恒 A1）。调用方拿到的是"看起来成功但口径不对"的数字/文本。
- **建议**：要么实现分支，要么在注册表把 `maxArgs` 收紧到实际支持的个数并在 README 声明"不支持第 N 参"，避免静默按默认口径计算。

### [一般][存量] #10 信息类函数是占位实现：`HYPERLINK` 丢链接、`INFO` 返回硬编码、`ROW()`/`COLUMN()` 无参报错

- **位置**：`f_excel/src/CalcFunctionsDynFin.cj:298-303`（`fnHyperlink`）、`f_excel/src/CalcFunctionsDbMisc.cj:539-550`（`fnInfo`）、`f_excel/src/CalcFunctionsExt.cj:585-588`（`fnRowColumn` 的 `args.size == 0` 分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3「公开契约承诺有行为，实现只返回常量/直接失败」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `fnHyperlink` 只返回第 2 个实参（friendly_name）的文本，`link_location`（`args[0]`）在给了 2 个实参时完全不参与，模型里也没有超链接字段可落；`fnInfo` 对 `"system"`/`"osversion"` 恒返回 `"Linux"`、`"release"` 恒 `"1.0"`、`"numfile"` 恒 `1`、`"directory"` 恒 `"/"`，与运行环境无关；`fnRowColumn` 在 `args.size == 0` 时直接 `Error(Value)`，而 `ROW()`/`COLUMN()` 在 Excel 里是"取当前单元格行列"的常用写法（注册表 `FunctionRegistry.cj:132-133` 也允许 0 参）。
- **描述**：三个函数都会给出"成功但无意义"的结果或误报错误：`=HYPERLINK("https://x","点击")` 得到纯文本、无法跳转；`=INFO("numfile")` 在多工作表文件里恒为 1（错误信息）；`=ROW()` 返回 `#VALUE!`（`ROW(A1)` 才正常）。这类"假值"比返回 `#N/A!` 更危险，使用方无法区分"不支持"和"真实值"。
- **建议**：`HYPERLINK` 要么把链接存进 `CellValue`（需要模型扩展），要么在 README 明确"只保留显示文本、不生成链接"；`INFO` 未支持的类型返回 `#N/A!` 而不是编造常量；`ROW()`/`COLUMN()` 需要在 resolver 暴露当前坐标后返回真实行列，暂时做不到就收紧 `minArgs = 1`。

### [一般][存量] #11 `LOGNORM.INV` 缺 `sd <= 0` 校验，与非逆分支口径不一致

- **位置**：`f_excel/src/CalcFunctionsDist.cj:119-121`（inverse 分支只校验 `p`）；对照 `:133`（非逆分支 `if (x <= 0.0 || sd <= 0.0)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「缺少边界校验」、§2「近似重复但少了一处边界判断」
- **证据**：静态确定 —— inverse 分支取 `sd` 后直接 `exp(mean + sd * normalInv(p))`；`sd = 0` 时退化成 `exp(mean)`（一个看起来合法的数），`sd < 0` 时得到 `exp(mean - |sd|·z)`，全部不报错。
- **描述**：`=LOGNORM.INV(0.5, 0, 0)` 返回 1 而不是 `#NUM!`；`sd` 为负时返回镜像分布的逆值。同一函数的正/逆两条路径对 `sd` 的契约不一致，属于典型的"复制时漏一行"。
- **建议**：inverse 分支补 `if (sd <= 0.0) return Error(Num)`，并把两条分支的参数提取合并到一处校验。

### [一般][存量] #12 `Z.TEST` 单样本时 `0/0` 产出 `NaN` 并以 `Number` 形式流出

- **位置**：`f_excel/src/CalcFunctionsDist.cj:367`（`sqrt(total / Float64(values.size - 1))`）、`:369-372`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「空集合/除零未处理」
- **证据**：静态确定 —— 只校验 `values.size == 0`（`:351`），`size == 1` 时 `Float64(0) / 0.0` = `NaN`；`if (sigma <= 0.0)` 对 `NaN` 恒为 false（IEEE 比较语义），继续执行 `1.0 - normalCdf(NaN)` → `NaN`，最后 `CalcValue.Number(NaN)`。
- **描述**：`=Z.TEST({5},3)` 得到 `NaN` 数值。该值会继续参与后续运算（比较、`TEXT` 格式化、写回缓存值），既不是错误值也不会被 `ISERROR` 捕获，错误会静默扩散。Excel 返回 `#DIV/0!`。
- **建议**：在 `size < 2`（未给 sigma 时）直接返回 `Error(DivZero)`；对 `sigma.isNaN()` 也统一转错误值。

### [一般][存量] #13 分布函数累积循环上界来自实参，且每次迭代重算阶乘（O(x²) 且无上限）

- **位置**：`f_excel/src/CalcFunctionsDist.cj:185-192`（POISSON.DIST 累积，循环内 `factorialOf(k)`）、`:218-225`（BINOM.DIST）、`:237-245`（BINOM.INV）、`:260-267`（NEGBINOM.DIST）、`:287-294`（HYPGEOM.DIST）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无拒绝路径」、§6.4「同一输入重复解析 / 已知规模不预计算」
- **证据**：静态确定 —— 五处 `while (k <= x)` / `while (i <= k)` / `while (f <= failures)` 的上界都是 `Int64(实参)`，没有上限校验；`factorialOf(k)`（`:197-205`）在每次迭代里从头累乘，`exp(-mean) * pow(...)` 也每次重算，整体是 O(x²) 次浮点运算。
- **描述**：`=POISSON.DIST(1000000000,1,TRUE)` 需要 10^9 次迭代、每次再乘 1e9 量级的阶乘 → 实际是永远算不完的挂死；`BINOM.DIST(1e9,...)`、`HYPGEOM.DIST` 同理。与 #5 一样属于"单条公式锁死求值线程"的可用性问题，只是机制是超长循环而非死循环。
- **建议**：限制 `x`/`n`/`failures`（Excel 本身也有上限，可对齐到 1e5 量级）并返回 `#NUM!`；累积分布改用递推（`P(k+1) = P(k)·λ/(k+1)`）或 `lgamma` 直接算，避免每次重算阶乘。

### [一般][存量] #14 `SUMIFS` / `COUNTIFS` 在双层循环内重复物化区域，且实参被逐格重新求值

- **位置**：`f_excel/src/CalcFunctionsMath.cj:259-267`（循环内 `gridOf(ev.arg(args, pair))`）、`:380-383`（`COUNTIFS` 同形）；外层循环 `:255-256` / `:375-376`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.4「同一输入重复解析」、§11「重复求值导致语义漂移」
- **证据**：静态确定 —— `gridOf(ev.arg(...))` 位于 `for row` × `for col` 之内，调用次数 = 结果区域格数；`ev.arg` 会重新 `eval` 表达式（`Evaluator.cj:119-124`），区域表达式每次都要走 `rangeValue` 全量取值（`Evaluator.cj:89-116`）。以 1000 行 × 50 列、1 组条件估算：5 万次物化 × 每次 5 万格 = 2.5×10^9 次取值，且每次都新建 `ArrayList`/数组。`COUNTIFS` 还额外把 `args[0]` 物化两次（`:373` 与 `pair = 0` 时）。
- **描述**：这是全部分析里最明确的算法级放大：复杂度从 O(格数 × 条件数) 变成 O(格数² × 条件数)。附带语义问题：若条件或求和实参含 `RAND()`/`NOW()` 等，逐格重算会让每个单元格看到不同取值，与 Excel"实参求值一次"的契约不一致。
- **建议**：进入循环前把所有 `(testGrid, criteria)` 一次性物化进 `ArrayList`，循环内只取数组；`COUNTIFS` 复用第一个 grid。耗时占比需实测，见「待验证假设」#2。

### [一般][存量] #15 财务函数 6 处"取实参 + 判空 + getOrThrow"样板重复，且 `PPMT` 与其余实现不一致

- **位置**：`f_excel/src/CalcFunctionsExt2.cj:593-627`（`fnPmt`）、`:629-660`（`fnFv`）、`:662-693`（`fnPv`）、`:695-734`（`fnNper`）、`:736-756`（`fnSln`）、`:780-827`（`fnIpmt`）；不一致点 `:829-847`（`fnPpmt` 全部用 `?? 0.0`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名的逐行对齐」+「差异导致行为漂移」
- **证据**：静态确定 —— 每个函数都是同一段 5 连（`let xOption = numberArg(...); if (xOption.isNone()) { return Error(Value) }; let x = xOption.getOrThrow()`），仅变量名不同，合计约 120 行；`fnPpmt:831-835` 把同一批参数写成 `?? 0.0`，缺参时静默取 0。
- **描述**：重复本身让"缺参即 `#VALUE!`"这条契约散落在 6 处，任何一处改口径都会漂移；漂移已经发生：`PPMT(0.1,1)` 缺 `nper/pv` 时按 0 计算返回一个数，而 `PMT(0.1,1)` 返回 `#VALUE!`。
- **建议**：抽 `requiredNumber(ev, args, index): ?Float64`（内部用 `numberArg` + 空判断），6 处改为一行取参；`fnPpmt` 改用同一 helper，缺参行为与兄弟函数对齐。

### [一般][存量] #16 `TIMEVALUE` 秒解析失败被 `catch` 吞掉并按 0 处理

- **位置**：`f_excel/src/CalcFunctionsExt2.cj:283-289`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3「`catch` 静默吞异常」
- **证据**：静态确定 —— 同一函数里 hour/minute 解析失败都 `return Error(Value)`（`:272-281`），只有 second 是 `catch (_: Exception) { 0 }`。
- **描述**：`=TIMEVALUE("12:30:ab")` 返回 `12:30:00` 而不是 `#VALUE!`，脏数据被静默当成合法时间；后续 `HOUR/TEXT` 都会给出看似正确的结果，问题被隐藏到很远的地方。
- **建议**：与 hour/minute 一致返回 `Error(Value)`。

### [一般][存量] #17 `ISOWEEKNUM` 跨年周计算用截断除法，年初日期返回 1 而非上年 52/53

- **位置**：`f_excel/src/CalcFunctionsDynFin.cj:364-366`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「逻辑错误（负值截断）」
- **证据**：静态确定 —— `(dayNumber - week1Monday) / 7 + 1`，`Int64` 除法向零截断。以 2021-01-01（周五）为例：`jan4` 为周一，`mondayOffset = 0`，`week1Monday` = 1 月 4 日，`dayNumber - week1Monday = -3`，`-3/7 = 0` → 返回 1；ISO 8601 该日属 2020 年第 53 周。2022-01-01（周六）同理返回 1，正确值是 52。
- **描述**：每年 1 月 1-3 日落在上一 ISO 年时都会算错；跨年周报、按周汇总会把这几天归到错误的年份周。
- **建议**：用向下取整除法（`floorDiv(diff, 7)`）或先判断 `diff < 0` 时改为 `52/53` 的上年归属（结合上年 12 月 28 日的 ISO 周数计算）。

### [一般][存量] #18 `CalcEngine` 的可变实例状态无同步、异常不复位

- **位置**：`f_excel/src/CalcEngine.cj:95-99`（`memo`/`inProgress`/`cycleCells`/`issues`/`evaluator` 均为实例可变字段）、`:112-124`（`evaluate` 每次重建）、`:302-364`（`lookup` 写 `memo`/`inProgress`/`currentSheet`）、`:337-349`（无 `finally`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」「异常后状态不一致」
- **证据**：待确认 —— 仓内没有把 `CalcEngine` 放进全局/单例（测试与调用方都是局部构造），所以本模块内**不存在具体共享路径**；但它是 `public class`，`evaluate`/`recalculate` 直接改写实例字段且全文无锁、无 `synchronized`、无不可变快照。若下游（如 f_app 的 Bean）持有一个引擎实例服务多请求，两个线程同时 `evaluate` 会互相把 `memo` 置空、把 `resolver.currentSheet` 改成对方的表，环检测 `inProgress` 也会串，结果是随机的 `#CIRC!`/错值。
- **描述**：另外 `lookup` 在 `evaluator.eval` 前后修改 `inProgress` 与 `currentSheet`，异常时（见 #1/#2/#6）不复位，引擎会停在"某 key 仍在 inProgress、currentSheet 是别人"的状态；虽然下一次 `evaluate` 会重置这几个字段，但同一次 `recalculate` 内没有恢复机会。
- **建议**：若要支持并发：`evaluate`/`recalculate` 改为"每次调用创建局部求值上下文（memo/inProgress/evaluator 作为参数对象）"，引擎只保留 `doc`；短期至少在类注释与 README 明确"非线程安全，单实例单线程使用"。异常安全用 `try { ... } finally { restore }` 包住 `lookup:337-349`。

### [轻微][存量] #19 三个文件存在未使用的 `import`

- **位置**：`f_excel/src/CalcFunctionsDbMisc.cj:20`、`f_excel/src/CalcFunctionsDynFin.cj:21`、`f_excel/src/CalcFunctionsExt2.cj:22`（均为 `import fountain::f_base.StringGenerator`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 三个文件中 `StringGenerator` 仅出现在 import 行，没有构造调用（对照 `CalcFunctionsExt.cj:733/767/786` 才是真用）。
- **描述**：死 import 会把 `f_base` 的编译期依赖挂在这三个纯计算文件上，也让读者误以为这里做了字符串拼接。
- **建议**：删除三行。

### [轻微][存量] #20 死代码与死赋值合集（不可达分支、恒等赋值、写入后不读）

- **位置**：`f_excel/src/CalcFunctionsMathEng.cj:367-378`（`fnBitwise` 的 `y >= 0` 判定与 `else` 负移分支）；`f_excel/src/CalcFunctionsDist.cj:65-68`（`var cumulativeIndex = 1; if (standard) { cumulativeIndex = 1 }`）；`f_excel/src/CalcFunctionsDynFin.cj:670`、`:709`（`fHigh = fMid` 后再未读取）；`f_excel/src/CalcFunctionsDynFin.cj:82-85`（`take && rows < 0` 时 `rowEnd` 连续赋两次）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「不可达语句 / 恒真恒假分支 / 读了不用」
- **证据**：静态确定 —— `fnBitwise:360-362` 已 `if (x < 0 || y < 0) return`，后续 `y >= 0` 恒真、`else` 分支不可达；`fnNormalDist` 的 `if (standard)` 分支把已初始化的 1 再赋 1；`fHigh` 只在初始 `fLow * fHigh > 0.0` 判定时读一次，循环内的赋值无读者；`fnTakeDrop:82` 的 `rowEnd = maxI(totalRows + rows, 0)` 被 `:85` 的 `rowEnd = totalRows` 覆盖。
- **描述**：不影响运行结果，但会误导读者以为负位移/负索引有专门处理（实际被前置校验挡掉），也会让"二分法维护上界"看起来是完整实现（实际只用下界收敛）。
- **建议**：删除不可达分支与恒等赋值；`fnBitwise` 若真要支持负位移，应放宽前置校验并补 `#NUM!` 边界；`fHigh` 相关语句一并删掉，或真正参与收敛判断。

### [轻微][存量] #21 `ROUND`/`ROUNDUP`/`ROUNDDOWN` 的 10 的幂因子计算复制三份

- **位置**：`f_excel/src/CalcFunctionsMath.cj:77-95`（`roundHalfAway` 内）、`:127-140`（`"up"` 分支）、`:141-154`（默认 `"down"` 分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「换控制流 / 同一换算重复实现」
- **证据**：静态确定 —— 三段都是 `var factor = 1.0; if (digits >= 0) { for ... factor *= 10.0 } else { for ... factor /= 10.0 }`，逐字相同；差别只在取整方向。
- **描述**：三份因子计算意味着精度口径（`digits` 截断到 ±15 在 `:119-124`）只对其中一条路径可查；后续若要改成 `pow(10, digits)` 或加保护，容易漏改。
- **建议**：抽 `factorOf(digits: Int64): Float64`（或直接用 `pow(10.0, Float64(digits))` + 边界处理），三个分支只保留取整方向差异。

### [轻微][存量] #22 `YEARFRAC` 的 basis 0（美式）与 basis 4（欧式）是逐字相同的代码块

- **位置**：`f_excel/src/CalcFunctionsDynFin.cj:388-400`（`case 4`）与 `:401-413`（默认分支）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改注释的重复逻辑」
- **证据**：静态确定 —— 两块除注释外完全一致（`d1 == 31 → 30`、`d2 == 31 → 30`、`(y*360 + m*30 + d)/360`）。而 `30/360` 两套规则的实质差异在于美式对"起始日为月末/2 月末"的额外调整，这里两边都用了欧式规则。
- **描述**：注释写"美国 30/360（简化）"，实际与 `case 4` 行为完全相同，`basis=0` 的调用方拿到的不是美式口径；由于两段一样，未来修其中一处必然漏另一处。
- **建议**：把 `30/360` 抽成一个函数并加 `european: Bool` 参数，美式分支实现"起始日为 31 或 2 月末则改 30"的规则；若暂不实现，`basis=0` 应返回 `#NUM!` 或在 README 声明与 `basis=4` 等价。

### [轻微][存量] #23 四处手写插入排序，其中 `LARGE/SMALL` 先排序一次又把结果丢掉再排一次

- **位置**：`f_excel/src/CalcFunctionsExt.cj:36-44`（`sortedNumbers`）、`:107`（`sortedNumbers(ev, args)` 结果只用于取错误，`values` 之后未使用）+ `:130-138`（`fnLargeSmall` 内联第二份插入排序）；`f_excel/src/CalcFunctionsMath.cj:439-447`（`fnMedian`）；`f_excel/src/CalcFunctionsDynFin.cj:49-65`（`fnSortBy`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「同语义不同实现」、§1「读了不用」
- **证据**：静态确定 —— 四段都是同款 `for i in 1..n { key; j = i-1; while (j >= 0 && a[j] > key) {...} }`；`fnLargeSmall:107-111` 的 `values` 在 `match (error)` 之后没有任何引用（后续用 `real`），即整趟 O(n²) 排序白做。
- **描述**：`LARGE(range,k)` 一次调用要做两趟排序（第一趟还把 k 也当数据排了）；`MEDIAN`/`PERCENTILE`/`MODE` 走 `sortedNumbers` 也是 O(n²)。对 1 万格区域约 5×10^7 次比较，属于可测量的浪费，但缺基线数据（见「待验证假设」#1）。
- **建议**：统一用 `std.sort`（或 `ArrayList.sort`）实现一处 `sortedNumbers`，`fnLargeSmall` 只排前 `n-1` 个实参；`fnSortBy` 需要稳定排序 + 同步置换 key，可用"索引数组 + 比较器"排一次。

### [轻微][存量] #24 `aggregateNumbers` 与 `SUM/AVERAGE/MIN/MAX/STDEV/VAR` 是同一组公式的第二套实现

- **位置**：`f_excel/src/CalcFunctionsDbMisc.cj:130-181`（`aggregateNumbers`，供 `DSUM`/`DAVERAGE`/`DSTDEV` 等使用）；对照 `f_excel/src/CalcFunctionsMath.cj:23-36`（`fnSum`）、`:281-299`（`fnAverage`）、`:397-421`（`fnMinMax`）、`f_excel/src/CalcFunctionsExt.cj:48-86`（`stdevOf`/`fnStdev`）、`:88-104`（`fnVariance`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「跨文件复制同一换算 / 统计公式」
- **证据**：静态确定 —— `sum`/`average`/`max`/`min`/`product`/`stdev`/`var` 在 `aggregateNumbers` 里各写一遍（`:150-180`），与 `fnSum`/`fnAverage`/`fnMinMax`/`stdevOf` 的公式相同但容器不同（`ArrayList<Float64>` vs `numbersOf`）；空集口径已经漂移：`aggregateNumbers:139-141` 对空集的 average/max 返回 `#DIV/0!`，而 `fnMinMax:417-419` 返回 `0`。
- **描述**：两套实现在"空集、错误值、文本单元格"三处的行为不一致，`DMAX` 与 `MAX` 对同一数据可能给不同结果（`DMAX` 先经 `dbRows` 过滤，空匹配集走 `#DIV/0!`）。
- **建议**：把聚合核心抽成"`Iterable<Float64>` + 模式"的单一实现，`fnSum`/`fnDatabase` 都调它；空集口径按 Excel（SUM=0、AVERAGE/MAX/MIN 对空区域分别为 `#DIV/0!`/0/0）在一处定义。

### [轻微][存量] #25 `XIRR` / `IRR` / `RATE` 迭代耗尽后无条件返回 `mid`，不返回 `#NUM!`

- **位置**：`f_excel/src/CalcFunctionsDbMisc.cj:458-472`（`fnXirr`）、`f_excel/src/CalcFunctionsDynFin.cj:661-676`（`fnIrr`）、`:700-715`（`fnRate`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「失败路径当成功」
- **证据**：静态确定 —— 三处都是 `for (_ in 0..200) { ... if (abs(fMid) < eps) return Number(mid) ... }` 之后直接 `CalcValue.Number(mid)`；没有"未收敛"标志。初值区间检查（`fLow * fHigh > 0` → `#NUM!`）只保证端点异号，不保证 200 次内达到容差。
- **描述**：极端现金流（多根、接近 -1 的折现率）下会返回一个未收敛的中间值，且与"已收敛"的结果无法区分；Excel 此时返回 `#NUM!`。金融场景下静默给错数比报错更危险。
- **建议**：循环结束后返回 `Error(Num)`；或用"相对误差 < 1e-10 且区间宽度 < 1e-12"双条件判定收敛。

<!-- 第 5 部分 -->

### [严重][存量] `renameSheet` 用空白 `Worksheet` 替换原表，整表单元格/样式/合并/图片全部丢失

- **位置**：`f_excel/src/ExcelDocument.cj:264-279`（关键行 `:274` `sheetList[i] = Worksheet(newName)`）
- **来源**：存量（`git blame -L 264,279` → `148f06a771 runningW 2026-10-30`，早于本次快照）
- **判据**：review-checklist §11（数据丢失 / 契约与实现不符）、§10 正确性
- **证据**：静态确定 —— `Worksheet` 的 `sheetName` 是 `private let`（`Worksheet.cj:28`），构造函数 `internal init(name:)` 只设名字（`Worksheet.cj:40-42`）；`renameSheet` 不复制 `cells` / `merges` / `stylesMap` / `richTexts` / `conditionalFormatsList` / `images` / `loader`，直接换成一个空对象，随后 `return true`。
- **描述**：调用 `doc.renameSheet("Sheet1", "Data")` 后 `sheet("Data")` 存在但没有任何数据；再 `write()` 会写出一个空表（原内容静默消失）。懒加载表还会丢掉 `loader`，改名后永远解析不出内容。README（`README.md:195`）只写 `renameSheet(oldName, newName): Bool`，没有"会清空数据"的提示，属于典型的数据丢失型契约违背。`ExcelDocument_test.sheetManagement`（`ExcelDocument_test.cj:41`）改名的是刚 `addSheet` 的空表，所以测试未能暴露。
- **建议**：把 `Worksheet.sheetName` 改为 `private var` 并提供 `internal func renameTo(name: String)`（只改名字），`renameSheet` 只做重名校验 + 改名；若必须保留"换对象"路径，则需深拷贝全部字段并重绑 loader。

### [严重][存量] `CellStore` 稠密块宽度只取首行，当前行更宽时尾部单元格永久读不到

- **位置**：`f_excel/src/CellStore.cj:218-237`（`get`）、`:240-275`（`addNumber` 稠密分支）、`:144-153`（`flushDense`）
- **来源**：存量（工作区快照；`CellStore` 为 M3-d 重构产物）
- **判据**：review-checklist §5（数据不可达 / 静默丢失）、§11（边界、契约不符）
- **证据**：静态确定 —— 逐行推演：
  1. `denseWidth` 只在"第二行开始"时由首行宽度定型（`:249-251`），此后仅靠"新行宽度 ≠ `denseWidth` → `flushDense`"（`:251-255`）维持矩形不变量；
  2. 但**当前行**（`denseRow`）继续 `addNumber` 时只判断 `row == denseRow && col == denseCol`（`:242`），不校验 `col <= denseWidth`，所以当前行可以比 `denseWidth` 宽；
  3. `get`（`:223`）用 `col <= this.denseWidth` 做可寻址判断，超出即 `return None`，既不回退稀疏列也不 `flushDense`；而 `size()`（`:117-122`）仍返回 `denseValues.size()`（含这些不可寻址的值）。
- **描述**：纯数值区首行 3 列、第二行 5 列时，`get(2,4)`/`get(2,5)` 返回 `None`（值确实存在于 `denseValues`）。解析路径 `ExcelDocument` → `Worksheet.setCell` 之后没有任何 `flushDense`，`denseActive` 一直为真，因此这类表**在文档整个生命周期内**尾部单元格读不到（`Worksheet.cell` 返回 `None`），`rowCount/colCount` 却已把它算进去。若之后有新的行或非数值单元格写入，`flushDense`（`:144` 用 `denseCol-1` 修正末行宽度）会把数据补回，说明这是"可寻址判断"缺陷而不是写入缺陷。
- **建议**：`get` 中稠密块无法寻址时先 `flushDense()` 再走稀疏路径（一次切换即可恢复正确性）；`addNumber` 在 `col > denseWidth && denseWidth > 0` 时直接 `flushDense()` 转稀疏，避免稠密块出现非矩形。补一条"首行 3 列、次行 5 列"的 `M3CellStore_test` 用例。

### [一般][存量] `FILTER` 的列筛选分支因 `include.size == grid.size` 恒不成立而返回 `#VALUE!`

- **位置**：`f_excel/src/DynamicArrays.cj:20-64`（判定在 `:32`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§14.1（半成品分支）
- **证据**：静态确定 —— 函数注释（`:20`）承诺"按行或按列筛选"，但入口条件要求 `include.size == grid.size`。列筛选的 `include` 是 1×m（单行），`include.size == 1`，只有 `grid` 恰好 1 行时方程才成立；n×m（n>1）表做列筛选必然落到 `:62` 的 `else` 返回 `#VALUE!`。行筛选（n×1）不受影响。
- **描述**：`FILTER(A1:C10, A1:C1=1)` 这类合法用法直接失效；用户无法用 FILTER 选列。附带问题：`include` 为 n×m（行列都>1）时进入列分支，只读 `include[0]`，属于静默降级（Excel 会做广播比较）。
- **建议**：拆成两个判定 —— `include.size == 1 && include[0].size == grid[0].size` → 列筛选；`include.size == grid.size && include[0].size == 1` → 行筛选；其余维度不一致返回 `#VALUE!`。

### [一般][存量] `LEFTB` / `RIGHTB` / `MIDB` 按字节切片后直接 `String.fromUtf8`，遇到多字节字符抛异常

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:541-566`（`:548`、`:553`、`:563`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 错误处理）、§10 正确性
- **证据**：静态确定 —— `text.toArray()` 取 UTF-8 字节，`bytes[0..count]` 等切片可能落在多字节字符中间；`String.fromUtf8` 的文档明确"入参不符合 utf-8 序列规则…抛出 `IllegalArgumentException`"（`stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:6384-6386`）。`Evaluator.eval` / `Worksheet` / `CalcEngine` 全链路无 `try`（`grep -rn "catch" CalcEngine.cj Evaluator.cj Worksheet.cj` 零命中），异常直接抛给 `CalcEngine.evaluate` 的调用方。
- **描述**：`LEFTB("中文", 1)` 在 Excel 里返回半个双字节字符或按整字返回，本实现抛 `IllegalArgumentException`，整个求值调用中断（不是 `#VALUE!`）。这是普通输入即可触发的失败路径，不是极端用例。
- **建议**：切完后向前/向后对齐到 UTF-8 字符边界（或用 `runes()` + 字节宽度计步），越界/截断返回 `CalcValue.Error(CalcError.Value)`；同时给 `eval` 外层加"函数实现抛异常 → `#VALUE!`/`#NUM!`"的兜底。

### [一般][存量] `TEXT` 的时间格式把 `mm` 当月份替换，且大写格式串完全不生效

- **位置**：`f_excel/src/CalcFunctionsTextDate.cj:194-251`（替换序列 `:209-220`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名 / 注释不符）、§10 正确性
- **证据**：静态确定 —— 分支条件用 `lower`（`:203-204`）判断是否日期，但替换全部落在原始大小写的 `text = code` 上（`:209-220`）：`replace("mm", 月份)` 先执行，`replace("m", 月份)` 兜底，因此 `hh:mm:ss` 的分钟位永远输出月份（`0.5` → `12:12:00`）；`HH:MM:SS` 因为 `replace("hh")` 匹配不到大写而原样返回格式串。
- **描述**：`TEXT(0.5,"hh:mm:ss")`、`TEXT(45231,"HH:MM")` 等常见调用输出错误文本，且是"看起来正常"的错误（不会报错），下游字符串比对/写回会静默拿到错值。
- **建议**：先 `code.toAsciiLower()` 再替换（或按 token 词法扫描而不是链式 `replace`）；`m`/`mm` 在 `h`/`s` 上下文中判为分钟，独立时判为月份。补 `TEXT` 的 `hh:mm`、`HH:MM` 用例。

### [一般][存量] `DOLLAR` / `FIXED` 的负数格式与 Excel 不一致

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:496-524`（`:517-522`）
- **来源**：存量
- **判据**：review-checklist §11（与规格 / Excel 语义冲突）
- **证据**：静态确定 —— 先 `text = "(" + text + ")"`（`:517-519`）再 `text = "$" + text`（`:520-522`），得到 `"$(1,234.57)"`；`dollar == false`（FIXED）时同样走括号分支。Excel：`DOLLAR(-1234.567,2)` = `($1,234.57)`，`FIXED(-1234.567,1)` = `-1,234.6`。
- **描述**：`DOLLAR` 负号/括号位置错（货币符号被包进括号内），`FIXED` 负号变成括号 —— 两者都是纯格式字符串错误，但会进入报表文本。
- **建议**：`dollar` 分支按 `"(" + "$" + text + ")"` 组装；`!dollar` 分支用 `"-" + text`。

### [一般][存量] `CalcValue.Number` 允许 `Inf`/`NaN` 进入，任何文本化或写回路径都会抛 `ExcelException`

- **位置**：`f_excel/src/CalcValue.cj:93-109`、`:160-174`；触发源示例 `f_excel/src/CalcFunctionsStatTextExt.cj:142-146`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失）、§3（异常逃逸）
- **证据**：静态确定 —— `formatNumber`（`Numbers.cj:27-33`）对 `NaN`/`Inf` 直接 `throw ExcelException("... 无法写入 xlsx")`，而 `CalcValue.toString()`（`:96`）与 `calcToText`（`:163`）无条件调用它；`KURT` 在 `n == 3` 时分母 `Float64((n-1)*(n-2)*(n-3))` 为 `0.0`，浮点除零得 `Inf`（`:143-146`），`Number(Inf)` 合法返回。同理 `Number(a + b)` 溢出到 `Inf`（`Evaluator.cj:239`）。
- **描述**：`CONCAT(KURT(A1:A3))`、`VALUETOTEXT(...)`、`recalculate(writeBack: true)` 在遇到 `Inf`/`NaN` 时抛"无法写入 xlsx"——错误消息面向写文件，却出现在求值/文本化路径上；异常沿 `evaluate` 直接抛出，未转成 `#NUM!`。
- **建议**：`KURT` 加 `n < 4 → #DIV/0!`；`calcToText` / `toString` 遇到非有限值返回 `#NUM!` 文本；`formatNumber` 的"不可写"契约只保留给写文件路径（拆成 `formatNumberForWrite`）。

### [一般][存量] `CellStore` 的 `others` / `numbers` 槽位只增不减，覆写换类型与删除都会泄漏

- **位置**：`f_excel/src/CellStore.cj:197-206`（`encode`）、`:304-325`（`addOther`）、`:327-337`（`remove`）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 长期持有）、§7（生命周期）
- **证据**：静态确定 —— `addOther` 覆写已有格子时：数值→文本走 `encode` 追加一条 `others` 记录（旧 `numbers` 槽位不再被任何 payload 引用）；文本→数值走 `numbers.addBits`（旧 `others` 记录残留）。`remove` 只删 `rows/cols/payload` 三列，`others`/`numbers` 无回收。二者都按"历史写入次数"增长，与当前单元格数无关。
- **描述**：对同一格反复 `setCell` 交替 `Number`/`Text`（或反复 `setCell`+`clearCell`）会让 `others`/`numbers` 无界增长；一个"编辑—回填"循环的长期进程会持续涨 RSS。`Worksheet.setCell` 是公开 API，该路径可直接触达。
- **建议**：`others` 改成"下标空闲链表 + 复用"（删除/覆盖时回收槽位），或对纯数值表保持稠密块优先；至少给 `others.size` 一个上界并在超限时改走 `HashMap<(row,col), CellValue>` 旁路。

### [一般][存量] `DependencyGraph.add` 重复调用只追加不清理，旧依赖残留；`dependenciesOf` 泄漏内部可变列表

- **位置**：`f_excel/src/DependencyGraph.cj:39-58`、`:61-66`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§10 设计
- **证据**：静态确定 —— `add` 只在 `deps` 里"不存在则新建"，随后 `for (item in refs) if (!list.contains(depKey)) list.add(depKey)`（`:52-55`），**从不清空** `list`；同名格子用新公式再 `add` 一次，旧依赖仍在 `order()` / `cycles()` 中生效。`dependenciesOf` 直接 `return list`（`:62-64`），调用方拿到的是图内部 `ArrayList`，`add`/`clear` 会静默改图。
- **描述**：`DependencyGraph` 是公开类（README 的模块级类型清单），天然被当作"可重建/可更新"的结构使用；一旦上层按"改公式后重新 add"的方式维护，会得到假环或错序重算。当前 `CalcEngine.buildGraph`（`CalcEngine.cj:281-297`）每格只 add 一次，所以主路径未暴露，但契约本身不成立。
- **建议**：`add` 前 `list.clear()`（或用 `deps.add(key, newList)` 替换）；`dependenciesOf` 返回副本（`ArrayList<String>(list)`）或改为只读迭代。

### [一般][存量] `SHEET` / `SHEETS` 恒返回 `1`，参数 `count` 与 `ev` 均未使用

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:430-432`
- **来源**：存量
- **判据**：review-checklist §3（空实现）、§14.1（接线缺失）
- **证据**：静态确定 —— 函数体只有 `CalcValue.Number(1.0)`；`count: Bool` 参数与 `ev` 都未读取。`CalcResolver`（`Evaluator.cj:23-35`）没有"sheet 数量 / 当前 sheet 索引"的访问器，实现无从取得真实值。
- **描述**：多 sheet 工作簿里 `SHEETS()` 返回 1，`SHEET()` 返回 1（即使当前在第 3 个表），是"会算错但看起来成功"的静默错误；已注册进 `FunctionRegistry`（`SHEET`/`SHEETS` 在 `FunctionRegistry.cj:302-303`）并被计入"350 个函数"。
- **建议**：给 `CalcResolver` 增加 `sheetCount(): Int64` 与 `currentSheetIndex(): Int64`，两个函数分别实现；注释标注阶段性限制的话，不如直接返回 `#N/A` 更安全。

### [一般][存量] `UNIQUE` 的行键用 `toString` 拼接，文本 `"1"` 与数字 `1` 被判为重复

- **位置**：`f_excel/src/DynamicArrays.cj:124-145`（`rowKey` 在 `:138-145`）
- **来源**：存量
- **判据**：review-checklist §11（数据错误）、§6.4（低效算法）
- **证据**：静态确定 —— `rowKey` 逐格 `out += item.toString()`（`:141`），`CalcValue.toString()` 对 `Text("1")` 与 `Number(1.0)`（`formatNumber`）都产出 `"1"`；分隔符 `\u{1F}` 只防跨格串接，不区分类型。
- **描述**：`UNIQUE` 会把文本 `1` 与数值 `1`、`TRUE` 与文本 `"TRUE"` 合并成一行；同时 `seen.contains` 是线性扫描，n 行去重为 O(n²)，`rowKey` 的 `+=` 每格再产生一次全串复制。
- **建议**：行键改为带类型标签的编码（`"n:"`/`"t:"`/`"b:"` 前缀 + 值），并用 `HashSet<String>` 替代 `ArrayList.contains`。

### [一般][存量] `Evaluator.rangeValue` 无上限物化整块区域，整列引用在高密度表上是 OOM 面

- **位置**：`f_excel/src/Evaluator.cj:89-116`
- **来源**：存量
- **判据**：review-checklist §5（一次性物化、拒绝路径缺失）
- **证据**：静态确定 —— `usedBounds` 只把范围裁到已用区域（`:97-99`），随后双层 `while` 逐格 `resolver.valueAt` 并 `items.add` 进 `ArrayList`（`:102-111`），再无任何元素数上限；`SEQUENCE` 有 `rows*cols > 1_048_576 → #NUM!` 保护（`DynamicArrays.cj:174`），`rangeValue` 没有对应保护。
- **描述**：量级估算：已用区域 10 万行 × 100 列时，`SUM(A:A)` 一次物化 1e7 个 `CalcValue`（枚举含 `String`/`Float64` 负载，按 ≥16 B/个估 ≥160 MB，加 `Array` 头与 `ArrayList` 扩容峰值约 2 倍），单次求值即可把常驻推到数百 MB；嵌套聚合（`SUMPRODUCT`、多次引用同区域）会成倍叠加。触发条件是"大表 + 整列引用"，属于常见报表写法。
- **建议**：给 `rangeValue` 加"元素数上限"（如 1e6）并在超限时返回 `#NUM!` 或走"只算数值聚合"的流式路径（聚合函数按需回调 `valueAt` 而不物化数组）。

### [一般][存量] 公式参数转 `Int64` 未做范围校验，超范围 / `NaN` 抛异常中断整次求值

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:418`、`:500`、`:546`、`:550`、`:555-556`；`f_excel/src/CalcFunctionsTextDate.cj:90`、`:115`、`:119`、`:339-348`；`f_excel/src/DynamicArrays.cj:150`、`:156`、`:163`、`:169`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失）、§10 正确性
- **证据**：静态确定 —— 各处模式为 `Int64(numberArg(ev, args, i, 0.0) ?? ...)`；仓颉文档明确"数值类型转换…根据默认的溢出策略将抛出异常"（`cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/integer.md:137`），`Int64(NaN)` / `Int64(1e30)` 同样抛。求值链路上无 `catch`（同 LEFTB 条的检索结果）。
- **描述**：`LEFT("abc", 1e30)`、`MID("abc", 1e300, 1)`、`SEQUENCE(1e20)`、`DATE(1e20,1,1)` 等由公式内容决定，属不可信输入；结果是异常穿透 `CalcEngine.evaluate`，而不是 `#VALUE!` / `#NUM!`。
- **建议**：抽 `argToInt64(...): ?Int64`，先判 `isNaN`/`isInf`/范围（`|v| <= 2^53`）再转，失败返回错误值；同时在 `Evaluator.eval` 的 `Call` 分支加 `try { entry.impl(...) } catch { #VALUE! }` 兜底。

### [一般][存量] 懒加载 `InputStream` 落盘的临时文件永不删除

- **位置**：`f_excel/src/ExcelDocument.cj:42-56`、`:318-341`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称）、mem §6.2
- **证据**：静态确定 —— `spoolInput` 用 `File.createTemp` 生成 `xl-tmp*` 文件（`:319-326`），路径存进 `lazyPath`（`:46`），全类没有 `close()`/`Drop`/`removeIfExists` 调用（`grep -n "removeIfExists" ExcelDocument.cj` 只命中 `spoolInput` 的失败分支 `:336`）。
- **描述**：每次 `ExcelDocument(ByteBuffer(...), options: eager=false)`（`Eager_test.lazyInputStreamSpools` 就是这种用法）都会在系统临时目录留下一个完整 xlsx 副本，直到进程退出、且退出时也不主动清理；长期服务反复读取上传流会持续占用磁盘（文件大小 = 输入大小）。
- **建议**：实现 `ExcelDocument.close()`（关掉/删除 `lazyPath`，若为自建临时文件），或给 `spoolInput` 的产物加 `Drop` 语义（仓颉 `Resource`/`Drop` 接口）；文档里写明"懒加载 InputStream 会在临时目录留副本"。

### [一般][存量] `WIDECHAR` / `ASC` 为恒等映射（空实现），两个函数名共用同一份无转换逻辑

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:537-539`；注册 `FunctionRegistry.cj:310-311`
- **来源**：存量
- **判据**：review-checklist §3（公开契约承诺有行为，函数体为 no-op）
- **证据**：静态确定 —— 函数体只有 `CalcValue.Text(calcToText(scalarize(ev.arg(args, 0))))`，无任何半角/全角转换；`WIDECHAR` 与 `ASC` 注册到同一个 `fnWideAsc`，二者语义（半角→全角、全角→半角）相反，不可能同时正确。
- **描述**：`ASC("ＡＢＣ")` 应得 `"ABC"`，实得 `"ＡＢＣ"`；`WIDECHAR("ABC")` 应得 `"ＡＢＣ"`，实得 `"ABC"`。README 以"350 个函数"宣称 Excel 函数覆盖（`README.md:22`），这类 no-op 会让下游拿到错值。
- **建议**：用 `Unicode` 区段映射实现半角↔全角（U+FF01–FF5E ↔ U+0021–007E、U+3000 ↔ U+0020），或暂时从注册表摘掉这两个名字，避免"注册了但不算"。

### [一般][存量] `TEXTSPLIT` 第 3 参数被静默忽略，且结果方向为单列（Excel 为单行）

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:462-471`；注册 `FunctionRegistry.cj:306`（`maxArgs = 3`）
- **来源**：存量
- **判据**：review-checklist §14.1（只做一半的分支 / 参数未接线）、§11
- **证据**：静态确定 —— 函数体只读 `args[0]`、`args[1]`，`args[2]`（`row_delimiter`）从未读取；返回结构是 `rows.add([CalcValue.Text(part)])`，即 N×1 单列。Excel `TEXTSPLIT("a,b,c", ",")` 返回 1×3 单行。
- **描述**：带行分隔符的调用（`TEXTSPLIT("a,b;c,d", ",", ";")`）只按列分隔符切一次，`";"` 混进单元格文本；方向和 Excel 相反，下游 `INDEX`/溢出引用会错位。
- **建议**：最小修复是按 `args.size` 实现两段切分（先行后列），并把单列结果改成单行；若暂不支持，注册表把 `maxArgs` 收紧到 2，让多余参数报 `#VALUE!` 而不是被吞。

### [一般][存量] 懒加载与告警列表无同步；实例被多线程共享时解析结果与告警可能错乱

- **位置**：`f_excel/src/ExcelDocument.cj:33-35`、`:173-198`、`:436-477`；`f_excel/src/Worksheet.cj:55-62`
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护 / 发布逸出）
- **证据**：待确认 —— 本部分没有 `static`/全局可变状态，`ExcelDocument` 实例是否跨线程共享取决于调用方（README/设计文档均未声明线程安全）。缺的信息：是否存在"多线程读同一文档"的使用契约。若存在，路径是：两个线程同时 `sheet.cell(...)` → `ensureLoaded()` 各自命中 `loader.isSome()`（`Worksheet.cj:56-59`，先置 `None` 再加载，非原子）→ 同一 `LazySheetSource.loadInto` 被并发执行两次，并并发 `warnings.add`（`ExcelDocument.cj:463`，共享 `ArrayList`）。
- **描述**：如果并发使用，后果是同一 sheet 解析两遍（内存翻倍、`CellStore` 被追加进重复行）与 `ArrayList` 并发写（未定义行为）。若确定单线程使用，本条应降为"文档未声明线程安全"。
- **建议**：`ExcelDocument` 明确标注"非线程安全"，或给 `ensureLoaded` 加一次性互斥（`Mutex`/原子状态机），并把 `warnings_` 的写入收进该临界区。

### [轻微][存量] 死代码与死参数（本部分范围内逐项取证）

- **位置与证据**（静态确定，全仓搜索结果）：
  - `f_excel/src/ExcelDocument.cj:35` `private let lazyParts` —— 只有 `:174` 一处写入，全仓无读取（`grep -n lazyParts` 仅 2 条命中，均为定义/写入）。
  - `f_excel/src/ExcelDocument.cj:186-195` —— `case None => LazySheetSource(Path("."), ...)` 不可达：进入该 `else` 分支的前提是 `options.eager == false`，而两个带 `load()` 的构造函数（`:42-46`、`:71-72`）都会先给 `lazyPath` 赋值，`ExcelDocument()`（`:38-40`）不调用 `load`。
  - `f_excel/src/CalcValue.cj:264-266` `serialToDateTime` —— `internal`，全仓除定义外零引用（`grep -rn serialToDateTime` 仅 1 条）。
  - `f_excel/src/CalcFunctionsStatTextExt.cj:512` 局部 `pattern` —— 赋值后从未读取；连带 `:526-535` 的 `zeros` 只被这一行使用（`grep zeros` 仅本文件 2 处）。
  - `f_excel/src/CfEval.cj:21-28` `cfRuleHit` 的 `sheet`、`ref` 两个参数函数体内零使用（唯一调用点 `Worksheet.cj:230` 仍在传值）。
  - 可见性建议（**不算死代码**）：`CellStore.size()`（`CellStore.cj:117`）只被 `M3CellStore_test.cj:30` 使用；`ByteColumn` 整个类只服务于 `CellStore`。
- **判据**：review-checklist §1
- **建议**：删 `lazyParts`、`serialToDateTime`、`pattern`/`zeros`、不可达分支；`cfRuleHit` 去掉两个未用参数（`expression` 闭包已捕获），把 `CellStore.size()` 收窄到 `internal`（已是）并在注释里写明测试用途。

### [轻微][存量] 重复逻辑：数值文本化两套、枚举 `==` 走 `toString`、名字表两处、错误展开样板 27 处

- **位置**：
  - 数字→文本：`f_excel/src/CellValue.cj:72`（`"${v}"`）vs `f_excel/src/CalcValue.cj:96`（`formatNumber(v)`）—— 同一个数字在 `CellValue.toString()` 与 `CalcValue.toString()` 下可能不同（如 `1.0E20`、`-0.0`），`UNIQUE` 行键（`DynamicArrays.cj:141`）与日志/`CalcReport` 会分别走两条路径。
  - 枚举相等：`f_excel/src/CalcValue.cj:36-42`、`f_excel/src/ConditionalFormat.cj:90-92`、`:139-141` —— 三处 `operator ==` 都是 `this.toString() == that.toString()`，于是 `CfRuleType.Unknown("cellIs") == CellIs` 为真（`Unknown` 可携带任意文本），`CalcError`/`CfOperator` 同理。
  - 名字表：`f_excel/src/ConditionalFormat.cj:42-64`（`toString`，18 个字面量）与 `:66-88`（`parse`，同一批 18 个字面量）—— 两处各维护一份映射，新增 `CfRuleType` 时容易漏改一侧。
  - 参数错误展开样板：`match (firstError([x])) { Some(e) => return Error(e); None => () }` 在本部分 `CalcFunctionsTextDate.cj` 出现 10 次、`Evaluator.cj` 2 次；`sortedNumbers(ev, [args[0]])` + 同款 `match` 在 `CalcFunctionsStatTextExt.cj` 出现 3 次（全模块 27 处）。
- **来源**：存量
- **判据**：review-checklist §2
- **证据**：静态确定（上面的搜索与逐行比对）
- **建议**：数值文本化统一走 `formatNumber`（`CellValue` 侧若需保留 `"${v}"` 语义要写明理由）；枚举 `==` 改成 `match ((this, that))` 的逐分支比较；`CfRuleType` 的名字表收敛为 `const` 数组 + 双向查表；错误展开抽成 `internal func orReturn(error: ?CalcError, fail: CalcValue): Option<CalcValue>` 之类的小助手，避免 27 处复制。

### [轻微][存量] 条件格式 / 合并失败被记为 `SheetEntryMissing` 告警，诊断信息误导

- **位置**：`f_excel/src/ExcelDocument.cj:375-399`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）、§13 相邻（告警语义）
- **证据**：静态确定 —— `addConditionalFormat` 与 `merge` 抛出的 `ExcelException` 被包装成 `ExcelWarningKind.SheetEntryMissing`（`:382`、`:396`），该枚举的本义是"sheet 部件读取失败"（同文件 `:167`、`:465` 的用法）。
- **描述**：使用者按 kind 过滤告警时会把"条件格式规则非法""合并区域非法"误判成"文件缺 sheet 部件"，排障方向被带偏；两段 `try/catch` 结构也完全重复（§2 同源）。
- **建议**：新增 `ConditionalFormatInvalid` / `MergeRangeInvalid`（或复用一个 `StructuralWarning`），并把两段合并成一个 `recordWarning(kind, e)` 辅助函数。

### [轻微][存量] `PERCENTRANK` 在 `x` 大于最大值时返回大于 1 的百分比，应返回 `#NUM!`

- **位置**：`f_excel/src/CalcFunctionsStatTextExt.cj:171-191`（`:188-190`）
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— 非 exclusive 分支分母 `n-1`、分子 `below`；`x` 大于所有元素时 `below == n`，结果 `n/(n-1) > 1`，函数不做范围校验（只有 `n < 2` 的检查 `:179`）。
- **描述**：`PERCENTRANK({1,2,3}, 10)` 返回 `1.5`，Excel 返回 `#NUM!`；下游按百分比使用时会被放大到错误区间。
- **建议**：算出结果后判 `0 <= v <= 1`，越界返回 `#NUM!`（INC 与 EXC 都需要）。

### [轻微][存量] `validateName` 用 UTF-8 字节数当"字符数"，11 个汉字即被判超长

- **位置**：`f_excel/src/ExcelDocument.cj:230-242`（`:234`）
- **来源**：存量
- **判据**：review-checklist §11（与文档/规格不符）、§10 正确性
- **证据**：静态确定 —— `name.toArray().size > 31` 数的是字节；Excel/README（`README.md:198`"超过 31 字符"）指字符。
- **描述**：`addSheet("第一季度销售数据汇总表明细")`（11 个汉字 = 33 字节）被拒绝，而 Excel 允许 31 个字符。反过来纯 ASCII 判断是正确的，所以问题只在非 ASCII 名。
- **建议**：用 `name.runes()` 计数（或在 UTF-8 上按首字节计字符数）；同时可补一条非 ASCII 名用例。

### [轻微][存量] `CellRef` 允许构造非法坐标，`toString()` 直接抛异常

- **位置**：`f_excel/src/CellRef.cj:86-91`、`:176-184`
- **来源**：存量
- **判据**：review-checklist §11（前置条件未校验）
- **证据**：静态确定 —— `public init(row:col:rowAbs:colAbs:)` 对 `row`/`col` 无校验；`toString()`/`toA1()` 调 `columnLetters(this.col)`，而 `columnLetters` 对 `< 1` 或 `> 16384` 抛 `ExcelException`（`:57-60`）。
- **描述**：`CellRef(0, 0).toString()` 抛异常；日志/告警路径（`ExcelWarning.toString`）里拼接坐标时，一个越界对象就能把日志变成异常。
- **建议**：`init` 做范围断言（或在 `toString` 里降级为 `"R0C0"` 形式），把"非法坐标"在构造期就挡住。

<!-- 第 6 部分 -->

### [严重][存量] #1 公式解析递归无深度上限，恶意/畸形公式可直接栈溢出崩溃进程

- **位置**：`f_excel/src/FormulaParser.cj:154-162`（`parseUnary` 每遇一个 `-`/`+` 递归一层）、`f_excel/src/FormulaParser.cj:207-211`（`(` 内递归 `parseExpression` → 又一条 6 层调用链）；同深度递归下游：`f_excel/src/FormulaAst.cj:152-191`（`collectRefs`）、`f_excel/src/Evaluator.cj:52-64`（`eval`）
- **来源**：存量（快照模式无基线；`git blame -L 154,162` → `ed6ecc68` 2026-10-31）
- **判据**：review-checklist §4（无界递归）/ §11（存量缺陷）
- **证据**：静态确定 —— 递归深度等于输入前缀 `-` 个数或括号嵌套层数，而输入是 xlsx 的 `<f>` 文本（`f_excel/src/WorksheetParser.cj:419` `formulaText.toString()`），文件内容没有任何长度/深度上限；`FormulaParser.parse`（47-57）只捕获异常、不做深度记账。按每层约 150 B 栈帧、1 MB 栈估算，约 6 k 层括号或前缀负号即可压穿栈。
- **描述**：`=((((…1…))))` 或 `=-----…1` 这类公式在 `CalcEngine.evaluate` / `recalculate` 时栈溢出，进程直接崩溃（不是慢，也不是 `#VALUE!`）。第三方生成的 xlsx、用户上传的 xlsx 都可能带这种公式，而读取侧其它路径（数值/日期/共享字符串）都做了宽容降级，唯独语法层没有护栏。
- **建议**：`tokenizeFormula` 里维护括号深度计数并设常量上限（例如 `MAX_FORMULA_DEPTH = 256`），超限抛 `FormulaSyntaxException`（外层映射为 `#VALUE!`/`#NAME?`）；`parseUnary` 改为循环累计符号个数；或改用显式栈的迭代下降解析。

### [一般][存量] #2 sheet 名 31 字符上限按 UTF-8 字节判断，合法中文名的文件被拒

- **位置**：`f_excel/src/ExcelWriter.cj:53`（`name.toArray().size > 31`）、`f_excel/src/ExcelWriter.cj:56`（同一名字第二次 `toArray()`）
- **来源**：存量（`git blame -L 50,56` → `27c3f80d` 2026-10-30）
- **判据**：review-checklist §11（边界差一 / 语义与消息不符）/ §13 判据「口径与规格不一致」；`String.toArray()` 返回 UTF-8 字节数组（`cangjie-doc` `core_package_structs.md:8207-8213`「获取字符串的 UTF-8 编码的字节数组」），`String.size` 也是字节长度（同文件 `6186-6191`）
- **证据**：静态确定 —— 11 个汉字 = 33 字节 > 31，直接抛「sheet 名不得超过 31 个字符：明细表…」；而 Excel 的限制是 31 个字符（非 ASCII 基本 1 个、U+10000 以上 2 个 UTF-16 单元）。仓库自己的测试只用「明细」「一」「二」这类 ≤ 5 字的名字（`ExcelWriter_test.cj:57,75,109`），边界没被覆盖。
- **描述**：数据正确性上不会写坏文件，但会把完全合法的中文 sheet 名拒掉，且错误消息与真实原因相反，使用者会以为是名字太长。附带成本：每个 sheet 名分配两份字节数组。
- **建议**：改用 `name.runes().count()` 判断（对 U+10000 以上按 2 计则再细分），并把 `56` 行的字节循环改为复用同一份 `Array<Byte>`。

### [一般][存量] #3 `open`/`build` 失败路径不释放 ZipReader 与 spool 临时文件

- **位置**：`f_excel/src/ExcelSheetStream.cj:192-197`（spool 分支 `ZipReader(tempPath)` 失败只抛不删临时文件）、`:199-204`、`:211-257`（`build` 内 `PackageReader.read`、`StylesLite.load`、`SharedStringTable.load` 抛异常时无任何清理）
- **来源**：存量（`git blame -L 190,200` / `-L 219,224` → `27c3f80d` 2026-10-30）
- **判据**：review-checklist §11「资源不对称（打开未关、异常跳过释放）」
- **证据**：静态确定 —— `build()` 没有 try/catch/finally；`PackageReader.read(zip)` 在缺/坏 `workbook.xml` 时抛 `ExcelException`（`PackageReader.cj:56,61,80`），`StylesLite.load` 在坏 styles 时抛（`StylesLite.cj:91`），`SharedStringTable.load` 同理。此时 `ZipReader` 已打开文件句柄（`f_zip/src/ZipReader.cj:64-72`，`init(path)` 立即 `FileSource(path)`），而 `ExcelSheetStream` 对象尚未构造，调用方**根本拿不到 `close()`**。spool 分支的临时文件只在 `copy` 失败时删除（`188` 行），`ZipReader` 构造失败时残留。
- **描述**：批量处理损坏文件（或攻击者构造的“看似 xlsx”包）会累积未关闭的 fd 与临时文件；在常驻服务里最终触发 fd/磁盘耗尽。错误本身有正确包装（`ExcelException`），只是资源没回收。
- **建议**：把 `build` 的调用点包成 `try { return build(...) } catch (e) { try { zip.close() } catch(_){}; match (spool) { case Some(p) => try { removeIfExists(p) } catch(_){}; case None => () }; throw e }`，或让 `build` 自己在 `finally` 里收敛资源。

### [一般][存量] #4 `styles.xml` 缺失时静默降级，`StylesMissing`/`DateBaseMismatch`/`UnsupportedTimeFormat` 三个公开告警种类从不产生

- **位置**：`f_excel/src/ExcelSheetStream.cj:219-224`（`case None => ()`）；对照 `f_excel/src/ExcelException.cj:47`（`UnsupportedTimeFormat`）、`:51`（`DateBaseMismatch`）、`:52`（`StylesMissing`）；承诺源 `f_excel/README.md:516-527`（告警枚举全文 + 「告警不打断解析，通过 … `warnings()` 读取」）
- **来源**：存量（`git blame -L 219,224` → `27c3f80d`；三个枚举值 `git blame -L 44,60` → 同批）
- **判据**：review-checklist §3（静默降级 / 契约承诺但实现为空）、§14.1（接线缺失：枚举 case 无生产点）
- **证据**：静态确定 —— `grep -rn "ExcelWarningKind.StylesMissing\|ExcelWarningKind.DateBaseMismatch\|ExcelWarningKind.UnsupportedTimeFormat" f_excel/src/*.cj` 除枚举定义外 **0 处**；`build()` 在 `zip.read("xl/styles.xml")` 返回 `None` 时只把 `styles` 留在 `StylesLite.empty()`，不记任何告警。
- **描述**：缺 styles 的文件（第三方导出器常见）里，日期序列号、百分比、自定义格式全部退化成裸数字，用户拿到的 `Number(45000)` 而不是日期，却没有任何提示；按 README 监听 `StylesMissing` 的代码永远等不到。另两个 kind 同样是“文档承诺有、代码里没有”的悬空契约。
- **建议**：`loadStyles == true` 且部件缺失时补 `warnings_.add(ExcelWarning(StylesMissing, "xl/styles.xml 缺失，样式与日期格式按默认处理"))`；`DateBaseMismatch`（`workbookPr.date1904` 与调用方 `date1904` 冲突时）与 `UnsupportedTimeFormat`（`[h]:mm` 之外的时间格式）要么接上生产点，要么从公开枚举与 README 删除。

### [一般][存量] #5 共享字符串全量解压物化，无大小上限；`sharedStringsIndex` 也只是把常驻换成峰值不降

- **位置**：`f_excel/src/ExcelSheetStream.cj:229-241`（`zip.read("xl/sharedStrings.xml")` → `SharedStringTable.load(bytes)` / `SharedStringIndex.build(bytes)`）
- **来源**：存量（`git blame -L 228,244` 主体 `27c3f80d`，索引分支 `71cfef61` 2026-10-31）
- **判据**：review-checklist §5「一次性物化」「无拒绝路径」；§7 先决条件（量化）
- **证据**：静态确定（全量读入）+ 需实测（真实峰值）—— `ZipReader.read` 返回整段解压字节（`f_zip/src/ZipReader.cj:89-95`）；`SharedStringTable.load` 再为每个 `<si>` 建 `String`（`SharedStringTable.cj:45-52` 起）；`SharedStringIndex.build(bytes)` 同样先接收全量 `Array<Byte>` 再 scan + 落盘（`SharedStringIndex.cj:45-58`）。量化：解压后 SST 为 S 字节时，峰值 ≈ S（字节数组）+ ≈S（字符串副本）+ 索引数组（每 `<si>` 16 B）≈ 2S 以上，无上限、无分块、无拒绝阈值。
- **描述**：README:16 宣传流式读「内存与行数无关」，README:530 只承认「sharedStrings 随文件增长」——实际是**随 SST 解压大小线性增长，且是瞬时峰值**，`sharedStringsIndex = true` 省的是常驻而不是峰值（建索引那一刻同样要 S 字节在场）。200 MB 的 sharedStrings 就能把 512 MB 堆的服务打到 OOM。
- **建议**：用 `zip.open("xl/sharedStrings.xml")` 边解压边扫 `<si>` 起点偏移（配一份落盘副本），彻底不出现整段 bytes；至少在 `build()` 入口加可配置上限（例如 `maxSharedStringsBytes`），超限抛 `ExcelException` 并保留“按需索引”降级路径。

### [一般][存量] #6 告警列表无上限累积；`mergedRanges()` 每调用一次重复追加一条告警

- **位置**：`f_excel/src/ExcelSheetStream.cj:124`（`warnings_`）、`:328-333`（`absorb` 全量并入）、`:335-343`（`noteMergesUnavailable` 无去重）、`:94-100`（`RowReader.mergedRanges` 每次未结束都调用它）
- **来源**：存量（`git blame -L 320,345` → `27c3f80d`）
- **判据**：review-checklist §5「无界容器（随请求增长，GC 后条目仍在）」、§11
- **证据**：静态确定 —— `warnings_` 只 `add` 从不裁剪；逐格告警（`NumberParseFailed`/`InvalidCellRef`/`UnknownCellType`/`MaxColsTruncated` 之外者均为每格一条，`SheetRowHandler` 侧 add）会按坏格数量线性增长：100 万坏格 ≈ 100 万 `ExcelWarning`（每个含 kind + 插值后的 message + sheet 名 + 可选 `CellRef`），估算数百 MB 且在全生命周期内不被回收。另一个放大点：`reader.mergedRanges()` 在流结束前每次调用都 `add` 一条 `MergedRangesUnavailable`，轮询式写法会把同一告警刷屏。
- **建议**：同类告警按 `(kind, sheet)` 聚合为首条 + 计数（`ExcelWarning.count` 或 `warningsSummary()`），或设硬上限（例如 10 000 条后只计数）；`noteMergesUnavailable` 加 `var mergesWarned = false` 一次性标志。

### [一般][存量] #7 共享公式平移会把“长得像单元格引用”的未加引号表名前缀一起平移

- **位置**：`f_excel/src/FormulaShift.cj:85-120`（字母段+数字段成立即按引用处理，`109-112` 只排除标识符续字符与 `(`，**未排除 `!`**）、`:146-151`（据此改写坐标）；调用点 `f_excel/src/WorksheetParser.cj:431-437`（共享公式）、`f_excel/src/Worksheet.cj:226`（条件格式公式）
- **来源**：存量（`git blame -L 85,90` → `ed6ecc68` 2026-10-31）
- **判据**：review-checklist §11（边界 / 语义与注释不符：注释承诺“带引号的工作表名原样复制”暗示表名不参与平移）
- **证据**：静态确定 —— 输入 `S1!A1`、`dRow = 1` 时，`S1` 命中 `hasLetters && hasDigits`、`columnIndex("S") = 19 ≤ 16384`，于是被当作引用改写，输出 `S2!A2`。`Sheet1!A1` 只是因为 "SHEET" 折算列号 > 16384 被 `columnIndex` 返回 `None`（`CellRef.cj:34-56`）才侥幸原样保留，属巧合而非设计。
- **描述**：表名为 1–3 个字母 + 数字（`S1`、`Q1`、`AB12`）且文件中未加引号时，表名被平移，公式指向另一张表 —— 共享公式从属格与条件格式规则会得到错误结果（数据错误，不是异常）。Excel 通常会给歧义表名加引号，因此触发面窄，但代码侧没有任何防护。
- **建议**：判定为 cell ref 后补一条 `if (i < n && runes[i] == r'!')` 则整段原样输出；更稳的是先按 `!` 切出表名前缀（含 `'…'`）再只对后半段平移。

### [一般][存量] #8 大区域依赖被截断为“左上+右下”两个角点，注释承诺的“保守重算路径”不存在

- **位置**：`f_excel/src/FormulaAst.cj:161-176`（`area > MAX_DEPENDENCY_CELLS` 只 `add` 两个角）、`:130-137`（注释「超过 MAX_DEPENDENCY_CELLS 时只记左上与右下，重算走保守路径」）；消费方 `f_excel/src/DependencyGraph.cj:44-57`
- **来源**：存量（`git blame -L 166,176` → `ed6ecc68` 2026-10-31）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复中的边界缺失」；`MAX_DEPENDENCY_CELLS` 全仓仅 3 处引用（定义 + 一处比较 + 无消费）
- **证据**：静态确定 —— `DependencyGraph.add` 把 `collectRefs` 的结果原样变成边，没有任何“粗粒度/保守”标记；`grep -rn "MAX_DEPENDENCY_CELLS" f_excel/src` 只有 `FormulaAst.cj:137,167`。`CalcEngine.recalculate`（`CalcEngine.cj:141-190`）全表扫描、根本不读图，所以仓内主路径未受影响。
- **描述**：`=SUM(A:A)`、`=SUM(A1:B100000)` 这类公式（area 1 048 576 或 2×10⁵）在 `DependencyGraph.dependenciesOf` 里只返回 A1 与 A1000000 两个键；`CalcEngine.buildGraph()` 是 public API（`CalcEngine.cj:281`），外部若拿它做增量重算，中间任意格变更都不会触发该公式重算 —— 静默得到旧值。
- **建议**：命中截断时把节点标记为“依赖不可枚举”（例如 `DependencyGraph` 维护 `coarse: HashSet<String>`，`order()` 与调用方对粗节点退化为全量重算），或改用“行列区间 + 区间重叠判定”表示；同时删掉注释里并不存在的“保守路径”表述。

### [一般][存量] #9 `ExcelWriter` 失败或未 `finish` 时没有任何释放路径，调用方也关不掉内部 ZipWriter

- **位置**：`f_excel/src/ExcelWriter.cj:138-143`（catch 里只 `entry.close()` 然后 `fail`）、`:148-161`（只有 `finish` 才 `zip.close()`）、`:172-176`（`fail` 只置标志并抛）；对照 `f_zip/src/ZipWriter.cj` 公共 API 只有 `close()`（无 `abort`/`discard`）
- **来源**：存量（`git blame -L 138,143` → `27c3f80d`）
- **判据**：review-checklist §11「资源不对称」、§3「失败路径静默」
- **证据**：静态确定 —— `fail` 之后 `ensureUsable` 让所有后续调用直接抛（`163-170`），`zip` 始终未 `close`，中央目录/EOCD 不写；`zip` 仍强引用 `output`（`ZipWriter.init` 保存 OutputStream）与已溢写的中间状态。类上没有 `close`/`abort`，`zip` 是 `private`，调用方除关闭自己的 `out` 外无法解除这条引用链，只能等 GC。
- **描述**：文档（类注释 22-27 行、README:346）说“失败即残缺，产物由调用方丢弃”，但没说“请自行 close(out)”。长驻进程里反复失败的导出任务会累积未关闭的 writer/溢写临时状态与输出流引用，表现为 fd 与堆缓慢增长；更糟的是调用方若复用同一个 `ByteBuffer`/`File`，会在未收尾的 ZIP 状态上继续写。
- **建议**：`fail` 前尽力 `try { zip.close() } catch (_: Exception) {}`（或给 `ZipWriter` 加 `abort()` 只释放资源不写目录）；`ExcelWriter` 增加 `close()` 供 `finally` 调用；README 明确失败路径的资源归属。

### [一般][存量] #10 `ExcelStreamReadOptions.loadRowHeight` 从未被读取，开关无效（README 有文档）

- **位置**：`f_excel/src/ExcelOptions.cj:44`（字段定义）；`f_excel/src/ExcelSheetStream.cj:314-326`（`streamOptions()` 逐项搬运但漏掉它）；承诺源 `f_excel/README.md:470`
- **来源**：存量（`git blame -L 42,46` → `148f06a7` 2026-10-30）
- **判据**：review-checklist §14.1「接线缺失：配置项被读取却从未使用」、§1「死配置字段」
- **证据**：静态确定 —— `grep -rn "loadRowHeight" --include=*.cj .`（排除 `.worktrees`）仅 `ExcelOptions.cj:44` 一处定义，无任何读取；`SheetRowHandler` 的 `ExcelReadOptions` 结构里也没有对应字段。
- **描述**：用户按 README 设 `loadRowHeight = false` 以为能省掉行高解析，实际 `RowData.height` 照旧解析填充；这是“配置看起来生效、实际静默无效”，也会让性能调优结论失真。
- **建议**：把字段搬进 `ExcelReadOptions`（或给 `SheetRowHandler` 加独立开关）并在 `<row ht=…>` 分支判断；短期内若不做，删字段并同步 README。

### [轻微][存量] #11 死代码 4 处 + 1 个未使用 import

- **位置**：
  - `f_excel/src/FunctionRegistry.cj:514-516` `scalarsOf`（`internal`，全仓仅定义处）
  - `f_excel/src/Image.cj:39-44` `ImageFormat.contentType()`（`internal`，全仓仅定义处；`PackageWriter` 里另有按扩展名的 content-type 表）
  - `f_excel/src/ExcelSheetStream.cj:125,145` `spoolFile`（只赋值、从不读取，且传入的是已 `close()` 的 `File`；真正的清理用的是 `spoolDir` 那个“文件路径”字段）
  - `f_excel/src/WorksheetParser.cj:54` `RowSink.merged` + `f_excel/src/ExcelSheetStream.cj:33-34` `RowCapture.merged`（空实现）：全仓无 `.merged(` 调用点，合并区域实际经 `ParsedSheet.merges` 传递
  - `f_excel/src/ExcelSheetStream.cj:20` `import std.fs.{… OpenMode …}`，文件内未使用 `OpenMode`
- **来源**：存量（快照模式无基线；`grep` 结果见上，全部仅命中定义处）
- **判据**：review-checklist §1（`private`/`internal` 按无调用者判；`public` 成员所在类型是 `internal` 时按全项目无使用判）/ §3（空实现）
- **证据**：静态确定 —— `scalarsOf` 全仓 1 处、`contentType()` 全仓 1 处（`f_email` 的同名方法是无关类型）、`spoolFile` 2 处赋值 0 处读取、`RowSink.merged` 0 处调用。
- **描述**：`spoolFile` 最危险：它让人误以为 spool 生命周期由该字段管理，实际是死字段（真正的路径存在 `spoolDir`，命名还相反）。`RowCapture.merged` 的空实现让“流式合并区域”看起来已接线，实际永远不会被回调。
- **建议**：删除这 4 个符号与 import；若 `merged` 是给未来流式合并预留的钩子，加 `// 预留：合并区域目前只经 ParsedSheet 传递` 并至少留一处测试引用，避免长期悬空。

### [轻微][存量] #12 重复逻辑：同名工具两套实现、引号扫描 4 份、枚举相等 3 种写法

- **位置**：
  - `f_excel/src/FormulaShift.cj:168-176` `runesText` 与 `f_excel/src/FormulaLexer.cj:293-301` `runesToString` **逐行相同**（Rune 切片 → `StringGenerator` 拼接）
  - `f_excel/src/Image.cj:25-30` `toString()` 与 `:32-37` `extension()`：两个 case 输出完全一致（`Png→"png"`、`Jpeg→"jpeg"`）
  - 引号扫描循环 4 份：`FormulaLexer.cj:182-205`（字符串）、`:206-229`（表名）、`FormulaShift.cj:49-66`（字符串原文复制）、`:67-84`（表名原文复制）—— 都是“读到未成对的引号为止、`""`/`''` 视为转义”，差异只在“反转义后收进 token”与“原样复制”
  - 枚举相等 3 种写法：`ExcelException.cj:62-93`（23 个 case 手写 `match` + `_ => false`）、`FormulaLexer.cj:39-82`（15 个 case 手写）、`FormulaAst.cj:64-74`（`UnaryOp` 手写）；而 `FormulaAst.cj:34-40`（`BinaryOp`）用 `this.toString() == that.toString()`
- **来源**：存量（`git blame` 对应行分别落在 `ed6ecc68` / `793bc0e8` / `27c3f80d`）
- **判据**：review-checklist §2（只改类型名/换控制流的同语义实现、字面量复制）
- **证据**：静态确定 —— `runesText`/`runesToString` 函数体逐行一致；`extension()` 与 `toString()` 的 `match` 分支值一致。**行为漂移风险**：手写 `==` 的 `_ => false` 兜底使“新增一个枚举 case 后忘了同步”不会编译报错（`toString` 的 `match` 是穷尽的会报错），此时 `x == x` 静默为 `false`，`ExcelWarningKind` / `FTokKind` 上的 `match`/去重逻辑会集体失灵。
- **建议**：抽一个 `scanQuotedSegment(runes, i, quote) -> (end, unescaped?)` 供 4 处复用；`runesText` 合并为模块内一个 helper（放 `FormulaAst.cj` 或新建 `FormulaText.cj`）；`extension()` 直接用 `toString()`；三个手写 `==` 统一改成 `this.toString() == that.toString()`（与 `BinaryOp` 一致，单次 match、新增 case 自动正确）。

### [轻微][存量] #13 语法层把非法引用宽容成整列/整行引用，且行号会截断小数

- **位置**：`f_excel/src/FormulaParser.cj:288-303`（`parseRef`：`RefPart.Column`/`RefPart.Row` 在**没有冒号**时也展开成 `A:A` / `1:1`）、`:179-193`（`Int64(token.number)` 截断）
- **来源**：存量（`git blame -L 154,162` 同批 `ed6ecc68`）
- **判据**：review-checklist §11「语义与注释不符」/ §11「边界」；注释 `:287` 写“支持整列 `A:A` / 整行 `1:1`”，而实现额外接受了裸 `A`
- **证据**：静态确定 —— 词法层把 `A` 判为 `Ident`、`parseRefPart("A")` 走 `columnIndex` 得到 1 返回 `RefPart.Column`，`parseRef` 见下一个 token 不是 `Colon` 仍返回 `RangeExpr(sheet, CellRef(1,1), CellRef(MAX_ROW,1))`；即 `=A` 求值为整列数组（Excel 给 `#NAME?`）。`=1.5:2` 因 `Int64(1.5) = 1` 被当成 `1:2`。
- **描述**：拼错的函数名/定义名（`A`、`AB`、`Q`）被静默当成整列引用并返回一个看似合理的数组/数字，比报错更难排查；小数行号同理。
- **建议**：整列/整行分支要求“两侧都出现”：只有见到 `Colon` 才进入 `RefPart.Column`/`Row` 组合；单侧裸字母/数字直接抛 `FormulaSyntaxException`。行号要求 `token.number == Float64(Int64(token.number))`。

### [轻微][存量] #14 三处注释与实现不符（选项默认值、残留措辞、自相矛盾的截断说明）

- **位置**：`f_excel/src/ExcelOptions.cj:66-70`（`/** use range；… */` 残留英文；`maxCellStyles` 写「Linux 64000，其他平台 8192（M2-a）」，但默认值就是 64000 且 `ExcelWriter.cj:110` 无任何平台分支）；`f_excel/src/FormulaAst.cj:130-136`（「区域只记录**边界**：`A1:B3` 记 6 个格子」——同一句里既说只记边界又说记 6 格）
- **来源**：存量（`git blame` → `148f06a7` / `ed6ecc68`）
- **判据**：review-checklist §10（可读性/可维护性：注释与代码不符）、§13「规格与实现漂移」（代码内注释口径）
- **证据**：静态确定 —— `grep -rn "maxCellStyles" f_excel/src/*.cj` 只有默认值 64000 与 `StylePool.getOrAdd` 的通用上限比较，无平台判断；`StylePool.cj:109-112` 的错误文案也按传入值提示。
- **描述**：平台差异是 MS Excel 自身的历史限制，不是本库行为，读注释的人会去找根本不存在的平台分支；`collectRefs` 的注释让“截断”与“展开”两种语义混在一起（与 #8 同源）。
- **建议**：改成「默认 64000（与 Excel 桌面版上限一致，其他平台由调用方自行下调）」；删 `use range`；`collectRefs` 注释改为“area ≤ 上限时逐格展开，否则只记左上/右下（见 `DependencyGraph` 的粗粒度处理）”。

### [轻微][存量] #15 `M3DistDb_test` 把 `INFO("system")` 断言成固定字符串 `"Linux"`，换平台必挂

- **位置**：`f_excel/src/M3DistDb_test.cj:115`（`@Assert(calc("=INFO(\"system\")").toString(), "Linux")`）
- **来源**：存量（`git blame -L 115,115` → 2026-10-31 批次）
- **判据**：review-checklist §11「测试与实现契约不符」/ 基线 §1「编译/测试在 WSL Ubuntu 里跑」——断言依赖运行平台，而不是被测语义
- **证据**：静态确定 —— 断言值是常量 `"Linux"`；`INFO("system")` 的返回值按平台变化（Windows/macOS 上不同），在 Windows 侧或跨平台 CI 上会失败，且失败原因与业务无关。
- **描述**：这是一条环境绑定测试，会掩盖真实回归（只要平台变，红点与被测功能无关）。
- **建议**：改成断言“非空且属于已知集合”，或改用 `INFO("release")`/`INFO("numfile")` 这类平台无关项。

### [轻微][存量] #16 「350 个函数」用 7 个名字数组 + 魔法数 4 拼出来，新增函数不会被发现

- **位置**：`f_excel/src/M3CellStore_test.cj:99-104`（`CORE + EXTENDED + STAT_TEXT + MATH_ENG + DYN_FIN + DIST_DB + 4`）
- **来源**：存量（`git blame -L 99,104` → 2026-10-31 批次）
- **判据**：review-checklist §14.1「版本/数量漂移」+ §11「测试与实现契约不符」
- **证据**：静态确定 —— 实测数组长度 62/81/62/51/37/53，和 = 346，加硬编码 `4`（`FILTER`/`SORT`/`UNIQUE`/`SEQUENCE`）得 350；断言只校验“名单加总”，`lookupFunction` 里新注册一个函数而没进任何名单时该用例仍然通过（`Function_test.cj:184` / `FunctionExt_test.cj:210` 只逐个验证 CORE 与 EXTENDED）。
- **描述**：这个数字是文档/README 里“支持 350 个函数”的依据，但没有任何用例真正清点 `lookupFunction` 的分支；数量漂移不可发现，`4` 也没有注释来源。
- **建议**：给 `lookupFunction` 提供 `registeredNames()`（表化后天然可得）并对它做 `size` 断言；或把 4 个动态数组函数并入常量名单，去掉魔法数。

<!-- 第 7 部分 -->

### [严重][存量] #1 公式缓存值不写 `c@t`，文本/布尔/错误结果被写成数字单元格

- **位置**：`f_excel/src/SheetXmlWriter.cj:165-175`（`case Formula` 只补了 `s`，不加 `t`）、`:252-272`（`writeCachedValue` 对 `Text`/`Boolean`/`Error` 只写 `<v>`，同样不加 `t`）
- **来源**：存量（`git blame -L 252,262` → `bc7aaa46b2` 2026-10-30）
- **判据**：review-checklist §11「契约与实现不符 / 语义与规格不符」、§10 正确性。OOXML `c@t` 缺省为 `n`；公式结果若是字符串须 `t="str"`、布尔 `t="b"`、错误 `t="e"`（ECMA-376 `ST_CellType`，§18.18.11）
- **证据**：静态确定 —— `writeCell` 只在 `Text`(`:129`)、`Boolean`(`:151`)、`Error`(`:159`) 三个分支往 `attrs` 追加 `t`；`Formula` 分支与 `writeCachedValue` 全程不追加。自有读侧可佐证后果链：`f_excel/src/WorksheetParser.cj:421-425` 用 `plainValue()` 按 `cellType` 解析缓存，`t` 缺失时走 `numericValue`（`:524`），非数字串落到 `:535-543` —— 记一条 `NumberParseFailed` 并降级成 `Text`；缓存布尔 `"1"` 则变成 `Number(1.0)`。
- **描述**：`CellValue.Formula("A1&\"x\"", Some(CellValue.Text("abc")))` 写出的是 `<c r="A1"><f>A1&amp;"x"</f><v>abc</v></c>`。Excel 按 `n` 解析该 `<v>`，会判"内容有问题/需要修复"或显示 0；缓存布尔退化成 1/0 的数字（看似一致但类型丢失）；缓存错误（见 #3，`#SPILL!`）则写出非法数值。`RoundTrip_test.cj:43` 只覆盖了 `Some(Number(...))` 这一种缓存，所以测试全绿。
- **建议**：在 `case Formula` 里按缓存值类型补类型属性：`Number` 不加、`Text` → `t="str"`、`Boolean` → `t="b"`、`Error` → `t="e"`（`Date`/`TimeSpan` 先转序列号再按 `n`）；`writeCachedValue` 改为接收并由调用方传入已决定好的 `t`；补三条 round-trip 断言（文本/布尔/错误缓存）。

### [严重][存量] #2 `SharedStringIndex` 用字节级 `<si>` 扫描，自闭合 `<si/>` 或 CDATA 中的 `</si>` 会让全部索引错位

- **位置**：`f_excel/src/SharedStringIndex.cj:75-92`（`scan` 只匹配 `<si` 前缀 + 紧跟 `>`/空格/`/`）、`:94-105`（`findClose` 找字面 `</si>`）、消费点 `:125-149`、`:151-165`
- **来源**：存量（`git blame -L 75,90` → `71cfef6187` 2026-10-31）
- **判据**：review-checklist §11「边界 / 语义与结构不符」、§2「近似重复导致行为漂移」——同一件事（切分 `<si>`）有两份实现，语义不同
- **证据**：静态确定。
  1. `<si/>`：`scan` 的第三个条件 `bytes[i+3] == 47`（`/`）专门放行自闭合标签，但 `findClose` 找的是 `</si>`，于是会一路找到**后面某条** `<si>` 的结束标签；`offsets[0]` 因此跨两条记录，`i = end`（`:86`）又跳过第二条 → 从索引 1 起整体前移一位。
  2. `<si><t><![CDATA[a</si>b]]></t></si>`：`findClose` 命中 CDATA 里的字面 `</si>`，切片在 CDATA 中间截断，剩余字节被当成新记录继续扫。
  对照实现：`f_excel/src/SharedStringTable.cj:62-167` 走 `XmlPullParser`，自闭合标签会补 `EndElement`（`f_xml/src/ParserEngine.cj:325-327`），CDATA 走 `CData` 事件（`SharedStringTable.cj:159-164`），两种输入都能正确切分。即"全量表正确、索引表错位"。
- **描述**：`sharedStringsIndex = true`（README:61 宣传的能力）时，一旦 SST 里出现自闭合空串或含 `</si>` 字面量的 CDATA，第 1 条之后的单元格都会拿到相邻字符串 —— 静默错值，不抛异常、无告警。`SharedStringReuse_test.cj` 只测了 64 KB 长串，未覆盖这两类输入。
- **建议**：不要用字节串搜索切分 XML。可选：把 `<si>` 切分改到 `f_xml` 的 Lexer/PullParser 上（需要它暴露元素起止偏移），或至少在 `scan`/`findClose` 里做结构约束 —— 跳过 `/>` 自闭合、跳过 `<![CDATA[…]]>`、跳过 `<!-- -->`，并按同名标签成对匹配；补 `<si/>` 与 CDATA 两个用例（断言 `get(i)` 与全量表一致）。

### [一般][存量] #3 错误值白名单不含 `#SPILL!`/`#CALC!`，而引擎自己会产出这两种错误

- **位置**：`f_excel/src/SheetXmlWriter.cj:386-394`（`checkErrorCode` 的 7 个 `allowed` 值）；生产点 `f_excel/src/CalcEngine.cj:213`、`:228`（写回 `CellValue.Formula(source, Some(CellValue.Error("#SPILL!")))`）、`f_excel/src/CalcValue.cj:55-56`
- **来源**：存量（`git blame -L 386,392` → `bc7aaa46b2` 2026-10-30）
- **判据**：review-checklist §11「契约与实现不符」、§3「契约承诺但实现拒绝」；`f_excel` 公开类型 `CellValue.Error` 与引擎口径必须一致
- **证据**：静态确定 —— `allowed` 只有 `#NULL!/#DIV/0!/#VALUE!/#REF!/#NAME?/#NUM!/#N/A`；`#SPILL!`/`#CALC!` 在 `CalcValue.cj:55-56` 是正式枚举分支，引擎 `recalculate(writeBack: true)` 会把它们写进单元格。同一取值走两条路径结果还不同：`CellValue.Error("#SPILL!")` → `checkErrorCode` 抛 `ExcelException`；`Formula(_, Some(Error("#SPILL!")))` → `writeCachedValue`（`:266-269`）绕过校验，写出 `<v>#SPILL!</v>` 且无 `t="e"`（与 #1 同根）。
- **描述**：`CalcEngine.recalculate(writeBack: true)` 后直接 `doc.write(...)`，只要表里有一格数组溢出，整份写出失败（异常），或者写出一个 Excel 不认的"数字型错误值"。"引擎能算、写不出去"是公开流程上的断点。
- **建议**：白名单补 Excel 2013+ 全部错误码（`#SPILL!` `#CALC!` `#FIELD!` `#BLOCKED!` `#UNKNOWN!` `#CONNECT!` `#BUSY!` `#PYTHON!` `#GETTING_DATA`），或改成 `#` + 大写字母/数字 + `!` 的结构校验；`writeCachedValue` 的 `Error` 分支复用同一校验并补 `t="e"`。

### [一般][存量] #4 公开字段 `CellStyle.namedStyle` 写出侧完全不落盘，却参与样式去重

- **位置**：`f_excel/src/Style.cj:450`（字段）、`f_excel/src/StylePool.cj:102-120`（`styleKey` 含 `namedStyle`）、`StylePool.cj:208-303`（`cellStyles` 只写固定的 `Normal`，每个 `xf` 的 `xfId` 恒为 `"0"`，`:228`）；读侧 `f_excel/src/StylesLite.cj:183-187`、`:437`
- **来源**：存量（`git blame -L 448,452` → `87cdb4fa42` 2026-10-31）
- **判据**：review-checklist §14.1「接线缺失：字段被读/写却没有消费」、§11「契约与实现不符」。承诺源：`f_excel/README.md:265`（`public let namedStyle: ?String` 出现在 `CellStyle` 公开结构里）
- **证据**：静态确定 —— `grep -rn namedStyle f_excel/src` 只命中 `Style.cj` 的定义/传递/`toString` 与 `StylesLite.cj` 的读侧（`xfs[xfId].namedStyle = Some(name)`、`CellStyle(... namedStyle: xf.namedStyle)`），`StylesWriter` 里 0 处引用；`xf@xfId` 恒为 `"0"`，也没有为命名样式生成 `<cellStyle name=...>`。
- **描述**：两张方向的问题叠加：①读入带命名样式的文件（例如"货币""超链接"）再写出，名字全部丢失，`CellStyle.namedStyle` 永远回到 `None`；②用户 `setStyle(CellStyle(namedStyle: Some("货币")))` 静默无效；③`namedStyle` 仍进 `styleKey`，两个只差名字的样式会占两个内容完全相同的 `cellXfs`，更快撞上 64 000 上限（`StylePool.cj:109-115`）。
- **建议**：二选一 —— 实现 `<cellStyles>`/`<cellStyle name>` 与 `xf@xfId` 映射（按名字去重，`namedStyle` 有值时引用对应 `cellStyleXfs` 索引），或从公开结构与 README 删除该字段。过渡期至少把 `namedStyle` 从 `styleKey` 剔除，避免无意义样式膨胀。

### [一般][存量] #5 `styles.xml` 把 `<dxfs>` 写在 `<numFmts>`/`<fonts>` 之前，违反 CT_Stylesheet 元素顺序

- **位置**：`f_excel/src/StylePool.cj:135-164`（先写 `dxfs`）→ `:165-178`（再写 `numFmts`）→ `:180-206`（`fonts/fills/borders`）
- **来源**：存量（`git blame -L 135,140` → `c8f5812abd` 2026-10-31）
- **判据**：review-checklist §11「与规格冲突」；ECMA-376 §18.8.39 `CT_Stylesheet` 是 sequence：`numFmts → fonts → fills → borders → cellStyleXfs → cellXfs → cellStyles → dxfs → tableStyles → colors → extLst`
- **证据**：静态确定（顺序违规）—— 只要文档里存在 dxf（即条件格式带 `CfFormat`），输出就以 `<styleSheet><dxfs>` 开头；仓库自己的夹具 `f_excel/src/M4_test.cj:26-37` 恰恰是按 `fonts → fills → borders → cellStyleXfs → cellXfs → cellStyles → dxfs` 写的，说明作者知道正确顺序。Excel 对顺序的具体容忍度需实测，故按"一般"而非"严重"。
- **描述**：`M4_test.addProgrammaticRule`（`:162-185`）这类"写条件格式"的文档交给 Excel 打开，可能提示"发现内容有问题/已修复"，dxf 与样式在部分版本会被丢弃。现有用例测不出来：`M4_test.roundTripPreservesRules`（`:142-159`）走自有容错读侧（`StylesLite` 用 `root.child("dxfs")`，与顺序无关），`PackageBuffer_test.partsMatchPinnedBaseline`（`:189-204`）的固定夹具不含 dxf。
- **建议**：把 `dxfs` 段整体移到 `cellXfs`/`cellStyles` 之后（即 `:292` 之后、`cellStyles` 前后按 schema 排列）；同步更新 `PackageBuffer_test` 的 golden 字节与 `GOLDEN_STYLES_SIZE`；新增一个"含 dxf"的用例，用 `XmlParser` 取 `styleSheet` 子元素顺序断言。

### [一般][存量] #6 写出侧告警按单元格无界累积，没有去重也没有上限

- **位置**：`f_excel/src/SheetXmlWriter.cj:356-364`（`warnFormat`，每格一条）、`:425-433`（`stripControl`，每格最多一条）；持有者 `f_excel/src/ExcelWriter.cj:33,88-90`、`f_excel/src/ExcelDocument.cj:287-289`
- **来源**：存量（`git blame -L 356,363` / `-L 426,433` → `bc7aaa46b2` 2026-10-30）
- **判据**：review-checklist §5「无界容器」、§11
- **证据**：静态确定 —— 传进来的 `warnings` 是调用方长期持有的 `ArrayList`，只 `add` 从不裁剪、不按 `(kind, sheet)` 去重。单个 `ExcelWarning` 含插值后的 message + sheet 名（估算 100–200 B）。
- **描述**：10 万格日期没配日期格式 → 10 万条 `NumberFormatNotSupportedInM1`（≈10–20 MB 估算常驻）；大批含非法控制字符的清洗数据每格一条 `ControlCharStripped`，千万级单元格可到 GB 级。这属于"写脏数据"的正常路径，不是异常路径，且用户通常只想知道"有没有发生、发生了几次"。
- **建议**：按 `(kind, sheet)` 聚合首条 + 计数（与 part6 #6 的读侧同一修法），或设 10 000 条上限后只计数并补一条汇总告警；`warnFormat` 还可按 `(sheet, style 索引)` 去重。

### [一般][存量] #7 `SharedStringIndex` 错误处理不对称：解析失败静默变空值，UTF-8 失败直接抛非 `ExcelException`

- **位置**：`f_excel/src/SharedStringIndex.cj:125-149`（`sliceAt` 末尾 `String.fromUtf8` 在 try 之外）、`:151-165`（`parseItem` 把 `SharedStringTable.load` 的异常吞成 `None`）
- **来源**：存量（`git blame -L 125,149` → `71cfef6187` 2026-10-31 与 `af3ca77d8e` 2026-11-22 各占一半；`parseItem` 段 `71cfef6187`）
- **判据**：review-checklist §11「错误处理缺失或静默」、§10 正确性
- **证据**：静态确定 + 文档 —— `String.fromUtf8` 在入参不符合 UTF-8 序列规则时抛 `IllegalArgumentException`（`std/core/core_package_api/core_package_structs.md`「static func fromUtf8(Array\<UInt8>)」异常段），代码未捕获；同一函数里 XML 解析失败却被 `catch (_: Exception) { None }` 吞掉，随后 `WorksheetParser.plainValue` 把它当"索引越界"记 `SharedStringIndexOutOfRange` 并给 `Empty`。
- **描述**：同一条坏 SST 记录，两种坏法给出两种完全不同的行为：结构坏 → 单元格静默空（有告警但语义错位）；字节坏 → `IllegalArgumentException` 从 `RowReader.next()` 冒出，调用方按 `ExcelException` 捕获会漏。排障时无法判断"是文件坏了还是索引坏了"。
- **建议**：把 `sliceAt` 与 `parseItem` 收进同一个 try，统一策略（要么统一转 `ExcelException` 带上 si 索引，要么统一降级 `None` + 明确告警文案）；UTF-8 解码失败按替换字符处理而不是抛穿透。

### [轻微][存量] #8 `StylePool` 导入了 `HashMap` 但全文未使用

- **位置**：`f_excel/src/StylePool.cj:18`
- **来源**：存量（`git blame -L 18,18` → `87cdb4fa42` 2026-10-31）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `grep -n HashMap f_excel/src/StylePool.cj` 只命中该导入行；本文件去重全部用 `ArrayList` 线性扫。
- **描述**：无用导入，且与"这里本该用哈希表"的优化方向（见优化方案 [CPU]）对应，容易被读者误解为已做过 map 化。
- **建议**：删除；或在做优化方案 [CPU]-1 时真正用上。

### [轻微][存量] #9 五组复制粘贴型重复逻辑

- **位置**：
  1. `QName(local, uri: Some(NS_MAIN))` 三份同体：`f_excel/src/PackageWriter.cj:45-47`（`xl`）、`f_excel/src/SheetXmlWriter.cj:29-31`（`xl`）、`f_excel/src/StylePool.cj:464-466`（`styleEl`）
  2. `addUniqueFont` / `addUniqueFill` / `addUniqueBorder`：`StylePool.cj:318-327`、`:329-338`、`:340-349`（仅类型名不同，逐行对齐）
  3. `checkTextLength` / `checkFormulaLength`：`SheetXmlWriter.cj:366-374`、`:376-384`（仅上限与文案不同）
  4. MIME 字面量：`PackageWriter.cj:199-210` 硬编码 `image/png` / `image/jpeg`，而 `f_excel/src/Image.cj:39-43` 的 `ImageFormat.contentType()` 返回同样的值
  5. `<v>` 写出模板：`SheetXmlWriter.cj:144-149`、`:150-156`、`:157-164`、`:176-181`、`:182-187` 五处 `startElement(v)/text/endElement` 同构
- **来源**：存量（`git blame -L 45,47` → `bc7aaa46b2`；`:318-349` → `87cdb4fa42`）
- **判据**：review-checklist §2（只改类型名 / 字面量复制 / 换控制流）
- **证据**：静态确定（逐行比对函数体：输入-输出-副作用一致，差异仅在类型名或常量）。
- **描述**：三份 `QName` 助手任何一处改动（例如将来带前缀或换命名空间）都会漂移；`addUnique*` 三份未来加字段时极易漏改其中一份；MIME 已有枚举方法却复制字面量，改一处忘一处就会让 `[Content_Types].xml` 与扩展名不一致（这类不一致直接导致 Excel 打不开图片）。附带：`ImageFormat.contentType()` 全仓 0 引用（范围外提示：`Image.cj` 不在本部分文件清单内，其死代码状态由对应子轮确认）。
- **建议**：抽一个模块内 `xmlNames.cj`（`mainNs(local)` / `pkgRel(local)`），`PackageWriter`/`SheetXmlWriter`/`StylePool` 共用；`addUnique*` 用一个泛型去重器或直接建 `HashMap<String, Int64>`；长度校验参数化 `(value, limit, label)`；MIME 改用 `format.contentType()`；`<v>` 抽 `writeValueElement(text: String)`。

### [轻微][存量] #10 `writeCachedValue` 的 `case _ => ()` 静默丢弃日期/时长/嵌套公式缓存值

- **位置**：`f_excel/src/SheetXmlWriter.cj:252-272`（`case _ => ()` 在 `:270`）
- **来源**：存量（`git blame -L 252,262` → `bc7aaa46b2` 2026-10-30）
- **判据**：review-checklist §3「`case None/_ => ()` 当兜底把值吃掉」
- **证据**：静态确定 —— 只处理 `Number/Text/Boolean/Error` 四类，`Date`/`TimeSpan`/`Formula`/`Empty` 一律不写 `<v>`。
- **描述**：`Formula(src, Some(Date(...)))` 写出后 `<c>` 只有 `<f>`，读回 `cached = None`（`WorksheetParser.cj:421-422`），`CalcEngine` 会当作未算缓存；`Empty` 缓存连空 `<v/>` 都没有，与"缓存值明确为空"无法区分。不是崩溃，但属于静默降级。
- **建议**：`Date`/`TimeSpan` 转序列号写 `<v>`（复用 `serialFromDateTime` / `toSeconds()/86400`），`Empty` 写空 `<v/>`，`Formula` 嵌套缓存显式忽略并留注释说明原因。

### [轻微][存量] #11 `apply*` 标志判据不覆盖全部字段，`indexOf` 缺键静默回退 0

- **位置**：`f_excel/src/StylePool.cj:235-243`（`applyFont` 漏 `scheme`/`family`/`charset`；`applyBorder` 漏 `diagonal`）、`:309-316`（`indexOf` 未命中返回 `0`）
- **来源**：存量（`git blame -L 235,246` → `87cdb4fa42` 2026-10-31）
- **判据**：review-checklist §11「语义与字段不符」、§3「静默兜底」
- **证据**：静态确定 —— 只要 `Font` 只改了 `scheme`（如 `Some("minor")`）或 `family`，`fontId` 会指向非 0 字体但 `xf` 没有 `applyFont="1"`；只有 `diagonal` 的边框同理没有 `applyBorder="1"`（`:240-243` 只看四边）。`indexOf`（`:225-227` 调用）内部找不到键时返回 0，把"表内不一致"变成"默认字体/填充/边框"。
- **描述**：用户设置的字体主题/字族、斜线边框写出后 Excel 不套用（视觉静默丢失）；`indexOf` 的 0 兜底让潜在的样式表 bug 变成错误样式而不是异常，排查成本高。
- **建议**：`apply*` 判据换成"与 `fonts[0]`/`fills[0]`/`borders[0]` 的键逐字比较不相等"；`indexOf` 返回 `?Int64`，缺键抛 `ExcelException`（构造上应恒命中，抛错即暴露内部 bug）。

### [轻微][存量] #12 样式去重键依赖 `toString` + 空串/占位符拼接，存在键碰撞

- **位置**：`f_excel/src/Style.cj:246-247`（`Font.toString` 用 `?? "-"` 表示缺失）、`:496`（`CellStyle.toString` 用 `?? ""`）、`f_excel/src/StylePool.cj:54`（`"${format.fill ?? ""}|${format.fontColor ?? ""}|..."`）
- **来源**：存量（`git blame -L 241,248` / `-L 501,503` → `87cdb4fa42`；`StylePool.cj:54` → 同批）
- **判据**：review-checklist §11「语义与命名不符」、§2「近似重复导致行为漂移」
- **证据**：静态确定 —— `Font(name: None)` 与 `Font(name: Some("-"))` 的 `toString` 完全相同；`CellStyle(namedStyle: None)` 与 `Some("")` 相同；`CfFormat(fill: None)` 与 `Some("")` 相同。`styleKey` 就是 `style.toString()`（`Style.cj:501-503`），`getOrAdd` / `getOrAddDxf` 因此把两种不同样式判成同一种。
- **描述**：命中时用户看到的是"样式设置不生效"且没有任何提示；概率取决于数据里是否出现 `"-"` 字体名或空串颜色，但一旦命中极难定位。更普遍的风险是：任何将来给 `toString` 增加/省略字段都会悄悄改变去重语义。
- **建议**：去重键改成结构化表示（为 `CellStyle`/`CfFormat` 实现 `Equatable` 并用 `HashMap`），或对每个字段做长度前缀拼接（`"${f.size}:${f.value}"`），彻底不依赖 `toString` 与空串占位。

<!-- 第 8 部分 -->

### [严重][存量] `valuesOfRange` 按 sqref 矩形全量物化，无任何面积上限，文件内容可直接决定几十 GB 分配

- **位置**：`f_excel/src/Worksheet.cj:243-268`（`valuesOfRange`），调用点 `:202`；同一根因另一处 `f_excel/src/Worksheet.cj:327-348`（`range()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）、§6.4（只判存在却全量扫描）
- **证据**：静态确定 —— 双层 `while (row <= to.row) / while (col <= to.col)` 把区域每个坐标都 `values.add(cellValueToCalc(...))`；`sqref` 直接来自 worksheet XML（`WorksheetParser.cj:211` `cfSqref = attr(attrs, "sqref")`，`:276-278` 原样存进 `ConditionalFormat`），`CellRef.parseRange` 只校验行列 ≤ `EXCEL_MAX_ROW/COL`（`CellRef.cj:137-139`、`:170-172`），**不限制面积**；`ExcelReadOptions.maxRows/maxCols` 只截断单元格解析（`WorksheetParser.cj:324`、`:381`），对该区域收集完全不生效。
- **描述**：`matchedRules(row,col)`（`:198-202`）在"该格落在 sqref 内"时，对**每个命中组、每次查询**都重建一次整区 `ArrayList<CalcValue>`。量化：`sqref="A1:A1048576"`（整列，Excel 允许且常见）→ 1,048,576 ×（`CalcValue` 枚举 ≥16 B）≈ 16 MB/次调用；`sqref="A1:XFD1048576"`（整表）→ 17.18e9 格 × ≥16 B ≈ 275 GB，必然 OOM。一个几百字节的 xlsx 就能触发；渲染侧逐格调用 `matchedRules` 时，百万行表 = 百万次 16 MB 分配，等价于把整个列复制一百万遍。没有上限配置、没有告警、没有异常，唯一的"拒绝路径"是进程被 OOM kill。`range(from,to)` 同构（公共 API，调用方给整表区域即同样爆），只是规模由调用方显式给定。
- **建议**：① 给区域收集加显式面积上限（新配置项，超限跳过并记一条 summary 级告警，不要逐格报警）；② 结构性修法：`Top10`/`Duplicate`/`ColorScale`/`DataBar`/`IconSet` 只需要单趟聚合（min/max/计数/前 N/去重集），不要物化整区；③ 把 `cfThreshold` 的"复制整区 + 插入排序"改成一次预扫描 + 有界选择（第 5 部分已把该 CPU 面列为优化方案，本条只报无上限导致的 OOM 面）。

### [一般][存量] 流式通道 `maxRows` 永不生效：判据用 `parsed.rows.size`，sink 通道从不写该列表

- **位置**：`f_excel/src/WorksheetParser.cj:324`（判定）、`:633-636`（sink 分支不累加 `parsed.rows`）；触发侧 `f_excel/src/ExcelSheetStream.cj:301-309`（`sink = capture`）、`:323`（把 `options.maxRows` 转进 `ExcelReadOptions`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§14.1（配置项接线缺失）
- **证据**：静态确定 —— `skipRow` 的唯一来源是 `Int64(parsed.rows.size) >= options.maxRows`；`finishRow` 在 `sink` 非 `None` 时只调 `s.row(data)`，`parsed.rows` 全程为空，判定恒假，`MaxRowsTruncated` 告警也永不产生。承诺源：`f_excel/doc/f_excel模块设计.md:1119`（2.7.5 流式行产出语义表「超出 `maxRows` / `maxCols` → 截断并记 warning，流正常结束」）、`README.md:476-477`；单测只覆盖整文档通道（`WorksheetParser_test.cj:195-201`），`StreamRead_test.cj` 无 `maxRows` 用例（全仓 `grep maxRows` 仅定义/赋值/整文档测试命中）。
- **描述**：调用方在流式读里设 `maxRows = 1000` 读一张 100 万行的表，会安静地拿到 100 万行 —— 既不截断也不告警。上限的本意是"防止消费端被大表拖垮"，失效后风险全部转移到调用方，且没有任何可观测信号。
- **建议**：`SheetRowHandler` 增加 `emittedRows` 计数，`finishRow` 里对两个通道统一判断（"已产出行数"而非"已存在列表长度"）；到上限后置 `skipRow`、记一次 `MaxRowsTruncated`。补一条 `StreamRead_test` 用例（3 行 + `maxRows = 1`）。

### [一般][存量] 流式通道把每格富文本累积到 `ParsedSheet`，与「内存与行数无关」的契约相反

- **位置**：`f_excel/src/WorksheetParser.cj:406-415`（`parsed.richTexts.add(...)`）；消费侧 `f_excel/src/ExcelSheetStream.cj:328-333`（`absorb` 只搬 `warnings`/`merges`）；契约 `f_excel/src/ExcelSheetStream.cj:112`
- **来源**：存量
- **判据**：review-checklist §5（无界容器）、§11（契约与实现不符）
- **证据**：静态确定 —— `finishCell` 无条件把 `(rowIndex, col, RichText(runs))` 存到 `ParsedSheet.richTexts`，`sink` 分支（流式）也照存；`RowReader` 只把 `capture.latest` 的 `RowData` 交出去，`RowData` 不带富文本（`RowData.cj:47-67`），`absorb` 只取 `warnings`/`merges`，因此流式通道里 `parsed.richTexts` **全程无人读取**。`ExcelSheetStream` 类注释写「逐行拉取，内存与行数无关」（`:112`）。
- **描述**：量化：100 万行、每行 1 个 `t="s"` 富文本格 → 100 万个 `(Int64, Int64, RichText)` 元组（≥24 B/个）+ `ArrayList` 扩容，几十 MB 常驻到该 sheet 结束，且随行数线性增长。富文本表（常见于带样式的报表）流式读会退化成"按行数增长内存"，恰好违背使用流式的唯一理由。
- **建议**：`finishCell` 只在整文档通道记录：

  ```cangjie
  if (cellType == Some("s") && this.sink.isNone()) { ... richTexts.add ... }
  ```

  若流式也必须暴露富文本，则把它挂到 `RowData`（需扩模型，代价大，需单独设计）。

### [一般][存量] `RowData.cells` 不保证 `col` 升序 / 不唯一，流式读→写会原样产出乱序 `<c>`

- **位置**：`f_excel/src/WorksheetParser.cj:396-416`（`finishCell` 按 XML 出现顺序 `cells.add`）、`:623`（`RowData(rowIndex, cells.toArray(), ...)` 直接产出）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符 / 语义与注释不符）
- **证据**：静态确定 —— `RowData.cj:21` 明确「`cells` 在 `RowData` 里必须按 `col` 严格升序，且只含实际出现的单元格」；`f_excel/doc/f_excel模块设计.md:1112` 同样写「`RowData.index = 5`，`cells` 按 `col` 升序」。`finishRow` 没有排序、没有重复列去重、没有"本列必须大于上一列"的校验；`SheetXmlWriter.row`（`SheetXmlWriter.cj:82-84`）按数组顺序逐格写。整文档通道不受影响（`CellStore.addNumber/addOther` 用 `lowerBound` 插入，天然有序），所以同一份文件两条通道的产出不同。
- **描述**：源文件列乱序（手工编辑、非 Excel 生成器）时，`RowReader` → `ExcelWriter.writeSheet` 的流式转存会把乱序 `<c>` 原样写回，产出不满足 CT_Row 顺序的 sheet XML；同一 `<c r="A1">` 出现两次时两格都会写出。读侧"宽容"（`f_excel模块设计.md:1120` 只要求行号乱序照原样产出）不等于允许破坏 `cells` 升序契约。
- **建议**：`finishRow` 里对 `cells` 按 `col` 做稳定排序并合并重复列（保留首个或末个，需在文档定语义），乱序/重复时记一条新告警（如 `CellOrderViolation`，不要复用 `RowOrderViolation` 以免混淆行/列）。

### [一般][存量] `stopIfTrue` 与 `priority` 只在单个 `conditionalFormatting` 组内生效，跨组不抑制

- **位置**：`f_excel/src/Worksheet.cj:198-239`（组内排序 `:203-215`；`break` `:233-235`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误）
- **证据**：静态确定 —— 命中且 `rule.stopIfTrue` 时执行 `break`，只跳出内层 `for (rule in sorted)`；外层 `for (format in this.conditionalFormatsList)` 继续处理下一个 sqref 组并把结果追加进 `result`。Excel/OOXML 语义是 `stopIfTrue=1` 后该单元格不再评估任何更低优先级规则（跨 sqref）。`priority` 也只有组内插入排序，组间按文件出现顺序，因此返回列表顺序 ≠ Excel 实际应用顺序。
- **描述**：常见的"整列颜色刻度 + 局部 `cellIs` 高亮"组合里，`cellIs` 命中并不阻止前面/后面组继续加 `CfMatch`；调用方若取 `result[0]` 上色，遇到组顺序与 priority 不一致时会选错格式。
- **建议**：把所有组的规则拍平成 `(priority, groupSeq, rule)` 后一次性稳定排序遍历，`stopIfTrue` 用整轮 `break`；若有意只做组内语义，则改注释并在 README 写明与 Excel 的差异。

### [一般][存量] 多段 `sqref` 时表达式规则的相对引用平移恒为 0，非首段格子按错位公式求值

- **位置**：`f_excel/src/Worksheet.cj:216-228`（`CellRef.parseRange(format.range)` 两处求 delta）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 静默错误）
- **证据**：静态确定 —— `sqref` 允许空格分隔多段（`sqrefContains` `ConditionalFormat.cj:312-327` 与 `valuesOfRange` `Worksheet.cj:245` 都按空格切分）；但 `CellRef.parseRange("B2:B9 F2:F9")` 因出现第二个 `:` 直接返回 `None`（`CellRef.cj:147-154`），`match` 落到 `case None => 0`，`deltaRow`/`deltaCol` 都是 0，`shiftFormula` 不平移。
- **描述**：`sqref="B2:B9 F2:F9"` 且规则公式为 `=$A2>5` 时，F 列格子应取 `$A2`（相对列偏移 0、行偏移按 F 区行号），实现取的是 `$A2` 但行偏移也为 0，等于每格都按首行求值。结果只影响 `CalcEngine.matchedRules` 注入求值器的路径（`CalcEngine.cj:255`），公共 `Worksheet.matchedRules` 不评估 `expression`（第 3 部分 #7 已记），因此静默。
- **建议**：先按空格切段找出"包含当前格"的那一段，用该段左上角算 delta；把 `sqref` 切分抽成 `parseSqref(sqref) -> Array<(CellRef, CellRef)>`，供 `sqrefContains` / `valuesOfRange` / 平移三处共用（同时解掉下文重复逻辑第 3 组）。

### [一般][存量] `ensureLoaded` 先清 `loader` 再执行 `load()`：加载抛异常后 sheet 永久停在半成品状态

- **位置**：`f_excel/src/Worksheet.cj:55-62`（`:58` `this.loader = None`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 状态不一致）、§3（静默吞掉失败）
- **证据**：静态确定 —— `load()` 由 `ExcelDocument.cj:197` 注入，最终走 `LazySheetSource.loadInto` → `parseAndFill`（`ExcelDocument.cj:344-399`），该路径会抛（sheet XML 解析失败、`setCell` 越界 `ExcelException` 等）。异常抛出后 `loader` 已为 `None`，后续 `cell()` / `rowCount()` 不再重试，也不报错，直接返回已灌入的部分数据。
- **描述**：`loader = None` 的动机显然是防重入（`load()` 内部会调 `setCell` → `ensureLoaded`），但把"防重入"和"已加载"压成同一个字段，代价是失败不可重试、不可观测。调用方 catch 住第一次异常后继续用同一 `ExcelDocument`，拿到的是静默残缺的工作表（例如只灌了前几行）。
- **建议**：引入显式状态（`NotLoaded / Loading / Loaded / Failed`）：`Loading` 时直接返回（防重入），成功置 `Loaded`、失败置 `Failed`；`Failed` 时在每次访问重新抛同一个异常（或缓存首个异常），至少保证"错一次不会变成静默成功"。

### [一般][存量] `conditionalFormats()` / `mergedRanges()` 直接返回内部可变列表，公开 getter 可绕过模型不变量

- **位置**：`f_excel/src/Worksheet.cj:156-159`（`conditionalFormats`）、`:395-398`（`mergedRanges`）、`:390-393`（`sheetImages`，internal）
- **来源**：存量
- **判据**：review-checklist §10（设计 / 封装）、§11（契约与实现不符）
- **证据**：静态确定 —— 三个函数都 `return this.<ArrayList>`（引用共享，不拷贝）。模型不变量只在写入口维护：`addConditionalFormat` 校验 `CellRef.parseRange`（`:164-167`）、`merge` 校验两两不重叠（`:435-447`）。调用方 `sheet.conditionalFormats().add(ConditionalFormat("bad range", rules))` 或 `mergedRanges().add("X")` 直接绕过校验，随后 `matchedRules` 的 `sqrefContains` 会静默忽略非法段，写侧 `SheetXmlWriter` 则会把非法区域写进 `<mergeCells>`（Excel 打不开或报修复）。
- **描述**：这是"getter 把内部容器交出去"的典型封装泄漏；`SheetImage` 列表同样可被包内代码改写，只是不对外。对外两个 getter 是 public API，破坏面覆盖所有下游。
- **建议**：返回浅拷贝（`ArrayList<ConditionalFormat>(this.conditionalFormatsList)`）或只读视图；确实需要零拷贝的内部路径另开 `internal func ...View()` 并在注释声明"只读，不得修改"。

### [一般][存量] `parseFont` 从 `<font>` 的属性读 `family` / `charset`，实际是子元素，读回恒为默认值

- **位置**：`f_excel/src/StylesLite.cj:306-307`（`parseIntAttr(item, "family", 2)`、`parseIntAttr(item, "charset", 0)`）
- **来源**：存量
- **判据**：review-checklist §11（语义与格式不符）、§13 相邻（读写不一致）
- **证据**：静态确定 —— 本仓写侧把两者写成子元素：`StylePool.cj:373-377` 生成 `<family val="N"/>`、`<charset val="N"/>`；ECMA-376 `CT_Font` 中 `family`、`charset` 也是带 `val` 的子元素，不是 `<font>` 的属性。`parseIntAttr`（`StylesLite.cj:247-252`）取不到属性就返回 fallback，于是 `Font.family` 恒 2、`charset` 恒 0。
- **描述**：本库自己写出的文件再读回也丢这两个字段（写侧只有在 `family != 0` 时才写，读侧永远拿不到），第三方文件同样。`Style_test.cj:71-88` 的 `fullStyleRoundTrip` 只断言 name/size/bold/italic/underline/fill/border/alignment/numberFormat/color，没有断言 family/charset，所以回归测试没暴露。
- **建议**：新增 `parseChildInt(item, "family", 2)`（读 `item.child("family")` 的 `val`），替换现有两处；在 `fullStyleRoundTrip` 补 `family`/`charset` 断言。

### [一般][存量] `namedStyle` 把 `cellStyles/@xfId` 当作 `cellXfs` 下标，命名样式会挂到错误的 xf

- **位置**：`f_excel/src/StylesLite.cj:132-144`（`named.add(xfId, name)`）、`:183-187`（`xfs[xfId].namedStyle = Some(name)`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `cellStyle/@xfId` 指向 **cellStyleXfs** 的下标，而 `cellXfs` 里的 `<xf>` 另有自己的 `xfId` 属性指回 cellStyleXfs。代码把 `cellStyles` 的 `xfId` 直接当 `cellXfs` 的下标挂名字，只有 `xfId` 恰好等于 `cellXfs` 下标时才正确。正确映射应是：遍历 `cellXfs`，`xf.xfId == 某 cellStyle.xfId` 才挂该名字。
- **描述**：多命名样式的工作簿（Excel 默认就有 Normal/Good/Bad 等，实测常见 5-10 条 `cellStyles`）里，命名样式被挂到编号相同的 `xf` 上；`cellXfs` 数量少于 `cellStyles` 时多出的名字被丢弃。`CellStyle.namedStyle` 是 public 字段，下游"按命名样式判语义"会拿到错值。写侧同名问题（`namedStyle` 完全不落盘）见第 7 部分 #4，两者合起来等于该字段全链路不可用。
- **建议**：改成

  ```cangjie
  for (i in 0..xfs.size) {
      if (let Some(name) <- named.get(xfs[i].xfId)) { xfs[i].namedStyle = Some(name) }
  }
  ```

  并补一条"两个命名样式指向不同 xfId"的读回用例。

### [一般][存量] 解析器只按 `name.local` 匹配、无祖先栈，`<extLst>` 里的 `x14:*` 同名元素会被当成标准元素

- **位置**：`f_excel/src/WorksheetParser.cj:170-178`（`StartElement(name, attrs, _) => onStart(name.local, attrs)`）、`:189-260`（`onStart` 的 case 列表）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 解析健壮性）
- **证据**：待确认 —— 匹配逻辑本身是静态确定的：没有元素栈、没有命名空间判断，文档里任何局部名为 `conditionalFormatting` / `cfRule` / `dataBar` / `iconSet` / `colorScale` / `cfvo` / `color` 的元素都会进入条件格式状态机（`parsed.merges` 的 `mergeCell`、单元格的 `c` / `f` / `v` 同理）。待确认的是真实文件的放大程度：Excel 2010+ 为数据条/图标集在 `<extLst>` 写一份 `x14:conditionalFormattings`（含 `x14:cfRule`、`x14:dataBar`、`x14:cfvo`），局部名与标准元素相同。
- **描述**：若上述扩展存在，`</x14:conditionalFormatting>` 会命中 `:276-280` 追加一个 `ConditionalFormat`（sqref 与标准规则相同），`addConditionalFormat` 按 range 合并后规则数翻倍；`matchedRules` 返回重复命中，写回时 `SheetXmlWriter.writeConditionalFormats` 会把同一规则写两遍。对"读→改→写"的使用者是可见的数据污染。
- **建议**：维护最小祖先路径（`sheetData` / `conditionalFormatting` / `extLst` 深度），只在标准位置响应；或直接用 `f_xml` 提供的命名空间 URI（`NS_MAIN`）过滤。补一个带 `<extLst><x14:conditionalFormattings>` 的夹具用例，确认是"应忽略"还是"应支持"。

### [轻微][存量] `bold` / `italic` / `strike` 只看元素存在，忽略 `val="0"`；`u/@val` 的 false 值被当成 Single

- **位置**：`f_excel/src/StylesLite.cj:301-304`、`:284-293`
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— `bold: item.child("b").isSome()`、`italic`、`strike` 同理；`CT_Boolean` 的 `val` 可为 `0`/`false`（显式关闭）。`u` 的 `match` 只识别 `double`/`singleAccounting`/`doubleAccounting`/`none`，`val="false"`/`val="0"` 落到 `case _ => Underline.Single`。
- **描述**：只在生成器显式写 `<b val="0"/>`、`<u val="false"/>` 的样式表上出错（Excel 自身通常省略元素），后果是字体被误判为粗斜体或下划线。属于"第三方文件保真度"问题，不影响本库自产文件。
- **建议**：加一个 `boolAttr(node, default: true)`：读 `val`，缺省 true，`0`/`false` 为 false；`u` 的 `val="false"|"0"` 归 `Underline.Off`。

### [轻微][存量] 死代码：`StylesLite.codeOf`、`Worksheet.setCellNumber`、`RowSink.merged`（跨部分重合）

- **位置**：`f_excel/src/StylesLite.cj:380-382`；`f_excel/src/Worksheet.cj:112-125`；`f_excel/src/WorksheetParser.cj:52-55`
- **来源**：存量
- **判据**：review-checklist §1（internal 符号在本包内无调用者；接口方法无调用点）
- **证据**：静态确定 ——
  - `codeOf`：`grep -rn "\bcodeOf\b" --include=*.cj .` 在 `f_excel` 内只有定义处；`fdbm` 的 `codeOf` 是另一包的私有 helper，与 `fountain::f_excel` 无关。
  - `setCellNumber`：`grep -rn setCellNumber` 全仓只有定义；注释写"内部/解析用"，但解析路径实际走 `setCell`（`ExcelDocument.cj:368`），所谓"数值快路径"没有任何入口。
  - `RowSink.merged`：全仓无 `.merged(` 调用点（`grep` 命中的是 `f_rule` 的无关方法）；实现 `RowCapture.merged`（`ExcelSheetStream.cj:33`）是空函数体。此条与第 6 部分 #11 同源，合并时保留一条即可。
- **建议**：删除 `codeOf` 与 `setCellNumber`（或把后者接进 `parseAndFill` 的纯数值行快路径并加测试）；`RowSink.merged` 要么在 `finishRow` 末尾对 `parsed.merges` 调一次，要么从接口、`RowCapture` 与设计文档同时删除。

### [轻微][存量] 重复逻辑 5 组（内联属性解析、区域规范化、sqref 遍历、SST 索引二次解析、图片空校验）

- **位置与证据**（静态确定）：
  1. `parseIntAttr`（`StylesLite.cj:247-252`）与 `cellXfs` 循环里 5 处内联写法（`StylesLite.cj:149-153`：`numFmtId`/`fontId`/`fillId`/`borderId`/`xfId`，形如 `parseIntOrNone(item.attr("numFmtId") ?? "0") ?? 0`）语义完全一致（属性缺失 → fallback；属性非法 → fallback），但 5 处没复用助手，且助手现在被用在了错误的 family/charset 上。
  2. 区域规范化 `"${parsed[0].toString()}:${parsed[1].toString()}"` 在 `Worksheet.cj:434`（`merge`）与 `:462`（`unmerge`）各写一遍，改一处容易漏另一处。
  3. `sqref` 按空格切分 + 逐段 `CellRef.parseRange` 的有两套：`Worksheet.cj:243-268`（收集值）与 `ConditionalFormat.cj:312-327`（命中测试），只是消费方式不同。
  4. 同一 `t="s"` 的索引文本解析两次：`WorksheetParser.cj:407`（`finishCell` 为取富文本）与 `:482`（`plainValue`）。
  5. 图片空数据校验两层：`Image.cj:77-79`（`"图片为空：${path}"`）与 `Worksheet.cj:379-381`（`"图片数据为空"`）；`addImage(path, ...)`（`:360-364`）必然连续走两遍，两条错误文案还不一致。
- **判据**：review-checklist §2
- **描述**：差异点只有错误文案与调用位置，没有语义差异可保留。（第 3/5 组另有行为影响：抽成 `parseSqref` 可顺带修掉上文的平移 bug。）
- **建议**：`parseIntAttr` 推广到 5 处；区域规范化抽 `canonicalRange(from, to)`；`parseSqref` 抽到 `CellRef.cj` 附近（`ConditionalFormat` 与 `Worksheet` 都依赖它，放在 `CellRef` 同级无分层问题）；`finishCell` 复用 `plainValue` 的解析结果（先算出 `index` 再传下去）；图片空校验只保留 `addImage(data,...)` 一层。

### [轻微][存量] 测试夹具 `fixtures.cj` 不是 `_test.cj`，会随动态库一起编译发布

- **位置**：`f_excel/src/fixtures.cj:21-136`（4 个 `NS_*` 常量 + `contentTypesXml`/`rootRelsXml`/`workbookXml`/`workbookRelsXml`/`stylesXml`/`worksheetXml`/`escapeXml`/`buildXlsx`）
- **来源**：存量
- **判据**：review-checklist §1（「仅测试使用」→ 可见性建议，**不算死代码**）
- **证据**：静态确定 —— `contentTypesXml` / `rootRelsXml` / `workbookXml` / `workbookRelsXml` / `escapeXml` 在 `src` 内除 `fixtures.cj` 自身外 0 命中；`buildXlsx` / `stylesXml` / `worksheetXml` / `NS_MAIN` 只被 `*_test.cj` 使用（`Date_test` / `Eager_test` / `ExcelDocument_test` / `ExcelWriter_test` / `Formula_test` / `M2d_test` / `WorksheetParser_test` 等）。
- **描述**：`src` 下的非 `_test.cj` 文件会进库编译，使用者拿到一整套永远用不到的 XLSX 夹具构建代码（含硬编码命名空间字符串与 4 MB `ByteBuffer` 预分配）。功能无害，但属于"测试代码进产物"。
- **建议**：改名 `Fixtures_test.cj`（`_test.cj` 不参与库编译），或按 cjpm 约定放到独立测试源目录；引用处无需改动（同包）。

### [轻微][存量] 测试代码问题：未用 import、类名与文件不符、格式、关键字段无断言

- **位置**：`f_excel/src/WorksheetParser_test.cj:18`（`import std.collection.ArrayList` 全文未使用）、`:23`（类名 `SharedStringTable_test` 放在 `WorksheetParser_test.cj`）、`:111`（`public func sharedStringLookup(): Unit {        let table = ...` 两条语句挤在一行）；`f_excel/src/Style_test.cj:71-88`（round-trip 未断言 family/charset）
- **来源**：存量
- **判据**：review-checklist §1（未使用 import）、§10（可维护性）、§11 相邻（测试掩盖缺陷）
- **证据**：静态确定 —— `grep -n ArrayList WorksheetParser_test.cj` 仅 import 一行；`grep -rn "maxCols" f_excel/src` 只有 `ExcelOptions.cj:30`、`:52`、`ExcelSheetStream.cj:324` 与 `WorksheetParser.cj:381`，**没有任何测试**（`maxCols` 截断逻辑完全无覆盖）；`Worksheet_test.cj` 未覆盖 `matchedRules` / `conditionalFormats` / `addImage` / 懒加载。
- **描述**：SST 的 5 个用例挂在 `WorksheetParser_test.cj` 里，按文件名找不到；`maxCols` 与条件格式求值都是本部分的高风险路径，却没有针对边界的用例（也正因如此 family/charset 丢失、`stopIfTrue` 跨组、多段 sqref 平移都没被发现）。
- **建议**：删未用 import；SST 用例拆到 `SharedStringTable_test.cj`；补 `maxCols` 截断、`stopIfTrue` 跨组、多段 sqref expression、family/charset round-trip 四类用例。

### [轻微][存量] `clearCell` 只删值，样式/富文本/最大行列计数都不回收，`rowCount()` 与"最大已用行号"不符

- **位置**：`f_excel/src/Worksheet.cj:310-316`
- **来源**：存量
- **判据**：review-checklist §11（状态清理不对称 / 语义与文档不符）
- **证据**：静态确定 —— 函数体只有 `cells.remove(row, col)`；`stylesMap` / `richTexts` 中该格条目保留，`maxRowSeen` / `maxColSeen` 不回退。`f_excel/doc/f_excel模块设计.md:290` 把 `rowCount()` 定义为「最大已用行号，0 表示空」，而 `setCell("A5")` + `clearCell("A5")` 之后 `rowCount()` 仍为 5、`styleOf(5,1)` 仍 `Some(...)`。样式是否应一起清属语义选择（Excel 有"清除内容/清除格式"两档），**待确认**本模块的 `clearCell` 对应哪一档。
- **描述**：清空唯一单元格后 sheet 实际为空但计数不复位，`<dimension>`/`rowCount` 类元信息与内容不一致；重复"写入大范围再清除"的编辑循环会让计数只增不减。
- **建议**：明确 `clearCell` 的语义（建议=Excel"清除内容"：只清值），把 `rowCount` 文档改成"历史最大写入行号"或在 `clearCell` 后按需重算（扫描 `CellStore` 末条）；若采用"清除内容"语义，另加 `clearStyle`/`clearAll` 并补测试。

### [轻微][存量] `loadStyles=false` 时流式通道静默关闭日期识别，没有 `AutoDetectDateDisabled` 告警

- **位置**：`f_excel/src/WorksheetParser.cj:549-551`（`if (!autoDetectDate || !loadStyles) return Number`）；对照 `f_excel/src/ExcelDocument.cj:129-135`（整文档通道记告警）
- **来源**：存量
- **判据**：review-checklist §11（两通道行为不一致）、§13 相邻（文档承诺）
- **证据**：静态确定 —— 整文档入口在 `loadStyles=false && autoDetectDate=true` 时记一条 `AutoDetectDateDisabled`（`ExcelDocument.cj:129-135`，`Date_test.cj:142` 有用例）；流式入口 `ExcelSheetStream.streamOptions()`（`:314-326`）只搬字段不记告警，`numberValue` 直接返回 `Number`。承诺源 `f_excel/doc/f_excel模块设计.md:485`（「不报错。自动把 `autoDetectDate` 降级为 false，并记一条 `ExcelWarning`」），该表挂在 `ExcelDocument` 章节下，**流式是否同样要求待确认**。
- **描述**：同一份文件走 `ExcelSheetStream` 时日期列全变裸数字、零告警；走 `ExcelDocument` 时有告警。使用者按 README 监听告警做降级提示会漏掉流式路径。
- **建议**：在 `ExcelSheetStream.build()` 里补同一条告警（只记一次），或在 `streamOptions()` 内统一处理；若确认流式不要求，则在文档里写明两通道差异。

> **与其它分部分的重合说明**（合并时请注意，本部分未重复计数）：
> ① 「每格告警无上限累积」已由第 6 部分 #6 报出，其量化已覆盖本部分 `WorksheetParser` 的 `SharedStringIndexOutOfRange` / `NumberParseFailed` / `UnknownCellType` 逐格 `warnings.add`；
> ② `RowSink.merged` 空实现与第 6 部分 #11 同源，本部分只在死代码条中列一次；
> ③ `ensureLoaded` 的**并发**风险（非原子、重复解析）已由第 5 部分报出，本部分只报**异常路径**（先清 loader 后 load）；
> ④ `matchedRules` 的 CPU 面（整区重建 + 排序）已由第 5 部分列为优化方案，本部分只报其**无上限导致的 OOM**；
> ⑤ `namedStyle` 写回不落盘、`Worksheet.matchedRules` 不评估 `expression`、写回不按 priority 排序，分别见第 7 部分 #4、第 3 部分 #7/#8。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分为文档，未提出性能/内存改造方案。文档中出现的性能结论（`README.md:523` 的 3 MB / 29 MB、设计 §9.3 的耗时预估）均无可复核基线，已移入「待验证假设」，不构成本轮方案。

<!-- 第 2 部分 -->

本部分 20 个文件全是规格文档，**没有可测量的代码路径，也没有 profile / bench 数据**，因此不产出
堆内存 / CPU 优化方案（按 `reviewer.md` 铁律，无基线的性能结论只能写进「待验证假设」）。
上面第 2 条发现的"告警数组随单元格增长"本质是无界容器缺陷（已进「发现」），其修复不依赖性能数据。

<!-- 第 3 部分 -->

本部分文件全部为 `doc/spec/**` 规格与验收文档，不含运行时代码，因此不产出堆内存 / CPU 优化方案（§7 / §8 记 0 条）。文档侧可执行的改进已并入上面各条「建议」。

<!-- 第 4 部分 -->

> 本部分没有 `cjprof` / `cjpm bench` 数据，以下均为"还能更好"的方案，**不进修复清单**。

### [堆内存] 区域按需读取：`ROWS`/`COLUMNS` 与 `SUMIFS` 不必物化整片区域

- **现状**：`rangeValue`（`Evaluator.cj:89-116`）把 `[from, to] ∩ usedBounds` 的每个格子都取出来塞进 `ArrayList<Array<CalcValue>>`。`fnRowsColumns`（`CalcFunctionsExt.cj:597-604`）只为取行列数就调用 `gridOf(ev.arg(args,0))`，一个 100 万行 × 1 列的区域会临时产生 100 万个 `CalcValue` + 100 万个单元素数组；`SUMIFS`（`CalcFunctionsMath.cj:260`）在循环里反复制造同样的对象图。
- **方案**：在 resolver 暴露"区域尺寸"查询（`usedBounds` 已有 → 由 `RangeExpr` 的 `from/to` 直接算 `min(to.row, maxRow) - from.row + 1`），`ROWS/COLUMNS` 走尺寸 API 不取格；`SUMIFS`/`COUNTIFS` 在进入循环前把每个条件区域物化一次并复用。
- **预期**：`ROWS`/`COLUMNS` 的临时对象从 O(格数) 降到 O(1)；`SUMIFS` 从 O(格数²) 降到 O(格数)。具体字节量需按实际 used range 测。
- **代价**：resolver 增加一个方法（`CalcResolver` 是 internal 接口，改动面小）；`SUMIFS` 需要多一份 `ArrayList` 持有各 test grid，峰值常驻略增（条件数 × 区域大小）。
- **验证**：同一 `xlsx` 跑 `recalculate` 10 轮，采 `getAllocatedHeapSize()` 峰值与 RSS，比对业务计数（重算格数）一致；对照改前基线。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 五处手写插入排序统一改为 `std.sort`

- **现状**：`sortedNumbers`（`Ext.cj:36-44`）、`fnLargeSmall`（`Ext.cj:130-138`）、`fnMedian`（`Math.cj:439-447`）、`fnSortBy`（`DynFin.cj:49-65`）都是 O(n²) 插入排序；`fnLargeSmall` 还会先做一次被丢弃的排序（`Ext.cj:107`）。以 1 万格估算约 5×10^7 次比较 × 2 趟。
- **方案**：`sortedNumbers` 用 `ArrayList<Float64>.sort()`（或 `std.sort.sort`）；`fnSortBy` 排索引数组 + 自定义比较器以保持稳定；`fnLargeSmall` 只在 `args[0..n-1]` 上排一次。
- **预期**：排序段从 O(n²) 降到 O(n log n)；`LARGE/SMALL` 去掉一趟完整排序。端到端收益取决于排序在公式耗时中的占比（未测）。
- **代价**：`fnSortBy` 需要把"行数组随 key 一起置换"改成"索引置换后重建"，多一层间接；需补等价性用例（稳定序、重复 key、空行）。
- **验证**：`cjpm bench -O2` 对 `MEDIAN`/`LARGE`/`SORTBY` 三组各 1k/10k/100k 输入对照，报中位数与离散程度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CalcEngine.evaluate` 每次重建 4 个 `ArrayList` + `HashMap` + `Evaluator`

- **现状**：`evaluate`（`CalcEngine.cj:117-122`）与 `recalculate`（`:142-146`）每次都 `new HashMap` 与 4 个空 `ArrayList`，并 `Evaluator(this.resolver)`。单格查询（如条件格式逐格 `matchedRules`）会放大成每格一次分配。
- **方案**：把 memo/集合改成实例字段复用 + `clear()`（注意 `clear()` 只清元素、不归还物理内存，见 `mem §3.2`，所以要有容量上限），`Evaluator` 用"重置 randomState/now"代替重建；`matchedRules` 的一次遍历内复用同一个 `Evaluator`。
- **预期**：单次求值减少 6 次容器分配；稳态下 GC 次数与分配速率下降（幅度需测）。
- **代价**：实例复用会让"并发安全"问题（#18）更严重，必须与"每次调用独立上下文"的重构一起做；`clear()` 保留容量会抬高常驻内存。
- **验证**：`cjprof heap` 对照 10 万次 `evaluate` 的分配量与 GC 次数；同时确认 `NOW()`/`RAND()` 在单次求值内的一致性未被破坏（设计 7.5.2）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

### [CPU] `matchedRules` 每格重算整区取值，阈值排序在每个规则、每个单元格上重复

- **现状**：`Worksheet.matchedRules(row, col)`（`Worksheet.cj:180-241`）对每个单元格 `valuesOfRange(format.range)`（`:202`）重建整区 `ArrayList<CalcValue>`；随后 `cfThreshold`（`CfEval.cj:247-288`）每次都把整区数值**复制一遍再用插入排序**（`:253-265`），`cfIconSet`（`:389-394`）还按阈值个数循环调用它。量级：1000 格区域、3 档图标集，单次 `matchedRules` 调用即 ~3000 次排序 × O(n²)。
- **方案**：把"区域数值排序结果 + 阈值"按 `(sqref, 规则集)` 缓存到一次 `matchedRules` 遍历的上层（`CalcEngine.matchedRules` 批量入口），或让 `cfThreshold` 接收"已排序数组 + 已算好的 min/max/percentile"，排序只做一次。
- **预期**：单格条件格式求值从 O(k·n²) 降到 O(k + n log n)；整区分摊后接近 O(1)。
- **代价**：需要一个"区域版本号/失效"机制（单元格被改写后缓存作废），否则会读到旧值。
- **验证**：`cjpm bench -O2`，输入 1000×10 区域 + 3 档 colorScale/iconSet，对比改前改后 `matchedRules` 全表遍历的中位耗时（多轮取中位数与离散度）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `UNIQUE` / `SORT` / `DependencyGraph.cycles` 的 O(n²) 结构

- **现状**：`fnUnique`（`DynamicArrays.cj:124-145`）用 `ArrayList.contains` 去重 + `rowKey` 循环 `+=` 拼串；`fnSort`（`:101-119`）是插入排序；`cycles`（`DependencyGraph.cj:111-120`）对每个节点 `ordered.contains`。
- **方案**：`HashSet<String>` 去重 + 复用 `StringGenerator` 拼键；`fnSort` 换 `sort` 包（`std.sort`）并按 `compareCalc` 提供比较函数；`cycles` 改成 `HashSet` 差集。
- **预期**：n=10k 行时从 ~1e8 次比较降到 ~1e4 量级（插入排序最坏复杂度 O(n²) 是静态结论，实际耗时降幅需实测）。
- **代价**：`fnSort` 必须保持"稳定排序 + 类型不可比时按相等处理"的现有语义，需要等价性用例（重复值、文本/数值混排、`None` 比较）。
- **验证**：`cjpm bench`，`UNIQUE`/`SORT` 输入 1k / 10k / 100k 行，记录中位耗时；`DependencyGraph.cycles` 用 10k 节点链式依赖。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CellStore`/`ByteColumn` 的插入与删除是 O(n)，逆序写入退化 O(n²)

- **现状**：`ByteColumn.insert`（`CellStore.cj:75-83`）先 `addBits` 再逐字节搬移，`removeAt`（`:85-92`）同理；`addNumberSparse`/`addOther` 每次先 `lowerBound` 再 `insert`（`:277-293`、`:304-325`）。行优先升序写入时插入位置在末尾，摊还 O(1)；**降序或随机行序**写入时每次搬移整列。
- **方案**：给 `CellStore` 加"批量装载"入口（解析器按行输出，天然有序），或检测到连续逆序插入时改用"追加 + 末尾一次性反向"，再或对装载期使用 `ArrayList<(row,col,payload)>` 后统一排序建列。
- **预期**：最坏 O(n²) → O(n log n)（静态复杂度结论；实际收益取决于输入行序，需实测）。
- **代价**：新增一条装载 API 与排序内存峰值（装载期临时数组 ≈ 10 B/格）。
- **验证**：`M3CellStore_test.bulkInsertKeepsOrder` 的变体（逆序 20 万格），`cjpm bench -O2` 对比耗时与峰值 RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `parseAndFill` 对每行扫描全部富文本条目（O(rows × richTexts)）

- **现状**：`ExcelDocument.cj:361-374` 在 `for (row in parsed.rows)` 内部再 `for (entry in parsed.richTexts)` 只为了比较 `entry[0] == row.index`。
- **方案**：把 `richTexts` 先按行号分桶（`HashMap<Int64, ArrayList<...>>`）一次，循环内 O(1) 取；或直接在校验 `richTexts` 已按行升序时用游标推进。
- **预期**：富文本密集表从 O(rows × richTexts) 降到 O(rows + richTexts)。
- **代价**：多一个临时 `HashMap`（条目数级别的额外内存，解析结束即可释放）。
- **验证**：构造 5 万行、每行 1 个富文本单元格的表，`ExcelDocument(path)` 构造耗时对照（`cjpm bench -O2`，含 cold/warm）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 稠密/稀疏双表示与 `others` 槽位回收

- **现状**：全数值表走 `denseValues`（8 B/格），混合表回退三列 + `others`；`others` / `numbers` 只增不减（见「一般」条目），一次"编辑—回填"循环可让槽位数远超单元格数。
- **方案**：`others` 改为可回收槽位（空闲链表），`numbers` 在 `remove`/覆写时归还；`flushDense` 之后按需把 `others` 压缩到当前引用集。
- **预期**：稳态 RSS 从"随写入次数增长"变成"随单元格数增长"；具体字节量需按实际编辑模式测。
- **代价**：编码/解码多一次间接寻址；`others` 压缩要遍历 payload 重建索引（O(n)），只能在低频点（如 `write` 前）触发。
- **验证**：同一文档反复 `setCell`（Number↔Text 交替）10 万次，多轮后 `getAllocatedHeapSize()` 与 RSS 是否回到稳态（`mem §1.2`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 6 部分 -->

### [堆内存] A 图片按路径延迟读，避免整文件常驻

- **现状**：`Image.cj:74-81` `readImage` 用 `File.readFrom(path)` 整文件读入，`SheetImage.data`（`:49`）在 `Worksheet` 里一直持有到写盘；N 张图片常驻 ≈ Σ文件大小（100 张 5 MB 照片 = 500 MB），且与写盘时刻无关。
- **方案**：`addImage(path, …)` 只保存 `Path` + 文件大小/修改时间，写出时用 `ZipWriter.addFileStream`（`f_zip/src/ZipWriter.cj:142`）流式入包；`addImage(Array<Byte>, …)` 重载保持现状。
- **预期**：图片常驻从 Σsize 降到 O(1)（每张只剩路径字符串），峰值内存与图片总大小解耦。
- **代价**：写盘时文件可能已被修改/删除（需在 `write()` 开头做一次存在性 + 大小校验并抛 `ExcelException`）；同一路径被多 sheet 引用时要么重复入包要么加去重表。
- **验证**：100 × 5 MB 图片负载，多轮 `getAllocatedHeapSize()` + RSS 峰值对照，`-O2`，同输入。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] B sharedStrings 边解压边建索引，去掉整段 `Array<Byte>` 峰值

- **现状**：`ExcelSheetStream.cj:229` 一次拿到解压后的整段 SST 字节（S 字节），再在 `SharedStringTable.load` / `SharedStringIndex.build` 里解析；峰值 ≈ 2S 以上（见 #5），与 `sharedStringsIndex` 开关无关。
- **方案**：把 `xl/sharedStrings.xml` 解压流写入临时文件的同时顺序扫 `<si` 记 `(offset, length)`（`SharedStringIndex.scan` 已有逻辑，只需接受 `InputStream`），此后一律走索引读取；`loadSharedStrings = true && sharedStringsIndex = false` 时再决定是否全量表化。
- **预期**：峰值从 ≈2S 降到 S 级（只留落盘文件 + 偏移数组，每 `<si>` 16 B）；常驻同理。
- **代价**：多一次落盘 I/O；全量表路径（`SharedStringTable`）与索引路径的富文本行为差异需保持（`runsAt`）；临时目录不可写时要能回退。
- **验证**：构造 200 MB SST 的 xlsx，`getUsedHeapSize()` 峰值 + RSS 对照，索引命中率计数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] A 函数注册表预构建为常量表，去掉每次 `Call` 的闭包分配

- **现状**：`FunctionRegistry.cj:38-412` 的 `lookupFunction` 每次调用都 `toAsciiUpper` 一次字符串、构造一个 `FnEntry` 结构体并新建一个闭包（`{ ev, args => fnSum(ev, args) }`），然后立刻丢弃；`Evaluator.cj:67` 在每个 `Call` 节点求值时调用一次。recalculate 场景下调用次数 = 全表公式的 `Call` 节点数（10 万格 × 每格 3 个函数 = 30 万次）。
- **方案**：改为 `static let FUNCTIONS: HashMap<String, FnEntry>`（进程级初始化一次，350 项）或排序数组 + 二分；`lookupFunction` 只做查表。
- **预期**：每次 `Call` 去掉 1 次大写转换 + 2 次分配（`FnEntry` + 闭包），GC 压力随之下降。
- **代价**：静态初始化在首次使用时完成（~350 项，毫秒级）；需保证 `FnEntry` 里的闭包不捕获可变状态（当前实现均无捕获，安全）。
- **验证**：`cjpm bench -O2` 对照“10 万格、每格 3 个函数”的 recalculate 耗时中位数，`cjprof` 看分配/GC 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] B `joinText` 改 `StringGenerator`；`criteriaMatch` 常量化比较符并只解析一次

- **现状**：`FormulaAst.cj:139-150` `joinText` 用 `out += part` 逐段拼接（String 不可变 ⇒ 与段数平方成正比），被 `TEXTJOIN`（`CalcFunctionsStatTextExt.cj:575`）与表达式 `toString` 复用；`FunctionRegistry.cj:524` 每次 `criteriaMatch` 新建 6 元素字符串数组，`:537-538` 先 `isNumericText(rest)`（内部 `parseNumberText`）再 `parseNumberText(rest)`，同一串解析两遍，而它在 `COUNTIF(S)` / `SUMIF(S)` 里是逐格调用。
- **方案**：`joinText` 内部改 `StringGenerator`（`f_base` 已有，`FormulaLexer.cj:20` 在用）；比较符数组提为 `static let`，`criteriaMatch` 里一次 `parseNumberText` 后按 `Option` 分支。
- **预期**：TEXTJOIN/大 region 拼接从 O(k²) 降到 O(k)；每格条件判断少一次解析与一次数组分配。
- **代价**：`joinText` 语义不变（含空段），但需保留现有“分隔符只在段间”的行为；`StringGenerator` 输出需与原实现逐字节一致。
- **验证**：`cjpm bench -O2`，输入 `TEXTJOIN("-",TRUE, 1..10000)` 与 `COUNTIF(A1:A1000000,">0")`，中位数 + 离散度。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 7 部分 -->

> 不是缺陷，是"还能更好"。以下全部没有改前基线，按规则只作待验证方案，不进 `todo.md` / `tasks.md`。

### [堆内存] 文本单元格写出要 4 趟扫描 + 2 份整串副本

- **现状**：每个 `Text` 单元格依次经过 `stripControl`（新建 `StringGenerator` 并 `toString()` 出一份等长新串，`SheetXmlWriter.cj:412-434`）→ `checkTextLength`（`runes()` 全量计数，`:366-374`）→ `needsPreserve`（新建 `ArrayList<Rune>` 把整串装进去，`:396-405`），共 3 趟遍历 + 2 个等长临时对象；`PackageWriter.cj:115-119` 再为每行建 `ArrayList<Cell>` 并 `toArray()`。
- **方案**：一次 `runes()` 遍历同时完成非法字符判定、长度计数、首/末 rune 记录；仅当确实发现非法字符时才构造新串，否则直接把原 `String` 交给 `XmlWriter`；`needsPreserve` 只取首末两个 rune（不用 ArrayList）。
- **预期**：每个文本格少 1 份等长 `String` 与 1 个 n 元 `ArrayList<Rune>`（32 767 字符的格约 256 KB 瞬时峰值，按 rune 4 B + 扩容系数估算）；写出期分配量约降 2/3。
- **代价**：控制流略复杂；`stripControl` 与长度计数的顺序需保持"先剔除后计数"（现为剔除后计数，语义不变）。
- **验证**：`cjpm bench` 加 10 万文本格（含 1% 长文本）夹具，`-O2`，对比 `getAllocatedHeapSize()`、峰值 RSS 与 `benchPackageWrite` 中位数/P95。
- **证据状态**：无基线（待验证，不进 tasks）。

### [堆内存] SST 富文本双份存储 + 每条 `<si>` 一个空 `runSets`

- **现状**：`SharedStringTable.load` 对每个 `<si>` 都 `runSets.add(currentRuns)`（`SharedStringTable.cj:148`），非富文本时是空 `ArrayList`；富文本时 `TextRun.text` 与 `items[i]` 各存一份完全相同的文本（`:139` 与 `:147`）。这两份数据随表常驻整个 `ExcelDocument` / `ExcelSheetStream` 生命周期。
- **方案**：`runSets` 改为 `HashMap<Int64, ArrayList<TextRun>>`，只登记真富文本；`runsAt` 未命中返回共享空表（或改 `?ArrayList`，需要同步 `Worksheet.richText` 语义）。富文本场景改为按需拼接（`RichText.text()` 已能由 runs 还原）。
- **预期**：1 M 条非富文本 `<si>` 省约 1 M 个 `ArrayList` 头（估算 24–32 B/个 → 24–32 MB 常驻，估算）；富文本 SST 的字符串字节量约减半。
- **代价**：`runsAt` 从数组索引变哈希查（只出现在读取富文本的冷路径）；`items` 仍需平坦串（`CellValue.Text` 依赖）。
- **验证**：1 M 条非富文本 SST + 10 万条富文本 SST，加载后对比 `getUsedHeapSize()` 与 `getAllocatedHeapSize()`，并回归 `M2d_test` 富文本用例。
- **证据状态**：无基线（待验证）。

### [CPU] 样式去重是 O(格数 × 样式数) 线性扫 + 每格一次 `toString`

- **现状**：`SheetXmlWriter.writeCell:116-122` 每格调 `StylePool.getOrAdd`，内部线性扫 `keys`（`StylePool.cj:104-108`）且先 `styleKey` → `CellStyle.toString()` 拼一个 100–250 B 的串；`StylesWriter` 写 `cellXfs` 时又对每个 xf 用 `indexOf` 重算 `font/fill/border.toString()` 并线性扫（`:225-227`、`:309-316`）。
- **方案**：`keys` / `dxfKeys` 换 `HashMap<String, Int64>`（导入已存在，`StylePool.cj:18`）；`fonts`/`fills`/`borders` 也各建一张 `HashMap<String, Int64>`，在收集阶段算好 id，写出时直接查。
- **预期**：每格从 O(样式数) 次长串比较降为 O(1) 哈希查找；2 万种样式 × 20 万格的最坏情形约 4×10⁹ 次字符比较 → 2×10⁵ 次哈希查找（复杂度推算，非实测）；`cellXfs` 阶段去掉 O(样式数²)。
- **代价**：多几张 map 的内存（受 64 000 上限约束，可忽略）；key 字符串仍需构造（可进一步给 `CellStyle` 实现 `Equatable` 直接做 map key）。
- **验证**：`cjpm bench` 增"每行一种样式 + 20 万格"夹具，`-O2`，对照 `benchPackageWrite` 中位数与 P95，并用 `cjprof` 看 `CellStyle.toString` / `string.equals` 自耗时占比。
- **证据状态**：无基线（待验证）。

### [CPU] `SharedStringIndex` 每次取一条 = 1 次 seek/read + 一次完整 XML 解析 + 2 份整串拷贝

- **现状**：`sliceAt` 每条都 `seek` + `read`（`SharedStringIndex.cj:129-144`）+ `String.fromUtf8`（`:148`）；`parseItem` 再拼 `<?xml…?><sst>` 包装串并 `toString().toArray()` 又拷贝两次（`:156-161`），且只缓存最后一条（`:35-36`）—— 顺序扫描时缓存 0 命中率。
- **方案**：按 64 KB 窗口预读（顺序命中就不 seek）+ 只对 slice 做一次解码；把"拼 wrapper 再转字节"改成直接喂解析器（或直接从 slice 构造 `SharedStringTable`）；缓存改为按索引的 N 条窗口（带上限）。
- **预期**：顺序扫 1 M 格时系统调用从 1 M 次降到约 SST 字节数/64 KB 次；解析次数不变但省两次整串拷贝。随机访问场景收益小。
- **代价**：窗口缓存要设上界（否则变成无界缓存）；实现复杂度上升；`SharedStringIndex` 与 `SharedStringTable` 的解析路径会分叉更多（与 #2 同源风险）。
- **验证**：1 M 格顺序读，对比"全量表 / 索引现状 / 索引+窗口"的墙钟与 `cjprof` 中 `File.read`/`XmlPullParser.nextEvent` 占比，`-O2`，取中位数与离散度。
- **证据状态**：无基线（待验证）。

### [CPU] `formatNumber` 每个非整数最多 17 次 `format` + `parse`

- **现状**：`Numbers.cj:43-55` 对每个非整数从精度 1 试到 17，每轮一次 `Float64.format(".Ng")` 加一次 `Float64.parse`；写 1 M 个非整数最多 1 700 万次解析（`g` 的精度是有效位数，见 `std/convert/convert_package_interfaces.md` 示例 `f.format("g")` → `3.14159`）。
- **方案**：先取一次 `.17g` 得到可往返串，再在字符串上做"最短化"（从尾部尝试删除数字并验证往返），或对常见值域（|v| ∈ [1e-6, 1e15] 且小数位 ≤ 6）走一次 `.6g` 快速分支 + 校验。
- **预期**：典型数据从平均 N 次 `parse` 降到 1–2 次（N 需按真实数据分布实测）；纯 CPU 收益，不改变输出。
- **代价**：最短化逻辑必须与现有输出逐字节一致，否则 `PackageBuffer_test.partsMatchPinnedBaseline` 的 golden 会变；实现需谨慎处理 `-0.0`/指数形式。
- **验证**：先给 `formatNumber` 加"尝试次数"计数，用真实导出数据统计分布；再 `cjpm bench` 写 10 万/100 万数字格对照 `-O2` 中位数。
- **证据状态**：无基线（待验证）。

<!-- 第 8 部分 -->

### [堆内存] 解析期每个 `<c>` 重建 3 个 `StringGenerator`，可复用 + `reset()`

- **现状**：`WorksheetParser.cj:352-354` 在 `startCell` 里 `valueText = StringGenerator()`、`inlineText = StringGenerator()`、`formulaText = StringGenerator()`，每格 3 个对象 + 3 个内部 `ArrayList<Byte>`；一张 100 万格的表 = 300 万对象 + 300 万次 `ArrayList` 初始扩容，全部是毫秒级短命对象（只活到 `finishCell` 的 `toString()`）。
- **方案**：三个字段保留在 handler 上，`startCell` 改调 `valueText.reset()` / `inlineText.reset()` / `formulaText.reset()`（`f_base` 的 `StringGenerator.reset()` 只 `clear()`，保留容量，`StringGenerator.cj:35-38`）。
- **预期**：每格减少 3 次对象分配与 3 次 `ArrayList` 扩容；百万格减少约 300 万次分配（字节量取决于平均单元格文本长度，需实测分配量）。
- **代价**：`reset` 必须覆盖 `startCell` 现在做的所有状态复位（当前本来就是全量重建，语义等价）；`StringGenerator` 容量会被最大单格文本撑大并常驻到 sheet 结束（按最大格文本量级，可接受）。
- **验证**：`cjpm bench -O2` 读同一张 100 万格表，对比 `getAllocatedHeapSize()` 增量、`cjprof` 的 GC 次数与解析耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `mergedRangeAt` 每次线性扫全部合并区并对每个字符串重新 `parseRange`

- **现状**：`Worksheet.cj:400-414` 对每次查询遍历 `merges`（m 条），每条都跑 `CellRef.parseRange`（内部 `s.toArray()` + 多次 `String.fromUtf8` 切片 + `columnIndex`）；`mergedValue`（`:416-426`）命中后再解析一次同一字符串。渲染侧逐格调用 `mergedValue` 时是 O(格数 × m) 次字符串解析；1000×1000 表 + 100 个合并区 ≈ 1e8 次解析。
- **方案**：`merge`/`unmerge` 时缓存 `(CellRef, CellRef, canonical)`；或额外维护 `HashMap<Int64, ArrayList<(Int64, Int64, String)>>`（行 → 列区间），查询只扫行内的少数区间。`mergedRanges()` 仍返回原字符串列表。
- **预期**：单次查询从 O(m·parse) 降到 O(1)~O(log m)；整表遍历的解析次数从 1e8 量级降到 1e3 量级（复杂度结论静态成立，耗时降幅需实测）。
- **代价**：模型多一份索引，`merge`/`unmerge` 需同步维护（两处写入口已集中，风险可控）；内存 +O(m)。
- **验证**：`cjpm bench -O2`，1000×1000 表遍历 `mergedValue`，m = 10 / 100 / 1000 三档，取中位数与 P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Worksheet.range` 逐格走 `cell()`（ensureLoaded + 边界校验 + `lowerBound` 二分）

- **现状**：`Worksheet.cj:327-348` 对 `rows × cols` 每格调 `cell(start.row + i, start.col + j)`（`:340`），每次都要 `ensureLoaded()`（`Option` match）、`valid()`（4 次比较）、`CellStore.lowerBound`（O(log n) 二分，每步 `rowAt`/`colAt` 解码）。1000×1000 区域 = 1e6 次二分（每次约 20 步比较）。
- **方案**：按行取一次 `cells.rowEntries(row, end.col)`（已按列升序，`CellStore.cj:340-353`），再线性铺进该行的 `Array<CellValue>`；缺失位置保持 `Empty`。
- **预期**：1e6 格从 1e6 次 `lowerBound` 降到 1e3 次 `lowerBound` + 线性填充，量级 O(cells·log n) → O(rows·log n + cells)。
- **代价**：需保持"缺失格 → `Empty`、超出区域截断"的现有语义；`rowEntries` 会触发 `flushDense`（现有逐格 `cell()` 路径在读 `denseActive` 时也可能触发，行为一致）。
- **验证**：`cjpm bench -O2`，稠密/稀疏两种 1000×1000 表，对比 `range("A1","CV1000")` 中位耗时与 `getUsedHeapSize()` 峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「稠密数值表 100 万格 RSS 增量约 3 MB；稀疏/混合表约 29 MB」在当前实现下仍成立 | `f_excel/README.md:523` | 测量口径（RSS 还是 `getUsedHeapSize`）、SDK 版本、构建选项、表形状 | 固定 SDK + `-O2`，分别造 100 万格稠密数值表与 1% 密度稀疏表，读前/读后各采 5 次 RSS 与 `getUsedHeapSize()`，取中位数与离散度 |
| 2 | `sharedStringsIndex=true` 的 open 峰值等于一份完整解压的 `sharedStrings.xml` | `f_excel/src/SharedStringIndex.cj:45-48`、`src/ExcelSheetStream.cj:229-235` | 峰值倍数（相对部件大小） | 造 10 MB / 100 MB 两档 `sharedStrings.xml`，`open` 前后采样 RSS 与分配量，分别测 `sharedStringsIndex` 开/关 |
| 3 | 设计 §9.3 的耗时预估（1 万行 / 10 万行 × 10 列：100~300 ms / 1~3 s）仍可作为容量规划依据 | `doc/f_excel模块设计.md:2641-2653` | 实测耗时与机器规格 | `cjpm bench -O2` 跑流式/整文档两条通道，各 5 轮取中位数；记录 CPU 型号与核数 |

<!-- 第 2 部分 -->

> 本部分没有性能数据，以下仅为下一轮补数据的清单，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `loadSharedStrings = false` 模式下逐格告警的峰值内存（发现 #2 的量化部分） | `f_excel/src/WorksheetParser.cj:486-497` | 1M 行 × 10 列全 `t="s"` 时的 `warnings().size` 与峰值 RSS | 构造该表跑 `ExcelSheetStream`（`loadSharedStrings = false`），记录 `getAllocatedHeapSize()` / `getUsedHeapSize()` 峰值与告警条数 |
| 2 | 「大表复制」（`RowReader` 直喂 `ExcelWriter`）的真实内存曲线是否与行数无关 | `f_excel/src/ExcelSheetStream.cj:41-100`、`f_excel/src/ExcelWriter.cj:100-160` | 10 万 / 100 万行两档的 RSS 稳态与 GC 次数 | `cjprof record` + 分段计时，`-O2`，同机同输入，取中位数 |
| 3 | `sharedStrings` 全量装载对文本密集型工作簿的常驻内存占比 | `f_excel/src/SharedStringTable.cj:44-171` | 表项数与 `items` + `runSets` 字节量 | 对 100 万条 `<si>` 的样本测 `heapUsed` 前后差，与 `sharedStringsIndex = true` 对照 |

<!-- 第 3 部分 -->

> 没有性能测试数据支撑的猜测。不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 稀疏/混合表 100 万格 29 MB 的结论可能已过时（`CellStore` 在 `05ae1e96b` 之后仍有改动可能） | `f_excel/doc/spec/implement-f-excel-m3/verification.md:23` | 测量环境（SDK 版本、`-O2`、机器、轮次中位数）、口径（RSS 增量 vs `getUsedHeapSize`）、是否含索引结构 | 固定 100 万格稀疏夹具，`cjpm bench -O2` + 每轮前后 RSS/堆采样，跑 5 轮取中位数 |
| 2 | 缓冲复用"少分配 4 次 / 每带图 sheet 再省 3 次"缺少实测支撑，`Package_bench` 结果未落进任何文档 | `f_excel/doc/spec/reuse-package-writer-buffer/proposal.md:47`、`tasks.md:47` | 复用 vs 新建两条路径的耗时与分配量（中位数、离散度） | `cd f_excel && cjpm bench -O2`，取 `benchSevenPartsReused/Fresh`、`benchStylesReused/Fresh` 中位数并记录到 tasks 5.3 |

<!-- 第 4 部分 -->

> 没有性能数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序（`MEDIAN`/`LARGE`/`SORT`/`SORTBY`）在大区域上占公式耗时主要部分 | `f_excel/src/CalcFunctionsExt.cj:36-44`、`f_excel/src/CalcFunctionsMath.cj:439-447` | 自耗时占比、n 拐点 | `cjprof record` 跑 `MEDIAN(A1:A100000)` 与 `LARGE(...,5)`，各 100 次，报 self time |
| 2 | `SUMIFS`/`COUNTIFS` 的循环内物化是真实热点（静态复杂度已确认，缺占比） | `f_excel/src/CalcFunctionsMath.cj:259-267`、`:380-383` | 端到端耗时占比 | 1000×50 区域、1/3 组条件，分段计时对比"循环外物化"改写版 |
| 3 | `CalcEngine` 每次 `evaluate` 重建容器的分配开销在条件格式逐格求值场景下显著 | `f_excel/src/CalcEngine.cj:117-122` | 分配量/GC 次数 | `cjprof heap` 跑 10 万格 `matchedRules`，统计分配字节与 GC 暂停 |
| 4 | `EXPAND` / 大 `VSTACK` 的结果数组是主要峰值内存来源 | `f_excel/src/CalcFunctionsDynFin.cj:173-185`、`:188-218` | 峰值 RSS 与结果规模关系 | 固定 used range，逐步放大 `EXPAND` 目标行列，记录 `getUsedHeapSize()` 与 RSS |
| 5 | 分布函数累积循环（#13）在正常输入（x ≤ 1000）下耗时占比不高，风险集中在恶意大输入 | `f_excel/src/CalcFunctionsDist.cj:185-192` 等 5 处 | x 与单次耗时曲线 | 对 x = 10/100/1000/10000 计时，确认拐点后再定上限 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `cfThreshold` 的复制+插入排序是条件格式求值的主要耗时 | `f_excel/src/CfEval.cj:247-288` | 自耗时占比（`cjprof` report 中该函数 self%） | `cjprof record` 跑 1000×10 区域、3 档 iconSet 的 `matchedRules` 全表遍历，输入 1 万格 |
| 2 | `CellStore` 逆序/随机行序写入的搬移是装载瓶颈 | `f_excel/src/CellStore.cj:75-92` | 20 万格逆序写入耗时与 `memmove` 占比 | `cjpm bench -O2` 对比升序/逆序写入；`cjprof` 看 `ByteColumn.insert` |
| 3 | `UNIQUE`/`SORT` 在 1 万行以上成为用户可见延迟 | `f_excel/src/DynamicArrays.cj:101-145` | 1k/10k/100k 行的耗时曲线 | `cjpm bench` 单函数基准，取中位数与 P95 |
| 4 | `rangeValue` 物化大区域是 `recalculate` 的内存峰值来源 | `f_excel/src/Evaluator.cj:89-116` | 峰值 `getUsedHeapSize()` 与 RSS 增量 | 10 万行×100 列数值表跑 `SUM(A:A)` / `SUMPRODUCT`，多轮记录峰值 |
| 5 | `lookupFunction` 的 350 分支 `match` 在大量小公式场景有可观分派开销 | `f_excel/src/FunctionRegistry.cj`（本部分外，`Evaluator.cj:66` 调用） | 每公式调用次数与分派自耗时 | `cjprof record` 跑 10 万格简单公式（`=A1+1`），看字符串比较与 `lookupFunction` 自耗时 |

<!-- 第 6 部分 -->

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `lookupFunction` 的每次大写 + 闭包分配在 recalculate 中占可观 GC 时间 | `f_excel/src/FunctionRegistry.cj:38-412` | 分配次数与 GC 时间占比 | `cjprof record` 跑 10 万格 × 每格 3 函数的 recalculate，看 `lookupFunction` self time 与分配采样 |
| 2 | `criteriaMatch` 的数组分配 + 双重 `parseNumberText` 是 COUNTIF/SUMIF 的主要开销 | `f_excel/src/FunctionRegistry.cj:519-556` | 单格耗时与 100 万格总耗时 | 分段计时：`COUNTIF(A1:A1000000,">0")` 前后插桩，对照“数组提常量”补丁 |
| 3 | `joinText` 的 O(k²) 在 TEXTJOIN 大数组下占比显著 | `f_excel/src/FormulaAst.cj:139-150` | 段数-耗时曲线 | `cjpm bench -O2`，k = 10/100/1000/10000 四档 |
| 4 | SST 峰值与解压大小严格线性，且 `sharedStringsIndex` 不降低峰值 | `f_excel/src/ExcelSheetStream.cj:229-241` | 解压大小 vs 峰值曲线 | 造 50/100/200 MB sharedStrings 各一份，采样 `getUsedHeapSize()` 峰值 + RSS |
| 5 | `DependencyGraph.add` 的 `list.contains` 在 65 536 依赖时 O(n²) 明显 | `f_excel/src/DependencyGraph.cj:49-56` | 建图耗时 vs 依赖数 | 单格引用整列/大区域，计时 `buildGraph()`；对象为 `HashSet` 的对照实现 |

<!-- 第 7 部分 -->

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `formatNumber` 的 17 次 format/parse 是写出路径的热点 | `f_excel/src/Numbers.cj:43-55` | 自耗时占比、平均尝试次数分布 | 加尝试次数计数；`cjprof record` 跑 `ExcelDocument.write`，输入 100 万数字格（其中 50% 非整数） |
| 2 | 样式去重的线性扫在高样式数下成为瓶颈 | `f_excel/src/StylePool.cj:102-120` | `CellStyle.toString`/`string.equals` 自耗时、样式数分布 | 合成"每行一种样式"的 20 万格文档，`cjprof record` + `cjpm bench -O2` 前后对照 |
| 3 | 索引模式顺序读被系统调用拖慢（每格一次 seek/read） | `f_excel/src/SharedStringIndex.cj:125-165` | 每格平均耗时、syscall 次数 | 1 M 格 sheet 顺序读，分段计时 + 系统调用统计，与全量表模式对照 |
| 4 | 文本格 4 趟扫描造成的分配占写出期分配量的显著比例 | `f_excel/src/SheetXmlWriter.cj:366-434` | 分配量与峰值 RSS 占比 | `cjprof heap` + `getAllocatedHeapSize()`，10 万文本格（1% 为 30 KB 长文本） |
| 5 | `runSets` 的空表与富文本副本是 SST 常驻内存的主要增量 | `f_excel/src/SharedStringTable.cj:139-148` | 常驻堆占比 | 1 M 条非富文本 + 10 万条富文本 SST，加载后 `getUsedHeapSize()` 对照 |
| 6 | 文档写出按 `maxRow` 全量循环，稀疏表（A1 + A1048576）会白跑百万行 | `f_excel/src/PackageWriter.cj:110-120` | 稀疏表写出耗时占比 | 只有两行的文档 vs 紧凑文档，分段计时 `rowValues` 累计耗时 |

<!-- 第 8 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `StringGenerator` 每格重建是解析期 GC 压力的主要来源之一 | `f_excel/src/WorksheetParser.cj:352-354` | 分配量（字节）与 GC 次数、占总耗时比例 | 同一份 100 万格表，改前/改后 `getAllocatedHeapSize()` + `cjprof` GC 线程耗时，`-O2` |
| 2 | `mergedRangeAt` 的字符串解析在渲染路径上可观测 | `f_excel/src/Worksheet.cj:400-426` | 函数自耗时占比、每次解析平均耗时 | `cjprof record` 跑 1000×1000 表 + 100 合并区，逐格 `mergedValue` |
| 3 | `rowValues()` 触发 `flushDense` 会把稠密表一次性摊成稀疏，常驻内存随之上升 | `f_excel/src/Worksheet.cj:351-357`、`f_excel/src/CellStore.cj:340-341` | 摊平前后 RSS / `getUsedHeapSize()` 差 | 1000×1000 全数值表先 `range(...)` 再 `rowValues(...)`，多轮记录 RSS（该议题与第 5 部分「稠密/稀疏双表示」同源） |
| 4 | 规则复制 + 插入排序在规则数 > 20 的组上占比可观 | `f_excel/src/Worksheet.cj:203-215` | 排序自耗时、单次 `matchedRules` 耗时随 k 的曲线 | `cjpm bench`，k = 3 / 10 / 50，区域 100 格，取中位数 |

## 文件覆盖

> 与 `files/f_excel.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/README.md` | .md | ✅ | — |
| 2 | `f_excel/README_en.md` | .md | ✅ | — |
| 3 | `f_excel/doc/f_excel模块设计.md` | .md | ✅ | — |
| 4 | `f_excel/doc/spec/f-excel-images/design.md` | .md | ✅ | — |
| 5 | `f_excel/doc/spec/f-excel-images/proposal.md` | .md | ✅ | — |
| 6 | `f_excel/doc/spec/f-excel-images/specs/f-excel-images/spec.md` | .md | ✅ | — |
| 7 | `f_excel/doc/spec/f-excel-images/tasks.md` | .md | ✅ | — |
| 8 | `f_excel/doc/spec/implement-f-excel-m1/baseline.md` | .md | ✅ | — |
| 9 | `f_excel/doc/spec/implement-f-excel-m1/design.md` | .md | ✅ | — |
| 10 | `f_excel/doc/spec/implement-f-excel-m1/proposal.md` | .md | ✅ | — |
| 11 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-cell-model/spec.md` | .md | ✅ | — |
| 12 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-reader/spec.md` | .md | ✅ | — |
| 13 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-roundtrip/spec.md` | .md | ✅ | — |
| 14 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-stream-read/spec.md` | .md | ✅ | — |
| 15 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-stream-write/spec.md` | .md | ✅ | — |
| 16 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-writer/spec.md` | .md | ✅ | — |
| 17 | `f_excel/doc/spec/implement-f-excel-m1/tasks.md` | .md | ✅ | — |
| 18 | `f_excel/doc/spec/implement-f-excel-m1/verification.md` | .md | ✅ | — |
| 19 | `f_excel/doc/spec/implement-f-excel-m1/verify.md` | .md | ✅ | — |
| 20 | `f_excel/doc/spec/implement-f-excel-m2/design.md` | .md | ✅ | — |
| 21 | `f_excel/doc/spec/implement-f-excel-m2/proposal.md` | .md | ✅ | — |
| 22 | `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-formula/spec.md` | .md | ✅ | — |
| 23 | `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-rich-values/spec.md` | .md | ✅ | — |
| 24 | `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-styles/spec.md` | .md | ✅ | — |
| 25 | `f_excel/doc/spec/implement-f-excel-m2/tasks.md` | .md | ✅ | — |
| 26 | `f_excel/doc/spec/implement-f-excel-m2/verification.md` | .md | ✅ | — |
| 27 | `f_excel/doc/spec/implement-f-excel-m3/design.md` | .md | ✅ | — |
| 28 | `f_excel/doc/spec/implement-f-excel-m3/ods-assessment.md` | .md | ✅ | — |
| 29 | `f_excel/doc/spec/implement-f-excel-m3/proposal.md` | .md | ✅ | — |
| 30 | `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-formula-ext/spec.md` | .md | ✅ | — |
| 31 | `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-ods/spec.md` | .md | ✅ | — |
| 32 | `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-scale/spec.md` | .md | ✅ | — |
| 33 | `f_excel/doc/spec/implement-f-excel-m3/tasks.md` | .md | ✅ | — |
| 34 | `f_excel/doc/spec/implement-f-excel-m3/verification.md` | .md | ✅ | — |
| 35 | `f_excel/doc/spec/implement-f-excel-m4/design.md` | .md | ✅ | — |
| 36 | `f_excel/doc/spec/implement-f-excel-m4/proposal.md` | .md | ✅ | — |
| 37 | `f_excel/doc/spec/implement-f-excel-m4/specs/f-excel-conditional-format/spec.md` | .md | ✅ | — |
| 38 | `f_excel/doc/spec/implement-f-excel-m4/tasks.md` | .md | ✅ | — |
| 39 | `f_excel/doc/spec/implement-f-excel-m4/verification.md` | .md | ✅ | — |
| 40 | `f_excel/doc/spec/reuse-package-writer-buffer/design.md` | .md | ✅ | — |
| 41 | `f_excel/doc/spec/reuse-package-writer-buffer/proposal.md` | .md | ✅ | — |
| 42 | `f_excel/doc/spec/reuse-package-writer-buffer/specs/excel-opc-package/spec.md` | .md | ✅ | — |
| 43 | `f_excel/doc/spec/reuse-package-writer-buffer/tasks.md` | .md | ✅ | — |
| 44 | `f_excel/src/Array_test.cj` | .cj | ✅ | — |
| 45 | `f_excel/src/CalcEngine.cj` | .cj | ✅ | — |
| 46 | `f_excel/src/CalcFunctionsDbMisc.cj` | .cj | ✅ | — |
| 47 | `f_excel/src/CalcFunctionsDist.cj` | .cj | ✅ | — |
| 48 | `f_excel/src/CalcFunctionsDynFin.cj` | .cj | ✅ | — |
| 49 | `f_excel/src/CalcFunctionsExt.cj` | .cj | ✅ | — |
| 50 | `f_excel/src/CalcFunctionsExt2.cj` | .cj | ✅ | — |
| 51 | `f_excel/src/CalcFunctionsLogic.cj` | .cj | ✅ | — |
| 52 | `f_excel/src/CalcFunctionsLookup.cj` | .cj | ✅ | — |
| 53 | `f_excel/src/CalcFunctionsMath.cj` | .cj | ✅ | — |
| 54 | `f_excel/src/CalcFunctionsMathEng.cj` | .cj | ✅ | — |
| 55 | `f_excel/src/CalcFunctionsStatTextExt.cj` | .cj | ✅ | — |
| 56 | `f_excel/src/CalcFunctionsTextDate.cj` | .cj | ✅ | — |
| 57 | `f_excel/src/CalcValue.cj` | .cj | ✅ | — |
| 58 | `f_excel/src/CellRef.cj` | .cj | ✅ | — |
| 59 | `f_excel/src/CellRef_test.cj` | .cj | ✅ | — |
| 60 | `f_excel/src/CellStore.cj` | .cj | ✅ | — |
| 61 | `f_excel/src/CellValue.cj` | .cj | ✅ | — |
| 62 | `f_excel/src/CellValue_test.cj` | .cj | ✅ | — |
| 63 | `f_excel/src/CfEval.cj` | .cj | ✅ | — |
| 64 | `f_excel/src/ConditionalFormat.cj` | .cj | ✅ | — |
| 65 | `f_excel/src/DateFormat.cj` | .cj | ✅ | — |
| 66 | `f_excel/src/DateSerial.cj` | .cj | ✅ | — |
| 67 | `f_excel/src/Date_test.cj` | .cj | ✅ | — |
| 68 | `f_excel/src/DependencyGraph.cj` | .cj | ✅ | — |
| 69 | `f_excel/src/DependencyGraph_test.cj` | .cj | ✅ | — |
| 70 | `f_excel/src/DynamicArrays.cj` | .cj | ✅ | — |
| 71 | `f_excel/src/Eager_test.cj` | .cj | ✅ | — |
| 72 | `f_excel/src/Evaluator.cj` | .cj | ✅ | — |
| 73 | `f_excel/src/ExcelDocument.cj` | .cj | ✅ | — |
| 74 | `f_excel/src/ExcelDocument_test.cj` | .cj | ✅ | — |
| 75 | `f_excel/src/ExcelException.cj` | .cj | ✅ | — |
| 76 | `f_excel/src/ExcelOptions.cj` | .cj | ✅ | — |
| 77 | `f_excel/src/ExcelSheetStream.cj` | .cj | ✅ | — |
| 78 | `f_excel/src/ExcelWriter.cj` | .cj | ✅ | — |
| 79 | `f_excel/src/ExcelWriter_test.cj` | .cj | ✅ | — |
| 80 | `f_excel/src/FormulaAst.cj` | .cj | ✅ | — |
| 81 | `f_excel/src/FormulaLexer.cj` | .cj | ✅ | — |
| 82 | `f_excel/src/FormulaParser.cj` | .cj | ✅ | — |
| 83 | `f_excel/src/FormulaShift.cj` | .cj | ✅ | — |
| 84 | `f_excel/src/Formula_test.cj` | .cj | ✅ | — |
| 85 | `f_excel/src/FunctionExt_test.cj` | .cj | ✅ | — |
| 86 | `f_excel/src/FunctionRegistry.cj` | .cj | ✅ | — |
| 87 | `f_excel/src/Function_test.cj` | .cj | ✅ | — |
| 88 | `f_excel/src/Image.cj` | .cj | ✅ | — |
| 89 | `f_excel/src/Image_test.cj` | .cj | ✅ | — |
| 90 | `f_excel/src/M2d_test.cj` | .cj | ✅ | — |
| 91 | `f_excel/src/M3CellStore_test.cj` | .cj | ✅ | — |
| 92 | `f_excel/src/M3DistDb_test.cj` | .cj | ✅ | — |
| 93 | `f_excel/src/M3DynFin_test.cj` | .cj | ✅ | — |
| 94 | `f_excel/src/M3Index_test.cj` | .cj | ✅ | — |
| 95 | `f_excel/src/M3Math_test.cj` | .cj | ✅ | — |
| 96 | `f_excel/src/M3Spill_test.cj` | .cj | ✅ | — |
| 97 | `f_excel/src/M3StatText_test.cj` | .cj | ✅ | — |
| 98 | `f_excel/src/M4_test.cj` | .cj | ✅ | — |
| 99 | `f_excel/src/Numbers.cj` | .cj | ✅ | — |
| 100 | `f_excel/src/PackageBuffer_test.cj` | .cj | ✅ | — |
| 101 | `f_excel/src/PackageReader.cj` | .cj | ✅ | — |
| 102 | `f_excel/src/PackageReader_test.cj` | .cj | ✅ | — |
| 103 | `f_excel/src/PackageWriter.cj` | .cj | ✅ | — |
| 104 | `f_excel/src/Package_bench.cj` | .cj | ✅ | — |
| 105 | `f_excel/src/RichText.cj` | .cj | ✅ | — |
| 106 | `f_excel/src/RoundTrip_test.cj` | .cj | ✅ | — |
| 107 | `f_excel/src/RowData.cj` | .cj | ✅ | — |
| 108 | `f_excel/src/SharedStringIndex.cj` | .cj | ✅ | — |
| 109 | `f_excel/src/SharedStringReuse_test.cj` | .cj | ✅ | — |
| 110 | `f_excel/src/SharedStringTable.cj` | .cj | ✅ | — |
| 111 | `f_excel/src/SheetXmlWriter.cj` | .cj | ✅ | — |
| 112 | `f_excel/src/StreamRead_test.cj` | .cj | ✅ | — |
| 113 | `f_excel/src/Style.cj` | .cj | ✅ | — |
| 114 | `f_excel/src/StylePool.cj` | .cj | ✅ | — |
| 115 | `f_excel/src/Style_test.cj` | .cj | ✅ | — |
| 116 | `f_excel/src/StylesLite.cj` | .cj | ✅ | — |
| 117 | `f_excel/src/Worksheet.cj` | .cj | ✅ | — |
| 118 | `f_excel/src/WorksheetParser.cj` | .cj | ✅ | — |
| 119 | `f_excel/src/WorksheetParser_test.cj` | .cj | ✅ | — |
| 120 | `f_excel/src/Worksheet_test.cj` | .cj | ✅ | — |
| 121 | `f_excel/src/Writer_test.cj` | .cj | ✅ | — |
| 122 | `f_excel/src/fixtures.cj` | .cj | ✅ | — |

合计：`.cj` 79 个 / `.md` 43 个 / 共 122 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 命中的是文档层面的契约错误：能力表里程碑口径（#2）、API 归类不可用（#9）、线程安全契约缺失（#10）；本部分无源码，语言特性与安全性无独立结论 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可搜；顺带读到的两个未读字段（`ExcelDocument.lazyParts`、`ExcelSheetStream.spoolFile`）属源码范围，记入「范围外提示」不计入统计 |
| §2 重复逻辑 | 2 | README 已知缺口两条「富文本」逐字重复；设计 §5.5.4 同一结论的正确写法与旧实现并存 |
| §3 空实现 | 1 | 设计 §17.4「差异」是空标题（#12） |
| §4 栈溢出 | 0 | 三份文档未承诺递归遍历；设计第 8 章只描述事件流解析，无递归结构。源码侧的依赖链递归风险见「范围外提示」 |
| §5 OOM | 1 | `sharedStringsIndex` 的 open 峰值口径缺失（#8）；临时文件累积属磁盘增长（#7，按资源问题计，不按堆 OOM 计） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，文档里的耗时均为预估，已列待验证假设 #3 |
| §6.2 大粒度锁 | 0 | 文档无锁设计章节；`ExcelWriter`/`CalcEngine` 的并发面见 §12 行 |
| §6.3 并发串行 | 0 | 文档未描述并发调度；设计 2.7.7 只声明「单 reader 不可并发 next」，不构成串行热点 |
| §6.4 低效算法 | 0 | 文档未给复杂度承诺；`Worksheet.range` / `StylePool.getOrAdd` 的复杂度问题属源码范围，见「范围外提示」 |
| §7 降堆内存方案 | 0 | 无改前/改后基线，任何方案只能作假设；已把 sharedStrings 峰值列为待验证假设 #2 |
| §8 降 CPU 方案 | 0 | 同上，无基线数据 |
| §9 local mode 可行性 | 0 | 三份文档均未涉及 local mode，本部分无可评估函数 |
| §11 现有代码的 BUG（存量） | 2 | 文档契约层面的两条：`loadRowHeight` 无声失效（#6）、spool 临时文件无清理（#7）；源码行仅作证据，实际代码缺陷由 part4–part8 报 |
| §12 并发安全与锁粒度 | 1 | `CalcEngine` 求值期改写实例状态且无线程安全声明（#10）；未发现文档层面的锁粒度讨论，故锁粒度 0 |
| §14 功能完备性与 README 覆盖 | 3 | 英文版承诺缺失（#1）、能力表与缺口章节口径冲突（#2）、`loadRowHeight` 接线缺失（#6） |
| 文件覆盖（§13 等） | 3/3 | 无缺失；三份文档均逐行读完（3069 行的设计文档分 5 次读完） |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 本部分无代码；按"文档承诺 → 源码取证"核对，命中 #1–#7（含 2 条数据/内存后果）；未发现安全问题（文档无凭据、无外部输入示例） |
| §1 死代码 | 1 | 文档侧等价检查：对文档点名的每个符号/文件跑全仓搜索（`SheetRowSink` / `Styles.cj` / `Ast.cj` / `functions/` / `stringMode` / `RichTextFlattened` / `CalcIssue` / 6 个测试文件名），零命中项合并为 #12、#8、#1、#7；`PackageStructure_test`、`DateFormat_test`、`SharedStringTable_test` 是真实测试类，未误报 |
| §2 重复逻辑 | 2 | 同一要求在 proposal/design/spec/tasks 重复表述并已漂移：`stringMode`（#8）、转义归属（#9）、`SheetSkipped` 语义（#3）、spool 回退（#11）各算一处根因，合并统计为 2 条（文档内漂移 + 文档/代码漂移） |
| §3 空实现 | 1 | 规格承诺的行为在实现里没有（富文本平坦化，`setRichText` 只存不用）→ #1；`ExcelWarningKind` 缺少 `RichTextFlattened` 分支同根 |
| §4 栈溢出 | 0 | 文档无递归结构描述；`WorksheetParser`/`DateSerial` 均为迭代实现，`XmlPullParser` 默认 `maxElementDepth=4096`（`baseline.md:61`），不构成本部分新风险 |
| §5 OOM | 1 | `loadSharedStrings = false` 的逐格告警 → 告警数组随单元格数线性增长（#2）；其余"全量读入"（`init(input)`）已在 spec 明示并在 `verification` 记录 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；本部分无代码可测，热点结论不成立，已把可量化的两点放进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分文档未描述锁；`f_excel` 读路径无可变共享状态（文档口径"sharedStrings 只读共享、条目游标各自独立"与 `ExcelSheetStream` 实现一致） |
| §6.3 并发串行 | 0 | 无 `spawn` / 并发写路径；`ExcelWriter` 文档明确"拉模式、不起线程" |
| §6.4 低效算法 | 0 | 文档未涉及算法复杂度承诺；`CalcEngine` 的 350 个函数注册是 `match` 分派（`FunctionRegistry.cj`），无嵌套扫描可判 |
| §7 降堆内存方案 | 0 | 无基线数据；不把"告警对象可复用"一类猜测写成方案 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时对象；文档也未承诺 local mode；收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 7 | 已核对：sheet 名 31 字符按字节（#6）、rels/sharedStrings 解析失败放大为整体失败（#4）、`SheetSkipped` 契约不符（#3）、`loadSharedStrings` 告警风暴（#2）、`evaluate` 返回类型（#7）、富文本写丢文本（#1）、样式上限平台分档（#14） |
| §12 并发安全与锁粒度 | 0 | 文档规定的并发边界与实现一致（同一 `ExcelSheetStream` 不同 reader 独立游标、禁止多线程同时 `next()`，`ExcelSheetStream.cj:41-100`）；本部分无新增共享可变状态 |
| §14 功能完备性与 README 覆盖 | 3 | #5（testdata/openpyxl 未落地）、#1（富文本写出）、#13（收尾产物缺失）；README 本身属第 1 部分，未在本部分统计 |
| 文件覆盖（§13 等） | 20/20 | 全部 `.md` 已逐文件读完，无抽样、无跳过 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 本部分无 `.cj`；"正确性"在文档语境下折算为规格与实现的一致性，命中的 9 条一般问题即 #1–#9；无安全性相关承诺（无凭据、无外部输入处理描述） |
| §1 死代码 | 0 | 文档无符号可见性；"文档里承诺但代码不存在"的符号（`ExcelDocument.setStyle`、`unsupportedFunctions`、`StyleOverridesNumberFormat`、`SpoolForLazy`）按要求记 §14/§13，不重复计死代码 |
| §2 重复逻辑 | 0 | 20 份文档之间无同语义段落复制；`m3/design.md` 与 `m3/specs/f-excel-scale/spec.md` 的门禁数字是引用而非重复实现；`m4/design.md:31` 与 `m4/specs/…/spec.md:8` 的"priority 升序"是规则的同义表述，已作为 #8 的实现缺口处理 |
| §3 空实现 | 0 | 无空函数体可查；"契约有行为但实现为空"的三处（告警、报告字段、求值分支）已计入 #2/#4/#7 |
| §4 栈溢出 | 0 | 文档无递归实现；`ods-assessment.md` 与 M3 数组广播描述未引入递归遍历承诺 |
| §5 OOM | 1 | 见 #6（100 万格 29 MB 与 20 MB 目标）；另 #5 的临时文件累积属磁盘而非堆，记在 #5 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据，`Package_bench` 结果未落文档（待验证假设 #2），不成立为热点结论 |
| §6.2 大粒度锁 | 0 | 无锁相关文档内容 |
| §6.3 并发串行 | 0 | 文档明确"不引入多线程求值"（M3 proposal Out of Scope），无并发串行设计 |
| §6.4 低效算法 | 0 | 本部分未定义算法；`design.md:44-52` 的行块方案与代码列式结构不符已记 #14 |
| §7 降堆内存方案 | 0 | 纯文档部分，无运行时代码可提方案 |
| §8 降 CPU 方案 | 0 | 同上；缓冲复用的 CPU 收益缺数据，见待验证假设 #2 |
| §9 local mode 可行性 | 0 | 本部分不涉及 local mode；`doc/spec` 内无相关承诺 |
| §11 现有代码的 BUG（存量） | 2 | 计 #5（临时文件无回收）与 #6（门禁口径），二者均由文档与代码对照确认；其余存量缺陷在 `.cj` 部分覆盖 |
| §12 并发安全与锁粒度 | 0 | 无共享状态描述；缓冲复用明确限定单线程串行（design §非目标） |
| §14 功能完备性与 README 覆盖 | 5 | #1（API 缺失）、#3（配置未接线）、#4（报告字段缺失）、#5（告警缺失）、#7（求值覆盖）；README 本体不在本部分，未据此判"README 遗漏" |
| 文件覆盖（§13 等） | 20/20 | 无缺失；§13 文档一致性命中 #1–#3、#6–#9、#10–#14 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 25 | 全部 25 条发现均落在正确性（越界/死循环/错值）与设计（重复、封装、并发契约）上；安全性无注入类风险（纯计算，无 SQL/HTML/文件路径），`CalcEngine` 未捕获异常归到可用性 |
| §1 死代码 | 3 | #19 未使用 import ×3（全仓 grep 仅 import 行）；#20 不可达分支/恒等赋值/死赋值 4 处；#23 `fnLargeSmall:107` 排序结果读了不用。另逐个核对本部分 27 个 `private`/`internal` 符号（`dbRows`/`aggregateNumbers`/`determinant`/`convertFactors`/`normalCdf`/`normalPdf`/`normalInv`/`combination`/`factorialOf`/`minI`/`maxI`/`minD`/`npvAt`/`rateAt`/`refBoundsOf`/`isLeapYear`/`daysInMonth`/`datePartsOf`/`addMonthsToSerial`/`sumIfCore`/`roundHalfAway`/`intToRadix`/`radixToInt`/`intBaseConvert`/`spillArray`/`xnpvAt`/`gcd`），全部有调用者；`DocumentResolver` 是 `internal class`，其 `public` 成员均为 `CalcResolver` 接口实现，按硬原则不计；`CalcReport`/`CalcEngine` 为对外可达 `public`，只记"仓内引用"不判死代码 |
| §2 重复逻辑 | 5 | #15 财务取参样板 ×6；#21 ROUND 因子 ×3；#22 YEARFRAC basis 0/4；#23 插入排序 ×4；#24 `aggregateNumbers` vs `SUM/AVERAGE/MIN/MAX/STDEV`。已两两比对本部分 150+ 个函数体的"输入-输出-副作用"，除上述外仅有跨函数通用的 `match (error) { Some => return }` 错误传播样板，属惯用写法不判 |
| §3 空实现 | 2 | #10（`HYPERLINK` 丢链接、`INFO` 假值、`ROW()`/`COLUMN()` 无参报错）；#16（`TIMEVALUE` 秒 `catch` 吞异常按 0）；`fnNa`/`fnAreas` 是有意的最简实现（`NA()` 就应返回 `#N/A`），不算空实现 |
| §4 栈溢出 | 0 | 唯一递归是 `determinant`（`DbMisc.cj:270-294`），入口已限制 `n <= 8`（`:250`）⇒ 深度 ≤ 8；`flattenValues`（`CalcValue.cj:204-224`）对嵌套 `ArrayValue` 递归，但数组最多两层（`ArrayLit`/`VSTACK` 不产生更深嵌套）；无自引用结构、无深拷贝 |
| §5 OOM | 2 | #3 `EXPAND` 无上限分配；#13 分布函数按实参上界的长循环（不是分配，但同属"无拒绝路径"）。`memo`/`cycleCells`/`issues` 每次 `evaluate` 重置、规模受本次触碰格数限制，不构成无界增长 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 `cjprof` / `cjpm bench` / 分段计时数据，按规则热点结论不成立，已把 5 条候选写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 读写锁（`grep` 全空），无锁内 I/O 或回调 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池，无并发度配置 |
| §6.4 低效算法 | 3 | #14 循环内区域物化（O(格数²)）；#23 插入排序 O(n²)；#13 阶乘重复计算 O(x²)。三者都给了复杂度推导，耗时占比标注"需实测" |
| §7 降堆内存方案 | 1 | 「区域按需读取」方案（无基线） |
| §8 降 CPU 方案 | 2 | 「统一 std.sort」「复用求值容器」两方案（均无基线） |
| §9 local mode 可行性 | 0 | 候选是 `rangeValue`/`SUMIFS` 里的临时 `ArrayList<Array<CalcValue>>`，但缺"峰值内存"对照数据，且 `rangeValue` 结果要逃逸到 `CalcValue.ArrayValue` 返回，逃逸检查不通过 ⇒ 只能写假设，不成立 |
| §11 现有代码的 BUG（存量） | 18 | #1–#7、#9–#14、#16–#18、#22、#25 共 18 条带 §11 判据（含合并了多位置的同根因条目）；本部分读到的 150+ 个函数边界、空值、错误路径均已核对，其余未发现缺陷 |
| §12 并发安全与锁粒度 | 1 | #18（`CalcEngine` 实例可变状态无同步、异常不复位；证据等级 `待确认`，因仓内无共享路径）。锁粒度维度无锁可谈 |
| §14 功能完备性与 README 覆盖 | 3 | #8（AGGREGATE options 未接线）、#9（4 个形参未读取）、#10（HYPERLINK/INFO/ROW 半成品）。本部分无 `.md`，README 覆盖维度留待含文档的子轮；承诺源用 `FunctionRegistry.cj:415-473` 的函数名清单 + Excel 函数契约 |
| 文件覆盖（§13 等） | 11/11 | 无缺失；本部分 0 个 `.md`，§13 文档一致性在本部分不适用 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 8 条（逻辑错误、边界、错误处理缺失）；设计 2 条（`DependencyGraph` 泄漏内部列表、`warnings_` 共享可变）；语言特性 1 条（`Int64(Float64)`/`fromUtf8` 转换会抛异常，未转成错误值）。安全性：本部分无外部 SQL/HTML/路径拼接，`Path` 只来自调用方；未见凭据与敏感数据落日志，0 条 |
| §1 死代码 | 5 | 逐个 `private`/`internal`/`protected` 符号全仓搜引用：`lazyParts`（写不读）、`serialToDateTime`（零引用）、`fnDollarFixed` 的 `pattern`（连带 `zeros`）、`load` 的 `lazyPath` `None` 分支（不可达）、`cfRuleHit` 的 `sheet`/`ref` 死参数。`public` 且对外可达（`ExcelDocument`/`Worksheet`/`CalcValue` 等）一律不判；`CellStore.size()` 仅测试引用，只记可见性建议 |
| §2 重复逻辑 | 4 | 8 个文件函数体两两比对（输入→输出→副作用）后命中：数值文本化两套（`CellValue`/`CalcValue`）、枚举 `==` 走 `toString` 三处、`CfRuleType` 名字表两处、`firstError`/`sortedNumbers` 错误展开样板 12+3 处（本部分） |
| §3 空实现 | 2 | `SHEET`/`SHEETS` 恒 1；`WIDECHAR`/`ASC` 恒等返回。逐函数检查了空 `{}`、只 `return None/false`、`catch {}`：本部分 `catch (_: Exception) {}` 只出现在资源关闭路径（`ExcelDocument.cj:83/92/312` 等），属"关闭失败可忽略"，不判 |
| §4 栈溢出 | 1 | `Evaluator.eval`（`:54-86`）按 `Expr` 深度递归，深度由文件里的公式嵌套决定，无深度计数；`flattenValues`（`CalcValue.cj:204-224`）对嵌套数组同源。可达深度上界需实测（平台栈大小与解析器递归），故未定严重 |
| §5 OOM | 2 | `rangeValue` 无元素数上限（一般）；`CellStore.others/numbers` 只增不减（一般）；`SEQUENCE` 已有 `rows*cols > 1_048_576` 拒绝路径、`spoolInput` 落盘与输入同阶，均确认无问题 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`scope.md` 的「已有性能资料」只有 LocalMode 文档，不含 f_excel 数据），所有疑似热点降级为「待验证假设」#1–#5，未计入统计 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件零 `synchronized`/`Mutex`/`Atomic`（`grep -rn "synchronized\|Mutex\|Atomic"` 零命中），无锁即无大粒度锁问题 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池提交，全部同步计算 |
| §6.4 低效算法 | 5 | `cfThreshold` 复制+插入排序（每格每规则）、`fnUnique` 线性 `contains` + 字符串 `+=`、`fnSort` 插入排序、`parseAndFill` 的行×富文本双循环、`DependencyGraph.cycles` 的 `contains`。均已给复杂度量级，耗时占比进待验证假设 |
| §7 降堆内存方案 | 1 | 「堆内存」方案：稠密/稀疏双表示与 `others` 槽位回收。`clear()` 不归还物理内存、`gc()` 不保证归还等假象已按 mem §3.2 写入方案说明 |
| §8 降 CPU 方案 | 4 | matchedRules 缓存、O(n²) 结构替换、装载期批量、富文本分桶 |
| §9 local mode 可行性 | 0 | 本部分主要对象（`CellStore`/`Worksheet`/`CalcValue.ArrayValue`）全部逃逸进文档模型或被作为返回值，`rangeValue` 的临时数组会作为 `ArrayValue` 返回；没有"函数内创建并释放的大对象"能通过逃逸检查。且无改前/改后峰值内存数据，按 §9 结论写法只能是"不可行/无证据"，故 0 条 |
| §11 现有代码的 BUG（存量） | 20 | 本轮读到的 20 个文件全部按边界/空值/错误处理/资源/契约过了一遍，命中 2 严重 + 15 一般 + 6 轻微（±0 的边界：`serial 60`→`None`、`DateSerial` 整除取整、`parseRange` 倒置拒绝、`sheetAt` 越界返回 `None` 均核对无问题）；每条都带 `git blame` 证据或"工作区快照无基线"标注 |
| §12 并发安全与锁粒度 | 1 | 无 `static` 可变状态、无单例；实例级共享点只有 `ExcelDocument.warnings_` 与 `Worksheet.loader`，懒加载路径无同步（1 条，证据 `待确认`，缺"是否允许跨线程共享"的契约）；锁粒度因无锁不适用 |
| §14 功能完备性与 README 覆盖 | 3 | `SHEETS`/`SHEET` 恒 1（能力未接线）、`WIDECHAR`/`ASC` no-op、`TEXTSPLIT` 第 3 参数未接线。README（`README.md:22/24/527`）与 `Worksheet.matchedRules`、`CalcEngine` 公开 API 逐项对照：`matchedRules` 只承诺 cellIs/expression/文本/colorScale/dataBar/iconSet，`timePeriod`/`aboveAverage` 明确标注"只保留不求值"，因此 `cfRuleHit` 的 `case _ => None`（`CfEval.cj:70`）**不算**缺陷 |
| 文件覆盖（§13 等） | 20/20 | 无遗漏；本部分不含 `.md`，`§13 文档一致性`在本部分记 0，README 只作承诺源交叉核对（发现 1 处与本部分 API 相关的不一致：`README.md:537` 与 `:527` 两处"富文本"要点重复，属其他部分范围，仅作提示） |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | #1（递归崩溃）、#2（字节≠字符）、#7（公式被改表）、#13（宽容解析）、#14（注释不符）、#16（测试假断言）；安全面未发现注入类问题——写侧全部经 `XmlWriter` 转义、`ExcelWriter` 只校验不拼串 |
| §1 死代码 | 5 | #11：`scalarsOf`、`ImageFormat.contentType`、`spoolFile`、`RowSink.merged`（含 `RowCapture.merged` 空实现）、未用 import `OpenMode`；已逐个按 `private` 全仓 / `internal` 本包及子包搜索，其余 `private`/`internal` 符号均有调用者；`ExcelException`/`ExcelWarning`/`RowReader`/`ExcelSheetStream`/`ExcelWriter`/`ImageFormat` 等对外可达声明、以及 `RowCapture.row` 这类接口实现按硬原则一不判 |
| §2 重复逻辑 | 4 | #12 的 4 类：`runesText`/`runesToString`（逐行相同）、`extension`/`toString`（输出相同）、引号扫描 4 份、枚举相等 3 种写法 |
| §3 空实现 | 1 | `RowCapture.merged`（`ExcelSheetStream.cj:33`）空函数体且无调用点，已并入 #11；另 `catch (_: Exception) {}` 出现 6 处但均为“清理时吞异常”，属合理用法 |
| §4 栈溢出 | 1 | #1：无深度上限的语法递归（下游 `collectRefs`/`eval`/`Expr.toString` 同深度）；其余无递归（`shiftFormula`、`tokenizeFormula`、读写路径均为循环） |
| §5 OOM | 2 | #5（SST 全量物化）、#6（告警无上限累积）；图片全量读入量化后不足以单独定级，转入方案 A |
| §6.1 热点瓶颈 | 0 | 本轮无 bench / cjprof / 分段计时数据；`lookupFunction`、`criteriaMatch`、`joinText` 均只进「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁、`synchronized` 或共享可变全局状态（`ExcelSheetStream`/`ExcelWriter`/`RowReader` 均为实例字段，无静态可变状态） |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无批处理提交；`ExcelSheetStream` 一个 reader 串行推进是设计（拉模式） |
| §6.4 低效算法 | 0 | 已核对候选：`joinText` 的 `+=`、`criteriaMatch` 的数组分配、`DependencyGraph.add` 的 `contains` —— 均无耗时数据，列入「待验证假设」3/2/5；`ExcelWriter` 的重复名检查 O(n²) 但 n = sheet 数（个位数）不构成问题 |
| §7 降堆内存方案 | 2 | 方案 A（图片延迟读）、方案 B（SST 流式索引），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 方案 A（函数表化）、方案 B（`joinText` + `criteriaMatch`），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 不可行/无法证明：`FormulaParser.parse` 的 token 数组与 AST 都作为返回值/`Expr` 逃逸出函数（`Excel` 求值链持有），`@ local!` 会被逃逸检查拒绝；`ExcelWriter` 的 `ByteBuffer` 是跨调用生命周期对象。无峰值内存对照数据，按清单只能判「待验证」，本轮不立方案 |
| §11 现有代码的 BUG（存量） | 16 | 全部 16 条均为存量（快照基线）；已核对 `ExcelWriter`/`ExcelSheetStream`/`FormulaParser`/`FormulaShift`/`FormulaAst` 的边界与空值分支，以及 3 处资源释放路径 |
| §12 并发安全与锁粒度 | 0 | 本部分无共享可变状态：`ExcelSheetStream`（`warnings_`/`lastSheet`/`lastMerges`/`closed`）、`ExcelWriter`（`nextSheet`/`failed`/`rowsWritten_`）、`RowReader`（`finished`/`closed`）都是实例字段，无静态可变成员、无注册表、无回调逸出，判定为线程封闭；README 未声明线程安全，建议后续补一句“非线程安全，单线程使用” |
| §14 功能完备性与 README 覆盖 | 1 | #10（`loadRowHeight` 接线缺失，README:470 有文档）；README 全量覆盖核对不在本部分（`.md` 由其他子轮审），此处只就代码侧承诺源做交叉引用 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md` 文件，§13 文档一致性不在本部分执行；无缺文件 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | #1（OOXML 类型属性）、#3（错误码契约）、#7（错误处理）。无外部输入注入面（写出侧只拼 XML 事件，转义统一由 `XmlWriter` 负责）；分层无 Controller/Service 概念，不适用 |
| §1 死代码 | 1 | #8 未使用导入；逐个核对了本部分 `private`/`internal` 符号：`PackageWriter` 的 1 参重载、`SharedStringTable.size`、`SharedStringIndex.size()` 仅被测试引用（按判据属"可见性建议"不计死代码）；`StylesWriter.indexOf`/`addUnique*` 均有调用；`StylePool.size`、`entries`/`dxfs`/`customFormats`/`formatIdAt` 均有调用；`ImageFormat.contentType()` 0 引用但文件不在本部分（范围外提示） |
| §2 重复逻辑 | 1 | #9 五组（QName 助手 ×3、addUnique ×3、长度校验 ×2、MIME 字面量、`<v>` 模板 ×5）；另核对了 `PackageReader` 与 `SharedStringIndex` 的"路径/切片"逻辑、`M3Math_test`/`M3StatText_test` 的同名 `close` 断言助手（测试准备代码，按误报边界不计） |
| §3 空实现 | 1 | #10 `writeCachedValue` 的 `case _ => ()`；其余 `case None => ()` 均为可选字段正常缺失，`stripControl`/`warnFormat` 有实际副作用 |
| §4 栈溢出 | 0 | 本部分无递归：`formatNumber` 是循环、`StylesWriter` 遍历、`SharedStringIndex.scan/findClose` 是双指针线性扫描；`SharedStringTable.load` 依赖 `XmlPullParser` 的迭代事件循环 |
| §5 OOM | 1 | #6 写出侧告警无界；`SharedStringIndex` 切片按已知长度精确分配（上界为 SST 解压大小，不放大）；SST 全量物化已在 part6 #5 报告，本部分只补 `runSets` 常驻开销（优化方案） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 结果；`Package_bench` 只覆盖缓冲复用，不覆盖本部分怀疑的热点，全部列入「待验证假设」（1–6） |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享可变全局状态 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池；写出是单线程顺序 ZIP 流 |
| §6.4 低效算法 | 0 | 唯一 O(n²) 候选（样式去重线性扫、`indexOf`）缺基线，按规则放「优化方案 [CPU]」+「待验证假设 2」，不计发现 |
| §7 降堆内存方案 | 2 | 文本格 4 趟扫描/2 份整串副本；SST `runSets` 空表 + 富文本双份（均无基线） |
| §8 降 CPU 方案 | 3 | 样式去重 map 化；索引窗口预读；`formatNumber` 最短化（均无基线） |
| §9 local mode 可行性 | 0 | 关键中间对象都逃逸：`stripControl` 的串写入 XML、`SharedStringTable.items/runSets` 成为成员、`PackageWriter` 缓冲返回给 `zip.add`；`SheetXmlWriter` 的临时 `ArrayList<XmlAttribute>` 太小，峰值收益无法用数据证明 |
| §11 现有代码的 BUG（存量） | 12 | 本轮 12 条发现全部为存量，覆盖边界（`<si/>`）、契约（`c@t`、错误码、`namedStyle`）、规格顺序（`dxfs`）、错误处理、无界容器、去重键碰撞 |
| §12 并发安全与锁粒度 | 0 | 无模块级/单例共享状态；`ExcelWriter`/`StylePool`/`SharedStringIndex` 都是"单实例单线程"对象（`SharedStringIndex` 有可变 `file` 句柄与单条缓存，但 API 是游标式、未声明线程安全，无跨线程共享路径可指） |
| §14 功能完备性与 README 覆盖 | 1 | #4 `namedStyle` 承诺有、写侧无接线；README 其余与实现相关的承诺（`sharedStringsIndex`、`maxCellStyles`、`RichText` 只读）已逐条对照，`.md` 文件本身由其他子轮审 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完；本部分无 `.md`，§13 文档一致性由覆盖 `.md` 的子轮负责 |

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性：`stopIfTrue` 跨组、多段 sqref 平移、`RowData.cells` 契约、`maxRows` 接线、`ensureLoaded` 异常、`clearCell` 计数；设计：内部容器外泄、`fixtures` 进 src、解析器无祖先栈；可读性：测试类名/格式；安全性：无注入面（本部分不拼 SQL/HTML，XML 由 `f_xml` 生成），无硬编码凭据 |
| §1 死代码 | 2 | 逐个 `private`（`key`/`valid`/`valuesOfRange`/`attr`/`onStart`/`onEnd`/`onText`/`startRow`/`startCell`/`finishCell`/`valueOf`/`plainValue`/`numericValue`/`numberValue`/`buildCfRule`/`finishRow`/`parseIntAttr`/`parseColor`/`parseFont`/`parseFill`/`parseBorderSide`/`parseBorder`）在全仓均有调用者；`internal`（`parseIntOrNone`/`parseFloatOrNone`/`parseDateOrNone`/`ParsedSheet`/`WorksheetParser`/`SheetRowHandler`/`setLoader`/`setDimension`/`sheetImages`/`matchedRulesWith`/`StylesLite.*`/`XfRecord`/`fixtures.*`）在本包内均有引用，唯 `codeOf`、`setCellNumber` 零引用；`RowSink.merged` 无调用点（与第 6 部分 #11 重合）；`public` 成员全部属对外可达的 `public class Worksheet`，按硬原则一不判；未用 import 见 §10 轻微条 |
| §2 重复逻辑 | 1 | 已把 8 个文件的函数体按"输入-输出-副作用"两两比对：`Worksheet.cell` 三个重载是转发不是重复；`rowCount/colCount` 属可读性展开；合并为 1 条含 5 组的发现（内联属性解析 ×5、区域规范化 ×2、sqref 遍历 ×2、SST 索引二次解析、图片空校验两层） |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/空函数体；`catch` 集中在 `parseIntOrNone`/`parseFloatOrNone`/`parseDateOrNone` 与 `StylesLite.load`（前者有 `Option` 语义、后者重抛 `ExcelException`），无静默吞异常；`RowCapture.merged` 空实现已在 §1 计 |
| §4 栈溢出 | 0 | 本部分无递归：`shiftFormula` 是迭代（外部文件）、XML 解析是拉模式迭代、`CellRef.parse`/`parseRange` 无自调用；`Worksheet.matchedRulesWith` 只有两层固定循环，深度不随输入增长 |
| §5 OOM | 2 | `valuesOfRange` 按 sqref 面积物化（含 `range()`）、流式通道 `parsed.richTexts` 随行数累积；「告警列表无上限」已由第 6 部分 #6 报出，本部分不重复计数 |
| §6.1 热点瓶颈 | 0 | 本轮无 `cjprof` / `cjpm bench` 数据，无法给"函数 + 自耗时占比 + 输入规模"三件套；候选热点全部进「待验证假设」，未写成发现 |
| §6.2 大粒度锁 | 0 | 本部分无线程同步原语（无 `synchronized`/`Mutex`/`Atomic`），`Worksheet` 是单线程可变模型 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无任务提交、无并发度配置 |
| §6.4 低效算法 | 0 | 唯一的"为判存在而全量扫描"（`valuesOfRange`）已并入 §5 那条按严重计；`mergedRangeAt` 的 O(m·parse) 与 `range()` 的逐格 `lowerBound` 进优化方案（无基线） |
| §7 降堆内存方案 | 1 | `StringGenerator` 复用；`CellStore` 的稠密/稀疏与槽位回收属第 5 部分，不重复 |
| §8 降 CPU 方案 | 2 | `mergedRangeAt` 索引化、`range()` 行批量填充；`matchedRules` 的整区重建与排序属第 5 部分 |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：解析期的 `Cell` 进 `RowData.cells`、`RowData` 进 `ParsedSheet.rows` 或交给 sink，`CellStyle`/`RichText` 进 `Worksheet` 成员；三个 `StringGenerator` 的缓冲最终 `toString()` 逃逸为 `String`。没有"函数内创建、函数内销毁"的大对象，收益也无法用峰值内存对照证明 |
| §11 现有代码的 BUG（存量） | 12 | 本部分 8 个文件的边界/空值/错误处理/契约逐项核对：`valuesOfRange` 面积、`maxRows` 流式、富文本累积、`cells` 升序、`stopIfTrue`、sqref 平移、`ensureLoaded`、内部容器、family/charset、namedStyle、`val="0"`、`clearCell`；快照模式全部记「存量」 |
| §12 并发安全与锁粒度 | 0 | 本部分无共享可变静态状态、无锁；`Worksheet` 的 `ArrayList`/`HashMap` 只在该实例内读写，线程封闭性由调用方保证（第 5 部分已就 `ensureLoaded` 的并发风险给出「待确认」结论） |
| §14 功能完备性与 README 覆盖 | 1 | `maxRows` 在流式入口"声明了但未接线"（§14.1「接线缺失」），与 §11 中同一条合并计数；本部分无 `.md` 文件，README 覆盖面（如 `matchedRules` 未文档化的 `expression` 限制）由包含 `README.md` 的分部分负责 |
| 文件覆盖（§13 等） | 8/8 | 本部分清单只有 8 个 `.cj`，无 `.md`；8 个文件全部逐行读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 15 |
| 一般 | 74 |
| 轻微 | 46 |
| 其中存量 | 135 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分的三个文件都停留在「写完即弃」的状态：代码已经走到 M4，文档还停在 M1/M2 的交叉口。

- **必须优先处理**：`README_en.md` 的「Known gaps (M1 scope)」（#1）。它不是措辞问题，而是把已实现的样式/公式声明为「不存在」，英文使用者会据此做错误选型；它的测试数与中文版对不上，进一步削弱可信度。
- **会直接导致误用**：设计文档 §2.2 / §7.4 / §7.6 的签名与值模型（#3）、`loadRowHeight` 空开关（#6）、`sharedStringsIndex` 的峰值口径（#8）。前两者会让调用方编译失败或以为省了内存，第三者会让人在大文件上低估 open 期峰值。
- **资源与并发契约**：#7（spool 临时文件无清理）与 #10（`CalcEngine` 非线程安全但未声明）是服务端场景的真问题——前者是磁盘无界增长，后者是单例复用时的数据错乱。两者都可以通过「补文档 + 小改动」解决，不需要重构。
- **可以排期**：设计文档 §5.5.4 的残留（#12）、重复的缺口条目、以及各处过期数字（#13）。

代码本身看起来比文档成熟得多（`package`/版权头齐备、异常与告警分层清晰、流式与整文档两条通道都有明确的失败语义），本轮的文档缺陷更像是「实现跑得快、回填没跟上」。建议把「README 与 `src/` 公开声明一致性」做成发布前检查项，否则每加一个里程碑都会重演一次。

### 范围外提示（不计入本轮统计，供对应部分参考）

- `ExcelDocument.renameSheet`（`src/ExcelDocument.cj:264-279`）用 `Worksheet(newName)` 整体替换原对象，**重命名即丢失全部单元格/样式/合并/图片**，与 README:195 的 `renameSheet: Bool` 契约不符——建议 part5 按数据丢失（严重）核实。
- `src/ExcelDocument.cj:361-366` 在 `for (row in parsed.rows)` 内层再遍历全部 `parsed.richTexts`，复杂度 O(rows × richTexts)，富文本多的大表会退化为平方级。
- `src/Worksheet.cj:336` 的 `range(from, to)` 直接按解析出的行列数 `Array(rows, ...)`，`range("A1","XFD1048576")` 无上限校验（约 172 亿格）；`src/StylePool.cj:102-108` 的 `getOrAdd` 每次线性扫全部 key 字符串，与设计 §2.6.4.3 的三层哈希查找不符。
- `src/ExcelSheetStream.cj:125-146` 的 `spoolFile` 与 `src/ExcelDocument.cj:35` 的 `lazyParts` 只有写入没有读取，属未使用字段（`§1`）。
- `src/SheetXmlWriter.cj:356-361` 在 M2 之后仍对自定义日期格式记 `NumberFormatNotSupportedInM1`「M1 不支持」，告警名与文案已过期，会污染 `warnings()`。

**第 2 部分**：本部分是 `f_excel` 的规格与验收文档，整体质量高于常见"写完就丢"的设计稿：**图片（M1.5）四个文件与实现
基本一一对应**；流式读写文档的主体（构造、行号、状态机、flush、`mergedRanges` 时序）也与实现一致，
偏差集中在 `spool` 与 `loadSharedStrings` 两处；`verification.md` 也如实标注了
"真实 Excel 人工验收未执行"，没有伪装成已通过。

主要风险集中在两类：

1. **承诺与实现反向**（阻塞项）。富文本写出承诺"只丢样式"，实际只调 `setRichText` 会丢整段文本；
   `loadSharedStrings = false` 承诺"不报错、内存与行数无关"，实际逐格生成告警，在百万行场景反而制造 OOM。
   这两条都直接打在使用者最可能走的路径上，且都没有用例兜住（前者用例靠手工补 `setCell` 绕过，后者零用例），
   建议在合并报告里列为必修。
2. **验收证据与文档链完整性**（可排期）。testdata 真实样本与 openpyxl 自动化缺失、`design.md` §10.1 实测记录空白、
   `build-warnings.md` 未生成、6 个测试文件名不存在 —— 这些不影响运行时，但会让"规格 → 实现 → 用例"的
   追溯链断在关键处，后续 SDK 升级或解析器改动时无法复核当时的结论。

存量共 14 条（严重 2 / 一般 5 / 轻微 7），全部为存量、无本次改动引入项；是否纳入修复由用户决定。

**第 3 部分**：本部分结论集中在"规格—实现—验收"三者的漂移，而不是代码本身的质量问题：20 份文档里，`reuse-package-writer-buffer` 的设计与实现基本对齐（仅数据流图把视图写成拷贝，属误导性错误但实现正确），M3/M4 的归档文档则存在多处"承诺了但没做到、验收却写全部完成"的情况——`ExcelDocument.setStyle`、`CalcReport.unsupportedFunctions`、`StyleOverridesNumberFormat`、`SpoolForLazy` 四个符号在代码里完全不存在，`maxCellStyles` 在整文档写出路径上不可配，M3 的 29 MB 与 20 MB 目标、5 条门禁只测 1 条却被判"全部达标"，M4 的 `timePeriod`/`aboveAverage` 求值与 `priority` 写回顺序也没兑现。

阻塞项建议按"会不会骗到使用者"排序：先修 #6（门禁口径，否则下游会按错误的容量假设上生产）与 #5（临时文件泄漏，长期服务会被写满 `/tmp`），再修 #1/#3/#4（对外契约缺失或不可达），最后处理 #2/#7/#8/#9 这类语义与告警层面的偏差。轻微项（#10–#14）可在下次动这些目录时顺手清理，其中 #10、#14 会让归档状态和内部结构读不出来，值得优先于纯文字项。

存量共 14 条（一般 9 + 轻微 5），是否纳入修复、哪些按"改文档"结案，待用户决定。

**第 4 部分**：计算引擎的骨架是好的：错误优先传播（`firstError`）、按格 memo、环检测与 `#CIRC!` 上报、`recalculate(writeBack)` 的 spill 冲突处理都有明确设计，`CalcEngine` 的注释也写清了"默认不自动重算"这一关键语义。问题集中在**函数实现层对输入的不信任不足**：7 条严重项里有 6 条是"合法/半合法公式直接打到未校验路径"——`CELL` 少一个实参就索引越界（#1）、`SUBSTITUTE` 遇中文就切坏 UTF-8（#2）、`EXPAND` 无上限分配（#3）、`WORKDAY` 遇负序列号死循环（#5）、日期函数把超范围序列号直接丢给 `DateTime.ofEpoch`（#6）、`VSTACK` 锯齿数组让 `INDEX` 越界（#7），而这些异常在 `Evaluator.eval` → `CalcEngine` 链路上没有任何 `try/catch` 兜底，单条公式即可中断整次重算。这些是阻塞项，建议先做"求值边界统一兜底 + 输入范围校验"两件事，再谈函数语义。

其次是 `NETWORKDAYS.INTL`/`WORKDAY.INTL` 把 weekend 当节假日（#4）：这是静默错值，比崩溃更难发现，优先级应与崩溃同级。功能完备性方面，#8/#9/#10 是一批"注册了但没实现"的形参和占位函数（AGGREGATE options、DAYS360 method、HYPERLINK、INFO），建议要么补齐要么收紧 `maxArgs` 并在 README 声明，避免使用者按 Excel 文档写公式却拿到别的口径。

性能与内存方面本部分没有任何测量数据，因此只给出 3 条无基线方案与 5 条待验证假设；其中 `SUMIFS`/`COUNTIFS` 的"循环内重复物化"（#14）复杂度是静态可证的 O(格数²)，建议在补数据时优先验证。代码重复（#15/#21/#22/#23/#24）不影响当前行为，但已经出现口径漂移（`PPMT` 缺参取 0、`DMAX` 空集与 `MAX` 不同、美式 30/360 名不副实），适合在修上面缺陷时顺手收敛。

**第 5 部分**：本部分（求值器 + 单元格存储 + 文档模型 + 条件格式求值 + 统计/文本函数）整体设计清晰：`CalcValue`/`CellValue` 的职责分界、日期序列号的 1900/1904 双基准、`CellStore` 的紧凑列式表示都是经过思考的取舍，注释与实现基本一致，`serial 60`、`usedBounds` 裁剪、`SEQUENCE` 上限这类边界都处理到了。

风险集中在两处**会静默丢数据**的地方，建议作为阻塞项：`ExcelDocument.renameSheet` 直接丢弃整表内容（一行就能修），以及 `CellStore` 稠密块宽度只按首行定型，导致"首行较短、次行更长"的纯数值表尾部单元格读不出来（`get` 缺一次 `flushDense` 回退）。其次是求值路径的错误处理范式问题：`Int64(Float64)` 越界、`String.fromUtf8` 半个字符、`formatNumber` 遇 `Inf/NaN` 都会把异常抛出 `CalcEngine.evaluate`，而 Excel 语义要求返回 `#VALUE!`/`#NUM!`；这类问题在"用户上传的 xlsx 里带公式"的场景下必然出现，建议统一在 `Evaluator.eval` 的 `Call` 分支加兜底。

其余（`FILTER` 列筛选失效、`TEXT` 的 `mm` 当月份、`DOLLAR/FIXED` 负数格式、`UNIQUE` 类型混淆、`SHEETS` 恒 1、`LEFTB` 半字符）都是"能跑但结果不对"的存量缺陷，修复面小、验证成本低，可以排进同一批。性能方面本部分没有任何实测数据，`cfThreshold` 的重复排序是唯一有明确复杂度证据的热点候选，先按「待验证假设」补 `cjprof` 数据再决定是否改动。

**第 6 部分**：本部分代码整体质量中上：流式读写的主干（`ExcelWriter` 顺序校验 + 失败即锁死、`RowReader` 拉模式自动收尾、`ExcelSheetStream` 的 `close` 幂等与 spool 清理）设计清楚；公式优先级表、共享公式平移、函数注册表的边界用例覆盖也明显好于一般模块。

真正的阻塞项只有一个：**#1 公式语法递归无深度上限**，畸形/第三方公式可直接把进程打崩，且读取侧其余路径都在做“宽容降级”，这里缺少护栏显得突兀，应在合并前修掉。

其次需要排期的是三条“静默失效”类问题：**#3** 失败路径泄漏 fd 与临时文件、**#4** 缺 styles 时无告警（`StylesMissing` 等三个 kind 形同虚设）、**#5** SST 全量物化的峰值内存——它们都不会报错，只会在长驻服务里表现为句柄/内存缓慢上涨或数据悄悄退化成数字，属于最难靠使用反馈发现的一类。#2（中文 sheet 名被拒）、#7（表名被平移）、#10（`loadRowHeight` 无效）都是单点可修的小缺陷。

轻微项集中在可维护性：4 处死代码（尤其 `spoolFile` 这个“假生命周期字段”）、4 类重复实现（含枚举相等三套写法带来的 `x != x` 隐患）、3 处注释与实现不符，以及两条测试可信度问题（`INFO("system")=="Linux"` 平台绑定、350 个函数的假断言）。

性能部分本轮没有 bench / cjprof 数据，因此全部按「待验证假设」处理，未写成结论：可疑点是每次函数调用重建注册项（closure 分配）、条件匹配的逐格数组分配与双重解析、`joinText` 的字符串平方级拼接 —— 都是“看起来热”的线索，需用 `cjpm bench -O2` 与 `cjprof` 补基线后才能决定是否进修复清单。

**存量 16 条（严重 1 / 一般 9 / 轻微 6），是否纳入修复待用户决定。**

**第 7 部分**：本部分代码的工程质量整体偏高：`XmlWriter` 事件式写出、样式池按值去重、`PackageBuffer` 共享缓冲、`SpreadsheetML` 上限校验（32767/8192/64000）都做得比较克制，测试也覆盖了字节级 golden、缓冲复用、关闭语义这些容易出问题的地方。

主要风险集中在两条"读/写与规范对不齐"的链路上：

1. **写出类型语义**（#1/#3/#10）：`c@t` 只对直接值生效，公式缓存值一律按数字写，错误值白名单又比引擎自己的错误词表窄。"引擎算得出、文件写不对"是公开主路径上的阻塞项，建议优先修，且修完要补文本/布尔/错误缓存三条 round-trip。
2. **SST 索引的结构假设**（#2/#7）：为了省内存改用字节级扫描，但没有覆盖自闭合标签与 CDATA，一旦命中就是静默错值，且与全量表实现语义分叉。这条可以选择"用 XML 解析器重做索引"或"在索引模式明确限制输入并告警"，但不宜维持现状。
3. **样式表规范一致性**（#4/#5/#11）：`dxfs` 顺序、`namedStyle` 悬空、`apply*` 判据不全，都是"用 Excel 打开才暴露"的问题，自有读侧因为宽容所以测不到，属于需要补外部解析器/人工打开验证的盲区。

轻量项（#8/#9/#12）不影响正确性，可随样式池的 map 化优化一起处理。性能与内存方面的 5 条方案都还停留在复杂度与分配量推算，缺 `-O2` 基线与 `cjprof` 数据，按规则只作下一轮补数据的清单。

**第 8 部分**：本部分覆盖 `f_excel` 的读取模型核心（`Worksheet` + `WorksheetParser`）与样式读写入口（`StylesLite`）。**阻塞项只有一条**：`valuesOfRange` 按 `sqref` 矩形全量物化且没有任何面积上限，一个几百字节的文件即可要求几十 GB 分配，属于"不可信输入直接决定内存规模"，应在下一版本前修掉（加面积上限或改成单趟聚合）。

**排期优先级**：三处"静默失效"类问题排在第二档 —— 流式 `maxRows` 完全不生效、流式富文本随行数累积、`ensureLoaded` 异常后停在半加载状态。它们不会报错，只会在长驻服务里表现为"上限不起作用 / 内存缓慢上涨 / 数据悄悄缺行"，是最难靠使用反馈发现的一类。第三档是读写保真度（family/charset、namedStyle、`val="0"`、`RowData.cells` 升序）与条件格式语义（`stopIfTrue` 跨组、多段 sqref 平移），影响的是"读进来再写出去"的正确性；第四档是封装与工程整洁（内部容器外泄、`fixtures.cj` 进产物、死代码与重复逻辑、测试覆盖缺口）。

代码整体质量中上：稀疏 `CellStore` 的分层、`ParsedSheet`/`RowSink` 的双通道抽象、`StylesLite` 对越界索引的统一降级（`styleAt`/`dxfAt`/`formatId` 一律回默认）都做得克制；`parseSheet` 用 `try/finally` 关解析器，告警文案带 sheet 名，测试对越界 SST、缺行号、非法列引用、1900-02-29 等边界都有覆盖。主要风险集中在"没有上限的按文件内容扩张"和"两条通道行为不一致"这两类结构性问题，而不是散点 bug。

存量共 18 条（严重 1 / 一般 10 / 轻微 7），是否纳入修复由用户在门禁决定；本部分只报不修。合并本模块报告时请按正文的「与其它分部分的重合说明」去重（尤其第 6 部分 #6/#11、第 5 部分 `ensureLoaded` 与 `matchedRules`、第 7 部分 #4、第 3 部分 #7/#8）。
