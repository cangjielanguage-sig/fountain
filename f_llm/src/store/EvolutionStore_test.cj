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

/** 演进报告表：内存实现与 f_store 实现的行为一致性 */
@Test
class EvolutionStore_test {
    /** 每次跑用新目录：避免上次残留数据让断言误判 */
    private static func newPath(): String {
        '/tmp/fllm-evolution-${UUID.random().toHexString()}'
    }

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

    /** f_store 的条件索引：同技能三条，返回按时间倒序（键里补零，字典序即时间序） */
    @TestCase
    func testFStoreBySkillUsesConditionIndex(): Unit {
        let path = newPath()
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let store = FStoreEvolutionStore(path)
        store.save(EvolutionEntry(0, '索引技能', 'skipped', '早期', 10))
        store.save(EvolutionEntry(0, '索引技能', 'evolved', '中期', 20))
        store.save(EvolutionEntry(0, '索引技能', 'rejected', '最近', 30))

        let hits = store.bySkill('索引技能', 3)
        @Expect(hits.size, 3)
        @Expect(hits[0].at, 30)
        @Expect(hits[1].at, 20)
        @Expect(hits[2].at, 10)
    }

    /** list 走时间索引：写入顺序与时间顺序不一致时，仍按时间倒序 */
    @TestCase
    func testFStoreListOrdersByTime(): Unit {
        let path = newPath()
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let store = FStoreEvolutionStore(path)
        // 写入序：100、300、200 —— 与时间序不同
        store.save(EvolutionEntry(0, '列表技能', 'skipped', '早', 100))
        store.save(EvolutionEntry(0, '列表技能', 'evolved', '晚', 300))
        store.save(EvolutionEntry(0, '列表技能', 'rejected', '中', 200))

        let all = store.list(0, 10)
        @Expect(all.size, 3)
        @Expect(all[0].at, 300)
        @Expect(all[1].at, 200)
        @Expect(all[2].at, 100)

        // offset / limit 作用在时间序上
        let page = store.list(1, 1)
        @Expect(page.size, 1)
        @Expect(page[0].at, 200)
    }

    /** f_store 实现：重开实例仍能读到，新 id 不复用 */
    @TestCase
    func testFStoreStorePersists(): Unit {
        let path = newPath()
        try{
            Directory.create(path)
        }catch(error: Exception){
            ()
        }
        let first = FStoreEvolutionStore(path)
        entries(first)

        let reopened = FStoreEvolutionStore(path)
        let all = reopened.list(0, 10)
        @Expect(all.size, 3)
        @Expect(all[0].at, 300)
        @Expect(reopened.bySkill('日报助手', 10).size, 2)
        // 继续追加时 id 不复用
        @Expect(reopened.save(EvolutionEntry(0, '爬虫助手', 'created', 'id=4', 400)), 4)
    }
}
