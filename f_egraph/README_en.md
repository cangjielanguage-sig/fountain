# `fountain::f_egraph` is an event-driven flow utility library
All the top-level declarations below are re-exports of `fountain::f_egraph`

Flow scripting relies on `fountain::f_jit`; see the JIT registration surface and script contract below.

## JIT support

`f_egraph` flow orchestration can be described by `f_jit` scripts. At startup `FlowInitializer` creates a compiler, registers the host types, compiles each script returned by `FlowLoader` into a zero-argument function and runs it. The script creates `ImmediateFlow` / `AsyncFlow` instances, calls `ClosureTask.compile` to build task bodies and registers them into the flow, so topology or task-body changes only require editing the script, not recompiling the host.

### Capabilities

| Capability | Entry point | Description |
|---|---|---|
| Scripted flow orchestration | `FlowLoader.load()` + `FlowInitializer` | Each element of `load()` is the complete registration script of one flow |
| Scripted task body | `ClosureTask.compile` | Compiles an `exec` statement sequence into `(Event) -> Event` |
| Script-side event construction | `FlowEventFactory` | `flowTaskEvent` / `flowEndEvent` / `flowErrorEvent` / `flowDummyEvent` / `flowDataOf` |
| Host type registration | `JitHostRegistry.configure` | Manual `ClassDescriptor` registration for the event family, `Emitter`, `BaseFlow`, `ImmediateFlow`, `AsyncFlow` |
| Automatic initialization | `FlowInitializer.initialize` | Creates and configures `Compiler`, injects `ClosureTask`, runs all scripts in order |
| Error propagation | f_jit exceptions | Compile / runtime errors are rethrown unchanged with source sites and codes |

### Minimal setup

Implement `FlowLoader`, register it as a bean, and register a `FlowInitializer` implementation; scripts are compiled and executed automatically at application startup:

```cangjie
import fountain::f_app.InitializerCollection
import fountain::f_bean.macros.*
import fountain::f_egraph.*

@Bean
public class OrderFlowLoader <: FlowLoader {
    public func load(): ArrayList<String> {
        // `script` may come from a file / config / database; see the flow script below
        ArrayList<String>([script])
    }
}

public class AppFlowInitializer <: FlowInitializer {
    static init() {
        InitializerCollection.register(AppFlowInitializer())
    }
}
```

Flow script (one element of `FlowLoader.load()`):

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

The default `FlowInitializer.initialize()`:

1. Creates `Compiler(CompileOptions(DummyDiagnosticsSink()))`;
2. Calls `JitHostRegistry.configure(compiler)` to register host types;
3. Calls `ClosureTask.initCompiler(compiler)` to inject the task compiler;
4. Iterates `FlowLoader.load()` in order, wraps each script as `{ => ... }`, compiles and executes it.

If the host builds its own `Compiler`, repeat steps 1–3 before running scripts. `FlowScriptRunner` is package-internal and not exposed.

### Script-visible API

| Category | Script syntax | Description |
|---|---|---|
| Flow | `ImmediateFlow("order", "v1")` / `AsyncFlow("order", "v1")` | The two positional arguments are `category` / `tag` |
| Registration | `flow.registerStart("created")` / `registerEnd()` / `registerError()` | Start, end and error executors |
| Tasks | `compile(name, acceptable, producing, exec)` | Returns a `ClosureTask`; register it with `flow.registerTask(task)` |
| Flow methods | `flow.removeExceptCurrentTag()` / `flow.canBeRemoved()` / `flow.remove()` | Old-tag cleanup and flow lifecycle |
| Event factory | `flowTaskEvent(c, t, n, data)` / `flowEndEvent(c, t, data)` / `flowErrorEvent(c, t, msg)` / `flowDummyEvent()` | Event constructors are not exposed; use the factory |
| Data access | `flowDataOf(e)` | Returns `data` when it is a `DataEvent` with a `String` payload, otherwise `""` |
| Event fields | `e.category` / `e.tag` / `e.name` / `e.session` | Read-only; `Event.toString()` is available |

