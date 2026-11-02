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

import fountain::f_data.*
import fountain::f_data.base.DataObject
import fountain::f_data.base.ObjectData

@Test
class LoomFunctions_test {
    private static func plannedJson(): String {
        '{"status":"planned","name":"daily","steps":[{"id":"fetch","kind":"jit","input":'
        + FlowPlan.jsonQuote('let fetch_result = "A"')
        + ',"async":"false"}],"edges":[]}'
    }

    private func param(json: String): LoomExecuteParam {
        match(DataObject<LoomExecuteParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw LoomException('bad test param')
        }
    }

    private func deleteParam(json: String): LoomDeleteParam {
        match(DataObject<LoomDeleteParam>.populate(JsonValue.fromStr(json).toData())){
            case Some(value) => value
            case None => throw LoomException('bad test param')
        }
    }

    private func install(): LoomRegistry {
        let registry = LoomRegistry()
        LoomServices.install(LoomService(Planner({ _, _ => plannedJson() }), registry))
        registry
    }

    @TestCase
    func testExecutePreviewRegistersPending(): Unit {
        let registry = install()
        let outcome = LoomExecuteFunction().call(
            param('{"nextEvent":"next","name":"daily","description":"抓取并汇总","tools":["webSearch"]}'))
        @Expect(outcome.event, 'next')
        @Expect(registry.get('daily').getOrThrow().status, LoomStatus.PENDING)
        LoomServices.reset()
    }

    @TestCase
    func testExecuteConfirmCompiles(): Unit {
        let registry = install()
        let function = LoomExecuteFunction()
        function.call(param('{"nextEvent":"next","name":"daily","description":"d"}'))
        @Expect(registry.get('daily').getOrThrow().status, LoomStatus.PENDING)

        function.call(param('{"nextEvent":"next","name":"daily","confirm":"true"}'))
        @Expect(registry.get('daily').getOrThrow().status, LoomStatus.COMPILED)
        LoomServices.reset()
    }

    @TestCase
    func testExecuteRequiresDescriptionWhenPreviewing(): Unit {
        let registry = install()
        LoomExecuteFunction().call(param('{"nextEvent":"next","name":"daily"}'))
        // 没有描述：不落任何流程
        @Expect(registry.get('daily').isNone(), true)
        LoomServices.reset()
    }

    @TestCase
    func testExecuteWithoutServiceDoesNotThrow(): Unit {
        LoomServices.reset()
        let outcome = LoomExecuteFunction().call(param('{"nextEvent":"next","name":"x"}'))
        @Expect(outcome.event, 'next')
    }

    @TestCase
    func testDeleteRemovesRegisteredFlow(): Unit {
        let registry = install()
        LoomExecuteFunction().call(param('{"nextEvent":"next","name":"daily","description":"d"}'))
        @Expect(registry.get('daily').isSome(), true)

        LoomDeleteFunction().call(deleteParam('{"nextEvent":"next","name":"daily"}'))
        @Expect(registry.get('daily').isNone(), true)
        LoomServices.reset()
    }

    @TestCase
    func testDeleteRequiresName(): Unit {
        let registry = install()
        LoomDeleteFunction().call(deleteParam('{"nextEvent":"next"}'))
        @Expect(registry.size(), 0)
        LoomServices.reset()
    }

    /** 模型显式传 parallel=true：即使计划里没写，也要落进 planJson */
    @TestCase
    func testParallelFlagPersistedIntoPlan(): Unit {
        let registry = install()
        LoomExecuteFunction().call(
            param('{"nextEvent":"next","name":"daily","description":"d","parallel":"true"}'))
        let stored = registry.get('daily').getOrThrow()
        @Expect(stored.planJson.contains('"parallel": true'), true)
        LoomServices.reset()
    }

    @TestCase
    func testExecuteAfterConfirmRunsFlow(): Unit {
        let registry = install()
        LoomServices.installHost(RunnerHost())
        let function = LoomExecuteFunction()
        function.call(param('{"nextEvent":"next","name":"daily","description":"d"}'))

        function.call(param('{"nextEvent":"next","name":"daily","confirm":"true","execute":"true"}'))
        @Expect(registry.get('daily').getOrThrow().status, LoomStatus.COMPILED)
        LoomServices.reset()
    }

    @TestCase
    func testExecuteAfterConfirmWithoutHostStillCompiles(): Unit {
        let registry = install()
        // 没装宿主：confirm+execute 只编译，跳过执行而不是抛错
        let function = LoomExecuteFunction()
        function.call(param('{"nextEvent":"next","name":"daily","description":"d"}'))
        function.call(param('{"nextEvent":"next","name":"daily","confirm":"true","execute":"true"}'))
        @Expect(registry.get('daily').getOrThrow().status, LoomStatus.COMPILED)
        LoomServices.reset()
    }
}
