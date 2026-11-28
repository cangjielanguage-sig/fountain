# f_concurrent 模块审查报告（第 2/3 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_concurrent`（34 个源文件；本部分覆盖 15 个：`LoadBalance` / `LoadBalance_test` / `RateLimiter` / `RateLimiterClose_test` / `SlidingWindowRateLimiter` / `SyncPriorityQueue` / `TokenBucketRateLimiter` / `eventbus/{EndEvent, Event, EventBus, JobQueue, Worker, exception/EventBusException}` / `exception/{ConcurrentException, LoadBalanceException}`）
- **基线**：工作区快照 `8c0ce643a`（`sts/1.3.x`；工作区除 `docs/review/`、`reviews/` 外干净，无 diff）⇒ 本部分全部缺陷记「存量」
- **审查重点**：负载均衡、限流器、优先队列、EventBus/Worker/JobQueue 的并发正确性与生命周期、锁粒度、死锁、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part2`，最终由主 Agent 合并为 `docs/review/f_concurrent_review_20261128.md`）

## 发现

### [严重][存量] `RoundRobin.next()` 的「取值 + 回绕」分两段加锁：并发下返回越界权重，负载均衡失效或抛 `NoneValueException`

- **位置**：`f_concurrent/src/LoadBalance.cj:35-49`（`v = current` 与 `current += step` 同锁，但回绕在另一段 `synchronized` 且 `:41` 在锁外读 `current`）；消费点 `f_concurrent/src/LoadBalance.cj:88-90`（`tree.forward(algo.next()).next().getOrThrow()`）、`:114-124`（`iterator` 越界时 `forward` 为空 ⇒ 静默从头绕回）
- **来源**：存量（`git blame -L 35,49` → `4be871f2fd` 2026-10-02，早于 HEAD `8c0ce643a`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 读-改-写非原子）；§11（边界越界、契约与实现不符）
- **证据**：静态确定 —— 设 `max=2.0, step=1.0, min=0.5`：T1 在 `:37-40` 取 `v=1.5` 并把 `current` 写到 `2.5`；T1 尚未执行 `:41-47` 回绕时，T2 在 `:38` 读到 `current=2.5` 作为 `v` 返回。`v > max` 时 `tree.forward(2.5, inclusive: true)` 为空。
- **描述**：仓内有三个并发消费点在请求路径上并发调用该算法：`f_dbd/src/multid/Datasource.cj:114`（`loadbalance.call(())` 借数据库连接）、`f_net/src/client/MultiClient.cj:228`（RPC 客户端 `iterator()` 取第一个节点）、`f_llm/src/llm/LLMConfsHolder.cj:211-214`（LLM 节点选择，`RoundRobin<Int64>(1, 1, total)`）。后果分两档：`call` 路径直接 `getOrThrow()` 抛 `NoneValueException`（`f_dbd` 只 catch `ConnectionException`，异常会冒到业务层）；`iterator` 路径静默回退到键最小的节点（= 最先 add 的节点），并发越高越频繁，权重/轮询形同失效，单节点被打满。附带 `:41` 在锁外读 `current`（普通字段，非原子）本身也是数据竞争。
- **建议**：把取值与回绕放进同一个临界区：`synchronized(mutex){ let v = current; current += step; if (current > max) { current = min }; v }`，删掉第二段加锁。补一条「N 线程并发调 `next()`（N=16、10⁵ 次）断言返回值始终 ∈ [min, max]」的用例；`f_dbd` 的 `call` 路径再补一条并发借连接的回归用例。

### [严重][存量] `EventBus.arrangeAndGet` 的完成通知不可复用：`notified` 置真后永不复位 + `notify()` 只唤醒一个等待者

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:288`（`private let notified = AtomicBool(false)`）、`:311-333`（`get` 的判定顺序）、`:340-346`（`deliver` 里 `notified.store(true)` + `condition.notify()`）；条件变量与锁 `:32-35`
- **来源**：存量（`git blame -L 288,288` / `-L 340,346` → `4be871f2fd`）
- **判据**：review-checklist §12.1（可见性用普通信号、条件等待未重查条件、异步语义）；§11（契约与实现不符）
- **证据**：静态确定 —— 全类只有 `:343` 一处 `notified.store(true)`，没有任何 `store(false)`；而 `:315` / `:321` 把它当作「本次调用已完成」的判断。第二次调用在结果尚未投递时先 `datas.remove` 得 `None`，随后 `notified.load()` 为 `true` ⇒ `:316` 直接返回 `None<T>`，不再等待。另外 `std.sync.Condition.notify()` 文档是「唤醒一个等待在关联互斥体上的线程」（`sync/sync_package_api/sync_package_interfaces.md:21-27`），而结果按 `arrangedThreadId` 存在全局 map 里，被唤醒的线程未必是目标线程。
- **描述**：单线程连续调用两次即失效（第二次立即拿到 `None`，且事件仍在跑，稍后 `deliver` 把结果塞进 `datas` 无人消费，留成陈旧条目）；多线程并发等待时，`notify()` 唤错线程 ⇒ 目标线程在 `condition.wait(timeout: Duration.Max)` 上永久挂起，被误唤醒的线程因 `notified` 已真而拿到 `None`。README:375 把 `arrangeAndGet` 列为公开方法，但仓内无任何调用者、无测试，缺陷被完全掩盖。
- **建议**：不要用全局布尔当完成信号。最小改法：`datas` 只放「本次调用的结果槽」，每个等待者用自己的 `Mutex`+`Condition`（或 `AtomicOptionReference<Result<T>>` + 自旋/条件）等待；或保留全局 `condition` 但改为 `notifyAll()` 且把 `notified` 换成按线程 id 的「已投递」集合、消费后即清除；`timeout` 分支必须 `datas.remove(threadId)` 清掉残留。补「同一 EventBus 串行两次 `arrangeAndGet`」与「16 线程并发 `arrangeAndGet`」两条用例。

### [严重][存量] Worker 的事件链没有异常隔离：ability 未注册或抛异常直接杀死工作线程

