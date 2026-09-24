# pool

## stdx 配置
用stdx的动态链接库路径声明环境变量`CANGJIE_STDX_DYNAMIC_PATH`

## 池的模式
```cj
package pool4cj
public enum Mode{
  | Fifo     // 先进先出，默认
  | Lifo     // 后进先出
  | WeakFifo // 弱引用先进先出，池对象以DEFERRED策略的弱引用维持
  | WeakLifo // 弱引用后进先出，池对象以DEFERRED策略的弱引用维持
}
```

### 池
```cj
//池对象管理器
public interface ObjectManager<V> where V <: Object {
    func create(): V // 创建对象
    func check(value: V): Bool // 检查对象
    func destroy(value: V): Unit // 销毁对象
    func clear(value: V): Unit {} // 清除对象
}
public class PoolBuilder<V> where V <: Object {
    init(){}
    // 设置池对象存储模式
    public func setMode(mode: Mode): This 
    // 设置池初始大小
    public func setInitSize(initSize: Int64): This 
    // 设置池对象最小大小
    public func setMinSize(minSize: Int64): This 
    // 设置池对象最大大小
    public func setMaxSize(maxSize: Int64): This 
    // 设置池对象空闲时间
    public func setIdleTimeout(idleTimeout: Duration): This 
    // 设置是否创建时检查
    public func setCheckOnCreation(checkOnCreation: Bool): This 
    // 设置是否借出时检查
    public func setCheckOnBorrowing(checkOnBorrowing: Bool): This 
    // 设置池对象归还时是否清除
    public func setCheckOnReturning(checkOnReturning: Bool): This 
    // 设置池对象归还时是否清除
    public func setClearOnReturning(clearOnReturning: Bool): This 
    // 设置池对象检查周期
    public func setCheckInterval(checkInterval: Duration): This 
    // 设置创建对象函数
    public func setCreator(creator: () -> V): This 
    // 设置检查对象函数
    public func setChecker(checker: (V) -> Bool): This 
    // 销毁对象函数
    public func setDestroier(destroier: (V) -> Unit): This 
    // 清除对象函数
    public func setClear(clear: (V) -> Unit): This 
    // 池对象管理器
    public func setManager(manager: ObjectManager<V>): This 
    // 创建池对象管理器
    public func build(): Pool<V>
}
public struct Pool<V> <: Resource where T <: Object {
    public init(
        mode!: Mode = Mode.Fifo, // 池对象存储模式
        initSize!: Int64, // 池初始大小
        minSize!: Int64 = 0, // 池最小大小
        maxSize!: Int64 = 10, // 池最大大小
        idleTimeout!: Duration = Duration.hour, // 池对象空闲时间
        checkOnCreation!: Bool = false, // 创建时检查
        checkOnBorrowing!: Bool = true, // 借出时检查
        checkOnReturning!: Bool = true, // 归还时检查
        clearOnReturning!: Bool = false, // 归还时清除
        checkInterval!: Duration = Duration.minute, // 池对象检查周期
        creator!: () -> V, // 创建对象函数
        checker!: (V) -> Bool, // 检查函数
        destroier!: (V) -> Unit, // 销毁函数
        clear!: (V) -> Unit = {_ =>} // 清除函数
    )
    public init(
        mode!: Mode = Mode.Fifo,
        initSize!: Int64,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        clearOnReturning!: Bool = false,
        checkInterval!: Duration = Duration.minute,
        manager!: ObjectManager<V>// 从manager实例获取creaator checker destroier clear
    )
    // 创建池构建器
    public static func builder(): PoolBuilder<V>
    // 获取对象，timeout是获取对象的超时时间，如果timeout <= Duration.Zero 会不等待立即返回
    public func get(timeout!: Duration = Duration.Max): ?V
    // 归还对象
    public func giveBack(value: V): Unit
}
```

