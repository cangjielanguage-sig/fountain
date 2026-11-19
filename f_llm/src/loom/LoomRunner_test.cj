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
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_egraph.base.*

@Test
class LoomRunner_test {
    private func start(): Event {
        StartEvent(category: 'loom', tag: 'p', name: 'start', data: 'go')
    }

    private func jitPlan(): FlowPlan {
        let plan = FlowPlan('chain')
        let first = StepPlan('fetch', 'jit')
        first.input = 'let fetch_result = "A"'
        let second = StepPlan('sum', 'jit')
        second.input = 'let sum_result = "B"'
        plan.steps.add(first)
        plan.steps.add(second)
        plan.edges.add(EdgePlan('fetch', 'sum'))
        plan
    }

    @TestCase
    func testTopologicalOrderFollowsEdges(): Unit {
        let order = LoomRunner.topologicalOrder(jitPlan())
        @Expect(order.size, 2)
        @Expect(order[0], 'fetch')
        @Expect(order[1], 'sum')
    }

    @TestCase
    func testCycleRejected(): Unit {
        let plan = FlowPlan('cycle')
        plan.steps.add(StepPlan('a', 'jit'))
        plan.steps.add(StepPlan('b', 'jit'))
        plan.edges.add(EdgePlan('a', 'b'))
        plan.edges.add(EdgePlan('b', 'a'))

        var message = ''
        try{
            LoomRunner.topologicalOrder(plan)
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('cycle'), true)
    }

    @TestCase
    func testRunsStepsInOrderAndReturnsLastEvent(): Unit {
        let host = RunnerHost()
        let out = LoomRunner().run(jitPlan(), host, start())
        @Expect(out.name, 'sum')
        match(out){
            case event: DataEvent => @Expect(event.tryGet<String>().getOrThrow(), 'B')
            case _ => @Expect(false, true)
        }
    }

    @TestCase
    func testToolAndLlmStepsGoThroughHost(): Unit {
        let plan = FlowPlan('tools')
        let tool = StepPlan('fetch', 'tool')
        tool.tool = 'echo'
        tool.args = '{"q":1}'
        let llm = StepPlan('sum', 'llm')
        llm.model = 'chat-pro'
        llm.system = 's'
        llm.input = 'template'
        plan.steps.add(tool)
        plan.steps.add(llm)
        plan.edges.add(EdgePlan('fetch', 'sum'))

        let host = RunnerHost()
        let out = LoomRunner().run(plan, host, start())
        @Expect(out.name, 'sum')
        @Expect(host.toolCalls, 1)
        @Expect(host.llmCalls, 1)
    }

    @TestCase
    func testHostIsUnboundAfterRun(): Unit {
        let plan = FlowPlan('one')
        let step = StepPlan('only', 'jit')
        step.input = 'let only_result = "x"'
        plan.steps.add(step)

        LoomRunner().run(plan, RunnerHost(), start())
        // 解绑后调工具应显式报错，而不是静默用旧宿主
        var message = ''
        try{
            LoomHostApi.callTool('echo', '{}')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('not bound'), true)
    }

    /** 菱形 DAG：a 分叉到 b/c，b、c 汇聚到 d；屏障保证 d 只执行一次 */
    @TestCase
    func testForkRunsBothBranches(): Unit {
        let plan = FlowPlan('diamond')
        for(id in ['a', 'b', 'c', 'd']){
            let step = StepPlan(id, 'tool')
            step.tool = 'echo'
            step.args = '{}'
            plan.steps.add(step)
        }
        plan.edges.add(EdgePlan('a', 'b'))
        plan.edges.add(EdgePlan('a', 'c'))
        plan.edges.add(EdgePlan('b', 'd'))
        plan.edges.add(EdgePlan('c', 'd'))

        let host = RunnerHost()
        let out = LoomRunner().run(plan, host, start())
        @Expect(out.name, 'd')
        // a + b + c + d（屏障保证 d 只跑一次）
        @Expect(host.toolCalls, 4)
    }

    /** 同一菱形 DAG 走 AsyncFlow 并发执行：语义不变 */
    @TestCase
    func testParallelRunsForkBranches(): Unit {
        let plan = FlowPlan('diamond-async')
        for(id in ['a', 'b', 'c', 'd']){
            let step = StepPlan(id, 'tool')
            step.tool = 'echo'
            step.args = '{}'
            plan.steps.add(step)
        }
        plan.edges.add(EdgePlan('a', 'b'))
        plan.edges.add(EdgePlan('a', 'c'))
        plan.edges.add(EdgePlan('b', 'd'))
        plan.edges.add(EdgePlan('c', 'd'))

        let host = RunnerHost()
        let out = LoomRunner().run(plan, host, start(), parallel: true)
        @Expect(out.name, 'd')
        @Expect(host.toolCalls, 4)
    }
}

class RunnerHost <: LoomHost {
    private let mutex = Mutex()
    private var tools: Int64 = 0
    private var llms: Int64 = 0

    public prop toolCalls: Int64 {
        get() {
            let box = CounterBox()
            synchronized(mutex){
                box.value = tools
            }
            box.value
        }
    }

    public prop llmCalls: Int64 {
        get() {
            let box = CounterBox()
            synchronized(mutex){
                box.value = llms
            }
            box.value
        }
    }

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        synchronized(mutex){
            tools++
        }
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        synchronized(mutex){
            llms++
        }
        input
    }
}

/** 计数返回值带出（`synchronized` 块是 Unit 语义） */
class CounterBox {
    public var value: Int64 = 0
}