The script **cannot** use event constructors, `emit` / `start` / `initDispatcher`, the `registerTask(eventName, closure)` closure overload, or `is` / `as`. Async flows require the host to call `AsyncFlow.initDispatcher(...)` first; `FlowInitializer` does not initialize it implicitly, to avoid overriding host configuration.

### Type registration

| Host type | Registration |
|---|---|
| `Task` / `ClosureTask` / `FlowEventFactory` | `@JitBind`; enrolled by `Compiler.registerInterface` / `registerType` via the macro |
| Event family, `Emitter`, `BaseFlow`, `ImmediateFlow`, `AsyncFlow` | `JitHostRegistry.configure` registers manual `ClassDescriptor`s; event fields are exposed through `HostFieldTable` |
| `ClosureTask.initCompiler` | `@IgnoreJitBinding`; stays `public` but outside the script namespace |
| `BarrierTask<G>` | Generic class, **not JIT-bindable**; use `ClosureTask` for scripted tasks |

### Constraints

- Each element of `FlowLoader.load()` must be the statement sequence of **one flow**; a blank script is a configuration error and throws `GraphException` during initialization.
- The last statement must be a `Unit` expression (by convention `flow.removeExceptCurrentTag()`); f_jit does not parse empty parentheses `()`.
- The first registered task must accept the start event; an event may have only one executor, and duplicate registration throws `GraphException`.
- Any compile or execution failure aborts initialization; later scripts do not run and completed registrations are not rolled back.
- Compile and runtime errors are rethrown unchanged, preserving f_jit source sites and error codes.

See “JIT registration surface”, “JIT task `ClosureTask`” and “Flow script contract” below for the detailed registration table and script contract.

---

## Event types

```cj
public enum EventType <: ToString & Hashable & Equatable<EventType> {
    /**
     * The start event; a flow may have only one start event
     */
    | Start
    /**
     * A task event
     */
    | Task
    /**
     * The end event; a flow may have only one end event
     */
    | End
    /**
     * The error event; a flow may have only one error event. If errors occurring while a flow runs must be handled,
     * they can be wrapped into task events
     */
    | Error
    /**
     * The multi event; a task executor may send several events, which are merged into one Multi event that is sent to
     * the next task executor
     */
    | Multi
    /**
     * The dummy event, which does nothing; the dispatcher ignores such events
     */
    | Dummy

    public func toString(): String 
    public func hashCode(): Int64 
    public operator func ==(other: EventType): Bool 
}
```


## Events

### `Event`
```cj
/**
 * The parent class of all events
 */
public open class Event <: ToString & Hashable & Equatable<Event> {
    /**
     * @param eventType Event type
     * @param category All events within one flow share a consistent category
     * @param tag Event version number; when a flow changes, tag should be modified and the flows with the same category but
     * a different tag should be deleted; it is the version of the flow
     * @param name Event name; only task events have a name, and events of other types use eventType.toString() instead
     * @param session Session id, a random UUID by default; keep it consistent within one flow session
     */
    public Event(
        public let eventType!: EventType,
        public let category!: String,
        public let tag!: String,
        public let name!: String,
        public let session!: String = UUID.random().toHexString()
    )
    /**
     * The class of an event instance does not affect event equality; event equality is determined by the four member
     * variables eventType, category, tag and name
     */
    public operator func ==(other: Event): Bool 
    public func hashCode(): Int64 
    public func toString(): String 
}
```

