# f_rule 模块审查报告（模块第 10/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个文件，全部为 `.cj`；模块整体 184 个 `.cj` + 33 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线，全部问题来源记「存量」）
- **审查重点**：规则集装配与构建期校验（`rule/*`）、决策表模型与 CSV 载体解析（`table/*`）、命中策略聚合（`HitAggregator`）、进程级共享编译器（`RuleRuntime`）；专项为求值/校验正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块第 10/12 部分，仅覆盖 `files/f_rule.part10.txt` 的 20 个 `.cj`）

> 说明：本部分不含 `.md`。§13/§14 只做跨部分抽查——用 `f_rule/doc/07-decision-table.md`、`f_rule/README.md` 与 `src/table/*` 对照，文档侧文件归其他部分，命中处已标注「文档侧属其他部分」，合并时按同一根因去重。

## 发现

### [一般][存量] CSV 未闭合引号被静默接受，剩余整个文件被吞成单元格

- **位置**：`f_rule/src/table/CsvTableParser.cj:65-111`（`scan` 循环结束处 107-109）、`:113-138`（`readQuoted` 只在遇到配对引号时置 `inQuotes = false`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 非法输入当合法）
- **证据**：静态确定 —— `scan` 的唯一退出条件是 `index >= bytes.size`；退出后只判断 `cell.size > 0 || !row.isEmpty()` 就 `flushRow()`，`inQuotes` 从未被检查，也没有「引号内 EOF」的错误分支。`readQuoted` 的 `"` 分支（114-123）是唯一清 `inQuotes` 的地方
- **描述**：`doc/07` §5.2 要求按 RFC 4180 解析，RFC 规定引号包裹字段必须闭合。当前实现下，少一个结尾引号时（常见于手工编辑或导出脚本截断）解析器会把文件剩余全部内容拼进一个单元格：若因此列数不符，会抛 `TABLE_INVALID` 但行号指向错误位置，掩盖真正原因；若列数恰好凑齐（多行内容里含逗号/换行），则得到一张**静默错误**的表——条件/输出值被整体污染，编译期不会报错
- **建议**：`scan()` 收尾处加 `if (inQuotes) { throw RuleException(TABLE_INVALID, "第 ${recordLine} 行起的引号未闭合") }`；`readQuoted` 的 EOF 路径也可直接抛错，避免走到半成品 `flushRow`

### [一般][存量] `in`/`not in`/`between` 的值列表不做引号感知切分，含逗号的值被静默拆错

- **位置**：`f_rule/src/table/CellParser.cj:152-169`（`requireList`，切分在 `:165` `for (part in inner.split(","))`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 数据错误：值被静默改写）+ §13（与载体转义约定不一致）
- **证据**：静态确定 —— `requireList` 先把 `[` `]` 剥掉再 `inner.split(",")`，没有任何引号状态；随后的 `parseValue` → `unquote`（`:289-298`）只剥**整串**两端成对的引号，不还原被切碎的值。举例：`in ['A,B']` → 切成 `"'A"` 与 `"B'"` → `unquote` 两端不成对、原样返回 → 右值变成 `"'A"`、`"B'"` 两个错误字符串
- **描述**：`doc/07` §5.2 明确「含逗号的单元格必须用双引号包裹」，而 §4.1 的列表语法 `in [A, B]` 又允许给值加引号（`CellParser_test.cj:77` 用 `not in ['A', 'B']`）。两者组合（`'A,B'`）时不会报错，只会得到两个不存在的候选值，规则随之永不命中——最典型的「同义不同形」静默失败。相关同根问题：以算子关键字开头的裸值（如文本 `in progress`）会被当成 `In` 算子并抛 `TABLE_INVALID`，当前语法没有逃生写法
- **建议**：`requireList` 改为手写一次扫描（只在引号外认 `,`），或复用一个「行内值 tokenizer」；同时补用例 `in ['A,B', 'C']`。另外在 `doc/07` §4.1 注明「值以算子关键字开头时必须显式 `=` 前缀」

### [一般][存量] CSV 全量物化、每格两次拷贝，且没有大小上限

- **位置**：`f_rule/src/table/CsvTableParser.cj:187-196`（`File.readFrom(path)` 整文件读入）、`:198-203`（字节数组 + 全部 `CsvRecord` 同时存活）、`:159-162`（`flushCell` 先 `cell.toArray()` 再 `String.fromUtf8`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）
- **证据**：静态确定（结构）—— 峰值由三部分叠加：整文件 `Array<UInt8>`（= 文件大小 S）、`cell.toArray()` 的逐格临时字节数组（`Array` 切片/`toArray` 按文档 `core_package_structs.md:1948-1958`、`5` 均为拷贝）、`String.fromUtf8` 再复制一遍字节；随后 `parseBytes` 又为每行建 `ArrayList<?String>` 并存入 `TableRow`。量级换算（按 10 MB / 10 万行 / 6 列估算：60 万格 × 约 40–48 B 对象与指针开销 ≈ 25–30 MB，加 2×S 字节 ≈ 20 MB）合计约 45–60 MB；文件线性放大、无上限可配。具体倍数**需实测**（见「待验证假设」）
- **描述**：`doc/07` §6.4 给 XLSX 提供了 `stream()` 的恒内存路径，CSV 侧只有整表路径（`DecisionTable.streaming` 对 CSV 永远 `false`，见 `DecisionTable.cj:156-160`），而 `CsvTableParser` 既不限大小也不给出拒绝路径。决策表通常在启动期加载，正常规模无碍；但误把一个几十上百 MB 的导出文件当表加载就会在启动阶段打穿内存，且报错是 OOM 而非「表太大」
- **建议**：给 `parseFile` 加可配上限（如 `maxBytes`，超限抛 `TABLE_INVALID`）；`flushCell` 改为复用同一个 `ByteBuffer`，或用 `String.fromUtf8Unchecked` 跳过二次校验（`isValidUtf8` 已整文件校验过，见下条重复逻辑）

