## `FutureTask<T>`
```cj
public class FutureTask<T> <: AbstractFutureTask {
    //创建新的FutureTask
    //shutdownSubOnFinish: 是否在当前FutureTask结束时结束子任务
    //fn: 任务函数
    public init(shutdownSubOnFinish: Bool, fn: () -> T)
    //创建新的FutureTask，此时shutdownSubOnFinish为true
    public init(fn: () -> T)
    //返回当前线程ID对应的FutureTask，只有在FutureTask内部调用此函数才有效，否则将抛出异常
    public static func current(): FutureTask<T> 
    //返回当前FutureTask执行结束后的结果，即构造函数参数fn的返回结果
    public func get(): T 
    //返回当前FutureTask执行结束后的结果，即构造函数参数fn的返回结果，如果调用此函数超过timeout的时间任务还没有结束，将抛出异常
    public func get(timeout: Duration): T
    //返回当前FutureTask执行结束后的结果，即构造函数参数fn的返回结果，如果调用此函数时任务还没有结束，将返回None
    public func tryGet(): ?T 
    //结束当前FutureTask，并按照shutdownSubOnFinish决定是否结束子任务
    public func shutdown(): Unit 
    //结束当前FutureTask的所有子任务。
    public static func shutdownCurrentSubThreads(): Unit 
}
```