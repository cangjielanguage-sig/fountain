# f_concurrent 模块审查报告（模块第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_concurrent`（本部分 18 个源文件 + 1 个测试文件，模块合计 34 个 `.cj` + 3 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；全部问题来源 = 存量）
- **审查重点**：并发原语与同步语义正确性、死锁 / 活锁、可见性、大粒度锁、栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分报告，由主 Agent 与 `f_concurrent.part1.md` 合并；不写 `docs/review/`）
- **本部分覆盖**：`LoadBalance` / `RateLimiter` / `SlidingWindowRateLimiter` / `TokenBucketRateLimiter` / `SyncPriorityQueue` / `eventbus/*` / `exception/*` / `imports.cj`

## 发现

### [严重][存量] #1 `EventBus` 的 `notified` 一旦置真永不复位 —— 首次投递之后 `arrangeAndGet` 不再等待，直接返回 `None`

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:288`、`:315`、`:321`、`:343`
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02，快照模式无基线）
- **判据**：review-checklist §12.1（可见性 / 条件等待语义）、§11（契约与实现不符）
- **证据**：静态确定 —— `notified` 只在 `deliver()`（:343）`store(true)`，全文件无任何 `store(false)`；`get()` 的两处分支 `else if (notified.load()) { None<T> }`（:315、:321）把它当"永久已通知"用
- **描述**：`arrangeAndGet` 的契约是"安排任务并在 timeout 时间内等待执行结果"（:289-293）。第一次任何事件投递后 `notified` 恒为 `true`，此后每次调用只要 `datas.remove(threadId)` 没命中（任务还在跑），就立刻返回 `None<T>`，既不进 `synchronized(monitor)` 也不 `condition.wait`。即：`arrangeAndGet` 在进程生命周期内只有"第一个"调用可能真正阻塞，其余全部退化成非阻塞轮询一次，异步流程的调用方拿不到结果也不会超时。该文件是"条件等待"最典型的错误形态：用全局标志代替每请求的完成状态。
- **建议**：删除 `notified`，把完成状态做成 `datas` 的存在性（每线程 / 每请求一个 `Waiter` 对象 + `Condition`，或改成 `Future`/`SyncCounter`）；`wait` 放在 `while (datas.get(id).isNone())` 的循环里以免虚假唤醒。若确实需要"总线已关闭"的语义，另设 `retired` 标志，不要与"有结果了"共用一个原子量。

### [严重][存量] #2 `arrangeAndGet` 的结果表以「线程 id」为键、超时残留不清理 —— 同线程多请求互相串结果，且 map 无界增长

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:287`（`datas` 声明）、`:311`（`threadId`）、`:313`/`:319`/`:325`（三处 `remove`）、`:328`（超时抛异常，不清理）、`:342`（`datas.add`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（共享可变状态 / 检查-然后-写入）、§5（无界容器 + 缓存键无界）
- **证据**：静态确定（`ConcurrentHashMap.add` 对已存在 key 是"替换旧值并返回旧值"，见 `std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md`「func add(K, V)」；`remove(K): ?V` 语义同处「func remove(K)」）+ 需实测（生产上同线程并发 `arrangeAndGet` 的比例）
- **描述**：三处键冲突：
  1. 同一线程若先后发起两个 `arrangeAndGet`（例如一个任务内部又 `arrangeAndGet` 同一总线，或 `CurrentThread`/`New` 策略下任务在调用线程同步执行后再嵌套），两次结果都以同一 `threadId` 为键 → 后到的 `add` 覆盖先到的，先到的调用方只能等到超时。
  2. 超时路径（:328 抛 `EventBusException`）不删除 `datas[threadId]`；任务稍后完成仍会写回，这个残留值会被同一线程**下一次** `arrangeAndGet` 的 `remove` 取走 ⇒ 返回上一次事件的数据（数据错配）。
  3. 残留条目没有任何淘汰，`datas` 随超时次数单调增长（`mem §5.2` 无界容器）。
- **建议**：按请求而不是按线程发号（`requestId = 原子自增`），结果表键改成 `requestId`，`arrange` 前把 id 写进 `Event`；`finally` 里 `datas.remove(requestId)` 保证超时也清理；或直接用 `Future` 语义（每请求一个 `SyncCounter`/`Condition`），彻底去掉全局表。

### [严重][存量] #3 `RoundRobin.next()` 的回绕判定在锁外 —— 并发下返回超过 `max` 的取值，`LoadBalance.call` 抛 `NoneValueException`