### [一般][存量] `doc/07` 声称 `RuleException` 携带 `line`/`column`，实现两者都没有

- **位置**：`f_rule/src/table/CsvTableParser.cj:265-271`（列数错误只把 `line=${}` 拼进 message）、`f_rule/src/table/Column.cj:101-104`（表头未知列完全不提行号）、`f_rule/src/exception/RuleException.cj:26-46`（只有 `code` 与 `message`）
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现不符，须给两边位置）
- **证据**：静态确定 —— 承诺源：`f_rule/doc/07-decision-table.md:258`「错误定位：`RuleException(TABLE_INVALID)` 携带 `line`（物理行号）与 `column`（列名）」；反证：`RuleException` 类体只有 `public let code: RuleErrorCode`（`RuleException.cj:28`），全仓 `grep` 无 `line`/`column` 字段；实现侧只有部分错误把 `line=` 写进文案（`CsvTableParser.cj:268-269`、`:312`、`:319`），而表头错误（`CsvTableParser.cj:260-262` → `Column.cj:101-104`）连行号都没有。`README.md:257` 的措辞是「错误消息带物理行号」，与实现一致、与 `doc/07` 相反（文档侧属其他部分）
- **描述**：`RuleException` 的类注释明确「调用方按 `code` 分支处理，不解析 `message`」（`RuleException.cj:29-30`），而 `doc/07` 又承诺可编程读取行/列。使用者按文档写 `e.line` 会编译失败；退化成解析 message 又得不到列名。表结构错（未知列）时定位信息最缺，恰恰是最需要行号的场景
- **建议**：二选一并对齐三处文档——(a) 给 `RuleException` 增 `line: ?Int64` / `column: ?String` 两个可选字段并在 `CsvTableParser` 填充；(b) 改 `doc/07:258` 为「错误消息内带 `line=`，列名以 `column` 文案形式出现」，并让 `Column.parse` 的异常统一带上行号（在 `CsvTableParser` 侧 catch 后重抛，或在 `builder.column` 传入 line）

### [一般][存量] `ColumnKind.Metadata` 文档承诺「说明 / 启用开关」列，解析器只接受 `id`/`name`

- **位置**：`f_rule/src/table/Column.cj:77-79`（只识别 `id`/`name`）、`:101-104`（其余列名一律 `TABLE_INVALID`，错误文案自证「允许 id/name/salience/when.*/then.*/expr.*」）
- **来源**：存量
- **判据**：review-checklist §14（承诺了但没实现，双证）
- **证据**：静态确定 —— 承诺源：`f_rule/doc/07-decision-table.md:26`「`| Metadata    // 规则 id / 名称 / 说明 / 启用开关`」；缺失证据：`grep -rn '"comment"\|"description"\|"enabled"' f_rule/src` 无命中，`Column.parse` 也没有对应分支，`ColumnKind.Metadata` 的产生点只有 `Column.cj:78`
- **描述**：使用者照 `doc/07` §1 在表头加一列「说明」或「启用开关」，会在 `CsvTableParser.cj:260-262` 直接抛 `TABLE_INVALID`（未知列名），既不能注释也不能停用单行。README 的表头说明只列 `id`/`name`/`when.*`/`then.*`/`expr.*`/`salience`（`README.md:241-257` 示例与 557-560 的 API 段），与 `doc/07` 自相矛盾
- **建议**：要么实现 `comment`/`enabled` 两类元数据列（`enabled=false` 时跳过该行编译），要么把 `doc/07:26` 改为「规则 id / 名称」，并在 `doc/07` §5.1 的表头规则里写明「其余列名一律 `TABLE_INVALID`」

### [轻微][存量] `CsvScanner.start` 是死字段

- **位置**：`f_rule/src/table/CsvTableParser.cj:44`（`private let start`）、`:53-56`（init 里写一次）
- **来源**：存量
- **判据**：review-checklist §1（死字段：读了不用）
- **证据**：静态确定 —— 全仓 `grep -n "start" f_rule/src/table/CsvTableParser.cj` 只有声明、赋值与 `init` 形参三处；后续扫描全部用 `index`，`start` 再无读取点
- **描述**：构造时把 BOM 偏移存进字段纯属残留，删除不影响行为（`index = start` 已承担定位）
- **建议**：删掉字段，`init` 只保留形参

### [轻微][存量] 测试辅助 `sample` 未使用

- **位置**：`f_rule/src/table/CsvTableParser_test.cj:39-41`
- **来源**：存量
- **判据**：review-checklist §1（private 函数零调用）
- **证据**：静态确定 —— 该文件 `grep -n "sample"` 只有定义处一行，全部用例直接调 `csv(...)`
- **描述**：`sample` 函数体就是 `csv(lines)`，是改名过程的残留；测试文件内的死代码会让人误以为存在第二套构造入口
- **建议**：删除；若想表达语义可改名为局部变量或直接删

### [轻微][存量] `asRuleAction` 兼容残留，且两个实现逐字相同

