# f_egraph 模块审查报告

> **模块第 4/4 部分**（本报告只覆盖 `files/f_egraph.part4.txt` 列出的 13 个文件：`src/base/` 的 `JitManualBinding_test` → `imports` 共 9 个、`src/egraph.cj`、`src/exception/` 2 个、`src/loader/FlowLoader.cj`；`README*`、`doc/spec/**` 与其余 37 个文件由第 1/2/3 部分产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_egraph`（本部分 13 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」；`git blame` 抽样：`QueuedClosureTask.cj:100-145` 为 `c6cd191aa5` / `da88f4bc4a` / `afb9821e26`，均 2026-11-01）
- **审查重点**：图算法正确性、递归深度与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 4/4 部分）
- **验证口径**：只读代码，不跑构建、不跑测试；语言 / 标准库语义现场查文档（路径写在各条判据里）；凡涉及频次、占比、耗时的只进「待验证假设」

## 发现

### [严重][存量] #1 `runNext` 只在取批时持锁、任务体在锁外执行，且取消令牌只有单槽 ⇒ 多线程投递时同一任务体并发执行、`>=2` 号事件乱序、「顶替」只对最后一个执行生效

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:169-204`（`172-181` 持锁取批、`188` 锁外 `evaluate`、`189-201` 单槽清理、`202` 锁外 `dispatcher.accept`）、`45-46`（`currentName` / `currentToken` 各一个槽）、`180`（新批直接覆盖 `currentToken`）、`68-74`（`exec` = 提交后自排空）；并发路径：`f_egraph/src/base/AsyncDispatcher.cj:116-128`（`asyncExecute` / `asyncDispatch` 逐事件、逐执行器 `spawn`）→ `TaskExecutor.cj:39-41`（`task(event)`）→ `AsyncFlow.cj:127-131`（`registerTask(e, task.exec)` 把同一实例的 `exec` 登记到每个 acceptable 名字）
- **来源**：存量（`git blame -L 100,145 -- f_egraph/src/base/QueuedClosureTask.cj` 全为 2026-11-01 的 `c6cd191aa5`/`da88f4bc4a`/`afb9821e26`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 数据竞争」、§11「契约与实现不符」（类注释 `:31` 承诺「`>=2` 按 `(priority, birth, 入队序号)` 顺序逐条执行」）
- **证据**：静态确定 —— 三条事实叠加：
  1. **任务体会被多线程并发调用**：`AsyncDispatcher.asyncDispatch` 对每个事件 `spawn`（`122-128`），`asyncExecute` 再 `spawn`（`116-121`），最终走到 `TaskExecutor.execute` → `task(event)`，即 `QueuedClosureTask.exec`。同一 `QueuedClosureTask` 实例被 `AsyncFlow.registerTask(task: Task)` 按 `acceptableEvents` 逐个登记（`AsyncFlow.cj:127-131`），所以每次入站事件都在**独立线程**上进入 `exec`；同步侧（`ImmediateFlow` 被两个线程各自 `start`）同理。
  2. **锁不覆盖执行段**：`runNext` 在 `172-181` 取批后立即释放 `mutex`，`188` 在锁外 `evaluate`。两个线程可以各自取一批（`takeBatchLocked` 返回不同批）并**同时**执行任务体；`202` 的 `dispatcher.accept` 谁先到谁先发，与 `birth`/`sequence` 顺序无关。
  3. **取消令牌只有一个槽**：`currentName`/`currentToken` 是单字段（`45-46`）。两个批同时在跑时，后取批的线程在 `180` 覆盖令牌，`submitImmediate` 的顶替判定（`114-123`）只能标记**最后一个**令牌；先跑的那批即使同名、本应被顶替，其 `token.cancelled` 仍为 `false`，结果照常 `accept`（`129-131` 只判自己的 token）。
- **描述**：类注释把「0 号抢占、1 号合并、`>=2` 逐条按 `birth` 顺序」写成契约，实现只保证**单线程驱动**下成立（`:37` 的注释自认「执行由 `runNext()`/`drain()` 驱动（便于单线程确定性）」，但 `exec` 是公开入口且被派发器从多线程调用）。并发下的三个后果都不是「慢」：① 同一任务体并发执行 ⇒ 任务体读写共享状态即数据竞争（`f_llm/src/loom/LoomRunner.cj:295-298` 用 `AsyncFlow` + `QueuedClosureTask` 注册每个步骤，属范围外但证明该组合在仓内真实使用）；② 结果投递顺序与 `birth` 无关，流程后续节点看到的顺序与契约相反；③ 抢占漏判 ⇒ 本应被丢弃的旧结果被 `accept` 进流程（数据陈旧）。三者都依赖「并发投递同一任务」这一条件，但对 `AsyncFlow` 而言这是常态而非异常用法。
- **建议**：三选一，并同步类注释：(a) 增加私有 `execMutex`，`evaluate + accept` 整段串行（最简单，代价是任务体不再并行）；(b) 改「单消费者」——`exec` 只入队，由固定 driver（`spawn` 一次）`drain`，`submit` 不再自排空；(c) 若要保留多批并行，把 `currentToken` 换成 `Map<Int64, CancelToken>`（或按 `name` 分桶）并声明任务体必须线程安全。无论哪种，补一条并发用例：>1 线程 `submit` + 并发 `drain`，断言 `accept` 顺序 = `birth` 顺序、`cancelledCount` = 预期数。

