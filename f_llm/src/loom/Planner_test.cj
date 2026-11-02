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

/** 记录注入给模型的 prompt（闭包不能捕获可变局部变量） */
class PromptRecorder {
    public var system: String = ''
    public var user: String = ''
}

@Test
class Planner_test {
    private static let PLANNED_JSON = '''
{
  "status": "planned",
  "name": "daily-report",
  "persona": "whimsical",
  "steps": [
    {"id": "fetch", "kind": "tool", "tool": "webSearch", "args": {"query": "仓颉 版本"}, "async": "auto"},
    {"id": "sum", "kind": "llm", "model": "chat-pro", "system": "你是技术编辑", "input": "fetch.output", "async": "false"}
  ],
  "edges": [["fetch", "sum"]],
  "notes": "先抓再总结"
}
'''

    private static let CLARIFY_JSON = '''
{
  "status": "need_clarification",
  "round": 1,
  "questions": [
    {"id": "q1", "question": "日报发给谁？", "why": "决定收件人",
     "options": [{"label": "只发我自己", "value": "self"}, {"label": "发团队群", "value": "team"}],
     "default": "self", "blocking": true}
  ],
  "assumptions": [{"field": "执行时间", "value": "每天 09:00", "reason": "描述未写"}],
  "partial_plan": {"name": "daily-report", "steps": [], "edges": []}
}
'''

    private func request(): LoomRequest {
        LoomRequest('daily-report', '抓取仓颉版本并总结', tools: ['webSearch'], persona: 'whimsical')
    }

    @TestCase
    func testParsesPlannedStepsAndEdges(): Unit {
        let result = Planner.parse(PLANNED_JSON, request())
        @Expect(result.isPlanned, true)
        let plan = result.plan.getOrThrow()
        @Expect(plan.name, 'daily-report')
        @Expect(plan.persona, 'whimsical')
        @Expect(plan.steps.size, 2)
        @Expect(plan.steps[0].tool, 'webSearch')
        @Expect(plan.steps[0].args.contains('"query"'), true)
        @Expect(plan.steps[1].async, 'false')
        @Expect(plan.edges.size, 1)
        @Expect(plan.edges[0].from, 'fetch')
        @Expect(plan.edges[0].to, 'sum')
    }

    @TestCase
    func testParsesClarification(): Unit {
        let result = Planner.parse(CLARIFY_JSON, request())
        @Expect(result.status, 'need_clarification')
        @Expect(result.plan.isNone(), true)
        @Expect(result.round, 1)
        @Expect(result.questions.size, 1)
        @Expect(result.questions[0].id, 'q1')
        @Expect(result.questions[0].options.size, 2)
        @Expect(result.assumptions.size, 1)
    }

    @TestCase
    func testInvalidJsonRejected(): Unit {
        var message = ''
        try{
            Planner.parse('not a json', request())
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('invalid JSON'), true)
    }

    @TestCase
    func testMissingNameFallsBackToRequest(): Unit {
        let raw = '''
{"status":"planned","steps":[{"id":"s1","kind":"llm"}],"edges":[]}
'''
        let result = Planner.parse(raw, request())
        @Expect(result.plan.getOrThrow().name, 'daily-report')
    }

    @TestCase
    func testUnknownKindRejectedByValidate(): Unit {
        let raw = '''
{"status":"planned","steps":[{"id":"s1","kind":"sql"}],"edges":[]}
'''
        var message = ''
        try{
            Planner.parse(raw, request())
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unknown loom step kind'), true)
    }

    @TestCase
    func testPlanWithoutStepsIsRejectedByCodeGen(): Unit {
        let raw = '''
{"status":"planned","steps":[],"edges":[]}
'''
        let plan = Planner.parse(raw, request()).plan.getOrThrow()
        @Expect(plan.steps.size, 0)
    }

    @TestCase
    func testParsesParallelFlagFromModel(): Unit {
        let raw = '{"status":"planned","name":"p","parallel":true,'
            + '"steps":[{"id":"s","kind":"jit","input":"let s_result = 1"}],"edges":[]}'
        let plan = Planner.parse(raw, request()).plan.getOrThrow()
        @Expect(plan.parallel, true)
    }

    @TestCase
    func testRequestParallelIsMergedIntoPlan(): Unit {
        let raw = '{"status":"planned","name":"p",'
            + '"steps":[{"id":"s","kind":"jit","input":"let s_result = 1"}],"edges":[]}'
        let asker = LoomRequest('p', 'd', parallel: true)
        let plan = Planner.parse(raw, asker).plan.getOrThrow()
        @Expect(plan.parallel, true)
    }

    @TestCase
    func testLlmCallbackReceivesPrompt(): Unit {
        let recorder = PromptRecorder()
        let planner = Planner({ system, user =>
            recorder.system = system
            recorder.user = user
            PLANNED_JSON
        })
        let result = planner.plan(request())
        @Expect(result.isPlanned, true)
        @Expect(recorder.system.contains('流程编排器'), true)
        @Expect(recorder.user.contains('抓取仓颉版本并总结'), true)
    }
}
