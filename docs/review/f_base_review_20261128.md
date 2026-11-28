# f_base 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（52 个源文件；4 个子轮合并：15 + 15 + 15 + 7，另 `README.md` / `README_en.md` 未进文件清单，仅被 §14 契约核对引用）
- **基线**：工作区快照（`sts/1.3.x`，`git log -1` = `8c0ce643a`；快照模式无 diff，本轮全部条目记为「存量」）
- **审查重点**：基础类型 / 并发原语 / unsafe 内存 / 进程退出编排；死代码、重复逻辑、空实现、栈溢出、OOM、存量 BUG、并发安全与锁粒度
- **报告版本**：v1（合并自 `reviews/202611280829_full/parts/f_base.part1-4.md`；同日重审另存 `_v2`）
- **合并规则**：同一根因跨部分重复的条目合并为一条并列出全部位置；严重程度不一致时取更严格一级，并在该条「严重程度说明」中写明两侧定级。待验证假设与优化方案不参与缺陷计数。

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

### [严重][存量] `unsafeZeroValue<T>()` 对引用类型产出 null 引用：`ExtendArray.grow` 的默认零值与 `ZERO_TIMER` 同源

- **位置**：`f_base/src/ExtendArray.cj:60`（默认值）、`:66`（`case ZeroValue => unsafeZeroValue<T>()`）、`:75-81`（写入新槽位）；`f_base/src/unsafeZeroValue.cj:18-22`；`f_base/src/zero_timer.cj:18-20`
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（内存/类型安全、空引用）、§10（unsafe 使用）、§5（无界/非法默认值）、§14（公开 API 风险未文档化）
- **证据**：静态确定 —— `unsafeZeroValue<T>()` 实现为 `unsafe { zeroValue<T>() }`，即**全零位模式**；对 `T` 为引用类型（`String`、任意 class）时该值是 null，但类型系统仍视其为非空 `T`。std 文档明确写「通过该函数获取到的实例一定要赋值为正常初始化的值再使用，否则将引发程序崩溃」（`stdlib/doc/libs/std/core/core_package_api/core_package_funcs.md:1719-1740`）；`Timer` 是 `public class Timer <: Equatable<Timer> & Hashable`（`stdlib/libs/std/sync/timer.cj:36`），零值即空引用，`cancel()`（`timer.cj:196`）读 `isEnabled` 字段时直接解引用。
- **严重程度说明**：第 1/4 部分按 `grow` 侧定级**严重**（`arr.grow(n)` 直接产出 n 个 null 引用，读取或调用成员即段错误）；第 4/4 部分按 `ZERO_TIMER` 侧定级**一般**（仓内零引用，后果限于契约未文档化）。合并后按更严格一侧取**严重**：`unsafeZeroValue` 是公开能力，`Array<Class>.grow(n)` 与任何 class 零值使用都落到同一个空引用，后果是进程崩溃而非可捕获异常。
- **描述**：`grow` 的 `new!` 参数默认就是 `ZeroValue`，最自然的用法 `arr.grow(n)`（`Array<String>`/`Array<Foo>`）即产出 null 引用数组，一旦 `arr[i].size()`、`'${arr[i]}'` 或作为 map key 求 hash 就段错误；当前仓内 `grow` 无调用方（全仓 grep `grow(` 仅定义处），影响面为对外 API。`ZERO_TIMER` 是全仓零引用的公开常量（`grep -rn ZERO_TIMER` 仅命中定义与 README `:506`），README 只贴代码未说「不可调用」。`unsafeZeroValue` 的名字里 `unsafe` 被「不必使用 unsafe 关键词」的描述弱化，下游已有把 class 零值当真值用的实例（`f_http/src/MultipartFormData.cj:47`、`f_io/src/MMapFile.cj:33`、`f_llm/src/agents/AgentTask.cj:423`），`f_rpc` 历史段错误根因之一就是零值 `MessageID`（`.autocode/bugs/bug-archived-on-20261004.md:755`）。
- **建议**：(1) `grow` 三选一并写进 README——删除默认值强制显式 `new!`；或 `ZeroValue` 分支对引用类型抛 `IllegalArgumentException`；或把泛型约束收紧到可零值安全的场景。(2) `unsafeZeroValue` 的 KDoc 补「T 必须是有确定零值语义的类型；引用类型得到的是空引用，直接使用会崩溃」，并考虑 `where T <: CType` 之类的受限重载。(3) `ZERO_TIMER` 改成 `?Timer` 或删除（对外可达，删前确认下游），README 同段补风险说明。

### [严重][存量] `FutureTask` 在 `initLock` 内执行用户回调，可经「回调内派生任务再对同一 local 求值」形成死锁

- **位置**：`f_base/src/FutureTask.cj:157-166`（`getOrComputeLocal` 的 `synchronized(local.initLock)` 包住 `fn()`）、`:143-151`（`getOrSetLocal` 同构）；锁对象定义 `:333`
- **来源**：存量（`git blame -L 153,167` → `254ef066e4` 2026-07-25 / `83b55f8744` 2026-10-11；快照模式无 diff）
- **判据**：review-checklist §12.1（死锁：锁内调用外部回调，回调再取同一把锁）、§6.2（锁内做用户代码）
- **证据**：静态确定 —— `fn()` 是调用方传入的 `() -> T`，整段执行都在 `local.initLock` 的临界区内；`getLocal` 会沿途取父任务 `localLock`、`setLocal` 取当前任务 `localLock`，锁序为 `initLock → task.localLock`，但**没有任何机制阻止 `fn()` 再去获取同一 `initLock`（同 local）或另一个 `initLock`（另一 local）**。
- **描述**：两条可达路径：
  1. **同 local、跨线程**：任务 A 调 `local.getOrCompute{f}`，A 持 `initLock` 执行 `f`；`f` 内 `FutureTask{...}.get()` 派生任务 B，B 也对同一 `local` 调 `getOrCompute`。B 沿父链查不到值（A 还没 `set`），进 `synchronized(local.initLock)` 阻塞；A 阻塞在 `B.get()` ⇒ 双方永久互等。「懒初始化内部再并行初始化同一资源」是常见写法。
  2. **跨 local、双线程反向**：线程 1 持 `L1.initLock` 的 `fn` 内调 `L2.getOrCompute`，线程 2 持 `L2.initLock` 的 `fn` 内调 `L1.getOrCompute` ⇒ 经典锁序反转。

  代码注释（`:329-332`）只论证了「同线程重入安全」（该结论成立，std `Mutex` 文档明确可重入），未覆盖上述跨线程路径；`Mutex` 无超时参数，一旦命中即永久挂起，属阻塞级故障。
- **建议**：把 `fn()` 移出锁——锁内只做「复查 + 登记计算中标记」，计算在锁外执行，第二个调用方等待该标记完成（`Condition` / 一次性 `Future`）；或退化为「允许多次计算、最后一次写入生效」并写进注释（去掉 `initLock`，与 `ThreadLocal.getOrCompute` 对齐）。若保留现状，必须在注释与 README 明确「`fn` 内不得派生任务、不得访问其它 `InheritedTaskLocal`」。

### [严重][存量] `StringGenerator.remove` / `replace` 传入空搜索串时进入死循环（`remove` 还伴随无界内存增长）

- **位置**：`f_base/src/StringGenerator.cj:156`（`remove` 的 while 循环）、`:158`（`torm.add`）、`:177`（`replace` 的 while 循环）
- **来源**：存量（`git blame` → `4be871f2f`，2026-10-02 统一换行符提交之前的既有实现）
- **判据**：review-checklist §5（无界容器 / 拒绝路径缺失）、§11（边界/空值未处理）、§6.4（低效算法）
- **证据**：静态确定 —— 已核 std 源码 `stdlib/libs/std/core/array_common.cj:207`：`indexOf(elements, fromIndex)` 在 `elements.size == 0` 且 `fromIndex < this.size` 时，循环首轮 `this[i..i] == []` 恒真，返回 `Some(fromIndex)`。
- **描述**：
  - `remove` 的循环体 `let range = idx .. idx + search.size`（`:157`）在 `search` 为空时是 `idx..idx`，`fromIdx = range.end`（`:159`）恒等于 `idx`，下一轮 `indexOf` 仍返回同一个 `idx` ⇒ **while 永不退出**；同时 `torm.add(range)`（`:158`）每轮追加一个空区间 ⇒ `ArrayList<Range<Int64>>` 无界增长，最终 OOM。
  - `replace` 在 `oldBytes.size == newBytes.size == 0` 时走 `utf8.unsafeData()[idx..idx] = []` 的无操作分支（`:179`），`fromIdx = idx + 0`（`:189`）同样不前进 ⇒ **纯 CPU 死循环**（无分配，进程直接挂住）。
  - 触发条件只是「待删除/待替换内容为空串」，而 `content` 是 `T <: ToString` 的调用方入参（可来自配置、模板占位符），不是非法输入。
- **建议**：方法入口显式拒绝空搜索串（`if (search.isEmpty()) { return this }` 或抛 `IllegalArgumentException`），并在循环里加「位置必须前进」的自检（`fromIdx = range.end > fromIdx ? range.end : fromIdx + 1`）。两个方法都要改，不能只改一处。

### [严重][存量] `TypeMemberInfos` 缓存「先发布、后填充」，`HashMap` 被并发读写

- **位置**：`f_base/src/TypeMemberInfos.cj:28`（`staticPropertyMap[typeInfo] = map` 在填充前发布）、`:102`（`staticFunctionMap[typeInfo] = map` 同样先发布）；填充动作在 `:30-33` / `:104-109`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §12.1（发布逸出 / 迭代与修改并发）、§6.2（锁内/缓存一致性）
- **证据**：静态确定 —— `map` 是普通 `HashMap`，在 `case _ =>` 分支里先写进 `ConcurrentHashMap` 让其它线程可见，之后才在局部函数里逐个 `map[p.name] = p`。
- **描述**：`getStaticPropertyMap` / `getStaticFunctionMap` 是静态方法、缓存是静态字段，任何线程都走同一条路径。线程 A 首次未命中时先把**空 map** 发布到 `ConcurrentHashMap`，再逐条写入；线程 B 此时 `get(typeInfo)` 命中同一个空 map，随即 `get(name)` 或 `values()` 读取 —— 一边 `put` 一边读普通 `HashMap`，属数据竞争（可能读到半成品、丢条目，扩容期还可能读到错乱桶链）。另外 `staticProperty(typeInfo, name)` 对外返回的 `Collection`（`:50`）就是这个可变缓存本身，调用方遍历时被另一线程填充同样是并发修改。与另外 4 个同类 getter（`:79`、`:159`、`:197`、`:237` 都是「填完再发布」）不一致，属典型漂移。
- **建议**：统一改成「局部建好 → 填满 → 再 `put`」，并改用 `putIfAbsent` 让并发首次构建的赢家唯一（`ConcurrentHashMap.addIfAbsent`），输家丢弃自己那份直接返回缓存值；若必须在填完前发布，则把内层容器换成不可变结构或用锁保护整个构建段。

### [严重][存量] `ExitCallbacks.onExit` 无异常隔离：任一清理回调抛异常即中断后续清理，异常还会抛穿 `@C` 信号处理函数

- **位置**：`f_base/src/signal.cj:60-68`（`onExit` 的 `for` 循环内 `atexit()` 无 `try`）、调用点 `:42-46`
- **来源**：存量（`git blame -L 60,68` → `562abf068b` / `28d2e75be3` 2026-08-07，最初在 `f_app/src/signal.cj`，后随文件迁入 `f_base`；`4be871f2f` 仅换行符）
- **判据**：review-checklist §11（错误处理缺失 / 静默中断）、§3（异常被吞或穿透）、§1（`:45` 不可达 `false`）
- **证据**：静态确定 —— `onExit` 两个 `for` 里直接 `atexit()`，没有任何 `catch`。std 侧同样不兜底：`cangjie_runtime/stdlib/libs/std/runtime/runtime_signal.cj:113-129` 的 `signalHandler` 是 `@C` 函数，`for (fn in slot) { let result = fn(sig) ... }` 也没有 `try`。而 `signal.cj:44` 的 `exit(0)` 在 `std.env` 中签名为 `func exit(code: Int64): Nothing`（`stdlib/libs/std/env/env.cj:154`），即 `:45` 的 `false` 是**不可达语句**（§1 死代码，计入本模块死代码命中）。
- **描述**：触发条件是一次正常下线（SIGTERM / Ctrl-C）中，某个模块通过 `ExitCallbacks.atExit` 注册的回调抛异常（下游是 DB 关闭、日志 flush、池关停这类可能失败的清理）。后果按顺序：
  1. 后续优先级的回调**全部不执行**（`f_log` 的队列排空、`f_orm` 的连接释放等被跳过）——典型的数据丢失面；
  2. 异常从 `onExit` 传回 `f_base` 注册的 `() -> Bool` 处理器，再穿过 std 的 `@C` 信号分发函数，`exit(0)` 不会执行，进程以异常路径而非受控路径终止。

  现有 `f_bean` 的 `shutdown`（`f_bean/src/BeanFactory.cj:47` 注册）就是没有自兜底的实现，`docs/review/f_bean_review_20261128.md:43` 已记录同类风险，本函数是它唯一的上游保护层而该保护层缺失。
- **建议**：`onExit` 内对每个回调单独 `try { atexit() } catch (e: Exception) { 记录到 stderr }`，保证「一个失败不影响其余」；同时删掉 `:45` 不可达的 `false`，或改成「全部成功才 `exit(0)`，否则 `exit(70)`」。

### [一般][存量] `EmptyList.contains(all!)` 恒返回 false，与同文件其余空集合实现不一致

- **位置**：`f_base/src/EmptyCollections.cj:475-477`
- **来源**：存量（快照模式无基线）
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
- **建议**：加宽分支改为直接语言转换（`Int16(this)`、`Int32(this)`、`Int64(this)`），只在**收窄**时保留重解释；README 写明 `to<T>()` 的语义（截断 or 值保持）并给出边界用例（`0xFF`、`0x80`）。

### [一般][存量] `BaseException.addSuppressed` 允许自我挂接，`printStackTrace` 因此无限递归

