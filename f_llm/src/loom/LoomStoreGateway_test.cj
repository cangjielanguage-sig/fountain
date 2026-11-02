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

/** 存储网关：op 映射、错误分支与 JIT 可达性 */
@Test
class LoomStoreGateway_test {
    private func gateway(): LoomStoreGateway {
        LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
    }

    @TestCase
    func testSkillCount(): Unit {
        @Expect(gateway().call('skill', 'count', '{}'), '0')
    }

    @TestCase
    func testKnowledgeDocIdsEmpty(): Unit {
        @Expect(gateway().call('knowledge', 'docIds', '{"offset":0,"limit":10}'), '[]')
    }

    @TestCase
    func testKnowledgeUpsertAccepted(): Unit {
        let gateway = gateway()
        @Expect(gateway.call('knowledge', 'upsert',
            '{"docId":"d1","title":"t","content":"hello"}'), 'ok')
        // docIds 的可见性依赖各实现的索引策略，这里只断言返回合法 JSON 数组
        @Expect(gateway.call('knowledge', 'docIds', '{"offset":0,"limit":10}').startsWith('['), true)
    }

    @TestCase
    func testMemoryAddReturnsId(): Unit {
        let gateway = gateway()
        let id = gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"t","content":"c","kind":"fact"}')
        @Expect(id.isEmpty(), false)
    }

    @TestCase
    func testUnsupportedOpRejected(): Unit {
        var message = ''
        try{
            gateway().call('memory', 'search', '{}')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unsupported'), true)
    }

    /** JIT 步骤通过注册的 loomStore 调网关 */
    @TestCase
    func testJitStepCallsStoreGateway(): Unit {
        LoomHostApi.installStore(gateway().call)
        try{
            let step = StepPlan('s1', 'jit')
            step.input = 'let s1_result = loomStore("skill", "count", "{}")'
            let fn = LoomCompiler().compileStep(step)
            let out = fn(StartEvent(category: 'loom', tag: 't', name: 'start', data: 'go'))
            match(out as DataEvent){
                case Some(event) => @Expect(event.tryGet<String>().getOrThrow(), '0')
                case None => @Expect(false, true)
            }
        }finally{
            LoomHostApi.resetStore()
        }
    }
}
