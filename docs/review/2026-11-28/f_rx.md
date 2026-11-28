# f_rx 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_rx`（12 个 `.cj` + 2 个 `.md`，共 2232 行）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 可比；`git blame` 抽查的源码行与 README 行均落在 `4be871f2f` 2026-10-02 及更早的 `ab8722d1f` 2025-07-13，全部记为存量）
- **审查重点**：响应式流语义、背压与有界性、并发安全、栈溢出、死代码、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

> 索引：#1 `AsyncObserver` 排空线程生命周期 ／ #2 `Emitter` 生产者异常被吞 ／ #3 调度线程完成后退出 ／ #4 默认队列无界、背压不触发 ／ #5 `isDisposed` getter 副作用 ／ #6 公开类构造函数缺省 `internal` ／ #7 满队列判定竞态 ／ #8 `wrapper` 跨线程可见性 ／ #9 回调异常广播且不终止 ／ #10 `QueuedCache` 锁内回调 ／ #11 `immediately` 无同步 ／ #12 错误恢复 `getOrThrow` ／ #13 `withAlwaysNew` 无界 `spawn` ／ #14 README 与实现不符 ／ #15 README 覆盖缺失 ／ #16 `CombinedObserverPolicy` 未接线 ／ #17 `clone` 重复 ／ #18 未使用导入 ／ #19 注释与实现相反 ／ #20 空实现无说明 ／ #21 参数校验缺失 ／ #22 测试靠固定 sleep。

### [严重][存量] #1 `AsyncObserver` 排空线程在空闲 100ms 或回调异常后永久退出，此后 `onNext` 阻塞、终态丢失

- **位置**：`f_rx/src/Observer.cj:229`（排空循环 234–247，`onNext` 249–251）；`asyncCombined: true` 时由 `f_rx/src/Observer.cj:140` 为每个观察者包一层
- **来源**：存量（`git blame -L 229,258` → `4be871f2fd`，2026-10-02；快照模式无 diff 基线）
- **判据**：review-checklist §12.1（异步语义 / 有界性）+ §11（资源与错误处理不对称）
- **证据**：静态确定 —— 排空循环的条件是 `e.load().isNone() && !c.load() && let Some(d) <- q.remove(100ms)`，队列一旦空闲 100ms，`remove` 返回 `None`，`let Some(d)` 模式不匹配即退出循环，**线程随后自然结束**；`q` 是 `ArrayBlockingQueue<T>(1)`，而 std 文档明确 `ArrayBlockingQueue.add` 在队列满时阻塞（`std.collection_concurrent` 类表，本机文档 `md/doc/cjapi/concurrent_collection.md:100-121`）。线程退出后：第 1 条新数据占满队列且永不被取走，第 2 条数据起 `q.add` 永久阻塞调用方；`c.store(true)` / `e.store(ex)` 不再有任何线程读取，`onComplete` / `onError` 永久不投递。同一循环内 `observer.onNext(d)` 未包 try/catch，回调抛异常会让 `spawn` 线程直接结束，异常只落在无人 `get()` 的 `Future` 里，后续 `onNext` 同样阻塞。
- **描述**：`Observable.iterable(items, asyncCombined: true)`（README.md:72 明确宣传的能力）只在"数据间隔 < 100ms 且单次回调不抛异常"时可用。任何空闲间隔（最常见：用户思考、IO 等待、下游限速）都会让该观察者静默失活：数据丢 1 条、调用线程挂死、完成事件永不到达。`testMultiAsyncObserver`（`f_rx/src/rxcj_test.cj:303`）三条数据连续投递，正好绕开了这个窗口，因此测试是绿的。
- **建议**：排空线程不要以"队列空闲"为退出条件——`q.remove()` 去掉超时，用哨兵状态（`OnComplete` / `OnError` 直接入队，而不是 `AtomicBool` 旁路）唤醒线程并退出；`ArrayBlockingQueue(1)` 换成有界队列 + 明确背压策略（丢弃/阻塞/抛错），并给 `onNext` 一个"消费者已死"的失败路径（抛 `IllegalStateException` 或返回 `Bool`）。回调一律包 try/catch，异常转成 `onError` 后再退出。补一条"投递 1 条 → sleep 300ms → 再投递 2 条"的用例。

### [严重][存量] #2 `Emitter` 的生产者闭包异常被 `spawn` 的 `Future` 吞掉，`next()` 无超时阻塞

- **位置**：`f_rx/src/Emitter.cj:33`（`f = spawn { fn(this) }` 在 36–40，`q.remove()` 在 41）
- **来源**：存量（`git blame -L 33,48` → `4be871f2fd`）
- **判据**：review-checklist §11（错误处理静默 / 失败路径当成功）+ §12.1（`Future` 异常被吞）
- **证据**：静态确定 —— `spawn` 的返回值被存进 `private var f` 后，全文件只有 `f.isNone()` 一处读取（`Emitter.cj:36`），从不 `get()`；std 文档说明 `spawn` 的异常归属其 `Future`（`md/doc/cj_syntax.md:918-929`、`Future` 类文档 `core_package_classes.md:577`）。`next()` 里 `match(q.remove())` 是**无超时**的阻塞出队（`LinkedBlockingQueue.remove()`，见 `md/doc/cjapi/concurrent_collection.md:131-160`）。
- **描述**：`Observable.emitter{ emitter => ... }` 的闭包只要在 `onNext` 之外抛异常（空指针、解析失败、`bufSize` 不足导致 `onError` 之前退出），消费端就永远停在 `q.remove()`：既没有异常，也没有完成事件，线程无法回收。`onNext` 侧若 `q.add` 因队列满而阻塞（默认 `bufSize=1`），生产者线程同样挂死，且没有任何超时/取消手段。
- **建议**：把 `f` 的异常纳入数据流——例如再起一个 `spawn { try { fn(this) } catch (e) { q.add(Ex(e)) } }`，或在 `next()` 阻塞前用 `f.get(timeout)` 探活；`q.remove()` 换成带超时的 `remove(timeout)`，超时时检查 `f` 是否已完成并抛 `SpawnException`。同时把"`onNext` 必须在与 `next()` 不同的线程调用"（`Emitter.cj:22-24` 的注释）写进 README。

### [严重][存量] #3 `SingleScheduler` / `FixedScheduler` 排空线程在完成或异常后永久退出，重启后数据只入队无人消费

