# f_concurrent 模块审查报告

> **模块第 1/2 部分**（本报告只覆盖 `files/f_concurrent.part1.txt` 列出的 18 个文件：`README.md`、`README_en.md`、`doc/performance_report.md` 与 `src/` 下 `AnyMomentRateLimiter.cj` → `LeakingBucketRateLimiter.cj` 的 15 个 `.cj`。`LoadBalance` / `RateLimiter` / `SlidingWindowRateLimiter` / `TokenBucketRateLimiter` / `SyncPriorityQueue` / `eventbus/**` / `exception/**` 等剩余 19 个 `.cj` 由第 2 部分产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_concurrent`（本部分 15 个 `.cj` + 3 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：并发原语与同步语义正确性、死锁 / 活锁、可见性、大粒度锁、栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

### [严重][存量] #1 `clear()` 与 `add()` 的 epoch 补偿会重复扣减 `size_` —— `size` 可为负、也可永久漂移，`toArray()` 直接抛异常

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:520-527`（`clear()`：`epoch.fetchAdd(1)` → `headRef.store(...)` → `size_.store(0)`）、`f_concurrent/src/ConcurrentSkipListMap.cj:359-368`（`add()` 插入后 `size_.fetchAdd(1)`，再按 epoch 变化 `size_.fetchSub(1)`）；受影响的下游：`ConcurrentSkipListMap.cj:666-669` 的 `toArray()`、`656-660` 的 `size`、`662-664` 的 `isEmpty()`
- **来源**：存量（快照模式无基线；`doc/performance_report.md:86-108` 记录了这次「clear() 原子性修复」，本轮读到的就是该修复后的代码）
- **判据**：review-checklist §11「并发正确性 / 检查后写入非原子」、§12.1「共享可变状态无保护」「检查-然后-写入」
- **证据**：静态确定 —— 两条合法交错即可破坏不变量（无需竞态之外的额外假设）：
  1. **负 size**：T1 在 `add()` 中读到 `curEpoch=E`（`:307`）→ 完成 level-0 插入（`:350`）→ `size_.fetchAdd(1)` 使 `size=1`（`:359`）；T2 此时执行完整个 `clear()`（`epoch=E+1`、新 head、`size=0`）；T1 在 `:360` 看到 `epoch != curEpoch`，走 `:366-367` 的 `size_.fetchSub(1)` ⇒ **`size = -1`**。`clear()` 的 `store(0)` 已经替它归零，这次 `fetchSub` 是重复扣减。
  2. **幽灵漂移**：T1 在 `:307` 读到的已是 `E+1`（T2 刚做完 `epoch.fetchAdd(1)`，尚未 `headRef.store`），随后 `findNode` 仍走旧 head 插入（`:350`），`size_.fetchAdd(1)` 发生在 T2 的 `size_.store(0)` **之后**，此时 `epoch.load() == curEpoch` ⇒ 不做补偿 ⇒ 新表里没有任何节点，`size` 却永久 +1。
  `remove()` 侧不存在重复扣减（`:575`、`:601` 只在 epoch 未变时减），所以问题集中在 `add()` 的补偿分支。
- **描述**：`size` 是公开属性并被四处当作「真实条目数」使用：`toArray()` 直接 `Array<(K, V)>(size){...}`（`size=-1` 时数组构造抛异常，`size` 偏大时 `itr.next().getOrThrow()` 抛 `NoneValueException`，见 #8）；`isEmpty()`（`:662`）在空表上返回 `false`；`effectiveMaxLevel()`（`:108-113`）用 `size_` 决定层数上限，负值/漂移会让层级长期停在 8。README（`README.md:302`「弱一致性：size 属性可能存在少量偏差」）只承诺「少量偏差」，负值属于不变量被破坏。
  该问题与本模块 `src/ConcurrentSkipListMap_bug_test.cj` 里被整体注释掉的「用例44（size 不一致）」同源（见 #11）——即团队已知此 bug，用注释用例回避了回归。
- **建议**：把「clear 归零」与「add 补偿」二选一，不要两边都做：给 `size_` 引入 generation 标记（`AtomicInt64` 打包 `(epoch, count)` 或用单独的 `sizeEpoch` 数组），`add` 只在「自己那次 `fetchAdd` 的 epoch 仍等于当前 epoch」时才允许 `fetchSub`，否则认为已被 `clear` 归零、直接放弃补偿；或干脆把 `size_` 改成 `clear()` 之后惰性重建（`clear` 只换 head，`size` 走一次 O(n) 统计并缓存）。无论哪种，都要恢复 `bug_test` 里的 200 线程 size 一致性用例作为回归，并新增一条 8 线程 add + 单线程 loop `clear()` 的用例断言 `size >= 0`。