- **位置**：`f_concurrent/src/LoadBalance.cj:35-49`（回绕在 `:41-47`，第一次 `current += step` 在 `:37-40` 锁内）；抛点 `f_concurrent/src/LoadBalance.cj:88-90`
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（检查-然后-写入非原子）、§6.2（锁用错导致正确性问题）、§11（并发正确性）
- **证据**：静态确定 —— 可复现的交错序列：线程 A 在 `:37-40` 取 `v=max` 并把 `current` 自增到 `max+step` 后放锁；线程 B 在 A 执行 `:41-47` 的回绕前进入 `:37-40`，读到的 `v` 就是 `max+step`（已越界），随后 B 也放锁；A 才把 `current` 复位成 `min`。B 的 `v` 永远回不来。`TreeMap.forward(mark, inclusive: true)` 的定义是"第一个键 ≥ mark"，mark 超过所有键时返回空迭代器（`std/collection/collection_package_api/collection_package_class.md`「func forward(K, Bool)」），于是 `forward(...).next()` 为 `None`，`:89` 的 `getOrThrow()` 抛 `NoneValueException`
- **描述**：这是双重检查写错了位置——"自增"和"回绕"必须在同一个临界区里完成。后果是 `LoadBalance.call(data)` 抛 `NoneValueException`（不是 `LoadBalanceException`），且调用方 `fdbm/src/resources/DatabaseResources.cj:186` 的 `borrow()` 只 `catch (e: ConnectionException)`，异常会冒泡成 `INTERNAL`。该路径在 fdbm 里是**每个数据库读写请求**都会走的（`selectRead`/`selectWrite` → `borrow` → `balance.call(())`），并发度≈业务线程数，不是冷路径。
- **建议**：
  ```cangjie
  synchronized(mutex) { v = current; current += step; if (current > max) { current = min } }
  ```
  另外 `call(data)` 应对"空/越界"给出 `LoadBalanceException`，而不是让 `NoneValueException` 漏出去（见 #9）。

### [严重][存量] #4 `Worker` 的消费循环没有异常隔离 —— 任一 ability 抛异常（含"事件未注册"的 `NoneValueException`）都会让该 worker 永久停摆

- **位置**：`f_concurrent/src/eventbus/Worker.cj:40-60`（裸 `spawn` + `:49` 的 `this.abilities[e](e)`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（异步语义 / 线程池堆积）、§3（静默失效）、§11
- **证据**：静态确定 —— `spawn` 块内没有任何 `try/catch`；`abilities` 是 `ConcurrentHashMap<Event, (Event) -> Event>`，下标读在键不存在时抛 `NoneValueException`（`collection_concurrent_class.md`「operator func \[](K)」），而 ability 本身是**用户代码**，任何异常都沿 `:49` 逃出循环
- **描述**：worker 线程一旦被异常终止，它自己的 `queue` 再也不会有消费者：`arrange` 继续把事件塞进这个队列直到满，`arrangeAndGet` 的调用方只能等到超时（叠加 #1 就连超时都不会等）。未注册事件是最容易触发的入口（`EventBus.register` 只对"注册时刻已存在的 ability 集合"生效，用户漏注册一个事件不会在 `arrange` 时报错，而是在 worker 里炸）。
- **建议**：`while` 体内整体 `try { ... } catch (e: Exception) { log + 走错误投递/丢弃策略 }`，保证循环体不会因单条事件退出；`abilities` 读取改成 `abilities.get(e)` + `None` 时明确抛 `EventBusException("event ${e.name} not registered")` 并记日志；worker 线程退出前把 `retired` 置真并 `notify` 等待方。

### [一般][存量] #5 `SlidingWindowRateLimiter` 不是「滑动窗口计数」：`limit` 实际只是「在途任务上限」，窗口内可放行 `limit+1` 个

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:22`（`queue` 容量 = `limit`）、`:30-47`（构造 + 定时器）、`:48-67`（`exec`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §11（语义与命名 / 注释不符、契约与实现不符）
- **证据**：静态确定 —— 代码里没有任何"窗口内已放行计数"或"时间戳集合"，`window` 只出现在 `:43` 计算下一次消费延迟；`queue` 的唯一作用是给并发排队数封顶
- **描述**：构造时定时器立刻阻塞在 `queue.remove()`（`remove()` 无参版本是**阻塞**出队，`collection_concurrent_class.md`「func remove()」），所以第 1 个任务入队即被立刻取走、不占容量；之后 `window` 内还能再入队 `limit` 个 ⇒ 单个窗口最多放行 `limit+1`。同时 `README.md` / 类注释（`:28`）承诺的是"时间窗口内最大任务数"。真实语义是「未消费任务数 ≤ limit 的并发闸门 + 任务超窗告警」，与名字和文档都不一致；按限流器使用时会出现稳定超发。
- **建议**：要么把语义改成真正的滑动窗口（存 `MonoTime` 环形缓冲或分段计数，按 `now - window` 淘汰后判 `count >= limit`），要么把类改名为并发闸门并在文档里写清"`limit` = 在途任务上限、`window` = 超时告警阈值"。

### [一般][存量] #6 `SlidingWindowRateLimiter.close()` 停不掉已经阻塞在 `queue.remove()` 的定时任务线程 —— 每个实例泄漏一个常驻线程

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:41`（回调内 `queue.remove()`）、`:69-74`（`close`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（资源 / 跨线程资源）、§11（资源不对称）
- **证据**：静态确定 —— `Timer.cancel()` 只让定时器停止调度，不中断正在执行的任务（`std/sync/sync_package_api/sync_package_classes.md`「class Timer」注意事项："只有关联 Task 执行完毕，或使用 cancel 接口主动取消 Timer，Timer 的生命周期才会结束"；`cancel` 不存在中断语义），而 `queue.remove()` 在队列空时**永久阻塞**
- **描述**：`close()` 只是 `t.cancel()`。若关闭时队列为空（最常见：空闲期关闭），回调线程仍挂在 `remove()` 上，直到下一个任务入队才返回；定时器对象也因此无法被回收。从池里按 key 创建限流器、定期淘汰的用法下，线程数随淘汰次数单调增长。现有用例 `RateLimiterClose_test.cj:69-77` 恰好是"空闲期 close"，只断言了不抛异常，覆盖不到这一点。
- **建议**：`close()` 里先放入一个哨兵元素（`queue.tryAdd(SENTINEL)`）唤醒回调再 `cancel`，回调判哨兵后返回 `None<Duration>` 退出；或改用 `queue.remove(timeout)` + `closed` 标志轮询，使关闭有确定性出口。

