# f_concurrent 模块审查报告（第 1/3 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_concurrent`（34 个源文件；本部分覆盖 15 个：`AnyMomentRateLimiter` / `AtomicInteger` / `ConcDict` / `ConcHashDict` / `ConcurrentHashSet` / `ConcurrentSkipListMap` 及其 4 个测试 / `Constants` / `DelayQueue` / `Executor` / `Executor_pool_test` / `LeakingBucketRateLimiter`）
- **基线**：工作区快照 `8c0ce643a`（`sts/1.3.x`，除 `docs/review/`、`reviews/` 外工作区干净，无 diff）⇒ 本部分全部缺陷记「存量」
- **审查重点**：并发容器正确性、锁粒度、死锁、可见性、限流器、执行器池、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part1`，最终由主 Agent 合并为 `docs/review/f_concurrent_review_20261128.md`）

## 发现

### [严重][存量] 任务抛异常时工作线程直接死亡，且对应 Future 永不完成 → 调用方永久阻塞、池逐步失能

- **位置**：`f_concurrent/src/Executor.cj:56-62`（worker 循环 `q.remove()()`，无 try/catch）、`f_concurrent/src/Executor.cj:66-72` / `:89-100`（闭包内 `future.complete(task())`，`task()` 先求值）、`f_concurrent/src/Executor.cj:110-116`（`complete` 只承载正常返回值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（异步语义：Future 异常被吞）、§3（静默吞异常）、§11（错误处理缺失）
- **证据**：静态确定 —— worker 的 `while(running.load()){ q.remove()() }` 没有任何捕获；闭包 `{=> future.complete(task()) }` 中 `task()` 抛异常时不会执行 `complete`，异常沿 `q.remove()()` 冒出并终止该 spawn 线程；`ExecutorFuture` 没有"失败"状态，`finished` 恒为 false。
- **描述**：任一业务任务抛异常即永久损失一个 worker；`Executors` 的 N 个 worker 全部死亡后，此后所有 `call(...).get()` 都永久阻塞（`f_net/src/server/server.cj:169` 在请求线程上 `get`，等于请求线程泄漏）。`ExecutorPoolTest` 只覆盖正常返回，无异常用例。
- **建议**：worker 循环改为 `try { handler() } catch (e) { /* 记录 + 让该 future 以失败完成 */ }` 且不退出循环；`ExecutorFuture` 增加 `exception: ?Exception`，`get()` 时重新抛出（或至少 `complete(None)` 并记日志），为"任务抛异常后池仍可用 / `get` 不挂起"补测试。

### [严重][存量] `call(limiter, …)` 被限流器拒绝时闭包不执行，Future 永不完成，`get()` 永久阻塞（f_net / f_rpc / f_rx 主路径）

- **位置**：`f_concurrent/src/Executor.cj:89-100`（`limiter.exec{ … q.tryAdd(…) … }`）、`f_concurrent/src/AnyMomentRateLimiter.cj:44-46`（`queue.add` 超时 → 直接 `return default`，不执行 task）、`f_concurrent/src/LeakingBucketRateLimiter.cj:63-72`（同样在拒绝分支返回 `default`）
- **来源**：存量
- **判据**：review-checklist §12.1（有界性 / 异步语义）、§11（契约与实现不符、失败路径当成功）
- **证据**：静态确定 —— `RateLimiter.exec(default, task)` 的拒绝分支**不调用** `task`；而 `Executor` 把"入队 + 完成 Future"整体放进 `task` 里，拒绝时 `future` 从未被 `complete`。调用方 `f_net/src/server/server.cj:169` 的写法是 `executors.call(limiter){…}.get{defaultResp(req.id)}`，会一直等在条件变量上。
- **描述**：任何配置了 `anyMomentRateLimiter` / `leakingBucketRateLimiter` 的服务，在触发限流的那一刻不是"降级返回默认响应"，而是**请求线程永久挂起**；只有默认的 `UnlimitedRateLimiter` 不受影响，因此现网默认配置掩盖了该缺陷。
- **建议**：拒绝分支必须完成 Future。最小改法：先把 `future.complete(default)` 放到 `limiter.exec` 的 else 语义里不可行（`exec` 只返回默认值），因此改为 `let r = limiter.exec(None<Unit>){ q.tryAdd(closure); Some(()) }; if (r.isNone()) { future.complete(default) }`，把"入队"当作被限流的动作、把"未入队"显式映射为 `complete(default)`；并补一条"限流拒绝时 `get` 应立即返回默认值"的用例。

### [严重][存量] `shutdown()` 不唤醒阻塞在 `q.remove()` 的 worker：线程永不退出，关闭后提交的任务永久挂起

- **位置**：`f_concurrent/src/Executor.cj:57-61`（阻塞式 `q.remove()`）、`:101-103`（`shutdown` 仅 `running.store(false)`）、`:43-47`（`Executors.shutdown` 逐个调用）
- **来源**：存量
- **判据**：review-checklist §12.1（线程/资源生命周期、有界性）、§11（资源释放不对称）
- **证据**：静态确定 —— `running` 只在线程从 `remove()` 返回之后才被检查；队列为空时 `remove()` 无限阻塞，`shutdown()` 既不投递"毒丸"也不中断线程。关闭后再 `call()` 会把任务投进同一个队列，而 worker 已全部置 false（若恰好被唤醒则退出、任务无人执行），Future 永不完成。
- **描述**：`Server` / `RxScheduler` 等以 `Resource.close()` 关闭池时，N 个线程泄漏且进程无法优雅退出；`ExecutorPoolTest` 的 `finally { pool.shutdown() }` 也不会真正回收线程。
- **建议**：关闭路径投递 N 个哨兵任务（或队列里放 `?()`，`None` 表示退出）后 `join`；`running` 置 false 前先让 worker 有退出点；`call()` 在 `!running` 时直接返回已完成的 Future（而不是入队）。补"shutdown 后线程数归零 / 再 call 立即返回"用例。

### [严重][存量] `ConcurrentSkipListMap` 的 `size_` 可能变成负数（`clear()` 与 `add()` 的代际检查竞态）

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:359-368`（先 `size_.fetchAdd(1)`，再判 epoch 并**无条件** `fetchSub(1)`）、`:520-527`（`clear()` 先 `epoch.fetchAdd(1)`，再 `size_.store(0)`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入非原子）、§11（边界 / 计数错误）
- **证据**：静态确定 —— 交错顺序：add 在 `:359` 把 size 加到 1 → `clear()` 在 `:522-526` 把 epoch +1 并把 size 置 0 → add 在 `:360` 发现 epoch 变化，`:366` 再 `fetchSub(1)` ⇒ size = -1。
- **描述**：此后 `size` 返回 -1、`isEmpty()` 恒为 false、`toArray()` 的 `Array<(K,V)>(size)`（`:668`）按负数长度分配直接抛异常；任何以 `map.size` 做分页/统计的调用方都会拿到负值。`clear()` 是公开 API，线上"清理缓存 + 并发写入"是常见组合。
- **建议**：把"是否已计入 size"做成显式状态：`clear()` 用 `epoch` 与 `size_` 的成对 CAS（或 `size_.store(0)` 前先 `fetchAdd` 一个足够大的代际偏移），add 侧只在 `epoch` 未变时回滚；更简单的方案是 `clear()` 不重置 `size_`，改为把 `size_` 换成 `AtomicReference<SizeCounter>` 整体替换，避免"归零 + 回滚"交叉。

