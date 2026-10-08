# `fountain::f_egraph` is an event-driven flow utility library
All the top-level declarations below are re-exports of `fountain::f_egraph`
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
     */
    public Event(
        public let eventType!: EventType,
        public let category!: String,
        public let tag!: String,
        public let name!: String 
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
    public init(category!: String, tag!: String, name!: String, data!: Any){
        super(eventType: Start, category: category, tag: tag, name: name, data: data)
    }
}
```

### End event `EndEvent`
```cj
public class EndEvent <: DataEvent {
    public init(category!: String, tag!: String, data!: Any){
        super(eventType: End, category: category, tag: tag, name: EventType.End.toString(), data: data)
    }
}
```

### Task event `TaskEvent`
```cj
public class TaskEvent <: DataEvent {
    public init(category!: String, tag!: String, name!: String, data!: Any){
        super(eventType: EventType.Task, category: category, tag: tag, name: name, data: data)
    }
}
```

### Error event `ErrorEvent`
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

### Multi event `MultiEvent`

```cj
public class MultiEvent <: DataEvent {
    public init(category!: String, tag!: String, events!: Iterable<Event>, 
                session!: String = UUID.random().toHexString()){
        super(eventType: EventType.Task, category: category, tag: tag, name: 'multi', data: events, session: session)
    }
}
```

### Dummy event `DummyEvent`
```cj
public class DummyEvent <: Event {
    public static let instance = DummyEvent()
    private init(){
        super(eventType: EventType.Dummy, category: '', tag: '', name: '')
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
        events!: Array<(String, String, Int64)>
    )
    public prop name: String 
    public prop acceptableEvents: Array<String> 
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
    func registerStart(name: String): Unit
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
    func registerTask(name: String, task: (Event) -> Event): Unit
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
    func registerTaskByFlow<G, F>(name!: String, flow!: F): Unit where G <: EndExecutorGetter, F <: Flow<G> {
        registerTask(name){e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}
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
     * Wrap data together with the category and tag of this instance into a start event and start a flow
     */
    public func start(data: Any): EndExecutorGetter 
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### Asynchronous flow `AsyncFlow`
```cj
public class AsyncFlow <: Flow<AsyncEndExecutorGetter> {
    /**
     * AsyncDispatcher is an instance member variable of this type; this argument clearTimerDuration and
     * toThrowIfNoExecutor instantiate an AsyncDispatcher.
     * One AsyncFlow instance keeps several flows; the executors with the same category form one flow, and several tags
     * of the same category must not coexist for long. The old tag should be deleted as soon as possible.
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
     * Construct a start event from data together with the category and tag of the current instance and start a flow
     */
    public func start(data: Any): AsyncEndExecutorGetter 
    public func emit(eventType!: EventType, name!: String, data!: Any): Unit
}
```

### Flow DSL compiler
```cj
package fountain::f_egraph
/**
 * async means an asynchronous flow and immediate means a synchronous flow; StartEvent is the event name of the event
 * whose type is Start
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
 *         END //END must be either the last event of the braces it is in, or the current braces have no END
 *     }
 * }
 */
public struct FlowDSLCompiler {
    /**
     * Compile the flow orchestration DSL; returns the (category, tag) of the flow
     */
    public static func compile(dsl: String): (String, String)
}
```

### Flow loader
```cj
/**
 * The load() function returns the flow DSL
 */
public interface FlowLoader {
    func load(): ArrayList<String>
}
```

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `BarrierKey` (class), `ConcurrentEndExecutor` (class), `FlowInitializer` (interface), `public struct ProducingDef`, `TaskDef` (struct)
- `BarrierKey`: `let eventName: String`
