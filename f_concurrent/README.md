## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 并发安全的字典

`ConcDict<K, V>` 是并发字典接口（`<: Collection<(K, V)>`）：**不要求 `K` 实现 `Hashable & Equatable<K>` 或 `Comparable<K>`** ——
散列与相等由实现方在构造时给出（`hasher: (K) -> Int64` / `equals: (K, K) -> Bool`），因此键可以是任意自定义类型。
`ConcHashDict` 是它的哈希实现，`ConcurrentHashSet` 在此基础上提供并发 Set。

```cj
public interface ConcDict<K, V> <: Collection<(K, V)> {
    /* 需要实现方自己实现 */
    func get(key: K): Option<V>
    func add(key: K, value: V): Option<V>            // 返回被覆盖的旧值（若有）
    func add(all!: Collection<(K, V)>): Unit
    func addIfAbsent(key: K, value: V): ?V           // 不存在才放入，返回原值（若有）
    func replace(key: K, value: V): ?V               // 已存在才替换，返回旧值
    func remove(key: K): Option<V>
    func remove(all!: Collection<K>): Unit
    func removeIf(predicate: (K, V) -> Bool): Unit
    func contains(key: K): Bool
    func contains(all!: Collection<K>): Bool
    func clear(): Unit
    func keys(): Collection<K>
    func values(): Collection<V>
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V    // 原子化的「读-改-写」，下面的便捷方法都建在它之上
    prop size: Int64
    func isEmpty(): Bool
    func iterator(): Iterator<(K, V)>
    operator func [](key: K): V                      // 键不存在抛异常
    operator func [](key: K, value!: V): Unit

    /* 接口里已给出默认实现（都基于 entryView） */
    func addIfAbsent(key: K, fn: () -> V): V         // 不存在则用 fn 建值并放入，返回最终值
    func addIfPreset(key: K, fn: () -> V): ?V        // 已存在则用 fn 生成新值替换
    func removeIf(key: K, predicate: (V) -> Bool): ?V
}
```

两点容易看漏：

- `addIfAbsent` 有**两个重载** —— `(key, value)` 返回旧值、需要实现方实现；`(key, fn: () -> V)` 有默认实现、返回最终值；
- `removeIf` 也有两个不同签名 —— `(predicate: (K, V) -> Bool): Unit` 与 `(key, predicate: (V) -> Bool): ?V`。

```cj
public class ConcHashDict<K, V> <: ConcDict<K, V> {
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /** initElement 的入参范围是 0 ～ size，返回该位置的初始键值对 */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool)
}
```

（`toArray()` 等来自 `Collection` 父接口。）

## `public class ConcurrentHashSet<T> <: Set<T> where T <: Hashable & Equatable<T>`
并发安全的 Set：4 个 `init`（容量 / 初始集合等）、`retainAll`、`clone`，并扩展了 `==` / `toString` /
`intersection` / `union` / `difference`。详见 `doc/ConcurrentHashSet.md`。

## 负载均衡

```cj
/** 轮转法：每次 next() 返回 current，然后 current += step；current > max 时回到 min */
public struct RoundRobin<W> <: LoadBalanceAlgo<W> where W <: Addable<W> & Comparable<W> {
    public RoundRobin(private let step: W, private let min: W, private let max: W)
}
/** 随机权重：Int64Weight 取值 [min, max]，Float64Weight 取值 [min, max)（浮点不能用 closed 的 +1 语义） */
public abstract class RandomWeight<W> <: LoadBalanceAlgo<W> where W <: StdNumber<W> & Addable<W> & Comparable<W>
public class Int64Weight <: RandomWeight<Int64>
public class Float64Weight <: RandomWeight<Float64>

public class LoadBalance<W, D, R> where W <: Addable<W> & Comparable<W> {
    /** min 是**累计权重键的起点**，不是「最小权重」；algo 必传 */
    public LoadBalance(min: W, algo: LoadBalanceAlgo<W>)
    public func add(weight: W, fn: (D) -> R): Unit
    public func add(all!: Iterable<(W, (D) -> R)>): Unit
    /** 按算法取一个节点执行 */
    public func call(data: D): R
    /** 失败时按顺序换下一个节点重试最多 maxRetrying 次 */
    public func call(data: D, maxRetrying: Int64): (?R, ?LoadBalanceException)
    /** 从算法选定的位置开始迭代，走完绕回开头（首个元素即选中节点，其余是重试节点） */
    public func iterator(): Iterator<(D) -> R>
}
```

