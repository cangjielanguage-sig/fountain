# f_base 模块审查报告（第 1/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（全模块 52 个源文件；**本部分覆盖 15 个**：Arch / BaseCommand / BaseException / Bucket / Comparator / Comparator_test / Console / CpuFeatures / CpuFeatures_test / EmptyCollections / Equaler / ExtendArray / ExtendIterator / ExtendNumber / ExtendOption）
- **基线**：工作区快照（`sts/1.3.x`，工作区干净；快照模式无 diff，本部分发现全部记为「存量」）
- **审查重点**：基础类型 / 并发原语 / unsafe 内存、死代码、重复逻辑、空实现、栈溢出、OOM、存量 BUG、并发安全与锁粒度
- **报告版本**：v1（部分报告，待主 Agent 合并为 `docs/review/f_base_review_20261128.md`）
- **说明**：本文件统计**只含第 1/4 部分**，不含 JSON 之外的其余 37 个文件；合并时勿与本部分数字直接相加覆盖。

## 发现

### [严重][存量] `ExtendIterator.groupBy` 从不把新分组写回 map，恒返回空 HashMap

- **位置**：`f_base/src/ExtendIterator.cj:108-119`（关键行 `:112-116`）
- **来源**：存量（快照模式无 diff；`git blame -L 104,120` 全部落在 `4be871f2f` 2026-10-02 的 LF 统一提交，无法据 blame 区分更早来源）
- **判据**：review-checklist §11（契约与实现不符 / 静默失效）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `if (let Some(list) <- m.get(k)) { list } else { ArrayList<T>() }.add(t)`：`Some` 分支只对**已有**列表 `add`，`else` 分支新建的 `ArrayList` 只执行 `add(t)` 后即被丢弃，**任何分支都没有 `m[k] = list`**；`HashMap.get` 不产生条目，故 `m` 始终为空，返回值恒为空 map。
- **描述**：`groupBy` 是本模块对外 API，且已被生产代码依赖：
  - `f_orm/src/migro/SchemaFinderMediator.cj:29` `TableMetas.tableMetas().groupBy{m => m.driver}` → 分组为空 ⇒ `generate()` 的内层 `flatMap` 不执行，**数据库迁移不生成任何 SQL**；
  - `f_orm/src/migro/MysqlSchema.cj:88` `findIndexes` 的按索引名分组为空 ⇒ `generateIndexSql` 认为「当前无索引」，增量迁移会重复建索引。
  两处都是静默失效（不抛异常、日志也看不出），属数据/部署后果。
- **建议**：改成显式写回，例如
  ```cangjie
  for (t in this) {
      let k = key(t)
      match (m.get(k)) {
          case Some(list) => list.add(t)
          case _ =>
              let list = ArrayList<T>()
              list.add(t)
              m.add(k, list)      // 或 m[k] = list
      }
  }
  ```
  补齐一个 `@Test`：对 5 个元素、2 个 key 断言 `size == 2` 与各组条数——当前无任何测试覆盖 `groupBy`（`f_base` 无 ExtendIterator 测试）。

### [严重][存量] `ExtendArray.grow` 默认 `ZeroValue` 用 `unsafeZeroValue<T>()` 填充，引用类型会写入 null 引用

- **位置**：`f_base/src/ExtendArray.cj:60`（默认值）、`:66`（`case ZeroValue => unsafeZeroValue<T>()`）、`:75-81`（写入新槽位）
- **来源**：存量（同上，`4be871f2f`）
- **判据**：review-checklist §11（内存/类型安全）、§10（unsafe 使用）、严重度表「崩溃」
- **证据**：静态确定 —— `unsafeZeroValue<T>()` 定义在 `f_base/src/unsafeZeroValue.cj:18-22`，实现为 `unsafe { zeroValue<T>() }`，即**全零位模式**；对 `T` 为引用类型（`String`、任意 class）时该值是 null，但类型系统仍视其为非空 `T`。仓内已有同类段错误的记录：`.autocode/bugs/bug-archived-on-20261004.md:755`（「零值 `MessageID` 一格式化就崩」）、`f_rpc/src/server/LogMessage.cj:20`（注释明确「零值对象…会直接段错误」）。
- **描述**：`grow` 的 `new!` 参数默认就是 `ZeroValue`，因此最自然的用法 `arr.grow(n)`（`Array<String>`/`Array<Foo>`）会产出 n 个 null 引用；一旦读取或调用成员（`arr[i].size()`、`'${arr[i]}'`、作为 map key 求 hash）即段错误。当前仓内 `grow` 无调用方（全仓 grep `grow(` 仅定义处），影响面为**对外 API**，但后果是崩溃而非异常。
- **建议**：三选一并写进 README——(1) 删除默认值，强制调用方显式指定 `new!`；(2) 保留默认但 `ZeroValue` 分支对引用类型改为抛 `IllegalArgumentException`（需要类型判据）；(3) 泛型约束收紧到可零值安全的场景（数值/`Option`）。至少应在接口注释里加「T 为引用类型时结果是 null，读取即崩溃」的警告。

