# f_rule 模块审查报告

> **模块第 11/12 部分**（本报告只覆盖 `files/f_rule.part11.txt` 列出的 20 个文件：`src/table/` 下 `HitPolicy.cj` → `table.cj`，全部为 `.cj`。模块内其余 164 个 `.cj` 与 33 个 `.md` 由其他部分产出；本部分计数独立，合并时以主 Agent 为准。`doc/07-decision-table.md`、`f_excel`、`src/fact/ValueKey.cj` 仅作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个 `.cj`，0 个 `.md`；模块共 184 `.cj` + 33 `.md`）
- **基线**：工作区快照（`HEAD 97507061b5`，`git status f_rule` 为空 ⇒ 无本次改动，全部问题记「存量」）
- **审查重点**：规则引擎求值正确性（决策表编译 / 逐行求值 / 命中策略聚合）、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 11/12 部分）

## 发现

### [一般][存量] #1 流式 XLSX 两条路径都不释放 `ExcelSheetStream`：`RowReader` 只在读到头才关，编译中途失败即泄漏

- **位置**：`f_rule/src/table/XlsxTableParser.cj:106-119`（`stream(path)` 建 `ExcelSheetStream` 后交给 `XlsxTableStream`，全流程无 `stream.close()`）、`f_rule/src/table/XlsxTableParser.cj:771-777`（`XlsxRowSource.rows()` 每次新开 `RowReader`）、`f_rule/src/table/XlsxTableParser.cj:857-870`（`warnMergedRanges()` 是唯一 `reader.close()`，只在 `reader.next()` 返回 `None` 时触发）
- **来源**：存量（`git blame`：`4e765c37c4 2026-11-01`，`stream` 与 `XlsxRowIterator` 同一提交）
- **判据**：review-checklist §11「资源不对称：打开未关、异常跳过释放」
- **证据**：静态确定 —— `ExcelSheetStream` 明确要求显式关闭才能释放 ZIP 句柄与 spool 临时目录（`f_excel/src/ExcelSheetStream.cj:357-377`：`close()` 里 `zip.close()`、删 `spoolDir`）；`RowReader.close()` 关的是单个 sheet 的条目流（同文件 `82-91`）。f_rule 侧全包搜 `close()` 只有 `XlsxTableParser.cj:137`（读 `_meta`）、`:177`（读表头/类型行）、`:869`（读到流尾）三处，**没有任何** `stream.close()`。
- **描述**：三类可复现的泄漏面：
  1. `XlsxTableParser.stream(path)` 返回的迭代器把 `ExcelSheetStream` 一直挂在 `XlsxTableStream.stream`（`:721`）里，即使把所有 sheet 迭代完也不会关，ZIP 句柄（`open(input)` 场景还有落盘的 spool 临时目录）活到 GC 或进程结束；
  2. `TableCompiler.compile()`（`f_rule/src/table/TableCompiler.cj:178`）遍历 `rowIterator()` 时，任何一行触发 `TABLE_INVALID` / `TYPE_MISMATCH`（例如 `CellParser` 值解析失败、`render` 遇到 `Error` 单元格）都会抛出并丢弃迭代器 ⇒ 该 sheet 的 `RowReader` 永不关闭，而此时 `ExcelSheetStream` 仍被表模型引用，等于条目不释放；
  3. `XlsxRowIterator` 没有破坏性释放路径（无 `finally`、`Iterator` 也无 `close` 约定），调用方无法主动收尾。
- **建议**：`XlsxTableParser.stream` 的返回类型改为自带 `close()` 的迭代器（或返回 `(Iterator<DecisionTable>, () -> Unit)`），把 `stream.close()` 交给调用方；更省事的做法是 `XlsxTableStream` 在 `next()` 返回 `None` 时自行 `stream.close()`，并让 `TableCompiler.compile()` 用 `try { ... } finally { 关闭行来源 }` 包住 `rowIterator()` 循环——为此需要给 `TableRowSource` 加 `func close(): Unit`（默认空实现，`XlsxRowSource` 覆盖为 `reader.close()`）。

### [一般][存量] #2 「流式大表内存与行数无关」的承诺在编译/执行路径不成立：每行仍物化成 `CompiledRow + Rule + Pattern` 并常驻

- **位置**：`f_rule/src/table/XlsxTableParser.cj:53-54`（类注释："`ExcelSheetStream` 走流式路径（大表，内存与行数无关）"）、`f_rule/src/table/XlsxTableParser.cj:101-105`（"10 万行的表也只有一行在内存里"）；反证：`f_rule/src/table/TableCompiler.cj:175-184`（`for (row in table_.rowIterator())` 逐行 `rows.add(compiled)` + `rules.add(compiled.rule)`）、`f_rule/src/table/TableExecutor.cj:43-44`（`compiled_` 随执行器长期持有）
- **来源**：存量（`git blame`：注释 `4e765c37c4 2026-11-01`，编译循环 `4e765c37c4 / 57e7cd67f6`）
- **判据**：review-checklist §14.1「承诺了但没实现（契约与实现不符）」、§5「一次性物化」
- **证据**：静态确定（对象数）+ 需实测（字节量）——`CompiledTable.rows` 长度恒等于数据行行数，`CompiledRow` 内嵌 `TableRow`（含 `Array<?String>`）、`Rule`（含 `Pattern` 与输出闭包捕获的 `Array<CompiledOutput>`）、`conditions`/`outputs` 两个数组；`CompiledTable.rules` 再持一份同样的 `Rule` 指针。100 000 行 ⇒ 至少 10 万 × (1 `CompiledRow` + 1 `Rule` + 1 `Pattern` + 2~3 个数组) 个对象常驻，按每行 0.4–0.8 KB 估算约 40–80 MB（量级待实测）。同一个 `TableExecutor` 还会被 `RuleEngine` 按 `id@version` 缓存到引擎生命周期（`f_rule/src/engine/RuleEngine.cj:110-111`），不会随一次调用释放。
- **描述**：文档与类注释把"10 万行"作为流式入口的卖点，测试 `XlsxTableParser_test.cj:600-630`（T-14）也只断言 `table.rows.isEmpty()` 与逐行可读，**没有**覆盖"编译/执行后仍不物化"。实际链路是"读取流式、编译物化"：只要表被编译（无论议程路径还是 `TableExecutor`），内存就回到 O(行数)，`stream()` 只省了原始单元格文本那一层。
- **建议**：两个方向二选一，并在文档写清：(a) 把注释/文档改成"读取阶段内存与行数无关；编译后每行一条规则，内存为 O(行数)"，同时给 T-14 补一条"编译 10 万行后 `getUsedHeapSize()` 增量"的用例；(b) 若确实要保住 O(1) 行内存，聚合路径需要改成"边读边判边聚合"（`TableExecutor` 不缓存 `CompiledRow`，只保留命中行），这需要把 `HitAggregator` 改成流式累加器（见优化方案 3）。

### [一般][存量] #3 `Any` 策略多命中时返回全部行，与 `TableResult` 文档契约「单值策略至多一条」冲突

