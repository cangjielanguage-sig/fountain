# `fountain::f_egraph`是一个事件驱动的流程工具库
下面所有的顶级声明都是`fountain::f_egraph`的重导出

流程脚本能力依赖 `fountain::f_jit`；JIT 注册面与脚本契约见下文对应章节。

## JIT 支持

`f_egraph` 的流程编排可以由 `f_jit` 脚本描述：启动时由 `FlowInitializer` 创建编译器、注册宿主类型，再把 `FlowLoader` 返回的每个脚本编译成无参函数并执行。脚本在运行期创建 `ImmediateFlow` / `AsyncFlow`、调用 `ClosureTask.compile` 生成任务并注册到流程，因此流程拓扑或任务体变化只需改脚本，不必重新编译宿主。

### 能力概览

| 能力 | 入口 | 说明 |
|---|---|---|
| 脚本化流程编排 | `FlowLoader.load()` + `FlowInitializer` | `load()` 的每个元素是一个流程的完整注册脚本 |
| 脚本化任务体 | `ClosureTask.compile` | 编译 `exec` 语句序列为 `(Event) -> Event` |
| 脚本侧事件构造 | `FlowEventFactory` | `flowTaskEvent` / `flowEndEvent` / `flowErrorEvent` / `flowDummyEvent` / `flowDataOf` |
| 宿主类型注册 | `JitHostRegistry.configure` | 事件族、`Emitter`、`BaseFlow`、`ImmediateFlow`、`AsyncFlow` 的 `ClassDescriptor` 手工注册 |
| 自动初始化 | `FlowInitializer.initialize` | 创建并配置 `Compiler`、注入 `ClosureTask`、按顺序执行全部脚本 |
| 错误传播 | f_jit 异常 | 编译 / 运行期错误原样上抛，保留站点与错误码 |

### 最小接入

实现 `FlowLoader` 并注册为 bean，再注册一个 `FlowInitializer` 实现；应用启动时会自动编译并执行脚本：

```cangjie
import fountain::f_app.InitializerCollection
import fountain::f_bean.macros.*
import fountain::f_egraph.*

@Bean
public class OrderFlowLoader <: FlowLoader {
    public func load(): ArrayList<String> {
        // script 可由文件 / 配置 / 数据库加载，内容见下方「流程脚本」
        ArrayList<String>([script])
    }
}

public class AppFlowInitializer <: FlowInitializer {
    static init() {
        InitializerCollection.register(AppFlowInitializer())
    }
}
```

流程脚本（`FlowLoader.load()` 的一个元素）：

```text
let flow = ImmediateFlow("order", "v1")
flow.registerStart("created")
flow.registerEnd()
flow.registerError()

let validate = compile("validate", ["created"], ["validated"],
    "flowTaskEvent(\"order\", \"v1\", \"validated\", flowDataOf(e))")
flow.registerTask(validate)

let pay = compile("pay", ["validated"], ["End"],
    "flowEndEvent(\"order\", \"v1\", flowDataOf(e))")
flow.registerTask(pay)

flow.removeExceptCurrentTag()
```

`FlowInitializer.initialize()` 的默认实现是：

1. 创建 `Compiler(CompileOptions(DummyDiagnosticsSink()))`；
2. 调用 `JitHostRegistry.configure(compiler)` 注册宿主类型；
3. 调用 `ClosureTask.initCompiler(compiler)` 注入任务编译器；
4. 按 `FlowLoader.load()` 返回顺序，把每个脚本包裹为 `{ => ... }` 后编译并执行。

宿主若自建 `Compiler`，必须重复第 1–3 步后再执行脚本；`FlowScriptRunner` 是包内实现，不对外暴露。

### 脚本可用 API

| 类别 | 脚本中的写法 | 说明 |
|---|---|---|
| 流程 | `ImmediateFlow("order", "v1")` / `AsyncFlow("order", "v1")` | 两个位置参数是 `category` / `tag` |
| 注册 | `flow.registerStart("created")` / `registerEnd()` / `registerError()` | 开始、结束、错误执行器 |
| 任务 | `compile(name, acceptable, producing, exec)` | 返回 `ClosureTask`，再用 `flow.registerTask(task)` 注册 |
| 流程方法 | `flow.removeExceptCurrentTag()` / `flow.canBeRemoved()` / `flow.remove()` | 旧 tag 清理与流程生命周期 |
| 事件工厂 | `flowTaskEvent(c, t, n, data)` / `flowEndEvent(c, t, data)` / `flowErrorEvent(c, t, msg)` / `flowDummyEvent()` | 脚本面不暴露事件构造器，统一经工厂构造 |
| 读取数据 | `flowDataOf(e)` | `DataEvent` 且 `data` 是 `String` 时返回其值，否则空串 |
| 事件字段 | `e.category` / `e.tag` / `e.name` / `e.session` | 只读；`Event.toString()` 可用 |