### [一般][存量] `EmptyList.contains(all!)` 恒返回 false，与同文件其余空集合实现不一致

- **位置**：`f_base/src/EmptyCollections.cj:475-477`
- **来源**：存量
- **判据**：review-checklist §11（语义与约定不符）、§2（近似重复中的行为漂移）
- **证据**：静态确定 —— 同文件 `EmptySet.contains(all!)`（`:71-73`）、`EmptyMap.contains(all!)`（`:192-194`）、`EmptyEquatableCollection.contains(all!)`（`:394-396`）统一返回 `all.isEmpty()`，只有 `EmptyList` 返回常数 `false`。项目自身约定见 `f_cache/src/ConcHashMap_test.cj:38`：`@Assert(true, keys.contains(all: ArrayList<String>()))`。
- **描述**：「包含参数集合的全部元素」在空集合上等价于「参数集合为空」；`EmptyList<T>.instance().contains(all: 空集合)` 应为 true，现为 false。`List<T>` 接口本身没有这个重载（`std.collection.List` 只声明 `add/remove/contains(T)` 之外的成员，见 `list_interface.cj:18-29`），所以这是 fountain 自定语义，缺乏 std 契约兜底，更容易被误用成「集合包含判定」。
- **建议**：改为 `all.isEmpty()`，并补 4 个空集合的一致性用例（当前 `EmptyCollections` 无测试）。

### [一般][存量] `Option` 的 `+` / `*` 运算符提升交换了操作数顺序

- **位置**：`f_base/src/ExtendOption.cj:144-146`（`+`）、`:171-173`（`*`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误）、§2（同一模式复制导致个别实现漂移）
- **证据**：静态确定 —— 两处都写成 `call<?T> {x => other + x}` / `{x => other * x}`，即 `other op this`；而同一批的 `-`/`/`/`%`/`**`/`&`/`|`/`^`/`<<`/`>>` 均为 `x op y`（`:156-161`、`:183-188`、`:199-204`、`:215-220`、`:231-236`、`:247-252`、`:263-268`、`:290-295`、`:306-311`）。
- **描述**：`Some("a") + Some("b")` 得到 `Some("ba")`（`String <: Addable<String>`，加法不可交换）。数值类型因交换律掩盖了问题，字符串/矩阵等 `Addable`/`Mulable` 实现会得到错误结果，且无编译期提示。
- **建议**：改为 `call<?T> {x => x + other}`、`{x => x * other}`（与 `-` 保持一致），并加一条 `Option<String>` 的断言用例。

### [一般][存量] `UInt8/UInt16/UInt32.to<T>()` 加宽时先按同宽有符号重解释，结果与语言转换不一致