### [严重][存量] `DelayQueue` 的 `peek` / `size` / `isEmpty` 无锁读取非线程安全的 `PriorityQueue`（数据竞争）

- **位置**：`f_concurrent/src/DelayQueue.cj:42-44`（`peek` 直接 `queue.peek()`）、`:79-83`（`size`）、`:84-86`（`isEmpty`）、`:87-89`（`iterator` 在锁外创建迭代器）；被读对象 `f_collection/src/PriorityQueue.cj:169-192`（`peek` 读 `currentSize` + `queue[0]`，`remove` 在 `adjustDown` 中改写同一数组）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护、迭代与修改并发）
- **证据**：静态确定 —— `add` / `remove` 全程 `synchronized(mutex)`，而 `peek` / `size` / `isEmpty` / `iterator()` **完全不取 mutex**；`PriorityQueue` 自身无任何同步手段（纯数组堆）。`DelayQueue` 是对外 `public` 的并发队列，多线程调用是默认场景。
- **描述**：`peek()` 与并发 `remove()` 可观察到同一个元素（消费者若按 `peek` 判空再 `remove` 会重复处理同一任务）；`size` 可能读到 `currentSize--` 后、`adjustDown` 前的中间态；`iterator()` 在锁外拿到内部数组迭代器，后续 `add` 触发的扩容/交换会让遍历读到已被清空的位置。
- **建议**：`peek` / `size` / `isEmpty` / `iterator()` 统一进入同一把 `mutex`（`iterator` 返回快照 `Array` 或返回"每次 `next` 取锁"的迭代器，现有 `DelayQueueIterator` 已按后者实现，但迭代器对象本身仍在锁外创建，需把创建放进锁内并确保 `PriorityQueue.iterator()` 的可见性）。

### [一般][存量] `DelayQueue.remove/remove(timeout)` 先把元素取出再等待：超时契约被破坏、元素在等待期间对其它线程不可见

- **位置**：`f_concurrent/src/DelayQueue.cj:45-61`（`queue.remove()` 已出队 → `delayedCond.wait(timeout: v.delayedAt - now)` → 无条件 `return v`）、`:62-78`（`remove(timeout)` 用元素剩余延迟做等待，而不是调用方剩余预算）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§12.1（条件等待未在循环里重查条件）
- **证据**：静态确定 —— `:53` 等待时长 = `v.delayedAt - now`，与 `timeout` 无关；`:70` 同理。`timeout` 预算只在"队列空"分支（`:72`）参与判断，一旦取到未到期元素就完全绕过。`:54` / `:71` 等待返回后不重新比较 `delayedAt`，被提前唤醒即返回未到期元素（`Condition.wait` 早返回属平台语义，标 `待确认`）。
- **描述**：`remove(timeout: 10ms)` 在队首元素还有 5s 才到期时会阻塞约 5s；等待期间该元素已从堆中移除，`peek()` 看不到它、其它 `remove()` 会跳过它，`size` 也少算一个；若等待线程被取消/异常，元素永久丢失。
- **建议**：改为"`peek` 判到期 → 到期才 `remove`"，未到期则 `delayedCond.wait(剩余预算)` 并在 `while` 里重查（同时用 `MonoTime` 计算剩余预算）；`remove(timeout)` 的等待上限取 `min(元素剩余延迟, 调用方剩余预算)`，超预算返回 `None`。

### [一般][存量] `Executors.maxQueueSize` 参数完全未使用，队列容量实际等于 worker 数（编译器已警告）

- **位置**：`f_concurrent/src/Executor.cj:24-27`（`let q = ArrayBlockingQueue<()->Unit>(executors)`，`maxQueueSize` 未参与）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置）、§11（契约与实现不符）、§14.1（配置项被读取却从未使用）
- **证据**：静态确定 —— 编译器告警 `unused variable: 'maxQueueSize'`（`f_concurrent/target/release/.build-logs/…errlog:21-24`）。调用方 `f_net/src/server/server.cj:46` 传 `Executors<Message>(executors: executors, maxQueueSize: 1)`，期望"1 个排队位"。
- **描述**：实际排队容量 = 200（worker 数），`f_net` 的背压假设失效：突增请求不会被 `tryAdd` 拒绝，而是堆到 200 个任务、每个都持有 `SocketBuffer` 强引用（内存放大），超时/丢弃策略也不再按配置生效。
- **建议**：`ArrayBlockingQueue<()->Unit>(maxQueueSize)`（worker 数只决定 `Array<Executor>` 长度），或在 `Executors` 里显式两条上限（worker 上限 + 队列上限）；删除该参数时同步改 `f_net` 调用点。