- **位置**：`f_base/src/BaseException.cj:59-61`（`addSuppressed`）、`:71-86`（`printStackTrace`，递归点在 `:79-84`）
- **来源**：存量
- **判据**：review-checklist §4（自引用结构 / 无界递归）、§11（边界与契约）
- **证据**：静态确定 —— `addSuppressed(suppressed: Exception)` 无任何自引用检查，`suppressed_` 为普通 `ArrayList<Exception>`；`printStackTrace` 对每个 suppressed 递归调用 `printStackTrace(s, w)`（`:81-83`），若 `s === this`（或 A↔B 互挂）则递归无出口。`causedBy` 链因只能由构造函数设置而不可能成环，suppressed 链可以。
- **描述**：`e.addSuppressed(e)`（或 `A.addSuppressed(B); B.addSuppressed(A)`）之后任何一次 `printStackTrace` 都会栈溢出（进程级崩溃，不是可捕获的业务异常）。Java 的 `Throwable.addSuppressed` 对自引用抛 `IllegalArgumentException`，此处未对齐。仓内唯一调用点（`f_aspect/src/Aspect.cj:68,81`）挂的是新构造的 `AspectException`，暂不会触发。
- **建议**：`addSuppressed` 增加 `if (suppressed === this) throw IllegalArgumentException(...)`；`printStackTrace` 内对 suppressed 也加 `s !== this` 保护（互挂场景需按 identity 集合去重）。

### [一般][存量] `ExtendArray.grow` 的边界分支未处理空数组与 0 次重复

- **位置**：`f_base/src/ExtendArray.cj:63-65`（`First`/`Last`）、`:68-73`（`Repeat`）、`:94-96`（`operator *`）、`:55-59`（`check`）
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 空集合未处理 / 除零）
- **证据**：静态确定 ——
  1. `case First => this[0]`、`case Last => this[this.size - 1]` 在 `size == 0` 且请求扩容时执行 ⇒ `IndexOutOfBoundsException`；甚至 `[].grow(0, new: First)`（文档承诺「size 相等只复制」）也会越界，因为 `newval` 在判空之前就被求值（`:63-74`）。
  2. `Repeat` 只特判了 `s == 1`，`s == 0` 时走 `Array<T>(size){i => this[i % s]}` ⇒ `% 0` 抛算术异常（`:68-73`）。
  3. `operator *`：`[1,2] * 0` 先算出 `grow(0)`，`check(0)` 因 `0 < 2` 抛 `IllegalArgumentException`（`:55-59, :94-96`）——「重复 0 次」应得空数组。
- **描述**：三个分支都在输入退化时抛异常而非返回直观结果；`grow` 无任何测试。
- **建议**：`First`/`Last` 在 `this.size == 0` 时直接抛带说明的 `IllegalArgumentException`（或返回零值需另行决策）；`Repeat` 用 `s == 0` 单独分支；`operator *` 对 `repeat <= 0` 返回 `Array<T>()`。

### [一般][存量] 包内私有 `Option.map` 与 std 同名重载：包内语义被改成 flatten，且零引用

- **位置**：`f_base/src/ExtendOption.cj:51-57`
- **来源**：存量
- **判据**：review-checklist §1（本包内无调用者的 `internal` 符号 = 死代码）、§10（语言特性 / 标准库利用）
- **证据**：静态确定 —— 该成员没有 `public` 修饰（包内可见），`f_base/src` 全目录 grep `\.map` 零命中 ⇒ 无调用者。std 侧已有 `Option.map<R>(transform: (T) -> R): Option<R>`（`std/core/option.cj:61`）；本重载签名 `fn: (T) -> ?O` 更特化，包内任何 `opt.map{x => Some(v)}` 会被解析到这里得到**扁平化**结果，而仓内其它模块得到 `Some(Some(v))`。
- **描述**：既是死代码，又是「同名不同语义」的隐形陷阱：将来 f_base 内新增的 `map` 调用会与全仓行为不一致，编译器不会提示。Cangjie 不允许扩展成员覆盖 std 成员，只能靠重载优先级决胜，风险不可控。
- **建议**：删除，或改名为 `mapOption`/`flatMap` 并加 `public` 说明语义；若确需扁平化语义，在 README 显式记载。

### [一般][存量] `AsyncIterator.next()` 每次 `spawn` 一个线程，无并发上限

- **位置**：`f_base/src/ExtendIterator.cj:20-27`（`next()` 在 `:22-26`）
- **来源**：存量
- **判据**：review-checklist §5（一次提交全量任务）、§12.1（有界性）、§6.3
- **证据**：静态确定 —— `next()` 直接 `spawn { itr.next() }` 并返回 `Future`，没有窗口、没有批大小、也没有「上一个 Future 完成才发下一个」的约束。触发路径可枚举：`it.async().toArray()`（`ExtendIterator.cj:46-48` 的 `toArray` 会全量消费）⇒ 元素数 = 同时存活线程数。
- **描述**：设 10 万元素的迭代器，`async().toArray()` 会同时创建约 10 万个线程与 10 万个 `Future`；按每线程栈 1MB 量级估算即 100GB 级虚拟内存，实际表现为 `EAGAIN`/OOM 或被调度器拖死。即使调用方逐个 `get()`，也是「每元素一次线程创建 + 一次同步」，比串行更慢。仓内无调用方（grep `AsyncIterator`/`.async()` 仅定义处），属对外 API 的潜在风险。
- **建议**：改成固定大小工作线程 + 有界队列（或 `f_concurrent` 线程池），或把 API 改成「批量 `nextBatch(n)`」；至少在文档写明「不得在未等待前一个 Future 的情况下连续 `next`」。

### [一般][存量] `CpuFeatures_test.cj` 缺 Apache 版权头

- **位置**：`f_base/src/CpuFeatures_test.cj:1`（文件首行直接是 `package fountain::f_base`）
- **来源**：存量
- **判据**：`fountain-baseline` §3（每个 `.cj` 必须有 Apache 2.0 头且位于 `package` 之前；缺失按「一般」）
- **证据**：静态确定 —— 同目录 `Comparator_test.cj:1-15` 有完整头，本文件没有。
- **建议**：补 2026 年版权头。

### [一般][存量] `InheritedTaskLocal.set` 在任务外回退写 owner，`get` 不回退 —— 在 main 线程 `set` 后自读恒为 `None`

- **位置**：`f_base/src/FutureTask.cj:349-359`（`writeTarget` + `set`）与 `:361-363`（`get`）
- **来源**：存量（`git blame -L 349,371` → `c89cb7cf9a` / `b7226c1785`，2026-10-11）
- **判据**：review-checklist §11（契约与实现不一致、静默丢值）、§10（正确性）
- **证据**：静态确定 —— `set` 走 `writeTarget()`：不在任务里时返回 owner，把值写进 owner 的 `local` 表；`get` 走 `task.getLocal<T>(this)`，而 `getLocal`（`:118-130`）从 `currentTask.get()` 起沿父链上溯，**在 main 线程 `currentTask` 为 `None`，循环体一次都不执行，直接 `None<T>`**。`remove()` 也走 `writeTarget`，与 `set` 对称、与 `get` 不对称。
- **描述**：`FutureTask_test.cj:40-43` 正是支持「任务外先 `set`、任务内读」（`local.set(5)` 在测试线程，任务内读到 5）。但同一 API 在任务外 `set` 之后**自己读不回来**：
  ```cangjie
  let t = FutureTask<Int64>({ => 1 })
  let l = t.newLocal<Int64>()
  l.set(7)
  l.get()      // None —— 值其实写进了 t 的表
  ```
  调用方无法区分「没写进去」和「写了但读不到」。
- **建议**：`get` 与 `set/remove` 采用同一解析规则：先沿 `currentTask` 父链查，全部未命中且当前不在任务里时回退到 owner 的 `readLocalRaw`；或把 owner 回退收进显式 API（`seedForOwner`）。补一条「任务外 set 后任务外 get 应得 `Some(7)`」的测试。

### [一般][存量] `AbstractFutureTask.shutdown()` 的「关子树」作用在**调用线程**而不是 `this` 的子树上

- **位置**：`f_base/src/FutureTask.cj:171-174`（`shutdown`）、`:177-195`（`shutdownCurrentSubThreads`，键取 `Thread.currentThread.id`，见 `:180-182`）
- **来源**：存量（`git blame -L 171,174` → `5905520079`，2026-10-11）
- **判据**：review-checklist §11（语义与命名不符）、§12.1（跨线程语义错误）
- **证据**：静态确定 —— 实例方法 `shutdown()` = `cancelSelf()` + `shutdownCurrentSubThreads()`；后者是 `static`，按**当前线程** id 从 `subTasks` 摘桶并逐个 `f.shutdown()`。在 self 线程调用等于「取消自己 + 取消我的子树」；在**其它线程**调用（例如 main 拿到 `taskA` 句柄后 `taskA.shutdown()`）则变成「取消 taskA（`future.cancel`）+ 摘掉 **main** 名下的桶」，会把 main 创建的、与 taskA 无关的其它子任务一起取消。
- **描述**：任务线程被 cancel 后其 `finally` 会自行清理子树，最终状态通常仍正确，但**中间动作误伤了无关任务**：main 名下挂着的其它 `FutureTask`（例如一批后台任务）会被 `if(!f.finished.load()) f.shutdown()` 连带取消。方法名与签名让调用方无法预期这个副作用。
- **建议**：把子树清理拆成按 task 定位的 `shutdownSubTasksOf(task)`（桶键改为任务 id，或按 `parent` 链递归），`shutdown()` 只作用于 `this`；「关当前线程子树」保留为 `public static shutdownCurrentSubThreads()`。补一条「main 创建 A、B，对 A 调 `shutdown()`，断言 B 未被取消」的测试。

### [一般][存量] `HashBuilder.hashCode()` 有副作用（清零内部状态）且非幂等，却声明实现 `Hashable`

- **位置**：`f_base/src/HashBuilder.cj:37-39`（`hashCode` 直接 `build()`）、`:32-36`（`build` 清零 `hashed`）、`:25`（`<: Hashable`）
- **来源**：存量（`git blame -L 32,39` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符：`Hashable` 要求哈希稳定）、§1（`hashCode` 读了就破坏状态）
- **证据**：静态确定 —— 第一次 `hashCode()` 返回累计值并把 `hashed` 置 0，第二次返回 0。仓内没有任何位置把 `HashBuilder` 当 `Hashable` 使用（全仓 30+ 处调用都是 `append(...).build()` / `append(...)`），该 `Hashable` 声明没有消费者。
- **描述**：`Hashable` 的契约是「同一对象哈希稳定，相等对象哈希相同」。现在 `HashBuilder` 若被放进 `HashSet`/`HashMap`（或作为 `@DataAssist` 字段被 `append`），第一次求哈希后位置即失效；且 `HashBuilder` 未重写 `==`（身份相等），两个「内容相同」的 builder 哈希也不同。这是一条**已声明但不可用**的接口。
- **建议**：优先删除 `<: Hashable`（无内部依赖，属公开契约变更，需确认无下游使用）；若保留，`hashCode()` 改为只读返回 `hashed`，把清零留给 `build()`，并在注释说明「builder 可变，求哈希后继续 `append` 会使哈希失效」。

### [一般][存量] 集合重载按迭代顺序累加哈希：内容相同的 `HashMap`/`HashSet` 可能得到不同哈希

- **位置**：`f_base/src/HashBuilder.cj:109-124`（`ConcurrentHashMap` 重载）、`:90-99`（任意 `Iterable` 重载）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11（契约与实现不符）、§2（隐式假设「迭代顺序只由内容决定」）
- **证据**：待确认 —— 代码把 `for ((k, v) in value)` 的**遍历顺序**直接折进 `seed ^ ... << 6` 链；两个键集相同但插入/删除历史不同（导致容量、探测位置不同）的 map 是否得到同一遍历顺序，需按当前 std 实现的容量与重排规则验证。
- **描述**：`DataAssist` 生成集合字段哈希时走的是 `hasher.append(field.toString())`（`f_data/src/macros/DataAssist.cj:335-338`），**不经过这里**，风险面限于直接调用 `HashBuilder().append(someMap)` 的代码；仓内这类调用点未在形状上命中（本部分未逐一验证 30 处调用的实参类型）。若遍历顺序依赖历史，则「相等对象哈希相同」不成立，作为 map key 会查不到。
- **建议**：对 map/set 重载先按键排序（键可比较时）或对每项哈希做与顺序无关的组合（`sum`/`xor`，代价是碰撞率略升）；至少在注释写明「哈希与迭代顺序相关，仅用于同一进程内短生命周期对象」。

### [一般][存量] `ExtendRune` 的有符号偏移在 `Int*.Min` 上取负溢出

- **位置**：`f_base/src/ExtendRune.cj:44`（`-(n: Int8)`）、`:64`、`:71`、`:93`、`:100`、`:113`、`:120`（Int16 / Int64 / Int32 同构分支，全部写 `this ∓ UInt32(-n)`）
- **来源**：存量（文件年份 2025，`git blame` 落在换行符统一提交，无法区分更早来源）
- **判据**：review-checklist §11（边界差一 / 极值）、§10（正确性）
- **证据**：静态确定（取负溢出本身）＋ 待确认（后续转换的确切行为）—— `n == Int8.Min` 时 `-n` 仍是 `-128`，`UInt32(-n)` 的实参为负；`Int16/Int32/Int64.Min` 同理。四个有符号重载都走这条路径，无 `Min` 特判。
- **描述**：`r'中' + Int64.Min` 这类调用不会得到「减少 2^63」的语义，而是把负值送进 `UInt32()`：要么按检查转换抛 `OverflowException`（调用方拿到与「字符偏移越界」无关的异常），要么回绕成巨大偏移后由 `Rune(...)` 产出错误字符。两种结果都不是该 API 的契约。无符号重载与 `-(c: Rune)` 只存在越界问题，没有取负溢出。
- **建议**：先在 `Int64` 域上加一次（`Int64(UInt32(this)) + n`），判 `0 <= r <= 0x10FFFF` 且非代理区后再转 `Rune`；越界抛带信息的 `IllegalArgumentException`。补 4 个极值用例（`Min`、`Max`、`-1`、越过 `0x10FFFF`）。

### [一般][存量] `TypeMemberInfos` 三个 getter 的闭包捕获了外层变量，继承来的成员查不到

