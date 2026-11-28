# f_concurrent 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_concurrent`（34 个源文件，全部为 `.cj`；`README.md` / `README_en.md` / `doc/**` 不在模块文件清单内，仅作承诺源引用）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git log` 顶部 `8c0ce643a`，除 `docs/review/`、`reviews/` 外工作区干净、无 diff）⇒ 全部发现统一记「存量（无基线可比）」
- **审查重点**：并发容器正确性、锁粒度与死锁、可见性、执行器池与限流器生命周期、负载均衡、EventBus/Worker 事件链、异常类型契约、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（由 `reviews/202611280829_full/parts/f_concurrent.part1~3.md` 合并；同一根因跨部分条目已合并为一条并列全位置，合并不改变严重程度，未出现严重程度冲突——详见文末「合并说明」）

## 发现

### [严重][存量] 任务抛异常时工作线程直接死亡，且对应 Future 永不完成 → 调用方永久阻塞、池逐步失能

- **位置**：`f_concurrent/src/Executor.cj:56-62`（worker 循环 `q.remove()()`，无 try/catch）、`:66-72` / `:89-100`（闭包内 `future.complete(task())`，`task()` 先求值）、`:110-116`（`complete` 只承载正常返回值）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（异步语义：异常被吞）、§3（静默吞异常）、§11（错误处理缺失）
- **证据**：静态确定 —— worker 的 `while (running.load()) { q.remove()() }` 没有任何捕获；闭包 `{ => future.complete(task()) }` 中 `task()` 抛异常时不会执行 `complete`，异常沿 `q.remove()()` 冒出并终止该 spawn 线程；`ExecutorFuture` 没有「失败」状态，`finished` 恒为 false。
- **描述**：任一业务任务抛异常即永久损失一个 worker；`Executors` 的 N 个 worker 全部死亡后，此后所有 `call(...).get()` 都永久阻塞（`f_net/src/server/server.cj:169` 在请求线程上 `get`，等于请求线程泄漏）。`ExecutorPoolTest` 只覆盖正常返回，无异常用例。
- **建议**：worker 循环改为 `try { handler() } catch (e) { /* 记录 + 让该 future 以失败完成 */ }` 且不退出循环；`ExecutorFuture` 增加 `exception: ?Exception`，`get()` 时重新抛出（或至少 `complete(None)` 并记日志），为「任务抛异常后池仍可用 / `get` 不挂起」补测试。

### [严重][存量] `call(limiter, …)` 被限流器拒绝时闭包不执行，Future 永不完成，`get()` 永久阻塞（f_net / f_rpc / f_rx 主路径）

- **位置**：`f_concurrent/src/Executor.cj:89-100`（`limiter.exec{ … q.tryAdd(…) … }`）、`f_concurrent/src/AnyMomentRateLimiter.cj:44-46`（`queue.add` 超时 → 直接 `return default`，不执行 task）、`f_concurrent/src/LeakingBucketRateLimiter.cj:63-72`（同样在拒绝分支返回 `default`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（有界性 / 异步语义）、§11（契约与实现不符、失败路径当成功）
- **证据**：静态确定 —— `RateLimiter.exec(default, task)` 的拒绝分支**不调用** `task`；而 `Executor` 把「入队 + 完成 Future」整体放进 `task` 里，拒绝时 `future` 从未被 `complete`。调用方 `f_net/src/server/server.cj:169` 的写法是 `executors.call(limiter){…}.get{defaultResp(req.id)}`，会一直等在条件变量上。
- **描述**：任何配置了 `anyMomentRateLimiter` / `leakingBucketRateLimiter` 的服务，在触发限流的那一刻不是「降级返回默认响应」，而是**请求线程永久挂起**；只有默认的 `UnlimitedRateLimiter` 不受影响，因此现网默认配置掩盖了该缺陷。
- **建议**：拒绝分支必须完成 Future。最小改法：`let r = limiter.exec(None<Unit>){ q.tryAdd(closure); Some(()) }; if (r.isNone()) { future.complete(default) }`，把「入队」当作被限流的动作、把「未入队」显式映射为 `complete(default)`；并补一条「限流拒绝时 `get` 应立即返回默认值」的用例。

### [严重][存量] `shutdown()` 不唤醒阻塞在 `q.remove()` 的 worker：线程永不退出，关闭后提交的任务永久挂起

- **位置**：`f_concurrent/src/Executor.cj:57-61`（阻塞式 `q.remove()`）、`:101-103`（`shutdown` 仅 `running.store(false)`）、`:43-47`（`Executors.shutdown` 逐个调用）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（线程/资源生命周期、有界性）、§11（资源释放不对称）
- **证据**：静态确定 —— `running` 只在线程从 `remove()` 返回之后才被检查；队列为空时 `remove()` 无限阻塞，`shutdown()` 既不投递「毒丸」也不中断线程。关闭后再 `call()` 会把任务投进同一个队列，而 worker 已全部置 false（若恰好被唤醒则退出、任务无人执行），Future 永不完成。
- **描述**：`Server` / `RxScheduler` 等以 `Resource.close()` 关闭池时，N 个线程泄漏且进程无法优雅退出；`ExecutorPoolTest` 的 `finally { pool.shutdown() }` 也不会真正回收线程。
- **建议**：关闭路径投递 N 个哨兵任务（或队列里放 `?()`，`None` 表示退出）后 `join`；`running` 置 false 前先让 worker 有退出点；`call()` 在 `!running` 时直接返回已完成的 Future（而不是入队）。补「shutdown 后线程数归零 / 再 call 立即返回」用例。