### [一般][存量] `Executors` 默认创建 1024 个 worker 线程

- **位置**：`f_concurrent/src/Executor.cj:24`（`executors!: Int64 = 1024`）、`:26`（每个 `Executor` 构造都 `spawn` 一个线程）
- **来源**：存量
- **判据**：review-checklist §5（无界/过大资源默认值）、§12.1（有界性）
- **证据**：静态确定（线程数 = `executors` 参数，构造即创建）；内存占用 `待实测`（线程栈大小取决于平台，未在本环境测量）。
- **描述**：库的默认构造即申请 1024 个 OS 线程，加上 1024 个 `Mutex`/`Condition`/`AtomicBool`/`ConcurrentHashMap`（其中 map 从未使用，见死代码）。小规模业务一旦不传参就走默认值，线程数与内存都会被放大。
- **建议**：默认值降到"核数 × 2"或 `8`，并在文档中写明；`Executors` 提供惰性创建 worker（首个任务到达才 spawn）。

### [一般][存量] 所有 `ExecutorFuture` 共用同一把互斥锁与同一个条件变量，每次完成都 `notifyAll` 全部等待者

- **位置**：`f_concurrent/src/Executor.cj:66-72` / `:90-99`（每个 Future 都用 `mutex`/`condition` 构造）、`:110-116`（`complete` 内 `condition.notifyAll()`）；`Executors.call` 固定走 `executors[0]`（`:28-42`）
- **来源**：存量
- **判据**：review-checklist §12.2（锁粒度：能否分片 / 单值用原子）、§6.2（锁内唤醒放大）
- **证据**：静态确定 —— `Executors` 的 200 个 worker 共用 `executors[0].mutex`；等待者数 = 并发请求数（`f_net` 每个连接一个请求线程）。临界区内容：`result = …; finished = true; notifyAll()`，持有时长在微秒级，但 `notifyAll` 会唤醒**所有** pending Future 的等待者，被唤醒者抢锁后重新 `wait`（伪唤醒放大 O(n²)）。
- **描述**：请求并发升高时，每次任务完成都造成一次全量唤醒风暴，吞吐随并发度下降；这也是"200 个 worker 却只有 1 个 Future 锁"的结构性串行点。收益需实测，故不作为性能缺陷计入统计。
- **建议**：每个 Future 自带 `Mutex` + `Condition`（`ExecutorFuture` 内部 `new`），或改为单值 `AtomicOptionReference<Result<T>>` + 一个轻量 `SyncCounter`（`count` 归零即完成），彻底去掉共享条件变量；`Executor` 只保留提交队列。

### [一般][存量] `ConcHashDict.clear()` / `ConcurrentHashSet.clear()` 用"遍历逐个删除"实现，非原子且 O(n) 次哈希

- **位置**：`f_concurrent/src/ConcHashDict.cj:140-144`、`f_concurrent/src/ConcurrentHashSet.cj:97-99`（转调 `removeIf{_ => true}`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§6.4（低效算法）、§2（同语义两处实现）
- **证据**：静态确定 —— 两处都是 `for ((k, _) in map) { map.remove(k) }` 的模式；`ConcDict` 的文档承诺"清除所有键值对"（`ConcDict.cj:80-83`），但并发写入时遍历是弱一致快照，循环结束后仍可能有新元素残留；`ConcurrentHashMap` 自带 `clear()`。
- **描述**：`clear()` 在并发场景下不满足"清空"语义；同时也是 n 次哈希 + n 次 CAS，比容器自带的 `clear()` 慢一个量级（无基准数据，性能部分只作说明）。
- **建议**：`ConcHashDict.clear()` 改为 `map.clear()`；`ConcurrentHashSet.clear()` 改为 `store.clear()`；如需"清空后仍拒绝旧写入"的语义，再另加代际计数。

### [一般][存量] `toArray()` 按瞬时 `size` 预分配并 `getOrThrow()`，并发收缩时抛异常

- **位置**：`f_concurrent/src/ConcHashDict.cj:206-212`（`Array<(K,V)>(map.size){ _ => itr.next().getOrThrow() }`）、`f_concurrent/src/ConcurrentSkipListMap.cj:666-669`（同形）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 空集合未处理）、§5（按不可信规模预分配）
- **证据**：静态确定 —— `size` 与随后的迭代之间没有同步；期间发生 `remove` / `clear` 时 `itr.next()` 返回 `None`，`getOrThrow()` 抛 `NoneValueException`；`ConcurrentSkipListMap` 还叠加"size 可能为负"（见严重项），`Array(size)` 直接抛异常。
- **描述**：并发读多写多时 `toArray()` 会随机失败，且失败率随写入频率上升；这是 `Collection` 的通用读接口，调用方通常不会预期它抛异常。
- **建议**：改为 `ArrayList` 追加 + 最后 `toArray()`（长度自适应），或先取 `size` 作为容量提示、`next()` 返回 `None` 时正常结束；两处共用同一实现。

### [一般][存量] `AtomicInt8/16/32/64` 及无符号扩展的 `addFetch`/`subFetch` 在边界处溢出抛异常，但原子写已完成