- **位置**：`f_rx/src/Scheduler.cj:140`（`spawn` 体 141–203；单线程完成分支 156–159；毒丸分支 162–171；`catch` 200–202）
- **来源**：存量（`git blame -L 140,203` → `4be871f2fd`）
- **判据**：review-checklist §11（资源不对称 / 契约与实现不符）+ §5（无界容器只增不减）
- **证据**：静态确定 —— 单线程收到 `Item(None)` 时执行 `onComplete(); return false`，外层 `if (!exec(state, false)) { return }` 结束 `spawn` 闭包，消费线程结束；`FixedScheduler` 的毒丸分支对**每个** worker 都 `return false`，即所有 worker 一起结束。而 `schedule(state)`（`Scheduler.cj:212-218`）之后仍会照常 `queue.add`，队列默认无界（`LinkedBlockingQueue()`，容量 `Int64.Max`）。
- **描述**：README.md:66-68 明确承诺"没有观察者时暂停，注册新观察者并重新调用启动函数即可继续"，`Observable.subscribe` 也确实把 `disposed_` 复位（`Observable.cj:219/229/239`）。但 `pause(completion: true)` 会先经 `isDisposed` 发一次终态（见 #5），消费线程随即退出；用户再 `subscribe` + `immediately()` 时，`this.iterator` 仍是原迭代器，剩余数据被 `queue.add` 收下但**没有消费者**：数据静默丢失，队列无界增长直到 OOM。`FixedScheduler` 下毒丸会让全部线程退出，问题更彻底。`catch` 分支（200–202）同样只 `onError` 一次就结束线程，后续数据也只进不出。
- **建议**：调度器的生命周期应与 `Observable` 的 `disposed_` 解耦——收到终态后不退出线程，改为"终止标记 + 继续阻塞出队"，由显式 `close()`/`disposeAll()` 或被 GC 时退出；或让 `schedule` 在消费者已终止时直接 `onError` 并拒绝入队。`pause` 后的"重启"必须重建调度器和迭代器，而不是复用已死的实例。

### [严重][存量] #4 `withSingle(policy:)` / `withFixed(threads:policy:)` 默认队列无界，背压策略永不触发且无拒绝路径

- **位置**：`f_rx/src/Scheduler.cj:209`（无 `queueSize` 的 `SingleScheduler`，`LinkedBlockingQueue()`）、`f_rx/src/Scheduler.cj:264`（`FixedScheduler` 同）、入口 `f_rx/src/Observable.cj:266`、`f_rx/src/Observable.cj:273`
- **来源**：存量（`git blame -L 206,218` → `4be871f2fd`）
- **判据**：review-checklist §5（无界容器 / 没有拒绝路径）+ §12.1（有界性）
- **证据**：静态确定 —— `LinkedBlockingQueue()` 的默认容量是 `Int64.Max`（std 文档 `md/doc/cjapi/concurrent_collection.md:131-145`），而 `schedule(state)` 的判定是 `if (queue.size < queue.capacity)`（`Scheduler.cj:213`），容量恒大于 `size`，因此 `else` 分支（背压策略）在这两个重载下**永远走不到**。
- **描述**：README.md:93-113 把背压策略当作模块核心能力，但默认入口 `withSingle()` / `withFixed(threads)`（`policy` 只是可选参数）实际是无界缓冲：生产快于消费时只会在 `queue.size` 上单调增长，没有任何丢弃/阻塞/抛错，也没有上限配置，最终 OOM。用户以为指定了 `Discarding()` / `Throwing()` 就有了保护，实际完全无效——这是"承诺了但实现为空"的典型。`withSingle(queueSize:)` / `withFixed(threads:queueSize:)` 才有边界。
- **建议**：给无 `queueSize` 的重载一个有限默认值（例如 1024）并写进 README，或直接删除这两个重载，强制用户显式选择容量；`schedule` 的容量判定改为 `tryAdd` 的返回值（见 #7），不要先读 `size` 再 `add`。

### [严重][存量] #5 `isDisposed` 属性 getter 有发送副作用：每次读取都再发一次 `onComplete`