- **位置**：`f_base/src/ExtendNumber.cj:486-499`（UInt8，关键 `:488-491`）、`:573-585`（UInt16，`:575-578`）、`:665-677`（UInt32，`:667-670`）；对偶问题 `Int8.to<T>()` `:119-132`（`:125-128`）
- **来源**：存量
- **判据**：review-checklist §11（转换语义错误 / 无文档契约）
- **证据**：静态确定 —— `UInt8(200).to<Int16>()` 走 `case _: ?Int16 => Int16(this.toInt())`，`toInt()` 先把 200u8 重解释为 `Int8(-56)`，再 `Int16(-56)` ⇒ **-56**；而语言转换 `Int16(200u8)` = 200。同理 `UInt16(40000).to<Int32>()` 得 -25536，`Int8(-1).to<UInt16>()` 得 255（语言转换 `UInt16(-1i8)` = 65535）。
- **描述**：`to<T>()` 是 `Integer<T>` 的公开成员（`ExtendNumber.cj:44`），全仓无调用方（grep `\.to<` 零命中），因此当前无实际数据错误；但对外部使用者是「同名加宽转换给出与语言规则不同的值」，且 `Number/Integer` 系接口没有任何注释说明这是「按位宽重解释」语义。另外 `(any as T).getOrThrow()` 对未列出的 `Integer<T>` 实现会抛 `NoneValueException`，契约未声明。
- **建议**：加宽分支改为直接语言转换（`Int16(this)`、`Int32(this)`、`Int64(this)`），只在**收窄**时保留重解释；同时在 README 写明 `to<T>()` 的语义（截断 or 值保持）并给出边界用例（`0xFF`、`0x80`）。

### [一般][存量] `BaseException.addSuppressed` 允许自我挂接，`printStackTrace` 因此无限递归

- **位置**：`f_base/src/BaseException.cj:59-61`（`addSuppressed`）、`:71-86`（`printStackTrace`，递归点在 `:79-84`）
- **来源**：存量
- **判据**：review-checklist §4（自引用结构 / 无界递归）、§11（边界与契约）
- **证据**：静态确定 —— `addSuppressed(suppressed: Exception)` 无任何自引用检查，`suppressed_` 为普通 `ArrayList<Exception>`；`printStackTrace` 对每个 suppressed 递归调用 `printStackTrace(s, w)`（`:81-83`），若 `s === this`（或 A↔B 互挂）则递归无出口。`causedBy` 链因只能由构造函数设置而不可能成环，suppressed 链可以。
- **描述**：`e.addSuppressed(e)`（或 A.addSuppressed(B); B.addSuppressed(A)）之后任何一次 `printStackTrace` 都会栈溢出（进程级崩溃，不是可捕获的业务异常）。Java 的 `Throwable.addSuppressed` 对自引用抛 `IllegalArgumentException`，此处没有对齐。仓内唯一调用点（`f_aspect/src/Aspect.cj:68,81`）挂的是新构造的 `AspectException`，暂不会触发。
- **建议**：`addSuppressed` 增加 `if (suppressed === this) throw IllegalArgumentException(...)`；`printStackTrace` 内对 suppressed 也加 `s !== this` 保护（互挂场景需按 identity 集合去重）。

### [一般][存量] `ExtendArray.grow` 的边界分支未处理空数组与 0 次重复

- **位置**：`f_base/src/ExtendArray.cj:63-65`（`First`/`Last`）、`:68-73`（`Repeat`）、`:94-96`（`operator *`）、`:55-59`（`check`）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 空集合未处理 / 除零）
- **证据**：静态确定 ——
  1) `case First => this[0]`、`case Last => this[this.size - 1]` 在 `size == 0` 且请求扩容时执行 ⇒ `IndexOutOfBoundsException`；甚至 `[].grow(0, new: First)`（文档承诺「size 相等只复制」）也会越界，因为 `newval` 在判空之前就被求值（`:63-74`）。
  2) `Repeat` 只特判了 `s == 1`，`s == 0` 时走 `Array<T>(size){i => this[i % s]}` ⇒ `% 0` 抛算术异常（`:68-73`）。
  3) `operator *`：`[1,2] * 0` 先算出 `grow(0)`，`check(0)` 因 `0 < 2` 抛 `IllegalArgumentException`（`:55-59, :94-96`）——「重复 0 次」应得空数组。
- **描述**：三个分支都在输入退化时抛异常而非返回直观结果；`grow` 无任何测试。
- **建议**：`First`/`Last` 在 `this.size == 0` 时直接抛带说明的 `IllegalArgumentException`（或返回零值需另行决策）；`Repeat` 用 `s == 0` 单独分支（返回零值数组或抛异常，取一并写注释）；`operator *` 对 `repeat <= 0` 返回 `Array<T>()`。

### [一般][存量] 包内私有 `Option.map` 与 std 同名重载：包内语义被改成 flatten，且零引用

