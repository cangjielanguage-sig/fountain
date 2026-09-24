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
