# f_base 模块审查报告

> **模块第 1/3 部分**（本报告只覆盖 `files/f_base.part1.txt` 列出的 20 个文件：`README.md`、`README_en.md` 与 `src/` 下 `Arch` → `ExtendString` 的 18 个 `.cj`。`ExtendThreadLocal` / `FutureTask` / `HashBuilder` / `Options` / `Result` / `signal` 等剩余 34 个 `.cj` 由第 2、3 部分产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（本部分 18 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，`git status` 干净，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：基础并发原语正确性与可见性、栈溢出、OOM、死代码、重复逻辑、存量 BUG（本部分涉及的并发面是 `Iterator.async()` 的 `spawn`；`FutureTask` / 锁 / 原子量在后续部分）
- **报告版本**：v1（第 1/3 部分）

## 发现

### [严重][存量] #1 `Iterator.groupBy` 的新键分支从未把分组建回 HashMap —— 返回值恒为空 map

- **位置**：`f_base/src/ExtendIterator.cj:108-119`（关键在 `112-116`：`if (let Some(list) <- m.get(k)) { list } else { ArrayList<T>() }.add(t)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「逻辑错误 / 空集合未处理」、§14「承诺了但没实现」
- **证据**：静态确定 —— 整个 `for` 循环体内对 `m` 只有一次 `m.get(k)`（读），**没有任何写操作**（无 `m[k] =`、无 `m.add`、无 `put`）。因此从 `HashMap<K, ArrayList<T>>()` 创建到 `118` 行返回，`m` 始终为空。两种可能的解析（`.add(t)` 作用于整个 if-else 表达式，或只作用于 else 块的值）都得到同一结果：新键创建的 `ArrayList` 被 `.add(t)` 一次后即丢弃，`m` 里永远不会出现条目。
- **描述**：README（`README.md:146-149`）与接口签名（`ExtendIterator.cj:53`）都把 `groupBy` 描述成"按 key 分组"。实际行为是"吞掉全部元素后返回空 map"，无异常、无日志。**这不是理论缺陷，仓内已有两处真实调用**：
  - `f_orm/src/migro/SchemaFinderMediator.cj:29-30`：`TableMetas.tableMetas().groupBy{m => m.driver}` → `metasByDriver` 恒空 → `generate()` 的 `flatMap` 一次都不执行 → **schema 迁移一行 SQL 都不生成**（静默无输出，退出码仍是成功）。
  - `f_orm/src/migro/MysqlSchema.cj:88-91`：`... .groupBy{po => po.name}.iterator()` → `findIndexes` 恒返回空 → 调用方拿到"库里没有任何索引"，`generateIndexSql` 的 `currentIndexes` 恒为空（下游是否因此重复建索引需实测，但"现存索引信息全部丢失"是静态确定的）。
- **建议**：改成显式两段写入：`if (let Some(list) <- m.get(k)) { list.add(t) } else { let list = ArrayList<T>(); list.add(t); m[k] = list }`；或 `m.addIfAbsent(k, ArrayList<T>())` 之后再 `m[k].add(t)`（注意 `get` 返回的是引用副本，必须真正写回 map）。补一条用例：3 个元素分 2 组，断言 `m.size == 2` 且各组元素数正确——本模块目前除 `Comparator_test` 外没有任何 `groupBy` 用例。

### [严重][存量] #2 `AsyncIterator.next()` 每元素 `spawn` 一个线程，且这些线程并发推进同一个非线程安全迭代器

- **位置**：`f_base/src/ExtendIterator.cj:20-27`（`next()` 在 `22`，`spawn { itr.next() }` 在 `23-25`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「异步语义」、§5「一次提交全量任务 / 无界容器」
- **证据**：静态确定 —— `next()` 只做 `spawn`，不等待；`itr` 是构造时持有的**同一个** `Iterator<T>` 实例（`21` 行 `private let itr`），`spawn` 体里直接 `itr.next()`，无锁、无串行队列。于是：
  1. 调用方连续两次 `next()`（`for (f in it.async())` 就是这个节奏）时，第一个 `spawn` 线程可能还没跑完，第二个线程已经在调 `itr.next()` —— 两个线程同时推进同一份迭代器状态（`ArrayList` / `HashMap` 迭代器、扫描器之类全部非线程安全）。后果是丢元素、重复元素或迭代器内部状态损坏，属数据竞争。
  2. 消费者若把返回值物化（`it.async().toArray()` / `toArrayList()`，`ExtendIterator.cj:46-51`），会在一瞬间创建 `n` 个线程并持有 `n` 个 `Future`，无窗口、无上限 ⇒ 大集合直接线程创建失败或 OOM。
- **描述**：README（`README.md:130-131`）确实写明"每次执行 `next()` 都创建一个新线程"，即线程-per-元素是有意设计，但设计里没有回答"底层迭代器能不能被并发 advance"。当前实现让"有意的线程创建"直接变成"无意的并发读写同一迭代器"，同时顺序也不再保证（返回值顺序与元素顺序无关）。
- **建议**：`AsyncIterator` 内部加一把 `Mutex` 把 `itr.next()` 串行化（代价是失去并行，但这本来也并行不了）；若目的是"预取"，改成 `next()` 同步取出元素、只把后续处理交给 `spawn`（`spawn { f(v) }` 而不是 `spawn { itr.next() }`）。另外在 README 与类型注释里写清"每元素一个线程、无上限"，并给 `async()` 增加有界变体（窗口大小参数）供 `toArray()` 这类物化路径使用。

### [一般][存量] #3 `filterType(exactly:)` 的 `exactly` 参数完全没有效果，与 README 承诺相反

- **位置**：`f_base/src/ExtendIterator.cj:31-36`（`32` 行 `for (v in itr where (exactly && TypeInfo.of(v) == TypeInfo.of<R>()) || v is R)`）；文档侧 `README.md:136-137`、`README_en.md:137-138`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「读了不用 / 语义与注释不符」、§13「文档承诺与实现不符」
- **证据**：静态确定 —— 布尔等价变形：`(exactly && E) || S`，`E` 是"精确类型相等"，`S` 是"`v is R`"（子类型判定）。`exactly == false` 时退化为 `S`；`exactly == true` 时，`E` 成立必有 `S` 成立，整个表达式仍等价于 `S`。即两种取值行为完全相同，"只返回精确类型"从未实现。`for ... where` 是过滤器这一点见语言文档 `docs/dev-guide/source_zh_cn/function/function_call_desugar.md:105`。
- **描述**：README 明确承诺 `exactly: true` 时"每个元素类型必须是 R 类型才会返回；`exactly: false` 时必须是 R 的子类型"。实际 `exactly: true` 也会放行子类实例，调用方按文档写"精确过滤"会拿到不该拿的元素（例如 `filterType<Exception>(exactly: true)` 会把 `BaseException` 子类一起放行）。参数存在但无作用，属"读了不用"的契约缺陷。
- **建议**：拆成两个分支：`where TypeInfo.of(v) == TypeInfo.of<R>()`（`exactly` 真）与 `where v is R`（`exactly` 假）；并补两条用例（父类型 + 子类型元素各一组）。

### [一般][存量] #4 `Array.grow` 的 `First` / `Last` / `Repeat` 在空数组上越界或除零；`arr * 0` 反而抛异常

- **位置**：`f_base/src/ExtendArray.cj:60-82`（`64` 行 `case First => this[0]`、`65` 行 `case Last => this[this.size - 1]`、`68-73` 行 `Repeat` 分支的 `this[i % s]`）、`94-96` 行 `operator *`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」「空集合未处理」
- **证据**：静态确定 —— 三条路径都没有 `s == 0` 判断：
  - `grow(n, new: First)`：空数组时 `this[0]` → `IndexOutOfBoundsException`；
  - `grow(n, new: Last)`：空数组时 `this[-1]` → `IndexOutOfBoundsException`；
  - `grow(n, new: Repeat)`：`s == 0` 且 `n > 0` 时 `this[i % s]` → 整数除零（仓颉算术运算溢出/非法会被检测并抛异常，见 `docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md:5`）；`s == 0` 且 `n == 0` 时 lambda 一次都不执行，**静默返回空数组**，比抛异常更难发现。
  另：`operator *(repeat)` 走 `grow(this.size * repeat, ...)`，`check()`（`55-59`）在 `size * repeat < size` 时抛 `IllegalArgumentException`，所以非空数组 `* 0` 抛异常而不是返回空数组——与"重复 0 次"的直觉不符。
- **描述**：文档注释（`27-31`、`39-43`）只承诺"new size 小于当前大小时抛 `IllegalArgumentException`"，没有承诺空数组行为；调用方在"表为空也要扩到 N 并用首/尾值填充"这种常见写法上会拿到越界或除零异常，异常类型还与注释写的 `IllegalArgumentException` 不一致。
- **建议**：`check` 里补空数组分支：`First` / `Last` / `Repeat` 在 `s == 0` 时抛带明确消息的 `IllegalArgumentException`（或按 `ZeroValue` 语义填充，二者取一并在注释与 README 写明）；`operator *` 对 `repeat <= 0` 先判断（`0` 返回空数组、负数抛 `IllegalArgumentException`）。

### [一般][存量] #5 `BaseException.printStackTrace` 无环检测：`addSuppressed(this)` 或互指的 suppressed 会无限递归爆栈

- **位置**：`f_base/src/BaseException.cj:71-86`（递归点在 `74` 的 `printStackTrace(this, w)`、`77` 的 `printStackTrace(c, w)`、`82` 的 `printStackTrace(s, w)`）；写入入口 `59-61` 的 `addSuppressed` 不做任何校验
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「自引用结构 ⇒ 递归打印无限递归（崩溃，不是慢）」、§11「契约不符」
- **证据**：静态确定 —— `addSuppressed(suppressed: Exception)` 把任意 `Exception`（包括 `this`）加入列表，`printStackTrace` 对列表逐个递归调用 `printStackTrace(s, w)`，链上没有任何 visited 集合或深度上限。`e.addSuppressed(e)` 一行即可构造自环，`a.addSuppressed(b); b.addSuppressed(a)` 构造互环，两者都无限递归直到栈溢出。`causedBy` 一条链由构造函数固定、构造期无法自引用，因此只有 `suppressed` 面可被触发。
- **描述**：这是"打印诊断信息时崩掉进程"的形态：出错路径本来就要打日志，日志一打反而栈溢出（在信号处理 / 退出回调里还会连带丢失现场）。仓内 `addSuppressed` 有 20+ 处调用（`f_orm/src/base/SqlExecutor.cj:349-373`、`f_store/src/store_func.cj:142-161`、`f_rpc/src/client/RPCClient.cj:194-228` 等），目前都是"不同异常"，但该 API 对调用方完全开放，且没有任何注释约束"不得自引用"。
- **建议**：`printStackTrace` 走一个 `HashSet<Exception>`（按引用身份）做 visited 检测，命中即打印 `[CIRCULAR REFERENCE]` 并返回；或至少给递归加深度上限（如 32 层）。`addSuppressed` 增加 `if (suppressed === this) { return }` 之类的自引用短路。

### [一般][存量] #6 `ExtendRune` 的加减重载入参范围处理不一致：`UInt64` 版实际只吃 32 位，有符号版对 `MIN` 取负会抛溢出

- **位置**：`f_base/src/ExtendRune.cj:103-108`（`+(n: UInt64)` / `-(n: UInt64)` 都转 `UInt32(n)`）、`40-53` / `60-73` / `89-102`（有符号版 `UInt32(-n)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「边界差一」、§10「类型使用」
- **证据**：静态确定 —— `UInt64 → UInt32` 是窄化转换，仓颉在运行期检测溢出并抛异常（`docs/dev-guide/source_zh_cn/basic_data_type/integer.md:137`：类型转换溢出"根据默认的溢出策略将抛出异常"）。所以 `rune + 5u64` 正常，`rune + 0x1_0000_0001u64` 抛 `ArithmeticException` —— 签名宣告接受 `UInt64` 全范围，实现只支持 `0 ..= UInt32.MAX`。有符号版对 `Int8.MIN`（`-128i8`）执行 `-n` 时 `-(-128)` 超出 `Int8` 范围，同样触发溢出异常；`Int16/Int32/Int64` 的 `MIN` 同理。
- **描述**：两个问题同源（没有做范围归一化就套用更窄的类型）：① `UInt64` 重载的"能力"与签名不符，调用方在偏移量较大时拿到溢出异常而不是"越界"语义；② `MIN` 取负是"先取绝对值再判断正负"写法的经典坑，`rune + Int64.MIN` 会直接抛异常而非往回走一大截。
- **建议**：`UInt64` 版先 `if (n > UInt32.MAX) { throw IllegalArgumentException(...) }`（或返回 `Option` / 做饱和），并在接口注释写明有效范围；有符号版改掉 `-n` 写法（用 `@OverflowWrapping` 的按位加，或先把 `n` 提升到 `Int64` 再判断），并在 README 的扩展开关清单里注明范围。

