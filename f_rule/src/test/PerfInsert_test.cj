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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.agenda.Activation
import fountain::f_rule.fact.{Fact, FactBase, FactHandle, FactSpace, TypeTag}
import fountain::f_rule.rete.{RecordingSink, SessionRuntime, ShardedNetwork}
import fountain::f_rule.rule.RuleSet

/**
 * 运行期吞吐门禁（`doc/09-testing.md` §5 B-02~B-04）。
 *
 * 口径：
 * - B-02 每个样本新建一个会话（网络结构复用），插入 10000 条事实；激活集合与
 *   `NaiveMatcher` 逐条比对（含激活数），比对不计时。
 * - B-03 网络与会话预热后，单条插入逐条计时，取真实 P95。
 * - B-04 预置 4 个 10000 条事实的会话，每个样本撤销其中 3000 条（30%）。
 */
@Tag[perf]
@Test
class PerfInsert_test {
    private let ruleCount: Int64 = 1000
    private let factCount: Int64 = 10000
    private var session_: Int64 = 0
    private var extraCursor_: Int64 = 0
    private var retractCursor_: Int64 = 0

    private func spaceOf(ruleSet: RuleSet): FactSpace {
        ruleSet.registry.get(TypeTag.DEFAULT_SPACE).getOrThrow()
    }

    /** B-02：10000 条事实插入 < 2s，且激活集合与朴素匹配一致。 */
    @Tag[perf, b02]
    @TestCase
    public func b02InsertsTenThousandFactsWithinGate(): Unit {
        let ruleSet = PerfFixture.ruleSet("perf-b02", ruleCount)
        let network = ShardedNetwork(ruleSet)
        let facts = PerfFixture.facts(factCount)
        let space = spaceOf(ruleSet)

        let stats = PerfSupport.measure(1, 5) {
            session_ += 1
            let sessionId = "b02-${session_}"
            let runtime = network.session(sessionId, RecordingSink())
            let base = FactBase(space, sessionId)
            for (fact in facts) {
                let handle = base.assert(fact)
                runtime.assert(TypeTag.DEFAULT_SPACE, handle, fact)
            }
        }
        PerfSupport.report("B-02 10000 事实插入", stats)

        let expected = PerfFixture.expectedActivations(ruleCount, factCount)
        let runtime = network.session("b02-verify", RecordingSink())
        let base = FactBase(space, "b02-verify")
        let factList = ArrayList<Fact>()
        for (fact in facts) {
            factList.add(fact)
            let handle = base.assert(fact)
            runtime.assert(TypeTag.DEFAULT_SPACE, handle, fact)
        }
        let actual = runtime.activations()
        @Expect(Int64(actual.size), expected)
        let naive = NaiveMatcher(ruleSet).matches(TypeTag.DEFAULT_SPACE, factList.toArray())
        let left = activationKeys(actual)
        let right = naiveKeys(naive)
        @Expect(left.size, right.size)
        let reteText = joinKeys(left)
        let naiveText = joinKeys(right)
        if (reteText != naiveText) {
            throw Exception(
                "B-02 激活集合与朴素匹配不一致：rete=${left.size} naive=${right.size} " +
                "首个差异 ${firstDiff(left, right)}"
            )
        }
        println("[BENCH] B-02 激活数=${actual.size}（朴素匹配 ${naive.size}）")
        // 正确性先于门禁：门禁不达标时也要能区分"慢"与"错"。
        PerfSupport.requireAtMost("B-02 插入", stats.p95(), PerfGate.B02_INSERT_NANOS)
    }