- **位置**：`f_base/src/ExtendOption.cj:51-57`
- **来源**：存量
- **判据**：review-checklist §1（本包内无调用者的 `internal` 符号 = 死代码）、§10（语言特性/标准库利用）
- **证据**：静态确定 —— 该成员没有 `public` 修饰（包内可见），`f_base/src` 全目录 grep `\.map` 零命中 ⇒ 无调用者。std 侧已有 `Option.map<R>(transform: (T) -> R): Option<R>`（`std/core/option.cj:61`）；本重载签名 `fn: (T) -> ?O` 更特化，包内任何 `opt.map{x => Some(v)}` 会被解析到这里，得到**扁平化**结果，而仓内其它模块得到 `Some(Some(v))`。
- **描述**：既是死代码，又是「同名不同语义」的隐形陷阱：将来 f_base 内新增的 `map` 调用会与全仓行为不一致，且编译器不会提示。Cangjie 不允许扩展成员覆盖 std 成员，只能靠重载优先级决胜，风险不可控。
- **建议**：删除，或改名为 `mapOption`/`flatMap` 并加 `public` 说明语义；若确需扁平化语义，在 README 显式记载。

### [一般][存量] `AsyncIterator.next()` 每次 `spawn` 一个线程，无并发上限

- **位置**：`f_base/src/ExtendIterator.cj:20-27`（`next()` 在 `:22-26`）
- **来源**：存量
- **判据**：review-checklist §5（一次提交全量任务）、§12.1（有界性）、§6.3
- **证据**：静态确定 —— `next()` 直接 `spawn { itr.next() }` 并返回 `Future`，没有窗口、没有批大小、也没有「上一个 Future 完成才发下一个」的约束。触发路径可枚举：`it.async().toArray()`（`ExtendIterator.cj:46-48` 的 `toArray` 会全量消费）⇒ 元素数 = 同时存活线程数。
- **描述**：设 10 万元素的迭代器，`async().toArray()` 会同时创建约 10 万个线程与 10 万个 `Future`；按每线程栈 1MB 量级估算即 100GB 级虚拟内存，实际表现为 `EAGAIN`/OOM 或被调度器拖死。即使调用方逐个 `get()`，也是「每元素一次线程创建 + 一次同步」，比串行更慢。仓内无调用方（grep `AsyncIterator`/`.async()` 仅定义处），属对外 API 的潜在风险。
- **建议**：改成固定大小的工作线程 + 有界队列（或用 `f_concurrent` 的线程池），或把 API 改成「批量 `nextBatch(n)`」；至少在文档里写明「不得在未等待前一个 Future 的情况下连续 `next`」。

### [一般][存量] `CpuFeatures_test.cj` 缺 Apache 版权头

- **位置**：`f_base/src/CpuFeatures_test.cj:1`（文件首行直接是 `package fountain::f_base`）
- **来源**：存量
- **判据**：`fountain-baseline` §3（每个 `.cj` 必须有 Apache 2.0 头且位于 `package` 之前；缺失按「一般」）
- **证据**：静态确定 —— 同目录 `Comparator_test.cj:1-15` 有完整头，本文件没有。
- **建议**：补 2026 年版权头。

### [轻微][存量] 未使用 / 重复的 import

- **位置**：`f_base/src/BaseException.cj:18`（`StringWriter` 未使用）、`f_base/src/Console.cj:18`（`ConsoleReader` 未使用）、`f_base/src/Console.cj:18,20`（`ConsoleWriter` 既普通导入又 `public import`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 两个文件内均无 `StringWriter` / `ConsoleReader` 的类型引用。
- **建议**：删除多余项；`ConsoleWriter` 只保留 `public import`。

### [轻微][存量] `Comparator_test` 的断言没用被测对象，`create`/`operator()` 实际未验证

- **位置**：`f_base/src/Comparator_test.cj:25-28`
- **来源**：存量
- **判据**：review-checklist §1（读了不用）、§11（测试与意图不符）
- **证据**：静态确定 —— `let comparator = Comparator<Int64>.create<Int64>()` 之后两次断言都写 `cmp(1, 2)`，局部变量 `comparator` 再无使用。
- **建议**：断言改为 `@Assert(Ordering.LT, comparator(1, 2))`，并补 `reverse()`/`then()` 的用例（这两个是最容易写错的方向）。

### [轻微][存量] `CpuFeatures_test` 的断言恒真

