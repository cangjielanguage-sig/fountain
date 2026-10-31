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

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.rule.RuleSetBuilder
import fountain::f_rule.agenda.Activation
import fountain::f_rule.fact.{Fact, FactBase, FactHandle}
import fountain::f_rule.rule.{Rule, RuleSet}
import fountain::f_rule.rete.{MatcherMode, NaiveActivationFn, RecordingSink, ShardedNetwork}

/**
 * Rete 与朴素匹配的差分（`doc/09-testing.md` §4.1，用例 R-01~R-20 的横向回归）。
 *
 * 每个种子固定（`20261031 + group`），失败时输出两侧的排序键，便于定位到具体规则与绑定。
 * 覆盖 1~5 模式、每模式 0~4 约束、等值/范围/In/Between/IsNull 混合，插入后随机撤销 30%。
 */
@Test
class Differential_test {
    private let groups: Int64 = 200

    @TestCase
    public func reteMatchesNaiveAcrossRandomCases(): Unit {
        var group: Int64 = 0
        while (group < groups) {
            let generated = PropertyGen(seed: 20261031 + group)
            let rules = generated.randomRules(1 + generated.next(3))
            let facts = generated.randomFacts(generated.next(7))
            let ruleSet = ruleSetOf(rules)
            let space = ruleSet.registry.get("default").getOrThrow()
            let base = FactBase(space, "s${group}")
            let sink = RecordingSink()
            let runtime = ShardedNetwork(ruleSet).session("s${group}", sink)

            let handles = ArrayList<FactHandle>()
            let factList = ArrayList<Fact>()
            for (fact in facts) {
                factList.add(fact)
                let handle = base.assert(fact)
                handles.add(handle)
                runtime.assert("default", handle, fact)
            }
            expectEqual(group, runtime.activations(),
                NaiveMatcher(ruleSet).matches("default", factList.toArray()), "插入后")

            // 随机撤销约 30%：按固定步长挑选，保证可复现
            let remaining = ArrayList<Fact>()
            var i: Int64 = 0
            while (i < Int64(facts.size)) {
                if (i % 10 < 3) {
                    let _ = base.retract(handles[i])
                    runtime.retract("default", handles[i])
                } else {
                    remaining.add(facts[i])
                }
                i += 1
            }
            expectEqual(group, runtime.activations(),
                NaiveMatcher(ruleSet).matches("default", remaining.toArray()), "撤销后")
            group += 1
        }
    }

    /** 3.19：内部 matcher 开关可切到 Naive 后端，结果与 Rete 一致。 */
    @TestCase
    public func matcherSwitchFallsBackToNaive(): Unit {
        let generated = PropertyGen(seed: 20261031)
        let rules = generated.randomRules(3)
        let facts = generated.randomFacts(6)
        let ruleSet = ruleSetOf(rules)
        let naive: NaiveActivationFn = { ruleList: Array<Rule>, bySpace: HashMap<String, Array<Fact>> =>
            let evaluated = NaiveMatcher(ruleSetOf(ruleList)).matches(bySpace)
            let out = ArrayList<Activation>()
            for (item in evaluated) {
                out.add(Activation(item.rule, item.bindings))
            }
            out.toArray()
        }

        let reteSink = RecordingSink()
        let rete = ShardedNetwork(ruleSet).session("s1", reteSink)
        let naiveRuntime = ShardedNetwork(ruleSet, mode: MatcherMode.Naive, naive: naive)
            .session("s1", RecordingSink())
        var id: Int64 = 1
        for (fact in facts) {
            let handle = FactHandle("default", id, "GenFact")
            rete.assert("default", handle, fact)
            naiveRuntime.assert("default", handle, fact)
            id += 1
        }
        let left = activationKeys(rete.activations())
        let right = activationKeys(naiveRuntime.activations())
        @Assert(joinKeys(left), joinKeys(right))
    }

    private func ruleSetOf(rules: Array<Rule>): RuleSet {
        let builder = RuleSetBuilder("diff")
            .registerDynamicType("default", "GenFact", ["amount", "level", "code"])
        for (rule in rules) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }

    private func expectEqual(group: Int64, actual: Array<Activation>,
        expected: Array<NaiveActivation>, phase: String): Unit {
        let left = activationKeys(actual)
        let right = naiveKeys(expected)
        if (left.size != right.size) {
            throw Exception(
                "组 ${group} ${phase} 激活数不一致: rete=${left.size} naive=${right.size}\n" +
                "rete:\n${joinKeys(left)}\nnaive:\n${joinKeys(right)}"
            )
        }
        let equal = joinKeys(left) == joinKeys(right)
        if (!equal) {
            throw Exception(
                "组 ${group} ${phase} 激活集合不一致\nrete:\n${joinKeys(left)}\nnaive:\n${joinKeys(right)}"
            )
        }
    }

    private func activationKeys(actual: Array<Activation>): Array<String> {
        let out = ArrayList<String>()
        for (item in actual) {
            out.add(item.sortKey())
        }
        sort(out)
        out.toArray()
    }

    private func naiveKeys(actual: Array<NaiveActivation>): Array<String> {
        let out = ArrayList<String>()
        for (item in actual) {
            out.add(item.sortKey())
        }
        sort(out)
        out.toArray()
    }

    private func sort(items: ArrayList<String>): Unit {
        var i = 1
        while (i < items.size) {
            let current = items[i]
            var j = i - 1
            while (j >= 0 && items[j] > current) {
                items[j + 1] = items[j]
                j -= 1
            }
            items[j + 1] = current
            i += 1
        }
    }

    private func joinKeys(keys: Array<String>): String {
        var out = ""
        for (key in keys) {
            out = out + key + "\n"
        }
        out
    }
}