### [严重][存量] `ConcurrentSkipListMap` 的 `size_` 可能变成负数（`clear()` 与 `add()` 的代际检查竞态）

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:359-368`（先 `size_.fetchAdd(1)`，再判 epoch 并**无条件** `fetchSub(1)`）、`:520-527`（`clear()` 先 `epoch.fetchAdd(1)`，再 `size_.store(0)`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（检查-然后-写入非原子）、§11（边界 / 计数错误）
- **证据**：静态确定 —— 交错顺序：add 在 `:359` 把 size 加到 1 → `clear()` 在 `:522-526` 把 epoch +1 并把 size 置 0 → add 在 `:360` 发现 epoch 变化，`:366` 再 `fetchSub(1)` ⇒ size = -1。
- **描述**：此后 `size` 返回 -1、`isEmpty()` 恒为 false、`toArray()` 的 `Array<(K,V)>(size)`（`:668`）按负数长度分配直接抛异常；任何以 `map.size` 做分页/统计的调用方都会拿到负值。`clear()` 是公开 API，线上「清理缓存 + 并发写入」是常见组合。
- **建议**：把「是否已计入 size」做成显式状态：`clear()` 用 `epoch` 与 `size_` 的成对 CAS；更简单的方案是 `clear()` 不重置 `size_`，改把 `size_` 换成 `AtomicReference<SizeCounter>` 整体替换，避免「归零 + 回滚」交叉。

### [严重][存量] `DelayQueue` 的 `peek` / `size` / `isEmpty` 无锁读取非线程安全的 `PriorityQueue`（数据竞争）

- **位置**：`f_concurrent/src/DelayQueue.cj:42-44`（`peek` 直接 `queue.peek()`）、`:79-83`（`size`）、`:84-86`（`isEmpty`）、`:87-89`（`iterator` 在锁外创建迭代器）；被读对象 `f_collection/src/PriorityQueue.cj:169-192`（`peek` 读 `currentSize` + `queue[0]`，`remove` 在 `adjustDown` 中改写同一数组）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（共享可变状态无保护、迭代与修改并发）
- **证据**：静态确定 —— `add` / `remove` 全程 `synchronized(mutex)`，而 `peek` / `size` / `isEmpty` / `iterator()` **完全不取 mutex**；`PriorityQueue` 自身无任何同步手段（纯数组堆）。`DelayQueue` 是对外 `public` 的并发队列，多线程调用是默认场景。
- **描述**：`peek()` 与并发 `remove()` 可观察到同一个元素（消费者若按 `peek` 判空再 `remove` 会重复处理同一任务）；`size` 可能读到 `currentSize--` 后、`adjustDown` 前的中间态；`iterator()` 在锁外拿到内部数组迭代器，后续 `add` 触发的扩容/交换会让遍历读到已被清空的位置。
- **建议**：`peek` / `size` / `isEmpty` / `iterator()` 统一进入同一把 `mutex`（`iterator` 返回快照 `Array` 或返回「每次 `next` 取锁」的迭代器，现有 `DelayQueueIterator` 已按后者实现，但迭代器对象本身仍在锁外创建，需把创建放进锁内）。

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
- **建议**：不要用全局布尔当完成信号。最小改法：每个等待者用自己的 `Mutex`+`Condition`（或 `AtomicOptionReference<Result<T>>`）等待；或保留全局 `condition` 但改为 `notifyAll()` 且把 `notified` 换成按线程 id 的「已投递」集合、消费后即清除；`timeout` 分支必须 `datas.remove(threadId)` 清掉残留。补「同一 EventBus 串行两次 `arrangeAndGet`」与「16 线程并发 `arrangeAndGet`」两条用例。

### [严重][存量] Worker 的事件链没有异常隔离：ability 未注册或抛异常直接杀死工作线程

- **位置**：`f_concurrent/src/eventbus/Worker.cj:40-60`（`spawn` 的 `while` 循环内 `:49` `this.abilities[e](e)`，全段无 `try/catch`）、`:88-94`（`force` 同样直接调用 `abilities[ee](ee)`）；`abilities` 是 `ConcurrentHashMap`，下标访问缺键即抛异常（`:26`）
- **来源**：存量（`git blame -L 40,60` → `4be871f2fd`）
- **判据**：review-checklist §12.1（异步语义：异常被吞 / 线程生命周期）；§3（静默吞异常、失败路径不闭环）；§11（错误处理缺失）
- **证据**：静态确定 —— 事件被 `arrange` 入队后由 worker 线程执行；`abilities[e]` 对未注册事件抛 `KeyNotFoundException`，ability 内部任何异常也沿 `:49` 冒出。外层只有 `while`，没有捕获；线程终止后该 worker 的队列再无人消费，`deliverIfNeed`（`:58`）也不会执行。
- **描述**：一条坏事件（未注册的 event、ability 里一次 NPE/越界）就永久损失一个 worker；该 worker 队列里后续事件全部滞留（只有 `seize` 线程可能把任务偷走，且偷走后仍会在别的 worker 上因同一事件再次失败）。若走 `arrangeAndGet`，调用方拿不到结果。`EventBus` 没有任何 worker 存活监控，故障是静默的。
- **建议**：worker 循环用 `try { 链式执行 + deliverIfNeed } catch (e) { 记录日志 + 以失败完成该事件（至少 `event.setNoneData()` 后 `deliverIfNeed`）}` 包住，且不退出循环；`force` 的同步路径也要把异常转成「事件失败」而不是抛给调用者（或明确文档化为抛出）。对未注册事件，在 `arrange` 入口先查 `abilities` 并抛带事件名的 `EventBusException`，把错误暴露在提交侧。补「ability 抛异常后 worker 仍能处理下一条事件 / `arrangeAndGet` 立即返回」用例。

### [一般][存量] `Executors.maxQueueSize` 参数完全未使用，队列容量实际等于 worker 数（编译器已警告）

- **位置**：`f_concurrent/src/Executor.cj:24-27`（`let q = ArrayBlockingQueue<()->Unit>(executors)`，`maxQueueSize` 未参与）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（读了不用 / 死配置）、§11（契约与实现不符）、§14.1（配置项被读取却从未使用）
- **证据**：静态确定 —— 编译器告警 `unused variable: 'maxQueueSize'`（`f_concurrent/target/release/.build-logs/…errlog:21-24`）。调用方 `f_net/src/server/server.cj:46` 传 `Executors<Message>(executors: executors, maxQueueSize: 1)`，期望「1 个排队位」。
- **描述**：实际排队容量 = 200（worker 数），`f_net` 的背压假设失效：突增请求不会被 `tryAdd` 拒绝，而是堆到 200 个任务、每个都持有 `SocketBuffer` 强引用（内存放大），超时/丢弃策略也不再按配置生效。
- **建议**：`ArrayBlockingQueue<()->Unit>(maxQueueSize)`（worker 数只决定 `Array<Executor>` 长度），或在 `Executors` 里显式两条上限（worker 上限 + 队列上限）；删除该参数时同步改 `f_net` 调用点。

### [一般][存量] `Executors` 默认创建 1024 个 worker 线程

- **位置**：`f_concurrent/src/Executor.cj:24`（`executors!: Int64 = 1024`）、`:26`（每个 `Executor` 构造都 `spawn` 一个线程）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §5（无界/过大资源默认值）、§12.1（有界性）
- **证据**：静态确定（线程数 = `executors` 参数，构造即创建）；内存占用 `需实测`（线程栈大小取决于平台，未在本环境测量）。
- **描述**：库的默认构造即申请 1024 个 OS 线程，加上 1024 个 `Mutex`/`Condition`/`AtomicBool`/`ConcurrentHashMap`（其中 map 从未使用，见死代码）。小规模业务一旦不传参就走默认值，线程数与内存都会被放大。
- **建议**：默认值降到「核数 × 2」或 `8`，并在文档中写明；`Executors` 提供惰性创建 worker（首个任务到达才 spawn）。

### [一般][存量] 所有 `ExecutorFuture` 共用同一把互斥锁与同一个条件变量，每次完成都 `notifyAll` 全部等待者

- **位置**：`f_concurrent/src/Executor.cj:66-72` / `:90-99`（每个 Future 都用 `mutex`/`condition` 构造）、`:110-116`（`complete` 内 `condition.notifyAll()`）；`Executors.call` 固定走 `executors[0]`（`:28-42`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.2（锁粒度：能否分片 / 单值用原子）、§6.2（锁内唤醒放大）
- **证据**：静态确定 —— `Executors` 的 200 个 worker 共用 `executors[0].mutex`；等待者数 = 并发请求数（`f_net` 每个连接一个请求线程）。临界区内容：`result = …; finished = true; notifyAll()`，持有时长在微秒级，但 `notifyAll` 会唤醒**所有** pending Future 的等待者，被唤醒者抢锁后重新 `wait`（伪唤醒放大 O(n²)）。
- **描述**：请求并发升高时，每次任务完成都造成一次全量唤醒风暴，吞吐随并发度下降；这也是「200 个 worker 却只有 1 个 Future 锁」的结构性串行点。收益需实测，故不作为性能缺陷计入统计。
- **建议**：每个 Future 自带 `Mutex` + `Condition`（`ExecutorFuture` 内部 `new`），或改为单值 `AtomicOptionReference<Result<T>>` + 一个轻量 `SyncCounter`（`count` 归零即完成），彻底去掉共享条件变量；`Executor` 只保留提交队列。

### [一般][存量] `DelayQueue.remove/remove(timeout)` 先把元素取出再等待：超时契约被破坏、元素在等待期间对其它线程不可见

- **位置**：`f_concurrent/src/DelayQueue.cj:45-61`（`queue.remove()` 已出队 → `delayedCond.wait(timeout: v.delayedAt - now)` → 无条件 `return v`）、`:62-78`（`remove(timeout)` 用元素剩余延迟做等待，而不是调用方剩余预算）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）、§12.1（条件等待未在循环里重查条件）
- **证据**：静态确定 —— `:53` 等待时长 = `v.delayedAt - now`，与 `timeout` 无关；`:70` 同理。`timeout` 预算只在「队列空」分支（`:72`）参与判断，一旦取到未到期元素就完全绕过。`:54` / `:71` 等待返回后不重新比较 `delayedAt`，被提前唤醒即返回未到期元素（`Condition.wait` 早返回属平台语义，标 `待确认`）。
- **描述**：`remove(timeout: 10ms)` 在队首元素还有 5s 才到期时会阻塞约 5s；等待期间该元素已从堆中移除，`peek()` 看不到它、其它 `remove()` 会跳过它，`size` 也少算一个；若等待线程被取消/异常，元素永久丢失。
- **建议**：改为「`peek` 判到期 → 到期才 `remove`」，未到期则 `delayedCond.wait(剩余预算)` 并在 `while` 里重查（同时用 `MonoTime` 计算剩余预算）；`remove(timeout)` 的等待上限取 `min(元素剩余延迟, 调用方剩余预算)`，超预算返回 `None`。

### [一般][存量] `DelayQueue` 用 `DateTime`（墙钟）做延迟判定，系统时间跳变会导致提前/延后取到元素

- **位置**：`f_concurrent/src/DelayQueue.cj:23`（`prop delayedAt: DateTime`）、`:49` / `:70`（`DateTime.now()`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与命名不符 / 计时器语义）、fountain-baseline §5（先查 API 语义再下结论）
- **证据**：静态确定 —— 延迟判定与等待时长全部基于 `DateTime.now()`；`MonoTime`（单调时钟）已在同文件 `:63` 使用，说明作者知道两者区别。另外 `:67` 与 `:70` 各调一次 `DateTime.now()`，两次取值不一致。
- **描述**：NTP 校时/夏令时回拨会让元素提前到期或长时间不触发（`wait(timeout)` 用的是墙钟差值，回拨后可能变成负值）。延迟队列的到期语义应当单调。
- **建议**：`Delayed` 改用（或同时提供）`MonoTime` 版本的到期时间；`compare` 与 `wait` 全部基于单调时钟；`:67`、`:70` 复用同一个 `now`。

### [一般][存量] `ConcHashDict.clear()` / `ConcurrentHashSet.clear()` 用「遍历逐个删除」实现，非原子且 O(n) 次哈希

- **位置**：`f_concurrent/src/ConcHashDict.cj:140-144`、`f_concurrent/src/ConcurrentHashSet.cj:97-99`（转调 `removeIf{_ => true}`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）、§6.4（低效算法）、§2（同语义两处实现）
- **证据**：静态确定 —— 两处都是 `for ((k, _) in map) { map.remove(k) }` 的模式；`ConcDict` 的文档承诺「清除所有键值对」（`ConcDict.cj:80-83`），但并发写入时遍历是弱一致快照，循环结束后仍可能有新元素残留；`ConcurrentHashMap` 自带 `clear()`。
- **描述**：`clear()` 在并发场景下不满足「清空」语义；同时也是 n 次哈希 + n 次 CAS，比容器自带的 `clear()` 慢一个量级（无基准数据，性能部分只作说明）。
- **建议**：`ConcHashDict.clear()` 改为 `map.clear()`；`ConcurrentHashSet.clear()` 改为 `store.clear()`；如需「清空后仍拒绝旧写入」的语义，再另加代际计数。

### [一般][存量] `toArray()` 按瞬时 `size` 预分配并 `getOrThrow()`，并发收缩时抛异常

- **位置**：`f_concurrent/src/ConcHashDict.cj:206-212`（`Array<(K,V)>(map.size){ _ => itr.next().getOrThrow() }`）、`f_concurrent/src/ConcurrentSkipListMap.cj:666-669`（同形）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（边界 / 空集合未处理）、§5（按不可信规模预分配）
- **证据**：静态确定 —— `size` 与随后的迭代之间没有同步；期间发生 `remove` / `clear` 时 `itr.next()` 返回 `None`，`getOrThrow()` 抛 `NoneValueException`；`ConcurrentSkipListMap` 还叠加「size 可能为负」（见严重项），`Array(size)` 直接抛异常。
- **描述**：并发读多写多时 `toArray()` 会随机失败，且失败率随写入频率上升；这是 `Collection` 的通用读接口，调用方通常不会预期它抛异常。
- **建议**：改为 `ArrayList` 追加 + 最后 `toArray()`（长度自适应），或先取 `size` 作为容量提示、`next()` 返回 `None` 时正常结束；两处共用同一实现。

### [一般][存量] `AtomicInt8/16/32/64` 及无符号扩展的 `addFetch`/`subFetch` 在边界处溢出抛异常，但原子写已完成

- **位置**：`f_concurrent/src/AtomicInteger.cj:43-48`（`addFetch = fetchAdd(val) + val`、`subFetch = fetchSub(val) - val`），同形实现见 `:86-91`、`:129-134`、`:171-176`、`:213-218`、`:255-260`、`:297-302`、`:339-344`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（边界差一 / 溢出）、§10（正确性）、§3（失败路径与状态不一致）
- **证据**：静态确定 —— 仓颉整数算术默认溢出抛 `OverflowException`（同文件 `ConcurrentSkipListMap.cj:128` / `:141` / `:159` 用 `@OverflowWrapping` 显式规避，反证默认是检查型）；`fetchAdd` 已在硬件层完成原子写，随后的 `+ val` 溢出抛异常 ⇒ 内存值已改变而调用方收到异常，读到的「新值」与异常状态矛盾。典型触发：`Int8(127).addFetch(1)`、`UInt8(0).subFetch(1)`、`decrFetch()` 于 0。
- **描述**：把「检查型算术」叠在「环绕型原子运算」之上，边界上必然出现「值变了但抛异常」，且无文档说明。
- **建议**：返回值改为按环绕语义计算（`@OverflowWrapping` 标注或 `wrappingAdd` 等显式 API），并在接口注释写明「溢出按环绕处理」；若希望抛异常，则必须在写之前判断（CAS 循环），不能先写后算。

### [一般][存量] `ConcurrentHashSet.==` 依赖 `ConcurrentHashMap` 的迭代顺序，容量不同的相等集合会被判为不等

- **位置**：`f_concurrent/src/ConcurrentHashSet.cj:110-125`（逐位比较两个迭代器，`i == this.size` 收尾）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与命名 / 契约不符）、§12.1（迭代与修改并发）
- **证据**：需实测 —— `ConcurrentHashMap` 的迭代是桶序，桶下标 = `hash & (capacity-1)`；`ConcurrentHashSet(capacity: 100)` 与默认容量构造的同元素集合桶序不同 ⇒ 逐位比较在第一个元素就停止，返回 `false`。**缺** 一条「相同元素、不同容量」的断言用例，需按此构造复现。
- **描述**：`Equatable` 契约要求「元素相同即相等」，现实现实际比较的是「哈希表布局」，等价于弱化版有序比较；同时并发修改期间比较结果也无意义。
- **建议**：改为「小集合遍历 + `contains`」（`if (this.size != other.size) false else this 的每个元素都在 other 中`）；不要依赖迭代顺序。

### [一般][存量] `ConcurrentSkipListMap.entryView` 的 `fn` 在 CAS 失败时会被重复调用，有副作用的回调会执行多次

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:671-734`（`:705` / `:715` 失败后 `continue` 重新进入循环并再次 `fn(view)`）、`:735-739`（`(K,?V)->?V` 重载直接委托）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约未声明）、§12.1（检查-然后-写入的重试语义）
- **证据**：静态确定 —— 重试路径确实重新执行 `fn(view)`，且每次传入的 `oldVal?.value` 可能不同；`ConcurrentHashMap.entryView` 的 std 语义是否同样允许重试 `待确认`，但本类 README（`f_concurrent/README.md:285`）只给了签名，未说明「回调可能被调用多次」。
- **描述**：调用方若在回调里做计数、发消息、生成 ID，会在高竞争下重复生效；`ConcDict` 的默认实现 `addIfAbsent(key, fn)`（`ConcDict.cj:130-138`）正是把 `fn()` 放在回调里，等于「生成值可能被丢弃/重复」。
- **建议**：在 `entryView` 文档与接口注释中明确「回调必须是纯函数、可能被多次调用」；`ConcDict.addIfAbsent` 的默认实现改为先 `get` 再 `addIfAbsent`（或缓存已生成的值跨重试复用）。

### [一般][存量] `Constants` 的静态缓存无容量上限、无淘汰，键由调用方任意字符串拼接

- **位置**：`f_concurrent/src/Constants.cj:20`（`private static let constants = ConcurrentHashMap<String, Any>()`）、`:22-28`（`computeIfAbsent('${TypeInfo.of<T>()}-${key}')`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §5（缓存键无界 → OOM）、§7（有界化）
- **证据**：静态确定 —— 缓存是进程级 `static`，只增不减；键含调用方传入的 `key`。仓内无调用点（`README.md:352` 有文档说明），实际键的分布 `待确认`。
- **描述**：一旦有调用方用请求 ID / 用户 ID 之类的高基数 `key`，进程内存单调增长且无法回收（GC 也清不掉静态强引用）。该 API 的命名（`Constants`）暗示「常量」，但实现是任意键缓存，语义误导。
- **建议**：在 API 文档明确「`key` 必须是有限枚举，禁止使用请求级 ID」；实现上加容量上限 + 淘汰（或改用 `LRUCache`），超限时抛异常/不缓存而非静默增长。

### [一般][存量] 限流器定时器回调在空载时阻塞出队，永不返回：线程无法被 `close()` 回收（`LeakingBucket` 自循环 / `SlidingWindow` 阻塞 `remove`）