### [严重][存量] #2 `entryView` 的返回值违反 `ConcurrentMap` 契约：更新返回**旧值**、删除返回**旧值**，而契约要求返回「fn 之后的最终值」

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:671-734`（关键 `:702-704` 更新成功时 `return oldVal?.value`；`:707-714` 删除成功时 `return oldVal?.value`）、`f_concurrent/src/ConcurrentSkipListMap.cj:735-739`（`(K, ?V) -> ?V` 重载把返回值原样透传，因此同样返回旧值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性」；契约源：std `collection_concurrent_package_api/collection_concurrent_interface.md:88,101`（「并返回最终映射中键 key 对应的值」「函数 fn 调用结束后当前映射中键 key 对应的值，如果 key 不存在，返回 None」）与 `collection_concurrent_package_api/collection_concurrent_class.md:1225`
- **证据**：静态确定 —— 类声明 `<: ConcurrentMap<K, V>`（`:101`），`entryView(key, fn: (MapEntryView<K,V>) -> Unit): ?V` 是接口方法，契约由上面两处文档固定。实现三条分支的返回值：
  - 键不存在且 fn 置 `Some(x)` → `:690` 返回 `v`（= `Some(x)`，**符合**）；
  - 键存在且 fn 置 `Some(x)` → `:703` 返回 `oldVal?.value`（**旧值，不符**）；
  - 键存在且 fn 置 `None`（删除）→ `:713` 返回 `oldVal?.value`（**旧值，按契约应为 `None`**）。
  对比同类 `ConcDict` 底层用的 std `ConcurrentHashMap.entryView`：返回的是最终值。两个「并发字典」实现对同一语义给出相反结果。
- **描述**：`entryView` 是「原子读-改-写」的唯一入口，返回值天然被调用方当作「改完之后的值」使用。当前实现下：
  - `map.entryView(k){view => view.value = Some(acc + 1)}` 拿回的是改前的值，用它做后续判断会整体错一拍（例如拿返回值累加、或据此决定是否发布事件）；
  - `map.entryView(k){view => view.value = None}` 拿回一个「删除成功」的旧值，调用方无法按契约判断「最终已无此键」；
  - `:735` 的 `(K, ?V) -> ?V` 重载（README `README.md:282` 称之为「Entry View 操作的简重载版本」）把错误一路透传，且它在**插入**路径返回新值、在**更新**路径返回旧值，返回值语义在同一函数内前后不一致。
  影响面：`f_rule` 已在使用 `ConcurrentSkipListMap`（`f_rule/src/rete/AlphaMemory.cj:43,253`、`BetaMemory.cj`），目前只用 `header/sub/tailer/toArray`，未用 `entryView`；但这是对外可达的 public API，且与 std `ConcurrentMap` 契约冲突。
- **建议**：按契约统一返回「最终值」：更新分支 `return newVal`（`Some(x)`）、删除分支 `return None`、插入分支保持 `v`；若希望保留「返回旧值」能力，另开 `removeEntryView` 之类的新方法并在 README 写明「返回旧值」，不要占用接口方法的返回值。给 `entryView` 三个分支各补一条用例（插入 / 更新 / 删除），断言返回值 = 最终值。

### [一般][存量] #3 `DelayQueue`：`add()` 只唤醒 `remCond`，等待在 `delayedCond` 上的消费者既不重查也不被唤醒，更早到期的元素被推迟到前一个元素的到期时间；`wait` 后也不重查 `delayedAt`

- **位置**：`f_concurrent/src/DelayQueue.cj:36-41`（`add()` 只 `remCond.notifyAll()`）、`:45-61`（`remove()`：`:48` 先 `queue.remove()` 弹出堆顶，`:53` 一次性 `delayedCond.wait(timeout: v.delayedAt - now)` 后 `:54` 直接 `return v`）、`:62-78`（`remove(timeout)` 同样在 `:70` wait 后 `:71` 直接返回）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「条件等待：条件变量虚假唤醒未在循环里重查条件」「异步语义」、§11「契约与实现不符」
- **证据**：静态确定 ——
  1. 全文件对 `delayedCond` 只有 `wait`（`:53`、`:70`）没有一次 `notify`/`notifyAll`（`grep notify` 只命中 `:39` 的 `remCond`）。因此「新元素更早到期」这件事永远不会通知到正在等待的消费者；消费者醒来只可能是自己那段 `timeout` 到点。
  2. `remove()` 是「先出队、后等待」：T1 弹出 `delayedAt=now+1h` 的 A 后睡眠；此间 `add()` 一个 `delayedAt=now` 的 B，B 进的是队列而不是 T1 的等待条件；T1 仍睡满 1h。若只有一个消费者，B 被整体延后近 1h。这是延迟队列核心语义（最早到期优先交付）失效。
  3. `wait` 返回后没有任何 `if (v.delayedAt <= DateTime.now())` 复检（`:54`、`:71`），条件变量虚假唤醒会让元素**提前**返回。
- **描述**：README（`README.md:328`「如果队列为空则等待直到非空，否则等待队列头部数据的延迟时间后返回」）描述的是「等到该元素到期」，实现里既没有「到期前被更新元素打断时改等更早元素」的路径，也没有「醒来复核是否真的到期」。多消费者场景下还会出现「后到期元素先交付」：T2 弹出 `delayedAt=now+1s` 的 B，1s 后返回，而 T1 手里还攥着 1h 的 A。
- **建议**：`remove` 改成标准条件变量循环：`while (head 未到期) { delayedCond.wait(timeout: head.delayedAt - now) }`，并在 `add()` 里对「新元素成为堆顶」的情况 `delayedCond.notifyAll()`；等待结束后必须回环重新 `peek` 而不是直接返回已弹出的元素。若坚持「先出队」，至少在 `:54` 前补 `if (v.delayedAt > DateTime.now()) { 重新入队; delayedCond.notifyAll(); continue }`。用例：单消费者 + 先加 1s、后加 0ms，断言 0ms 的先返回。

### [一般][存量] #4 `Executors` 的 `maxQueueSize` 参数被完全忽略：队列容量取的是**线程数**，`f_net` 传的 `maxQueueSize: 1` 实际得到容量 = `executors`

- **位置**：`f_concurrent/src/Executor.cj:24-27`（`public init(executors!: Int64 = 1024, maxQueueSize!: Int64 = 1)`，函数体内 `:25` 用 `executors` 建队列、`:26` 用 `executors` 建线程数组，`maxQueueSize` 一次都没读）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用」、§14.1「接线缺失：配置项被读取却从未使用」
- **证据**：静态确定 —— `init` 参数列表两个入参，函数体只用 `executors`（`:25` `ArrayBlockingQueue<()->Unit>(executors)`、`:26` `Array<Executor<T>>(executors){...}`）。全仓唯一调用点 `f_net/src/server/server.cj:46`：`Executors<Message>(executors: executors, maxQueueSize: 1)`，即**明确传了 1 却拿到 `executors` 大小的队列**。
- **描述**：`maxQueueSize` 是唯一的背压开关。现在它的语义被 `executors` 顶替：`Executors(executors: 8, maxQueueSize: 1)` 实际允许 8 个待执行任务排队，服务端按「最多积压 1 个请求」估算的时延/内存模型全部偏大 `executors` 倍。参数存在但无效，比没有参数更危险——调用方以为设了上限。
- **建议**：`this.executors = Array<Executor<T>>(executors){_ => Executor<T>(q)}` 之前把队列容量改成 `maxQueueSize`（若要「每线程一个队列」，则每个 `Executor` 各建一条容量为 `maxQueueSize` 的队列，并把 `Executors.call` 的分发策略写清）；参数语义写进 README 的 `Executors` 段落。加一条用例：`maxQueueSize: 1` + 两个 `tryCall`，断言第二次返回已完成的 `None`。

### [一般][存量] #5 `Executor.shutdown()` 只置标志，工作线程阻塞在 `q.remove()` 上永不退出 —— 每销毁一个 `Executors` 留下 N 个常驻线程

- **位置**：`f_concurrent/src/Executor.cj:56-62`（线程体 `while(running.load()){ q.remove()() }`）、`:101-103`（`shutdown()` 仅 `running.store(false)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「资源不对称：打开未关」、§12.1「有界性」、`mem §5.2`
- **证据**：静态确定 —— `q.remove()`（std `ArrayBlockingQueue.remove(): E`，`collection_concurrent_class.md:561-571`「如果队列为空，则阻塞等待」）没有超时、没有中断点、也没有「毒丸」元素；`shutdown()` 之后不会再有人入队，因此线程永远停在 `:59`。仅当 shutdown 后还有人 `call()`，某条线程取到任务、执行完、回到 `while` 才发现 `running == false` 而退出——且只会退出一条，其余任务仍会堆在队列里。
- **描述**：`Executors` 是 per-实例的资源（`f_net` 服务端每个 `Server` 一个），默认 1024 条线程、`f_net` 按核数条。`shutdown()` 语义上承诺「关池」，实现上是「不再接受新任务但线程不回收」。进程内多实例创建/销毁（测试、灰度切流量、热重建）会持续累积线程栈。
- **建议**：worker 循环改成 `while (running.load()) { q.remove(timeout: xxx) ... }` 且在 `shutdown()` 里 `running.store(false)` 之后逐个 `q.tryAdd(毒丸)`（N 条线程就投 N 个 `EndTask` 标记），或记录线程句柄并在 `shutdown` 里持续投毒丸直到全部退出；至少要把「shutdown 不退线程」写进 README。用例：`Executors(2).shutdown()` 后 `sleep(100ms)` 断言活跃线程数回落。

### [一般][存量] #6 同一个 `Executor` 的所有 `ExecutorFuture` 共用一把 `Mutex` + 一个 `Condition`：每次 `complete` 都 `notifyAll` 唤醒全部等待者