- **位置**：`f_rx/src/Observable.cj:379`（getter 380–388，`scheduler.schedule(None<T>)` 在 383）
- **来源**：存量（`git blame -L 379,389` → `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现 / 语义与命名不符）+ §12.1（异步语义）
- **证据**：静态确定 —— getter 在 `disposed_.load() && completionOnDisposing.load()` 时执行 `scheduler.schedule(None<T>)`，没有任何"只发一次"的标记；`completionOnDisposing` 由 `pause(completion: true)` 置位后一直为 `true`（`Observable.cj:397`），因此**每次**读 `isDisposed` 都会排入一个新的 `Item(None)`，单线程调度器每次都会调 `observer.onComplete()`。
- **描述**：`isDisposed` 从名字与文档（`Observable.cj:376-378` "判断是否取消"）看是纯查询，实际是"发完成事件"的动作。用户写 `while (!o.isDisposed) { ... }` 轮询，会在每次迭代都向所有观察者投一次 `onComplete`——观察者收到多次终态事件（违反 Rx 至多一次终态的语义），单线程调度器的队列也随之无界增长。反过来，只调 `pause(completion: true)` 而不读 `isDisposed` 时，完成事件永远不会发出，与 README.md:66-67 的"completion 决定是否发送完成事件"不符。
- **建议**：把发送动作移出 getter——`pause(completion)` 直接 `scheduler.schedule(None)` 一次并用 `AtomicBool` 保证幂等；`isDisposed` 只返回状态。若为兼容必须保留延迟发送，至少加 `completionSent` 一次性标记。

### [严重][存量] #6 `FuncObserver` / `CombinedObserver` 的主构造函数缺省为 `internal`，模块外无法构造（README 主示例因此不可用）

- **位置**：`f_rx/src/Observer.cj:42`（`FuncObserver(let name: String){}`）、`f_rx/src/Observer.cj:94`（`CombinedObserver(private let async!: Bool = false){}`）；契约源 `f_rx/README.md:5`、`:124-133`
- **来源**：存量（`git blame -L 42,42` / `-L 94,94` → `4be871f2fd`）
- **判据**：review-checklist §14（承诺的能力外部不可用）+ §13（文档与实现不符）
- **证据**：静态确定 —— 语言文档明确"对于 `class` 的成员（包括成员变量、成员属性、构造函数、成员函数）……缺省的含义是 `internal`"，且示例中主构造函数都显式写 `public`（`md/doc/doc/cangjie_docs-main-docs/docs/dev-guide/source_zh_cn/class_and_interface/class.md:363-378`、`:162-176`）。这两个类型是 `public class`，但仓内/仓外检索不到任何 `public` 构造函数声明；`f_rx` 仅通过 `src/rx/rx.cj:18` 的 `public import fountain::f_rx.*` 对外暴露，没有额外包装。
- **描述**：下游项目按 README 写 `FuncObserver<Int64>('name').setNext{...}` 会撞上"构造函数不可见"；`CombinedObserver` 同理，README.md:158 把它列为公开 API 却无法实例化。唯一对外可用的订阅路径是 `Observable.subscribe(name: String, creator: (FuncObserver<T>) -> Unit)`（`Observable.cj:213`，闭包内拿到已构造的实例），但 README 从头到尾**没有提到**这个重载，等于把唯一可用的入口藏起来了。
- **建议**：把两个主构造函数改成 `public FuncObserver(let name: String)` / `public CombinedObserver(...)`；若刻意不开放 `CombinedObserver`，就把它从 README 的公开 API 列表移除。同时在 README 的"注册观察者"补 `subscribe(name) { ob => ob.setNext{...} }` 的示例。

### [一般][存量] #7 满队列判定是"读 size 再 add"的检查-然后-写入，`ToDropOldest` 的 remove+add 亦非原子

- **位置**：`f_rx/src/Scheduler.cj:212`（判定 213，`queue.add` 214，`policy.schedule` 216）；`f_rx/src/BackPressure.cj:62`（`tryRemove()` 64 + `add(state)` 65）
- **来源**：存量（`git blame -L 206,218` / `-L 62,66` → `4be871f2fd`）
- **判据**：review-checklist §12.1（检查-然后-写入；容器线程安全不代表组合操作原子）+ §6.2 表（并发容器当复合操作原子）
- **证据**：静态确定 —— `LinkedBlockingQueue.size` 明确"不保证并发原子性"（`md/doc/cjapi/concurrent_collection.md:137`），两个生产者可以同时读到 `size < capacity` 并都执行 `add`，其中一个在 `add` 上永久阻塞（`add` 满时阻塞）；`ToDropOldest` 的 `tryRemove` 成功后队列可能已被另一个生产者填满，紧接着的 `add` 同样阻塞，或者 `tryRemove` 返回 `None` 时 `add` 直接阻塞——"丢最旧"退化成"卡住生产者"。另外 `tryRemove` 无差别丢弃队首状态，若队首是 `Item(None)` 或 `Poison`，终态事件会丢失（该分支触发概率低，**待确认**是否需要防护）。
- **描述**：`Discarding` / `Throwing` 的语义是"队列满时丢弃/抛错"，实际在并发竞争下会变成"无限阻塞"，与文档承诺相反；`AlwaysBlocking` 与 `ToDropOldest` 则可能在错误的时机阻塞。这三个策略都在生产主路径上。
- **建议**：用 `tryAdd` 的返回值做唯一判定（`if (!queue.tryAdd(state)) { policy.schedule(state) }`），彻底去掉 `size`/`capacity` 读取；`ToDropOldest` 改为"`tryAdd` 失败 → `tryRemove` → 再 `tryAdd`"，并跳过 `Item(None)`/`Poison`（先 `peek` 判断状态类型再决定是否丢弃）。

### [一般][存量] #8 `SingleScheduler.wrapper` 是普通 `var`，构造线程写、消费线程读，无任何同步；构造期还把 `this` 发布给策略对象并起线程

- **位置**：`f_rx/src/Scheduler.cj:135`（`var wrapper`）、`:149`（消费线程读）、`:260`（`FixedScheduler` 构造中写）；发布点在 `:139-140`
- **来源**：存量（`git blame -L 134,140` / `-L 255,262` → `4be871f2fd`）
- **判据**：review-checklist §12.1（可见性 / 发布逸出）
- **证据**：静态确定 —— `wrapper` 没有 `Atomic*` 也没有在锁内读写；`SingleScheduler` 构造函数先 `policy.scheduler = this`（把 `this` 交给外部可变对象），再 `spawn` 启动消费线程，而 `wrapper` 要等 `FixedScheduler` 构造完成（`Scheduler.cj:259-261`）才被赋值。消费线程读 `wrapper` 时没有任何 happens-before 保证，可能读到 `None` 并走"当前是单线程调度器立即结束"分支（`:156-158`），把固定线程池误判为单线程。
- **描述**：这是典型的"构造未完成就发布 `this`"+ 普通字段跨线程通信。当前只在"构造后立刻就有数据到达"时才会命中，但 `Observable` 的 `immediately()` 与 `withFixed()` 可以在不同线程先后调用（先 `withFixed` 再 `immediately` 通常安全，反过来不安全），因此是真实可触发的竞态，且后果是固定线程数退化为 1 个线程且不广播毒丸。
- **建议**：`wrapper` 改成 `AtomicOptionReference<FixedScheduler<T>>` 或构造完再启动消费线程（`FixedScheduler` 统一 `start()` 所有 worker）；构造期不要先把 `this` 交给 `policy`，改为 `start()` 里赋值。

### [一般][存量] #9 观察者回调抛异常被转换成 `onError` 广播给所有观察者，且流继续投递后续数据

- **位置**：`f_rx/src/Observer.cj:207`（`onNext` 209–214，`onError` 216–218）、`f_rx/src/Scheduler.cj:112`（`CurrentScheduler` 119–121）、`f_rx/src/Observer.cj:219`（`onComplete` 同理）
- **来源**：存量（`git blame -L 207,227` → `4be871f2fd`）
- **判据**：review-checklist §11（契约与实现：终态唯一、错误隔离）+ §10（正确性）
- **证据**：静态确定 —— `CombinedObserver.onNext` 的 `catch` 调用的是 `this.onError(e)`，而 `onError` 走 `call{o => o.onError(ex)}`，即把某一个观察者的异常**广播**给全部观察者；`catch` 结束后 `call` 的 `for` 循环继续处理下一个观察者，`Observable.immediately` 的 `while` 也继续取下一项。
- **描述**：Rx 语义里 `onError` 是终态、且错误应只影响出错的那条订阅。当前实现有两个后果：① 一个下游的 bug 会让**所有**订阅者收到 `onError`（健康的订阅者被迫终止/误判）；② 收到 `onError` 之后还继续收到 `onNext` 与下一次 `onComplete`，观察者若按"终态后不再处理"实现，会丢数据或抛异常。`withCurrent` 下同样（`Scheduler.cj:119-121`）。
- **建议**：`CombinedObserver` 层不要兜底捕获并广播——`onNext` 的异常应交给该观察者自己的 `onError`（`FuncObserver` 已经这样做了），或记录后仅终止该观察者（`remove(name)`）；若确实要全局终止，则必须置 `disposed_` 并停止后续投递，保证"终态之后不再有事件"。

### [一般][存量] #10 `QueuedCache.replay` 持锁调用外部回调；`Cache.iterator()` 在锁外创建非线程安全的 `LinkedList` 迭代器

- **位置**：`f_rx/src/Cache.cj:57`（`synchronized` 58–63，`observer.onNext` 60）、`f_rx/src/Cache.cj:46`（`iterator()` 47 在锁外取 `queue.iterator()`，`next()` 70–76 才加锁）
- **来源**：存量（`git blame -L 57,63` → `4be871f2fd`）
- **判据**：review-checklist §6.2 / §12.2（锁内做 O(输入) 工作、锁内调用外部回调）+ §12.1（迭代与修改并发）
- **证据**：静态确定 —— `replay` 在持锁状态下遍历整个缓存（最大 `capacity` 条）并逐条调用用户回调 `observer.onNext`；`Cache.iterator()` 返回的 `CacheIterator` 在**构造时**（锁外）持有 `queue.iterator()`，而 `set`（`Cache.cj:49-56`）会在锁内 `removeFirst`/`addLast` 修改同一个 `LinkedList`。std 文档说明 `LinkedList` 的迭代在检测到并发修改时会抛 `ConcurrentModificationException`（`collection_package_class.md:10135` 等）。
- **描述**：`replaySize(capacity)` 后晚注册的观察者，其回调在缓存锁内执行：回调只要稍慢（写日志、IO、再订阅），所有生产者的 `cache.set` 全部被阻塞，`immediately` 主循环停摆；若回调里再操作同一 `Observable`（`subscribe` → `replayCached` → `cache.replay`），`Mutex` 是可重入的（`sync_package_classes.md:8919-8930`）不会立刻死锁，但会递归重放、重复投递缓存。`Cache.iterator()` 是公开 API，外部并发 `set` + 遍历是数据竞争，可能抛 `ConcurrentModificationException` 或读到错乱序列。
- **建议**：`replay` 先在锁内把缓存复制成 `Array<T>` 快照，出锁后再逐条 `onNext`，最后在锁内 `fn()`（注册）——保证"重放 + 注册"相对 `set` 原子，同时回调不持锁；`iterator()` 要么整体加锁复制快照（`Array` 迭代器），要么文档声明"仅单线程使用"并去掉误导性的 `Mutex`。

### [一般][存量] #11 `Observable.immediately` 的迭代器惰性赋值与 `scheduler` 替换都没有同步，重启或并发启动会重复消费

- **位置**：`f_rx/src/Observable.cj:442`（`itr` 计算 447–453，循环 454–464）、`f_rx/src/Observable.cj:245-283`（`withCurrent/withAlwaysNew/withSingle/withFixed` 直接替换 `this.scheduler`）
- **来源**：存量（`git blame -L 442,464` → `4be871f2fd`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）+ §10（设计一致性）
- **证据**：静态确定 —— `this.iterator` 是普通 `var`，`if (let Some(i) <- this.iterator) { i } else { let it = this.items(); this.iterator = it; it }` 是典型 check-then-write；`scheduler` 也是普通 `var`，`withSingle()` 等在运行期替换它。同文件里 `disposed_` 用 `AtomicBool`、观察者表用 `ConcurrentHashMap`，说明作者已经考虑了并发，但这两个字段没有。两个线程同时进入 `immediately()` 会各自 `items()` 出独立迭代器，同一份数据被两条流水线重复投递。
- **描述**：README.md:66-68 的"重新调用启动函数"场景天然可能出现"旧 `immediately` 尚未退出、新 `immediately` 已启动"（旧的在等 `itr.next()` 阻塞）；`defer()` 走 `Timer` 线程、`immediately()` 走调用线程，二者可以重叠。后果是重复投递 / 数据交叉 / 完成事件提前。该类没有声明线程安全，但也没有任何"单线程使用"的文档约束。
- **建议**：用一个 `AtomicBool running` 做互斥（重入时直接返回或抛 `IllegalStateException`），`iterator` 与 `scheduler` 要么在启动时一次性快照到局部变量，要么用 `AtomicOptionReference`/不可变配置对象；README 明确"一个 `Observable` 实例只允许一个启动线程"。

### [一般][存量] #12 错误恢复路径 `this.iterator.getOrThrow()` 在 `items()` 自身失败时抛 `OptionException`，覆盖原异常并中断恢复

- **位置**：`f_rx/src/Observable.cj:350`（恢复器 351–359，`getOrThrow` 357）、`:365`（368 同）
- **来源**：存量（`git blame -L 350,375` → `4be871f2fd`）
- **判据**：review-checklist §11（空值未处理 / 错误处理缺失）+ §10（异常路径）
- **证据**：静态确定 —— `this.iterator` 只在 `immediately` 的 `else` 分支里赋值（`Observable.cj:450-452`），且赋值发生在 `this.items()` **成功返回之后**；若 `items()` 本身抛异常（`iterable` 的 `Future.get()`、`single` 的 `item()` 都可能），`iterator` 仍是 `None`，此时错误恢复器执行 `this.iterator.getOrThrow()` 抛 `OptionException`，从 `catch` 块内逸出。
- **描述**：`setErrorResumer(resumeWithEmpty: false, ...)` / `setErrorResumer(resumeIfFalse: ...)` 的语义是"用当前迭代器继续"，但在"第一次建立迭代器就失败"这种最常见的场景下必然抛 `OptionException`，原始异常丢失，`defer()` 路径上还会让 `Timer` 静默失效（`Timer` 文档：Task 有未捕获异常即失效）。
- **建议**：改为 `this.iterator` 为 `None` 时回退到 `this.items()`（重新建立），并把这个选择写进注释；恢复器整体包 try/catch，恢复失败时保留原异常作为 `cause` 上抛；或在 `immediately` 的 `catch` 里先尝试补建 `iterator` 再调恢复器。

### [一般][存量] #13 `withAlwaysNew()` 每条数据 `spawn` 一个线程，无上限、无背压

- **位置**：`f_rx/src/Scheduler.cj:88`（`AlwaysNewScheduler.schedule` 的 `spawn` 89–99，`schedule(ex)` 101–105）
- **来源**：存量（`git blame -L 84,105` → `4be871f2fd`）
- **判据**：review-checklist §5（一次提交全量任务 / 无界线程）+ §12.1（有界性）
- **证据**：静态确定 —— 每处理一个 `item` 就 `spawn` 一个新线程，没有任何并发上限或队列；N 条数据（`Observable.iterable` 可以是任意长度的 `Iterable`）会在消费速度跟不上时同时存在 O(N) 个线程。具体线程栈占用与可承受 N 未测（**待验证假设** #2），但"没有上限"本身是代码事实。
- **描述**：README.md:75-76 明确宣传"总是使用新线程处理每条数据"，`testAlwaysNewAndImmediately` 也用线程数做断言（`rxcj_test.cj:254`）。对高频事件流，这是"线程数随数据量增长"的 OOM/调度退化路径；对低频事件则只是浪费。文档没有提示适用边界。
- **建议**：保留语义的同时加一个上限（例如复用 `f_concurrent` 的线程池，或 `Semaphore` 限流到 K 个在飞任务）；README 补一句"仅适用于低频事件，高频请用 `withFixed`"。

### [一般][存量] #14 README 与实现不符：示例不可编译、`dispose(completion)` 不存在、`disposed_` 语义写反、`setErrorResumer` 签名错、重放说成"异步"

- **位置**：`f_rx/README.md:5`、`:10-11`、`:54`、`:91`、`:141-145`、`:150`（`f_rx/README_en.md` 逐行同构，问题相同）
- **来源**：存量（`git blame -L 1,12 -- f_rx/README.md` → `4be871f2fd`）
- **判据**：review-checklist §13（示例代码不能用 / API 与源码不符 / 文档过期）
- **证据**：静态确定，逐条对照：① `README.md:5` 的 `FuncObserver<Int64>()` 既缺必填的 `name`（`Observer.cj:42` 无默认值），构造函数又不可见（#6）；② `:10` "disposed_ 是 false 的立即结束"与 `Observable.cj:381`（`if (disposed_.load())` 才结束）相反；③ `:54` / `:91` 列出的 `dispose(completion)` 单参重载不存在，实际是 `disposeAll(completion!)`（`Observable.cj:407`）或 `dispose<O>(completion!)`（`:435`）；④ `:141` 把 `private func setErrorResumer(resumer: (Exception) -> ?Iterable<T>)`（`Observable.cj:295`）写成 `public`，`:143` 的 `(Exception) -> Unit` 重载实际签名是 `(resumeWithEmpty: Bool, resumer: (Exception) -> Unit)`（`:350`）；⑤ `:150` 说"异步重放"，实现是在 `subscribe` 的调用线程里同步 `cache.replay`（`Observable.cj:207-209`、`Cache.cj:57-64`）。
- **描述**：README 是模块唯一的对外文档，这 5 处覆盖了"快速开始、暂停/停止、错误恢复、重放"四个核心段落，按文档写代码会直接编译失败或得到相反行为。中英文两版内容一致，说明是同一次编写留下的问题，不是翻译漂移。
- **建议**：按上面 5 条逐条改：示例改成 `subscribe('test') { ob => ob.setNext{ v => println(v) } }`；`disposed_` 描述改为"true 时立即结束"；`dispose(completion)` 改为 `disposeAll(completion!)`；删除 private 的 `setErrorResumer` 重载并补全 `resumeWithEmpty` 参数；"异步重放"改为"在订阅线程同步重放"。

### [一般][存量] #15 README 覆盖缺失：唯一可用的订阅入口、`Emitter` 线程约束、背压策略清单与多个公开类型的语义都没写

- **位置**：`f_rx/README.md:47-52`（注册观察者）、`:93-113`（背压列表）、`:154-165`（"其他公开 API"仅列名）；`f_rx/README_en.md` 同构
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 缺关键段落 / 索引未登记）
- **证据**：静态确定 —— 逐符号核对：① `Observable.subscribe(name: String, creator: (FuncObserver<T>) -> Unit)`（`Observable.cj:213`）README 全文检索不到，而它是外部唯一能构造 `FuncObserver` 的路径（#6）；② `Emitter` 的"`on*` 必须与 `next()` 不同线程"只写在源码注释（`Emitter.cj:22-24`），README 的 emitter 段落（`:20-28`）没有任何约束说明，且 `bufSize` 参数、队列满会阻塞生产者都没提；③ 背压列表编号为 1、2、3、7、8、9、10、11（缺 4-6），且**漏掉了** `RateLimited<T>`（`RateLimited.cj:23`，`BackPressure<T>` 子类，8 个静态工厂 `tokenBucket`/`slidingWindow`/`leakingBucket`/`anyMoment` 各两个重载）——用户无法从 README 知道限流也是一种背压；④ `CombinedObserver`、`Cache`/`EmptyCache`/`QueuedCache`、`Scheduler`/`SingleScheduler`/`SingleSchedulerState`、`RateLimited` 只出现在 `:158-165` 的名字清单里，没有签名、参数、语义或示例；⑤ `replaySize` 的 `capacity=0` 表示关闭、`withSingle`/`withFixed` 的队列上限与线程上限均未说明。
- **描述**：README 的结构是"入门用法 + 公开 API 清单"，但清单只有名字，读者无法据此调用；而被漏掉的恰是模块最需要解释的部分（限流背压、线程/队列有界性、Emitter 的线程契约）。按文档用不起来，或误以为默认就有背压保护（#4）。
- **建议**：补三节：`subscribe` 的三种重载（含 `creator` 示例）、`Emitter` 的"生产/消费必须分线程 + bufSize 语义 + 满时阻塞"、`RateLimited` 的工厂方法表（tokenBucket / slidingWindow / leakingBucket / anyMoment × 是否带 `scheduler`）；`CombinedObserver`/`Cache`/`Scheduler` 若定位为内部实现，就收窄可见性并从公开清单移除（见 #6），不要只列名字。

### [一般][存量] #16 `CombinedObserverPolicy` 公开枚举没有任何消费点，属于未接线的空能力

- **位置**：`f_rx/src/CombinedObserverPolicy.cj:18`（三个变体 19–21）
- **来源**：存量（`git blame -L 18,22` → `4be871f2fd`）
- **判据**：review-checklist §14.1（接线缺失 / 半成品）
- **证据**：静态确定 —— 全仓检索 `CombinedObserverPolicy` 只命中定义处与 `README.md:158` / `README_en.md:158` 的名单，没有任何函数参数、字段或 `match` 使用它；`CombinedObserver` 实际只接受 `async!: Bool`（`Observer.cj:94`）。
- **描述**：枚举的变体（`Async(Duration)` / `AsyncOrdering` / `Sync`）暗示"异步合并策略可配置"，但配置入口不存在，用户既无法使用也无法从 README 知道它是否生效。这是"公开了但没实现"的半成品，容易被下游误用为契约。
- **建议**：要么把它接进 `CombinedObserver` 的构造（替代 `async: Bool`，`Async(Duration)` 正好对应 #1 里那个 100ms），要么删除该文件并同步删掉 README 的名单条目。

### [轻微][存量] #17 9 个 `BackPressure` 子类的 `clone()` 逐行相同，只有类型名不同

- **位置**：`f_rx/src/BackPressure.cj:42-46`（`Discarding`）、`:57-61`（`ToDropOldest`）、`:76-80`（`AlwaysBlocking`）、`:93-97`（`Throwing`）、`:110-114`（`CurrentThread`）、`:127-131`（`NewThread`）、`:148-152`（`Action`）、`:173-177`（`AfterBlocking`）、`f_rx/src/RateLimited.cj:88-96`
- **来源**：存量（`git blame -L 42,46` 等 → `4be871f2fd`）
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 8 处函数体都是 `let bp = X<T>(...); bp.scheduler_ = this.scheduler_; bp`，唯一差异是类型名与 `Action`/`AfterBlocking` 多带一个构造参数；`RateLimited.clone` 除子策略克隆外同形。
- **描述**：这是"每个子类都要复制一遍"的模板代码，新增一种策略必须记得复制，漏掉 `scheduler_` 赋值就会在 `scheduler` getter 的 `getOrThrow` 上崩（`BackPressure.cj:25-28`）。目前 9 处一致，属于可维护性风险而非现网缺陷。
- **建议**：把 `clone` 的公共部分下沉到基类（例如 `protected func rebuild(): BackPressure<T>` 只负责构造空实例，基类 `clone` 统一补 `scheduler_`），子类只实现 `rebuild`；`AfterBlocking`/`RateLimited` 的复合克隆单独覆盖。

### [轻微][存量] #18 `imports.cj` 导入了未使用的 `ArrayList`

- **位置**：`f_rx/src/imports.cj:18`
- **来源**：存量（`git blame -L 18,18` → `4be871f2fd`）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 全模块 `.cj` 检索 `ArrayList`：仅 `imports.cj:18` 与 `rxcj_test.cj`（该文件自己 `import std.collection.*`，不使用本文件的导入）；`LinkedList` 在 `Cache.cj:38/41` 有使用。
- **描述**：多余的导入不影响行为，但会让"这个模块用到哪些集合"的判断失真，也是 §1 机械检查里唯一命中项。
- **建议**：删掉 `ArrayList`，保留 `LinkedList`。

### [轻微][存量] #19 `CombinedObserver.add(name, FuncObserver)` 的注释与实现相反，且返回值与其它 `add` 重载不一致

- **位置**：`f_rx/src/Observer.cj:112`（注释 115–118，实现 112–114）
- **来源**：存量（`git blame -L 109,118` → `4be871f2fd`）
- **判据**：review-checklist §10（语义与注释不符 / API 一致性）+ §11
- **证据**：静态确定 —— 注释写"如果试图注册 `FuncObserver<T>` 会抛出异常"，实现是 `addIfAbsent(name, observer)`，只在**重名**时抛 `ObserverRegistrationException`（`Observer.cj:136-138`）；该重载返回 `Unit`，而 `add(observer)` / `add(name, observer)` 返回 `This`（`:119`、`:131`）。
- **描述**：注释会让维护者误以为该重载是"禁止 FuncObserver"的守卫；返回值不一致会让链式调用 `add(name, funcObserver).add(...)` 编译失败，而用户从其它重载推断它可以链式。
- **建议**：注释改为"按名称注册 `FuncObserver`，重名抛 `ObserverRegistrationException`"，返回值统一为 `This`。

### [轻微][存量] #20 两处有意的空实现没有"为什么可以为空"的说明

- **位置**：`f_rx/src/Cache.cj:30-32`（`EmptyCache.set`）、`f_rx/src/BackPressure.cj:47`（`Discarding.schedule`）
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §3（Null Object / no-op 必须有注释说明）
- **证据**：静态确定 —— 两处函数体为空（`{}` 与只含空行的 `{ }`），类的文档注释只写了"丢弃当前数据"（`BackPressure.cj:36`）/ 类名 `EmptyCache`，没有说明"空缓存等价于不缓存"与"丢弃时不通知上游"这两个语义。
- **描述**：空实现本身是合理的策略（不是缺陷），但缺乏注释时容易被后续维护者当成漏写，尤其 `EmptyCache.set` 与 `QueuedCache.set` 形似而语义完全不同。
- **建议**：各补一行注释，例如 `// 无缓存：replaySize(0) 时使用，set 不做任何事` / `// 有意丢弃：不阻塞、不抛错、不通知`。