### `DataEvent`
```cj
/**
 * An event carrying data; a flow must have data while it runs. Events without data are used to register executors when
 * the flow is initialized
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

### Start event `StartEvent`
```cj
public class StartEvent <: DataEvent {
    /**
     * The StartExecutor corresponding to the start event does nothing but hand the data to the first task executor of
     * the flow; for the task executor to receive the event, the name of the start event must equal the event name of
     * the first task executor
     */
    public init(category!: String, tag!: String, name!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: Start, category: category, tag: tag, name: name, data: data, session: session)
    }
}
```

### End event `EndEvent`
```cj
public class EndEvent <: DataEvent {
    public init(category!: String, tag!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: End, category: category, tag: tag, name: EventType.End.toString(), data: data, session: session)
    }
}
```

### Task event `TaskEvent`
```cj
public class TaskEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, data!: Any,
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Task, category: category, tag: tag, name: name, data: data, session: session)
    }
}
```

### Error event `ErrorEvent`
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

### Multi event `MultiEvent`

```cj
public class MultiEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, events!: Iterable<Event>, 
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Multi, category: category, tag: tag, name: name, data: events, session: session)
    }
}
```

### Dummy event `DummyEvent`
```cj
public class DummyEvent <: Event {
    public static let instance = DummyEvent()
    private init(){
        super(eventType: EventType.Dummy, category: '', tag: '', name: '', session: '')
    }
}
```


## Event accepter `Accepter`

Event executors and event dispatchers are both subtypes of it
```cj
public interface Accepter {
    func accept(event: Event): Unit
}
```


## Event executor `Executor`

```cj
public interface Executor <: Accepter {
    /**
     * The event the current executor accepts
     */
    prop acceptable: Event
    /**
     * Execute the event
     */
    func execute(event: Event): Unit
    func accept(event: Event): Unit {
        execute(event)
    }
}
```

### Synchronous event executor `ImmediateExecutor`
```cj
public abstract class ImmediateExecutor <: Executor {
    /**
     * @param acceptingEvent The event the current executor accepts
     */
    public ImmediateExecutor(private let acceptingEvent!: Event){}
    /**
     * Returns acceptingEvent
     */
    public prop acceptable: Event 
    /**
     * Execute the event
     */
    public func execute(event: Event): Unit 
}
```

#### Start event executor `StartExecutor`
```cj
public class StartExecutor <: ImmediateExecutor {
    /**
     * A flow must have exactly one start event executor, which is the starting point of the flow.
     * StartExecutor does nothing but send its event to the first task executor of the flow.
     * 
     * @param acceptingEvent The event the current executor accepts
     * @param accepter The target to which the current executor sends the event
     */
    public StartExecutor(acceptingEvent!: Event, private let accepter!: Accepter){
        super(acceptingEvent: acceptingEvent)
    }