脚本**不可用**：事件构造器、`emit` / `start` / `initDispatcher`、`registerTask(eventName, closure)` 闭包重载、`is` / `as`。异步流程需要宿主先调用 `AsyncFlow.initDispatcher(...)`，`FlowInitializer` 不会隐式初始化，避免覆盖宿主配置。

### 类型注册方式

| 宿主类型 | 注册方式 |
|---|---|
| `Task` / `ClosureTask` / `FlowEventFactory` | `@JitBind`，由 `Compiler.registerInterface` / `registerType` 读取宏登记 |
| `Event` 家族、`Emitter`、`BaseFlow`、`ImmediateFlow`、`AsyncFlow` | `JitHostRegistry.configure` 用 `ClassDescriptor` 手工注册；事件字段经 `HostFieldTable` 暴露 |
| `ClosureTask.initCompiler` | `@IgnoreJitBinding`，保持 `public` 但不进入脚本名空间 |
| `BarrierTask<G>` | 泛型类，**不支持 JIT 绑定**；脚本化任务用 `ClosureTask` |

### 约束

- `FlowLoader.load()` 的每个元素必须是**一个流程**的语句序列；空脚本视为配置错误，初始化抛 `GraphException`。
- 脚本末条语句必须是 `Unit` 表达式（约定为 `flow.removeExceptCurrentTag()`）；f_jit 不支持空括号 `()`。
- 第一个注册的任务必须接受开始事件；同一事件只能注册一个执行器，重复注册抛 `GraphException`。
- 任一脚本编译或执行失败都会终止初始化，后续脚本不执行，已完成的注册不回滚。
- 编译错误与运行期错误原样上抛，保留 f_jit 的站点与错误码。