- **位置**：`f_concurrent/src/LeakingBucketRateLimiter.cj:42-59`（`do { … } while (next <= Duration.Zero)`，空桶时 `bucket.remove(remainder)` 阻塞满一个周期后 `next ≈ 0` 恒满足循环条件）、`:74-79`（`close()` 仅 `timer.cancel()`）；`f_concurrent/src/SlidingWindowRateLimiter.cj:36-47`（`Timer.after(Duration.Zero)` 回调中 `:41` `queue.remove()`，无超时）、`:69-74`（`close()` 只 `timer.cancel()`）、`:46`（`atExit(timer.cancel)`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（线程生命周期 / 有界性）、§6.2（阻塞动作在调度回调里）
- **证据**：静态确定（`SlidingWindow` 一处另据 std 文档）—— `LeakingBucket`：循环条件与空桶时 `next` 的关系可纯代码推导，回调进入「睡一个周期 → 判 `next<=0` → 再睡一个周期」的无限循环；`SlidingWindow`：`std.sync.Timer.cancel()` 明确「如果调用该函数时关联 Task 正在执行，不会打断当前运行。该函数不会阻塞当前线程」（`sync/sync_package_api/sync_package_classes.md:11013-11021`），低负载时回调正卡在 `ArrayBlockingQueue.remove()` 上，`cancel()` 只阻止下一次调度。
- **描述**：这是同一个根因在两个限流器上的两种表现：低负载（桶空/队列空，最常见）时定时器回调永久占住一个线程且永不返回；`close()` 只取消后续调度，无法终止已进入阻塞的回调，`queue`/`prev`/`this` 仍被阻塞栈持有。若 `Timer` 的回调共享线程池，还会拖住同进程其它定时任务（`f_net` 的连接巡检、`f_ticktock` 任务）；若限流器按连接/租户动态创建，线程数线性增长。两处的 `Timer.cancel()` 是否可中断正在执行的回调，`SlidingWindow` 侧已由文档确认不可，`LeakingBucket` 侧 `待确认`（缺 `std.sync.Timer` 线程模型文档，本环境无本地文档源）。
- **建议**：回调一律改为非阻塞：`LeakingBucket` 用 `tryRemove()` 批量漏出后 `return max(next, 1ms)` 交还调度权；`SlidingWindow` 用 `tryRemove()` 取不到就 `return Some(1ms)`；两者都增加 `closed: AtomicBool` 作为循环/等待退出条件，`close()` 置位（可选投递哨兵元素唤醒）并等待回调退出。补「close 后空闲线程退出 / 回调不再执行」用例（现有 `RateLimiterClose_test` 未覆盖）。

### [一般][存量] `LeakingBucketRateLimiter.timer` 是非原子 `var`，`close()` 无同步读取

- **位置**：`f_concurrent/src/LeakingBucketRateLimiter.cj:24`（`private var timer: ?Timer = None`）、`:60`（构造末尾赋值）、`:74-79`（`close()` 读取）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（可见性：普通字段跨线程当信号）
- **证据**：待确认 —— 需要「`close()` 与构造/另一个 `close()` 并发」的调用路径；`RateLimiterClose_test.cj:59-66` 只在同线程调用。若池化淘汰线程与构造线程不同，则属于无同步发布。
- **描述**：轻则 `close()` 读到 `None` 而未取消定时器（线程/定时器泄漏），重则两次 `close()` 并发取消同一 `Timer`（是否幂等需查文档）。
- **建议**：改为 `AtomicOptionReference<Timer>`（或 `AtomicReference`）以 `compareAndSwap(Some(t), None)` 保证只取消一次；`close()` 幂等。

### [一般][存量] `AnyMomentRateLimiter` 不校验 `maxTokens`，`<=0` 时静默变成全拒绝

- **位置**：`f_concurrent/src/AnyMomentRateLimiter.cj:27-30`（直接 `ArrayBlockingQueue<Unit>(maxTokens)`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（缺少边界校验）、§3（静默失效）、§10（正确性）
- **证据**：待确认 —— `maxTokens <= 0` 时 `ArrayBlockingQueue` 构造的具体行为（抛异常 / 容量 0）需查 std 文档；两种结果都不是期望语义：抛异常 = 构造期崩溃，容量 0 = `add` 永远失败、所有任务静默走 `default`。同一模块的 `LeakingBucketRateLimiter.cj:38-40` 已做参数校验，两者不一致。
- **描述**：配置写错（0 / 负数）不会得到明确错误，而是限流器整体失效，线上表现为「所有请求都拿到默认响应」，很难定位。
- **建议**：构造时校验 `maxTokens > 0`，抛 `RateLimiterException`（与 `LeakingBucket` 保持一致）。

### [一般][存量] `atExit(timer.cancel)` 让每个限流器实例挂进进程级退出回调表且无法注销，`close()` 后仍不能回收

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:46`、`f_concurrent/src/TokenBucketRateLimiter.cj:50`（同类位置：`f_concurrent/src/LeakingBucketRateLimiter.cj:61`，该处由 part1 读取文件、part2 作范围外提示指出，形态相同）；注册表语义 `std.env.atExit`（`env/env_package_api/env_package_funcs.md:3-30`，只有注册、无注销）；`Timer` 生命周期 `sync/sync_package_api/sync_package_classes.md:10740`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §5（长期持有 / 注册表不注销 → 内存无界）、§7（缩短生命周期、对称注销）
- **证据**：静态确定 —— `atExit` 的回调要「当前进程退出时执行」，必须在进程生命周期内一直持有；标准库与 `f_base.ExitCallbacks`（`f_base/src/signal.cj:36-68`）都只提供 `add`，没有移除接口。`timer.cancel` 是绑定方法，强引用 `Timer`，`Timer` 又持有构造时的 task 闭包（引用 `this.queue` / `this.prev` / `this`）。
- **描述**：每个用过的 `TokenBucketRateLimiter` / `SlidingWindowRateLimiter` / `LeakingBucketRateLimiter` 都会在退出回调表里留下一条永不释放的记录，`close()` 仅取消定时器、不会摘掉回调 ⇒ 限流器及其队列（`ArrayBlockingQueue(limit)` / `LinkedBlockingQueue(tokens)`）直到进程退出都无法被 GC。配置热更新或按连接建限流器时内存单调增长。
- **建议**：去掉 `atExit(timer.cancel)`，改由持有方（连接池 / 服务）在 `close()` / 淘汰时显式取消；若必须兜底，用一个进程级单例回调统一 `cancel` 一个弱引用列表（`WeakRef<Timer>`），并在 `close()` 时移除自身。

### [一般][存量] `SlidingWindowRateLimiter` 的 `Mono.time` 用无界自旋等待写入，定时器线程可能持续烧 CPU

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:81-89`（`get()` 里 `while (_time.load().isNone()) {}`）、`:42-43`（定时器读到 `mono.time`）、`:57-58`（`exec` 先 `queue.add` 再写 `mono.time`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（条件等待未在循环里重查条件、忙等）；§6.2（调度回调里的忙等）
- **证据**：静态确定 —— 入队成功与写入 `time` 之间存在窗口；定时器线程 `queue.remove()` 取到该元素后调用 `mono.time` 会进入 `while` 自旋，直到 `exec` 线程被调度执行 `:58`。写入方若被长时间抢占，自旋就持续占用一个核。
- **描述**：正常负载下窗口很短，但这是「用自旋代替同步」的写法：`time` 只写一次、读侧无超时，一旦写入线程被挂起（GC、调度、debug 断点），定时器线程无限忙等；同时它让定时器线程无法处理下一个窗口。
- **建议**：改为一次性 handshake：`Mono` 内用 `Mutex` + `Condition`（写入后 `notify`，读侧 `wait`），或把时间戳改为入队前写入、定时器侧用 `max(mono.time, dequeueTime)` 兜底；更简单的是让 `exec` 在 `queue.add` 成功返回后立刻写 `time` 并在 `Mono` 中保存 `AtomicBool ready`，读侧 `waitUntil` 而非空转。

### [一般][存量] `WorkerStrategy.New` 未实现：被并入 `CurrentThread`，在调用线程同步跑完整条事件链

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:94-105`（`:103` `case CurrentThread | New => currentThreadStrategy`）；承诺源 `f_base/src/WorkerStrategy.cj:62-67`（`New` 的文档：「创建新实例，如果是任务队列就创建新线程……用完即弃」）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §14.1（承诺了但没实现 / 只做了一半的分支）；§11（契约与实现不符）
- **证据**：静态确定（双证）—— 枚举文档承诺「创建新线程」，`genDoArrange` 把 `New` 与 `CurrentThread` 合并到同一个 `currentThreadStrategy`（`EventBus.cj:193-195` → `arrange(id, e, true)` → `:249-251` 在调用线程 `force`），代码中没有 `spawn` 分支对应 `New`。
- **描述**：选择 `New` 的调用方期望「不占原工作线程、用完即弃」，实际是同步阻塞当前线程（对 `arrangeAndGet` 意味着调用线程要等整条链跑完，且期间无法处理其它事）；且 `New` 与 `CurrentThread` 的行为完全一致，枚举值等于摆设。
- **建议**：为 `New` 单独实现策略：`spawn { workers[workerId].force(event) }`（与 `arrange(..., currentThread=false)` 的 `:252-257` 分支一致），并明确「新线程不回收、每事件一条线程」的代价；或在文档中删掉 `New` 的线程语义并改名。补一条「`New` 策略下 `arrange` 不阻塞调用者」的用例。

### [一般][存量] `EventBus.retireAll()` 停不掉线程：阻塞在 `queue.remove()` 的 worker 永不被唤醒，`seize` 线程也没有退出路径

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:197-201`（`retireAll` 仅逐个 `worker.retire()`）、`:63-93`（`seize()` 的 `while (true)` + `seizeQueue.remove()`，无退出条件）；`Worker.cj:40-47`（循环条件在阻塞前判断，`queue.remove()` 无超时）、`:65-67`（`retire` 只置原子位）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（线程/资源生命周期、有界性）；§11（契约与实现不符）
- **证据**：静态确定 —— `retired` 只在 `:41` 的循环条件与 `:98` / `:107` 的入口检查处被读；worker 已经停在 `:46` 的 `queue.remove()` 时没有任何信号能唤醒它（`retire` 不投毒丸、不 `interrupt`）。`EventBus` 没有 `close()`，`seize` 线程是 `while (true)` 且只阻塞在 `seizeQueue.remove()`。
- **描述**：`retireAll` 之后线程数不下降（至少「已空闲的 worker」与 seize 线程常驻），进程无法优雅退出；队列里还有事件的 worker 会继续执行（`queue.size > 0` 使循环继续），与「退役」语义相反；退役期间对已退役 worker 的 `arrange` 直接抛异常（见下一条）。
- **建议**：`retire` 时向队列投递哨兵（`JobQueue` 里放 `?Event`，`None` 表示退出）或改用带超时的 `remove(timeout)` 轮询 `retired`；`seizeQueue` 同样投毒丸并让 `seize` 线程退出；补 `close()` 语义：`retireAll` + 等待全部线程结束。补「retireAll 后线程数归零」用例（可用 `Process`/`Thread` 计数或日志断言）。

### [一般][存量] `arrangeAndGet` 的结果槽把 `?Any` 存进 `Any`，读取时多一层 Option；超时后条目不清除会返回上一次的结果

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:287`（`ConcurrentHashMap<Int64, Any>`）、`:297-310`（`convert(d: ?Any)` 里 `case Some(x) => match (x) { case x: T … }`）、`:335-346`（`deliverIfNeed` 取 `event.getData<Any>()` → `deliver(…, data: ?Any)` → `datas.add(id, data)`）；`Event.cj:56-61`（`getData` 返回 `?T`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）；§3（失败路径与返回类型不一致）
- **证据**：待确认（需一条 `arrangeAndGet` 用例确认装箱层级）—— `getData<Any>()` 返回 `Some(x)`，`deliver` 再以 `?Any` 存入 `Any` 槽，`datas.remove` 得 `Some(Some(x))`，`convert` 的 `case x: T` 拿到的是 Option 而不是 `T`，按类型检查应恒不匹配（`toThrowIfNotMatch=true` 时抛「data does not match」）。另一处为静态确定：`:323-329` 超时分支直接抛异常，不 `datas.remove(threadId)`；若任务随后才完成，`deliver` 会把结果写进该槽，该线程下一次 `arrangeAndGet` 在 `:313` 先取到它 ⇒ 返回上一次事件的结果。
- **描述**：`arrangeAndGet` 是 README:375 列出的公开同步接口；按代码路径它要么永远拿不到值，要么在超时后拿到陈旧结果。仓内没有调用者与用例，所以问题一直没暴露。
- **建议**：`datas` 的 value 改为 `?Any` 或直接存 `Result<T>` 的擦除形式，避免二次装箱；`convert` 前先判定「槽位属于本次调用」（带一个自增 token/序号）；超时分支 `datas.remove(threadId)` 清理。补「ability 返回 `None` / `Some(Int64)`」「第一次超时、第二次正常」两条用例。

### [一般][存量] `EventBus` 未校验 `workers` / `maxWaitingJobPerWorker`：0 会在构造深处抛无上下文异常

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:48-62`（`:56` `LinkedBlockingQueue<Int64>(workers)`、`:57-59` `Array<Worker>(workers)`、`:233` `random.nextInt64(workers.size)`）；`JobQueue.cj:30-32`（`LinkedBlockingQueue<Event>(max)`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定（依据 std 文档）—— `LinkedBlockingQueue(capacity)` 在 `capacity <= 0` 时抛 `IllegalArgumentException`（`collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:2818-2823`），`workers = 0` 时 `nextInt64(0)` 也会失败；`JobQueue` 的构造在 `Worker` 里，异常栈会指向 `JobQueue.cj:31`。
- **描述**：配置写 0 时得到的异常信息是 `Invalid capacity '0'`，与「workers / maxWaitingJobPerWorker 配错」没有关联；若仅放宽 `LinkedBlockingQueue` 的校验而不补入口校验，`workers = 0` 还会让 `seize()` 线程永久阻塞在 `seizeQueue.remove()`，问题更隐蔽。
- **建议**：构造入口显式校验 `workers > 0 && maxWaitingJobPerWorker > 0`，抛带参数名的 `EventBusException`；同时把 `abilities` 中「事件名为空 / 重复注册」也在这里检查（当前同名事件在 `Worker.register` 里静默覆盖）。