### [一般][存量] #2 任务体抛异常时 `currentToken` / `currentName` 不清理（无 `try`/`finally`）⇒ 槽位永久残留、后续同名 0 号事件被误判为「正在执行」

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:127-141`（`127` `evaluate`，`128-140` 的清理是其后顺序语句）、`188`（同构，`189-201` 为其后的清理）
- **来源**：存量（`git blame -L 100,145`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §11「错误处理缺失 / 资源不对称」、§3「异常被静默」
- **证据**：静态确定 —— `evaluate` 调用与令牌清理之间无 `try`/`catch`/`finally`，任务体抛出（`f_jit` 脚本错误、宿主闭包抛错，`ClosureTask.cj:145-148` 明确「错误原样上抛」）时 `128-140` / `189-201` 整体跳过：
  1. 槽位残留：`currentName` 仍是该事件名、`currentToken` 仍指向已结束的令牌，且**没有任何路径会再清空它**（清理条件是 `active.id == token.id`，`134`/`192`）。
  2. 误判顶替：下一次同名 0 号事件在 `114-123` 看到 `currentToken.isSome()` 且未 `cancelled` ⇒ 置 `cancelled = true`、`cancelled++`，`cancelledCount`（`151-157`）虚增，且这次的 `cancelled` 永远等不到对应执行结束。
  3. 静默丢失：`takeBatchLocked`（`218-248`）已把批从队列删除，异常向上穿过 `exec` → `TaskExecutor.execute` → `AsyncDispatcher` 的 `spawn` 线程（无人捕获），dispatcher 侧既收不到结果也收不到 `ErrorEvent`——批事件就这样消失。
- **描述**：错误路径与成功路径的清理不对称。触发条件是任意一次任务体异常（脚本编译通过但运行期报错很常见），后果是「取消计数不可信 + 槽位脏死 + 该批事件无声丢失」。第 3 点会让排障变成不可能：日志里看不到该批的去向。
- **建议**：`let result = try { evaluate(payload) } catch (e: Exception) { 在 finally 里按 id 清理令牌槽；再把 e 包成 ErrorEvent 交 dispatcher.accept（或至少 f_log 记录 batch 名字与异常）; rethrow }`；清理逻辑抽成 `clearTokenIfCurrent(token)`，`submitImmediate` 与 `runNext` 共用。

### [一般][存量] #3 批量执行把 `MultiEvent` 的 `session` 换成新 UUID，与单条路径及批内子事件都不一致

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:182-187`（`MultiEvent(category: batch[0].category, tag: batch[0].tag, name: batch[0].name, events: batch)`，未传 `session`）；默认值 `f_egraph/src/base/Event.cj:104-108`（`session! = UUID.random().toHexString()`）
- **来源**：存量（`git blame -L 180,190`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §11「语义与注释不符 / 契约与实现不符」（同一入口两条路径的 session 语义不同）
- **证据**：静态确定（不一致本身）——`batch.size == 1` 时 `payload` 就是原事件（`182-184`），`session` 原样保留；`batch.size > 1` 时新建 `MultiEvent` 走默认值，得到一条与所有子事件无关的随机 session。`session` 是对外可见的语义字段：`JitHostRegistry.cj:82-92` 把它登记给脚本读取，`BarrierTask.cj:83` 用它作会话聚合键（`BarrierKey(category, tag, name, session)`）。下游影响面为**待确认**（本部分无法确认有多少消费者读 `MultiEvent.session`）。
- **描述**：同一个任务、同一个事件名的结果，单条时 session 属于调用方，批量时属于一个凭空生成的值。若消费者按 session 关联请求（Barrier 聚合、脚本里读 `e.session` 打点），批量路径会关联到不存在的会话；而批内各子事件各自带着不同的原 session（`MultiEvent.data` 是 `Iterable<Event>`），"以谁为准"也没有约定。
- **建议**：传 `session: batch[0].session` 并在注释写明「批内 session 以首条为准（同批通常同会话）」；若确认批内可跨会话，则改为 `session` 保留首条 + 文档标注「批内可能跨会话，勿用 MultiEvent.session 做聚合」。

### [一般][存量] #4 `Flow` 公共入口无法产生 `priority != 2` 的事件 ⇒ `QueuedClosureTask` 的 0/1 号分支在生产路径不可达，只在测试与直接 `submit` 下触发

- **位置**：承诺方 `f_egraph/src/base/QueuedClosureTask.cj:27-31`（「Flow 收到事件后立即调用 `exec(e)`：`priority = 0` 立即执行…`priority = 1` 合并成一批…」）；缺失方 `f_egraph/src/base/Emitter.cj:19`、`Flow.cj:41,95`、`ImmediateFlow.cj:126-127`、`AsyncFlow.cj:153-154`、`FlowEventFactory.cj:31-46`（全部只有 `eventType` / `name` / `data`，构造 `DataEvent` 时不传 `priority` / `cancelPrev`）
- **来源**：存量（`git blame`：`QueuedClosureTask.cj:24-38` 为 `c6cd191aa5`；`emit` 三处为 2026-10/11 提交）
- **判据**：review-checklist §14.1「接线缺失 / 只有一半的分支」、§13「文档承诺与实现不一致」
- **证据**：静态确定 —— 逐个签名核对：`Emitter.emit(eventType:name:data:)`、`BaseFlow.emit` 同签名、`ImmediateFlow.emit` / `AsyncFlow.emit` 直接 `DataEvent(eventType:category:tag:name:data:)`，`priority` 取默认 `2`（`Event.cj:33`），`cancelPrev` 取默认 `0`；`FlowEventFactory` 的 4 个工厂函数也没有这两个参数；脚本面同样不可达——`README.md:85` 明确「脚本**不可用**：事件构造器…」，`JitManualBinding_test.cj:233-238` 另证 `Event.data` 字段都不在注册面。仓内 `priority != 2` 的构造只出现在测试里（`QueuedClosureTask_test.cj:45`、`:72`、`:89-91`、`:129`，均经 `ev(...)` 助手传 `priority`），生产代码无一处。
- **描述**：合并（1 号）、抢占（0 号）、撤销（`cancelPrev`）三条能力写在类注释里并作为「Flow 收到事件后」的行为描述，但 Flow 侧没有任何入口能表达它们：生产流量里所有事件都是 2 号，`takeBatchLocked` 的 `if(priority <= 1)` 分支（`224-238`）与 `submitImmediate`（`108-142`）只被测试覆盖。这既让能力"看起来有、实际用不上"，也让 #1、#2 这两条只影响 0/1 号路径的缺陷长期无人发现（无生产触发）。
- **建议**：二选一并写进 README：给 `emit` 增加 `priority!: Int64 = 2, cancelPrev!: Int64 = 0` 具名参数（`DataEvent` 已支持，改动落在 `Emitter`/`BaseFlow`/`Flow` 三处声明、`ImmediateFlow`/`AsyncFlow` 两个实现与 `FlowEventFactory` 的工厂函数）；或在类注释里明确「优先级仅供宿主直接调用 `submit`，Flow 派发恒为 2 号事件」，并说明为什么不做入口。
- **与第 3 部分的边界**：第 3 部分 #3 讲的是「`ImmediateDispatcher` 路由完全忽略 `priority`/`cancelPrev`」，本条讲「Flow 的 `emit` 无法表达这两个字段 ⇒ `QueuedClosureTask` 的 0/1 分支不可达」，判据文件不同（`Emitter`/`Flow`/`emit` vs `ImmediateDispatcher`），合并时可归到同一根因「优先级只在单点实现」。