语义（**最容易踩的点**）：内部用 `TreeMap`，键是各节点的**累计权重** `K_i = min + w₁ + … + w_i`，
取节点 = 第一个键 ≥ 算法给出的值 ⇒ 节点 i 覆盖 `(K_{i-1}, K_i]`。因此算法取值必须落在**桶的内部**：
若取值与桶边界对齐（例如让取值起点等于 `min`），就会**永远命中同一个节点**。
权重场景推荐 `min = 0`、取值起点 `step / 2`、上界 `Σw`（`f_rpc` 的 `ClientConfig` 即如此接线，
见 `.autocode/bugs/bug-archived-20261004-2.md` 第 2 部分）。完整说明与示例见 `doc/负载均衡.md`。


## 限流算法
```cj
abstract sealed class RateLimiter<T> {
    /**阻塞超时时长*/
    public RateLimiter(protected let timeout: Duration)
    /**执行函数*/
    public func exec(task: () -> ?T): ?T
    /**如果task返回None本函数就返回default*/
    public func exec(default: ?T, task: () -> ?T): ?T
}
```
### 不限流
```cj
public class UnlimitedRateLimiter<T> <: RateLimiter<T>
```
### 漏桶算法
```cj
public class LeakingBucketRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param timeout 任务等待时长
     * @param maxWaitings 允许等待的最大任务数
     * @param leakingPerDuration 每个漏桶周期漏下的任务数
     * @param leakingDuration 漏桶周期
     */
    public init(
        timeout!: Duration,
        maxWaitings!: Int64,
        leakingPerDuration!: Int64,
        leakingDuration!: Duration
    )
}
```

### 滑动窗口算法
```cj
public class SlidingWindowRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param window 时间窗口（必须 > 0）
     * @param timeout 阻塞超时时长
     * @param limit 时间窗口内最大任务数（必须 > 0）
     */
    public init(window!: Duration, timeout!: Duration, limit!: Int64)
}
```

### 令牌桶算法
```cj
public class TokenBucketRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param tokens 令牌总数
     * @param timeout 阻塞时长
     * @param populationPeriod 填充令牌的周期
     */
    public init(tokens!: Int64, timeout!: Duration, populationPeriod!: Duration)
}
```

### 任意时刻最大数限流器
```cj
public class AnyMomentRateLimiter<T> <: RateLimiter<T> {
    /**
     * @param maxTokens 任意时刻允许最多这么多任务并发执行
     * @param timeout 任务等待时长
     */
    public init(maxTokens!: Int64, timeout!: Duration)
}
```


## 只计算一次
```cj
public struct Constants {
    /**
     * 获取一个常量，如果key对应的值不存在就调用fn计算并返回
     */
    public static func get<T>(key: String, fn: () -> T): T
    /**
     * 获取一个常量，如果不存在就调用fn计算并返回
     */
    public static func get<T>(fn: () -> T): T
}
```


## ConcurrentSkipListMap

基于跳表实现的并发安全字典，支持有序键操作。

```cj
public class ConcurrentSkipListMap<K, V> <: ConcurrentMap<K, V> & Collection<(K, V)> where K <: Comparable<K>
```

除下表列出的自有方法外，`put` / `putIfAbsent` / `add(all!)` / `contains(all!)` / `toArray()` 等来自
`ConcurrentMap` / `Collection` 父接口（见 `src/ConcurrentSkipListMap.cj`）。

### 构造函数

```cj
public init()
```

### 核心方法

#### 查找
```cj
// 根据 key 获取值
public func get(key: K): Option<V>

// 判断是否包含指定键
public func contains(key: K): Bool

// 获取元素个数
prop size: Int64

// 判断是否为空
public func isEmpty(): Bool
```

#### 插入/更新
```cj
// 插入或更新键值对，返回旧值（如果存在）
public func add(key: K, value: V): Option<V>

// 仅当键不存在时插入
public func addIfAbsent(key: K, value: V): Option<V>

// 仅当键存在时更新
public func addIfPresent(key: K, value: V): Option<V>

// 无条件替换
public func replace(key: K, value: V): Option<V>

// 带条件的替换
public func replace(key: K, eval: (V) -> V): ?V

// 带条件判断的替换
public func replace(key: K, predicate: (V) -> Bool, eval: (V) -> V): ?V
```

#### 删除
```cj
// 删除指定键的映射
public func remove(key: K): Option<V>

// 带条件的删除
public func remove(key: K, predicate: (V) -> Bool): Option<V>

// 删除满足条件的所有键值对
public func removeIf(predicate: (K, V) -> Bool): Unit

// 删除多个键
public func remove(all!: Collection<K>): Unit

// 清空所有键值对
public func clear(): Unit
```

#### 遍历
```cj
// 返回迭代器
public func iterator(): Iterator<(K, V)>

// 获取所有键
public func keys(): EquatableCollection<K>

// 获取所有值
public func values(): Collection<V>
// 从最小的KEY开始遍历，到max结束，including决定是否包含max
public func header(max: K, including!: Bool = false): Iterator<(K, V)>
/**
 * @param min: 迭代器的第一个key不小于min
 * @param including: 迭代器的第一个key是否包含min，true为包含，false为不包含
 */
public func tailer(min: K, including!: Bool = true): Iterator<(K, V)> 
// 返回指定区间的迭代器，从min开始到max结束，includingMax决定是否包含max，includingMin决定是否包含min
public func sub(min: K, max: K, includingMin!: Bool = true, includingMax!: Bool = true): Iterator<(K, V)>
```