- **位置**：`f_rule/src/rule/TableAction.cj:52-55`（本部分）、`f_rule/src/rule/ClosureAction.cj:34-37`（部分外）
- **来源**：存量
- **判据**：review-checklist §1（兼容残留）+ §2（重复逻辑）
- **证据**：静态确定 —— 两处方法体都是 `this`，注释也都是「兼容旧调用点：动作对象自身就是 `RuleAction`」；全仓 `grep -rn "asRuleAction" f_rule` 只有这两个定义，无调用点
- **描述**：两个类都已 `<: RuleAction`，方法恒等返回 `this`，没有存在的必要。因所属类型是 `public class`、成员对外可达，按硬原则一不判死代码；但「兼容旧调用点」已无旧调用点，属残留 API
- **建议**：确认无下游引用后删除两处（属对外可见性收窄，需用户拍板）；若保留，至少把注释改成「保留给按旧签名书写的调用方」并给出迁移说明

### [轻微][存量] `prioritySorted` 与 `OutputOrder` 分支函数体等价

- **位置**：`f_rule/src/table/HitAggregator.cj:94-96`（`OutputOrder` 分支）与 `:100-103`（`prioritySorted`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/换名字的同一套逻辑）
- **证据**：静态确定 —— 两段都是 `let names = orderedNames(hits)` + `sorted(hits) { l, r => compareOutputs(l, r, names) == Ordering.LT }`，逐字相同，只差函数封装
- **描述**：`Priority` 与 `OutputOrder` 的差异只在「取第 0 个」还是「全返回」，排序部分完全一致；两份实现将来若只改一处（比如换成 `std.sort`）就会静默漂移
- **建议**：`OutputOrder` 分支直接调 `prioritySorted(hits)`（命名可改为 `sortedByOutputs`），排序逻辑只留一份

### [轻微][存量] `number` 与 `infer` 的数值推断逻辑重复

- **位置**：`f_rule/src/table/CellParser.cj:175-188`（`number`）与 `:266-274`（`infer` 的前半段）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的近似复制）
- **证据**：静态确定 —— 两处都是「含 `.`/`e`/`E` → `Float64.parse`，否则 `Int64.parse`」，都在 `try/catch` 里；差异只有失败时的动作（抛 `TYPE_MISMATCH` vs 继续推断）
- **描述**：同一套数值判定规则写两遍，`Float64`/`Int64` 的取舍将来若调整（例如支持 `_` 分隔、支持超出 `Int64` 的整数降级为浮点），很容易只改一处，导致 `Number` 列与 `Any` 列对同一文本给出不同类型
- **建议**：抽出 `private static func tryNumber(text: String): ?Any`，`number` 在 `None` 时抛错、`infer` 在 `None` 时继续向后推断

### [轻微][存量] 手写 UTF-8 校验与 `String.fromUtf8` 重复，同一份字节扫两遍

- **位置**：`f_rule/src/table/CsvTableParser.cj:189-194`（调用）、`:347-393`（`isValidUtf8` 状态机）
- **来源**：存量
- **判据**：review-checklist §2（与标准库能力重复）+ §8（同一输入重复解析）
- **证据**：静态确定 —— `String.fromUtf8` 文档明确「入参不符合 utf-8 序列规则……抛 `IllegalArgumentException`」（`std/core/core_package_api/core_package_structs.md:6384-6386`），与 `isValidUtf8` 的职责重叠；`flushCell`（`:160`）每格都调 `fromUtf8`，等于整文件被校验两次
- **描述**：手写状态机覆盖了过长编码与代理区（`:378-389`），正确性没问题；代价是 O(S) 多扫一遍、且多维护 47 行易出错代码
- **建议**：保留一次「整文件校验」或「逐格校验」即可——推荐保留 `isValidUtf8`（能给出文件名/统一错误码），单元格改用 `fromUtf8Unchecked`；或删掉 `isValidUtf8`，把 `fromUtf8` 的 `IllegalArgumentException` 包成 `TABLE_INVALID`（`parseFile` 处 catch 一次）

### [轻微][存量] `Validator` 对每条规则都取一次共享编译器，无脚本也会触发惰性创建与 WARN

- **位置**：`f_rule/src/rule/Validator.cj:95`（`let compiler = RuleRuntime.compiler()` 在 `for (rule in ruleSet.rules)` 内）
- **来源**：存量
- **判据**：review-checklist §3（静默副作用：日志噪声）+ §6.1 / §12（无谓的全局锁流量）
- **证据**：静态确定 —— 语句位于规则循环体内、`for (source in rule.scripts)` 之前；`RuleRuntime.compiler()`（`RuleRuntime.cj:53-71`）在未注入时会创建 `Compiler` 并打一条「未注入共享 Compiler」WARN
- **描述**：N 条规则 = N 次 `synchronized(mtx)`；没有任何脚本条件的规则集也会触发惰性编译器和那条 WARN，运维看到「脚本条件将在构建期报 SCRIPT_COMPILE」的告警却根本没有脚本，属误导。多次构建时该 WARN 只出一次（`lazyWarned`），但仍是错误信号
- **建议**：把 `compiler` 提到规则循环外，并且只在 `!rule.scripts.isEmpty()` 时取；或改成惰性 `var compiler: ?Compiler = None` 首次需要时再取

### [轻微][存量] `buildOrInvalid` 成功路径上先装配一遍再丢弃

- **位置**：`f_rule/src/rule/RuleSetBuilder.cj:161`（`var ruleSet = assemble(rules_)`）、`:169`（`ruleSet = assemble(expanded)`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用：第一次装配结果在成功路径上未被使用）+ §6.4（同一输入重复处理）
- **证据**：静态确定 —— 两次 `assemble` 都会为每条规则 `withOrder` 新建一个 `Rule`（`RuleSetBuilder.cj:179-187`），成功路径上第一次的结果整体被覆盖
- **描述**：规则集每次构建都多分配 1 个 `RuleSet` + N 个 `Rule`，并在 `build()` 前多走一遍 O(N) 复制；失败路径才真正需要这份「未展开」结果
- **建议**：先算 `expanded` 再 `assemble`；`catch` 分支里才 `ruleSet = assemble(rules_)`（或直接复用失败前的对象）

