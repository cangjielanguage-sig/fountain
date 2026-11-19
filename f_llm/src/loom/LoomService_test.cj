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

import fountain::f_egraph.base.*

@Test
class LoomService_test {
    /** 用拼接构造：多行字符串会吃掉反斜杠，导致 JSON 里的引号未转义 */
    private static func plannedJson(): String {
        '{"status":"planned","name":"daily","steps":[{"id":"fetch","kind":"jit","input":'
        + FlowPlan.jsonQuote('let fetch_result = "A"')
        + ',"async":"false"}],"edges":[]}'
    }

    private static let CLARIFY = '''
{"status":"need_clarification","round":1,"questions":[
  {"id":"q1","question":"发给谁？","blocking":true}
]}
'''

    private func service(json: String, registry!: ?LoomRegistry = None): LoomService {
        let store = match(registry){
            case Some(value) => value
            case None => LoomRegistry()
        }
        LoomService(Planner({ _, _ => json }), store)
    }

    private func request(): LoomRequest {
        LoomRequest('daily', '抓取并汇总', tools: ['webSearch'])
    }

    @TestCase
    func testPreviewStoresPendingWithSources(): Unit {
        let registry = LoomRegistry()
        let result = service(plannedJson(), registry: registry).execute(request())
        @Expect(result.status, 'pending')
        @Expect(result.planJson.contains('"name": "daily"'), true)
        @Expect(result.stepSources.size, 1)
        @Expect(result.stepSources.contains('fetch'), true)
        @Expect(result.flowSource.contains('registerTask("fetch"'), true)

        let stored = registry.get('daily').getOrThrow()
        @Expect(stored.status, LoomStatus.PENDING)
        @Expect(stored.description, '抓取并汇总')
        @Expect(stored.tools, 'webSearch')
    }

    @TestCase
    func testClarificationStoresClarifyingWithoutSources(): Unit {
        let registry = LoomRegistry()
        let result = service(CLARIFY, registry: registry).execute(request())
        @Expect(result.needsClarification, true)
        @Expect(result.questions.size, 1)

        let stored = registry.get('daily').getOrThrow()
        @Expect(stored.status, LoomStatus.CLARIFYING)
        @Expect(stored.planJson, '')
        @Expect(stored.questionsJson.contains('发给谁'), true)
    }

    @TestCase
    func testConfirmCompilesAndMarksCompiled(): Unit {
        let registry = LoomRegistry()
        let target = service(plannedJson(), registry: registry)
        target.execute(request())
        @Expect(target.status('daily'), LoomStatus.PENDING)

        let confirmed = target.confirmFlow('daily')
        @Expect(confirmed.status, 'compiled')
        @Expect(target.status('daily'), LoomStatus.COMPILED)
    }

    @TestCase
    func testConfirmUnknownFlowThrows(): Unit {
        var message = ''
        try{
            service(plannedJson()).confirmFlow('missing')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('not found'), true)
    }

    @TestCase
    func testDeleteRemovesFlow(): Unit {
        let registry = LoomRegistry()
        let target = service(plannedJson(), registry: registry)
        target.execute(request())

        @Expect(target.delete('daily'), true)
        @Expect(registry.get('daily').isNone(), true)
        @Expect(target.status('daily'), '')
    }

    /** 分叉 + 汇聚的流程可以走「确认 → 立即执行」整条链路 */
    @TestCase
    func testExecuteNowRunsForkPlanWithBarrier(): Unit {
        let registry = LoomRegistry()
        let flow = LoomFlow('diamond', description: '菱形')
        flow.planJson = '{"status":"planned","name":"diamond","steps":['
            + '{"id":"a","kind":"tool","tool":"echo"},'
            + '{"id":"b","kind":"tool","tool":"echo"},'
            + '{"id":"c","kind":"tool","tool":"echo"},'
            + '{"id":"d","kind":"tool","tool":"echo"}],'
            + '"edges":[["a","b"],["a","c"],["b","d"],["c","d"]]}'
        flow.status = LoomStatus.COMPILED
        registry.put(flow)

        let service = LoomService(Planner({ _, _ => '' }), registry)
        let host = RunnerHost()
        let out = service.executeNow('diamond', host,
            StartEvent(category: 'loom', tag: 'diamond', name: 'start', data: 'go'))
        @Expect(out.name, 'd')
        @Expect(host.toolCalls, 4)
    }

    @TestCase
    func testConfirmRejectsBrokenStoredPlan(): Unit {
        let registry = LoomRegistry()
        let flow = LoomFlow('broken', description: 'd')
        flow.planJson = '{"status":"planned","steps":[{"id":"s","kind":"sql"}],"edges":[]}'
        registry.put(flow)

        var message = ''
        try{
            service(plannedJson(), registry: registry).confirmFlow('broken')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unknown loom step kind'), true)
        @Expect(registry.get('broken').getOrThrow().status, LoomStatus.PENDING)
    }
}
