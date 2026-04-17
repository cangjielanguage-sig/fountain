## 事件调度器`Dispatcher`
```cj
/**
 * 所有事件执行器都注册到调度器实现类的实例当中
 * 所有函数的category参数都是用来区分流程的标识。
 * tag是同一流程的版本标识，同一流程的不同版本不能长时间共存，应当尽快删除旧版
 */
public abstract class Dispatcher <: Accepter & EndExecutorGetter {
    /**
     * 注册开始事件执行器，一个流程只能有一个开始事件执行器
     * @param name  开始事件名，必须与流程的第一个任务事件执行器所拥有的事件名相同
     */
    public func registerStart(category!: String, tag!: String, name!: String): Unit
    /**
     * 注册错误事件执行器，一个流程只能有一个错误事件执行器
     */
    public func registerError(category!: String, tag!: String): Unit
    /**
     * 注册结束事件执行器，一个流程只能有一个结束事件执行器
     */
    public func registerEnd(category!: String, tag!: String): Unit
    /**
     * 注册任务事件执行器，一个流程可以有大于等于一个开始事件执行器
     */
    public func registerTask(category!: String, tag!: String, name!: String, task!: (Event) -> Event): Unit
    /**
     * 调度事件执行器。必须先接收到一个事件才能调用本函数
     */
    protected func dispatch(): Unit
    /**
     * 招收一个事件
     */
    public func accept(event: Event): Unit
    /**
     * 接收一个事件并开始流程
     */ 
    public func start(event: StartEvent): Dispatcher
    /**
     * 得到结束执行器，如果没有就抛出异常
     */
    public func get(): EndExecutor
    /**
     * 立即返回结束执行器，如果没有就返回None
     */
    public func tryGet(): ?EndExecutor
    /**
     * 遍历所有注册到当前调度器中的执行器，用执行器对应的事件调用predicate，删除predicate返回true的那些执行器
     */
    public func removeIf(predicate: (Event) -> Bool): Unit
}
```

### 同步调度器`ImmediateDispatcher`
```cj
public class ImmediateDispatcher <: Dispatcher {
    public func registerStart(category!: String, tag!: String, name!: String): Unit 
    public func registerError(category!: String, tag!: String): Unit 
    public func registerEnd(category!: String, tag!: String): Unit 
    public func registerTask(category!: String, tag!: String, name!: String, task!: (Event) -> Event): Unit 
    private var end = None<EndExecutor>
    protected func dispatch(): Unit 
    public func accept(event: Event): Unit 
    public func start(event: StartEvent): Dispatcher 
    public func get(): EndExecutor 
    public func tryGet(): ?EndExecutor 
    public func removeIf(predicate: (Event) -> Bool): Unit 
}
```

### 异步调度器`AsyncDispatcher`
```cj
public class AsyncDispatcher <: Dispatcher & AsyncEndExecutorGetter {
    private static let log = LoggerFactory.getLogger<AsyncDispatcher>()
    private let mutex = Mutex()
    private let endMutex = Mutex()
    private let end = ConcurrentHashMap<Int64, WeakRef<EndExecutor>>()
    private let endCondition = synchronized(endMutex){
        endMutex.condition()
    }
    private let dispatcher = ImmediateDispatcher()
    /**
     * @param clearTimerDuration 清除成员变量end内失效的元素的时间间隔，end内的WeakRef的value返回None即为失效。
     *        获取EndExecutor的线程可能超时以后才将执行结果填充到成员变量end，所以增加一个清除线程，定时清除
     * @param toThrowIfNoExecutor 当事件没有对应的执行器时是否抛出异常，本参数为false时不抛出异常而是记日志
     */
    public AsyncDispatcher(
        clearTimerDuration!: Duration = Duration.second,
        private let toThrowIfNoExecutor!: Bool = true)
    public func registerStart(category!: String, tag!: String, name!: String): Unit 
    public func registerEnd(category!: String, tag!: String): Unit 
    public func registerError(category!: String, tag!: String): Unit 
    public func registerTask(category!: String, tag!: String, name!: String, task!: (Event) -> Event): Unit 
    public func accept(event: Event): Unit 
    public func start(event: StartEvent): Dispatcher 
    public func get(): EndExecutor 
    public func tryGet(): ?EndExecutor 
    public func tryGet(timeout!: Duration): ?EndExecutor 
    public func removeIf(predicate: (Event) -> Bool): Unit 
    protected func dispatch(): Unit 
}
```
