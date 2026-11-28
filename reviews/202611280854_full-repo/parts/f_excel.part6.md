# f_excel 模块审查报告

> **模块第 6/8 部分**（本报告只覆盖 `files/f_excel.part6.txt` 列出的 20 个文件：Excel 异常/选项/流式读写/写入口、公式词法·语法·AST·平移、函数注册表、图片，以及对应的 8 个测试文件。其余 `.cj` 与全部 `.md` 由同模块其他子轮产出，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 20 个源文件：20 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」；`git blame` 抽检落在 `27c3f80d`/`ed6ecc68`/`71cfef61`/`793bc0e8`/`148f06a7`，均为 2026-10-30~31 的历史提交）
- **审查重点**：Excel 读写正确性、共享字符串/样式表边界、OOM、资源释放、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 6/8 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `lookupFunction` 的每次大写 + 闭包分配在 recalculate 中占可观 GC 时间 | `f_excel/src/FunctionRegistry.cj:38-412` | 分配次数与 GC 时间占比 | `cjprof record` 跑 10 万格 × 每格 3 函数的 recalculate，看 `lookupFunction` self time 与分配采样 |
| 2 | `criteriaMatch` 的数组分配 + 双重 `parseNumberText` 是 COUNTIF/SUMIF 的主要开销 | `f_excel/src/FunctionRegistry.cj:519-556` | 单格耗时与 100 万格总耗时 | 分段计时：`COUNTIF(A1:A1000000,">0")` 前后插桩，对照“数组提常量”补丁 |
| 3 | `joinText` 的 O(k²) 在 TEXTJOIN 大数组下占比显著 | `f_excel/src/FormulaAst.cj:139-150` | 段数-耗时曲线 | `cjpm bench -O2`，k = 10/100/1000/10000 四档 |
| 4 | SST 峰值与解压大小严格线性，且 `sharedStringsIndex` 不降低峰值 | `f_excel/src/ExcelSheetStream.cj:229-241` | 解压大小 vs 峰值曲线 | 造 50/100/200 MB sharedStrings 各一份，采样 `getUsedHeapSize()` 峰值 + RSS |
| 5 | `DependencyGraph.add` 的 `list.contains` 在 65 536 依赖时 O(n²) 明显 | `f_excel/src/DependencyGraph.cj:49-56` | 建图耗时 vs 依赖数 | 单格引用整列/大区域，计时 `buildGraph()`；对象为 `HashSet` 的对照实现 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/src/ExcelException.cj` | .cj | ✅ | 告警枚举与异常；见 #4（3 个 kind 无生产点）、#12（相等实现重复） |
| 2 | `f_excel/src/ExcelOptions.cj` | .cj | ✅ | 见 #10（`loadRowHeight` 未接线）、#14（注释残留/平台默认值） |
| 3 | `f_excel/src/ExcelSheetStream.cj` | .cj | ✅ | 见 #3、#4、#5、#6、#11；`open/rows/close` 语义与 README 一致 |
| 4 | `f_excel/src/ExcelWriter.cj` | .cj | ✅ | 见 #2（字节数当字符数）、#9（失败路径无释放） |
| 5 | `f_excel/src/ExcelWriter_test.cj` | .cj | ✅ | 7 个用例覆盖顺序/校验/往返；未覆盖 31 字符边界与失败路径资源 |
| 6 | `f_excel/src/FormulaAst.cj` | .cj | ✅ | 见 #8（大区域截断）、#12（`joinText`/枚举相等）、#14（注释矛盾） |
| 7 | `f_excel/src/FormulaLexer.cj` | .cj | ✅ | 词法边界（数字/转义引号/`#` 错误值）实现正确；见 #12（引号扫描/`runesToString` 重复） |
| 8 | `f_excel/src/FormulaParser.cj` | .cj | ✅ | 见 #1（递归无上限）、#13（裸列名宽容、行号截断）；优先级表与 Excel 一致（`-2^2=4`、`^` 左结合、`%` 后缀） |
| 9 | `f_excel/src/FormulaShift.cj` | .cj | ✅ | 见 #7（表名前缀被平移）、#12（`runesText`/引号扫描重复） |
| 10 | `f_excel/src/Formula_test.cj` | .cj | ✅ | 覆盖词法/优先级/区域/循环/共享公式平移；未覆盖深嵌套与“表名像单元格引用”的平移 |
| 11 | `f_excel/src/FunctionExt_test.cj` | .cj | ✅ | 数值断言带容差，注册覆盖用例有效；未发现问题 |
| 12 | `f_excel/src/FunctionRegistry.cj` | .cj | ✅ | 见 #11（`scalarsOf` 死代码）、优化方案 A/B；函数表与 6 个名单双份维护（→ 假设 1） |
| 13 | `f_excel/src/Function_test.cj` | .cj | ✅ | 核心 62 个函数的注册/求值覆盖较完整；未发现问题 |
| 14 | `f_excel/src/Image.cj` | .cj | ✅ | 见 #11（`contentType` 死代码）、#12（`extension`/`toString` 重复）；`readImage` 全量读入 → 方案 A |
| 15 | `f_excel/src/Image_test.cj` | .cj | ✅ | 部件名/relationship/锚点断言到位，回读丢图与 README 缺口一致；未发现问题 |
| 16 | `f_excel/src/M2d_test.cj` | .cj | ✅ | 时长格式、富文本读写断言有效；未发现问题 |
| 17 | `f_excel/src/M3CellStore_test.cj` | .cj | ✅ | 见 #16（350 断言靠名单相加） |
| 18 | `f_excel/src/M3DistDb_test.cj` | .cj | ✅ | 见 #15（`INFO("system")=="Linux"` 平台绑定） |
| 19 | `f_excel/src/M3DynFin_test.cj` | .cj | ✅ | 动态数组/财务/日期断言有效；未发现问题 |
| 20 | `f_excel/src/M3Index_test.cj` | .cj | ✅ | 索引与全量表逐格对照，是 SST 边界唯一有效用例；未发现问题 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（`wc -l` 合计 4 115 行）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 9 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分代码整体质量中上：流式读写的主干（`ExcelWriter` 顺序校验 + 失败即锁死、`RowReader` 拉模式自动收尾、`ExcelSheetStream` 的 `close` 幂等与 spool 清理）设计清楚；公式优先级表、共享公式平移、函数注册表的边界用例覆盖也明显好于一般模块。