- **位置**：`f_rule/src/table/HitAggregator.cj:87-89`（`case Any => ensureConsistentOutputs(hits); return hits`）；契约源：`f_rule/src/table/TableResult.cj:23-24`（注释："`outputs` 与 `hits` 一一对应（`Collect` 类策略多条，单值策略至多一条）"）、`f_rule/doc/07-decision-table.md:404`（"单值时 size == 1，Collect 类策略时可能多条"）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §11「契约与实现不符」、§3「空实现/契约语义错位」
- **证据**：静态确定 —— `Any` 分支只做一致性校验后原样返回 `hits`（N 条）；`TableResult.outputs` 在 `TableExecutor.cj:75-78` 逐条展开，因此 `Any` 且 N 行命中时 `outputs.size == N`，而 `Any` 不在文档所列的 `Collect 类策略`（`Collect` / `RuleOrder` / `OutputOrder`）之内。测试 `HitPolicy_test.cj:96-101` 已把该行为写成断言（`@Assert(ids(...), ["R1", "R2"])`），说明是有意实现但与契约文字相反；DMN 对 `Any` 的语义也是"任取一条输出"。
- **描述**：调用方若按契约写 `result.outputs[0]` + 断言 `size == 1`（`Any` 是"多行命中但输出必须一致"的策略，本就只该有 1 条输出），会拿到 N 条重复输出；对下游"取唯一输出"的消费逻辑（例如把 outputs 直接当事件负载写出）会造成 N 倍重复。反过来若按现状写，则与文档冲突。
- **建议**：择一并同步三处：把 `Any` 改为 `return [hits[0]]`（与 DMN、文档一致，测试改为断言 size==1 且输出一致），或把 `TableResult.cj:23-24` 与 `doc/07:404` 改成"`Any`/`Collect` 类策略可能多条"。前者更符合策略语义，改动只在 `HitAggregator.cj:87-89` 一行 + 一条测试。

### [一般][存量] #4 `${binding}` 整事实输出与 `Any` / `Priority` / `OutputOrder` 的组合在聚合期抛 `TYPE_MISMATCH`

- **位置**：输出侧 `f_rule/src/table/OutputCell.cj:98-101`（`BindingRef` 直接把 `Fact` 当 `Any` 返回）；聚合侧 `f_rule/src/table/HitAggregator.cj:121-134`（`sameOutputs` → `ValueKey.of(value)`）、`:138-146` / `:177-184`（`compareOutputs` / `compareValue` → `ValueKey.of`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §11「逻辑错误 / 契约承诺但实现不支持」
- **证据**：静态确定 —— `ValueKey.of` 只接受 `String/整数/浮点/Decimal/Bool/DateTime/Array<Any>/Set<Any>`，其余一律抛 `RuleException(TYPE_MISMATCH, "ValueKey 不支持的值类型…")`（`f_rule/src/fact/ValueKey.cj:96-129`，`124-128` 是兜底 `_ =>` 抛出）。而 `${binding}` 是**文档化的输出形态**（`doc/07-decision-table.md:191`：`${<binding>}  # 整个事实`），`OutputCell.resolve` 返回的正是 `Fact` 对象，`TableExecutor.outputsOf`（`TableExecutor.cj:158-169`）把它原样塞进 `HashMap<String, Any>`。
- **描述**：下表任一行成立即在运行期抛异常（表定义本身完全合法、编译期不报错）：

  | hitPolicy | 触发条件 | 抛错点 |
  | --- | --- | --- |
  | `Any` | ≥2 行命中且输出含 `${o}` | `sameOutputs` → `ValueKey.of(Fact)` |
  | `Priority` | ≥2 行命中且 `outputOrder` 含该输出槽 | `prioritySorted` → `compareValue` |
  | `OutputOrder` | ≥2 行命中 | `sorted` 的比较器 → `compareValue` |
  | `Collect` / `First` / `Unique` / `RuleOrder` | — | 不比较输出，正常 |

  抛出的错误码是 `TYPE_MISMATCH`（数据问题），而根因是"输出值类型超出聚合比较器支持范围"，排障会指向错误的表/字段。附带问题：`TableResult.outputs` 中出现 `Fact` 对象后，任何按标量序列化/日志化的下游（如把 outputs 直接转 JSON）都会失败。
- **建议**：在 `TableCompiler.compileOutputs`（`TableCompiler.cj:332-358`）就拒掉"`BindingRef` 输出 + 需要比较输出的策略"组合并抛 `TABLE_INVALID`（带列名与策略名），或在 `HitAggregator.compareValue`/`sameOutputs` 里对 `Fact` 走引用相等（`ValueKey` 不做比较，直接用 `refEq`），同时补一条 `${o}` + `Any` 的两行命中用例。

### [一般][存量] #5 命中排序用插入排序 O(n²)：`RuleOrder` / `OutputOrder` 在 10 万行命中时退化为平方级

- **位置**：`f_rule/src/table/HitAggregator.cj:187-204`（`sorted`：插入排序）、`:100-103`（`prioritySorted` 复用同一排序）、`:163-173`（`orderedNames` 里另写一遍 `String` 版插入排序）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §6.4「低效算法：每请求排序用 O(n²)」、§2「只改类型名的重复实现」
- **证据**：静态确定（复杂度）——`sorted` 的双层 `while` 是教科书插入排序，比较次数 = O(n²)（逆序时最坏）；输入规模 n = **命中行数**，上界由表行数决定，而本模块主打的流式表就是 10 万行（`XlsxTableParser.cj:101-105`）。**未做耗时实测**，故不声称端到端占比或收益百分比（见「待验证假设」5）。
- **描述**：`Collect` 直接返回不做排序，所以不受影响；但 `RuleOrder`（按 salience 降序）与 `OutputOrder`（按输出值）对所有命中行排序，`Priority` 也先全排序再取 `[0]`。一张"宽条件"表（例如所有行都满足 `level >= 1`）在 10 万行规模下命中数≈行数，10¹⁰ 量级比较，单次 `execute` 可能从毫秒级掉到分钟级；`Priority` 只需最小值，却付了全排序的代价。
- **建议**：`sorted` 换成稳定排序（`std.sort.sort` 不保证稳定，可先按行序编号做二级键，或用 `ArrayList.sort` 的自定义比较把"行序"作为 tie-break）；`Priority` 改为单趟取最小（O(n)）；`orderedNames` 的 `String` 插入排序改 `ArrayList<String>.sort()` 或直接用 `names.sort()`（排序后顺序即输出顺序，稳定性无意义）。改完补等价性用例（同 salience 保持行序、缺失输出键排最后）。

### [轻微][存量] #6 `markAssembled` / `markExecuted` 在编译之前执行：编译失败后实例被永久锁在单一模式

