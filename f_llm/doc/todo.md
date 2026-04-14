## todo
```cj
package fountain::f_llm.finder
public interface TodoFinder {
    /**
     * 保存待办
     * @param task 待办任务名称
     * @param todos 当前task的待办列表
     */
    func save(task: String, todos: ArrayList<Todo>): Unit
    /**
     * 列出待办
     * @param task 待办任务名称
     * @return 待办列表
     */
    func list(task: String): ArrayList<Todo>
    /**
     * 更新待办状态
     * @param task 待办任务名称
     * @param id 待办ID
     * @param status 待办状态
     * @return 更新的待办数量，如果返回的值不是1表示参数错了，或者待办不存在
     */
    func updateStatus(task: String, id: Int64, status: String): Int64
}
```

```cj
package fountain::f_llm.tool
@DataAssist[props fields]
public class TodoSavingParam {
    @JsonStringSchema[description:'流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名称']
    private var task: String = ''
    @JsonArraySchema[description:'待办列表']
    private var todos: ArrayList<TodoSaving> = ArrayList<TodoSaving>()
}
@DataAssist[props fields]
public class TodoSaving {
    @JsonStringSchema[description:'待办标题']
    private var title: String = ''
    @JsonStringSchema[description:'待办详述']
    private var content: String = ''
    @JsonStringSchema[description:'待办状态']
    private var status: String = TODO_STATUS_PENDING
    @JsonArraySchema[description:'前置待办ID列表']
    private var predecessor: ArrayList<Int64> = ArrayList<Int64>()
}
@DataAssist[props fields]
public class TodoListParam{
    @JsonStringSchema[description:'流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名称']
    private var task: String = ''
}
@DataAssist[props fields]
public class TodoStatusParam{
    @JsonStringSchema[description:'流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'任务名称']
    private var task: String = ''
    @JsonStringSchema[description:'待办ID']
    private var id: Int64 = 0
    @JsonStringSchema[description:'新的待办状态']
    private var status: String = ''
}
```

```cj
package fountain::f_llm.tool
@ToolCall
public class TodoFunction {
    @FunctionDefinition[
        name: 'addTodo',
        description: '添加待办'
    ]
    public func addTodo(param: TodoSavingParam): FunctionResult 

    @FunctionDefinition[
        name: 'todoList',
        description: '查询全部待办'
    ]
    public func todoList(param: TodoListParam): FunctionResult 
    @FunctionDefinition[
        name: 'updateTodoStatus',
        description: '更新待办状态'
    ]
    public func updateStatus(param: TodoStatusParam): FunctionResult 
}
```