### [轻微][存量] #21 公开入口缺少参数校验：`withFixed(0)`、`withSingle(0)`、`emitter(bufSize: 0)` 会以底层异常失败

- **位置**：`f_rx/src/Observable.cj:95`（`bufSize` 直接传给 `Emitter`）、`:259`/`:280`（`queueSize` 直接传 `SingleScheduler`）、`:273`/`:280`（`threads` 直接用于 `Array<SingleScheduler<T>>(threads)`，`Scheduler.cj:265`、`:268`、私构造 `:257-258` 取 `queues[0]`）
- **来源**：存量（`git blame` → `4be871f2fd`）
- **判据**：review-checklist §11（边界未校验）+ §10（错误契约）
- **证据**：静态确定 —— `threads == 0` 时 `Array(0)` 为空，`FixedScheduler` 私有构造 `super(queues[0].observer)` 越界；`threads < 0` 抛 `NegativeArraySizeException`；`bufSize == 0` 交给 `ArrayBlockingQueue(0)`，std 文档明确容量须 > 0（`md/doc/cjapi/concurrent_collection.md:113`）。`queueSize == 0` 交给 `LinkedBlockingQueue(0)` 的具体行为文档未写明（**待确认**：抛异常还是零容量队列；若为零容量则每条数据都走背压分支）。以上都不是本模块定义的异常，也没有文档说明。
- **描述**：配置来自用户/配置文件时，错误的值以 `IndexOutOfBoundsException` / `NegativeArraySizeException` / `IllegalArgumentException` 的形状出现，排查成本高；`threads` 特别大时还会瞬间创建大量线程（与 #13 同源的无界性）。
- **建议**：在 `withFixed` / `withSingle` / `emitter` 入口做 `requireArg(threads > 0 && threads <= 上限)`、`queueSize > 0`、`bufSize > 0`，抛带参数名的 `IllegalArgumentException`，并把合法范围写进 README。