- **位置**：`f_concurrent/src/eventbus/Worker.cj:40-60`（`spawn` 的 `while` 循环内 `:49` `this.abilities[e](e)`，全段无 `try/catch`）、`:88-94`（`force` 同样直接调用 `abilities[ee](ee)`）；`abilities` 是 `ConcurrentHashMap`，下标访问缺键即抛异常（`:26`）
- **来源**：存量（`git blame -L 40,60` → `4be871f2fd`）
- **判据**：review-checklist §12.1（异步语义：异常被吞 / 线程生命周期）；§3（静默吞异常、失败路径不闭环）；§11（错误处理缺失）
- **证据**：静态确定 —— 事件被 `arrange` 入队后由 worker 线程执行；`abilities[e]` 对未注册事件抛 `KeyNotFoundException`，ability 内部任何异常也沿 `:49` 冒出。外层只有 `while`，没有捕获；线程终止后该 worker 的队列再无人消费，`deliverIfNeed`（`:58`）也不会执行。
- **描述**：一条坏事件（未注册的 event、ability 里一次 NPE/越界）就永久损失一个 worker；该 worker 队列里后续事件全部滞留（只有 `seize` 线程可能把任务偷走，且偷走后仍会在别的 worker 上因同一事件再次失败）。若走 `arrangeAndGet`，调用方拿不到结果。`EventBus` 没有任何 worker 存活监控，故障是静默的。
- **建议**：worker 循环用 `try { 链式执行 + deliverIfNeed } catch (e) { 记录日志 + 以失败完成该事件（至少 `event.setNoneData()` 后 `deliverIfNeed`）}` 包住，且不退出循环；`force` 的同步路径也要把异常转成「事件失败」而不是抛给调用者（或明确文档化为抛出）。对未注册事件，在 `arrange` 入口先查 `abilities` 并抛带事件名的 `EventBusException`，把错误暴露在提交侧而不是消费侧。补「ability 抛异常后 worker 仍能处理下一条事件 / `arrangeAndGet` 立即返回」用例。

### [一般][存量] `WorkerStrategy.New` 未实现：被并入 `CurrentThread`，在调用线程同步跑完整条事件链

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:94-105`（`:103` `case CurrentThread | New => currentThreadStrategy`）；承诺源 `f_base/src/WorkerStrategy.cj:62-67`（`New` 的文档：「创建新实例，如果是任务队列就创建新线程……用完即弃」）
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现 / 只做了一半的分支）；§11（契约与实现不符）
- **证据**：静态确定（双证）—— 枚举文档承诺「创建新线程」，`genDoArrange` 把 `New` 与 `CurrentThread` 合并到同一个 `currentThreadStrategy`（`EventBus.cj:193-195` → `arrange(id, e, true)` → `:249-251` 在调用线程 `force`），代码中没有 `spawn` 分支对应 `New`。
- **描述**：选择 `New` 的调用方期望「不占原工作线程、用完即弃」，实际是同步阻塞当前线程（对 `arrangeAndGet` 意味着调用线程要等整条链跑完，且期间无法处理其它事）；且 `New` 与 `CurrentThread` 的行为完全一致，枚举值等于摆设。
- **建议**：为 `New` 单独实现策略：`spawn { workers[workerId].force(event) }`（与 `arrange(..., currentThread=false)` 的 `:252-257` 分支一致），并明确「新线程不回收、每事件一条线程」的代价；或在文档中删掉 `New` 的线程语义并改名。补一条「`New` 策略下 `arrange` 不阻塞调用者」的用例。

### [一般][存量] `SyncPriorityQueue` 的 `capacity` / `overSizePolicy` 形同虚设：队列永远扩容，实际无界

- **位置**：`f_concurrent/src/SyncPriorityQueue.cj:21-54`（四个构造/工厂入口都只透传 `capacity` 与 `overSizePolicy`）、`:18`（`<: Queue<T> & Growable`）；被透传对象 `f_collection/src/PriorityQueue.cj:103-113`（`if (capacity > 0 && size >= capacity) { if (growOnFull) doOffer else overSizePolicy.reject }`）、`:114-131`（`doOffer` 的 `while (isFull()) grow()`）、`:130-146`（`grow` 直接翻倍）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符、配置项未接线）；§5（无界容器 → OOM）；§14.1（配置被读取却从未生效）
- **证据**：静态确定 —— `PriorityQueue` 的 `growOnFull` 默认 `true`，`SyncPriorityQueue` 没有暴露该参数，因此 `capacity > 0 && size >= capacity` 时永远走 `doOffer` 分支，`overSizePolicy` 分支不可达；`capacity` 只影响首次分配大小。README:348-349 却把 `init(comparator, capacity, overSizePolicy)` 作为可用参数列出。
- **描述**：调用方按 README 传 `capacity: 1000, overSizePolicy: DiscardOverSizePolicy` 会得到一个**无界**队列：超限不丢弃、不拒绝，而是翻倍扩容，直到 OOM。`f_egraph` 目前用默认 `capacity: 0`（本就无界）不受影响，但这是公开 API 的语义陷阱。
- **建议**：`SyncPriorityQueue` 增加并透传 `growOnFull!: Bool`（默认 `false`，与「有 `overSizePolicy`」的直觉一致），或对 `capacity > 0` 固定 `growOnFull: false`；若刻意保持无界，就删掉 `overSizePolicy` 参数并同步改 README。补「capacity=2 时第 3 个元素按策略被丢弃/拒绝」用例。

### [一般][存量] `EventBus.retireAll()` 停不掉线程：阻塞在 `queue.remove()` 的 worker 永不被唤醒，`seize` 线程也没有退出路径

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:197-201`（`retireAll` 仅逐个 `worker.retire()`）、`:63-93`（`seize()` 的 `while (true)` + `seizeQueue.remove()`，无退出条件）；`Worker.cj:40-47`（循环条件在阻塞前判断，`queue.remove()` 无超时）、`:65-67`（`retire` 只置原子位）
- **来源**：存量
- **判据**：review-checklist §12.1（线程/资源生命周期、有界性）；§11（契约与实现不符）
- **证据**：静态确定 —— `retired` 只在 `:41` 的循环条件与 `:98` / `:107` 的入口检查处被读；worker 已经停在 `:46` 的 `queue.remove()` 时没有任何信号能唤醒它（`retire` 不投毒丸、不 `interrupt`）。`EventBus` 没有 `close()`，`seize` 线程是 `while (true)` 且只阻塞在 `seizeQueue.remove()`。
- **描述**：`retireAll` 之后线程数不下降（至少「已空闲的 worker」与 seize 线程常驻），进程无法优雅退出；队列里还有事件的 worker 会继续执行（`queue.size > 0` 使循环继续），与「退役」语义相反；退役期间对已退役 worker 的 `arrange` 直接抛异常（见下一条）。
- **建议**：`retire` 时向队列投递哨兵（`JobQueue` 里放 `?Event`，`None` 表示退出）或改用带超时的 `remove(timeout)` 轮询 `retired`；`seizeQueue` 同样投毒丸并让 `seize` 线程退出；补 `close()` 语义：`retireAll` + 等待全部线程结束。补「retireAll 后线程数归零」用例（可用 `Process`/`Thread` 计数或日志断言）。