- **位置**：`f_concurrent/src/Executor.cj:51-54`（`Executor` 只持有一个 `mutex` / `condition`）、`:67`、`:74`、`:90`（每个 future 都 `ExecutorFuture<T>(mutex, condition)` 复用同一个）、`:110-116`（`complete` 里 `condition.notifyAll()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.2「锁粒度：能不能更小」、§6.2「一把全局锁保护多个无关资源」、§6.3「所有任务抢同一把锁 ⇒ 并行度上限 = 1」
- **证据**：静态确定 —— 共享路径完整：`Executors` 只从 `executors[0]` 建 future（`:29`、`:32`、`:35`、`:38`、`:41`），所以**所有** future 都挂在 `executors[0]` 的同一个 `mutex`/`condition` 上。临界区本身很短（两次字段赋值 + `notifyAll`），但 `notifyAll` 的代价与「当前等待者数量」成正比：M 个并发 `get()` 时，每完成一个任务就唤醒 M-1 个与自己无关的等待者，它们醒来重新拿锁、发现 `finished == false` 再睡回去。
- **描述**：`f_net` 服务端每个请求 `call()` 一个 future 并 `get()` 等结果（`f_net/src/server/server.cj:46` 起），M = 在途请求数。这是「请求主路径上的单点锁 + 惊群」：并发越高，唤醒风暴越明显；且 `ExecutorFuture.result` / `finished` 也由这把锁保护，等于把彼此无关的 future 串在同一把锁上。
- **建议**：每个 `ExecutorFuture` 自带 `Mutex` + `Condition`（构造时自建，不再由 `Executor` 注入），`complete`/`get` 只碰自己的锁；`Executor` 层的 `mutex`/`condition` 随之删除。若要保留「共用一把锁」以省对象，把 `notifyAll` 换成按 future 定向唤醒（std 的 `Condition` 不支持定向，因此还是建议每 future 一把）。这是设计变更，需附并发压测（100 并发 × 10k 次 `call+get`，对比改前后 P50/P99）。

### [一般][存量] #7 `ConcurrentHashSet.==` 用迭代顺序逐个比较 —— 元素相同但容量/插入顺序不同的两个 Set 判为不等

- **位置**：`f_concurrent/src/ConcurrentHashSet.cj:110-125`（`:117-122` 双迭代器同步 `next()` 比较，`:123` `i == this.size`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§10「正确性」；`Set` 的相等应当与顺序无关
- **证据**：静态确定 —— 底层是 `ConcurrentHashMap<T, Unit>`（`:26`），其迭代顺序 = 桶序（`hash & (capacity-1)`）+ 桶内链序。两个集合元素相同但用不同 `init`（`:27` 默认容量 / `:30` `capacity` / `:33` `:39` 从集合构造）时表容量不同 ⇒ 同一元素落到不同桶 ⇒ 迭代顺序不同 ⇒ `while` 在第一个位置就 `x != y` 退出，`i < size`，返回 `false`。
- **描述**：`==` 是 `Equatable` 的对外契约，也是 `Set` 语义的核心（去重、断言、缓存键判定）。当前实现把「哈希表遍历顺序」当成了集合的规范顺序，一旦发生扩容差异或桶内碰撞顺序差异就误判。测试里没有任何 `==` 用例，因此该缺陷不会被现有用例发现。
- **建议**：改成大小相等 + 逐元素 `contains`（`if (this.size != other.size) return false; for (v in this) { if (!other.contains(v)) return false }`；O(n) 次哈希查找，与现实现同为 O(n) 但正确）。补用例：`ConcurrentHashSet(["a","b"]) == ConcurrentHashSet(1024)` 与两元素顺序相反的构造。

### [一般][存量] #8 `toArray()` 用 `size` 快照预分配、再 `next().getOrThrow()`：并发删除时抛 `NoneValueException`，`size` 为负时数组构造直接失败

- **位置**：`f_concurrent/src/ConcHashDict.cj:206-212`、`f_concurrent/src/ConcurrentSkipListMap.cj:666-669`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失 / 边界」、§12.1「迭代与修改并发：快照语义未定义」
- **证据**：静态确定 —— `Array<(K, V)>(map.size){ _ => itr.next().getOrThrow() }`：长度取自**调用瞬间**的 `size`，元素取自随后遍历的迭代器。两者之间任何删除都会让迭代器提前返回 `None`，`getOrThrow()` 抛 `NoneValueException`（`Option.getOrThrow` 的契约）；`ConcurrentSkipListMap` 侧还叠加 #1 的负 `size`（`Array(-1)` 直接抛）。
- **描述**：`toArray()` 被 `Collection` 契约要求「返回全部元素的数组」，在并发容器上是最容易被业务当作「安全快照」使用的方法（`f_rule/src/rete/AlphaMemory.cj:129,157,187,191` 就大量调用）。当前实现不是快照：删除即抛异常，插入则静默丢新元素（数组长度已定）。
- **建议**：改为「迭代器驱动、不够再扩」：先按 `size` 预分配但用 `ArrayList` 收集（`while (let Some(x) <- itr.next()) { out.add(x) }`，最后 `toArray()`）；或至少 `next()` 返回 `None` 时 `break` 并把数组截断到实际长度。文档上写明弱一致语义。用例：8 线程 `removeIf` 的同时主线程 `toArray()`，断言不抛异常。

### [一般][存量] #9 `DelayQueue` 的 `peek` / `size` / `isEmpty` 无锁读被加锁写原地修改的 `PriorityQueue` —— 「部分线程安全」的队列

- **位置**：`f_concurrent/src/DelayQueue.cj:42-44`（`peek`）、`:79-83`（`size`）、`:84-86`（`isEmpty`）对 `:34` 的 `queue` 直接读；写侧 `:36-41`、`:45-78` 全部在 `synchronized(mutex)` 内
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护」「迭代与修改并发」，§11「契约与实现不符（部分同步）」
- **证据**：静态确定 —— `queue` 是 `f_collection` 的 `PriorityQueue`（`f_collection/src/PriorityQueue.cj:37`），所有方法都不加锁，`add` 走 `doOffer` → `adjustUp`（`:238` 起）**原地搬移数组元素**，`remove` 走 `adjustDown` 同样原地搬移，`grow` 还会整体换数组（`:140-156`）。`DelayQueue.add/remove` 在 `mutex` 内调用它们，`peek` 却在锁外读 `queue[0]`（`PriorityQueue.cj:169-176`）⇒ 读到的是「搬移过程中的堆顶」，可能是已被移走的元素，也可能在 `size` 刚变化时读到 `None`。
- **描述**：README（`README.md:325-334`）把这几个方法明确标注为「非同步函数」，所以这是**有意取舍**；但取舍的后果不是「读到旧值」，而是「读到堆结构中间态」：`peek()` 返回的元素可能已经不在堆顶。对一个供多线程 `add/remove` 的队列，只在 3 个读方法上放弃同步，等于把「部分线程安全」暴露给使用者。
- **建议**：三者统一走 `synchronized(mutex)`（临界区只有一次数组读，代价可忽略）；若要保留无锁读，则把 `PriorityQueue` 换成「写时复制堆顶快照」（`AtomicOptionReference<T> head`，在 `mutex` 内更新），`peek` 只读原子引用。README 相应改写为「全部方法线程安全」。

### [一般][存量] #10 `Constants.get` 把用户 `fn()` 放进 `ConcurrentHashMap` 的 entryView 临界区执行 —— 慢 `fn` 阻塞同桶线程，`fn` 内跨线程回访可死锁

- **位置**：`f_concurrent/src/Constants.cj:22-28`（`:23` `constants.computeIfAbsent('${TypeInfo.of<T>()}-${key}'){fn()}`）；`computeIfAbsent` 的实现链：`f_collection/src/ExtendCollection.cj:122-126`（`ConcurrentHashMap.entryView(key){entry => entry.value = fn(key, entry.value)}`）→ std `ConcurrentHashMap.entryView`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.2「锁内调用外部回调」、§12.1「死锁：锁内调用外部回调（回调再取锁）」；契约源：std `collection_concurrent_package_api/collection_concurrent_class.md:1231`（「注意参数 fn 中不能并发调用函数 entryView、remove、replace」）与 `:1245`（「该操作具有原子性」）
- **证据**：静态确定（由 std 文档固定）—— std 明文规定回调执行期间不能并发调用 `entryView/remove/replace`，说明回调运行在持有桶锁的临界区内。`Constants.get` 把**任意用户代码** `fn()` 放进这个回调：`fn` 取一次远程配置、读一个大文件、或等另一个线程（`SyncCounter.waitUntilZero`、`Future.get`）时，同桶的所有 `Constants.get` 调用全部阻塞；若被等的那个线程也要 `Constants.get` 且落到同一桶，即构成 hold-and-wait 死锁。
- **描述**：`Constants` 的定位是「只计算一次」的轻量工具（README `README.md:164-176`），调用方没有任何线索知道自己的 `fn` 会在锁里执行。桶锁还是按 key 哈希分散的，死锁需要「同一桶」，概率低但不可排除；阻塞则是常态（同桶串行化）。
- **建议**：改成「锁外计算 + 锁内二次判定」：`if (let Some(x) <- constants.get(k)) { return cast(x) }; let v = fn(); if (let Some(x) <- constants.addIfAbsent(k, v)) { cast(x) } else { v }`（允许重复计算、只保留先到者），并在注释/README 写明「fn 可能被并发调用多次」。若必须保证只算一次，用 `f_collection` 的 `ConcHashMap.getOrCompute`（分段锁且已修过 CACHE-2）并在文档写明「fn 内不得回访同一 key 空间」。

### [一般][存量] #11 `ConcurrentSkipListMap_bug_test.cj` 整文件被注释 —— 173 行死文件，已知的 size 不一致用例（用例44）没有守护

- **位置**：`f_concurrent/src/ConcurrentSkipListMap_bug_test.cj:1-173`（`:17-22` 连 `import` 都注释，`:23-172` 全部是 `//` 开头的 `@Test` 类与 4 个用例）
- **来源**：存量（快照模式无基线；文件头年份 2026，与 `cjpm.toml` 的 1.3.x 同期）
- **判据**：review-checklist §1「死代码：无调用者 / 注释掉的整文件」、§14.1「半成品：主路径上还有被跳过的用例」
- **证据**：静态确定 —— 文件内没有任何非注释的声明，编译产物里不存在 `ConcurrentSkipListMap_bug_test` 类；`cjpm.toml` 的 `include = ["src"]` 会把它一起发布。
- **描述**：该文件里的 4 个用例正是 #1 的回归用例（`:76`、`:111`、`:143` 三个 `test_size_consistency_under_concurrent_modifications`，注释写着「暴露 size 不一致 bug（用例44）」），线程数从 200 降到 `ConcurrentSkipListMap_conc_test.cj` 里的 20 才「通过」。注释掉而不是修掉，等于把「已知缺陷」从 CI 视野里移走；同时 `bug_test` 这个名字会让人误以为缺陷已修。
- **建议**：要么修 #1 后把用例恢复到 `conc_test` 并保留 200 线程，要么删除该文件（保留 `conc_test` 里的 20 线程版本并在注释里写明「因 #1 未修，线程数下调」）。不要留整文件注释。

### [一般][存量] #12 本部分 5 个 public 类型零用例、`header/sub/toArray` 零用例，且现有用例里存在恒真断言与占位断言

- **位置**：零用例类型 —— `DelayQueue`（`DelayQueue.cj`）、`ConcDict` / `ConcHashDict`（`ConcDict.cj` / `ConcHashDict.cj`）、`ConcurrentHashSet`（`ConcurrentHashSet.cj`）、`Constants`（`Constants.cj`）；零用例方法 —— `ConcurrentSkipListMap.header`（`:751`）、`sub`（`:770`）、`toArray`（`:666`）—— 全模块 `*_test.cj` 内 `grep` 无命中；恒真断言 —— `ConcurrentSkipListMap_conc_test.cj:734`（`@Assert(map.size == 0 || map.size > 0)`）；占位断言 —— `ConcurrentSkipListMap_test.cj:228`、`:240`（`@Assert(true)  // 占位`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2「示例覆盖不足」的测试侧对应项、§3「空实现（占位）」、§11「用例断言写错」
- **证据**：静态确定 —— `grep -n "DelayQueue\|ConcHashDict\|ConcDict\|ConcurrentHashSet\|Constants" f_concurrent/src/*_test.cj` 无任何输出；`grep "header(\|sub(\|\.toArray" *_test.cj` 同样无输出。`@Assert(true)` 两处对应 `test_random_level_distribution` / `...2`（注释自述「这里简化：直接测试不会崩溃」），实际只验证了「插入 10000 次不崩」。`:734` 的表达式对任意非负 `size` 恒真，唯一能失败的值是负数——而负数恰是 #1 的症状，等于把一条本该抓 bug 的断言写成了「除了负数都通过」。
- **描述**：本部分承载的是并发容器与线程池，正确性完全依赖并发用例；实际覆盖集中在 `ConcurrentSkipListMap`（单线程 23 条 + 并发 17 条），另外 5 个 public 类型**完全没有用例**。`DelayQueue` 的 #3、`ConcurrentHashSet` 的 #7、`toArray` 的 #8 都是「一写用例就能抓到」的类型。
- **建议**：按类型补最小用例集：`DelayQueue`（空队列阻塞/超时、按到期顺序、add 唤醒、iterator）；`ConcurrentHashSet`（`==`、`retainAll/retain`、`clone`、并发 add/remove）；`ConcHashDict`（`toArray` 并发、`removeIf(key)` 返回值、`clear`）；`Constants`（并发只算一次、类型不符抛 `TypeNotMatchException`）；`ConcurrentSkipListMap` 补 `header/sub/toArray` 与随机层数（用 `level` 反射或断言不变量）。把 `:734` 的恒真断言改成 `@Assert(map.size == 0)` 之外的明确不变量（如 `>= 0`），`@Assert(true)` 两处删除或改成实际断言。