#### 原子操作
```cj
// 如果键不存在，调用 fn 计算值并存储
public func addIfAbsent(key: K, fn: () -> V): V

// 如果键存在，用当前值调用 fn 并存储结果
public func addIfPresent(key: K, fn: () -> V): ?V

// Entry View 操作的简重载版本
public func entryView(key: K, fn: (K, ?V) -> ?V): ?V

// 带条件检查的原子更新
public func entryView(key: K, fn: (MapEntryView<K, V>) -> Unit): ?V
```

### 运算符重载
```cj
// 通过键获取值（键不存在则抛出异常）
operator func [](key: K): V

// 通过键设置值
operator func [](key: K, value!: V): Unit
```

### 实现细节

- **数据结构**：使用跳表实现，支持 O(log n) 的查找、插入和删除
- **并发安全**：基于 CAS 操作实现无锁并发
- **弱一致性**：size 属性可能存在少量偏差
- **延迟清理**：采用逻辑删除 + 物理清理策略
- **动态层级**：根据 size 动态调整最大层级（8/12/16）


## DelayQueue
### Delayed
```cj
public interface Delayed<T> <: Comparable<T> where T <: Delayed<T> {
    //只要Delayed实例确定了，delayedAt的值就必须是确定的，不能再改变
    prop delayedAt: DateTime

    func compare(other: T): Ordering {
        delayedAt.compare(other.delayedAt)
    }
}
```

### `DelayQueue<T> where T <: Delayed<T>`
```cj
public class DelayQueue<T> <: Queue<T> where T <: Delayed<T> {
    public init()
    //同步函数，返回前通知所有等待数据的线程
    public func add(element: T): Unit
    //非同步函数，返回队列头部数据，不删除队列头
    public func peek(): ?T
    //同步函数，如果队列为空则等待直到非空，否则等待队列头部数据的延迟时间后返回
    public func remove(): ?T
    //同步函数，如果队列为空则等待直到非空或超时，否则等待队列头部数据的延迟时间后返回
    public func remove(timeout: Duration): ?T
    //非同步函数，获取队列大小
    public prop size: Int64
    //非同步函数，判断队列是否为空
    public func isEmpty(): Bool
    //非同步函数，获取迭代器，返回的迭代器的next函数是同步的
    public func iterator(): Iterator<T>
}
```

## 补充：README 未展开的公开面（以源码为准）

- **`Executors` / `Executor` / `ExecutorFuture`**（`Executor.cj`）：线程池 + Future ——
  `Executors(n)` 创建，`call(task)` / `tryCall(task)` / `call(limiter, task)` 提交，`get(...)` 取结果。
- **事件总线**（`eventbus/`）：`EventBus`（`init(workers, maxWaitingJobPerWorker, fullJobQueueStrategy,
  toThrowIfNotMatch, abilities)`，方法 `arrange` / `arrangeAndGet` / `register` / `retireAll`）、
  `Event`（抽象事件基类：`name` / `getData` / `setData` / `deliverResult` / `workerId`）、
  `EndEvent`（返回它以结束任务）、`Worker` / `JobQueue`；异常 `EventBusException`（队列满 / 超时）。
- **`SyncPriorityQueue<T>`**（`SyncPriorityQueue.cj`）：并发优先队列 ——
  `init(comparator, capacity, overSizePolicy)`、`create` / `createReverse`、`peek` / `remove` / `add`。
- **其它并发容器与工具**：`ConcDict`（字典接口，部分方法在接口内已有默认实现）、`ConcHashDict`（`toArray()` 等）、
  `ConcurrentHashSet`、`AtomicInteger` 与 `ExtendAtomic{Int8..UInt64}`（`fetchIncr` / `incrFetch` / `addFetch` …）、
  `Constants.get<T>`（键为 `TypeInfo.of<T>() + key`，类型不符抛 `TypeNotMatchException`）。
- **异常**（`exception/`）：`ConcurrentException`、`LoadBalanceException`、`RateLimiterException`、
  `ReadWriteSyncerException`、`TimeoutException`；`RateLimiter` 在 `timeout <= 0` 时抛 `RateLimiterException`，
  `UnlimitedRateLimiter` 内部用 `Duration.Max`。
- **负载均衡的用例**：`src/LoadBalance_test.cj`（等权 50/50、2:1 → 67/33、4:1 → 80/20、随机两档）。
- ⚠️ `doc/ConcurrentHashSet.md` 当前正文与标题不符（内容是 `LoadBalanceAlgo` 接口），需要重写。