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

    /** 关闭策略后不记录、不写入 */
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
