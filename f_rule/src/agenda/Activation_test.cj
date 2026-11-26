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
package fountain::f_rule.agenda

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.Rule

/**
 * 激活契约（`doc/05-agenda-conflict-resolution.md` §2）。
 *
 * 覆盖：相等性 `(factSpace, ruleId, bindings)`、跨空间同名规则不同激活、
 * `specificity` 由规则条件数算出、`seq` 单调、`salience`/`rule` 透传。
 */
@Test
class Activation_test {
    private func order(amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func bindingsOf(space: String, id: Int64, amount: Int64): Bindings {
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        handles["o"] = FactHandle(space, id, "Order")
        facts["o"] = order(amount)
        Bindings.of(handles, facts)
    }

    /** 两个模式、每个模式一条约束 → specificity = 2 + 2。 */
    private func rule(id: String, space: String, salience!: Int64 = 0): Rule {
        Rule.builder(id)
            .salience(salience)
            .facts(space)
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 100))
            .addPattern(Pattern("Order", "u").constrain("amount", Operator.Lt, 500))
            .build()
    }

    /** 相等性只由 `(factSpace, ruleId, bindings)` 决定。 */
    @TestCase
    public func equalityUsesSpaceRuleAndBindings(): Unit {
        let target = rule("R1", "orders")
        let shared = bindingsOf("orders", 1, 300)
        let left = Activation(target, shared)
        let right = Activation(target, shared)
        let otherFact = Activation(target, bindingsOf("orders", 2, 300))

        @Expect(left == right, true)
        @Assert(left.hashCode(), right.hashCode())
        @Expect(left == otherFact, false)
    }

    /** 不同空间的同名规则是不同激活。 */
    @TestCase
    public func sameRuleIdInDifferentSpacesIsDistinct(): Unit {
        let orders = Activation(rule("R1", "orders"), bindingsOf("orders", 1, 300))
        let users = Activation(rule("R1", "users"), bindingsOf("users", 1, 300))

        @Expect(orders == users, false)
        @Assert(orders.factSpace, "orders")
        @Assert(users.factSpace, "users")
        @Expect(orders.sortKey() == users.sortKey(), false)
    }

    /** `specificity` 是模式数 + 约束数，与具体事实无关。 */
    @TestCase
    public func specificityCountsPatternsAndConstraints(): Unit {
        let activation = Activation(rule("R1", "orders"), bindingsOf("orders", 1, 300))
        @Assert(activation.specificity, 4)
    }

    /** `seq` 单调递增，保证冲突消解有全序兜底。 */
    @TestCase
    public func seqIsMonotonic(): Unit {
        let target = rule("R1", "orders")
        let first = Activation(target, bindingsOf("orders", 1, 300))
        let second = Activation(target, bindingsOf("orders", 2, 300))
        let third = Activation(target, bindingsOf("orders", 3, 300))

        @Expect(first.seq < second.seq, true)
        @Expect(second.seq < third.seq, true)
    }

    /** 激活携带规则、salience 与规则声明顺序，供动作与冲突消解使用。 */
    @TestCase
    public func carriesRuleSalienceAndOrder(): Unit {
        let target = rule("R7", "orders", salience: 100)
        let activation = Activation(target, bindingsOf("orders", 1, 300))

        var sameRule = false
        match ((activation.rule as Object, target as Object)) {
            case (Some(left), Some(right)) => sameRule = refEq(left, right)
            case _ => ()
        }
        @Expect(sameRule, true)
        @Assert(activation.ruleId, "R7")
        @Assert(activation.salience, 100)
        @Assert(activation.bindings.resolve("o").getOrThrow().get("amount").getOrThrow() as Int64, 300)
        @Expect(activation.bindings.get("o").isSome(), true)
        @Expect(activation.bindings.get("missing").isNone(), true)
    }
}