- **位置**：`f_rule/src/table/DecisionTable.cj:233`（`markAssembled()` 在 `TableCompiler(...).compile()` 之前）、`:243`（`compileInto` 同）、`:115-127`（`markExecuted`）；调用点 `f_rule/src/table/TableExecutor.cj:52`（构造期先 `markExecuted()` 再编译）
- **来源**：存量（`git blame`：`5702078ebc 2026-11-01`）
- **判据**：review-checklist §11「错误处理缺失 / 状态机残留」
- **证据**：静态确定 —— 编译抛错（`UNKNOWN_FACT_SPACE`、`UNKNOWN_FIELD`、`TYPE_MISMATCH`、空表…）时 `mode_` 已被写成 `Assembled` / `Executed`，`compile()` 与 `TableExecutor` 构造都没有回滚路径。
- **描述**：错误恢复场景（改注册表后重试另一条路径、在配置错误后想改用 `TableExecutor` 调试）会得到与真实原因无关的 `TABLE_MODE_CONFLICT`；`TableAssembly_test.cj:74-100`（AS-03/AS-05）本身就制造了这种"失败后实例被标记"的状态，只是没有断言。
- **建议**：把 `markXxx()` 挪到编译成功之后（`compile()` 返回前），或失败时在 `catch` 里恢复 `Unbound`；`TableExecutor` 同理改成"编译成功 → `markExecuted` → 赋值字段"。这样 `mode` 才真实反映"已被成功使用"。

### [轻微][存量] #7 `CsvScanner.start` 字段只写不读（死字段）

- **位置**：`f_rule/src/table/CsvTableParser.cj:44`（`private let start: Int64`）、`:53-56`（构造里 `this.start = start` 后再无引用）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §1「读了不用 / 死字段」，机械动作第 6 条
- **证据**：静态确定 —— 全仓搜 `start` 在 `CsvTableParser.cj` 内只命中 `44`（声明）、`53`/`55`（形参/赋值）、`56`（`this.index = start` 用的是形参）、`199-203`（`parseBytes` 的局部变量，与字段无关）；`CsvScanner` 的扫描逻辑全部基于 `index`，`start` 字段没有任何读者。
- **建议**：删掉字段与 `this.start = start`，构造函数保留形参直接 `this.index = start`。

### [轻微][存量] #8 `TableExecutor.evaluate` 无候选分支里的 `let _ = condition` 是空转语句

- **位置**：`f_rule/src/table/TableExecutor.cj:108-115`（`110` 行 `for (condition in row.conditions)`、`111` 行 `let _ = condition`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §1「不可达/无效语句：局部 `let` 赋值后不被读取」
- **证据**：静态确定 —— `let _ = condition` 的唯一作用是消掉"循环变量未使用"的告警，循环体真正做的事只有 `unknowns.add(Truth.False)`，等价于按条件数补 `False`。
- **建议**：整段替换为 `results = Array<Truth>(row.conditions.size, repeat: Truth.False)`（一次分配、无中间 `ArrayList`），同时消掉这条死语句。

### [轻微][存量] #9 `XlsxRowIterator` 耗尽后再 `next()` 抛 `ExcelException`，与同包其它迭代器行为不一致；且行读取异常未折算成 `RuleException`

- **位置**：`f_rule/src/table/XlsxTableParser.cj:805-819`（`next()` 走 `reader.next()`，`None` 分支调 `warnMergedRanges()` → `reader.close()`）、`:857-870`（唯一的 `close()`）
- **来源**：存量（`git blame`：`4e765c37c4 2026-11-01`）
- **判据**：review-checklist §11「契约不符 / 错误类型泄漏」、§3「错误处理不完善」
- **证据**：静态确定 —— `RowReader.next()` 在 `closed` 后直接 `throw ExcelException("流已关闭")`（`f_excel/src/ExcelSheetStream.cj:64-67`，`close()` 在 `82-91`）。`XlsxRowIterator` 在返回第一个 `None` 前就 `close()` 了 reader，因此第二次 `next()` 必抛；同包的 `XlsxEmptyRowIterator`（`:781-785`）与整表路径的 `rows.iterator()` 都会稳定返回 `None`。此外 `reader.next()` 在解析损坏的 sheet XML 时抛的 `ExcelException`（f_excel 类型）会原样穿过 `TableCompiler.compile()`，与"表问题统一 `RuleException(TABLE_INVALID)`"的约定（`openDocument`/`stream` 都做了折算，`:257-268`、`:107-116`）不一致。
- **建议**：`next()` 加 `if (finished) { return None<TableRow> }` 的幂等守卫；在 `TableCompiler` 的行循环（或 `XlsxRowIterator.next()` 外层）用 `catch (e: ExcelException)` 折算为 `RuleException(TABLE_INVALID, "sheet X 第 N 行读取失败: ...")`。

### [轻微][存量] #10 `==` / `!=` 用 `toString()` 字符串比较，三份逐字重复

- **位置**：`f_rule/src/table/TableMode.cj:40-46`、`f_rule/src/table/HitPolicy.cj:54-60`、`f_rule/src/table/Column.cj:38-44`（三处函数体只有类型名不同）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「只改类型名的重复实现」
- **证据**：静态确定 —— 三个 `enum` 的 `==` 都是 `this.toString() == other.toString()`，`!=` 都是 `!(this == other)`；`toString()` 本身是 `match` 到字面量，等价于按变体比较，但每次比较都分配两个 `String`（`HitPolicy.parse`、`Column.parse` 的频繁判断都走这条路径）。
- **建议**：无参 enum 的相等可直接 `match` 枚举变体（或对单例变体用引用比较），至少把三份样板收敛为一次显式 `match`；若语言版本支持，让三个 enum 各自实现 `Equatable` 的 `match` 版本，避免相等判断走字符串。若判定收益不足，至少加注释说明"用 toString 比较是为了避免变体字段比较"。

### [轻微][存量] #11 `_meta` → `DecisionTableBuilder` 的属性映射在 CSV / XLSX 各写一份（含 `salience` 解析三份）

- **位置**：`f_rule/src/table/CsvTableParser.cj:224-259` 与 `f_rule/src/table/XlsxTableParser.cj:494-531`（8 个键逐个 `match`）；另 `salience` 解析三份：`CsvTableParser.cj:324-333`、`XlsxTableParser.cj:543-552`、`TableCompiler.cj:378-400`
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「换控制流 / 字面量复制：同一组字段名散落多处」
- **证据**：静态确定 —— 两处处理的键集合完全相同（`name`/`version`/`factspace`/`facttype`/`hitpolicy`/`salience`/`outputorder`），`outputorder` 的"逗号切分 + trim + 丢空段"逻辑逐行相同；**已知差异**只有三点：XLSX 额外对 `_meta.id` 与 sheet 名不一致打 WARN（`XlsxTableParser.cj:532-540`）、CSV 的 `salience` 错误文案是 `# salience 必须是整数`、XLSX 的是 `_meta.salience 必须是整数`。三处 `salience` 都是"`Int64.parse` 失败 → `TABLE_INVALID`"。
- **描述**：同一张表用 CSV 与 XLSX 两种载体承载时，属性行为已出现分叉风险（XLSX 有 id 校验、CSV 没有；错误文案不同），而 T-12 等价性用例（`XlsxTableParser_test.cj:546-577`）只比对 `id/name/version/factSpace/hitPolicy/salience` 的**值**，比不出这类漂移。
- **建议**：在 `table` 包内抽 `applyMeta(builder, meta: HashMap<String,String>, tableId: ?String)` 与 `parseSalience(text, context)`（两个解析器同包，抽取不跨层），把"是否校验 id"作为可选参数（XLSX 传表名、CSV 传 `None`）；`TableCompiler` 的行级 `salience` 保留独立实现但复用同一个 `parseSalience`。

