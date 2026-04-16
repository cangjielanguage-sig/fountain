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