- **位置**：`f_base/src/TypeMemberInfos.cj:30`（`addProp(ti)` 内遍历的是 `typeInfo.staticProperties`）、`:104`（`addFunc(ti)` 内遍历的是 `typeInfo.staticFunctions`）、`:232`（`for (v in x.instanceVariables)`，循环变量是 `c`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（语义与实现不符）、§2（近似重复导致行为漂移）
- **证据**：静态确定 —— 形参 `ti` / `c` 在函数体内完全没被读取；与正确实现 `addProps(ti)`（`:66`）、`addFunc(ti)`（`:143`）、`staticVariables` 的 `for (v in c.staticVariables)`（`:192`）对照即可确认。
- **描述**：三个方法都按「沿 `superClass` 链向上遍历」的意图写成 `while`，但取成员时用了循环外的 `typeInfo`（或初始的 `x`），于是：静态属性/静态函数每轮重复添加**最派生类自己**的那份，父类静态成员永远进不了缓存；实例字段每轮重复添加 `x` 自己的字段，父类字段永远缺失。后果是 `staticProperty` / `staticFunction` / `instanceVariable` 对继承成员返回 `None` —— `f_data/src/base/DataObject.cj:78-90` 这类按名反射读写属性的调用方会静默走错分支。
- **建议**：三处闭包改读形参（`for (p in ti.staticProperties)`、`for (f in ti.staticFunctions)`、`for (v in c.instanceVariables)`），并补「子类实例能查到父类字段/父类静态方法」的回归用例（当前无 `TypeMemberInfos` 测试）。

### [一般][存量] `StringGenerator.remove` 倒序删除漏掉下标 0，单匹配时完全不删

- **位置**：`f_base/src/StringGenerator.cj:161`（`for(i in torm.size - 1 .. 0: -1)`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（边界差一）、§6.4
- **证据**：静态确定 —— 已核 std `Range` 源码 `stdlib/libs/std/core/range.cj:65-93`：非闭区间 `a..b` 配 `step = -1` 时 `last() = end.next(1)`，迭代序列是 `a, a-1, …, b+1`，**不含 `b`**。std 自身在 `array_common.cj:240` 用的是 `size - 1..=0 : -1`（闭区间）。
- **描述**：`torm` 按下标升序收集命中区间，倒序删除方向正确，但区间末端写成 `0`（半开）⇒ 只删到下标 1。`torm.size == 1` 时 `0 .. 0 : -1` 是空区间，**一个都不删**；`torm.size > 1` 时首个命中残留。表现为 `gen.remove("{x}")` 返回后文本里仍留一处/全部占位符，属静默产出错误字符串。
- **建议**：改成 `for (i in torm.size - 1 ..= 0 : -1)`（或 `torm.size - 1 .. -1 : -1`），并补 0 处 / 1 处 / 多处命中的用例。

### [一般][存量] `StringGenerator.checkIndex` 边界过严：合法位置被拒、空生成器上的无操作调用直接抛异常

- **位置**：`f_base/src/StringGenerator.cj:41`（`fromIndex >= size` 判定），影响 `remove`（`:152`）、`replace`（`:173/194`）、`replaceFirst`（`:211`）、`replaceLast`（`:231`）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（边界差一）、§10（边界校验）
- **证据**：静态确定 —— `size` 是字节长度（`String.size` 为 UTF-8 字节长度，本类 `utf8` 存字节），判定式只允许 `fromIndex < size`。
- **描述**：两类合法调用被误判：① `fromIndex == size`（在末尾追加式替换/删除）被判越界；② 对空生成器（`size == 0`）调用 `remove` / `replace` / `replaceFirst`（默认 `fromIndex = 0, toIndex = size = 0`）必抛 `IndexOutOfBoundsException`，而语义上应是「无匹配、原样返回」。当前下游多在非空串上使用，因此长期没暴露。
- **建议**：`fromIndex > size` 才算越界（保留 `fromIndex < 0` 与 `toIndex < fromIndex || toIndex > size`），并允许 `size == 0 && fromIndex == 0 && toIndex == 0` 通过。

### [一般][存量] `StringGenerator.substring` 不做索引与 UTF-8 边界校验，可产出非法 `String`

- **位置**：`f_base/src/StringGenerator.cj:128-132`
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §11（契约/边界）、§10（正确性）
- **证据**：静态确定 —— 已核 std：`Array[a..b]` 越界抛 `IndexOutOfBoundsException`，`String.fromUtf8Unchecked` 只做 `clone`、**不做** UTF-8 合法性检查（`stdlib/libs/std/core/string.cj:271-273`）。
- **描述**：与同类方法不同，`substring` 既不调 `checkIndex`，也不校验 `start/end` 是否落在字符边界。对中文等多字节内容，`substring(0, 1)` 会构造出半个字符的 `String`，违反 `String` 的 UTF-8 不变量（此后 `runes()`、比较、`rawData` 消费方行为不可预期）。`Array` 切片会抛越界异常，所以「越界崩溃」这一路是安全的，风险集中在**非法 UTF-8 静默通过**。
- **建议**：补 `checkIndex(start, end)`，并（若语义允许）把 `start/end` 定义成字符边界或提供按 Rune 的子串方法；若刻意保留字节语义，注释里写明「调用方保证落在字符边界」。

### [一般][存量] `hex.fromHex` 只校验长度上限，空串/单字符/非十六进制字符走越界或未文档化异常

- **位置**：`f_base/src/hex.cj:29-34`（判定在 `:30`，取值在 `:33`）
- **来源**：存量（`git blame` → 早于 `4be871f2f` 的实现）
- **判据**：review-checklist §11（空串/边界未处理、错误处理缺失）
- **证据**：静态确定 —— 代码只判 `s.size > 2`；`s[0]`/`s[1]` 在 `size` 为 0/1 时必然越界；`hexmap` 只装了 `'0'-'9'`、`'a'-'f'` 16 个键，`Map.[]` 缺键是抛异常而非返回 `None`。
- **描述**：`fromHex("")`、`fromHex("a")` 抛 `IndexOutOfBoundsException`；`fromHex("zz")`、`fromHex("0A")`（大写）抛哈希表缺键异常。方法签名承诺「String → Byte」，实际没有任何输入校验，错误类型也不是 `IllegalArgumentException`，调用方无法区分「输入非法」与「内部 bug」。`toHex` 侧无问题。
- **建议**：入口判 `s.size != 2` 抛 `IllegalArgumentException(s)`；取值改为 `hexmap.get(...)` + `?? throw IllegalArgumentException(s)`；如要支持大写，建表时把 `'A'-'F'` 一并写入（或先 `toAsciiLower`）。

### [一般][存量] `OverSizePolicy` 契约没有「是否接受」的反馈，`DiscardOverSizePolicy` 静默丢元素

- **位置**：`f_base/src/OverSizePolicy.cj:25`（`func reject(o: T, fn: () -> Unit): Unit`）、`:36`（`DiscardOverSizePolicy.reject` 空实现）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §3（公开契约声称有行为但实现为空 / 静默吞掉）、§11（契约与实现不符）
- **证据**：静态确定 —— `reject` 返回 `Unit`，`fn` 是否被执行是唯一信号，但策略实现不回报执行结果；实际调用方 `f_collection/src/PriorityQueue.cj:101`（范围外，仅作契约核对）的 `add(x): Unit` 直接丢弃了这个信号。
- **描述**：容器满时 `DiscardOverSizePolicy` 丢弃新元素、`BlockingOverSizePolicy` 超时也可能丢弃，但 `add` 的调用方拿到 `Unit`，无法得知「元素没进队列」。对队列类 API 这是静默数据丢失，且没有任何日志/计数钩子。
- **建议**：`reject` 增加返回值（如 `Bool` 表示「已处理/已接收」），或让 `add` 返回 `Bool`/抛 `OverSizeException`；至少在 `DiscardOverSizePolicy` 里留注释说明「满则丢新值」。

### [一般][存量] `BlockingOverSizePolicy.reject` 超时后静默丢弃，且条件等待不重查谓词

- **位置**：`f_base/src/OverSizePolicy.cj:63-70`（`condition.wait` 在 `:65`，`recovered(o)` 分支在 `:67-69`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §12.1（条件等待虚假唤醒未在循环里重查条件）、§11（错误处理缺失）
- **证据**：静态确定 —— `std.sync.Condition.wait(timeout)` 返回 `Unit`（`sync_package_classes.md:8295`），无法区分「被通知」与「超时」；`recovered(o)` 为 `false` 时函数直接返回，既不 `throw` 也不走 `policy`。
- **描述**：语义上它是「等空间 → 有空间按内层策略重试 / 没空间就……」，但「没空间」这一支是空的分支：新元素被丢掉而调用方无感（叠加 `add` 返回 `Unit`）。另外默认 `timeout = Duration.Max`（`:60`），没人 `notify/notifyAll` 时 `reject` 会永久阻塞调用线程；`wait` 也没放在 `while (!recovered(o))` 里，被无关 `notify` 唤醒后直接走向丢弃分支。
- **建议**：`wait` 包进 `while` 重查 `recovered(o)`，并记录是否超时（`DateTime.now()` 前后取或 `tryLock`+`sleep`）；超时后要么抛 `OverSizeException`，要么显式交给 `policy.reject`，不要留空分支。默认超时改成有限值（如 30s）并写进文档。

### [一般][存量] `TypeInfos.getGenericTypes(qualifiedName:)` 调用了仓内不存在的 `parseParameterTypes`

- **位置**：`f_base/src/TypeInfos.cj:64`
- **来源**：存量（`git blame` → 该行自初始提交 `45aeab749` 起就存在；`git log -S 'parseParameterTypes'` 全历史只命中调用点）
- **判据**：review-checklist §11（契约与实现不符）、§1（无定义符号）
- **证据**：待确认 —— ① 全仓 `grep -rn 'parseParameterTypes'`（含大小写不敏感、含非 `.cj`）只有这一处调用，`f_base/src` 及其它模块均无定义、`f_base` 也无 `extend TypeInfos`；② 但 `f_base/target/release/f_base@fountain/libf_base@fountain.so` 里存在同名符号，说明构建机（`/mnt/linux_share/...`）的源码与当前工作区不一致 —— 需确认是否存在未入库文件或生成代码。
- **描述**：按当前工作区源码，`getGenericTypes(qualifiedName:)` 无法解析 `parseParameterTypes`，该文件应编译失败；即使能编过，`qualifiedName[i + 1 .. qualifiedName.size - 1]` 在没有结尾 `>` 时会静默截断最后一个字符，嵌套泛型 `Foo<Bar<Int64>>` 里的 `,`/`<` 也无从切分。该方法在仓内零调用（对外 public API）。
- **建议**：补 `parseParameterTypes` 实现（按 `<>` 深度切分参数，逐个走 `TypeInfos.get(qualifiedName:)`），或把该方法降级/删除；先在本机 `cjpm build` 确认是否真的编不过，再决定「补实现」还是「删 API」。

### [一般][存量] `Result.mapError` / `flatten` / `transpose` 在类型不匹配时静默丢弃 Ok 值

- **位置**：`f_base/src/Result.cj:98-99`（`case Ok(v: U) => Ok(v)` + `case Ok(_) => Ok`）、`:162-163`（`flatten`）、`:170-181`（`transpose`，`Ok(None)` 落到 `NoResult`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（错误处理/数据丢失）、§10（`Result` 是否被静默丢弃）
- **证据**：静态确定 —— 三个方法都用「运行时类型测试 + 兜底空值」的写法，兜底分支不保留原值也不报错。
- **描述**：`mapError` 只该改写 `Err`，但 `T` 不是 `U` 时 `Ok(v)` 被替换成裸 `Ok`（值丢失）；`flatten` 对「`Ok` 里不是 `Result<U,E>`」同样降级为裸 `Ok`；`transpose` 把 `Ok(None)` 映射成 `NoResult` 并被外层 `?` 自动包成 `Some(NoResult)`，而标准 transpose 语义应是 `None`（`Ok(Some(x)) → Some(Ok(x))`、`Err(e) → Some(Err(e))`、`Ok(None) → None`）。均无文档说明。
- **建议**：给 `mapError` 加 `T <: U` 约束（或用显式转换函数承担丢失语义并在注释写明）；`transpose` 的 `Ok(None)` 分支返回 `None`；`flatten` 的兜底改为 `Err`/抛异常，不要静默 `Ok`。

### [一般][存量] `onExit` 在持有 `ExitCallbacks.mutex` 的临界区内执行全部用户回调：临界区无界，并与 std 信号锁构成反向锁序

- **位置**：`f_base/src/signal.cj:61-67`（`synchronized(mutex)` 包住整个回调循环）；锁与表定义 `:37-38`
- **来源**：存量（`git blame -L 61,67` → `91978212cc` 2026-09-01；`onExit` 骨架见 `562abf068b`）
- **判据**：review-checklist §6.2（锁内做用户代码）、§12.2（临界区只保护不变量）、§12.1（多锁顺序）
- **证据**：静态确定 —— 临界区包含全部 `atexit()`，时长由回调决定（含 DB/日志/IO），无上界；`Mutex` 在仓颉中可重入（`stdlib/libs/std/sync/mutex_cjnative.cj:17-40` 注释 "Support reentrant"），故**同线程**回调里再 `atExit` 不会自锁，但跨线程锁序成立：
  - 信号线程：std `mtx`（`runtime_signal.cj:120`，包住用户 handler）→ `ExitCallbacks.mutex`（`onExit`）；
  - 清理线程：`ExitCallbacks.mutex` → 回调内若调 `registerSignalHandler` / `resetSignalHandler` 则取 std `mtx`。

  两条路径顺序相反，同时成立即死锁（触发条件：某个清理回调里注册/复位信号处理器，例如模块下线时撤销自己的 handler）。
- **描述**：即使不死锁，`atExit` 注册路径在关机期间也被所有回调的总耗时串行阻塞；`f_cache`（`HeapCache.cj:65`）、`f_pool` 等注册的回调里包含 `close()` 这类等待内部线程退出的动作，会把其它线程的注册/退出流程一起拖住。
- **建议**：先在锁内把回调**快照**成 `Array<() -> Unit>`（按 `TreeMap` 升序 + 列表注册序展开），释放锁后再逐个执行；临界区只剩 O(n) 拷贝，也消除反向锁序。快照语义写进 README（「执行期间新注册的回调本轮不执行」）。

### [一般][存量] `atExit` 只增不减且强持有闭包：按实例注册的清理项与进程同寿，下游只能靠 `WeakRef` 自救

