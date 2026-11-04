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

/** 演进报告表：内存实现与 f_store 实现的行为一致性 */
@Test
class EvolutionStore_test {
    private static func entries(store: EvolutionStore): Unit {
        @Expect(store.save(EvolutionEntry(0, '日报助手', 'evolved', 'v1 -> v2', 100)), 1)
        @Expect(store.save(EvolutionEntry(0, '代码评审', 'rejected', 'no samples', 200)), 2)
        @Expect(store.save(EvolutionEntry(0, '日报助手', 'skipped', 'cooldown', 300)), 3)
    }

    /** 内存实现：倒序、按技能筛选、limit */
    @TestCase
    func testInMemoryStore(): Unit {
        let store = InMemoryEvolutionStore()
        entries(store)
        let all = store.list(0, 10)
        @Expect(all.size, 3)
        // 最近的在前
        @Expect(all[0].at, 300)
        @Expect(store.bySkill('日报助手', 10).size, 2)
        @Expect(store.list(0, 2).size, 2)
    }

    /** f_store 的条件索引：同技能多条第，返回按时间倒序（键里补零，字典序即时间序） */
    @TestCase
    func testFStoreBySkillUsesConditionIndex(): Unit {
        let path = '/tmp/fllm-evolution-idx-${seed()}'
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let store = FStoreEvolutionStore(path)
        let skill = 'idx-${Int64(seed())}'
        store.save(EvolutionEntry(0, skill, 'skipped', '早期', 10))
        store.save(EvolutionEntry(0, skill, 'evolved', '中期', 20))
        store.save(EvolutionEntry(0, skill, 'rejected', '最近', 30))

        let hits = store.bySkill(skill, 3)
        @Expect(hits.size, 3)
        @Expect(hits[0].at, 30)
        @Expect(hits[1].at, 20)
        @Expect(hits[2].at, 10)
    }

    private static var seedValue: Int64 = 0

    private static func seed(): Int64 {
        seedValue++
        seedValue
    }

    /** f_store 实现：写入后可读、按技能筛选、重开实例仍能读到 */
    @TestCase
    func testFStoreStorePersists(): Unit {
        // 固定目录便于复现；断言用「至少包含」避免历史数据干扰
        let path = '/tmp/fllm-evolution-persist-${seed()}'
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let marker = 'crawler skill created'
        let first = FStoreEvolutionStore(path)
        entries(first)

        let reopened = FStoreEvolutionStore(path)
        let all = reopened.list(0, 200)
        @Expect(all.size >= 3, true)

        var found = false
        for(item in all){
            if(item.detail.contains('v1 -> v2')){
                found = true
            }
        }
        @Expect(found, true)
        @Expect(reopened.bySkill('日报助手', 100).size >= 2, true)
        // 新增记录分配到的 id 必须是正数（且不复用已有 id）
        let next = reopened.save(EvolutionEntry(0, '爬虫助手', 'created', marker, 400))
        @Expect(next > 3, true)
    }
}
