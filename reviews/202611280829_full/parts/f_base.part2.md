# f_base 模块审查报告（第 2/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（全模块 52 个源文件；**本部分覆盖 15 个**：ExtendRange / ExtendRune / ExtendString / ExtendThreadLocal / FutureTask / FutureTask_test / HashBuilder / Help / LocalComparable / LocalEquatable / NoneOrder / OS / Operators / OptionComparable / Options，共 2417 行）
- **基线**：工作区快照（`sts/1.3.x`，`git status` 仅有本轮 `reviews/` 目录未跟踪；快照模式无 diff，本部分发现**全部记为「存量」**）
- **审查重点**：基础类型 / 并发原语 / unsafe 内存、死代码、重复逻辑、空实现、栈溢出、OOM、存量 BUG、并发安全与锁粒度
- **报告版本**：v1（部分报告，待主 Agent 合并为 `docs/review/f_base_review_20261128.md`）
- **说明**：本文件统计**只含第 2/4 部分**，合并时不要与其余三部分的数字直接相加覆盖。

## 发现

### [严重][存量] `getOrSet` / `getOrCompute` 在 `initLock` 内执行用户回调，可经「回调内派生任务并再对同一 local 求值」形成死锁

- **位置**：`f_base/src/FutureTask.cj:157-166`（`getOrComputeLocal` 的 `synchronized(local.initLock)` 包住 `fn()`）、`:143-151`（`getOrSetLocal` 同构）；锁对象定义 `:333`
- **来源**：存量（`git blame -L 153,167` → `254ef066e4` 2026-07-25 / `83b55f8744` 2026-10-11；快照模式无 diff）
- **判据**：review-checklist §12.1（死锁：锁内调用外部回调，回调再取同一把锁）、§6.2（锁内做用户代码）
- **证据**：静态确定 —— `fn()` 是调用方传入的 `() -> T`，整段执行都在 `local.initLock` 的临界区内；`getLocal` 会沿途取父任务 `localLock`、`setLocal` 取当前任务 `localLock`，锁序为 `initLock → task.localLock`，但**没有任何机制阻止 `fn()` 再去获取 `initLock`（同 local）或另一个 `initLock`（另一 local）**。
- **描述**：两条可达路径：
  1. **同 local、跨线程**：任务 A 调 `local.getOrCompute{f}`，A 持 `initLock` 执行 `f`；`f` 内 `FutureTask{...}.get()` 派生任务 B，B 也对同一 `local` 调 `getOrCompute`。B 沿父链查不到值（A 还没 `set`），进 `synchronized(local.initLock)` 阻塞；A 阻塞在 `B.get()` ⇒ 双方永久互等。递归式的「懒初始化内部再并行初始化同一资源」是常见写法。
  2. **跨 local、双线程反向**：线程 1 持 `L1.initLock` 的 `fn` 内调 `L2.getOrCompute`，线程 2 持 `L2.initLock` 的 `fn` 内调 `L1.getOrCompute` ⇒ 经典锁序反转。
  代码注释（`:329-332`）只论证了「同线程重入安全」（该结论成立，std `Mutex` 文档明确可重入），未覆盖上述跨线程路径；`Mutex` 无超时参数，一旦命中即永久挂起，属阻塞级故障。
- **建议**：把 `fn()` 移出锁——锁内只做「复查 + 登记计算中标记」，计算在锁外执行，第二个调用方等待该标记完成（`Condition` / 一次性 `Future`）；或退化为「允许多次计算、最后一次写入生效」并把该语义写进注释（去掉 `initLock`，与 `ThreadLocal.getOrCompute` 的行为对齐）。若保留现状，必须在注释与 README 里明确「`fn` 内不得派生任务、不得访问其它 `InheritedTaskLocal`」。

### [一般][存量] `InheritedTaskLocal.set` 在任务外回退写 owner，`get` 不回退 —— 在 main 线程 `set` 后自读恒为 `None`