### [轻微][存量] #22 测试用固定 `sleep(5s)` 等待异步完成，`testSleep` 没有任何断言

- **位置**：`f_rx/src/rxcj_test.cj:234`、`:252`、`:270`、`:299`、`:328`（各 5 秒 sleep）、`:332-335`（`testSleep` 只 sleep）
- **来源**：存量（`git blame -L 332,335` → `4be871f2fd`）
- **判据**：review-checklist §10（可测试性）+ §14.1（半成品）
- **证据**：静态确定 —— 断言依赖 `sleep` 之后读 `AtomicOptionReference`/`map.size`，没有任何 `Future`/`SyncCounter`/`Condition` 同步点；`testSleep` 无断言、无被测对象。
- **描述**：这类测试在慢机器/CI 高负载下会假失败，在快机器上又可能提前断言（观察者线程还没跑完）——`testMultiAsyncObserver` 尤其依赖 100ms 轮询的时序（#1）。同时模块最核心的背压策略（9 个 `BackPressure` 子类，含 `RateLimited`）、重放 `QueuedCache`、`setErrorResumer`、`CombinedObserver.remove/clear` 完全没有用例，这正是 #1/#3/#4 未被发现的原因。
- **建议**：把 `sleep` 换成 `SyncCounter(1)` + `waitUntilZero(timeout)` 或 `Future.get(timeout)` 之类的显式汇合；删除 `testSleep`；补 4 组用例：各背压策略在满队列下的行为、`pause` 后重启、`replaySize` 重放、错误恢复器（含 `items()` 首次失败）。