- **位置**：`f_base/src/CpuFeatures_test.cj:12`
- **来源**：存量
- **判据**：review-checklist §11（测试无效）
- **证据**：静态确定 —— `@Assert(v == CpuFeatures.hasSse41, true)` 是同一属性两次读取的比较；在 x86_64 上无论实现返回什么都会通过。
- **建议**：改为直接断言与 `/proc/cpuinfo` 的一致性，或断言「两次读取一致 + 非 x86_64 为 false」（后者已有 `:13-15`）。

### [轻微][存量] `CpuFeatures` 类注释与实现范围不符

- **位置**：`f_base/src/CpuFeatures.cj:21-26`（注释）、`:35-40`（非 Linux 分支）
- **来源**：存量
- **判据**：review-checklist §11（注释与实现不符）
- **证据**：静态确定 —— 注释写「非 x86_64 平台恒 false」，但 `@When[arch != 'x86_64' || os != 'Linux']` 使得 **x86_64 + Windows/macOS 也恒 false**；这类平台会静默关闭 SSE4.1 路径（只损失性能，不崩溃）。
- **建议**：注释改为「非 x86_64 或非 Linux 平台恒 false」，并在 `f_jit` 侧注明该限制。

### [轻微][存量] `BaseException.suppressed` 直接暴露内部可变列表；堆栈头文案拼写错误

- **位置**：`f_base/src/BaseException.cj:63-67`（`prop suppressed` 返回 `suppressed_`）、`:24`（`An exception has occured`）
- **来源**：存量
- **判据**：review-checklist §10（封装性 / 可读性）
- **证据**：静态确定 —— getter 返回内部 `ArrayList` 引用，调用方可 `e.suppressed.add(x)` 绕过 `addSuppressed`；`occured` 应为 `occurred`。
- **建议**：返回只读视图或 `ArrayList<Exception>` 的副本（调用频次极低，拷贝无成本）；修正拼写（注意会改变输出文本，需同步测试快照）。

### [轻微][存量] `EmptyMapEntryView.value` 的 setter 静默丢弃写入

- **位置**：`f_base/src/EmptyCollections.cj:339-344`
- **来源**：存量
- **判据**：review-checklist §3（空实现；Null Object 必须注释说明）
- **证据**：静态确定 —— `set(value) {}`，无注释。
- **描述**：空 map 的 entryView 写入不可持久化是合理的（Null Object），但静默丢弃会让「以为写成功了」的调用方难以发现缺陷。
- **建议**：保留空实现并加一行注释说明「空 map 不保存任何 value」；或改抛 `UnsupportedException`（会改变现有行为，需用户决策）。

### [轻微][存量] `flatten` 的异常文案写错类型

- **位置**：`f_base/src/ExtendIterator.cj:82-83`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 错误信息）
- **证据**：静态确定 —— 文案是 `'${TypeInfo.of<T>()} does not match ${TypeInfo.of<Iterator<R>>()}'`，期望类型应为 `R`，不是 `Iterator<R>`；排查时会误导。
- **建议**：改为 `${TypeInfo.of<R>()}`。

### [轻微][存量] `ExtendNumber` 8 个整数扩展的实现近似逐行复制

- **位置**：`f_base/src/ExtendNumber.cj:82-139`（Int8）及 `:166-228`、`:255-323`、`:350-423`、`:450-506`、`:533-594`、`:621-687`、`:714-786` 共 8 份
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 换算复制的重复逻辑）
- **证据**：静态确定 —— `numberOfLeadingZeros` / `flip` / `to<T>()` / `toUInt` / `toInt` / `isEven` 五套实现逐行对应，差异仅是位宽常量与类型名；`to<T>()` 的 8 个 match 分支表也只是把目标类型名换了一遍。
- **描述**：8 份复制带来的是「一处修、七处漏」的风险（本次已发现 `to<T>()` 的加宽规则在 3 个无符号类型里同时错，正是复制扩散的后果）。位运算无法泛型化，但可以用宏统一生成，或至少把 `to<T>()` 的分派表抽成一处。
- **建议**：用 `f_macros` 生成 8 份实现（保留 `@OverflowWrapping` 等属性），或集中成一个「按目标类型分派」的私有函数 + 8 个薄包装；重复本身不致命，但必须与上一条的语义修正一起做。