### [一般][存量] `SyncPriorityQueue` 的 `capacity` / `overSizePolicy` 形同虚设：队列永远扩容，实际无界

- **位置**：`f_concurrent/src/SyncPriorityQueue.cj:21-54`（四个构造/工厂入口都只透传 `capacity` 与 `overSizePolicy`）、`:18`（`<: Queue<T> & Growable`）；被透传对象 `f_collection/src/PriorityQueue.cj:103-113`（`if (capacity > 0 && size >= capacity) { if (growOnFull) doOffer else overSizePolicy.reject }`）、`:114-131`（`doOffer` 的 `while (isFull()) grow()`）、`:130-146`（`grow` 直接翻倍）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符、配置项未接线）；§5（无界容器 → OOM）；§14.1（配置被读取却从未生效）
- **证据**：静态确定 —— `PriorityQueue` 的 `growOnFull` 默认 `true`，`SyncPriorityQueue` 没有暴露该参数，因此 `capacity > 0 && size >= capacity` 时永远走 `doOffer` 分支，`overSizePolicy` 分支不可达；`capacity` 只影响首次分配大小。README:348-349 却把 `init(comparator, capacity, overSizePolicy)` 作为可用参数列出。
- **描述**：调用方按 README 传 `capacity: 1000, overSizePolicy: DiscardOverSizePolicy` 会得到一个**无界**队列：超限不丢弃、不拒绝，而是翻倍扩容，直到 OOM。`f_egraph` 目前用默认 `capacity: 0`（本就无界）不受影响，但这是公开 API 的语义陷阱。
- **建议**：`SyncPriorityQueue` 增加并透传 `growOnFull!: Bool`（默认 `false`，与「有 `overSizePolicy`」的直觉一致），或对 `capacity > 0` 固定 `growOnFull: false`；若刻意保持无界，就删掉 `overSizePolicy` 参数并同步改 README。补「capacity=2 时第 3 个元素按策略被丢弃/拒绝」用例。

### [一般][存量] `LoadBalance.add` 不校验权重：`weight <= 0` 时新键不递增，直接覆盖前一个节点

- **位置**：`f_concurrent/src/LoadBalance.cj:78-87`（`:79` `max = tree.last?[0] ?? min`、`:80` `new = max + weight`、`:81` `tree[new] = fn`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（缺少边界校验 / 数据丢失）；§3（静默失效）
- **证据**：静态确定 —— `weight = 0` 时 `new == max`，TreeMap 同一键赋值覆盖前一个节点的 `fn`；`weight < 0` 时新键小于前键，破坏「键 = 累计权重」的单调性，`forward` 的桶划分随之失真。
- **描述**：配置写成 0 / 负权重（如从配置解析失败得到 0）不会报错，表现为「某个节点永远不被选中」或「两个节点合并成一个」，与 `f_dbd` 的 `algorithmOf` 对权重和的校验（`Datasource.cj:180-191`）不一致。
- **建议**：`add` 入口校验 `weight > 0`，否则抛 `LoadBalanceException`（与 `f_dbd` 的 `CONFIG` 语义对齐）；`tree[new]` 改为 `tree.add(new, fn)` 之类的「键已存在即失败」写法，避免静默覆盖。

### [一般][存量] `LoadBalance` 对「算法给出越界键 / 空树」的错误处理三处不一致

- **位置**：`f_concurrent/src/LoadBalance.cj:88-90`（`call` 越界 → `next().getOrThrow()` 抛 `NoneValueException`）、`:114-124`（`iterator` 越界 → `forward` 为空 → `LoadBalanceIterator` 静默从 `itr` 头部绕回）、`:91-113`（空树时返回 `(None, None)`，既不成功也不报错）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符、错误类型不一致）
- **证据**：静态确定 —— `tree.forward(v)` 在 `v > 最大键` 时返回空迭代器；`call` 直接 `getOrThrow`；`iterator` 的 `:118-122` 用 `tree.isEmpty()` 判断，越界但非空时 `forward` 为空，`LoadBalanceIterator.next()` 的 `:136-142` 会 `endsub = true` 后回到 `itr.next()`（键最小的节点）。
- **描述**：同一份数据、同一种异常输入，`call` 抛标准库 `NoneValueException`（不是 `LoadBalanceException`，调用方无法按契约捕获），`iterator` 静默降级到第一个节点（掩盖了算法错误，也是上条严重项的表现之一），`call(maxRetrying)` 空树返回 `(None, None)` 与「成功但无值」不可区分。`f_dbd` 的 `connect()` 只 catch `ConnectionException`，越界异常会穿透成非预期错误。
- **建议**：统一为一个显式语义：`tree.isEmpty()` → 抛 `LoadBalanceException("no node registered")`；`forward` 为空（算法越界）→ 抛 `LoadBalanceException("algorithm returned out-of-range key")`（同时修上文的回绕竞态）；`iterator` 不要静默绕回，或在文档中明确「越界即从头开始」并让 `call` 与之一致。三处共用同一个 `pickFirst()` 实现。

### [一般][存量] `TimeoutException` 与 `std.core.TimeoutException` 同名，且模块内没有任何抛出点

- **位置**：`f_concurrent/src/exception/TimeoutException.cj:20`（`public class TimeoutException <: BaseException`）
- **来源**：存量（`git log --diff-filter=A` → `d3ca87f00` 2024-11-10「增加限流器……还有一些并发相关的异常」创建；此后仅 `4be871f2f` 2026-10-02 换行符统一）
- **判据**：review-checklist §11（语义与命名 / 契约与实现不符）、§10（设计：对外 API 命名）、§14.1（声明了类型但无任何产生路径）
- **证据**：静态确定 —— `std.core` 的 `TimeoutException` 是隐式导入（`cangjie_docs/docs/dev-guide/source_zh_cn/package/import.md:143-145`：「编译器会自动为源码隐式的导入 core 包中所有的 public 修饰的声明」），定义在 `stdlib/libs/std/core/timeout_exception.cj:11`，并由 `std.core.Future.get(timeout)` 抛出（`stdlib/libs/std/core/future.cj:126`）。仓内既有代码捕获的都是 core 版本：`f_pool/src/KeyPool.cj:653`、`f_jsonrpc/src/server/JsonRpcServer.cj:293`、`f_net/src/test/f_net_tcp_test.cj:179`、`fprobe/src/collect/hw/CommandRunner.cj:77`（这四个文件都没有导入本模块的异常包，靠隐式导入解析）。本模块内 `grep "throw TimeoutException"` 命中 **0** 次，`imports.cj` 也没有导入它，即这个类型从定义起从未被使用。
- **描述**：模块对外导出了一个与语言预置类型完全同名、语义也相同（超时）的异常类，自己却从不抛出。下游一旦 `import fountain::f_concurrent.exception.TimeoutException`（或 `import ...exception.*`），就与隐式导入的 `core.TimeoutException` 同名：按 `import.md:219`（「如果没有对导入的存在冲突的名字进行重命名，在 import 语句处不报错；在使用处，会因为无法导入唯一的名字而报错」），使用处会编译失败；若编译器改为让显式导入遮盖 core，则同一文件里 `catch (e: TimeoutException)` 会静默捕获错类型——`Future.get(timeout)` 抛出的 core 版本反而漏捕。两种结果都让这个类型在它的本意用途（捕获超时）上不可用。冲突的编译期具体表现标 `待确认`（本轮按要求不跑构建）。
- **建议**：删除该类型，超时统一用 `std.core.TimeoutException`（`ExecutorFuture.get(timeout)` 当前返回 `None`，与 core 版本不冲突；将来若改成抛出，直接用 core 版本即可）。若确有模块专属语义（如带限流上下文的超时），改名 `ConcurrentTimeoutException` 并在 README 写明与 core 版本的捕获关系。该类型仓内零引用，删除零成本（对外可见性建议仍需用户拍板）。

### [轻微][存量] 死代码清单：未被调用的私有实现、未使用字段/参数/导入、注释掉的残留

- **位置**：
  - part1：`f_concurrent/src/ConcurrentSkipListMap.cj:261-282`（`isReachable`，全仓唯一引用是 `:285` 的注释）、`f_concurrent/src/ConcHashDict.cj:217-234`（`ConcDictView`，仅定义未构造）、`f_concurrent/src/Executor.cj:55`（`result` 字段无读写）、`f_concurrent/src/Constants.cj:19`（`private init()`）、`f_concurrent/src/ConcDict.cj:18`（未使用 import）、`f_concurrent/src/ConcurrentSkipListMap.cj:522`（`oldEpoch`）、`f_concurrent/src/ConcDict.cj:131/140/149`（lambda 形参 `k`）、`f_concurrent/src/DelayQueue.cj:59` / `:76`（`while(true)` 之后的 `None<T>` 不可达）、`f_concurrent/src/ConcurrentSkipListMap_bug_test.cj:1-173`（全文注释）
  - part2：`f_concurrent/src/eventbus/JobQueue.cj:18`（`ConcurrentHashMap`）、`:19`（`EventBusException`）两个未使用 import；`f_concurrent/src/RateLimiter.cj:38`（`// public static let INSTANCE = UnlimitedRateLimiter<T>()`）
  - part3：`f_concurrent/src/imports.cj:22`（`std.process.Process`，全包零使用）
- **来源**：存量（工作区快照，无基线可比；`imports.cj:22` 的 blame 指向 `8f93b4e11` 2025-05-02）
- **判据**：review-checklist §1（无调用者 / 读了不用 / 不可达语句 / 未使用 import / 兼容残留）
- **证据**：静态确定 —— 大部分项由编译器 `-Wunused` 直接点名（`f_concurrent/target/release/.build-logs/…errlog`：`unused import`、`unused function:'init'`、`unused variable:'oldEpoch'`、3×`unused variable:'k'`、`unused import 'std.collection.concurrent.ConcurrentHashMap'`、`unused import 'fountain::f_concurrent.eventbus.exception.EventBusException'`）；`isReachable` / `ConcDictView` 全仓（含 `.worktrees/` 快照）搜索只剩定义处；`imports.cj` 是 `internal import`，按 `import.md:294` 对当前包及全部子包可见，而 `grep -w Process` 只命中该行（`eventbus/EventBus.cj:19` 用的是 `std.runtime.getProcessorCount`），且该文件不在 `-Wunused` 覆盖范围内（编译日志 7 条告警无一指向 `imports.cj`）；`RateLimiter.cj:38` 的 `INSTANCE` 只存在于注释。
- **描述**：三部分的残留同源——跳表从「全表可达性校验」回退到 `validateNode` 后未清理旧函数、`ConcDictView` 是 `entryView` 改造前的包装层、`JobQueue` 的两个 import 是早期「直接抛 `EventBusException`」版本的残留、`imports.cj` 的 `Process` 是「跟随版本修改」时带入的通配/包级导入残留。测试文件整段注释后仍参与编译，`f_concurrent_bug_test` 这个名字会让人误以为有覆盖；注释掉的单例让人误以为有全局无限流器可用。
- **建议**：删除编译器已告警的残留、两个无调用私有实现与三处注释掉的代码行；`bug_test.cj` 要么恢复用例（当前 4 个 `size` 一致性用例在 `_conc_test.cj` 里已有更弱版本），要么删文件；`imports.cj` 另建议给 `std.sync.*` / `std.env.*` / `fountain::f_base.*` / `fountain::f_collection.*` 四个通配导入各加一行注释，写明「服务哪些未自带 import 的文件」（现状是 `RateLimiter.cj` / `DelayQueue.cj` / `LeakingBucketRateLimiter.cj` / `SlidingWindowRateLimiter.cj` / `SyncPriorityQueue.cj` 依赖它，而 `LoadBalance.cj` / `ConcurrentSkipListMap.cj` 自带 import），否则下次清理时同样查不出残留；`helpPhysicallyRemove`（`:515`）仅本文件使用，可收窄为 `private`（属可见性建议，不是死代码）。