> 范围外提示（不占本轮统计）：`src/rx/rx.cj:18` 只是 `public import fountain::f_rx.*` 的再导出，仓内没有任何模块调用 `f_rx` 的 API（全仓检索 `fountain::f_rx` 仅命中该再导出），因此以上缺陷目前只影响下游使用者，不会被本仓测试暴露。

存量缺陷共 22 条（严重 6 / 一般 10 / 轻微 6），默认只报不修，是否纳入修复待用户决定。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本模块无 bench / profile 数据，以下全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] `AsyncObserver` 的"每观察者一条线程 + 容量 1 队列"改为共享调度 + 每观察者有界队列

- **现状**：`asyncCombined: true` 时每个观察者一个 `ArrayBlockingQueue<T>(1)`（`Observer.cj:230`）+ 一条常驻线程（`:234`），N 个观察者即 N 个队列对象 + N 条线程；队列只缓冲 1 条，且 100ms 空转轮询。`Observable` 本身还长期持有 `cache` 与全部观察者，直到 `disposeAll`。
- **方案**：`CombinedObserver` 内部复用 `Scheduler` 的单线程/固定线程机制（`SingleScheduler` 已有队列 + 毒丸 + 背压），每个观察者一个有界队列（例如 64/1024），由统一的一组消费线程驱动；`AsyncOrdering` / `Async(Duration)`（#16）正好作为该队列的策略参数。
- **预期**：线程数从 O(观察者数) 降到 O(消费线程数)，队列容量从 1 提到可配置的有界值（减少 `q.add` 阻塞）；具体降幅需测。
- **代价**：语义变化——多个观察者共享消费线程，慢观察者会拖慢同线程上的其它观察者，需要"每观察者独立队列 + 独立背压"才能保持隔离；要正确处理完成/异常的关闭路径（否则重演 #1/#3）。
- **验证**：10 个观察者、1e6 条数据、生产 10 万条/秒，跑 10 分钟；对照 `getAllocatedHeapSize()` 峰值、`RSS`、线程数（`Thread` 统计）与业务计数是否稳态。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `AsyncObserver` 的 100ms 轮询改为阻塞等待 + 哨兵唤醒

- **现状**：每个 `AsyncObserver` 每 100ms 唤醒一次（`q.remove(Duration.millisecond * 100)`，`Observer.cj:235`），空闲期也照常唤醒；N 个观察者时空转唤醒 = 10N 次/秒。
- **方案**：`q.remove()` 改为无超时阻塞，`onComplete`/`onError` 直接投递哨兵状态（与 #1 的修法合并），线程只在有数据或终态时被唤醒。
- **预期**：空闲期唤醒从 10N 次/秒降到 0；CPU 收益取决于观察者数量与空闲比例，未测。
- **代价**：必须保证终态一定投递（否则线程永久阻塞），与 #1 是同一处改动，风险集中在关闭路径。
- **验证**：`cjprof record` 跑"5 个观察者、每分钟 1 条数据、持续 10 分钟"的场景，看 `AsyncObserver` 线程的 CPU 时间占比与唤醒次数；`cjpm bench -O2` 对照改动前后。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `withAlwaysNew()` 的"每数据一线程"改为有界线程池