### [一般][存量] `SlidingWindowRateLimiter` 的定时器回调空闲时永久阻塞在 `queue.remove()`，`close()` 无法回收线程

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:36-47`（`Timer.after(Duration.Zero)` 回调中 `:41` `queue.remove()`，无超时）、`:69-74`（`close()` 只 `timer.cancel()`）、`:46`（`atExit(timer.cancel)`）
- **来源**：存量
- **判据**：review-checklist §12.1（线程生命周期 / 有界性）；§6.2（阻塞动作放在调度回调里）
- **证据**：静态确定（依据 std 文档）——`std.sync.Timer.cancel()` 明确「如果调用该函数时关联 Task 正在执行，不会打断当前运行。该函数不会阻塞当前线程」（`sync/sync_package_api/sync_package_classes.md:11013-11021`）。低负载（队列空，最常见）时回调正卡在 `ArrayBlockingQueue.remove()` 上，`cancel()` 只阻止下一次调度。
- **描述**：每个 `SlidingWindowRateLimiter` 实例在构造后、无任何任务时就会占住一个线程并永久阻塞；`close()` 后线程不退出、`queue`/`prev`/`this` 被阻塞栈与注册的退出回调继续持有。若限流器按连接/租户动态创建，线程数线性增长。
- **建议**：回调改为非阻塞：`tryRemove()` 取不到就 `return Some(1ms)`（或 `Option.None` 前先置 `closed` 检查），把等待交还调度器；`close()` 置 `closed: AtomicBool` 并（可选）投递一个哨兵元素唤醒回调。补「close 后空闲线程退出」用例（当前 `RateLimiterClose_test` 没有覆盖）。

### [一般][存量] `atExit(timer.cancel)` 让每个限流器实例挂进进程级退出回调表且无法注销，`close()` 后仍不能回收

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:46`、`f_concurrent/src/TokenBucketRateLimiter.cj:50`（`atExit(timer.cancel)`）；注册表语义 `std.env.atExit`（`env/env_package_api/env_package_funcs.md:3-30`，只有注册、无注销）；`Timer` 生命周期 `sync/sync_package_api/sync_package_classes.md:10740`
- **来源**：存量
- **判据**：review-checklist §5（长期持有 / 注册表不注销 → 内存无界）；§7（缩短生命周期、对称注销）
- **证据**：静态确定 —— `atExit` 的回调要「当前进程退出时执行」，必须在进程生命周期内一直持有；标准库与 `f_base.ExitCallbacks`（`f_base/src/signal.cj:36-68`）都只提供 `add`，没有移除接口。`timer.cancel` 是绑定方法，强引用 `Timer`，`Timer` 又持有构造时的 task 闭包（引用 `this.queue` / `this.prev` / `this`）。
- **描述**：每个用过的 `TokenBucketRateLimiter` / `SlidingWindowRateLimiter` 都会在退出回调表里留下一条永不释放的记录，`close()` 仅取消定时器、不会摘掉回调 ⇒ 限流器及其队列（`ArrayBlockingQueue(limit)` / `LinkedBlockingQueue(tokens)`）直到进程退出都无法被 GC。配置热更新或按连接建限流器时内存单调增长。
- **建议**：去掉 `atExit(timer.cancel)`，改由持有方（连接池 / 服务）在 `close()` / 淘汰时显式取消；若必须兜底，用一个进程级单例回调统一 `cancel` 一个弱引用列表（`WeakRef<Timer>`），并在 `close()` 时移除自身。

### [一般][存量] `arrangeAndGet` 的结果槽把 `?Any` 存进 `Any`，读取时多一层 Option；超时后条目不清除会返回上一次的结果

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:287`（`ConcurrentHashMap<Int64, Any>`）、`:297-310`（`convert(d: ?Any)` 里 `case Some(x) => match (x) { case x: T … }`）、`:335-346`（`deliverIfNeed` 取 `event.getData<Any>()` → `deliver(…, data: ?Any)` → `datas.add(id, data)`）；`Event.cj:56-61`（`getData` 返回 `?T`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）；§3（失败路径与返回类型不一致）
- **证据**：待确认（需一条 `arrangeAndGet` 用例确认装箱层级）——`getData<Any>()` 返回 `Some(x)`，`deliver` 再以 `?Any` 存入 `Any` 槽，`datas.remove` 得 `Some(Some(x))`，`convert` 的 `case x: T` 拿到的是 Option 而不是 `T`，按类型检查应恒不匹配（`toThrowIfNotMatch=true` 时抛「data does not match」）。另一处为静态确定：`:323-329` 超时分支直接抛异常，不 `datas.remove(threadId)`；若任务随后才完成，`deliver` 会把结果写进该槽，该线程下一次 `arrangeAndGet` 在 `:313` 先取到它 ⇒ 返回上一次事件的结果。
- **描述**：`arrangeAndGet` 是 README:375 列出的公开同步接口；按代码路径它要么永远拿不到值，要么在超时后拿到陈旧结果。仓内没有调用者与用例，所以问题一直没暴露。
- **建议**：`datas` 的 value 改为 `?Any` 或直接存 `Result<T>` 的擦除形式，避免二次装箱；`convert` 前先判定「槽位属于本次调用」（带一个自增 token/序号）；超时分支 `datas.remove(threadId)` 清理。补「ability 返回 `None` / `Some(Int64)`」「第一次超时、第二次正常」两条用例。

### [一般][存量] `LoadBalance.add` 不校验权重：`weight <= 0` 时新键不递增，直接覆盖前一个节点

- **位置**：`f_concurrent/src/LoadBalance.cj:78-87`（`:79` `max = tree.last?[0] ?? min`、`:80` `new = max + weight`、`:81` `tree[new] = fn`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 / 数据丢失）；§3（静默失效）
- **证据**：静态确定 —— `weight = 0` 时 `new == max`，TreeMap 同一键赋值覆盖前一个节点的 `fn`；`weight < 0` 时新键小于前键，破坏「键 = 累计权重」的单调性，`forward` 的桶划分随之失真。
- **描述**：配置写成 0 / 负权重（如从配置解析失败得到 0）不会报错，表现为「某个节点永远不被选中」或「两个节点合并成一个」，与 `f_dbd` 的 `algorithmOf` 对权重和的校验（`Datasource.cj:180-191`）不一致。
- **建议**：`add` 入口校验 `weight > 0`，否则抛 `LoadBalanceException`（与 `f_dbd` 的 `CONFIG` 语义对齐）；`tree[new]` 改为 `tree.add(new, fn)` 之类的「键已存在即失败」写法，避免静默覆盖。

### [一般][存量] `LoadBalance` 对「算法给出越界键 / 空树」的错误处理三处不一致

- **位置**：`f_concurrent/src/LoadBalance.cj:88-90`（`call` 越界 → `next().getOrThrow()` 抛 `NoneValueException`）、`:114-124`（`iterator` 越界 → `forward` 为空 → `LoadBalanceIterator` 静默从 `itr` 头部绕回）、`:91-113`（空树时返回 `(None, None)`，既不成功也不报错）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符、错误类型不一致）
- **证据**：静态确定 —— `tree.forward(v)` 在 `v > 最大键` 时返回空迭代器；`call` 直接 `getOrThrow`；`iterator` 的 `:118-122` 用 `tree.isEmpty()` 判断，越界但非空时 `forward` 为空，`LoadBalanceIterator.next()` 的 `:136-142` 会 `endsub = true` 后回到 `itr.next()`（键最小的节点）。
- **描述**：同一份数据、同一种异常输入，`call` 抛标准库 `NoneValueException`（不是 `LoadBalanceException`，调用方无法按契约捕获），`iterator` 静默降级到第一个节点（掩盖了算法错误，也是上文严重项的表现之一），`call(maxRetrying)` 空树返回 `(None, None)` 与「成功但无值」不可区分。`f_dbd` 的 `connect()` 只 catch `ConnectionException`，越界异常会穿透成非预期错误。
- **建议**：统一为一个显式语义：`tree.isEmpty()` → 抛 `LoadBalanceException("no node registered")`；`forward` 为空（算法越界）→ 抛 `LoadBalanceException("algorithm returned out-of-range key")`（同时修上文的回绕竞态）；`iterator` 不要静默绕回，或在文档中明确「越界即从头开始」并让 `call` 与之一致。三处共用同一个 `pickFirst()` 实现。

### [一般][存量] `EventBus` 未校验 `workers` / `maxWaitingJobPerWorker`：0 会在构造深处抛无上下文异常

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:48-62`（`:56` `LinkedBlockingQueue<Int64>(workers)`、`:57-59` `Array<Worker>(workers)`、`:233` `random.nextInt64(workers.size)`）；`JobQueue.cj:30-32`（`LinkedBlockingQueue<Event>(max)`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定（依据 std 文档）——`LinkedBlockingQueue(capacity)` 在 `capacity <= 0` 时抛 `IllegalArgumentException`（`collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:2818-2823`），`workers = 0` 时 `nextInt64(0)` 也会失败；`JobQueue` 的构造在 `Worker` 里，异常栈会指向 `JobQueue.cj:31`。
- **描述**：配置写 0 时得到的异常信息是 `Invalid capacity '0'`，与「workers / maxWaitingJobPerWorker 配错」没有关联；若仅放宽 `LinkedBlockingQueue` 的校验而不补入口校验，`workers = 0` 还会让 `seize()` 线程永久阻塞在 `seizeQueue.remove()`，问题更隐蔽。
- **建议**：构造入口显式校验 `workers > 0 && maxWaitingJobPerWorker > 0`，抛带参数名的 `EventBusException`；同时把 `abilities` 中「事件名为空 / 重复注册」也在这里检查（当前同名事件在 `Worker.register` 里静默覆盖，见 §2 建议）。