### [一般][存量] #13 `doc/performance_report.md` 与性能用例、与当前实现三处不符（「3 轮取平均」「并发 80,000 ops」「Random 修复代码片段」）

- **位置**：文档 `f_concurrent/doc/performance_report.md:16`（「连续运行3轮取平均值」）、`:27`（「并发 add (8线程) | 80,000 | …」）、`:65-84`（「Random 线程安全修复详情」代码片段）、`:74`（`private static let seedGen = AtomicInt64(0)`）；实现 `f_concurrent/src/ConcurrentSkipListMap_perf_test.cj:30-37`、`:78-92`（单轮计时，`println` 一次，无平均、无预热、无重复）、`f_concurrent/src/ConcurrentSkipListMap.cj:117`（`seedGen` 用 `DateTime.now().toUnixTimeStamp().toNanoseconds()` 初始化）、`:106,143-157`（线程局部 `XorShiftState`，文档写的是「实例级别种子 `var seed: AtomicInt64`」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档与代码一致性：API / 默认值与源码不符」「规格与实现漂移」
- **证据**：静态确定 —— 三条都对得上位置：① `perf_test.cj` 每个用例只 `MonoTime.now()` 一次、`for` 跑一遍、`println` 一次，没有任何「重复 3 轮取平均」的代码；② `test_perf_concurrent_add`（`:72-93`）8 条线程都是 `for (j in 0..10000) { map.add(j, j) }`，即**同一批 10,000 个键被重复写 8 遍**，其中 70,000 次是「覆盖更新」而不是「插入」，文档却把它统计为 80,000 次插入吞吐；③ 文档贴出的修复代码（`var seed: AtomicInt64` / `seedGen = AtomicInt64(0)` / 每个实例一个种子）与当前实现（每线程一个 `XorShiftState`、静态种子用时间戳、`fetchAdd(1)` 后乘 LCG 常数）完全不同。
- **描述**：这份报告是本模块唯一的性能基线，`docs/LocalMode-*` 之类的后续优化会拿它当「改前数据」。三处不符让基线不可复现：按「3 轮平均」的预期去跑 `cjpm test` 只会得到一次运行结果；按「80,000 次插入」理解吞吐会高估并发插入能力约 8 倍（真实首次插入只有 10,000 次）。
- **建议**：① 用例与文档二选一：把 `perf_test` 改成 3 轮循环并输出中位数/极值，或把文档改成「单轮」；② 并发 add 用例改成按线程分配不重叠的键区间（`t*10000 + j`），并在文档注明「8 线程 × 10,000 个互不相同的键」；③ 删掉文档里的历史代码片段，改成「见 `ConcurrentSkipListMap.cj:106,142-157`」的指针，避免片段与实现再度分叉。另建议把 6 个 `perf_*` 用例移出 `cjpm test`（它们会 `println` 并占用数秒），改用 `cjpm bench`。

### [轻微][存量] #14 README 三处与实现不一致：`RateLimiter` 声明为 `sealed`、`entryView` 未写返回值语义、两个 public 迭代器类未登记

- **位置**：`f_concurrent/README.md:97`（`abstract sealed class RateLimiter<T>`）、`:282-285`（`entryView` 只写「简重载版本」「带条件检查的原子更新」，未写返回值）、`:340-384`（「补充：README 未展开的公开面」「其他公开 API」两张清单）；实现 `f_concurrent/src/RateLimiter.cj:18`（`public abstract class RateLimiter<T>`）、`src/DelayQueue.cj:92`（`public class DelayQueueIterator`）、`src/ConcurrentHashSet.cj:18`（`public class ConcurrentHashSetIterator`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 声明与源码不符」、§14.2「公开 API 未文档化」
- **证据**：静态确定 —— ① `RateLimiter` 在代码里是 `public abstract`（非 `sealed`），README 写成 `abstract sealed`，会让使用者以为不能在本模块外继承（实际可以，且 `RateLimiter.cj:34` 的 `close()` 就是留给子类覆盖的扩展点）；② `DelayQueueIterator` / `ConcurrentHashSetIterator` 是顶层 `public` 类，两张「其他公开 API」清单里都没有；③ `entryView` 的返回值语义（#2）在 README 中完全没写，只写了「简化重载」。
- **建议**：README 的 `RateLimiter` 声明改成 `public abstract class`；`entryView` 两个重载补一行「返回 fn 执行后该键的最终值（键不存在则为 None）」；两个迭代器类要么在清单里补一行，要么把类改成 `internal`（它们只作为 `iterator()` 的实现返回，见 #22）。

### [轻微][存量] #15 `Executor.result` 是从未使用的字段：每个 `Executor` 都白建一个 `ConcurrentHashMap`（默认 1024 个实例 = 1024 个空 map）

- **位置**：`f_concurrent/src/Executor.cj:55`（`private var result = ConcurrentHashMap<Int64, T>()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「死代码：读了不用 / 私有字段无使用」
- **证据**：静态确定 —— `Executor` 类体（`:49-104`）内 `result` 只出现在声明处；`:106` 的 `var result` 属于 `ExecutorFuture`，与它无关。
- **描述**：`Executors(executors: 1024)` 会构造 1024 个 `Executor`，每个都分配一个 `ConcurrentHashMap`（含初始桶数组），其中 1023 个永远为空；同时该字段让 `Executor` 看起来「有结果缓存」，误导维护者。
- **建议**：直接删除该字段。

### [轻微][存量] #16 `isReachable` 与 `ConcDictView` 是无引用的死代码

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:261-282`（`private func isReachable`）、`f_concurrent/src/ConcHashDict.cj:217-234`（`private struct ConcDictView`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「`private` 符号在本项目内无调用者」
- **证据**：静态确定 —— 全仓搜 `isReachable` 只命中定义处与 `:285` 的注释「替代 isReachable 的 O(log n) 全表遍历」（`grep -rn isReachable` 排除 `.worktrees` 后共 2 行）；`ConcDictView` 只有 `:217` 定义与 `:218` 构造器，无任何 `ConcDictView(` 实例化。
- **描述**：`isReachable` 是 `validateNode` 改造前的 O(log n) 全表可达性检查，已被替换但没删；`ConcDictView` 是 `MapEntryView` 的包装，`ConcHashDict.entryView`（`:213-215`）最终没有用它（改用 `(K, ?V) -> ?V` 版本）。两者都会让人以为还有一条「全表验证」或「视图」路径。
- **建议**：删除两个符号；`validateNode` 的注释保留「替代 isReachable」的历史说明即可。

### [轻微][存量] #17 `AtomicInteger.cj` 是 8 组 × 9 个「只差类型名」的方法体

- **位置**：`f_concurrent/src/AtomicInteger.cj:18-354`（`ExtendAtomicInt8`/`UInt8`/`Int16`/`UInt16`/`Int32`/`UInt32`/`Int64`/`UInt64` 各 1 组接口 + 1 个 `extend`，每组 9 个方法体逐行同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名：两个函数体逐行对齐，只有 `Int64`/`Int32` 不同」
- **证据**：静态确定 —— `:43-45` 与 `:86-88`、`:129-131`、`:171-173`、`:213-215`、`:255-257`、`:297-299`、`:339-341` 八处 `addFetch` 完全相同，只把 `Int8` 换成 `UInt8`…；`fetchIncr`/`incrFetch`/`decrFetch` 同理。
- **描述**：72 个方法体来自同一模板。仓颉没有「对整数类型泛型」，这部分重复无法用泛型消除，但可以用宏（`f_macros` 已有先例）或一个私有 helper 收口「先 fetch 再合成」，避免今后只在某一组加方法/改语义（#20 就是这种漂移：8 组的溢出行为完全一致地错）。
- **建议**：用 `@Mixin`/宏按类型展开生成，或至少把 8 组 `addFetch` 的文档注释统一（当前 8 组注释都没有说明溢出行为）。

