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
class LoomBootstrap_test {
    private static func jitPlan(name: String): String {
        '{"status":"planned","name":${FlowPlan.jsonQuote(name)},"steps":['
        + '{"id":"fetch","kind":"jit","input":'
        + FlowPlan.jsonQuote('let fetch_result = "A"')
        + ',"async":"false"}],"edges":[]}'
    }

    private func storedFlow(name: String, status: String): LoomFlow {
        let flow = LoomFlow(name, description: 'd')
        flow.planJson = jitPlan(name)
        flow.status = status
        flow
    }

    @TestCase
    func testStartupRecompilesCompiledFlows(): Unit {
        let store = MemoryLoomStore()
        store.save(storedFlow('ok', LoomStatus.COMPILED))
        let registry = LoomRegistry(store: store)

        let result = LoomBootstrap.startup(registry)
        @Expect(result.restored, 1)
        @Expect(result.compiled, 1)
        @Expect(result.failed, 0)
        @Expect(registry.get('ok').getOrThrow().status, LoomStatus.COMPILED)
    }

    @TestCase
    func testBrokenCompiledFlowMarkedFailed(): Unit {
        let store = MemoryLoomStore()
        let broken = LoomFlow('broken', description: 'd')
        broken.planJson = '{"status":"planned","steps":[{"id":"s","kind":"sql"}],"edges":[]}'
        broken.status = LoomStatus.COMPILED
        store.save(broken)

        let registry = LoomRegistry(store: store)
        let result = LoomBootstrap.startup(registry)
        @Expect(result.failed, 1)
        @Expect(result.compiled, 0)
        @Expect(registry.get('broken').getOrThrow().status, LoomStatus.FAILED)
    }

    @TestCase
    func testPendingFlowsAreNotCompiledAtStartup(): Unit {
        let store = MemoryLoomStore()
        store.save(storedFlow('pending', LoomStatus.PENDING))
        let result = LoomBootstrap.startup(LoomRegistry(store: store))
        @Expect(result.restored, 1)
        @Expect(result.compiled, 0)
    }

    @TestCase
    func testStoreForDriver(): Unit {
        @Expect(LoomBootstrap.storeFor('postgres') is PostgresLoomStore, true)
        @Expect(LoomBootstrap.storeFor('mysql') is MySqlLoomStore, true)
        @Expect(LoomBootstrap.storeFor('f_hydra') is MemoryLoomStore, true)
    }

    @TestCase
    func testExecuteNowRunsCompiledFlow(): Unit {
        let store = MemoryLoomStore()
        store.save(storedFlow('run', LoomStatus.COMPILED))
        let registry = LoomRegistry(store: store)
        LoomBootstrap.startup(registry)

        let service = LoomService(Planner({ _, _ => '' }), registry)
        let event = service.executeNow('run', RunnerHost(),
            StartEvent(category: 'loom', tag: 'run', name: 'start', data: 'go'))
        @Expect(event.name, 'fetch')
    }

    /** 重启恢复的流程按计划里的 parallel 值执行（走 AsyncFlow） */
    @TestCase
    func testRestoredFlowKeepsParallelExecution(): Unit {
        let store = MemoryLoomStore()
        let flow = LoomFlow('diamond-parallel', description: '菱形并发')
        flow.planJson = '{"status":"planned","name":"diamond-parallel","parallel":true,"steps":['
            + '{"id":"a","kind":"tool","tool":"echo"},'
            + '{"id":"b","kind":"tool","tool":"echo"},'
            + '{"id":"c","kind":"tool","tool":"echo"},'
            + '{"id":"d","kind":"tool","tool":"echo"}],'
            + '"edges":[["a","b"],["a","c"],["b","d"],["c","d"]]}'
        flow.status = LoomStatus.COMPILED
        store.save(flow)

        let registry = LoomRegistry(store: store)
        let reloaded = LoomBootstrap.startup(registry)
        @Expect(reloaded.compiled, 1)

        let service = LoomService(Planner({ _, _ => '' }), registry)
        let host = RunnerHost()
        let out = service.executeNow('diamond-parallel', host,
            StartEvent(category: 'loom', tag: 'diamond-parallel', name: 'start', data: 'go'))
        @Expect(out.name, 'd')
        @Expect(host.toolCalls, 4)
    }

    @TestCase
    func testExecuteNowRejectsUncompiledFlow(): Unit {
        let store = MemoryLoomStore()
        store.save(storedFlow('pending', LoomStatus.PENDING))
        let registry = LoomRegistry(store: store)
        registry.restore()

        let service = LoomService(Planner({ _, _ => '' }), registry)
        var message = ''
        try{
            service.executeNow('pending', RunnerHost(),
                StartEvent(category: 'loom', tag: 'pending', name: 'start', data: 'go'))
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('not compiled'), true)
    }
}