    /** B-03：网络已建后的单条插入 P95 < 1ms。 */
    @Tag[perf, b03]
    @TestCase
    public func b03SingleInsertP95WithinGate(): Unit {
        let ruleSet = PerfFixture.ruleSet("perf-b03", ruleCount)
        let network = ShardedNetwork(ruleSet)
        let space = spaceOf(ruleSet)
        let runtime = network.session("b03", RecordingSink())
        let base = FactBase(space, "b03")
        for (fact in PerfFixture.facts(factCount)) {
            let handle = base.assert(fact)
            runtime.assert(TypeTag.DEFAULT_SPACE, handle, fact)
        }
        let extras = PerfFixture.facts(factCount + 1000)
        extraCursor_ = factCount
        let stats = PerfSupport.measure(100, 500) {
            let fact = extras[extraCursor_]
            extraCursor_ += 1
            let handle = base.assert(fact)
            runtime.assert(TypeTag.DEFAULT_SPACE, handle, fact)
        }
        PerfSupport.report("B-03 单条插入", stats)
        PerfSupport.requireAtMost("B-03 单条插入 P95", stats.p95(), PerfGate.B03_INSERT_P95_NANOS)
    }

    /** B-04：撤销 30% 事实 < 500ms。 */
    @Tag[perf, b04]
    @TestCase
    public func b04RetractsThirtyPercentWithinGate(): Unit {
        let ruleSet = PerfFixture.ruleSet("perf-b04", ruleCount)
        let network = ShardedNetwork(ruleSet)
        let space = spaceOf(ruleSet)
        let facts = PerfFixture.facts(factCount)
        let sessions = ArrayList<PreparedSession>()
        var index: Int64 = 0
        while (index < 4) {
            let sessionId = "b04-${index}"
            let runtime = network.session(sessionId, RecordingSink())
            let base = FactBase(space, sessionId)
            let handles = ArrayList<FactHandle>()
            for (fact in facts) {
                let handle = base.assert(fact)
                handles.add(handle)
                runtime.assert(TypeTag.DEFAULT_SPACE, handle, fact)
            }
            sessions.add(PreparedSession(base, runtime, handles.toArray()))
            index += 1
        }
        retractCursor_ = 0
        let stats = PerfSupport.measure(1, 3) {
            let prepared = sessions[retractCursor_]
            retractCursor_ += 1
            var i: Int64 = 0
            while (i < Int64(prepared.handles.size)) {
                if (i % 10 < 3) {
                    let handle = prepared.handles[i]
                    if (prepared.base.retract(handle)) {
                        prepared.runtime.retract(TypeTag.DEFAULT_SPACE, handle)
                    }
                }
                i += 1
            }
        }
        PerfSupport.report("B-04 撤销 30% 事实", stats)
        PerfSupport.requireAtMost("B-04 撤销", stats.max(), PerfGate.B04_RETRACT_NANOS)
    }

    private func activationKeys(actual: Array<Activation>): Array<String> {
        let out = ArrayList<String>()
        for (item in actual) {
            out.add(item.sortKey())
        }
        PerfSupport.sortedKeys(out)
    }

    private func naiveKeys(actual: Array<NaiveActivation>): Array<String> {
        let out = ArrayList<String>()
        for (item in actual) {
            out.add(item.sortKey())
        }
        PerfSupport.sortedKeys(out)
    }

    private func joinKeys(keys: Array<String>): String {
        var out = ""
        var i = 0
        while (i < keys.size && i < 20) {
            out = out + keys[i] + "\n"
            i += 1
        }
        out
    }

    private func firstDiff(left: Array<String>, right: Array<String>): String {
        var i = 0
        while (i < left.size && i < right.size) {
            if (left[i] != right[i]) {
                return "@${i} rete=${left[i]} naive=${right[i]}"
            }
            i += 1
        }
        "prefix equal"
    }
}

/** B-04 复用的预置会话。 */
class PreparedSession {
    let base: FactBase
    let runtime: SessionRuntime
    let handles: Array<FactHandle>

    PreparedSession(base: FactBase, runtime: SessionRuntime, handles: Array<FactHandle>) {
        this.base = base
        this.runtime = runtime
        this.handles = handles
    }
}