### [一般][存量] #5 事件队列无容量上限、无背压、无拒绝路径；`overSizePolicy` 因 `capacity = 0` 永远不生效

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:41`（字段声明）、`54`（`SyncPriorityQueue<QueueEntry>(QueuedClosureTask.compareEntries)`，未传 `capacity`）、`94`（`queue.add`）；容量语义 `f_concurrent/src/SyncPriorityQueue.cj:21-27`（`capacity!: Int64 = 0`）、`f_collection/src/PriorityQueue.cj:103-113`（`capacity > 0` 才走 `overSizePolicy`）、`159-164`（`capacity <= 0` 即「heap is infinity」）
- **来源**：存量（`git blame -L 39,56`：`afb9821e26`/`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §5「无界容器 / 无拒绝路径」、§12.1「有界性」
- **证据**：静态确定（无上限）；增长速度与峰值 **需实测**（见「待验证假设」#2）——`capacity = 0` 在 `PriorityQueue` 里表示无限（`isFull` 只比较内部数组），`DiscardOverSizePolicy` 只在 `capacity > 0` 分支被调用（`104-109`），所以这里的"超限丢弃"策略从未生效。每条 `QueueEntry`（`324-332`）持有一个 `Event`，`DataEvent.data` 是 `Any`（`Event.cj:67`），可以是整包载荷；生产侧是 `AsyncDispatcher` 每事件一条 `spawn`（`AsyncDispatcher.cj:116-128`），消费侧是调用 `exec` 的线程。任务体慢于事件到达时（LLM 步骤、外部 IO），`queue` 单调增长、GC 无法回收，进程内没有任何阈值、TTL、丢弃或拒绝。
- **描述**：按 `backlog × (QueueEntry ≈ 40B + Event ≈ 100–200B + 载荷)` 线性占堆，没有上界也没有观测点（`pending` 只是 `queue.size` 的读取器，没有告警、没有采样）。对长跑服务意味着「压力上来只会表现为 OOM」，而不是明确的拒服务。
- **建议**：构造时给 `capacity`（配 `DiscardOverSizePolicy` 或自定义 `reject` 抛 `GraphException`），或把上限做成配置并在 `submit` 满时快速失败；至少给 `pending` 加周期性打点与阈值告警，让"堆积"可见。

### [一般][存量] #6 0 号事件在提交线程同步 `evaluate`，任务体自提交即无界递归（无深度上限、无环检测）

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:68-74`（`exec` → `submit`）、`90-99`（`immediate` 分支出锁后调 `submitImmediate`）、`108-127`（`submitImmediate` 内 `evaluate` 直接在当前栈执行）
- **来源**：存量（`git blame -L 108,127`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §4「无界递归 / 间接递归」
- **证据**：静态确定（无 `depth` 计数、无队列兜底、无"同一线程已在执行"的标记）；触发需任务体自提交 0 号事件 —— `QueuedClosureTask_test.cj:194-228` 正是这种写法（`slow` 的任务体里 `target.submit(DataEvent(..., name: 'slow', priority: 0))`），说明该模式被当作正常用法并有测试保护。
- **描述**：`exec → submit → submitImmediate → evaluate → (任务体) submit → …` 的递归深度 = 提交链长度，完全由任务体决定。一个"每次运行都重排自己一次"的任务体（常见的自我续跑写法）会一直递归到栈耗尽（崩溃，不是变慢）；同期 `epoch`/`tokenCounter` 正常递增，看不出异常。尾调用不保证优化（清单 §4），不能靠"看起来是尾递归"兜底。
- **建议**：在实例上记录"当前线程正在执行 0 号事件"的标记（或用 `ThreadLocal`）：已在执行时把新 0 号事件**入队**并在当前 `exec` 的 `while(runNext())` 里执行，把递归改成迭代；或保留递归但加 `depth` 上限（如 32）超限抛 `GraphException`，让栈溢出变成可诊断错误。

### [一般][存量] #7 `generation` 对**所有** 0 号事件递增，但注释把它当「被顶替」信号 ⇒ 按注释实现的任务体会误判并交出不完整结果

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:113`（`epoch++` 在 `currentName == e.name` 判定（`114`）之前）、`160-166`（`prop generation`）、`28-29`（注释「其返回结果被丢弃（协作式：Cangjie 无法强杀闭包，任务体可轮询 `generation` 提前退出）」）
- **来源**：存量（`git blame -L 108,125`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §11「注释承诺 A，实现做 B」
- **证据**：静态确定 —— `epoch` 只在一处递增（`113`），无条件；是否真的取消由 `114-123` 决定。两类 0 号事件对 `generation` 的效果相同，对结果的影响相反：同名 ⇒ `token.cancelled = true`，结果被丢弃（`129-131`/`198-200`）；不同名 ⇒ 不取消，结果照常 `accept`（`QueuedClosureTask_test.cj:231-258` 用 `cancelledCount == 0` 且 `events.size == 2` 固定了这条语义）。
- **描述**：任务体按注释"轮询 `generation` 提前退出"时无法区分这两种情况（它不知道"自己"的 epoch 值，只能比较快照）：别的名字提交一条 0 号事件就会让它提前返回，而它的结果**仍会被投递**（未被取消）——流程拿到一个被截断的结果且没有任何错误标记。这是"按文档写就会错"的语义陷阱。
- **建议**：把"是否被顶替"暴露成可查询对象：`prop cancelled: Bool`（读 `currentToken` 对应令牌，且只在该执行期间有效），或让 `evaluate` 拿到 `CancelToken`；`generation` 明确为"存在新 0 号提交"的观测指标，注释改掉"用它提前退出"的建议。

