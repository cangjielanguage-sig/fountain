/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_rule.test

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.engine.RuleEngine
import fountain::f_rule.fact.TypeTag
import fountain::f_rule.rete.ShardedNetwork
import fountain::f_rule.rule.RuleSet

/**
 * 网络构建性能门禁（`doc/09-testing.md` §5 B-01、B-06）。
 *
 * 口径：只计时**网络构建**，规则集在计时外构造好（规则构建不是门禁对象）。
 * B-01 用 5 个全新规则集各构建一次并取最大值（冷构建，必然 miss 缓存）；
 * B-06 用同一个规则集重复构建，断言命中结构缓存且不重建节点。
 */
@Tag[perf]
@Test
class PerfNetwork_test {
    private var nodeCount_: Int64 = 0
    private var cursor_: Int64 = 0

    /** B-01：1000 规则（每规则 2 模式）构建 < 500ms，节点数 < 3000。 */
    @Tag[perf, b01]
    @TestCase
    public func b01BuildsThousandRuleNetworkWithinGate(): Unit {
        let ruleSets = ArrayList<RuleSet>()
        var i: Int64 = 0
        while (i < 6) {
            ruleSets.add(PerfFixture.ruleSet("perf-b01-${i}", 1000))
            i += 1
        }
        cursor_ = 0
        let stats = PerfSupport.measure(1, 5) {
            let ruleSet = ruleSets[cursor_]
            cursor_ += 1
            let network = ShardedNetwork(ruleSet)
            nodeCount_ = network.network(TypeTag.DEFAULT_SPACE).getOrThrow().nodeCount()
        }
        PerfSupport.report("B-01 1000 规则网络构建", stats, detail: "nodes=${nodeCount_}")
        PerfSupport.requireAtMost("B-01 构建", stats.max(), PerfGate.B01_BUILD_NANOS)
        PerfSupport.requireBelow("B-01 节点数", nodeCount_, PerfGate.B01_NODE_LIMIT)
    }

    /** B-06：同一规则集重复构建 < 50ms（命中缓存），且返回同一网络对象。 */
    @Tag[perf, b06]
    @TestCase
    public func b06RepeatedBuildHitsCache(): Unit {
        let ruleSet = PerfFixture.ruleSet("perf-b06", 1000)
        let first = ShardedNetwork.shared(ruleSet)
        let second = ShardedNetwork.shared(ruleSet)
        @Expect(refEq(first, second), true)

        let stats = PerfSupport.measure(10, 100) {
            let again = ShardedNetwork.shared(ruleSet)
            if (!refEq(again, first)) {
                throw Exception("B-06 缓存未命中")
            }
        }
        PerfSupport.report("B-06 重复构建（命中缓存）", stats)
        PerfSupport.requireAtMost("B-06 重复构建", stats.p95(), PerfGate.B06_REBUILD_NANOS)

        // 引擎门面走同一条缓存路径：第二次 `RuleEngine(ruleSet)` 不应重建网络。
        let engineSet = PerfFixture.ruleSet("perf-b06-engine", 1000)
        let _ = ShardedNetwork.shared(engineSet)
        let engineStats = PerfSupport.measure(2, 20) {
            let _ = RuleEngine(engineSet)
        }
        PerfSupport.report("B-06 重复构造引擎", engineStats)
        PerfSupport.requireAtMost("B-06 重复构造引擎", engineStats.max(), PerfGate.B06_REBUILD_NANOS)
    }
}
