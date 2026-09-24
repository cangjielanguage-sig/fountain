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