### [轻微][存量] #12 `HitAggregator` 内三处排序样板：`prioritySorted` 与 `OutputOrder` 分支函数体逐行相同，另有两份插入排序

- **位置**：`f_rule/src/table/HitAggregator.cj:94-96`（`OutputOrder` 分支）与 `:100-103`（`prioritySorted`）：同为 `let names = orderedNames(hits); sorted(hits) { ... compareOutputs(...) == Ordering.LT }`；`:163-173`（`String` 插入排序）与 `:187-204`（`TableHit` 插入排序）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「换控制流 / 只改类型名」
- **证据**：静态确定 —— `prioritySorted` 只有 `aggregate` 一处调用（`:85`），其函数体与 `OutputOrder` 分支完全一致，唯一差别是调用方后续取 `[0]`；两处插入排序外层循环结构逐行相同，只有元素类型与比较谓词不同。
- **建议**：删掉 `prioritySorted`，`Priority` 分支复用同一条排序后取 `[0]`（或按 #5 改成单趟取最小）；`orderedNames` 的排序改调 `ArrayList<String>.sort()`，与 #5 的 `sorted` 替换一起做。

### [轻微][存量] #13 「单绑定 + 逐输出槽解析」逻辑在 `TableExecutor` 与 `TableCompiler` 各写一遍

- **位置**：`f_rule/src/table/TableExecutor.cj:158-169`（`outputsOf`：建 `HashMap<String,Fact>`、填 `bindings[compiled_.binding]=fact`、遍历 `row.outputs` 调 `cell.resolve`）与 `f_rule/src/table/TableCompiler.cj:361-376`（`actionFor` 返回的闭包：建同一个 `HashMap`、`ctx.fact(binding)`、同样遍历 `outputs` 调 `cell.resolve`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「跨层复制：输入-输出-副作用相同，只改写入目标」
- **证据**：静态确定 —— 两段都是"1 个绑定 → `HashMap<String, Fact>` → 对每个 `CompiledOutput` 调 `resolve` → 有值则写入"，差别只在写入目标是 `HashMap<String, Any>` 还是 `ActionContext.set`；`resolve` 的 `None` 语义（缺绑定/缺字段静默跳过）也在两处各判一次。
- **建议**：抽 `private func resolveOutputs(outputs: Array<CompiledOutput>, binding: String, fact: ?Fact): Array<(String, Any)>`，两处各自消费结果（executor 填 map、action 调 `ctx.set`）。注意保留差异：executor 的 `fact` 来自命中事实、action 的来自 `ctx.fact(binding)`，抽取时以 `?Fact` 入参。

### [轻微][存量] #14 数值字面量推断与表头宽度计算各有两套近似实现

