# `fountain::f_egraph`是一个事件驱动的流程工具库
下面所有的顶级声明都是`fountain::f_egraph`的重导出
---

## 事件类型
```cj
public enum EventType <: ToString & Hashable & Equatable<EventType> {
    /**
     * 开始事件，一个流程只能有一个开始事件
     */
    | Start
    /**
     * 任务事件
     */
    | Task
    /**
     * 结束事件，一个流程只能有一个结束事件
     */
    | End
    /**
     * 错误事件，一个流程只能有一个错误事件。如果需要处理执行流程时发生的错误，可以把错误包装成任务事件
     */
    | Error
    /**
     * 多事件，一个任务执行器可以发送多个事件，多个事件会合并成一个Multi事件，Multi事件会发送给下一个任务执行器
     */
    | Multi
    /**
     * 哑事件，不做任何事，调度器会忽略这类事件
     */
    | Dummy

    public func toString(): String 
    public func hashCode(): Int64 
    public operator func ==(other: EventType): Bool 
}
```

## 事件
### `Event`
```cj
/**
 * 所有事件的父类
 */
public open class Event <: ToString & Hashable & Equatable<Event> {
    /**
     * @param eventType 事件类型
     * @param category 一个流程内所有事件拥有一致的category
     * @param tag 事件版本号，一个流程发生变更时应当修改tag，同时删除相同category不同tag的流程，相当于流程的版本
     * @param name 事件名称，只有任务事件拥有名字，其它类型的事件使用eventType.toString()代替
     */
    public Event(
        public let eventType!: EventType,
        public let category!: String,
        public let tag!: String,
        public let name!: String 
    )
    /**
     * 事件实例的类不影响事件相等性，事件相等性由eventType category tag name这四个成员变量决定
     */
    public operator func ==(other: Event): Bool 
    public func hashCode(): Int64 
    public func toString(): String 
}
```

### `DataEvent`
```cj
/**
 * 带数据的事件，流程在运行时一定要有数据。没有数据的事件用来在流程初始化时注册执行器
 */
public open class DataEvent <: Event {
    public DataEvent (
        eventType!: EventType,
        category!: String,
        tag!: String,
        name!: String,
        public let data!: Any
    ) 
    public func tryGet<T>(): ?T 
}
```

### 开始事件`StartEvent`
```cj
public class StartEvent <: DataEvent {
    /**
     * 开始事件对应的StartExecutor什么也不做只是把数据转给流程的第一个任务执行器，为了任务执行器能收到事件，开始事件的name必须与第一个任务执行器的事件名一致
     */
    public init(category!: String, tag!: String, name!: String, data!: Any){
        super(eventType: Start, category: category, tag: tag, name: name, data: data)
    }
}
```

### 结束事件`EndEvent`
```cj
public class EndEvent <: DataEvent {
    public init(category!: String, tag!: String, data!: Any){
        super(eventType: End, category: category, tag: tag, name: EventType.End.toString(), data: data)
    }
}
```

### 任务事件`TaskEvent`
```cj
public class TaskEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, data!: Any){
        super(eventType: EventType.Task, category: category, tag: tag, name: name, data: data)
    }
}
```

### 错误事件`ErrorEvent`
```cj
public class ErrorEvent <: DataEvent {
    public init(category!: String, tag!: String, message!: String){
        super(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString(), data: message)
    }
    public init(category!: String, tag!: String, error!: Exception){
        super(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString(), data: error)
    }
}
```

### 多事件`MultiEvent`

```cj
public class MultiEvent <: DataEvent {
    public init(category!: String, tag!: String, events!: Iterable<Event>, 
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Task, category: category, tag: tag, name: 'multi', data: events, session: session)
    }
}
```

### 哑事件`DummyEvent`
```cj
public class DummyEvent <: Event {
    public static let instance = DummyEvent()
    private init(){
        super(eventType: EventType.Dummy, category: '', tag: '', name: '')
    }
}
```

## 事件接收器`Accepter`
事件执行器、事件调度器都是它的子类型
```cj
public interface Accepter {
    func accept(event: Event): Unit
}
```

## 事件执行器`Executor`
```cj
public interface Executor <: Accepter {
    /**
     * 当前执行器接受的事件
     */
    prop acceptable: Event
    /**
     * 执行事件
     */
    func execute(event: Event): Unit
    func accept(event: Event): Unit {
        execute(event)
    }
}
```

