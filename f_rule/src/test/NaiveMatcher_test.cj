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
package fountain::f_rule.test

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.*
import fountain::f_rule.condition.*
import fountain::f_rule.fact.*
import fountain::f_rule.rule.*

/**
 * 朴素顺序匹配器（差分基准）的空间语义（`doc/09-testing.md` §4.1，用例 F-11/F-12）。
 *
 * 作为 Rete 的语义基准，这里的行为必须最直白：按空间取事实、按模式过滤、
 * 嵌套循环组合、逐条 join 判定。
 */
@Test
class NaiveMatcher_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func ruleSetOf(rules: Array<Rule>): RuleSet {
        let builder = RuleSetBuilder("naive")
            .registerDynamicType("a", "Order", ["amount"])
            .registerDynamicType("b", "Order", ["amount"])
            .registerDynamicType("default", "Order", ["amount"])
        for (rule in rules) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }

    private func factsOf(space: String, facts: Array<Fact>): HashMap<String, Array<Fact>> {
        let map = HashMap<String, Array<Fact>>()
        map[space] = facts
        map
    }

    /** 单空间单规则：匹配所有满足约束的事实。 */
    @TestCase
    public func singleRuleMatchesConformingFacts(): Unit {
        let ruleSet = ruleSetOf([
            Rule.builder("R1").facts("a")
                .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
                .build()
        ])
        let facts: Array<Fact> = [order(500), order(100), order(300)]
        let matched = NaiveMatcher(ruleSet).matches(factsOf("a", facts))
        @Assert(matched.size, 2)
        @Assert(matched[0].ruleId, "R1")
        @Assert(matched[0].factSpace, "a")
        @Expect(matched[0].bindings.resolve("o").isSome(), true)
    }

    /** F-12：同空间的多条规则都能看到同一批事实。 */
    @TestCase
    public func sharedSpaceRulesSeeSameFacts(): Unit {
        let ruleSet = ruleSetOf([
            Rule.builder("R1").facts("a").addPattern(Pattern.any("Order", "o")).build(),
            Rule.builder("R2").facts("a").addPattern(Pattern.any("Order", "p")).build(),
            Rule.builder("R3").facts("a")
                .addPattern(Pattern("Order", "q").constrain("amount", Operator.Ge, 0))
                .build()
        ])
        let matched = NaiveMatcher(ruleSet).matches(factsOf("a", [order(10)]))
        @Assert(matched.size, 3)
        @Assert(matched[0].ruleId, "R1")
        @Assert(matched[1].ruleId, "R2")
        @Assert(matched[2].ruleId, "R3")
    }

    /** F-11：隔离空间互不可见。 */
    @TestCase
    public func isolatedSpacesDoNotSeeEachOther(): Unit {
        let ruleSet = ruleSetOf([
            Rule.builder("R1").facts("a").addPattern(Pattern.any("Order", "o")).build(),
            Rule.builder("R2").facts("b").addPattern(Pattern.any("Order", "o")).build()
        ])
        let facts: Array<Fact> = [order(10)]
        let matched = NaiveMatcher(ruleSet).matches(factsOf("a", facts))
        @Assert(matched.size, 1)
        @Assert(matched[0].ruleId, "R1")
        @Assert(matched[0].factSpace, "a")

        let empty = NaiveMatcher(ruleSet).matches(HashMap<String, Array<Fact>>())
        @Assert(empty.size, 0)
    }

    /** 两模式 join：嵌套循环 + 逐条判定。 */
    @TestCase
    public func joinProducesOnlySatisfyingCombinations(): Unit {
        let ruleSet = ruleSetOf([
            Rule.builder("R1").facts("a")
                .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 0))
                .addPattern(Pattern("Order", "u").constrain("amount", Operator.Gt, 0))
                .join(JoinConstraint("o", "amount", Operator.Gt, "u", "amount"))
                .build()
        ])
        let facts: Array<Fact> = [order(10), order(20), order(30)]
        let matched = NaiveMatcher(ruleSet).matches(factsOf("a", facts))
        // 3 条事实两两组合满足 o > u 的有 C(3,2) = 3 组
        @Assert(matched.size, 3)
    }

    /** 无约束模式匹配类型全部事实；空事实集合产出空激活。 */
    @TestCase
    public func emptyFactsProduceNoActivation(): Unit {
        let ruleSet = ruleSetOf([
            Rule.builder("R1").facts("a").addPattern(Pattern.any("Order", "o")).build()
        ])
        let matched = NaiveMatcher(ruleSet).matches(factsOf("a", []))
        @Assert(matched.size, 0)
    }
}
