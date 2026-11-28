# f_egraph 模块审查报告

> **模块第 2/4 部分**（本报告只覆盖 `files/f_egraph.part2.txt` 列出的 20 个文件：`doc/spec/f-egraph-jit-flow-init/` 下的 3 个 `.md`，以及 `src/FlowScriptRunner.cj`、`src/FlowInitializer_test.cj` 与 `src/base/` 下 `Accepter` → `EndExecutor` 的 15 个 `.cj`。`README.md`、`design.md`、`proposal.md`、`flow-script/spec.md` 及 `Event` / `ImmediateDispatcher` / `JitHostRegistry` / `QueuedClosureTask` 等其余 38 个文件由第 1/3/4 部分产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_egraph`（本部分 17 个 `.cj` + 3 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，`git status --porcelain f_egraph` 为空，无 diff 可比 ⇒ 全部问题记「存量」；`git blame` 抽样：关键行集中在 `4be871f2fd`（2026-10-02），`AsyncFlow.cj:79` 为 `8f86940889`（2026-10-24））
- **审查重点**：图算法/流程调度正确性、递归与栈溢出、OOM 与无界增长、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 2/4 部分）
- **验证口径**：本轮不跑构建、不跑测试（reviewer 铁律），所有结论为静态阅读 + 语言/标准库文档现场核对；凡涉及频次、占比、耗时的一律只进「待验证假设」

## 发现

### [严重][存量] #1 `AsyncDispatcher.dispatch()` 每次 `start()` 派生一个**永不退出**的消费线程，线程数随流程启动次数线性增长

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:138-148`（`140` `spawn{`、`141` `while(let event <- getEvent())`），调用方 `f_egraph/src/base/AsyncFlow.cj:148`（`start` 每次都 `getDispatcher().start(...)` → `AsyncDispatcher.start` `70-74` → `dispatch()`）；同源另一处 `AsyncDispatcher.cj:30-36`（构造器里的清理线程 `while(true){ removeIf; sleep }`）
- **来源**：存量（`git blame -L 138,148` 全为 `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §5「无界容器 / 长期持有」、§12.1「有界性」、§11「契约与实现不符」
- **证据**：静态确定 —— 三层文档核对后结论唯一：
  1. `spawn` 就是新建一个仓颉线程（语言文档 `cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/create_thread.md:3`「要创建一个新的仓颉线程，可以使用关键字 `spawn`」）；
  2. `getEvent()` 转调 `ImmediateDispatcher.getEvent()` → `eventQueue.remove()`，而 `LinkedBlockingQueue.remove(): E` 的语义是「如果队列为空，则阻塞等待」（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:561-567`）；
  3. `getEvent()` 的返回类型是非 `Option` 的 `Event`（`AsyncDispatcher.cj:162`、`ImmediateDispatcher.cj:106`），所以 `while(let event <- getEvent())` 的绑定永远成立 ⇒ 该线程只会在空队列上永久阻塞，**没有任何退出路径**（构造器里的 `while(true)` 同理）。
- **描述**：`AsyncDispatcher.start()` 是 `accept(event); dispatch()`，于是**每一次流程启动**都新增一个常驻消费线程。这些线程共享同一个 `eventQueue`，谁被唤醒谁处理事件（见 #2、#4 的连带后果）。服务端每次异步流程启动 = 一个永久线程（默认栈保留 + 调度实体），启动 1 万次就是 1 万个线程 ⇒ 线程创建失败 / RSS 失控。另外构造器里的「定时清理线程」在正常路径上几乎清不掉任何条目：`end` 里存的是 `WeakRef<EndExecutor>`（`111`），而 `EndExecutor` 同时被 `ImmediateDispatcher.executors` 强引用（`ImmediateDispatcher.cj:52` 的 `doRegister('EndExecutor', ...)`），弱引用不会失效，只有 `removeIf` 注销执行器后才会命中——付出一个常驻线程换到几乎为零的清理量。
- **建议**：消费循环移出 `dispatch()`，改成「`AsyncDispatcher` 构造时启动 1 个消费者」或用有界线程池（`spawn` 数 = 核数/固定窗口）驱动 `getEvent()`；`dispatch()` 只做「确保消费者已启动」的幂等操作（`AtomicBool` / 一次性初始化）。清理线程改为跟随生命周期（提供 `close()` 或用 `WeakRef` + 退出标志），并说明为什么不能只靠 `get()` 时顺带清理。

### [严重][存量] #2 结束事件按「消费线程的**创建者**线程 id」单槽登记 ⇒ 并发启动会取错结果，跨线程 `get()` 永久阻塞

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:108-115`（`111` `this.end[tid] = WeakRef(end, DEFERRED)`）、`116-128`（`tid` 由 `dispatch()` 在 `139` 捕获后逐层透传）、`87-89`（`tryGet` 用 `Thread.currentThread.id` 取键）、`70-74` + `AsyncFlow.cj:148`
- **来源**：存量（`git blame -L 75,115` 全为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入」、§11「语义与命名/契约不符」
- **证据**：静态确定 —— 键的产生与消费明显不是同一个东西：
  - 写：`dispatch()` 在**调用 `start()` 的线程**上取 `tid`（`139`），该 `tid` 被闭包捕获，之后这个消费线程处理**任意**流程的事件时，都仍用这个 `tid` 登记结束执行器（`118` → `111`）；
  - 读：`tryGet()` 用的是**调用 `get()` 的线程**的 id（`88`）。
  于是有两个互相独立的错配：
  1. **队列是全局的、消费者是每启动一个**：线程 A 启动的流程，其 `StartEvent` 可能被线程 B 那次 `dispatch()` 派生的消费者取走，于是结束执行器被登记在 `end[B]` 下。结果 A 的 `get()` 等不到自己的结果（永久阻塞），B 的 `get()` 可能拿到 A 的结束事件（数据错投）。
  2. **同一线程上的两个在途流程共用一个槽**：`end` 的键只有线程 id，第二次 `start()` 的 `notifyEnd` 直接覆盖第一次的条目；第一次 `get()` 拿到的是第二个流程的 `EndExecutor`，第二个 `get()` 永久阻塞。`AsyncDispatcher_test.cj:24` 的注释「用例都从同一线程发起并等待，`AsyncDispatcher` 用线程 id 关联结束事件」等于把这一限制写成了使用前提，但 `AsyncEndExecutorGetter`（`AsyncEndExecutorGetter.cj:18-20`）与 `Dispatcher.get()` 都没有任何注释声明「必须同线程、且同线程只能有一个在途流程」，`AsyncFlow.start()` 返回的又是**共享的 dispatcher 本身**（`AsyncFlow.cj:148-151`），调用方完全无从得知。
- **建议**：把「一次启动」的关联标识显式化——`start()` 返回一个 per-start 的句柄（内含 `EndExecutor` 或 `Future`），`AsyncDispatcher` 内部用自增序号/`Event.session` 做键，而不是线程 id；至少在 `AsyncEndExecutorGetter` 与 `AsyncFlow.start` 的注释/README 里写清线程约束，并让「同线程并发启动」直接抛异常而不是静默覆盖。

### [严重][存量] #3 条件等待不循环、醒后直接 `getOrThrow()` ⇒ 被无关的 `notifyAll` 唤醒即抛 `NoneValueException`；同一线程第二次 `get()` 永久阻塞

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:75-86`（`83` `endCondition.wait()`、`84` `tryGet().getOrThrow()`）；同一模板的另一份拷贝 `f_egraph/src/base/ConcurrentEndExecutor.cj:33-44`（`41-42`）
- **来源**：存量（`git blame -L 75,86`、`-L 33,44` 均为 `4be871f2fd`）
- **判据**：review-checklist §12.1「条件等待：条件变量虚假唤醒未在循环里重查条件」、§11「边界/空值未处理」
- **证据**：静态确定 —— `notifyAll()` 在 `112` 是被**任意线程的任意一次结束事件**触发的（`end` 是全局 map），而 `get()` 只 `wait()` 一次，醒来后不校验「我要的 `tid` 是否真的有值」，直接 `tryGet().getOrThrow()`。两个线程各自等自己的流程时，先完成的那一方会把另一方从 `wait()` 唤醒，被唤醒者 `tryGet()` 返回 `None` → `getOrThrow()` 抛 `NoneValueException`（异常类型与语义都对调用方完全不可预期，且不是 `GraphException`）。
  另外 `tryGet()`（`87-89`）是**破坏性**的（`end.remove(...)`）：同一线程对这个 getter 调两次 `get()`，第二次先 `remove` 到 `None`，然后进锁 `wait()`，此后再没有 `notifyAll` 会针对它发生 ⇒ 永久阻塞。行为上「取一次就失效」没有任何文档说明。