### [轻微][存量] #8 四处同语义实现（取消批处理 / 序列排序 / 令牌临界区 / 排空循环），且已出现行为漂移

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:264-278`（`dropTailByNameAndPriority`）vs `281-295`（`dropTailSamePriority`，只差 `name` 谓词）；`297-307`（`sortBySequenceDesc`）vs `310-320`（`sortBySequenceAsc`，只差比较方向）；`110-126` vs `172-181` 与 `128-140` vs `189-201`（令牌安装/清理临界区逐行同形）；`68-74`（`exec` 的 `while(runNext())`）vs `207-213`（`drain`）
- **来源**：存量（`git blame`：全部 `c6cd191aa5`/`afb9821e26`，2026-11-01）
- **判据**：review-checklist §2「表现形式不同的重复逻辑」
- **证据**：静态确定 —— 差异点已逐项列出：`dropTail*` 只差一个 `item.event.name == name` 条件；排序两版只差 `<` / `>`；令牌两版本应完全同构，但已经漂移出两处不一致：`runNext` 在**锁外** `accept`（`202`）而 `submitImmediate` 在**锁内**（`128-131`）；`runNext` 用 `if(token.cancelled){ return true }` 早退（`198-200`）而 `submitImmediate` 用 `if(!token.cancelled)` 包裹（`129`）。
- **描述**：复制本身是维护成本，但这里的代价已经具体化：`submitImmediate` 的 `accept` 位置（→ #9）与取消判断的写法不同，说明两份临界区在演进中分叉；`dropTail*` 的 `matched → toArray → 插入排序 → 逐个 removeIf` 四步也是两份手抄（`265-277` / `282-294`）。
- **建议**：合并为 `dropTail(priority: Int64, name: ?String, n: Int64)`（`None` 表示不限名）、`sortBySequence(entries: Array<QueueEntry>, ascending: Bool)`（或直接用 `std.sort` 的 `sort(comparator:)`）；把令牌安装/清理抽成 `installToken(name)` / `clearTokenIfCurrent(token)`，`exec` 直接调 `drain()`。

### [轻微][存量] #9 `submitImmediate` 在持有 `mutex` 时调用 `dispatcher.accept`（外部虚函数），与 `runNext` 的锁外投递不一致

- **位置**：`f_egraph/src/base/QueuedClosureTask.cj:128-131`（`synchronized(mutex){ if(!token.cancelled){ dispatcher.accept(result) } … }`）；对照 `202`（`runNext` 在锁外投递）；`dispatcher` 是 `public abstract class Dispatcher`（`Dispatcher.cj:18,47-51`），`accept` 由下游实现
- **来源**：存量（`git blame -L 128,131`：`da88f4bc4a`，2026-11-01）
- **判据**：review-checklist §12.2「临界区只保护不变量；I/O、解析、日志、外部回调一律移到锁外」、§6.2「锁内调用外部回调」
- **证据**：静态确定（调用位置在锁内）；实际影响 **待确认** —— 仓内两个实现的 `accept` 都只是入队（`ImmediateDispatcher.cj:89-91` → `LinkedBlockingQueue.add`；`AsyncDispatcher.cj:67-69` 转发），开销 O(1) 且不阻塞；但 `Dispatcher` 是公开可继承的抽象类，第三方实现的 `accept` 可以做任意事（派发、等待、再入 `submit`）。同线程再入不会死锁（仓颉 `Mutex` 可重入，见「可重入是指线程获取该锁后可再次获得该锁」`stdlib/doc/libs/std/sync/sync_package_api/sync_package_classes.md:8919-8930`），但跨线程若 `accept` 在等一个正在 `submit` 的线程，就会互相等待。
- **描述**：临界区里放了不保护任何不变量的外部调用，且两处入口做法不一致（`runNext` 已经在锁外投递）。修正成本极低，收益是把"锁内未知时长"彻底消掉。
- **建议**：锁内只算 `let dropped = token.cancelled` 并清槽，出锁后 `if(!dropped){ dispatcher.accept(result) }`；与 `runNext` 的形态对齐。

### [轻微][存量] #10 `imports.cj` 有两项全模块零引用的 `internal import`

- **位置**：`f_egraph/src/base/imports.cj:30`（`JitFunction`）、`22`（`Condition`）
- **来源**：存量（`git blame -L 18,35`：`c6cd191aa5`，2026-11-01）
- **判据**：review-checklist §1「无调用者 → 未使用的 import」
- **证据**：静态确定 —— 对 `f_egraph/src` 全量 grep（排除 `imports.cj` 自身）：`JitFunction` 0 处、`Condition` 0 处。`AsyncDispatcher.cj:23-25` 用的是 `endMutex.condition()` 方法而非 `Condition` 类型名，类型由推断得出，不需要该 import。其余 19 项均有引用（`Compiler`/`CompileOptions` 6+、`JitBindSupport` 4、`ClassDescriptor` 15、`PublicCtor` 5、`PublicField`/`PublicMethod` 各 9、`PredefinedFunction`/`JitBindings` 各 2、`LocalType` 28、`DummyDiagnosticsSink` 6、`HostFieldTable` 13、`WeakRef` 2、`MonoTime` 2、`TypeInfo` 6、`LinkedBlockingQueue` 2、`ConcurrentHashMap` 5、`StringGenerator` 2、`ConcurrentHashSet` 8）。
- **描述**：`internal import` 是包级可见（同包各文件无需再写 import，这是本模块 `AsyncDispatcher.cj` 等文件零 import 仍能编译的原因），因此无用项不会被"本文件未使用"的常规 lint 抓到，只会长期留在公共 import 面里误导读者以为这些类型被用到。
- **建议**：删除 `JitFunction` 与 `Condition` 两项；若 `JitFunction` 是为将来扩展预留，加注释说明并接受 lint 提示。

### [轻微][存量] #11 `PriorityQueueBench_test` 把基准塞进单元测试：无断言、毫秒分辨率、对照组不同量纲、固定写 `/tmp`

- **位置**：`f_egraph/src/base/PriorityQueueBench_test.cj:42-51`（`millis()` 用 `DateTime.now().toUnixTimeStamp().toMilliseconds()`、`dump()` 写 `/tmp/pq-bench-*.txt`）、`54-111`（三个 `@TestCase`，`N = 20000`）、`78-80`（对照组用 `remove(at: 0)`）
- **来源**：存量（`git blame -L 34,112`：2026-11 提交）
- **判据**：review-checklist §6.1（证据要求）反向适用：既然没有可复核的对照数据，就不应以"测试"形式产出伪基准
- **证据**：静态确定 —— 三个用例只断言队列被清空（`82`/`96`/`110`），耗时仅落盘不参与判定；1 ms 分辨率下 20k 次 `add`+`remove` 可能整段落入 0–1 ms 区间，落盘值无法区分实现；`testSortedArrayList` 的计时把 `list.remove(at: 0)`（每次 O(n)，共 O(n²)）计入，与堆的 `remove()`（O(log n)）不同量纲，三者不可比；用例在 `src/` 下，`cjpm test` 每次都会跑 3×20000。固定 `/tmp` 路径在非 WSL 环境会失败（项目约定测试在 WSL 跑，可接受，但也说明它不是可移植的基准）。
- **描述**：这份文件唯一能成立的信息是"哪种结构被选中"，真正的结论（谁快、快多少）无法从落盘的一个整数得出；同时它拖慢常规测试。仓内也没有对应的 bench 套件在用它。
- **建议**：改成 `@Bench` 基准或独立 `bench/` 目录（`cjpm bench -O2`、多轮取中位数、输出到 stdout）；对照组只保留语义等价的 `add` + `remove`（去掉 `remove(at: 0)` 或用双端队列替代），并把 `N` 做成参数。

## 优化可行性方案

> 以下不是缺陷，是「还能更好」；两条都**没有改前基线**，只作待验证方向，不进 `todo.md` / `tasks.md`。

### [堆内存] `takeBatchLocked` 每批都 `queue.toArray()` 全量复制一次

- **现状**：`takeBatchLocked`（`QueuedClosureTask.cj:218-248`）每取一批就 `queue.toArray()`（`227`）拿到**整个队列长度**的临时数组，再筛出匹配项、`matched.toArray()`（`232`）再复制一次；批内每个元素还要 `queue.removeIf`（`236`）一次，而 `removeIf` 内部对整个堆数组做一次 O(n) 压实（`f_collection/src/PriorityQueue.cj:239-258`）。等价于每批 O(n) 临时内存 + O(k·n) 堆操作。
- **方案**：给队列加"按 `(priority, name)` 分桶"的二级索引（`HashMap<(Int64,String), ArrayDeque<QueueEntry>>` + 一个按 `(priority, birth, seq)` 取最小桶的堆），批处理直接取整桶、O(k) 出队；或退一步：先 `toArray` 取出全部条目，一次 `removeIf` 删掉本批（`removeIf` 内部只做一次压实），把 k 次 `removeIf` 降为 1 次。
- **预期**：单批临时数组从 O(n) 降到 O(k)；`drain` 一批的开销从 O(k·n) 降到 O(n)（或 O(k)）。峰值内存下降量 ≈ `backlog × 16B`（`Array<QueueEntry>` 引用）级别，量级取决于 backlog。
- **代价**：一次 `removeIf` 需要把整批 `sequence` 放进 `HashSet`（或改用范围谓词），谓词里不能再依赖"逐条删除"；分桶方案则要维护索引与主队列的一致性，复杂度更高。
- **验证**：同机同 SDK `-O2`，固定 `n = 10k`（priority 1，同名与 `n` 个不同名两种分布）× 5 轮取中位数，对比 `getAllocatedHeapSize()` 增量、P50/P99 `drain` 耗时、`cjprof` 中 `PriorityQueue.removeIf`/`toArray` 的自耗时占比。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 批量取批路径的复杂度与排序都还有余量

- **现状**：`priority <= 1` 的批路径实际复杂度是 O(n)（`toArray`）+ O(k·n)（k 次 `removeIf`）+ O(k²)（`sortBySequenceAsc` 插入排序，`310-320`）；`priority >= 2` 的路径只有一次 `queue.remove()`（O(log n)），两条路径差一个量级。`dropTail*`（`264-295`）是同样的 O(n) + O(limit·n)。
- **方案**：① 用一次遍历 + 重建堆替代 k 次 `removeIf`（见上条）；② 批内排序换 `std.sort` 的比较排序（O(k log k)），或利用 `sequence` 单调性用计数/桶排；③ `dropTail*` 合并为一趟收集 + 一趟重建。
- **预期**：批处理与取消两条路径从 O(n²) 降到 O(n log n)；k 较大（同名高频事件合并）时收益最大。
- **代价**：批量删除要靠 `removeIf` 一次谓词完成（`PriorityQueue.removeIf` 已是 O(n) 单趟压实，`f_collection/src/PriorityQueue.cj:239-258`），谓词需支持"整批序号集合"判断；`std.sort` 需要 `Comparator`，会引入一次函数调用开销。
- **验证**：`cjpm bench -O2` 对 `submit`+`drain` 做前后对照（n = 1k/10k/100k，同名比例 0%/50%/100%），报绝对值、中位数、离散程度；`cjprof record` 确认 `removeIf` 是否真的是自耗时大头（否则不做）。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 批量取批的 O(n²)（`toArray` + 逐条 `removeIf` + 插入排序）在 backlog 上千后成为 `drain` 的主要耗时 | `QueuedClosureTask.cj:218-248,310-320` | 各函数自耗时占比、n 多大时劣于 `>=2` 路径 | `cjprof record` 跑「10k 条 priority=1 同名事件 → `drain`」，并发 1/8，看 `removeIf`/`toArray`/`sortBySequenceAsc` 占比 |
| 2 | 事件到达快于任务体执行时 `queue` 无界增长（无背压） | `QueuedClosureTask.cj:41,54,94` | 稳态 backlog 曲线、RSS 增长速率 | 埋点周期性记录 `pending`/`getUsedHeapSize()`/RSS，跑 30 分钟 >消费速率的压测（任务体固定 sleep 50ms，提交 200/s） |
| 3 | `takeBatchLocked` 持锁做 O(n) 工作会拉长 `submit` 的等锁时间（尤其并发提交时） | `QueuedClosureTask.cj:172-181` + `227-244` | 锁等待时长、P99 `submit` 延迟 | 线程状态采样（BLOCKED/WAITING 时长）+ 分段计时，8 线程 submit、backlog 10k |
| 4 | 任务体并发执行在 `AsyncFlow` 场景下的实际触发频率（是否存在同一 task 同名事件并发到达） | `QueuedClosureTask.cj:169-204`；`AsyncDispatcher.cj:116-128` | 生产/压测中同名事件并发度 | 在 `exec` 入口加线程 id + 并发计数埋点，跑 `f_llm` Loom parallel 场景与 `f_rule` 异步流程，统计重入次数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_egraph/src/base/JitManualBinding_test.cj` | .cj | ✅ | 12 个用例覆盖手工绑定面的正反向（字段/`toString`/构造器/注册链/清理/负向）；`BindingTestTask`、`compileError` 均被使用；唯一偏弱处是 `typeTestOnEventSubtypeIsNotAllowed`（`250-254`）只断言 `message.size > 0`，同组的 `castToEventSubtypeIsNotAllowed`（`241-246`）断言了具体文案——属断言偏弱，不单列发现 |
| 2 | `f_egraph/src/base/PriorityQueueBench_test.cj` | .cj | ✅ | 见 #11（伪基准、无断言、量纲不等价、固定 `/tmp`） |
| 3 | `f_egraph/src/base/QueueCapacityRegression_test.cj` | .cj | ✅ | 2 个用例：容量 0 的 `SyncPriorityQueue` 不再死循环（`27-34`）、`QueuedClosureTask.submit` 真实 dispatcher 下 `pending == 1`（`37-43`）；用例本身有效，但只覆盖"不挂死"，未覆盖 `drain`/取消路径 |
| 4 | `f_egraph/src/base/QueuedClosureTask.cj` | .cj | ✅ | 本部分核心，见 #1-#9；`takeBatchLocked` 的批语义、`compareEntries` 的三级比较（priority→birth→sequence，`250-261`）与 `Event.cj:24-25` 承诺一致；`pending` 读 `queue.size` 走队列自身锁（`SyncPriorityQueue.cj:56-62`），不构成 race |
| 5 | `f_egraph/src/base/QueuedClosureTask_test.cj` | .cj | ✅ | 14 个用例；`testPriorityZeroReplacesSameNameExecution`（`194-228`）是本部分 #6 自提交递归的现成写法；`RecordingDispatcher`（`268-313`）是测试替身（空实现有注释说明），不算空实现；**无并发用例**，也没有"任务体抛异常后状态如何"的用例——#1/#2 长期存活的直接原因 |
| 6 | `f_egraph/src/base/StartExecutor.cj` | .cj | ✅ | `execute` 把 `DataEvent` 转 `TaskEvent` 并保留 `session`（`25`），非 `DataEvent` 抛 `GraphException` 带类型名（`27`）；`priority`/`cancelPrev` 未透传，但 `StartEvent`（`Event.cj:76-81`）恒为默认 2/0，当前无可观测差异，不报 |
| 7 | `f_egraph/src/base/Task.cj` | .cj | ✅ | `@JitBind public interface Task`，4 个成员均为对外契约；文件头注释说明宏导入必须逐文件（与 `ClosureTask.cj:18` 一致），无缺陷 |
| 8 | `f_egraph/src/base/TaskExecutor.cj` | .cj | ✅ | 3 个公开工厂 + `execute`（`39-41`）；`newByFlow` 的 `(e as DataEvent).getOrThrow()` 对非 `DataEvent` 抛异常，与 `StartExecutor` 的判定口径一致；三个工厂仓内只有测试使用（`Executor_test.cj:210,231`），属对外 API 不判死代码 |
| 9 | `f_egraph/src/base/imports.cj` | .cj | ✅ | 见 #10；`internal import` 是包级可见（本模块 `AsyncDispatcher.cj` 零 import 仍编译，即证据），其余 19 项均有引用 |
| 10 | `f_egraph/src/egraph.cj` | .cj | ✅ | `FlowInitializer.initialize()`（`37-44`）：建 `Compiler` → `JitHostRegistry.configure` → `ClosureTask.initCompiler` → `lookup<FlowLoader>().load()` → 逐脚本 `FlowScriptRunner.run`；"谁来注册 `FlowInitializer`"由宿主的 `InitializerCollection.register` 完成（`README.md:23-40` 给出 `AppFlowInitializer <: FlowInitializer` + `static init` 的写法，`f_bean/src/BeanInitializer.cj:19-21` 是同模式的仓内范例），因此**不是**接线缺失；`DummyDiagnosticsSink`（`38`）丢弃编译诊断是既有约定，错误仍以异常上抛，不报 |
| 11 | `f_egraph/src/exception/GraphException.cj` | .cj | ✅ | 4 个构造器全部转发 `BaseException`，无额外状态；对外可达 |
| 12 | `f_egraph/src/exception/GraphException_test.cj` | .cj | ✅ | 4 个用例与 4 个构造器一一对应，含 `causedBy` 透传；断言有效 |
| 13 | `f_egraph/src/loader/FlowLoader.cj` | .cj | ✅ | 单方法接口 `load(): ArrayList<String>`，注释即契约（每元素一个流程脚本、空脚本视为配置错误、末条语句须为 `Unit`）；"空脚本抛 `GraphException`"由 `FlowScriptRunner` 实现并由 `FlowInitializer_test.cj:140-141` 覆盖，本文件无缺陷 |