真正的阻塞项只有一个：**#1 公式语法递归无深度上限**，畸形/第三方公式可直接把进程打崩，且读取侧其余路径都在做“宽容降级”，这里缺少护栏显得突兀，应在合并前修掉。

其次需要排期的是三条“静默失效”类问题：**#3** 失败路径泄漏 fd 与临时文件、**#4** 缺 styles 时无告警（`StylesMissing` 等三个 kind 形同虚设）、**#5** SST 全量物化的峰值内存——它们都不会报错，只会在长驻服务里表现为句柄/内存缓慢上涨或数据悄悄退化成数字，属于最难靠使用反馈发现的一类。#2（中文 sheet 名被拒）、#7（表名被平移）、#10（`loadRowHeight` 无效）都是单点可修的小缺陷。

轻微项集中在可维护性：4 处死代码（尤其 `spoolFile` 这个“假生命周期字段”）、4 类重复实现（含枚举相等三套写法带来的 `x != x` 隐患）、3 处注释与实现不符，以及两条测试可信度问题（`INFO("system")=="Linux"` 平台绑定、350 个函数的假断言）。

性能部分本轮没有 bench / cjprof 数据，因此全部按「待验证假设」处理，未写成结论：可疑点是每次函数调用重建注册项（closure 分配）、条件匹配的逐格数组分配与双重解析、`joinText` 的字符串平方级拼接 —— 都是“看起来热”的线索，需用 `cjpm bench -O2` 与 `cjprof` 补基线后才能决定是否进修复清单。

**存量 16 条（严重 1 / 一般 9 / 轻微 6），是否纳入修复待用户决定。**
