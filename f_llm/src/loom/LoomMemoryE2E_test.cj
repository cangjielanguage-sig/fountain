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

/** 记录模型实际收到的 system 与 input */
class E2eHost <: LoomHost {
    public var lastSystem: String = ''
    public var lastInput: String = ''
    public var calls: Int64 = 0

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        calls++
        lastSystem = system
        lastInput = input
        '模型回答'
    }
}

/**
 * 端到端：流程内部**读**记忆/知识/经验、**写**记忆/知识，并确认这些内容真的进入模型调用。
 *
 * 与 `LoomStoreGateway_test` 的区别：那边测的是网关接口本身；
 * 这里测的是「JIT 步骤取到的值经 `{step.output}` 落到 LLM 步骤的 input / system」。
 */
@Test
class LoomMemoryE2E_test {
    private static let USER: Int64 = 5
    private static let NS = 'e2e'

    private static func gateway(): LoomStoreGateway {
        LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
    }

    /** 预置六类素材：记忆、经验、知识、技能、提示词、人格 */
    private static func seed(target: LoomStoreGateway): Unit {
        target.call('memory', 'add',
            '{"userId":5,"namespace":"e2e","title":"用户偏好",'
            + '"content":"偏好：先结论后数据","kind":"note"}')
        target.call('memory', 'add',
            '{"userId":5,"namespace":"e2e","title":"日报经验",'
            + '"content":"经验正文：先列数据再给结论","kind":"experience"}')
        target.call('knowledge', 'upsert',
            '{"docId":"k1","title":"差旅","content":"差旅标准：高铁二等座"}')
        target.call('skill', 'upsert',
            '{"title":"日报助手","details":"三段式：结论-数据-建议",'
            + '"functions":"{}","version":1}')
        target.call('prompt', 'put',
            '{"name":"reviewer","version":1,"content":"你是严格评审员"}')
        target.call('character', 'set',
            '{"userId":5,"characterKey":"reviewer","prompts":""}')
    }

    /** 六个步骤串成一条链：三个检索 → 两个写入 → 一次模型调用 */
    private static func plan(): FlowPlan {
        let value = FlowPlan('memory-e2e')
        // persona 留空：走 character → prompt 回落
        let mem = StepPlan('mem', 'jit')
        mem.input = "let mem_result = loomStore('memory', 'list', "
            + "'{\"userId\":5,\"namespace\":\"e2e\",\"kind\":\"note\",\"offset\":0,\"limit\":10}')"
        let kn = StepPlan('kn', 'jit')
        kn.input = "let kn_result = loomStore('knowledge', 'get', '{\"docId\":\"k1\"}')"
        let exp = StepPlan('exp', 'jit')
        exp.input = "let exp_result = loomStore('experience', 'list', "
            + "'{\"userId\":5,\"namespace\":\"e2e\",\"kind\":\"experience\",\"offset\":0,\"limit\":10}')"
        let saveMem = StepPlan('savemem', 'jit')
        saveMem.input = "let savemem_result = loomStore('memory', 'add', "
            + "'{\"userId\":5,\"namespace\":\"e2e\",\"title\":\"流程内写入\","
            + "\"content\":\"流程内保存的记忆\",\"kind\":\"note\"}')"
        let saveKn = StepPlan('savekn', 'jit')
        saveKn.input = "let savekn_result = loomStore('knowledge', 'upsert', "
            + "'{\"docId\":\"k2\",\"title\":\"流程内文档\",\"content\":\"流程内保存的知识\"}')"
        let ask = StepPlan('ask', 'llm')
        ask.model = 'deepseek-flash'
        ask.system = 'BASE'
        ask.input = '记忆：{mem.output}\n知识：{kn.output}\n经验：{exp.output}'

        value.steps.add(mem)
        value.steps.add(kn)
        value.steps.add(exp)
        value.steps.add(saveMem)
        value.steps.add(saveKn)
        value.steps.add(ask)
        value.edges.add(EdgePlan('mem', 'kn'))
        value.edges.add(EdgePlan('kn', 'exp'))
        value.edges.add(EdgePlan('exp', 'savemem'))
        value.edges.add(EdgePlan('savemem', 'savekn'))
        value.edges.add(EdgePlan('savekn', 'ask'))
        value
    }