更细的注册表与脚本契约见下文「JIT 注册面」「JIT 任务 `ClosureTask`」「流程脚本契约」。

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
     * @param session 会话标识，缺省为随机 UUID；同一流程会话内保持一致
     */
    public Event(
        public let eventType!: EventType,
        public let category!: String,
        public let tag!: String,
        public let name!: String,
        public let session!: String = UUID.random().toHexString()
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
        session!: String = UUID.random().toHexString(),
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
    public init(category!: String, tag!: String, name!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: Start, category: category, tag: tag, name: name, data: data, session: session)
    }
}
```

### 结束事件`EndEvent`
```cj
public class EndEvent <: DataEvent {
    public init(category!: String, tag!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: End, category: category, tag: tag, name: EventType.End.toString(), data: data, session: session)
    }
}
```

### 任务事件`TaskEvent`
```cj
public class TaskEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Task, category: category, tag: tag, name: name, data: data, session: session)
    }
}
```

### 错误事件`ErrorEvent`
```cj
public class ErrorEvent <: DataEvent {
    public init(category!: String, tag!: String, message!: String,
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString(), data: message, session: session)
    }
    public init(category!: String, tag!: String, error!: Exception,
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Error, category: category, tag: tag, name: EventType.Error.toString(), data: error, session: session)
    }
}
```

### 多事件`MultiEvent`

```cj
public class MultiEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, events!: Iterable<Event>, 
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Multi, category: category, tag: tag, name: name, data: events, session: session)
    }
}
```

### 哑事件`DummyEvent`
```cj
public class DummyEvent <: Event {
    public static let instance = DummyEvent()
    private init(){
        super(eventType: EventType.Dummy, category: '', tag: '', name: '', session: '')
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
     * @param producing 本任务可能产生的事件（Task 契约元数据）
     */
    public BarrierTask(
        name!: String,
        events!: Array<(String, String, Int64)>,
        producing!: Array<String>
    )
    public prop name: String 
    public prop acceptableEvents: Array<String> 
    public prop producingEvents: Array<String> 
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
    func registerStart(eventName: String): Unit
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
    func registerTask(eventName: String, task: (Event) -> Event): Unit
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
    func registerTaskByFlow<G, F>(eventName!: String, flow!: F): Unit where G <: EndExecutorGetter, F <: Flow<G> {
        registerTask(eventName){e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}
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
 * 一个同步调度器是一个流程，ImmediateFlow 维持着若干个流程
 */
public class ImmediateFlow <: Flow<EndExecutorGetter> {
    public ImmediateFlow(let category!: String, let tag!: String)
    public func canBeRemoved(): Unit
    public func remove(): Unit
    public func removeExceptCurrentTag(): Unit
    public prop dependencied: ConcurrentHashSet<String>
    public func hashCode(): Int64
    public operator func ==(other: ImmediateFlow): Bool
    public operator func ==(other: AsyncFlow): Bool
    public func toString(): String
    public func registerStart(eventName: String): Unit
    public func registerEnd(): Unit
    public func registerError(): Unit
    public func registerTask(eventName: String, task: (Event) -> Event): Unit
    public func registerTask(task: Task): Unit
    public func registerMultiEventTask(): Unit
    /**
     * 将 data 与本实例的 category 和 tag 一起包装为开始事件，并开始执行一个流程。
     * 宿主可用新建的同 (category, tag) 实例启动 initialize() 已注册的流程：开始事件名由
     * dispatcher 共享记录，本地 registerStart 未调用时自动回退读取。
     */
    public func start(data: Any): EndExecutorGetter
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### 异步流程`AsyncFlow`
```cj
public class AsyncFlow <: Flow<AsyncEndExecutorGetter> {
    /**
     * AsyncDispatcher 是本类型的实例成员变量，用本参数 clearTimerDuration 和 toThrowIfNoExecutor 实例化一个 AsyncDispatcher。
     * 一个 AsyncFlow 实例会维持多个流程，相同 category 的执行器构成一个流程，相同的 category 不应长时间同时存在多个 tag。应尽快将旧的 tag 删除。
     */
    public static func initDispatcher(clearTimerDuration!: Duration = Duration.second, toThrowIfNoExecutor!: Bool = true): Unit
    public AsyncFlow(let category!: String, let tag!: String)
    public func canBeRemoved(): Unit
    public func remove(): Unit
    public func removeExceptCurrentTag(): Unit
    public prop dependencied: ConcurrentHashSet<String>
    public func hashCode(): Int64
    public operator func ==(other: AsyncFlow): Bool
    public operator func ==(other: ImmediateFlow): Bool
    public func toString(): String
    public func registerStart(eventName: String): Unit
    public func registerEnd(): Unit
    public func registerError(): Unit
    public func registerTask(eventName: String, task: (Event) -> Event): Unit
    public func registerTask(task: Task): Unit
    public func registerMultiEventTask(): Unit
    /**
     * 将 data 跟当前实例的 category 和 tag 一起构造开始事件并开始执行一个流程。
     * 开始事件名回退规则同 ImmediateFlow。
     */
    public func start(data: Any): AsyncEndExecutorGetter
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### JIT 注册面
- `Task`、`ClosureTask`、`FlowEventFactory` 标注 `@JitBind`，由 `Compiler.registerInterface` / `registerType` 直接取用宏登记；
- `Event` 家族、`Emitter`、`BaseFlow`、`ImmediateFlow`、`AsyncFlow` **不标** `@JitBind`：它们使用命名形参、`operator func` 或函数类型形参，宏无法展开；改由 `JitHostRegistry` 用 `ClassDescriptor` 手工注册（接口 `isInterface = true`），事件字段另经 `HostFieldTable` 暴露；
- `f_jit` 的 `@IgnoreJitBinding` 只能出现在 `@JitBind` 声明内部；宏展开与 `ReflectRegistrar` 反射注册**两层**都会跳过被标注成员。`ClosureTask.initCompiler` 用它保持 `public`，但不进入脚本名空间。

### JIT 任务`ClosureTask`
```cj
/**
 * 任务体由 f_jit 脚本生成的任务。
 * 编译器由宿主注入（FlowInitializer.initialize 会调用 initCompiler），
 * 未注入时首次 compile 惰性创建一个并完成宿主类型注册。
 */
@JitBind
public class ClosureTask <: Task {
    public init(name: String, acceptableEvents: Array<String>, producingEvents: Array<String>, body: (Event) -> Event)
    /**
     * 宿主专用：注入编译器和宿主类型注册表，不在脚本名空间。
     */
    @IgnoreJitBinding
    public static func initCompiler(compiler: Compiler): Unit
    /**
     * 编译任务体，返回可直接 registerTask 的任务。
     * exec 是任务体语句序列，包裹为 `{ e: Event => ... }` 后编译，返回值必须是 Event。
     */
    public static func compile(name: String, acceptableEvents: ArrayList<Any>, producingEvents: ArrayList<Any>, exec: String): ClosureTask
    public prop name: String
    public prop acceptableEvents: Array<String>
    public prop producingEvents: Array<String>
    public func exec(e: Event): Event
}
```
- 两个事件列表形参声明为 `ArrayList<Any>`（f_jit 列表字面量的运行时形态），内部逐元素校验字符串，非字符串抛 `GraphException`；
- `name`、两个事件列表、`exec` 去空白后为空 → `GraphException`；
- 编译错误与运行期错误原样上抛，保留 f_jit 的站点与错误码。

### 事件工厂`FlowEventFactory`
```cj
@JitBind
public class FlowEventFactory {
    public static func flowTaskEvent(category: String, tag: String, name: String, data: String): Event
    public static func flowEndEvent(category: String, tag: String, data: String): Event
    public static func flowErrorEvent(category: String, tag: String, message: String): Event
    public static func flowDummyEvent(): Event
    /** data 为 String 时返回其值，否则返回空串；非 DataEvent 返回空串。 */
    public static func flowDataOf(event: Event): String
}
```
事件族的构造器把 `data` 声明为 `Any`，脚本方言没有对应类型码，因此脚本面**不暴露事件构造器**，一律经该工厂以 `String` 载荷构造与读取。

### 流程脚本契约
`FlowLoader.load()` 的每个元素是**一个流程**的 f_jit 编排脚本（语句序列，执行前包裹为 `{ => ... }`）：

```cj
let flow = ImmediateFlow("order", "v1")   // 或 AsyncFlow("order", "v1")
flow.registerStart("created")
flow.registerEnd()
flow.registerError()

let validate = compile("validate", ["created"], ["validated"],
    "flowTaskEvent(\"order\", \"v1\", \"validated\", flowDataOf(e))")
flow.registerTask(validate)

let pay = compile("pay", ["validated"], ["End"], "flowEndEvent(\"order\", \"v1\", flowDataOf(e))")
flow.registerTask(pay)

flow.removeExceptCurrentTag()
```

约束：

1. `registerStart` 必须在第一个 `registerTask` 之前；
2. 第一个注册的任务必须接受开始事件，否则 `registerTask` 抛 `GraphException`；
3. 同一事件只能注册一个执行器，重复注册抛 `GraphException`；
4. 只用 `registerTask(task: Task)` 重载（闭包重载不在脚本名空间，调用会在编译期报「未注册方法」）；
5. 末行必须是 `flow.removeExceptCurrentTag()`，且末条语句必须是 `Unit` 表达式——f_jit 不支持空括号 `()`，执行器不追加哨兵；
6. 异步脚本的前提是宿主已调用 `AsyncFlow.initDispatcher(...)`（`FlowInitializer` 不隐式调用，避免覆盖宿主配置）；
7. 事件与流程类型上不得使用 `is` / `as`；`emit` / `start` / `initDispatcher` 不在脚本名空间，事件载荷用 `flow*` 工厂函数。

空脚本视为配置错误，初始化时抛 `GraphException`；任一脚本失败即终止初始化，后续脚本不执行，已完成的注册不回滚。

`BarrierTask<G>` 是泛型类，**不支持 JIT 绑定**；需要脚本化任务时用 `ClosureTask`。

### 从旧 DSL 迁移
`FlowDSLCompiler`、`TaskDef`、`ProducingDef` 已删除。旧 DSL 与脚本是两种语言，不是文本兼容关系，需要按下表重写 `FlowLoader`：

| 旧 DSL | 新脚本 |
|---|---|
| `immediate(c, t)` / `async(c, t)` | `ImmediateFlow("c", "t")` / `AsyncFlow("c", "t")` |
| `: 'Start' =>` | `flow.registerStart("Start")` |
| 隐式结束/错误执行器 | `flow.registerEnd()` / `flow.registerError()` |
| `task |> { 'out' => { ... } }` | `compile("task", ["<accept>"], ["out"], "<exec>")` + `flow.registerTask(t)` |
| 嵌套任务 | 按深度优先先序展开为连续语句，顺序即注册顺序 |
| `END` | 无对应语句，任务返回 `flowEndEvent(...)` 即结束 |
| 末尾自动清理旧 tag | 脚本末行显式 `flow.removeExceptCurrentTag()` |

例如旧 DSL：

```
immediate(order, v1): 'created' => {
    validate |> {
        'validated' => { pay |> {END} }
    }
}
```

改写为上面的「流程脚本契约」示例即可（`validate` 产出 `validated`，`pay` 返回结束事件）。

### 流程加载器
```cj
/**
 * load() 的每个元素是一个流程的 f_jit 编排脚本（见上节契约）；
 * 空脚本视为配置错误，初始化时抛 GraphException。
 */
public interface FlowLoader {
    func load(): ArrayList<String>
}
```



---

## 异常

```cj
/**
 * f_egraph 的统一异常类型，继承 f_base 的 BaseException。
 */
public class GraphException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`BarrierKey`（class）、`ConcurrentEndExecutor`（class）、`FlowInitializer`（interface）、`JitHostRegistry`（class）
- `BarrierKey`：`let eventName: String`
- `JitHostRegistry`：`public static func configure(compiler: Compiler): Unit`（把 f_egraph 的宿主类型注册到自定义 `Compiler`，须在执行脚本前调用）