### [一般][存量] #7 `EventBus.retireAll()` 停不掉线程：空闲 worker 阻塞在 `queue.remove()`，`seize` 线程没有退出条件

- **位置**：`f_concurrent/src/eventbus/Worker.cj:41-47`、`f_concurrent/src/eventbus/EventBus.cj:63-93`、`:197-201`
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（有界性 / 资源）、§11
- **证据**：静态确定 —— `retire()` 只 `retired.store(true)`；`while (!retired.load() || queue.size > 0)` 只有在 `queue.remove()` 返回后才会重新求值，而空队列的 `remove()` 永久阻塞；`seize()` 的 `while (true) { seizeQueue.remove() ... }` 没有任何退出分支
- **描述**：`retireAll()` 之后，空闲 worker 线程与那条 `seize` 线程都还在，且 `seize` 闭包强引用 `this`（EventBus）⇒ 整个 EventBus 实例（含 workers 数组、abilities、`datas`）无法被 GC。与 #5 的 `Executor.shutdown()` 是同一类"标志位 ≠ 唤醒"的错误。
- **建议**：`retire()` 里 `queue.tryAdd(END_SENTINEL)` 唤醒阻塞的 `remove`，worker 看到哨兵就退出；`EventBus` 增加 `closed` 标志 + 在 `retireAll` 里 `seizeQueue.tryAdd(-1)` 让 `seize` 线程退出。

