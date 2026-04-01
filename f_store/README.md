badger-cj的薄封装
---

```cj
/**
 * badger-cj 的薄封装.
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
     * 删除.
     * @param key 键.
     */
    public func delete(key: String): Unit 
    /**
     * 设置TTL.
     * @param key 键.
     * @param value 值.
     * @param life 生命周期.
     */
    public func ttl(key: String, value: Array<Byte>, life: Duration): Unit

    /**
     * 只读迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，Array<Byte>是当前迭代的值.
     */
    public func readOnlyIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, Array<Byte>) -> Unit): Unit 
    /**
     * 可写迭代.
     * @param prefix 键前缀.
     * @param reverse 是否倒序.
     * @param fn 迭代闭包，Transaction是当前迭代的Transaction，String是当前迭代的键，Array<Byte>是当前迭代的值.
     */
    public func updateIterate(prefix!: String = '', reverse!: Bool = false, fn!: (Transaction, String, Array<Byte>) -> Unit): Unit 
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
}
```