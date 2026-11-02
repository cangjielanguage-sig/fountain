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
package fountain::f_llm.loom

import std.collection.*

import fountain::f_egraph.base.*

/** 记录最后一个步骤的输出（闭包不能捕获可变局部变量） */
class LastEventBox {
    public var value: ?Event = None
}

/**
 * 流程执行器（§9.6 的执行段）。
 *
 * 用 `ImmediateFlow` 组装：每个步骤是一个 `QueuedClosureTask`，步骤闭包的结果按计划的边
 * 改写成**下一个步骤 id** 的事件并回灌派发器；出度为 0 的步骤改写成 `End` 事件收尾。
 *
 * 约束（当前实现）：
 * - 只支持单后继（出度 ≤ 1）；分叉需要 `MultiEvent`，尚未实现，遇到直接报错；
 * - 事件名必须等于下一步的 id——返回自己的名字会「自己喂自己」，派发循环停不下来；
 * - 结束事件名固定为 `EventType.End.toString()`，由 `registerEnd()` 的 EndExecutor 匹配。
 */
public class LoomRunner {
    private let compiler: LoomCompiler

    public init(compiler!: LoomCompiler = LoomCompiler()) {
        this.compiler = compiler
    }

    /**
     * 按计划的边执行整条流程。
     *
     * @param plan 通过校验的计划（内部会再校验一次）
     * @param host 工具/模型宿主；执行期间由 `LoomHostApi` 持有
     * @param input 起始事件（通常是 StartEvent）
     * @return 最后一个步骤产出的事件（名字为步骤 id）
     */
    public func run(plan: FlowPlan, host: LoomHost, input: Event): Event {
        plan.validate()
        let order = topologicalOrder(plan)
        if(order.isEmpty()){
            throw LoomException('loom plan has no steps to run')
        }
        let steps = compiler.compileSteps(plan)
        let successors = successorsOf(plan)
        let flow = ImmediateFlow(category: 'loom', tag: plan.name)
        flow.registerStart(order[0])
        let record = LastEventBox()

        for(id in order){
            let compiled = match(steps.get(id)){
                case Some(value) => value
                case None => throw LoomException('loom step is not compiled: ${id}')
            }
            let next = successors.get(id) ?? ArrayList<String>()
            if(next.size > 1){
                throw LoomException('loom runner does not support fork yet: ${id} -> ${next.size} successors')
            }
            let sink = next.isEmpty()
            let target = if(sink){ EventType.End.toString() }else{ next[0] }
            let body = { e: Event =>
                let produced = compiled(e)
                record.value = produced
                let data = match(produced as DataEvent){
                    case Some(event) => event.data
                    case None => ''
                }
                DataEvent(eventType: if(sink){ EventType.End }else{ EventType.Task },
                          category: e.category, tag: e.tag, name: target, data: data)
            }
            let queued = QueuedClosureTask(id, [id], [target], flow.getDispatcher(), body)
            flow.registerTask(queued)
        }
        flow.registerEnd()

        LoomHostApi.bind(host)
        try{
            match(input as DataEvent){
                case Some(event) => flow.start(event.data)
                case None => flow.start(input)
            }
        }finally{
            LoomHostApi.unbind()
        }
        match(record.value){
            case Some(event) => event
            case None => DummyEvent.instance
        }
    }

    /** 每个步骤的后继列表（保持计划中的顺序） */
    private static func successorsOf(plan: FlowPlan): HashMap<String, ArrayList<String>> {
        let result = HashMap<String, ArrayList<String>>()
        for(edge in plan.edges){
            let list = result.get(edge.from) ?? ArrayList<String>()
            list.add(edge.to)
            result[edge.from] = list
        }
        result
    }

    /** Kahn 拓扑排序；有环时抛错（`validate` 只查自环与缺失端点） */
    public static func topologicalOrder(plan: FlowPlan): ArrayList<String> {
        let indegree = HashMap<String, Int64>()
        let next = HashMap<String, ArrayList<String>>()
        for(item in plan.steps){
            indegree[item.id] = 0
        }
        for(edge in plan.edges){
            let list = next.get(edge.from) ?? ArrayList<String>()
            list.add(edge.to)
            next[edge.from] = list
            indegree[edge.to] = (indegree.get(edge.to) ?? 0) + 1
        }
        let ready = ArrayList<String>()
        for(item in plan.steps){
            if((indegree.get(item.id) ?? 0) == 0){
                ready.add(item.id)
            }
        }
        let order = ArrayList<String>()
        while(!ready.isEmpty()){
            let current = ready.remove(at: 0)
            order.add(current)
            match(next.get(current)){
                case Some(items) =>
                    for(item in items){
                        let left = (indegree.get(item) ?? 0) - 1
                        indegree[item] = left
                        if(left == 0){
                            ready.add(item)
                        }
                    }
                case None => ()
            }
        }
        if(order.size != plan.steps.size){
            throw LoomException('loom plan contains a cycle, cannot execute')
        }
        order
    }
}