- **位置**：`f_base/src/FutureTask.cj:349-359`（`writeTarget` + `set`）与 `:361-363`（`get`）
- **来源**：存量（`git blame -L 349,371` → `c89cb7cf9a` / `b7226c1785`，2026-10-11）
- **判据**：review-checklist §11（契约与实现不一致、静默丢值）、§10（正确性）
- **证据**：静态确定 —— `set` 走 `writeTarget()`：不在任务里时返回 owner（构造 local 的那个任务），把值写进 owner 的 `local` 表；`get` 走 `task.getLocal<T>(this)`，而 `getLocal`（`:118-130`）从 `currentTask.get()` 起沿父链上溯，**在 main 线程 `currentTask` 为 `None`，循环体一次都不执行，直接 `None<T>`**。同一个 local 的 `remove()` 也走 `writeTarget`，与 `set` 对称、与 `get` 不对称。
- **描述**：`FutureTask_test.cj:40-43` 正是支持「任务外先 `set`、任务内读」的用法（`local.set(5)` 在测试线程，任务内读到 5）。但同一个 API 在任务外 `set` 之后**自己读不回来**：
  ```cangjie
  let t = FutureTask<Int64>({ => 1 })
  let l = t.newLocal<Int64>()
  l.set(7)
  l.get()      // None —— 值其实写进了 t 的表
  ```
  调用方无法区分「没写进去」和「写了但读不到」，只能靠「必须在任务内读」这条未写进文档的隐含约定。
- **建议**：`get` 与 `set/remove` 采用同一解析规则：先沿 `currentTask` 父链查，全部未命中且当前不在任务里时回退到 owner 的 `readLocalRaw`；或反过来把 `set` 的 owner 回退收进一个显式 API（`seedForOwner`），保持 `get/set` 对称。补一条测试：任务外 `set` 后任务外 `get` 应得 `Some(7)`。

### [一般][存量] `AbstractFutureTask.shutdown()` 的「关子树」作用在**调用线程**而不是 `this` 的子树上

- **位置**：`f_base/src/FutureTask.cj:171-174`（`shutdown`）、`:177-195`（`shutdownCurrentSubThreads`，键取 `Thread.currentThread.id`，见 `:180-182`）
- **来源**：存量（`git blame -L 171,174` → `5905520079`，2026-10-11）
- **判据**：review-checklist §11（语义与命名不符）、§12.1（跨线程语义错误）
- **证据**：静态确定 —— 实例方法 `shutdown()` = `cancelSelf()` + `shutdownCurrentSubThreads()`；后者是 `static`，按**当前线程** id 从 `subTasks` 摘桶并逐个 `f.shutdown()`。在 self 线程调用等于「取消自己 + 取消我的子树」；在**其它线程**调用（例如 main 拿到 `taskA` 句柄后 `taskA.shutdown()`）则变成「取消 taskA（`future.cancel`）+ 摘掉 **main** 名下的桶」，会把 main 创建的、与 taskA 无关的其它子任务一起取消。
- **描述**：任务线程被 cancel 后其 `finally` 会自行清理子树，因此最终状态通常仍然正确，但**中间动作误伤了无关任务**：main 名下挂着的其它 `FutureTask`（例如一批后台任务）会被 `if(!f.finished.load()) f.shutdown()` 连带取消。方法名与签名（实例方法）让调用方无法预期这个副作用。
- **建议**：把子树清理拆成按 task 定位的 `shutdownSubTasksOf(task: AbstractFutureTask)`（桶键改为任务 id，或按 `parent` 链递归），`shutdown()` 只作用于 `this`；「关当前线程子树」保留为 `public static shutdownCurrentSubThreads()` 单独暴露。补一条测试：main 创建 A、B 两个任务，对 A 调 `shutdown()`，断言 B 未被取消。

### [一般][存量] `HashBuilder.hashCode()` 有副作用（清零内部状态）且非幂等，却声明实现 `Hashable`