- **位置**：`f_base/src/signal.cj:36-59`（`private static let callbacks = TreeMap<UInt16, ArrayList<() -> Unit>>()`，仅 `atExit` 追加，无 `remove` / 清空）
- **来源**：存量（`git blame -L 36,38` → `91978212cc` 2026-09-01）
- **判据**：review-checklist §5（无界容器 / 长期持有）、§7（缩短生命周期）、§12.1（共享可变状态）
- **证据**：静态确定 —— 整个 `ExitCallbacks` 只有 `toExitGracefully` / `atExit` / 私有 `onExit` 三个成员，没有注销入口；`callbacks` 是进程级静态表，`ArrayList<() -> Unit>` 里的闭包被强引用直到进程结束。下游已出现规避代码：`f_cache/src/HeapCache.cj:62-65` 注释明写「注册项只捕弱引用，避免 f_base 的全局注册表把实例钉住」，`f_pool` 的 `POOL-13` 同样改为弱引用（`.autocode/bugs/bug-pool-archived-20261006.md:496-519`）。
- **描述**：按「每个对象构造时注册一次」的用法（缓存、连接池、日志 facade 都这样），注册表条目数随实例创建次数单调增长；闭包捕获的实例在 `close()` 之后仍不可回收。`f_base` 把「必须自己用弱引用」这一约束留给每个调用方，任何新模块漏写就是一次常驻泄漏。
- **建议**：`atExit` 返回注销句柄（`ExitCallbackHandle`，内部持 `priority` + 唯一 id），提供 `remove(handle)`；或在文档与类型层面强制弱引用语义。保留现状时至少：`atExit` 的 KDoc 与 README 写明「注册表无注销、闭包会被强持有到进程结束」。

### [一般][存量] Windows 分支 `atExit` / `toExitGracefully` 为空实现且无注释，与 POSIX 行为静默不同

- **位置**：`f_base/src/signal.cj:70-74`（`@When[os == "Windows"] public struct ExitCallbacks { ... {} ... }`）；同类空桩还有 `:109-125` 的 `registerSignalHandler` / `resetAndRegisterSignalHandler` / `resetSignalHandler`
- **来源**：存量（`git blame -L 70,74` → `3a350f62f` / `1677ac48a` / `39d7cccce`，2026-09 为 Windows 补编译）
- **判据**：review-checklist §3（有意的 Null Object 必须有注释说明为什么可以空）、§11（契约与实现不符）、§14（跨平台能力差异未声明）
- **证据**：静态确定 —— Windows 分支两个方法都是 `{}`，文件内没有任何注释解释；而 POSIX 分支是「登记 → 信号触发 → 按权重执行」。下游把它当唯一销毁路径：`f_bean/src/BeanFactory.cj:47` 只通过 `ExitCallbacks.atExit(253, this.shutdown)` 注册 `shutdown`，全包无第二条 `doDestroy` 调用点（已由 `docs/review/f_bean_review_20261128.md:29-36` 取证）。
- **描述**：Windows 上 bean 的 `destroy`/`close`、池的关停、日志的排空都不会执行，且不报错、不告警，属静默能力缺失。`f_dbd/doc/spec/.../design.md:109` 已把「`ExitCallbacks` 在 Windows 为空实现」写成规格，但 `f_base` 自身的 README（`:735-745`）没有这句，使用者按 README 用会踩空。
- **建议**：Windows 分支用 `std.env.atExit`（仓颉 std 在 Windows 可用）承接注册表，使语义对齐；若确定不做，至少在结构体与 README 标注「Windows 无优雅退出，注册项永不执行」，并让 `f_bean` 等模块在 Windows 走显式关闭。

### [一般][存量] `MEM_PAGE_SIZE` 在非 Linux 平台固定 4096，macOS arm64 实际 16 KiB，`msync` 偏移因此不对齐

- **位置**：`f_base/src/native.cj:28-31`（`@When[os != "Linux"] public let MEM_PAGE_SIZE: Int64 = 4096`）
- **来源**：存量（`git blame -L 28,31` → `a927b5937`「添加 Linux 系统内存页大小获取功能」，2026 早期；`4be871f2f` 换行）
- **判据**：review-checklist §11（边界 / 平台常量错误）、§13（注释与实现不符）
- **证据**：静态确定（代码侧）＋平台事实 —— 注释写「当前系统内存页大小」，但只有 `os == "Linux"` 调 `getpagesize()`，其余平台一律 4096；Apple Silicon macOS 的 `getpagesize()` 返回 16384，该符号在 macOS 亦可用。下游把它当页对齐基准：`f_io/src/MMapFile.cj:154-155` 用 `(dirtyStart / MEM_PAGE_SIZE) * MEM_PAGE_SIZE` 算 `msync` 起始地址，而 POSIX 要求 `msync` 的 `addr` 按**真实页大小**对齐。
- **描述**：macOS arm64 上 `dirtyStart` 不是 16384 的倍数时，`syncStart` 只是 4096 对齐，`msync` 返回 `EINVAL`；`MMapFile.sync` 未检查返回值（范围外提示：`f_io/src/MMapFile.cj:155` 丢弃了 `msync` 返回），于是**同步失败被静默忽略**，映射文件数据可能不落盘。Linux / OpenHarmony（4 KiB）不受影响，Windows 不适用。
- **建议**：把 `getpagesize` 声明与 `MEM_PAGE_SIZE` 取值放宽到 `@When[os != "Windows"]`，或改用 `sysconf(_SC_PAGESIZE)`；`@When[os == "Windows"]` 保留 4096。README 注明各平台来源。

### [一般][存量] `nextPowerOf2` 未校验入参：`n > 2^62` 时 `x + 1` 溢出返回负数，`default ≤ 0` 被静默换成 128

- **位置**：`f_base/src/nextPowerOf2.cj:18-32`（`x |= x >> ...` 之后 `return x + 1`；`:19-21` 的 `default` 分支）
- **来源**：存量（`git blame -L 18,32` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（边界 / 溢出）、§10（正确性）
- **证据**：静态确定 —— 对 `n = 2^62 + 1`，`x |= x >> 1/2/4/8/16/32` 把低 63 位全部置 1，得 `Int64.MaxValue`，`+1` 回绕成 `Int64.MinValue` 并返回。函数是 `public`（README `:722` 列为公开 API），无任何范围检查。`default` 路径：`n <= 0` 时递归 `nextPowerOf2(default)`，而该递归调用的 `default` 形参重新取默认值 128，故 `nextPowerOf2(0, default: 0)` 返回 128 而不是调用方给的值。
- **描述**：仓内两处调用都传 `concurrencyLevel`：`f_cache/src/ConcHashMap.cj:210-211` 无守卫，`f_cache/src/HeapCache.cj:86-92` 调用前判 `> (1 << 62)` 抛 `IllegalArgumentException`——同一份算术，一个调用点显式防了溢出、另一个没防，说明阈值问题已知，只是防护写在调用方。`HeapCache.cj:55-59` 先用 `roundUpToPowerOf2` 收口，所以仓内当前不会触发；但对外 API 直接调用会拿到负分段数，随后 `Array(负数)` 抛异常。`default ≤ 0` 的静默替换会让「关闭兜底」的配置失效。
- **建议**：入口校验：`n > (Int64(1) << 62)` 或 `default <= 0` 时抛 `IllegalArgumentException`（文案与 `HeapCache.cj:88` 对齐）；把 `HeapCache` 的调用前守卫删掉，统一收口到 `nextPowerOf2`。README 补「有效范围 `(0, 2^62]`，非正值走 `default`」。

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
- **建议**：断言改为 `@Assert(Ordering.LT, comparator(1, 2))`，并补 `reverse()`/`then()` 的用例。

### [轻微][存量] `CpuFeatures_test` 的断言恒真

- **位置**：`f_base/src/CpuFeatures_test.cj:12`
- **来源**：存量
- **判据**：review-checklist §11（测试无效）
- **证据**：静态确定 —— `@Assert(v == CpuFeatures.hasSse41, true)` 是同一属性两次读取的比较；在 x86_64 上无论实现返回什么都会通过。
- **建议**：改为断言与 `/proc/cpuinfo` 的一致性，或断言「两次读取一致 + 非 x86_64 为 false」（后者已有 `:13-15`）。

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
- **建议**：返回只读视图或副本（调用频次极低，拷贝无成本）；修正拼写（会改变输出文本，需同步测试快照）。

### [轻微][存量] `EmptyMapEntryView.value` 的 setter 静默丢弃写入

- **位置**：`f_base/src/EmptyCollections.cj:339-344`
- **来源**：存量
- **判据**：review-checklist §3（空实现；Null Object 必须注释说明）
- **证据**：静态确定 —— `set(value) {}`，无注释。
- **描述**：空 map 的 entryView 写入不可持久化是合理的（Null Object），但静默丢弃会让「以为写成功了」的调用方难以发现缺陷。
- **建议**：保留空实现并加一行注释说明「空 map 不保存任何 value」；或改抛 `UnsupportedException`（改变现有行为，需用户决策）。

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
- **描述**：8 份复制带来「一处修、七处漏」的风险（本轮已发现 `to<T>()` 的加宽规则在 3 个无符号类型里同时错，正是复制扩散的后果）。位运算无法泛型化，但可用宏统一生成，或至少把 `to<T>()` 的分派表抽成一处。
- **建议**：用 `f_macros` 生成 8 份实现（保留 `@OverflowWrapping` 等属性），或集中成一个「按目标类型分派」的私有函数 + 8 个薄包装；必须与 `to<T>()` 的语义修正一起做。

### [轻微][存量] `ExtendOption` 的 12 组运算符提升逐字重复

- **位置**：`f_base/src/ExtendOption.cj:140-313`（`+ - * / % ** & | ^ ! << >>`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 只改运算符符号）
- **证据**：静态确定 —— `?T` 版本全部是 `call<?T> {x => match (other) { case Some(y) => x op y; case _ => None<T> }} ?? None<T>`，只有运算符不同。
- **描述**：这正是 `+`/`*` 两处写反操作数却未被发现的原因（复制时手写 `other op x`）。
- **建议**：抽一个私有 `lift(other: ?T, op: (T, T) -> T): ?T`，12 组各自退化成一行；`T` 版本保留（签名不同，无法合并）。

### [轻微][存量] `Help` 是内部死代码，其中三个 `public static convert` 因泛型参数无法推断而不可调用

- **位置**：`f_base/src/Help.cj:18-46`
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §1（`internal` 类全仓零引用；其 `public` 成员随之不可达）、§10（泛型推断）
- **证据**：静态确定 —— `abstract sealed class Help` 无可见性修饰（包内可见），全仓零引用；`convert<T>(Array<?String>)`、`convert<T, C>(Array<C>)` 的 `T` 只出现在约束里，调用处无推断来源，三个重载实际不可调用。
- **建议**：直接删除整个类；若将来需要，重新设计成带显式 `T` 形参的公开工具。

### [轻微][存量] `HashBuilder` 的 `private append(Map)` 无调用者，且与 `ConcurrentHashMap` 重载逐段复制

- **位置**：`f_base/src/HashBuilder.cj:134-153`
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §1（私有符号零调用 = 死代码）、§2（9 臂 `match` 完全复制）
- **证据**：静态确定 —— 全文件仅定义处出现 `append(` 的 `Map` 重载；`:110-122` 已有同构的 9 臂 `match`。
- **建议**：删除该私有重载，保留 `ConcurrentHashMap` 版本；若需支持 `Map`，改为转调（`append(ConcurrentHashMap(value))` 或共用私有实现）。

### [轻微][存量] `HashBuilder` 13 个标量 `append` 重载与泛型重载逐行等价

- **位置**：`f_base/src/HashBuilder.cj:53-88`
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 13 个重载（`Int8`…`Bool`）全部只做 `append(arg.hashCode())`，与 `:47-49` 的 `append<T>(arg: T)` 语义相同。
- **描述**：13 份副本对 `Int64`/`String` 等类型甚至可能因重载优先级产生与泛型版不同的解析结果，维护面大而收益为零。
- **建议**：保留泛型版，删除标量重载；若担心装箱，改为 `appendInt64` 之类的具名方法而不是重载。

### [轻微][存量] `Options.isEmptyOrUnit` / `isNotEmptyOrUnit` 与 `isEmpty` / `isNotEmpty` 行为完全一致

- **位置**：`f_base/src/Options.cj:34-42`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2（同义 API）
- **证据**：静态确定 —— `isEmpty` 的 `case Some(x) where x is Unit` 已把空 Unit 判为真，故两个「OrUnit」版本对所有取值返回相同结果。
- **建议**：删除两个同义方法（对外 API，删前确认下游），或让它们承担真正不同的语义（例如只判 `Some(())`）。

### [轻微][存量] `Options` 的类参数 `R` 只出现在方法体内，调用方无法推断

- **位置**：`f_base/src/Options.cj:20`、`:23-30`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §10（API 可用性 / 泛型推断）
- **证据**：静态确定 —— `R` 只出现在 `Collection<R>` 的静态方法体内，形参里无推断来源，调用方必须写全 `Options<T, R>.isEmpty(...)`。
- **建议**：把 `R` 从类参数改为方法级泛型（`isEmpty<T, R>(...)`），或改用接口 + 扩展方法承载。

### [轻微][存量] `Options` 的类型不匹配异常没有消息

- **位置**：`f_base/src/Options.cj:120`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §10（错误信息）
- **证据**：静态确定 —— `throw IllegalArgumentException()` 无参。
- **建议**：带上目标类型与实际类型（`'cannot convert ${TypeInfo.of<T>()} to ${TypeInfo.of<R>()}'`）。

### [轻微][存量] `Options.convert` 与 `convertOrThrow` 对同一失败给出相反语义

- **位置**：`f_base/src/Options.cj:91-105`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（同名系列契约不一致）
- **证据**：静态确定 —— `convert(origin, default)` 转换失败回退 `default`；`convertOrThrow(origin, default)` 转换失败抛异常，`default` 形参在抛异常路径上无意义。
- **建议**：`convertOrThrow` 去掉 `default` 形参（或改名为 `convertOrDefault` / `convertOrFail`），让两个签名各自表意。

### [轻微][存量] `FutureTask_test` 有未使用的 `import`

- **位置**：`f_base/src/FutureTask_test.cj:21`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §1（未使用 import）
- **证据**：静态确定 —— `import std.collection.HashSet` 仅出现在注释里。
- **建议**：删除该 import。

### [轻微][存量] `FutureTask_test` 的桶上限断言远松于实现阈值，且多处定长 `sleep` 断言

- **位置**：`f_base/src/FutureTask_test.cj:472`（`assert(maxBucket <= 200)`）、`:83/:107/:135/:161`（`sleep(400/450/600ms)`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（测试无效 / 脆弱）
- **证据**：静态确定 —— 实现剪枝阈值是 64（`FutureTask.cj:238-240`），断言放到 200 时剪枝退化为 200 也能通过；定长等待在高负载 CI 上易假失败。
- **建议**：断言收紧到 64 的合理上界（如 `<= 80`），等待改为轮询条件（`while (!cond) { sleep(10ms) }` + 总超时）。