### [轻微][存量] `ExtendOption` 的 12 组运算符提升逐字重复

- **位置**：`f_base/src/ExtendOption.cj:140-313`（`+ - * / % ** & | ^ ! << >>`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 只改运算符符号）
- **证据**：静态确定 —— `?T` 版本全部是 `call<?T> {x => match (other) { case Some(y) => x op y; case _ => None<T> }} ?? None<T>`，只有运算符不同。
- **描述**：这正是 `+`/`*` 两处写反操作数却未被发现的原因（复制时手写 `other op x`）。
- **建议**：抽一个私有 `lift(other: ?T, op: (T, T) -> T): ?T`，12 组各自退化成一行；`T` 版本保留（签名不同，无法合并）。

## 优化可行性方案

### [堆内存] 空集合工厂每次调用都新建实例

- **现状**：`EmptySet/EmptyMap/EmptyList/EmptyCollection/EmptyIterator/EmptyEquatableCollection.instance()` 每次 `new` 一个仅含零字段的对象（`EmptyCollections.cj:30-32, 141-143, 163-165, 349-351, 401-403, 438-440`）。高频路径是 `get(k) ?? EmptyList<T>.instance()`（如 `f_llm/src/agents/AgentEventData.cj:42`）与 `iterator()` 内的 `EmptyIterator<T>.instance()`（每次开始迭代一次）。
- **方案**：改为每类型共享单例（对应文件里被注释掉的 `public static let instance` 就是原设计）。泛型类不能声明泛型静态字段时，退而求其次：把 `iterator()` 的返回值改成 `OptionIterator(None)` 复用，或让调用方直接用空 `ArrayList`。
- **预期**：每次未命中少 1 个对象（16–24B 级），量级取决于未命中次数，未测。
- **代价**：单例需注意线程安全（这些对象不可变，安全）；泛型静态字段可能不被语言支持。
- **验证**：`getAllocatedHeapSize()` 在 100 万次未命中循环下的分配量对照（`-O2`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `Iterator.toArray()` 经 `ArrayList` 再切片，多一次全量拷贝

- **现状**：`ExtendIterator.cj:46-48` 先 `toArrayList()`（多次扩容复制）再 `unsafeData()`（`UnsafeData.cj:25-29` 里 `getRawArray()[0..size]` 再复制一份精确长度数组）。
- **方案**：`collect` 阶段预估容量（若迭代器可 `size`），或改为两趟：先计数再填 `Array`（仅当迭代器可重复遍历）。
- **预期**：峰值多占 1 份 n×sizeof(T)，拷贝次数从 ~2 次降到 1 次；具体占比未测。
- **代价**：两趟遍历不适用于一次性迭代器；API 语义不变。
- **验证**：`cjpm bench` 对 100 万元素 `toArray()` 的耗时/分配量对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Arch.hashCode()` 每次拼接完整限定名再取哈希

- **现状**：`Arch.cj:23-25` `'fountain::f_base.Arch.${this}'.hashCode()`——每次算 hash 都要构造一个 30 字符左右的 `String`。
- **方案**：直接返回 `match (this) { case x86_64 => 1; case aarch64 => 2 }`（或 `ordinal`），保持与 `==` 一致。
- **预期**：单次从「分配 + 逐字符哈希」降为常数比较；`Arch` 作为 map key 的场景才可见，未测。
- **代价**：哈希值变化（仅影响跨进程持久化的哈希，仓内无此用法）。
- **验证**：`Arch` 作为 key 的 100 万次 `HashMap` 插入基准。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Integer.to<T>()` 的运行时类型分派