### [一般][存量] `SlidingWindowRateLimiter` 的 `Mono.time` 用无界自旋等待写入，定时器线程可能持续烧 CPU

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:81-89`（`get()` 里 `while (_time.load().isNone()) {}`）、`:42-43`（定时器读到 `mono.time`）、`:57-58`（`exec` 先 `queue.add` 再写 `mono.time`）
- **来源**：存量
- **判据**：review-checklist §12.1（条件等待未在循环里重查条件、忙等）；§6.2（调度回调里的忙等）
- **证据**：静态确定 —— 入队成功与写入 `time` 之间存在窗口；定时器线程 `queue.remove()` 取到该元素后调用 `mono.time` 会进入 `while` 自旋，直到 `exec` 线程被调度执行 `:58`。写入方若被长时间抢占，自旋就持续占用一个核。
- **描述**：正常负载下窗口很短，但这是「用自旋代替同步」的写法：`time` 只写一次、读侧无超时，一旦写入线程被挂起（GC、调度、debug 断点），定时器线程无限忙等；同时它让定时器线程无法处理下一个窗口。
- **建议**：改为一次性 handshake：`Mono` 内用 `Mutex` + `Condition`（写入后 `notify`，读侧 `wait`），或把时间戳改为入队前写入、定时器侧用 `max(mono.time, dequeueTime)` 兜底；更简单的是让 `exec` 在 `queue.add` 成功返回后立刻写 `time` 并在 `Mono` 中保存 `AtomicBool ready`，读侧 `waitUntil` 而非空转。

### [轻微][存量] 退役 worker 的 `tryArrange` 抛异常，会打断 `tryArrangeOther` / `discardOldest*` 的容错循环

- **位置**：`f_concurrent/src/eventbus/Worker.cj:106-111`（retired 即抛 `EventBusException`）；`EventBus.cj:265-271`（`tryArrangeOther` 的 `while` 条件直接调用它）、`:129-138`（`discardOldestStrategy` 的 `while`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 契约）
- **证据**：静态确定 —— `tryArrange` 抛异常时 `while (i < workers.size && !tryArrange(...))` 整个表达式退出，不会尝试下一个 worker；`discardOldest*` 同样直接抛出而不是丢弃。
- **描述**：部分退役（缩容）后，只要随机/哈希落到退役 worker，`arrange` 就以异常失败，而不是换一个可用 worker；这与「`tryArrangeOther` 就是为换 worker 准备」的设计意图相反。
- **建议**：`tryArrange` 对 retired 返回 `false`（由调用方换 worker），只在 `arrange`（阻塞式）里抛；或在 `tryArrangeOther` 内 catch 并跳过退役 worker。

### [轻微][存量] 死代码：`JobQueue.cj` 两个未使用 import、`RateLimiter.cj` 注释掉的单例

- **位置**：`f_concurrent/src/eventbus/JobQueue.cj:18`（`ConcurrentHashMap`）、`:19`（`EventBusException`）；`f_concurrent/src/RateLimiter.cj:38`（`// public static let INSTANCE = UnlimitedRateLimiter<T>()`）
- **来源**：存量
- **判据**：review-checklist §1（未使用 import / 兼容残留）
- **证据**：静态确定 —— 编译器告警直接点名（`f_concurrent/target/release/.build-logs/f_concurrent@fountain/f_concurrent.eventbus@….errlog`：`unused import 'std.collection.concurrent.ConcurrentHashMap'`、`unused import 'fountain::f_concurrent.eventbus.exception.EventBusException'`）；`INSTANCE` 只存在于注释。
- **描述**：两个 import 是 `JobQueue` 早期版本（曾直接抛 `EventBusException`）的残留；注释掉的单例让人误以为有全局无限流器可用。
- **建议**：删除两个 import 与注释行。

### [轻微][存量] 重复逻辑：四个异常类同形、三个 `close()` 同形、六个满队列策略成对近似