### [一般][存量] #8 唯一的 `seize` 线程里调用阻塞的 `arrange` —— 一次满队列就能让全局窃取停摆

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:84-90`（`:88` `this.workers[sizedBy].arrange(e)`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（锁内 / 单线程内阻塞调用导致的活锁）、§6.3（单消费者串行段）
- **证据**：静态确定 —— `Worker.arrange` → `JobQueue.add` → `LinkedBlockingQueue.add(element)` 是"队列满则阻塞"（`collection_concurrent_class.md`「func add(E)」）；整个总线只有这一条 `seize` 线程（`EventBus.cj:64`），阻塞期间没有任何其它线程会替它继续窃取
- **描述**：窃取线程已经把事件从"最长队列"里 `tryRemove` 出来了，此时 `sizedBy` 的队列若恰好被其它生产者填满，`add` 就无限期阻塞 —— 事件被卡在窃取线程手里，最长队列与目标队列都不再变化，负载再均衡整体失效（表现为各 worker 队列持续不均、`arrange` 的 `Block` 策略更容易卡死）。
- **建议**：改成 `tryArrange(sizedBy, e, timeout: Duration.Zero)`，失败就把事件放回原队列（或改投随机可用 worker）并继续循环，绝不在窃取线程里做无界等待。

### [一般][存量] #9 `Worker.force` 把事件入队后无条件 `deliverIfNeed` —— 交付的是**中间事件**的结果，且派生事件没继承 `arrangedThreadId`/`deliverResult`

- **位置**：`f_concurrent/src/eventbus/Worker.cj:82-96`（`:95` `deliverIfNeed(ee)`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §11（逻辑错误 / 语义与注释不符）、§12.1（异步语义）
- **证据**：静态确定 —— `arrangeAndGet` 的注释（`EventBus.cj:292`）明确"整个任务流程必须以返回 EndEvent 实例为任务终点"，但 `force` 在 `tryAdd` 成功后无论 `ee` 是否为 `EndEvent` 都调用 `deliverIfNeed`；`:89` 由 `abilities[ee](ee)` 生成的新事件既没有 `ee.deliverResult = e.deliverResult` 也没有 `ee.arrangedThreadId = e.arrangedThreadId`（对比 `:50-52` 的正常消费路径有这两行拷贝），`Event` 的默认值是 `deliverResult = true`、`arrangedThreadId = 0`（`Event.cj:28-30`）
- **描述**：两个后果：(a) `CurrentThread` / `New` 策略且目标队列满时，调用方会在流程还没跑完时拿到中间事件的数据；(b) 由 ability 派生出的中间事件被投递到 `datas[0]`，污染结果表并把 #1 的 `notified` 置真（连锁触发"此后不再等待"）。
- **建议**：`:95` 改为只在 `ee is EndEvent` 时投递；`force` 里派生事件后补上与 `:50-52` 相同的三个字段拷贝；更好的做法是把 `force` 的循环体抽成与消费循环共用的 `step(e)` 函数，避免两处语义漂移。

### [一般][存量] #10 `LoadBalance.call` 的失败语义不统一：空表抛 `NoneValueException`，重试版空表返回 `(None, None)`

- **位置**：`f_concurrent/src/LoadBalance.cj:88-90`、`:91-113`（`:112` `(None<R>, ex)` 且 `ex` 为 `None`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §11（错误处理缺失 / 契约不符）、§10（`Option` 语义）
- **证据**：静态确定 —— 空 `TreeMap` 上 `forward(...).next()` 为 `None`（`collection_package_class.md`「func forward(K, Bool)」），`:89` 直接 `getOrThrow()`；`:94` 的 `for(f in iterator())` 在空表时不进循环，`:112` 用 `ex`（此时仍是 `None`）当异常返回
- **描述**：`call(data)` 的空表失败以 `NoneValueException` 形式出现（`README.md:79` 承诺的是按算法取一个节点执行），调用方按 `LoadBalanceException` 捕获会漏；`call(data, maxRetrying)` 在没有节点时返回 `(None, None)`，"没有返回值"和"没有异常"两种信息挤在同一个位置上，调用方无法区分"空表"与"任务返回 None"。
- **建议**：空表在 `add` 时就应可判定，`call` 入口显式 `if (tree.isEmpty()) { throw LoadBalanceException("no node registered") }`；重试版返回类型改成 `Result` 或让第二项在空表时一定是 `Some(LoadBalanceException)`。

### [一般][存量] #11 `arrangeAndGet` 把 `?Any` 存进 `ConcurrentHashMap<Int64, Any>`，`convert` 的类型判定打在包装层上

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:335-339`（`deliver(event.arrangedThreadId, event.getData<Any>())`）、`:340-346`、`:297-310`（`convert`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §11（类型使用 / 契约不符）
- **证据**：待确认 —— `getData<Any>()` 返回 `?Any`，`deliver` 的形参也是 `?Any`，最终 `datas.add(key, value: Any)` 存入的是 `Option<Any>` 这个值；`convert` 里 `case x: T` 判的是取出值的运行时类型。若取出值是包装后的 `Option`（而非业务载荷），则 `arrangeAndGet<String>` 永远匹配不到 `String`，只会返回 `None` 或（`toThrowIfNotMatch = true` 时）抛 "data in current Event does not match."。仓内 `arrangeAndGet` 零调用（全仓 grep 仅定义处），没有用例能证伪
- **描述**：需要一次端到端用例确认（注册 `EndEvent` 前 `setData("x")`，`arrangeAndGet<String>` 是否返回 `Some("x")`）。若确为双层包装，说明这条 API 从未真正跑通，`toThrowIfNotMatch` 的默认 `false` 把问题掩盖成了"返回 None"。
- **建议**：`datas` 的值类型改成 `?Any`（或在 `deliver` 里 `getData<Any>()` 之后按 `Some/None` 分别处理），`convert` 只对业务载荷做 `as T`；补一个 `arrangeAndGet` 的成功用例与超时用例。

### [轻微][存量] #12 `Mono.time` 用无让出的自旋等待，且 `exec` 是「先入队、后赋值」

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:57-58`（`queue.add` 后 `mono.time = ...`）、`:81-89`（`while (_time.load().isNone()) {}`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（可见性 / 忙等）、§6.1（需数据）
- **证据**：静态确定（存在无 `yield`/`sleep` 的纯自旋，且在赋值前对象已对消费线程可见）；自旋实际时长需实测
- **描述**：`queue.add` 一返回，阻塞在 `remove()` 的定时任务就可能拿到 `mono` 并读 `time`，此时 `exec` 还没执行赋值 ⇒ 消费线程空转占满一个核直到生产者被调度。正确顺序是先 `mono.time = MonoTime.now()` 再入队；getter 里也不该自旋（应改为"入队前赋值"后直接 `getOrThrow`）。
- **建议**：把 `:57-58` 两行交换；getter 去掉 `while`，用 `_time.load() ?? MonoTime.now()` 之类的兜底，或把 `time` 改成构造参数（`Mono(time)`），彻底去掉可变可见性依赖。

### [轻微][存量] #13 `unfinishedTasks` 只写不读 —— 死字段

- **位置**：`f_concurrent/src/SlidingWindowRateLimiter.cj:24`、`:39`
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §1（读了不用 / 非 public 符号无消费者）
- **证据**：静态确定 —— 全仓搜 `unfinishedTasks` 仅两处：定义与 `fetchAdd(1)`（已排除 `.worktrees`、`target`）；`private let` 无任何读取
- **描述**：这个计数器显然想统计"超时未完成任务数"，但只作为日志里的序号打印，既不是计数也不对外暴露；日志文案 "`${n} tasks are timeout`" 因此每次打印的都是自增序号，语义错误。
- **建议**：要么删掉计数器、日志改成"task timeout"；要么真的维护计数（`fetchAdd` 前先判 `finished`，并提供 `public prop timeoutCount` 供观测）。

### [轻微][存量] #14 `EventBus` 构造参数无边界校验 —— 非法值以 std 的 `IllegalArgumentException` 逃出

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:48-62`（`:56` `LinkedBlockingQueue<Int64>(workers)`、`:57` `Array<Worker>(workers)`）、`:58` → `JobQueue.cj:31`
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §11（边界 / 契约）、§10（错误处理）
- **证据**：静态确定 —— `LinkedBlockingQueue(capacity)` 在 `capacity <= 0` 时抛 `IllegalArgumentException`（`collection_concurrent_class.md`「init(Int64)」示例明确 `Invalid size of BlockingQueue: 0.`）；`workers = 0`、`maxWaitingJobPerWorker <= 0` 都无人校验
- **描述**：误配 `workers = 0` 或 `maxWaitingJobPerWorker = 0` 时，用户看到的是 std 的异常文案，与本模块统一的 `EventBusException` 不一致；且 `workers = 0` 时 `nextInt64(0)` 也会在后续路径上出问题。
- **建议**：构造入口校验 `workers > 0 && maxWaitingJobPerWorker > 0`，违反时抛 `EventBusException`。