### [轻微][存量] 重复逻辑：`retain`/`retainAll`、容器 `clear`、`Atomic*` 8×9 同形扩展

- **位置**：`f_concurrent/src/ConcurrentHashSet.cj:73-77` 与 `:100-104`；`f_concurrent/src/ConcHashDict.cj:140-144` 与 `f_concurrent/src/ConcurrentHashSet.cj:97-99`；`f_concurrent/src/AtomicInteger.cj:18-354`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §2（同语义不同入口 / 只改类型名）
- **证据**：静态确定 —— `retain(all!)` 与 `retainAll(values)` 的循环体、谓词、副作用逐行等价，仅参数名与修饰不同；`clear` 两处同为「遍历 + 逐个删」（该同形的行为后果已按 §11 单列为一般项）；`Atomic*` 的 72 个方法体是同一模板对 8 种数值类型展开。
- **描述**：`retain` 是 `Set` 接口要求，`retainAll` 是额外入口，两者长期并存必然漂移；`Atomic*` 的逐类型展开使「溢出语义」这类修改要同步 8 处（见一般项），是漏改的结构性来源。
- **建议**：`retainAll` 转调 `retain`（或反过来），只保留一处实现；`Atomic*` **不建议**泛型化（仓颉对数值类型没有可用的统一 trait，抽象只会加间接层），改为在文件头注释说明「逐类型展开是刻意为之，改一处要同步 8 处」，降低后续漏改风险。

### [轻微][存量] 重复逻辑：6 个异常类 4 构造器逐字节同形、3 个限流器 `close()` 同形、6 个满队列策略成对近似

- **位置**：`f_concurrent/src/exception/ConcurrentException.cj:20-32`、`exception/LoadBalanceException.cj:20-32`、`exception/RateLimiterException.cj:20-32`、`exception/ReadWriteSyncerException.cj:20-32`、`exception/TimeoutException.cj:20-32`、`eventbus/exception/EventBusException.cj:20-32`；`SlidingWindowRateLimiter.cj:69-74` / `TokenBucketRateLimiter.cj:60-65` / `LeakingBucketRateLimiter.cj:74-79`（三个 `close()` 逐行同形）；`EventBus.cj:106-195`（`abort*` / `discardCurrent*` / `discardOldest*` 各成对）
- **来源**：存量（工作区快照，无基线可比；创建提交 `d3ca87f00` / `4be871f2f`）
- **判据**：review-checklist §2（只改类型名 / 同语义不同入口）
- **证据**：静态确定 —— 6 个异常类除类名外四个构造器（`init()` / `init(String)` / `init(Exception)` / `init(String, Exception)`）逐行相同，基类 `f_base/src/BaseException.cj:44-57` 已提供同样 4 个构造器，但仓颉**构造函数不继承**，子类只能重写；`close()` 都是 `match (timer) { case Some(t) => t.cancel(); case _ => () }`；策略对的差异只有「是否多一次 `tryArrange(timeout)`」与「拒绝时抛异常还是丢弃」。
- **描述**：异常类的重复是语言约束造成的强制重复，不是可抽取的重复逻辑（泛型化会让 `catch (e: RateLimiterException)` 这类按类型捕获失效，宏化只为一个 4 行模板引入编译期复杂度），真实成本是「给异常加字段（如错误码）要同步改 6 个文件」；`close()` 的语义（幂等、置 closed）分散在三处，容易漂移；策略对复制意味着新增一种策略要同步改两处。
- **建议**：异常类保留现状（对外 API 类型名有语义价值），只在 `exception/` 目录或 README 补一句「异常类统一沿用 4 构造器模板，改动需同步 6 个文件」；抽一个 `RateLimiter` 基类的 `protected func cancelTimer()` 供三个限流器复用，并在其中统一置 `closed`；策略函数改为参数化：`genStrategy(timeout!: ?Duration, onReject: RejectAction)`，差异点（超时、抛/丢/deliver）显式入参。

### [轻微][存量] 注释/文档与实现不符、复制粘贴残留、日志通道与计数不规范

- **位置**：`f_concurrent/src/DelayQueue.cj:50`（「先使用peek取得值，再这个if内remove有可能导致活锁」，实际实现是「先 remove 再判到期」）；`f_concurrent/src/ConcDict.cj:44-45` 与 `f_concurrent/src/ConcHashDict.cj:82-83`（文档注释里多出一行 `           120`）；`f_concurrent/src/SlidingWindowRateLimiter.cj:26-29`（`@param timeout 时间窗口`，实际 `timeout` 是入队等待超时、窗口是 `window`）、`:24` + `:38-39`（`unfinishedTasks = AtomicInt64(1)`，首次超时日志打印 `1 tasks`）、`:38`（`Console.writeln` 而非 `f_log`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与注释不符）、§10（可读性）、fountain-baseline §6（日志走 `f_log`，热点路径不 `println`）
- **证据**：静态确定 —— `DelayQueue` 注释描述的算法与 `:48-54` 的代码顺序相反；`120` 在文档注释中间自成一行，无任何语义；`SlidingWindowRateLimiter.cj:57` 用的是 `timeout` 作为 `queue.add` 的等待时长、`window` 才是窗口；`fetchAdd(1)` 返回旧值，初值 1 使第一条日志的计数从 1 开始（应为 0 或先 `fetchAdd` 再打印新值）。
- **描述**：误导性注释比没有注释更危险：读者会以为「先 peek 后 remove」是刻意设计，从而误判并发语义；参数注释会把使用者引向错误配置（把窗口配到 `timeout` 上）；限流超时是运维关注事件，走 `Console` 会绕过日志级别/异步缓冲/采样。
- **建议**：按当前实现重写 `DelayQueue` 注释（说明「取出后等待、等待结束即返回」的取舍与副作用），删除两处 `120`；修正 `@param` 说明；`unfinishedTasks` 初值改 0 并用 `fetchAdd(1) + 1` 打印；改用 `f_log`（该模块若不便依赖 `f_log`，至少统一走一个可注入的 logger）。

### [轻微][存量] `FindNodeCache` 的数组长度硬编码 17，与 `MAX_LEVEL` 无关联

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:89-90`（`Array<Option<Node<K,V>>>(17)`）、`:102`（`MAX_LEVEL = 16`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §10（可维护性）、§11（魔数与常量脱钩）
- **证据**：静态确定 —— 17 = `MAX_LEVEL + 1` 只体现在注释里；调整 `MAX_LEVEL` 时两处不会同步，`preds[level]` 将越界。
- **建议**：`MAX_LEVEL` 改为 `static const`，数组长度写 `MAX_LEVEL + 1`。

### [轻微][存量] `header` 与 `tailer` 的 `including` 默认值相反且 `header` 无文档

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:751-753`（`including!: Bool = false`）与 `:759-769`（`including!: Bool = true`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §10（可读性 / API 一致性）
- **证据**：静态确定 —— 同为区间边界参数，一个默认排除、一个默认包含；`tailer` 有 `@param` 说明，`header` 没有。
- **建议**：统一默认值（建议都「包含」）或在两处都写明默认语义；补 `header` 的参数注释。

### [轻微][存量] 测试有效性：恒真断言、时序依赖、单次计时当性能、缺并发与生命周期用例

- **位置**：`f_concurrent/src/ConcurrentSkipListMap_conc_test.cj:734`（`@Assert(map.size == 0 \|\| map.size > 0)`）、`f_concurrent/src/ConcurrentSkipListMap_test.cj:228` / `:240`（`@Assert(true)`）、`ConcurrentSkipListMap_perf_test.cj:36` / `:52` / `:68` / `:92` / `:135`（只 `println` 单次耗时）、`ConcurrentSkipListMap_conc_test.cj:53-70`（`result.store(1)` 而非累加，无法发现「多个线程都插入成功」）、`ConcurrentSkipListMap_test.cj:230`（`@TestCase` 缩进错位）；`f_concurrent/src/RateLimiterClose_test.cj:76`（`@Assert(true, true)`）、`:48-56` / `:59-66`（首次 `exec` 依赖零延迟定时器在 `timeout`（1ms / 5ms）内补到令牌，`sleep` 与周期强耦合）、`:69-77`（只验证两次 `close()` 不抛，未验证线程退出）；`f_concurrent/src/LoadBalance_test.cj:32-133`（全部单线程，无一条并发 `next()`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（恒真分支）、§6.1（性能结论必须有数据）、§11（用例无法覆盖目标缺陷）
- **证据**：静态确定 —— 恒真表达式与占位断言可读即知；`perf_test` 无多轮/中位数，`-O0` 下运行，结论不可引用（baseline §8）；`store(1)` 无计数语义；`tokens: 1, timeout: 1ms, populationPeriod: 10ms` 的首次断言取决于调度；RoundRobin 的越界竞态没有任何用例（这也是本模块严重项未被发现的原因）。
- **描述**：`test_no_duplicate_keys_under_high_concurrency` 用 `@Expect` 做了全表计数（有效），但 `test_concurrent_insert_same_key` 的 `result` 不是累加，重复插入也只会得到 1；`close` 相关用例只覆盖「不再补令牌」，没有覆盖「阻塞回调能否退出」这一真正的资源风险，`testSlidingWindowCloseIsIdempotent` 自身会留下一个阻塞在 `queue.remove()` 的线程；性能测试打印的数字不能作为任何优化依据。
- **建议**：恒真断言删除或改为有意义的终态校验；`result` 改 `fetchAdd(1)`；首次 `exec` 改为「先 `sleep(populationPeriod)` 再断言」或把 `populationPeriod` 调到远小于 `timeout`；新增「16 线程并发 `next()` 落在区间内」「`close()` 后线程数下降 / 回调退出」两条用例；`perf_test` 若要保留，改为 `cjpm bench -O2` + 多轮取中位数，或在文件头标注「仅冒烟，不作性能结论」。

### [轻微][存量] 退役 worker 的 `tryArrange` 抛异常，会打断 `tryArrangeOther` / `discardOldest*` 的容错循环

- **位置**：`f_concurrent/src/eventbus/Worker.cj:106-111`（retired 即抛 `EventBusException`）；`EventBus.cj:265-271`（`tryArrangeOther` 的 `while` 条件直接调用它）、`:129-138`（`discardOldestStrategy` 的 `while`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（边界 / 契约）
- **证据**：静态确定 —— `tryArrange` 抛异常时 `while (i < workers.size && !tryArrange(...))` 整个表达式退出，不会尝试下一个 worker；`discardOldest*` 同样直接抛出而不是丢弃。
- **描述**：部分退役（缩容）后，只要随机/哈希落到退役 worker，`arrange` 就以异常失败，而不是换一个可用 worker；这与「`tryArrangeOther` 就是为换 worker 准备」的设计意图相反。
- **建议**：`tryArrange` 对 retired 返回 `false`（由调用方换 worker），只在 `arrange`（阻塞式）里抛；或在 `tryArrangeOther` 内 catch 并跳过退役 worker。

### [轻微][存量] `LoadBalanceIterator` 绕回时重复枚举已走过的后缀，重试候选出现重复

- **位置**：`f_concurrent/src/LoadBalance.cj:132-143`（`sub` 走完后 `endsub = true` 再 `next()` → `itr.next()`；`itr` 是整棵树）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义偏差 / 重复遍历）
- **证据**：静态确定 —— `sub` = `[algo 选定键, 末尾]`，`itr` = `[最小键, 末尾]`；枚举总量为 `n + (n - idx + 1)`（`idx` 为选定键下标），选定键及其后缀被枚举两次。
- **描述**：`call(data, maxRetrying)` 按该迭代器重试时，越靠后的节点会被重复尝试，重试顺序与「每个节点一次」的直觉不符；`MultiClient` 只取第一个元素，暂不受影响。
- **建议**：`itr` 改为「从最小键到选定键之前」的前缀（`tree.forward(min).takeWhile(k < chosen)` 或先收集键再切分），保证整轮枚举恰好覆盖每个节点一次；补一条「迭代器长度 == 节点数且无重复」的用例。

