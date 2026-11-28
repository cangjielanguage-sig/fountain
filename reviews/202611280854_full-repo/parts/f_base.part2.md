# f_base 模块审查报告

> **模块第 2/3 部分**（本报告只覆盖 `files/f_base.part2.txt` 列出的 20 个文件，全部为 `src/` 下的 `.cj`：`ExtendThreadLocal` → `TypeInfos`。`README.md` / `README_en.md` 与其余 32 个 `.cj` 由第 1、3 部分产出；本部分编号独立，合并时以主 Agent 为准。README 只作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（本部分 20 个 `.cj`，0 个 `.md`；模块共 52 `.cj` + 2 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status` 只有审查产物，无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：基础并发原语（`FutureTask` / `InheritedTaskLocal` / 锁 / 原子量）的正确性与可见性、栈溢出、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 2/3 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个 `FutureTask` 都 `spawn` 一个 OS 线程（`FutureTask.cj:252`），任务数上千时线程创建/栈内存成为主要成本 | `f_base/src/FutureTask.cj:252-285` | 单任务创建耗时、每任务栈占用、并发任务数分布 | 创建 1k/10k 个立即返回的任务，分段计时构造 vs `get`，并读 `/proc/self/status` 的 `VmRSS`/线程数；对照改成有界线程池或协程的方案 |
| 2 | `subTasksLock`（全局唯一）在任务构造/拆除路径上形成锁竞争 | `f_base/src/FutureTask.cj:60-61`、`235-247`、`266-268` | 锁等待时长、竞争线程数 | 8/32 线程各创建 10k 个短任务，`cjprof` 看 `synchronized` 阻塞时间，或在线程状态采样里统计 BLOCKED 比例 |
| 3 | `InheritedTaskLocal` 同桶导致 `set/get` 的桶内线性扫描成为热点 | `f_base/src/FutureTask.cj:335-337`、`88-114` | 单任务 local 数分布、`HashMap.get` 自耗时占比 | 在 `readLocalRaw` 加计数（次数 × 表大小），跑 `f_orm`/`f_bean` 真实负载 10 分钟，再看 `cjprof` 里 `f_base` 的占比是否 >5% |
| 4 | `TypeInfos.get<T>()` 无缓存在启动期被高频调用 | `f_base/src/TypeInfos.cj:32-36` | 调用次数、单次 `TypeInfo.of<T>()` 耗时 | 入口加 `AtomicInt64` 计数，跑一次 `fboot` 启动；`cjpm bench` 测单次调用 |
| 5 | `StringGenerator.reverse()` 的双份内容使峰值内存翻倍（当前仓内 0 调用点，属对外 API 潜在路径） | `f_base/src/StringGenerator.cj:250-259` | 调用频次、n 的分布、峰值 RSS | 先统计外部使用方的 `reverse()` 调用点（仓内已确认为 0），若有则按 1MB 串测 `getAllocatedHeapSize()` 峰值 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_base/src/ExtendThreadLocal.cj` | .cj | ✅ | `ThreadLocal.getOrCompute` / `remove` 扩展（`remove` = `set(None)`，已核对 `ThreadLocal.set(?T)` 文档 `core_package_classes.md:4140-4146`）；无并发/边界问题 |
| 2 | `f_base/src/FutureTask.cj` | .cj | ✅ | 见 #2（shutdown 目标）、#3（get/set 不对称）、#4（锁内回调）、#5（tid 作键）、#13（哈希退化）、#14（全局锁）；优化方案 2 |
| 3 | `f_base/src/FutureTask_test.cj` | .cj | ✅ | 见 #15（辅助函数重复、自旋）；用例覆盖 FT-1…FT-6 与 FT-L1/L2，与源码注释一一对应 |
| 4 | `f_base/src/HashBuilder.cj` | .cj | ✅ | 见 #10（private `append(Map)` 死代码 + 重复）、#12（`hashCode` 副作用）；12 个基础类型 `append` 重载是为免装箱刻意展开，不判重复 |
| 5 | `f_base/src/Help.cj` | .cj | ✅ | 见 #7（整类不可达 + README 误记） |
| 6 | `f_base/src/LocalComparable.cj` | .cj | ✅ | local 模态运算符族；`@ local?` / `@ local!` 两组重载是模态类型所需，不判重复；无边界问题 |
| 7 | `f_base/src/LocalEquatable.cj` | .cj | ✅ | 同上；普通 `==` 明确留给实现类（注释说明了原因），无隐患 |
| 8 | `f_base/src/NoneOrder.cj` | .cj | ✅ | 二值枚举，`compare` 穷尽 `match`；`isGreatest` / `isLeast` 有调用方（`OptionComparable`） |
| 9 | `f_base/src/OS.cj` | .cj | ✅ | 见 #16（HarmonyOS 不可达、注释块）；`@When` 单引号字面量与文档双引号等价（单行字符串可用单引号，`strings.md:9`） |
| 10 | `f_base/src/Operators.cj` | .cj | ✅ | 15 个纯运算符接口，无实现、无状态；对外可达的 `public` 接口不判死代码 |
| 11 | `f_base/src/OptionComparable.cj` | .cj | ✅ | `Option<T>` 比较扩展；`noneOrder` 四种组合语义自洽（Some/None × Greatest/Least）；仓内无直接调用，属对外 API |
| 12 | `f_base/src/Options.cj` | .cj | ✅ | `isEmpty*` / `convert*` 家族；`getOrThrow()` 前有 `isEmpty` 短路，无空值风险；`convert(origin, default)` 失败时返回 `Some(default)`，与参数名一致 |
| 13 | `f_base/src/OverSizeException.cj` | .cj | ✅ | 4 个构造器，与 `BaseException` 语义一致，无逻辑 |
| 14 | `f_base/src/OverSizePolicy.cj` | .cj | ✅ | 见 #8（Blocking 默认策略永不执行 `fn`）；`Discard` 的空体是策略语义（§3 不计） |
| 15 | `f_base/src/Peekable.cj` | .cj | ✅ | `peek` / `next` 语义正确；迭代器耗尽后每次 `next()` 会重复调底层 `next()`（幂等，未单列）；`close` / `isClosed` 转发 `Resource` |
| 16 | `f_base/src/Result.cj` | .cj | ✅ | 见 #9（`transpose`）；`ResultFilter` / `ResultMapper` 分支穷尽，仓内无调用方但属对外 API |
| 17 | `f_base/src/SingleIterable.cj` | .cj | ✅ | 单元素迭代器，`next()` 取后置空；无问题 |
| 18 | `f_base/src/StringGenerator.cj` | .cj | ✅ | 见 #1（零长搜索串死循环）、#6（`fromIndex == size`）、#11（三段重复 / `reset`≡`clear`）；优化方案 3 |
| 19 | `f_base/src/StringGeneratorRune_test.cj` | .cj | ✅ | `append(Rune)` 与 `append<String>(r.toString())` 的逐字节等价用例；`@Assert(expected, actual)` 用法正确 |
| 20 | `f_base/src/TypeInfos.cj` | .cj | ✅ | 见 #17（畸形限定名截断）；姓名版 `get` 的双检与无限递归修复在注释中留存（`46`）；优化方案 1 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分（`f_base` 的"并发原语 + 基础容器"层）代码密度高、注释里带实测数据（`EXP16`/`EXP18`/`FPS` 等），凡是"为什么这么写"的地方基本都留了取证，整体可读性明显高于一般工具模块；并发可见性的骨架也站得住——`local` 的读写全在锁内、任务身份用构造期 `AtomicInt64` 而非可变 `tid`、`finished` 用原子量、`spawn` 不持锁，这几条把最容易出事的"值丢失"面堵住了。真正的风险不在可见性，而在**语义边界**：

