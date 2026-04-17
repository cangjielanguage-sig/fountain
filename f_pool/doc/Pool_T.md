## `Pool<T>`
```cj
/**
 * 本类型无法分辨返还的实例是不是从Pool借出去的，也无法分辨借出实例的Pool跟返回实例的Pool是不是同一个，因此调用giveBack返还实例的时候，如果返回时检查失败了一定会销毁返还的实例，池维护的实例数随之减1。
 */
public class Pool<T> <: Resource {
    public Pool(
        private let initSize!: Int64 = 0, //池初始化对象数量
        private let minSize!: Int64 = 0, //池最小对象数量
        private let maxSize!: Int64 = Int64.Max, //池最大对象数量
        private let idleTimeout!: Duration = Duration.hour, //池化对象空闲时长
        private let checkOnCreation!: Bool = false, //创建对象时是否检查对象性
        private let checkOnBorrowing!: Bool = true, //获取对象时是否检查对象有效性
        private let checkOnReturning!: Bool = true, //返回对象时是否检查对象有效性
        private let clearOnReturning!: Bool = false, //返回对象时是否清除对象内的数据或状态
        private let checkInterval!: Duration = Duration.minute, //空闲的池化对象检查周期
        private let creator!: () -> T, //对象创建函数
        private let checker!: (T) -> Bool, //对象检查函数
        private let destroier!: (T) -> Unit, //对象销毁函数
        private let clear!: (T) -> Unit = {_ =>} //对象清除函数，调用此函数清除对象内的数据或状态
    )
    public init(
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = Int64.Max,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        checkInterval!: Duration = Duration.minute,
        manager!: PooledManager<T>
    )
    public func isClosed(): Bool
    public func close(): Unit
    /**
     * 获取对象
     */
    public func borrow(timeout!: Duration = Duration.Max): ?T
    /**
     * 返还对象
     */
    public func giveBack(object: T): Unit
}
```
```cj
/**
 * 对象管理接口，实现这个接口用来管理对象
 */
public interface PooledManager<T> {
    /**
     * 对象创建函数
     */
    func create(): T
    /**
     * 对象检查函数
     */
    func check(object: T): Bool
    /**
     * 对象销毁函数
     */
    func destroy(object: T): Unit
    /**
     * 清除函数，清除object的内部数据或状态
     */
    func clear(object: T): Unit
}
```