### 同步事件执行器`ImmediateExecutor`
```cj
public abstract class ImmediateExecutor <: Executor {
    /**
     * @param acceptingEvent 当前执行器接收的事件
     */
    public ImmediateExecutor(private let acceptingEvent!: Event){}
    /**
     * 返回acceptingEvent
     */
    public prop acceptable: Event 
    /**
     * 执行事件
     */
    public func execute(event: Event): Unit 
}
```

#### 开始事件执行器`StartExecutor`
```cj
public class StartExecutor <: ImmediateExecutor {
    /**
     * 一个流程必须且只能有一个开始事件执行器，它是流程的起点。
     * StartExecutor什么也不做，只是把它的事件发给流程的第一个任务执行器。
     * 
     * @param acceptingEvent 当前执行器接收的事件
     * @param accepter 当前执行器把事件
     */
    public StartExecutor(acceptingEvent!: Event, private let accepter!: Accepter){
        super(acceptingEvent: acceptingEvent)
    }

    public func execute(event: Event) {
        accepter.accept(Task)
    }
}
```

#### 结束事件执行器`EndExecutor`
```cj
/**
 * 一个流程必须且只能有一个结束事件执行器。
 * 结束事件执行器什么也不做只是接收到事件，并在调用它的get/tryGet函数时返回事件包含的数据。
 */
public class EndExecutor <: ImmediateExecutor {
    public init(acceptingEvent!: Event){
        super(acceptingEvent: acceptingEvent)
    }
    private var end = None<Event>
    public func execute(event: Event): Unit {
        end = event
    }
    public func tryGet(): ?Event {
        end
    }
    public func get(): Event {
        end.getOrThrow()
    }
}
```

#### 错误事件执行器`ErrorExecutor`
```cj
/**
 * 一个流程可以有零或一个错误事件执行器。
 * 错误事件执行器把接收到的错误信息包装成fountain::f_egraph.exception.GraphException并抛出去。
 * 如果需要流程内部处理错误，则把错误作为任务事件交给专门的任务事件执行器处理。
 */
public class ErrorExecutor <: ImmediateExecutor {
    public init(acceptingEvent!: Event){
        super(acceptingEvent: acceptingEvent)
    }
    public func execute(event: Event): Unit{
        throw if(let e: DataEvent <- event){
            match(e.data){
                case x: String => GraphException(x)
                case x: Exception => GraphException(x)
                case x => GraphException(TypeInfo.of(x).qualifiedName)
            }
        }else{
            GraphException()
        }
    }
}
```

#### 同步任务事件执行器`TaskExecutor`
```cj
public class TaskExecutor <: ImmediateExecutor {
    /**
     * @param acceptingEvent 当前任务事件执行器接收到的事件
     * @param accepter 当前任务事件执行器的task返回的事件转发的目标
     * @param task 任务事件执行器的逻辑
     *             task: {e => ImmediateFlow(category: e.category, tag: e.tag)
     *                           .emmit(eventType: e.eventType, 'eventName', eventData)}
     *             task: {e => AsyncFlow(category: e.category, tag: e.tag)
     *                           .emmit(eventType: e.eventType, 'eventName', eventData)}
     */
    public TaskExecutor(acceptingEvent!: Event, private let accepter!: Accepter, private let task!: (Event) -> Unit){
        super(acceptingEvent: acceptingEvent)
    }
    /**
     * 使用指定流程作为任务执行器的构造函数参数
     * @param acceptingEvent 当前任务事件执行器接收到的事件
     * @param accepter 当前任务事件执行器的task返回的事件转发的目标
     * @param flow 用一个流程作为任务事件执行器的逻辑
     */
    public static func newByFlow<G, F>(acceptingEvent!: Event, accepter!: Accepter, flow!: F): TaskExecutor where G <: EndExecutorGetter, F <: Flow<G> 
    /**
     * 使用指定的同步流程作为任务执行器的构造函数参数
     * @param acceptingEvent 当前任务事件执行器接收到的事件
     * @param accepter 当前任务事件执行器的task返回的事件转发的目标
     * @param subCategory 子流程的唯一标识
     * @param subTag 子流程的版本
     */
    public static func newByImmediateFlow(acceptingEvent!: Event, accepter!: Accepter, subCategory!: String, subTag!: String): TaskExecutor 
    /**
     * 使用指定的异步流程作为任务执行器的构造函数参数
     * @param acceptingEvent 当前任务事件执行器接收到的事件
     * @param accepter 当前任务事件执行器的task返回的事件转发的目标
     * @param subCategory 子流程的唯一标识
     * @param subTag 子流程的版本
     */
    public static func newByAsyncFlow(acceptingEvent!: Event, accepter!: Accepter, subCategory!: String, subTag!: String): TaskExecutor  
    public func execute(event: Event): Unit {
        accepter.accept(task(event))
    }
}
```