- **位置**：`f_concurrent/src/AtomicInteger.cj:43-48`（`addFetch = fetchAdd(val) + val`、`subFetch = fetchSub(val) - val`），同形实现见 `:86-91`、`:129-134`、`:171-176`、`:213-218`、`:255-260`、`:297-302`、`:339-344`
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 溢出）、§10（正确性）、§3（失败路径与状态不一致）
- **证据**：静态确定 —— 仓颉整数算术默认溢出抛 `OverflowException`（同文件 `ConcurrentSkipListMap.cj:128` / `:141` / `:159` 用 `@OverflowWrapping` 显式规避，反证默认是检查型）；`fetchAdd` 已在硬件层完成原子写，随后的 `+ val` 溢出抛异常 ⇒ 内存值已改变而调用方收到异常，读到的"新值"与异常状态矛盾。典型触发：`Int8(127).addFetch(1)`、`UInt8(0).subFetch(1)`、`decrFetch()` 于 0。
- **描述**：把"检查型算术"叠在"环绕型原子运算"之上，边界上必然出现"值变了但抛异常"，且无文档说明。
- **建议**：返回值改为按环绕语义计算（`@OverflowWrapping` 标注或 `wrappingAdd` 等显式 API），并在接口注释写明"溢出按环绕处理"；若希望抛异常，则必须在写之前判断（CAS 循环），不能先写后算。

### [一般][存量] `LeakingBucketRateLimiter` 空桶时定时器回调不返回，长期占用线程且 `close()` 无法回收

- **位置**：`f_concurrent/src/LeakingBucketRateLimiter.cj:42-59`（`do { … while (next <= Duration.Zero)`，空桶时 `bucket.remove(remainder)` 阻塞满一个周期后 `next ≈ 0` 恒满足循环条件）、`:74-79`（`close()` 仅 `timer.cancel()`）
- **来源**：存量
- **判据**：review-checklist §12.1（线程生命周期 / 有界性）、§6.2（阻塞动作在调度回调里）
- **证据**：静态确定（循环条件与空桶时 `next` 的关系可纯代码推导）；`Timer.cancel()` 是否能中断正在执行的回调 `待确认`（缺 std.sync.Timer 线程模型文档，本环境无本地文档源）。
- **描述**：低负载（桶空，最常见）时该回调进入"睡一个周期 → 判 `next<=0` → 再睡一个周期"的无限循环，永不返回；每个限流器长期独占一个线程。若 `Timer` 的回调共享线程池，还会拖住同进程其它定时任务（`f_net` 的连接巡检、`f_ticktock` 任务）。`close()` 只取消后续调度，无法终止已进入循环的回调。
- **建议**：回调内改为非阻塞：用 `tryRemove()` 批量漏出，然后 `return max(next, 1ms)` 交还调度权；增加 `closed: AtomicBool` 作为循环退出条件，`close()` 置位并等待回调退出。

### [一般][存量] `ConcurrentHashSet.==` 依赖 `ConcurrentHashMap` 的迭代顺序，容量不同的相等集合会被判为不等

- **位置**：`f_concurrent/src/ConcurrentHashSet.cj:110-125`（逐位比较两个迭代器，`i == this.size` 收尾）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名 / 契约不符）、§12.1（迭代与修改并发）
- **证据**：需实测 —— `ConcurrentHashMap` 的迭代是桶序，桶下标 = `hash & (capacity-1)`；`ConcurrentHashSet(capacity: 100)` 与默认容量构造的同元素集合桶序不同 ⇒ 逐位比较在第一个元素就停止，返回 `false`。**缺** 一条"相同元素、不同容量"的断言用例，需按此构造复现。
- **描述**：`Equatable` 契约要求"元素相同即相等"，现实现实际比较的是"哈希表布局"，等价于弱化版有序比较；同时并发修改期间比较结果也无意义。
- **建议**：改为"小集合遍历 + `contains`"（`if (this.size != other.size) false else this 的每个元素都在 other 中`）；不要依赖迭代顺序。

### [一般][存量] `Constants` 的静态缓存无容量上限、无淘汰，键由调用方任意字符串拼接

- **位置**：`f_concurrent/src/Constants.cj:20`（`private static let constants = ConcurrentHashMap<String, Any>()`）、`:22-28`（`computeIfAbsent('${TypeInfo.of<T>()}-${key}')`）
- **来源**：存量
- **判据**：review-checklist §5（缓存键无界 → OOM）、§7（有界化）
- **证据**：静态确定 —— 缓存是进程级 `static`，只增不减；键含调用方传入的 `key`。仓内无调用点（`README.md:352` 有文档说明），实际键的分布 `待确认`。
- **描述**：一旦有调用方用请求 ID / 用户 ID 之类的高基数 `key`，进程内存单调增长且无法回收（GC 也清不掉静态强引用）。该 API 的命名（`Constants`）暗示"常量"，但实现是任意键缓存，语义误导。
- **建议**：在 API 文档明确"`key` 必须是有限枚举，禁止使用请求级 ID"；实现上加容量上限 + 淘汰（或改用 `LRUCache`），超限时抛异常/不缓存而非静默增长。

### [一般][存量] `AnyMomentRateLimiter` 不校验 `maxTokens`，`<=0` 时静默变成全拒绝

- **位置**：`f_concurrent/src/AnyMomentRateLimiter.cj:27-30`（直接 `ArrayBlockingQueue<Unit>(maxTokens)`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）、§3（静默失效）、§10（正确性）
- **证据**：待确认 —— `maxTokens <= 0` 时 `ArrayBlockingQueue` 构造的具体行为（抛异常 / 容量 0）需查 std 文档；两种结果都不是期望语义：抛异常 = 构造期崩溃，容量 0 = `add` 永远失败、所有任务静默走 `default`。同一模块的 `LeakingBucketRateLimiter.cj:38-40` 已做参数校验，两者不一致。
- **描述**：配置写错（0 / 负数）不会得到明确错误，而是限流器整体失效，线上表现为"所有请求都拿到默认响应"，很难定位。
- **建议**：构造时校验 `maxTokens > 0`，抛 `RateLimiterException`（与 `LeakingBucket` 保持一致）。

