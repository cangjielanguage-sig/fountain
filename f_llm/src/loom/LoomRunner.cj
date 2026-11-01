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

/**
 * 流程执行器（§9.6 的执行段）。
 *
 * 当前按**拓扑序串行**执行：`LoomCompiler` 产出的步骤闭包逐个调用，前一步的输出事件
 * 作为后一步的输入。没有直接组装 `f_egraph` 的 `ImmediateFlow`，原因有二：
 *
 * 1. `ImmediateFlow` 的 `Dispatcher` 是私有的，`QueuedClosureTask` 拿不到所属 Dispatcher，
 *    装不进流程（见 f_egraph 的构造约束）；
 * 2. 计划的边是 DAG，而 `Flow` 的注册模型是「事件名 → 下一个任务」的链；
 *    多后继需要拆成 `MultiEvent`，属于后续增强。
 *
 * 串行执行保证语义正确（依赖顺序），并行化留给接入 Flow 之后。
 */
public class LoomRunner {
    private let compiler: LoomCompiler

    public init(compiler!: LoomCompiler = LoomCompiler()) {
        this.compiler = compiler
    }

    /**
     * 按拓扑序执行整条计划。
     *
     * @param plan 通过校验的计划（内部会再校验一次）
     * @param host 工具/模型宿主；执行期间由 `LoomHostApi` 持有
     * @param input 起始事件（通常是 StartEvent）
     * @return 最后一个步骤产出的事件
     */
    public func run(plan: FlowPlan, host: LoomHost, input: Event): Event {
        plan.validate()
        let steps = compiler.compileSteps(plan)
        let order = topologicalOrder(plan)
        LoomHostApi.bind(host)
        var current = input
        try{
            for(id in order){
                match(steps.get(id)){
                    case Some(task) => current = task(current)
                    case None => throw LoomException('loom step is not compiled: ${id}')
                }
            }
        }finally{
            LoomHostApi.unbind()
        }
        current
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
                case Some(successors) =>
                    for(item in successors){
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
