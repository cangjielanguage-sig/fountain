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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.fact.{FactBase, TypeTag}
import fountain::f_rule.rete.{RecordingSink, ShardedNetwork}

/**
 * 规模夹具自身的契约（`doc/09-testing.md` §5）。
 *
 * 性能门禁依赖"每命中一对 `(code, group)` 产生一个激活"这一解析解，
 * 先用小规模数据锁定夹具语义，避免门禁数字建立在错误的期望值上。
 */
@Test
class PerfFixture_test {
    @TestCase
    public func fixtureMatchesAnalyticActivationCount(): Unit {
        let ruleSet = PerfFixture.ruleSet("fixture-small", 20)
        let network = ShardedNetwork(ruleSet)
        let sink = RecordingSink()
        let runtime = network.session("s1", sink)
        let base = FactBase(ruleSet.registry.get(TypeTag.DEFAULT_SPACE).getOrThrow(), "s1")
        for (fact in PerfFixture.facts(100)) {
            runtime.assert(TypeTag.DEFAULT_SPACE, base.assert(fact), fact)
        }
        let expected = PerfFixture.expectedActivations(20, 100)
        println("[BENCH] 夹具自检 expected=${expected} actual=${sink.size()} " +
            "alpha=${runtime.alphaSize(TypeTag.DEFAULT_SPACE)}")
        @Assert(expected > 0)
        @Assert(Int64(sink.size()), expected)
    }

    /** 同一网络连续开多个会话后，新会话的激活集合仍然完整（会话隔离）。 */
    @TestCase
    public func laterSessionsStillProduceAllActivations(): Unit {
        let ruleSet = PerfFixture.ruleSet("fixture-sessions", 1000)
        let network = ShardedNetwork(ruleSet)
        let facts = PerfFixture.facts(10000)
        let space = ruleSet.registry.get(TypeTag.DEFAULT_SPACE).getOrThrow()
        var round: Int64 = 0
        while (round < 1) {
            let id = "warm-${round}"
            let runtime = network.session(id, RecordingSink())
            let base = FactBase(space, id)
            for (fact in facts) {
                runtime.assert(TypeTag.DEFAULT_SPACE, base.assert(fact), fact)
            }
            round += 1
        }
        let sink = RecordingSink()
        let runtime = network.session("verify", sink)
        let base = FactBase(space, "verify")
        for (fact in facts) {
            runtime.assert(TypeTag.DEFAULT_SPACE, base.assert(fact), fact)
        }
        println("[BENCH] 多会话后 verify actual=${sink.size()} " +
            "tracked=${runtime.activations().size}")
        @Assert(Int64(sink.size()), PerfFixture.expectedActivations(1000, 10000))
    }
}