### [轻微][存量] `SyncPriorityQueue.iterator()` 返回的是弱一致迭代器，类名与文档没有说明

- **位置**：`f_concurrent/src/SyncPriorityQueue.cj:93-97`、`:110-117`；底层 `f_collection/src/PriorityQueue.cj:234-238`（创建时捕获 `queue.iterator()` 与 `currentSize`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（迭代与修改并发）；§11（契约未声明）
- **证据**：静态确定 —— 迭代器持有创建时刻的内部数组引用与 `max_` 长度；后续 `add` / `remove` 在同一数组内 `adjustUp/Down`、`grow` 换新数组（`PriorityQueue.cj:130-146`），迭代期间读到的顺序/成员可能变化或重复。每次 `next()` 有锁，因此不是数据竞争，但也不是快照。
- **描述**：类名 `Sync*` 与 README 的「并发优先队列」容易让人认为迭代是快照或强一致；实际是弱一致，且未在任何注释说明。
- **建议**：在类注释与 README 写明「iterator 为弱一致视图，迭代期间不得依赖元素集合」；如需快照，`iterator()` 内 `toArray().iterator()`（代价 O(n) 拷贝）。

### [轻微][存量] `LoadBalance` 的 `tree` 无任何同步，`add` 与 `call/iterator` 并发不安全且未声明

- **位置**：`f_concurrent/src/LoadBalance.cj:76`（`private let tree = TreeMap<...>()`）、`:78-87`（写）、`:88-124`（读）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（共享可变状态无保护）；§11（契约未声明线程安全）
- **证据**：静态确定 —— 类内没有锁/原子/不可变快照；`TreeMap` 非线程安全。仓内 `add` 只在构建期调用（`MultiClient.cj:177`、`LLMConfsHolder.cj:214`、`Datasource.cj:97`），读路径在请求线程并发。
- **描述**：当前用法（构建后只读）实际安全，但公开 `add` 允许运行期增删节点；一旦如此，`call/iterator` 会读到重排中的树。同时 `RoundRobin` 内部有 `Mutex`，容易让人误判整个 `LoadBalance` 线程安全。
- **建议**：在类/README 明确「`add` 仅限初始化阶段，运行期只读」；若要支持热更新，改为「构建新 TreeMap → `AtomicReference` 整体替换」的写时复制。

### [轻微][存量] `EventBus.seize` 偷任务后不刷新被偷 worker 的统计，且有一处无意义的 let 绑定

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:84-90`（`tryRemove()` 后只 `putQueueSize(sizedBy)`，未 `putQueueSize(maxQueueIndex)`）、`:72-82`（`:77` `if (let s <- …waitingJobSize && maxQueueSize < s)`，`waitingJobSize` 不是 Option，绑定恒成立）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（状态不一致）；§10（可读性）
- **证据**：静态确定 —— 被偷 worker 的队列少了一个元素，但 `maxQueueSize` 仍记着旧值；该值只在 `putQueueSize` 里更新，而偷取路径不调用它。`let s <-` 在非 Option 上等价于直接比较。
- **描述**：`maxQueueSize` 偏高会让 `seize` 线程反复对同一个 worker 做 `tryRemove`（返回 `None`，空转），在长期运行的 EventBus 上累积无效扫描；`let s <-` 让读者误以为 `waitingJobSize` 可能是 `None`。
- **建议**：偷取成功后补 `putQueueSize(maxQueueIndex)`；`:77` 改为 `if (maxQueueSize < workers[i].waitingJobSize)`。

### [轻微][存量] `ReadWriteSyncerException` 是孤儿类型：全仓无 `ReadWriteSyncer`、无抛出点，README 却把它列为模块异常

- **位置**：`f_concurrent/src/exception/ReadWriteSyncerException.cj:20`；承诺源 `f_concurrent/README.md:353-354`、`f_concurrent/README_en.md:353-354`
- **来源**：存量（`git log --diff-filter=A` → `d3ca87f00` 2024-11-10 创建）
- **判据**：review-checklist §14.1（承诺源 + 缺失证据）、§13（文档与实现一致性）、§11（语义与能力不符）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`、`target/`）`grep -w ReadWriteSyncer` 只命中该定义与 README 两行；没有 `ReadWriteSyncer` 类型、没有 `throw ReadWriteSyncerException`、`imports.cj` 未导入、`grep -rn "f_concurrent.exception"` 显示外部模块只导入了 `LoadBalanceException`（`f_net/src/client/MultiClient.cj:20`、`f_rpc/src/client/ClientConfig.cj:19`）。README 原文：「**异常**（`exception/`）：`ConcurrentException`、`LoadBalanceException`、`RateLimiterException`、`ReadWriteSyncerException`、`TimeoutException`」——把 5 个类型并列为「模块异常」，其中实际有抛出路径的只有 `RateLimiterException`（4 处：`RateLimiter.cj:21`、`SlidingWindowRateLimiter.cj:33`、`TokenBucketRateLimiter.cj:32`、`LeakingBucketRateLimiter.cj:39`）与 `LoadBalanceException`（`LoadBalance.cj:101` 构造、`:109` 抛出）；`ConcurrentException` / `ReadWriteSyncerException` / `TimeoutException` 抛出点均为 0。
- **描述**：异常类本身对外可达（public 顶层声明），按硬原则一**不算死代码**；问题在于它承载的「读写同步」能力在模块里根本不存在，README 的并列写法会让读者以为模块提供读写同步器。这与本模块「限流器/容器/负载均衡」的实际能力范围不符。
- **建议**：能力已规划未实现 → README 标注「预留、尚未实现」或从异常清单移除并说明；已放弃 → 删类并同步 `README.md` / `README_en.md`（删除对外 public 类型属契约变更，需用户确认无下游依赖）。

## 优化可行性方案

> 不是缺陷，是「还能更好」。本模块**未提供任何 profile / bench 数据**（`scope.md`「已有性能资料」为空），以下 5 条全部为 `无基线（待验证，不进 tasks）`。

### [CPU] `EventBus` 每次入队/出队都取全局 `queueMutex`，把统计量变成串行点

- **现状**：`arrange` 每次分发后调 `putQueueSize`（`f_concurrent/src/eventbus/EventBus.cj:239-240`），`Worker.tryRemove` 每次取任务后也调（`Worker.cj:120-128`）；两者都在 `synchronized(queueMutex)` 内读 `queue.size` 并可能写元组（`EventBus.cj:276-283`）。即每个事件至少 2 次全局锁往返，worker 数 N 时全部 worker 在这一把锁上排队。
- **方案**：`maxQueueSize` 只是 `seize` 的启发式，可改为「每个 worker 一个 `AtomicInt64` 队列计数 + `seize` 线程周期性扫描（或按阈值触发）」，把 per-event 的全局锁去掉；至少把 `putQueueSize` 改成只在越过高水位/低水位时更新。
- **预期**：去掉每事件 2 次全局互斥；吞吐提升比例取决于 N 与临界区占比（未测）。
- **代价**：`maxQueueSize` 从「精确」退化为「近似」，偷任务的时机略有延迟；需要保证 `seizeQueue` 的唤醒频率不下降。
- **验证**：N=8/32 worker，事件处理耗时 10µs，跑 5 分钟，对比 `putQueueSize` 的锁等待时间（线程状态采样）与吞吐；`cjpm bench -O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `LoadBalance.iterator()` 每请求分配迭代器与两个闭包；节点选择用 `SecureRandom`

- **现状**：`f_net` 每个 RPC 请求调用 `loadbalance.iterator()`（`MultiClient.cj:228`），每次构造 `tree.iterator()`、`forward(...).map(mapper)`、`LoadBalanceIterator`，且 `algo.next()` 需要取锁（`f_concurrent/src/LoadBalance.cj:114-124`、`:35-49`）；`Int64Weight` / `Float64Weight` 用 `SecureRandom`（`:52`）选节点。
- **方案**：`RoundRobin` 路径提供「只取下一个节点」的 `nextNode()`（不建迭代器，`tree.forward(...).next()`），`MultiClient` 直接用；随机权重改用 `std.random.Random`（节点选择不需要密码学强度），并确认 `SecureRandom` 是否线程安全（文档未声明）。
- **预期**：每请求少 2-3 个短生命周期对象/闭包；`SecureRandom.nextInt64` 的单次开销与锁竞争占比待测。
- **代价**：新增一个内部 API；随机分布仍需通过现有 `LoadBalance_test` 的比例断言。
- **验证**：`cjprof record` 跑 200 并发 RPC 压测 60s，看 `iterator`/`next`/`SecureRandom` 的 self time 与分配量；`cjpm bench -O2` 前后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 跳表上层的「每层重新从 head 下降」与 `entryView` 的整轮重试

- **现状**：`physicallyRemove` 对每一层调用 `findPredecessorAtLevel`（`f_concurrent/src/ConcurrentSkipListMap.cj:462-492`），后者每次从 `MAX_LEVEL` 重新下降 ⇒ 每次删除 O(log²n)；`entryView` 在 CAS 失败时整轮重跑（含 `findNode`）。
- **方案**：删除时复用 `findNode` 的 `preds`（该节点已在 `FindResult` 里），或一次性收集各层前驱再逐层 CAS；`entryView` 失败重试只重读 value，不重跑 `findNode`。
- **预期**：删除路径比较次数从 O(log²n) 降到 O(log n)（16 层 × 17 次比较 → 17 次量级）；实际收益取决于删除占比，需 profile。
- **代价**：需要处理「前驱已失效」的退化路径，复杂度上升；并发正确性需压力测试复核。
- **验证**：`cjprof record` 跑 `ConcurrentSkipListMap_conc_test` 的混合负载（16 线程 / 5s），看 `findPredecessorAtLevel` 自耗时占比；再跑 `cjpm bench -O2` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `Executors` 的 1024 个空 `ConcurrentHashMap` 与每线程 `ThreadLocal` 缓存

- **现状**：每个 `Executor` 持有一个从未使用过的 `ConcurrentHashMap<Int64,T>`（`f_concurrent/src/Executor.cj:55`），默认 1024 个；`ConcurrentSkipListMap` 每个 map 每线程还持有 2×17 个 `Option<Node>` 的数组（`ConcurrentSkipListMap.cj:88-91`），线程数 × map 数增长。
- **方案**：删除 `Executor.result`；`FindNodeCache` 改为按需分配（首次 `findNode` 再 `Array(17)`），或在 `MAX_LEVEL` 降低到 12 后同步缩小数组。
- **预期**：消除 1024 个空 map（对象数 -1024）；每线程缓存由固定 34 槽降为按需（仅在真正使用该 map 的线程上分配）。字节量待测。
- **代价**：`findNode` 首次调用多一次分配；无锁语义不变。
- **验证**：`cjpm bench -O2` 前后对照 + `getAllocatedHeapSize()` / RSS，构造 1 个池 + 100 线程跑 10 分钟。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `SlidingWindowRateLimiter` 每个任务分配 `Box<MonoTime>` 并放进 `AtomicOptionReference`

- **现状**：每个受控任务构造一个 `Mono`，`time` 用 `AtomicOptionReference<Box<MonoTime>>`（`f_concurrent/src/SlidingWindowRateLimiter.cj:78-88`），即每任务一个 `Mono` + 一个 `Box` + 一层原子引用；元素在队列里存活一个 `window`。
- **方案**：`Mono` 改为 `class Mono(time: MonoTime)`（入队前写入 + 读侧按上文 handshake/兜底），去掉 `Box` 与 `AtomicOptionReference`；队列容量为 `limit`，元素生命周期由窗口决定，不必再原子化。
- **预期**：每任务少 1 个 `Box` 与一层原子包装（对象数 -1，另省一次原子 `store`/`load`），峰值分配量与 GC 压力按 QPS 比例下降（未测）。
- **代价**：需要解决「入队前写入时间」与「等待时长计入窗口」的语义差异（见自旋项的建议）；并发正确性需压测复核。
- **验证**：固定 `limit=100`、QPS=1k、跑 10 分钟，对比 `getAllocatedHeapSize()` 与 RSS，`cjpm bench -O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。本表不计入模块统计。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单 Future 共用锁 + `notifyAll` 在 200 worker 下造成唤醒风暴，吞吐随并发下降 | `f_concurrent/src/Executor.cj:110-116` | P99 延迟、每秒唤醒次数、锁等待占比 | 200 worker / 500 并发请求跑 5 分钟，`cjprof` + 线程状态（BLOCKED/WAITING）采样，改前改后对照 |
| 2 | `DelayQueue` 的「先取后等」使 `remove(timeout)` 平均超时误差远大于配置值 | `f_concurrent/src/DelayQueue.cj:62-78` | 实测 `remove(timeout=10ms)` 的 P50/P99 阻塞时长 | 预置 1 个 delayedAt=+5s 的元素，1k 次调用统计时长分布 |
| 3 | 限流器空闲时线程数与内存随实例数线性增长（`Timer` 是否共享线程决定影响面） | `f_concurrent/src/LeakingBucketRateLimiter.cj:42-59`、`f_concurrent/src/SlidingWindowRateLimiter.cj:36-47` | `Timer` 线程模型（共享池 or 每 Timer 一线程）、线程数/RSS 随实例数增长曲线 | 构造 10/100 个限流器、空闲 60s 后读 `/proc/self/status` 的 `Threads` 与 RSS，并对 `Timer` 源码/文档确认 |
| 4 | 跳表 `physicallyRemove` 的 O(log²n) 在删除密集场景成为热点 | `f_concurrent/src/ConcurrentSkipListMap.cj:462-492` | `findPredecessorAtLevel` 自耗时占比 | `cjprof record` 跑 16 线程 50% 删除混合负载，n=10⁵ |
| 5 | `EventBus` 的 `queueMutex` 在 N worker 下成为分发吞吐上限 | `f_concurrent/src/eventbus/EventBus.cj:276-283`、`:239-240` | 锁等待时间占比、线程状态 | 8/32 worker 跑 10µs 事件 5 分钟，线程状态采样（BLOCKED）+ 改造前后吞吐 |
| 6 | `SecureRandom` 参与节点选择（`arrange` / `next`）造成可观延迟 | `f_concurrent/src/LoadBalance.cj:52`、`EventBus.cj:224-233` | 单次 `nextInt64` 耗时、占比 | `cjprof record` 跑 200 并发 60s，或微基准 10⁶ 次调用取中位数 |
| 7 | 每请求构造 `LoadBalanceIterator` + 两个闭包的分配占比 | `f_concurrent/src/LoadBalance.cj:114-124` | 分配量与 GC 时间占比 | `cjprof heap` + 200 并发压测，统计每请求分配字节 |

