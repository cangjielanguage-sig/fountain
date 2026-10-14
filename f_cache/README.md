# 强引用堆缓存
1. 强引用
2. 可以为缓存指定寿命
3. 可以为缓存指定最大缓存的对象数
```cj
public class HeapCache<V> where V <: Object {
    /**
     * concurrencyLevel 并发度（分段数），默认 0 = 按 maxSize 自动选段数（16~128，2 的幂）
     * maxLife 缓存对象的最大寿命
     * maxSize 缓存对象的最大数
     * checkDuration 缓存的检查周期
     * evictionCallback 缓存对象失效的回调函数
     */
    public HeapCache(
        concurrencyLevel!: Int64 = 0,
        private let maxLife!: Duration = DEFAULT_HEAP_CACHE_MAX_LIFE,
        private let maxSize!: Int64 = DEFAULT_HEAP_CACHE_MAX_SIZE,
        private let checkDuration!: Duration = DEFAULT_HEAP_CHECK_CHECK_DURATION,
        private let evictionCallback!: (String, V) -> Unit = {_, _ => ()}
    )
    /**缓存构建器*/
    public static func builder(): HeapCacheBuilder<V>
    /**获取缓存KEY对应的值*/
    public func get(key: String): Option<V>
    /**确认缓存KEY是否存在*/
    public func contains(key: String): Bool
    /**
     * 缓存KEY存在且缓存对象是一次性的返回true。
     * 一次性对象的意思是每次取用对象不会重新计时对象过期时间，否则每次取用对象都会对过期时间重新计时
     */
    public func once(key: String): Bool
    /**
     * 修改对象过期时间和是否一次性对象。
     * 一次性对象的意思是每次取用对象不会重新计时对象过期时间，否则每次取用对象都会对过期时间重新计时
     */
    public func prolong(key: String, life: Duration, once!: Bool = false): Bool
    /**
     * 修改对象过期时间，同时改为一次性对象
     * 一次性对象的意思是每次取用对象不会重新计时对象过期时间，否则每次取用对象都会对过期时间重新计时
     */
    public func prolong(key: String, deathTime: DateTime): Bool
    /**
     * 添加或覆盖缓存对象，同时指定缓存对象的过期时间以及是否一次性对象
     * 一次性对象的意思是每次取用对象不会重新计时对象过期时间，否则每次取用对象都会对过期时间重新计时
     */
    public func set(key: String, value: V, life!: Duration = this.maxLife, once!: Bool = false): ?V
    /**
     * 添加或覆盖缓存对象，将对象指定为一次性对象
     * 一次性对象的意思是每次取用对象不会重新计时对象过期时间，否则每次取用对象都会对过期时间重新计时
     */
    public func set(key: String, value: V, dieAt: DateTime): ?V
    /**
     * 获取缓存对象，如果缓存对象不存在就返回default
     */
    public func getOrDefault(key: String, default: V): V
    /**
     * 获取缓存对象，如果缓存对象不存在就缓存value，且返回value
     */
    public func getOrStore(key: String, value: V): V
    /**
     * 获取缓存对象，如果缓存对象不存在就缓存callable的返回值，且把它作为返回值
     */
    public func getOrCompute(key: String, callable: () -> V): V
    /**
     * 获取缓存对象，如果缓存对象不存在就缓存callable的返回值，并把它的过期时间指定为返回的时间，
     * 且把返回对象作为本函数的返回值
     */
    public func getOrCompute(key: String, callable: () -> (V, DateTime)): V
    /**
     * 获取缓存对象，如果缓存对象不存在就缓存callbale的返回值，
     * 并把它的过期时间指定为Duration、以及把是否一次性的指定为callable返回的Bool；
     * 且把callable返回的V作为本函数的返回值
     */
    public func getOrCompute(key: String, callable: () -> (V, Duration, Bool)): V
    /**
     * 删除指定key的缓存
     */
    public func remove(key: String): Option<V>
    /**
     * 删除predicate返回true的缓存，缓存的键值对是predicate参数
     */
    public func removeIf(predicate: (String, V) -> Bool): Unit
    /**返回缓存对象数*/
    public prop size: Int64
    /**清除缓存*/
    public func clear(): Unit
    /**关闭缓存：停止内部线程、取消定时器并清空（Resource 接口，可重复调用）*/
    public func close(): Unit
    /**缓存是否已关闭（Resource 接口）*/
    public func isClosed(): Bool
}
```
```cj
public open class HeapCacheBuilder<V> where V <: Object {
    public func setMaxLife(maxLife: Duration): HeapCacheBuilder<V> 
    public func setConcurrencyLevel(concurrencyLevel: Int64): HeapCacheBuilder<V> 
    public func setMaxSize(maxSize: Int64): HeapCacheBuilder<V> 
    public func setEvictionCallback(callback: (String, V) -> Unit): HeapCacheBuilder<V> 
    public func setCheckDuration(checkDuration: Duration): HeapCacheBuilder<V> 
    public open func build(): HeapCache<V> 
}
```