合计：`.cj` 13 个 / `.md` 0 个 / 共 13 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1（并发下顺序与独占不成立）、#2（异常路径状态残留）、#3（session 不一致）、#5（无界无背压）、#6（自提交递归）、#7（`generation` 语义陷阱）；设计 #4（能力只在单点实现）；可读性 #8（四处同形实现）；语言特性：`synchronized` 内早退（`176-178`、`198-200`）与 `Mutex` 可重入语义已按 `sync_package_classes.md:8919-8930` 核对，未据此报缺陷；安全性 0 条——本部分不接外部输入、无 SQL/命令/路径拼接、无凭据与敏感数据 |
| §1 死代码 | 1 | 已逐符号机械检查：本部分 `private` 符号 `submitImmediate`(`98`)、`takeBatchLocked`(`175`)、`compareEntries`(`54`)、`dropTailByNameAndPriority`(`82`)、`dropTailSamePriority`(`85`)、`sortBySequenceAsc`(`233`)、`sortBySequenceDesc`(`272,289`)、测试里的 `ev`/`newTask`/`names`/`configuredCompiler`/`category`/`compileError` 全部有调用者；`internal` 顶层类 `QueueEntry`(`324`)、`CancelToken`(`335`) 只在本文件用（同包内），有引用；`protected` 无新增声明；`public` 成员（`owner`/`pending`/`cancelledCount`/`generation`/`runNext`/`drain`/`submit`/`exec`、`TaskExecutor.newBy*`、`StartExecutor.execute`、`GraphException` 四个构造器）均属对外可达（`egraph.cj:23-24` 的 `public import`），按硬原则一不判——其中 `owner`/`cancelledCount`/`generation`/`runNext`/`drain` 仓内仅测试引用，记为「对外 API，仓内无生产引用」的可见性信息，不作死代码；`return`/`throw`/`continue` 之后无同层语句（`runNext` 的 `return false`/`return true` 均为分支末句）；`import` 命中 #10 两项 |
| §2 重复逻辑 | 1 | 已把 6 个非测试文件的函数体压成「输入→输出→副作用」两两比对：命中 #8（四组同形实现，且令牌临界区已漂移）；判为**不**重复的：`submit` 与 `submitImmediate`（前者做取消+入队，后者做顶替+立即执行，副作用不同）、`compareEntries` 与 `sortBySequence*`（一个是 `Ordering` 三级比较器，一个是原地插入排序）、`RecordingDispatcher` 的空实现（测试替身）、`GraphException` 四构造器（转发目标不同）、`TaskExecutor` 三个工厂（泛型参数与 flow 类型不同） |
| §3 空实现 | 0 | 本部分无 `TODO`/`FIXME`、无 `catch {}`、无 `throw UnsupportedException`：`FlowLoader.load` 是抽象成员（契约由宿主实现，`FlowInitializer_test.cj:40` 有实现）；`RecordingDispatcher` 的 `dispatch`/`doRegisterMulti`/`removeIf`/`register*` 空体有注释「只实现管道所需的接口」（`267`），属测试替身；`FlowInitializer.initialize` 有完整实现（`egraph.cj:37-44`）；`JitManualBinding_test.BindingTestTask.exec` 转发 `body_`，非空实现 |
| §4 栈溢出 | 1 | #6：0 号事件在提交线程同步 `evaluate`，任务体自提交即 `exec→submit→submitImmediate→evaluate→…` 无界递归，深度 = 提交链长度（由任务体决定），无 `depth` 上限、无环检测。其余无递归：`takeBatchLocked`/`dropTail*`/`sortBySequence*` 全为迭代，`drain`/`exec` 是 while 循环 |
| §5 OOM | 1 | #5：`queue` 容量 0 = 无限（`PriorityQueue.cj:159-164`）、`overSizePolicy` 永不生效、无背压/无拒绝；已按「backlog × 单条 ≈ 140–240B + 载荷」给出线性估算与缺失的拒绝路径。其余容器：`sequence`/`epoch`/`tokenCounter` 是标量；`QueuedClosureTask_test.Holder` 是测试对象，无长期持有 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 的「已有性能资料」只给 `docs/LocalMode*.md`，与本部分无关），`PriorityQueueBench_test` 落盘的毫秒数没有对照意义（#11），故不成立任何热点结论；`takeBatchLocked` 的 O(n²)、锁内 `toArray`、队列堆积三项已进「待验证假设」#1-#3 |
| §6.2 大粒度锁 | 1 | #9：`submitImmediate` 持 `mutex` 调外部虚函数 `dispatcher.accept`；当前两个实现都是 O(1) 入队，故只定轻微。`takeBatchLocked` 持锁做 O(n) 工作属"临界区偏大"，与 #9 同源（同一把 `mutex`），未单列，性能面见「待验证假设」#3 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get()`、无批大小配置；相反的问题是"并发没有被串行化"（#1），按正确性报 |
| §6.4 低效算法 | 1 | `takeBatchLocked` 批量路径 O(n)+O(k·n)+O(k²)（`227`/`234-238`/`233`），与 `>=2` 路径 O(log n) 差一个量级；未定为缺陷（无耗时数据），落在「优化可行性方案 [CPU]」+「待验证假设」#1 |
| §7 降堆内存方案 | 1 | 「`takeBatchLocked` 每批 `toArray` 全量复制」（证据状态：无基线，待验证） |
| §8 降 CPU 方案 | 1 | 「批量取批复杂度与批内排序」（证据状态：无基线，待验证） |
| §9 local mode 可行性 | 0 | 不可行：`batch`/`matched`/`entries` 三个临时容器都不在函数内销毁——`batch` 被塞进 `MultiEvent.events`（`185-186`）并随返回值交给 dispatcher，`payload`/`result` 直接逃逸到 `dispatcher.accept`（`130`/`202`），不符合「不逃逸」前提；且需 `--experimental --enable-local-mode`、`ArrayList`/`Array` 需 mode 重载版本，收益只能用峰值内存对照证明（本模块无任何峰值基线） |
| §11 现有代码的 BUG（存量） | 8 | 本轮逐个核对了 13 个文件的边界与空值：`submit` 的 `EmptyEvent`/`cancelPrev` 四分支（`79-89`）、`dropTail*` 的 `n > size` 截断（`273`/`290`）、`sortBySequence*` 的 `position >= 0` 循环（`301`/`314`）、`takeBatchLocked` 的空队列（`245-246`）、`runNext` 的空批早退（`176-178`）、`compareEntries` 的三级比较、`StartExecutor` 的非 `DataEvent` 分支、`GraphException` 四构造器、`FlowInitializer` 的 `lookup` 缺失路径；命中的 8 条为 #1、#2、#3、#5、#6、#7、#9、#11，全部标「存量（快照模式无基线）」 |
| §12 并发安全与锁粒度 | 2 | 共享点与同步手段已逐条列出：`mutex`（`40`）保护 `sequence`/`epoch`/`cancelled`/`currentName`/`currentToken`/`tokenCounter`，`queue` 由 `SyncPriorityQueue` 自身 `Mutex` 保护，锁序恒为「task.mutex → queue.mutex」（`pending` 只取 queue.mutex，无反向路径，不构成死锁）；`cancelled` 的读写都在 `mutex` 内（`118` 写、`129`/`198` 读），可见性成立。**不成立的是"执行段互斥"**：`evaluate`（`188`，及 `127`）在锁外且 `exec` 可被多线程进入（#1），`currentToken` 单槽无法表达多个在途执行（#1），`dispatcher.accept` 在锁内（#9）。锁粒度结论：不是"锁太大"，而是"该串行的段没有串行"；改法见 #1 建议 |
| §14 功能完备性与 README 覆盖 | 1 | #4：`QueuedClosureTask` 注释承诺的 0/1 号语义没有 Flow 入口，`emit` 恒为 2 号（`Emitter.cj:19`、`Flow.cj:41`、`ImmediateFlow.cj:126`、`AsyncFlow.cj:153`、`FlowEventFactory.cj:31-46`），属"能力只接了单点"。README 覆盖归第 1 部分（本部分无 `.md`），本部分只核对了源码注释与实现的一致性；另记一句范围外提示：`README.md:913` 只列出 `QueuedClosureTask` 的 API 名，没有任何一段说明 0/1/`cancelPrev` 的使用条件（该缺口由第 1 部分的 README 覆盖条统一处理，此处不重复计数） |
| 文件覆盖（§13 等） | 13/13 | 无缺失文件；`files/f_egraph.part4.txt` 的 13 行全部在「文件覆盖」表中出现且已读。本部分无 `.md`，§13 文档一致性不适用（模块文档由第 1/2 部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分是「队列化任务 + 手工 JIT 绑定测试 + 模块初始化 + 异常/加载器契约」的组合，代码量最小（13 个文件约 1360 行，其中 5 个是测试），但**唯一的核心类 `QueuedClosureTask` 承担了本模块最重的并发契约**，严重与一般问题几乎都集中在这里：