### 键池
每个键对应一个池，只有池对象需要销毁，键不需要销毁
```cj
// 键池对象管理器
public interface KeyedObjectManager<K, V> where V <: Object {
    // 创建对象
    func create(key: K): V
    // 检查对象
    func check(key: K, value: V): Bool
    // 销毁对象
    func destroy(key: K, value: V): Unit
    // 清除对象
    func clear(key: K, value: V): Unit {}
}

public class KeyPoolBuilder<K, V> where K <: Hashable & Equatable<K>, V <: Object {
    init(){}
    // 设置池对象存储模式
    public func setMode(mode: Mode): This 
    // 设置池初始对象，按照返回的键创建池，一个键返回多少次就在对应的池创建多少对象
    public func setInitKeys(initKeys: () -> ?K): This 
    // 设置添加初始对象
    public func setinitKeys(initKeys: Iterable<K>): This
    // 设置每个键的池对象最小数量
    public func setMinSize(minSize: Int64): This 
    // 设置每个键的池对象最大数量
    public func setMaxSize(maxSize: Int64): This 
    // 设置整个池的对象总大小，total和maxSize共同影响池对象数量
    public func setTotalSize(totalSize: Int64): This 
    // 设置池对象空闲时间
    public func setIdleTimeout(idleTimeout: Duration): This 
    // 设置对象创建时是否检查
    public func setCheckOnCreation(checkOnCreation: Bool): This 
    // 设置借出时是否检查
    public func setCheckOnBorrowing(checkOnBorrowing: Bool): This 
    // 设置池对象归还时是否检查
    public func setCheckOnReturning(checkOnReturning: Bool): This 
    // 设置池对象归还时是否清除
    public func setClearOnReturning(clearOnReturning: Bool): This 
    // 设置池对象检查周期
    public func setCheckInterval(checkInterval: Duration): This 
    // 设置创建对象函数
    public func setCreator(creator: (K) -> V): This 
    // 设置池对象检查函数
    public func setChecker(checker: (K, V) -> Bool): This 
    // 设置销毁对象函数
    public func setDestroier(destroier: (K, V) -> Unit): This 
    // 设置池对象清除函数
    public func setClear(clear: (K, V) -> Unit): This 
    // 设置池对象管理器
    public func setManager(manager: KeyedObjectManager<K, V>): This 
    // 创建池
    public func build(): KeyPool<K, V> 
}

public class KeyPool<K, V> <: Resource where K <: Hashable & Equatable<K>, V <: Object {
    public KeyPool(
        mode!: Mode = Mode.Fifo, // 池对象存储模式
        initKeys!: () -> ?K, // 池初始对象，按照返回的键创建池，一个键返回多少次就在对应的池创建多少对象
        private let minSize!: Int64 = 0, // 每个键的池最小数量
        private let maxSize!: Int64 = 10, // 每个键的池最大数量
        private let totalSize!: Int64 = maxSize, // 池对象总数，total和maxSize共同影响池对象数量
        private let idleTimeout!: Duration = Duration.hour, // 池对象空闲时间
        private let checkOnCreation!: Bool = false, // 创建时检查
        private let checkOnBorrowing!: Bool = true, // 借出时检查
        private let checkOnReturning!: Bool = true, // 归还时检查
        private let clearOnReturning!: Bool = false, // 归还时清除
        private let checkInterval!: Duration = Duration.minute, // 池对象检查周期
        private let creator!: (K) -> V, // 创建对象函数
        private let checker!: (K, V) -> Bool, // 检查函数
        private let destroier!: (K, V) -> Unit, // 销毁函数
        private let clear!: (K, V) -> Unit = {_, _ =>} // 清除函数
    )
    public init(
        mode!: Mode = Mode.Fifo, // 池对象存储模式
        initKeys!: () -> ?K, // 池初始对象，按照返回的键创建池，一个键返回多少次就在对应的池创建多少对象
        minSize!: Int64 = 0, // 每个键的池最小数量
        maxSize!: Int64 = 10, // 每个键的池最大数量
        totalSize!: Int64 = maxSize, // 池对象总数，total和maxSize共同影响池对象数量
        idleTimeout!: Duration = Duration.hour, // 池对象空闲时间
        checkOnCreation!: Bool = false, // 创建时检查
        checkOnBorrowing!: Bool = true, // 借出时检查
        checkOnReturning!: Bool = true, // 归还时检查
        clearOnReturning!: Bool = false, // 归还时清除
        checkInterval!: Duration = Duration.minute, // 池对象检查周期
        manager!: KeyedObjectManager<K, V> // 从manager实例获取creaator checker destroier clear
    )
    // 创建池构建器
    public static func builder(): KeyPoolBuilder<K, V>
    // 获取对象, timeout是尝试获取对象的超时时间，如果timeout <= Duration.Zero 会不等待立即返回
    public func get(key: K, timeout!: Duration = Duration.Max): ?V
    // 归还对象
    public func giveBack(key: K, object: V): Unit
}
```


### 针对commons-pool的扩展
```cj
public interface ExtendPool<T> where T <: Object{
    func borrowObject(): ?T //借出对象，如果没有可用对象就一直阻塞
    func borrowObject(timeout: Duration): ?T //借出对象，等待timeout如果超时前没有可用对象返回None
    func returnObject(obj: T): Unit //归还对象
}
public interface ExtendKeyPool<K, T> where K <: Hashable & Equatable<T>, T <: Object {
    func borrowObject(key: K): ?T //借出对象，如果没有可用对象就一直阻塞
    func borrowObject(key: K, timeout: Duration): ?T //借出对象，等待timeout如果超时前没有可用对象返回None
    func returnObject(key: K, obj: T): Unit //归还对象
}

extend<T> Pool<T> <: ExtendPool<T> where T <: Object 
extend<K, T> KeyPool<K, T> <: ExtendKeyPool<K, T> where K <: Hashable & Equatable<T>, T <: Object 
```