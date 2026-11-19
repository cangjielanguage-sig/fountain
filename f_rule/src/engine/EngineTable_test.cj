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
package fountain::f_rule.engine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.{DynamicFact, Fact}
import fountain::f_rule.rule.{RuleSet, RuleSetBuilder}
import fountain::f_rule.table.*

/**
 * 引擎侧决策表执行（`doc/11-assembly.md` §4.3/§4.4，用例 AS-06~AS-12）。
 *
 * 聚合路径（`executeTable`）按 `(id, version)` 缓存执行器；议程路径（`.table()`）
 * 由 `activationGroup` + `salience` 表达命中策略。两条路径对同一实例硬互斥。
 */
@Test
class EngineTable_test {
    private func ruleSet(): RuleSet {
        RuleSetBuilder("engine")
            .version("v1")
            .registerDynamicType("orders", "Order", ["level", "amount"])
            .build()
    }

    private func order(level: Int64, amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("level", level)
        fact.set("amount", amount)
        fact
    }

    private func table(id!: String = "pricing", version!: String = "v1",
        policy!: HitPolicy = HitPolicy.First, firstDiscount!: String = "0.85",
        secondDiscount!: String = "0.90"): DecisionTable {
        DecisionTable.builder(id)
            .version(version)
            .factSpace("orders")
            .hitPolicy(policy)
            .whenColumn("order.level")
            .thenColumn("discount")
            .row("R1", [">=1", firstDiscount])
            .row("R2", [">=2", secondDiscount])
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

    private func firedIds(result: FireResult): Array<String> {
        let ids = ArrayList<String>()
        for (item in result.fired) {
            ids.add(item.ruleId)
        }
        ids.toArray()
    }

    /** AS-06：`executeTable` 的输出与直接构造 `TableExecutor` 一致。 */
    @TestCase
    public func executesTableEndToEnd(): Unit {
        let engine = RuleEngine(ruleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", order(3, 500))
        let table = table()

        let viaEngine = engine.executeTable(table, session)
        let direct = TableExecutor(table, engine.ruleSet.registry)
            .execute(session.factsOf("orders"))

        @Assert(viaEngine.hits.size, direct.hits.size)
        @Assert(viaEngine.hits[0].ruleId, direct.hits[0].ruleId)
        @Assert(viaEngine.outputs[0].get("discount").getOrThrow() as Float64,
            direct.outputs[0].get("discount").getOrThrow() as Float64)
    }

    /** AS-07：同一张表两次执行只编译一次。 */
    @TestCase
    public func cachesExecutorPerTable(): Unit {
        let engine = RuleEngine(ruleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", order(3, 500))
        let table = table()
        let before = TableCompiler.compileCount()

        let _ = engine.executeTable(table, session)
        let _ = engine.executeTable(table, session)

        @Expect(TableCompiler.compileCount() - before, 1)
    }

    /** AS-08：同 id 不同 version 视为两张表，各自编译并产出各自结果。 */
    @TestCase
    public func recompilesWhenVersionChanges(): Unit {
        let engine = RuleEngine(ruleSet())
        let session = engine.session("s1")
        let _ = session.assert("orders", order(3, 500))
        let v1 = table(version: "v1", firstDiscount: "0.85")
        let v2 = table(version: "v2", firstDiscount: "0.95")
        let before = TableCompiler.compileCount()

        let first = engine.executeTable(v1, session)
        let second = engine.executeTable(v2, session)

        @Expect(TableCompiler.compileCount() - before, 2)
        @Assert(first.outputs[0].get("discount").getOrThrow() as Float64, 0.85)
        @Assert(second.outputs[0].get("discount").getOrThrow() as Float64, 0.95)
    }

    /** AS-09：`First` 进议程后同组互斥，两行都命中也只执行第一行。 */
    @TestCase
    public func firstPolicyFiresOnlyFirstRow(): Unit {
        let table = table(policy: HitPolicy.First)
        let ruleSet = RuleSetBuilder("engine")
            .version("v1")
            .registerDynamicType("orders", "Order", ["level", "amount"])
            .table(table)
            .build()
        let engine = RuleEngine(ruleSet)
        let session = engine.session("s1")
        let _ = session.assert("orders", order(3, 500))

        let result = session.fireDetailed()

        @Expect(result.fired.size, 1)
        @Assert(firedIds(result), ["pricing/R1"])
        @Assert(result.outputs.get("discount").getOrThrow() as Float64, 0.85)
    }

    /** AS-10：`Collect` 不分组，两行都执行，输出槽按行序后写覆盖。 */
    @TestCase
    public func collectPolicyFiresAllRowsInOrder(): Unit {
        let table = table(policy: HitPolicy.Collect)
        let ruleSet = RuleSetBuilder("engine")
            .version("v1")
            .registerDynamicType("orders", "Order", ["level", "amount"])
            .table(table)
            .build()
        let engine = RuleEngine(ruleSet)
        let session = engine.session("s1")
        let _ = session.assert("orders", order(3, 500))

        let result = session.fireDetailed()

        @Expect(result.fired.size, 2)
        @Assert(firedIds(result), ["pricing/R1", "pricing/R2"])
        @Assert(result.outputs.get("discount").getOrThrow() as Float64, 0.90)
    }

    /** AS-11：装配后再 `executeTable` 抛冲突；反向亦然。 */
    @TestCase
    public func rejectsCrossModeUseBothDirections(): Unit {
        let assembled = table()
        let engineA = RuleEngine(RuleSetBuilder("engine")
            .registerDynamicType("orders", "Order", ["level", "amount"])
            .table(assembled)
            .build())
        let sessionA = engineA.session("s1")
        @Expect(codeOf({ => engineA.executeTable(assembled, sessionA) }),
            RuleErrorCode.TABLE_MODE_CONFLICT)

        let executed = table()
        let engineB = RuleEngine(ruleSet())
        let sessionB = engineB.session("s1")
        let _ = engineB.executeTable(executed, sessionB)
        @Expect(codeOf({ => RuleSetBuilder("engine")
            .registerDynamicType("orders", "Order", ["level", "amount"])
            .table(executed) }), RuleErrorCode.TABLE_MODE_CONFLICT)
    }

    /** AS-12：同模式重复使用合法——两个引擎对同一张表各执行一次。 */
    @TestCase
    public func allowsSameModeAcrossEngines(): Unit {
        let table = table()
        let first = RuleEngine(ruleSet())
        let second = RuleEngine(ruleSet())
        let firstSession = first.session("s1")
        let secondSession = second.session("s1")
        let _ = firstSession.assert("orders", order(3, 500))
        let _ = secondSession.assert("orders", order(3, 500))

        let firstResult = first.executeTable(table, firstSession)
        let secondResult = second.executeTable(table, secondSession)

        @Assert(firstResult.hits.size, 1)
        @Assert(secondResult.hits.size, 1)
    }
}