### [轻微][存量] `lastError_` 不在构建入口清零，成功后仍返回旧错误

- **位置**：`f_rule/src/rule/RuleSetBuilder.cj:160-177`（`buildOrInvalid` 只在 `catch` 里赋值）、`:189-194`（`lastError()`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符：文档说「最近一次校验失败的错误」）
- **证据**：静态确定 —— 入口没有 `lastError_ = None`；一次失败后继续 `rule(...)` 再 `buildOrInvalid()` 成功时，`isValid()` 为 true 但 `lastError()` 仍返回上一次的异常
- **描述**：诊断 API 在成功构建后给出陈旧错误，调用方若按「`lastError() != None` 就当失败」判断会误报；当前用例（`RuleSetValidation_test.cj:138`、`RuleSetBuilderCondition_test.cj:223`）都只在失败后读取，所以未暴露
- **建议**：`buildOrInvalid()` 开头 `lastError_ = None`；并在 `lastError()` 文档里写明「仅当 `buildOrInvalid()` 返回的规则集 `isValid() == false` 时有意义」

### [轻微][存量] 两处注释与当前实现不符

- **位置**：`f_rule/src/rule/RuleSetBuilder.cj:26-28`（「放在包根是为了……不制造包循环」）、`f_rule/src/rule/ScriptAction.cj:32-34`（「注册为四个重载（`Int64/Float64/Bool/String`）」）
- **来源**：存量
- **判据**：review-checklist §11（注释承诺 A、实现做 B）+ §10（可维护性）
- **证据**：静态确定 —— `RuleSetBuilder.cj:16` 是 `package fountain::f_rule.rule`（不是包根），且 `RuleSet.cj:16` 同包，注释里描述的「`rule → 根包` 反向依赖」已不成立；`ScriptAction.cj:96-100` 实际注册 5 个 `set` 重载（`i64`/`f64`/`dec`/`bool`/`str`），`dec` 对应 `LocalType.DECIMAL`
- **描述**：这类过期注释会直接误导下一轮改动（例如有人照「包根」的说法把类搬走，或以为 `Decimal` 不被支持）
- **建议**：`RuleSetBuilder` 的段落改为「与 `RuleSet` 同包，因此装配器不能由 `RuleSet` 提供 `builder()`（会与 `RuleSetBuilder` 形成同包内的构造环）」；`ScriptAction` 把「四个重载」改为「五个重载（含 `Decimal`）」

### [轻微][存量] `RuleRuntime` 用两个字段表达同一状态，计数器名不副实

- **位置**：`f_rule/src/runtime/RuleRuntime.cj:36-37`（`lazyWarned` / `lazyWarnings`）、`:60-67`（`if (!lazyWarned) { lazyWarned = true; lazyWarnings += 1; ... }`）
- **来源**：存量
- **判据**：review-checklist §2（重复状态）/ §10（命名与语义）
- **证据**：静态确定 —— `lazyWarnings` 只在 `!lazyWarned` 分支内自增，恒 ≤ 1；`resetForTest()`（`:90-96`）同时清两个字段，说明它们语义相同
- **描述**：名为「计数」的字段实际只能取 0/1，测试断言（`RuleRuntime_test.cj:55`）也因此只能写 `1`；两个字段必须同步维护，容易漏清一个
- **建议**：保留一个 `lazyWarned: Bool`，把 `lazyWarningCount()` 改为 `if (lazyWarned) { 1 } else { 0 }`；或反过来只留计数并判断 `== 0`

### [轻微][存量] `ColumnKind` 用 `toString()` 字符串比较实现相等

- **位置**：`f_rule/src/table/Column.cj:38-44`（`==` 走 `this.toString() == other.toString()`，`!=` 再取反）
- **来源**：存量
- **判据**：review-checklist §10（仓颉语言特性：枚举判等应走 `match`/序数，不应构造字符串）
- **证据**：静态确定 —— `toString()`（`:28-36`）每次比较新建字符串，`!=` 又包一层；`ColumnKind` 是无载荷枚举，两种实现结果一致
- **描述**：每次 `column.kind == ColumnKind.When` 都分配一个 `String` 并逐字符比较；调用点集中在 `DecisionTable.binding`/`columnsOf`、`TableCompiler` 的列遍历，规模小（列数级），所以只算可读性/微性能问题，不是热点
- **建议**：`==` 改成 `match ((this, other)) { case (When, When) => true ... }` 或先转 `Int64` 序数比较；`!=` 保持 `!(this == other)`

### [轻微][存量] CSV 未知 `# key: value` 元数据键静默忽略，拼错即静默用默认值

- **位置**：`f_rule/src/table/CsvTableParser.cj:289-303`（`applyMetadata` 只按 `:` 拆键值，不校验键名）、`:224-259`（逐个 `metadata.get(...)`，缺失即跳过）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失：可识别的错误输入被静默降级为默认值）
- **证据**：静态确定 —— `applyMetadata` 对任意键都写入 map，`parseBytes` 只读 8 个已知键；`# hitPolciy: Unique` 这类拼写错误既不报错也不告警，最终 `hitPolicy` 取默认 `First`
- **描述**：命中策略、`factSpace`、`salience` 拼错时表仍能建起来并按默认值运行，测试与生产都难发现；对比 `required(metadata, "id")` 对唯一必填键做了校验，其余键完全没有
- **建议**：对「形如 `key: value` 但 key 不在白名单」的行记一条 WARN（普通注释没有冒号，不会误报）；或在 `applyMetadata` 里按白名单过滤并统计未知键