### [轻微][存量] `OS` 手写 `operator ==` 与 `toString()`，与枚举默认语义等价

- **位置**：`f_base/src/OS.cj:27-38`、`:74-84`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2（与语言默认实现重复）、§10
- **证据**：静态确定 —— `==` 是 7 分支全枚举匹配，`toString()` 也是 7 分支；枚举自带同语义实现。
- **描述**：新增枚举值时两处都要改，是纯维护面；`toString()` 的文本被 `hashCode()` 依赖（见优化方案）。
- **建议**：删除 `==`，`toString` 保留仅当需要固定文本（则加注释说明与默认实现不同）。

### [轻微][存量] `ExtendString.trimAsciiBlanks` 与 std `String.trimAscii()` 近似但不一致，命名未体现差异

- **位置**：`f_base/src/ExtendString.cj:45-58`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2（近似重复造成行为漂移）、§10（命名）
- **证据**：静态确定 —— 此处判定 `<= b' '`（含 0x00–0x08、0x0E–0x1F），std 只含 0x09–0x0D 与 0x20。
- **描述**：同名场景下两者结果不同（例如含 `\x00` 的串），调用方按 std 语义理解会拿到意外结果。
- **建议**：改名为 `trimAsciiAndControls`，或直接转调 std `trimAscii()` 并把控制符裁剪做成显式开关。

### [轻微][存量] `Operators` 的 `Cmpable` / `Eqable` 仓内零引用（可见性建议）

- **位置**：`f_base/src/Operators.cj:46-56`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §1 硬原则一（对外可达 public 不算死代码，单列可见性建议）
- **证据**：静态确定 —— 全仓 grep 两个接口名仅命中定义；其余 13 个接口均有使用。
- **建议**：确认无下游依赖后评估收窄或合并到 `Comparable`/`Equatable` 系列；不按死代码处理。

### [轻微][存量] `FutureTask` 在 `spawn` 之前登记，`spawn` 失败时登记项残留

- **位置**：`f_base/src/FutureTask.cj:235-252`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（资源释放不对称 / 异常路径）
- **证据**：待确认 —— 登记发生在 `spawn` 之前；`spawn` 抛异常（线程资源耗尽）时任务已进 `subTasks` 却永不进入 teardown，登记项残留到父任务收尾。需核对 `spawn` 的失败模式（是否可能抛）。
- **建议**：把登记移到 `spawn` 成功之后，或 `spawn` 外包 `try { } catch { 撤销登记; rethrow }`；补一条注入失败的用例。

### [轻微][存量] `ExtendRune` 的 4 组有符号 / 4 组无符号重载逐行相同

- **位置**：`f_base/src/ExtendRune.cj:40-73`、`:89-121`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 8 份实现只差 `Int8/16/32/64`（及无符号）类型名。
- **描述**：`Int*.Min` 的取负溢出现在 4 份里同时存在，正是复制的后果（见对应「一般」项）。
- **建议**：窄类型重载转调 `Int64` 版本（`this + Int64(n)`），把极值判定收到一处。

### [轻微][存量] `OverSizePolicy` 接口注释与实际调用方式相反

- **位置**：`f_base/src/OverSizePolicy.cj:21-24`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 注释写「`o` 是待添加的新值」，实际调用方 `f_collection/src/PriorityQueue.cj:101` 传的是 `this`（队列本身），新元素在 `fn` 闭包里（范围外，仅作契约核对）。
- **描述**：`RemoveSomeOnePolicy` 的 `remove(o)` 语义是「从容器里腾一个位置」，与注释描述的「新值」完全不同；照注释实现会得到「删除尚未入队的新值」的错误策略。
- **建议**：重写注释：`o` 是**已满的容器**，`fn` 是「腾出空间后重新提交」的动作；并补各实现的预期作用对象。

### [轻微][存量] `DiscardOverSizePolicy` 空实现没有「有意 no-op」说明

- **位置**：`f_base/src/OverSizePolicy.cj:36`
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §3（有意的 Null Object 必须有注释说明为什么可以空）
- **证据**：静态确定 —— 方法体为 `{}`，`fn` 与 `o` 都被丢弃，类上无注释。
- **描述**：与 `AbortOverSizePolicy`、`CallerRunsOverSizePolicy` 并列时，读者无法判断空实现是「刻意丢弃」还是「忘了写」。
- **建议**：补 `// 有意丢弃：满则丢新值（fn 不执行），与 Java ThreadPoolExecutor.DiscardPolicy 同义`。

### [轻微][存量] `StringGenerator` 内部重复逻辑（`reset`/`clear`、三处 replace、removeFirst/removeLast）

- **位置**：`f_base/src/StringGenerator.cj:35-38` 与 `:133-136`（完全相同）；`:178-188` / `:215-225` / `:235-245`（11 行拼接体逐行相同）；`:137-143` 与 `:144-150`（只差取下标调用）
- **来源**：存量（`git blame` → `4be871f2f`）
- **判据**：review-checklist §2（表现形式不同的重复逻辑）
- **证据**：静态确定 —— 逐行比对函数体的「输入-输出-副作用」摘要一致。
- **描述**：`replace` 的三份拼接体已是「改一处必须改三处」的状态（本轮已在其中发现空串死循环与边界问题，需三处同改）；`reset` 与 `clear` 是同一语义的两个名字。
- **建议**：抽 `private func spliceAt(idx: Int64, oldSize: Int64, newBytes: Array<Byte>)`；`reset` 保留为 `clear` 的别名并在注释说明（或直接删 `reset`，确认无外部依赖后）。

### [轻微][存量] `Result` 的 5 个 prop 与 4 个 filter 方法同构，`ResultFilter` 又重写一遍

- **位置**：`f_base/src/Result.cj:25-66`（`isOk`/`isErr`/`isNoResult`/`withE`/`withValue`）、`:129-156`（4 个 `filterXxx()`）、`:238-286`（`ResultFilter.filter` 的等价判定）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2
- **证据**：静态确定 —— 每个成员都是「对 `this` 做一次变体归属判断 → Bool/自身/`NoResult`」。
- **描述**：`filterOk()` 与 `filterOk(predicate)` 的语义分散在两个类型里，新增变体时要改 9 处以上；`ResultFilter.filter` 的 `Ok`/`Err` 两个分支也是同一段逻辑复制。
- **建议**：用 `isOk` 等 prop 实现 4 个 `filterXxx()`；`ResultFilter.filter` 抽 `keep(origin, flag, fn?)`，`Ok`/`Err` 各调一次。

### [轻微][存量] `@nameof` 缺空输入校验，与 `@nameValueOf` 不一致

- **位置**：`f_base/src/macros/nameof.cj:23-25`（对比 `:31-34`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §2（近似重复导致行为漂移）、§3（错误提示缺失）
- **证据**：静态确定 —— `nameValueOf` 有 `input.size == 0` 的 `diagReport` + 抛异常，`nameof` 直接 `quote(@nameValue($input)[0])`。
- **描述**：`@nameof()` 会展开成 `@nameValue()[0]`，报错点落在使用处而不是宏参数，错误文案也与 `nameValueOf` 不一致。两个宏共享「取最后一个 IDENTIFIER」的判定逻辑，却只有一份做了校验。
- **建议**：把「空输入 / 末 token 必须是 IDENTIFIER（或 `x.y` 形式）」抽成私有宏辅助函数，两个宏都调用。

### [轻微][存量] `PeekableIterator.isClosed()` 对非 `Resource` 迭代器恒为 `true`，`close()` 后仍可 `next()`

- **位置**：`f_base/src/Peekable.cj:46-51`（`case _ => true`）、`:22-30`（`next` 不看关闭状态）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `Resource.isClosed` 的语义是「资源是否已关闭」，这里被当成「底层不是 `Resource` 就视为无需关闭」。
- **描述**：包装普通 `Iterator` 时，`isClosed()` 在从未 `close()` 的情况下就返回 `true`，而迭代仍能继续；按 `Resource` 契约判断「已关闭就不要再读」的调用方会被误导。
- **建议**：加 `private var closed = false`，`close()` 置位并转发；`isClosed()` 返回 `closed || (itr is Resource && itr.isClosed())`，并让 `next()` 在 `closed` 时返回 `None`。

### [轻微][存量] `TypeInfos.withAnnotation` 的 `?? None` 是恒等无用表达式

- **位置**：`f_base/src/TypeInfos.cj:74`
- **来源**：存量（`git blame` → `aba9a64f8` 之前即为该写法）
- **判据**：review-checklist §1（无意义表达式 / 可读性）、§10
- **证据**：静态确定 —— `findAnnotation<A>()` 已返回 `Option<A>`，`?? None` 不改变结果。
- **描述**：容易被误读成「把 `null` 归一化」，实际是空操作；也掩盖了「`instanceFunction` 为 `None` 时等价于无注解」这一判断。
- **建议**：删掉 `?? None`，直接 `.isSome()`。

### [轻微][存量] `UnsafeData` / `UnsafeBytes` 缺「视图 vs 副本」「零拷贝」契约注释

- **位置**：`f_base/src/UnsafeData.cj:24-29`（返回 `getRawArray()[0..size]` 视图）、`f_base/src/UnsafeBytes.cj:23-33`（`rawData()` 视图、`withRawData` 零拷贝）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §7（副本假象）、§11（契约未文档化）
- **证据**：静态确定 —— 已核 std 文档/源码：`Array[Range]` 返回**共享底层存储的切片**（`core_package_structs.md:1544` 示例：改原数组后切片内容随之变化），`String.rawData` 明示「不要修改返回数组」，`String.withRawData` 不做拷贝。
- **描述**：两个接口都没有注释，而其语义恰是「调用方拿到活视图」：① 对 `ArrayList` 做 `add`/`remove` 后，先前拿到的 `unsafeData()` 可能指向已替换的旧数组或与当前 `size` 脱节；② `unsafeUtf8(bytes)` 之后若复用/清空该数组（如 `ByteBuffer.clear()`），字符串内容会被后续写入改写——这是 `String` 不可变性的破口。仓内现有调用方（`f_codec/src/default/DefaultCodec.cj:808`、`f_data/src/json/JsonValue.cj:114`）传的都是新建数组，暂未触发（范围外提示，不占本轮统计）。
- **建议**：在接口上补注释「返回共享视图，生命周期内不得对底层容器扩缩容/复用该缓冲区；调用方需保证数组在字符串存活期间不被修改」，并在 `unsafeUtf8` 文档点名该前提。

### [轻微][存量] 测试用 `@Assert(true, cond)`，失败时没有任何可用信息

- **位置**：`f_base/src/StringGeneratorRune_test.cj:46`、`:68`
- **来源**：存量（`git blame` → `4f1a463c7`）
- **判据**：review-checklist §10（可维护性 / 可测试性）
- **证据**：静态确定 —— `Array<Byte>` 已实现 `Equatable<Array<Byte>>`（`core_package_structs.md:2014` 元素级相等），无需绕过断言。
- **描述**：`@Assert(true, a == b)` 的期望值恒为 `true`，失败时报 "expected true, actual false"，看不出哪段字节不匹配。
- **建议**：改成 `@Assert(expected.unsafeBytes(), gen.unsafeBytes())`；要更细的定位信息时打印两串十六进制（`toHex`）的差异下标。

### [轻微][存量] `ResultFilter` / `ResultMapper` 未配置规则时静默把有值分支降级

- **位置**：`f_base/src/Result.cj:238-286`（`ResultFilter.filter` 空配置 ⇒ 全部 `NoResult`）、`:291-295` + `:316-324`（`ResultMapper` 默认 `resultMap` 丢弃 `T` 只返回 `Ok`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §11（契约不清导致数据丢失）、§3
- **证据**：待确认 —— 属「设计意图不明」：没有文档说明「不设规则 = 全部过滤掉 / 全部映射为空壳」是否为预期。
- **描述**：`r.filter()` 不设任何条件时，`Ok(v)`/`Err(e)` 都变 `NoResult`（值被丢）；`r.mapper().map()` 不设 `result(f)` 时，`Ok(v)` 变裸 `Ok`（值被丢）。两处都是「少写一步就静默丢数据」，且没有断言或日志。
- **建议**：默认行为改为「原样返回」（无规则即恒等），或在方法注释写明默认语义；`ResultMapper.resultMap` 默认实现建议直接抛 `UnsupportedException`（漏配置是编程错误）。

### [轻微][存量] `TypeInfos.get(name)` 在锁内做反射注册表查找，且不缓存失败

- **位置**：`f_base/src/TypeInfos.cj:41-51`
- **来源**：存量（`git blame` → `aba9a64f8`）
- **判据**：review-checklist §6.2（锁内做耗时操作）、§12.2（临界区内容）
- **证据**：需实测 —— 临界区是一次 `TypeInfo.get(qualifiedName)`（全局注册表查找，量级取决于注册类型数）+ 一次 `ConcurrentHashMap` 写入；冷路径，但未注册的名字每次都要重新进锁并抛 `InfoNotFoundException`（无负缓存）。
- **描述**：若调用方按请求驱动地探测类型名（配置/注解/路由名），未命中路径会串行化所有线程，且每轮抛一次异常。是否成为实际热点取决于探测频次。
- **建议**：把 `TypeInfo.get` 调用挪到锁外（先构建再 `putIfAbsent`），并对确定不存在的结果做有界负缓存（`Map<String, Bool>` + 容量上限），或在文档约定「只用于已注册类型」。

### [轻微][存量] `TypeInfos` 残留注释掉的 `Types<T>` 缓存与「待支持」TODO

- **位置**：`f_base/src/TypeInfos.cj:24-27`（整段注释）、`:33-34`（`// Types<T>.INSTANCE` + `//待支持静态成员再改回使用Types`）
- **来源**：存量（`git blame` → 早于 `4be871f2f`）
- **判据**：review-checklist §1（兼容残留 / 注释死代码）、§3（TODO 占位）
- **证据**：静态确定 —— 注释块内无有效代码，`Types<T>` 在本文件中不存在。
- **描述**：注释掉的类与「待支持静态成员」的 TODO 长期留在主路径文件里，读者难以判断「静态成员是否已支持」。`get<T>()` 当前每次调用都重新 `TypeInfo.of<T>()`（无缓存），与注释描述的意图相反。
- **建议**：删除注释块；若「给 `get<T>()` 加缓存」仍是待办，转成 issue 或在方法上留一行含原因与前置条件的 TODO。

### [轻微][存量] `resource()` 与 `ResourceManager.call()` 是同一段 `try/finally close` 的两份实现

