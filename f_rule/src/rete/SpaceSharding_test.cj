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

import std.collection.HashSet
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.RuleSetBuilder
import fountain::f_rule.agenda.Activation
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{Rule, RuleSet}

/**
 * 按 FactSpace 分片（`doc/04-rete-network.md` §1.1，用例 R-16~R-20）。
 *
 * 分片只包含归属该空间的规则；节点共享不跨片；重建某片不影响其他片的
 * 令牌与激活；同一会话跨空间的激活进同一个会话视图。
 */
@Test
class SpaceSharding_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func ruleSetOf(): RuleSet {
        RuleSetBuilder("sharding")
            .registerDynamicType("a", "Order", ["amount"])
            .registerDynamicType("b", "Order", ["amount"])
            .rule(Rule.builder("Ra").facts("a")
                .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
                .build())
            .rule(Rule.builder("Rb").facts("b")
                .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
                .build())
            .build()
    }

    /** R-16：断言 `a` 空间事实不影响 `b` 分片。 */
    @TestCase
    public func assertInOneSpaceDoesNotTouchAnother(): Unit {
        let sharded = ShardedNetwork(ruleSetOf())
        let runtime = sharded.session("s1", RecordingSink())
        runtime.assert("a", FactHandle("a", 1, "Order"), order(300))
        @Assert(runtime.alphaSize("a"), 1)
        @Assert(runtime.alphaSize("b"), 0)
        @Assert(runtime.activations().size, 1)
    }

    /** R-17：相同 alpha 签名在两个分片各建一个节点，不跨片共享。 */
    @TestCase
    public func identicalSignatureIsNotSharedAcrossShards(): Unit {
        let sharded = ShardedNetwork(ruleSetOf())
        let a = sharded.network("a").getOrThrow()
        let b = sharded.network("b").getOrThrow()
        @Assert(a.alphaNodeCount(), 1)
        @Assert(b.alphaNodeCount(), 1)
        @Expect(sameNode(a, b), false)
    }

    /** R-18：只重建 `a` 分片，`b` 的令牌与激活不变。 */
    @TestCase
    public func rebuildOneShardLeavesOthersIntact(): Unit {
        let sharded = ShardedNetwork(ruleSetOf())
        let runtime = sharded.session("s1", RecordingSink())
        runtime.assert("a", FactHandle("a", 1, "Order"), order(300))
        runtime.assert("b", FactHandle("b", 1, "Order"), order(300))
        let beforeTokens = runtime.tokenCount("b")
        let beforeActivations = countSpace(runtime.activations(), "b")
        let bNetwork = sharded.network("b").getOrThrow()

        sharded.rebuild("a")
        @Assert(runtime.tokenCount("b"), beforeTokens)
        @Assert(countSpace(runtime.activations(), "b"), beforeActivations)
        @Expect(sameNode(bNetwork, sharded.network("b").getOrThrow()), true)
        // `a` 分片被换新，运行态随 generation 失效
        @Assert(runtime.tokenCount("a"), 0)
    }

    /** R-19：同一会话跨空间各有激活，且归属空间正确。 */
    @TestCase
    public func sameSessionCollectsActivationsFromBothSpaces(): Unit {
        let sharded = ShardedNetwork(ruleSetOf())
        let runtime = sharded.session("s1", RecordingSink())
        runtime.assert("a", FactHandle("a", 1, "Order"), order(300))
        runtime.assert("b", FactHandle("b", 1, "Order"), order(300))
        let spaces = HashSet<String>()
        for (activation in runtime.activations()) {
            spaces.add(activation.factSpace)
        }
        @Assert(spaces.size, 2)
        @Expect(spaces.contains("a"), true)
        @Expect(spaces.contains("b"), true)
    }

    /** R-20：空间内没有规则关心的类型被忽略，其他分片不受影响。 */
    @TestCase
    public func unmonitoredTypeInOneShardIsIgnored(): Unit {
        let ruleSet = RuleSetBuilder("sharding")
            .registerDynamicType("a", "Order", ["amount"])
            .registerDynamicType("a", "Ghost", ["amount"])
            .registerDynamicType("b", "Order", ["amount"])
            .rule(Rule.builder("Ra").facts("a")
                .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
                .build())
            .rule(Rule.builder("Rb").facts("b")
                .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
                .build())
            .build()
        let sharded = ShardedNetwork(ruleSet)
        let runtime = sharded.session("s1", RecordingSink())
        let ghost = DynamicFact("Ghost")
        ghost.set("amount", 999)
        runtime.assert("a", FactHandle("a", 1, "Ghost"), ghost)
        runtime.assert("b", FactHandle("b", 1, "Order"), order(300))
        @Assert(runtime.activations().size, 1)
        @Assert(runtime.alphaSize("a"), 0)
    }

    /** 同一规则集里单空间版本作为基线：两片各建一个节点，总数是基线的两倍。 */
    @TestCase
    public func shardNodeCountsArePerShard(): Unit {
        let sharded = ShardedNetwork(ruleSetOf())
        var total: Int64 = 0
        for (space in ["a", "b"]) {
            total += sharded.network(space).getOrThrow().alphaNodeCount()
        }
        @Assert(total, 2)
    }

    private func sameNode(left: ReteNetwork, right: ReteNetwork): Bool {
        left.generation == right.generation
    }

    private func countSpace(activations: Array<Activation>, space: String): Int64 {
        var total: Int64 = 0
        for (activation in activations) {
            if (activation.factSpace == space) {
                total += 1
            }
        }
        total
    }
}
