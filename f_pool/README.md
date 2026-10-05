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
        private let checkInterval!: Duration = Duration.minute, // 池对象检查周期（<= Duration.Zero 或 Duration.Max = 不启用巡检，见下）
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
    // 摘掉某个键的池：先关闭 + 销毁它的池项，再把键从键表里删掉（键不存在 = 空操作）
    public func remove(key: K): Unit
}
```

> `giveBack(key: K, object: V)` 在「这个键从来没有过池」（写错键、把 A 键借出的对象还给 B 键）时抛
> `UnknownKeyException`（`fountain::f_pool.exception`，`f_base.BaseException` 的子类，带 `key` 字段）：
> 池**不归还也不销毁**，对象所有权仍在调用方，由应用层决定处置。在 `finally` / `release()` 这类清理路径里
> 归还时，用 `addSuppressed` 把被顶掉的异常挂上（别丢现场）：
> `catch (e: UnknownKeyException) { if (let Some(p) <- inFlight) { e.addSuppressed(p) }; throw e }`。
> 仓库内使用的池都是 `Pool<V>`（键为 `Unit`，键永远只有一个），不会走到这条路径。详见
> `.autocode/bugs/bug-pool.md` §2.5 `POOL-10`。
>
> `checkInterval` 的一档特殊值：**`<= Duration.Zero`（含 `Duration.Zero`）或 `Duration.Max` 表示不启用巡检**
> —— 不起巡检线程，池也就不做 `minSize` 补足、空闲回收（`idleTimeout`）与 `audit()` 自愈。
> `Duration.Max` 与「永不巡检」等价（原来它只是起一个 `sleep(Duration.Max)`、永不醒来、关池都叫不醒的线程）。
> 想要「很慢但仍要巡检」请给一个很大的**有限**值（如 `Duration.hour`）；这类池在 `close()` 时会立刻
> 被叫醒退出，不会 park 满一个周期。`ArrayPool` / `ArrayListPool` 的默认值 `Duration.Zero`、
> `BytesListOutputStream.builder` 的默认值 `Duration.Max` 都落在这一档。详见 §3 `POOL-L2`。
>
> 同一口径：**`giveBack` 抛异常 ⇒ 对象没有归还**。`clearOnReturning = true` 时 `clear` 回调抛异常，
> `giveBack` 抛 `ClearFailedException`（同为 `f_base.BaseException` 子类、带 `key` 字段，原始回调异常挂在
> `suppressed` 上）—— 不销毁、不结清记账、不进池，池项状态与调用 `giveBack` 之前一样，所有权仍在调用方：
> 修好条件后可以**重试** `giveBack`（重试成功额度照常结清），或者自己销毁它。见 §2.7 `POOL-12`。
>
> `remove(key)` 用于**主动回收键**：键的基数由应用控制时（用户 / 会话 / 文件 …），不回收的话键表、
> 空池条目与巡检每轮 O(#keys) 的遍历都是永久成本（§2.6 `POOL-11`）。摘键只销毁**池内**的项；借用中的
> 对象仍在应用手里，而且摘掉之后 `giveBack(key, …)` 会抛 `UnknownKeyException` —— 那些对象要应用层自己销毁。
> `close()` **幂等**，返回前会销毁所有键的池并清空键表；关停之后 `get` 返回 `None`、`giveBack` 直接销毁，
> 键表不会重新长回来。池这一层不再有 `destroy`（唯一的销毁入口是 `close`）。

## ArrayListPool

`ArrayListPool<T>` 是「池项类型固定为 `ArrayList<T>`」的池：`creator` 固定为 `{=> ArrayList<T>()}`，
**没有** `arraySize` / `creator` 参数（早期文档把它误抄成了 `ArrayPool` 的签名）。
其余参数与 `ArrayPool` 相同（`initSize` / `minSize` / `maxSize` / `elementLife` / `checkInterval` /
`clearOnReturning` / `maxWaiting`），`giveBack` 返回 `Unit`（签名见 `src/ArrayListPool.cj`）。

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

## `maxWaiting`：池耗尽时的等待上限

`maxWaiting` 是**池的初始化参数**（`Pool` / `KeyPool` / `ArrayListPool` / `ArrayPool` / `BytesListOutputStream.builder`
都有，默认 `Duration.second * 30`；builder 用 `setMaxWaiting(maxWaiting)` 设置），语义是「池耗尽时 `get()` 愿意等多久」：

| 调用方传的 `timeout` | 行为 |
| --- | --- |
| `<= Duration.Zero` | 不等待：取不到空闲项立即返回 `None` |
| `Duration.Max`（默认） | 循环等待（每轮 `sleep(1ms)`，**不忙等**）。到达 `maxWaiting` 上限时记 WARN `key pool exhausted but no idle element: size=…/…, keyedSize=…/…, waited …, give up` 并返回 `None`，由调用方决定重试还是失败 |
| 其它有限值 | 等待该时长，等不到返回 `None`（实现见 `KeyPool.get` 的第三个分支） |

`maxWaiting` 自身传 `Duration.Max` 表示**真无限等待**：实现按固定分片等待（既避免 `MonoTime + Duration.Max` 溢出，
也保证能及时看见 `running` 变化）。

> 这条约束的由来：原实现在「池已满但取不到空闲项」时是 `while(running)` 无 sleep 忙等，既占满一个核又会**无日志地永久挂住**
> 调用者（见 `.autocode/bugs/bug-archived-on-20261004.md` 六 / §7.6）。用例
> `KeyPool_test.maxWaitingBoundsInfiniteWait` 直接验证「无限等待也必须受 `maxWaiting` 约束」。

## `clear` / `clearOnReturning` 的语义（`ObjectManager.clear` 默认空体）

- `ObjectManager<V>` / `KeyedObjectManager<K, V>` 的 `clear` 是**默认空实现**（`{_ =>}` / `{_, _ =>}`）——
  「归还时清除」是可选行为，默认什么都不做；要生效必须显式给 `clear`（或 `clearOnReturning = true` 且 `clear` 非空）；
- `setManager(manager)` 会把 `manager` 的 `create` / `check` / `destroy` / `clear` 一并接上；
  `Pool<V>` 内部转交 `KeyPool<Unit, V>` 时也**必须**把 `clear` 继续往下传 —— 漏传会让归还的池项保留旧内容，
  `f_codec` 曾因此出现「编码结果里混进上一条消息的字节 ⇒ 对端解码错位 ⇒ 拆链风暴」
  （见 `.autocode/bugs/bug-archived-on-20261004.md` 六）。

## 内部实现：`BasePool<T>` / `BaseKeyPool<K, V>`（internal，非公开 API）

这两层是 `Pool` / `KeyPool` 的底座（`BasePool` 在 `fountain::f_pool.base` 且为 `protected package`；
`BaseKeyPool` 无 `public`），列出来便于排查问题：

- **`BasePool<T>`**：`add(value): Bool`（返回是否入池；池已关闭时 `false`）/ `giveBack` / `get(checker, destroier)` /
  `check(running, checker, taskPusher)` / `audit(): Int64`（主动审计自愈，返回校正动作数）/
  `close(destroier): Int64`（**关闭并清空**：先置关闭标志，再把池项逐个销毁、返回销毁数，调用方据此同步全局计数；
  `destroy` 已删除，见 `.autocode/bugs/bug-pool.md` §2.6 `POOL-11`）/ `prop size`；
  四个实现是 `FifoPool`（`insertTail` + `append`）、
  `LifoPool`（`insertHead` + `prepend`）、`WeakFifoPool` / `WeakLifoPool`（弱引用队列）。
  **`maxWaiting` 不在这里**：它只决定「取不到池项时上层等多久」，由 `Pool` / `KeyPool` 的 `get` 负责。
- **`BaseKeyPool<K, V>`**：`map: ConcurrentHashMap<K, BasePool<V>>` + 全局计数 `s`。
  `s` 里**既有空闲项也有借出项**（借出不会从队列计数里减掉），所以 `s` 与「各 key 队列 `size` 之和」**任何时刻都该相等**，
  不等就是真脱钩：
  - `add` / `giveBack` / `get(key, checker, destroier)` / `keyedSize(key)` / `entries()` / `size` / `keyCount()`；
  - `check(running, checker, taskPusher)`：逐 key 巡检（条件为 `p.size < max && checker(...)`）；
  - `audit()`：先让每个 key 的队列自愈，再把 `s` 校正为各队列之和（校正的日志由 `KeyPool` 巡检统一 WARN，
    避免同一处校正被打印两次）；
  - `remove(key, fn)`：摘掉一个键的池（先 `map.remove` 再关闭 + 销毁池项），按该池**名下全部**
    `s.fetchSub(...)`；键不存在时是空操作（`POOL-11`）；
  - `close(fn)`：逐个键 `remove`，最后把 `s` 清零 —— 只有这样才能让键表真正清空（`ConcurrentHashMap`
    没有 `clear`，且 `running=false` 之后 `add` / `get` / `keyedSize` 都不再按需建池）；
  - 记账：`s` 与「各 key 队列 `size` 之和」任何时刻都该相等，不同步的话 `size` 会报旧值、
    后续 `get` 会以为池已满而不再新建池项（见归档报告 7.2）。
- `Mode` 到实现的映射：`Fifo` → `FifoPool`，`Lifo` → `LifoPool`，`WeakFifo` / `WeakLifo` → 对应弱引用实现
  （当前无调用方）；`KeyPool` 在 `K` 为 `Unit` 时改用特化的 `UnitKeyPool`（见 `KeyPool.cj` 构造处），
  `IKeyPool<K, V>` 是它们的共同接口。

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
- **其它实现**：`BasePool` / `BaseKeyPool` / `UnitKeyPool` / `IKeyPool` —— 详见上面「内部实现」一节；
- **内部机制（排查用）**：`SyncDeque` 的记账不变量 `size ≡ 队列节点数 + 借出数`、每 10000 次操作的
  `DEQUE-SELFCHECK` 自检、取不到池项时的 `WEDGE-HEAL` 自愈（含滞留 CHECKING 项复原）、
  `LinkedNode.check` 的异常安全与 `nextForGet` 的取值路径 —— 细节见源码与
  `.autocode/bugs/bug-archived-on-20261004.md`（§7.2 / §7.3 / §7.4）。