### [轻微][存量] #18 三处「同语义不同写法」的实现重复：两个迭代器类逐行相同、`entryView` 内两段插入分支相同、`remove(key)` 与 `remove(key, predicate)` 同骨架

- **位置**：`f_concurrent/src/ConcurrentSkipListMap.cj:880-899`（`EntryIterator`）vs `:901-920`（`TailEntryIterator`，`next()` 体逐行相同，只有构造参数不同）；`f_concurrent/src/ConcurrentSkipListMap.cj:678-693` vs `:717-730`（`entryView` 内两段「键不存在 → 建 view → `fn` → `addIfAbsent`」）；`f_concurrent/src/ConcurrentSkipListMap.cj:560-589`（`remove(key, predicate)`）vs `:591-614`（`remove(key)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「换控制流 / 同文件内函数体摘要相同」
- **证据**：静态确定 —— `EntryIterator.next()`（`:887-898`）与 `TailEntryIterator.next()`（`:908-919`）除类名外字符级一致；`entryView` 的两段插入分支（`:681-692` 与 `:719-730`）一致；`remove(key)`（`:591-614`）就是 `remove(key, predicate)`（`:560-589`）去掉 `predicate(box.value)` 判断后的版本。
- **描述**：`TailEntryIterator` 完全可以复用 `EntryIterator`（把构造参数从 `head` 改成 `Option<Node>` 即可，或让 `EntryIterator` 接受 `Option<Node>` 起点）；`entryView` 的两段可以合并到 `case Some/None` 之后统一处理；`remove(key)` 可以用 `remove(key){ _ => true }` 转发（但要注意返回值语义：#2 已涉及 `entryView` 的返回值，`remove` 这条转发是安全的）。
- **建议**：合并 `EntryIterator`/`TailEntryIterator`（保留一个带 `Option<Node>` 起点的实现）；`entryView` 抽一个私有 `insertViaView(key, view)`；`remove(key)` 转发到带 `predicate` 的版本并写清「predicate 恒真」。

### [轻微][存量] #19 `contains(all!)` / `add(all!)` / `remove(all!)` 在 5 个类型里各写一遍同形循环

- **位置**：`f_concurrent/src/ConcHashDict.cj:73-78`、`:98-102`、`:123-127`；`f_concurrent/src/ConcurrentHashSet.cj:59-63`、`:67-72`、`:87-91`；`f_concurrent/src/ConcurrentSkipListMap.cj:780-785`、`:801-805`、`:867-871`；`f_concurrent/src/ConcHashDict.cj:278-280`（`ConcHashKeyCollection.contains(all!)` 直接转发）；`f_concurrent/src/ConcurrentSkipListMap.cj:927-932`（`SkipListKeyCollection.contains(all!)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「跨层复制 / 字面量复制」
- **证据**：静态确定 —— 5 处 `for (k in all where !contains(k)) { return false }` 与 3 处 `for (...) { add/remove(...) }` 结构完全一致。
- **描述**：这几个方法来自 std `Collection` / `Queue` 接口，每个实现类都必须提供，但「全包含」「批量增删」的语义完全一样，可以下沉为一个包内 helper（`CollectionUtil.containsAll(self, all)`）或接口默认实现（`f_collection` 的 `ExtendCollection` 已经有类似能力）。
- **建议**：在 `f_concurrent` 内加一个 `private func containsAll<K>(...)` 之类的包内 helper，5 处改为转发；`add(all!)`/`remove(all!)` 保持循环（语义差异小，收益低，可不改）。

### [轻微][存量] #20 `addFetch` / `incrFetch` / `decrFetch` 的第二次运算是普通加法：`Int8/Int16/Int32` 越过上界时抛 `OverflowException`，与 `fetchAdd` 的原子环绕语义不一致

- **位置**：`f_concurrent/src/AtomicInteger.cj:43-45`、`:86-88`、`:129-131`、`:171-173`、`:213-215`、`:255-257`、`:297-299`、`:339-341`（`fetchAdd(val) + val`）；`:37-39`（`incrFetch` → `addFetch(one)`）、`:40-42`（`decrFetch` → `subFetch(one)`）、`:46-48`（`subFetch` 同理）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§10「类型使用」；语言规则见 `cangjie_docs` `docs/dev-guide/source_zh_cn/basic_data_type/integer.md:137`（溢出按默认策略抛异常）
- **证据**：静态确定 —— `fetchAdd` 是原子原语（`sync_package_classes.md:3081-3085`「将原子类型的值与参数 val 进行加操作」），`+ val` 是**普通算术**，走语言的溢出检查。`AtomicInt8(100).addFetch(100)`：`fetchAdd(100)` 返回 100，`100 + 100` 超出 `Int8` 上界 ⇒ 抛 `OverflowException`；同理 `AtomicInt8(127).incrFetch()`。
- **描述**：`incrFetch` / `addFetch` 的语义是「计数器的原子自增」，调用方在 `Int8`/`Int16` 这种小类型上做循环计数（例如协议字段、分片号）会在边界上崩。`fetchAdd` 不抛、`addFetch` 抛，两个名字只差语序却行为不同。
- **建议**：给 8 个 `extend` 加 `@OverflowWrapping`（或在方法上标注），让 `+ val` 与 `fetchAdd` 一样环绕；若希望溢出可见，则在 README 与注释里明确写「越界抛 `OverflowException`」，并补一条边界用例。

### [轻微][存量] #21 `AnyMomentRateLimiter` 的参数校验错在 `ArrayBlockingQueue` 里，抛的是 std 的 `IllegalArgumentException` 而不是本模块统一的 `RateLimiterException`

- **位置**：`f_concurrent/src/AnyMomentRateLimiter.cj:27-30`（`:29` `ArrayBlockingQueue<Unit>(maxTokens)`，无 `maxTokens <= 0` 前置校验）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§10「错误处理」；对照 `LeakingBucketRateLimiter.cj:38-40`（同类参数校验抛 `RateLimiterException`）
- **证据**：静态确定 —— std 文档 `collection_concurrent_class.md:112-113`：「如果 capacity 小于等于 0 则抛出 `IllegalArgumentException`」，示例输出 `Invalid capacity '0': expected a positive value.`（`:148`）。`AnyMomentRateLimiter(maxTokens: 0)` 因此抛 `IllegalArgumentException`；而 `LeakingBucketRateLimiter(maxWaitings: 0)` 抛 `RateLimiterException`，`RateLimiter` 基类对 `timeout <= 0` 也抛 `RateLimiterException`（`RateLimiter.cj:19-23`）。
- **描述**：模块内的限流器对「参数非法」给出两种异常类型，调用方无法用 `catch (e: RateLimiterException)` 统一处理配置错误（`f_net/src/server/server.cj:304`、`f_rpc/src/server/ServerConfig.cj:89` 都是按配置构造限流器）。
- **建议**：`init` 开头补 `if (maxTokens <= 0) { throw RateLimiterException('maxTokens must be larger than zero, but current is ${maxTokens}') }`，与 `LeakingBucketRateLimiter` 对齐。

### [轻微][存量] #22 `LeakingBucketRateLimiter` 的 `leaked` 只在定时任务开头清零，跨周期重入时沿用上一周期的已漏计数 ⇒ 新周期少漏

