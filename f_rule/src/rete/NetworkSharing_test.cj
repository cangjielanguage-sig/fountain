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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.rule.RuleSetBuilder
import fountain::f_rule.condition.{JoinConstraint, Operator, Pattern}
import fountain::f_rule.rule.{Rule, RuleSet}

/**
 * 节点共享与签名归一（`doc/04-rete-network.md` §4，用例 R-05/R-06/R-07/R-15）。
 *
 * alpha 网络是树：路径不同的节点即使末约束相同也各建一个（memory 语义不同）；
 * beta 共享要求左侧路径完全一致。
 */
@Test
class NetworkSharing_test {
    private func ruleSetOf(rules: Array<Rule>): RuleSet {
        let builder = RuleSetBuilder("sharing")
            .registerDynamicType("default", "Order", ["amount", "level", "code"])
        for (rule in rules) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }

    private func networkOf(rules: Array<Rule>): ReteNetwork {
        let ruleSet = ruleSetOf(rules)
        let network = ReteNetwork("default")
        network.build(ruleSet.rules, ruleSet.registry)
        network
    }

    private func twoPatternRule(id: String, amount: Int64, level: Int64): Rule {
        Rule.builder(id)
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Ge, amount))
            .addPattern(Pattern("Order", "u").constrain("level", Operator.Le, level))
            .join(JoinConstraint("o", "amount", Operator.Eq, "u", "amount"))
            .build()
    }

    /** R-15：100 条规则共享 20 个 alpha 签名，节点数 = 20 + 不同 join 数。 */
    @TestCase
    public func hundredRulesShareTwentyAlphaSignatures(): Unit {
        let rules = ArrayList<Rule>()
        var i: Int64 = 0
        while (i < 100) {
            let amount = i % 10
            let level = i / 10
            rules.add(twoPatternRule("R${i}", amount * 10, level))
            i += 1
        }
        let network = networkOf(rules.toArray())
        @Assert(network.alphaNodeCount(), 20)
        @Assert(network.betaNodeCount(), 100)
        @Assert(network.nodeCount(), 120)
    }

    /** R-06：同一 join 签名跨规则只建一个 beta 节点。 */
    @TestCase
    public func identicalJoinSignatureIsShared(): Unit {
        let network = networkOf([
            twoPatternRule("R1", 100, 3),
            twoPatternRule("R2", 100, 3)
        ])
        @Assert(network.alphaNodeCount(), 2)
        @Assert(network.betaNodeCount(), 1)
        @Assert(network.terminalCount(), 2)
    }

    /** R-07：前两模式相同、第三模式不同 → 前两个 join 共享，第三个分叉。 */
    @TestCase
    public func divergentThirdPatternSharesFirstTwoJoins(): Unit {
        let first = Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Ge, 100))
            .addPattern(Pattern("Order", "u").constrain("level", Operator.Le, 3))
            .addPattern(Pattern("Order", "z").constrain("code", Operator.Eq, "A"))
            .join(JoinConstraint("o", "amount", Operator.Eq, "u", "amount"))
            .join(JoinConstraint("u", "level", Operator.Eq, "z", "level"))
            .build()
        let second = Rule.builder("R2")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Ge, 100))
            .addPattern(Pattern("Order", "u").constrain("level", Operator.Le, 3))
            .addPattern(Pattern("Order", "z").constrain("code", Operator.Eq, "B"))
            .join(JoinConstraint("o", "amount", Operator.Eq, "u", "amount"))
            .join(JoinConstraint("u", "level", Operator.Eq, "z", "level"))
            .build()
        let network = networkOf([first, second])
        @Assert(network.alphaNodeCount(), 4)
        @Assert(network.betaNodeCount(), 3)

        // 第三个 join 的左侧都应指向第一个 join 的 beta memory
        let firstJoinId = firstBetaId(network)
        var sharedLeft = 0
        for (beta in network.betaNodes()) {
            match (beta.leftSource) {
                case BetaLeft.FromBeta(id) =>
                    if (id == firstJoinId) {
                        sharedLeft += 1
                    }
                case BetaLeft.FromAlpha(_) => ()
            }
        }
        @Assert(sharedLeft, 2)
    }

    /** 约束顺序不同但集合相同：签名归一后共享全部节点（D5）。 */
    @TestCase
    public func constraintOrderDoesNotChangeSignature(): Unit {
        let first = Rule.builder("R1")
            .addPattern(Pattern("Order", "o")
                .constrain("amount", Operator.Ge, 100)
                .constrain("level", Operator.Le, 3))
            .build()
        let second = Rule.builder("R2")
            .addPattern(Pattern("Order", "o")
                .constrain("level", Operator.Le, 3)
                .constrain("amount", Operator.Ge, 100))
            .build()
        let network = networkOf([first, second])
        @Assert(network.alphaNodeCount(), 2)
        @Assert(network.betaNodeCount(), 0)
        @Assert(network.terminalCount(), 2)
    }

    /** 同长度不同内容的列表值不能共用 alpha 节点（否则会产生假阳性）。 */
    @TestCase
    public func differentListValuesDoNotShareAlphaNodes(): Unit {
        let firstBounds: Array<Any> = [1, 2]
        let secondBounds: Array<Any> = [3, 4]
        let first = Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Between, firstBounds))
            .build()
        let second = Rule.builder("R2")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Between, secondBounds))
            .build()
        let network = networkOf([first, second])
        @Assert(network.alphaNodeCount(), 2)
    }

    private func firstBetaId(network: ReteNetwork): Int64 {
        for (beta in network.betaNodes()) {
            match (beta.leftSource) {
                case BetaLeft.FromAlpha(_) => return beta.id
                case BetaLeft.FromBeta(_) => ()
            }
        }
        -1
    }
}
