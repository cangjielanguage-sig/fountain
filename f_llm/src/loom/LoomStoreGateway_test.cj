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

    /** experience.list 不传 kind 时必须只返回经验 */
    @TestCase
    func testExperienceListFiltersByKind(): Unit {
        let gateway = gateway()
        let _ = gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"普通笔记","content":"note-body","kind":"note"}')
        let _ = gateway.call('experience', 'add',
            '{"userId":7,"namespace":"n","title":"一次经验","content":"exp-body"}')

        let list = gateway.call('experience', 'list',
            '{"userId":7,"namespace":"n","offset":0,"limit":10}')
        @Expect(list.contains('exp-body'), true)
        @Expect(list.contains('note-body'), false)
    }

    /** 显式 kind 仍然优先（与 search 的既有语义一致） */
    @TestCase
    func testExperienceListHonoursExplicitKind(): Unit {
        let gateway = gateway()
        let _ = gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"普通笔记","content":"note-body","kind":"note"}')
        let _ = gateway.call('experience', 'add',
            '{"userId":7,"namespace":"n","title":"一次经验","content":"exp-body"}')

        let list = gateway.call('experience', 'list',
            '{"userId":7,"namespace":"n","kind":"note","offset":0,"limit":10}')
        @Expect(list.contains('note-body'), true)
        @Expect(list.contains('exp-body'), false)
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
    func testPromptPutAutoVersionAndLatest(): Unit {
        let gateway = gateway()
        @Expect(gateway.call('prompt', 'put', '{"name":"score","content":"v1 正文"}'), '1')
        @Expect(gateway.call('prompt', 'put', '{"name":"score","content":"v2 正文"}'), '2')
        let latest = gateway.call('prompt', 'latest', '{"name":"score"}')
        @Expect(latest.contains('"version":2'), true)
        @Expect(latest.contains('v2 正文'), true)
        @Expect(gateway.call('prompt', 'get', '{"name":"score","version":1}').contains('v1 正文'), true)
        @Expect(gateway.call('prompt', 'remove', '{"name":"score","version":1}'), 'true')
        @Expect(gateway.call('prompt', 'latest', '{"name":"missing"}'), '')
    }

    @TestCase
    func testCharacterSetGetReset(): Unit {
        let gateway = gateway()
        @Expect(gateway.call('character', 'set',
            '{"userId":7,"characterKey":"reviewer","prompts":"严格"}'), 'ok')
        let loaded = gateway.call('character', 'get', '{"userId":7}')
        @Expect(loaded.contains('"characterKey":"reviewer"'), true)
        @Expect(gateway.call('character', 'reset', '{"userId":7}'), 'ok')
        @Expect(gateway.call('character', 'get', '{"userId":7}'), '')
    }

    /** kind 过滤必须先于分页：limit=1 时也要能取到目标 kind 的记录 */
    @TestCase
    func testListFiltersByKindBeforePaging(): Unit {
        let gateway = gateway()
        gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"a","content":"普通","kind":"note"}')
        gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"b","content":"经验","kind":"experience"}')
        let hits = gateway.call('memory', 'list',
            '{"userId":7,"namespace":"n","kind":"experience","offset":0,"limit":1}')
        @Expect(hits.contains('"kind":"experience"'), true)
        @Expect(hits.contains('"kind":"note"'), false)
    }

    /** 演进报告表：流程内只读——直接写库后能查到 */
    @TestCase
    func testEvolutionReadOnlyQuery(): Unit {
        let store = InMemoryEvolutionStore()
        store.save(EvolutionEntry(0, '日报助手', 'evolved', 'v1 -> v2', 10))
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore(), evolution: store)
        let listed = gateway.call('evolution', 'list', '{"offset":0,"limit":10}')
        @Expect(listed.contains('"skill":"日报助手"'), true)
        @Expect(listed.contains('"action":"evolved"'), true)
        let bySkill = gateway.call('evolution', 'by_skill', '{"skill":"日报助手","limit":5}')
        @Expect(bySkill.contains('v1 -> v2'), true)
        @Expect(gateway.call('evolution', 'by_skill', '{"skill":"不存在","limit":5}'), '[]')
    }

    /** 记忆记录带 saveTime：技能演进的水位线按真实时间判定 */
    @TestCase
    func testMemoryListExposesSaveTime(): Unit {
        let gateway = gateway()
        gateway.call('memory', 'add',
            '{"userId":7,"namespace":"n","title":"t","content":"c","kind":"fact"}')
        let records = gateway.call('memory', 'list',
            '{"userId":7,"namespace":"n","offset":0,"limit":10}')
        @Expect(records.contains('"saveTime":'), true)
        @Expect(records.contains('"saveTime":0'), false)
    }

    @TestCase
    func testUnsupportedOpRejected(): Unit {
        var message = ''
        try{
            // prompt.put 已实现，用真正不存在的 op 触发错误分支
            gateway().call('character', 'purge', '{}')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unsupported'), true)
    }

    /** 流程内查演进报告：JIT 步骤直接调 loomStore("evolution","by_skill",…) */
    @TestCase
    func testJitStepQueriesEvolutionReport(): Unit {
        let store = InMemoryEvolutionStore()
        store.save(EvolutionEntry(0, '日报助手', 'evolved', 'v1 -> v2', 10))
        store.save(EvolutionEntry(0, '代码评审', 'rejected', 'no samples', 20))
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore(),
                                       evolution: store)
        LoomHostApi.installStore(gateway.call)
        try{
            let step = StepPlan('s1', 'jit')
            step.input = 'let s1_result = loomStore("evolution", "by_skill", '
                + '"{\\"skill\\":\\"日报助手\\",\\"limit\\":5}")'
            let fn = LoomCompiler().compileStep(step)
            let out = fn(StartEvent(category: 'loom', tag: 't', name: 'start', data: 'go'))
            match(out as DataEvent){
                case Some(event) =>
                    let text = event.tryGet<String>().getOrThrow()
                    @Expect(text.contains('"action":"evolved"'), true)
                    @Expect(text.contains('v1 -> v2'), true)
                    // 其它技能的记录不能混进来
                    @Expect(text.contains('代码评审'), false)
                case None => @Expect(false, true)
            }
        }finally{
            LoomHostApi.resetStore()
        }
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