### [一般][存量] `ConcurrentSkipListMap.entryView` 的 `fn` 在 CAS 失败时会被重复调用，有副作用的回调会执行多次

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:671-734`（`:705` / `:715` 失败后 `continue` 重新进入循环并再次 `fn(view)`）、`:735-739`（`(K,?V)->?V` 重载直接委托）
- **来源**：存量
- **判据**：review-checklist §11（契约未声明）、§12.1（检查-然后-写入的重试语义）
- **证据**：静态确定 —— 重试路径确实重新执行 `fn(view)`，且每次传入的 `oldVal?.value` 可能不同；`ConcurrentHashMap.entryView` 的 std 语义是否同样允许重试 `待确认`，但本类 README（`f_concurrent/README.md:285`）只给了签名，未说明"回调可能被调用多次"。
- **描述**：调用方若在回调里做计数、发消息、生成 ID，会在高竞争下重复生效；`ConcDict` 的默认实现 `addIfAbsent(key, fn)`（`ConcDict.cj:130-138`）正是把 `fn()` 放在回调里，等于"生成值可能被丢弃/重复"。
- **建议**：在 `entryView` 文档与接口注释中明确"回调必须是纯函数、可能被多次调用"；`ConcDict.addIfAbsent` 的默认实现改为先 `get` 再 `addIfAbsent`（或缓存已生成的值跨重试复用）。

### [一般][存量] `DelayQueue` 用 `DateTime`（墙钟）做延迟判定，系统时间跳变会导致提前/延后取到元素

- **位置**：`f_concurrent/src/DelayQueue.cj:23`（`prop delayedAt: DateTime`）、`:49` / `:70`（`DateTime.now()`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符 / 计时器语义）、fountain-baseline §5（先查 API 语义再下结论）
- **证据**：静态确定 —— 延迟判定与等待时长全部基于 `DateTime.now()`；`MonoTime`（单调时钟）已在同文件 `:63` 使用，说明作者知道两者区别。另外 `:67` 与 `:70` 各调一次 `DateTime.now()`，两次取值不一致。
- **描述**：NTP 校时/夏令时回拨会让元素提前到期或长时间不触发（`wait(timeout)` 用的是墙钟差值，回拨后可能变成负值）。延迟队列的到期语义应当单调。
- **建议**：`Delayed` 改用（或同时提供）`MonoTime` 版本的到期时间；`compare` 与 `wait` 全部基于单调时钟；`:67`、`:70` 复用同一个 `now`。

### [一般][存量] `LeakingBucketRateLimiter.timer` 是非原子 `var`，`close()` 无同步读取

- **位置**：`f_concurrent/src/LeakingBucketRateLimiter.cj:24`（`private var timer: ?Timer = None`）、`:60`（构造末尾赋值）、`:74-79`（`close()` 读取）
- **来源**：存量
- **判据**：review-checklist §12.1（可见性：普通字段跨线程当信号）
- **证据**：待确认 —— 需要"`close()` 与构造/另一个 `close()` 并发"的调用路径；`RateLimiterClose_test.cj:59-66` 只在同线程调用。若池化淘汰线程与构造线程不同，则属于无同步发布。
- **描述**：轻则 `close()` 读到 `None` 而未取消定时器（线程/定时器泄漏），重则两次 `close()` 并发取消同一 `Timer`（是否幂等需查文档）。
- **建议**：改为 `AtomicOptionReference<Timer>`（或 `AtomicReference`）以 `compareAndSwap(Some(t), None)` 保证只取消一次；`close()` 幂等。

### [轻微][存量] 死代码清单：未被调用的私有实现、未使用字段与参数

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:261-282`（`isReachable`，全仓唯一引用是 `:285` 的注释）、`f_concurrent/src/ConcHashDict.cj:217-234`（`ConcDictView`，仅定义未构造）、`f_concurrent/src/Executor.cj:55`（`result` 字段无读写）、`f_concurrent/src/Constants.cj:19`（`private init()`）、`f_concurrent/src/ConcDict.cj:18`（未使用 import）、`f_concurrent/src/ConcurrentSkipListMap.cj:522`（`oldEpoch`）、`f_concurrent/src/ConcDict.cj:131/140/149`（lambda 形参 `k`）、`f_concurrent/src/DelayQueue.cj:59` / `:76`（`while(true)` 之后的 `None<T>` 不可达）、`f_concurrent/src/ConcurrentSkipListMap_bug_test.cj:1-173`（全文注释）
- **来源**：存量
- **判据**：review-checklist §1（无调用者 / 读了不用 / 不可达语句 / 未使用 import）
- **证据**：静态确定 —— 后 6 项由编译器 `-Wunused` 直接点名（`f_concurrent/target/release/.build-logs/…errlog`：`unused import`、`unused function:'init'`、`unused variable:'oldEpoch'`、3×`unused variable:'k'`）；`isReachable` / `ConcDictView` 全仓（含 `.worktrees/` 快照）搜索只剩定义处。
- **描述**：这些残留说明跳表实现从"全表可达性校验"回退到 `validateNode` 后没有清理旧函数，`ConcDictView` 是 `entryView` 改造前的包装层。测试文件整段注释后仍参与编译，`f_concurrent_bug_test` 这个名字会让人误以为有覆盖。
- **建议**：删除 6 项编译器已告警的残留与两个无调用私有实现；`bug_test.cj` 要么恢复用例（当前 4 个 `size` 一致性用例在 `_conc_test.cj` 里已有更弱版本），要么删文件；`helpPhysicallyRemove`（`:515`）仅本文件使用，可收窄为 `private`（属可见性建议，不是死代码）。

### [轻微][存量] 重复逻辑：`retain`/`retainAll`、两处 `clear`、`Atomic*` 8×9 同形扩展

- **位置**：`f_concurrent/src/ConcurrentHashSet.cj:73-77` 与 `:100-104`；`f_concurrent/src/ConcHashDict.cj:140-144` 与 `f_concurrent/src/ConcurrentHashSet.cj:97-99`；`f_concurrent/src/AtomicInteger.cj:18-354`
- **来源**：存量
- **判据**：review-checklist §2（同语义不同入口 / 只改类型名）
- **证据**：静态确定 —— `retain(all!)` 与 `retainAll(values)` 的循环体、谓词、副作用逐行等价，仅参数名与修饰不同；`clear` 两处同为"遍历 + 逐个删"。
- **描述**：`retain` 是 `Set` 接口要求，`retainAll` 是额外入口，两者长期并存必然漂移；`Atomic*` 的 72 个方法体是同一模板对 8 种数值类型展开。
- **建议**：`retainAll` 转调 `retain`（或反过来），只保留一处实现；`Atomic*` **不建议**泛型化（仓颉对数值类型没有可用的统一 trait，抽象只会加间接层），改为在文件头注释说明"逐类型展开是刻意为之，改一处要同步 8 处"，降低后续漏改风险。

