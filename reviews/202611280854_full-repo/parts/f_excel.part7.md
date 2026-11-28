# f_excel 模块审查报告

> **模块第 7/8 部分**（本报告只覆盖 `files/f_excel.part7.txt` 列出的 20 个文件：写包/读包、共享字符串表与磁盘索引、样式结构与样式池/`styles.xml` 生成、单元格与行模型、富文本、数字格式化，以及 9 个测试 / 1 个基准文件。其余 `.cj` 与全部 `.md` 由同模块其他子轮产出，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 20 个源文件：20 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」；`git blame` 抽检落在 `bc7aaa46b2`(2026-10-30)、`71cfef6187`(2026-10-31)、`87cdb4fa42`(2026-10-31)、`c8f5812abd`(2026-10-31)，均为历史提交）
- **审查重点**：Excel 读写正确性、共享字符串/样式表边界、OOM、资源释放、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 7/8 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `formatNumber` 的 17 次 format/parse 是写出路径的热点 | `f_excel/src/Numbers.cj:43-55` | 自耗时占比、平均尝试次数分布 | 加尝试次数计数；`cjprof record` 跑 `ExcelDocument.write`，输入 100 万数字格（其中 50% 非整数） |
| 2 | 样式去重的线性扫在高样式数下成为瓶颈 | `f_excel/src/StylePool.cj:102-120` | `CellStyle.toString`/`string.equals` 自耗时、样式数分布 | 合成"每行一种样式"的 20 万格文档，`cjprof record` + `cjpm bench -O2` 前后对照 |
| 3 | 索引模式顺序读被系统调用拖慢（每格一次 seek/read） | `f_excel/src/SharedStringIndex.cj:125-165` | 每格平均耗时、syscall 次数 | 1 M 格 sheet 顺序读，分段计时 + 系统调用统计，与全量表模式对照 |
| 4 | 文本格 4 趟扫描造成的分配占写出期分配量的显著比例 | `f_excel/src/SheetXmlWriter.cj:366-434` | 分配量与峰值 RSS 占比 | `cjprof heap` + `getAllocatedHeapSize()`，10 万文本格（1% 为 30 KB 长文本） |
| 5 | `runSets` 的空表与富文本副本是 SST 常驻内存的主要增量 | `f_excel/src/SharedStringTable.cj:139-148` | 常驻堆占比 | 1 M 条非富文本 + 10 万条富文本 SST，加载后 `getUsedHeapSize()` 对照 |
| 6 | 文档写出按 `maxRow` 全量循环，稀疏表（A1 + A1048576）会白跑百万行 | `f_excel/src/PackageWriter.cj:110-120` | 稀疏表写出耗时占比 | 只有两行的文档 vs 紧凑文档，分段计时 `rowValues` 累计耗时 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_excel.part7.txt` 一一对应，20 行。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/src/M3Math_test.cj` | .cj | ✅ | 数学/工程函数用例；`close()` 用绝对误差 `<1e-9`，只覆盖小值域；`registryCoversMathEngList` 断言函数名表长度 62，硬编码易漂移（测试健壮性，不计缺陷） |
| 2 | `f_excel/src/M3Spill_test.cj` | .cj | ✅ | 溢出写回用例；正是它证明引擎会产出 `CellValue.Formula(_, Some(Error("#SPILL!")))`（见 #3） |
| 3 | `f_excel/src/M3StatText_test.cj` | .cj | ✅ | 统计/文本函数用例；与实现一致，未发现断言与实现冲突 |
| 4 | `f_excel/src/M4_test.cj` | .cj | ✅ | 条件格式解析/命中/往返；夹具 `STYLES`(:26-37) 按规范顺序写 `dxfs`，反证 #5；`roundTripPreservesRules` 走自有读侧，测不出 #5 |
| 5 | `f_excel/src/Numbers.cj` | .cj | ✅ | 最短往返十进制串；整数快路径 + 1..17 位 `g` 试错；NaN/Inf 抛 `ExcelException`；见优化方案 [CPU]-3 |
| 6 | `f_excel/src/PackageBuffer_test.cj` | .cj | ✅ | 包部件字节/共享缓冲复用/golden 基线；`bytesViewMustBeConsumedBeforeReuse` 明确了 `ByteBuffer.bytes()` 是视图；golden 用例不含 dxf（见 #5） |
| 7 | `f_excel/src/PackageReader.cj` | .cj | ✅ | workbook/rels 解析、`date1904`、部件缺失告警；`resolvePart` 未做 `..`/百分号解码（轻微，未单列）；关系查找 O(n²) 仅在小规模成立 |
| 8 | `f_excel/src/PackageReader_test.cj` | .cj | ✅ | sheet 名/部件/1904/命名空间前缀/缺 workbook 抛错/缺 rels 告警；与实现一致 |
| 9 | `f_excel/src/PackageWriter.cj` | .cj | ✅ | 整包生成；重复的 `xl()` 助手与 MIME 字面量（#9）；`cells` 每行两次拷贝（优化方案 [堆内存]-1） |
| 10 | `f_excel/src/Package_bench.cj` | .cj | ✅ | `@Bench` 复用/新建缓冲对照 + 整包写；有 `checksum` 防优化，但未覆盖样式去重/数字格式化/索引模式 |
| 11 | `f_excel/src/RichText.cj` | .cj | ✅ | 公开值类型 + `text()` 拼接；`runs` 暴露可变 `ArrayList`（别名风险，内部无共享路径，不判缺陷） |
| 12 | `f_excel/src/RoundTrip_test.cj` | .cj | ✅ | 七种值类型/文本边界/数值精度/1904/多 sheet 合并 + 包结构一致性；缓存值只测 `Number`（见 #1） |
| 13 | `f_excel/src/RowData.cj` | .cj | ✅ | 读写共用行模型；`height` 读侧 `WorksheetParser.cj:623` 产出、写侧 `SheetXmlWriter.cj:77-80` 消费，闭环成立 |
| 14 | `f_excel/src/SharedStringIndex.cj` | .cj | ✅ | 磁盘索引；#2/#7 详见发现，优化方案 [CPU]-2 |
| 15 | `f_excel/src/SharedStringReuse_test.cj` | .cj | ✅ | 仅覆盖 64 KB 长串跨底层读；未覆盖 `<si/>`/CDATA（见 #2） |
| 16 | `f_excel/src/SharedStringTable.cj` | .cj | ✅ | 全量 SST 解析；`<rPh>` 跳过、rich run 保留；与索引实现语义不一致（#2）；`size` 仅测试引用（可见性建议，不算死代码） |
| 17 | `f_excel/src/SheetXmlWriter.cj` | .cj | ✅ | 单元格→XML 事件；#1/#3/#6/#10 详见发现 |
| 18 | `f_excel/src/StreamRead_test.cj` | .cj | ✅ | 流式读行/关闭语义/告警时机/乱序行；与实现一致 |
| 19 | `f_excel/src/Style.cj` | .cj | ✅ | 公开样式值类型；`namedStyle` 悬空（#4）、去重键用 `toString`（#12） |
| 20 | `f_excel/src/StylePool.cj` | .cj | ✅ | 样式池 + `styles.xml` 生成；#5/#8/#11 与优化方案 [CPU]-1 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量 12 条，是否纳入修复待用户决定。