### [一般][存量] #7 `CpuFeatures_test.cj` 缺 Apache 版权头

- **位置**：`f_base/src/CpuFeatures_test.cj:1`（文件第 1 行直接是 `package fountain::f_base`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：`fountain-baseline.md` §3「每个 `.cj` 文件必须有 Apache 2.0 版权注释，位于 `package` 之前；缺头按一般报」
- **证据**：静态确定 —— 同目录 `Comparator_test.cj:1-15` 有完整头，本文件没有；`cjpm.toml` 的 `include=["src"]` 会把 `src/*_test.cj` 一起发布（`README.md:725` 已确认），缺头会随制品外发。
- **描述**：合规性问题，影响制品对外发布；顺带该文件只有 1 个用例，注释写"本机 aarch64 恒 false"，但断言只在 `!Arch.current.isX86_64` 时执行（`13-15`），x86_64 上真正被验证的只有"两次读数一致"。
- **建议**：补 `Copyright (c) 2025/2026 WuJingrun（吴京润）` + Apache 2.0 全文头；用例补一条 x86_64 + Linux 下"`/proc/cpuinfo` 含 `sse4_1` ⇒ true"的正向断言。

### [轻微][存量] #8 `Comparator_test` 第 28 行断言写错：`create()` 从未被验证，且留下未读变量

