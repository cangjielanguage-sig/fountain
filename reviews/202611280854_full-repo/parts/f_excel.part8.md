# f_excel 模块审查报告（第 8/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（79 个 `.cj` + 43 个 `.md`；本部分 8 个 `.cj` / 0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比，全部记「存量」）
- **审查重点**：Excel 读写正确性、共享字符串 / 样式表边界、OOM、资源释放、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（模块第 8/8 部分；本部分文件：`Style_test.cj` / `StylesLite.cj` / `Worksheet.cj` / `WorksheetParser.cj` / `WorksheetParser_test.cj` / `Worksheet_test.cj` / `Writer_test.cj` / `fixtures.cj`）

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `StringGenerator` 每格重建是解析期 GC 压力的主要来源之一 | `f_excel/src/WorksheetParser.cj:352-354` | 分配量（字节）与 GC 次数、占总耗时比例 | 同一份 100 万格表，改前/改后 `getAllocatedHeapSize()` + `cjprof` GC 线程耗时，`-O2` |
| 2 | `mergedRangeAt` 的字符串解析在渲染路径上可观测 | `f_excel/src/Worksheet.cj:400-426` | 函数自耗时占比、每次解析平均耗时 | `cjprof record` 跑 1000×1000 表 + 100 合并区，逐格 `mergedValue` |
| 3 | `rowValues()` 触发 `flushDense` 会把稠密表一次性摊成稀疏，常驻内存随之上升 | `f_excel/src/Worksheet.cj:351-357`、`f_excel/src/CellStore.cj:340-341` | 摊平前后 RSS / `getUsedHeapSize()` 差 | 1000×1000 全数值表先 `range(...)` 再 `rowValues(...)`，多轮记录 RSS（该议题与第 5 部分「稠密/稀疏双表示」同源） |
| 4 | 规则复制 + 插入排序在规则数 > 20 的组上占比可观 | `f_excel/src/Worksheet.cj:203-215` | 排序自耗时、单次 `matchedRules` 耗时随 k 的曲线 | `cjpm bench`，k = 3 / 10 / 50，区域 100 格，取中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/src/Style_test.cj` | .cj | ✅ | 6 个用例：值语义、完整样式往返、自定义格式、去重、池上限、日期自动样式；往返断言缺 family/charset（见轻微条） |
| 2 | `f_excel/src/StylesLite.cj` | .cj | ✅ | `numFmt`/font/fill/border/cellXfs/dxfs 读取；family/charset 读错位置、namedStyle 索引错、`val="0"` 忽略、`codeOf` 死代码 |
| 3 | `f_excel/src/Worksheet.cj` | .cj | ✅ | 稀疏单元格模型 + 合并 + 条件格式 + 图片 + 懒加载；`valuesOfRange` OOM、stopIfTrue 跨组、多段 sqref 平移、`ensureLoaded` 半加载、内部容器外泄、`clearCell` 不对称、`setCellNumber` 死代码 |
| 4 | `f_excel/src/WorksheetParser.cj` | .cj | ✅ | sheet 事件状态机；流式 `maxRows` 失效、富文本累积、`RowData.cells` 无序、local-name-only 匹配、每格 3 个 `StringGenerator` |
| 5 | `f_excel/src/WorksheetParser_test.cj` | .cj | ✅ | SST 5 例 + 解析 11 例；未用 import、SST 类名/文件不符、`maxRows` 只测整文档、`maxCols` 无覆盖 |
| 6 | `f_excel/src/Worksheet_test.cj` | .cj | ✅ | 三种访问形式一致、越界/缺失、计数与行取值、清除与区域、合并取值；未覆盖 `matchedRules`/`addImage`/懒加载 |
| 7 | `f_excel/src/Writer_test.cj` | .cj | ✅ | 数字最短往返、包布局、值往返、空白保留、控制字符、错误码、日期序列、合并位置、输出流不关闭、多 sheet；断言与实现一致 |
| 8 | `f_excel/src/fixtures.cj` | .cj | ✅ | 测试夹具构建器（ContentTypes/rels/workbook/styles/sheet + `buildXlsx`）；只被 `*_test.cj` 使用，随库编译（见轻微条） |

合计：`.cj` 8 个 / `.md` 0 个 / 共 8 个，全部读完（本部分清单无 `.md`）。

## 覆盖自检

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
| 严重 | 1 |
| 一般 | 10 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分覆盖 `f_excel` 的读取模型核心（`Worksheet` + `WorksheetParser`）与样式读写入口（`StylesLite`）。**阻塞项只有一条**：`valuesOfRange` 按 `sqref` 矩形全量物化且没有任何面积上限，一个几百字节的文件即可要求几十 GB 分配，属于"不可信输入直接决定内存规模"，应在下一版本前修掉（加面积上限或改成单趟聚合）。

**排期优先级**：三处"静默失效"类问题排在第二档 —— 流式 `maxRows` 完全不生效、流式富文本随行数累积、`ensureLoaded` 异常后停在半加载状态。它们不会报错，只会在长驻服务里表现为"上限不起作用 / 内存缓慢上涨 / 数据悄悄缺行"，是最难靠使用反馈发现的一类。第三档是读写保真度（family/charset、namedStyle、`val="0"`、`RowData.cells` 升序）与条件格式语义（`stopIfTrue` 跨组、多段 sqref 平移），影响的是"读进来再写出去"的正确性；第四档是封装与工程整洁（内部容器外泄、`fixtures.cj` 进产物、死代码与重复逻辑、测试覆盖缺口）。

代码整体质量中上：稀疏 `CellStore` 的分层、`ParsedSheet`/`RowSink` 的双通道抽象、`StylesLite` 对越界索引的统一降级（`styleAt`/`dxfAt`/`formatId` 一律回默认）都做得克制；`parseSheet` 用 `try/finally` 关解析器，告警文案带 sheet 名，测试对越界 SST、缺行号、非法列引用、1900-02-29 等边界都有覆盖。主要风险集中在"没有上限的按文件内容扩张"和"两条通道行为不一致"这两类结构性问题，而不是散点 bug。

存量共 18 条（严重 1 / 一般 10 / 轻微 7），是否纳入修复由用户在门禁决定；本部分只报不修。合并本模块报告时请按正文的「与其它分部分的重合说明」去重（尤其第 6 部分 #6/#11、第 5 部分 `ensureLoaded` 与 `matchedRules`、第 7 部分 #4、第 3 部分 #7/#8）。