- **建议**：改成标准的「循环 + 谓词」写法：`while (true) { if (let Some(v) <- tryGet()) { return v }; if (!endCondition.wait(timeout: remain)) { return None } }`，把 `tryGet` 拆成「非破坏性 peek」+「成功后 remove」；`wait()` 的返回布尔值不要丢弃（`wait(timeout)` 返回 `Bool`，见 `sync_package_interfaces.md:77-79`）。

### [严重][存量] #4 管线异常只抛在被 `spawn` 的线程里，等待方没有任何通知 ⇒ `get()` 永久阻塞且异常被静默吞掉

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:116-121`（`asyncExecute` 的 `spawn` 内直接 `executor.accept(event)`，无 try/catch）、`129-137`（`133` `throw GraphException(...)`）、`122-128`（`asyncDispatch` 再套一层 `spawn`）
- **来源**：存量（`git blame -L 116,137` 为 `4be871f2fd`）
- **判据**：review-checklist §3「静默吞异常 / 开关打开后走进空分支」、§11「错误处理缺失或静默」、§12.1「异步语义：Future 异常被吞」
- **证据**：静态确定 —— 任务体抛异常（`TaskExecutor.execute` → `task(event)`，`TaskExecutor.cj:39-41`；`BarrierTask.exec` 的 `GraphException`，`BarrierTask.cj:89`；`ErrorExecutor` 必然抛异常）发生在 `spawn` 出来的线程里，异常终止该线程；`notifyEnd`（`118`）只在「执行器是 `EndExecutor`」时才触发（`109`），失败路径既不发 `end`、也不 `notifyAll`、也不记录错误 → 调用方 `get()` 永久阻塞（无超时版本连兜底都没有），异常信息只留在被杀掉的线程里。`AsyncDispatcher_test.cj:118` 的注释「`toThrowIfNoExecutor = true` 时异常在 dispatch 线程内抛出，用例侧只断言『拿不到结束事件』」已经把这一行为当成既定事实。
- **建议**：`asyncExecute` 外层 `try { ... } catch (e: Exception) { 记录 error 到 slot; notifyAll }`，把异常挂到 per-start 句柄上，让 `get()` 抛 `GraphException(cause: e)`；`doDispatch` 的「无执行器」也不要只 `throw` 在消费线程，应回填到该 `tid` 的结果槽。`get()` 增加可选的超时重载，避免无界等待。

### [严重][存量] #5 结束执行器「先登记、后赋值」，且 `EndExecutor.end` 被无同步读取 ⇒ `start().get().get()` 的第二次 `get()` 可能读到 `None` 或永久看不到写入

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:116-121`（`118` 先 `notifyEnd` 登记并唤醒，`119` 才 `executor.accept(event)`）、`f_egraph/src/base/EndExecutor.cj:22-31`（`22` `private var end = None<Event>`，`23-25` `execute` 赋值，`26-31` `tryGet`/`get` 直接读，无锁无原子）
- **来源**：存量（`git blame` 对应区间均为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性 / 发布逸出」、§11「并发正确性」、§3「`case None => ()` 当兜底把错误吃掉」（`getOrThrow` 版本）
- **证据**：静态确定 —— 写读之间存在真实的先后与可见性缺口：
  1. 顺序：`notifyEnd` 在 `110-113` 里先 `end[tid] = ...` 再 `notifyAll()`，**然后**才在 `119` 调 `executor.accept(event)`；`EndExecutor.accept` → `execute`（`EndExecutor.cj:23-25`）才是给 `end` 赋值的地方。等待方被唤醒后 `AsyncDispatcher.get()` 立刻返回这个 `EndExecutor`，紧接着调用 `.get()`（`EndExecutor.cj:29-31`）读 `end`——此时写者可能还没执行到赋值语句，直接 `None.getOrThrow()`。
  2. 可见性：`EndExecutor.end` 是普通 `var`（`22`），`notifyAll` 时持锁释放的是 `endMutex`，而写 `end` 发生在**解锁之后**，读者拿同一把锁也建立不了与这次写之间的 happens-before；`tryGet`/`get` 本身又完全不加锁。按语言并发模型（`cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/sync.md` 第 1 节：共享可变状态必须用原子/锁/通道保护），这是一处数据竞争，读者可能长期读到 `None`。
  也就是说 `AsyncFlow.start(...).get().get()` 的正确性只依赖「写者比读者先跑完」，而不是任何同步手段；`AsyncDispatcher_test.blockingGetReturnsEnd`（`AsyncDispatcher_test.cj:50-60`）这类用例存在偶发 `NoneValueException` 的理论可能。
- **建议**：把「赋值」移到「登记」之前（先 `executor.accept(event)`，再 `notifyEnd`）；`EndExecutor.end` 改用 `AtomicReference`/`AtomicOption`（或整个 `EndExecutor` 读写都走同一把 `Mutex`），`get()` 用条件变量等到非空，而不是 `getOrThrow`。

### [严重][存量] #6 `BarrierTask.exec` 的并发累积无任何同步：非线程安全 `ArrayList` 并发 `add` + 「检查数量-然后-发射-删除」 ⇒ 丢数据/重复发射