    public func execute(event: Event) {
        accepter.accept(Task)
    }
}
```

#### End event executor `EndExecutor`
```cj
/**
 * A flow must have exactly one end event executor.
 * The end event executor does nothing but receive the event and return the data contained in the event when its
 * get/tryGet function is called.
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

#### Error event executor `ErrorExecutor`
```cj
/**
 * A flow may have zero or one error event executor.
 * The error event executor wraps the received error information into fountain::f_egraph.exception.GraphException and
 * throws it.
 * If the error must be handled inside the flow, pass the error as a task event to a dedicated task event executor.
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

#### Synchronous task event executor `TaskExecutor`
```cj
public class TaskExecutor <: ImmediateExecutor {
    /**
     * @param acceptingEvent The event the current task event executor receives
     * @param accepter The destination to which the event returned by the task of the current task event executor is forwarded
     * @param task The logic of the task event executor
     *             task: {e => ImmediateFlow(category: e.category, tag: e.tag)
     *                           .emmit(eventType: e.eventType, 'eventName', eventData)}
     *             task: {e => AsyncFlow(category: e.category, tag: e.tag)
     *                           .emmit(eventType: e.eventType, 'eventName', eventData)}
     */
    public TaskExecutor(acceptingEvent!: Event, private let accepter!: Accepter, private let task!: (Event) -> Unit){
        super(acceptingEvent: acceptingEvent)
    }
    /**
     * A constructor taking the given flow as the logic of the task executor
     * @param acceptingEvent The event the current task event executor receives
     * @param accepter The destination to which the event returned by the task of the current task event executor is forwarded
     * @param flow Uses a flow as the logic of the task event executor
     */
    public static func newByFlow<G, F>(acceptingEvent!: Event, accepter!: Accepter, flow!: F): TaskExecutor where G <: EndExecutorGetter, F <: Flow<G> 
    /**
     * A constructor taking the given synchronous flow as the logic of the task executor
     * @param acceptingEvent The event the current task event executor receives
     * @param accepter The destination to which the event returned by the task of the current task event executor is forwarded
     * @param subCategory Unique identifier of the sub-flow
     * @param subTag Version of the sub-flow
     */
    public static func newByImmediateFlow(acceptingEvent!: Event, accepter!: Accepter, subCategory!: String, subTag!: String): TaskExecutor 
    /**
     * A constructor taking the given asynchronous flow as the logic of the task executor
     * @param acceptingEvent The event the current task event executor receives
     * @param accepter The destination to which the event returned by the task of the current task event executor is forwarded
     * @param subCategory Unique identifier of the sub-flow
     * @param subTag Version of the sub-flow
     */
    public static func newByAsyncFlow(acceptingEvent!: Event, accepter!: Accepter, subCategory!: String, subTag!: String): TaskExecutor  
    public func execute(event: Event): Unit {
        accepter.accept(task(event))
    }
}
```

#### Asynchronous task event executor `AsyncTaskExecutor`
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


## Event dispatcher `Dispatcher`

```cj
/**
 * All event executors are registered into an instance of a dispatcher implementation class
 * The category argument of every function is the identifier that distinguishes flows.
 * tag is the version identifier of the same flow; different versions of the same flow must not coexist for long, and
 * the old version should be deleted as soon as possible
 */
public abstract class Dispatcher <: Accepter & EndExecutorGetter {
    /**
     * Register the start event executor; a flow may have only one start event executor
     * @param name  Start event name; must equal the event name of the first task event executor of the flow
     */
    public func registerStart(category!: String, tag!: String, name!: String): Unit
    /**
     * Register the error event executor; a flow may have only one error event executor
     */
    public func registerError(category!: String, tag!: String): Unit
    /**
     * Register the end event executor; a flow may have only one end event executor
     */
    public func registerEnd(category!: String, tag!: String): Unit
    /**
     * Register a task event executor; a flow may have one or more start event executors
     */
    public func registerTask(category!: String, tag!: String, name!: String, task!: (Event) -> Event): Unit
    /**
     * Dispatch the event executors. This function may be called only after an event has been received
     */
    protected func dispatch(): Unit
    /**
     * Accept one event
     */
    public func accept(event: Event): Unit
    /**
     * Receive one event and start a flow
     */ 
    public func start(event: StartEvent): Dispatcher
    /**
     * Get the end executor; throws when there is none
     */
    public func get(): EndExecutor
    /**
     * Return the end executor immediately, or None when there is none
     */
    public func tryGet(): ?EndExecutor
    /**
     * Traverse all executors registered in the current dispatcher, call predicate with the event corresponding to
     * each executor, and delete the executors for which predicate returns true
     */
    public func removeIf(predicate: (Event) -> Bool): Unit
}
```

### Synchronous dispatcher `ImmediateDispatcher`
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

### Asynchronous dispatcher `AsyncDispatcher`
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
     * @param clearTimerDuration Interval for clearing the invalid elements of the member variable end; an element of
     *        end is invalid when the value of its WeakRef returns None.
     *        A thread getting an EndExecutor may fill the result into the member variable end only after a timeout, so
     *        a clearing thread is added to remove them periodically
     * @param toThrowIfNoExecutor Whether to throw when an event has no corresponding executor; when this argument is
     *        false a log is written instead of throwing
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
 * Task
 */
public interface Task{
    /**
     * Task event name
     */
    prop name: String
    /**
     * The events that may be received; any one of them can trigger this task
     */
    prop acceptableEvents: Array<String>
    /**
     * The events this task may produce; to produce several events you can call the emit function of the Flow inside
     * the exec function, or return a MultiEvent
     */
    prop producingEvents: Array<String>
    /**
     * The task execution logic, used as the function argument that initializes the task event executor
     */
    func exec(e: Event): Event
}
```
### BarrierTask
```cj
/**
 * Events keyed by event identifier are accumulated to the given count and then emitted as one new event
 */
public class BarrierTask<G> <: Task where G <: EndExecutorGetter{
    /**
     * @param name Task name
     * @param events The events that can be received and output; the first element of a tuple is the receivable event,
     *               the second element is the corresponding emitted event, and the third element is the number of the
     *               same event after which the output event is sent
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
     * Always returns DummyEvent; when the number of data items of the same event reaches the given count, a new event
     * is constructed and emitted once through flow.emit
     */
    public func exec(e: Event): Event 
}
```


