# f_excel 模块审查报告

> **模块第 3/8 部分**（本报告只覆盖 `files/f_excel.part3.txt` 列出的 20 个文件，全部为 `doc/spec/` 下的 `.md`：`implement-f-excel-m2` 尾部 3 个、`implement-f-excel-m3` 8 个、`implement-f-excel-m4` 5 个、`reuse-package-writer-buffer` 4 个。`.cj` 源码与 `README*.md` 由第 1、2 部分覆盖；本部分只为核对文档承诺而引用源码行号，不计入覆盖。编号在本部分内独立，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 0 个 `.cj`，20 个 `.md`；模块共 79 `.cj` + 43 `.md`）
- **基线**：工作区快照（`HEAD` 工作区，无 diff ⇒ 全部问题记「存量」）
- **审查重点**：Excel 读写正确性、共享字符串/样式表边界、OOM、资源释放、死代码、重复逻辑、存量 BUG；本部分实际内容为 M2/M3/M4 与 OPC 缓冲复用的 OpenSpec 规格、任务、验收与设计文档，落点是 §13 文档一致性 / §14 功能完备性
- **报告版本**：v1（第 3/8 部分）

## 发现

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

## 优化可行性方案

本部分文件全部为 `doc/spec/**` 规格与验收文档，不含运行时代码，因此不产出堆内存 / CPU 优化方案（§7 / §8 记 0 条）。文档侧可执行的改进已并入上面各条「建议」。

## 待验证假设

> 没有性能测试数据支撑的猜测。不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 稀疏/混合表 100 万格 29 MB 的结论可能已过时（`CellStore` 在 `05ae1e96b` 之后仍有改动可能） | `f_excel/doc/spec/implement-f-excel-m3/verification.md:23` | 测量环境（SDK 版本、`-O2`、机器、轮次中位数）、口径（RSS 增量 vs `getUsedHeapSize`）、是否含索引结构 | 固定 100 万格稀疏夹具，`cjpm bench -O2` + 每轮前后 RSS/堆采样，跑 5 轮取中位数 |
| 2 | 缓冲复用"少分配 4 次 / 每带图 sheet 再省 3 次"缺少实测支撑，`Package_bench` 结果未落进任何文档 | `f_excel/doc/spec/reuse-package-writer-buffer/proposal.md:47`、`tasks.md:47` | 复用 vs 新建两条路径的耗时与分配量（中位数、离散度） | `cd f_excel && cjpm bench -O2`，取 `benchSevenPartsReused/Fresh`、`benchStylesReused/Fresh` 中位数并记录到 tasks 5.3 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/doc/spec/implement-f-excel-m2/specs/f-excel-styles/spec.md` | .md | ✅ | 见 #1、#2、#3 |
| 2 | `f_excel/doc/spec/implement-f-excel-m2/tasks.md` | .md | ✅ | 见 #11、#13 |
| 3 | `f_excel/doc/spec/implement-f-excel-m2/verification.md` | .md | ✅ | 见 #1、#2、#3 |
| 4 | `f_excel/doc/spec/implement-f-excel-m3/design.md` | .md | ✅ | 见 #6、#14 |
| 5 | `f_excel/doc/spec/implement-f-excel-m3/ods-assessment.md` | .md | ✅ | 与 §6 结论自洽（40–60 人日、暂不实现），无问题 |
| 6 | `f_excel/doc/spec/implement-f-excel-m3/proposal.md` | .md | ✅ | 目标与 design 一致；"140 个函数"是 M2 基数，与 M2 verification 的 143 有 3 个差额，属历史口径，未单列 |
| 7 | `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-formula-ext/spec.md` | .md | ✅ | 见 #4 |
| 8 | `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-ods/spec.md` | .md | ✅ | 与 ods-assessment 结论一致，无问题 |
| 9 | `f_excel/doc/spec/implement-f-excel-m3/specs/f-excel-scale/spec.md` | .md | ✅ | 见 #5、#6 |
| 10 | `f_excel/doc/spec/implement-f-excel-m3/tasks.md` | .md | ✅ | 见 #5、#6、#14 |
| 11 | `f_excel/doc/spec/implement-f-excel-m3/verification.md` | .md | ✅ | 见 #5、#6、#10、#14 |
| 12 | `f_excel/doc/spec/implement-f-excel-m4/design.md` | .md | ✅ | 见 #8、#12 |
| 13 | `f_excel/doc/spec/implement-f-excel-m4/proposal.md` | .md | ✅ | API 清单与代码一致（`Worksheet.matchedRules`/`addConditionalFormat`/`evaluateCf` 位置见 #7） |
| 14 | `f_excel/doc/spec/implement-f-excel-m4/specs/f-excel-conditional-format/spec.md` | .md | ✅ | 见 #7、#8、#12 |
| 15 | `f_excel/doc/spec/implement-f-excel-m4/tasks.md` | .md | ✅ | 见 #7、#13 |
| 16 | `f_excel/doc/spec/implement-f-excel-m4/verification.md` | .md | ✅ | 见 #7、#12 |
| 17 | `f_excel/doc/spec/reuse-package-writer-buffer/design.md` | .md | ✅ | 见 #9；其余（D1–D7、测试设计）与代码 `PackageWriter.cj:81-124`、`StylePool.cj:124-128` 一致 |
| 18 | `f_excel/doc/spec/reuse-package-writer-buffer/proposal.md` | .md | ✅ | 与 design 一致；"少 4 次分配"与自身 832 KiB 表格的 5 处缓冲略有不符，并入待验证假设 #2 |
| 19 | `f_excel/doc/spec/reuse-package-writer-buffer/specs/excel-opc-package/spec.md` | .md | ✅ | 与实现一致（单缓冲、clear、视图消费语义） |
| 20 | `f_excel/doc/spec/reuse-package-writer-buffer/tasks.md` | .md | ✅ | 分支名前后不一致（标题 `feature/reuse-package-writer-buffer` vs 0.1 `feature/reuse-f-excel-buffers`），并入 #13 同类问题；bench 数据缺失见待验证假设 #2 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分结论集中在"规格—实现—验收"三者的漂移，而不是代码本身的质量问题：20 份文档里，`reuse-package-writer-buffer` 的设计与实现基本对齐（仅数据流图把视图写成拷贝，属误导性错误但实现正确），M3/M4 的归档文档则存在多处"承诺了但没做到、验收却写全部完成"的情况——`ExcelDocument.setStyle`、`CalcReport.unsupportedFunctions`、`StyleOverridesNumberFormat`、`SpoolForLazy` 四个符号在代码里完全不存在，`maxCellStyles` 在整文档写出路径上不可配，M3 的 29 MB 与 20 MB 目标、5 条门禁只测 1 条却被判"全部达标"，M4 的 `timePeriod`/`aboveAverage` 求值与 `priority` 写回顺序也没兑现。

阻塞项建议按"会不会骗到使用者"排序：先修 #6（门禁口径，否则下游会按错误的容量假设上生产）与 #5（临时文件泄漏，长期服务会被写满 `/tmp`），再修 #1/#3/#4（对外契约缺失或不可达），最后处理 #2/#7/#8/#9 这类语义与告警层面的偏差。轻微项（#10–#14）可在下次动这些目录时顺手清理，其中 #10、#14 会让归档状态和内部结构读不出来，值得优先于纯文字项。

存量共 14 条（一般 9 + 轻微 5），是否纳入修复、哪些按"改文档"结案，待用户决定。