- **位置**：`f_egraph/src/base/BarrierTask.cj:82-96`（`85` `datas.computeIfAbsent(key){ArrayList<Any>()}`、`86` `list.add(de.data)`、`91` `list.size >= count`、`92-93` `emit` + `datas.remove(key)`）
- **来源**：存量（`git blame -L 82,96` 全为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 检查-然后-写入 / 用并发容器就当复合操作原子」、§11「并发正确性」
- **证据**：静态确定 —— `datas` 是 `ConcurrentHashMap`（`42`），但**值**是普通 `ArrayList<Any>`，而同一 `BarrierKey`（同一 `category/tag/eventName/session`）的多个事件会被 `AsyncDispatcher` 的 `asyncExecute` 派到**不同线程**并发执行（`AsyncDispatcher.cj:116-121`），于是：
  1. `list.add` 并发写同一个 `ArrayList` → 元素丢失/内部数组损坏（`ConcurrentHashMap` 只保证 map 结构安全，不保护 value）；
  2. `list.size >= count` 与 `datas.remove(key)` 之间没有原子性 → 两个线程可同时通过判断，各 `emit` 一次（下游流程被重复触发），随后一个线程 `remove` 后另一个把新事件加进已被摘下的 list（彻底丢失）。
  这是把「并发容器」当成「复合操作原子」的典型误用。
- **建议**：改成 `ConcurrentHashMap<BarrierKey, Mutex>` + 在锁内做「add → 判数量 → 取出并清空 → 锁外 emit」，或直接 `datas.compute(key) { ... }` 的原子重映射（在映射函数内只做累积与计数，返回 `null` 表示触发，再把要发射的 list 带出来，emit 放锁外）。

### [严重][存量] #7 `AsyncFlow` 构造期的 `flows` 判重是 check-then-act ⇒ 并发构造同一 `(category, tag)` 会重复登记 Multi 执行器，`MultiEvent` 被重复扇出

- **位置**：`f_egraph/src/base/AsyncFlow.cj:75-81`（`77` `if(!flows.contains(this))`、`78` `registerMultiEventTask()`、`79` `flows.add(this)`），`135-137`（注册走 `Dispatcher.registerMultiTask` → `ImmediateDispatcher.doRegister(executor)`，后者只 `add` 不查重：`ImmediateDispatcher.cj:54-58`）
- **来源**：存量（`blame`：`77-78` 为 `4be871f2fd`，`79` 为 `8f86940889`（2026-10-24，即 `tasks.md 0.6` 的补丁））
- **判据**：review-checklist §12.1「检查-然后-写入：容器线程安全不代表组合操作原子」、§11「并发正确性」
- **证据**：静态确定 —— `flows` 是 `ConcurrentHashSet`（`73`），但 `contains` 与 `add` 之间有窗口。两个线程同时 `AsyncFlow(c, t)`（这是公开构造器，也是 `registerTaskByAsyncFlow`（`Flow.cj:91-93`）与「宿主用新实例启动」的既定用法，见 `FlowInitializer_test.cj:228`）→ 两边都看到 `contains == false` → 两边都 `registerMultiEventTask()` → `ImmediateDispatcher.executors` 里同一 `Event(Multi, c, t, "Multi")` 键下出现 2 个 `TaskExecutor`（`doRegister` 无查重）→ `dispatch` 遍历该 list（`ImmediateDispatcher.cj:78-83`）把 `MultiEvent` 扇出两次 → 每个子事件被执行两次（重复的业务副作用）。`AsyncFlow.start()` 同一时刻也被多个线程调用是服务端的常态，窗口很容易命中。
- **建议**：`if (flows.addIfAbsent(this)) { registerMultiEventTask() }`（先原子占位再注册），或在 `AsyncDispatcher` 的 `mutex` 内完成「判重 + 注册」；`ImmediateDispatcher.doRegister(executor)` 对 Multi 也应查重，避免任何路径产生重复执行器。

### [一般][存量] #8 `BarrierTask` 未达阈值的聚合数据永不回收：以 `session` 为键的无界增长

- **位置**：`f_egraph/src/base/BarrierTask.cj:42`（`datas` 定义）、`85-94`（只在达到阈值时 `datas.remove(key)`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §5「无界容器：全局 HashMap 随请求增长，GC 后条目仍在」、§7「有界化」
- **证据**：静态确定 —— `BarrierKey` 含 `session`（`18-27`），而 `session` 默认是每个事件新生成的 UUID（`Event.cj:32`）。任何「事件数没凑够 `count`」的会话（上游失败、客户端断开、部分事件被 `removeIf` 清掉）都会在 `datas` 里永久留下「key + 该会话已收到的 `Any` 引用」。量级：`Σ(未完成会话数) × 平均已收条目数 × 8B 引用`，无上限、无 TTL、无淘汰，且 `BarrierTask` 是长生命周期对象（注册在 dispatcher 里）。同样，`ArrayList` 在 `remove(key)` 后即被丢弃，没有复用/收缩。
- **建议**：给 `datas` 加容量/TTL（例如「会话首次写入时间 + 超时清理」，或复用 dispatcher 已有的 `clearTimerDuration` 循环做定期清空），并在 `count` 长期不满足时打点/告警；`sessions` 维度按 `category/tag` 分片便于整体清理。

### [一般][存量] #9 `Condition.wait` 的超时余量可能 ≤ 0，抛 `IllegalArgumentException` 而不是返回 `None`

- **位置**：`f_egraph/src/base/AsyncDispatcher.cj:99`（`endCondition.wait(timeout: timeout - (MonoTime.now() - start))`）、`f_egraph/src/base/ConcurrentEndExecutor.cj:53`（`condition.wait(timeout: timeout)`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11「边界差一 / 契约与实现不符」；标准库文档 `sync_package_interfaces.md:83`「如果 `timeout` 小于等于 `Duration.Zero`，抛出 `IllegalArgumentException`」
- **证据**：静态确定 —— `tryGet(timeout:)` 的契约是「超时返回 `None`」（`AsyncEndExecutorGetter.cj:19` 与 `AsyncDispatcher_test.cj:128` 的负向用例都这么用），但先做了一次快速 `tryGet()`，若这一步耗时 ≥ `timeout`（极短超时、GC 停顿、被抢占），`timeout - elapsed` 为负 ⇒ `wait` 抛 `IllegalArgumentException`，调用方拿到的不是 `None` 而是异常。`timeout = Duration.Zero` 时同样直接抛。`ConcurrentEndExecutor.get(timeout:)` 把用户传入值原样透传，问题相同。对照：`LinkedBlockingQueue.remove(timeout)` 对负值「立即执行并返回结果」（`collection_concurrent_class.md:595-601`），两处 API 的负值语义并不一致，更容易写错。
- **建议**：`if (remain <= Duration.Zero) { return None }` 后再 `wait`；或统一用 `waitUntil(predicate, timeout)`（`sync_package_interfaces.md:107-133`）把「条件 + 超时」交给标准库处理。

