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
package fountain::f_rule.rete

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.{JoinConstraint, Operator, Pattern}
import fountain::f_rule.fact.{DynamicFact, Fact, FactBase, FactSpace}
import fountain::f_rule.rule.{Rule, RuleSet, RuleSetBuilder}

/**
 * 根节点按值分发（`doc/04-rete-network.md` §3）。
 *
 * 等值首约束的链头按 `(字段, 值)` 建桶后，事实只计算一次字段值就能定位命中的链头。
 * 这些用例锁定分发不改变匹配语义：命中值激活、未命中值不激活、字符串与数值都覆盖，
 * 且同值的多个链头都会传播。
 */
@Test
class RootDispatch_test {
    private func ruleSet(id: String, rules: Array<Rule>): RuleSet {
        let builder = RuleSetBuilder(id)
            .registerDynamicType("default", "GenFact", ["code", "amount"])
        for (rule in rules) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }

    private func spaceOf(ruleSet: RuleSet): FactSpace {
        ruleSet.registry.get("default").getOrThrow()
    }

    private func factOf(code: String, amount: Int64): DynamicFact {
        let fact = DynamicFact("GenFact")
        fact.set("code", code)
        fact.set("amount", amount)
        fact
    }

    /** 字符串等值约束：命中值产生激活，未命中值不产生。 */
    @TestCase
    public func stringEqualityDispatchesByValue(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "o").constrain("code", Operator.Eq, "A"))
            .build()
        let ruleSet = ruleSet("dispatch-string", [rule])
        let sink = RecordingSink()
        let runtime = ShardedNetwork(ruleSet).session("s1", sink)
        let base = FactBase(spaceOf(ruleSet), "s1")

        let hit = factOf("A", 1)
        runtime.assert("default", base.assert(hit), hit)
        @Expect(Int64(sink.size()), 1)
    }

    /** 未命中的值不进入任何链头；随后命中值仍能正常激活。 */
    @TestCase
    public func nonMatchingValueIsSkipped(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "o").constrain("code", Operator.Eq, "A"))
            .build()
        let ruleSet = ruleSet("dispatch-miss", [rule])
        let sink = RecordingSink()
        let runtime = ShardedNetwork(ruleSet).session("s1", sink)
        let base = FactBase(spaceOf(ruleSet), "s1")

        let miss = factOf("B", 2)
        runtime.assert("default", base.assert(miss), miss)
        @Expect(Int64(sink.size()), 0)

        let hit = factOf("A", 3)
        runtime.assert("default", base.assert(hit), hit)
        @Expect(Int64(sink.size()), 1)
    }

    /** 数值等值约束与 `Int64`/`Float64` 归一后的相等语义保持一致。 */
    @TestCase
    public func numericEqualityUsesValueKeySemantics(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "o").constrain("amount", Operator.Eq, 7))
            .build()
        let ruleSet = ruleSet("dispatch-number", [rule])
        let sink = RecordingSink()
        let runtime = ShardedNetwork(ruleSet).session("s1", sink)
        let base = FactBase(spaceOf(ruleSet), "s1")

        let real = factOf("X", 0)
        real.set("amount", 7.0)
        runtime.assert("default", base.assert(real), real)
        @Expect(Int64(sink.size()), 1)
    }

    /** 同值的多个链头都要被分发到（桶内多条）。 */
    @TestCase
    public func allHeadsInBucketPropagate(): Unit {
        let first = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "o")
                .constrain("code", Operator.Eq, "A")
                .constrain("amount", Operator.Gt, 0))
            .build()
        let second = Rule.builder("R2")
            .addPattern(Pattern("GenFact", "o")
                .constrain("code", Operator.Eq, "A")
                .constrain("amount", Operator.Lt, 100))
            .build()
        let ruleSet = ruleSet("dispatch-bucket", [first, second])
        let sink = RecordingSink()
        let runtime = ShardedNetwork(ruleSet).session("s1", sink)
        let base = FactBase(spaceOf(ruleSet), "s1")

        let fact = factOf("A", 50)
        runtime.assert("default", base.assert(fact), fact)
        @Expect(Int64(sink.size()), 2)
    }

    /** 非等值首约束（范围）仍走逐条测试路径。 */
    @TestCase
    public func rangeHeadStaysUnindexed(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "o").constrain("amount", Operator.Ge, 10))
            .build()
        let ruleSet = ruleSet("dispatch-range", [rule])
        let sink = RecordingSink()
        let runtime = ShardedNetwork(ruleSet).session("s1", sink)
        let base = FactBase(spaceOf(ruleSet), "s1")

        let hit: Fact = factOf("Z", 10)
        runtime.assert("default", base.assert(hit), hit)
        @Expect(Int64(sink.size()), 1)
    }

    /** 两个等值模式 + 跨模式 join：两条按值分发路径相遇后产出激活。 */
    @TestCase
    public func joinedEqualityPatternsProduceActivation(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "a").constrain("code", Operator.Eq, "A"))
            .addPattern(Pattern("GenFact", "b").constrain("code", Operator.Eq, "A"))
            .join(JoinConstraint("a", "amount", Operator.Eq, "b", "amount"))
            .build()
        let ruleSet = ruleSet("dispatch-join", [rule])
        let sink = RecordingSink()
        let runtime = ShardedNetwork(ruleSet).session("s1", sink)
        let base = FactBase(spaceOf(ruleSet), "s1")

        let fact = factOf("A", 5)
        runtime.assert("default", base.assert(fact), fact)
        @Assert(Int64(sink.size()), 1)
    }
}