### [轻微][存量] #15 `discardOldestDuringStrategy` 用墙钟 `DateTime.now()` 计超时

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:172`、`:174`
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §11（语义与命名不符）、§10
- **证据**：静态确定 —— 同文件其它耗时判定（`SlidingWindowRateLimiter` / `TokenBucketRateLimiter`）都用 `MonoTime`，只有这里用 `DateTime.now()`
- **描述**：`DateTime` 是墙钟，NTP 校时或手工改时间会让 `DateTime.now() - start` 变成负数或大幅跳变：回拨时 `while` 持续 `discard(id)`（丢光队列）直到墙钟追上，前跳时会提前走 `setNoneData` 分支。
- **建议**：改 `MonoTime.now()`（单调时钟）。

### [轻微][存量] #16 六份「满队列策略」闭包骨架重复 —— 新增策略时极易漏改某个分支

- **位置**：`f_concurrent/src/eventbus/EventBus.cj:106-116`（Abort）、`:118-128`（DiscardCurrent）、`:129-138`（DiscardOldest）、`:139-150`（AbortAfter）、`:151-164`（DiscardCurrentAfter）、`:165-184`（DiscardOldestDuring）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §2（换控制流 / 近似重复且差异未参数化）
- **证据**：静态确定 —— 六者共享同一骨架「`if (e is EndEvent) { deliverIfNeed; false }` → `tryArrange || tryArrangeOther` → 失败分支」；`discardCurrent`（:118）与 `discardCurrentAfterStrategy`（:151）的差异只有多一次 `tryArrange(timeout: d)`，且前者失败分支**没有** `setNoneData()`（后者有），是典型的"复制后少改一行"
- **描述**：`DiscardCurrent` 丢弃时保留原 `data`，`DiscardCurrentAfter` 丢弃时清空 `data`，两者对调用方拿到的结果不同；这种差异没有任何注释说明是有意为之。合并前需先确认该差异。
- **建议**：抽一个 `tryArrangeOrElse(id, e, timeout, onFail)` 骨架，把"是否 `setNoneData`/是否抛异常/是否丢最旧"作为参数；差异点加注释。

### [轻微][存量] #17 `RoundRobin` 是 `struct` 却含可变游标 + 共享 `Mutex` —— 值拷贝会分裂状态

- **位置**：`f_concurrent/src/LoadBalance.cj:29-50`（`:30` `private let mutex = Mutex()`、`:31` `private var current`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §10（值 / 引用语义）、§12.1（锁对象误用）
- **证据**：静态确定 —— `Mutex` 是 class（`sync_package_classes.md`「class Mutex」），`struct` 拷贝按字段复制：`mutex` 复制的是引用、`current` 复制的是值
- **描述**：把同一个 `RoundRobin` 实例喂给两个 `LoadBalance`（每次都发生一次 struct → 接口装箱）后，两个游标各自独立却共用同一把锁：锁不再保护"同一个游标"的不变量（保护对象与状态已分离），且两次 `next()` 相互串行。当前仓内调用方（`fdbm`）只装箱一次，尚未触发。
- **建议**：改成 `class`（游标是可变的、需要共享身份），或把游标做成 `AtomicInt64` 并把"自增 + 回绕"用 CAS 循环完成（同时解决 #3）。

### [轻微][存量] #18 `LoadBalance` 未声明线程安全边界，`add` 与 `call`/`iterator` 并发时无任何保护

- **位置**：`f_concurrent/src/LoadBalance.cj:76-77`（`tree`）、`:78-87`（`add`）、`:88-90`（`call`）、`:114-124`（`iterator`）
- **来源**：存量（`git blame` → `4be871f2f` 2026-10-02）
- **判据**：review-checklist §12.1（共享可变状态无保护）
- **证据**：静态确定（无锁、无原子、无不可变发布）；是否有运行期 `add` 需确认
- **描述**：`tree` 是普通 `TreeMap`，`RoundRobin` 有锁但 `tree` 没有。若"构造期 `add`、运行期只 `call`"是唯一用法，则并发读是安全的——但类注释与 README 都没写这条约束，下游很容易在运行期 `add` 一个节点，届时与 `call` 的 `forward` 并发读写会让 `TreeMap` 内部结构失效（不是数据陈旧，而是迭代器/树结构被破坏）。
- **建议**：类注释与 README 明确"构造完成后不可变，运行期 `add` 不安全"；或 `add` 走 copy-on-write（新建 `TreeMap` + 原子替换引用），使运行期扩容也安全。

## 优化可行性方案

### [CPU] `EventBus.arrange` 的全局 `mutex` 里做 `SecureRandom` 选取

- **现状**：`EventBus.cj:219-237` 每次 `arrange` 都要进全局 `mutex`；临界区里 `ThreadLocal.get()`（首次未命中时还要 `SecureRandom()` 构造，`SecureRandom` 首次使用要取熵）再 `nextInt64(workers.size)`。`arrange` 是事件总线的唯一投递入口，调用频率 = 业务事件频率
- **方案**：worker 选取不需要跨线程不变量 —— 换成 `AtomicInt64` 自增取模（轮询），或 `ThreadLocal<SecureRandom>` 在锁外取随机数后再做一次"若 `workerId < 0` 则 CAS 写入 `Event.workerId`"；`SecureRandom` 换 `std.random.Random`（worker 分配不需要密码学强度）
- **预期**：无法量化（缺基线）；可预期的是去掉每事件的全局串行点
- **代价**：分配从"随机"变"轮询"时负载分布更均匀但可预测；若业务依赖随机打散需保留可配置
- **验证**：`cjprof` 火焰图看 `EventBus.arrange` 的 self + wait 占比；线程状态统计 BLOCKED 时间；`cjpm bench -O2` 对照 10k/100k 事件投递
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `Event` 每步携带 4 个原子对象 + 全局 `ordinal`

- **现状**：每个 `Event` 实例固定持有 `AtomicReference<Box<?Any>>`（`Event.cj:27`）、`AtomicInt64` ×2（`:28-29`）、`AtomicBool`（`:30`），外加 `ordinal`（`:25`，`AtomicUInt64` 全局自增）。事件总线里**每一步**都会 `abilities[e](e)` 产出新 `Event`，一条 N 步流程 = N 个事件对象 + 4N 个原子对象 + N 次 `Box` 分配
- **方案**：`ordinal` 全仓零引用（见文件覆盖说明），可删；`arrangedThreadId`/`workerId`/`deliverResult` 只在 `arrange` 时写一次、消费线程读一次，可用普通字段 + `arrange` 前的 happens-before（入队即发布）替代原子；`data` 的 `Box<?Any>` 可改成普通 `?Any` 字段（`setData`/`getData` 之间已有队列/条件变量做同步）
- **预期**：每事件对象数从 1+4 降到 1，堆分配与 GC 压力按流程步数线性下降
- **代价**：去掉原子后必须保证"写字段 → 入队"的顺序（当前代码已经是这个顺序），否则会引入可见性问题；需要并发用例守护
- **验证**：`getAllocatedHeapSize()` 在 100k 事件、5 步流程下的分配量对照；RSS 稳态
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `EventBus.arrange` 的全局 `mutex` 是投递瓶颈（含 `SecureRandom` 首次取熵） | `f_concurrent/src/eventbus/EventBus.cj:219` | 锁等待占比、BLOCKED 线程数 | 多线程压 10k 事件/秒，采线程状态 + `cjprof` |
| 2 | `SlidingWindowRateLimiter` 的 `Mono.time` 自旋会吃掉一个核 | `f_concurrent/src/SlidingWindowRateLimiter.cj:83` | 自旋轮次 / CPU 时间 | 高频 `exec` 下 `cjprof` 看该函数 self time；统计自旋退出耗时 |
| 3 | `Worker.force` 的"满队列时在调用线程跑 ability"会让请求延迟长尾化 | `f_concurrent/src/eventbus/Worker.cj:88` | P95/P99 延迟、`force` 触发次数 | 把 `maxWaitingJobPerWorker` 调到 1 压测，埋点统计 `force` 调用与耗时 |
| 4 | `Event` 的 4 个原子字段占事件分配量的显著比例 | `f_concurrent/src/eventbus/Event.cj:27-30` | 单事件字节数、GC 次数 | `getAllocatedHeapSize()` 前后对照（含 `-O2`） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_concurrent/src/LoadBalance.cj` | .cj | ✅ | 见 #3 / #10 / #17 / #18 |
| 2 | `f_concurrent/src/LoadBalance_test.cj` | .cj | ✅ | 6 个用例，覆盖轮询/随机分布；并发路径无用例（见 #3） |
| 3 | `f_concurrent/src/RateLimiter.cj` | .cj | ✅ | 基类 + `close()` 默认空实现（有注释说明，非空实现缺陷） |
| 4 | `f_concurrent/src/RateLimiterClose_test.cj` | .cj | ✅ | `testSlidingWindowCloseIsIdempotent` 覆盖不到"空闲期 close 泄漏线程"（见 #6） |
| 5 | `f_concurrent/src/SlidingWindowRateLimiter.cj` | .cj | ✅ | 见 #5 / #6 / #12 / #13 |
| 6 | `f_concurrent/src/SyncPriorityQueue.cj` | .cj | ✅ | 锁覆盖全部读写入口，未发现缺陷 |
| 7 | `f_concurrent/src/TokenBucketRateLimiter.cj` | .cj | ✅ | 定时器回调不阻塞、`close` 有效；见 #5 对照 |
| 8 | `f_concurrent/src/eventbus/EndEvent.cj` | .cj | ✅ | `name` 常量，无缺陷 |
| 9 | `f_concurrent/src/eventbus/Event.cj` | .cj | ✅ | `ordinal` 全仓零引用（对外可达，不判死代码）；`==`/`hashCode` 均基于 `name`，自洽 |
| 10 | `f_concurrent/src/eventbus/EventBus.cj` | .cj | ✅ | 见 #1 / #2 / #7 / #8 / #9 / #11 / #14 / #15 / #16 |
| 11 | `f_concurrent/src/eventbus/JobQueue.cj` | .cj | ✅ | 薄封装；`add`/`remove` 的阻塞语义见 #4 / #7 / #8 |
| 12 | `f_concurrent/src/eventbus/Worker.cj` | .cj | ✅ | 见 #4 / #7 / #9 |
| 13 | `f_concurrent/src/eventbus/exception/EventBusException.cj` | .cj | ✅ | 4 个构造器，与其它异常类同形（§2 不判重复，契约类型） |
| 14 | `f_concurrent/src/exception/ConcurrentException.cj` | .cj | ✅ | 同上 |
| 15 | `f_concurrent/src/exception/LoadBalanceException.cj` | .cj | ✅ | 同上；仓内仅 `LoadBalance.call(_, maxRetrying)` 内部使用 |
| 16 | `f_concurrent/src/exception/RateLimiterException.cj` | .cj | ✅ | 同上；构造参数校验处使用 |
| 17 | `f_concurrent/src/exception/ReadWriteSyncerException.cj` | .cj | ✅ | 本部分无 `ReadWriteSyncer` 实现（在别处）；异常类对外可达，不判死代码 |
| 18 | `f_concurrent/src/exception/TimeoutException.cj` | .cj | ✅ | 同上；`f_cache` / `f_pool` / `fprobe` 有 `catch` 使用 |
| 19 | `f_concurrent/src/imports.cj` | .cj | ✅ | 包级 `internal import` 汇总；`Set`/`ReadOnlySet`/`MapEntryView`/`Process`/`TypeInfo` 的使用方在第 1 部分文件中，本部分无法判死 import |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | #1 #2 #3 #4 #5 #9 #10 #11 #17；无外部输入解析、无敏感数据、无凭据 |
| §1 死代码 | 1 | `unfinishedTasks` 只写不读（#13）。逐个核对：`private` 符号（`LoadBalanceIterator`、`Mono`、`EventBus.datas/notified/maxQueueSize/seizeQueue/doArrange`、`Worker.queue/abilities/eventBus`、`JobQueue.max`）均有读取方；`internal` 符号（`putQueueSize`/`seizeBy`/`deliver`/`deliverIfNeed`/`Worker.register/force/arrange/tryArrange/tryRemove/discard`）均有调用方；`protected` 仅 `RandomWeight.random`（`public abstract class` 成员，豁免）；对外可达 `public`（`Event.ordinal`、`Event.startEvent`、`EventBus.*`、`SyncPriorityQueue*`）零引用也不判，仅记信息。可见性建议 1 条：`RateLimiterClose_test.cj:22` 的 `CountingRateLimiter` 是 `internal` 类且只被测试引用，可考虑收窄（不算死代码） |
| §2 重复逻辑 | 1 | #16（六份满队列策略骨架重复）。另逐行比对：6 个异常类仅类名不同（对外异常类型契约，合并会破坏 `catch` 语义，不判重复）；`LoadBalance.add(weight)` 与 `add(all!)` 关系是前者被后者复用，不重复；`TokenBucketRateLimiter` 与 `SlidingWindowRateLimiter` 的 `close()` 同形但在不同类，且语义（能否停掉回调）不同 |
| §3 空实现 | 0 | `RateLimiter.close()` 是空实现，但注释 + 文档都写明"默认空实现，定时器型必须覆盖"，属有意 Null Object；`UnlimitedRateLimiter` 无资源可释放故不覆盖，合理；未见 `TODO`/`catch {}` |
| §4 栈溢出 | 0 | 两处自递归均有一层守卫且深度恒定：`LoadBalanceIterator.next()`（`endsub` 置真后不再递归）、`EventBus.get()`（`toWaitIfNeed=false` 后不再递归）。无用户可控深度的递归 |
| §5 OOM | 1 | `EventBus.datas` 无界增长（并入 #2）。`seizeQueue` 容量 = `workers` 有界；`JobQueue`/`SlidingWindow.queue` 有界；`TokenBucket.tokens` 有界 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，`doc/performance_report.md` 不含事件总线与限流器数据；热点结论不成立，已转「待验证假设」1-4 |
| §6.2 大粒度锁 | 1 | `EventBus.arrange` 的全局 `mutex` 内含 `SecureRandom` 选取（优化方案 1）。`SyncPriorityQueue` 的锁只保护 `PriorityQueue` 单次操作，临界区无 I/O / 回调 |
| §6.3 并发串行 | 0 | `Block` 策略让生产者阻塞是设计选择（`fullJobQueueStrategy` 可配），不判；本部分未发现 `spawn` 后立即 `get()` 的形态 |
| §6.4 低效算法 | 0 | `tryArrangeOther` 是 O(workers) 线性扫描（workers = 核数，量级小）；`seize` 的扫描同样是 O(workers)；未发现 `remove(at: 0)`、热点 `contains`、循环内字符串拼接 |
| §7 降堆内存方案 | 1 | 见「[堆内存] `Event` 每步携带 4 个原子对象」；无基线 |
| §8 降 CPU 方案 | 1 | 见「[CPU] `EventBus.arrange` 的全局 `mutex` 里做 `SecureRandom` 选取」；无基线 |
| §9 local mode 可行性 | 0 | 热点临时对象（`Mono`、`Event`）都逃逸到队列 / 结果表，`@ local!` 不成立；唯一不逃逸的 `convert` 中间值规模可忽略，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 18 | 本报告全部 18 条均为存量（快照模式无基线） |
| §12 并发安全与锁粒度 | 6 | #1（可见性 / 条件等待）、#2（检查-然后-写入）、#3（非原子复合操作）、#4（异步语义）、#7（有界性 / 资源）、#8（单线程阻塞导致活锁）；另 #17 锁对象与状态分离、#18 共享可变状态无保护 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 public 类型/成员逐个对照了 README（`LoadBalance`/`RoundRobin`/`Int64Weight`/`Float64Weight`/`RateLimiter`/`Unlimited`/`SlidingWindow`/`TokenBucket`/`SyncPriorityQueue`/`EventBus`/`Event`/`EndEvent`/`Worker`/`JobQueue`/5 个异常类），README 均有条目；`ordinal`/`startEvent`/`setNoneData`/`close` 已列入「其他公开 API」 |
| 文件覆盖（§13 等） | 19/19 | 本部分 `.md` 为 0；模块 `README.md` / `README_en.md` / `doc/performance_report.md` 属第 1 部分 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 7 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分的风险高度集中在 `eventbus/`：`EventBus` + `Worker` 是"标志位当同步手段"的重灾区——`notified` 一次性置真（#1）、结果表按线程 id 且不清理（#2）、`retireAll` 停不掉线程（#7）、worker 无异常隔离（#4），四条叠加后 `arrangeAndGet` 这条 API 在运行期基本不可能按契约工作。好在全仓 `EventBus` 与 `arrangeAndGet` 均零调用（仅定义处），所以目前是"库里的哑弹"而不是线上故障；但它是 `public` 对外契约，下游一旦使用就会直接踩中。建议按 #1 → #4 → #2 → #7 的顺序修，四条都在同一处、可一次改完并补一个"多线程 `arrangeAndGet` + 超时 + `retireAll`"的用例。

