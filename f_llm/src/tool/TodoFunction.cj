/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_llm.tool

import fountain::f_bean.macros.*
import fountain::f_data
import fountain::f_data.macros.*
import fountain::f_llm.macros.*

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
/**
 * - ⏸️ 等待用户提供信息
 * - ◯ 尚未开始
 * - 🟡 存在风险，需要用户确认
 * - ✅ 成功完成
 * - ❌ 失败结束
 * - 🔄 进行中
 * - 🗑️ 删除
 */
@ToolCall
public class TodoFunction {
    @FunctionDefinition[
        name: 'addTodo',
        description: '添加待办'
    ]
    public func addTodo(param: TodoSavingParam): FunctionResult {
        let todos = f_data.convert<ArrayList<Todo>>(param.todos.toData()).getOrThrow()
        lookup<TodoFinder>().save(param.task, todos)
        FunctionResult(event: param.nextEvent, result: 'success')
    }

    @FunctionDefinition[
        name: 'todoList',
        description: '查询全部待办'
    ]
    public func todoList(param: TodoListParam): FunctionResult {
        let list = lookup<TodoFinder>().list(param.task)
        let todos = StringGenerator('#### 待办列表\n\n')
        for(todo in list){
            todos.append('''
##### ID: ${todo.id}, title: ${todo.title}
${todo.content}

''')
        }
        FunctionResult(event: param.nextEvent, result: todos.toString())
    }
    @FunctionDefinition[
        name: 'updateTodoStatus',
        description: '更新待办状态'
    ]
    public func updateStatus(param: TodoStatusParam): FunctionResult {
        let updated = lookup<TodoFinder>().updateStatus(param.task, param.id, param.status)
        FunctionResult(event: param.nextEvent, result: if(updated == 1){'success'}else{'todo id ${param.id} of task ${param.task} is not found'})
    }
}