- **位置**：`f_concurrent/src/LeakingBucketRateLimiter.cj:42-59`（`:43` `leaked.store(0)` 在任务入口，`:46-56` 的 `do { ... } while (next <= Duration.Zero)` 重入时不再清零）、`:48`（`while (leaked.load() < leakingPerDuration && ...)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「边界差一 / 状态未重置」、§10「正确性」
- **证据**：静态确定 —— 若一次任务执行跨过了周期边界（`:55` 算出 `next <= 0` 时说明本周期已耗尽），`do-while` 回到 `:47` 开新周期，但 `leaked` 仍是上一周期的计数，`:48` 的新周期预算变成 `leakingPerDuration - leaked` 而不是 `leakingPerDuration`。周期边界处的漏出速率会短时低于配置值（漏得少 = 限流更严），不会多漏。
- **描述**：`leakingPerDuration` 是「每个周期的许可数」，实现把它当成了「本次任务执行内的累计数」。README（`README.md:112-125`）没有说明这种跨周期行为，使用者按「每周期 N 个」估算吞吐会偏低。
- **建议**：在 `:47` 的 `do` 体开头（`end = ...` 之前）再 `leaked.store(0)`，或用局部变量 `var leakedInCycle` 替代全局 `leaked`（定时任务自带线程，见 std 文档「每个 Timer 会创建一个线程」`sync_package_classes.md:10738`，无需原子量）；若要保留「跨周期累计」语义，则改写注释与 README。

### [轻微][存量] #23 `DelayQueue.iterator()` 返回的是堆数组序而非到期顺序，且不是快照

- **位置**：`f_concurrent/src/DelayQueue.cj:87-89`（`DelayQueueIterator<T>(mutex, queue.iterator())`）、`:92-102`（`next()` 加锁后直接委托底层迭代器）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§12.1「迭代与修改并发：快照语义未定义」
- **证据**：静态确定 —— 底层 `PriorityQueue.iterator()`（`f_collection/src/PriorityQueue.cj:234-238`）对内部**堆数组**建迭代器并记录当时的 `currentSize`；堆数组是「层序」不是「有序」，因此 `DelayQueue.iterator()` 的产出顺序与 `delayedAt` 无关。README（`README.md:335`）只说「获取迭代器，返回的迭代器的 next 函数是同步的」，没有承诺顺序；`next()` 的 `synchronized(mutex)` 只能避免「读到搬移中间态」，两次 `next()` 之间堆被 `adjustUp/adjustDown` 重排仍会漏元素或重复元素。
- **描述**：一个「延迟队列」的迭代器被自然理解为「按到期时间从早到晚」，实现给的是堆内部顺序；如果上层用它做「批量取出到期任务」，会拿到乱序结果。另外「非快照」也没有文档化。
- **建议**：要么按 `delayedAt` 排序输出（代价 O(n log n)，可接受，因为迭代本身 O(n)），要么在 README 写明「顺序不保证、非快照」。若要保持 O(n)，可用「复制堆数组后排序」的实现（`iterator()` 内 `queue.toArray().sortBy(delayedAt)`）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分没有改前/改后对照数据，以下全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [CPU] `header()` / `sub()` 全表过滤：区间查询退化为 O(n)，`f_rule` 的 RETE 区间检索每次都要扫完整张有序索引

- **现状**：`ConcurrentSkipListMap.header`（`:751-753`）与 `sub`（`:770-775`）都走 `filterIterator`（`:747-750`）→ `iterator().filter{...}`，从最小键开始遍历**整张表**，即使 `max` 之前的键只有几个也不提前终止；`tailer`（`:759-769`）已经用 `findNode` 做到 O(log n) 定位，`header/sub` 没有。调用方 `f_rule/src/rete/AlphaMemory.cj:218`（`ordIndex_[field].header(bound, ...)`）与 `:154`（`sub(...)`）在规则匹配的区间查询主路径上，索引规模 = 该字段的去重值个数。
- **方案**：`header` 改成「从 `head.next[0]` 起用 `maxChecker` 判直到第一个不满足的键即 `break`」——底层 `EntryIterator` 本身按 level-0 有序推进，只要把 `filter` 换成带 `break` 的循环即可；`sub` 用 `tailer(min)` 起、同样在 `key > max` 处 `break`。复杂度从 O(n) 降到 O(log n + k)。
- **预期**：区间命中 k 个元素时，扫描量从「全表 n」降到「k + log n」；`n=10^4`、`k=10` 时理论降幅约 1000 倍（仅针对该函数自身耗时，端到端占比待测）。
- **代价**：`Iterator` 没有 `break`，需要写一个显式的 `while (let Some(x) <- itr.next())` 循环并手工拼迭代器（或用 `takeWhile`）；语义不变（`including` 的边界判定复用 `maxChecker`）。
- **验证**：`cjpm bench -O2` 分别构造 n = 1k / 1万 / 10万 的索引，`header` 取中位键，对比改前后单次耗时；再用 `f_rule` 的规则匹配压测看端到端变化。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ConcurrentHashSet` 的 `intersection` / `union` / `difference` 每次都把入参整体复制成新 Set

- **现状**：`ConcurrentHashSet.cj:144-152` 三个方法都在返回视图前执行 `ConcurrentHashSet<T>(collection)`（`:145`、`:148`、`:151`），即 O(m) 次哈希插入 + 一份新表；而 `IntersectionSetView` / `UnionSetView` / `DifferenceSetView`（`f_collection`）本身只做 `contains` 查询，并不需要副本。
- **方案**：直接把 `collection` 传给视图（把 `ConcurrentHashSet<T>(collection)` 换成 `collection`），视图内部用原集合的 `contains`；若担心并发修改，则在视图构造时记录 `size` 做防御。
- **预期**：每次集合运算省掉一份 m 元素的哈希表（m = 入参元素数）与 m 次插入的 CPU；对 m=10^4 约省 1 次扩容 + 10^4 次哈希。
- **代价**：返回的视图不再持有入参快照，语义从「快照」变为「活视图」（需在 README 写明）；若调用方依赖「构造后入参变化不影响视图」则需要保留副本。
- **验证**：`cjpm bench -O2`，m = 1k / 1万 / 10万 下调用 `intersection` 并累加结果，对比改前后耗时与 `getAllocatedHeapSize()`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ConcurrentSkipListMap` 的每实例双 `ThreadLocal`（`findNodeCache` + `xorShiftState`）无清理入口

- **现状**：`ConcurrentSkipListMap.cj:104-106` 每个 map 实例各持一个 `ThreadLocal<FindNodeCache>`（两个 17 元素 `Option<Node>` 数组，`:89-90`）与一个 `ThreadLocal<XorShiftState>`；`ThreadLocal` 没有 `remove` API（std `core_package_classes.md:4064-4080` 只有 `get`/`set`/`getOrCompute`），线程侧的表项只能随线程结束回收。`f_rule` 的 `AlphaMemory`（`f_rule/src/rete/AlphaMemory.cj:43`）按字段维度创建多个 map，若按会话/规则集重建，长驻工作线程会为每个已废弃的 map 各留一份残留。
- **方案**：① 把两个 `ThreadLocal` 改成 `static`（按 `ConcurrentSkipListMap` 类型共享）+ 按 `map` 身份分槽（每线程一个 `HashMap<Int64, FindNodeCache>`，槽位在 map 销毁时不可回收，需配 `WeakRef` 键）；或 ② 更简单：`findNode` 改成局部数组（每次 2×17 引用分配），并把 `xorShift64` 的种子改成 `static` 的每线程状态（与 map 生命周期解耦）。方案 ② 只对「写操作」生效（`add`/`remove`/`replace`/`entryView`），`get`/`contains` 本来就不走 `findNode`（`:530-558` 自带下降循环）。
- **预期**：消除「每个存活线程 × 每个已创建 map」的 2 个 17 元素数组残留（每份约 0.3 KiB），并让 `effectiveMaxLevel` 之外的 map 生命周期不再影响线程侧内存。
- **代价**：方案 ② 会给每次写操作增加 2 次小数组分配（`findNode` 是写路径唯一分配点），可能抵消收益；方案 ① 需要 `WeakRef` + 清理逻辑，复杂度上升。
- **验证**：创建/丢弃 1000 个 map（每个 8 线程各做 100 次 `add`），在每轮结束后 `gc()` 再读 `getUsedHeapSize()` 与 RSS，对比当前实现是否随 map 数量单调上升。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单线程 `add` 722 ops/s（1.38 ms/op）不是环境噪声，而是存在 O(n) 级别的隐藏成本；同类 `get` 38,301 ops/s 也远低于一个 10k 元素跳表的预期 | `ConcurrentSkipListMap.cj:298-407`（`add`）、`:184-233`（`findNode`）；数据源 `doc/performance_report.md:24` | 函数级自耗时占比、调用路径、`-O2` 下的绝对值 | WSL Ubuntu 下 `cjpm bench -O2` 跑 10k 次 `add`（`perf_test.cj` 现为单轮、无预热），再 `cjprof record` 取 self time；同时把 `findNode` / `tryInsertAtLevel` / `randomLevel` 分段计时 |
| 2 | `findNode` 每层都 `ThreadLocal.getOrCompute` + `pred.next[level].load()`，是写路径的主要开销来源（每层至少 1 次 TLS 访问 + 1 次原子读） | `ConcurrentSkipListMap.cj:185-217` | 每层耗时与 TLS 命中率 | 在 `findNode` 内插桩统计循环层数与 `getOrCompute` 次数，配合 `cjprof` 看 `AtomicOptionReference.load` 的自耗时 |
| 3 | `AtomicOptionReference`（`Node.value` / `Node.next`）在高并发下比普通 `AtomicReference` 贵（每次 CAS 需要打包 `Option`），是「并发 add 7,443 ops/s」偏低的主因 | `ConcurrentSkipListMap.cj:28-29`、`:444-446` | 单次 `compareAndSwap` 的耗时与失败率 | 8 线程各写 1 万互不重叠的键，统计 CAS 失败次数 / 总 CAS 数，并与 `AtomicReference<Node>` 版实现对照 |
| 4 | `header` / `sub` 的全表扫描已在 `f_rule` 的区间查询中占可观比例 | `ConcurrentSkipListMap.cj:747-753`、`f_rule/src/rete/AlphaMemory.cj:154,218` | 该路径的调用次数与耗时占比 | 在 `header`/`sub` 加计数器，跑一次规则集匹配压测（1 万事实），统计调用次数与总耗时占比 |
| 5 | 每实例 `ThreadLocal` 在「map 反复创建 + 长驻线程」场景下造成 RSS 单调上升 | `ConcurrentSkipListMap.cj:104-106` | 多轮负载后的 `getAllocatedHeapSize()` / RSS | 1000 轮「建 map → 8 线程各 100 次 add → 丢弃」，每 100 轮 `gc()` 记录堆与 RSS |
| 6 | `Constants.get` 的字符串键（`TypeInfo.of<T>() + "-" + key`）在调用频次高时成为分配热点 | `Constants.cj:23` | 调用次数与每秒分配量 | 加计数埋点，跑 10 分钟稳态负载，`cjprof` 看 `String` 分配占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_concurrent/README.md` | .md | ✅ | 见 #14（`RateLimiter` 写成 `sealed`、`entryView` 返回值未写、两个迭代器类未登记）；`Executors`/`EventBus`/`SyncPriorityQueue` 段落属第 2 部分，未展开 |
| 2 | `f_concurrent/README_en.md` | .md | ✅ | 与中文版逐节对齐（384 行 vs 384 行），同样含 #14 三处；无额外偏差 |
| 3 | `f_concurrent/doc/performance_report.md` | .md | ✅ | 见 #13（3 轮平均 / 80,000 次插入 / Random 代码片段三处与实现不符）；`doc` 只有这一份 |
| 4 | `f_concurrent/src/AnyMomentRateLimiter.cj` | .cj | ✅ | 见 #21（参数校验异常类型）；信号量用 `ArrayBlockingQueue<Unit>` + `tryRemove` 语义正确 |
| 5 | `f_concurrent/src/AtomicInteger.cj` | .cj | ✅ | 见 #17（8 组重复）、#20（溢出语义）；8 个 `extend` 全部有实现，无遗漏方法 |
| 6 | `f_concurrent/src/ConcDict.cj` | .cj | ✅ | 接口 + 3 个默认实现；`addIfPreset` 命名（应为 `addIfPresent`）与 `removeIf(key,pred)` 返回值恒为 `None`（std `entryView` 返回最终值）见文末「范围外提示」 |
| 7 | `f_concurrent/src/ConcHashDict.cj` | .cj | ✅ | 见 #8（`toArray` 并发抛异常）、#16（`ConcDictView` 死代码）；`clear()` 只能逐键删（std `ConcurrentHashMap` 无 `clear`，已核对 API 清单），不判低效 |
| 8 | `f_concurrent/src/ConcurrentHashSet.cj` | .cj | ✅ | 见 #7（`==` 顺序依赖）、#19（同形循环）；`retain` / `retainAll` 同语义双入口见文末 |
| 9 | `f_concurrent/src/ConcurrentSkipListMap.cj` | .cj | ✅ | 见 #1 / #2 / #8 / #16 / #18 / #19；`isReachable` 与 `while(true)` 后的 `None<V>` 分别按死代码与「类型检查需要」处理 |
| 10 | `f_concurrent/src/ConcurrentSkipListMap_bug_test.cj` | .cj | ✅ | 见 #11（整文件 173 行全注释） |
| 11 | `f_concurrent/src/ConcurrentSkipListMap_conc_test.cj` | .cj | ✅ | 17 个并发用例；见 #12（`:734` 恒真断言、`:882-890` 一次提交 1 万个 `spawn`） |
| 12 | `f_concurrent/src/ConcurrentSkipListMap_perf_test.cj` | .cj | ✅ | 6 个「性能用例」实为 `@TestCase` + `println`，单轮无预热；见 #13 |
| 13 | `f_concurrent/src/ConcurrentSkipListMap_test.cj` | .cj | ✅ | 23 个单线程用例；见 #12（`@Assert(true)` 两处、`header/sub/toArray` 无覆盖） |
| 14 | `f_concurrent/src/Constants.cj` | .cj | ✅ | 见 #10（`fn` 在桶锁内执行）；`Constants` 全仓无调用方（对外可达，不判死代码） |
| 15 | `f_concurrent/src/DelayQueue.cj` | .cj | ✅ | 见 #3（唤醒/重查）、#9（无锁 `peek`）、#23（迭代器顺序）；`while(true)` 后的 `None<T>` 属类型检查需要 |
| 16 | `f_concurrent/src/Executor.cj` | .cj | ✅ | 见 #4（`maxQueueSize` 被忽略）、#5（shutdown 不退线程）、#6（共用 Condition）、#15（死字段） |
| 17 | `f_concurrent/src/Executor_pool_test.cj` | .cj | ✅ | 1 个用例（慢任务不阻塞其他 worker），确有并发断言，质量良好；`maxQueueSize` 未覆盖 |
| 18 | `f_concurrent/src/LeakingBucketRateLimiter.cj` | .cj | ✅ | 见 #22（`leaked` 跨周期不清零）；`Timer` 任务返回 `next` 即重排，符合 `fountain-baseline.md` §5，不误报 |