- **位置**：`f_rule/src/table/CellParser.cj:175-188`（`number`：`contains(".")/"e"/"E"` → `Float64.parse`，否则 `Int64.parse`，失败抛 `TYPE_MISMATCH`）与 `:266-287`（`infer`：同样判 `contains(".")/"e"/"E"` 走 `Float64.parse`，否则 `Int64.parse`，失败静默继续）；`f_rule/src/table/XlsxTableParser.cj:302-312`（`headerWidth`：`while (width < cols)` 读 `cellText(1, width+1)` 到空为止）与 `:184-190`（`streamLayout` 内的同逻辑，只是数据源换成 `streamCellText`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31` / `4e765c37c4 2026-11-01`）
- **判据**：review-checklist §2「换算复制 / 近似重复」
- **证据**：静态确定 —— 数字判定表达式完全相同（`text.contains(".") || text.contains("e") || text.contains("E")`），`infer` 只是把异常静默后继续尝试 Bool/时间；两处表头宽度都是"从第 1 列起连续非空单元格数"，`parse()` 里 `:74` 与 `parseWorksheet` 里 `:327` 还会对同一 sheet 各算一次。
- **描述**：`infer` 与 `number` 的差异（一个抛错、一个回退）是业务需要，可以保留，但"是否为实数字面量"的判据重复后一旦修改（例如支持 `Infinity`/`_` 分隔符）必须同步两处；表头宽度两份实现在"空格也算断开"的边界上必须永远一致，否则整表路径与流式路径对同一文件会得到不同列数。
- **建议**：`CellParser` 抽 `private func looksReal(text: String): Bool`；`XlsxTableParser` 抽 `private func headerWidthOf(textAt: (Int64) -> String, limit: Int64): Int64`，两条路径各传自己的取单元格函数（顺带消掉 `parse()` 的重复计算）。

**存量合计 14 条**（严重 0 / 一般 5 / 轻微 9），是否纳入修复待用户决定。

## 优化可行性方案

> 本部分没有 `cjprof` / `cjpm bench` 基线，五条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [堆内存] `execute()` 无条件构造 trace 对象（`trace = false` 时全量丢弃）

- **现状**：`f_rule/src/table/TableExecutor.cj:116-123` 每行都 `new ArrayList<ColumnTrace>` + `Array<ColumnTrace>` + N 个 `ColumnTrace` + 1 个 `RowTrace`；`:67-69` 在 `trace = false` 时直接丢弃。对象数 ≈ 行数 × (2 + 条件列数 + 1)。10 万行 × 4 条件 ≈ 70 万个短命对象/次调用。
- **方案**：`evaluate` 增加 `collectTrace: Bool` 入参（或让 `RowOutcome.trace` 为 `?RowTrace`），`trace = false` 时只算 `matched` 不建 `ColumnTrace`；`RowTrace.columns` 也可改为惰性（只存每个条件的 `Truth` 数组，需要时再包 `ColumnTrace`）。
- **预期**：`trace = false`（生产默认）时该路径分配降到接近 0；收益取决于行数 × 条件列数与调用频次（**未测**）。
- **代价**：`RowOutcome`/`evaluate` 的签名变化（内部类型，无对外影响）；`trace = true` 行为不变。
- **验证**：同一视图跑 1 万次 `execute`（10 万行表），对比 `getAllocatedHeapSize()` 增量、GC 次数与 P95 延迟。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每个 (行 × 事实) 都新建 `HashMap<String, Fact>` 装单绑定

- **现状**：`f_rule/src/table/TableExecutor.cj:128-129`（`evaluateConditions`）与 `:160-161`（`outputsOf`）各建一个 `HashMap<String,Fact>`，只放 1 个 entry。成本 = 行数 × 候选事实数 × 2 个 `HashMap`（外加桶数组）；无 `expr` 列、输出全是字面量时这些 map 完全无用。
- **方案**：编译期给每行算两个标记 `needsBindingsForExpr` / `needsBindingsForOutput`（`CompiledRow` 上加字段），只在需要时构造 map；更彻底的做法是给 `Constraint.eval` / `JitExpression.eval` 提供"单绑定"重载（`eval(fact)`），彻底去掉 map。
- **预期**：无 `expr` 列的表（`doc/07` 的主用法）在该路径上减少 2 个 map/行/事实；配合候选事实数 N，减少量 = 2 × R × N 个对象（**未测**）。
- **代价**：`CompiledRow` 多 2 个 `Bool`；需要给 `JitExpression` 加重载（跨包改动）。
- **验证**：`cjpm bench -O2` 跑 1 万行 × 100 事实，对比分配量与中位耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 聚合路径重复持有 `CompiledTable.rules`

- **现状**：`f_rule/src/table/TableCompiler.cj:175-184` 同时填 `rows`（`CompiledRow`，含 `rule`）与 `rules`（`Array<Rule>`，同一批 `Rule` 指针）；`TableExecutor` 只用 `rows`，`rules` 仅议程路径（`DecisionTable.compile`/`compileInto` 取 `.rules`）需要。100 万字节级：10 万行 × 8 B 指针 ≈ 0.8 MB（`Array` 本体），外加读者误用风险。
- **方案**：`CompiledTable.rules` 改为 `?Array<Rule>`（`agendaPath_` 为 true 时填），或让 `compile()` 返回 `Array<Rule>` 由调用方取，`CompiledTable` 不再存。
- **预期**：聚合路径少一个 10 万元素数组；议程路径不变（**未测**）。
- **代价**：`CompiledTable.rules` 由 `let Array<Rule>` 变 `?Array<Rule>`，`TableAssembly_test`/`TableCompiler_test` 取值处要改。
- **验证**：编译 10 万行表后 `getUsedHeapSize()` 差值与 `CompiledTable` 对象图规模。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 编译期把"列级校验"下沉到行循环外

- **现状**：`f_rule/src/table/TableCompiler.cj:239-245` 每行每列调 `fieldTypeOf`（一次 `HashMap.get` + 缺失即抛），`:413-422` 的 `validateOperator` 又对同一列**再取一次** `fieldType`；每行还要额外遍历列 3 遍：`compileOutputs`（`:332-358`）、`salienceOf`（`:378-400`）、`conditionKey`（`:441-456`，仅 Unique）。10 万行 × 6 列 ⇒ 约 300 万次 hash 查找 + 2 倍冗余。
- **方案**：编译前建一次 `Array<ColumnPlan>`（列种类、`FieldType`、是否已通过算子校验、输出槽名、是否 salience 列、列下标），行循环里只按下标取 `row.values[i]` 并解析值；`requireUniqueRows` 的 key 构造改 `StringBuilder`。
- **预期**：编译期列级 hash 查找从 O(行×列) 降到 O(列)（**未测**）；对 10 万行表的 `compile()` 总耗时影响需实测。
- **代价**：多一个内部类型 `ColumnPlan`；`compileRow` 结构重排（行为不变，靠现有 15 条编译用例回归）。
- **验证**：`cjpm bench -O2` 或用例内分段计时，对比 1 万 / 10 万行 `compile()` 中位耗时与 `cjprof` 里 `HashMap.get` 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 命中排序改稳定 O(n log n) + `Priority` 单趟取最小

- **现状**：见发现 #5（`HitAggregator.cj:100-103`、`187-204`、`163-173`），插入排序 O(n²)，`Priority` 全排序后只取 `[0]`。
- **方案**：`RuleOrder`/`OutputOrder` 用"行序 index 作二级键"的通用排序（或先 `sort` 再按行序稳定化）；`Priority` 用 `minBy`（单趟，O(n)）；`orderedNames` 用 `sort()`。
- **预期**：排序比较次数从 O(n²) 降到 O(n log n)；10 万命中时理论降幅 3~4 个数量级（**未测**，实际取决于比较器成本）。
- **代价**：需保证"同键保持行序"语义不变（新增用例断言），`OutputOrder` 缺失输出键的排序位置（当前 `None` 排最后）必须保持。
- **验证**：`cjpm bench -O2` 构造 1 千 / 1 万 / 10 万条 hit 的 `aggregate` 基准，对比中位耗时；再用等价性用例覆盖重复值、缺失键、同 salience。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `TableExecutor.execute` 的 O(行 × 候选事实) 求值是聚合路径的主要热点 | `f_rule/src/table/TableExecutor.cj:62-70`（行循环）→ `:94-107`（事实循环）→ `:126-147`（条件求值） | 自耗时占比、条件列数/事实数下的曲线 | `cjprof record` 跑 1 万行 × 1/100/1000 事实三档，看 `evaluate`/`evaluateConditions` self time 占比是否 >20% |
| 2 | 10 万行流式表编译后的常驻堆与"内存与行数无关"的偏差有多大 | `f_rule/src/table/TableCompiler.cj:175-184`、`TableExecutor.cj:43-44` | `CompiledRow`/`Rule` 单对象字节量、总堆增量 | 对 `src/fixtures/pricing_large.xlsx` 跑 `stream → compile`，前后取 `getUsedHeapSize()`/`getAllocatedHeapSize()`，并用 `cjprof heap` 看 `CompiledRow` 实例数与占比 |
| 3 | `CellParser.parseCondition` 的十余次 `startsWith` + `toAsciiLower` 在宽表编译中占比可观 | `f_rule/src/table/CellParser.cj:54-122` | 单次解析耗时、每表单元格数 | 分段计时：只解析条件单元格 vs 全量 `compile()`，`cjprof` 看 `CellParser.parseCondition` 占比；输入 10 万行 × 6 列 |
| 4 | `XlsxMergeMap.anchorOf` 线性扫描在合并区域多的表上放大成 O(单元格 × 合并数) | `f_rule/src/table/XlsxTableParser.cj:691-698`（每次 `readCells` 每格都遍历 `ranges`） | 合并区域数、单次 `parse()` 耗时 | 造 500 个合并区域的 1 万行表，`cjprof` 看 `anchorOf` 自耗时；对照无合并区域版本 |
| 5 | `HitAggregator` 插入排序在真实宽条件表上确实退化为秒级 | `f_rule/src/table/HitAggregator.cj:187-204` | n=1k/10k/100k 命中的单次 `aggregate` 耗时与增长曲线 | `cjpm bench -O2` 直接对 `aggregate` 造逆序/随机/已排序三组输入，测中位数与 P95；同时记录比较次数埋点 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/table/HitPolicy.cj` | .cj | ✅ | 7 变体 + `parse` 大小写不敏感；`==`/`!=` 见 #10；无未知值静默回退（未知抛 `TABLE_INVALID`，`HitPolicy_test.cj:130-140` 覆盖） |
| 2 | `f_rule/src/table/HitPolicy_test.cj` | .cj | ✅ | 7 策略 0/1/N 行为用例；`Any` 多命中断言 `["R1","R2"]` 固化了 #3 的行为，本身无缺陷 |
| 3 | `f_rule/src/table/OutputCell.cj` | .cj | ✅ | 见 #4（`BindingRef` 返回 `Fact` 进入聚合比较）；`${}` 三形态解析、右花括号/空引用/段数校验均正确，`unquote` 与 `parseValue` 无越界 |
| 4 | `f_rule/src/table/OutputCell_test.cj` | .cj | ✅ | 覆盖字面量三种推断、`FieldRef`/`BindingRef`、未知绑定、畸形引用；运行时 `resolvesValues` 用 `refEq` 断言整事实引用，印证 #4 的取值路径 |
| 5 | `f_rule/src/table/RowTrace.cj` | .cj | ✅ | `ColumnTrace`/`RowTrace` 纯数据类；`columns` 由 `TableExecutor` 填充，长度与条件列一致（见 #8 的空候选分支） |
| 6 | `f_rule/src/table/TableAssembly_test.cj` | .cj | ✅ | AS-01~AS-05：规则数与 id 前缀、未知空间/字段、重复装配 `DUPLICATE_RULE`；AS-03/AS-05 会留下"失败后标记 Assembled"的状态（见 #6） |
| 7 | `f_rule/src/table/TableCompiler.cj` | .cj | ✅ | 见 #2 / #4 / #6 / #11 / #13 / #14；`compileCount_` 用 `Mutex` 保护（无并发缺陷）；`checkColumnTypes` 的 `columnTypeAt` 越界返回 `None`，与 `columns` 等长假设成立；`conditionKey` 用长度前缀避免歧义 |
| 8 | `f_rule/src/table/TableCompilerAgenda_test.cj` | .cj | ✅ | 议程路径 `activationGroup`/`salience` 映射用例；与 `agendaGroup`/`agendaSalience` 实现逐条对应，无缺陷（`base - rowIndex` 在极小 salience 下有 Int64 溢出理论风险，行数需 > 9.2e18，不成立） |
| 9 | `f_rule/src/table/TableCompiler_test.cj` | .cj | ✅ | 15 条编译用例（字段/算子/值/绑定/salience/空表/Unique 重复行/expr）；`compilesThroughPublicApi` 是 `DecisionTable.compile(ruleSet)` 的仓内唯一调用点 |
| 10 | `f_rule/src/table/TableExecutor.cj` | .cj | ✅ | 见 #2 / #4 / #8 / #13；`outcome.fact.getOrThrow()` 安全（`matched` 只在 `allTrue` 时置 `Some`）；`execute` 全部用局部变量、字段全 `let` ⇒ 可被 `RuleEngine` 缓存后并发调用（见覆盖自检 §12） |
| 11 | `f_rule/src/table/TableExecutor_test.cj` | .cj | ✅ | I-01/T-06/T-10/Unique 零命中/Any 冲突/trace/expr；`view()` 每个用例新建，无跨用例污染 |
| 12 | `f_rule/src/table/TableMode.cj` | .cj | ✅ | 见 #10；`Unbound`/`Assembled`/`Executed` 三态语义与 `DecisionTable` 一致 |
| 13 | `f_rule/src/table/TableMode_test.cj` | .cj | ✅ | AS-11 实例级互斥五条用例；覆盖"同模式重复使用合法"与"不同实例独立" |
| 14 | `f_rule/src/table/TableResult.cj` | .cj | ✅ | 契约文字是 #3 的判据来源；`hits`/`outputs`/`trace` 三数组由 `TableExecutor` 一次构造，无独立逻辑 |
| 15 | `f_rule/src/table/TableRow.cj` | .cj | ✅ | 纯数据类；`values` 与 `columns` 等长由 `DecisionTableBuilder.rowAt`（`values.size != columns_.size` 抛错）保证 |
| 16 | `f_rule/src/table/TableSource_test.cj` | .cj | ✅ | `TableSource.compileInto` 两条用例；`compileInto` 只依赖 registry，符合 `doc/11` §4.1 |
| 17 | `f_rule/src/table/TableTestSupport_test.cj` | .cj | ✅ | 三个测试宿主类型 + `tableOrderSchema`/`tableCouponSchema`/`tableUserSchema` + `tableRuleSet`；被 6 个 `_test.cj` 引用，无死代码；`RuleSet` 直接构造绕过 `RuleSetBuilder` 的原因已在注释说明（包循环） |
| 18 | `f_rule/src/table/XlsxTableParser.cj` | .cj | ✅ | 见 #1 / #2 / #9 / #11 / #14；`render` 对 `Error`/无缓存 `Formula` 抛 `TABLE_INVALID`（测试已覆盖）；`renderNumber` 的 17 位精度回读循环有界；`headerWidth` 遇空列即截断属 `doc/07` §6.1 已声明语义，未计入缺陷 |
| 19 | `f_rule/src/table/XlsxTableParser_test.cj` | .cj | ✅ | T-12~T-14 与合并单元格/类型行/公式/错误单元格用例；T-14（`:600-630`）只断言 `rows.isEmpty()`，未覆盖编译后内存（见 #2）；`pricingXlsxMatchesPricingCsv` 的 `canonicalRow` 是有效的等价性快照 |
| 20 | `f_rule/src/table/table.cj` | .cj | ✅ | 包级文档（无声明，沿用 `f_rule/src/rule.cj` 的包文档风格）；所述"CSV/XLSX 均已落地、`stream` 供 10 万行"与实现一致，唯一夸大点是 #2 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #3（`Any` 语义）、#4（`${o}` 组合抛错）、#9（迭代器契约/异常类型）；设计 #1（资源所有权）、#2（流式承诺与编译物化）；可读性 #10（枚举样板）。语言特性：#4 涉及 `Any` 装箱后进入 `ValueKey` 的边界，其余 `Option`/`match` 用法正确（无静默丢弃：`OutputCell.resolve` 的 `None` 语义有文档、`collect` 的 `None` 分支是正常缺失）。安全性：本部分不拼 SQL/HTML/路径，无凭据、无外部输入进命令，XLSX/CSV 解析只做值转换；未命中 |
| §1 死代码 | 2 | 逐符号机械过：`private`（全仓搜）`RowOutcome`/`CsvRecord`/`CsvScanner`/`RenderedCell`/`XlsxStreamLayout`/`XlsxTableStream`/`XlsxRowSource`/`XlsxRowIterator`/`XlsxEmptyRowIterator`/`ColumnKindInference`/`XlsxMergeMap`/`TableCompiler.conflicts`/`agendaGroup`/`agendaSalience`/`salienceOf`/`fieldTypeOf`/`validateOperator`/`requireUniqueRows`/`conditionKey`/`warnAgendaDegradation`/`prioritySorted`/`orderedNames`/`sameOutputs`/`compareOutputs`/`compareValue` 均有调用者；`internal`（默认可见性的包内成员：`XlsxTableParser.streamTable`/`streamLayout`/`streamCellText`/`render`/`resolveTypeRow`/`typeOfToken`/`idIndex`/`ruleIdAt`/`readCells`/`applyMeta`/`parseSalience`/`putMeta`/`headerWidth`/`cellText`/`parseWorksheet`/`readTypeRow`/`readMeta`/`readStreamMeta`/`openDocument`，`CsvTableParser.parseBytes`/`applyMetadata`/`required`/`parseSalience`/`headerIndex`/`isValidUtf8`，`DecisionTableBuilder.columnType`/`rowSource`/`rowAt`，`DecisionTable.markAssembled`/`markExecuted`）在本包内均有引用。命中 2 条：#7（`CsvScanner.start` 只写不读）、#8（`let _ = condition`）。`protected` 本部分零声明。对外可达 `public` 一律不判；仓内零引用者仅作信息：`CompiledCondition.isEmpty`（`TableCompiler.cj:41-45`）、`DecisionTable.columnsOf`（`DecisionTable.cj:145-153`）、`DecisionTable.compile(ruleSet, compiler)` 两参重载（`DecisionTable.cj:232-235`）——三者都在 `public class` 上且顶层 `public`，属对外 API，只提示"仓内无使用"。无不可达语句、无恒真恒假分支；20 个文件 import 逐条核对均有使用 |
| §2 重复逻辑 | 5 | 同文件函数体两两比对（`TableExecutor` 5 个私有函数、`TableCompiler` 9 个、`HitAggregator` 6 个、`XlsxTableParser` 20 个、`CellParser` 9 个、`CsvTableParser` 7 个），跨文件按相同错误文案/字面量搜。命中：#10（三个 enum 的 `==`/`!=`）、#11（`_meta` 映射 ×2 + `salience` 解析 ×3）、#12（`prioritySorted` vs `OutputOrder` 分支 + 两份插入排序）、#13（`outputsOf` vs `actionFor`）、#14（数字推断 ×2 + 表头宽度 ×2）。已排除：`CellParser.parseValue` 的 7 个 `case`（按 `FieldType` 分派，非重复）；`TableCompiler.compileRow`/`compileOutputs`/`salienceOf`/`conditionKey` 的"遍历列"（各自取不同的列种类，属正交职责，仅建议下沉列计划见优化方案）；CSV/XLSX 两套扫描器（RFC 4180 与 OOXML 本质不同）；三份 `codeOf(...)` 测试辅助（各自捕获自家异常码，测试准备代码不判） |
| §3 空实现 | 0 | 全部分支逐条看：`XlsxEmptyRowIterator.next()` 返回 `None` 是有注释的 Null Object（`XlsxTableParser.cj:780-785`）；`collect`/`outputsOf`/`OutputCell.resolve`/`parseCondition` 的 `None` 分支都是"可选缺失"的正常语义（有文档说明）；`CsvTableParser`/`XlsxTableParser` 无 `TODO`/`FIXME`/`UnsupportedException`（全目录 grep 无命中）；无 `catch (_: Exception) {}` 空吞（`CellParser.parseIntOr`/`tryTime`/`TableCompiler.salienceOf` 的 `catch` 都转成了确定值或 `RuleException`） |
| §4 栈溢出 | 0 | 唯一的递归是 `XlsxTableParser.render`（`:586-595`）对 `Formula` 缓存值自调用，深度受 `CellValue` 模型嵌套限制（Excel 解析只产生一层 `Formula(inner)`），不可由表行数/列数放大；`TableCompiler`/`TableExecutor`/`HitAggregator`/两个解析器全部是显式循环，无树/图遍历、无 `equals`/`hashCode`/`toString` 自引用、无深拷贝 |
| §5 OOM | 1 | 命中 #2（编译/执行把每行物化为 `CompiledRow`，10 万行 40–80 MB 量级常驻；上界由表行数决定，无拒绝路径/上限配置）。已核对不算 OOM：`CsvTableParser.parseFile` 的 `File.readFrom` 与 `XlsxTableParser.parse` 的全表读取都以"文件大小"为上界（不是按报文头/DB 字段预分配）；`TableExecutor.collect` 的候选数组是单次调用的临时物化（O(事实数)，不跨调用累积）；`compileCount_` 是单个 `Int64`；无全局集合只增不减、无按请求 ID 建键的缓存 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench`/分段计时数据，5 条疑似热点全部进「待验证假设」；发现 #5 只声明"复杂度 O(n²)"这一可从代码静态判定的部分，不声称耗时占比或端到端收益 |
| §6.2 大粒度锁 | 0 | 仅有 2 处锁：`TableCompiler.countMtx`（只包一次 `Int64 +=`/读）、`DecisionTable.modeMutex_`（只包 `mode_` 读写，临界区 3 行）；无锁内 I/O、日志、解析、回调，且都不在请求主路径上 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池/队列，无"提交后立刻 `get`"、无单消费者串行段 |
| §6.4 低效算法 | 1 | 命中 #5（插入排序 O(n²)，`Priority` 全排序取最小）。另提示未计入缺陷的形态：`XlsxMergeMap.anchorOf` 每单元格线性遍历合并区域（`XlsxTableParser.cj:691-698`）、`conditionKey` 循环内 `String +=`（`TableCompiler.cj:441-456`，列数小，可忽略）、`XlsxRowIterator.rowOf` 对越界单元格再调 `streamCellText` 形成 O(单元格²)（仅畸形行触发）——三者都进「待验证假设」4 或不成立 |
| §7 降堆内存方案 | 3 | 优化方案 1（trace 对象按需构造）、2（单绑定 map 按需）、3（`CompiledTable.rules` 去重），全部 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 4（列级校验下沉 + 列计划）、5（稳定排序 + `Priority` 单趟），全部 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 无合格候选：`TableExecutor.evaluate` 的临时对象（`Array<Truth>`、`RowTrace`/`ColumnTrace`、`bindings`）要么**逃逸**进 `TableResult`/`RowOutcome`，要么是每 (行×事实) 的短命对象但 std 的 `HashMap`/`ArrayList` 无 local mode 重载，需 `@ local!` 重建且工具链（`cjfmt`/`cjlint`/LSP）不保证支持；且 `cjLocalRegionMaxSize` 是新的 OOM 面（10 万行 × 多列临时对象）。没有改前/改后峰值内存数据，按 §9 只能写"不可行（逃逸 + 无 mode 重载）" |
| §11 现有代码的 BUG（存量） | 14 | 14 条全部为存量（快照无 diff，`git status f_rule` 空；`git blame` 落在 `57e7cd67f6 2026-10-31`、`4e765c37c4 / 5702078ebc 2026-11-01`）。已逐个核对未列入缺陷的边界：`Column.parse` 的 `trimmed[5..]` 对 `"when."`（长度 5）得到空串并抛 `TABLE_INVALID`（正确）；`OutputCell.parse` 的 `raw[2..size-1]` 对 `"${"`+`"}"` 得空串 → 抛"引用为空"（正确，且下标全 ASCII 无 UTF-8 越界）；`CellParser` 的算子偏移量（`in`=2、`not in`=6、`between`=7、`contains `=9、`startswith `=11、`endswith `=9、`matches `=8）逐个与字面量长度一致；`tryTime` 的 `day<=31` 由 `DateTime.of` 兜底（非法日期被 catch 成 `None`）；`CsvTableParser.isValidUtf8` 的过长的编码/代理区/上界检查（`E0/ED/F0/F4`）完整，且 `i+extra>=size` 先判；`CsvScanner` 的 `\r\n` 与引号内换行行号维护一致；`DecisionTable.columnTypeAt` 越界返回 `None`；`TableExecutor.evaluate` 中 `results` 与 `conditions` 长度恒等（三处来源都按条件数填充） |
| §12 并发安全与锁粒度 | 0 | 逐个共享点取证：① `TableExecutor` 被 `RuleEngine` 按 `id@version` 缓存后跨会话共享（`engine/RuleEngine.cj:106-115`），但 `table_`/`compiled_` 都是 `let` 且 `CompiledTable` 构造后只读，`execute` 全部状态是局部变量 ⇒ 可并发调用（`JitExpression.eval` 只读，`condition/JitExpression.cj:230-241`）；② `DecisionTable.mode_` 的读（`prop mode`）与写（`markAssembled`/`markExecuted`）都在 `modeMutex_` 内，检查-然后-写入在同一临界区（无 TOCTOU）；③ `TableCompiler.compileCount_` 的 `+=` 与读都在 `countMtx` 内；④ 唯一未声明线程约束的是 `DecisionTable.rowIterator()` 在流式表上会与共享的 `ExcelSheetStream` 交互（`ExcelSheetStream.cj:310` 写 `lastSheet`），但类文档已写"不要同时持有两个迭代器"（`DecisionTable.cj:165-166`），且现有唯一调用方 `TableCompiler.compile` 由 `RuleEngine` 的 `executorsMtx_` 串行化 ⇒ 当前无并发路径踩到，仅作为公共 API 的隐含约束记在此处。锁粒度：#6.2 的 3 处临界区都在微秒级、无嵌套锁、无锁顺序问题 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `README.md`/`README_en.md`/`doc/**`，README 覆盖无法在本部分判定（模块 README 属其他部分）。就"承诺源—实现"对照做了三处抽查（承诺源都在本部分文件内）：`table.cj:18-24` 声称的两个载体与 `stream` 入口均存在；`OutputCell.cj:40-41` 声称的 `${binding}` 已实现（但组合语义见 #4）；`DecisionTable.cj:162-167` 声称的 `rowIterator` 两种来源均实现。`f_rule/src/rule.cj:33-34` 的门面重导出已含 `CsvTableParser`/`XlsxTableParser`/`Column`/`ColumnKind`/`HitPolicy`/`RowTrace`/`TableMode`/`TableResult`/`TableRow`/`DecisionTable(Builder)`（`TableExecutor`/`OutputCell`/`HitAggregator` 未进门面，但 `f_rule.table` 是公开子包，可取到，不判缺失） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 无对象。跨文件一致性按要求用 `doc/07-decision-table.md`（§2/§4.2/§6/§9）与 `f_excel/src/ExcelSheetStream.cj`、`f_rule/src/fact/ValueKey.cj` 做了判据核对，不计入本部分覆盖 |

