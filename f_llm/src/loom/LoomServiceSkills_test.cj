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
import fountain::f_llm.store.*

/** 计划里声明的技能要在执行期真正注入，而不是只躺在 planJson 里 */
@Test
class LoomServiceSkills_test {
    private static func planJson(skills: String): String {
        return '{"status":"planned","name":"sk-flow",'
            + '"skills":${skills},'
            + '"steps":[{"id":"only","kind":"llm","model":"deepseek-flash",'
            + '"system":"BASE","input":"go"}],"edges":[]}'
    }

    private static func compiled(service: LoomService, registry: LoomRegistry,
                                 json: String): Unit {
        let flow = LoomFlow('sk-flow', description: '技能注入')
        flow.planJson = json
        flow.mark(LoomStatus.PENDING)
        registry.put(flow)
        let _ = service.confirmFlow('sk-flow')
    }

    private static func start(): Event {
        StartEvent(category: 'loom', tag: 'sk-flow', name: 'start', data: '帮我写一份日报')
    }

    /** 计划写了 skills → executeNow 注入该技能正文 */
    @TestCase
    func testPlanSkillsInjectedIntoSystem(): Unit {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '先列三段式，再给数据', '{}', version: 1))
        SkillCatalog.install({ => meta.skills })
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try {
            let registry = LoomRegistry()
            let service = LoomService(Planner({ _, _ => planJson('["日报助手"]') }), registry)
            compiled(service, registry, planJson('["日报助手"]'))

            let host = PersonaHost()
            LoomHostApi.bind(host)
            let _ = service.executeNow('sk-flow', host, start())

            @Expect(host.lastSystem.contains('先列三段式，再给数据'), true)
        } finally {
            LoomHostApi.installStore({ kind, op, payload => '[]' })
            LoomMemoryPolicy.reset()
            LoomHostApi.clearSkills()
        }
    }

    /** 调用方显式给的技能优先于计划 */
    @TestCase
    func testExplicitSkillsOverridePlan(): Unit {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '先列三段式，再给数据', '{}', version: 1))
        meta.skills.upsert(Skill(2, '代码评审', '只挑错，不夸奖', '{}', version: 1))
        SkillCatalog.install({ => meta.skills })
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try {
            let registry = LoomRegistry()
            let service = LoomService(Planner({ _, _ => planJson('["日报助手"]') }), registry)
            compiled(service, registry, planJson('["日报助手"]'))

            let host = PersonaHost()
            LoomHostApi.bind(host)
            let _ = service.executeNow('sk-flow', host, start(), skills: ['代码评审'])

            @Expect(host.lastSystem.contains('只挑错，不夸奖'), true)
            @Expect(host.lastSystem.contains('先列三段式'), false)
        } finally {
            LoomHostApi.installStore({ kind, op, payload => '[]' })
            LoomMemoryPolicy.reset()
            LoomHostApi.clearSkills()
        }
    }
}