# 弱引用堆缓存
内部维持的键和值被弱引用包装，定时遍历缓存并清除被运行时清除的弱引用
```cj
public class WeakHeapCache<T> where T <: Object {
    public init()
    /**添加缓存键值对象*/
    public func set(key: String, value: T): ?T
    /**
     * 获取缓存对象，如果缓存不存在且fn返回了Some，就缓存这个值，并返回这个值，其它情况返回None<T>
     */
    public func getOrCompute(key: String, fn: () -> ?T): ?T
    /**
     * 返回缓存对象，如果没有缓存的KEY就返回None<T>
     */
    public func get(key: String): ?T
    /**
     * 返回缓存对象，如果缓存不存在就返回default
     */
    public func getOrDefault(key: String, default: T): T
    /**
     * 返回缓存对象，如果缓存不存在就缓存value，并返回value
     */
    public func getOrStore(key: String, value: T): T
    /**
     * 删除缓存KEY
     */
    public func remove(key: String): ?T
    /**
     * 删除predicate返回true的缓存
     */
    public func removeIf(predicate: (String, T) -> Bool): Unit
    /**
     * 缓存的大小
     */
    public prop size: Int64
    /**清除缓存*/
    public func clear(): Unit
}
```

# 并发与约定（2026-10-05 补充）

缓存内部按 `concurrencyLevel` 分成若干分段，每个分段一把互斥锁（`Mutex`），段与段之间互不阻塞。`concurrencyLevel` 默认传 0：按 `maxSize` 自动选段数（每段目标 ≤1024 条、段数取 2 的幂且不超过 `DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL`=128）——段对象的固定开销摊在每个实例上，小缓存（如 `maxSize: 1000`）用 128 段会白付 ~150 KB 内存与 ~250 µs 构造时间（实测见 `cron-bench/logs/evict2_new.log`）；`maxSize` 无上限时仍是 128 段。显式传正数则按指定值分段。段内用互斥锁而非读写锁：std 的读锁为「每线程读计数」维护 ThreadLocal，无人竞争时一次 lock+unlock 也要 ~517 ns，而 `Mutex` 约 20 ns；且段内 `get` 会经 `turnToTail` 维护 LRU 链表序（`checkOverSize` 的采样依据），本身就是写操作，互斥保护同时消除并发改链表的竞争（实测见 `cron-bench/logs/heapcache/perf-audit-2026-10-14.md`）：