## 总评

本部分代码的工程质量整体偏高：`XmlWriter` 事件式写出、样式池按值去重、`PackageBuffer` 共享缓冲、`SpreadsheetML` 上限校验（32767/8192/64000）都做得比较克制，测试也覆盖了字节级 golden、缓冲复用、关闭语义这些容易出问题的地方。

主要风险集中在两条"读/写与规范对不齐"的链路上：

1. **写出类型语义**（#1/#3/#10）：`c@t` 只对直接值生效，公式缓存值一律按数字写，错误值白名单又比引擎自己的错误词表窄。"引擎算得出、文件写不对"是公开主路径上的阻塞项，建议优先修，且修完要补文本/布尔/错误缓存三条 round-trip。
2. **SST 索引的结构假设**（#2/#7）：为了省内存改用字节级扫描，但没有覆盖自闭合标签与 CDATA，一旦命中就是静默错值，且与全量表实现语义分叉。这条可以选择"用 XML 解析器重做索引"或"在索引模式明确限制输入并告警"，但不宜维持现状。
3. **样式表规范一致性**（#4/#5/#11）：`dxfs` 顺序、`namedStyle` 悬空、`apply*` 判据不全，都是"用 Excel 打开才暴露"的问题，自有读侧因为宽容所以测不到，属于需要补外部解析器/人工打开验证的盲区。

轻量项（#8/#9/#12）不影响正确性，可随样式池的 map 化优化一起处理。性能与内存方面的 5 条方案都还停留在复杂度与分配量推算，缺 `-O2` 基线与 `cjprof` 数据，按规则只作下一轮补数据的清单。