### [一般][存量] #10 `AsyncFlow` 的全局可变状态无同步；`initDispatcher` 可重复覆盖，旧 dispatcher 的执行器与线程被静默遗弃

- **位置**：`f_egraph/src/base/AsyncFlow.cj:19-26`（`private static var dispatcher`，`20-22` 无条件覆盖、`24-26` 测试用清空）、`27`（`dependencied_`）、`73`（`flows`）、`96-98`（`getDispatcher` 直接 `getOrThrow`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」、§14.1「接线缺失：开关只在一处判断」
- **证据**：静态确定 ——
  1. `dispatcher` 是普通 `static var`，`initDispatcher` 写入、每个 `AsyncFlow` 构造/启动读，无锁、无原子 ⇒ 按语言并发模型属数据竞争（`sync.md` 第 1 节）；典型调用点是启动期单线程，但 `initDispatcher` 是 `public`，测试里就被反复调用（`AsyncFlow_test.cj:38,46`、`BarrierTask_test.cj:58`、`FlowInitializer_test.cj:222`）。
  2. 覆盖后果不止「旧实例没人引用」：旧的 `AsyncDispatcher` 及其常驻线程（#1）继续存活，而 `flows`（`73`）里仍记着旧 dispatcher 上注册过的流程 —— 再次 `AsyncFlow(c, t)` 时 `flows.contains` 为真 ⇒ **跳过** `registerMultiEventTask()`，但新 dispatcher 里根本没有这些执行器。也就是「重新初始化」之后流程会静默失去 Multi 扇出，随后 `start` 抛「No executor found」，且无法自愈。
  3. `dependencied_` / `flows` 只在 `remove()` 路径清理，未 `remove()` 的流程永久驻留（有界于 `(category, tag)` 数量，属轻度泄漏）。
- **建议**：`dispatcher` 改为 `AtomicReference` 或用 `Mutex` 保护的「只允许初始化一次 + 显式 `reset()`」；`initDispatcher` 被二次调用时要么抛异常要么先清理旧实例（停线程、清 `flows`/`dependencied_`）；`flows` 与 dispatcher 的生命周期绑定到同一个对象上，避免两套全局状态不同步。

### [一般][存量] #11 `removeIf` 谓词里构造 `AsyncFlow` 带注册副作用：在 `HashMap.removeIf` 迭代中可能修改同一个 map

- **位置**：`f_egraph/src/base/AsyncFlow.cj:57-72`（`59-68` 是传给 `dispatcher.removeIf` 的谓词，`61` `let flow = AsyncFlow(category: category, tag: e.tag)`，`62` `flow.canBeRemoved()`，`69-71` 循环后删 `flows`）；谓词在被 `AsyncDispatcher.removeIf`（`103-107`）持有 `mutex` 时执行，最终落到 `ImmediateDispatcher.executors.removeIf`（`ImmediateDispatcher.cj:103-105`）
- **来源**：存量（`blame`：`57-72` 中 11 行为 `4be871f2fd`、5 行为 `8f86940889`）
- **判据**：review-checklist §12.1「迭代与修改并发」、§3「开关打开后走进空分支」、§11「语义与注释不符」
- **证据**：静态确定（机制）/ 待确认（可达状态）——
  - 谓词里 `AsyncFlow(...)` 不只是读：构造器在 `flows` 里查不到时会**注册执行器**（`77-79`）。若 `executors.removeIf` 正在遍历 `executors` 而谓词往同一个 `HashMap` 里 `computeIfAbsent(...).add(...)`，属「迭代中修改容器」，结果取决于 `HashMap.removeIf` 的实现（抛并发修改异常、漏删或结构损坏）。
  - 可达状态需要「dispatcher 里存在某 tag 的执行器，但该 tag 不在 `flows`」：直接调 `AsyncDispatcher.registerStart/registerTask`（公开 API）注册、`canBeRemoved()` 在 `62` 抛异常导致 `69-71` 的 `flows.remove` 未执行（执行器已删、`flows` 残留的相反情况）、或 #10 的 dispatcher 覆盖都会造出这种状态。
  - 代码注释（`50-56`）把重排的理由写成「`AsyncDispatcher` 的 `mutex` 不可重入 —— 同一次 `removeIf` 里删集合会在下一个事件上自锁」。这条理由与标准库文档相反：`std.sync.Mutex` 是**可重入**的（`sync_package_classes.md:8927-8930`「可重入是指线程获取该锁后可再次获得该锁」；`sync.md:350` 同义）。真正的风险是上面的「迭代中改 map」以及「重复登记 Multi」，不是自锁（另见 #15）。
- **建议**：谓词里只做纯判断（按 `category/tag` 过滤），把「构造实例 / 判依赖 / 删 `flows`」全部移到 `removeIf` 返回之后（对自己收集的 `(category, tag)` 列表做）；`AsyncFlow` 构造器也不要带注册副作用，把「注册 Multi」显式成 `ensureRegistered()`。

### [一般][存量] #12 D11 的「开始事件名回退」只做在 `start`，`registerTask` 仍只看本地 `startName` ⇒ 宿主新实例无法给已注册流程补任务，且错误消息误导

- **位置**：`f_egraph/src/base/AsyncFlow.cj:142-152`（`start` 在本地为空时回退到 `getDispatcher().startEventName(...)`）vs `117-126`（`registerTask` 仍在 `118` 用本地 `startName.size == 0` 判定并抛 `GraphException`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §14.1「只做了一半的分支」、§11「语义与命名/注释不符」
- **证据**：静态确定 —— 回退的动机在 `Dispatcher.cj:34-39` 写得很清楚：「流程的 `startName` 是实例字段，宿主在初始化后新建的实例读不到脚本里登记的名字」。这个理由对 `registerTask` 同样成立：宿主 `AsyncFlow(c, t)` 新建实例后想追加一个任务，`registerTask` 会走 `118` 抛「There must be with StartExecutor before registering first TaskExecutor」——而 dispatcher 里**确实**已经注册了 StartExecutor（`startEventName` 能查到），错误消息与事实相反。要么这是有意的「任务只能由脚本注册」，那就应在接口注释里写明；要么是 D11 漏改一处。
- **建议**：`registerTask` 的 `startName` 取值改成与 `start` 相同的回退逻辑（抽 `private func effectiveStartName(): String`），或在注释里明确「宿主实例只允许 `start`/`emit`，任务必须在脚本里注册」。

### [一般][存量] #13 测试的全局状态与真实时钟等待，与 `f-egraph-test-coverage` 的「用例隔离 / 不依赖真实时钟」条款不符

