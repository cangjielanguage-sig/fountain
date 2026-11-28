# f_excel 模块审查报告（模块第 5/8 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 20 个源文件，全模块 79 个 `.cj` + 43 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x` 工作区，无 diff 基线；本部分全部结论按「存量」记录）
- **审查重点**：Excel 读写正确性、共享字符串 / 样式表边界、OOM、资源释放、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本文件是 `f_excel` 第 5 部分的**分报告**，只统计本部分文件；模块级报告由主 Agent 合并生成）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `cfThreshold` 的复制+插入排序是条件格式求值的主要耗时 | `f_excel/src/CfEval.cj:247-288` | 自耗时占比（`cjprof` report 中该函数 self%） | `cjprof record` 跑 1000×10 区域、3 档 iconSet 的 `matchedRules` 全表遍历，输入 1 万格 |
| 2 | `CellStore` 逆序/随机行序写入的搬移是装载瓶颈 | `f_excel/src/CellStore.cj:75-92` | 20 万格逆序写入耗时与 `memmove` 占比 | `cjpm bench -O2` 对比升序/逆序写入；`cjprof` 看 `ByteColumn.insert` |
| 3 | `UNIQUE`/`SORT` 在 1 万行以上成为用户可见延迟 | `f_excel/src/DynamicArrays.cj:101-145` | 1k/10k/100k 行的耗时曲线 | `cjpm bench` 单函数基准，取中位数与 P95 |
| 4 | `rangeValue` 物化大区域是 `recalculate` 的内存峰值来源 | `f_excel/src/Evaluator.cj:89-116` | 峰值 `getUsedHeapSize()` 与 RSS 增量 | 10 万行×100 列数值表跑 `SUM(A:A)` / `SUMPRODUCT`，多轮记录峰值 |
| 5 | `lookupFunction` 的 350 分支 `match` 在大量小公式场景有可观分派开销 | `f_excel/src/FunctionRegistry.cj`（本部分外，`Evaluator.cj:66` 调用） | 每公式调用次数与分派自耗时 | `cjprof record` 跑 10 万格简单公式（`=A1+1`），看字符串比较与 `lookupFunction` 自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/src/CalcFunctionsStatTextExt.cj` | .cj | ✅ | `DOLLAR/FIXED`、`Inf` 文本化、`SHEET(S)`、`LEFTB`、`Int64` 越界、`WIDECHAR/ASC`、`TEXTSPLIT`、`PERCENTRANK` |
| 2 | `f_excel/src/CalcFunctionsTextDate.cj` | .cj | ✅ | `TEXT` 的 `mm`/大写问题、`Int64` 越界、错误展开样板 |
| 3 | `f_excel/src/CalcValue.cj` | .cj | ✅ | `Inf` 文本化、`serialToDateTime` 死代码、数值文本化重复 |
| 4 | `f_excel/src/CellRef.cj` | .cj | ✅ | `CellRef(0,0).toString()` 抛异常（轻微）；解析边界核对通过 |
| 5 | `f_excel/src/CellRef_test.cj` | .cj | ✅ | 覆盖列映射/parse 全表，未见缺测 |
| 6 | `f_excel/src/CellStore.cj` | .cj | ✅ | 稠密块宽度缺陷（严重）与槽位泄漏（一般）核心文件 |
| 7 | `f_excel/src/CellValue.cj` | .cj | ✅ | 数值文本化重复逻辑 |
| 8 | `f_excel/src/CellValue_test.cj` | .cj | ✅ | 类型语义用例充分 |
| 9 | `f_excel/src/CfEval.cj` | .cj | ✅ | `cfThreshold` 性能候选、`cfRuleHit` 死参数 |
| 10 | `f_excel/src/ConditionalFormat.cj` | .cj | ✅ | 名字表 / `==` 重复逻辑 |
| 11 | `f_excel/src/DateFormat.cj` | .cj | ✅ | serial 60 / 1904 基准核对通过 |
| 12 | `f_excel/src/DateSerial.cj` | .cj | ✅ | `utcDayNumber` 整除取整核对通过（均为零点整倍数） |
| 13 | `f_excel/src/Date_test.cj` | .cj | ✅ | 日期用例覆盖 serial 0/59/60/61 与 1904 |
| 14 | `f_excel/src/DependencyGraph.cj` | .cj | ✅ | `add` 不清旧依赖 + 泄漏内部列表；`cycles` O(n²) |
| 15 | `f_excel/src/DependencyGraph_test.cj` | .cj | ✅ | 未覆盖"同格重复 add" |
| 16 | `f_excel/src/DynamicArrays.cj` | .cj | ✅ | `FILTER` 列筛选、`UNIQUE` 键混淆、`Int64` 越界、O(n²) 结构 |
| 17 | `f_excel/src/Eager_test.cj` | .cj | ✅ | 覆盖懒加载跳过坏表；未覆盖临时文件清理 |
| 18 | `f_excel/src/Evaluator.cj` | .cj | ✅ | `rangeValue` 物化上限、`Int64` 越界下游、§4 递归 |
| 19 | `f_excel/src/ExcelDocument.cj` | .cj | ✅ | `renameSheet` 丢数据、临时文件、死字段/不可达分支、告警 kind 语义、名字长度校验 |
| 20 | `f_excel/src/ExcelDocument_test.cj` | .cj | ✅ | 改名用例只测空表，未能暴露 `renameSheet` 丢数据 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（`files/f_excel.part5.txt` 20 行一一对应）。
交叉核对用到的 `README.md` / `README_en.md` / `doc/f_excel模块设计.md` 属于本模块其他部分，只作为"承诺源"引用，不计入本部分覆盖。

## 覆盖自检

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

## 模块统计

> 仅统计本部分（`f_excel` 第 5/8 部分）的 20 个文件。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 15 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 4 |

存量缺陷 23 条（2 严重 / 15 一般 / 6 轻微，全部为存量；另 5 条 CPU/堆内存优化方案不计入缺陷），是否纳入修复待用户决定；本报告不替用户拍板。

## 总评

本部分（求值器 + 单元格存储 + 文档模型 + 条件格式求值 + 统计/文本函数）整体设计清晰：`CalcValue`/`CellValue` 的职责分界、日期序列号的 1900/1904 双基准、`CellStore` 的紧凑列式表示都是经过思考的取舍，注释与实现基本一致，`serial 60`、`usedBounds` 裁剪、`SEQUENCE` 上限这类边界都处理到了。

风险集中在两处**会静默丢数据**的地方，建议作为阻塞项：`ExcelDocument.renameSheet` 直接丢弃整表内容（一行就能修），以及 `CellStore` 稠密块宽度只按首行定型，导致"首行较短、次行更长"的纯数值表尾部单元格读不出来（`get` 缺一次 `flushDense` 回退）。其次是求值路径的错误处理范式问题：`Int64(Float64)` 越界、`String.fromUtf8` 半个字符、`formatNumber` 遇 `Inf/NaN` 都会把异常抛出 `CalcEngine.evaluate`，而 Excel 语义要求返回 `#VALUE!`/`#NUM!`；这类问题在"用户上传的 xlsx 里带公式"的场景下必然出现，建议统一在 `Evaluator.eval` 的 `Call` 分支加兜底。

其余（`FILTER` 列筛选失效、`TEXT` 的 `mm` 当月份、`DOLLAR/FIXED` 负数格式、`UNIQUE` 类型混淆、`SHEETS` 恒 1、`LEFTB` 半字符）都是"能跑但结果不对"的存量缺陷，修复面小、验证成本低，可以排进同一批。性能方面本部分没有任何实测数据，`cfThreshold` 的重复排序是唯一有明确复杂度证据的热点候选，先按「待验证假设」补 `cjprof` 数据再决定是否改动。
