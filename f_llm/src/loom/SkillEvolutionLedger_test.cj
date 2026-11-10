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

import fountain::f_llm.store.*

/** 演进报告表：写入、回读、按技能筛选 */
@Test
class SkillEvolutionLedger_test {
    private static func report(): SkillEvolutionReport {
        SkillEvolutionReport(
            ArrayList<String>(['日报助手: v1 -> v2 (passed)']),
            ArrayList<String>(['代码评审: no samples']),
            ArrayList<String>(['爬虫助手: cooldown']),
            ArrayList<String>(['爬虫助手 (id=2)']),
            1)
    }

    /** 四类结果都落表，条数对得上 */
    @TestCase
    func testWritesAllOutcomes(): Unit {
        let store = InMemoryEvolutionStore()
        let written = SkillEvolutionLedger.write(store, report(), 1700000000)
        @Expect(written, 4)
        @Expect(SkillEvolutionLedger.list(store, limit: 10).size, 4)
    }

    /** 能区分动作类型，详情原样保留 */
    @TestCase
    func testListPreservesActionAndDetail(): Unit {
        let store = InMemoryEvolutionStore()
        SkillEvolutionLedger.write(store, report(), 1700000000)
        let entries = SkillEvolutionLedger.list(store, limit: 10)
        var actions = ArrayList<String>()
        for(item in entries){
            actions.add(item.action)
        }
        @Expect(actions.contains('evolved'), true)
        @Expect(actions.contains('created'), true)
        @Expect(actions.contains('rejected'), true)
        @Expect(actions.contains('skipped'), true)
        @Expect(entries[0].detail.isEmpty(), false)
    }

    /** 空报告不写任何东西 */
    @TestCase
    func testEmptyReportWritesNothing(): Unit {
        let store = InMemoryEvolutionStore()
        let empty = SkillEvolutionReport(ArrayList<String>(), ArrayList<String>(),
            ArrayList<String>(), ArrayList<String>(), 0)
        @Expect(SkillEvolutionLedger.write(store, empty, 1), 0)
        @Expect(SkillEvolutionLedger.list(store, limit: 5).size, 0)
    }

    /** 按技能筛选：只返回该技能的记录 */
    @TestCase
    func testHistoryFiltersBySkill(): Unit {
        let store = InMemoryEvolutionStore()
        SkillEvolutionLedger.write(store, report(), 1700000000)
        let history = SkillEvolutionLedger.history(store, '日报助手', limit: 10)
        @Expect(history.size, 1)
        @Expect(history[0].action, 'evolved')
    }

    /** limit 生效 */
    @TestCase
    func testListRespectsLimit(): Unit {
        let store = InMemoryEvolutionStore()
        SkillEvolutionLedger.write(store, report(), 1700000000)
        @Expect(SkillEvolutionLedger.list(store, limit: 2).size, 2)
    }
}
