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
package fountain::f_llm.store

import std.collection.*
import std.fs.Directory
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_util.UUID

/** 演进状态：内存实现与 f_store 实现的行为一致性 */
@Test
class EvolutionStateStore_test {
    private static func newPath(): String {
        '/tmp/fllm-evo-state-${UUID.random().toHexString()}'
    }

    /** 每技能状态可覆盖，水位线独立 */
    @TestCase
    func testInMemoryStore(): Unit {
        let store = InMemoryEvolutionStateStore()
        @Expect(store.lastRunAt(), 0)
        @Expect(store.get('日报助手').isNone(), true)

        store.save(EvolutionSkillState('日报助手', 1000, true))
        @Expect(store.get('日报助手').getOrThrow().lastEvolvedAt, 1000)
        @Expect(store.get('日报助手').getOrThrow().lastGatePassed, true)

        // 覆盖写：门禁失败要能翻转
        store.save(EvolutionSkillState('日报助手', 2000, false))
        @Expect(store.get('日报助手').getOrThrow().lastGatePassed, false)

        store.markRun(3000)
        @Expect(store.lastRunAt(), 3000)
    }

    /** 知识消费记录：标记幂等，重开实例仍能读到 */
    @TestCase
    func testKnowledgeDedupePersists(): Unit {
        let path = newPath()
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let first = FStoreEvolutionStateStore(path)
        first.markKnowledge(['k1', 'k2'])
        @Expect(first.processedKnowledge().size, 2)
        // 重复标记幂等
        first.markKnowledge(['k1'])
        @Expect(first.processedKnowledge().size, 2)

        let reopened = FStoreEvolutionStateStore(path)
        @Expect(reopened.processedKnowledge().size, 2)
        // 空串不落库
        reopened.markKnowledge([''])
        @Expect(reopened.processedKnowledge().size, 2)

        let memory = InMemoryEvolutionStateStore()
        memory.markKnowledge(['a'])
        @Expect(memory.processedKnowledge().size, 1)
    }

    /** f_store：重开实例仍能读到技能状态与水位线 */
    @TestCase
    func testFStorePersists(): Unit {
        let path = newPath()
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let first = FStoreEvolutionStateStore(path)
        first.save(EvolutionSkillState('日报助手', 1000, true))
        first.markRun(1500)

        let reopened = FStoreEvolutionStateStore(path)
        @Expect(reopened.get('日报助手').getOrThrow().lastEvolvedAt, 1000)
        @Expect(reopened.get('日报助手').getOrThrow().lastGatePassed, true)
        @Expect(reopened.lastRunAt(), 1500)
        @Expect(reopened.get('不存在的技能').isNone(), true)
    }
}