合计：`.cj` 15 个 / `.md` 3 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #1 / #2 / #3 / #7 / #8 / #20 / #22（7 条）；设计 #4（背压参数失效）、#6（锁粒度）（2 条）；可读性 #14 / #23（2 条）。语言特性：`Option` 可选链（`?[0]`、`?.value`）、`Box<V>` 包装、`ThreadLocal.getOrCompute`、`AtomicOptionReference` 均按 std 文档核对（`core_package_classes.md:4064`、`collection_concurrent_*`）。安全性：无 SQL / 路径 / 凭据 / 外部输入解析，仅 `Constants.get` 接受任意 `fn`（#10），未命中注入类 |
| §1 死代码 | 3 | 逐个 `private` / `internal` / 默认可见性符号搜引用（`private` 全仓、`internal` 本包及子包）：`isReachable`、`ConcDictView`（#16）、`Executor.result`（#15）无引用；`ConcurrentSkipListMap_bug_test.cj` 整文件注释（#11）。`while(true)` 之后的 `None<V>` / `None<T>`（`ConcurrentSkipListMap.cj:406,588,613,733,824,842,865`、`DelayQueue.cj:59,76`）是仓颉「函数体末表达式即返回值」所必需，**不判**死代码；`add()` 的两处 `physicallyRemove(活节点)` 因 `physicallyRemove:469-471` 对 `value.isSome()` 直接 `return` 而是 no-op（`:315`、`:331`），属冗余调用但保留重试语义，并入 #18 不计独立缺陷；`AddMode.==`、`helpPhysicallyRemove`、`findPredecessorAtLevel`、`maxChecker`、`filterIterator`、`SkipList*Collection`、`ConcurrentSkipListEntryViewImpl`、`ConcHashKey*`、`DelayQueueIterator`、`ConcurrentHashSetIterator`、`HashDictIterator`（`f_collection` 提供）均有调用方；`Constants.get` / `ConcDict` 默认方法 / `retain` / `subsetOf` 等对外可达 public 不判 |
| §2 重复逻辑 | 4 | 同文件两两比对 60+ 函数体：`AtomicInteger` 8 组 × 9 方法（#17）、`EntryIterator`/`TailEntryIterator` + `entryView` 双插入分支 + `remove` 骨架（#18）、`contains(all!)`/`add(all!)`/`remove(all!)` 跨 5 类型（#19）、`Atomic*` 的 8 组接口声明本身（并入 #17）。另核对：`ConcHashDict.keys()` vs `values()`（一个包 `ConcHashKeyCollection`、一个直接用 std 视图，语义不同不判）；`ConcurrentHashSet.retain(all!)` 与 `retainAll(values: Set<T>)` 同语义双入口（见文末范围外提示，差异是入参类型）；`ConcDict.addIfAbsent(key,fn)` 与 `computeIfAbsent`（不同模块、不同返回语义，不判） |
| §3 空实现 | 1 | #12 的 `@Assert(true)` 两处（占位断言，等于没有断言）。其余：`RateLimiter.close()` 默认空实现有注释说明「定时器型必须覆盖」（`RateLimiter.cj:29-34`，属 part2 文件，不判）；`DelayQueueIterator` 委托底层迭代器，非空实现 |
| §4 栈溢出 | 0 | 本部分无递归：`findNode` / `findPredecessorAtLevel` / `isReachable` / `EntryIterator` / `DelayQueue` 全部是显式循环；`ConcurrentSkipListMap` 的节点图虽有环（`Node.next` 可指回自身）但不做递归打印/深拷贝；`Constants.get` 的 `fn` 递归属调用方责任，不计 |
| §5 OOM | 2 | #5（`Executors` 每实例 N 条线程不回收）、#15（每个 `Executor` 白建 `ConcurrentHashMap`）。另核：`Executors` 默认 `executors=1024` ⇒ 1024 条线程（并入 #4 的默认值风险）；`ConcurrentSkipListMap` 无全局只增容器（`size_`/`epoch` 是标量），`DelayQueue` / `ConcHashDict` 的上界由使用者控制，无「按报文长度预分配」 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench -O2` 数据（`doc/performance_report.md` 是 cjc 1.1.0 + `--dy-std` + WSL2，且 #13 已证明与用例不符），全部降级为「待验证假设」1-6；不写成发现 |
| §6.2 大粒度锁 | 1 | #6（`Executor` 单个 `Mutex`+`Condition` 服务全部 future，`notifyAll` 惊群；临界区只有两次赋值，问题在「共享范围」而非持有时长）。#10 的桶锁内跑用户 `fn` 归在并发安全（死锁面），不重复计 |
| §6.3 并发串行 | 1 | #6：所有 `get()` 在途请求串在同一把锁上（并行度上限 = 1 个唤醒事件只能服务一个 future）；`Executors` 的 `executors[0]` 只用于建 future，任务仍由 N 条线程并行消费，**不判**形式并发 |
| §6.4 低效算法 | 0 | `header/sub` 的 O(n) 全表过滤复杂度可静态判定，但缺「耗时占比」数据 ⇒ 按规则写入优化方案（无基线）+ 假设 4，不计为发现。其余：`ConcHashDict.clear()` 逐键删是 std `ConcurrentHashMap` 无 `clear` 的必然选择（已核对 API 清单）；`toArray` 预分配不是平方级；无 `remove(at: 0)`、无双层循环匹配 |
| §7 降堆内存方案 | 1 | 优化方案「每实例双 `ThreadLocal`」（无基线）；另核 `toArray` 双份数组（#8 已在缺陷里给出修法，不重复列方案） |
| §8 降 CPU 方案 | 2 | `header/sub` 提前终止、`ConcurrentHashSet` 集合运算去副本（均无基线） |
| §9 local mode 可行性 | 0 | 候选全部逃逸：`findNode` 的 `FindResult`（含 `preds/succs` 数组）返回给调用方并跨函数使用（`add`/`remove`/`tailer`），`Node` 从 `add` 逃逸为 map 成员，`DelayQueue.remove` 返回 `T`，`Executors` 的 lambda 逃逸到队列。唯一函数内临时对象是 `Node.value` 的 `Box<V>`（被 `AtomicOptionReference` 存进节点 = 逃逸）。无 `--enable-local-mode` 编译的可行性 |
| §11 现有代码的 BUG（存量） | 10 | #1（size 负值/漂移）、#2（`entryView` 返回值）、#3（`DelayQueue` 唤醒）、#7（`==` 顺序）、#8（`toArray` 抛异常）、#9（无锁 `peek`）、#11（注释掉的回归用例）、#20（`addFetch` 溢出）、#21（异常类型）、#22（`leaked` 跨周期）。另核对了 `get()` 的下降循环边界、`findNode` 的 17 层数组下标（`MAX_LEVEL=16`，数组 17）、`tryInsertAtLevel` 的重试上界（3 次）、`physicallyRemove` 的 `node.level..=0` 下标、`removeIf` 的 `case None` 分支（`isHead` 已在上方 return，属防御性死分支，不判）、`ExecutorFuture.get` 的三条路径、`AnyMomentRateLimiter` 的 `finally` 归还许可、`Constants` 的 `TypeNotMatchException` 分支，均无缺陷 |
| §12 并发安全与锁粒度 | 5 | #1（`size_` 检查-然后-写入）、#3（条件等待未循环重查）、#6（锁粒度）、#9（部分方法无同步）、#10（锁内调外部回调）。已核：`ConcurrentSkipListMap` 的节点插入/删除是 CAS + 逻辑删除，无锁顺序问题（不存在两把锁）；`LeakingBucketRateLimiter` 用 `AtomicInt64` + 独立 `Timer` 线程 + `ArrayBlockingQueue`，`timer` 只在构造期写、`close()` 只读，无可见性问题；`DelayQueue` 的 `mutex`/`remCond` 使用正确（除 #3）；`ConcurrentHashSet` 全部委托 std 并发容器，无复合操作（`add`/`remove` 的返回值即 std 的原子结果） |
| §14 功能完备性与 README 覆盖 | 2 | #12（5 个 public 类型与 3 个方法零用例）、#14（两个 public 迭代器类未进 README、`Executors` 的 `maxQueueSize` 无文档）。逐项对照：`ConcDict` / `ConcHashDict` / `ConcurrentHashSet` / `ConcurrentSkipListMap` / `DelayQueue` / `Delayed` / `Constants` / `RateLimiter`+4 个实现（本部分 2 个）/ `Executors`/`Executor`/`ExecutorFuture` 均在 README 或「其他公开 API」清单中出现；`Executors` 的两个构造参数（`executors` / `maxQueueSize`）只写了「`Executors(n)` 创建」，`maxQueueSize` 完全没提（#4 的功能面） |
| 文件覆盖（§13 等） | 18/18 | 无缺文件；`.md` 三份按 §13 逐段核对（#13 / #14），`doc/performance_report.md` 的 6 张表逐行比对过用例代码 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 11 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分（`f_concurrent` 的并发容器与线程池层，15 个 `.cj`）的**无锁数据结构功底是够的**：`ConcurrentSkipListMap` 的 CAS 插入、逻辑删除 + 物理清理、每层前驱缓存、`ThreadLocal` 随机源、`epoch` 代际这些手段都用对了方向，`Executor_pool_test` 那条「慢任务不阻塞其他 worker」的用例也说明线程池曾经被认真修过（`ExecutorFuture.get` 里的两段注释就是修复痕迹）。风险不在「不懂并发」，而在**边界与契约**：

