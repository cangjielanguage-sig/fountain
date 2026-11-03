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

/** 记录收到的 system，用于验证人格注入 */
class PersonaHost <: LoomHost {
    public var lastSystem: String = ''

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        lastSystem = system
        input
    }
}

/** 计划的 persona / prompt 生效，技能按标题加载 */
@Test
class LoomPersona_test {
    private static func plan(persona: String): FlowPlan {
        let value = FlowPlan('persona-flow')
        value.persona = persona
        let step = StepPlan('only', 'llm')
        step.model = 'deepseek-flash'
        step.system = 'BASE'
        step.input = 'go'
        value.steps.add(step)
        value
    }

    private static func start(): Event {
        StartEvent(category: 'loom', tag: 'persona-flow', name: 'start', data: 'go')
    }

    /** 字面人格：拼在 system 前面 */
    @TestCase
    func testLiteralPersonaPrefixedToSystem(): Unit {
        LoomHostApi.resetStore()
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan('严格'), host, start())
            @Expect(host.lastSystem, '严格\nBASE')
            @Expect(LoomHostApi.currentPersonaText(), '')
        }finally{
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /** 人格写成提示词名：从 prompt.latest 取正文 */
    @TestCase
    func testPersonaResolvedFromPromptStore(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        gateway.call('prompt', 'put', '{"name":"reviewer","content":"只挑错，不夸奖"}')
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan('reviewer'), host, start())
            @Expect(host.lastSystem.contains('只挑错，不夸奖'), true)
            @Expect(host.lastSystem.contains('BASE'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /** 技能按标题加载后自动拼进 system，模型不必自己想起来去查 */
    @TestCase
    func testSkillsInjectedIntoSystem(): Unit {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '先列三段式，再给数据', '{}', version: 1))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan(''), host, start(), skills: ['日报助手'])
            @Expect(host.lastSystem.contains('可用技能'), true)
            @Expect(host.lastSystem.contains('先列三段式，再给数据'), true)
            @Expect(LoomHostApi.currentSkillsText(), '')
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearSkills()
        }
    }

    /** persona 为空时回落到该用户 character 记录的 key */
    @TestCase
    func testPersonaFallsBackToCharacterKey(): Unit {
        let meta = InMemoryMetaStore()
        meta.characters.set(Character(9, 'strict', '{}'))
        meta.prompts.put(PromptEntry('strict', 1, '严格模式正文'))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: 9))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan(''), host, start())
            @Expect(host.lastSystem.contains('严格模式正文'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /** 没显式给技能时，按任务描述自动挑（SkillCatalog） */
    @TestCase
    func testAutoSelectsSkillByTaskText(): Unit {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '先列三段式，再给数据', '{}', version: 1))
        meta.skills.upsert(Skill(2, '代码评审', '只挑错，不夸奖', '{}', version: 1))
        SkillCatalog.install({ => meta.skills })
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            let host = PersonaHost()
            let start = StartEvent(category: 'loom', tag: 'persona-flow',
                                   name: 'start', data: '帮我写一份日报')
            LoomRunner().run(plan(''), host, start)
            @Expect(host.lastSystem.contains('可用技能'), true)
            @Expect(host.lastSystem.contains('先列三段式'), true)
            @Expect(host.lastSystem.contains('只挑错'), false)
        }finally{
            LoomHostApi.resetStore()
            SkillCatalog.reset()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearSkills()
        }
    }

    /** 技能按标题加载，流程不需要知道 id */
    @TestCase
    func testSkillLoadByTitle(): Unit {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(5, '日报助手', '正文内容', '{}', version: 2))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        @Expect(gateway.call('skill', 'load', '{"title":"日报助手"}').contains('正文内容'), true)
        @Expect(gateway.call('skill', 'load', '{"title":"不存在"}'), '')
    }
}
