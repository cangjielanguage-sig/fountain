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

---

## 待办：暂不实现（2026-11-01 记录）

以下项**不在当前实现范围**，先登记，避免被误认为遗漏。loom 单独排期（见 `f_llm-memory-design.md` §9）。

### B. 占位实现

| 项 | 位置 | 现状 |
|---|---|---|
| 余额查询 zhipu / siliconflow / aliyun | `balance/BalanceQueriers.cj` | 调用抛 `BalanceUnsupportedException`；见 `known-limitations.md` §7 |

### C. 单一实现 / 降级路径

| 项 | 现状 |
|---|---|
| 联网搜索 provider | 只有 `DeepSeekSearchProvider`；Bing/Google/百度等需外部凭据，未实现（§9） |
| OpenAI 兼容端点的 sparse / colbert | `LlmEmbeddingTransport` 只有 dense，用它会 `degraded=true`；三路需 `BgeM3Transport`（§2） |

### D. 外部 / 设计约束

| 项 | 说明 |
|---|---|
| 运行期修改配置 | 永久不支持，必须重启（§0） |
| HTTP 连接级超时 | `stdx.net.http` 无 `connectTimeout`（§1） |
| MySQL 向量索引 | 依赖 MyVector 组件 + 手工 `myvector_index_build`（§3） |
| f_store 单实例、无事务 | 外部组件语义，靠 `repair()` 兜底（§4） |
| 历史数据重建 sparse/colbert | 需显式调用重建工具（§5） |