### [轻微][存量] 注释与实现不符、复制粘贴残留

- **位置**：`f_concurrent/src/DelayQueue.cj:50`（"先使用peek取得值，再这个if内remove有可能导致活锁"，实际实现是"先 remove 再判到期"）；`f_concurrent/src/ConcDict.cj:44-45` 与 `f_concurrent/src/ConcHashDict.cj:82-83`（文档注释里多出一行 `           120`）
- **来源**：存量
- **判据**：review-checklist §10（可读性）/ §11（语义与注释不符）
- **证据**：静态确定 —— 注释描述的算法与 `:48-54` 的代码顺序相反；`120` 在文档注释中间自成一行，无任何语义。
- **描述**：误导性注释比没有注释更危险：读者会以为"先 peek 后 remove"是刻意设计，从而误判并发语义。
- **建议**：按当前实现重写注释（说明"取出后等待、等待结束即返回"的取舍与副作用），删除 `120`。

### [轻微][存量] `FindNodeCache` 的数组长度硬编码 17，与 `MAX_LEVEL` 无关联

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:89-90`（`Array<Option<Node<K,V>>>(17)`）、`:102`（`MAX_LEVEL = 16`）
- **来源**：存量
- **判据**：review-checklist §10（可维护性）、§11（魔数与常量脱钩）
- **证据**：静态确定 —— 17 = `MAX_LEVEL + 1` 只体现在注释里；调整 `MAX_LEVEL` 时两处不会同步，`preds[level]` 将越界。
- **建议**：`MAX_LEVEL` 改为 `static const`，数组长度写 `MAX_LEVEL + 1`。

### [轻微][存量] `header` 与 `tailer` 的 `including` 默认值相反且 `header` 无文档

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:751-753`（`including!: Bool = false`）与 `:759-769`（`including!: Bool = true`）
- **来源**：存量
- **判据**：review-checklist §10（可读性 / API 一致性）
- **证据**：静态确定 —— 同为区间边界参数，一个默认排除、一个默认包含；`tailer` 有 `@param` 说明，`header` 没有。
- **建议**：统一默认值（建议都"包含"）或在两处都写明默认语义；补 `header` 的参数注释。

### [轻微][存量] 测试有效性：恒真断言、单次计时当性能、计数断言无法检出重复插入

- **位置**：`f_concurrent/src/ConcurrentSkipListMap_conc_test.cj:734`（`@Assert(map.size == 0 \|\| map.size > 0)`）、`f_concurrent/src/ConcurrentSkipListMap_test.cj:228` / `:240`（`@Assert(true)`）、`f_concurrent/src/ConcurrentSkipListMap_perf_test.cj:36` / `:52` / `:68` / `:92` / `:135`（只 `println` 单次耗时）、`f_concurrent/src/ConcurrentSkipListMap_conc_test.cj:53-70`（`result.store(1)` 而非累加，无法发现"多个线程都插入成功"）、`f_concurrent/src/ConcurrentSkipListMap_test.cj:230`（`@TestCase` 缩进错位）
- **来源**：存量
- **判据**：review-checklist §1（恒真分支）、§6.1（性能结论必须有数据）、§11（用例无法覆盖目标缺陷）
- **证据**：静态确定 —— 恒真表达式与占位断言可读即知；`perf_test` 无多轮/中位数，`-O0` 下运行，结论不可引用（baseline §8）；`store(1)` 无计数语义。
- **描述**：`test_no_duplicate_keys_under_high_concurrency` 用 `@Expect` 做了全表计数（有效），但 `test_concurrent_insert_same_key` 的 `result` 不是累加，重复插入也只会得到 1；性能测试打印的数字不能作为任何优化依据。
- **建议**：恒真断言删除或改为有意义的终态校验；`result` 改 `fetchAdd(1)`；`perf_test` 若要保留，改为 `cjpm bench -O2` + 多轮取中位数，或在文件头标注"仅冒烟，不作性能结论"。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本模块**未提供任何 profile / bench 数据**（`scope.md`「已有性能资料」为空），以下全部为 `无基线（待验证）`，不进 `tasks.md`。

### [堆内存] `Executors` 的 1024 个空 `ConcurrentHashMap` 与每线程 `ThreadLocal` 缓存

- **现状**：每个 `Executor` 持有一个从未使用过的 `ConcurrentHashMap<Int64,T>`（`Executor.cj:55`），默认 1024 个；`ConcurrentSkipListMap` 每个 map 每线程还持有 2×17 个 `Option<Node>` 的数组（`ConcurrentSkipListMap.cj:88-91`），线程数 × map 数增长。
- **方案**：删除 `Executor.result`；`FindNodeCache` 改为按需分配（首次 `findNode` 再 `Array(17)`），或在 `MAX_LEVEL` 降低到 12 后同步缩小数组。
- **预期**：消除 1024 个空 map（对象数 -1024）；每线程缓存由固定 34 槽降为按需（仅在真正使用该 map 的线程上分配）。字节量待测。
- **代价**：`findNode` 首次调用多一次分配；无锁语义不变。
- **验证**：`cjpm bench -O2` 前后对照 + `getAllocatedHeapSize()` / RSS，构造 1 个池 + 100 线程跑 10 分钟。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 跳表上层的"每层重新从 head 下降"与 `entryView` 的整轮重试