**范围外提示**（不计入统计）：`engine/RuleEngine.cj:105` 以 `"${table.id}@${table.version}"` 作为执行器缓存键，两个同名同版本但内容不同的 `DecisionTable` 会复用同一个 `TableExecutor`（文档 `doc/07`/`doc/11` 已要求"表变更需换版本号或新建引擎"，此处仅提示该约束没有运行期校验）。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 3 / 2 |

## 总评

本部分是 `f_rule` 的决策表运行时：模型（`DecisionTable`/`TableRow`/`Column`）、编译（`TableCompiler` + `CellParser`/`OutputCell`/`ExprColumn`）、执行与聚合（`TableExecutor`/`HitAggregator`）、两种载体解析（`CsvTableParser`/`XlsxTableParser`）以及 6 个测试文件。整体质量偏上：编译期校验链完整（空表 → 类型推断 → 字段/算子/值 → 输出引用 → salience → Unique 重复行），错误码区分清楚（`TABLE_INVALID` 结构问题 vs `TYPE_MISMATCH` 数据问题 vs `UNKNOWN_BINDING`/`UNKNOWN_FIELD` 引用问题），两条执行路径的互斥有专门状态机与 5 条用例，流式入口与整表入口的语义差异（合并单元格、类型推断）在文档与 WARN 里都交代过；并发面很小且都用了正确的同步手段（`mode_` 与 `compileCount_` 各一把短锁，执行器本身不可变），没有发现数据竞争或栈溢出。

