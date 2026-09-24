## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 并发安全的字典
未实现`Hashable & Equatable<K>` 也没有实现`Comparable<K>`，目前只提供了
```cj
public interface ConcDict<K, V> <: Collection<(K, V)> {
    /**
     * 根据 key 得到 Map 中映射的值
     * 参数 key - 传递 key，获取 value
     * 返回值 Option<V> - key 对应的值是用 Option 封装的
     */
    func get(key: K): Option<V>

    /**
     * 判断是否包含指定键的映射
     * 参数 key - 传递要判断的 key
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    func contains(key: K): Bool

    /**
     * 判断是否包含指定集合键的映射
     * 参数 keys - 传递待判断的 keys
     * 返回值 Bool - 如果存在，则返回 true；否则，返回 false
     */
    func contains(all!: Collection<K>): Bool

    /**
     * 将指定的值与此映射中指定的键关联
          120
     * 如果映射以前包含键的映射，则旧值将被替换
     * 参数 key - 要放置的键
     * 参数 value - 要分配的值
     * 返回值 Option<V> - 如果赋值之前 key 存在，旧的 value 用 Option 封装；
     * 否则，返回 Option<V>.None
     */
    func add(key: K, value: V): Option<V>

    /**
     * 传递指定元素进行遍历，并按顺序赋值
     * 如果映射以前包含键的映射，则旧值将被替换
     * 参数 element - 传递给遍历赋值的元素
     */
    func add(all!: Collection<(K, V)>): Unit
    /**
     * 如果key存在就返回对应的值，否则保存value并返回None<T>
     */
    func addIfAbsent(key: K, value: V): ?V
    /**
     * 将key对应的值替换为value，如果key不存在等同于add(key, value)
     */
    func replace(key: K, value: V): ?V

    /**
     * 从此映射中删除指定键的映射（如果存在）
     * 参数 key - 传入要删除的 key
     * 返回值 Option<V> - 被移除映射的 V 用 Option 封装
     */
    func remove(key: K): Option<V>

    /**
     * 从此映射中删除指定集合的映射（如果存在）
     * 参数 all - 传人要删除的集合
     */
    func remove(all!: Collection<K>): Unit
    /**
     * 传入 lambda 表达式，如果满足条件，则删除对应的键值
     * 参数 predicate - 传递一个 lambda 表达式进行判断
     */
    func removeIf(predicate: (K, V) -> Bool): Unit
    /**
     * 清除所有键值对
     */
    func clear(): Unit

    /**
     * 运算符重载集合，如果键存在，返回键对应的值，如果不存在，抛出异常。
     * 参数 key - 传递值进行判断
     * 返回值 V - 与键对应的值
     */
    operator func [](key: K): V

    /**
     * 运算符重载集合，如果键存在，新 value 覆盖旧 value，如果键不存在，
     * 添加此键值对
     * 参数 key - 传递值进行判断
     * 参数 value - 传递要设置的值
     */
    operator func [](key: K, value!: V): Unit

    /**
     * 返回 Map 中所有的 key，并将所有 key 存储在一个 Keys 容器中
     * 返回值 Keys<K> - 保存所有返回的 key
     */
    func keys(): Collection<K>

    /**
     * 返回 Map 中所有的 value，并将所有 value 存储在一个 Values 容器中
     * 返回值 Values<V> - 保存所有返回的 value
     */
    func values(): Collection<V>

    /**
     * 返回 Map 中所有的元素个数
     * 返回值 Int64 - 元素个数
     */
    prop size: Int64

    /**
     * 检查 Map 是否为空
     * 返回值 Bool - 如果是，则返回 true; 否则，返回 false
     */
    func isEmpty(): Bool

    /**
     * 返回 Map 的迭代器
     * 返回值 Iterator<(K,V)> - Map 的迭代器
     */
    func iterator(): Iterator<(K, V)>
    /**
     * key和当前dict中的key对应的值作fn的参数，如果fn返回Some则将值保存到dict，如果返回None将原键值对删除
     * 本函数返回值是执行fn之前保存在dict中的值，如果key在之前不存在返回None
     */
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V
    /**
     * 如果key不存在，将fn的返回值存入dict，并返回fn的返回，如果key存在就返回key对应的值
     */
    func addIfAbsent(key: K, fn: () -> V): V
    /**
     * 如果key存在，将fn的返回值存入dict，并返回dict之前的值，如果key不存在就返回None
     */
    func addIfPreset(key: K, fn: () -> V): ?V
    /**
     * 如果key存在，用key对应的值做参数调用predicate，且predicate返回true，就删除键值对，并返回None，
     * 如果predicate返回false就返回key对应的值。如果key不存在返回None。
     */
    func removeIf(key: K, predicate: (V) -> Bool): ?V
}

public class ConcHashDict<K, V> <: ConcDict<K, V> {
    /**
     * hasher 是哈希函数，equals 比较两个KEY是否相等
     */
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher 是哈希函数，equals 比较两个KEY是否相等
     * elements 是初始元素
     */
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher 是哈希函数，equals 比较两个KEY是否相等
     * elements 是初始元素
     */
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher 是哈希函数，equals 比较两个KEY是否相等
     * size 是初始容量
     */
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher 是哈希函数，equals 比较两个KEY是否相等
     * size 是初始容量，
     * initElement 的返回值是初始元素，它的参数范围是 0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool)
}
```

## `public class ConcurrentHashSet<T> <: Set<T> where T <: Hashable & Equatable<T>`
并发安全的Set

## 负载均衡
### 轮转法
```cj
public struct RoundRobin<W> <: LoadBalanceAlgo<W> where W <: Addable<W> & Comparable<W>{
    public RoundRobin(private let step: W, private let min: W, private let max: W)
}
```
### 随机权重
```cj
public abstract class RandomWeight<W> <: LoadBalanceAlgo<W> where W <: StdNumber<W> & Addable<W> & Comparable<W> {
    public RandomWeight(protected let min: W, protected let max: W){}
}
public class Int64Weight <: RandomWeight<Int64>
public class Float64Weight <: RandomWeight<Float64>
```
### 负载均衡
```cj
public class LoadBalance<W, D, R> where W <: Addable<W> & Comparable<W> {
    /**
     * min是最小权重，algo是权重算法
     */
    public LoadBalance(private let min: W, private let algo: LoadBalanceAlgo<W>{})
    /**
     * 添加权重和对应的函数
     */
    public func add(weight: W, fn: (D) -> R): Unit
    public func add(all!: Array<(W, (D) -> R)>): Unit
    /**
     * 要执行的数据
     */
    public func call(data: D): R
}
```


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
     * @param timeout 时间窗口
     * @param limit 时间窗口内最大任务数
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
public class ConcurrentSkipListMap<K, V> where K <: Comparable<K>
```

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
    //同步函数，如果队列为空则等待直到非空，否则等待队列头部数据延迟时间后再返回
    //如果等待延迟时间后队列头部数据被其他线程获得，重复这个过程
    public func remove(): ?T
    //同步函数，如果队列为空则等待直到非空或超时，否则等待队列头部数据延迟时间后再返回
    //如果等待延迟时间后队列头部数据被其他线程获得，重复这个过程，
    //每次等待的超时时间为上一次等待的剩余时间
    public func remove(timeout: Duration): ?T
    //非同步函数，获取队列大小
    public prop size: Int64
    //非同步函数，判断队列是否为空
    public func isEmpty(): Bool
    //非同步函数，获取迭代器，返回的迭代器的next函数是同步的
    public func iterator(): Iterator<T>
}
```