- **现状**：`AlwaysNewScheduler.schedule` 每条数据 `spawn` 一个线程（`Scheduler.cj:89`），N 条数据 = N 次线程创建/销毁；线程栈与调度开销随数据量线性增长（#13）。
- **方案**：引入 K 个 worker 的线程池 + 有界任务队列（可直接复用 `f_concurrent` 的池，或 `SingleScheduler` 的多队列结构）；保留 `withAlwaysNew` 作为"每任务新线程"的显式选项，默认策略换成池化。
- **预期**：线程创建次数从 O(N) 降到 O(K)，峰值线程数有上界；吞吐提升幅度需测。
- **代价**：语义变化——线程 id 不再唯一对应一条数据（`testAlwaysNewAndImmediately` 的断言方式要改），用户依赖"每数据独立线程"的隔离性会受影响。
- **验证**：`cjpm bench -O2`，1e5 条数据、观察者耗时 1ms/条，对照线程数、总耗时中位数与离散度；`cjprof` 看线程创建占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `AsyncObserver` 的 100ms 轮询在"观察者多、事件稀疏"时是可见 CPU 开销 | `f_rx/src/Observer.cj:235` | 线程唤醒次数与 CPU 时间占比 | `cjprof record` 跑 5 个观察者、每分钟 1 条数据、10 分钟，看 `AsyncObserver` 线程自耗时 |
| 2 | `withAlwaysNew` 的每数据一线程在 1e4 条以上时线程创建成为瓶颈并抬高峰值内存 | `f_rx/src/Scheduler.cj:89` | 线程数峰值、创建耗时、栈内存 | `cjpm bench -O2` 对照池化版本，1e3/1e4/1e5 三档输入，记录线程数与 RSS |
| 3 | `SingleScheduler` 的 `size < capacity` 竞态在并发生产者下会转化为实际阻塞 | `f_rx/src/Scheduler.cj:213` | 阻塞发生频率、持有时长 | 多线程灌入 + 有界队列（capacity=16），统计 `add` 阻塞次数与 P99 延迟 |
| 4 | `QueuedCache.replay` 持锁执行回调会把 `cache.set` 拖成串行段 | `f_rx/src/Cache.cj:58-63` | 锁等待时长、重放条数分布 | 观察者回调 sleep 1ms、`replaySize(1000)`，用 `cjprof` 看 `Mutex` 等待与 `immediately` 主循环停顿 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rx/README.md` | .md | ✅ | 165 行全文；#14（5 处与实现不符）、#15（覆盖缺失）、#6（主示例不可用）位置 |
| 2 | `f_rx/README_en.md` | .md | ✅ | 165 行全文；与 `README.md` 逐行同构，问题相同，无独立缺陷 |
| 3 | `f_rx/src/BackPressure.cj` | .cj | ✅ | 192 行全文；#7（`ToDropOldest`）、#17（8 处 `clone`）、#20（`Discarding` 空实现） |
| 4 | `f_rx/src/Cache.cj` | .cj | ✅ | 77 行全文；#10（锁内回调 / 锁外迭代器）、#20（`EmptyCache.set`） |
| 5 | `f_rx/src/CombinedObserverPolicy.cj` | .cj | ✅ | 22 行全文；#16（零消费点） |
| 6 | `f_rx/src/Emitter.cj` | .cj | ✅ | 63 行全文；#2（异常被 `Future` 吞、`q.remove` 无超时）、#15（线程约束未进 README） |
| 7 | `f_rx/src/FullSchedulerException.cj` | .cj | ✅ | 22 行全文；异常类型样板，仅被 `Throwing` 抛出，无缺陷 |
| 8 | `f_rx/src/Observable.cj` | .cj | ✅ | 511 行全文；#5（`isDisposed`）、#11（`immediately`）、#12（`getOrThrow`）、#21（参数校验）、#6（`subscribe(creator)` 未文档化） |
| 9 | `f_rx/src/Observer.cj` | .cj | ✅ | 257 行全文；#1（`AsyncObserver`）、#9（异常广播）、#19（注释相反）、#6（构造函数 `internal`） |
| 10 | `f_rx/src/ObserverRegistrationException.cj` | .cj | ✅ | 22 行全文；异常类型样板，`addIfAbsent`/`remove` 抛出，无缺陷 |
| 11 | `f_rx/src/RateLimited.cj` | .cj | ✅ | 96 行全文；#17（`clone`）、#15（README 漏 `RateLimited`）；8 个静态工厂签名与 `f_concurrent` 的 `RateLimiter.exec(task: () -> ?T): ?T` 返回值语义已核对 |
| 12 | `f_rx/src/Scheduler.cj` | .cj | ✅ | 285 行全文；#3（线程退出）、#4（无界队列）、#7（竞态）、#8（`wrapper` 可见性）、#13（`spawn` 无界）、#21（`threads<=0`） |
| 13 | `f_rx/src/imports.cj` | .cj | ✅ | 20 行全文；#18（未使用的 `ArrayList`） |
| 14 | `f_rx/src/rxcj_test.cj` | .cj | ✅ | 335 行全文；#22（固定 sleep / `testSleep`）；测试未覆盖背压、重放、错误恢复（并入 #22 描述） |

合计：`.cj` 12 个 / `.md` 2 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 22 | 严重 6（#1-#6）、一般 10（#7-#16）、轻微 6（#17-#22）。安全性未命中：模块无外部输入拼接、无凭据、无日志输出，唯一"外部输入"是参数值（见 #21） |
| §1 死代码 | 1 | 逐个符号核过：`private` 级 `wrapAsyncIfNeed`/`unwrapAsync`/`isSame`/`addIfAbsent`/`call`/`replayCached`/`noObserver`/`setErrorResumer(resumer:)`/`SingleScheduler.schedule(state)`/`nextIndex`/`FixedScheduler` 私有构造/`CacheIterator.consumed` 全部有调用者；`internal` 级 `AsyncObserver`/`AlwaysNewScheduler`/`CurrentScheduler`/`FixedScheduler`/`EmitterIterator`/`EmitterState`/`CacheIterator` 全部被引用；无 `return`/`throw` 后的同层语句，无恒真恒假分支；`EmptyObserver`/`CombinedObserverPolicy`/`EmptyCache`/`SingleScheduler.add`/`tryRemove`/`doSchedule` 属对外可达 `public`，按硬原则一不判死代码（`CombinedObserverPolicy` 的"未接线"另计 #16）。命中 1 条：未使用的 `ArrayList` 导入（#18） |
| §2 重复逻辑 | 1 | 同文件内把 12 个 `.cj` 的函数体压成"输入→输出→副作用"两两比对：`Observable` 的 4 组 `iterable`/`single`/`maybe`/`concat` 重载是薄委托（保留），`wrapAsyncIfNeed`/`unwrapAsync` 是同一匹配的正反两向（不是重复），`remove` 三个重载语义不同。跨文件按 `BackPressure.clone` 的固定三行形状检索，9 处逐行一致 → #17 |
| §3 空实现 | 1 | 无 `TODO`/`FIXME`/`UnsupportedException`；无 `catch {}` 吞异常（所有 `catch` 都有 `onError`/`schedule(e)` 动作）；`EmptyObserver` 三个空方法是 Null Object 且有类名语义，不计；`EmptyCache.set`（`Cache.cj:30`）与 `Discarding.schedule`（`BackPressure.cj:47`）是有意 no-op 但缺注释 → #20 |
| §4 栈溢出 | 0 | 全部函数逐一核对：无直接/间接递归，无自引用结构的递归打印或深拷贝；`immediately` 的错误恢复走 `Timer.once`（新线程）不在同栈递归。唯一潜在无限递归是"用户在 `onNext` 内再 `subscribe` → `replay` → `onNext`"，属调用方构造，记录在 #10 描述里，不计入本维度 |
| §5 OOM | 3 | #3（消费线程死后无界队列只增）、#4（默认 `LinkedBlockingQueue()` 容量 `Int64.Max`，无拒绝路径）、#13（每数据一线程，O(N) 线程）；`QueuedCache` 有 `capacity` 上限、`Emitter`/`AsyncObserver` 队列有界（1），已排除 |
| §6.1 热点瓶颈 | 0 | 未提供本模块 bench / `cjprof` 数据；`AsyncObserver` 轮询、`withAlwaysNew` 线程创建、`replay` 持锁三条疑点已降级为待验证假设 #1/#2/#4，不作缺陷、不进统计 |
| §6.2 大粒度锁 | 1 | #10：`QueuedCache.replay` 在 `synchronized(lock)` 内遍历最多 `capacity` 条并逐条调用 `observer.onNext`（用户代码），临界区含 O(输入) 工作 + 外部回调；模块内无其它锁（`AsyncObserver`/`SingleScheduler` 用的是阻塞队列，不是显式锁） |
| §6.3 并发串行 | 0 | 无 `spawn` 后立刻 `get()`；`FixedScheduler` 的 `queues[nextIndex]` 确实按 round-robin 分发到多队列（`Scheduler.cj:270-284`），`CurrentThread`/`NewThread`/`Action` 是显式策略而非串行热点；未测实际并行度，故不判 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`/`indexOf`、无 `remove(at: 0)` 当队列（`QueuedCache` 用 `LinkedList.removeFirst` O(1)）、无循环字符串拼接、无重复正则；`FixedScheduler.nextIndex` 为 O(1) |
| §7 降堆内存方案 | 1 | `AsyncObserver` 改为共享调度 + 每观察者有界队列（`无基线（待验证）`）；默认队列无界属缺陷（#4），不重复计入方案 |
| §8 降 CPU 方案 | 2 | 100ms 轮询改阻塞唤醒、`withAlwaysNew` 改有界线程池；均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本模块的常驻对象是队列、线程与观察者表（生命周期跨调用），local region 只覆盖"函数内创建、函数内释放"的对象；`immediately` 每次循环的临时对象很小，无峰值内存数据可证收益。已有资料结论一致：`docs/LocalMode.md:488` 判 f_rx"流式小对象；不做"，`docs/LocalMode-O2-Plan.md:127` 把 f_rx 列入"跨调用持有"不适用；无前后峰值数据，不构成方案 |
| §11 现有代码的 BUG（存量） | 22 | 本轮读到的 14 个文件全部为存量（快照模式无 diff）；22 条发现全部标 `[存量]`，覆盖终态丢失、线程挂死、无界增长、重复终态、构造函数不可见、竞态、错误路径覆盖等形态 |
| §12 并发安全与锁粒度 | 7 | #1（异步语义/线程生命周期）、#3（线程退出后无消费者）、#7（检查-然后-写入）、#8（`wrapper` 可见性 + 发布逸出）、#9（终态语义）、#10（锁内回调 / 迭代与修改并发）、#11（`iterator`/`scheduler` 无同步）；#5 的"getter 每次读都发终态"同时是可见性/幂等问题，计入正确性不重复计 |
| §14 功能完备性与 README 覆盖 | 3 | #6（`FuncObserver`/`CombinedObserver` 外部不可构造，README 主示例不可用）、#15（`subscribe(creator)`、`Emitter` 线程约束、`RateLimited`、背压清单编号均缺）、#16（`CombinedObserverPolicy` 零消费点）。公开符号与 README 已逐项对照：`Observable` 的 6 类工厂、`with*`/`dispose*`/`pause`/`replaySize`/`isDisposed` 均有条目 |
| 文件覆盖（§13 等） | 14/14 | 14 个文件全部读完；§13 文档一致性命中并入 #14（README.md:5/:10/:54/:91/:141-145/:150）与 #15，README 与 README_en 已逐行对照，无中英漂移 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 6 |
| 一般 | 10 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

