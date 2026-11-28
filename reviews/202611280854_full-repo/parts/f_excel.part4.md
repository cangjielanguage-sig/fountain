# f_excel 模块审查报告

> **模块第 4/8 部分**（本报告只覆盖 `files/f_excel.part4.txt` 列出的 11 个 `.cj`：`Array_test.cj`、`CalcEngine.cj`、`CalcFunctionsDbMisc.cj`、`CalcFunctionsDist.cj`、`CalcFunctionsDynFin.cj`、`CalcFunctionsExt.cj`、`CalcFunctionsExt2.cj`、`CalcFunctionsLogic.cj`、`CalcFunctionsLookup.cj`、`CalcFunctionsMath.cj`、`CalcFunctionsMathEng.cj`。其余 68 个 `.cj` 与 43 个 `.md` 由同模块其他子轮产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_excel`（本部分 11 个 `.cj` + 0 个 `.md`，共 11 个文件 / 5337 行）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」；抽查 `git blame` 命中同一导入提交 `9c95dacbe2 2026-10-31`）
- **审查重点**：本轮指定「Excel 读写正确性、共享字符串/样式表边界、OOM、资源释放、死代码、重复逻辑、存量 BUG」。本部分不含 `.xlsx` 读写与共享字符串/样式表代码（那些在 `PackageReader` / `SharedStringTable` / `StylePool` 等文件，属其他子轮），实际覆盖的是**公式计算引擎 + 函数实现层**：求值正确性、跨函数契约、边界与异常、无界循环/分配、死代码、重复逻辑。
- **报告版本**：v1（第 4/8 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能数据支撑的猜测，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 插入排序（`MEDIAN`/`LARGE`/`SORT`/`SORTBY`）在大区域上占公式耗时主要部分 | `f_excel/src/CalcFunctionsExt.cj:36-44`、`f_excel/src/CalcFunctionsMath.cj:439-447` | 自耗时占比、n 拐点 | `cjprof record` 跑 `MEDIAN(A1:A100000)` 与 `LARGE(...,5)`，各 100 次，报 self time |
| 2 | `SUMIFS`/`COUNTIFS` 的循环内物化是真实热点（静态复杂度已确认，缺占比） | `f_excel/src/CalcFunctionsMath.cj:259-267`、`:380-383` | 端到端耗时占比 | 1000×50 区域、1/3 组条件，分段计时对比"循环外物化"改写版 |
| 3 | `CalcEngine` 每次 `evaluate` 重建容器的分配开销在条件格式逐格求值场景下显著 | `f_excel/src/CalcEngine.cj:117-122` | 分配量/GC 次数 | `cjprof heap` 跑 10 万格 `matchedRules`，统计分配字节与 GC 暂停 |
| 4 | `EXPAND` / 大 `VSTACK` 的结果数组是主要峰值内存来源 | `f_excel/src/CalcFunctionsDynFin.cj:173-185`、`:188-218` | 峰值 RSS 与结果规模关系 | 固定 used range，逐步放大 `EXPAND` 目标行列，记录 `getUsedHeapSize()` 与 RSS |
| 5 | 分布函数累积循环（#13）在正常输入（x ≤ 1000）下耗时占比不高，风险集中在恶意大输入 | `f_excel/src/CalcFunctionsDist.cj:185-192` 等 5 处 | x 与单次耗时曲线 | 对 x = 10/100/1000/10000 计时，确认拐点后再定上限 |

## 文件覆盖

> 与 `files/f_excel.part4.txt` 一一对应，11 行。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_excel/src/Array_test.cj` | .cj | ✅ | 3 个用例覆盖数组广播/FILTER/SORT+UNIQUE+SEQUENCE；未覆盖 `EXPAND`/`VSTACK`/`TAKE`/`SUBTOTAL` 等，属测试覆盖建议（不计问题） |
| 2 | `f_excel/src/CalcEngine.cj` | .cj | ✅ | 求值入口/环检测/spill/报告；见 #18、优化方案 3 |
| 3 | `f_excel/src/CalcFunctionsDbMisc.cj` | .cj | ✅ | 数据库/AGGREGATE/CONVERT/INFO/CELL；见 #1、#8、#10、#19、#24、#25 |
| 4 | `f_excel/src/CalcFunctionsDist.cj` | .cj | ✅ | 分布函数；见 #11、#12、#13、#20 |
| 5 | `f_excel/src/CalcFunctionsDynFin.cj` | .cj | ✅ | 动态数组/日期/财务扩展；见 #3、#4、#5、#6、#7、#9、#10、#17、#19、#20、#22、#23 |
| 6 | `f_excel/src/CalcFunctionsExt.cj` | .cj | ✅ | 统计/查找/文本扩展；见 #2、#7、#10、#23 |
| 7 | `f_excel/src/CalcFunctionsExt2.cj` | .cj | ✅ | 数学/日期/财务扩展；见 #4、#5、#6、#9、#15、#16、#19 |
| 8 | `f_excel/src/CalcFunctionsLogic.cj` | .cj | ✅ | IF/IFS/AND/OR/XOR/IFERROR/SWITCH/IS*；未发现缺陷（IFS 多余实参当默认值属轻微口径差异，未单列） |
| 9 | `f_excel/src/CalcFunctionsLookup.cj` | .cj | ✅ | VLOOKUP/INDEX/MATCH；见 #7 |
| 10 | `f_excel/src/CalcFunctionsMath.cj` | .cj | ✅ | SUM/ROUND/条件聚合；见 #14、#21、#23 |
| 11 | `f_excel/src/CalcFunctionsMathEng.cj` | .cj | ✅ | 三角/组合/进制/工程；见 #9、#20 |

