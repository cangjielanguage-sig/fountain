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

/** 演进报告库：写入与回读 */
@Test
class SkillEvolutionLedger_test {
    private static func gateway(): LoomStoreGateway {
        LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
    }

    private static func report(): SkillEvolutionReport {
        SkillEvolutionReport(
            ArrayList<String>(['日报助手: v1 -> v2 (passed)']),
            ArrayList<String>(['代码评审: no samples']),
            ArrayList<String>(['爬虫助手: cooldown']),
            ArrayList<String>(['爬虫助手 (id=2)']),
            1)
    }

    /** 四类结果都落库，条数对得上 */
    @TestCase
    func testWritesAllOutcomes(): Unit {
        let gateway = gateway()
        let written = SkillEvolutionLedger.write(gateway, report(), 1700000000)
        @Expect(written, 4)
        let records = SkillEvolutionLedger.list(gateway, limit: 10)
        @Expect(records.size, 4)
        @Expect(records[0].docId.startsWith('loom:evolution:'), true)
    }

    /** 读回来能区分动作类型与详情 */
    @TestCase
    func testListPreservesActionAndDetail(): Unit {
        let gateway = gateway()
        SkillEvolutionLedger.write(gateway, report(), 1700000000)
        let records = SkillEvolutionLedger.list(gateway, limit: 10)
        var actions = ArrayList<String>()
        for(item in records){
            actions.add(item.action)
        }
        @Expect(actions.contains('evolved'), true)
        @Expect(actions.contains('created'), true)
        @Expect(actions.contains('rejected'), true)
        @Expect(actions.contains('skipped'), true)
    }

    /** 空报告：不写任何东西 */
    @TestCase
    func testEmptyReportWritesNothing(): Unit {
        let gateway = gateway()
        let empty = SkillEvolutionReport(ArrayList<String>(), ArrayList<String>(),
            ArrayList<String>(), ArrayList<String>(), 0)
        @Expect(SkillEvolutionLedger.write(gateway, empty, 1), 0)
        @Expect(SkillEvolutionLedger.list(gateway, limit: 5).size, 0)
    }

    /** limit 生效：最多返回指定条数 */
    @TestCase
    func testListRespectsLimit(): Unit {
        let gateway = gateway()
        SkillEvolutionLedger.write(gateway, report(), 1700000000)
        @Expect(SkillEvolutionLedger.list(gateway, limit: 2).size, 2)
    }
}