## 文件覆盖

> 与 `{workdir}/files/f_concurrent.txt` 一一对应（`modules.md` 记 34 个文件，本模块清单全部为 `.cj`；`README.md` / `README_en.md` / `doc/performance_report.md` 不在清单内，仅作承诺源引用，不计入覆盖）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_concurrent/src/AnyMomentRateLimiter.cj` | .cj | ✅ | 48 行；参数校验缺失（一般项） |
| 2 | `f_concurrent/src/AtomicInteger.cj` | .cj | ✅ | 354 行；8×9 同形扩展，溢出语义见一般项 |
| 3 | `f_concurrent/src/ConcDict.cj` | .cj | ✅ | 未使用 import（编译器告警）；默认方法 3 处未用参数 `k`；注释残留 `120` |
| 4 | `f_concurrent/src/ConcHashDict.cj` | .cj | ✅ | `ConcDictView` 死代码；`clear` / `toArray` 见一般项 |
| 5 | `f_concurrent/src/ConcurrentHashSet.cj` | .cj | ✅ | `==` 依赖迭代顺序；`retain` / `retainAll` 重复 |
| 6 | `f_concurrent/src/ConcurrentSkipListMap.cj` | .cj | ✅ | 核心容器；size 负数、`isReachable` 死代码、`entryView` 重试、`FindNodeCache` 魔数 |
| 7 | `f_concurrent/src/ConcurrentSkipListMap_bug_test.cj` | .cj | ✅ | 全文 173 行均为注释，文件无有效内容 |
| 8 | `f_concurrent/src/ConcurrentSkipListMap_conc_test.cj` | .cj | ✅ | 25 个并发用例；含恒真断言（`size == 0 \|\| size > 0`） |
| 9 | `f_concurrent/src/ConcurrentSkipListMap_perf_test.cj` | .cj | ✅ | 只 `println` 单次耗时，无中位数/多轮，不能作为性能结论 |
| 10 | `f_concurrent/src/ConcurrentSkipListMap_test.cj` | .cj | ✅ | 单线程功能用例较完整；`@Assert(true)` 占位两处 |
| 11 | `f_concurrent/src/Constants.cj` | .cj | ✅ | 静态缓存无上限；`private init` 未被使用（编译器告警） |
| 12 | `f_concurrent/src/DelayQueue.cj` | .cj | ✅ | peek/size 无锁；先取后等；两处不可达 `None<T>`；墙钟判定 |
| 13 | `f_concurrent/src/Executor.cj` | .cj | ✅ | 3 个严重项来源；`maxQueueSize` 未使用（编译器告警） |
| 14 | `f_concurrent/src/Executor_pool_test.cj` | .cj | ✅ | 仅 1 个用例（慢任务不阻塞其它 worker），无异常/关闭用例 |
| 15 | `f_concurrent/src/LeakingBucketRateLimiter.cj` | .cj | ✅ | 定时器回调空桶死循环；`timer` 非原子；`atExit` 残留 |
| 16 | `f_concurrent/src/LoadBalance.cj` | .cj | ✅ | 144 行；`RoundRobin` 回绕竞态（严重项）、`add` 权重校验、越界处理不一致 |
| 17 | `f_concurrent/src/LoadBalance_test.cj` | .cj | ✅ | 133 行；单线程用例完整，无并发用例 |
| 18 | `f_concurrent/src/RateLimiter.cj` | .cj | ✅ | 45 行；`close()` 默认空实现有注释说明（有意 Null Object）；注释掉的 `INSTANCE` |
| 19 | `f_concurrent/src/RateLimiterClose_test.cj` | .cj | ✅ | 78 行；恒真断言、时序依赖、未验证线程退出 |
| 20 | `f_concurrent/src/SlidingWindowRateLimiter.cj` | .cj | ✅ | 98 行；阻塞回调 + `atExit` 保留 + 自旋等待 + 注释/日志不符 |
| 21 | `f_concurrent/src/SyncPriorityQueue.cj` | .cj | ✅ | 117 行；`capacity`/`overSizePolicy` 不生效、迭代器弱一致 |
| 22 | `f_concurrent/src/TokenBucketRateLimiter.cj` | .cj | ✅ | 66 行；回调非阻塞（可退出），`atExit` 保留问题同 SlidingWindow |
| 23 | `f_concurrent/src/eventbus/EndEvent.cj` | .cj | ✅ | 29 行；无问题 |
| 24 | `f_concurrent/src/eventbus/Event.cj` | .cj | ✅ | 84 行；原子字段、`==`/`hashCode` 按 name；`startEvent`/`ordinal` 对外可达无仓内引用（不算死代码） |
| 25 | `f_concurrent/src/eventbus/EventBus.cj` | .cj | ✅ | 347 行；`notified`/`notify`、结果槽装箱、`New` 策略、retire 生命周期、参数校验、seize 统计 |
| 26 | `f_concurrent/src/eventbus/JobQueue.cj` | .cj | ✅ | 50 行；两个未使用 import（编译器告警）；`max <= 0` 直接抛底层异常 |
| 27 | `f_concurrent/src/eventbus/Worker.cj` | .cj | ✅ | 129 行；事件链无异常隔离（严重项）、retired 抛异常打断重试 |
| 28 | `f_concurrent/src/eventbus/exception/EventBusException.cj` | .cj | ✅ | 32 行；4 构造器，与另外 5 个异常类同形 |
| 29 | `f_concurrent/src/exception/ConcurrentException.cj` | .cj | ✅ | 32 行；仓内无引用（对外可达，不算死代码） |
| 30 | `f_concurrent/src/exception/LoadBalanceException.cj` | .cj | ✅ | 32 行；仅 `LoadBalance.call` 使用 |
| 31 | `f_concurrent/src/exception/RateLimiterException.cj` | .cj | ✅ | 32 行；4 构造器，仅 `message` 版本被 4 处限流器使用（`RateLimiter.cj:21` 等）；类名无冲突 |
| 32 | `f_concurrent/src/exception/ReadWriteSyncerException.cj` | .cj | ✅ | 32 行；孤儿类型（见轻微项）；README 列为模块异常 |
| 33 | `f_concurrent/src/exception/TimeoutException.cj` | .cj | ✅ | 32 行；与 `std.core.TimeoutException` 同名、零抛出（见一般项） |
| 34 | `f_concurrent/src/imports.cj` | .cj | ✅ | 28 行；`internal import` 包级导入 12 条，11 条有使用、`std.process.Process` 无使用 |

合计：`.cj` 34 个 / `.md` 0 个 / 共 34 个，全部读完（part1 15 + part2 15 + part3 4，与 `modules.md` 的 34 一致）。模块 `README.md` / `README_en.md` / `doc/performance_report.md` 只作为承诺源被引用，未列入模块清单，故不计入覆盖。

## 覆盖自检

> 全部维度都必须出现，命中 0 条也写理由。命中数为三个部分之和，同根因合并后按一条计。

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 24 | 正确性：size 负数、限流拒绝挂起、`entryView` 重试、`Atomic` 溢出、`clear` 语义、`toArray` 抛异常、RoundRobin 越界、`arrangeAndGet` 通知与结果槽、`add` 权重、越界处理三态、seize 统计；设计：共享 condition、`Executors` 默认线程数、`Constants` 语义命名、`New` 策略、`overSizePolicy` 无效、retire 生命周期、`LoadBalance` 无同步约定、`imports.cj` 职责不统一、`TimeoutException` 命名；可读性：注释不符、无意义 let 绑定；语言特性：`AtomicOptionReference<Box<…>>` + 自旋代替同步；安全性 0 命中：无外部输入注入面、无凭据、无敏感日志 |
| §1 死代码 | 10 | part1 7 项（`isReachable`、`ConcDictView`、`Executor.result`、`Constants.private init`、`ConcDict` 未使用 import、`oldEpoch`/lambda `k`、`DelayQueue` 两处不可达 `None<T>`；另 `bug_test.cj` 全文注释）+ part2 2 项（`JobQueue` 两个未使用 import、`RateLimiter` 注释掉的 `INSTANCE`）+ part3 1 项（`imports.cj` 的 `std.process.Process`）。已逐个机械核对 `private` / `internal` / `protected` 符号并全仓搜引用：`LoadBalanceIterator`、`SyncPriorityQueueIterator`、`JobQueue` 各方法、`EventBus` 全部 private 函数、`helpPhysicallyRemove` 均有引用；对外可达 `public`（`ExtendAtomic*`、`ConcurrentHashSet`、`DelayQueue`、`Event.*`、三个异常类）按硬原则一不判，只作可见性建议 |
| §2 重复逻辑 | 6 | part1 3 项（`Atomic*` 8×9 同形、`retain`/`retainAll`、容器 `clear` 两处）+ part2 3 项（6 异常类 4 构造器、3 个限流器 `close()`、6 个满队列策略成对）；part3 的「异常类同形」与 part2 同根因，合并后不重复计。已两两比对函数体：`findNode`/`isReachable`/`get` 三份近似下降遍历（`isReachable` 无调用，已计死代码）；`LoadBalance` 的节点选择在 `call`/`iterator`/`call(maxRetrying)` 三处各写一遍（并入「越界处理不一致」） |
| §3 空实现 | 1 | `ExecutorFuture` 无失败态、`complete` 只在成功路径被调用，等价于「失败路径静默不完成」；`Worker` 的异常不闭环已归 §12.1/§11。排除项：`RateLimiter.close()` 是带注释的有意 no-op（Null Object）、三个异常类 `init() {}` 转调 `BaseException`、`abort*/discard*/block*/currentThread*` 均有实际行为，无 `TODO`/`FIXME`/空 `catch` |
| §4 栈溢出 | 0 | 已核对全部递归/自调用：无递归函数；跳表遍历均为显式循环、`Node` 之间无环；`LoadBalanceIterator.next()` 递归受 `endsub` 保证只 1 层；`arrangeAndGet.get(false)` 递归最多 2 层；`Worker` 事件链是 `while` 循环；4 个声明层文件无任何调用 |
| §5 OOM | 4 | `Constants` 静态缓存键无界、`Executors` 默认 1024 线程且队列容量随 worker 数放大、`atExit(timer.cancel)` 进程级强引用无注销、`SyncPriorityQueue` 的 `capacity` 不生效导致实际无界；另 `arrangeAndGet` 的 `datas` 超时残留（并入该条）与 `EventBus` 队列有界（`maxWaitingJobPerWorker`）已核对；`DelayQueue` 无容量上限属队列语义（Java `DelayQueue` 同为无界），未计 |
| §6.1 热点瓶颈 | 0 | 三部分均未提供 profile / bench 数据（`scope.md` 明确为空），「函数 + 自耗时占比 + 调用路径 + 输入规模 + 工具」五要素不齐，热点不成立；`notifyAll` 唤醒风暴、跳表删除 O(log²n)、`queueMutex`、`SecureRandom`、每请求迭代器、限流器线程数共 7 条线索全部进「待验证假设」 |
| §6.2 大粒度锁 | 1 | 所有 Future 共用一把 mutex + 一个 condition（一般项），临界区只含赋值与 `notifyAll`，问题在唤醒放大而非持有时长；`DelayQueue` 在持锁期间 `Condition.wait` 会释放锁，未命中；`EventBus` 的 `queueMutex` 临界区仅 `size` 读取与元组写入（微秒级），`SyncPriorityQueue` 的 `removeIf` 在锁内调用户谓词但仓颉 `Mutex` 可重入，均只作说明 |
| §6.3 并发串行 | 1 | `Executors` 的 200 worker 共享一个队列与一个 Future 锁 ⇒ 提交/完成两段串行（并入 §12.2 条目）；无 `spawn(...).get()` 自锁等待；`EventBus` 单 `seize` 线程 + 每事件一次全局锁属串行线索，但无并发度/吞吐数据，只进优化方案 |
| §6.4 低效算法 | 2 | `clear()` 的 n 次 remove（一般项）；`physicallyRemove` 每层重新从 head 下降 O(log²n)（仅作优化方案，无数据）。`LoadBalanceIterator` 绕回重复枚举是 O(n) 额外工作，按轻微正确性报，不作性能缺陷 |
| §7 降堆内存方案 | 2 | 删除 `Executor.result` 空 map + `FindNodeCache` 按需分配；`Mono` 去 `Box`/原子引用。均 `无基线`。`atExit` 保留属缺陷（§5）已单列 |
| §8 降 CPU 方案 | 3 | `EventBus` 每事件全局锁 → 分片/原子计数；`LoadBalance` 每请求迭代器/闭包 + `SecureRandom`；跳表删除复用 `preds` / `entryView` 局部重试。均 `无基线` |
| §9 local mode 可行性 | 0 | 热点对象全部跨线程/跨生命周期逃逸：跳表节点、`Future`、队列元素、`Event`（提交线程→worker→投递线程）、`Mono`（调用线程→队列→定时器线程）、`LoadBalance` 的闭包（长期存在 TreeMap）；`findNode` 的临时 `FindResult` 已是线程缓存复用。无「函数内创建、函数内释放」的大临时对象，且缺峰值内存前后对照 ⇒ 按规则记不可行（缺数据） |
| §11 现有代码的 BUG（存量） | 45 | 本模块 45 条发现全部为存量（快照 `8c0ce643a`，除 `docs/review/`、`reviews/` 外无 diff；blame 指向 `4be871f2fd` 2026-10-02 / `d3ca87f00` 2024-11-10 / `8f93b4e11` 2025-05-02）。已逐函数核对边界、空值、错误处理、资源释放、并发与契约；三部分自检原计 18/22/3，合并去重后按完整发现集计 45 |
| §12 并发安全与锁粒度 | 16 | 共享点与同步手段：`Executor.q/running/future`（异常、关闭、共享 condition 三处缺陷）、`DelayQueue.queue`（锁覆盖不全）、`ConcurrentSkipListMap.headRef/size_/epoch`（CAS + 代际，size 负数竞态）、`RoundRobin.current`（Mutex 但回绕拆分）、`EventBus.datas/notified/condition`（全局锁 + 单播唤醒）、`Worker.abilities/queue/retired`（并发容器 + 原子位）、`SyncPriorityQueue.queue`（单锁全覆盖，仅迭代器弱一致）、`SlidingWindow.queue/prev/_time`（阻塞队列 + 原子 + 自旋）、`LoadBalance.tree`（无同步，仅构建期写）、`Constants` 静态 map、限流器 `timer`（普通 var）。未发现多锁嵌套与锁顺序反转；「限流拒绝 → Future 永不完成」等价于调用方永久阻塞 |
| §13 文档一致性（.md） | 3 | `README.md` 与实现对照出 3 处不一致：①`:353-354` 把 `ReadWriteSyncerException` 列为模块能力（无对应实现、零抛出）；②`:348-349` 把 `capacity` / `overSizePolicy` 列为可用参数（实现不生效）；③`:352` / `:375` 的 `Constants` / `arrangeAndGet` 只有签名、无「键必须低基数」「通知不可复用」等约束说明。三点均已并入对应发现，不重复计入模块统计；`README_en.md` 仅在 `:353-354` 取过承诺源，未做全文逐段比对（属下一轮补证） |
| §14 功能完备性与 README 覆盖 | 4 | ①`WorkerStrategy.New` 承诺建新线程、实现为当前线程（双证：`WorkerStrategy.cj:62-67` + `EventBus.cj:103`）②`SyncPriorityQueue` 的 `capacity`/`overSizePolicy` 在 README:348-349 列为可用参数但实现不生效（双证）③`Executors.maxQueueSize` 接了参数但未接线（`server.cj:46` 传入、`Executor.cj:24` 未用）④README:353-354 异常清单含 `ReadWriteSyncerException` 但能力不存在（双证）。`public` 声明与 README 逐项对照未发现「API 未进 README」 |
| 文件覆盖（§13 等） | 34/34 | 34 个文件全部读完，无缺读；模块清单内无 `.md`，`README.md` / `README_en.md` / `doc/performance_report.md` 只作承诺源引用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 8 |
| 一般 | 24 |
| 轻微 | 13 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

> 合计发现 45 条，全部为存量（严重 8、一般 24、轻微 13），无「本次改动」引入项。合并前为三部分各 25 / 22 / 4 条（共 51 条），合并 5 组同根因条目（共减 6 条）后为 45 条：①死代码清单 3 条并 1（part1+part2+part3，减 2）②限流器定时器阻塞回调 2 条并 1（`LeakingBucket` + `SlidingWindow`，减 1）③异常类同形重复 2 条并 1（part2+part3，减 1）④注释/日志与实现不符 2 条并 1（part1+part2，减 1）⑤测试有效性 2 条并 1（part1+part2，减 1）；`atExit` 条目另把 part2 范围外提示的 `LeakingBucket.cj:61` 作为并列位置补入，不涉及计数。合并项严重程度一致，未出现需就高取值的情况。**存量 45 条，是否纳入修复待用户决定。** 7 条待验证假设不计入本表。

## 合并说明

- 合并依据：同一根因/同一缺陷在不同部分的重复描述，合并后列出全部位置（`并列全位置`）；`ConcHashDict.clear` 与 `ConcurrentHashSet.clear` 的「遍历删除」实现既是 §2 重复逻辑又是一般级 §11 缺陷，两处均保留但只在 §11 计一条，§2 只记重复关系。
- 严重程度：合并项均同级（死代码/重复/注释/测试类为轻微，定时器阻塞回调为一般），未出现「一部分判严重、另一部分判一般」的冲突，故无需按更严格值上调；`DelayQueue` 的无锁读（严重）与 `SyncPriorityQueue` 迭代器弱一致（轻微）分属不同根因（前者缺同步、后者已同步但非快照），未合并。
- 未合并的相邻项：`atExit` 无法注销（§5 内存）与限流器回调阻塞（§12.1 线程）虽同属限流器资源问题，但失效机制与修法不同（注册表无摘除 vs 回调不退出），保持两条并互相引用。
- 证据分级：需实测 1 条（`ConcurrentHashSet.==`）、待确认 5 条（`AnyMomentRateLimiter` 的 `maxTokens<=0`、`LeakingBucket.timer` 可见性、`arrangeAndGet` 装箱层级、`Condition.wait` 早返回、`entryView` 的 std 重试语义），其余为静态确定；`需实测` 条目未定严重。

## 总评

`f_concurrent` 是整套 fountain 的并发地基：跳表、延迟队列、执行器池、限流器、负载均衡、事件总线。设计意图普遍是清醒的——跳表用 CAS + 逻辑删除 + 代际计数，查找用线程局部 `preds` 缓存，限流器用令牌桶/漏桶/滑动窗口三种标准模型，EventBus 用「每 worker 一条队列 + seize 偷任务」做工作窃取。**问题不在思路，而在并发路径的错误分支和资源生命周期没有闭环**，且这类缺陷在默认配置下被掩盖，一旦配置变化或并发升高就会显形。

**阻塞项（严重 8 条，建议优先修）**：执行器池的三条主路径都会让调用方**永久阻塞**——任务抛异常（worker 死 + Future 不完成）、被限流器拒绝（Future 不完成）、`shutdown` 后（worker 不退出）——而 `f_net` 正是在请求线程上 `get()` 等结果，属于线上可触发的阻塞项。容器侧，跳表在 `clear()` 与 `add()` 交错时能把 `size_` 打成负数（随后 `toArray()` 按负长度分配崩溃），`DelayQueue` 的 `peek/size/isEmpty` 又在锁外读非线程安全的 `PriorityQueue`（消费者可重复处理同一任务），二者都是「容器契约本身被破坏」。负载均衡侧，`RoundRobin` 把「取值」和「回绕」拆成两个临界区，`f_dbd` 借连接会抛 `NoneValueException`、`f_net`/`f_llm` 会静默退化成「永远选第一个节点」，属于线上可触发的失效。EventBus 侧，`arrangeAndGet` 的通知机制只能支撑「单线程、只调用一次」，`Worker` 又没有异常隔离，一条坏事件就静默损失一个工作线程。

**需要设计拍板的**：EventBus 目前仓内零调用者，「对外 API 一旦被使用就踩坑」，建议要么补齐测试与修复，要么在 README 明确标注实验性；`WorkerStrategy.New` 与 `SyncPriorityQueue` 的 `capacity`/`overSizePolicy` 是「承诺了但没接线」的典型，前者应补 `spawn` 分支、后者应透传 `growOnFull`（或删参数并改文档）；`TimeoutException` 与 `std.core` 同名且自己从不抛出，下游一旦导入就会在使用处编译失败或 `catch` 捕错类型，建议直接删除、统一用 core 版本（零引用、零风险）；`ReadWriteSyncerException` 指向一个全仓不存在的能力，属文档误导。

**资源生命周期是第二梯队**：限流器（`LeakingBucket` / `SlidingWindow`）的定时器回调在空载时会阻塞在队列入队/出队上永不返回，`close()` 只 `cancel` 后续调度，线程与队列都无法回收；`atExit(timer.cancel)` 又把每个实例永久钉在进程退出回调表上，`close()` 也摘不掉。按连接/租户动态建限流器时会线性泄漏。修法明确（非阻塞回调 + `closed` 位 + 去掉 `atExit`），但要配套「close 后线程退出」的用例——现有 `RateLimiterClose_test` 恰恰没覆盖这一点。

**死代码与重复实现集中在扩展类与测试**：`isReachable`、`ConcDictView`、`Executor.result`、`maxQueueSize`、`JobQueue` 的两个 import、`imports.cj` 的 `Process` 已被编译器 `-Wunused` 直接点名（`imports.cj` 因 `internal import` 不在告警范围内，只能人工核对），清理成本极低，建议顺手做掉。真正需要谨慎的只有两处：`Atomic*` 的 8×9 逐类型展开（不建议泛型化，但要在文件头声明「改一处要同步 8 处」）、6 个异常类的 4 构造器（仓颉构造函数不继承，属语言约束，只能靠注释与改动清单兜底）。

**测试面**：并发容器的用例数量不少（跳表 25 个并发用例），但无效断言与测不到的路径同样多——`@Assert(true)`、`@Assert(map.size == 0 || map.size > 0)`、`result.store(1)` 不累加、`perf_test` 只 `println` 单次耗时且 `-O0` 运行；`LoadBalance_test` 全单线程，恰好漏掉了本模块最严重的 `RoundRobin` 竞态；`RateLimiterClose_test` 用 `sleep` 与定时周期强耦合，且自身会留下阻塞线程。建议在修严重项的同时补三条用例：并发 `next()` 区间断言、`shutdown`/`close` 后线程数归零、限流拒绝时 `get` 立即返回默认值。

**性能**：本轮没有新的热点结论——`scope.md` 未提供任何 profile / bench 数据，优化方案 5 条（CPU 3 / 堆内存 2）全部 `无基线`，只作下一轮补数据与 `cjprof` 验证的候选，不进修复清单。已识别的线索（`notifyAll` 唤醒风暴、跳表删除 O(log²n)、`EventBus` 每事件 2 次全局锁、每请求迭代器 + `SecureRandom`、限流器空闲线程数）已整理为 7 条待验证假设，各自写明缺哪种数据与怎么采。

**存量共 45 条（严重 8、一般 24、轻微 13），是否纳入修复待用户决定。**