- **位置**：`f_egraph/src/FlowInitializer_test.cj:219-233`（`asyncScriptRequiresInitDispatcher` 调 `AsyncFlow.initDispatcher()` 覆盖全局 dispatcher，且**未** `remove()`）、`276-296`（`readmeExampleScriptRuns` 同样只 `start` 不 `remove`）、`f_egraph/src/base/AsyncDispatcher_test.cj:128,137`（`tryGet(timeout: Duration.millisecond * 200)` 的负向用例要真的等 200ms）
- **来源**：存量（`blame` 为 `4be871f2fd`）
- **判据**：review-checklist §13「规格与实现漂移」；承诺源 `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-test-coverage/spec.md:13`（「不依赖外部服务、网络或真实时钟等待」）、`:18`（「流程用例使用的 `category` 唯一并在结束时清理」）、`tasks.md:295`（5.5 全局状态隔离，勾选为已完成）
- **证据**：静态确定 —— 上述两个用例既没有在结束处 `flow.remove()`（对比同文件 `syncScriptRegistersRunnableFlow:115`、`twoScriptsRegisterTwoFlows:133-134` 都有），又用 `initDispatcher()` 把全局 dispatcher 换掉：先于它们注册的 `AsyncFlow` 会留在旧 dispatcher 上（#10 的第 2 点），后于它们构造的同 tag 流程会因为 `flows` 判重跳过 Multi 注册。`AsyncDispatcher_test` 的负向断言用 200ms 真实等待，属于 spec 明令避免的「真实时钟等待」，在慢 CI 上可能抖动（`removeIfDropsExecutors` 期望 200ms 内取不到结果，慢机器上若派发晚于 200ms 反而会变红）。
- **建议**：两个用例补 `flow.remove()`（或 `finally` 里清理）；把「重置 + 初始化 dispatcher」收敛成测试夹具的 `@BeforeAll` 一次性动作，并提供 `AsyncFlow.resetDispatcherForTest()`（已有，`AsyncFlow.cj:24-26`）在 `@AfterEach` 里清空；负向用例改成「注入一个永不完成的执行器 + 立即断言 `isNone()`」，或用可控时钟/注入的 `Condition` 替身避免真实等待。

### [轻微][存量] #14 重复逻辑：`ClosureTask.exec` 与 `evaluate` 函数体逐字相同；`AsyncDispatcher` 与 `ConcurrentEndExecutor` 是同一份「双重检查 → wait → getOrThrow」模板

- **位置**：`f_egraph/src/base/ClosureTask.cj:141-143` vs `146-148`；`f_egraph/src/base/AsyncDispatcher.cj:75-102` vs `f_egraph/src/base/ConcurrentEndExecutor.cj:33-57`
- **来源**：存量（`ClosureTask.cj:141-148` 为 `afb9821e26`/`8f86940889`；其余 `4be871f2fd`）
- **判据**：review-checklist §2「只改类型名 / 换控制流，语义相同」
- **证据**：静态确定 ——
  1. `ClosureTask.exec` 与 `protected evaluate` 都只有一行 `body_(e)`。`evaluate` 的注释说「不经过 `exec` 的入队逻辑」，但 `ClosureTask` 本身没有任何入队逻辑（入队逻辑在子类 `QueuedClosureTask.exec` 里，`QueuedClosureTask.cj:76-83`），所以这句注释和这份重复都不成立：`exec` 直接写 `evaluate(e)` 即可，子类仍能覆盖 `exec`。
  2. `AsyncDispatcher.get()` / `tryGet(timeout:)` 与 `ConcurrentEndExecutor.get()` / `get(timeout:)` 是同一个「锁外快速判定 → 加锁 → 再判定 → `wait` → `getOrThrow`」模板的两份拷贝（差异只有返回类型与等待的目标），并且两份**带着同样的缺陷**（#3、#9）。这正是「近似重复里少一处边界判断」的典型：修一处必须记得修另一处。
- **建议**：`ClosureTask.exec` 改为 `evaluate(e)`；抽出 `private func awaitValue<T>(mutex, cond, probe: () -> ?T): T`（带 timeout 重载）供两个类共用，把 #3/#9 的修法只写一遍。注意 `AsyncDispatcher` 的 5 个 `register*` 包装（`37-56`）虽形状相同但目标方法不同，**不**算重复逻辑，保持现状即可。

### [轻微][存量] #15 代码注释与变更记录声称「`AsyncDispatcher` 的 `mutex` 不可重入」，与标准库文档相反

- **位置**：`f_egraph/src/base/AsyncFlow.cj:53-56`（「`AsyncDispatcher` 的 `mutex` 不可重入 …… 会在下一个事件上自锁」）；同一论断在 `doc/spec/f-egraph-jit-flow-init/tasks.md:223-225`（「原在 `removeIf` 谓词内删 `flows` …… 而自锁」）
- **来源**：存量（`4be871f2fd`；`tasks.md` 同批次）
- **判据**：review-checklist §10「可读性/可维护性：必要注释（尤其是『为什么这样写』）」、§13「文档与实现一致性」；反证文档 `sync_package_classes.md:8927-8930`、`sync.md:350`（「`Mutex` 在设计上是一个可重入锁……再次尝试获取同一个 `Mutex` 锁，永远可以立即获得」）
- **证据**：静态确定 —— `synchronized(x)` 的锁对象是 `Lock`，这里就是 `std.sync.Mutex`，文档明确可重入；`ImmediateDispatcher` 内部也没有第二把锁。因此「同一次 `removeIf` 里删集合会自锁」这个因果链不成立（真实风险是 #11 的迭代中改 map、以及重复登记 Multi）。留着的危害是：它把一个错误的约束写进了代码与变更记录，后续维护者会据此继续做不必要的重排，或反过来误判真实死锁风险。
- **建议**：改写注释，说明真正的约束（谓词内不要产生注册副作用 / 不要在 `removeIf` 遍历中改 map），并在 `design.md` D9/D11（第 1 部分范围内）同步更正。

## 优化可行性方案

> 以下都不是缺陷（缺陷见上），是「还能更好」；**全部没有改前基线**，故只作待验证方向，不进 `todo.md` / `tasks.md`。

### [CPU] 把「事件 → 两层 spawn」换成有界执行器

- **现状**：每个事件至少 2 次线程创建：`asyncDispatch`（`AsyncDispatcher.cj:123`）→ 每个执行器一次 `asyncExecute`（`117`）；`AsyncTaskExecutor.execute` 还会再 `spawn` 一次（`AsyncTaskExecutor.cj:36-40`）。线程创建 + 调度 + 栈分配的单次开销远大于事件本身的路由成本，且 `spawn` 无上限、无复用（`spawn` 语义见 `create_thread.md:3`）。
- **方案**：`AsyncDispatcher` 持有固定大小的 `ThreadPool`/`Executor`（复用 `f_concurrent` 或 `f_pool` 里的能力，若已有；否则用固定 worker 数 + 有界队列），`doDispatch` 只提交任务；`AsyncTaskExecutor` 直接复用同一执行器而不是自己 `spawn`。
- **预期**：线程数与并发度解耦（常数 vs ∝在途事件数）；线程创建开销从「每事件 2 次」降到「每 worker 一次」。端到端收益取决于事件处理体本身的耗时占比（未测）。
- **代价**：并发模型从「无界并行」变为「有界并行」，长任务可能互相排队，需要评估单任务耗时；`spawn` 的「线程即隔离」语义（异常不传染）会变成「线程池内异常」——必须配合 #4 的异常回填，否则会把单个坏任务升级成 worker 丢失。
- **验证**：同机同 SDK `-O2`，固定输入（例如 10k 个事件、4 阶段流程、并发 8），对比 `cjprof record` 中线程创建/调度占比与 P50/P99 端到端延迟、峰值线程数（`/proc/<pid>/status` 或运行时统计）。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 缩小 `removeIf` 的临界区，别在 `mutex` 内跑用户谓词