## Event emitter `Emitter`

```cj
public interface Emitter {
    func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```


## Flow `Flow<G> where G <: EndExecutorGetter`

```cj
public interface BaseFlow <:Emitter {
    /**
     * If the current flow is not a sub-flow of another flow it can be deleted and this returns (); otherwise it throws
     * @throws GraphException
     */
    func canBeRemoved(): Unit
    /**
     * Returns the other flows that depend on the current flow as their sub-flow; the strings held in the set are the
     * '${category}-${tag}' of the flows
     */
    prop dependencied: ConcurrentHashSet<String>
    /**
     * Delete the given flow; throws when other flows depend on it as a sub-flow
     */
    static func remove(): Unit 
    /**
     * Delete the flows whose category equals the given value but whose tag differs from the current flow
     */
    static func removeExceptCurrentTag(): Unit
    /**
     * Register the start event executor with the flow; name is the start event name and must equal the event name
     * corresponding to the first task event executor of the flow
     */
    func registerStart(eventName: String): Unit
    /**
     * Register the end event executor with the flow
     */
    func registerEnd(): Unit
    /**
     * Register the end event executor with the flow
     */
    func registerError(): Unit
    /**
     * Register a task event executor with the flow
     */
    func registerTask(eventName: String, task: (Event) -> Event): Unit
    /**
     * Register a task event executor with the flow
     */
    func registerTask(task: Task): Unit
    /**
     * Called automatically when a Flow implementation is instantiated; developers do not need to care about it
     */
    func registerMultiEventTask(): Unit
    /**
     * A constructor taking the given synchronous flow as the logic of the task executor
     * @param subCategory Unique identifier of the sub-flow
     * @param subTag Version of the sub-flow
     */
    func registerTaskByImmediateFlow(eventName!: String, subCategory!: String, subTag!: String): Unit
    /**
     * A constructor taking the given asynchronous flow as the logic of the task executor
     * @param subCategory Unique identifier of the sub-flow
     * @param subTag Version of the sub-flow
     */
    func registerTaskByAsyncFlow(eventName!: String, subCategory!: String, subTag!: String): Unit 
    /**
     * Emit an event into the current flow.
     * @param eventType Event type
     * @param name Event name
     * @param data Event data
     */
    func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
/**
 * Create a flow:
 * category is the unique identifier of the flow and tag is its version identifier; after registering flows with the
 * same category but different tags, the previously registered flows with the same category and a different tag should
 * be deleted as soon as possible
 * name is the event name corresponding to the event executor
 */
public interface Flow<G> <: BaseFlow & Hashable & Equatable<ImmediateFlow> & Equatable<AsyncFlow> & ToString where G <: EndExecutorGetter {
    /**
     * A constructor taking the given flow as the logic of the task executor
     * @param flow The logic of the task event executor
     */
    func registerTaskByFlow<G, F>(eventName!: String, flow!: F): Unit where G <: EndExecutorGetter, F <: Flow<G> {
        registerTask(eventName){e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}
    }
    /**
     * Wrap data into a start event and start a flow
     */
    func start(data: Any): G
}
```