#### 异步任务事件执行器`AsyncTaskExecutor`
```cj
public class AsyncTaskExecutor <: Executor {
    public init(acceptingEvent!: Event, accepter!: Accepter, task!: (Event) -> Unit){
        executor = TaskExecutor(acceptingEvent: acceptingEvent, accepter: accepter, task: task)
    }
    public prop acceptable: Event 
    public func execute(event: Event): Unit 
    public func accept(event: Event): Unit 
}
```

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

## `EndExecutorGetter`
```cj
public interface EndExecutorGetter {
    func get(): EndExecutor 
    func tryGet(): ?EndExecutor
}
```

## `AsyncEndExecutorGetter`
```cj
public interface AsyncEndExecutorGetter <: EndExecutorGetter {
    func tryGet(timeout!: Duration): ?EndExecutor
}
```

## `Task`
```cj
/**
 * 任务
 */
public interface Task{
    /**
     * 任务事件名称
     */
    prop name: String
    /**
     * 可接收的事件，任意一个这些事件都可触发本任务
     */
    prop acceptableEvents: Array<String>
    /**
     * 本任务可能产生的事件，需要产生多个事件可以在exec函数内调用Flow的emit函数发送事件，也可以返回MultiEvent
     */
    prop producingEvents: Array<String>
    /**
     * 任务执行逻辑，用来初始任务事件执行器的函数实参
     */
    func exec(e: Event): Event
}
```
### BarrierTask
```cj
/**
 * 事件标识做key的事件积累到指定数量，作为新事件一次发出
 */
public class BarrierTask<G> <: Task where G <: EndExecutorGetter{
    /**
     * @param name 任务名
     * @param events 可接收的和输出的事件，可接收的事件是元组的第一个元素，
     *               对应的发射事件是元组的第二个元素，
     *               第三个元素是同一事件的数量达到指定数后发送输出事件
     */
    public BarrierTask(
        name!: String,
        events!: Array<(String, String, Int64)>
    )
    public prop name: String 
    public prop acceptableEvents: Array<String> 
    /**
     * 固定返回DummyEvent，同一事件的数据量达到指定数时，构造成新事件调用flow.emit一次发出
     */
    public func exec(e: Event): Event 
}
```

