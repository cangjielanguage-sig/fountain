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
package fountain::f_rule.table

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * 七种命中策略的 0/1/N 行为（`doc/07-decision-table.md` §2，用例 T-07~T-11）。
 *
 * 聚合器只做"命中集合 → 结果集合"的纯函数变换，不接触事实与引擎。
 */
@Test
class HitPolicy_test {
    private func hit(ruleId: String, line: Int64, salience: Int64,
        outputs: Array<(String, Any)>): TableHit {
        let map = HashMap<String, Any>()
        for ((key, value) in outputs) {
            map[key] = value
        }
        TableHit(TableRow(line, Array<?String>(), ruleId), map, salience)
    }

    private func hit(ruleId: String, discount: Float64): TableHit {
        hit(ruleId, 2, 0, [("discount", discount)])
    }

    private func ids(hits: Array<TableHit>): Array<String> {
        let out = ArrayList<String>()
        for (item in hits) {
            out.add(item.row.ruleId)
        }
        out.toArray()
    }

    private func codeOf(policy: HitPolicy, hits: Array<TableHit>): RuleErrorCode {
        try {
            let _ = HitAggregator(policy).aggregate(hits)
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** T-07：Unique 零命中抛 `TABLE_NO_MATCH`；一行命中原样返回。 */
    @TestCase
    public func uniquePolicy(): Unit {
        @Expect(codeOf(HitPolicy.Unique, Array<TableHit>()), RuleErrorCode.TABLE_NO_MATCH)
        let single = HitAggregator(HitPolicy.Unique).aggregate([hit("R1", 2, 0, [("discount", 0.85)])])
        @Assert(ids(single), ["R1"])
    }

    /** T-08：Unique 多命中抛 `TABLE_MULTI_MATCH`。 */
    @TestCase
    public func uniqueRejectsMultiHit(): Unit {
        @Expect(codeOf(HitPolicy.Unique, [hit("R1", 0.85), hit("R2", 0.9)]),
            RuleErrorCode.TABLE_MULTI_MATCH)
    }

    /** T-09：First 零命中返回空，多命中取第一行。 */
    @TestCase
    public func firstPolicy(): Unit {
        let none = HitAggregator(HitPolicy.First).aggregate(Array<TableHit>())
        @Expect(none.size, 0)
        let picked = HitAggregator(HitPolicy.First).aggregate([hit("R1", 0.85), hit("R2", 0.9)])
        @Assert(ids(picked), ["R1"])
    }

    /** Priority：按 outputOrder 指定的输出值取最小。 */
    @TestCase
    public func priorityPolicy(): Unit {
        let aggregator = HitAggregator(HitPolicy.Priority, outputOrder: ["discount"])
        let hits = [hit("R1", 0.90), hit("R2", 0.85), hit("R3", 0.95)]
        @Assert(ids(aggregator.aggregate(hits)), ["R2"])
        @Expect(HitAggregator(HitPolicy.Priority, outputOrder: ["discount"])
            .aggregate(Array<TableHit>()).size, 0)
    }

    /** T-11：Any 多命中且输出一致才返回，输出不同抛 `TABLE_MULTI_MATCH`。 */
    @TestCase
    public func anyPolicy(): Unit {
        let same = [hit("R1", 0.85), hit("R2", 0.85)]
        @Assert(ids(HitAggregator(HitPolicy.Any).aggregate(same)), ["R1", "R2"])
        @Expect(codeOf(HitPolicy.Any, [hit("R1", 0.85), hit("R2", 0.90)]),
            RuleErrorCode.TABLE_MULTI_MATCH)
    }

    /** T-10：Collect 返回全部命中，保持行序。 */
    @TestCase
    public func collectPolicy(): Unit {
        let hits = [hit("R2", 3, 0, [("discount", 0.9)]), hit("R1", 2, 0, [("discount", 0.85)])]
        @Assert(ids(HitAggregator(HitPolicy.Collect).aggregate(hits)), ["R2", "R1"])
    }

    /** RuleOrder：按 salience 降序，同 salience 保持行序。 */
    @TestCase
    public func ruleOrderPolicy(): Unit {
        let hits = [
            hit("R1", 2, 10, [("discount", 0.85)]),
            hit("R2", 3, 30, [("discount", 0.9)]),
            hit("R3", 4, 20, [("discount", 0.95)])
        ]
        @Assert(ids(HitAggregator(HitPolicy.RuleOrder).aggregate(hits)), ["R2", "R3", "R1"])
    }

    /** OutputOrder：按输出值升序。 */
    @TestCase
    public func outputOrderPolicy(): Unit {
        let hits = [hit("R1", 0.9), hit("R2", 0.85), hit("R3", 0.95)]
        @Assert(ids(HitAggregator(HitPolicy.OutputOrder).aggregate(hits)), ["R2", "R1", "R3"])
    }

    /** 未知策略名解析失败。 */
    @TestCase
    public func parsesPolicyNames(): Unit {
        @Expect(HitPolicy.parse("collect"), HitPolicy.Collect)
        @Expect(HitPolicy.parse("RuleOrder"), HitPolicy.RuleOrder)
        var code = RuleErrorCode.ILLEGAL_STATE
        try {
            let _ = HitPolicy.parse("bogus")
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.TABLE_INVALID)
    }
}