- **现状**：`AsyncDispatcher.removeIf`（`103-107`）与 `getExecutors`（`149-153`）都在 `mutex` 内调用 `dispatcher` 的方法，前者还把**调用方传入的谓词**（公开 API `predicate: (Event) -> Bool`）整个包在临界区里；`AsyncFlow.doRemove` 的谓词会构造对象、算 hash、查 `flows` 集合、可能拼异常消息（`AsyncFlow.cj:59-68`）。
- **方案**：`removeIf` 改为「锁内只做快照/标记 + 锁外执行谓词 + 再次加锁确认删除」，或让 `ImmediateDispatcher` 维护「category → tag → 事件」的索引，把 `O(全部执行器)` 的遍历降为按 `category` 定位。
- **预期**：锁持有时间从 `O(全部注册事件) + 谓词耗时` 降到 `O(该 category)`，注册/启动路径的偶发长尾减少（未测）。
- **代价**：快照 + 二次确认会引入 ABA/竞态，需要明确「谓词执行期间新注册的执行器是否也要删」的语义；实现复杂度上升。
- **验证**：`cjprof` 看 `removeIf`/`registerStart` 的阻塞时长，或加埋点记录 `mutex` 等待时间（P99），在「每秒启动 N 个流程 + 周期性 remove」的压测下对照。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `BarrierTask.datas` 与 `eventQueue` 的有界化

- **现状**：`BarrierTask.datas`（`BarrierTask.cj:42`）按 `session` 累积 `ArrayList<Any>`，只有凑满阈值才删（见 #8）；`ImmediateDispatcher.eventQueue` 用 `LinkedBlockingQueue<Event>()` 无参构造 → 容量 `Int64.Max`（`collection_concurrent_class.md:2789`），生产者（`emit`，任何线程）快于消费者时无条件堆积。
- **方案**：`datas` 加「会话 TTL + 总条目上限」，超限按最旧会话淘汰并打点；`eventQueue` 改为显式容量（例如按 `--queue-capacity` 之类的配置），满时对生产者施加背压（阻塞或拒绝 + 明确异常）而不是无限追加。
- **预期**：等待中的会话不再无界累积；队列峰值内存可估算（容量 × 单事件大小），从「到 OOM 才知道」变成「有明确上限与拒绝路径」。
- **代价**：背压会把压力传导回 `emit`/`start` 调用方，需要确认框架侧是否接受阻塞；TTL 淘汰会让「慢会话」丢失聚合数据（需业务确认可接受）。
- **验证**：多轮压测下 `getAllocatedHeapSize()` + RSS 是否达到有界稳态（`mem §1.2`），并统计「被淘汰会话数 / 队列拒绝次数」。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 线程-per-事件（两层 `spawn`）的创建/调度开销占端到端耗时的主要部分 | `AsyncDispatcher.cj:117,123`、`AsyncTaskExecutor.cj:37` | 线程创建 + 调度自耗时占比、10k 事件下的线程峰值 | `cjprof record` 跑 4 阶段流程 × 10k 事件、并发 8；同时采 `Thread.getAllThreads()`/`/proc/<pid>/status` 的线程数曲线 |
| 2 | 每次 `start()` 一个常驻消费线程会把 RSS 推到不可接受（默认栈保留 × 启动次数） | `AsyncDispatcher.cj:138-148` | 单线程栈实际占用、连续 1 万次启动后的 RSS/线程数 | 循环 `AsyncFlow.start` 1 万次（不 `get`）后采 RSS 与线程数；对照改为单消费者版本 |
| 3 | `BarrierTask` 的未完成会话在真实业务里占比很低，因此 #8 的内存增长是慢性的而非突发 | `BarrierTask.cj:42,85-94` | `datas.size` 随时间/请求量的曲线、未完成会话比例 | 给 `datas` 加 `size` 打点，跑 30 分钟稳态 + 20% 失败注入 |
| 4 | `removeIf` 在 `mutex` 内的持有时长已成为注册路径的长尾 | `AsyncDispatcher.cj:103-107`、`AsyncFlow.cj:59-68` | `mutex` 等待时间 P99、执行器总数 | 埋点记录 `synchronized` 前后时间差，压测「频繁 start + 周期性 removeExceptCurrentTag」 |
| 5 | 并发构造同一 `(category, tag)`（#7）在真实调用图上是否可达 | `AsyncFlow.cj:75-81` | 运行期 `AsyncFlow(...)` 构造的并发度、重复构造次数 | 在构造器加计数器（同 tag 并发进入次数），跑真实网关流量或 100 并发 `start` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-jit-binding/spec.md` | .md | ✅ | 归档变更的 spec delta；与 `ClosureTask`/`Dispatcher` 实现逐条核对一致（`ClosureTask` 4 项校验、`compile` 包裹、`JitHostRegistry` 注册面在其它部分）；`BaseFlow` 7 方法命名与 `Flow.cj:18-42` 相符 |
| 2 | `f_egraph/doc/spec/f-egraph-jit-flow-init/specs/f-egraph-test-coverage/spec.md` | .md | ✅ | 见 #13：`13` 行「不依赖真实时钟等待」、`18` 行「结束时清理」被 `FlowInitializer_test` / `AsyncDispatcher_test` 违反 |
| 3 | `f_egraph/doc/spec/f-egraph-jit-flow-init/tasks.md` | .md | ✅ | 见 #13（5.5 勾选与代码不符）、#15（`:223-225` 的「自锁」论断与 std 文档相反）；`7.2` 的 121/121 无法静态核实 |
| 4 | `f_egraph/src/FlowInitializer_test.cj` | .cj | ✅ | 见 #13；其余用例断言与 `FlowScriptRunner`/D11 实现一致 |
| 5 | `f_egraph/src/FlowScriptRunner.cj` | .cj | ✅ | 空脚本抛 `GraphException`（`33-35`）；被 `egraph.cj:42` 调用，非死代码 |
| 6 | `f_egraph/src/base/Accepter.cj` | .cj | ✅ | 公开接口，`TaskExecutor`/`Dispatcher`/`Executor` 实现；对外可达，不判死代码 |
| 7 | `f_egraph/src/base/AsyncDispatcher.cj` | .cj | ✅ | 见 #1-#5、#9、#11、#13、#14 |
| 8 | `f_egraph/src/base/AsyncDispatcher_test.cj` | .cj | ✅ | 见 #13（`:128`、`:137` 真实时钟等待）；`:118` 注释自认异常在派发线程内丢失（#4） |
| 9 | `f_egraph/src/base/AsyncEndExecutorGetter.cj` | .cj | ✅ | 仅 `tryGet(timeout:)`；**无任何线程约束注释**（#2 的证据之一） |
| 10 | `f_egraph/src/base/AsyncFlow.cj` | .cj | ✅ | 见 #2、#7、#10、#11、#12、#15 |
| 11 | `f_egraph/src/base/AsyncFlow_test.cj` | .cj | ✅ | `:24-26` 每次用例换 category；`:31,38` 重置/重建全局 dispatcher（#10、#13） |
| 12 | `f_egraph/src/base/AsyncTaskExecutor.cj` | .cj | ✅ | `execute` 内 `spawn`（`36-40`）；仓内仅 `Executor_test` 引用（对外可达的 public，按硬原则一不判死代码） |
| 13 | `f_egraph/src/base/BarrierTask.cj` | .cj | ✅ | 见 #6、#8 |
| 14 | `f_egraph/src/base/BarrierTask_test.cj` | .cj | ✅ | `:58` 调 `initDispatcher`（#10、#13）；`barrierTaskEmitsWhenThresholdReached` 只覆盖单线程路径，未覆盖 #6 的并发累积 |
| 15 | `f_egraph/src/base/ClosureTask.cj` | .cj | ✅ | 见 #14；`initCompiler`/`ensureCompiler` 有锁，惰性创建正确；`evaluate` 被 `QueuedClosureTask.cj:127,188` 调用 |
| 16 | `f_egraph/src/base/ClosureTask_test.cj` | .cj | ✅ | 10 个用例覆盖构造/编译成功/4 类失败/惰性创建，与 spec 场景一一对应 |
| 17 | `f_egraph/src/base/ConcurrentEndExecutor.cj` | .cj | ✅ | 见 #3（`:41-42`）、#9（`:53`）、#14；仓内仅 `Executor_test` 引用（public，对外可达） |
| 18 | `f_egraph/src/base/Dispatcher.cj` | .cj | ✅ | `internal registerMultiTask`/`startEventName` 均被 `AsyncFlow.cj:136,146` 使用；`protected doRegisterMulti`/`doStartEventName` 由两个 dispatcher 实现（非死代码） |
| 19 | `f_egraph/src/base/Emitter.cj` | .cj | ✅ | 公开接口，被 `BaseFlow`/`ImmediateFlow`/`AsyncFlow` 实现 |
| 20 | `f_egraph/src/base/EndExecutor.cj` | .cj | ✅ | 见 #5（`22` 普通 `var end`，`26-31` 无同步读取） |