- **位置**：`f_base/src/HashBuilder.cj:37-39`（`hashCode` 直接 `build()`）、`:32-36`（`build` 清零 `hashed`）、`:25`（`<: Hashable`）
- **来源**：存量（`git blame -L 32,39` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符：`Hashable` 要求哈希稳定）、§1（`hashCode` 读了就破坏状态）
- **证据**：静态确定 —— 第一次 `hashCode()` 返回累计值并把 `hashed` 置 0，第二次返回 0。仓内没有任何位置把 `HashBuilder` 当 `Hashable` 使用（全仓 `HashBuilder` 的 30+ 处调用都是 `append(...).build()` / `append(...)`），该 `Hashable` 声明没有消费者。
- **描述**：`Hashable` 的契约是「同一对象哈希稳定，相等对象哈希相同」。现在 `HashBuilder` 若被放进 `HashSet`/`HashMap`（或作为 `@DataAssist` 字段被 `append`），第一次求哈希后位置就失效，且 `HashBuilder` 未重写 `==`（身份相等），两个「内容相同」的 builder 哈希也不同。这是一条**已声明但不可用**的接口。
- **建议**：优先删除 `<: Hashable`（无内部依赖，属公开契约变更，需确认无下游使用）；若要保留，`hashCode()` 改为只读返回 `hashed`（不清零），把「清零」留给 `build()`，并在注释里说明「builder 可变，求哈希后继续 `append` 会使哈希失效」。

### [一般][存量] 集合重载按迭代顺序累加哈希：内容相同的 `HashMap`/`HashSet` 可能得到不同哈希

