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

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.RuleSetBuilder
import fountain::f_rule.agenda.Activation
import fountain::f_rule.condition.{JoinConstraint, Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{Rule, RuleSet}
import fountain::f_rule.test.{NaiveActivation, NaiveMatcher}

/**
 * 网络的增量插入、撤销与更新（`doc/04-rete-network.md` §6、§9，
 * 用例 R-01/R-08/R-10/R-11/R-12/R-13）。
 *
 * 每个断言点都与 `NaiveMatcher` 的激活集合逐条比对，避免"能跑但语义错"。
 */
@Test
class ReteNetwork_test {
    private func order(amount: Int64, level: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact.set("level", level)
        fact
    }

    private func ruleSetOf(rules: Array<Rule>): RuleSet {
        let builder = RuleSetBuilder("rete")
            .registerDynamicType("default", "Order", ["amount", "level"])
        for (rule in rules) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }

    private func singleRule(): Rule {
        Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
            .build()
    }

    private func joinRule(): Rule {
        Rule.builder("R1")
            .addPattern(Pattern("Order", "o")
                .constrain("amount", Operator.Ge, 100)
                .constrain("level", Operator.Ge, 4))
            .addPattern(Pattern("Order", "u")
                .constrain("amount", Operator.Ge, 100)
                .constrain("level", Operator.Le, 3))
            .join(JoinConstraint("o", "amount", Operator.Eq, "u", "amount"))
            .build()
    }

    private func open(ruleSet: RuleSet): (ReteNetwork, SessionNetwork, RecordingSink) {
        let network = ReteNetwork("default")
        network.build(ruleSet.rules, ruleSet.registry)
        let sink = RecordingSink()
        (network, network.open("s1", sink), sink)
    }

    /** R-01：单模式规则的激活与朴素匹配一致。 */
    @TestCase
    public func singlePatternMatchesNaive(): Unit {
        let ruleSet = ruleSetOf([singleRule()])
        let (_, session, sink) = open(ruleSet)
        let facts: Array<Fact> = [order(500, 1), order(100, 1), order(300, 1)]
        var id: Int64 = 1
        for (fact in facts) {
            session.assert(FactHandle("default", id, "Order"), fact)
            id += 1
        }
        @Assert(sink.size(), 2)
        @Expect(sameActivations(sink.activations(), NaiveMatcher(ruleSet).matches("default", facts)), true)
    }

    /** R-10：重复传播同一句柄幂等。 */
    @TestCase
    public func duplicatePropagationIsIdempotent(): Unit {
        let ruleSet = ruleSetOf([singleRule()])
        let (_, session, sink) = open(ruleSet)
        let handle = FactHandle("default", 1, "Order")
        let fact = order(300, 1)
        session.assert(handle, fact)
        session.assert(handle, fact)
        @Assert(sink.size(), 1)
        @Assert(session.alphaSize(), 1)
    }

    /** R-08：撤销后令牌归零、激活被移除，其余激活保留。 */
    @TestCase
    public func retractRemovesTokenAndActivation(): Unit {
        let ruleSet = ruleSetOf([joinRule()])
        let (_, session, sink) = open(ruleSet)
        let left = order(100, 5)
        let right = order(100, 2)
        let leftHandle = FactHandle("default", 1, "Order")
        let rightHandle = FactHandle("default", 2, "Order")
        session.assert(leftHandle, left)
        session.assert(rightHandle, right)
        @Assert(sink.size(), 1)
        @Assert(session.tokenCount(), 1)

        session.retract(leftHandle)
        @Assert(sink.size(), 0)
        @Assert(session.tokenCount(), 0)
    }

    /** R-11：update 等价于 retract + assert（同一句柄）。 */
    @TestCase
    public func updateEqualsRetractThenAssert(): Unit {
        let ruleSet = ruleSetOf([singleRule()])
        let (_, session, sink) = open(ruleSet)
        let handle = FactHandle("default", 1, "Order")
        session.assert(handle, order(300, 1))
        @Assert(sink.size(), 1)

        session.update(handle, order(100, 1))
        @Assert(sink.size(), 0)
        @Expect(sameActivations(sink.activations(),
            NaiveMatcher(ruleSet).matches("default", [order(100, 1)])), true)
    }

    /** R-13：没有规则关心的类型直接忽略。 */
    @TestCase
    public func unknownTypeIsIgnored(): Unit {
        let ruleSet = ruleSetOf([singleRule()])
        let (_, session, sink) = open(ruleSet)
        let other = DynamicFact("Unknown")
        other.set("amount", 999)
        session.assert(FactHandle("default", 1, "Unknown"), other)
        @Assert(sink.size(), 0)
    }

    /** R-12：撤销从未断言过的句柄不抛错。 */
    @TestCase
    public func retractAbsentHandleIsSilent(): Unit {
        let ruleSet = ruleSetOf([singleRule()])
        let (_, session, sink) = open(ruleSet)
        session.retract(FactHandle("default", 99, "Order"))
        @Assert(sink.size(), 0)
    }

    /** 冻结后再次构建抛 `NETWORK_FROZEN`。 */
    @TestCase
    public func buildAfterFreezeIsRejected(): Unit {
        let ruleSet = ruleSetOf([singleRule()])
        let network = ReteNetwork("default")
        network.build(ruleSet.rules, ruleSet.registry)
        @Expect(network.frozen(), true)
        var code = RuleErrorCode.CLOSED
        try {
            network.build(ruleSet.rules, ruleSet.registry)
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.NETWORK_FROZEN)
    }

    private func sameActivations(actual: Array<Activation>, expected: Array<NaiveActivation>): Bool {
        if (actual.size != expected.size) {
            return false
        }
        let left = ArrayList<String>()
        for (item in actual) {
            left.add(item.sortKey())
        }
        let right = ArrayList<String>()
        for (item in expected) {
            right.add(item.sortKey())
        }
        var i = 0
        while (i < left.size) {
            var found = false
            for (key in right) {
                if (key == left[i]) {
                    found = true
                    break
                }
            }
            if (!found) {
                return false
            }
            i += 1
        }
        true
    }
}