### Synchronous flow `ImmediateFlow`
```cj
/**
 * A synchronous dispatcher is a flow; ImmediateFlow keeps several flows
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
     * Wrap data with this instance's category and tag into a start event and start a flow.
     * A host may start a flow registered by initialize() with a new instance of the same
     * (category, tag): the start event name is recorded by the dispatcher and is used as a
     * fallback when registerStart was not called locally.
     */
    public func start(data: Any): EndExecutorGetter
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### Asynchronous flow `AsyncFlow`
```cj
public class AsyncFlow <: Flow<AsyncEndExecutorGetter> {
    /**
     * AsyncDispatcher is an instance member of this type, instantiated with clearTimerDuration and toThrowIfNoExecutor.
     * One AsyncFlow instance keeps several flows; executors with the same category form one flow, and several tags of
     * the same category should not coexist for long. Old tags should be removed as soon as possible.
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
     * Wrap data with this instance's category and tag into a start event and start a flow.
     * The start-event-name fallback is the same as ImmediateFlow.
     */
    public func start(data: Any): AsyncEndExecutorGetter
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### JIT registration surface
- `Task`, `ClosureTask` and `FlowEventFactory` are annotated with `@JitBind`; `Compiler.registerInterface` / `registerType` pick up the macro enrollment directly;
- The `Event` family, `Emitter`, `BaseFlow`, `ImmediateFlow` and `AsyncFlow` are **not** annotated: they use named parameters, `operator func` or function-type parameters that the macro cannot expand. `JitHostRegistry` registers them manually with `ClassDescriptor` (`isInterface = true` for interfaces), and event fields are exposed through `HostFieldTable`;
- `@IgnoreJitBinding` (f_jit) may only appear inside a `@JitBind` declaration; both macro expansion and `ReflectRegistrar` skip the annotated member. `ClosureTask.initCompiler` uses it to stay `public` while remaining outside the script namespace.

### JIT task `ClosureTask`
```cj
/**
 * A task whose body is generated from an f_jit script.
 * The compiler is injected by the host (FlowInitializer.initialize calls initCompiler);
 * when it is missing, the first compile lazily creates one and registers the host types.
 */
@JitBind
public class ClosureTask <: Task {
    public init(name: String, acceptableEvents: Array<String>, producingEvents: Array<String>, body: (Event) -> Event)
    /**
     * Host only: injects the compiler and the host type registry; not part of the script namespace.
     */
    @IgnoreJitBinding
    public static func initCompiler(compiler: Compiler): Unit
    /**
     * Compiles a task body and returns a task ready for registerTask.
     * exec is a statement sequence wrapped as `{ e: Event => ... }`; its result must be an Event.
     */
    public static func compile(name: String, acceptableEvents: ArrayList<Any>, producingEvents: ArrayList<Any>, exec: String): ClosureTask
    public prop name: String
    public prop acceptableEvents: Array<String>
    public prop producingEvents: Array<String>
    public func exec(e: Event): Event
}
```
- Both event lists are typed `ArrayList<Any>` (the runtime shape of an f_jit list literal); every element is checked to be a string, otherwise `GraphException`;
- A blank `name`, either empty list, or a blank `exec` raises `GraphException`;
- Compile and runtime errors are rethrown unchanged, keeping f_jit's source site and error code.

### Event factory `FlowEventFactory`
```cj
@JitBind
public class FlowEventFactory {
    public static func flowTaskEvent(category: String, tag: String, name: String, data: String): Event
    public static func flowEndEvent(category: String, tag: String, data: String): Event
    public static func flowErrorEvent(category: String, tag: String, message: String): Event
    public static func flowDummyEvent(): Event
    /** Returns data when it is a String, otherwise an empty string; non-DataEvent yields an empty string. */
    public static func flowDataOf(event: Event): String
}
```
The event constructors declare `data` as `Any`, which has no type code in the script dialect, so the script surface **does not expose event constructors**; payloads are built and read through this factory with `String` values.

### Flow script contract
Every element of `FlowLoader.load()` is the f_jit orchestration script of **one flow** (a statement sequence, wrapped as `{ => ... }` before execution):

```cj
let flow = ImmediateFlow("order", "v1")   // or AsyncFlow("order", "v1")
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

Rules:

1. `registerStart` must come before the first `registerTask`;
2. The first registered task must accept the start event, otherwise `registerTask` raises `GraphException`;
3. Only one executor per event; a duplicate registration raises `GraphException`;
4. Only the `registerTask(task: Task)` overload is available (the closure overload is not in the script namespace; calling it fails at compile time);
5. The last line must be `flow.removeExceptCurrentTag()`, and the last statement must be a `Unit` expression — f_jit does not parse empty parentheses `()`, so the runner appends no sentinel;
6. An asynchronous script requires the host to call `AsyncFlow.initDispatcher(...)` first (`FlowInitializer` never calls it implicitly, so host configuration is not overwritten);
7. `is` / `as` are not allowed on event or flow types; `emit` / `start` / `initDispatcher` are not in the script namespace — use the `flow*` factory functions for payloads.

A blank script is a configuration error and raises `GraphException`; the first failing script aborts initialization, later scripts are not executed, and registrations already done are not rolled back.

`BarrierTask<G>` is generic and **cannot be JIT-bound**; use `ClosureTask` for scripted tasks.

### Migrating from the old DSL
`FlowDSLCompiler`, `TaskDef` and `ProducingDef` are removed. The old DSL and the scripts are two different languages, not text-compatible; rewrite `FlowLoader` with the mapping below:

| Old DSL | New script |
|---|---|
| `immediate(c, t)` / `async(c, t)` | `ImmediateFlow("c", "t")` / `AsyncFlow("c", "t")` |
| `: 'Start' =>` | `flow.registerStart("Start")` |
| Implicit end/error executors | `flow.registerEnd()` / `flow.registerError()` |
| `task |> { 'out' => { ... } }` | `compile("task", ["<accept>"], ["out"], "<exec>")` + `flow.registerTask(t)` |
| Nested tasks | Flattened depth-first in pre-order; order is registration order |
| `END` | No statement; return `flowEndEvent(...)` from the task |
| Automatic old-tag cleanup | Explicit `flow.removeExceptCurrentTag()` as the last line |

For example, the old DSL:

```
immediate(order, v1): 'created' => {
    validate |> {
        'validated' => { pay |> {END} }
    }
}
```

becomes the script shown in "Flow script contract" above (`validate` produces `validated`, `pay` returns the end event).

### Flow loader
```cj
/**
 * Every element returned by load() is the f_jit orchestration script of one flow (see the contract above);
 * a blank script is a configuration error and raises GraphException during initialization.
 */
public interface FlowLoader {
    func load(): ArrayList<String>
}
```

---

## Exceptions

```cj
/**
 * Unified exception type of f_egraph, extending BaseException from f_base.
 */
public class GraphException <: BaseException {
    public init()
    public init(message: String)
    public init(caused: Exception)
    public init(message: String, caused: Exception)
}
```

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `BarrierKey` (class), `ConcurrentEndExecutor` (class), `FlowInitializer` (interface), `JitHostRegistry` (class)
- `JitHostRegistry`: `public static func configure(compiler: Compiler): Unit` (registers the f_egraph host types into a custom `Compiler`; call it before running any script)
- `BarrierKey`: `let eventName: String`