主要风险集中在**契约与实现的三处错位**，它们都不会在编译期暴露，也都已有测试把"现状"固化成"期望"：

- 契约面 #2：`XlsxTableParser` 类注释与 `table.cj` 把"10 万行"当卖点，但流式只覆盖读取阶段，`TableCompiler` 仍把每行编译成 `CompiledRow + Rule + Pattern` 常驻（40–80 MB 量级），T-14 只断言了 `rows.isEmpty()`，等于用一个不完整的体积不变式背书了整个链路。建议先改文档措辞 + 补一条"编译后堆增量"用例，再决定要不要做流式聚合。
- 契约面 #3 / #4：`Any` 返回 N 条与 `TableResult`「单值策略至多一条」相反；`${o}`（整事实输出）与 `Any`/`Priority`/`OutputOrder` 组合会在聚合期抛 `TYPE_MISMATCH`（`ValueKey` 不接受 `Fact`）。前者改一行 + 一条用例即可对齐 DMN，后者建议在编译期就拒掉该组合，避免运行期用错误的错误码失败。
- 资源面 #1：流式路径从头到尾没有 `ExcelSheetStream.close()`，`RowReader` 只在读到头才关；编译中途因坏单元格失败时条目流不释放，而 `XlsxTableStream` 会一直持有该 stream。这类泄漏在"批量导入一堆 XLSX 决策表"的启动场景里会累积成句柄耗尽。

性能方面本部分**没有**任何测量数据，因此只有一条可以从代码静态判定的算法问题——#5 的插入排序（`RuleOrder`/`OutputOrder` 在 10 万命中时从 O(n log n) 退化到 O(n²)）——其余 5 条假设与 5 条优化方案都标了"无基线（待验证）"，不进修复清单。下一轮最值得补的数据是假设 1（`execute` 的 O(行×事实) 占比）与假设 5（排序耗时曲线），它们决定聚合路径要不要结构改造；假设 2 则直接决定 #2 到底该改文档还是改实现。

轻度债务集中在重复逻辑（三个 enum 的 `==`/`!=`、CSV/XLSX 的 `_meta` 映射与 `salience` 解析、`HitAggregator` 的三处排序样板、`outputsOf` vs `actionFor`、两套数字推断/表头宽度）与两处死代码（`CsvScanner.start`、`let _ = condition`），修起来都轻，但 #11 的映射重复已经出现"XLSX 校验 id、CSV 不校验"的漂移，值得在下一轮一并收敛。