- **位置**：`f_base/src/resource.cj:18-24`（顶级函数）、`:31-38`（`ResourceManager.call`）
- **来源**：存量（`git blame -L 18,38` → `4be871f2fd`）
- **判据**：review-checklist §2（同文件内同语义实现）
- **证据**：静态确定 —— 两个函数体逐行对应：「取资源 → 在 `try` 里 `fn(res)` → `finally` 里 `res.close()`」，唯一差别是资源来源（参数 vs 字段）。`call` 里的 `resource.getOrThrow()` 完全可换成 `resource(res, fn)`。
- **描述**：两份实现目前行为一致，但 `close` 的调用时机、异常传播策略（`close` 异常覆盖 `fn` 异常、未做 suppressed）只要改一处就会漂移。README `:384-392` 把两者差异定义为「资源来源不同」，无语义差异。
- **建议**：`call` 改为 `resource(resource.getOrThrow(), fn)`；若要保留两份，至少把 `try/finally` 抽成私有辅助。

### [轻微][存量] `resetAndRegisterSignalHandler` 三个重载各自内联「reset + 注册」，未复用同文件已有的注册重载

- **位置**：`f_base/src/signal.cj:92-95`、`:97-102`、`:104-107`（对照 `:77-89` 的三个 `registerSignalHandler`）
- **来源**：存量（`git blame -L 91,107` → `91978212cc` / `562abf068b`）
- **判据**：review-checklist §2（换控制流的重复逻辑）
- **证据**：静态确定 —— `:97-102` 的 `for(signal in signals){ registerSignalHandler(signal, handler) }` 与 `:81-85` 逐字相同；`:92-95` 的 `resetSignalHandler(signals); registerSignalHandler(signals){_ => handler()}` 与 `:77-79` + reset 的组合相同；`:104-107` 同理。
- **描述**：三份副本行为一致，但包装闭包 `{_ => handler()}` 出现 4 次（`:78`、`:88`、`:94`、`:106`），后续调整「返回 `false`」的语义或去重策略时容易漏改。
- **建议**：统一实现为「reset 后转调对应的 `registerSignalHandler` 重载」，把 `{_ => handler()}` 收敛到一处；若担心多一层间接，注释说明「保持与 register 重载同步」。

### [轻微][存量] `ResourceManager` 的 `Option<R>` 字段在 `init` 后恒为 `Some`，且 `struct` 可复制会带来同一资源被多个副本 `close`

- **位置**：`f_base/src/resource.cj:25-39`（`private var resource = None<R>` + `init` 里直接赋值 + `call` 里 `getOrThrow()`）
- **来源**：存量（`git blame -L 25,39` → `4be871f2fd`）
- **判据**：review-checklist §1（恒真分支）、§10（值 / 引用语义、可读性）
- **证据**：静态确定 —— `resource` 只有 `init` 一处写入（`resource = new()`），构造成功后不可能是 `None`，`getOrThrow()` 的 `None` 分支不可达；`ResourceManager` 是 `struct`，按值复制后两个副本持有同一个 `R` 引用，各自 `call` 一次即对同一资源 `close()` 两次（README `:389-390` 只声明「同一个实例第二次 call 会拿到已关闭的资源」，未覆盖「复制出第二个实例」）。
- **描述**：`Option` 包装没有换来任何状态能力（既不支持重置，也不支持懒初始化），只增加一层不可达分支；复制语义则把「一次性使用」的错误从「第二次 call」扩大到「两个变量各 call 一次」，`close` 非幂等时会二次关闭。
- **建议**：改成 `private let resource: R`（去掉 `Option` 与 `getOrThrow`）；若确需一次性语义，加 `closed: Bool` 或 `call` 末尾置空并让第二次调用抛 `IllegalStateException`，把契约从文档搬到运行时。

### [轻微][存量] 关机窗口内新注册的 `atExit` 永远不会执行，且无「已关机」标记

- **位置**：`f_base/src/signal.cj:48-59`（`atExit` 只登记）与 `:60-68`（`onExit` 执行完即返回，随后 `:44` `exit(0)`）
- **来源**：存量（`git blame` → `91978212cc` / `562abf068b`）
- **判据**：review-checklist §11（检查-然后-写入 / 时序缺口）、§12.1
- **证据**：静态确定 —— `onExit` 迭代 `callbacks` 时持锁，其它线程的 `atExit` 会阻塞到迭代结束；迭代结束后 `onExit` 返回、`exit(0)` 立即终止进程，刚登记进 `TreeMap` 的条目不会再被遍历，也没有任何提示。
- **描述**：典型触发场景是某个清理回调间接导致另一组件注册（例如关闭顺序中后者才被初始化）；该组件以为「已登记，退出时会收尾」，实际永远不会被调用，属静默丢失。
- **建议**：加 `private static var closed = false`，`onExit` 开始时置位，`atExit` 在 `closed` 时直接执行回调（或抛 `IllegalStateException`）；配合「锁外执行回调」的快照方案，窗口可缩到最小。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下全部无改前/改后对照数据，`证据状态` 均为 `无基线（待验证，不进 tasks）`。

### [堆内存] 空集合工厂每次调用都新建实例

- **现状**：`EmptySet/EmptyMap/EmptyList/EmptyCollection/EmptyIterator/EmptyEquatableCollection.instance()` 每次 `new` 一个仅含零字段的对象（`EmptyCollections.cj:30-32, 141-143, 163-165, 349-351, 401-403, 438-440`）。高频路径是 `get(k) ?? EmptyList<T>.instance()`（如 `f_llm/src/agents/AgentEventData.cj:42`）与 `iterator()` 内的 `EmptyIterator<T>.instance()`（每次开始迭代一次）。
- **方案**：改为每类型共享单例（对应文件里被注释掉的 `public static let instance` 就是原设计）。泛型类不能声明泛型静态字段时，退而求其次：把 `iterator()` 的返回值改成 `OptionIterator(None)` 复用，或让调用方直接用空 `ArrayList`。
- **预期**：每次未命中少 1 个对象（16–24B 级），量级取决于未命中次数，未测。
- **代价**：单例需注意线程安全（这些对象不可变，安全）；泛型静态字段可能不被语言支持。
- **验证**：100 万次未命中循环下 `getAllocatedHeapSize()` 的分配量对照（`-O2`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `Iterator.toArray()` 经 `ArrayList` 再切片，多一次全量拷贝

- **现状**：`ExtendIterator.cj:46-48` 先 `toArrayList()`（多次扩容复制）再 `unsafeData()`（`UnsafeData.cj:25-29` 里 `getRawArray()[0..size]` 再复制一份精确长度数组）。
- **方案**：`collect` 阶段预估容量（若迭代器可 `size`），或改为两趟：先计数再填 `Array`（仅当迭代器可重复遍历）。
- **预期**：峰值多占 1 份 n×sizeof(T)，拷贝次数从 ~2 次降到 1 次；具体占比未测。
- **代价**：两趟遍历不适用于一次性迭代器；API 语义不变。
- **验证**：`cjpm bench` 对 100 万元素 `toArray()` 的耗时/分配量对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每个任务的 `local` 表从 `HashMap` 起步，单个 local 也付整表成本

- **现状**：`f_base/src/FutureTask.cj:96-106` 首次 `writeLocalRaw` 建 `HashMap`（注释给出的实测：同尺寸 `HashMap` 构造 0.42~0.55µs、空 `ConcurrentHashMap` 3.6~5.2µs）；每个任务最多一张表，元素数通常 1~2，`HashMap` 的桶数组对 1~2 项明显过量。
- **方案**：单元素时用「键 + 值」两个字段直存，第 2 个 local 写入时才升级为 `HashMap`（`?Any` 的 box 可同时承载值）；或改用有序小数组线性查找（n ≤ 8 时快于哈希）。
- **预期**：每次首次写入省一个 `HashMap`（约 0.4µs + 桶数组），常驻堆按「活跃任务数 × 表开销」下降；具体字节数需按活跃任务数实测。
- **代价**：状态机变复杂（None / 单槽 / map 三态），三条读写路径都要覆盖；收益依赖「每任务 local 数」分布。
- **验证**：多轮负载下 `getAllocatedHeapSize()` + RSS + 活跃任务数计数是否达到有界稳态；`cjprof heap` 看 `HashMap` 分配占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `StringGenerator.reverse()` 整串副本 + 每个 Rune 一个临时 String

- **现状**：`reverse()`（`StringGenerator.cj:250-259`）先 `toString()` 复制整段字节（`fromUtf8Unchecked` 内部 `clone`，已核 std 源码），再对每个 Rune 调 `rune.toString().unsafeBytes()` 分配一个 1–4 字节的临时 `String` + `Array`。缓冲区 n 字节、Rune 数 m 时，一次 reverse 的额外分配约 `n + m×(16~40) B`（头开销为估算，需实测）。
- **方案**：不做 `toString()` 副本，直接在 `utf8` 缓冲区上从尾部向前扫描 UTF-8 首字节定位字符边界（`(b & 0xC0) != 0x80`），用固定的 4 字节栈上数组做中转倒排。
- **预期**：额外堆分配从 `O(n + m)` 降到 `O(1)`（不含结果缓冲本身）；峰值内存少一份与缓冲区同大的副本。
- **代价**：需手写 UTF-8 边界判定（约 20 行）；非法 UTF-8（由 `substring` 产生）时的行为需定义；实现复杂度上升。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 对 10KB/1MB 中文串跑 `cjpm bench -O2`，给中位数与 P95；补「ASCII/2/3/4 字节混合串 reverse 再 reverse == 原串」用例。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `TypeMemberInfos` 六套缓存各自遍历类链，可并为一次扫描

- **现状**：6 个 getter（`:23/:60/:97/:137/:177/:217`）在首次未命中时各自沿 `superClass` 链遍历一次、各建一个 `HashMap`、各建一个闭包；一个类型首次被反射时最多 6 次类链遍历 + 6 个容器 + 6 个闭包对象。缓存常驻（键为 `TypeInfo`，数量与进程内类型数同阶）。
- **方案**：用一个 `ConcurrentHashMap<TypeInfo, TypeMembers>`，`TypeMembers` 里放 6 个不可变视图（`HashMap` 建成后不再改），一次类链遍历同时填充 6 类成员；顺带修掉「先发布后填充」与「闭包捕获错变量」两个缺陷。
- **预期**：首次反射的类链遍历次数 6→1，闭包与中间对象减少 5/6；稳态内存条目数不变（6 份 map 收进 1 个 record）。
- **代价**：`TypeInfo` 冷路径改造，需回归 `f_bean`/`f_data` 的属性查找行为；record 一次性构建变重（首 miss 延迟略升）。
- **验证**：`cjprof record` 跑 `f_bean` 启动 + `f_data` 序列化场景，看 `getStaticPropertyMap` 系自耗时；`getAllocatedHeapSize()` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 枚举 `hashCode()` 用字符串插值（`Arch` / `OS` 同一写法）