- **位置**：`f_concurrent/src/exception/ConcurrentException.cj:20-32`、`f_concurrent/src/exception/LoadBalanceException.cj:20-32`、`f_concurrent/src/eventbus/exception/EventBusException.cj:20-32`（另 `exception/RateLimiterException.cj` 同形，属第 3 部分）；`SlidingWindowRateLimiter.cj:69-74` / `TokenBucketRateLimiter.cj:60-65` / `LeakingBucketRateLimiter.cj:74-79`（三个 `close()` 逐行同形）；`EventBus.cj:106-195`（`abort*` / `discardCurrent*` / `discardOldest*` 各成对）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 同语义不同入口）
- **证据**：静态确定 —— 异常类只有类名不同；`close()` 都是 `match (timer) { case Some(t) => t.cancel(); case _ => () }`；策略对的差异只有「是否多一次 `tryArrange(timeout)`」与「拒绝时抛异常还是丢弃」。
- **描述**：异常类 4×4 个构造器没有共享基类工厂，改错误字段要改 4 处；`close()` 的语义（幂等、置 closed）分散在三处，容易漂移；策略对复制意味着新增一种策略要同步改两处。
- **建议**：异常类可保留（对外 API 类型名有语义价值），但至少抽一个 `RateLimiter` 基类的 `protected func cancelTimer()` 供三个限流器复用，并在其中统一置 `closed`；策略函数改为参数化：`genStrategy(timeout!: ?Duration, onReject: RejectAction)`，差异点（超时、抛/丢/deliver）显式入参。

### [轻微][存量] 注释与实现不符、日志计数与通道不规范

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:26-29`（`@param timeout 时间窗口`，实际 `timeout` 是入队等待超时，窗口是 `window`）、`:24` + `:38-39`（`unfinishedTasks = AtomicInt64(1)`，首次超时日志打印 `1 tasks`）、`:38`（`Console.writeln` 而非 `f_log`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）；fountain-baseline §6（日志走 `f_log`，热点路径不 `println`）
- **证据**：静态确定 —— `:57` 用的是 `timeout` 作为 `queue.add` 的等待时长，`window` 才是窗口；`fetchAdd(1)` 返回旧值，初值 1 使第一条日志的计数从 1 开始（应为 0 或先 `fetchAdd` 再打印新值）。
- **描述**：参数注释会把使用者引向错误配置（把窗口配到 `timeout` 上）；限流超时是运维关注事件，走 `Console` 会绕过日志级别/异步缓冲/采样。
- **建议**：修正 `@param` 说明；`unfinishedTasks` 初值改 0 并用 `fetchAdd(1) + 1` 打印；改用 `f_log`（该模块若不便依赖 `f_log`，至少统一走一个可注入的 logger）。

### [轻微][存量] `LoadBalanceIterator` 绕回时重复枚举已走过的后缀，重试候选出现重复

- **位置**：`f_concurrent/src/LoadBalance.cj:132-143`（`sub` 走完后 `endsub = true` 再 `next()` → `itr.next()`；`itr` 是整棵树）
- **来源**：存量
- **判据**：review-checklist §11（语义偏差 / 重复遍历）
- **证据**：静态确定 —— `sub` = `[algo 选定键, 末尾]`，`itr` = `[最小键, 末尾]`；枚举总量为 `n + (n - idx + 1)`（`idx` 为选定键下标），选定键及其后缀被枚举两次。
- **描述**：`call(data, maxRetrying)` 按该迭代器重试时，越靠后的节点会被重复尝试，重试顺序与「每个节点一次」的直觉不符；`MultiClient` 只取第一个元素，暂不受影响。
- **建议**：`itr` 改为「从最小键到选定键之前」的前缀（`tree.forward(min).takeWhile(k < chosen)` 或先收集键再切分），保证整轮枚举恰好覆盖每个节点一次；补一条「迭代器长度 == 节点数且无重复」的用例。

### [轻微][存量] 测试有效性：恒真断言、时序依赖、缺并发与生命周期用例

- **位置**：`f_concurrent/src/RateLimiterClose_test.cj:76`（`@Assert(true, true)`）、`:48-56` / `:59-66`（首次 `exec` 依赖零延迟定时器在 `timeout`（1ms / 5ms）内补到令牌，`sleep` 与周期强耦合）、`:69-77`（只验证两次 `close()` 不抛，未验证线程退出）；`f_concurrent/src/LoadBalance_test.cj:32-133`（全部单线程，无一条并发 `next()`）
- **来源**：存量
- **判据**：review-checklist §1（恒真分支）、§6.1（结论需数据）、§11（用例覆盖不到目标缺陷）
- **证据**：静态确定 —— `@Assert(true, true)` 恒真；`tokens: 1, timeout: 1ms, populationPeriod: 10ms` 的首次断言取决于调度；RoundRobin 的越界竞态没有任何用例（这也是本部分严重项 1 未被发现的原因）。
- **描述**：`close` 相关用例只覆盖「不再补令牌」，没有覆盖「阻塞回调能否退出」这一真正的资源风险；`testSlidingWindowCloseIsIdempotent` 自身会留下一个阻塞在 `queue.remove()` 的线程。
- **建议**：删除恒真断言；把首次 `exec` 改为「先 `sleep(populationPeriod)` 再断言」或把 `populationPeriod` 调到远小于 `timeout`；新增「16 线程并发 `next()` 落在区间内」「`close()` 后线程数下降 / 回调退出」两条用例。

### [轻微][存量] `SyncPriorityQueue.iterator()` 返回的是弱一致迭代器，类名与文档没有说明

- **位置**：`f_concurrent/src/SyncPriorityQueue.cj:93-97`、`:110-117`；底层 `f_collection/src/PriorityQueue.cj:234-238`（创建时捕获 `queue.iterator()` 与 `currentSize`）
- **来源**：存量
- **判据**：review-checklist §12.1（迭代与修改并发）；§11（契约未声明）
- **证据**：静态确定 —— 迭代器持有创建时刻的内部数组引用与 `max_` 长度；后续 `add` / `remove` 在同一数组内 `adjustUp/Down`、`grow` 换新数组（`PriorityQueue.cj:130-146`），迭代期间读到的顺序/成员可能变化或重复。每次 `next()` 有锁，因此不是数据竞争，但也不是快照。
- **描述**：类名 `Sync*` 与 README 的「并发优先队列」容易让人认为迭代是快照或强一致；实际是弱一致，且未在任何注释说明。
- **建议**：在类注释与 README 写明「iterator 为弱一致视图，迭代期间不得依赖元素集合」；如需快照，`iterator()` 内 `toArray().iterator()`（代价 O(n) 拷贝）。

### [轻微][存量] `LoadBalance` 的 `tree` 无任何同步，`add` 与 `call/iterator` 并发不安全且未声明

- **位置**：`f_concurrent/src/LoadBalance.cj:76`（`private let tree = TreeMap<...>()`）、`:78-87`（写）、`:88-124`（读）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）；§11（契约未声明线程安全）
- **证据**：静态确定 —— 类内没有锁/原子/不可变快照；`TreeMap` 非线程安全。仓内 `add` 只在构建期调用（`MultiClient.cj:177`、`LLMConfsHolder.cj:214`、`Datasource.cj:97`），读路径在请求线程并发。
- **描述**：当前用法（构建后只读）实际安全，但公开 `add` 允许运行期增删节点；一旦如此，`call/iterator` 会读到重排中的树。同时 `RoundRobin` 内部有 `Mutex`，容易让人误判整个 `LoadBalance` 线程安全。
- **建议**：在类/README 明确「`add` 仅限初始化阶段，运行期只读」；若要支持热更新，改为「构建新 TreeMap → `AtomicReference` 整体替换」的写时复制。

### [轻微][存量] `EventBus.seize` 偷任务后不刷新被偷 worker 的统计，且有一处无意义的 let 绑定

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:84-90`（`tryRemove()` 后只 `putQueueSize(sizedBy)`，未 `putQueueSize(maxQueueIndex)`）、`:72-82`（`:77` `if (let s <- …waitingJobSize && maxQueueSize < s)`，`waitingJobSize` 不是 Option，绑定恒成立）
- **来源**：存量
- **判据**：review-checklist §11（状态不一致）；§10（可读性）
- **证据**：静态确定 —— 被偷 worker 的队列少了一个元素，但 `maxQueueSize` 仍记着旧值；该值只在 `putQueueSize` 里更新，而偷取路径不调用它。`let s <-` 在非 Option 上等价于直接比较。
- **描述**：`maxQueueSize` 偏高会让 `seize` 线程反复对同一个 worker 做 `tryRemove`（返回 `None`，空转），在长期运行的 EventBus 上累积无效扫描；`let s <-` 让读者误以为 `waitingJobSize` 可能是 `None`。
- **建议**：偷取成功后补 `putQueueSize(maxQueueIndex)`；`:77` 改为 `if (maxQueueSize < workers[i].waitingJobSize)`。

