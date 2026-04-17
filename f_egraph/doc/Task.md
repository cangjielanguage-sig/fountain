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