- **现状**：`physicallyRemove` 对每一层调用 `findPredecessorAtLevel`（`ConcurrentSkipListMap.cj:462-492`），后者每次从 `MAX_LEVEL` 重新下降 ⇒ 每次删除 O(log²n)；`entryView` 在 CAS 失败时整轮重跑（含 `findNode`）。
- **方案**：删除时复用 `findNode` 的 `preds`（该节点已在 `FindResult` 里），或一次性收集各层前驱再逐层 CAS；`entryView` 失败重试只重读 value，不重跑 `findNode`。
- **预期**：删除路径比较次数从 O(log²n) 降到 O(log n)（16 层 × 17 次比较 → 17 次量级）；实际收益取决于删除占比，需 profile。
- **代价**：需要处理"前驱已失效"的退化路径，复杂度上升；并发正确性需压力测试复核。
- **验证**：`cjprof record` 跑 `ConcurrentSkipListMap_conc_test` 的混合负载（16 线程 / 5s），看 `findPredecessorAtLevel` 自耗时占比；再跑 `cjpm bench -O2` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单 Future 共用锁 + `notifyAll` 在 200 worker 下造成唤醒风暴，吞吐随并发下降 | `f_concurrent/src/Executor.cj:110-116` | P99 延迟、每秒唤醒次数、锁等待占比 | 200 worker / 500 并发请求跑 5 分钟，`cjprof` + 线程状态（BLOCKED/WAITING）采样，改前改后对照 |
| 2 | `DelayQueue` 的"先取后等"使 `remove(timeout)` 平均超时误差远大于配置值 | `f_concurrent/src/DelayQueue.cj:62-78` | 实测 `remove(timeout=10ms)` 的 P50/P99 阻塞时长 | 预置 1 个 delayedAt=+5s 的元素，1k 次调用统计时长分布 |
| 3 | `LeakingBucketRateLimiter` 空桶回调长期占用线程；`Timer` 是否共享线程决定影响面 | `f_concurrent/src/LeakingBucketRateLimiter.cj:42-59` | `Timer` 线程模型（共享池 or 每 Timer 一线程）、线程数随限流器数量增长曲线 | 构造 10 个限流器、空闲 60s 后读 `/proc/self/status` 的 `Threads`，并对 `Timer` 源码/文档确认 |
| 4 | 跳表 `physicallyRemove` 的 O(log²n) 在删除密集场景成为热点 | `f_concurrent/src/ConcurrentSkipListMap.cj:462-492` | `findPredecessorAtLevel` 自耗时占比 | `cjprof record` 跑 16 线程 50% 删除混合负载，n=10⁵ |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_concurrent/src/AnyMomentRateLimiter.cj` | .cj | ✅ | 48 行；参数校验缺失（见一般项） |
| 2 | `f_concurrent/src/AtomicInteger.cj` | .cj | ✅ | 354 行；8×9 同形扩展，溢出语义见一般项 |
| 3 | `f_concurrent/src/ConcDict.cj` | .cj | ✅ | 未使用 import（编译器告警）；默认方法 3 处未用参数 `k` |
| 4 | `f_concurrent/src/ConcHashDict.cj` | .cj | ✅ | `ConcDictView` 死代码；`clear` / `toArray` 见一般项 |
| 5 | `f_concurrent/src/ConcurrentHashSet.cj` | .cj | ✅ | `==` 依赖迭代顺序；`retain` / `retainAll` 重复 |
| 6 | `f_concurrent/src/ConcurrentSkipListMap.cj` | .cj | ✅ | 核心容器；size 负数、`isReachable` 死代码、`entryView` 重试 |
| 7 | `f_concurrent/src/ConcurrentSkipListMap_bug_test.cj` | .cj | ✅ | 全文 173 行均为注释，文件无有效内容 |
| 8 | `f_concurrent/src/ConcurrentSkipListMap_conc_test.cj` | .cj | ✅ | 25 个并发用例；含恒真断言（`size == 0 \|\| size > 0`） |
| 9 | `f_concurrent/src/ConcurrentSkipListMap_perf_test.cj` | .cj | ✅ | 只 `println` 单次耗时，无中位数/多轮，不能作为性能结论 |
| 10 | `f_concurrent/src/ConcurrentSkipListMap_test.cj` | .cj | ✅ | 单线程功能用例较完整；`@Assert(true)` 占位两处 |
| 11 | `f_concurrent/src/Constants.cj` | .cj | ✅ | 静态缓存无上限；`private init` 未被使用（编译器告警） |
| 12 | `f_concurrent/src/DelayQueue.cj` | .cj | ✅ | peek/size 无锁；先取后等；两处不可达 `None<T>` |
| 13 | `f_concurrent/src/Executor.cj` | .cj | ✅ | 3 个严重项来源；`maxQueueSize` 未使用（编译器告警） |
| 14 | `f_concurrent/src/Executor_pool_test.cj` | .cj | ✅ | 仅 1 个用例（慢任务不阻塞其它 worker），无异常/关闭用例 |
| 15 | `f_concurrent/src/LeakingBucketRateLimiter.cj` | .cj | ✅ | 定时器回调空桶死循环；`timer` 非原子 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。本部分不含 `README.md` / `README_en.md` / `doc/performance_report.md`（属模块第 2/3 部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 6 条（size 负数、限流拒绝挂起、`entryView` 重试、`Atomic` 溢出、`Clear` 语义、`toArray` 抛异常）；设计 3 条（共享 condition、`Executors` 默认线程数、`Constants` 语义命名）；安全性无外部输入注入面，未命中 |
| §1 死代码 | 7 | ①`isReachable`（`ConcurrentSkipListMap.cj:261`，全仓仅注释引用）②`ConcDictView`（`ConcHashDict.cj:217`，仅定义）③`Executor.result`（`Executor.cj:55`，无读写）④`Constants.private init`（`Constants.cj:19`，编译器告警）⑤`ConcDict.cj:18` 未使用 import（编译器告警）⑥`oldEpoch`（`ConcurrentSkipListMap.cj:522`）、lambda `k`（`ConcDict.cj:131/140/149`，编译器告警）⑦`DelayQueue.cj:59/76` 的 `while(true)` 之后 `None<T>` 不可达；另：`bug_test.cj` 全文注释。对外可达的 `public`（`ExtendAtomic*`、`ConcurrentHashSet`、`DelayQueue` 等）按硬原则一不判；`helpPhysicallyRemove` 有 4 处调用，仅作可见性建议 |
| §2 重复逻辑 | 3 | ①`AtomicInteger.cj` 8 个接口 × 9 个方法同形（仅类型名不同），因仓颉无通用数值 trait，**不建议泛型化**，只作提示；②`ConcurrentHashSet.retain` 与 `retainAll` 语义相同（`:73-77` / `:100-104`）；③`ConcHashDict.clear` 与 `ConcurrentHashSet.clear` 同形"遍历删除"；`findNode` / `isReachable` / `get` 的下降遍历三份近似（`isReachable` 无调用，已计死代码） |
| §3 空实现 | 1 | `ExecutorFuture` 无失败态、`complete` 只在成功路径被调用，等价于"失败路径静默不完成"；其余无空函数体 / TODO |
| §4 栈溢出 | 0 | 已核对全部递归/自调用：无递归函数；跳表遍历均为显式循环；`Node` 之间无环（`next` 只指向后继） |
| §5 OOM | 2 | `Constants` 静态缓存键无界（一般项）；`Executors` 默认 1024 线程 / 队列容量随 worker 数放大（一般项）。`DelayQueue` 无容量上限属队列语义（Java `DelayQueue` 同为无界），未计 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 明确"未提供"），热点不成立；已把"共享 condition 唤醒风暴""跳表删除 O(log²n)"写入待验证假设 |
| §6.2 大粒度锁 | 1 | 所有 Future 共用一把 mutex + 一个 condition（一般项），临界区只含赋值与 `notifyAll`，问题在唤醒放大而非持有时长；`DelayQueue` 在持锁期间 `Condition.wait` 会释放锁，未命中 |
| §6.3 并发串行 | 1 | `Executors` 的 200 worker 共享一个队列与一个 Future 锁 ⇒ 提交/完成两段串行（已并入 §12.2 条目）；无 `spawn(...).get()` 自锁等待 |
| §6.4 低效算法 | 2 | `clear()` 的 n 次 remove；`physicallyRemove` 每层重新从 head 下降 O(log²n)（后者仅作优化方案，无数据） |
| §7 降堆内存方案 | 1 | 删除空 `ConcurrentHashMap` + `FindNodeCache` 按需分配（优化方案，无基线） |
| §8 降 CPU 方案 | 1 | 跳表删除路径复用 `preds`、`entryView` 局部重试（优化方案，无基线） |
| §9 local mode 可行性 | 0 | 本部分热点均在容器/池的长生命周期对象上（节点、Future、队列元素都会逃逸到其它线程），`findNode` 的临时 `FindResult` 已是线程缓存复用，local region 无可证明的峰值收益；按"无前后峰值数据不得写成建议"记为不可行（缺数据） |
| §11 现有代码的 BUG（存量） | 18 | 本部分 18 条发现全部为存量（快照 `8c0ce643a`，无 diff）；已逐函数核对边界/空值/错误处理/资源/并发/契约 |
| §12 并发安全与锁粒度 | 8 | 共享点：`DelayQueue` 的 `queue`（锁覆盖不全）、`ConcurrentSkipListMap` 的 `headRef/size_/epoch`（CAS + 代际，发现 size 负数竞态）、`Executor` 的 `q/running/future` 字段（异常与关闭路径）、`LeakingBucket` 的 `timer`、`Constants` 的静态 map（安全）。死锁方向：未见多锁嵌套（`DelayQueue` 只有一把 mutex，`Executor` 的 limiter 调用在锁外），但"限流拒绝 → Future 永不完成"等价于调用方永久阻塞 |
| §14 功能完备性与 README 覆盖 | 1 | `Executors.maxQueueSize` 是"接了参数但没接线"的典型（一般项）；本部分不含 README，公开 API 与 README 的逐项对照留给合并后的模块报告 |
| 文件覆盖（§13 等） | 15/15 | 15 个文件全部读完；模块 `README.md` / `README_en.md` / `doc/performance_report.md` 不在本部分，§13 文档一致性未在本部分展开 |

## 模块统计（第 1/3 部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 14 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

这 15 个文件是 `f_concurrent` 的"并发地基"：跳表、延迟队列、执行器池、限流器。设计意图清楚（CAS + 逻辑删除 + 代际计数、线程局部缓存、条件变量等待），但**并发路径的错误分支普遍没有闭环**，这是本部分最主要的风险：

- 执行器池的三条主路径都会让调用方**永久阻塞**——任务抛异常（worker 死 + Future 不完成）、被限流拒绝（Future 不完成）、`shutdown` 后（worker 不退出）——而 `f_net` 正是在请求线程上 `get()` 等结果，属于线上可触发的阻塞项，应优先修。
- 跳表在 `clear()` 与 `add()` 交错时能把 `size_` 打成负数，随后 `toArray()` 直接按负长度分配崩溃；`DelayQueue` 的 `peek/size` 又在锁外读非线程安全容器。这两处属于"容器契约本身被破坏"，建议与压力用例一起补。
- `DelayQueue` 的"先出队再等待"是实现层面的设计偏差（超时预算被元素延迟覆盖、元素在等待期间不可见），修法明确，但要配套改测试。
- 死代码与重复实现集中在扩展类与测试：`isReachable`、`ConcDictView`、`Executor.result`、`maxQueueSize` 等已被编译器 `-Wunused` 直接点名，清理成本极低，建议顺手做掉。

存量缺陷 25 条（5 严重 / 14 一般 / 6 轻微），是否纳入修复待用户决定；本部分的性能条目均无基线，只作下一轮补数据的清单。