## 优化可行性方案

> 本模块未提供任何 profile / bench 数据（`scope.md`「已有性能资料」为空），以下全部为 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] `EventBus` 每次入队/出队都取全局 `queueMutex`，把统计量变成串行点

- **现状**：`arrange` 每次分发后调 `putQueueSize`（`EventBus.cj:239-240`），`Worker.tryRemove` 每次取任务后也调（`Worker.cj:120-128`）；两者都在 `synchronized(queueMutex)` 内读 `queue.size` 并可能写元组（`EventBus.cj:276-283`）。即每个事件至少 2 次全局锁往返，worker 数 N 时全部 worker 在这一把锁上排队。
- **方案**：`maxQueueSize` 只是 `seize` 的启发式，可改为「每个 worker 一个 `AtomicInt64` 队列计数 + `seize` 线程周期性扫描（或按阈值触发）」，把 per-event 的全局锁去掉；至少把 `putQueueSize` 改成只在越过高水位/低水位时更新。
- **预期**：去掉每事件 2 次全局互斥；吞吐提升比例取决于 N 与临界区占比（未测）。
- **代价**：`maxQueueSize` 从「精确」退化为「近似」，偷任务的时机略有延迟；需要保证 `seizeQueue` 的唤醒频率不下降。
- **验证**：N=8/32 worker，事件处理耗时 10µs，跑 5 分钟，对比 `putQueueSize` 的锁等待时间（线程状态采样）与吞吐；`cjpm bench -O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `LoadBalance.iterator()` 每请求分配迭代器与两个闭包；节点选择用 `SecureRandom`

- **现状**：`f_net` 每个 RPC 请求调用 `loadbalance.iterator()`（`MultiClient.cj:228`），每次构造 `tree.iterator()`、`forward(...).map(mapper)`、`LoadBalanceIterator`，且 `algo.next()` 需要取锁（`LoadBalance.cj:114-124`、`:35-49`）；`Int64Weight` / `Float64Weight` 用 `SecureRandom`（`:52`）选节点。
- **方案**：`RoundRobin` 路径提供「只取下一个节点」的 `nextNode()`（不建迭代器，`tree.forward(...).next()`），`MultiClient` 直接用；随机权重改用 `std.random.Random`（节点选择不需要密码学强度），并确认 `SecureRandom` 是否线程安全（文档未声明）。
- **预期**：每请求少 2-3 个短生命周期对象/闭包；`SecureRandom.nextInt64` 的单次开销与锁竞争占比待测。
- **代价**：新增一个内部 API；随机分布仍需通过现有 `LoadBalance_test` 的比例断言。
- **验证**：`cjprof record` 跑 200 并发 RPC 压测 60s，看 `iterator`/`next`/`SecureRandom` 的 self time 与分配量；`cjpm bench -O2` 前后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `SlidingWindowRateLimiter` 每个任务分配 `Box<MonoTime>` 并放进 `AtomicOptionReference`

- **现状**：每个受控任务构造一个 `Mono`，`time` 用 `AtomicOptionReference<Box<MonoTime>>`（`SlidingWindowRateLimiter.cj:78-88`），即每任务一个 `Mono` + 一个 `Box` + 一层原子引用；元素在队列里存活一个 `window`。
- **方案**：`Mono` 改为 `class Mono(time: MonoTime)`（入队前写入 + 读侧按上文 handshake/兜底），去掉 `Box` 与 `AtomicOptionReference`；队列容量为 `limit`，元素生命周期由窗口决定，不必再原子化。
- **预期**：每任务少 1 个 `Box` 与一层原子包装（对象数 -1，另省一次原子 `store`/`load`），峰值分配量与 GC 压力按 QPS 比例下降（未测）。
- **代价**：需要解决「入队前写入时间」与「等待时长计入窗口」的语义差异（见上文自旋项的建议）；并发正确性需压测复核。
- **验证**：固定 `limit=100`、QPS=1k、跑 10 分钟，对比 `getAllocatedHeapSize()` 与 RSS，`cjpm bench -O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `EventBus` 的 `queueMutex` 在 N worker 下成为分发吞吐上限 | `f_concurrent/src/eventbus/EventBus.cj:276-283`、`:239-240` | 锁等待时间占比、线程状态 | 8/32 worker 跑 10µs 事件 5 分钟，线程状态采样（BLOCKED）+ 改造前后吞吐 |
| 2 | `SecureRandom` 参与节点选择（`arrange` / `next`）造成可观延迟 | `f_concurrent/src/LoadBalance.cj:52`、`EventBus.cj:224-233` | 单次 `nextInt64` 耗时、占比 | `cjprof record` 跑 200 并发 60s，或微基准 10⁶ 次调用取中位数 |
| 3 | 每请求构造 `LoadBalanceIterator` + 两个闭包的分配占比 | `f_concurrent/src/LoadBalance.cj:114-124` | 分配量与 GC 时间占比 | `cjprof heap` + 200 并发压测，统计每请求分配字节 |
| 4 | `SlidingWindowRateLimiter` 空闲时的阻塞线程数与内存随实例数线性增长 | `f_concurrent/src/SlidingWindowRateLimiter.cj:36-47` | 线程数、RSS 随实例数曲线 | 构造 10/100 个限流器、空闲 60s 后读 `/proc/self/status` 的 `Threads` 与 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_concurrent/src/LoadBalance.cj` | .cj | ✅ | 144 行；`RoundRobin` 回绕竞态（严重项）、`add` 权重校验、越界处理不一致 |
| 2 | `f_concurrent/src/LoadBalance_test.cj` | .cj | ✅ | 133 行；单线程用例完整，无并发用例 |
| 3 | `f_concurrent/src/RateLimiter.cj` | .cj | ✅ | 45 行；`close()` 默认空实现有注释说明（有意 Null Object）；注释掉的 `INSTANCE` |
| 4 | `f_concurrent/src/RateLimiterClose_test.cj` | .cj | ✅ | 78 行；恒真断言、时序依赖、未验证线程退出 |
| 5 | `f_concurrent/src/SlidingWindowRateLimiter.cj` | .cj | ✅ | 98 行；阻塞回调 + `atExit` 保留 + 自旋等待 + 注释不符 |
| 6 | `f_concurrent/src/SyncPriorityQueue.cj` | .cj | ✅ | 117 行；`capacity`/`overSizePolicy` 不生效、迭代器弱一致 |
| 7 | `f_concurrent/src/TokenBucketRateLimiter.cj` | .cj | ✅ | 66 行；回调非阻塞（可退出），`atExit` 保留问题同 SlidingWindow |
| 8 | `f_concurrent/src/eventbus/EndEvent.cj` | .cj | ✅ | 29 行；无问题 |
| 9 | `f_concurrent/src/eventbus/Event.cj` | .cj | ✅ | 84 行；原子字段、`==`/`hashCode` 按 name；`startEvent`/`ordinal` 对外可达无仓内引用（不算死代码） |
| 10 | `f_concurrent/src/eventbus/EventBus.cj` | .cj | ✅ | 347 行；`notified`/`notify`、结果槽装箱、`New` 策略、retire 生命周期、参数校验、seize 统计 |
| 11 | `f_concurrent/src/eventbus/JobQueue.cj` | .cj | ✅ | 50 行；两个未使用 import（编译器告警）；`max <= 0` 直接抛底层异常 |
| 12 | `f_concurrent/src/eventbus/Worker.cj` | .cj | ✅ | 129 行；事件链无异常隔离（严重项）、retired 抛异常打断重试 |
| 13 | `f_concurrent/src/eventbus/exception/EventBusException.cj` | .cj | ✅ | 32 行；4 构造器，与另外三个异常类同形 |
| 14 | `f_concurrent/src/exception/ConcurrentException.cj` | .cj | ✅ | 32 行；仓内无引用（对外可达，不算死代码） |
| 15 | `f_concurrent/src/exception/LoadBalanceException.cj` | .cj | ✅ | 32 行；仅 `LoadBalance.call` 使用 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。本部分不含 `f_concurrent/README.md` / `README_en.md` / `doc/performance_report.md`（不在本部分的 15 个文件内，§13 / §14 的文档逐项对照留给合并后的模块报告统一完成）；为核对承诺源另读了 `f_concurrent/README.md:340-385`、`f_base/src/WorkerStrategy.cj`、`f_collection/src/PriorityQueue.cj`、std 的 `Timer` / `Condition` / `LinkedBlockingQueue` 文档，均只作证据，不计入本部分覆盖统计。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 13 | 正确性 6（RoundRobin 越界、arrangeAndGet 通知、结果槽装箱、`add` 权重、越界处理三态、seize 统计）；设计 4（`New` 策略、`overSizePolicy` 无效、retire 生命周期、`LoadBalance` 无同步约定）；可读性 2（注释不符、无意义 let 绑定）；语言特性 1（`AtomicOptionReference<Box<…>>` + 自旋代替同步）；无外部输入/凭据/注入面，安全性未命中 |
| §1 死代码 | 2 | ①`JobQueue.cj:18-19` 两个未使用 import（编译器 `-Wunused` 点名）②`RateLimiter.cj:38` 注释掉的 `INSTANCE`。已逐符号核对：`LoadBalanceIterator`（internal，`iterator()` 构造）、`SyncPriorityQueueIterator`（public，`iterator()` 构造）、`JobQueue` 各方法（`Worker` 内调用）、`EventBus` 全部 private 函数（`genDoArrange` / `seize` / 策略族 / `deliver*`）均有引用；`Event.startEvent` / `ordinal`、`RandomWeight.min/max`（protected，public abstract 类）按硬原则一不判 |
| §2 重复逻辑 | 3 | ①三个异常类 + `RateLimiterException` 同形（只改类名）②三个限流器 `close()` 逐行同形③六个满队列策略成对近似（差异仅为 timeout 与拒绝动作，已点名）；另 `LoadBalance` 的节点选择在 `call` / `iterator` / `call(maxRetrying)` 三处各写一遍（已并入「越界处理不一致」） |
| §3 空实现 | 0 | `RateLimiter.close()` 是带注释说明的有意 no-op（Null Object），不算缺陷；无 `TODO` / `FIXME` / 空函数体；`abort*`/`discard*`/`block*`/`currentThread*` 均有实际行为；失败路径不闭环的问题（Worker 异常、arrangeAndGet）已归 §12.1 / §11 |
| §4 栈溢出 | 0 | 已核对全部自调用：`LoadBalanceIterator.next()` 递归受 `endsub` 保证只 1 层；`arrangeAndGet.get(false)` 递归最多 2 层（`toWaitIfNeed=false` 后不再等待）；`Worker` 的事件链是 `while` 循环而非递归；无按输入深度递归的结构 |
| §5 OOM | 2 | ①`atExit(timer.cancel)` 进程级强引用 + 无注销（限流器不能回收）②`SyncPriorityQueue` 的 `capacity` 不生效导致实际无界；另 `arrangeAndGet` 的 `datas` 在超时后残留条目（并入该条）与 `EventBus` 队列有界（`maxWaitingJobPerWorker`）已核对 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 明确为空），热点不成立；`queueMutex`、`SecureRandom`、每请求迭代器、限流器线程数四条线索已写入「待验证假设」，未计入统计 |
| §6.2 大粒度锁 | 0 | 已核对：`EventBus` 的 `queueMutex` 临界区只含 `size` 读取与元组写入（微秒级），未构成「锁内 I/O / 解析 / 回调」；`SyncPriorityQueue` 的 `removeIf` 在锁内调用用户谓词，但仓颉 `Mutex` 为可重入锁（`sync_package_classes.md:8919-8930`），不构成自锁死锁，且无测量数据，只作 §12.2 说明；限流器定时器回调的阻塞已按 §12.1 报 |
| §6.3 并发串行 | 0 | `EventBus` 单个 `seize` 线程 + 每事件一次全局 `queueMutex` 是串行线索，但没有并发度/吞吐数据，按规则写入优化方案与待验证假设，不算发现；无 `spawn(...).get()` |
| §6.4 低效算法 | 0 | 未发现 O(n²) 或 `remove(at: 0)` 型热点；`LoadBalanceIterator` 绕回重复枚举是 O(n) 的额外工作，已按轻微正确性/重复报，不作为性能缺陷 |
| §7 降堆内存方案 | 1 | `Mono` 每任务 `Box<MonoTime>` + 原子引用（优化方案，无基线）；`atExit` 保留属缺陷（§5）已单列 |
| §8 降 CPU 方案 | 2 | ①`EventBus` 每事件全局锁 → 分片/原子计数②`LoadBalance` 每请求迭代器/闭包 + `SecureRandom`（均无基线） |
| §9 local mode 可行性 | 0 | 本部分的对象都跨线程/跨生命周期逃逸：`Event` 从提交线程到 worker 再回投递线程，`Mono` 从调用线程进 `queue` 再到定时器线程，`LoadBalance` 的闭包长期存放在 TreeMap；无「函数内创建、函数内释放」的大临时对象，缺峰值内存前后对照，按规则记不可行（缺数据） |
| §11 现有代码的 BUG（存量） | 22 | 本部分 22 条发现全部为存量（快照 `8c0ce643a`，无 diff；blame 显示关键行为 `4be871f2fd` 2026-10-02）；已逐函数核对边界、空值、错误处理、资源释放、并发与契约 |
| §12 并发安全与锁粒度 | 8 | 共享点与同步手段：`RoundRobin.current`（`Mutex` 但回绕拆分，发现越界竞态）、`EventBus.datas/notified/condition`（全局锁 + 单播唤醒，发现通知缺陷）、`Worker.abilities/queue/retired`（并发容器 + 原子位，发现异常隔离与 retire 生命周期）、`SyncPriorityQueue.queue`（单锁全覆盖，仅迭代器弱一致）、`SlidingWindow.queue/prev/_time`（阻塞队列 + 原子 + 自旋，发现线程回收与忙等）、`LoadBalance.tree`（无同步，仅构建期写，记轻微）、限流器 `timer`（普通 var，`close()` 读，已并入 `atExit`/生命周期条）；未发现多锁嵌套与锁顺序反转 |
| §14 功能完备性与 README 覆盖 | 2 | ①`WorkerStrategy.New` 承诺建新线程、实现为当前线程（双证：`WorkerStrategy.cj:62-67` + `EventBus.cj:103`）②`SyncPriorityQueue` 的 `capacity`/`overSizePolicy` 在 README:348-349 列为可用参数但实现不生效（双证）；`EventBus` / `LoadBalance` / 限流器在 README 中仅列名，无行为承诺，未再记遗漏（README 逐项核对留给第 3 部分） |
| 文件覆盖（§13 等） | 15/15 | 15 个文件全部读完；本部分不含 `.md`，§13 文档一致性（README / README_en / doc）与 README 公开 API 逐项覆盖不在本部分范围，留给合并后的模块报告 |

## 范围外提示

- `f_base/src/WorkerStrategy.cj:38-49`：`DiscardCurrentAfter` / `DiscardOldestDuring` 的注释写「等待 Duration，然后抛出 JobQueueFullException」，实际语义是丢弃（`EventBus` 的实现也是丢弃），属第 1 部分范围外的注释错误，仅提示。
- `f_concurrent/src/LeakingBucketRateLimiter.cj:61` 有同形的 `atExit(timer.cancel)`（第 1 部分文件），本部分未重复统计。
- `EventBus` / `Worker` / `JobQueue` 在仓内除 `f_concurrent/eventbus` 自身外零引用（`grep -rn "EventBus" --include=*.cj` 已核实），属对外 API；README:344-347、374-375 有列名，故不判死代码。

## 模块统计（第 2/3 部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 10 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 22 条（3 严重 / 10 一般 / 9 轻微），是否纳入修复待用户决定；优化方案与待验证假设均无基线，只作下一轮补数据的清单。

## 总评

本部分的两条主线——「负载均衡」与「事件总线」——都建立在正确的并发意图上（轮询用锁保护游标、事件总线用条件变量交付结果、限流器用定时器补令牌），但**关键路径的状态机没有闭环**：

- `RoundRobin` 把「取值」和「回绕」拆成两个临界区，导致并发下返回越界键；这不只是理论竞态：`f_dbd` 借数据库连接走 `call` 会抛 `NoneValueException`，`f_net` RPC 与 `f_llm` 走 `iterator` 会静默退化成「永远选第一个节点」。属于线上可触发的阻塞项，应优先修并补并发用例。
- `EventBus.arrangeAndGet` 的通知机制只能支撑「单线程、只调用一次」，`notified` 永不复位、`notify()` 单播、结果槽二次装箱，三个问题叠加使这个公开同步接口在真实使用下不可用；`Worker` 又没有异常隔离，一条坏事件就会静默损失一个工作线程。EventBus 目前仓内零调用者，风险是「对外 API 一旦被使用就踩坑」，建议要么补齐测试与修复，要么明确标注实验性。
- 限流器（`SlidingWindow` / `TokenBucket`）的定时器与 `atExit` 组合带来两类资源问题：空闲时阻塞线程无法被 `close()` 回收，以及每个实例被进程退出回调永久强引用；按连接/租户动态建限流器时会线性泄漏。
- `SyncPriorityQueue` 的 `capacity` / `overSizePolicy` 是「接了参数但没接线」的典型：看起来有界，实际永远扩容；这是公开 API 的语义陷阱，修法很小（透传 `growOnFull`）。

死代码与重复实现集中在 `JobQueue` 的残留 import、三个限流器同形的 `close()` 与四个同形异常类，清理成本低但收益也低，建议随上述修复顺手处理。整体上，本部分没有发现栈溢出与无界队列（除 `SyncPriorityQueue` 参数失效）这类新 OOM 面；主要风险是并发正确性与资源生命周期，建议按「严重项 → 限流器资源 → 参数/文档」的顺序排期。
