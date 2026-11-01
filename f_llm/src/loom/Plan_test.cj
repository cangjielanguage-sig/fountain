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
class Plan_test {
    private func sample(): FlowPlan {
        let plan = FlowPlan('daily-report')
        plan.persona = 'whimsical'
        let fetch = StepPlan('fetch', 'tool')
        fetch.tool = 'webSearch'
        fetch.args = '{"query":"仓颉 版本"}'
        fetch.async = 'auto'
        let sum = StepPlan('sum', 'llm')
        sum.model = 'chat-pro'
        sum.system = '你是技术编辑'
        sum.input = '$' + '{fetch.output}'
        sum.async = 'false'
        plan.steps.add(fetch)
        plan.steps.add(sum)
        plan.edges.add(EdgePlan('fetch', 'sum'))
        plan
    }

    @TestCase
    func testValidateAcceptsWellFormedPlan(): Unit {
        sample().validate()
    }

    @TestCase
    func testDuplicateStepIdRejected(): Unit {
        let plan = sample()
        plan.steps.add(StepPlan('fetch', 'llm'))
        var message = ''
        try{
            plan.validate()
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('duplicate'), true)
    }

    @TestCase
    func testEdgeToMissingStepRejected(): Unit {
        let plan = sample()
        plan.edges.add(EdgePlan('sum', 'missing'))
        var message = ''
        try{
            plan.validate()
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('missing'), true)
    }

    @TestCase
    func testUnknownKindRejected(): Unit {
        let plan = sample()
        plan.steps.add(StepPlan('bad', 'sql'))
        var message = ''
        try{
            plan.validate()
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unknown loom step kind'), true)
    }

    @TestCase
    func testToJsonContainsSchemaFields(): Unit {
        let json = sample().toJson()
        @Expect(json.contains('"name": "daily-report"'), true)
        @Expect(json.contains('"persona": "whimsical"'), true)
        @Expect(json.contains('"tool": "webSearch"'), true)
        @Expect(json.contains('["fetch", "sum"]'), true)
    }

    @TestCase
    func testJsonEscapesQuotesAndControlChars(): Unit {
        let plan = FlowPlan('p"1')
        let step = StepPlan('a', 'llm')
        step.system = "line1\nline2"
        plan.steps.add(step)
        let json = plan.toJson()
        @Expect(json.contains('p\\"1'), true)
        @Expect(json.contains('line1\\nline2'), true)
    }
}

@Test
class ToolScope_test {
    @TestCase
    func testCheckRejectsUnknownTool(): Unit {
        var message = ''
        try{
            ToolScope.check('tool', ['webSearch', 'ghost'], ['webSearch', 'memoryCall'])
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('ghost'), true)
    }

    @TestCase
    func testCheckDeduplicates(): Unit {
        let result = ToolScope.check('tool', ['a', 'a'], ['a'])
        @Expect(result.size, 1)
    }

    @TestCase
    func testVerifyPlanEnforcesWhitelist(): Unit {
        let plan = FlowPlan('p')
        let step = StepPlan('s1', 'tool')
        step.tool = 'webSearch'
        plan.steps.add(step)

        // 白名单为空 → 拒绝
        var message = ''
        try{
            ToolScope.verifyPlan(plan, Array<String>(), ['webSearch'])
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('whitelist'), true)

        // 白名单包含且已注册 → 通过
        ToolScope.verifyPlan(plan, ['webSearch'], ['webSearch'])
    }
}
