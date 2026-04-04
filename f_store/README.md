badger-cj的薄封装
---

```cj
/**
 * badger-cj 的薄封装.
 * setIfAbsent setPreset computeIfAbsent computeIfPresent ttlIfAbsent ttlIfPresent 等函数不是原子的
 */
public struct Store <: Resource {
    /**
     * 使用当前路径初始化
     */
    public init()
    /**
     * @param path 存储路径，默认是空串，表示保存在当前路径. 
     */
    public init(path: String) 
    /**
     * @param path 存储路径
     */
    public init(path: Path)
    public func isClosed(): Bool 
    public func close(): Unit 
    /**
     * 判断键是否存在.
     */
    public func contains(key: String): Bool 
    /**
     * 获取值.
     * @param key 键.
     */
    public func get(key: String): ?Array<Byte> 
    /**
     * 获取数据，如果存在键值对，则尝试把数据解码为T的实例
     * @param key 键.
     */
    public func getData<T>(key: String): ?T where T <: DataFields<T>
    /**
     * 获取键对应的字符串.
     * @param key 键.
     */
    public func getString(key: String): ?String
    /*
     * 更新
     * @param fn 闭包，详细见badge-cj文档
     */
    public func update<T>(fn: (Transaction) -> T): T 
    /**
     * 设置值.
     * @param key 键.
     * @param value 值.
     */
    public func set(key: String, value: Array<Byte>): Unit 
    /**
     * 设置数据。把value序列化为字节数组后保存。
     */
    public func set<T>(key: String, value: T): Unit where T <: DataFields<T>
    /**
     * 批量设置键值对.
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func set<T>(key: String, fn: () -> T): Unit where T <: DataFields<T>
    /**
     * 设置键值对，如果键不存在则设置，如果键存在则返回键对应的值.
     */
    public func setIfAbsent(key: String, value: Array<Byte>): ?Array<Byte> 
    /**
     * 如果键不存在就设置新值并返回None，如果键存在则什么也不做并返回键对应的旧值。
     * @param key 键值对.
     * @param value 值.
     * @return 
     */
    public func setIfAbsent<T>(key: String, value: T): ?T where T <: DataFields<T>
    /**
     * 设置键值对，如果键存在则设置值并返回键对应的旧值，否则什么也不做并返回None。
     */
    public func setIfPresent(key: String, value: Array<Byte>): ?Array<Byte> 
    /**
     * 设置数据，如果键存在则设置新值并返回键对应的旧值，否则什么也不做并返回None。
     * @param key 键.
     * @param value 新值.
     */
    public func sestIfPresent<T>(key: String, value: T): ?Array<Byte> where T <: DataFields<T>
    /**
     * 计算键值对，如果键不存在则设置并返回键对应的新值，如果键存在则返回键对应的旧值。
     */
    public func computeIfAbsent(key: String, fn: () -> Array<Byte>): Array<Byte> 
    /**
     * 计算数据，如果键不存在则设置并返回键对应新值，如果键存在则返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent<T>(key: String, fn: () -> T): T where T <: DataFields<T>
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     * @param key 键.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent(key: String, fn: () -> Array<Byte>): ?Array<Byte>
    /**
     * 计算键值对，如果键不存在则什么也不做并返回None，如果键存在则更新新值返回键对应的旧值。
     */
    public func computeIfPresent<T>(key: String, fn: () -> T): ? T where T <: DataFields<T>
    /**
     * 删除.
     * @param key 键.
     */
    public func delete(key: String): Unit 
    /**
     * 批量设置TTL.
     * @param 迭代器返回的元组依次是键、值和生命周期。
     */
    public func ttl(iterable: Iterable<(String, Array<Byte>, Duration)>): Unit 
    /**
     * 批量设置TTL.
     * @param 迭代器返回的元组依次是键、值和生命周期。
     */
    public func ttl<T>(iterable: Iterable<(String, T, Duration)>): Unit where T <: DataFields<T> 
    /**
     * 设置TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl(key: String, value: Array<Byte>, life: Duration): Unit
    /**
     * 获取TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl<T>(key: String, value: T, life: Duration): Unit where T <: DataFields<T>
    /**
     * 设置TTL.
     * @param key 键.
     * @param life 生命周期.
     */
    public func ttl(key: String, life: Duration): ?Array<Byte> 
    /**
     * TTL设置，如果键不存在则设置并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent(key: String, value: Array<Byte>, life: Duration): ?Array<Byte> 
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfAbsent<T>(key: String, value: T, life: Duration): ?T where T <: DataFields<T>
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfPresent(key: String, value: Array<Byte>, life: Duration): ?Array<Byte> 
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttlIfPresent<T>(key: String, value: T, life: Duration): ?T where T <: DataFields<T>
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent(key: String, life: Duration, fn: () -> Array<Byte>): Array<Byte> 
    /**
     * TTL设置，如果键不存在则设置并返回键对应新值，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfAbsent<T>(key: String, life: Duration, fn: () -> T): T where T <: DataFields<T>
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent(key: String, life: Duration, fn: () -> Array<Byte>): ?Array<Byte>
    /**
     * TTL设置，如果键不存在则什么也不做并返回None，如果键存在则重新设置ttl并返回旧值。
     * @param key 键.
     * @param life 生命周期.
     * @param fn 闭包，返回键对应新值.
     */
    public func computeIfPresent<T>(key: String, life: Duration, fn: () -> T): ?T where T <: DataFields<T>
    /**
     * 只读迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，Array<Byte>是当前迭代的值.
     */
    public func readOnlyIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, Array<Byte>) -> Unit): Unit 
    /**
     * 只读迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，T是当前迭代的值.
     */
    public func readOnlyIterate<T>(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, T) -> Unit): Unit where T <: DataFields<T>
    /**
     * 可写迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，Array<Byte>是当前迭代的值.
     */
    public func updateIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, Array<Byte>) -> Unit): Unit 
    /**
     * 可写迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，T是当前迭代的值.
     */
    public func updateIterate<T>(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, T) -> Unit): Unit where T <: DataFields<T>
    /**
     * 删除指定前缀的键.
     * @param prefix 键前缀.
     */
    public func deletePrefix(prefix: String): Int64 
    /**
     * 删除满足条件的键.
     * @param prefix 键前缀.
     * @param fn 删除闭包，Transaction是当前Transaction，String是当前键，Array<Byte>是当前值，返回true则删除.
     */
    public func deletePrefix(prefix!: String = '', fn!: (Transaction, String, Array<Byte>) -> Bool): Unit 
    /**
     * 删除满足条件的键.
     * @param prefix 键前缀.
     * @param fn 删除闭包，Transaction是当前Transaction，String是当前键，T是当前值，返回true则删除.
     */
    public func deletePrefix<T>(prefix!: String = '', fn!: (Transaction, String, T) -> Bool): Unit where T <: DataFields<T>
    /**
     * 迭代指定键前缀的键值对，内部维持一个长度是1024的ArrayBlockingQueue。
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @return 迭代器，迭代器的元素是(String, Array<Byte>)，元组的第一个值是键，第二个是值.
     */
    public func iterator(prefix!: String = '', reverse!: Bool = false): StdIterator<(String, Array<Byte>)> 
    /**
     * 迭代指定键前缀的键值对
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @return 迭代器，迭代器的元素是(String, T)，元组的第一个值是键，第二个是值.
     */
    public func scanData<T>(prefix!: String = '', reverse!: Bool = false): StdIterator<(String, T)> where T <: DataFields<T>
    /**
     * 迭代指定键前缀的键值对
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @return 迭代器，迭代器的元素是(String, String)，元组的第一个值是键，第二个是值，值以UTF8解码.
     */
    public func scanString(prefix!: String = '', reverse!: Bool = false): StdIterator<(String, String)>
}
```