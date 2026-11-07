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

/** 记录交互并返回固定文本的宿主 */
class MemoryHost <: LoomHost {
    public var calls: Int64 = 0

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        calls++
        'answer-${calls}'
    }
}

/** 临时上下文 → 记忆/经验 */
@Test
class LoomContextMemory_test {
    private static func plan(): FlowPlan {
        let value = FlowPlan('memory-flow')
        for(id in ['first', 'second']){
            let step = StepPlan(id, 'llm')
            step.model = 'deepseek-flash'
            step.system = 'system-${id}'
            step.input = 'input-${id}'
            value.steps.add(step)
        }
        value.edges.add(EdgePlan('first', 'second'))
        value
    }

    private static func start(): Event {
        StartEvent(category: 'loom', tag: 'memory-flow', name: 'start', data: 'go')
    }

    /** 默认策略：不额外调模型，规则提炼，各写一条记忆与经验 */
    @TestCase
    func testExtractsMemoryAndExperienceAfterRun(): Unit {
        let content = InMemoryContentStore()
        let gateway = LoomStoreGateway(content, InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 7, namespace: 'n'))
        try{
            let host = MemoryHost()
            LoomRunner().run(plan(), host, start())
            @Expect(host.calls, 2)
            @Expect(LoomContextLog.isActive(), false)

            let records = gateway.call('memory', 'list',
                '{"userId":7,"namespace":"n","offset":0,"limit":10}')
            @Expect(records.contains('"kind":"note"'), true)
            @Expect(records.contains('"kind":"experience"'), true)
            @Expect(records.contains('answer-2'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 成功跑完：经验记为 experience，内容带结果标记 */
    @TestCase
    func testSuccessWritesSuccessExperience(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 5, namespace: 'ok'))
        try{
            LoomRunner().run(plan(), MemoryHost(), start())
            let records = gateway.call('memory', 'list',
                '{"userId":5,"namespace":"ok","offset":0,"limit":10}')
            @Expect(records.contains('"kind":"experience"'), true)
            @Expect(records.contains('结果：success'), true)
            @Expect(records.contains('experience_failed'), false)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 步骤抛异常：仍要留下经验，并标记成 failed */
    @TestCase
    func testFailureWritesFailedExperience(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 6, namespace: 'bad'))
        try{
            let failing = FlowPlan('failing-flow')
            // 先有一次模型交互，再让工具步骤炸掉：确保提炼时有上下文可写
            let thinking = StepPlan('think', 'llm')
            thinking.model = 'deepseek-flash'
            thinking.system = 'sys'
            thinking.input = 'go'
            failing.steps.add(thinking)
            let step = StepPlan('boom', 'tool')
            step.tool = 'explode'
            step.args = '{}'
            failing.steps.add(step)
            failing.edges.add(EdgePlan('think', 'boom'))

            var message = ''
            try{
                LoomRunner().run(failing, ThrowingToolHost(),
                    StartEvent(category: 'loom', tag: 'failing-flow', name: 'start', data: 'go'))
            }catch(e: Exception){
                message = e.message
            }
            @Expect(message.isEmpty(), false)

            let records = gateway.call('memory', 'list',
                '{"userId":6,"namespace":"bad","offset":0,"limit":10}')
            @Expect(records.contains('"kind":"experience_failed"'), true)
            @Expect(records.contains('结果：failed'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 流程结束只提炼记忆/经验，不碰技能（技能演进统一交给 SkillEvolutionJob） */
    @TestCase
    func testFlowEndDoesNotEvolveSkills(): Unit {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '正文', '{}', version: 1))
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 4, namespace: 's'))
        try{
            LoomRunner().run(plan(), MemoryHost(), start())
            let skills = meta.skills.list()
            @Expect(skills.size, 1)
            @Expect(skills[0].version, 1)
            @Expect(skills[0].details, '正文')
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    @TestCase
    func testDisabledPolicyWritesNothing(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(enabled: false))
        try{
            LoomRunner().run(plan(), MemoryHost(), start())
            @Expect(LoomContextLog.isActive(), false)
            @Expect(gateway.call('memory', 'list',
                '{"userId":0,"namespace":"loom","offset":0,"limit":10}'), '[]')
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 打开 writeKnowledge：提炼结果同时写一份知识文档 */
    @TestCase
    func testWritesKnowledgeWhenEnabled(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 3, namespace: 'k',
            writeKnowledge: true))
        try{
            LoomRunner().run(plan(), MemoryHost(), start())
            let ids = gateway.call('knowledge', 'docIds', '{"offset":0,"limit":10}')
            @Expect(ids.contains('loom:memory-flow'), true)
            let doc = gateway.call('knowledge', 'get', '{"docId":"loom:memory-flow:1"}')
            @Expect(doc.contains('上下文摘要'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 模型总结模式：解析 JSON 后按返回内容写入 */
    /** 中文长正文不能因为按字节截断而丢掉整次提炼 */
    @TestCase
    func testChineseLongTurnStillWrites(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 7, namespace: 'cn'))
        try{
            let host = ScriptedHost('')
            LoomRunner().run(plan(), host, start())
            let records = gateway.call('memory', 'list',
                '{"userId":7,"namespace":"cn","offset":0,"limit":10}')
            @Expect(records.contains('"kind":"note"'), true)
            @Expect(records.contains('"kind":"experience"'), true)
            @Expect(records.contains('…'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 模型返回自然语言：按字段回落，仍然两条都写 */
    @TestCase
    func testInvalidSummaryFallsBackToRule(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 7, namespace: 'fb',
            summarize: true, model: 'deepseek-flash'))
        try{
            let host = ScriptedHost('我觉得这次流程还不错')
            LoomRunner().run(plan(), host, start())
            let records = gateway.call('memory', 'list',
                '{"userId":7,"namespace":"fb","offset":0,"limit":10}')
            @Expect(records.contains('"kind":"note"'), true)
            @Expect(records.contains('"kind":"experience"'), true)
            @Expect(records.contains('结果：success'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 模型只给 memory：经验仍用规则提炼补齐 */
    @TestCase
    func testPartialSummaryKeepsBothFields(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 7, namespace: 'part',
            summarize: true, model: 'deepseek-flash'))
        try{
            let host = ScriptedHost('{"memory":"模型给的记忆"}')
            LoomRunner().run(plan(), host, start())
            let records = gateway.call('memory', 'list',
                '{"userId":7,"namespace":"part","offset":0,"limit":10}')
            @Expect(records.contains('模型给的记忆'), true)
            @Expect(records.contains('结果：success'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 模型把 memory 给成空串：该字段回落，experience 用模型结果 */
    @TestCase
    func testEmptyMemoryFieldFallsBack(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 7, namespace: 'mix',
            summarize: true, model: 'deepseek-flash'))
        try{
            let host = ScriptedHost('{"memory":"","experience":"模型给的经验"}')
            LoomRunner().run(plan(), host, start())
            let records = gateway.call('memory', 'list',
                '{"userId":7,"namespace":"mix","offset":0,"limit":10}')
            @Expect(records.contains('模型给的经验'), true)
            // memory 走的规则提炼，正文里带「上下文摘要」标记
            @Expect(records.contains('上下文摘要'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    @TestCase
    func testSummarizeModeUsesModelOutput(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 0, namespace: 'loom',
            summarize: true, model: 'deepseek-flash'))
        try{
            let host = SummarizeHost()
            LoomRunner().run(plan(), host, start())
            let records = gateway.call('memory', 'list',
                '{"userId":0,"namespace":"loom","offset":0,"limit":10}')
            @Expect(records.contains('提炼后的记忆'), true)
            @Expect(records.contains('提炼后的经验'), true)
        }finally{
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }

    /** 提炼只记步骤 system：人格与技能不进记忆 */
    @TestCase
    func testPersonaIsNotWrittenIntoMemory(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        LoomHostApi.installStore(gateway.call)
        LoomMemoryPolicy.install(LoomMemoryPolicy(userId: 7, namespace: 'np'))
        try {
            let host = ScriptedHost('')
            let styled = plan()
            styled.persona = '严格'
            LoomRunner().run(styled, host, start())
            let records = gateway.call('memory', 'list',
                '{"userId":7,"namespace":"np","offset":0,"limit":10}')
            @Expect(records.contains('严格'), false)
        } finally {
            LoomHostApi.resetStore()
            LoomMemoryPolicy.reset()
            LoomContextLog.clear()
        }
    }
}



/** 工具调用直接抛错的宿主：验证失败流程也会写经验 */
class ThrowingToolHost <: LoomHost {
    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        throw IllegalStateException('tool exploded')
    }

    public func callLlm(model: String, system: String, input: String): String {
        input
    }
}

/** 前两次返回普通结果，第三次（总结）返回 JSON */
class SummarizeHost <: LoomHost {
    private var calls: Int64 = 0

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        calls++
        if(input.contains('提炼两条内容')){
            return '{"memory":"提炼后的记忆","experience":"提炼后的经验"}'
        }
        'answer-${calls}'
    }
}

/** 会返回超长中文与可定制总结回复的宿主 */
class ScriptedHost <: LoomHost {
    private var calls: Int64 = 0
    private let summaryReply: String

    public init(summaryReply: String) {
        this.summaryReply = summaryReply
    }

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        calls++
        if (input.contains('提炼两条内容')) {
            return summaryReply
        }
        let builder = StringBuilder()
        for (i in 0..800) {
            builder.append('中')
        }
        builder.toString()
    }
}