- **`getOrCompute` 的 callable 在分段锁之外执行**：同一键可能被并发计算多次，只有第一次写入的结果生效，其余计算结果被丢弃。callable 应当是纯计算或幂等的；有副作用、或必须「只算一次」时请在调用方自行去重。
- **`removeIf` 是两阶段删除**：先在锁下取快照，再在锁外执行谓词，最后在锁下按 key 删除。谓词不会阻塞同段读写；代价是「判定—删除」不是原子的——两阶段之间新写入的条目也可能因快照里的旧值满足谓词而被删除。
- **`size` 与 `get`/`contains` 的口径差**：`get`/`contains` 会先做寿命判定，而 `size` 统计 map 中的条目 ⇒ 已过期但尚未被定时清扫的条目（最长一个 `checkDuration`）仍计入 `size`；`maxSize` 淘汰也以 `size` 为准。
- **`WeakHeapCache` 是弱引用缓存，键强、值弱**：值一旦不再被外部强引用就可能被 GC 回收，条目随之失效（最长 1 s 后被清扫线程摘除）⇒ `size` 会包含「值已失效但尚未清扫」的条目，与 `get`/`contains` 的口径差最长 1 s；`close()` 会主动清空并等清扫线程结束。
- **迭代一致性**：`ConcHashMap`/`SyncLinkedHashMap` 的迭代器是**弱一致**的（锁外创建、逐段/逐项取锁，跨段无快照）⇒ 迭代期间发生的写入不保证被本轮迭代看到、也不保证顺序；`HeapCache` 的定时淘汰与业务读并发时同理。
- **`maxSize` 超限时的淘汰顺序**：两个候选先比「距今时长」——差距超过一个 `checkDuration` 时直接淘汰更老的那个；差距在一个周期内则逐级比较：**本次检查周期内使用次数多者、最后使用时间更晚者优先保留**（「保护新生」）。（再往下还有「历史访问总量多者」「出生更晚者」两级 tie-break，实际几乎用不到。）
- **淘汰比较走「进堆快照」**：`checkOverSize` 把候选放进最小堆之前先加锁取一次「比较快照」（年龄 + 五级 tie-break 所需的量），堆内比较只读快照，不再逐次加锁、逐次取 `DateTime.now()` ⇒ 同一轮里所有候选的年龄基准一致，单轮可淘汰更多条目（实测 `evict 50000 maxSize=1000`：写入期淘汰量 ×2~4，300 ms 后能收敛到 `maxSize`）。`Priority` 内部时间戳统一为 Unix 纳秒（`Int64`）、计数与值字段用普通变量（读写都在 `lock` 内，不再用 `AtomicReference`/`AtomicBool` 包装）——10 万条目常驻 RSS 约降 10%。
- `set` / `get` / `remove` / `once` / `prolong` / `clear` 等公开方法都可并发调用（分段锁 + 原子计数）。
- **`HeapCache` 与 `WeakHeapCache` 实现了 `Resource`**：两者各持有 1 个常驻内部线程（`HeapCache` = 淘汰回调消费线程 + 1 个定时器；`WeakHeapCache` = 弱引用清扫线程）。用完请 `close()`（可重复调用）：它会向内部线程发送取消请求、取消定时器（`HeapCache`）并清空缓存；内部线程每轮循环检查 `Thread.currentThread.hasPendingCancellation`，`HeapCache` 的消费线程在收到取消后会把已入队的淘汰回调投递完再退出。（`HeapCache` 原 `destroy()` 已删除，统一用 `close()`；进程退出时由 `f_base` 的 `ExitCallbacks` 自动 `close()`，该注册项持**弱引用**，`close()` 之后实例可被 GC 回收。`close()` 还会向淘汰队列投递一个 `None` 哨兵，立即唤醒阻塞中的消费线程。）
- **关闭延迟**：`HeapCache` 的 `close()` 靠哨兵唤醒消费线程，毫秒级返回（不再等 100 ms 轮询超时）；`WeakHeapCache` 的清扫周期是 1 s，其 `close()` 最长会阻塞这么久（它在返回前会等内部线程结束）；两者的 `isClosed()` 都立即变为 true。
- **关闭之后**：`close()` 会**主动清空全部条目**，并在内部线程结束后才返回；此后调用任何操作（`get`/`set`/`contains`/`once`/`prolong`/`getOrCompute`/`remove`/`removeIf`/`size`/`clear`/…）都会抛 `IllegalStateException` —— 只有 `isClosed()` 与 `close()`（可重复调用）例外。
- **`once` / `prolong` 与 `get` / `contains` 同口径**：已过期（即使尚未被定时清扫）的条目视为不存在 —— `once`/`prolong` 返回 `false`，**不会把过期条目「复活」**；要续期或重建请用 `set`。


---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`public let DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL = 128`（`concurrencyLevel=0` 自动推导时的段数上限）、`DEFAULT_HEAP_CACHE_MAX_LIFE`（let）、`public let DEFAULT_HEAP_CACHE_MAX_SIZE = Int64.Max`、`public let DEFAULT_HEAP_CHECK_CHECK_DURATION = Duration.second`、`Priority`（class）、`public func hashCode(): Int64`
- `Priority`：`open func compare(other: Priority<V>): Ordering`
