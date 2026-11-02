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
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CodeGen_test {
    private func plan(): FlowPlan {
        let plan = FlowPlan('daily-report')
        let fetch = StepPlan('fetch', 'tool')
        fetch.tool = 'webSearch'
        fetch.args = '{"query":"仓颉 版本"}'
        fetch.async = 'auto'
        let sum = StepPlan('sum', 'llm')
        sum.model = 'chat-pro'
        sum.system = '你是技术编辑'
        sum.input = 'fetch.output'
        sum.async = 'false'
        plan.steps.add(fetch)
        plan.steps.add(sum)
        plan.edges.add(EdgePlan('fetch', 'sum'))
        plan
    }

    @TestCase
    func testToolStepSourceCallsHost(): Unit {
        let source = CodeGen.stepSource(plan().steps[0])
        @Expect(source.startsWith('{ args: String =>'), true)
        @Expect(source.contains('loomCallTool("webSearch"'), true)
        @Expect(source.contains('fetch_out'), true)
    }

    @TestCase
    func testLlmStepSourceUsesModelAndSystem(): Unit {
        let source = CodeGen.stepSource(plan().steps[1])
        @Expect(source.startsWith('{ input: String =>'), true)
        @Expect(source.contains('loomCallLlm("chat-pro"'), true)
        @Expect(source.contains('"你是技术编辑"'), true)
    }

    @TestCase
    func testFlowSourceUsesAsyncFlowWhenAutoStepExists(): Unit {
        let source = CodeGen.flowSource(plan())
        @Expect(source.contains('AsyncFlow(category: "loom", tag: "daily-report")'), true)
        @Expect(source.contains('flow.registerStart(category: "loom", tag: "daily-report", eventName: "fetch")'), true)
        @Expect(source.contains('flow.registerTask("fetch"'), true)
        @Expect(source.contains('flow.registerTask("sum"'), true)
        @Expect(source.contains('flow.registerEnd('), true)
    }

    @TestCase
    func testFlowSourceUsesImmediateFlowWhenAllSync(): Unit {
        let plan = FlowPlan('sync-only')
        let step = StepPlan('compute', 'jit')
        step.input = 'let compute_result = "x"'
        step.async = 'false'
        plan.steps.add(step)

        let source = CodeGen.flowSource(plan)
        @Expect(source.contains('ImmediateFlow'), true)
        @Expect(CodeGen.hasAsync(plan), false)
    }

    @TestCase
    func testGenerateReturnsAllStepsAndPlanJson(): Unit {
        let generated = CodeGen.generate(plan())
        @Expect(generated.stepSources.size, 2)
        @Expect(generated.stepSources.contains('fetch'), true)
        @Expect(generated.planJson.contains('"name": "daily-report"'), true)
        @Expect(generated.flowSource.contains(' loom flow: daily-report'), true)
    }

    @TestCase
    func testInvalidPlanRejectedBeforeCodeGen(): Unit {
        let plan = FlowPlan('bad')
        plan.steps.add(StepPlan('s1', 'sql'))
        var message = ''
        try{
            CodeGen.generate(plan)
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unknown loom step kind'), true)
    }
}
