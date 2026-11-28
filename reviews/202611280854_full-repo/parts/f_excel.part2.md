# f_excel 模块审查报告

> **模块第 2/8 部分**（分报告）。本部分 20 个文件**全部是 `doc/spec/**` 规格文档**
> （`f-excel-images` 4 个 + `implement-f-excel-m1` 12 个 + `implement-f-excel-m2` 4 个），**无 `.cj`**。
> 同模块的 `.cj` 与其余文档见其他分报告，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 20 个 `.md`；全模块 79 个 `.cj` + 43 个 `.md`）
- **基线**：工作区快照（`git status f_excel` 干净，无 diff）；三份 spec 最后提交分别为
  `793bc0e85`（images，2026-10-31）、`17fde7834`（m1，2026-10-30）、`ee178eb13`（m2，2026-10-31），
  全部按「存量」计
- **审查重点**：规格 ↔ 实现一致性、承诺未落地、上限/边界口径、OOM 与内存承诺、
  文档内部漂移（本部分专项由文件类型决定：这一部分没有代码可审，正确性/OOM 结论全部靠
  「文档承诺 + 源码取证」双向对齐）
- **报告版本**：v1

## 发现

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

## 优化可行性方案

本部分 20 个文件全是规格文档，**没有可测量的代码路径，也没有 profile / bench 数据**，因此不产出
堆内存 / CPU 优化方案（按 `reviewer.md` 铁律，无基线的性能结论只能写进「待验证假设」）。
上面第 2 条发现的"告警数组随单元格增长"本质是无界容器缺陷（已进「发现」），其修复不依赖性能数据。

## 待验证假设

> 本部分没有性能数据，以下仅为下一轮补数据的清单，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `loadSharedStrings = false` 模式下逐格告警的峰值内存（发现 #2 的量化部分） | `f_excel/src/WorksheetParser.cj:486-497` | 1M 行 × 10 列全 `t="s"` 时的 `warnings().size` 与峰值 RSS | 构造该表跑 `ExcelSheetStream`（`loadSharedStrings = false`），记录 `getAllocatedHeapSize()` / `getUsedHeapSize()` 峰值与告警条数 |
| 2 | 「大表复制」（`RowReader` 直喂 `ExcelWriter`）的真实内存曲线是否与行数无关 | `f_excel/src/ExcelSheetStream.cj:41-100`、`f_excel/src/ExcelWriter.cj:100-160` | 10 万 / 100 万行两档的 RSS 稳态与 GC 次数 | `cjprof record` + 分段计时，`-O2`，同机同输入，取中位数 |
| 3 | `sharedStrings` 全量装载对文本密集型工作簿的常驻内存占比 | `f_excel/src/SharedStringTable.cj:44-171` | 表项数与 `items` + `runSets` 字节量 | 对 100 万条 `<si>` 的样本测 `heapUsed` 前后差，与 `sharedStringsIndex = true` 对照 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_excel.part2.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/doc/spec/f-excel-images/design.md` | .md | ✅ | 图片 API/部件清单与实现一致（`Image.cj`、`PackageWriter.cj:330-424`） |
| 2 | `f_excel/doc/spec/f-excel-images/proposal.md` | .md | ✅ | 与 tasks/实现一致；M1.5 只做写侧如实 |
| 3 | `f_excel/doc/spec/f-excel-images/specs/f-excel-images/spec.md` | .md | ✅ | 三条要求均可在实现中定位；读侧 `imageCount()==0` 成立 |
| 4 | `f_excel/doc/spec/f-excel-images/tasks.md` | .md | ✅ | 8 条全勾；90 用例数与后续 147 用例的演进不冲突（历史记录） |
| 5 | `f_excel/doc/spec/implement-f-excel-m1/baseline.md` | .md | ✅ | 转义结论未标注过期 → 发现 #9 |
| 6 | `f_excel/doc/spec/implement-f-excel-m1/design.md` | .md | ✅ | `SheetRowSink.cj` 不存在（#12）、`count="4"`（#10）、§10.1 占位（#13） |
| 7 | `f_excel/doc/spec/implement-f-excel-m1/proposal.md` | .md | ✅ | 差异 9 与 writer spec 冲突（#8）；`build-warnings.md` 与耗时未落地（#13） |
| 8 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-cell-model/spec.md` | .md | ✅ | 枚举表与 reader spec 对 `SheetSkipped` 口径不一致（#3） |
| 9 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-reader/spec.md` | .md | ✅ | `SheetSkipped`（#3）、三种致命（#4）、`loadSharedStrings`（#2）、31 字符（#6） |
| 10 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-roundtrip/spec.md` | .md | ✅ | testdata / openpyxl 自动化未落地（#5） |
| 11 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-stream-read/spec.md` | .md | ✅ | spool 四级与消息（#11）、`loadSharedStrings` 场景（#2） |
| 12 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-stream-write/spec.md` | .md | ✅ | 构造/行号/状态机/flush 与 `ExcelWriter.cj` 一致 |
| 13 | `f_excel/doc/spec/implement-f-excel-m1/specs/f-excel-writer/spec.md` | .md | ✅ | `stringMode`（#8）、转义归属（#9）、31 字符（#6） |
| 14 | `f_excel/doc/spec/implement-f-excel-m1/tasks.md` | .md | ✅ | 测试文件名失效（#12）、勾选与产物不符（#13） |
| 15 | `f_excel/doc/spec/implement-f-excel-m1/verification.md` | .md | ✅ | 86 用例、openpyxl 一次性人工记录；人工 Excel 项未执行（如实标注） |
| 16 | `f_excel/doc/spec/implement-f-excel-m1/verify.md` | .md | ✅ | 回退校验自洽；测试类名引用有效（`PackageStructure_test` 在 `RoundTrip_test.cj`） |
| 17 | `f_excel/doc/spec/implement-f-excel-m2/design.md` | .md | ✅ | 文件表漂移（#12）、平台分档未实现（#14） |
| 18 | `f_excel/doc/spec/implement-f-excel-m2/proposal.md` | .md | ✅ | 与 M2 实现大体一致（350 函数 ≥ 承诺 140） |
| 19 | `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-formula/spec.md` | .md | ✅ | `evaluate` 返回类型 / `CalcIssue`（#7） |
| 20 | `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-rich-values/spec.md` | .md | ✅ | 富文本写出未平坦化（#1） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分是 `f_excel` 的规格与验收文档，整体质量高于常见"写完就丢"的设计稿：**图片（M1.5）四个文件与实现
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