    private static func start(): Event {
        StartEvent(category: 'loom', tag: 'memory-e2e', name: 'start', data: '写一份日报')
    }

    /** 检索到的记忆/知识/经验进入模型 input；人格与技能进入 system */
    @TestCase
    func testFlowRetrievalReachesModel(): Unit {
        let target = gateway()
        seed(target)
        LoomHostApi.installStore(target.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: USER))
        try{
            let host = E2eHost()
            LoomRunner().run(plan(), host, start(), skills: ['日报助手'])

            @Expect(host.calls, 1)
            // 模型 input 里必须有三类检索结果
            @Expect(host.lastInput.contains('偏好：先结论后数据'), true)
            @Expect(host.lastInput.contains('差旅标准：高铁二等座'), true)
            @Expect(host.lastInput.contains('经验正文：先列数据再给结论'), true)
            // system 里必须有个人格（character → prompt）与被加载的技能正文
            @Expect(host.lastSystem.contains('你是严格评审员'), true)
            @Expect(host.lastSystem.contains('三段式：结论-数据-建议'), true)
            @Expect(host.lastSystem.contains('BASE'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
            LoomHostApi.clearSkills()
        }
    }

    /** 检索（search）而不是列举：命中的记忆与知识同样进入模型 input */
    @TestCase
    func testFlowSearchReachesModel(): Unit {
        let target = gateway()
        target.call('memory', 'add',
            '{"userId":5,"namespace":"e2e","title":"检索样本",'
            + '"content":"cangjie 关键字记忆","kind":"note"}')
        target.call('knowledge', 'upsert',
            '{"docId":"s1","title":"检索样本","content":"cangjie 关键字知识"}')
        LoomHostApi.installStore(target.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: USER))
        try{
            let value = FlowPlan('search-e2e')
            let ms = StepPlan('ms', 'jit')
            ms.input = "let ms_result = loomStore('memory', 'search', "
                + "'{\"userId\":5,\"namespace\":\"e2e\",\"text\":\"cangjie\",\"topK\":5}')"
            let ks = StepPlan('ks', 'jit')
            ks.input = "let ks_result = loomStore('knowledge', 'search', "
                + "'{\"text\":\"cangjie\",\"limit\":5}')"
            let ask = StepPlan('ask', 'llm')
            ask.model = 'deepseek-flash'
            ask.system = 'BASE'
            ask.input = '检索：{ms.output} / {ks.output}'
            value.steps.add(ms)
            value.steps.add(ks)
            value.steps.add(ask)
            value.edges.add(EdgePlan('ms', 'ks'))
            value.edges.add(EdgePlan('ks', 'ask'))

            let host = E2eHost()
            LoomRunner().run(value, host,
                StartEvent(category: 'loom', tag: 'search-e2e', name: 'start', data: '找 cangjie'))
            @Expect(host.lastInput.contains('cangjie 关键字记忆'), true)
            @Expect(host.lastInput.contains('cangjie 关键字知识'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
            LoomHostApi.clearSkills()
        }
    }

    /** 流程内部写入的记忆与知识，流程结束后能从存储读回 */
    @TestCase
    func testFlowWritesMemoryAndKnowledge(): Unit {
        let target = gateway()
        seed(target)
        LoomHostApi.installStore(target.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false, userId: USER))
        try{
            LoomRunner().run(plan(), E2eHost(), start(), skills: ['日报助手'])

            let notes = target.call('memory', 'list',
                '{"userId":5,"namespace":"e2e","kind":"note","offset":0,"limit":10}')
            @Expect(notes.contains('流程内保存的记忆'), true)
            @Expect(notes.contains('偏好：先结论后数据'), true)

            let docs = target.call('knowledge', 'docIds', '{"offset":0,"limit":10}')
            @Expect(docs.contains('k2'), true)
            let doc = target.call('knowledge', 'get', '{"docId":"k2"}')
            @Expect(doc.contains('流程内保存的知识'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomHostApi.clearPersona()
            LoomHostApi.clearSkills()
        }
    }
}