### [轻微][存量] 空行判定只对「单列空行」生效，多列全空行会变成无约束兜底行

- **位置**：`f_rule/src/table/CsvTableParser.cj:164-171`（`var blank = row.size == 1 && row[0].trimAscii() == ""`）
- **来源**：存量
- **判据**：review-checklist §11（边界：空行/分隔符行的处理不一致）
- **证据**：静态确定 —— 空行 `\n` 只产生 1 个空单元格 → 被跳过；但 3 列表里的 `,,\n` 会产生 3 个空单元格 → `row.size == 3` → 不当空行，落成一条「条件全空、输出全空」的数据行。是否为缺陷取决于 `TableCompiler` 是否拒绝全空行，本部分无该代码
- **描述**：在 3 列以上表里，视觉上像空行的 `,,` 行（或误粘贴的纯分隔符行）会生成一条永不产出输出的兜底规则，改变命中计数（`Collect`/`Any` 策略下尤其明显）
- **建议**：`blank` 改为「所有单元格 `trimAscii()` 后都为空」；或在 `TableCompiler` 侧拒绝全空行并给出 `line`。补一条 `,,\n` 的用例

### [轻微][存量] 决策表编译失败后仍停留在 `Assembled`，无法切回聚合路径

- **位置**：`f_rule/src/table/DecisionTable.cj:228-234`（`compile(ruleSet, compiler)` 先 `markAssembled()`）、`:242-245`（`compileInto` 同样先标记）
- **来源**：存量
- **判据**：review-checklist §11（失败路径改状态且不回滚）
- **证据**：静态确定 —— `markAssembled()` 在 `TableCompiler(...).compile()` 之前调用；`compile()` 抛 `RuleException`（未知字段、类型不匹配等）时没有任何 `catch` 回滚，`mode_` 已是 `Assembled`，随后 `TableExecutor` 调 `markExecuted()` 会抛 `TABLE_MODE_CONFLICT`（`:115-127`）
- **描述**：装配失败通常是可修复的（补齐注册、改表头），但修复后同一张表已不能走聚合路径，只能重建实例；`markAssembled` 的重复调用是允许的（`case _ =>`），所以只有「失败后改走另一条路径」被永久阻断
- **建议**：`compile`/`compileInto` 用 try/catch 在失败时回滚成 `Unbound`（需在 `markAssembled` 增加对应的 `unmark`，仍在同一把 `modeMutex_` 下），或把标记推迟到 `TableCompiler.compile()` 成功之后

### [轻微][存量] `ScriptAction` 每次构造都重刷一次全局接口绑定快照

- **位置**：`f_rule/src/rule/ScriptAction.cj:85-94`（`ensureContextRegistered` 先 `enrollInterfaceOf`，再判断 `compiler.hasClass(owner)` 提前返回）
- **来源**：存量
- **判据**：review-checklist §12.2（不必要的全局写锁与全量拷贝）/ §6.4（构建期重复工作）
- **证据**：静态确定 —— `JitBindSupport.enrollInterfaceOf`（`f_jit/src/JitBindSupport.cj:130-144`）每次都 `copyBindings` + `copyAccepts` 全量复制快照并在 `writeMtx` 下 `store`；`ScriptAction` 的调用点在 `hasClass` 早退**之前**，因此每条 `thenScript` 动作都会重刷一次，且用 `JitBindings.empty()` 覆盖 `ActionContext` 的绑定项
- **描述**：规则集里 K 条脚本动作 → K 次全局快照复制 + K 次全局写锁，构建期被串行化；若将来有代码用 `@JitBind` 为 `ActionContext` 登记真实绑定，会被这里覆盖成空。功能上目前没有第二个写入者，所以只影响构建耗时
- **建议**：用 `JitBindSupport.isInterface(owner)`（`JitBindSupport.cj:156-158`）判断是否已登记，已登记则跳过；同时把 `enrollInterfaceOf` 移进「首次注册」分支内，避免用空绑定覆盖已有项

## 优化可行性方案

### [堆内存] CSV 单元格解析去掉逐格临时数组与二次字节拷贝

- **现状**：`flushCell` 每格执行 `String.fromUtf8(cell.toArray())`：`toArray()` 产生一个 `Array<UInt8>`（按 `core_package_structs.md:1948-1958` 是拷贝），`fromUtf8` 内部再复制一份字节并做一遍 UTF-8 校验。10 万行 × 6 列 = 60 万次临时数组分配，生命周期只到下一次 `cell.clear()`
- **方案**：保留一个可复用的 `Array<UInt8>` 缓冲按需扩容，或改成「记录 (from,to) 偏移、最后一次切片」；UTF-8 合法性由 `parseFile` 的整文件 `isValidUtf8` 已保证，可改用 `fromUtf8Unchecked`（见 `core_package_structs.md:6411-6419`）省掉逐格校验
- **预期**：减少 60 万次短命数组分配与一次全量字节复制（约等于文件大小 S 的额外峰值）；GC 次数与峰值同步下降
- **代价**：`fromUtf8Unchecked` 是 `unsafe` API，安全性依赖「先整文件校验」这一前置条件；`parse(text: String)` 入口拿到的已经是合法 `String`，同样成立。需在代码里把该前置条件写成注释/断言
- **验证**：同一 10 MB/10 万行 CSV，多轮加载取 `getAllocatedHeapSize()` 增量与 RSS 峰值中位数，对照改前
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `HitAggregator` 用手写插入排序，`Priority` 只取最小值也全量排序