合计：`.cj` 11 个 / `.md` 0 个 / 共 11 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 7 |
| 一般 | 11 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 25 条，是否纳入修复待用户决定（本部分全部为存量，无本次改动引入项）。

## 总评

计算引擎的骨架是好的：错误优先传播（`firstError`）、按格 memo、环检测与 `#CIRC!` 上报、`recalculate(writeBack)` 的 spill 冲突处理都有明确设计，`CalcEngine` 的注释也写清了"默认不自动重算"这一关键语义。问题集中在**函数实现层对输入的不信任不足**：7 条严重项里有 6 条是"合法/半合法公式直接打到未校验路径"——`CELL` 少一个实参就索引越界（#1）、`SUBSTITUTE` 遇中文就切坏 UTF-8（#2）、`EXPAND` 无上限分配（#3）、`WORKDAY` 遇负序列号死循环（#5）、日期函数把超范围序列号直接丢给 `DateTime.ofEpoch`（#6）、`VSTACK` 锯齿数组让 `INDEX` 越界（#7），而这些异常在 `Evaluator.eval` → `CalcEngine` 链路上没有任何 `try/catch` 兜底，单条公式即可中断整次重算。这些是阻塞项，建议先做"求值边界统一兜底 + 输入范围校验"两件事，再谈函数语义。

其次是 `NETWORKDAYS.INTL`/`WORKDAY.INTL` 把 weekend 当节假日（#4）：这是静默错值，比崩溃更难发现，优先级应与崩溃同级。功能完备性方面，#8/#9/#10 是一批"注册了但没实现"的形参和占位函数（AGGREGATE options、DAYS360 method、HYPERLINK、INFO），建议要么补齐要么收紧 `maxArgs` 并在 README 声明，避免使用者按 Excel 文档写公式却拿到别的口径。

性能与内存方面本部分没有任何测量数据，因此只给出 3 条无基线方案与 5 条待验证假设；其中 `SUMIFS`/`COUNTIFS` 的"循环内重复物化"（#14）复杂度是静态可证的 O(格数²)，建议在补数据时优先验证。代码重复（#15/#21/#22/#23/#24）不影响当前行为，但已经出现口径漂移（`PPMT` 缺参取 0、`DMAX` 空集与 `MAX` 不同、美式 30/360 名不副实），适合在修上面缺陷时顺手收敛。
