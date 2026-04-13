标准库不支持的集合

## BitSet
位集
```cj
//实例化一个64比特的位集
public init()
//实例化一个64 * capacity的位集
public init(capacity: Int64)
//将参数复制到一个新的位集
public init(set: BitSet)
//当前的位数
public prop size: Int64
//返回的迭代器迭代每个bit，迭代到的比特是1则返回Some(true)，否则是Some(false)
public func iterator(): Iterator<Bool>
//参数的哈希是否存在于当前的位集
public func contains<T>(value: T): Bool where T <: Hashable
//将参数的哈希保存于当前的位集
public func set<T>(value: T): Bool where T <: Hashable
//将参数的哈希移除当前的位集
public func remove<T>(value: T): Bool where T <: Hashable
//返回当前位集是否存于index
public operator func [](index: UInt32): Bool
public operator func [](index: Int32): Bool
public operator func [](index: UInt64): Bool
public operator func [](index: Int64): Bool
//将指定索引的值改为value
public operator func [](index: UInt32, value!: Bool): Unit
public operator func [](index: Int32, value!: Bool): Unit
public operator func [](index: UInt64, value!: Bool): Unit
public operator func [](index: Int64, value!: Bool): Unit
//指定索引的比特与1位或，并将值改为位或后的值
public operator func |(index: UInt32): Bool
public operator func |(index: Int32): Bool
public operator func |(index: UInt64): Bool
public operator func |(index: Int64): Bool
//指定索引的比特位与1位与，并将值改为位与后的值
public operator func &(index: UInt32): Bool
public operator func &(index: Int32): Bool
public operator func &(index: UInt64): Bool
public operator func &(index: Int64): Bool
//指定索引的比特位与1位异或，并将值改为位异或后的值
public operator func ^(index: UInt32): Bool
public operator func ^(index: Int32): Bool
public operator func ^(index: UInt64): Bool
public operator func ^(index: Int64): Bool
```

## `Dict<K, V>`
一个接口，实现没有实现`Hashable & Equatable<K>`也没有实现`Comparable<K>`实现键值存储
```cj
import std.collection.MapEntryView

public interface Dict<K, V> <: Collection<(K, V)> {
    
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
    func addIfAbsent(key: K, value: V): ?V 
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
    func entryView(k: K): MapEntryView<K, V> 
    func entryView(key: K, fn: (K, ?V) -> ?V): ?V {
        let entry = this.entryView(key)
        let value = fn(entry.key, entry.value)
        entry.value = value
        value
    }
    func addIfAbsent(key: K, fn: () -> V): V {
        let view = entryView(key)
        if (let Some(v) <- view.value) {
            v
        } else {
            let v = fn()
            view.value = v
            v
        }
    }
    func addIfPreset(key: K, fn: () -> V): ?V {
        let view = entryView(key)
        if (let Some(_) <- view.value) {
            let v = fn()
            view.value = v
            v
        } else {
            None<V>
        }
    }
    func removeIf(key: K, predicate: (V) -> Bool): ?V {
        let view = entryView(key)
        if (let Some(v) <- view.value && predicate(v)) {
            view.value = None<V>
            v
        } else {
            None<V>
        }
    }
}
```

## `HashDict<K, V> <: Dict<K, V>
```cj
//哈希字典
public class HashDict<K, V> <: Dict<K, V> {
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     */
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * elements用来初始化填充HashDict
     */
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * 初始容量是size
     */
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * 初始容量是size，
     * initElement用来返回初始化的键值对，传入的参数范围是0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool) 
}
```

## LinkedHashDict
```cj
/**按最近访问遍历的字典*/
public class LinkedHashDict<K, V> <: Dict<K, V> {
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     */
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * elements用来初始化填充HashDict
     */
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * 初始容量是size
     */
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * 初始容量是size，
     * initElement用来返回初始化的键值对，传入的参数范围是0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool) 
}
```

## TreeDict
```cj
/**按指定比较函数比较的排序树字典*/
public class LinkedHashDict<K, V> <: Dict<K, V> {
    /**
     * 用指定比较函数实例化字典
     */
    public TreeDict(private let cmp: (K, K) -> Ordering)
    /**
     * 用elements作为初始元素和指定的比较函数实例化字典
     */
    public init(elements: Array<(K, V)>, cmp: (K, K) -> Ordering)
    /**
     * 用elements作为初始元素和指定的比较函数实例化字典
     */
    public init(elements: Collection<(K, V)>, cmp: (K, K) -> Ordering)
    /**
     * 用指定的比较函数实例化字典，初始容量是size，initElement用来返回初始化的键值对，传入的参数范围是0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), cmp: (K, K) -> Ordering)
}
```