合计：`.cj` 17 个 / `.md` 3 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性见 #1-#13；设计见 #2（把「一次启动」的关联退化在线程 id 上）、#12；语言特性见 #5（普通 `var` 跨线程读写）、#9（`Condition.wait` 的负超时语义）；可读性见 #14、#15；安全性 0 条——本部分不处理外部输入、无 SQL/命令/路径拼接、无凭据 |
| §1 死代码 | 0 | 已逐符号执行机械检查：`private`/文件内私有的 `log`/`mutex`/`endMutex`/`end`/`endCondition`/`dispatcher`/`notifyEnd`/`asyncExecute`/`asyncDispatch`/`doDispatch`/`getExecutors`/`getEvent`（AsyncDispatcher）、`dependencied_`/`flows`/`h`/`startName`/`hasFirstTask`/`doRemove`（AsyncFlow）、`name_`/`events_`/`datas`/`acceptable`/`producing`/`flow`（BarrierTask）、`compilerMtx`/`sharedCompiler`/`name_`/`acceptable_`/`producing_`/`body_`/`ensureCompiler`/`stringEvents`（ClosureTask）、`end`（EndExecutor）、`run`（FlowScriptRunner）全部有引用；`internal` 的 `Dispatcher.registerMultiTask`/`startEventName` 被 `AsyncFlow` 使用，`FlowScriptRunner` 被 `egraph.cj:42` 使用；`AsyncFlow.resetDispatcherForTest`/`ClosureTask.resetCompilerForTest` 只被 `*_test.cj` 引用，按 §1「仅测试使用」只算可见性建议、不算死代码；`protected` 的 `Dispatcher.dispatch`/`doRegisterMulti`/`doStartEventName` 有实现与调用，`ClosureTask.evaluate` 属 `public open class` 的成员且被 `QueuedClosureTask` 调用；`public` 声明经 `egraph.cj:23` 的 `public import` 对外可达，按硬原则一不判（`AsyncTaskExecutor`/`ConcurrentEndExecutor` 仓内只有测试引用，记「对外 API，仓内无引用」）；逐个检查 `return`/`throw`/`continue` 之后无同层语句，无 `if(false)`，无未使用的 `import`（`internal import` 集中在 `imports.cj`，被同包文件共用） |
| §2 重复逻辑 | 2 | 已把本部分 17 个 `.cj` 里可执行函数体压成「输入→输出→副作用」逐一比对：命中 #14 的 (a) `ClosureTask.exec`/`evaluate`（同体）、(b) `AsyncDispatcher`/`ConcurrentEndExecutor` 的等待模板；`AsyncDispatcher` 的 5 个 `register*` 包装虽形状相同但目标方法不同，判为不重复；`AsyncDispatcher.tryGet()` 与 `tryGet(timeout:)` 是同一包装的两种形态（保留）；测试里的 `scriptsOf`/`list`（`FlowInitializer_test.cj:54-60` vs `ClosureTask_test.cj:33-39`）属「测试准备代码」误报边界，不报 |
| §3 空实现 | 2 | `BarrierTask.exec` 在 `flow` 未注入时 `flow?.emit` 静默不发射、却照样 `datas.remove(key)`（`92-93`），聚合数据静默丢失；`AsyncFlow.doRemove` 在 `dispatcher == None` 时 `dispatcher?.removeIf` 静默不做事（`59`）。两处都无注释说明「为什么可以空」。其余无空函数体、无 `TODO`、无 `catch {}` |
| §4 栈溢出 | 0 | 本部分无自递归/间接递归：`multiEventTaskBody`（`Flow.cj:48-60`）是迭代；`AsyncTaskExecutor`/`AsyncDispatcher` 的嵌套是「新线程」而非调用栈，不加深栈帧。跨层同步嵌套（`registerTaskByFlow` 在同一线程里启动子流程）在 `Flow.cj:74-77`，属第 1 部分范围，本轮不展开 |
| §5 OOM | 3 | #1（线程数随启动次数无界）、#8（`BarrierTask.datas` 无界）、以及 `eventQueue` 容量 `Int64.Max`（`ImmediateDispatcher.cj:20`，本部分只作为 #1 的背压缺失一并说明，容器本身归第 3 部分）。另核对过 `AsyncDispatcher.end`：`EndExecutor` 同时被 `executors` 表强引用，条目数有界于线程 id 数量，**不构成泄漏**（排除一个候选） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 只给了 `docs/LocalMode*.md`，与本部分无关），热点未成立；线程创建开销与 `removeIf` 锁持有时间已列入「待验证假设」#1、#4 |
| §6.2 大粒度锁 | 0 | `mutex` 的临界区内容已核对（转调 `ImmediateDispatcher` 的 map 操作、`removeIf` 谓词），未测持有时长与竞争线程数，按规则只进「待验证假设」#4 与优化方案「缩小 `removeIf` 临界区」；`endMutex` 只保护条件等待，`get()` 期间不持 `mutex`，无锁顺序嵌套（`mutex`→`endMutex` 不存在），未发现死锁组合 |
| §6.3 并发串行 | 1 | #1 的反面问题：不是并发度=1，而是**并发度无界**（每次 `start` 一个消费者，每个事件两层 `spawn`）。没有 `spawn` 后立刻 `get()` 的形态（`get()` 在调用方线程），`Batch=1` 形态不存在 |
| §6.4 低效算法 | 0 | `doRemove` 的 `removeIf` 是 `O(全部执行器)` 遍历，但只在流程移除时触发、无频次数据，不成立为发现（已进待验证假设 #4）；`canBeRemoved` 的字符串拼接只在异常路径 |
| §7 降堆内存方案 | 1 | 「`BarrierTask.datas` 与 `eventQueue` 有界化」，证据状态：无基线（待验证） |
| §8 降 CPU 方案 | 2 | 「有界执行器替代两层 spawn」「缩小 `removeIf` 临界区」，均为无基线（待验证） |
| §9 local mode 可行性 | 0 | 本部分的临时对象（`BarrierKey`、`ArrayList<Any>`、`StartEvent`）几乎全部**逃逸**到队列/执行器/跨线程（`accept`→`eventQueue`、`emit`→下游流程），不满足 local region 的逃逸约束；且需 `--experimental --enable-local-mode`、`String`/`Array` 需 mode 重载版本，收益只能靠峰值内存对照证明——本模块无任何峰值基线，故判「不可行/无证据」，不进方案 |
| §11 现有代码的 BUG（存量） | 13 | 本部分 17 个 `.cj` 的函数边界与空值已逐个核对（含 `BarrierTask` 阈值/空事件列表、`ClosureTask.compile` 的 4 类校验、`AsyncFlow.start` 的空 `startName`、`EndExecutor.get` 的未设置态、`AsyncDispatcher` 的超时余量）；命中的 13 条存量缺陷见 #1-#13，全部标「存量（快照模式无基线）」 |
| §12 并发安全与锁粒度 | 6 | 共享路径逐条列出：`AsyncDispatcher.end`（`ConcurrentHashMap`+`WeakRef`，按 tid 单槽，见 #2/#5）、`AsyncDispatcher.endCondition`（#3）、`AsyncDispatcher.dispatcher`/`mutex`（转调无竞态，`accept` 只碰线程安全队列）、`AsyncFlow.dispatcher/flows/dependencied_`（#7、#10）、`BarrierTask.datas`+`ArrayList`（#6）、`EndExecutor.end`（#5）；`ClosureTask.compilerMtx` 已正确加锁（惰性初始化在锁内完成，无双重检查漏洞）。锁粒度结论见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 1 | #12（D11 只做一半）。README 覆盖归第 1 部分（`README.md`/`README_en.md` 不在本部分文件清单），本部分只核对接口注释：`AsyncEndExecutorGetter` 无注释、`EndExecutor.get()` 的「未设置即抛」无说明，已并入 #2/#5 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；`files/f_egraph.part2.txt` 的 20 行全部在「文件覆盖」表中出现且已读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 7 |
| 一般 | 6 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分的风险不在「图算法复杂度」（流程路由就是 map 查表，`Event` 的 `hash` 预计算、`BarrierKey` 四字段哈希都没问题），而在**异步调度层的并发契约**：`AsyncDispatcher` 用「线程 id 当一次启动的标识」「每次 `start` 派生一个常驻消费者」「先登记结束执行器、后填值」「失败路径不通知等待方」四件事叠在一起，使得任何「同线程两个在途流程」「多线程并发启动」「任务抛异常」都会退化成永久阻塞或取到别人的结束事件。这 7 条严重问题里有 6 条集中在 `AsyncDispatcher.cj` 一个文件（约 160 行），根因是同一个设计决定（把 per-start 的结果槽放在全局 map 的线程 id 上，且结果槽的发布没有同步），修法也集中在同一个方向：per-start 句柄 + 有界执行器 + 条件等待循环 + 异常回填。

