# f_excel 模块审查报告

> **模块第 1/8 部分**（分报告）。本部分只覆盖 `README.md` / `README_en.md` / `doc/f_excel模块设计.md` 三个文档；
> 同模块其余 79 个 `.cj` 与 40 个 `.md` 见 `parts/f_excel.part2.md` ~ `part8.md`，最终模块报告由主 Agent 合并。
> 因本部分无源码文件，「文件覆盖」「覆盖自检」「模块统计」只统计这 3 个文件；源码行号仅作为文档与实现对照的证据。

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 3 个文档；全模块 79 个 `.cj` + 43 个 `.md`）
- **基线**：工作区快照（无 diff）。三个文件最后提交 `7de0791bd`（2026-11-22，`feat(f_excel): OPC 包生成复用单个 XML 部件缓冲`），`git status f_excel` 干净，全部按「存量」计
- **审查重点**：README / 设计文档与实现的一致性；读写语义、共享字符串与样式表边界、内存与资源释放的文档口径；文档层面的重复与残留
- **报告版本**：v1

## 发现

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

## 优化可行性方案

本部分为文档，未提出性能/内存改造方案。文档中出现的性能结论（`README.md:523` 的 3 MB / 29 MB、设计 §9.3 的耗时预估）均无可复核基线，已移入「待验证假设」，不构成本轮方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 「稠密数值表 100 万格 RSS 增量约 3 MB；稀疏/混合表约 29 MB」在当前实现下仍成立 | `f_excel/README.md:523` | 测量口径（RSS 还是 `getUsedHeapSize`）、SDK 版本、构建选项、表形状 | 固定 SDK + `-O2`，分别造 100 万格稠密数值表与 1% 密度稀疏表，读前/读后各采 5 次 RSS 与 `getUsedHeapSize()`，取中位数与离散度 |
| 2 | `sharedStringsIndex=true` 的 open 峰值等于一份完整解压的 `sharedStrings.xml` | `f_excel/src/SharedStringIndex.cj:45-48`、`src/ExcelSheetStream.cj:229-235` | 峰值倍数（相对部件大小） | 造 10 MB / 100 MB 两档 `sharedStrings.xml`，`open` 前后采样 RSS 与分配量，分别测 `sharedStringsIndex` 开/关 |
| 3 | 设计 §9.3 的耗时预估（1 万行 / 10 万行 × 10 列：100~300 ms / 1~3 s）仍可作为容量规划依据 | `doc/f_excel模块设计.md:2641-2653` | 实测耗时与机器规格 | `cjpm bench -O2` 跑流式/整文档两条通道，各 5 轮取中位数；记录 CPU 型号与核数 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_excel.part1.txt` 一一对应，共 3 行。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/README.md` | .md | ✅ | 全文 552 行；命中「M1 能力表口径」「theme1 缺口」「loadRowHeight」「spool 临时文件」「sharedStrings 峰值」「其他公开 API」「线程安全」「富文本重复」「测试数」9 条 |
| 2 | `f_excel/README_en.md` | .md | ✅ | 全文 567 行；命中「Known gaps 整节过期」（主问题）与「其他公开 API 同错」 |
| 3 | `f_excel/doc/f_excel模块设计.md` | .md | ✅ | 全文 3069 行；命中「§2.2/§7.4/§7.6 API 与值模型」「选项与样式上限」「sharedStrings 索引口径」「§5.5.4 残留」「数字不一致」；历史章节（§14–§17）按「实施记录」性质核对，不要求与当前实现逐字一致，但 §2/§7 的契约声明仍按对外文档审 |

合计：`.cj` 0 个 / `.md` 3 个 / 共 3 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 10 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分的三个文件都停留在「写完即弃」的状态：代码已经走到 M4，文档还停在 M1/M2 的交叉口。

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