`LoadBalance` 的 #3 是**唯一一条已在生产路径上**的严重并发缺陷：`RoundRobin.next()` 把回绕放在锁外，fdbm 每个读写请求都会走 `call()`，并发下会抛 `NoneValueException` 并冒泡成 `INTERNAL`。修法只有一行（把 `if (current > max)` 挪进临界区），应优先处理。`LoadBalance_test.cj` 全部是单线程用例，覆盖不到这个交错。

限流器三条（#5 / #6 / #12）属"能用但语义不对/资源不释放"：滑动窗口实际是并发闸门（#5）、`close` 泄漏回调线程（#6）、`Mono.time` 靠自旋同步（#12）。`TokenBucketRateLimiter` 与 `SyncPriorityQueue` 本轮未发现缺陷：前者的定时器回调不会阻塞、`close` 有效；后者的锁覆盖了全部读写入口。

`exception/` 六个类与 `imports.cj` 干净；六个异常类同形是契约需要，不建议合并。存量 18 条（严重 4 / 一般 7 / 轻微 7），是否纳入修复请用户决定；本轮不跑构建、不改源码。

## 范围外提示（不计入统计）

- 本部分 3 个限流器的 `Timer.after` 回调以**裸 `Duration`** 作为返回值（`SlidingWindowRateLimiter.cj:43`、`TokenBucketRateLimiter.cj:47`），而 1.3.0 std 文档的签名是 `after(delay: Duration, task: () -> Option<Duration>)`（`sync_package_classes.md`「static func after(Duration, ()->Option\<Duration>)」）。`f_ticktock` / `f_llm` / `f_log` 也是同样写法，推测实际构建用的 SDK 版本接受该写法；**需以实际构建 SDK 版本确认**，若确为类型不匹配则属编译期问题，不属本报告的运行期结论。
- `f_concurrent/README.md:97` 把 `RateLimiter` 写成 `abstract sealed class`，源码是 `public abstract class`——该文件属第 1 部分，已由 `f_concurrent.part1.md` 的 #14 记录，本报告不重复计数。