## LinkedHashMap
```cj
/**
 * 按最近访问顺序遍历的HashMap
 */
public class LinkedHashMap<K, V> <: Map<K, V> where K <: Hashable & Equatable<K> {
    /**
     * 不设置最大容量
     */
    public init()
    /**
     * size是初始容量；max如果是true，size也是初始容量
     */
    public init(size: Int64, max: Bool)
    /**
     * 将c的元素添加到新的LinkedHashMap
     */
    public init(c: Collection<(K, V)>)
    /**
     * 将c的元素添加到新的LinkedHashMap
     * size是初始容量；max如果是true，size也是初始容量
     */
    public init(c: Collection<(K, V)>, size: Int64, max: Bool)
    /**
     * size是初始容量；max如果是true，size也是初始容量
     * 用initElement的返回值填充新的LinkedHashMap，参数取值范围是0..size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V))
}
```

## `ValueEqualMapKK, V>` 与 `ValueContainsMap<K, V>`
这是两个接口，所有Map实现和ConcurrentHashMap都可以增加这两个接口的扩展
```cj
public interface Values<V> {
    func values(): Collection<V>
}
public interface ValueContainsMap<K, V> <: Values<V> where K <: Equatable<K> {
    /**
     * 确认当前Map是否包含predicate返回true的值
     */
    func containsValue(predicate: (V) -> Bool): Bool
}
public interface ValueEqualMap<K, V> <: Values<V> where K <: Equatable<K>, V <: Equal<V> {
    /**
     * 确认当前Map是否包含与value相等的值
     */
    func containsValue(value: V): Bool
}
```

## LinkedHashSet
```cj
/**
 * 按最近访问顺序遍历的HashSet
 */
public class LinkedHashSet<T> <: Set<T> where T <: Hashable & Equatable<T> {
    /**
     * 默认初始化的空集合
     */
    public init() 
    /**
     * 使用elements填充新的LinkedHashSet
     */
    public init(elements: Collection<T>) 
    /**
     * 使用elements填充新的LinkedHashSet
     */
    public init(elements: Array<T>) 
    /**
     * 新LinkedHashSet初始容量是size，
     * initElement的返回值用来填充LinkedHashSet，参数范围是0..size
     */
    public init(size: Int64, initElement: (Int64) -> T) 
}
```

## PriorityQueue
优先级队列，容量满时自动扩容
```cj
public class PriorityQueue<T> <: Queue<T> & Iterable<T> & Collection<T> & Growable {
    /**
     * comparator 元素比较器
     * capacity 初始容量
     * overSizePolicy 溢出拒绝策略，fountain::f_base.OverSizePolicy
     */
    public PriorityQueue(
        private let comparator: (T, T) -> Ordering,
        private var capacity!: Int64 = DEFAULT_CAPACITY,
        private let overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    )
    public init(
        comparator: Comparator<T>,
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    )
    public static func create<T>(
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T> where T <: Comparable<T>
    public static func createReverse<T>(
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T> where T <: Comparable<T>
    public static func create(
        comparator: Comparator<T>,
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T>
    /**
     * current size
     */
    public prop size: Int64
    public func isEmpty(): Bool
    /**
     * add an element
     */
    public func add(x: T): Unit
    /**
     * 扩容
     */
    public func grow(): Unit
    /**
     * offer all elements in values to current queue
     */
    public func add(all!: Collection<T>): Unit
    /**
     * is current heap full? if capacity is not greater than 0, heap is infinity
     */
    private func isFull(): Bool
    /**
     * get element on top
     */
    public func peek(): Option<T>
    /**
     * get and remove element on top
     */
    public func remove(): Option<T>
    public func iterator(): Iterator<T>
    public func removeIf(predicate: (T) -> Bool): Unit
    public func toArray(): Array<T>
}
```

## `SetOp<T>`
所有的Set实现都实现此接口的扩展
```cj
public interface SetOp<T> {
    /**
     * 对两个Set返回交集视图
     */
    func intersection<C>(collection: C): Set<T> where C <: Collection<T>
    /**
     * 对两个Set返回并集视图
     */
    func union<C>(collection: C): Set<T> where C <: Collection<T>
    /**
     * 对两个Set返回差集视图
     */
    func difference<C>(collection: C): Set<T> where C <: Collection<T>
}
```

## `DifferenceSetView<T> <: Set<T>`
差集视图

## `IntersectionSetView<T> <: Set<T>`
交集视图

## `UnionSetView<T> <: Set<T>`
并集视图
