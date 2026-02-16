# 强引用堆缓存
1. 强引用
2. 可以为缓存指定寿命
3. 可以为缓存指定最大缓存的对象数
```cj
public class HeapCache<V> where V <: Object {
    /**
     * concurrencyLevel 并发度，默认128
     * maxLife 缓存对象的最大寿命
     * maxSize 缓存对象的最大数
     * checkDuration 缓存的检查周期
     * evictionCallback 缓存对象失效的回调函数
     */
    public HeapCache(
        private let concurrencyLevel!: Int64 = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL,
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
    /**销毁堆缓存，销毁的堆缓存不可再用*/
    public func destroy(): Unit
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