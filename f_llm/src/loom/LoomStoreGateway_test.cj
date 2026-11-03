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
    func testKnowledgeUpsertThenDocIds(): Unit {
        let gateway = gateway()
        @Expect(gateway.call('knowledge', 'upsert',
            '{"docId":"d1","title":"t","content":"hello"}'), 'ok')
        // 往返：写入后必须能列出，且 limit 生效（此前 JSON 数字解析失败会得到 []）
        @Expect(gateway.call('knowledge', 'docIds', '{"offset":0,"limit":10}'), '["d1"]')
        @Expect(gateway.call('knowledge', 'docIds', '{"offset":0,"limit":0}'), '[]')
    }

    @TestCase
    func testMemoryAddThenRemove(): Unit {
        let gateway = gateway()
        let id = gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"t","content":"c","kind":"fact"}')
        @Expect(id.isEmpty(), false)
        @Expect(gateway.call('memory', 'remove', '{"userId":7,"id":${id}}'), 'true')
        @Expect(gateway.call('memory', 'remove', '{"userId":7,"id":${id}}'), 'false')
    }

    @TestCase
    func testKnowledgeSearchFindsUpsertedDoc(): Unit {
        let gateway = gateway()
        gateway.call('knowledge', 'upsert',
            '{"docId":"d1","title":"t","content":"cangjie language guide"}')
        let hits = gateway.call('knowledge', 'search', '{"text":"cangjie","limit":5}')
        @Expect(hits.contains('"docId":"d1"'), true)
    }

    @TestCase
    func testMemorySearchFindsAddedRecord(): Unit {
        let gateway = gateway()
        let id = gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"note","content":"cangjie","kind":"fact"}')
        let hits = gateway.call('memory', 'search',
            '{"userId":7,"namespace":"n","text":"cangjie","topK":5}')
        @Expect(hits.contains('"id":${id}'), true)
    }

    @TestCase
    func testKnowledgeGetReturnsContent(): Unit {
        let gateway = gateway()
        gateway.call('knowledge', 'upsert', '{"docId":"d2","title":"t","content":"正文"}')
        let doc = gateway.call('knowledge', 'get', '{"docId":"d2"}')
        @Expect(doc.contains('"content":"正文"'), true)
        @Expect(gateway.call('knowledge', 'get', '{"docId":"none"}'), '')
    }

    @TestCase
    func testMemoryGetAndList(): Unit {
        let gateway = gateway()
        let id = gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"t","content":"c","kind":"fact"}')
        let record = gateway.call('memory', 'get', '{"userId":7,"id":${id}}')
        @Expect(record.contains('"content":"c"'), true)
        let records = gateway.call('memory', 'list',
            '{"userId":7,"namespace":"n","offset":0,"limit":10}')
        @Expect(records.startsWith('['), true)
        @Expect(records.contains('"id":${id}'), true)
    }

    @TestCase
    func testSkillListAndGet(): Unit {
        let meta = InMemoryMetaStore()
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        meta.skills.upsert(Skill(3, '日报助手', '正文', '{}', version: 2))
        @Expect(gateway.call('skill', 'list', '{}').contains('"title":"日报助手"'), true)
        @Expect(gateway.call('skill', 'get', '{"id":3}').contains('"version":2'), true)
        @Expect(gateway.call('skill', 'get', '{"id":99}'), '')
    }

    @TestCase
    func testSkillUpsertAllocatesId(): Unit {
        let meta = InMemoryMetaStore()
        let gateway = LoomStoreGateway(InMemoryContentStore(), meta)
        @Expect(gateway.call('skill', 'upsert',
            '{"title":"新技能","details":"正文","functions":"{}"}'), '1')
        @Expect(gateway.call('skill', 'upsert',
            '{"id":1,"title":"新技能","details":"改过","functions":"{}","version":3}'), '1')
        let loaded = gateway.call('skill', 'get', '{"id":1}')
        @Expect(loaded.contains('"details":"改过"'), true)
        @Expect(loaded.contains('"version":3'), true)
    }

    @TestCase
    func testExperienceAliasesMemoryWithKind(): Unit {
        let gateway = gateway()
        let id = gateway.call('experience', 'add',
            '{"userId":7,"namespace":"n","title":"e","content":"踩过的坑"}')
        @Expect(id.isEmpty(), false)
        let hits = gateway.call('experience', 'search',
            '{"userId":7,"namespace":"n","text":"踩过","topK":5}')
        @Expect(hits.contains('"id":${id}'), true)
    }

    @TestCase
    func testUnsupportedOpRejected(): Unit {
        var message = ''
        try{
            gateway().call('prompt', 'put', '{}')
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