- **现状**：`f_rule/src/table/HitAggregator.cj:187-204` 的 `sorted` 是 O(n²) 插入排序，被 `RuleOrder`（:92-93）、`OutputOrder`（:94-96）、`Priority`（:100-103）使用；`Priority` 最终只取 `ordered[0]`，却先排完整个命中集。n = 命中行数，流式表可达 10 万行（`doc/07` §6.4）
- **方案**：① `Priority` 改为单趟取最小（O(n)）；② 需要全序时改用 `std.sort.sort(items, by: {l, r => compareOutputs(l, r, names)}, stable: true)`（`std/sort/sort_package_api/sort_package_funcs.md:463-475` 提供 `stable!` 参数，语义与现在的稳定插入排序一致）
- **预期**：`Priority` 由 O(n²) 降到 O(n)，`OutputOrder`/`RuleOrder` 由 O(n²) 降到 O(n log n)；n=10⁴ 时比较次数从 ~5×10⁷ 降到 ~1.3×10⁵ 量级（数量级估算，实际收益待测）
- **代价**：需引入 `std.sort`；`stable: true` 的常数比默认大，但只在 n 大时才有意义
- **验证**：`cjpm bench -O2` 用 1k/10k/100k 命中行分别跑 `OutputOrder` 与 `Priority`，对照改前中位数与离散程度；另用 10k 行做 `cjprof` 看 `sorted` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] CSV 的 UTF-8 校验做了两遍全量扫描