- **现状**：`Arch.cj:23-25` 与 `OS.cj:97-99` 都实现为 `'fountain::f_base.<Type>.${this}'.hashCode()`——每次算 hash 都要构造一个 20~30 字符的 `String`（插值再调 `toString()`，`OS` 侧 `:74-84` 还是 7 分支 `match`）再做一次 UTF-8 字符串哈希；每次调用至少 1 个 `String` 临时对象（23~25 字节 + 头部）。
- **方案**：改为常量映射——`match (this) { case Linux => 1; case Windows => 2; ... }`（或 `ordinal`），保持与 `==` 一致；`toString()` 可直接复用枚举默认实现。
- **预期**：单次 `hashCode` 由「1 次分配 + 1 次字符串遍历」降为纯分支返回；量级取决于把这些枚举当 map key 的调用次数（仓内未见热点调用）。
- **代价**：哈希值与字符串哈希解耦（枚举哈希本就不应持久化，无兼容要求）。
- **验证**：`cjpm bench -O2` 对两种类型各做 1e7 次循环取中位数；`cjprof` 看分配计数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Integer.to<T>()` 的运行时类型分派

- **现状**：`ExtendNumber.cj:119-132` 等 8 处用 `match (None<T>)` 做最多 8 次运行期类型判断，并把结果装箱进 `Any` 再 `as T` 回转。
- **方案**：若真有调用方，改为显式具名转换（`toInt8/toInt16/...`）或按 `TypeInfo` 缓存分派函数。
- **预期**：省掉 `Any` 装箱与最多 8 次类型测试；当前全仓无调用方，收益为 0。
- **代价**：API 扩张。
- **验证**：先确认有外部调用方，再测单次转换耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `AbstractInheritedTaskLocal.hashCode()` 只取 owner 任务 id，同一任务下所有 local 落同一桶

- **现状**：`FutureTask.cj:335-337`（`hashCode = task.hashCode()`）+ `:338-340`（`==` 用 `refEq`）。一个任务创建 n 个 local 时，任务 `local` 表（`HashMap<AbstractInheritedTaskLocal, Any>`）的 n 个键全部哈希相同 ⇒ 单桶线性链，`readLocalRaw`/`writeLocalRaw` 每次 O(n)。
- **方案**：`hashCode` 混入 local 自身 id（与 `nextTaskId` 同法新增 `static let nextLocalId = AtomicInt64(0)`），保持「相等 ⇒ 同哈希」（`refEq` 相等即同一对象，恒成立）。
- **预期**：n 个 local 的查表从 O(n) 降为 O(1)；n 典型值（每任务 1~5）下收益有限，n 大时才显著。
- **代价**：每个 local 多 8 字节 + 一次原子自增；`hashCode` 语义变化（仅进程内使用）。
- **验证**：构造单任务 1/8/64 个 local 的微基准，测 `getLocal` 中位数 + 桶链长度埋点。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 合并 `StringGenerator` 三处 replace 拼接体与 `remove` 的多次搬移

- **现状**：`replace`/`replaceFirst`/`replaceLast` 各写一遍 11 行的三分支拼接（`:178-188`、`:215-225`、`:235-245`）；`remove` 对每个命中区间调一次 `ArrayList.remove(range)`，m 个命中时搬移量为 `O(n·m)`，另外先收集 `ArrayList<Range>` 再做第二趟。
- **方案**：抽出私有 `spliceAt(idx: Int64, oldSize: Int64, newBytes: Array<Byte>)`；`remove` 改成单趟「读指针/写指针压紧」（O(n) 一趟完成，免去 `torm` 与 m 次搬移）。
- **预期**：`remove` 从 `O(n·m)` 降到 `O(n)`（复杂度是静态事实，收益幅度待测）；三处拼接体合掉约 20 行重复代码，消除漂移风险。
- **代价**：需保证 `spliceAt` 对三分支（等长/变长/变短）逐字节等价，补等价性用例；压紧实现要处理 UTF-8 字节不变式（按字节压紧天然保持）。
- **验证**：`cjpm bench -O2`，输入 10KB 文本 + 100 个命中位置，记录 remove 前后耗时中位数；同时跑现有 51 个使用方的 `cjpm test` 回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `mcopy` 在小块写入路径上逐次跨 CFFI 边界，可评估按批合并

- **现状**：`mcopy`（`f_base/src/native.cj:40-43`）是对 `memcpy` 的薄封装，已加 `@FastNative`；下游按「每条记录一次」调用（`f_io/src/BytePointerStream.cj:103` 的 `access`、`f_io/src/SegmentedLog.cj:767` 的追加写）。每次调用的固定成本 = 一次 FFI 边界 + `memcpy` 本身（小 size 时以边界成本为主）。
- **方案**：在写入侧把同一批小记录聚合到连续缓冲区后一次 `mcopy`（`SegmentedLog` 按段批量提交），或对固定小 size 用仓颉侧 `Array` 拷贝 + 一次 `mcopy` 替代多次调用。
- **预期**：若单次 FFI 开销在 10~30ns 量级、每批 16 条，理论可省 90% 边界调用；端到端收益取决于写入频率与 `memcpy` 占比，**当前无数据**。
- **代价**：写入延迟上升（需攒批）、崩溃时丢失未提交批次、`SegmentedLog` 的「写前拒绝超长记录」逻辑需跟着改。
- **验证**：`cjpm bench -O2` 对照「逐条 mcopy vs 批量 mcopy」，同机器同输入（1 KiB 记录 × 100 万条、单线程/4 线程各一组），取中位数与 P95；`cjprof` 确认 `mcopy` 的 self time 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 空集合工厂的每次分配在未命中路径上占比可观 | `EmptyCollections.cj:30-32` 等 | 分配量 / 未命中次数 | 计数埋点 + `getAllocatedHeapSize()`，跑 100 万次 `get ?? EmptyList.instance()` |
| 2 | `toArray()` 的双拷贝是批量转换的主要开销 | `ExtendIterator.cj:46-48` | 单次 vs 两次拷贝耗时 | `cjpm bench -O2`，100 万元素，中位数 |
| 3 | 枚举 `hashCode` 字符串拼接在 map key 场景显著（`Arch`） | `Arch.cj:23-25` | 单次哈希耗时占比 | 100 万次 HashMap 插入，`cjprof record` |
| 4 | `CpuFeatures.hasSse41` 每次访问都读 `/proc/cpuinfo` | `CpuFeatures.cj:29-54` | 调用频次 | 全仓仅 `f_jit/src/backend/X86Lower.cj:62` 初始化调用一次，**当前不构成热点**；若未来进热路径需加 `static let` 缓存，届时再测 |
| 5 | `Integer.to<T>()` 的 `Any` 装箱 + 类型分派在外部热路径偏贵 | `ExtendNumber.cj:119-132` | 外部调用方的调用频次与耗时 | 先确认调用方，再分段计时 |
| 6 | `OS.hashCode` 的字符串插值是热点（若某业务把 `OS` 当 map key） | `OS.cj:97` | 自耗时占比、调用次数 | `cjprof record` 跑 10 分钟稳态负载，输入为既有业务流量；同时统计 `OS.hashCode` 调用次数 |
| 7 | `HashMap`/`HashSet` 迭代顺序影响 `HashBuilder` 哈希一致性 | `HashBuilder.cj:109-124` | 同内容不同插入历史的两张 map 的遍历序列 | 写用例：相同 1k 键、不同插入顺序（含中途删除），比对 `append(map).build()` 结果是否一致 |
| 8 | `shutdown` 子树递归的深度在真实用法中不足以构成栈风险 | `FutureTask.cj:177-195` | 任务树最大深度 | 在 `shutdownCurrentSubThreads` 加深度计数埋点，跑嵌套派生任务的用例（深度 1/100/1000） |
| 9 | `StringGenerator.append`/`indexOf` 在 SQL 拼接主路径占比高 | `StringGenerator.cj:45-52,104-110` | 自耗时占比、调用次数 | `cjprof record` 跑 f_orm 批量查询（1k/10k 条），看 `unsafeData`/`add(all:)` 的 self time |
| 10 | `remove` 的 `O(n·m)` 在真实文本上已可见 | `StringGenerator.cj:151-166` | 命中最多个数 m 的分布 | 埋点统计 m 与 n，或构造 100 命中用例跑 bench |
| 11 | `TypeInfos.get(name)` 冷 miss 时持锁做反射查找会串行化 | `TypeInfos.cj:41-51` | 锁等待时长、miss 频次 | 8 线程反复查未注册名，`cjprof` + 线程状态（BLOCKED）采样 |
| 12 | `StringGenerator.reverse` 的分配对 GC 有可见影响 | `StringGenerator.cj:250-259` | `getAllocatedHeapSize()` 前后差、GC 次数 | 1MB 中文串 reverse 1e4 次，读分配量 + GC 统计 |
| 13 | `mcopy` 的 FFI 边界成本在 `SegmentedLog` 追加路径上占比可观 | `native.cj:40`、`f_io/src/SegmentedLog.cj:767` | `mcopy` 的 self time 占比、单次调用次数 | `cjprof record` 跑 100 万条 1 KiB 追加，`cjprof report` 看 `mcopy` 与 `memcpy` 的 self 占比；同场景用分段计时统计调用次数 |
| 14 | 关机时 `onExit` 的总耗时随注册条目线性增长，长尾可能超过容器 `terminationGracePeriod` | `signal.cj:60-68` | 条目数 × 单回调耗时的分布 | 在 `onExit` 前后打点（`MonoTime.now()`），跑真实应用 `kill -15`，统计 P95 退出耗时与条目数 |

## 文件覆盖

> 与 `{workdir}/files/f_base.txt` 一一对应（`plan.json` 记录 `file_count = 52`，分 4 个部分：15 + 15 + 15 + 7）。清单内无 `.md`；模块 `README.md` / `README_en.md` 未进清单，本轮仅在被引用的段落（`:384-392`、`:506`、`:722`、`:735-745`）上作 §14 契约核对，未做 §13 全文一致性审计。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_base/src/Arch.cj` | .cj | ✅ | `hashCode` 字符串插值 → 优化方案 [CPU] |
| 2 | `f_base/src/BaseCommand.cj` | .cj | ✅ | 无问题 |
| 3 | `f_base/src/BaseException.cj` | .cj | ✅ | 自挂递归（一般）、未用 import、`suppressed` 暴露（轻微） |
| 4 | `f_base/src/Bucket.cj` | .cj | ✅ | 空 marker 接口，非空实现 |
| 5 | `f_base/src/Comparator.cj` | .cj | ✅ | 无问题 |
| 6 | `f_base/src/Comparator_test.cj` | .cj | ✅ | 断言未用被测对象（轻微） |
| 7 | `f_base/src/Console.cj` | .cj | ✅ | 重复/未用 import（轻微） |
| 8 | `f_base/src/CpuFeatures.cj` | .cj | ✅ | 注释与实现范围不符（轻微）；`hasSse41` 频次待验证 |
| 9 | `f_base/src/CpuFeatures_test.cj` | .cj | ✅ | 缺版权头（一般）、断言恒真（轻微） |
| 10 | `f_base/src/EmptyCollections.cj` | .cj | ✅ | `contains(all!)` 恒假（一般）、entryView setter（轻微） |
| 11 | `f_base/src/Equaler.cj` | .cj | ✅ | 无问题 |
| 12 | `f_base/src/ExtendArray.cj` | .cj | ✅ | 零值默认值（严重）、三个边界分支（一般） |
| 13 | `f_base/src/ExtendIterator.cj` | .cj | ✅ | `groupBy` 恒空（严重）、`AsyncIterator`（一般）、`flatten` 文案（轻微） |
| 14 | `f_base/src/ExtendNumber.cj` | .cj | ✅ | `to<T>()` 加宽错误（一般）、8 份复制（轻微） |
| 15 | `f_base/src/ExtendOption.cj` | .cj | ✅ | `+`/`*` 反序（一般）、`map` 遮蔽 std（一般）、12 组复制（轻微） |
| 16 | `f_base/src/ExtendRange.cj` | .cj | ✅ | 无问题 |
| 17 | `f_base/src/ExtendRune.cj` | .cj | ✅ | 取负溢出（一般）、8 份重载复制（轻微） |
| 18 | `f_base/src/ExtendString.cj` | .cj | ✅ | 与 std `trimAscii` 近似（轻微） |
| 19 | `f_base/src/ExtendThreadLocal.cj` | .cj | ✅ | 无问题 |
| 20 | `f_base/src/FutureTask.cj` | .cj | ✅ | `initLock` 死锁（严重）、`set`/`get` 不对称、`shutdown` 误伤（一般）；本地表/hashCode 优化 |
| 21 | `f_base/src/FutureTask_test.cj` | .cj | ✅ | 未用 import、断言过松（轻微） |
| 22 | `f_base/src/HashBuilder.cj` | .cj | ✅ | `Hashable` 副作用、集合顺序依赖（一般）；两处复制（轻微） |
| 23 | `f_base/src/Help.cj` | .cj | ✅ | 内部死代码（轻微） |
| 24 | `f_base/src/LocalComparable.cj` | .cj | ✅ | 接口默认成员为刻意保留 |
| 25 | `f_base/src/LocalEquatable.cj` | .cj | ✅ | 接口默认成员为刻意保留 |
| 26 | `f_base/src/NoneOrder.cj` | .cj | ✅ | 无问题 |
| 27 | `f_base/src/OS.cj` | .cj | ✅ | 手写 `==`/`toString`（轻微）；`hashCode` 优化 |
| 28 | `f_base/src/Operators.cj` | .cj | ✅ | `Cmpable`/`Eqable` 零引用（可见性建议） |
| 29 | `f_base/src/OptionComparable.cj` | .cj | ✅ | 无问题 |
| 30 | `f_base/src/Options.cj` | .cj | ✅ | 同义 API、泛型 `R`、无消息异常、失败语义相反（轻微） |
| 31 | `f_base/src/OverSizeException.cj` | .cj | ✅ | 无问题 |
| 32 | `f_base/src/OverSizePolicy.cj` | .cj | ✅ | 无反馈通道、超时静默丢弃（一般）；注释/空实现（轻微） |
| 33 | `f_base/src/Peekable.cj` | .cj | ✅ | `isClosed` 恒真（轻微） |
| 34 | `f_base/src/Result.cj` | .cj | ✅ | 三方法丢值（一般）；同构 prop/filter（轻微） |
| 35 | `f_base/src/SingleIterable.cj` | .cj | ✅ | 无问题 |
| 36 | `f_base/src/StringGenerator.cj` | .cj | ✅ | 空串死循环（严重）、漏删下标 0、`checkIndex` 过严、`substring` 边界（一般）；内部重复（轻微） |
| 37 | `f_base/src/StringGeneratorRune_test.cj` | .cj | ✅ | `@Assert(true, cond)`（轻微） |
| 38 | `f_base/src/TypeInfos.cj` | .cj | ✅ | `parseParameterTypes` 缺失（一般）；锁内查找、注释残留（轻微） |
| 39 | `f_base/src/TypeInfos_test.cj` | .cj | ✅ | 无问题 |
| 40 | `f_base/src/TypeMemberInfos.cj` | .cj | ✅ | 先发布后填充（严重）、闭包捕获错变量（一般） |
| 41 | `f_base/src/UnsafeBytes.cj` | .cj | ✅ | 缺视图/零拷贝契约注释（轻微） |
| 42 | `f_base/src/UnsafeData.cj` | .cj | ✅ | 缺视图契约注释（轻微） |
| 43 | `f_base/src/WorkerStrategy.cj` | .cj | ✅ | 无问题 |
| 44 | `f_base/src/hex.cj` | .cj | ✅ | `fromHex` 未校验（一般） |
| 45 | `f_base/src/macros/nameof.cj` | .cj | ✅ | `@nameof` 缺校验（轻微） |
| 46 | `f_base/src/native.cj` | .cj | ✅ | `MEM_PAGE_SIZE` 平台错误（一般）；`mcopy` 优化 |
| 47 | `f_base/src/nextPowerOf2.cj` | .cj | ✅ | 未校验溢出（一般） |
| 48 | `f_base/src/public_std_imports.cj` | .cj | ✅ | 5 个 `public import`，无冲突证据 |
| 49 | `f_base/src/resource.cj` | .cj | ✅ | 两份 `try/finally`（轻微）；`Option` 字段/复制语义（轻微） |
| 50 | `f_base/src/signal.cj` | .cj | ✅ | 无异常隔离（严重）、锁内回调、无注销、Windows 空实现（一般）；两处重复/关机窗口（轻微） |
| 51 | `f_base/src/unsafeZeroValue.cj` | .cj | ✅ | 零值 null 引用（严重，与 `ExtendArray.grow` 合并） |
| 52 | `f_base/src/zero_timer.cj` | .cj | ✅ | `ZERO_TIMER` 为 null `Timer`（严重，同上合并；对外可达不判死代码） |

合计：`.cj` 52 个 / `.md` 0 个 / 共 52 个，全部读完（`.md` 未分派，见上说明）。

## 覆盖自检