- 这个类的设计是「一把锁保护队列与取消令牌，任务体在锁外执行」——单线程驱动下自洽（测试全是单线程 `drain`），可它被 `AsyncFlow` 以「每事件一条 `spawn` 线程」的方式调用（`AsyncDispatcher.cj:116-128` + `AsyncFlow.cj:127-131`），于是①执行段没有任何互斥、②`currentToken` 单槽装不下多个在途执行、③投递顺序与 `birth` 脱钩。这是 #1，本部分唯一的严重项，也是唯一必须优先修的：它把"顺序执行"的契约在最常见的异步用法下变成不成立。
- 与之配套的三条"状态机卫生"问题同样值得同批处理：#2 异常路径不清令牌槽（导致取消计数不可信、批事件无声丢失）、#7 `generation` 被当成"被顶替"信号（按注释写就会误判并交出不完整结果）、#3 批量的 `session` 凭空重置（会话关联错位）。
- #4 与 #5 是能力面问题：优先级/抢占/撤销只写在注释里，Flow 入口表达不了（#4），队列又没有容量上限与拒绝路径（#5）。两者叠加的现状是——"高级能力"只在测试里跑，"容量风险"在生产里没有护栏。
- 轻微项都是低成本可清的：#8 的四处同形实现（且令牌临界区已经漂移，正是 #9 的来源）、#9 锁内调外部回调、#10 两个无用 `internal import`、#11 把伪基准放进单测。