阻塞项：#1（线程无界增长）、#2（结果错投/永久阻塞）、#3（`NoneValueException`）、#4（异常吞掉后 `get()` 永挂）、#5（发布早于赋值的数据竞争）—— 这 5 条都会在真实服务端流量下出现，且表现为「调用方永久挂起」这类最难排查的故障，建议一并修复后再对上层流程能力做信任性评估。#6（`BarrierTask` 并发累积）取决于是否存在同一 session 的并发事件，属条件触发但后果是数据错乱，同样应优先。一般级 6 条（`BarrierTask` 无界累积、`Condition.wait` 负超时、`AsyncFlow` 全局状态、`removeIf` 谓词副作用、D11 半实现、测试隔离）可以排期；两条轻微问题（重复的等待模板、错误的「Mutex 不可重入」注释）修起来很便宜，但 #15 的错误论断会误导后续对死锁的判断，建议顺手改掉。

代码质量的正面之处：`ClosureTask` 的校验与惰性编译器（`compilerMtx` 全程持锁，无双重检查漏洞）写得很干净；`FlowScriptRunner` 的契约（空脚本抛异常、末句必须 `Unit`）与注释、测试三方一致；`Dispatcher` 用 `internal` 转发 + `protected` 抽象承接「抽象成员不能是 `internal`」的语言限制，处理得体并有注释说明。测试覆盖度本身不差（`ClosureTask_test` 10 条、`AsyncDispatcher_test` 7 条、`FlowInitializer_test` 10 条覆盖了主路径与失败路径），缺的是**并发路径**的用例：#2/#3/#6/#7 目前一条测试都没有，`BarrierTask_test.barrierTaskEmitsWhenThresholdReached` 只跑了单线程，这也是这些问题能长期存活的直接原因。

存量缺陷共 15 条（严重 7 / 一般 6 / 轻微 2），是否纳入修复清单待用户决定；本部分不替用户拍板，也未改动任何源码。