> 命中数为 4 个部分之和，已扣除合并条目（`unsafeZeroValue` 跨部分合并 −1）。全部维度均出现，命中 0 条者说明做了什么检查才排除。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 31 | 并入后：正确性 18（`groupBy` 恒空、`+`/`*` 反序、`to<T>` 加宽、`grow` 边界、`contains(all!)`、`set`/`get` 不对称、Rune 极值、`remove` 漏删/死循环、`checkIndex`、`substring`、`fromHex`、`transpose` 语义、继承成员缺失、`nextPowerOf2` 溢出、`MEM_PAGE_SIZE`、零点空引用、Windows 能力缺失、关机窗口）；设计 8（`Option.map` 遮蔽 std、`suppressed` 暴露、`HashBuilder` 的 `Hashable`、`shutdown` 作用域、`OverSizePolicy` 反馈、`Result` 三方法丢值、`PeekableIterator.isClosed`、`ResourceManager` 复制语义）；可读性 5（拼写、`flatten` 文案、`Options` 异常无消息、`OS` 冗余实现、`TypeInfos` 注释残留）；安全性 0（本模块无外部输入解析、无 SQL/注入面、无硬编码凭据；`unsafe` 面已在 `unsafeZeroValue`、`substring`、`UnsafeData/Bytes` 三条中覆盖） |
| §1 死代码 | 8 | 逐符号机械过：`private`（`BaseException.printStackTrace` 私有重载、`ExtendArray.check`、`CpuFeatures.detectSse41`、`EmptyMapEntryView.k`、`HashBuilder.append(Map)`、`TypeMemberInfos` 6 个静态 map、`StringGenerator` 的 `utf8`/`checkIndex`、`TypeInfos.INFOS`/`MUTEX`、`hexmap` 等）均有引用；`internal` 顶层 `FuncMeta` 有调用者、其 `public` 成员是接口实现（豁免）；`Help` 是包内 `abstract sealed class` 且全仓零引用；`protected` 仅 `cancelSelf`（被 `shutdown` 调用且被唯一子类覆盖，不判）。命中：`ExtendOption.map`、`StringWriter`/`ConsoleReader` 未用 import、`Comparator_test` 未读局部变量、`Help`、`HashBuilder` 私有 `Map` 重载、`HashBuilder` 6 个不可达 `match` 臂、`FutureTask_test` 未用 import、`signal.cj:45` 的 `false`。对外可达 public 零引用（`EmptyIterable`、`AsyncIterator`、`filterType`、`ZERO_TIMER`、`ResultFilter`、`@nameof`、`resource`、`Cmpable` 等）按硬原则一不判，仅 `Cmpable`/`Eqable` 单列可见性建议 |
| §2 重复逻辑 | 13 | 同文件两两比对 + 跨方法/跨文件比对，命中：`ExtendNumber` 8 份整数实现、`ExtendOption` 12 组运算符、`HashBuilder` 13 个标量 `append`、`HashBuilder` `Map`/`ConcurrentHashMap` 重载、`Options.isEmptyOrUnit`、`OS` 手写 `==`/`toString`、`ExtendString.trimAsciiBlanks` vs std `trimAscii`、`ExtendRune` 8 份重载、`TypeMemberInfos` 6 个 getter 同构、`StringGenerator` 内部三组、`Result` prop/filter/`ResultFilter`、`resource` vs `ResourceManager.call`、`resetAndRegisterSignalHandler` 3 份。未合并：`Comparator` 与 `Equaler` 返回类型/语义不同；`hex` 两函数、`Peekable.close/isClosed`、`OverSizePolicy` 各策略语义不同；接口默认成员（`LocalComparable`/`LocalEquatable`/`OptionComparable`）是刻意保留的模态分支 |
| §3 空实现 | 4 | 命中 `EmptyMapEntryView.value` setter（静默丢弃）、`DiscardOverSizePolicy.reject`（无注释）、`BlockingOverSizePolicy.reject` 的「未恢复」空分支（静默丢弃）、Windows `ExitCallbacks.atExit`/`toExitGracefully`（无注释）。其余 no-op 是 Null Object（`Empty*` 的 `remove`/`add`/`clear`/`sortBy`）或有意扩展点（`cancelSelf`，有注释且被覆盖）；`Bucket`、`Extend*Option` 是空 marker 接口，属约束用途；无 `TODO` 占位实现（`TypeInfos` 的 TODO 归 §1） |
| §4 栈溢出 | 1 | 命中 `BaseException.printStackTrace` 的 suppressed 自引用递归（互挂亦成环）。其余无递归：`nextPowerOf2` 递归最多 2 层；`shutdown → shutdownCurrentSubThreads` 深度 = 任务树深度（每层需新建线程、`parent` 构造期固定、树无环）；`TypeMemberInfos` 是 `while` + `superClass`（继承层数有限、不可自引用）；`printStackTrace` 的 `causedBy` 链只能由构造函数设置，成环不可行 |
| §5 OOM | 3 | 命中 `AsyncIterator` 每元素一线程（无界任务提交）、`StringGenerator.remove` 空搜索串时 `torm` 无界增长、`atExit` 注册表只增不减且强持有闭包。`grow` 的 `Array<T>(size)` 大小由调用方给定，属 API 目的；`subTasks` 已有界（`size >= 64` 剪枝，叶子任务不建桶）；`TypeInfos`/`TypeMemberInfos` 缓存键集是进程内已注册类型，规模有界 |
| §6.1 热点瓶颈 | 0 | `scope.md`「已有性能资料」为空，本轮未提供 `cjprof`/`cjpm bench` 数据；所有性能线索（枚举 `hashCode`、`to<T>` 分派、`toArray` 双拷贝、`mcopy`、`onExit` 耗时）已降级进「优化可行性方案 + 待验证假设」，不作发现 |
| §6.2 大粒度锁 | 3 | `FutureTask` 的 `initLock` 包住用户 `fn()`（临界区含父链遍历 + 回调 + 写入，与「严重」同源）、`TypeInfos.get(name)` 在 `Mutex` 内做 `TypeInfo.get` 且未命中不缓存、`signal.onExit` 的临界区含全部 `atexit()`。`subTasksLock` 是全局单锁但临界区只有 map 操作；`BlockingOverSizePolicy` 的锁只包 `condition.wait`，均不计 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get`、无批大小为 1 的窗口、无单消费者队列：`FutureTask` 的 `spawn` 是 fire-and-forget；`AsyncIterator` 的问题是「并发无界」而非「形式并发实际串行」（归 §5/§12.1）；`StringGenerator`/`Result*` 是单线程构建器 |
| §6.4 低效算法 | 1 | 命中 `StringGenerator.remove` 的 `O(n·m)`（m 次 `ArrayList.remove` + 先收集区间），已并入 [CPU] 优化方案。未命中：无嵌套循环匹配、无 `remove(at:0)` 当队列、无循环内字符串 `+`；`pruneFinishedChildren` 的 O(桶) 扫描是摊还登记路径；`nextPowerOf2` 是 O(1) 位运算 |
| §7 降堆内存方案 | 4 | 空集合工厂、`toArray` 双拷贝、任务 `local` 表三态、`reverse` 副本 + 临时串。`TypeMemberInfos` 六容器合并同时降分配，但主收益是 CPU（类链遍历 6→1），为避免同一方案跨维度重复计数只在 §8 计。全部无基线 |
| §8 降 CPU 方案 | 6 | 枚举 `hashCode`（`Arch`/`OS` 合并为 1 条）、`to<T>()` 类型分派、`InheritedTaskLocal.hashCode` 混入 local id、`TypeMemberInfos` 类链 6→1、`StringGenerator.remove`/三处 replace、`mcopy` 批量化。全部无基线 |
| §9 local mode 可行性 | 0 | `f_base/cjpm.toml` 已开 `--experimental --enable-local-mode`，但本模块函数内几乎无「创建即销毁」的大临时对象：`toArray` 的 `ArrayList` 原始数组经切片逃逸为返回值、`stringJoin`/`reverse`/`substring` 结果逃逸、`FutureTask` 对象跨线程逃逸、`HashBuilder` 地址被 `append` 返回、`resource`/`call`/`nextPowerOf2` 零分配。缺峰值内存数据，收益无法证明，不做改造建议 |
| §11 现有代码的 BUG（存量） | 47 | 计数为 4 个部分 §11 命中之和（8 + 20 + 11 + 9 = 48）扣除 `unsafeZeroValue` 跨部分合并 1 条；口径是各部分在 §11 登记的逻辑/边界/错误处理/资源/并发/契约类存量缺陷（重复逻辑与可维护性类登记在 §2/§1/§10，不在此重复计数）。本轮读到的 52 个文件全部按快照记为存量；逐方法核对了边界、空值、`Option` 不丢弃、异常路径、资源对称性。核对结论示例：`ExtendString.replace` 的 `indexOf` 返回 `Option<Int64>`（非 -1 哨兵），`None` 分支可达，无缺陷；`Options.isEmptyOrBlank` 的 `getOrThrow` 在 `isEmpty` 为 false 时必然 `Some`，无解包崩溃；`FutureTask` 登记/注销键一致（`parentTID` vs `Thread.currentThread.id` 分属父子两层） |
| §12 并发安全与锁粒度 | 9 | 共享点与同步手段已逐一列出：`FutureTask.subTasks` 全部访问在 `subTasksLock` 内、`local` 表全部访问在 `localLock` 内（含读）、`finished` 用 `AtomicBool`、`hasChildren` 线程封闭；`TypeInfos` 双检锁写法正确；`ExitCallbacks.callbacks` 由 `:37` 的 `Mutex` 保护但生命周期无界。判不安全的 9 处：`initLock` 内用户回调（死锁）、`shutdown` 作用域错位、`HashBuilder` 非幂等哈希、`TypeMemberInfos` 先发布后填充、`TypeMemberInfos` 闭包捕获、`BlockingOverSizePolicy` 条件等待不重查、`onExit` 锁内回调 + 反向锁序、`atExit` 无界持有、关机窗口检查-然后-写入 |
| §14 功能完备性与 README 覆盖 | 1 | `unsafeZeroValue` / `ZERO_TIMER` 的风险未在 KDoc 与 README 文档化（承诺源：README `:506` 只贴代码、README `:735-745` 未提 Windows 差异）。其余公开符号（`ExitCallbacks`、`registerSignalHandler` 系列、`resource`、`ResourceManager`、`nextPowerOf2`、`MEM_PAGE_SIZE`/`nullptr`/`mcopy`）在 README 均有条目；`f_base` README 未进文件清单，未做全文 §14 逐项对照 |
| 文件覆盖（§13 等） | 52/52 | 52 个 `.cj` 全部读完；清单无 `.md`，§13 文档一致性未单独成项（模块 `README.md`/`README_en.md` 仅在被引用段落上作契约核对） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 6 |
| 一般 | 27 |
| 轻微 | 39 |
| 优化方案（堆内存 / CPU） | 4 / 6 |

> 合并前 4 个部分合计 73 条发现；`unsafeZeroValue` 跨部分同根因合并 1 条（严重度由「严重 + 一般」取严为严重），合并后 72 条，全部为存量（快照模式无 diff）。存量 72 条默认只报不修，**是否纳入修复清单待用户决定**；优化方案 10 条与待验证假设 14 条不进修复清单。

## 总评

`f_base` 是「薄基础层」：类型工具（`Arch`/`Comparator`/`Equaler`/`Extend*`/空集合）、并发原语（`FutureTask`/`InheritedTaskLocal`）、unsafe 能力（`unsafeZeroValue`/`UnsafeBytes`/`native`）、进程退出编排（`signal`）与几个工具类（`StringGenerator`/`TypeInfos`/`TypeMemberInfos`）。整体风格统一、注释密度高（`FutureTask` 的并发决策逐条带编号与实测数据）、无可变全局状态的模块占多数，`unsafe` 面边界清晰。

**阻塞项（建议本轮必修）**：

1. `ExtendIterator.groupBy` 恒返回空 map —— 已被 `f_orm` 迁移链路（`SchemaFinderMediator`、`MysqlSchema.findIndexes`）依赖，会让迁移「成功但什么都不做」，且静默无日志。
2. `StringGenerator` 的空搜索串死循环（`remove` 伴随无界增长、`replace` 纯 CPU 挂死）—— 该类有 51 个使用方、是 SQL 拼接热路径，输入只要少一个占位符即触发。
3. `FutureTask` 在 `initLock` 内执行用户回调 —— 「回调内派生任务再对同一 local 求值」与「两个 local 反向取锁」都是确定性死锁，锁无超时；`FutureTask` 目前只被自身测试触发，风险实际落在下游。
4. `ExitCallbacks.onExit` 无异常隔离 —— 一次清理回调抛异常即跳过后续所有模块的收尾（DB/日志/池），异常还会穿出 `@C` 信号处理函数。
5. `TypeMemberInfos` 先发布后填充 —— 静态 `HashMap` 被并发读写，可能读到半成品或错乱桶链；同文件另有 3 处闭包捕获错变量导致继承成员永远查不到，属同一段结构复制 6 遍的漂移。
6. `unsafeZeroValue` 对引用类型产出 null 引用 —— `Array<Class>.grow(n)` 的默认值是最自然的用法，一读即崩；`ZERO_TIMER` 把这个坑固化成了公开常量。

**平台/契约风险（按目标平台决定优先级）**：`MEM_PAGE_SIZE` 在 macOS arm64 用 4096 而真实页 16 KiB，`msync` 会 `EINVAL` 且返回值被丢弃（若 macOS 是目标平台，应升为严重）；Windows 分支的 `atExit`/`toExitGracefully` 是静默空实现，而 `f_bean` 把它当唯一销毁路径；`nextPowerOf2`、`hex.fromHex`、`StringGenerator.substring`/`checkIndex`、`Result.mapError/flatten/transpose` 都是「对外 API 的边界契约未收口」。`TypeInfos.getGenericTypes` 依赖仓内不存在的 `parseParameterTypes`，需先跑一次 `cjpm build` 判断是「缺实现」还是「缺文件」，这条可能是阻塞项。

**可排期的清理**：`Help` 整个类是内部死代码（3 个 `public` 入口还因泛型无法推断而不可调用）；`HashBuilder` 的 14 个转发重载 + 私有 `Map` 重载可合并为 1 泛型 + 1 集合实现；`ExtendNumber` 8 份 / `ExtendOption` 12 组 / `ExtendRune` 8 份 / `TypeMemberInfos` 6 份复制都建议用宏或单一分派收口——本轮 3 个「同时错」的缺陷（`to<T>()` 加宽、`+`/`*` 反序、`Int*.Min` 取负）正是复制扩散的直接后果。`ExtendArray.grow` 的空数组与 0 次重复分支、`OverSizePolicy` 的反馈通道、`InheritedTaskLocal` 的读写对称性都属「一行改 + 一条断言」的范畴。

**欠账集中在测试**：52 个文件只有 5 个测试文件，且其中 3 个存在无效断言（恒真、未用被测对象、`@Assert(true, cond)`）、1 个缺版权头。`groupBy`、`grow`、`to<T>()`、`contains(all!)`、`Option` 运算符、`StringGenerator.remove/replace`、`TypeMemberInfos` 继承查询全部零覆盖——上述多数缺陷都能被一行断言拦住。

性能方面本轮不产出结论：`scope.md` 未提供 profile/bench，9 条优化方案全部标 `无基线（待验证，不进 tasks）`，另有 14 条待验证假设供下一轮补数据。可优先补的是 `StringGenerator`（使用方最多）与 `TypeMemberInfos`/`StringGenerator` 两条冷路径改造（顺带修并发与继承缺陷，收益可与缺陷修复合并验收）。