- **位置**：`f_base/src/Comparator_test.cj:27-28`（`let comparator = Comparator<Int64>.create<Int64>()` 之后断言仍用 `cmp`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失」、§1「局部变量赋值后未被读取」
- **证据**：静态确定 —— `@Assert(Ordering.LT, cmp(1, 2))` 与上一行完全相同，`comparator` 构造后无人使用；`create()` 产出的比较器即使实现为空也会通过用例。
- **描述**：用例给出的是"测试通过"的假信号，`create` / `reverse` / `then` 全部无覆盖（`reverse`、`then` 在仓内也无其他用例）。
- **建议**：改为 `@Assert(Ordering.LT, comparator(1, 2))`，并补 `reverse()` / `then()` 的行为断言。

### [轻微][存量] #9 `Option<T>.map`（internal 扩展）在本包及子包内零引用

- **位置**：`f_base/src/ExtendOption.cj:51-57`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1（`extend` 内未写修饰符的成员默认 `internal`，见 `docs/dev-guide/source_zh_cn/extension/access_rules.md:20`）
- **证据**：静态确定 —— `grep -rn "\.map{\|\.map(" f_base/src`（含 `src/macros`）零命中，全包没有调用点；`Option<T>` 是 std 类型，std 自带 `map`（返回 `Option<R>`），本扩展提供的是"返回 `?O` 时自动拍平"的重载。
- **描述**：死代码 + 语义陷阱：同名不同语义的重载会让 `opt.map{f}` 的返回类型依赖 `f` 的返回类型，读代码时容易误判是否需要再拍平。
- **建议**：删除；若确实需要"拍平 map"，改名 `flatMap` 并 `public` 出去（变成对外契约），同时进 README。