`f_rx` 的 API 设计（`Observable` 工厂 + `Observer` + 可插拔 `Scheduler`/`BackPressure` + 重放缓存 + 错误恢复）是完整的响应式流骨架，分层也清楚；但**运行时语义没有闭环**，六个严重问题里五个会直接造成挂死、丢数据或无界增长，且都发生在默认/文档推荐路径上：

- 异步合并（`asyncCombined: true`）的排空线程活不过 100ms 空闲，之后 `onNext` 永久阻塞（#1）——这条使模块宣传的"每观察者一线程"基本不可用；
- `emitter` 的生产者异常被 `spawn` 的 `Future` 吞掉，消费端无限等待（#2）；
- 单线程/固定线程调度器在完成或异常后线程退出，README 承诺的"重新订阅再启动"只会把数据堆进无界队列（#3）；
- 默认的 `withSingle()` / `withFixed(threads)` 根本没有容量上限，所有背压策略分支永不触发（#4）；
- `isDisposed` 这个"查询"属性每次读都再发一次 `onComplete`（#5）。

这五条互相叠加：背压不生效 → 队列增长 → 调度线程退出 → 数据静默丢失，排障时症状会互相掩盖，建议按 #1 → #3 → #4 → #2 → #5 的顺序一次修完并补并发用例，而不是逐条打补丁。

对外可用性上，#6 是阻塞项：`FuncObserver` 的主构造函数缺省 `internal`，下游按 README 写的第一行代码就编译不过；唯一可用的 `subscribe(name) { ob => ... }` 反而没写进 README。文档层面还有 5 处硬错误（#14：`dispose(completion)` 不存在、`disposed_` 语义写反、`setErrorResumer` 列了 private 重载、示例缺参、重放写成异步），以及背压清单漏 `RateLimited`、编号跳号（#15）。

并发与锁方面，#7/#8/#10/#11 都是"部分字段原子化、部分没有"的半吊子状态（`disposed_` 用 `AtomicBool`、观察者表用 `ConcurrentHashMap`，但 `iterator`/`scheduler`/`wrapper` 是普通 `var`），建议统一成"启动后配置不可变 + 运行期只读快照"的模型，比逐点加锁更省事。

`CombinedObserverPolicy` 是明确的半成品（#16），要么接进 `AsyncObserver` 的 100ms/顺序策略，要么删掉。其余为整洁度问题（`clone` 复制、未使用导入、注释与实现相反、参数校验、测试靠 sleep 且覆盖不到背压），可在修完上述阻塞项后一并处理。

性能与内存方面没有任何 bench / profile 数据，三套优化方案与四条假设都只是"待验证"，不建议在本轮排期；先修正确性，再用同一批用例采基线。

存量缺陷共 22 条（严重 6 / 一般 10 / 轻微 6），默认只报不修，是否纳入修复待用户决定。