## 事件发射器`Emitter`
```cj
public interface Emitter {
    func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

## 流程`Flow<G> where G <: EndExecutorGetter`
```cj
public interface BaseFlow <:Emitter {
    /**
     * 如果当前流程不是其它流程的子流程就可以删除，返回()；否则会抛出异常
     * @throws GraphException
     */
    func canBeRemoved(): Unit
    /**
     * 返回的是把当前流程当作子流程依赖的其它流程，集合保存的字符串是流程的'${category}-${tag}'
     */
    prop dependencied: ConcurrentHashSet<String>
    /**
     * 删除指定流程，如果有其它流程依赖这个流程作为子流程，会抛出异常
     */
    static func remove(): Unit 
    /**
     * 删除category与指定值相同，但是与当前流程的tag不同的流程
     */
    static func removeExceptCurrentTag(): Unit
    /**
     * 向流程注册开始事件执行器，name是开始事件名，必须与流程的第一个任务事件执行器对应的事件名称相同
     */
    func registerStart(name: String): Unit
    /**
     * 向流程注册结束事件执行器
     */
    func registerEnd(): Unit
    /**
     * 向流程注册结束事件执行器
     */
    func registerError(): Unit
    /**
     * 向流程注册任务事件执行器
     */
    func registerTask(name: String, task: (Event) -> Event): Unit
    /**
     * 向流程注册任务事件执行器
     */
    func registerTask(task: Task): Unit
    /**
     * 由Flow实现实例化时自动调用，开发者不必关心
     */
    func registerMultiEventTask(): Unit
    /**
     * 使用指定的同步流程作为任务执行器的构造函数参数
     * @param subCategory 子流程的唯一标识
     * @param subTag 子流程的版本
     */
    func registerTaskByImmediateFlow(eventName!: String, subCategory!: String, subTag!: String): Unit
    /**
     * 使用指定的异步流程作为任务执行器的构造函数参数
     * @param subCategory 子流程的唯一标识
     * @param subTag 子流程的版本
     */
    func registerTaskByAsyncFlow(eventName!: String, subCategory!: String, subTag!: String): Unit 
    /**
     * 向当前流程发射一个事件。
     * @param eventType 事件类型
     * @param name 事件名
     * @param data 事件数据
     */
    func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
/**
 * 创建一个流程，
 * category是流程唯一标识，tag是流程的版本标识，注册category相同，tag不同的流程以后，之前注册的相同category，不同tag的流程应当尽快删除
 * name是事件执行器所对应的事件名称
 */
public interface Flow<G> <: BaseFlow & Hashable & Equatable<ImmediateFlow> & Equatable<AsyncFlow> & ToString where G <: EndExecutorGetter {
    /**
     * 使用指定流程作为任务执行器的构造函数参数
     * @param flow 任务事件执行器的逻辑
     */
    func registerTaskByFlow<G, F>(name!: String, flow!: F): Unit where G <: EndExecutorGetter, F <: Flow<G> {
        registerTask(name){e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}
    }
    /**
     * 将data包装成开始事件，开始执行一个流程
     */
    func start(data: Any): G
}
```

### 同步流程`ImmediateFlow`
```cj
/**
 * 一个同步调度器是一个流程，ImmediateFlow维持着若干个流程
 */
public class ImmediateFlow <: Flow<EndExecutorGetter> & Hashable & Equatable<ImmediateFlow> {
    public ImmediateFlow(private let category!: String, private let tag!: String)
    public static func remove(category!: String, tag!: String): Unit 
    public func hashCode(): Int64 
    public operator func ==(other: ImmediateFlow): Bool 
    public func registerStart(name: String): Unit 
    public func registerEnd(): Unit 
    public func registerError(): Unit 
    public func registerTask(name: String, task: (Event) -> Event): Unit 
    public func registerTask(task: Task): Unit 
    /**
     * 将data与本实例的category和tag一起包装为开始事件，并开始执行一个流程
     */
    public func start(data: Any): EndExecutorGetter 
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### 异步流程`AsyncFlow`
```cj
public class AsyncFlow <: Flow<AsyncEndExecutorGetter> {
    /**
     * AsyncDispatcher是本类型的实例成员变量，用本参数clearTimerDuration和toThrowIfNoExecutor实例化一个AsyncDispatcher。
     * 一个AsyncFlow实例会维持多个流程，相同category的执行器构成一个流程，相同的category不应长时间同时存在多个tag。应尽快将旧的tag删除。
     */
    public static func initDispatcher(clearTimerDuration!: Duration = Duration.second, toThrowIfNoExecutor!: Bool = true): Unit 
    public AsyncFlow(private let category!: String, private let tag!: String){}
    public static func remove(category!: String, tag!: String): Unit 
    
    public func registerStart(name: String): Unit 
    public func registerEnd(): Unit 
    public func registerError(): Unit 
    public func registerTask(name: String, task: (Event) -> Event): Unit 
    public func registerTask(task: Task): Unit
    /**
     * 将data跟当前实例的category和tag一起构造开始事件并开始执行一个流程
     */
    public func start(data: Any): AsyncEndExecutorGetter 
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### 流程DSL编译器
```cj
package fountain::f_egraph
/**
 * async 表示异步流程，immediate 表示同步流程，StartEvent是类型为Start的事件名
 * async(category, tag): 'StartEvent' => {
 *     task |> {
 *         'out-event' => {
 *              other_task |> {'other-out-event'}
 *         }
 *     }
 *     task1 |> {
 *         event => {task3 |> {END}}
 *         event2 => task4 |> {'in-event'}
 *     }
 *     task2 |> {
 *         END //END 要么是所在花括号的最后一个事件，要么当前花括号没有END
 *     }
 * }
 */
public struct FlowDSLCompiler {
    /**
     * 编译流程编排DSL，返回的是流程的(category, tag)
     */
    public static func compile(dsl: String): (String, String)
}
```

### 流程加载器
```cj
/**
 * load()函数返回的是流程DSL
 */
public interface FlowLoader {
    func load(): ArrayList<String>
}
```