- 阻塞项：#1 `StringGenerator.remove` / `replace` 遇空串死循环并不断 `add`，是"合法入参 + 确定性挂死 + 无界分配"的组合，一旦有人用这个 builder 做通用替换就会打满 CPU 并 OOM。修法只有两行，建议先进 1.3.x。
- 次阻塞项：#2 `shutdown()` 的取消目标是调用线程而不是被调用任务；跨线程做超时清理时会误杀无关任务，属于"看不出错、但数据悄悄没了"的类型，且与 README 的实例语义直接冲突。修它需要把"清子树"从静态线程级拆成实例级，顺带补一条跨线程用例。
- 语义陷阱：#3（`set` 回退 owner 而 `get` 不回退，读己之写失败）、#6（`fromIndex == size` 被当越界）、#8（`Blocking` 策略默认永不放行）、#9（`transpose` 把 `Ok(None)` 变成 `Some(NoResult)`）都属于"库使用者按直觉写就会踩"的口径问题，单条修复成本低，建议与上面两条同批处理。
- 并发设计层：#4（锁内跑用户回调）与 #5（线程 id 作长期键）是这一层唯一有"将来会咬人"潜力的两处——前者要求调用方的 `fn` 不等待其它任务，后者依赖"线程 id 不复用"这个标准库不保证的前提。#14（并发容器 + 全局锁）在有 profile 数据前只当结构问题看。
- 死代码与重复：#7（`Help` 整类不可达却在 README 里当公开 API）、#10（`HashBuilder` 的 private `Map` 重载）都是"删了更安全"的项；#11 / #15 属可维护性，跟随上面几条一起改即可。
- 性能与内存：本部分没有任何改前/改后数据，3 条优化方案与 5 条假设都不进修复清单；最值得下一轮补数据的是"每任务一个 OS 线程"（假说 1）与 `subTasksLock` 争用（假说 2），它们决定了 `FutureTask` 能不能承载上千级并发任务。
- 已确认**没有**的问题：`local` 的跨线程可见性（全锁内）、`HashBuilder` 的溢出（`@OverflowWrapping`）、`Options` 的空值路径、`Peekable` / `SingleIterable` 的迭代器状态机、`Result` 的 `match` 穷尽性。

存量缺陷共 17 条（严重 1 / 一般 8 / 轻微 8），是否纳入修复待用户决定；本报告只读代码，未做任何修改。
