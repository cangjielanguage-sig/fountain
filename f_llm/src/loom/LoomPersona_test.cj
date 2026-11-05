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

    /** persona 为空时回落到该用户 character 记录的 key（第二级：prompt 库优先） */
    @TestCase
    func testPersonaFallsBackToCharacterKey(): Unit {
        let meta = InMemoryMetaStore()
        meta.characters.set(Character(9, 'rigorous', ''))
        meta.prompts.put(PromptEntry('rigorous', 1, '严格模式正文'))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: 9))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan(''), host, start())
            // 库里同名提示词优先于内置正文
            @Expect(host.lastSystem.contains('严格模式正文'), true)
            @Expect(host.lastSystem.contains('严谨的技术专家'), false)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /** 库里没有同名提示词：用内置角色正文，而不是把 key 当正文 */
    @TestCase
    func testBuiltinCharacterBodyUsed(): Unit {
        LoomHostApi.resetStore()
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan('rigorous'), host, start())
            @Expect(host.lastSystem.contains('严谨的技术专家'), true)
            @Expect(host.lastSystem.contains('rigorous\n'), false)
        }finally{
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /** 未知 key：仍按字面文本处理（第三级），不报错 */
    @TestCase
    func testUnknownKeyFallsBackToLiteral(): Unit {
        LoomHostApi.resetStore()
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan('只挑错不夸奖'), host, start())
            @Expect(host.lastSystem.contains('只挑错不夸奖'), true)
        }finally{
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /**
     * `custom` 人格：正文只来自 character.prompts。
     *
     * 不能走「字面文本」那一级——否则 system 开头会出现 `custom` 这个英文单词，
     * 比不设置更糟。两个分支都断言：有 prompts 用它，没 prompts 就当没设置。
     */
    @TestCase
    func testCustomCharacterUsesPromptsOnly(): Unit {
        let meta = InMemoryMetaStore()
        meta.characters.set(Character(6, 'custom', '只用英文回答，控制在两句话内'))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: 6))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan(''), host, start())
            @Expect(host.lastSystem.contains('只用英文回答，控制在两句话内'), true)
            @Expect(host.lastSystem.contains('custom'), false)
            @Expect(host.lastSystem.contains('BASE'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
        // 未填 prompts：等价于没设置人格，system 里不该留下 'custom'
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: 6))
        meta.characters.set(Character(6, 'custom', ''))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan(''), host, start())
            @Expect(host.lastSystem.contains('custom'), false)
            @Expect(host.lastSystem, 'BASE')
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
        }
    }

    /** character.prompts 作为附加要求追加在人格正文之后 */
    @TestCase
    func testCharacterPromptsAppended(): Unit {
        let meta = InMemoryMetaStore()
        meta.characters.set(Character(5, 'rigorous', '回答不超过 300 字，用中文'))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: 5))
        try{
            let host = PersonaHost()
            LoomRunner().run(plan(''), host, start())
            @Expect(host.lastSystem.contains('严谨的技术专家'), true)
            @Expect(host.lastSystem.contains('回答不超过 300 字，用中文'), true)
            @Expect(host.lastSystem.contains('BASE'), true)
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