### [轻微][存量] #10 `flatten` 两个分支逐字重复，且异常消息里的类型写成了 `Iterator<R>`

- **位置**：`f_base/src/ExtendIterator.cj:77-94`（`79-85` 与 `87-93` 的 lambda 只差兜底值；`83` 行的 `TypeInfo.of<Iterator<R>>()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 只改一个分支」、§11「语义与注释不符」
- **证据**：静态确定 —— 两段 `match` 主体一致，唯一差异是 `case _`（`throw` vs `EmptyIterator`）。错误消息在"元素不是 `Iterable<R>`"时却说"`T` does not match `Iterator<R>`"，把元素类型和迭代器类型混为一谈。
- **描述**：重复只是可维护性问题，但错误消息会直接误导排查（使用者会去找 `Iterator<R>` 的匹配问题，真正不匹配的是元素与 `Iterable<R>`）。
- **建议**：抽 `flatten<R>(missing: () -> Iterator<R>)` 单一实现；消息改为 `'${TypeInfo.of<T>()} element does not implement Iterable<${TypeInfo.of<R>()}>'`。

### [轻微][存量] #11 `Option` 的 12 组运算符扩展是同一模板的逐字复制

- **位置**：`f_base/src/ExtendOption.cj:138-313`（`+` `140-147`、`-` `151-163`、`*` `167-174`、`/` `178-190`、`%` `194-206`、`**` `210-222`、`&` `226-238`、`|` `242-254`、`^` `258-270`、`<<` `285-297`、`>>` `301-313`；`!` `274-281` 结构略异）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定 —— 每组两份重载：`(other: T)` 直接 `call<T>{x => x OP other}`；`(other: ?T)` 先 `call<?T>{x => match(other){ Some(y) => x OP y; _ => None }}` 再 `?? None<T>`。除运算符符号外无差异，10 组完全同构。
- **描述**：仓颉的运算符是符号级重载，无法用泛型参数化运算符本身，**不能**简单抽一个函数；但可以宏生成，或至少统一写法。当前已出现不一致：`+` / `*` 写成 `other OP x`（依赖对称性），`-` / `/` / `%` 用 `match`——若哪天补上非交换运算就很容易漏改。
- **建议**：确认 `+` / `*` 的 `other OP x` 是否只是笔误（语义等价则统一成 `match` 版本）；若要合并，用 `f_macros` 的代码生成能力，不建议手写 helper 增加间接层。

### [轻微][存量] #12 `ExtendNumber` 的 8 份数值实现逐字复制，`isOdd` 覆盖属冗余

- **位置**：`f_base/src/ExtendNumber.cj`：`numberOfLeadingZeros` 8 份（`82-99`、`166-187`、`255-281`、`350-380`、`450-466`、`533-553`、`621-645`、`714-742`）、`isEven` / `isOdd` 各 8 份（`isOdd` 在 `105-109`、`193-197`、`287-291`、`386-390`、`472-476`、`559-563`、`651-655`、`749-753`）、`to<T>()` 8 份大 `match`（`119-132`、`207-220`、`301-314`、`400-413`、`486-499`、`573-586`、`665-678`、`763-776`）、`toUInt` / `toInt` 8 份、`zero` / `one` / `ten` 8 组
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名」；误报边界见该节"泛型不能乱上"
- **证据**：静态确定 —— `Integer` 接口已给 `isOdd` 默认实现（`38-42`：`prop isOdd { get() { !isEven } }`），8 个 `extend` 又把完全相同的 `isOdd` 覆盖一遍，纯冗余；`numberOfLeadingZeros` 的 8 份只有位宽常量与移位档位不同（算法同源，缺 `1<<32` 一档）。
- **描述**：仓颉没有"泛型数值 + 静态分派到原生类型"的机制，逐类型实现是**语言限制下的合理选择**，因此不判"应该抽泛型"；这里只报两件确定可做的事：① `isOdd` 的 8 份覆盖可整段删除（接口默认实现结果相同）；② `to<T>()` 的 8 份 `match` 是唯一靠"复制 + 改 case 顺序"维护的地方（`Int8` 版把 `?Int8` 放首、`UInt64` 版把 `?UInt64` 放尾），已出现排列漂移风险，适合宏生成。
- **建议**：删除 8 处 `isOdd` 覆盖；`to<T>()` 用 `f_base.macros` 按"源 → 目标类型"表生成，或至少在每份实现顶部加"与 `Int8` 版逐 case 对齐"的注释，并补一组交叉转换用例（`Int8(-1).to<UInt8>()`、`UInt8(255).to<Int8>()` 这类符号扩展点）。

### [轻微][存量] #13 `Comparator.then` / `Equaler.then` / `comparing` / `equalling` 的函数版与结构体版重载实现完全重复

- **位置**：`f_base/src/Comparator.cj:39-46` 与 `47-54`、`70-77` 与 `78-85`、`60-64` 与 `65-69`；`f_base/src/Equaler.cj:30-37` 与 `38-45`、`61-68` 与 `69-76`、`51-55` 与 `56-60`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 结构体版内部就是 `Comparator<T>{...}` / `Equaler<T>{...}` 包一个同签名函数成员，两组重载的 lambda 体逐行相同，差异仅"入参是函数值还是包装类型"。
- **描述**：重复带来的不是行为差异而是**漂移风险**：`then` 的 EQ 判定、`comparing` / `equalling` 每次比较调用一次 mapper 的约定，在两份里必须保持一致，后续只改一处就会分叉。`Comparator.comparator` 已是 `public let`，结构体版完全可以转发。
- **建议**：结构体版统一转发：`then(comparator: Comparator<T>) { then(comparator.comparator) }`，`comparing(mapper, comparator: Comparator<T>)` 同理；`Equaler.eq` 是 `private let`，需一并放开或在同一文件内做等价转发。

### [轻微][存量] #14 README 三处签名 / 重导出与实现不一致

- **位置**：
  1. `README.md:209`（`README_en.md:210`）写 `public func none(callee: () -> R)`，实现是 `public func none(callee: () -> R): OptionCaller<T, R>`（`ExtendOption.cj:118-121`，返回 `this` 供链式调用）；
  2. `README.md:60`（`README_en.md:61`）写 `public struct Equaler`，实现是 `public struct Equaler<T>`（`Equaler.cj:18`），紧随的构造签名也因此缺 `<T>`；
  3. `README.md:706` 的 std 重导出清单只列 `std.collection.* / MathExtension / reflect.* / regex.* / time.*`，实际另有 `public import std.env.ConsoleWriter`（`Console.cj:20`）、`public import std.math.*` 与 `std.math.numeric.*`（`ExtendNumber.cj:18-19`）。
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API 与源码不符」「中英不同步」、§14.2「公开 API 未文档化」
- **证据**：静态确定 —— 三处均有两边位置（上列）。
- **描述**：第 1 条会让使用者误以为不能链式写 `opt.caller{...}.none{...}()`；第 3 条影响更大：`import fountain::f_base.*` 实际会带出 `std.math.*` 全部符号，使用者遇到 `abs` / `pow` 冲突时从文档里找不到原因。
- **建议**：改这三处；第 3 条建议直接写"另重导出 `std.math.*`、`std.math.numeric.*`、`std.env.ConsoleWriter`"，并在 `public_std_imports.cj` 顶部加一句"新增 `public import` 必须同步 README 对应小节"。

### [轻微][存量] #15 `BaseException.suppressed` 直接把内部可变 `ArrayList` 交出去

- **位置**：`f_base/src/BaseException.cj:63-67`（`prop suppressed { get() { suppressed_ } }`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「设计合理性 / 契约」、§12.1「共享可变状态」
- **证据**：静态确定 —— `ArrayList` 是引用类型，`get()` 返回内部列表本身；外部可 `e.suppressed.add(...)` / `clear()` 绕过 `addSuppressed`，也可在多线程下与 `printStackTrace` 的遍历并发修改。
- **描述**：`addSuppressed` 作为唯一写入入口的设计被该 getter 破坏；异常对象通常线程封闭，并发面风险低，主要是封装失效。
- **建议**：返回只读视图（`ReadOnlyList<Exception>`），或 `func suppressed(): Array<Exception>`（复制一份，代价是打印路径多一次分配）。

### [轻微][存量] #16 `printStackTrace` 的输出文案与缩进不规范

- **位置**：`f_base/src/BaseException.cj:24`（`'An exception has occured:...'`，拼写应为 `occurred`）、`76` / `80`（`"Caused by: "` / `"Suppressed: "` 后直接拼下一段完整头，无缩进、无分隔）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13（文案）、§10（可读性）
- **证据**：静态确定 —— 字符串字面量在 `24` 行；`74` 与 `77` / `82` 的递归调用都从 `"An exception has occured:"` 开头，导致 cause 链每层重复打印头部且无层级缩进。
- **描述**：影响日志可读性；`f_log/src/output/LogWriterImpl.cj:69-71` 会把这个输出直接写进日志文件，多行无缩进时很难区分层级。
- **建议**：`occured` → `occurred`；递归时传缩进层级（`printStackTrace(ex, w, indent)`），`Caused by:` / `Suppressed:` 各加两级缩进。

## 优化可行性方案

> 本部分没有 `cjprof` / `cjpm bench` 基线，两条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [堆内存] `Iterator.toArray()` 经 `ArrayList` 中转，峰值多一份完整数组

- **现状**：`ExtendIterator.cj:46-48` 的 `toArray()` = `toArrayList().unsafeData()`；`toArrayList()`（`49-51`）逐个 `add` 进 `ArrayList<T>`（`n` 次扩容复制），`unsafeData()`（`UnsafeData.cj:24-29`）再 `getRawArray()[0..size]` 切出一份新数组。同一时刻存在：`ArrayList` 的 raw array（容量 ≥ n，按增长策略可能到 1.5–2n）+ 结果数组（n）⇒ 峰值约为结果大小的 2.5–3 倍，且多一次 O(n) 复制。
- **方案**：`toArray()` 一遍成型——能预知 `n` 时 `Array<T>(n, repeat: ...)` 后按下标写入；不能预知时至少把 `unsafeData()` 换成 `ArrayList.toArray()`（省掉切片那一份复制，语义也更安全，`unsafeData` 的 `unsafe` 语义不应泄漏到通用 `toArray`）。
- **预期**：物化路径少一次完整数组复制，峰值下降约 30%–50%（按 n 与扩容策略估算，需实测）；`toArray` 是 `f_orm` / `f_codec` 等模块的常用收尾操作。
- **代价**：`ArrayList.toArray()` 仍需一次复制，收益不如"直接按 n 预分配"；两遍扫描方案要求 `Iterator` 可重放（通用 `Iterator<T>` 不保证）。
- **验证**：`cjpm bench`（`-O2`）对比 `iter.toArray()` 在 n = 1k / 100k / 1M 下的中位耗时与 `getAllocatedHeapSize()` 峰值，并对照 RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CpuFeatures.hasSse41` 每次读取都重新打开并全量解析 `/proc/cpuinfo`

