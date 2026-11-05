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

import fountain::f_config.Config
import fountain::f_llm.config.LLMConfig

@Test
class LoomWiringSupervisor_test {
    private static func plannedJson(name: String): String {
        '{"status":"planned","name":${FlowPlan.jsonQuote(name)},"steps":[{"id":"fetch","kind":"jit",'
        + '"input":'
        + FlowPlan.jsonQuote('let fetch_result = "A"')
        + ',"async":"false"}],"edges":[]}'
    }

    @TestCase
    func testWireSeedsCompiledFlowsWhenSwitchOn(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        Config.set<Bool>([(LLMConfig.LLM_SUPERVISOR, true)])
        // 装配会碰演进族存储：指到内存，避免写默认元数据目录污染别的用例
        Config.set<String>([('llm_metaStore', 'memory')])
        try{
            let store = MemoryLoomStore()
            let flow = LoomFlow('daily', description: '汇总日报')
            flow.planJson = plannedJson('daily')
            flow.mark(LoomStatus.COMPILED)
            store.save(flow)

            let _ = LoomWiring.wire({ _, _, _ => plannedJson('daily') }, store: store)

            let supervisor = Supervisor.current().getOrThrow()
            @Expect(supervisor.routes().size, 1)
            @Expect(supervisor.routable().size, 1)
            @Expect(supervisor.eventOf('daily').getOrThrow(), 'sv/daily')
        }finally{
            Config.remove(LLMConfig.LLM_SUPERVISOR)
            Config.remove('llm_metaStore')
            Supervisor.reset()
            LoomServices.reset()
        }
    }

    @TestCase
    func testWireSkipsSupervisorWhenSwitchOff(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        Config.remove(LLMConfig.LLM_SUPERVISOR)

        let _ = LoomWiring.wire({ _, _, _ => plannedJson('daily') }, store: MemoryLoomStore())
        @Expect(Supervisor.current().isNone(), true)
        LoomServices.reset()
    }
}