阻塞项：#1（并发下契约不成立 + 任务体数据竞争）。建议同批修 #2（异常清理）与 #7（取消信号）——它们都在同一段临界区里，改一次比改三次便宜。#3、#4、#5 可排期，但 #4 需要产品/API 决策（要不要把 `priority` 放进 `emit`）。#8-#11 是清理项，其中 #8 应先做，因为 #9 的正确修法就是"把两份临界区合成一份"。

正面之处：`takeBatchLocked` 的批语义（同优先级同名、跨非相邻位置合并）与 `compareEntries` 的三级稳定比较（`priority → birth → sequence`）实现清晰，`sequence` 的唯一性保证了堆序确定；`submit` 对 `EmptyEvent`/`cancelPrev` 的四个分支与 `dropTail*` 的 `n > size` 截断都做了边界处理；`GraphException` 与 `FlowLoader` 的契约薄而明确，`FlowInitializer` 的初始化链（compiler → host registry → `initCompiler` → loader → runner）责任划分干净，且"由宿主注册 `FlowInitializer`"的约定在 README 与仓内范例（`BeanInitializer`）里对得上。测试的主要缺口**不是覆盖数量**（`QueuedClosureTask_test` 有 14 条），而是**并发与错误路径**：没有任何多线程用例，也没有"任务体抛异常后状态如何"的用例——这正是 #1/#2 能长期存活的原因；`PriorityQueueBench_test` 则把"看起来在测性能"变成了误导。

存量缺陷共 11 条（严重 1 / 一般 6 / 轻微 4），是否纳入修复清单待用户决定；本部分不替用户拍板，也未改动任何源码。