- **现状**：`CpuFeatures.cj:29-33` 的 getter 直接调 `detectSse41()`（`43-54`），后者 `File('/proc/cpuinfo')` + `StringReader.readToEnd()` + `contains('sse4_1')`。仓内调用点只有 `f_jit/src/backend/X86Lower.cj:62`（每个 `X86Lower` 实例一次），当前频次极低，因此**不构成热点**；但这是"属性"语义，任何循环里读它都会退化成文件 I/O。
- **方案**：改成惰性一次性缓存——`private static var` + `AtomicBool` 初始化标记（或双检），首次探测后固定；`CpuFeatures_test.cj:12` 的"两次读数一致"断言正好可以保留。
- **预期**：属性访问从"打开文件 + 读全文件 + 扫描"降到一次字段读；仅在探测次数被放大时才有收益。
- **代价**：容器热迁移 / CPU 热插拔场景下不再跟随（实际影响可忽略，SSE4.1 不会变化）；首次并发访问需要一个同步点。
- **验证**：`cjpm bench` 循环读 100 万次 `hasSse41`，对比改前/改后中位耗时；`strace -c` 看 `openat` 次数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `hasSse41` 每次读 `/proc/cpuinfo` 若被上层放进编译循环会成为 I/O 热点（当前仅 `X86Lower` 构造时读一次，疑似不成立） | `f_base/src/CpuFeatures.cj:29-33`、`43-54` | 调用次数分布（每次 JIT 编译几次） | 在 `detectSse41` 加计数器，跑 `f_jit` 编译 10k 个表达式，看计数与 `openat` 系统调用次数 |
| 2 | `toArray()` 的 `ArrayList` 中转使物化路径峰值内存翻倍以上 | `f_base/src/ExtendIterator.cj:46-51` | n 与实际峰值 RSS / heap 的对照 | 对 n = 1k / 100k / 1M 跑 `toArray()`，记录 `getAllocatedHeapSize()` 峰值与 RSS，改成直接预分配后再测 |
| 3 | `Arch.hashCode()` 每次拼 `'fountain::f_base.Arch.${this}'` 再做字符串哈希，作为 map key 时分配开销高于直接返回序数 | `f_base/src/Arch.cj:23-25` | 单次耗时、分配量、`Arch` 作 key 的频次 | 微基准 100 万次 `hashCode()` + `cjprof` 看分配；统计 `HashMap<Arch, ...>` 使用点 |
| 4 | `async()` 每元素一个线程的创建成本（即使修好并发问题）在物化路径上远超元素处理成本 | `f_base/src/ExtendIterator.cj:20-27` | 线程创建/销毁耗时占比、可并行度 | 1000 元素各跑 10 次，分段计时 `spawn` vs `get`，并与固定大小线程池版本对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_base/README.md` | .md | ✅ | 与实现大体一致；见 #3（`filterType` 语义）、#14（`none` 返回类型、`Equaler<T>`、重导出清单） |
| 2 | `f_base/README_en.md` | .md | ✅ | 与中文版逐节对齐，同样含 #3 / #14 三处 |
| 3 | `f_base/src/Arch.cj` | .cj | ✅ | `current` 只对 x86_64 / aarch64 生效；`hashCode` 走字符串（待验证假设 3） |
| 4 | `f_base/src/BaseCommand.cj` | .cj | ✅ | 22 行薄封装 `stdx.effect.Command`，无逻辑 |
| 5 | `f_base/src/BaseException.cj` | .cj | ✅ | 见 #5（递归无环检测）、#15（内部列表外泄）、#16（文案） |
| 6 | `f_base/src/Bucket.cj` | .cj | ✅ | 纯接口别名（`Map` 的子接口），无实现 |
| 7 | `f_base/src/Comparator.cj` | .cj | ✅ | 见 #13（`then` / `comparing` 双重载重复） |
| 8 | `f_base/src/Comparator_test.cj` | .cj | ✅ | 见 #8（第 28 行断言写错、`create()` 无覆盖） |
| 9 | `f_base/src/Console.cj` | .cj | ✅ | `readlnValue` 用 `tryParse` 丢弃解析错误（符合返回 `?T` 契约）；`public import ConsoleWriter` 未进 README（#14） |
| 10 | `f_base/src/CpuFeatures.cj` | .cj | ✅ | 每次读 `/proc/cpuinfo`（优化方案 2）；`catch (e: Exception)` 的 `e` 未使用（轻微，未单列） |
| 11 | `f_base/src/CpuFeatures_test.cj` | .cj | ✅ | 见 #7（缺版权头）、用例覆盖面不足 |
| 12 | `f_base/src/EmptyCollections.cj` | .cj | ✅ | 8 个空集合的 Null Object 实现，方法与"空"语义一致；`EmptyMapEntryView` 的 no-op setter 属该类型的不可变语义（§3 不计） |
| 13 | `f_base/src/Equaler.cj` | .cj | ✅ | 见 #13（`then` / `equalling` 双重载重复） |
| 14 | `f_base/src/ExtendArray.cj` | .cj | ✅ | 见 #4（空数组边界、`* 0`） |
| 15 | `f_base/src/ExtendIterator.cj` | .cj | ✅ | 见 #1（groupBy）、#2（async）、#3（filterType）、#10（flatten 重复）；优化方案 1 |
| 16 | `f_base/src/ExtendNumber.cj` | .cj | ✅ | 见 #12（8 份复制 / `isOdd` 冗余） |
| 17 | `f_base/src/ExtendOption.cj` | .cj | ✅ | 见 #9（`map` 死代码）、#11（12 组运算符复制）、#14（`none` 文档） |
| 18 | `f_base/src/ExtendRange.cj` | .cj | ✅ | 26 行，`toString` 拼 `start ..= end : step`，无边界问题 |
| 19 | `f_base/src/ExtendRune.cj` | .cj | ✅ | 见 #6（`UInt64` 窄化、`MIN` 取负） |
| 20 | `f_base/src/ExtendString.cj` | .cj | ✅ | `trimAsciiBlanks` 按字节比较（UTF-8 多字节高位置 1，不会误删）；`replace` 对空 `old` 会在头部插入 `new`（边界未文档化，轻微，未单列） |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 / #2 / #3 / #4 / #5 / #6；设计 #15（内部状态外泄）、#8（用例无覆盖）；可读性 #16。安全性：本部分无 SQL / HTML / 路径拼接、无凭据、无外部输入直接进缓冲区，未命中 |
| §1 死代码 | 1 | 逐个 `private` / 默认可见性符号搜引用：`BaseException.printStackTrace(OutputStream, callee)`、`CpuFeatures.detectSse41`、`ExtendArray.check`、`ExtendString.replace`、`Console.output` / `input` 均有调用方；`Option<T>.map`（`ExtendOption.cj:51`）在 `f_base/src`（含 `src/macros`）零引用 ⇒ #9。`Console` / `EmptyArray` 的 `private init()` 无调用，但其作用是"禁止实例化"，属有意声明，不判。对外可达的 `public`（`Arch` / `EmptyCollections` / `Comparator` / `Equaler` / `Extend*`）不判；`Comparator_test.cj:27` 的 `comparator` 赋值后未读，并入 #8 |
| §2 重复逻辑 | 4 | 同文件两两比对 40+ 个函数体：`flatten` 双分支（#10）、12 组 Option 运算符（#11）、8 份数值实现（#12）、`then` / `comparing` / `equalling` 双重载（#13）。`stringJoin` 两个重载（`ExtendString.cj:18-24`）是重载解析所需（`Array<T>` 与 `C: Iterable<T>` 二义），不判；`Comparator` 与 `Equaler` 是"比较 / 相等"两个不同语义的姊妹类型，不判；`EmptyCollections` 的 8 个空类型方法体相同但各自实现不同接口契约，不判 |
| §3 空实现 | 0 | `EmptyCollections` 的 no-op 方法是 Null Object（类型名即语义：`Set.add` 返 `false`、`List.add` 空体），不是"承诺有行为却空实现"；`EmptyMap` 的写操作同属不可变语义。`CpuFeatures` 的 `catch { false }` 有注释说明"读取失败按不支持，调用方静默降级"（`CpuFeatures.cj:21-26`），属有意降级，未计为静默吞异常 |
| §4 栈溢出 | 1 | #5（`suppressed` 自环 / 互环 ⇒ `printStackTrace` 无限递归）。其余递归排查：`Comparator.then` / `Equaler.then` 构造的是闭包链而非自调用；`Option` 运算符重载互调的是**不同重载**（`?T + T` vs `T + T`），深度固定为 2；`numberOfLeadingZeros` 是迭代 |
| §5 OOM | 1 | #2（`async()` 每元素 `spawn`，物化时线程与 `Future` 数量 = n，无窗口无上限）。本部分没有"按报文字段预分配"、没有全局只增容器、没有 `readToEnd` 物化用户输入（`CpuFeatures` 读的 `/proc/cpuinfo` 大小固定） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；`hasSse41` 探测与 `toArray` 中转降级为优化方案 1 / 2 与待验证假设 1-2 |
| §6.2 大粒度锁 | 0 | 本部分只有一处跨线程动作（`AsyncIterator.spawn`），没有任何 `synchronized` / `Mutex` 临界区；`BaseException` 无锁（异常对象按线程封闭使用） |
| §6.3 并发串行 | 0 | 无"`spawn` 后立刻 `get()`"：`AsyncIterator` 是反过来的（只 `spawn` 不 `get`，见 #2）。`async()` 的"每元素一个线程、无上限"是并发安全与有界性问题，已归 #2，不重复计为串行热点 |
| §6.4 低效算法 | 0 | 无 `remove(at: 0)` 队列、无双层循环匹配、无循环内字符串 `+`（`stringJoin` 走 `StringGenerator`）。`trimAsciiBlanks` 是双指针 O(n)，`ExtendString.replace` 单次 `indexOf` |
| §7 降堆内存方案 | 1 | 优化方案 1（`toArray` 双份数组），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案 2（`hasSse41` 缓存），标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内释放"的候选：`ExtendArray.grow` 的结果作为返回值逃逸，`stringJoin` 的 `StringGenerator` 逃逸为 `String` 返回值，`printStackTrace` 的 `ByteBuffer` 写进外部 `OutputStream`。约束 3（非 `Copyable` 需 local 构造重载）在 `Array<T>` / `String` 上也无对应 API，改造不可行 |
| §11 现有代码的 BUG（存量） | 7 | #1（groupBy 恒空）、#3（exactly 无效）、#4（空数组越界 / 除零）、#5（递归无环检测）、#6（Rune 入参范围）、#8（用例断言写错）、#16（文案拼写）；另核对了 `EmptySet.contains(all)` / `EmptyMap.contains(all)` 的空集合语义、`EmptyList.remove` 的越界异常、`Console.readlnValue` 的空输入分支、`Arch.toString` 的穷尽 `match`、`Equaler.equals` 的 `==` 转发，均无缺陷 |
| §12 并发安全与锁粒度 | 1 | #2：共享可变状态是构造时注入的 `itr`（`extend Iterator.async()` 的返回对象被多线程消费时立即触发），缺失的同步手段是"对 `itr.next()` 的互斥或单线程取出"。其余无跨线程共享字段（`Console` 的 `output` / `input` 是 std 的线程安全门面；`CpuFeatures` 只读文件）。锁粒度：无线程同步，无粒度问题 |
| §14 功能完备性与 README 覆盖 | 1 | 逐项对照 `public` 声明与两版 README：`Arch` / `BaseCommand` / `BaseException` / `Bucket` / `Comparator` / `Console` / `CpuFeatures` / `Empty*` / `Equaler` / `ExtendArray` / `ExtendIterator` / `ExtendNumber` / `ExtendOption` / `ExtendRange` / `ExtendRune` / `ExtendString` 均在文档或"其他公开 API"清单中出现。遗漏：`AsyncIterator` / `TypeFilterIterator` / `OptionIterator`（`public` 类型，作为返回类型出现但 README 检索不到）、3 个 std 重导出（#14 第 3 条） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 按 §13 逐段核对（见 #3 / #14） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分（`f_base` 的"扩展与基础类型"层，18 个 `.cj`）整体是低风险的胶水代码：`EmptyCollections` 的 Null Object、`ExtendOption` 的运算符、`ExtendString` / `ExtendRange` 的小工具都没有外部输入面，也没有锁与线程间共享字段，**安全与锁竞争的攻击面几乎为零**。真正的问题集中在两处：

- 阻塞项（建议先修）：**#1 `groupBy` 恒返回空 map**。这不是边界问题，而是整个函数不写结果；更严重的是它已经在 `f_orm` schema 迁移的主路径上（`SchemaFinderMediator.cj:29`），意味着 `migro` 会静默生成零条 SQL、索引信息全丢。任何"迁移跑完但库没变"的现场都应先查这一条。
- 次阻塞项：**#2 `AsyncIterator`**。`spawn { itr.next() }` 同时踩两个坑（并发推进同一迭代器 + 线程数 = 元素数），README 还把"每元素一个线程"当特性写出来。修它要连文档一起改，属于小手术。
- 排期项：#3（`exactly` 无效）、#4（空数组 `grow` 越界 / 除零）、#5（`suppressed` 自环爆栈）都是"平时不响、边界上崩或静默错"的类型，单条修复成本都很低，建议与 #1 一起进 1.3.x。
- 可维护性：#10–#13 四组重复逻辑受仓颉"无泛型数值 / 无运算符参数化"限制，不能简单判"该抽泛型"；能立刻做的是删掉 8 处冗余 `isOdd`、把 `then` / `comparing` 的结构体重载改成转发、把 12 组 Option 运算符统一成同一写法（或宏生成），避免后续只改一处造成分叉。
- 文档：#14 的三处不一致里，"重导出清单漏了 `std.math.*`"最容易让使用者踩名称冲突；`filterType` 的表述（#3）则会让人写出行为不符的过滤代码。
- 性能与内存：本部分没有改前 / 改后数据（无 `cjprof` / `cjpm bench` 基线），两条优化与四条假设都不进修复清单；`toArray` 的双份数组最值得下一轮补数据。
- 已确认**没有**的问题：死锁与锁竞争（无锁）、线程间可见性问题（无共享字段）、按不可信长度预分配（无）、local mode 可用性（候选全部逃逸）、循环内物化用户输入（无）。

存量缺陷共 16 条（严重 2 / 一般 5 / 轻微 9），是否纳入修复待用户决定；本报告只读代码，未做任何修改。
