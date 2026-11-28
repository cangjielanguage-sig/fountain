# f_base 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（54 个文件：52 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 3 个分部分报告合并：`parts/f_base.part1..3.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [严重][存量] #1 `StringGenerator.remove` / `replace` 遇到零长搜索串：死循环 + `ArrayList` 无界增长 ⇒ OOM

- **位置**：`f_base/src/StringGenerator.cj:151-166`（`156` 的 `while`、`157-159` 的不前进赋值）、`171-192`（`189` 的 `fromIdx = idx + newBytes.size`）；相关私有封装 `104-110`
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`；快照模式无基线可比）
- **判据**：review-checklist §5「无界容器 / 平方级增长」、§6.4「循环不前进」、§11「边界未处理」
- **证据**：静态确定 —— 触发条件是 `content` / `old` 为空串，取决于 std 的两条语义（已现场核对，非记忆）：
  1. `Array<T>.indexOf(elements, fromIndex)` 对**空** `elements` 返回 `Some(fromIndex)`（`stdlib/libs/std/core/array_common.cj:274-289`：`this.size < 0` 与 `fromIndex >= this.size` 都不成立，循环第一步 `this[i..i] == []` 即为真）；
  2. `remove` 里 `range = idx .. idx + search.size`（`157`）⇒ `range.end == idx` ⇒ `fromIdx` 原地不动（`159`），`while` 条件永真，`torm`（`155`）每轮 `add` 一个 `Range` ⇒ 堆按迭代次数线性增长，直到 OOM/被 OOM killer 杀掉。`replace` 在 `old` 与 `new` 都为空时同样：`oldBytes.size == newBytes.size == 0` 走 `178-179` 的空赋值，`189` 的 `fromIdx = idx + 0` 原地踏步 ⇒ 纯死循环（不分配，只烧 CPU）。
- **描述**：`remove` / `replace` 都是 `public` 且签名接受任意 `T <: ToString`（`151`、`171`），空串是完全合法的入参（例如从配置/模板里读到的分隔符为空）。当前实现在这种输入下既不抛异常也不返回，进程直接挂死并持续分配。仓内目前没有 `StringGenerator.remove(` 的调用点（已全仓搜索），所以是**潜伏缺陷**，但 `StringGenerator` 有 51+ 个使用方（`f_orm` / `f_data` / `f_log` …），任何人拿它做通用字符串编辑都会踩到。
- **建议**：循环里加"必须前进"的硬约束：`if (search.size == 0) { return this }`（`remove`）、`if (oldBytes.size == 0) { return this }`（`replace`，与 `ExtendString.replace` 的"空 old 在头部插入"语义要对齐就先在注释里定口径）；或把 `fromIdx = range.end` 改成 `fromIdx = if (range.end > idx) { range.end } else { idx + 1 }`。补两条用例：`remove("")`、`replace("", "")` 必须立即返回且内容不变。

### [一般][存量] #2 `AbstractFutureTask.shutdown()` 取消的是**调用线程**的子任务，不是被调用任务的子任务

- **位置**：`f_base/src/FutureTask.cj:171-174`（`shutdown()` 里直接调 `shutdownCurrentSubThreads()`）、`177-195`（`181` 行 `subTasks.remove(Thread.currentThread.id)`）
- **来源**：存量（`git blame`：`5905520079 2026-10-11`）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「并发正确性 / 异步语义」
- **证据**：静态确定 —— `shutdown()` 是**实例**方法，语义应为"结束本任务及其子树"（README 原文："结束当前FutureTask，并按照shutdownSubOnFinish决定是否结束子任务"，`README.md:664-665`）；但它拼上的 `shutdownCurrentSubThreads()` 是 `static` 且以 `Thread.currentThread.id` 为键。于是：
  - 在任务自己的线程里调用（`task.shutdown()` 由任务体内触发）⇒ 两个键恰好相同，行为正确；
  - 在**别的线程**里对某个任务调 `shutdown()`（例如看门狗线程/父任务对子任务做超时清理）⇒ 取消自己（`cancelSelf`，`172`）正确，但随后把**调用线程**的整张子任务表取走并逐个 `f.shutdown()`（`180-192`），即**顺带取消了与目标任务无关的一批任务**。被取消方只会看到 `hasPendingCancellation`，属静默数据丢失。
- **描述**：`AbstractFutureTask.shutdown()` 把"实例取消"和"静态清当前线程"拼在一起，只有在 `this` 恰好属于当前线程时才自洽。同文件 `186-191` 的递归也依赖这一点：`f.shutdown()` 在父线程里执行，对 `f` 的子任务并不生效（`f` 的桶键是 `f` 自己的线程 id），子树的取消实际靠 `f` 自己 `finally` 里那次 `shutdownCurrentSubThreads()`（`262-270`）兜底——一旦 `f` 的任务体不检查取消标志而不返回，孙子任务就永远收不到取消信号。
- **建议**：把"清某个任务的子树"做成实例能力：在 `spawn` 体内第一句（`253` 附近）顺手记下 `this.runningTID = Thread.currentThread.id`，再提供 `private func shutdownSubTasksOf(tid: Int64)`；`shutdown()` 调 `shutdownSubTasksOf(this.runningTID)`，`public static shutdownCurrentSubThreads()` 保留为 `shutdownSubTasksOf(Thread.currentThread.id)` 的薄封装（兼容 README 的静态入口）。同时补一条用例：主线程创建任务 P，P 创建子任务 C，主线程对 P 调 `shutdown()`，断言 C 收到取消且主线程自己的其它子任务**未**被取消。

### [一般][存量] #3 `InheritedTaskLocal.get()` 与 `set()` / `remove()` 的写目标不一致：任务外 `set` 后 `get` 恒为 `None`

- **位置**：`f_base/src/FutureTask.cj:349-355`（`writeTarget()` 的回退分支）、`357-371`（`set` / `get` / `remove` 三个出口）、`118-130`（`getLocal` 从 `currentTask` 起沿父链）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「语义与注释不符 / 契约不对称」、§12.1「异步语义」
- **证据**：静态确定 —— `set` / `remove` 走 `writeTarget()`：不在任务里就回退到 `task`（创建该 local 的 owner，`353`）；而 `get()`（`361-363`）直接调 `task.getLocal<T>(this)`，`getLocal` 的起点是 `currentTask.get()`（`122`）。在创建线程（main / 普通 `spawn` / 单元测试线程）上 `currentTask` 为 `None`，`while` 一次都不进 ⇒ 返回 `None`。因此同一线程上 `local.set(5); local.get()` 得到 `None`，`local.remove()` 却又能删掉刚写进 owner 的值（`369-371` 走 `writeTarget()`）——三个 API 的目标集合不一致。
- **描述**：README 只写了"`set`/`remove` … 不在任务内部调用时回退到创建该 local 的任务"（`README.md:628`、`675`）与"`get` 从当前任务沿父任务逐级查找"（`README.md:627`），没有写"任务外 `get` 读不到刚 `set` 的值"。这是典型的"读己之写"失败：调用方在创建线程预置初值、随后回读校验时拿到 `None`，会误判为"没设置成功"。
- **建议**：让 `get()` 与 `set`/`remove` 用同一个起点。注意 `getLocal` 当前**完全不看 `this`**（只从 `currentTask` 出发），所以改法是把它拆成 `private func getFrom(start: AbstractFutureTask, local)`（原 `getLocal` 保留为 `getFrom(currentTask…, local)` 的薄封装），`get()` 调 `getFrom(writeTarget(), this)`：任务内 `start` 仍是当前任务、行为不变；任务外 `start` 是 owner，补齐读己之写。或不改结构，在 `getLocal` 的 `while` 结束后再补一次 `task.readLocalRaw(local)`。补用例：`let l = t.newLocal<Int64>(); l.set(1); @Expect(l.get(), Some(1))`。

### [一般][存量] #4 `getOrSet` / `getOrCompute` 在 `local.initLock` 内执行用户回调：跨任务互等可死锁，持锁时间不可控

- **位置**：`f_base/src/FutureTask.cj:139-152`（`143-151` 的 `synchronized(local.initLock)`）、`153-167`（`157-165`，`fn()` 在 `161`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.2「锁内调用外部回调」、§6.2「锁内做耗时动作」、§4「间接递归」
- **证据**：静态确定（结构）——`fn()` 与 `setLocal` 都在 `synchronized(local.initLock)` 内；`local.initLock` 是**每个 local 一把、跨任务共享**（`333`），锁粒度为"该槽的全部写入者"。两条后果只读代码即可确定：
  1. 任一调用方的 `fn` 阻塞多久，其它任务对同一 local 的 `getOrSet`/`getOrCompute` 就阻塞多久（`fn` 里做 RPC / 等子任务 / 等 I/O 都会把持锁时间放大到不可控）；
  2. 若 `fn` 内部等待的另一个任务也需要同一个 local，就构成跨线程互等（`Mutex` 可重入只解决了同线程重入，见 `sync` 文档 `Mutex` 为可重入锁），死锁窗口由此产生。同线程重入则是另一头：`fn` 里再对同一 local 调 `getOrCompute`，可重入锁不拦，会**无限递归**到栈溢出（`getOrCompute` 未命中 ⇒ 再进 `fn` ⇒ …）。
- **描述**：注释（`329-332`）已把"fn 在锁内执行"作为决策写明，但只交代了"只算一次"的收益，没有交代持锁期间不可再等待其它任务这一约束；对库使用者来说这是隐式契约。
- **建议**：改成"占位 + 单次计算"：先 `addIfAbsent(local, Placeholder)` 声明拥有权（原子），只有占位成功者执行 `fn()` 并在完成后 `writeLocalRaw` 真值 + 唤醒等待者（`Mutex` + `Condition`），失败者等待唤醒或用 `get()` 轮询；至少要把"`fn` 内不得等待其它任务、不得再对同一 local 递归"写进 README 与接口注释。补一条并发用例：`fn` 内 `sleep` 200ms，另一个任务同一 local 的 `getOrSet` 必须等到同值而不是各自计算。

### [一般][存量] #5 子任务表以 `Thread.currentThread.id` 为键，而标准库明确不保证线程结束后 id 不复用

- **位置**：`f_base/src/FutureTask.cj:61`（`subTasks`）、`73`（`parentTID`）、`181`、`236`、`276`（三处按键读写）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 键复用」、§11「契约与前提不成立」
- **证据**：待确认 —— 前提来自官方文档：`Thread.id`"所有存活的线程都有不同标识，但**不保证**当线程执行结束后复用它的标识"（`stdlib/doc/libs/std/core/core_package_api/core_package_classes.md:3833`）。而 `subTasks` 是**进程级长期表**，桶的存活时间可以超过键线程：
  - 创建者是普通线程（main / 短命 `spawn` 线程）且它创建的任务长期不返回（阻塞在 I/O、忽略取消标志）⇒ `parentTID` 对应的桶会一直留着（`274-283` 的自注销只在任务结束时执行）；
  - 该线程结束后 id 若被新线程复用 ⇒ 新线程的 `shutdownCurrentSubThreads()`（`181`）会取走并取消**旧线程遗留的任务**；新线程的构造登记会写进旧桶，其 teardown 又会把整桶摘掉（`266-268`），让旧任务从此失去被取消的机会。
- **描述**：整套"桶只能被键线程碰"的无锁推理（`230-234` 注释）成立的前提是"线程 id 永不复用"，标准库只保证"同时存活的线程 id 互异"。是否真的复用取决于运行时实现与线程生命周期模式，故记为待确认。
- **建议**：不要用线程 id 做长期表键。用任务对象自身的 `taskId`（`39-40` 已有单调 `AtomicInt64`）或"当前任务的 `AbstractFutureTask` 引用"做键；若必须按线程定位，给每个任务线程分配一个不复用的 `taskId` 并在 `currentTask` 里一起携带，`shutdownCurrentSubThreads()` 改用该 id。退一步至少要在任务结束时无条件删除自己的桶（去掉 `hasChildren` 短路），把"桶存活期 ≤ 线程存活期"变成不变量。

### [一般][存量] #6 `StringGenerator.checkIndex` 把 `fromIndex == size` 当越界：空缓冲区上的 `remove` / `replace` 直接抛异常

- **位置**：`f_base/src/StringGenerator.cj:40-44`（`41` 行 `fromIndex >= size`）、默认参数落点 `151`、`171`（`toIndex!: Int64 = size`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「边界差一」
- **证据**：静态确定 —— 合法区间是 `0 ≤ fromIndex ≤ toIndex ≤ size`，判据却写成 `fromIndex >= size` 即非法。于是：
  - 空 builder（`size == 0`）上任何 `gen.remove("x")` / `gen.replace("a","b")`：`checkIndex(0, 0)` 直接抛 `IndexOutOfBoundsException('current size is 0, but fromIndex: 0, toIndex: 0')`，而语义上应是无操作；
  - 非空 builder 上 `gen.remove("x", fromIndex: gen.size)`（空区间）同样被拒。对照 `insert(sub, at!)`（`167-170`）没有这项检查、`at == size` 合法，两套边界口径不一致。
- **描述**：`checkIndex` 的注释/异常消息都在表达"下标越界"，但对"末尾空区间"这一合法形态误判；调用方（尤其做增量编辑时把游标推到末尾再删）会收到无法理解的越界异常。
- **建议**：`fromIndex < 0 || fromIndex > size || toIndex < fromIndex || toIndex > size`，并补用例：空 builder 上 `remove` / `replace` 为无操作、`fromIndex == toIndex == size` 合法。

### [一般][存量] #7 `Help` 是对外不可达的 `internal` 顶层类，全仓零引用，README 却按公开 API 记载

- **位置**：`f_base/src/Help.cj:18-45`（`18` 行 `abstract sealed class Help`，四个 `public static func convert`）；文档侧 `README.md:332-342`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「非 public 顶层声明里的 public 成员，全项目无使用即死代码」、§14「README 承诺但不可用」
- **证据**：静态确定 —— 顶层声明省略修饰符的默认语义是 `internal`（`docs/dev-guide/source_zh_cn/package/toplevel_access.md:21`："其他顶层声明 … 默认修饰符为 `internal`"）。因此 `Help` 及其四个 `public static` 成员只在本包内可见；全仓搜索 `Help\.convert` 与 `\bHelp\b`（排除 `.worktrees`）只命中 `Help.cj` 自身，**无任何调用方** ⇒ 按硬原则二判死代码。同时 README 用 `## Help` 章节把它写成可直接调用的 API（`336-337` 的示例 `Help.convert<T>([a, b, c])`），下游 `import fountain::f_base.*` 后根本无法解析该符号。
- **描述**：既是死代码，又是文档陷阱：读者按 README 写 `Help.convert` 会得到"找不到符号"，且没有任何提示说明它是包内工具。
- **建议**：二选一并同步文档——(a) 确认要对外提供 ⇒ `public abstract sealed class Help`（或 `public class`），并在 `README_en.md` 同步；(b) 不对外 ⇒ 删除 `Help.cj` 与 README 的 `## Help` 章节。若保留内部使用，把类注释改成"包内工具，非公开 API"。

### [一般][存量] #8 `BlockingOverSizePolicy` 默认参数组合使 `fn` 永不执行：阻塞一段时间后静默丢弃

- **位置**：`f_base/src/OverSizePolicy.cj:53-81`（默认参数 `61` `policy!: OverSizePolicy<T> = DiscardOverSizePolicy<T>()`、`reject` 的 `63-70`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「错误处理缺失或静默」、§3「静默吞掉」、§12.1「条件等待」
- **证据**：静态确定 —— `reject(o, fn)` 的两条出口：
  1. `recovered(o) == true` ⇒ `policy.reject(o, fn)`，默认 `policy` 是 `DiscardOverSizePolicy`，它的 `reject` 是空体（`36`）⇒ `fn` 不被调用，`o` 被丢弃；
  2. `recovered(o) == false` ⇒ 直接函数返回，`fn` 不被调用，`o` 被丢弃。
  两条都是"静默丢弃"。也就是说**默认配置下 `BlockingOverSizePolicy` 等价于"先阻塞 `timeout` 再丢弃"**，只有显式传 `policy: CallerRunsOverSizePolicy()` 才会真正把值加进去（对比 `RemoveSomeOnePolicy` / `CallerRunsOverSizePolicy` 都显式调用 `fn()`）。另外 `65` 的 `condition.wait` 忽略了 `Bool` 返回值（`sync_package_classes.md:8534`：`wait(timeout!): Bool`，超时返回 `false`）、也没有 `while` 循环重查条件，`timeout <= 0` 时还会按文档抛 `IllegalArgumentException`（同文档 `8553`）。
- **描述**：一个叫 "Blocking" 的策略在默认参数下从不放行任何数据，且调用方拿不到任何信号（`reject` 返回 `Unit`，不抛异常、不打日志）；`recovered == false` 时"被拒绝的值去哪了"在代码里无交代。`BlockingOverSizePolicy` 全仓只有本文件一处定义、无使用方（`f_collection/src/PriorityQueue.cj`、`f_concurrent/src/SyncPriorityQueue.cj` 用的是 `DiscardOverSizePolicy` 与各自的 `GrowSizePolicy`），属公开 API 的默认值陷阱。
- **建议**：默认内层策略改成 `CallerRunsOverSizePolicy<T>()`（阻塞到有空间就自己执行 `fn`），或把 `recovered == false` 分支改成抛 `OverSizeException`（与 `AbortOverSizePolicy` 一致，至少让调用方知道丢了值）；`wait` 用 `if (!wait(...))` 分支显式处理超时，并把条件重查放进 `while`。补三条用例覆盖 `recovered` 真/假与超时。

### [一般][存量] #9 `Result.transpose`：`Ok(None)` 返回 `Some(NoResult)` 而不是 `None`

- **位置**：`f_base/src/Result.cj:170-182`（`172-175`：`case Ok(x: ?U) => match (x) { case Some(y) => Ok(y); case _ => NoResult }`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「惯用 Option」
- **证据**：待确认 —— 返回类型是 `?Result<U, E>`，`Ok(y)` / `NoResult` 这两个 `Result` 值会被隐式包成 `Some(...)`。于是 `Ok(Some(1))` → `Some(Ok(1))`、`Ok(None)` → `Some(NoResult)`、`Err(e)` → `Some(Err(e))`、`NoResult` → `Some(NoResult)`。`transpose` 的常规语义（Option↔Result 互换）要求 `Ok(None)` → `None`，本模块 `ExtendOption.toResult()` 也是用 `None<Result<U,E>>` 表示"无值"（`ExtendOption.cj:78-81`），两种口径相反。缺的是该函数的设计口径（README 只列签名不写语义，`README.md:265`；仓内无调用点，已全仓搜索 `transpose`）。
- **描述**：若按常规 `transpose` 语义使用，调用方 `match (r) { case Some(inner) => … }` 会把"没有值"误当成"有结果但状态是 NoResult"，分支走错。
- **建议**：`case _ => None<Result<U, E>>`（`Ok(None)` 与 `Option<Result>` 的 `None` 对齐），并在 README 补一行语义说明；若确实要保留三值语义，把返回类型改成 `Result<?U, E>` 让类型自解释。

### [轻微][存量] #10 `HashBuilder` 的 `private append(Map)` 无调用者（死代码），且与 `append(ConcurrentHashMap)` 逐行重复

- **位置**：`f_base/src/HashBuilder.cj:134-153`（private 重载）vs `109-124`（public `ConcurrentHashMap` 重载，9 个 `case` 完全一致）；文档侧 `README.md:328` 把它当 API 列出
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §1「private 无调用者 → 死代码」、§2「只改类型名」
- **证据**：静态确定 —— `private` 成员只能在本类型体内被调用，本文件内所有 `append(` 调用的实参都是 `Int64` / `String` / `Rune` / `Hashable` / `Iterable`，没有任何一处把 `Map` 值传给 `append`；全仓 30+ 处 `HashBuilder` 调用点都在其他模块，无法命中 private 重载（外部调用 `append(hashMap)` 会被 `append<T, I>(args: I) where I <: Iterable<T>` 接走）。两个重载的 9 分支 `match` 与 `if (let x: Hashable <- value)` 前置判断逐行相同，只有容器类型名不同。
- **描述**：重复的 20 行匹配级联维护成本高（改一处忘另一处就会让 `Map` 与 `ConcurrentHashMap` 的哈希口径分叉）；同时 README 把 private 成员写成公开能力，读者会以为可以 `HashBuilder().append(someMap)`。
- **建议**：删除 private 重载；确实需要按 `Map` 内容哈希时，改成 `append<K, V, I>(value: I) where I <: Iterable<(K, V)>` 一个实现（与 `ConcurrentHashMap` 版共用）。README 的 `HashBuilder` 章节同步（`README_en.md` 同）。

### [轻微][存量] #11 `StringGenerator` 的 `replace` / `replaceFirst` / `replaceLast` 三段拼接逻辑复制；`reset()` 与 `clear()` 完全等价

- **位置**：`f_base/src/StringGenerator.cj:178-188`、`215-225`、`235-245`（同一套"等长覆盖 / 变长插入 / 变短删除"三分支）；`35-38` 的 `reset()` 与 `133-136` 的 `clear()`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「同文件内语义相同的复制」「字面量/结构复制」
- **证据**：静态确定 —— 三个 `replace*` 的拼接块逐行对齐，唯一差异是定位方式（`indexOf` / `lastIndexOf`）与是否循环，`oldBytes.size` 与 `newBytes.size` 的三个比较分支完全一致；`reset()` 与 `clear()` 的函数体是同一句 `utf8.clear(); this`，两个名字对外都 `public`。
- **描述**：拼接逻辑已有三份，修 #6 那类边界时容易只改一处；`reset` / `clear` 双名同义会让调用方猜测二者差异（例如 `reset` 是否重置容量）。
- **建议**：抽 `private func spliceAt(idx: Int64, oldBytes: Array<Byte>, newBytes: Array<Byte>)`，三个入口只负责定位；`reset()` 改成转发 `clear()`（或直接删掉一个并在 README 标注为别名）。

### [轻微][存量] #12 `HashBuilder.hashCode()` 有副作用：读一次哈希就把状态清零，作为 Map/Set 键会失效

- **位置**：`f_base/src/HashBuilder.cj:32-39`（`build()` 里 `hashed = 0`，`hashCode()` 直接调 `build()`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「仓颉语言特性 / 契约」、§11「语义与命名不符」
- **证据**：静态确定 —— `hashCode()` 调用后 `hashed` 归零，第二次 `hashCode()` 返回 `0`；把它放进 `HashSet` / `HashMap` 后第一次 `get` 用旧哈希、之后桶位置不再匹配（哈希值变化），对象"消失"。类注释（`21-23`）只说明"一般只作为局部变量使用，不会发生逃逸"，即用约束规避了这个问题，但类型本身 `public` 且实现了 `Hashable`，编译器不会阻止误用。
- **描述**：`Hashable` 的隐含契约是"同一对象的 `hashCode` 稳定"，本类型违反；一旦有人写 `map[builder] = x` 就是静默丢数据。
- **建议**：拆成 `build()`（取值+复位，保持现语义）与 `hashCode()`（只返回 `hashed`，不复位），或在 `hashCode()` 上加显式注释/抛错说明不可作键；更好的做法是不实现 `Hashable`，只留 `build()`（已核对 `DataAssist.cj:350-352`、`SqlArgs.cj:111-114`、`ContentDisposition.cj:178-181` 等调用点，全部以 `build()` 取值，未见把 `HashBuilder` 当键使用）。

### [轻微][存量] #13 `AbstractInheritedTaskLocal.hashCode()` 取 owner 任务的哈希：同一任务的 local 在表里全部同桶

- **位置**：`f_base/src/FutureTask.cj:335-337`（`task.hashCode()`）、`50` / `99-103`（`HashMap<AbstractInheritedTaskLocal, Any>`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §6.4「每次重新计算昂贵 hash / 哈希退化」、§10「设计合理性」
- **证据**：静态确定（碰撞事实）—— 一个任务的所有 `local` 都由 `newLocal()` 创建（`84-86`），owner 恒为该任务，因此 `hashCode()` 恒等于 `task.taskId`（`78-80`）；`==` 用 `refEq`（`338-340`）。同一张 `local` 表里的每个键哈希值都相同，`HashMap.get` 退化为桶内线性 `refEq` 扫描，键数 n 即 O(n)。实际 n = 单任务的 local 个数（通常个位数），故影响大概率可忽略（收益待测，见待验证假设 3）。
- **描述**：哈希把"哪个 local"这一维度丢了，只保留"哪个任务"；语义上等价于用常量哈希做身份表。功能正确，但让 `HashMap` 完全失去分桶能力，也让"每个任务一张表"的设计意图（读多写少、并发度低）无法从数据结构上获得任何收益。
- **建议**：给 `AbstractInheritedTaskLocal` 一个单调 `AtomicInt64` 分配的 `localId` 并作为 `hashCode`；`task` 只用于语义（owner 回退），不参与哈希。

### [轻微][存量] #14 子任务表已经是 `ConcurrentHashMap`，却仍用一把全局 `Mutex` 串行化全部访问

- **位置**：`f_base/src/FutureTask.cj:60-61`（`subTasksLock` + `subTasks`）、`180-182`、`235-247`、`266-268`、`275-282`、`567`（测试）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §12.2「能不能不要锁 / 分片」、§6.2「一把全局锁保护多个无关资源」（数据面本轮无 profile，判据限于设计层）
- **证据**：静态确定（结构）——`subTasks` 的每一次读写都在 `synchronized(subTasksLock)` 内，`ConcurrentHashMap` 的并发能力从未被使用；而临界区按 `tid` 天然可分片（键空间 = 线程），每个桶的 `HashSet` 才是真正需要互斥的对象。所有任务的**构造**与**拆除**都要过这一把锁，`pruneFinishedChildren`（`198-208`，阈值 64）也在锁内扫描。
- **描述**：这不是缺陷（正确性由锁保证，注释 `57-59` 也说明了为何统一加锁），而是"并发容器 + 全局锁"的组合让锁成为任务创建/销毁路径的唯一串行点；争用程度未测，故只作轻微记录，收益进待验证假设 2。
- **建议**：`subTasks: ConcurrentHashMap<Int64, ConcurrentHashMap<AbstractFutureTask, Unit>>`（或 `ConcurrentHashSet`）后用桶级原子操作替代全局锁；至少把 `pruneFinishedChildren` 移出锁（快照后在锁外删）。

### [轻微][存量] #15 `FutureTask_test` 里两个 `pollCancel` 辅助函数逐行相同（仅键类型不同），另有 3 处忙等自旋

- **位置**：`f_base/src/FutureTask_test.cj:626-636`（`futureTaskTestPollCancel`，`ConcurrentHashMap<Int64, Bool>`）vs `657-667`（`futureTaskTestPollCancelStr`，`ConcurrentHashMap<String, Bool>`）；自旋点 `509`、`780`、`893`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名」、§10「可测试性」
- **证据**：静态确定 —— 两个函数体从 `var i = 0` 到 `box.add(key, Thread.currentThread.hasPendingCancellation)` 完全一致，只有 `box` 的键类型与函数名不同（调用方 `futureTaskTestPollCancelStrI64`（`669-672`）再包一层把 `Int64` 结果转成 `Unit`）；`while (!ready.load()) {}` / `while (!gate.load()) {}` 是无退避的 CPU 自旋，在被测线程数与核数不匹配时会改变调度时序。
- **描述**：重复本身成本很低，但"两份轮询实现"意味着以后调整超时/步长要改两处；忙等在 200 轮 × 8 线程的用例里会明显抬高 CPU，并可能让 `testGetOrComputeComputesOnceUnderConcurrency` 这类依赖"同时抢锁"的用例时序漂移（偶发红）。
- **建议**：合并成 `private func futureTaskTestPollCancel<K>(box: ConcurrentHashMap<K, Bool>, key: K): Unit`；自旋改成 `sleep(1ms)` 轮询或改用 `AtomicBool` + 门槛（`testDclParent` 已有 `sleep(1ms)` 的写法可复用）。

### [轻微][存量] #16 `OS.HarmonyOS` 没有任何 `@When` 分支产出：`current.isHarmonyOS` 恒为 `false`

- **位置**：`f_base/src/OS.cj:122-127`（被注释掉的 HarmonyOS 分支）、`128-133`（`env == 'ohos'` → `OpenHarmony`）、`54-58`（`isHarmonyOS`）、`85-96`（`valueOf("harmonyos")` 仍可构造该值）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §14「枚举新 case 没有分支 / 死配置」、§1「注释掉的死代码」
- **证据**：待确认 —— 六个 `current` 的 `@When` 分支分别是 `Linux+gnu` / `Windows` / `macOS` / `Linux+ohos` / `Linux+android` / `iOS`（`101-145`），唯一能返回 `HarmonyOS` 的分支被注释，`env` 的合法取值只有 `ohos`/`gnu`/`simulator`/`android`/空（`docs/dev-guide/source_zh_cn/compile_and_build/conditional_compilation.md:142`）。所以通过 `OS.current` 永远拿不到 `HarmonyOS`，`isHarmonyOS`（`54-58`）在正常路径上恒 `false`；只有 `OS.valueOf("harmonyos")` 能造出该值。缺的是"OpenHarmony 与 HarmonyOS 在编译期是否需要区分"这一设计结论。
- **描述**：枚举值、属性、`valueOf`、README 章节（`README.md:353`、`361`）都保留了 HarmonyOS，但运行期判定不可达；调用方按 README 写 `if (OS.current.isHarmonyOS)` 会得到永不成立的分支。同时 `122-127` 是注释掉的死代码块。
- **建议**：明确口径后二选一——(a) 若 HarmonyOS 与 OpenHarmony 在 SDK 里不可区分，删掉 `HarmonyOS`（或让 `isHarmonyOS` 委托 `isOpenHarmony`）并在 README 注明；(b) 若可区分（例如按 `cjc_version` 或自定义 `--cfg`），补上真实分支并删掉注释块。

### [轻微][存量] #17 `TypeInfos.getGenericTypes(qualifiedName)` 对畸形限定名静默截断

- **位置**：`f_base/src/TypeInfos.cj:60-69`（`61` 找 `<`，`63` 的 `qualifiedName[i + 1..qualifiedName.size - 1]`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §11「边界未校验 / 静默错误」
- **证据**：静态确定 —— 只要名字里出现 `<` 就按"最后一个字符必是 `>`"切片：`"Foo<Bar"` 会切出 `"Ba"`（丢掉最后一个字符），`"Foo<"` 会得到 `4..3` 这种非法区间直接抛 `IndexOutOfBoundsException`；`>` 出现在中间（`"Foo<Bar>Baz"`）时切出 `"Bar>Baz"` 再交给 `parseParameterTypes`。没有校验 `endsWith(">")`，也没有配平尖括号。
- **描述**：入参来自 `TypeInfo.qualifiedName`（可信）或调用方手写字符串；畸形输入不会得到"解析失败"，而是得到错位的类型名数组或一个与入参无关的越界异常。仓内调用点（`f_aspect` / `f_bean` / `f_orm` / `f_util`）都传 `TypeInfo` 派生值，风险低。
- **建议**：入口处 `if (!qualifiedName.endsWith(">") || !balanced) { return [] }`（或不匹配时抛 `IllegalArgumentException` 并带上原串），再用括号计数切分参数而不是固定 `size - 1`。

<!-- 第 3 部分 -->

### [严重][存量] #1 `TypeMemberInfos` 把**尚未填充**的 `HashMap` 先发布进 `ConcurrentHashMap`：并发首次查表静默返回 `None`

- **位置**：`f_base/src/TypeMemberInfos.cj:28`（`staticPropertyMap[typeInfo] = map` 在第 `29-42` 行的填充**之前**）、`f_base/src/TypeMemberInfos.cj:102`（`staticFunctionMap[typeInfo] = map` 在第 `103-119` 行填充之前）；同文件对照：`79`、`159` 是"填完再发布"的正确顺序
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入 / 发布逸出」、§11「并发正确性」
- **证据**：静态确定 —— `ConcurrentHashMap` 只保证单次操作线程安全、`get` 非阻塞（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:828`），被当作**值**存进去的 `HashMap` 本身不是并发容器（`collection_package_exception.md:14`："collection 包提供的容器类都不支持并发修改"）。执行顺序确定：线程 A 在 `28` 行 `put` 一个空 `HashMap` → 线程 B 在 `24` 行 `get` 命中同一个实例 → B 在 `56` 行 `map.get(name)` 得到 `None`（此时 A 还没执行 `29-42`），而 B 不会再去填充（`case Some(map) => map` 直接返回）。`getStaticFunctionMap`（`98-102`）同理。
- **描述**：反射元数据缓存是"首次查谁就谁填"的结构，填充窗口里任何并发调用方都会拿到**不完整视图**：`staticProperty` / `staticFunction` 对存在的成员返回 `None`，调用方据此走"没有该成员"分支（`f_bean/src/BeanFactory.cj:63` 判定 bean 是否有静态 `typeInfo`、`f_data` 的 `TypeInfos.functionHasAnnotation` 判定函数注解都在这个入口上）。另外 `staticProperties()` / `staticFunctions()`（`46-51`、`123-128`）把 `var` 表当前的 `values()` 直接交给调用方，若另一线程仍在 `29-42` 里 `map[p.name] = p`，就是"for-in 遍历容器途中被修改"（文档明确会抛 `ConcurrentModificationException`，`collection_package_exception.md:18`），属未定义行为而非"偶尔少一条"。
- **建议**：六处缓存统一改成"**局部填完再 `putIfAbsent` 发布**"（`79` / `159` 已是该写法，直接对齐）：`let map = HashMap...; fill(map); if (staticPropertyMap.addIfAbsent(typeInfo, map).isSome()) { 用已有值 } else { map }`；`addIfAbsent` 的返回值取"谁赢"，避免两个线程各自填充后互相覆盖。同时把 `values()` 的返回改成不可变快照（或文档写明"返回视图、不得并发读"，但更稳妥是发布后不再可变）。

### [严重][存量] #2 `@nameof` 展开引用了**不存在的宏** `@nameValue`：任何调用点都编译失败

- **位置**：`f_base/src/macros/nameof.cj:23-25`（`24` 行 `quote(@nameValue($input)[0])`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §14.1「承诺了但没实现 / 半成品」、§3「公开契约承诺有行为，实现不可用」
- **证据**：静态确定 —— 承诺源两处：本文件 `19-22` 的宏注释（"`@nameof(name)` 展开是 `'name'`"）与 `README.md:724`（把 `@nameof` 列为公开宏）；缺失证据：全仓 `*.cj`（`f_*` / `fdbm` / `fmq` / `fprobe` / `fleet` / `f_app`，排除 `.worktrees`）搜 `nameValue` 只有本文件这 3 处（`24` 的引用、`27-28` 的注释、`30` 的 `nameValueOf` 定义），宏包里没有任何名为 `nameValue` 的宏；语言文档（`cangjie_docs/**`）也搜不到该名字，不是编译器内置宏。此外即便存在这样一个宏，`[0]` 的下标形式对元组不成立，说明这是旧版实现的残留引用。
- **描述**：`@nameof` 是 `README.md` 承诺的公开能力（"宏包：`@nameof` / `@nameValueOf`"），但仓内**零使用**（全仓搜 `@nameof` 无命中），所以从未被编译器验证过；下游按 README 写 `@nameof(obj.field)` 会直接报"未声明的宏"，属"文档承诺、实现不可用"。同文件 `nameValueOf` 是可用的，说明只需把 `nameof` 展开式对齐即可。
- **建议**：`public macro nameof(input: Tokens): Tokens { quote($input) }` 不行（那会展开成表达式本身），应按注释语义取最后一个标识符：复用 `nameValueOf` 的 `last.kind == IDENTIFIER` 校验，然后 `quote('${identifier}')`（或 `quote(@nameValueOf($input)[0])`，前提是宏调用结果允许取下标）；同时补一条 `@Test` 用例，把"宏能展开"纳入编译期回归。

### [一般][存量] #3 `TypeMemberInfos` 父类遍历里循环变量写错：继承来的静态属性 / 实例变量永远查不到

- **位置**：`f_base/src/TypeMemberInfos.cj:29-33`（`30` 行 `for (p in typeInfo.staticProperties)`，应遍历参数 `ti`）、`f_base/src/TypeMemberInfos.cj:231-236`（`232` 行 `for (v in x.instanceVariables)`，应遍历 `c`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`，两处同一提交）
- **判据**：review-checklist §11「逻辑错误 / 语义与命名不符」、§2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 两处的同级实现都写对了，正好可以对照：
  - `getStaticPropertyMap` 的 `addProp(ti: TypeInfo)` 形参 `ti` 完全没用，循环体读的是外层 `typeInfo`（叶子类型）⇒ `addProp` 对每个祖先都做同一件事，**父类的 static property 一条也进不了表**；
  - `getInstancePropertyMap`（`65-69`）、`getStaticFunctionMap`（`103-110`）、`getInstanceFunctionMap`（`142-149`）都正确使用形参/`c`；
  - `getInstanceVariableMap`（`231-236`）外层已经在把 `cti` 沿 `c.superClass` 往上走，循环体却仍读 `x.instanceVariables` ⇒ 只有叶子类的实例变量进表，且被重复写入 `深度` 次。
- **描述**：`staticProperty(typeInfo, name)` 与 `instanceVariable(typeInfo, name)` 对**继承成员**恒返回 `None`。真实调用链有两条：`f_data/src/base/DataObject.cj:80/89`（`annotations` / `annotation` 在属性查不到时回退到 `instanceVariable`）与 `f_data/src/base/ReadableField.cj:52-60`（`tryGetAnnotation` → `MutableField.cj:25` 的 `@Validator`、`MutableField.cj:63` 的 `@DataConverter`）。也就是说**声明在父类上的 `var` 字段上的校验/转换注解会被静默丢弃**，数据校验与类型转换不执行，且没有日志。`ReadableField` 的查询结果还会进 `annotations.computeIfAbsent` 缓存，一旦按错误结果缓存，后续调用也不会自愈。
- **建议**：把 `30` 行改成 `for (p in ti.staticProperties)`、`232` 行改成 `for (v in c.instanceVariables)`；再补单测：`class Base { public var x: Int64 = 0 }`、`class Sub <: Base {}`，断言 `TypeMemberInfos.instanceVariable<Sub>("x").isSome()`、`staticProperty<Sub>("...").isSome()`（当前仓内**没有任何 `TypeMemberInfos_test.cj`**，见 #14，所以这类错误无从暴露）。

### [一般][存量] #4 `fromHex` 只校验上界：长度 0/1 抛越界，非十六进制字符抛 `NoneValueException`

- **位置**：`f_base/src/hex.cj:29-34`（`30` 行只判 `s.size > 2`，`33` 行直接取 `s[0]` / `s[1]` 并查 `hexmap`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「边界差一 / 空串未处理 / 错误处理缺失」
- **证据**：静态确定，依赖两条已现场核对的 std 语义：
  1. `String` 的 `[]` 是按下标取字节且有边界检查，`""` / `"a"` 取 `s[0]`、`s[1]` 直接抛 `IndexOutOfBoundsException`；
  2. `HashMap[]` 在键不存在时抛 `NoneValueException`（`collection_package_class.md:6160-6162`），而 `hexmap`（`19-25`）只装了 `'0'..'9'`、`'a'..'f'` 共 16 个键 ⇒ `"AB"` / `"g0"` / 多字节字符（`s.size` 是**字节数**，`'é'` 也被判成 2）全部走 `NoneValueException`，异常里没有任何"哪个字符非法"的信息。
- **描述**：函数契约只有一句"`s.size > 2` 抛 `IllegalArgumentException`"，实际还隐含"必须恰好 2 个字符且为小写十六进制"。仓内调用点只有 `fdbm/src/idmaker/IdMakers_test.cj:25`（固定 2 字符），所以是潜伏缺陷；一旦有人把它当通用 hex 解码器（`toHex` 的逆运算）用，空串/单字符/大写输入会得到与入参无关的异常类型。
- **建议**：入口统一为 `if (s.size != 2) throw IllegalArgumentException(s)`；字符校验用 `hexmap.contains`，非法字符抛带上下文的异常（如 `IllegalArgumentException("'${s}' is not a hex pair")`）；若需支持大写，初始化时把 `'A'..'F'` 也写进 `hexmap`。

### [一般][存量] #5 `ExitCallbacks.onExit` 在锁内 `for-in` 遍历回调表并执行回调：回调里再注册 `atExit` 直接抛 `ConcurrentModificationException`

- **位置**：`f_base/src/signal.cj:60-68`（`61` 行 `synchronized(mutex)`、`62-66` 双层 `for-in`），注册口 `48-59`
- **来源**：存量（`git blame`：`91978212cc 2026-09-01`，随 `f_app/src/signal.cj` 迁入）
- **判据**：review-checklist §12.1「迭代与修改并发 / 锁内调用外部回调」、§12.2「临界区内做不可控动作」
- **证据**：静态确定 —— `Mutex` 是可重入锁（`sync_package_classes.md:8927-8930`），所以回调里调 `atExit` **不会**被锁挡住，而是顺利进入 `49-58` 对 `callbacks`（`TreeMap`）/ 目标 `ArrayList` 做结构修改；而 `62-66` 正在 `for-in` 这两个容器，文档对该形态的结论是"遍历过程中修改容器时抛 `ConcurrentModificationException`"（`collection_package_exception.md:18`）。异常从信号处理函数里抛出 ⇒ 本轮剩余回调全部跳过，且 `exit(0)`（`44`）之前的状态已不可恢复。
- **描述**：`atExit` 是公开注册口（`README.md:731/742`，"回调按权重升序执行"），回调体是任意用户代码；"清理时顺手再注册一个收尾动作"是很自然的写法（例如关闭连接池后为新打开的临时文件注册删除）。当前实现把"遍历 + 执行"整体放在锁里，既拦不住同线程重入，又让其它线程的注册者一直阻塞到所有清理跑完（清理里有 join/close 时持锁时间不可控）。
- **建议**：快照后锁外执行：`let snapshot = synchronized(mutex) { callbacks.values().toArray() }`（或逐条 `removeFirst` 边取边执行），再在锁外依次 `atexit()`；这样既不会自修改遍历，也把外部回调移出临界区。补一条用例：两个回调，第一个在体内 `atExit(...)`，断言三个回调都执行且不抛异常。

### [一般][存量] #6 `toExitGracefully` 清掉别的模块注册的 SIGTERM/SIGINT，并在 handler 里 `exit(0)` 使后注册的 handler 永不执行

- **位置**：`f_base/src/signal.cj:39-47`（`41` 行 `resetSignalHandler(signals)`、`42-46` 注册处理器、`44` 行 `exit(0)`）
- **来源**：存量（`git blame`：`562abf068b 2026-09-01`）
- **判据**：review-checklist §12.1「死锁 / 异步语义」、§11「契约与实现不符」
- **证据**：静态确定（清空行为）+ 待确认（用户可见后果）—— 本文件 `23` 行 `public import` 的是 **std** 的同名函数，std 文档写明 `resetSignalHandler` 的功能是"清空注册的信号处理函数"（`runtime_package_funcs.md:587`），且 `registerSignalHandler` 的回调返回值 `false` 语义是"继续执行后续函数"（同文件 `507`）。于是两个方向都被切断：
  - 先于本函数注册的处理器被 `41` 行整体清空（`f_tui/src/render/Terminal.cj:57-58` 正是给 `SIGINT`/`SIGTERM` 各注册一个终端恢复处理器，`fprobe` 同时依赖 `f_tui` 与 `ExitCallbacks`，`fprobe/src/tui/SupervisorApp.cj:34` 走的就是本函数）；
  - 后于本函数注册的处理器即使存在，也永远轮不到：`44` 行 `exit(0)` 立即终止进程，FIFO 链上的下一个处理器没有机会执行——`46` 行 `false`（"继续后续"）在 `exit` 之后成为空话。
  `exit(0)` 是否触发 `std.env.atExit` 回调文档未明说（`env_package_funcs.md:53` 只说"立即终止当前进程"），所以"终端是否真被留在 raw 模式"记为待确认。
- **描述**：`README.md:728/736` 把"清除之前注册的这两个信号的处理函数"写成既有行为，但同一份文档在 `746-758` 又宣传 `registerSignalHandler` "不清空相同信号的其它处理函数"——同一个模块对外提供两套互斥语义，使用者无法既用 `ExitCallbacks` 又保留自己的信号处理。退出码固定 `0` 还会让上层（`fprobe` 这类监督进程）把"被 SIGTERM 杀掉"看成正常退出。
- **建议**：`toExitGracefully` 只注册自己的 handler、不再 `resetSignalHandler`（或在 README 明确"调用后 SIGTERM/SIGINT 归本模块独占，需自行在 `atExit` 里挂清理"）；`exit(0)` 改为 `exit(128 + signo)`（handler 已拿到 `Int32` 信号号，`registerSignalHandler(signals, handler: (Int32) -> Bool)` 重载现成），或用 `std.env.exit` 前显式 `atExit` 兜底并验证。

### [一般][存量] #7 `TypeMemberInfos` 六段缓存填充逻辑高度重复，已经漂移出三种不一致（含父类覆盖子类）

- **位置**：`f_base/src/TypeMemberInfos.cj:23-45`、`60-82`、`97-122`、`137-162`、`177-202`、`217-242`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「只改类型名 / 近似重复导致的行为漂移」
- **证据**：静态确定 —— 六段逐一比对"输入 → 输出 → 副作用"后，骨架相同（查 `ConcurrentHashMap` → 缺则建 `HashMap` → `ClassTypeInfo` 沿 `superClass` 走到 `Object` → 逐个成员写入 → 返回），差异只剩取值字段与三个**非语义必需**的漂移：
  1. 发布时机：`28` / `102` 先发布后填充，`79` / `159` / `186` / `197` / `226` / `237` 填充后发布（即 #1 的缺陷面）；
  2. 同名冲突策略：函数表用 `map.addIfAbsent(FuncMeta(...), f)`（`106`、`145`，子类先写入于是子类赢），属性/变量表用 `map[p.name] = p`（`31`、`67`、`184`、`193`、`224`、`233`，父类后写入于是**父类赢**）——同名属性被子类覆盖时，`instanceProperty` 会返回父类的 `PropertyInfo`；
  3. 结构分支：`177-202` / `217-242` 额外区分 `StructTypeInfo` 并对 `_` 返回 `EmptyMap`，前四段把 `_` 直接当非类处理（`40-42`、`76-78`、`117-119`、`156-158`），接口类型的静态/实例成员因此走 `addProp(typeInfo)` 而不是空表，语义不同却没有注释。
- **描述**：第 2 条与第 3 条是"重复实现各自演进"的典型后果：函数表与属性表对同名成员的取舍相反，调用方无法从 API 看出差异；接口类型在两族 API 上的行为也不一致。第 1 条已经造成 #1 的并发缺陷。
- **建议**：抽一个私有 `private func cachedIndex<K, V>(...)`（或 `private static func indexOfMembers(typeInfo, kind)`）统一"填充 → 发布 → 冲突策略"，冲突策略显式参数化（`childWins: Bool`），并在注释里写清为什么函数表要求子类优先、属性表也应当子类优先（同名 `prop` 被子类覆盖时显然应返回子类声明）。抽取不跨模块，落在本文件即可；改完用 #3 的单测覆盖"父类/子类同名成员"。

### [一般][存量] #8 `FuncMeta` 的 hash 由 `HashBuilder().append(param: Array<TypeInfo>)` 算出，而 `==` 按元素比较：可能整体破坏 `HashMap` 查找

- **位置**：`f_base/src/TypeMemberInfos.cj:257-268`（`260` 行算 hash、`263` 行 `param == other.param`）；`f_base/src/HashBuilder.cj:47-49`、`90-99`、`50-52` 的注释
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「哈希与相等契约」、`Hashable` 的 `hashCode` 必须与 `==` 一致
- **证据**：待确认（缺一条 SDK 语义证据）—— `HashBuilder` 对集合参数有运行时分支：`if (let x: Hashable <- args) { append(x.hashCode()); return this }`（`91-94`），即"数组实例若满足 `Hashable` 就按**身份**哈希"；`50-52` 的注释明确写了"`Array<T>`/`ArrayList<T>` 自身满足 `Hashable`，于是 `append<T>(arg: T) where T <: Hashable`（身份哈希）比 `append<T>(arg: Array<T>)` 更容易被选中"。而本文件 `263` 行的 `param == other.param` 走 `Array<T>` 的 `Equatable`（**按元素**比较，`core_package_structs.md:2014`）。若身份哈希成立，两条 `FuncMeta` 可以"相等但 hash 不同"⇒ `getStaticFunctionMap(...).get(FuncMeta(name, params))`（`133`、`173`）用调用方**新构造的数组**去查，哈希对不上，`staticFunction` / `instanceFunction` 恒返回 `None`。缺的证据是当前 SDK（1.3.0-alpha.20261112001016）里 `Array<T>` 是否真的实现 `Hashable`：本地 std 文档只列了 `Collection` / `Equatable` / `ToString`（`core_package_structs.md:1634-2852`），与 `HashBuilder.cj:50` 的注释矛盾，二者必有一个过期。
- **描述**：这是"哈希/相等契约"的潜在全面失效点，影响面很大：`TypeInfos.cj:74` 的 `instanceFunction(...)` 与 `f_data/src/base/DataObject.cj:166-168` 的 `staticFunction('tryParse', [TypeInfo.of<String>()])` 都靠这个查找，一旦 miss，前者让"函数注解"恒判定为无注解，后者让 `DataObject.tryParse` 直接 `getOrThrow()` 抛异常。若 Array 不满足 `Hashable`，则代码是对的（走 `append<T, I>(Iterable)` 的内容哈希），只剩注释过期。
- **建议**：先取证——写一个 5 行的 `@Test`：`let a = [TypeInfo.of<Int64>()]; let b = [TypeInfo.of<Int64>()]; @Assert(a.hashCode() == b.hashCode())`（或直接 `FuncMeta("f", a) == FuncMeta("f", b)` 且两者 `hashCode()` 相等）；若不等，把 `FuncMeta` 的 hash 改成显式内容哈希：`HashBuilder().append(name)` + `for (t in param) { hb.append(t.hashCode()) }`（顺序敏感，与 `==` 的数组逐元素比较一致），并订正 `HashBuilder.cj:50-52` 的注释。

### [轻微][存量] #9 `nextPowerOf2` 无上界：`n` 超过 2^62 时在 `x + 1` 溢出

- **位置**：`f_base/src/nextPowerOf2.cj:18-33`（`32` 行 `return x + 1`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11「边界未校验」
- **证据**：静态确定 —— `n ∈ (2^62, 2^63)` 时 `26-31` 的或运算把 `x` 抬到 `0x7FFF_FFFF_FFFF_FFFF`，`+1` 越过 `Int64.Max`；仓颉整数运算默认检查溢出并抛 `OverflowException`（`core_package_exceptions.md:1096`），所以结果是"抛一个与入参无关的异常"而不是返回上界。`n <= 0` 分支把 `default!` 当**输入**再递归一次（`20`），若调用方传 `default: 0`，会再落到默认值 `128` 上，行为与"用我给的默认值"不一致。
- **描述**：仓内唯一调用点 `f_cache/src/ConcHashMap.cj` 传的是容量，实际不会接近 2^62，故只是边界缺陷；但函数是 `public` 且没有文档说明上界。
- **建议**：入口加 `if (n > (1 << 62)) { throw IllegalArgumentException("n too large: ${n}") }`（或返回 `Int64.Max` 并在注释写清）；`n <= 0` 分支显式用 `nextPowerOf2(default, default: 128)` 或直接 `if (default <= 0) { 128 } else { nextPowerOf2(default) }`。

### [轻微][存量] #10 `ResourceManager.call` 重复实现 `resource()`，且不校验 `isClosed()`：第二次 `call` 静默使用已关闭资源

- **位置**：`f_base/src/resource.cj:31-38`（`try/finally` + `res.close()`）对照 `18-24`（同名语义的顶级函数）；`26` 的 `resource` 字段在 `call` 后不清空
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §2「跨函数复制」、§11「资源释放不对称 / 契约」
- **证据**：静态确定 —— `call` 的函数体 = `resource(res, fn)` 的函数体（`try { fn(res) } finally { res.close() }`）多一层 `getOrThrow()`；`Resource` 接口自带 `isClosed()`（`core_package_interfaces.md:1343-1350`）但这里没用。`README.md:388-390` 已经把这个行为写成契约（"第二次 `call` 会拿到已关闭的资源"），等于把缺陷文档化。仓内两处调用（`f_llm/src/tool/FileReadingFunction.cj:152`、`f_llm/src/tool/FileReplacingFunction.cj:77`）都是"就地新建、只 `call` 一次"，没有触发。
- **描述**：结构体对外宣称"管理资源生命周期"，却在第二次调用时把已关闭对象再交给 `fn`；`fn` 内部对已关闭 `File` 的操作行为取决于 std 实现，属静默错误而非显式失败。
- **建议**：`call` 开头 `if (res.isClosed()) { throw IllegalStateException("resource already closed") }`（或首次 `call` 后 `resource = None`，让 `getOrThrow()` 抛 `NoneValueException`）；实现上直接委托 `resource(res, fn)` 消除重复，再在 README 删掉"已知缺陷"式说明。

### [轻微][存量] #11 `WorkerStrategy` 三处注释是复制粘贴的错文案，且 `New` 的语义在其唯一消费方未实现

- **位置**：`f_base/src/WorkerStrategy.cj:42-49`（`DiscardCurrentAfter` / `DiscardOldestDuring` 的注释都写"等待 Duration，然后抛出 JobQueueFullException"）、`50-58`（`New`："创建新实例…如果是任务队列就创建新线程"）；消费方 `f_concurrent/src/eventbus/EventBus.cj:94-105`（`103` 行 `case CurrentThread | New => currentThreadStrategy`）、`193-195`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §2「字面量复制（同一段文案散落多处）」、§14.1「枚举新 case 没有分支 / 只做了一半的分支」
- **证据**：静态确定 —— 前两条只是注释错：消费方 `EventBus.cj:100-101` 分别调 `discardCurrentAfterStrategy` / `discardOldestDuringStrategy`，即"等待后丢弃"，与名字一致、与注释相反。`New` 则是承诺与实现不符：注释承诺"创建新实例 / 新线程"，`EventBus.cj:103` 把它和 `CurrentThread` 归到同一分支，`currentThreadStrategy`（`193-195`）就是 `arrange(id, e, true)` 在当前线程投递。
- **描述**：`WorkerStrategy` 是 `public enum`，被 `EventBus` 的 `fullJobQueueStrategy!` 参数直接暴露给使用者（默认 `Block`）；调用方按注释选 `New` 会得到"在调用线程执行"，直接违背"不阻塞调用线程"的预期。
- **建议**：改正 42-48 的两段注释（"等待 Duration，超时后丢弃"）；`New` 要么在 `EventBus` 里实现真正的"新建工作者/线程"分支，要么从枚举里删掉（对外 API 变更需拍板），退一步至少在枚举注释标注"当前 EventBus 实现等同 CurrentThread"。

### [轻微][存量] #12 `signal.cj` 三个注册函数各自重写一遍"遍历 signals"循环

- **位置**：`f_base/src/signal.cj:77-79` / `81-85`（`82-84` 的循环）、`91-95` / `97-102`（`99-101` 又写一遍同样的循环）
- **来源**：存量（`git blame`：`562abf068b 2026-09-01`）
- **判据**：review-checklist §2「换控制流 / 逐行对齐」
- **证据**：静态确定 —— `resetAndRegisterSignalHandler(signals, handler: (Int32) -> Bool)` 的 `97-102` = `resetSignalHandler(signals)` + `registerSignalHandler` 的 `81-85`；`(signals, () -> Bool)` 版与 `(signal, () -> Bool)` 版也只是把 `{_ => handler()}` 包一层。三对重载共 4 处相同循环/包装。
- **描述**：重复本身成本低，但"重置后注册"的口径以后要调整（例如只重置自己注册过的信号，见 #6）就要改两处，容易只改一处。
- **建议**：`resetAndRegisterSignalHandler(signals, handler: (Int32) -> Bool)` 改为 `resetSignalHandler(signals); registerSignalHandler(signals, handler)`；`(signals, () -> Bool)` 版同理委托 `(signal, ...)` 版。

### [轻微][存量] #13 `@nameValueOf` 的错误文案写成 `nameof`，`@nameof` 自身没有空入参校验

- **位置**：`f_base/src/macros/nameof.cj:32`、`39`（"macro nameof do not accept empty input" 等文案与所在宏 `nameValueOf` 不符）；`23-25`（`nameof` 无 `input.size == 0` 检查，直接 `$input` + `[0]`）
- **来源**：存量（`git blame`：`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10「可读性 / 错误信息准确」、§11「语义与命名不符」
- **证据**：静态确定 —— 两条 `diagReport` 的文案都以 `macro nameof` 自称，实际所在宏是 `nameValueOf`（`30`）；`nameof` 展开路径上没有空 `Tokens` 检查。
- **描述**：宏报错是使用者唯一能看到的诊断信息，指向错误的宏名会把排查方向带偏；`@nameof()` 这种空入参在 `nameof` 里没有前置校验（对比 `nameValueOf` 的 `31-34`）。
- **建议**：文案改为 `macro nameValueOf ...`；`nameof` 补同样的空入参检查（顺便按 #2 一起修）。

### [轻微][存量] #14 `TypeMemberInfos` 没有任何单测，两个循环变量 bug 因此长期潜伏

- **位置**：`f_base/src/TypeMemberInfos.cj`（全文件）；对照 `f_base/src/TypeInfos_test.cj:27-38`（本模块唯一的反射测试，只覆盖 `TypeInfos.get(qualifiedName)` 的两条路径）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §10「可测试性」、§11（缺陷可发现性）
- **证据**：静态确定 —— `f_base/src` 下不存在 `TypeMemberInfos_test.cj`（目录列举/全仓搜 `TypeMemberInfos_test` 均无），而 `TypeMemberInfos` 有 12 个 `public static` 入口、6 张缓存，被 `f_bean` / `f_data` 依赖。
- **描述**：#3 的两处 copy-paste 错误、#1 的发布顺序错误都属于"写一个 10 行用例就能发现"的类型，缺少用例是它们能长期存在的直接原因。
- **建议**：新增 `TypeMemberInfos_test.cj`，至少覆盖：父类 `var` 字段的 `instanceVariable` 查询（#3）、父类静态属性（#3）、同名成员父子优先级（#7）、`FuncMeta` 的 hash/相等一致（#8）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

> 本部分没有 `cjprof` / `cjpm bench` 基线，三条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [CPU] `TypeInfos.get<T>()` 每次调用都重新做一次 `TypeInfo.of<T>()`

- **现状**：`f_base/src/TypeInfos.cj:32-36` 的 `get<T>()` 直接 `TypeInfo.of<T>()`，不做任何缓存；同文件 `24-27` 保留着一段被注释掉的 `private class Types<T> { static let INSTANCE = TypeInfo.of<T>() }`，注释写明"待支持静态成员再改回使用 Types"。姓名版 `get(qualifiedName)`（`37-53`）已经有双检 + `INFOS` 缓存，两个入口的成本不对称。
- **方案**：恢复"每 `T` 一份静态实例"的缓存——若泛型静态成员仍不可用，用 `ConcurrentHashMap<String, TypeInfo>` 按 `TypeInfo.of<T>().qualifiedName` 缓存（与 `INFOS` 共用一张表即可，`get(qualifiedName)` 已经建好）。
- **预期**：把"每次反射查表 + 构造 `TypeInfo`"降为一次 map 查；收益取决于 `get<T>()` 的调用频次（`f_bean` 条件求值、`f_orm` 字段映射都在启动期密集调用），**收益幅度未测**。
- **代价**：`INFOS` 表多出按 `T` 的条目（与姓名版重复，键相同则自然合并）；类型集合在进程内固定，不会无界增长。
- **验证**：`cjpm bench -O2` 循环 `TypeInfos.get<SomeType>()` 1e6 次对比中位耗时；在 `get<T>()` 入口加计数，跑一次 `fboot` 启动统计调用次数，确认是否值得缓存。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `InheritedTaskLocal` 的哈希退化（同任务全部同桶）

- **现状**：`f_base/src/FutureTask.cj:335-337` ⇒ 同一任务的所有 local 哈希值相同（见 #13）；每次 `set/get/remove` 都要在单桶里 `refEq` 线性扫描，表大小 = 该任务的 local 数（通常 1–5）。
- **方案**：给 `AbstractInheritedTaskLocal` 分配单调 `localId` 作 `hashCode`（`AtomicInt64`，与 `nextTaskId` 同款）。
- **预期**：单次查找从 O(#local) 降到 O(1)；n 很小时绝对值收益是纳秒级，**需先证明该路径是热点**（`set/get` 在任务体内可能被高频调用）。
- **代价**：多一个 `Int64` 字段、多一次原子自增（仅构造期）；`hashCode` 语义变化不影响外部（`AbstractInheritedTaskLocal` 的 `==` 仍是 `refEq`）。
- **验证**：微基准：单任务 1/4/16 个 local，各跑 1e6 次 `get`，对比中位耗时；`cjprof` 看 `HashMap.get` 在 `f_base` 自身耗时中的占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `StringGenerator.reverse()` 全量复制 + 每 Rune 一个 `String`

- **现状**：`f_base/src/StringGenerator.cj:250-259`：`toString()`（`253`）把整个缓冲区复制成一个 `String`，循环里每个 `rune.toString().unsafeBytes()`（`254`）再各分配一个 `String` + 一个 `Array<Byte>`；峰值约为内容大小的 2 倍 + O(#rune) 个小对象。
- **方案**：直接按 UTF-8 码点边界在原地倒序（从尾部扫前导字节判断码点长度，或用一个固定 4 字节栈内 `Array<Byte>` 交换），不建 `String`、不建逐 Rune 数组。
- **预期**：峰值从 ~2n 降到 ~n，分配次数从 O(#rune) 降到 O(1)；`reverse` 是否在热路径未知。
- **代价**：需要自己处理 UTF-8 边界（当前 `runes()` 会对非法字节产出 U+FFFD，原地版本要么同样替换要么显式抛错，语义要定）；代码复杂度上升。
- **验证**：n = 1KB / 1MB 的 `StringGenerator` 跑 1000 次 `reverse`，对比 `getAllocatedHeapSize()` 峰值与 RSS，并对 ASCII/中文/emoji 混合串做前后字节一致断言。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 3 部分 -->

> 本部分没有 `cjprof` / `cjpm bench` 基线，三条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [CPU] `toHex` 每个字节做一次双 `Rune` 字符串插值

- **现状**：`f_base/src/hex.cj:26-28` 每调用一次分配 1 个 `String` 并做 2 次 `hex[...]` 数组下标 + 2 次 `Rune` 转字符串；调用方把字节渲染成文本时是**逐字节**调用（`fdbm/src/sql/SqlRenderer.cj:19`、`f_dbd/src/driver/DbdUrl.cj:20` 都 `import fountain::f_base.toHex`）。
- **方案**：静态初始化一张 `Array<String>(256) { i => ... }` 的两位小写表，`toHex(b)` 直接 `HEX_TABLE[Int64(b)]` 返回（返回的 `String` 不可变、可安全共享）；`fromHex` 同步用 256 项 `Array<Byte>`（非法位置填 0xFF）替掉 `HashMap` 查表。
- **预期**：单次调用从"1 次分配 + 2 次 boxed 下标 + 插值"降到"1 次数组读、0 分配"；端到端收益取决于 `toHex` 在 SQL 渲染里的调用次数（**未测**）。
- **代价**：多 256×2 个常驻对象（约几 KB）；`fromHex` 的非法字符判断从"抛 `NoneValueException`"变成显式分支（与 #4 的修法合并做最省事）。
- **验证**：`cjpm bench -O2` 对比 1e6 次 `toHex(Byte)` 的中位耗时与 `getAllocatedHeapSize()` 增量；再在 `fdbm` 的 SQL 渲染路径上跑分段计时，确认 `toHex` 是否进入前 10。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TypeMemberInfos` 每次父类遍历都重新取一次 `ClassTypeInfo.of<Object>()`

- **现状**：`f_base/src/TypeMemberInfos.cj:36`、`72`、`113`、`152`、`191`、`231` 六处 `while` 条件里各调用一次 `ClassTypeInfo.of<Object>()`；每次反射查表 + 比较在"每个类型首次填充"时执行一次，深度为类继承层数。
- **方案**：提取 `private static let OBJECT_CLASS_INFO = ClassTypeInfo.of<Object>()`（或 `TypeInfo.of<Object>()`）到类级常量，循环条件改用它。
- **预期**：把每次填充的反射调用从 `O(深度)` 降到 1；绝对收益是微秒级，只有类型数很多（数百个 `@DataAssist` 类型）且填充集中在启动期时才可能可见（**未测**）。
- **代价**：一个常驻引用（`TypeInfo` 本身就常驻，无额外内存）；无行为变化。
- **验证**：`cjpm test` 跑 `f_data` / `f_orm` 冷启动，分段计时"反射元数据首次填充"总耗时；`cjprof` 看 `ClassTypeInfo.of` 的调用次数与自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `TypeMemberInfos` 为每个类型常驻 6 张 `HashMap`

- **现状**：`f_base/src/TypeMemberInfos.cj:22`、`59`、`96`、`136`、`176`、`216` 各一张 `ConcurrentHashMap<TypeInfo, HashMap<...>>`；一个被反射过的类型最多产生 6 个内层 `HashMap` + 6 个外层条目（外加键的 `TypeInfo` 引用）。条目数 = 该类型的静态/实例属性、函数、变量数量之和。
- **方案**：合并为 `HashMap<TypeInfo, MemberIndex>`，`MemberIndex` 内放 6 张（或 4 张，函数/变量/属性按需延迟建）表；或把 6 张顶层表换成一张 `ConcurrentHashMap<(TypeInfo, MemberKind), ...>`。关键是"每个类型一个索引对象"，与 #7 的抽取一起做。
- **预期**：每类型常驻对象数从 6 降到 1–2，外层表条目从 6 降到 1；收益与"被反射类型数 × 成员数"成正比（**未测**，类型数在 `f_orm` / `f_data` 全量启动时可能上百）。
- **代价**：需要一次结构性重构（6 组 API 共用索引），并发发布策略必须同时按 #1 修正；`MemberIndex` 变大后单类型的内存占用不变，只是少了容器壳。
- **验证**：对 `f_orm` + `f_data` 全量类型跑一次初始化，输出 `getAllocatedHeapSize()` 前后差与 `TypeMemberInfos` 内层 `HashMap` 计数（临时加计数埋点）；RSS 对照 `mem §1.2` 的有界稳态判定。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `hasSse41` 每次读 `/proc/cpuinfo` 若被上层放进编译循环会成为 I/O 热点（当前仅 `X86Lower` 构造时读一次，疑似不成立） | `f_base/src/CpuFeatures.cj:29-33`、`43-54` | 调用次数分布（每次 JIT 编译几次） | 在 `detectSse41` 加计数器，跑 `f_jit` 编译 10k 个表达式，看计数与 `openat` 系统调用次数 |
| 2 | `toArray()` 的 `ArrayList` 中转使物化路径峰值内存翻倍以上 | `f_base/src/ExtendIterator.cj:46-51` | n 与实际峰值 RSS / heap 的对照 | 对 n = 1k / 100k / 1M 跑 `toArray()`，记录 `getAllocatedHeapSize()` 峰值与 RSS，改成直接预分配后再测 |
| 3 | `Arch.hashCode()` 每次拼 `'fountain::f_base.Arch.${this}'` 再做字符串哈希，作为 map key 时分配开销高于直接返回序数 | `f_base/src/Arch.cj:23-25` | 单次耗时、分配量、`Arch` 作 key 的频次 | 微基准 100 万次 `hashCode()` + `cjprof` 看分配；统计 `HashMap<Arch, ...>` 使用点 |
| 4 | `async()` 每元素一个线程的创建成本（即使修好并发问题）在物化路径上远超元素处理成本 | `f_base/src/ExtendIterator.cj:20-27` | 线程创建/销毁耗时占比、可并行度 | 1000 元素各跑 10 次，分段计时 `spawn` vs `get`，并与固定大小线程池版本对照 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个 `FutureTask` 都 `spawn` 一个 OS 线程（`FutureTask.cj:252`），任务数上千时线程创建/栈内存成为主要成本 | `f_base/src/FutureTask.cj:252-285` | 单任务创建耗时、每任务栈占用、并发任务数分布 | 创建 1k/10k 个立即返回的任务，分段计时构造 vs `get`，并读 `/proc/self/status` 的 `VmRSS`/线程数；对照改成有界线程池或协程的方案 |
| 2 | `subTasksLock`（全局唯一）在任务构造/拆除路径上形成锁竞争 | `f_base/src/FutureTask.cj:60-61`、`235-247`、`266-268` | 锁等待时长、竞争线程数 | 8/32 线程各创建 10k 个短任务，`cjprof` 看 `synchronized` 阻塞时间，或在线程状态采样里统计 BLOCKED 比例 |
| 3 | `InheritedTaskLocal` 同桶导致 `set/get` 的桶内线性扫描成为热点 | `f_base/src/FutureTask.cj:335-337`、`88-114` | 单任务 local 数分布、`HashMap.get` 自耗时占比 | 在 `readLocalRaw` 加计数（次数 × 表大小），跑 `f_orm`/`f_bean` 真实负载 10 分钟，再看 `cjprof` 里 `f_base` 的占比是否 >5% |
| 4 | `TypeInfos.get<T>()` 无缓存在启动期被高频调用 | `f_base/src/TypeInfos.cj:32-36` | 调用次数、单次 `TypeInfo.of<T>()` 耗时 | 入口加 `AtomicInt64` 计数，跑一次 `fboot` 启动；`cjpm bench` 测单次调用 |
| 5 | `StringGenerator.reverse()` 的双份内容使峰值内存翻倍（当前仓内 0 调用点，属对外 API 潜在路径） | `f_base/src/StringGenerator.cj:250-259` | 调用频次、n 的分布、峰值 RSS | 先统计外部使用方的 `reverse()` 调用点（仓内已确认为 0），若有则按 1MB 串测 `getAllocatedHeapSize()` 峰值 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `toHex` 在 SQL / URL 渲染热路径上逐字节调用，字符串插值成为可观开销 | `f_base/src/hex.cj:26-28`（调用方 `fdbm/src/sql/SqlRenderer.cj`、`f_dbd/src/driver/DbdUrl.cj`） | 调用次数、单次耗时、占总渲染时间比例 | 在 `toHex` 入口加 `AtomicInt64` 计数，跑一次带大 `WHERE IN` 的查询；`cjprof record` 看 `hex.toHex` 自耗时占比是否 >5% |
| 2 | `TypeMemberInfos` 的首次填充在启动期被多线程同时触发（#1 的窗口是否真的被踩到） | `f_base/src/TypeMemberInfos.cj:28`、`102` | 并发填充次数、命中半填表的次数 | 在 `28`/`102` 后与 `43`/`120` 后各加计数，`fboot` 启动跑 100 次，统计"发布后仍有并发读"的比例；或直接构造 8 线程同时查同一类型做压力用例 |
| 3 | 六张反射缓存的总常驻内存占 `f_base` 堆的显著比例 | `f_base/src/TypeMemberInfos.cj:22-242` | 类型数、每张表条目数、字节量 | 加计数导出"类型数 × (属性+函数+变量) 条数"，配合 `cjprof heap` 看 `HashMap` 实例数与占用 |
| 4 | `onExit` 的清理回调持锁时间较长，导致退出时 `atExit` 注册线程长时间阻塞 | `f_base/src/signal.cj:61-67`（回调体如 `fdbm/src/server/FdbmServer.cj:167` 的 `stop()`） | 单个回调耗时、退出阶段阻塞线程数 | 在 `62-66` 前后打点计时，记录每个回调耗时；杀进程时采样线程状态（BLOCKED 占比） |

## 文件覆盖

> 与 `files/f_base.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_base/README.md` | .md | ✅ | — |
| 2 | `f_base/README_en.md` | .md | ✅ | — |
| 3 | `f_base/src/Arch.cj` | .cj | ✅ | — |
| 4 | `f_base/src/BaseCommand.cj` | .cj | ✅ | — |
| 5 | `f_base/src/BaseException.cj` | .cj | ✅ | — |
| 6 | `f_base/src/Bucket.cj` | .cj | ✅ | — |
| 7 | `f_base/src/Comparator.cj` | .cj | ✅ | — |
| 8 | `f_base/src/Comparator_test.cj` | .cj | ✅ | — |
| 9 | `f_base/src/Console.cj` | .cj | ✅ | — |
| 10 | `f_base/src/CpuFeatures.cj` | .cj | ✅ | — |
| 11 | `f_base/src/CpuFeatures_test.cj` | .cj | ✅ | — |
| 12 | `f_base/src/EmptyCollections.cj` | .cj | ✅ | — |
| 13 | `f_base/src/Equaler.cj` | .cj | ✅ | — |
| 14 | `f_base/src/ExtendArray.cj` | .cj | ✅ | — |
| 15 | `f_base/src/ExtendIterator.cj` | .cj | ✅ | — |
| 16 | `f_base/src/ExtendNumber.cj` | .cj | ✅ | — |
| 17 | `f_base/src/ExtendOption.cj` | .cj | ✅ | — |
| 18 | `f_base/src/ExtendRange.cj` | .cj | ✅ | — |
| 19 | `f_base/src/ExtendRune.cj` | .cj | ✅ | — |
| 20 | `f_base/src/ExtendString.cj` | .cj | ✅ | — |
| 21 | `f_base/src/ExtendThreadLocal.cj` | .cj | ✅ | — |
| 22 | `f_base/src/FutureTask.cj` | .cj | ✅ | — |
| 23 | `f_base/src/FutureTask_test.cj` | .cj | ✅ | — |
| 24 | `f_base/src/HashBuilder.cj` | .cj | ✅ | — |
| 25 | `f_base/src/Help.cj` | .cj | ✅ | — |
| 26 | `f_base/src/LocalComparable.cj` | .cj | ✅ | — |
| 27 | `f_base/src/LocalEquatable.cj` | .cj | ✅ | — |
| 28 | `f_base/src/NoneOrder.cj` | .cj | ✅ | — |
| 29 | `f_base/src/OS.cj` | .cj | ✅ | — |
| 30 | `f_base/src/Operators.cj` | .cj | ✅ | — |
| 31 | `f_base/src/OptionComparable.cj` | .cj | ✅ | — |
| 32 | `f_base/src/Options.cj` | .cj | ✅ | — |
| 33 | `f_base/src/OverSizeException.cj` | .cj | ✅ | — |
| 34 | `f_base/src/OverSizePolicy.cj` | .cj | ✅ | — |
| 35 | `f_base/src/Peekable.cj` | .cj | ✅ | — |
| 36 | `f_base/src/Result.cj` | .cj | ✅ | — |
| 37 | `f_base/src/SingleIterable.cj` | .cj | ✅ | — |
| 38 | `f_base/src/StringGenerator.cj` | .cj | ✅ | — |
| 39 | `f_base/src/StringGeneratorRune_test.cj` | .cj | ✅ | — |
| 40 | `f_base/src/TypeInfos.cj` | .cj | ✅ | — |
| 41 | `f_base/src/TypeInfos_test.cj` | .cj | ✅ | — |
| 42 | `f_base/src/TypeMemberInfos.cj` | .cj | ✅ | — |
| 43 | `f_base/src/UnsafeBytes.cj` | .cj | ✅ | — |
| 44 | `f_base/src/UnsafeData.cj` | .cj | ✅ | — |
| 45 | `f_base/src/WorkerStrategy.cj` | .cj | ✅ | — |
| 46 | `f_base/src/hex.cj` | .cj | ✅ | — |
| 47 | `f_base/src/macros/nameof.cj` | .cj | ✅ | — |
| 48 | `f_base/src/native.cj` | .cj | ✅ | — |
| 49 | `f_base/src/nextPowerOf2.cj` | .cj | ✅ | — |
| 50 | `f_base/src/public_std_imports.cj` | .cj | ✅ | — |
| 51 | `f_base/src/resource.cj` | .cj | ✅ | — |
| 52 | `f_base/src/signal.cj` | .cj | ✅ | — |
| 53 | `f_base/src/unsafeZeroValue.cj` | .cj | ✅ | — |
| 54 | `f_base/src/zero_timer.cj` | .cj | ✅ | — |

合计：`.cj` 52 个 / `.md` 2 个 / 共 54 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #1 / #3 / #6 / #8 / #9 / #17；设计 #4 / #7 / #12 / #13 / #14；语言特性：#12（`Hashable` 契约）、#13（哈希与身份）；安全性：无 SQL / HTML / 路径拼接、无凭据、无外部输入直接进缓冲区，未命中 |
| §1 死代码 | 2 | 逐个 `private`（全仓搜）/ 默认 `internal`（本包内搜）/ `protected`（本 module 内搜）过一遍：`HashBuilder.a`、`hashed`、`StringGenerator.checkIndex` / `indexOf` / `lastIndexOf`、`Options.doConvert`、`OverSizePolicy` 的 `max`/`remove`/`monitor`/`condition`/`recovered`/`timeout`/`policy`、`Result` 各字段、`TypeInfos.INFOS`/`MUTEX`、`AbstractFutureTask` 的 `currentTask`/`subTasks`/`subTasksLock`/`hasChildren`/`finished`/`parentTID`/`parent`/`pruneFinishedChildren`/`setLocal`/`getLocal`/`removeLocal`/`getOrSetLocal`/`getOrComputeLocal` 均有引用。命中：`Help` 整类（#7，`internal` 顶层 + 全仓零引用）、`HashBuilder.append(Map)`（#10）。`AbstractFutureTask.cancelSelf` 虽为 `sealed` 类的 `protected`，但被 `shutdown()` 调用（`172`），不算死代码；`OS.cj:122-127` 的注释块并入 #16；对外可达的 `public`（`FutureTask` / `InheritedTaskLocal` / `OS` / `Result` / `Options` / `Peekable` / `SingleIterable` / `Operators` 接口族）不判 |
| §2 重复逻辑 | 3 | 同文件两两比对 60+ 个函数体：`HashBuilder` 的 `Map` / `ConcurrentHashMap` 两版 9 分支级联（#10）、`StringGenerator` 三个 `replace*` 的拼接块与 `reset`/`clear`（#11）、测试里两个 `pollCancel`（#15）。不判：`HashBuilder` 的 12 个基础类型 `append`（为避免装箱刻意展开）、`Options` 的 8 个 `isEmptyOr*`（判据不同）、`OS` 的 7 个 `is*` 属性与 `LocalComparable`/`LocalEquatable` 的模态重载（语言要求两组）、`Help` 的两个 `String` 版本已随 #7 整类删除不重复计 |
| §3 空实现 | 0 | 逐处核对：`AbstractFutureTask.cancelSelf`（`176`）是 `FutureTask` 必然覆盖的钩子；`DiscardOverSizePolicy.reject`（`36`）是"丢弃"策略的语义本体；`PeekableIterator.close` 的 `case _ => ()` 是"底层不是 Resource"的正常分支。无 `TODO` / `UnsupportedException` / `catch { }` |
| §4 栈溢出 | 0 | 递归只有两处：`shutdownCurrentSubThreads → f.shutdown()`（`186-191`，深度 = 任务树深度，每层是一个 OS 线程，实际深度极小；其"只对本线程生效"的问题已归 #2）；`getOrCompute` 内 `fn` 自递归（可重入锁不拦）已写入 #4 描述，不重复计。无自引用结构打印、无深度拷贝、无用户输入决定的递归 |
| §5 OOM | 1 | #1（`remove` 的 `torm` 随迭代次数无界增长）。另核对了 `subTasks` 的桶（阈值 64 剪枝 + 父任务整体摘除，有界，见 `198-208`、`262-283`）、`TypeInfos.INFOS`（键 = 类型名，进程内类型集合有界）、`Options` / `Result` 无物化路径 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；5 条疑似热点全部进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分两处锁：`subTasksLock`（#14，设计层记录为轻微，争用数据缺失 ⇒ 收益进假设 2）、`local.initLock`（#4，问题是"锁内跑用户回调"而非"锁太大"）。无锁内 I/O、无锁内日志 |
| §6.3 并发串行 | 0 | 无 "`spawn` 后立刻 `get()`"：`FutureTask` 的 `spawn` 只发布 future，`get` 由调用方决定何时等。`shutdownCurrentSubThreads` 在锁外发取消信号（`178-192`），不构成串行热点 |
| §6.4 低效算法 | 0 | 无 `remove(at: 0)` 队列、无双层循环匹配；`StringGenerator` 的 `indexOf` 是 std 的子数组搜索，`replace` 的 `while` 是线性推进（零长串例外已在 #1 报）；`Result` / `OptionComparable` 均为常量次比较 |
| §7 降堆内存方案 | 1 | 优化方案 3（`reverse` 双份内容），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 1（`TypeInfos.get<T>` 缓存）、2（local 哈希），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分无合格候选：`HashBuilder` 注释已说明"只作局部变量、逃逸分析会栈上分配"（`21-24`），加 `@ local` 无增量收益；`StringGenerator` 的缓冲区生命周期跨函数（builder 作为字段/返回值逃逸，`unsafeBytes()` 直接把内部数组交出去）；`FutureTask` / `Result` / `Options` 无函数内大临时对象。约束 3（非 `Copyable` 需 local 构造重载）在 `ArrayList` / `HashMap` 上也无对应 API |
| §11 现有代码的 BUG（存量） | 17 | 全部 17 条均为存量（快照无 diff）。另逐项核对了本轮读到的边界与空值：`Options.isEmpty*` 的 `getOrThrow` 前短路、`PeekableIterator.next/peek` 的 `None` 语义、`SingleIterator.next` 的二次读取、`Result` 的 `filter*` / `map*` 穷尽 `match`、`OS.valueOf` 的非法名抛错、`ExtendThreadLocal.getOrCompute` 的 `None` 语义，均无缺陷 |
| §12 并发安全与锁粒度 | 4 | 并发安全 #2（跨线程取消错对象）、#4（回调持锁 → 互等/递归）、#5（线程 id 作长期键）、#13（哈希退化属数据结构层，不计入并发）；锁粒度 #14。已核对的同步手段：`local` 的全部读写都在 `localLock` 内（`88-114`，读也在锁内 ⇒ 无发布问题）、`taskId` / `finished` 走原子量、`future` 只在构造期发布（`300-308` 用 `None` 分支把"未构造完"显式抛成本模块异常）。结论：**可见性面没有找到缺口**，风险集中在"锁的作用域"与"键的生命周期" |
| §14 功能完备性与 README 覆盖 | 1 | #7（`Help` 被 README 当公开 API，实际 `internal` 不可达）；#10 附带 README 把 private 重载写成 API。本部分其余 `public` 符号（`FutureTask` / `InheritedTaskLocal` / `OS` / `Result` / `Options` / `StringGenerator` / `HashBuilder` / `TypeInfos` / `Peekable` / `SingleIterable` / `OverSize*` / `Operators` 接口族 / `Local*`）在 `README.md:625-689`、`704-724` 或各自章节均有登记 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`（README 仅作取证判据引用，其正文审查属第 1 部分） |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #3 / #4 / #8 / #9；设计 #1（缓存发布顺序）/ #7（重复实现漂移）/ #10（职责与契约）/ #11（枚举语义）；可读性 #13；语言特性：#8（`Hashable` 与 `==` 的契约）、#3（`@OverflowWrapping` 未用于 hex/位移无关）。安全性：本部分无 SQL / HTML / 路径拼接、无凭据、无外部输入进缓冲区（`fromHex` 的非法输入只会抛异常，已在 #4 报），未命中 |
| §1 死代码 | 0 | 逐个 `private`（全仓搜）/ 默认 `internal`（本包及子包搜）/ `protected`（本 module 内搜）过一遍，全部有引用：`TypeMemberInfos` 的 12 个私有成员与 6 张表都被本文件的 12 个 `public static` 用到；`hex.hex`/`hexmap` 被 `toHex`/`fromHex` 用；`native.memcpy`/`getpagesize` 被 `mcopy`/`MEM_PAGE_SIZE` 用；`ResourceManager.resource` 被 `call` 用。`class FuncMeta`（包内可见）及其 `==`/`hashCode` 是接口实现，按误报边界不判。对外可达的 `public`（`TypeMemberInfos` 全部静态入口、`UnsafeBytes`/`UnsafeData` 及其 extend、`WorkerStrategy`、`toHex`/`fromHex`、`@nameof`/`@nameValueOf`、`MEM_PAGE_SIZE`/`nullptr`/`mcopy`、`nextPowerOf2`、`resource`/`ResourceManager`、`ExitCallbacks`/`registerSignalHandler` 族/`SIGIOT`/`SIGSEGV`、`unsafeZeroValue`、`ZERO_TIMER`、5 个 `public import`）一律不判；仓内零引用者已在覆盖面逐条记为"对外 API"（`resetAndRegisterSignalHandler` 的 6 个重载、`@nameof`/`@nameValueOf` 在仓内零使用，但都是对外契约）。无不可达语句、无恒真恒假分支、无未使用 import（`TypeInfos_test` 的 3 个 import、`signal.cj` 的 4 个 import、`UnsafeData` 的 `ArrayList` 均有用） |
| §2 重复逻辑 | 3 | 同文件两两比对：`TypeMemberInfos` 六段缓存填充（#7，已漂移出 3 种不一致）、`signal.cj` 的注册循环（#12）、`resource.cj` 的 `call` vs `resource`（#10）。另核对了 `WorkerStrategy` 三段复制文档注释（并入 #11）、`toHex`/`fromHex`（互逆运算，不是重复）、`TypeMemberInfos` 的 12 对 `xxx<T>()` / `xxx(typeInfo)` 重载（只是转调，属预期 API 形态，不判） |
| §3 空实现 | 2 | 命中的是"公开契约无实现"：#2（`@nameof` 展开成不存在的宏，等于不可用）、#11 的 `New` 分支（注释承诺新线程，实现是当前线程）。`signal.cj` 的 Windows 空实现（`70-74`、`109-137`）是条件编译桩、`README.md:747` 已声明"仅 Windows 空实现"，不判；`UnsafeBytes`/`UnsafeData` 接口无默认空体 |
| §4 栈溢出 | 0 | 递归只有 `nextPowerOf2` 的一层自递归（`20`，`default!` 固定 128 时深度恒为 1，异常输入已在 #9 报）；`TypeMemberInfos` 的父类遍历是 `while` 不是递归；`@nameof`/`@nameValueOf` 是编译期宏、无递归展开；无自引用结构打印、无深度拷贝 |
| §5 OOM | 0 | 逐项核对：`TypeMemberInfos` 6 张缓存以 `TypeInfo` 为键，进程内类型集合有界（无按请求 ID 建键）；`hexmap` 固定 16 项；`ExitCallbacks.callbacks` 只随启动期 `atExit` 注册增长（无按请求注册的调用点，`f_app`/`fdbm`/`fmq`/`fprobe` 各 1 处）；`fromHex`/`toHex` 无物化；无"按不可信长度预分配"（未出现 `Array(n, repeat:)`） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，4 条疑似热点全部进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 1 | #5（`onExit` 在 `mutex` 内执行全部用户回调，含 `stop()` / `close()` 这类可能 join 的动作）——但退出路径上不影响吞吐，故只按"锁内跑外部回调"记一般，收益/耗时数据进假设 4 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 Future/线程池、无"逐条 get"；`ExitCallbacks` 的回调本就是串行退出语义 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `contains` 热点、无 `remove(at: 0)`、无循环内字符串 `+`（`toHex` 的插值是单次两字符，已进优化方案 1）；`TypeMemberInfos` 的 `while` 是 O(继承深度)，深度由类层次决定且只在首次填充 |
| §7 降堆内存方案 | 1 | 优化方案 3（6 张表合并为每类型一个索引），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 1（`toHex` 256 项表）、2（`ClassTypeInfo.of<Object>()` 提出循环），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 无合格候选：`TypeMemberInfos` 构造的 `HashMap` 是**缓存值**，必须逃逸出函数（存进静态表），逃逸检查直接不通过；`toHex`/`fromHex` 的临时对象是 1 个 `String` / 2 次查表，峰值内存可忽略；`resource`/`signal`/`nextPowerOf2` 无函数内大临时对象。也没有 `getAllocatedLocalObjectSize()` 前后的峰值对照数据 |
| §11 现有代码的 BUG（存量） | 14 | 全部 14 条均为存量（快照无 diff，`git blame` 落在 `4be871f2fd 2026-10-02` / `562abf068b 2026-09-01` / `91978212cc 2026-09-01`）。另逐项核对了本轮读到的边界与空值：`TypeMemberInfos` 的 `xxx(typeInfo)` 重载不校验 `typeInfo` 合法性但签名要求非空；`ExitCallbacks.atExit` 的 `entryView` 对缺失键写入会新增（文档 `collection_package_interface.md:468-470` 已核）；`MapEntryView` 在容器被改后会失效（`collection_package_exception.md:19`）——本文件只在锁内立即使用，成立；`native.mcopy` 的 `n` 由调用方保证；`unsafeZeroValue` 直通 |
| §12 并发安全与锁粒度 | 3 | 并发安全 #1（发布半填容器 + 非线程安全 `HashMap` 跨线程读写）、#5（锁内用户回调 + 自修改遍历）、#6（`resetSignalHandler` 清空他人注册 + `exit(0)` 抢占）。已核对的同步手段：`hex`/`hexmap` 是"初始化后只读"的全局 `let`（无写路径）；`ExitCallbacks.callbacks` 的全部读写都在 `mutex` 内（`49-58`、`61-67`）；`TypeMemberInfos` 的 6 张表本身是 `ConcurrentHashMap`、单次 `get`/`put` 原子（`collection_concurrent_class.md:828`）——缺口只在"值对象发布时机"。锁粒度：#5 的临界区含全部回调执行，建议快照后锁外跑 |
| §14 功能完备性与 README 覆盖 | 3 | #2（README `724` 承诺的 `@nameof` 不可用）、#11（`New` 变体语义未实现）、#10（`ResourceManager` 的行为缺陷被写进 README `388-390` 当契约）。其余本部分 `public` 符号已在 README 登记：`TypeMemberInfos`（`789`）、`UnsafeBytes`/`UnsafeData`（`474-491`）、`unsafeZeroValue`/`ZERO_TIMER`（`497`/`506`）、`resource`/`ResourceManager`（`376-395`）、`ExitCallbacks`（`727-744`）、`registerSignalHandler` 族（`746-758`）、`SIGIOT`/`SIGSEGV`/`nextPowerOf2`/`toHex`/`fromHex`/`MEM_PAGE_SIZE`/`nullptr`/`mcopy`/`WorkerStrategy`/`@nameof`/`@nameValueOf`（`721-724`）；`resetAndRegisterSignalHandler` 仓内零调用但已在 README 声明，属对外 API |
| 文件覆盖（§13 等） | 14/14 | 无缺文件；本部分无 `.md`（README 仅作取证判据引用，其正文审查属第 1 部分）。§13 文档一致性按"README 与源码的交叉引用"抽查了 8 处（`376-395`、`474-507`、`704-724`、`727-758`），除 #10 的"把缺陷写成契约"外均一致 |

**范围外提示**（不计入统计）：`zero_timer.cj` 提供的 `ZERO_TIMER` 是零值 `Timer`（无 native handle），`README.md:501-507` 只给签名、未说明"不可对其调用任何方法"；已有调用方按哨兵写法踩到——`f_ticktock/src/Chrono.cj:22` 以 `ZERO_TIMER` 初始化、`47` 行 `shutdown()` 直接 `timer.cancel()`，若 `shutdown` 早于 `start` 就是对零值对象调方法。建议在 `f_base` 侧把该约束写进 README（或改成 `?Timer` 让编译器强制判空）。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 19 |
| 轻微 | 23 |
| 其中存量 | 47 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分（`f_base` 的"扩展与基础类型"层，18 个 `.cj`）整体是低风险的胶水代码：`EmptyCollections` 的 Null Object、`ExtendOption` 的运算符、`ExtendString` / `ExtendRange` 的小工具都没有外部输入面，也没有锁与线程间共享字段，**安全与锁竞争的攻击面几乎为零**。真正的问题集中在两处：

- 阻塞项（建议先修）：**#1 `groupBy` 恒返回空 map**。这不是边界问题，而是整个函数不写结果；更严重的是它已经在 `f_orm` schema 迁移的主路径上（`SchemaFinderMediator.cj:29`），意味着 `migro` 会静默生成零条 SQL、索引信息全丢。任何"迁移跑完但库没变"的现场都应先查这一条。
- 次阻塞项：**#2 `AsyncIterator`**。`spawn { itr.next() }` 同时踩两个坑（并发推进同一迭代器 + 线程数 = 元素数），README 还把"每元素一个线程"当特性写出来。修它要连文档一起改，属于小手术。
- 排期项：#3（`exactly` 无效）、#4（空数组 `grow` 越界 / 除零）、#5（`suppressed` 自环爆栈）都是"平时不响、边界上崩或静默错"的类型，单条修复成本都很低，建议与 #1 一起进 1.3.x。
- 可维护性：#10–#13 四组重复逻辑受仓颉"无泛型数值 / 无运算符参数化"限制，不能简单判"该抽泛型"；能立刻做的是删掉 8 处冗余 `isOdd`、把 `then` / `comparing` 的结构体重载改成转发、把 12 组 Option 运算符统一成同一写法（或宏生成），避免后续只改一处造成分叉。
- 文档：#14 的三处不一致里，"重导出清单漏了 `std.math.*`"最容易让使用者踩名称冲突；`filterType` 的表述（#3）则会让人写出行为不符的过滤代码。
- 性能与内存：本部分没有改前 / 改后数据（无 `cjprof` / `cjpm bench` 基线），两条优化与四条假设都不进修复清单；`toArray` 的双份数组最值得下一轮补数据。
- 已确认**没有**的问题：死锁与锁竞争（无锁）、线程间可见性问题（无共享字段）、按不可信长度预分配（无）、local mode 可用性（候选全部逃逸）、循环内物化用户输入（无）。

存量缺陷共 16 条（严重 2 / 一般 5 / 轻微 9），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

**第 2 部分**：本部分（`f_base` 的"并发原语 + 基础容器"层）代码密度高、注释里带实测数据（`EXP16`/`EXP18`/`FPS` 等），凡是"为什么这么写"的地方基本都留了取证，整体可读性明显高于一般工具模块；并发可见性的骨架也站得住——`local` 的读写全在锁内、任务身份用构造期 `AtomicInt64` 而非可变 `tid`、`finished` 用原子量、`spawn` 不持锁，这几条把最容易出事的"值丢失"面堵住了。真正的风险不在可见性，而在**语义边界**：

- 阻塞项：#1 `StringGenerator.remove` / `replace` 遇空串死循环并不断 `add`，是"合法入参 + 确定性挂死 + 无界分配"的组合，一旦有人用这个 builder 做通用替换就会打满 CPU 并 OOM。修法只有两行，建议先进 1.3.x。
- 次阻塞项：#2 `shutdown()` 的取消目标是调用线程而不是被调用任务；跨线程做超时清理时会误杀无关任务，属于"看不出错、但数据悄悄没了"的类型，且与 README 的实例语义直接冲突。修它需要把"清子树"从静态线程级拆成实例级，顺带补一条跨线程用例。
- 语义陷阱：#3（`set` 回退 owner 而 `get` 不回退，读己之写失败）、#6（`fromIndex == size` 被当越界）、#8（`Blocking` 策略默认永不放行）、#9（`transpose` 把 `Ok(None)` 变成 `Some(NoResult)`）都属于"库使用者按直觉写就会踩"的口径问题，单条修复成本低，建议与上面两条同批处理。
- 并发设计层：#4（锁内跑用户回调）与 #5（线程 id 作长期键）是这一层唯一有"将来会咬人"潜力的两处——前者要求调用方的 `fn` 不等待其它任务，后者依赖"线程 id 不复用"这个标准库不保证的前提。#14（并发容器 + 全局锁）在有 profile 数据前只当结构问题看。
- 死代码与重复：#7（`Help` 整类不可达却在 README 里当公开 API）、#10（`HashBuilder` 的 private `Map` 重载）都是"删了更安全"的项；#11 / #15 属可维护性，跟随上面几条一起改即可。
- 性能与内存：本部分没有任何改前/改后数据，3 条优化方案与 5 条假设都不进修复清单；最值得下一轮补数据的是"每任务一个 OS 线程"（假说 1）与 `subTasksLock` 争用（假说 2），它们决定了 `FutureTask` 能不能承载上千级并发任务。
- 已确认**没有**的问题：`local` 的跨线程可见性（全锁内）、`HashBuilder` 的溢出（`@OverflowWrapping`）、`Options` 的空值路径、`Peekable` / `SingleIterable` 的迭代器状态机、`Result` 的 `match` 穷尽性。

存量缺陷共 17 条（严重 1 / 一般 8 / 轻微 8），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

**第 3 部分**：本部分是 `f_base` 的"周边基础件"层：反射成员缓存（`TypeMemberInfos`）、信号/退出钩子（`signal`）、hex 转换、零值哨兵、资源管理糖、平台原生封装。单个文件都很短（最长 268 行），没有 Future/锁/原子量的自研实现，所以并发面很小——但正因为小，两处**会咬人**的地方格外突出：

- 阻塞项：#1 `TypeMemberInfos` 先把空 `HashMap` 挂进 `ConcurrentHashMap` 再填充，同一类型首次被并发查询时，另一个线程会拿到"成员不全"的映射并据此判定"没有这个成员"，且没有任何日志；`values()` 视图还会把"遍历中被修改"这个未定义行为暴露给调用方。修法只是把 `28`/`102` 的发布挪到填充之后（`79`/`159` 已是正确写法），成本极低。
- 阻塞项（契约面）：#2 `@nameof` 的展开引用了并不存在的 `@nameValue`，README 把它当公开能力宣传，实际任何调用点都编译不过。这条之所以零发现，是因为仓内零调用——与 #14「反射面没有单测」是同一个根因：**没有用例的对外承诺会腐烂**。
- 语义陷阱：#3 两处父类遍历写错循环变量（`30` 用 `typeInfo`、`232` 用 `x`），让"继承来的静态属性 / 实例变量"永远查不到，进而让 `f_data` 的校验/转换注解在父类字段上静默失效；#4 `fromHex` 只挡上界，空串/单字符/大写直接抛 `IndexOutOfBoundsException` / `NoneValueException`；#6 退出钩子会清掉别人的 SIGTERM/SIGINT 并用 `exit(0)` 抢在后续 handler 之前终止进程（`f_tui` 的终端恢复正好是这类注册方）；#8 `FuncMeta` 的哈希与相等可能不一致（`HashBuilder` 对集合走身份哈希），一旦成立，`staticFunction` / `instanceFunction` 全部 miss——这条必须先用一条 3 行用例定死。
- 可维护性：#7 六段几乎一样的缓存填充已经漂移出"发布顺序、同名冲突策略、结构分支"三种不一致，其中"父类覆盖子类"与函数表的 `addIfAbsent`（子类优先）正好相反；#10 / #11 / #12 / #13 是"缺陷被写进文档"与"复制粘贴文案"这两类典型债务，修起来都很轻。
- 性能与内存：本部分没有任何改前/改后数据，3 条优化方案与 4 条假设都不进修复清单。下一轮最值得补的是"`toHex` 在 SQL 渲染里的占比"（假设 1）与"反射缓存常驻内存"（假设 3），它们决定要不要动 `hex` 的查表与 `TypeMemberInfos` 的表结构。
- 已确认**没有**的问题：`hex`/`hexmap` 两个全局表的只读性、`signal.cj` 的 `@When` 分支穷尽（非 Windows 三对重载 + Windows 六桩 + `Signal`/`SignalHandlerFunc` 兜底）、`atExit` 的 `MapEntryView` 写入语义（文档已核会自动插入）、`UnsafeBytes`/`UnsafeData`/`unsafeZeroValue`/`native` 的封装正确性、`resource()` 的 `try/finally` 对称性。