- **位置**：`f_base/src/HashBuilder.cj:109-124`（`ConcurrentHashMap` 重载）、`:90-99`（任意 `Iterable` 重载）
- **来源**：存量（同 `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现不符）、§2（隐式假设「迭代顺序只由内容决定」）
- **证据**：待确认 —— 代码把 `for ((k, v) in value)` 的**遍历顺序**直接折进 `seed ^ ... << 6` 链；两个键集相同但插入/删除历史不同（导致容量、探测位置不同）的 map 是否得到同一遍历顺序，需要按当前 std 实现的容量与重排规则验证。
- **描述**：`DataAssist` 生成集合字段哈希时走的是 `hasher.append(field.toString())`（`f_data/src/macros/DataAssist.cj:335-338`），**不经过这里**，所以风险面限于直接调用 `HashBuilder().append(someMap)` 的代码；仓内这类调用点未在形状上命中（本部分未逐一验证 30 处调用的实参类型）。若遍历顺序依赖历史，则「相等对象哈希相同」不成立，作为 map key 会查不到。
- **建议**：对 map/set 重载先按键排序（键可比较时）或对每项哈希做与顺序无关的组合（如 `sum`/`xor`，代价是碰撞率略升）；至少在注释里写明「哈希与迭代顺序相关，仅用于同一进程内短生命周期对象」。

### [一般][存量] `ExtendRune` 的有符号偏移在 `Int*.Min` 上取负溢出

- **位置**：`f_base/src/ExtendRune.cj:44`（`-(n: Int8)`）、`:64`、`:71`、`:93`、`:100`、`:113`、`:120`（Int16 / Int64 / Int32 同构分支，全部写 `this ∓ UInt32(-n)`）
- **来源**：存量（文件年份 2025，`git blame` 落在换行符统一提交，无法区分更早来源）
- **判据**：review-checklist §11（边界差一 / 极值）、§10（正确性）
- **证据**：静态确定（取负溢出本身）＋ 待确认（后续转换的确切行为）—— `n == Int8.Min` 时 `-n` 仍是 `-128`，`UInt32(-n)` 的实参为负；`Int16/Int32/Int64.Min` 同理。四个有符号重载都走这条路径，无 `Min` 特判。
- **描述**：`r'中' + Int64.Min` 这类调用不会得到「减少 2^63」的语义，而是把负值送进 `UInt32()`：要么按检查转换抛 `OverflowException`（调用方拿到与「字符偏移越界」无关的异常），要么回绕成巨大偏移后由 `Rune(...)` 产出错误字符。两种结果都不是该 API 的契约（「加/减一个偏移」）。无符号重载（`UInt8/UInt16/UInt32/UInt64`）与 `-(c: Rune)` 只存在越界问题，没有取负溢出。
- **建议**：先在 `Int64` 域上做一次加法（`Int64(UInt32(this)) + n`），判 `0 <= r <= 0x10FFFF` 且非代理区后再转 `Rune`；越界时抛带信息的 `IllegalArgumentException`。补 4 个极值用例（`Min`、`Max`、`-1`、越过 `0x10FFFF`）。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下均为**无基线（待验证）**，不进修复清单。

### [CPU] `OS.hashCode()` 每次调用做一次字符串插值 + 一次字符串哈希

- **现状**：`f_base/src/OS.cj:97-99` 实现为 `'fountain::f_base.OS.${this}'.hashCode()`，即成串（插值调用 `toString()`，`:74-84` 再做一次 7 分支 `match`）+ 一次 UTF-8 字符串哈希；每次调用至少 1 个 `String` 临时对象（23~25 字节 + 头部）。
- **方案**：改为常量映射——`match (this) { case Linux => 1; case Windows => 2; ... }`，或用 `static let` 预置每个枚举值的哈希到字段；`toString()` 可直接复用枚举默认实现。
- **预期**：单次 `hashCode` 由「1 次分配 + 1 次字符串遍历」降为纯分支返回；量级取决于调用次数（本模块内 `OS` 只用于 `current`/`nextLine` 判断，`hashCode` 仓内未见热点调用）。
- **代价**：需接受「哈希值与字符串哈希解耦」（无兼容要求，枚举哈希本就不该持久化）。
- **验证**：`cjpm bench -O2`，对 `OS.hashCode()` 做 1e7 次循环取中位数；`cjprof` 看分配计数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU/堆] `AbstractInheritedTaskLocal.hashCode()` 只取 owner 任务 id，同一任务下所有 local 落同一桶

- **现状**：`f_base/src/FutureTask.cj:335-337`（`hashCode = task.hashCode()`）+ `:338-340`（`==` 用 `refEq`）。一个任务创建 n 个 local 时，任务 `local` 表（`HashMap<AbstractInheritedTaskLocal, Any>`）的 n 个键全部哈希相同 ⇒ 单桶线性链，`readLocalRaw`/`writeLocalRaw` 每次 O(n)。
- **方案**：`hashCode` 混入 local 自身 id（与 `nextTaskId` 同法新增 `static let nextLocalId = AtomicInt64(0)`），保持「相等 ⇒ 同哈希」（`refEq` 相等即同一对象，恒成立）。
- **预期**：n 个 local 的查表从 O(n) 降为 O(1)；n 的典型值（每任务 1~5 个 local）下收益有限，n 大时才显著。
- **代价**：每个 local 多 8 字节 + 一次原子自增；`hashCode` 语义变化（仅进程内使用，无持久化）。
- **验证**：构造单任务 1/8/64 个 local 的微基准，测 `getLocal` 中位数 + 桶链长度埋点。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 每个任务的 `local` 表从 `HashMap` 起步，单个 local 也付整表成本

- **现状**：`f_base/src/FutureTask.cj:96-106` 首次 `writeLocalRaw` 建 `HashMap`（注释给出的实测：同尺寸 `HashMap` 构造 0.42~0.55µs、空 `ConcurrentHashMap` 3.6~5.2µs）；每个任务最多一张表，元素数通常 1~2，`HashMap` 的桶数组对 1~2 项明显过量。
- **方案**：单元素时用「键 + 值」两个字段直存，第 2 个 local 写入时才升级为 `HashMap`（`?Any` 的 box 可同时承载值）；或改用有序小数组线性查找（n ≤ 8 时快于哈希）。
- **预期**：每次首次写入省一个 `HashMap`（约 0.4µs + 桶数组），常驻堆按「活跃任务数 × 表开销」下降；具体字节数需按活跃任务数实测。
- **代价**：状态机变复杂（None / 单槽 / map 三态），三条读写路径都要覆盖；收益依赖「每任务 local 数」分布。
- **验证**：多轮负载下 `getAllocatedHeapSize()` + RSS + 活跃任务数计数是否达到有界稳态；`cjprof heap` 看 `HashMap` 分配占比。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `OS.hashCode` 的字符串插值是热点（若某业务把 `OS` 当 map key） | `f_base/src/OS.cj:97` | 自耗时占比、调用次数 | `cjprof record` 跑 10 分钟稳态负载，输入为既有业务流量；同时统计 `OS.hashCode` 调用次数 |
| 2 | `HashMap`/`HashSet` 迭代顺序影响 `HashBuilder` 哈希一致性 | `f_base/src/HashBuilder.cj:109-124` | 同内容不同插入历史的两张 map 的遍历序列 | 写用例：相同 1k 键、不同插入顺序（含中途删除），比对 `append(map).build()` 结果是否一致 |
| 3 | `shutdown` 子树递归的深度在真实用法中不足以构成栈风险 | `f_base/src/FutureTask.cj:177-195` | 任务树最大深度 | 在 `shutdownCurrentSubThreads` 加深度计数埋点，跑嵌套派生任务的用例（深度 1/100/1000） |

> **范围外提示（1 句）**：`f_data/src/macros/DataAssist.cj:346-358` 生成的 `hashCode` 用 `if(__hAsh__ == 0)` 做惰性缓存，与本文 `HashBuilder` 的「哈希必须稳定」假设同源，未纳入本部分统计。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 3（`set`/`get` 不对称、`shutdown` 误伤、Rune 极值溢出）、设计 3（`isEmptyOrUnit` 冗余、`Options` 泛型 `R` 不可推断、`HashBuilder` 的 `Hashable` 声明）；语言特性按仓颉文档现场核对：单引号是 `String` 字面量、`r'...'` 才是 `Rune`、`String[i]` 返回 `UInt8`、`String.indexOf` 返回 `Option<Int64>`（故 `ExtendString.replace` 的 `None` 分支可达，无缺陷）、std `Mutex` 文档明确可重入（故同线程重入不判缺陷）；无外部输入、无 SQL/注入面、无凭据 |
| §1 死代码 | 4 | 逐个 `private`/`internal` 符号机械搜过：`HashBuilder` 的 `private append(Map)` 零调用者；`internal` 类 `Help`（`abstract sealed class`，无修饰符）全仓零引用，其 4 个 `public static convert` 随之不可达；`HashBuilder.append(ConcurrentHashMap)` 里 6 个 `match` 臂不可达（`K <: Hashable`，被前 3 臂完全覆盖）；`FutureTask_test.cj:21` 的 `import std.collection.HashSet` 未使用（仅出现在注释里）。`protected` 只有 `cancelSelf`（`sealed` 类，但被 `shutdown` 调用且被唯一子类覆盖）不判；`public` 对外可达的一律不判（`stringJoin`/`Options`/`Operators` 等仓内 0 引用只作信息） |
| §2 重复逻辑 | 6 | 同文件两两比对 + 跨方法比对：13 个标量 `append` 重载与泛型 `append<T>(arg: T)` 逐行等价；`Map` 重载的 9 臂 `match` 与 `ConcurrentHashMap` 重载完全复制；`Options.isEmptyOrUnit` 与 `isEmpty` 对全部取值语义相同；`OS` 手写 `==`/`toString` 与枚举默认实现等价；`ExtendString.trimAsciiBlanks` 与 std `trimAscii` 近似重复（差异见下条）；`ExtendRune` 的 4 组有符号重载逐行相同（仅类型不同）、4 组无符号同理。`NoneOrder`/`LocalComparable`/`LocalEquatable`/`OptionComparable` 已两两比对，接口默认成员是刻意保留的模态分支，不是重复 |
| §3 空实现 | 0 | 唯一的空函数体是 `protected open func cancelSelf(): Unit {}`（`:176`），有注释说明「子类在这里挂各自的取消手段」且被唯一子类覆盖，属有意的 no-op 扩展点；`Options`/`Help` 无 `TODO`、无 `catch {}`、无静默吞异常（`doConvert` 的 `else` 分支返回 `None` 是契约内语义） |
| §4 栈溢出 | 0 | 本部分唯二递归是 `shutdown → shutdownCurrentSubThreads → f.shutdown`（深度 = 任务树深度，每层需新建一个线程，且 `parent` 在构造期固定、树无环，无自引用结构）；`Options`/`HashBuilder`/`Extend*` 无递归。未发现每帧大对象 |
| §5 OOM | 0 | 唯一无界候选 `subTasks` 已有界：桶按线程 id 分组、登记路径在 `size >= 64` 时剪掉已完成项（`:238-240`），叶子任务不建桶（`hasChildren` 短路）；`pruneFinishedChildren` 只增临时 `ArrayList`（≤ 桶大小）。`stringJoin` 只产出目标串本身，`local` 表按任务生命周期随任务回收 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；`OS.hashCode`（字符串插值）与 `AbstractInheritedTaskLocal.hashCode`（单桶）已列入「优化可行性方案 + 待验证假设」，未作为发现 |
| §6.2 大粒度锁 | 1 | `getOrComputeLocal`/`getOrSetLocal` 在 `initLock` 内执行任意时长的用户 `fn()`，其它线程在整段计算期间被串行化；与「严重」条目同源，未重复计数细节（临界区内容：`getLocal` 父链遍历 + `fn()` + `setLocal`） |
| §6.3 并发串行 | 0 | 无 `spawn` 后立刻 `get`、无批大小为 1 的窗口、无单消费者队列；`FutureTask` 的 `spawn` 是 fire-and-forget，`get` 由调用方决定时机 |
| §6.4 低效算法 | 0 | 本部分无嵌套循环匹配、无 `remove(at: 0)` 当队列、无循环内字符串 `+`；`pruneFinishedChildren` 的 O(桶) 扫描是摊还后的登记路径，已由注释给出量化依据（~1 元素/次） |
| §7 降堆内存方案 | 1 | 「单槽 → HashMap 三态」方案（无基线，待验证） |
| §8 降 CPU 方案 | 2 | `OS.hashCode` 去字符串插值；`InheritedTaskLocal.hashCode` 混入 local id（均无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内用完的大中间结构」：`stringJoin` 的产出必须返回（逃逸）、`Options`/`Help` 只有标量与小 Option、`FutureTask` 的对象要跨线程（逃逸）；`HashBuilder` 是有状态对象且地址被 `append` 返回。收益无法用峰值内存证明，不列方案 |
| §11 现有代码的 BUG（存量） | 20 | 本部分全部 20 条发现均为存量（快照模式无 diff）；逐函数核对了边界、空值、`Option` 不丢弃、异常路径、资源对称性。核对结论：`ExtendString.replace` 的 `indexOf` 返回 `Option<Int64>`（非 -1 哨兵），`None` 分支可达，无缺陷；`trimAsciiBlanks` 的边界（全空白串、单字符、多字节尾）三种情形均正确；`Options.isEmptyOrBlank` 的 `getOrThrow` 在 `isEmpty` 为 false 时必然 `Some`，无 `None` 解包崩溃；`FutureTask` 的登记/注销键一致（`parentTID` vs `Thread.currentThread.id` 分属父子两层） |
| §12 并发安全与锁粒度 | 2 | 共享点与同步手段已逐一列出：`subTasks` 全部访问在 `subTasksLock` 内（登记/摘桶/剪枝/注销一致）；`local` 表全部访问在 `localLock` 内（含读）；`finished` 用 `AtomicBool`；`hasChildren` 只由创建线程写、同一线程读（无共享）；`future` 字段由构造线程写、常规用法同线程读。判不安全的两处：`initLock` 内执行用户回调（死锁）、`shutdown()` 的子树作用域错位。锁粒度方面 `subTasksLock` 是全局单锁但临界区只有 map 操作（取消动作已移到锁外），不计为大粒度锁热点 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 14 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

### 轻微条目清单

| # | 位置 | 问题 |
| --- | --- | --- |
| M1 | `f_base/src/Help.cj:18-46` | 死代码：`abstract sealed class Help` 为内部类型，全仓零引用；其中 `convert<T>(Array<?String>)`、`convert<T, C>(Array<C>)` 的 `T` 只出现在约束里，调用处无法推断，三个重载实际不可调用 |
| M2 | `f_base/src/HashBuilder.cj:134-153` | `private append(Map)` 无调用者（死代码），且 9 臂 `match` 与 `:110-122` 完全复制 |
| M3 | `f_base/src/HashBuilder.cj:53-88` | 13 个标量 `append` 重载（`Int8`…`Bool`）与 `:47-49` 的泛型重载逐行等价，全部只做 `append(arg.hashCode())` |
| M4 | `f_base/src/Options.cj:34-42` | `isEmptyOrUnit`/`isNotEmptyOrUnit` 与 `isEmpty`/`isNotEmpty` 行为完全一致（`isEmpty` 的 `case Some(x) where x is Unit` 已把空 Unit 判为真），属同义 API |
| M5 | `f_base/src/Options.cj:20,23-30` | 类参数 `R` 只出现在方法体内（`Collection<R>`），形参里无推断来源，调用方必须写全 `Options<T, R>.isEmpty(...)` |
| M6 | `f_base/src/Options.cj:120` | `throw IllegalArgumentException()` 无消息，类型不匹配时无法定位是哪个 `convert` |
| M7 | `f_base/src/Options.cj:91-105` | `convert(origin, default)` 转换失败回退 `default`，`convertOrThrow(origin, default)` 转换失败抛异常 —— 同一形状的两个 API 失败语义相反 |
| M8 | `f_base/src/FutureTask_test.cj:21` | 未使用 `import std.collection.HashSet` |
| M9 | `f_base/src/FutureTask_test.cj:472` | `assert(maxBucket <= 200)` 远松于实际阈值 64，剪枝退化为 200 也能通过；另有 `sleep(400/450/600ms)` 定长等待断言（`:83/:107/:135/:161`），高负载 CI 上偏脆 |
| M10 | `f_base/src/OS.cj:27-38,74-84` | 手写 `operator ==`（7 分支全枚举匹配）与 `toString()` 均与枚举默认语义等价，属冗余维护面 |
| M11 | `f_base/src/ExtendString.cj:45-58` | 与 std `String.trimAscii()` 近似重复，但判定范围不同（此处 `<= b' '` 含 0x00–0x08、0x0E–0x1F；std 只含 0x09–0x0D 与 0x20），命名未体现「连控制符一起裁掉」 |
| M12 | `f_base/src/Operators.cj:46-56` | 可见性建议（非死代码）：`Cmpable`/`Eqable` 仓内零引用，其余 13 个接口均有使用；如确认无下游依赖可评估收窄或合并 |
| M13 | `f_base/src/FutureTask.cj:235-252` | 登记发生在 `spawn` 之前：`spawn` 抛异常（线程资源耗尽）时任务已进 `subTasks` 却永不进入 teardown，登记项残留到父任务收尾；证据待确认（需核对 `spawn` 的失败模式） |
| M14 | `f_base/src/ExtendRune.cj:40-73,89-121` | 4 组有符号重载逐行相同（仅 `Int8/16/32/64` 不同），4 组无符号同理；可让窄类型重载转调 `Int64` 版本，避免 8 份实现各自漂移 |

## 总评

本部分代码整体结构清晰、注释密度高（`FutureTask` 的每处并发决策都带编号与实测数据），语言特性使用得当（`Option` 惯用法、`match` 穷尽、扩展成员而非改 std）。**唯一阻塞项是 `FutureTask` 的 `initLock` 在锁内执行用户回调**：同线程重入已被 std `Mutex` 的可重入性覆盖，但「回调内派生任务并再对同一 local 求值」和「两个 local 反向取锁」都会确定性死锁，且锁无超时。建议优先改成「锁内登记计算中标记、计算在锁外」，并把 `fn` 的调用约束写进文档。

其余一致性类问题集中在三条老代码线索上：(1) `InheritedTaskLocal` 的写路径（回退 owner）与读路径（只走 currentTask 链）不对称，任务外 `set` 后自读恒 `None`；(2) `shutdown()` 把「关子树」绑定到调用线程，跨线程调用会误伤无关任务；(3) `HashBuilder` 声明了 `Hashable` 但 `hashCode()` 破坏自身状态，集合重载还依赖迭代顺序。

`HashBuilder`、`Options`、`Help`、`Operators` 的重复与死代码属可排期清理：`Help` 整个类是内部死代码（4 个 `public` 入口不可达，其中 3 个还因泛型参数无法推断而不可调用），应直接删除；`HashBuilder` 的 14 个转发重载与私有 `Map` 重载可以合并成 1 个泛型 + 1 个集合实现。`ExtendRune` 的极值溢出是真实边界缺陷（`Int*.Min` 取负），修法很小。

补充一条使用面信息：`FutureTask`/`InheritedTaskLocal` 全仓（除本模块测试）**零消费者**，`ExtendRange`/`stringJoin`/`Options`/`OptionComparable` 同样如此——它们是对外契约，按规则不判死代码，但上述并发缺陷目前只被 `f_base` 自身的测试触发，风险实际落在下游使用方；`Options`/`Operators` 若长期无外部使用，可评估收窄维护面。

存量 20 条（严重 1 / 一般 5 / 轻微 14），是否纳入修复待用户决定。