- 阻塞项（建议先修）：**#1 `size_` 重复扣减**。#1 让一个公开容器的 `size` 可能为负，并直接打穿 `toArray()`；它的回归用例（`bug_test` 里的用例44）被整体注释掉（#11），等于把这个已知缺陷从 CI 移走。修 #1 时必须同时恢复 200 线程的 size 一致性用例。
- 次阻塞项：**#2 `entryView` 返回值违反 `ConcurrentMap` 契约**。这是一个「看起来能用、拿返回值就错」的接口：更新返回旧值、删除返回旧值，而且 `(K,?V)->?V` 重载在插入/更新两条路径上返回值语义还不一致。外部使用者按 std 文档写代码必踩。
- 并发正确性排期项：**#3 `DelayQueue`**（条件变量没通知、唤醒不复核，延迟队列退化成「先弹先等」）、**#9**（`peek/size/isEmpty` 读堆中间态）、**#6**（所有 future 共用一把锁 + `notifyAll` 惊群）。这三条都在 `f_net` / `f_rpc` 的请求路径或计划中的延迟任务路径上，但都能用几十行改完。
- 线程池资源项：**#4 / #5** 是同一处代码的两个面——`maxQueueSize` 没接上（背压失效）、`shutdown` 退不掉线程（线程泄漏）。`f_net/src/server/server.cj:46` 明确传了 `maxQueueSize: 1`，参数却在实现里被丢掉，值得优先核一遍服务端的积压上限到底是多少。
- 可维护性：#15–#19 是「死字段 / 死函数 / 8 组复制 / 3 处同构 / 5 处同形循环」。它们不改变行为，但 #20 已经证明复制会带来一致性的错误（8 组 `addFetch` 一起错），建议随修 #1/#2 一起收口。
- 文档与测试：#13 的 `performance_report.md` 是后续所有性能工作的「改前基线」，现在三处与实现不符（3 轮平均 / 80,000 次插入 / Random 代码片段），建议在补数据前先改口径；#12 的零覆盖类型（`DelayQueue`、`ConcDict`、`ConcHashDict`、`ConcurrentHashSet`、`Constants`）至少各补一条能抓住本轮发现的最小用例。
- 已确认**没有**的问题：死锁（无多锁顺序、无锁内 `spawn().get()`）、栈溢出（无递归）、按不可信长度预分配（无）、`Timer` 语义误用（`LeakingBucketRateLimiter` 返回 `next` 即重排，符合基线 §5）、`ConcurrentSkipListMap` 的节点插入/删除无锁竞争窗口的结构性缺陷（层数/前驱缓存的数组下标都核对过）。
- 性能结论：本部分**没有可用的改前基线**（`perf_test` 是单轮、无 `-O2`、`cjc 1.1.0`，且 #13 证明与文档描述不符）。文档记录的 722 ops/s 单线程插入异常低，必须先按待验证假设 1/2/3 补 `cjprof` 数据，才能判定 `findNode`/`AtomicOptionReference` 是否是瓶颈；在此之前不做任何性能结论。

存量缺陷共 23 条（严重 2 / 一般 11 / 轻微 10），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

---

## 范围外提示（不计入统计）

- `RateLimiter` 的 `sealed` 声明不符（#14 ①）与 `close()` 默认空实现位于 `src/RateLimiter.cj`（第 2 部分文件），本轮只按 README 侧登记，实现细节留给第 2 部分。
- `ConcDict.removeIf(key, predicate): ?V` 的默认实现（`ConcDict.cj:148-156`）返回 `entryView` 的结果；std `entryView` 返回「最终值」，删除后即 `None` ⇒ 该重载**永远拿不到被删掉的值**。这是接口默认实现与 `?V` 签名的意图冲突，但影响面仅限「返回值无用」，留给第 2 部分与 `ConcHashDict` 一并定夺。
- `ConcurrentHashSet` 同时提供 `retain(all!: Set<T>)`（`ConcurrentHashSet.cj:73`）与 `retainAll(values: Set<T>)`（`:100`）两个同语义入口，建议后续收敛为一个（接口要求的方法名保留）。
- `ConcDict.addIfPreset`（`ConcDict.cj:139`）应为 `addIfPresent`（拼写），属对外 API 命名，需用户拍板是否改名。
