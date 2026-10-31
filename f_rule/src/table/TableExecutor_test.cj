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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler
import fountain::f_rule.condition.Truth
import fountain::f_rule.exception.*
import fountain::f_rule.fact.{FactBaseView, FactBaseViewStore, TypedFact}
import fountain::f_rule.rule.RuleSet

/**
 * 决策表执行与结果聚合（`doc/07-decision-table.md` §9，用例 I-01/T-06/T-10）。
 *
 * `TableExecutor` 直接在事实视图上逐行求值（单模式表与议程语义等价），
 * 再按 `HitPolicy` 聚合输出，并可选记录逐列 trace。
 */
@Test
class TableExecutor_test {
    private func orderRuleSet(): RuleSet {
        tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
    }

    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<TableOrder>()
        c
    }

    private func view(ruleSet: RuleSet, orders: Array<TableOrder>): FactBaseView {
        let view = FactBaseViewStore(ruleSet.registry).view("orders", "s1")
        for (order in orders) {
            let _ = view.assert(TypedFact(order, tableOrderSchema()))
        }
        view
    }

    private func pricingTable(policy: HitPolicy): DecisionTable {
        DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(policy)
            .whenColumn("order.level")
            .whenColumn("order.amount")
            .thenColumn("discount")
            .thenColumn("event")
            .row("R1", [">=3", ">200", "0.85", "order.discounted"])
            .row("R2", [">=1", ">500", "0.90", "order.discounted"])
            .build()
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        try {
            action()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** I-01：端到端命中第一行并输出折扣。 */
    @TestCase
    public func executesEndToEnd(): Unit {
        let ruleSet = orderRuleSet()
        let table = pricingTable(HitPolicy.First)
        let result = TableExecutor(table, ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 500)]))

        @Assert(result.hits.size, 1)
        @Assert(result.hits[0].ruleId, "R1")
        @Expect(result.outputs.size, 1)
        @Assert(result.outputs[0].get("discount").getOrThrow() as Float64, 0.85)
        @Assert(result.outputs[0].get("event").getOrThrow() as String, "order.discounted")
    }

    /** T-06：`${binding.field}` 在运行期取事实字段。 */
    @TestCase
    public func resolvesFieldOutput(): Unit {
        let ruleSet = orderRuleSet()
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(HitPolicy.First)
            .whenColumn("order.level")
            .thenColumn("levelCopy")
            .row([">=1", "\${order.level}"])
            .build()
        let result = TableExecutor(table, ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 500)]))
        @Assert(result.outputs[0].get("levelCopy").getOrThrow() as Int64, 3)
    }

    /** T-10：`Collect` 返回全部命中，顺序与行序一致。 */
    @TestCase
    public func collectReturnsAllInRowOrder(): Unit {
        let ruleSet = orderRuleSet()
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(HitPolicy.Collect)
            .whenColumn("order.level")
            .thenColumn("discount")
            .row("R1", [">=1", "0.85"])
            .row("R2", [">=2", "0.90"])
            .row("R3", [">=3", "0.95"])
            .build()
        let result = TableExecutor(table, ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 500)]))

        @Expect(result.hits.size, 3)
        let ids = ArrayList<String>()
        for (hit in result.hits) {
            ids.add(hit.ruleId)
        }
        @Assert(ids.toArray(), ["R1", "R2", "R3"])
        @Expect(result.outputs.size, 3)
        @Assert(result.outputs[2].get("discount").getOrThrow() as Float64, 0.95)
    }

    /** `Unique` 零命中抛 `TABLE_NO_MATCH`。 */
    @TestCase
    public func uniqueNoMatchThrows(): Unit {
        let ruleSet = orderRuleSet()
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(HitPolicy.Unique)
            .whenColumn("order.amount")
            .thenColumn("discount")
            .row(["> 1000", "0.5"])
            .build()
        @Expect(codeOf({ => TableExecutor(table, ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 500)])) }),
            RuleErrorCode.TABLE_NO_MATCH)
    }

    /** `Any` 多命中但输出不同抛 `TABLE_MULTI_MATCH`。 */
    @TestCase
    public func anyConflictThrows(): Unit {
        let ruleSet = orderRuleSet()
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(HitPolicy.Any)
            .whenColumn("order.level")
            .thenColumn("discount")
            .row("R1", [">=1", "0.85"])
            .row("R2", [">=2", "0.90"])
            .build()
        @Expect(codeOf({ => TableExecutor(table, ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 500)])) }),
            RuleErrorCode.TABLE_MULTI_MATCH)
    }

    /** trace 记录每行每列结果，未命中行标出 false 的列。 */
    @TestCase
    public func traceRecordsEachColumn(): Unit {
        let ruleSet = orderRuleSet()
        let table = pricingTable(HitPolicy.First)
        let result = TableExecutor(table, ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 300)]), trace: true)

        @Expect(result.trace.size, 2)
        let r1 = result.trace[0]
        @Assert(r1.ruleId, "R1")
        @Expect(r1.matched, true)
        @Expect(r1.columns.size, 2)
        @Assert(r1.columns[1].column, "when.order.amount")
        @Expect(r1.columns[1].result, Truth.True)

        let r2 = result.trace[1]
        @Assert(r2.ruleId, "R2")
        @Expect(r2.matched, false)
        @Expect(r2.columns[1].result, Truth.False)
    }

    /** 未开启 trace 时结果为空。 */
    @TestCase
    public func traceIsOptIn(): Unit {
        let ruleSet = orderRuleSet()
        let result = TableExecutor(pricingTable(HitPolicy.First), ruleSet)
            .execute(view(ruleSet, [TableOrder("A", 3, 500)]))
        @Expect(result.trace.size, 0)
    }

    /** `expr` 列参与命中判定。 */
    @TestCase
    public func exprColumnFiltersRows(): Unit {
        let ruleSet = orderRuleSet()
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(HitPolicy.First)
            .exprColumn("big")
            .thenColumn("discount")
            .row(["o.amount > 200", "0.85"])
            .build()
        let executor = TableExecutor(table, ruleSet, compiler())

        let hit = executor.execute(view(ruleSet, [TableOrder("A", 3, 500)]))
        @Assert(hit.hits.size, 1)
        let miss = executor.execute(view(ruleSet, [TableOrder("B", 3, 100)]))
        @Expect(miss.hits.size, 0)
    }
}