- **现状**：`ExtendNumber.cj:119-132` 等 8 处用 `match (None<T>)` 做最多 8 次运行期类型判断，并把结果装箱进 `Any` 再 `as T` 回转。
- **方案**：若真的有调用方，改为显式具名转换（`toInt8/toInt16/...`）或按 `TypeInfo` 缓存分派函数。
- **预期**：省掉 `Any` 装箱与最多 8 次类型测试；当前全仓无调用方，收益为 0。
- **代价**：API 扩张。
- **验证**：先确认有外部调用方，再测单次转换耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 空集合工厂的每次分配在未命中路径上占比可观 | `EmptyCollections.cj:30-32` 等 | 分配量 / 未命中次数 | 计数埋点 + `getAllocatedHeapSize()`，跑 100 万次 `get ?? EmptyList.instance()` |
| 2 | `toArray()` 的双拷贝是批量转换的主要开销 | `ExtendIterator.cj:46-48` | 单次 vs 两次拷贝耗时 | `cjpm bench -O2`，100 万元素，中位数 |
| 3 | `Arch.hashCode` 字符串拼接在 map key 场景显著 | `Arch.cj:23-25` | 单次哈希耗时占比 | 100 万次 HashMap 插入，`cjprof record` |
| 4 | `CpuFeatures.hasSse41` 每次访问都读 `/proc/cpuinfo` | `CpuFeatures.cj:29-54` | 调用频次 | 全仓仅 `f_jit/src/backend/X86Lower.cj:62` 初始化调用一次，**当前不构成热点**；若未来进热路径需加 `static let` 缓存，届时再测 |
| 5 | `Integer.to<T>()` 的 `Any` 装箱 + 类型分派在外部热路径偏贵 | `ExtendNumber.cj:119-132` | 外部调用方的调用频次与耗时 | 先确认调用方，再分段计时 |

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 5（groupBy、`+`/`*` 反序、`to<T>` 加宽、`grow` 边界、`contains(all!)`）；设计 2（`map` 同名重载、`suppressed` 暴露内部列表）；可读性 2（拼写、`flatten` 文案）；安全性 0（本部分无外部输入解析、无凭据、无注入面；`unsafe` 唯一入口 `unsafeZeroValue` 已在严重项覆盖） |
| §1 死代码 | 3 | 已逐符号机械过：`private`（`BaseException.printStackTrace` 私有重载、`ExtendArray.check`、`CpuFeatures.detectSse41`、`EmptyMapEntryView.k`、ExtendNumber 的 7 个私有常量）均有引用；无 `internal` 顶层声明；`protected` 零出现。命中：`ExtendOption.map`（包内零引用）、`StringWriter`/`ConsoleReader` 未使用 import、`Comparator_test` 未读局部变量。对外可达 public 无仓内引用者（`EmptyIterable`、`AsyncIterator`、`filterType`、`Arch.hashCode` 等）按硬原则一不判死代码 |
| §2 重复逻辑 | 2 | 已把 15 个文件的函数体按「输入-输出-副作用」两两比对：`ExtendNumber` 8 份整数实现、`ExtendOption` 12 组运算符提升为同语义复制；`Comparator` 与 `Equaler` 结构对应但返回 `Ordering` / `Bool` 不同、`then` 语义不同，不构成同语义重复；`EmptySet/EmptyMap/EmptyEquatableCollection` 的 `contains(all!)` 一致，唯 `EmptyList` 漂移（已计入 §11 与正确性） |
| §3 空实现 | 1 | 命中 `EmptyMapEntryView.value` setter（静默丢弃）。`Empty*` 的其余 no-op 是 Null Object（`remove`/`add`/`clear`/`sortBy` 等），行为与类型名一致；`Bucket`、`Extend*Option` 为空 marker 接口，属约束用途，非空实现 |
| §4 栈溢出 | 1 | 命中 `BaseException.printStackTrace` 的 suppressed 自引用递归。其余文件无递归；`printStackTrace` 的 `causedBy` 链只能由构造函数设置，成环不可行，只受链长限制（与 JDK 行为一致，未额外记缺陷） |
| §5 OOM | 2 | 命中 `AsyncIterator` 每元素一个线程（无界任务提交）、`grow` 的 `ZeroValue`（`Array<T>(size)` 大小由调用方给定，属 API 目的，不另记）。`readToEnd`（`CpuFeatures` 读 `/proc/cpuinfo`）输入是内核固定文件，不计 |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据，`scope.md`「已有性能资料」为空；所有性能线索（`Arch.hashCode`、`to<T>` 分派、`toArray` 双拷贝）已降级进「待验证假设」，不作发现 |
| §6.2 大粒度锁 | 0 | 本部分 15 个文件**不含任何锁/synchronized/Mutex**，无可判定的临界区 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get` 的形态；`AsyncIterator` 的问题是「并发无界」而非「形式并发实际串行」，已归入 §5/§12.1 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无热点 `contains`、无 `remove(at: 0)` 队列；`groupBy` 的问题是逻辑错误不是复杂度问题；`collect<K>` 为 O(n) 单遍 |
| §7 降堆内存方案 | 2 | 空集合工厂每调用一次分配、`toArray` 多一次全量拷贝；均无基线，标「待验证」 |
| §8 降 CPU 方案 | 2 | `Arch.hashCode` 字符串拼接、`to<T>` 的 `Any` 装箱 + 8 路类型分派；均无基线 |
| §9 local mode 可行性 | 0 | 本部分无函数内大临时对象：`toArray` 的临时 `ArrayList` 虽在函数内消费，但其原始数组会经切片逃逸为返回值，且缺峰值内存数据 → 无法证明收益；`printStackTrace` 的 `ByteBuffer` 只随单次异常产生。结论：不可行/无证据，不列方案 |
| §11 现有代码的 BUG（存量） | 8 | 本轮读到的存量缺陷：`groupBy` 恒空、`ZeroValue` 空引用、`contains(all!)` 恒假、`+`/`*` 反序、`to<T>` 加宽错误、suppressed 递归、`grow` 三类边界、`map` 遮蔽 std（另含 6 条轻微：import、拼写/暴露内部列表、setter 空实现、`flatten` 文案、两处测试无效、注释不符）。全部标 `[存量]`，默认只报不修 |
| §12 并发安全与锁粒度 | 2 | 共享点逐个核对：`Console.output/input`（`static let`，转发 std `ConsoleWriter`/`ConsoleReader`，行原子性由 std 决定，仓内未取证，仅作观察项）；`BaseException.suppressed_`（`var` + `ArrayList`，`addSuppressed` 与 `printStackTrace` 可跨线程并发，无同步——异常对象跨线程传播是常见形态，但仓内未见并发 `addSuppressed`，记为风险而非缺陷）；`OptionCaller.noneCallee`（`var`，builder 每次新建、无线程共享）；`Empty*`（无状态）；`CpuFeatures`（只读文件、无共享状态）；`AsyncIterator` 的有界性缺失已计入 §5。**锁粒度**：本部分无锁，无需判 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

> 存量缺陷合计 19 条（含轻微），默认只报不修；是否纳入修复清单请用户在门禁决定。本部分统计只含 15 个文件，不含 f_base 其余 37 个文件。

## 总评

本部分绝大多数是「类型工具层」代码（`Arch`、`Comparator`、`Equaler`、`Extend*`、空集合），没有锁、没有 I/O 主路径、也没有外部输入解析，整体风险集中在**两个静默失效点**上：

1. `ExtendIterator.groupBy` 恒返回空 map —— 已被 `f_orm` 迁移链路依赖（`SchemaFinderMediator`、`MysqlSchema.findIndexes`），会让迁移「成功但什么都不做」，属阻塞项，必须优先修并补测试。
2. `ExtendArray.grow` 默认用 `unsafeZeroValue` 填充，引用类型一旦使用就段错误 —— 这是 API 设计层面的内存不安全默认值，仓内已有同类段错误先例，应在文档与签名上一起收口。

其余问题按后果排序：`EmptyList.contains(all!)` 与 `Option` 的 `+`/`*` 反序是「读代码即可定、改起来一行」的正确性缺陷；`to<T>()` 的加宽规则、`grow` 的空数组/零重复分支属边界契约缺失（无仓内调用方，影响外部使用者）；`AsyncIterator` 的每元素一线程是把「并发」当「并行」的典型写法，作为对外 API 应在文档里加硬约束或改成有界实现。死代码与重复逻辑命中不多但很具体（`map` 遮蔽 std、8×/12× 复制），修起来成本低，建议与语义修正一并做。

代码质量在「不可变、无状态」这一侧是好的：`Arch`/`Comparator`/`Equaler`/`Bucket`/空集合都没有共享可变状态，不存在锁粒度问题；`unsafe` 只集中在 `unsafeZeroValue` 一处，边界清晰。主要欠账是**测试**：本部分 15 个文件里只有 2 个测试文件，`groupBy`、`grow`、`to<T>()`、`contains(all!)`、`Option` 运算符全部零覆盖，上面几个缺陷都能被一行断言拦住。性能方面没有任何 profile/bench 数据，本轮不产出结论，只留 5 条待验证假设供下一轮补数据。
