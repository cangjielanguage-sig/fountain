# f_pool

## 池的模式
```cj
package fountain::f_pool
public enum Mode{
  | Fifo     // 先进先出，默认
  | Lifo     // 后进先出
  | WeakFifo // 弱引用先进先出，池对象以DEFERRED策略的弱引用维持（**当前无调用方**）
  | WeakLifo // 弱引用后进先出，池对象以DEFERRED策略的弱引用维持（**当前无调用方**）
}
```


## `Pool<T>`

```cj
//池对象管理器
public interface ObjectManager<V> {
    func create(): V // 创建对象
    func check(value: V): Bool // 检查对象
    func destroy(value: V): Unit // 销毁对象
    func clear(value: V): Unit {} // 清除对象
}
public class PoolBuilder<V> {
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
    // 设置池对象归还时是否检查
    public func setCheckOnReturning(checkOnReturning: Bool): This 
    // 设置池对象归还时是否清除（只有 clear 非空时才真正清空池项）
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
public struct Pool<V> <: Resource {
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

> 还有三处没在上面的签名里列全：`maxWaiting!: Duration = Duration.second * 30`（`get()` 默认 `Duration.Max` 时的
> 等待上限，超时告警并返回 `None`；builder 对应 `setMaxWaiting(maxWaiting)`）、`isClosed()` / `close()`
> （`Resource` 生命周期）、`PoolException`（builder 未设 `creator` / `checker` / `destroier` 时抛出）。

## `KeyPool<K, V> where K <: Hashable & Equatable<K>`
每个键对应一个池，只有池对象需要销毁，键不需要销毁
```cj
// 键池对象管理器
public interface KeyedObjectManager<K, V> {
    // 创建对象
    func create(key: K): V
    // 检查对象
    func check(key: K, value: V): Bool
    // 销毁对象
    func destroy(key: K, value: V): Unit
    // 清除对象
    func clear(key: K, value: V): Unit {}
}

public class KeyPoolBuilder<K, V> where K <: Hashable & Equatable<K> {
    init(){}
    // 设置池对象存储模式
    public func setMode(mode: Mode): This 
    // 设置池初始对象，按照返回的键创建池，一个键返回多少次就在对应的池创建多少对象
    public func setInitKeys(initKeys: () -> ?K): This 
    // 设置添加初始对象
    public func setinitKeys(initKeys: Iterable<K>): This
    // 每个从keys返回的K值将创建initSizePerKey个池对象，如果keys返回的K值有重复的，则这个K值对应的池对象初始化数就是重复次数*initSizePerKey
    public func setInitKeys(keys: Iterable<K>, initSizePerKey!: Int64 = 1)
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

public class KeyPool<K, V> <: Resource where K <: Hashable & Equatable<K> {
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

## ArrayListPool

`ArrayListPool<T>` 是「池项类型固定为 `ArrayList<T>`」的池：`creator` 固定为 `{=> ArrayList<T>()}`，
**没有** `arraySize` / `creator` 参数（早期文档把它误抄成了 `ArrayPool` 的签名）。
其余参数与 `ArrayPool` 相同（`initSize` / `minSize` / `maxSize` / `elementLife` / `checkInterval` /
`clearOnReturning` / `maxWaiting`），`giveBack` 返回 `Unit`。明细见 `doc/ArrayListPool.md`。

## ArrayPool

池项是**定长数组**：`arraySize` 是每个数组的长度，**尺寸不等于 `arraySize` 的数组归还时不会被接纳**
（`giveBack` 返回 `false`）。

```cj
// 池项是定长数组
ArrayPool<T>(
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = Int64.Max,
        elementLife!: Duration = Duration.Max,
        checkInterval!: Duration = Duration.Zero,
        clearOnReturning!: Bool = false,
        arraySize!: Int64 = 128,
        maxWaiting!: Duration = Duration.second * 30,
        creator!: () -> T = {=> unsafeZeroValue<T>()})
public func get(timeout!: Duration = Duration.Max): ?T
public func giveBack(value: T): Bool
```

## 补充：README 未展开的公开面（以源码为准）

- **`Releasable`**（`BytesCopier.cj`）：`release()` 必须**幂等**，用于把借出的池项还回去；
- **字节池（`f_codec` 编码缓冲的底座）**：
  - `BytesCopier <: BytesCopyTo & BytesCopyFrom`（`byteSize(): ?Int64`、`asBytes(): ?Array<Byte>`）；
  - `PooledBufferBytesCopyTo` / `PooledBufferedBytesCopyFrom`（借 `ArrayPool<Byte>` 做流式拷贝）；
  - `ChainedBytesCopyTo <: Releasable`（`release` 级联释放子项）；
  - `BytesListOutputStream`（`OutputStream & BytesCopyTo & Releasable`，`release()` 幂等，`isEmpty` / `reset`）与
    `BytesListOutputStream.builder(...)` / `BytesListOutputStreamBuilder.build(timeout!)`
    —— 对应 `f_codec` 的 `setBytesPool(...)` 与 `f_rpc` 的 `rpc_codec*` 配置；
- **`PoolDiagnostics`**（`diagnostics/PoolDiagnostics.cj`）：`snapshot()` / `dump()` / `redirectWarningsTo(...)` /
  `installCrashHandler(...)` / `uninstallCrashHandler()` / `CRASH_DUMP_ON_FATAL`，配合 `[FOUNTAIN_POOL.diag]`
  日志做池异常取证；
- **其它实现**：`BasePool`（`Mode` 的四个实现）、`BaseKeyPool`、`UnitKeyPool`、`IKeyPool`（接口）；
  `BasePool.destroy` / `BaseKeyPool.destroy` 返回「销毁掉的数量」，调用方据此同步池的 `size`；
- **内部机制（排查用）**：`SyncDeque` 的记账不变量 `size ≡ 队列节点数 + 借出数`、每 10000 次操作的
  `DEQUE-SELFCHECK` 自检、取不到池项时的 `WEDGE-HEAL` 自愈（含滞留 CHECKING 项复原）、
  `LinkedNode.check` 的异常安全与 `nextForGet` 的取值路径 —— 细节见源码与
  `.autocode/bugs/bug-archived-on-20261004.md`（§7.2 / §7.3 / §7.4）。