- **现状**：`f_rule/src/table/CsvTableParser.cj:189-194` 先 `isValidUtf8(bytes)` 全量扫一遍（`:347-393` 手写状态机），随后每格 `String.fromUtf8`（`:160`）内部再逐字节校验一遍；同一份 S 字节被校验两次，第二遍还拆成 60 万次小调用
- **方案**：整文件校验保留一次；单元格构造改用 `fromUtf8Unchecked`（前置条件由整文件校验保证），或直接依赖 `fromUtf8` 的 `IllegalArgumentException` 并把 `isValidUtf8` 降级为「仅在抛错时用于定位」
- **预期**：去掉一次 O(S) 扫描 + 每格一次 UTF-8 状态机；具体占比待测
- **代价**：`unsafe` API；错误码需要从 `IllegalArgumentException` 包装成 `TABLE_INVALID`（现在由 `isValidUtf8` 提前给出）
- **验证**：`cjpm bench -O2`，输入 10 MB 合法 CSV 与 1 处非法字节的 CSV 各跑 20 轮，对照耗时中位数；并确认非法字节仍抛 `TABLE_INVALID`
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | CSV 解析峰值内存约为文件大小的 2–4 倍 + 每格 ~40 B 对象开销，大文件会在启动期打穿容器内存 | `f_rule/src/table/CsvTableParser.cj:187-203` | 峰值 RSS / `getUsedHeapSize()` 与文件大小的比值 | 用 10 MB / 50 MB 两张同构 CSV 各加载 10 轮，记录进程峰值 RSS 与 `getAllocatedHeapSize()` |
| 2 | `HitAggregator.sorted` 在万级命中行时成为聚合路径热点（插入排序 O(n²)） | `f_rule/src/table/HitAggregator.cj:187-204` | 自耗时占比、n 与耗时的增长曲线 | `cjprof record` 跑 `TableExecutor` + `OutputOrder`，输入 1k/10k/100k 行；同时记录 n 翻倍时耗时倍数 |
| 3 | `ScriptAction` 共享同一个 `JitFunction` 被多线程并发 `call` 是否安全（`compiled_` 是规则集级单例，`JitFunction` 内部有 `active`/`lastEscaped` 等可变字段） | `f_rule/src/rule/ScriptAction.cj:66-69`、`f_jit/src/JitFunction.cj:59-115` | `JitFunction.call` 的线程安全契约 | 查 `f_jit` 的并发契约文档；若未声明，用两线程各 10 万次执行同一条 `thenScript` 规则，比对输出与异常率 |
| 4 | `ColumnKind.==` 用 `toString()` 字符串比较在编译期列遍历中占比可忽略（预计 <1%，仅登记） | `f_rule/src/table/Column.cj:38-44` | 单次比较耗时与调用次数 | 对 `TableCompiler` 编译一张 6 列 / 10 万行表做 `cjprof`，看 `ColumnKind.toString` 累计占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/rule/RuleSetBuilder.cj` | .cj | ✅ | 见发现「重复装配」「`lastError_` 不清零」「注释与实现不符」 |
| 2 | `f_rule/src/rule/ScriptAction.cj` | .cj | ✅ | 见发现「重复 enroll」「注释四/五个重载不符」；并发见假设 3 |
| 3 | `f_rule/src/rule/TableAction.cj` | .cj | ✅ | 见发现「`asRuleAction` 兼容残留」 |
| 4 | `f_rule/src/rule/TableSource.cj` | .cj | ✅ | 单方法接口，`DecisionTable` 实现，无问题 |
| 5 | `f_rule/src/rule/Validator.cj` | .cj | ✅ | 见发现「每规则取一次 `compiler()`」 |
| 6 | `f_rule/src/rule/rule.cj` | .cj | ✅ | `Rule` 不可变、`withOrder`/`withId` 共享数组，无问题 |
| 7 | `f_rule/src/runtime/RuleRuntime.cj` | .cj | ✅ | 见发现「双状态字段」；锁使用正确 |
| 8 | `f_rule/src/runtime/RuleRuntime_test.cj` | .cj | ✅ | 4 条用例与三条不变量一致，无问题 |
| 9 | `f_rule/src/table/CellParser.cj` | .cj | ✅ | 见发现「列表切分不识别引号」「`number`/`infer` 重复」 |
| 10 | `f_rule/src/table/CellParser_test.cj` | .cj | ✅ | 覆盖 13 种写法；无缺陷 |
| 11 | `f_rule/src/table/Column.cj` | .cj | ✅ | 见发现「Metadata 列名不足」「`==` 走字符串比较」 |
| 12 | `f_rule/src/table/CsvTableParser.cj` | .cj | ✅ | 见发现「引号未闭合」「全量物化」「`line`/`column` 不符」「`start` 死字段」「元数据键静默忽略」「空行判定」 |
| 13 | `f_rule/src/table/CsvTableParser_test.cj` | .cj | ✅ | 见发现「`sample` 未使用」；断言与外层实现一致 |
| 14 | `f_rule/src/table/DecisionTable.cj` | .cj | ✅ | 见发现「编译失败仍留 Assembled」；`mode` 互斥锁正确 |
| 15 | `f_rule/src/table/DecisionTableBuilder.cj` | .cj | ✅ | 列/行校验完整，无问题 |
| 16 | `f_rule/src/table/DecisionTableBuilder_test.cj` | .cj | ✅ | 与实现一致，无问题 |
| 17 | `f_rule/src/table/ExprColumn.cj` | .cj | ✅ | 空单元格/`-` 返回 `None`，与文档一致 |
| 18 | `f_rule/src/table/ExprColumn_test.cj` | .cj | ✅ | JIT/解释器两条路径都覆盖，无问题 |
| 19 | `f_rule/src/table/FixtureTable_test.cj` | .cj | ✅ | 依赖 `src/fixtures/*.csv` 与 `TableCompiler/TableExecutor`（部分外），仅作端到端线索 |
| 20 | `f_rule/src/table/HitAggregator.cj` | .cj | ✅ | 见发现「`prioritySorted` 重复」与 CPU 方案「插入排序」 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2（引号未闭合、列表切分）；设计 1（编译失败不回滚模式位）；语言特性 1（`ColumnKind` 用 `toString` 实现 `==`）；可读性 2（两处注释与实现不符、`RuleRuntime` 双状态）；安全性 0（无 SQL/命令/路径拼接，CSV 与规则表来自运维文件而非请求体，未发现注入面） |
| §1 死代码 | 2 | `CsvScanner.start`（`:44` 写入后从不读取，全文件仅 `:55-56` 出现）；`CsvTableParser_test.sample`（`:39-41`，全文件零调用）。其余 private/internal 逐个搜过：`CsvRecord`/`CsvScanner` 成员、`CellParser` 的 11 个 private 静态函数、`Column.conditionColumn`、`DecisionTableBuilder.columnType`/`rowSource`/`header`、`Rule.withId`、`Validator.pairCompatible`、`ConditionExpander` 调用链均有引用。`public` 且对外可达的一律不判（`TableAction.asRuleAction`、`DecisionTable.columnsOf`、`RuleRuntime.resetForTest`/`lazyWarningCount` 仅测试或仓内零引用，按硬原则一不算死代码，只记信息）。`RuleSetBuilder.cj:142-148` 的 `case None` 目前不可达（`markInvalid` 只与 `lastError_` 同时发生），属防御性兜底，不计 |
| §2 重复逻辑 | 4 | `HitAggregator.prioritySorted`（:100-103）与 `OutputOrder` 分支（:94-96）函数体等价；`CellParser.number`（:175-188）与 `infer`（:266-274）的「含 `.`/`e`/`E` 判浮点 + try/catch」逐字重复；手写 `isValidUtf8`（`CsvTableParser.cj:347-393`）与 `String.fromUtf8` 的校验重复（同一份字节扫两遍）；`TableAction.asRuleAction`（:52-55）与 `ClosureAction.cj:34-37` 完全同形同注释。`CsvTableParser` 的 7 段 `match (metadata.get(...))` 形状相近但 setter 与解析各不相同，判为可读性而非重复；`DecisionTableBuilder.row` 家族是接口重载，不判 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `UnsupportedException`。5 处 `catch (_: Exception)`（`CellParser.cj:185`、`:252`、`:260`、`:272`，`CsvTableParser.cj:327`）都是「转成 `RuleException(TYPE_MISMATCH)`」「推断失败继续下一候选」或「解析失败改用兜底值」，均非静默吞错 |
| §4 栈溢出 | 0 | 唯一递归链是 `parseValue → list → requireList → parseValue`，第二层起 `fieldType` 固定降级为 `Any`（`CellParser.cj:171-173`），按代码推进最深 3 层、与输入括号嵌套无关；`HitAggregator`/`CsvScanner`/`Validator`/`ConditionExpander` 均为迭代实现。条件树展开另有 `maxExpansions = 64` 上限（`ConditionExpander.cj:32`） |
| §5 OOM | 1 | CSV 全量物化 + 每格两次拷贝且无大小上限（见发现）。其余无「按不可信长度预分配」「只增不减的全局容器」：`RuleRuntime.shared` 单实例、`DecisionTable.rows` 由表结构决定 |
| §6.1 热点瓶颈 | 0 | 本轮无 bench / `cjprof` 数据，不成立任何热点结论；候选（`HitAggregator.sorted`、CSV 解析、`ColumnKind.==`）全部进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 临界区只有内存操作：`RuleRuntime.compiler()`（:54-70，锁内只构造 `Compiler` 与写两个标量）、`DecisionTable.mode`（:91-127，锁内只有 `match`+赋值），无 I/O、解析、回调 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get`、无线程池 |
| §6.4 低效算法 | 1 | `HitAggregator.sorted` 为 O(n²) 插入排序且 `Priority` 只需最小值（见 CPU 方案）；无占比数据，故不进缺陷、只进方案与假设 |
| §7 降堆内存方案 | 1 | CSV 逐格临时数组与二次字节拷贝（`无基线（待验证）`）。`buildOrInvalid` 的重复装配已作为静态确定的轻微缺陷计入「发现」，不再重复列为方案 |
| §8 降 CPU 方案 | 2 | `HitAggregator` 排序；CSV UTF-8 双次全量扫描。均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选是 `CsvScanner.flushCell` 的临时字节数组与 `CellParser.requireList` 的临时 `ArrayList`，但收益只能靠峰值内存对照证明；`String.fromUtf8` 无 local mode 重载（需 `exclave`/重建），且 `--enable-local-mode` 为实验特性、`cjLocalRegionMaxSize` 会引入新 OOM 面。结论：不可证明收益，不列为方案 |
| §11 现有代码的 BUG（存量） | 7 | 一般 2：「引号未闭合静默接受」「列表切分不识别引号」；轻微 5：「未知 `#` 元数据键静默忽略」「空行判定只覆盖单列」「`lastError_` 不清零」「两处注释与实现不符」「编译失败仍留 `Assembled`」。另逐条核对了 `DecisionTableBuilder.rowAt` 宽度校验、`HitAggregator` 五种策略的零/单/多命中分支、`Validator` 的 `getOrThrow` 前置条件（均先 `has`/`contains` 校验）、`CsvScanner` 行号推进（`\n` / `\r\n` / 引号内换行）与 `CsvTableParser.headerIndex` 越界（`record.cells.size == headerRecord.cells.size` 已保证），未再发现缺陷 |
| §12 并发安全与锁粒度 | 0 | 逐点核对：`RuleRuntime` 全局 `shared` 有 `Mutex`（无双重检查锁缺陷）；`DecisionTable.mode_` 有专用 `Mutex`，`markAssembled`/`markExecuted` 的检查-然后-写入在同一临界区；`HitAggregator`/`CellParser`/`CsvTableParser`/`Column` 无可变共享状态；`RuleSetBuilder` 为 builder，无线程安全承诺。流式表 `rowIterator()` 共享底层流属已声明限制（`DecisionTable.cj:162-167` 注释 + `doc/07` §6.4），按契约由调用方串行，不判缺陷。唯一未定项是 `ScriptAction` 共享 `JitFunction` 的并发调用，见假设 3（待确认） |
| §14 功能完备性与 README 覆盖 | 1 | `ColumnKind.Metadata` 承诺「说明/启用开关」但解析器只认 `id`/`name`（见发现，随 `doc/07` 一并在合并时去重）。抽查本部分 public API 与 `README.md:555-580` 的声明块：`TableAction`（README 未列，属内部动作实现）、`CellParser`/`Column`/`ExprColumn`/`HitAggregator` 未进声明块但 `doc/07` §4.1/§1/§4.3/§2 有对应章节，不判「公开 API 未文档化」；`CsvTableParser.parse/parseFile`、`DecisionTableBuilder` 的公开方法在 README 与 `doc/07` 均齐全 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个 `.cj` 全部读完；本部分无 `.md`，§13 只做跨部分抽查（`doc/07-decision-table.md`、`README.md`），文档侧归属其他部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 16 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

> 存量 21 条（5 一般 + 16 轻微），是否纳入修复待用户决定；本部分不含「本次改动」来源。

## 总评

本部分是全模块的「装配 + 载体」层：`Rule`/`RuleSetBuilder`/`Validator` 的职责划分清楚，`Validator` 的检查顺序（空间 → 规则身份 → 模式 → 算子类型）与错误码一一对应，注释把设计取舍（仓颉关键字改名、条件树 DNF 展开上限、表/聚合两条路径互斥）写得很到位；`DecisionTable.mode` 的双路径互斥用单把 `Mutex` 做成原子检查-然后-写入，`RuleRuntime` 的共享编译器也走了锁而不是双重检查锁，并发面无缺陷。**没有阻塞项，也没有严重问题**——12 个子轮里这一部分可以按「可排期」处理。

真正的风险集中在 CSV 载体：「引号未闭合」与「列表值含逗号」两处会让畸形输入静默产出**错误的命中结果**（不报错、不告警），建议优先修；同类还有「未知 `#` 元数据键拼错静默用默认策略」，因可用性影响较小只记轻微。`doc/07:258` 承诺的 `line`/`column` 与 `RuleException` 实际字段不符，属文档契约漂移，应与文档侧的本轮结论合并后一并订正；`ColumnKind.Metadata` 承诺的「说明/启用开关」列同理。内存面只有 CSV 全量物化一条（无上限、每格两拷贝），量级是「文件大小的数倍」，在启动期加载的常规规模下不构成事故，但值得加一个 `maxBytes` 拒绝路径。

轻微项多为可维护性：一处死字段、一处未使用的测试辅助、`asRuleAction` 兼容残留、三处重复实现、两处过期注释、`lastError_` 未清零、每规则取一次 `compiler()`、`ScriptAction` 每次构造都重刷一次全局绑定快照、`RuleRuntime` 双状态字段、`ColumnKind` 走字符串判等、空行判定只覆盖单列、编译失败不回滚模式位。这些不影响正常路径行为，但会让下一轮改动更容易踩到「注释说 A、代码做 B」。性能结论本轮一律未成立（无 bench / `cjprof` 数据），`HitAggregator` 的 O(n²) 插入排序是最值得下一轮补数据的一项：它在 `Priority` 场景只需单趟最小值，改动小、验证成本低。
