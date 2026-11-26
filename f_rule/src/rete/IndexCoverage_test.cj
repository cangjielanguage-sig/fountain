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
import fountain::f_rule.rule.{Rule, RuleSet, RuleSetBuilder}

/**
 * 构建期索引覆盖率（`doc/04-rete-network.md` §7.4）。
 *
 * 覆盖率 = 可走索引的 alpha 约束与 join / 全部 alpha 约束与 join。
 * 低于阈值写 WARN；覆盖率与建议字段通过 `ReteNetwork` 的只读属性暴露。
 * 统计本身不改变匹配语义与节点数。
 */
@Test
class IndexCoverage_test {
    private func ruleSetOf(rules: Array<Rule>): RuleSet {
        let builder = RuleSetBuilder("coverage")
            .registerDynamicType("default", "Order", ["amount", "level", "code"])
            .registerDynamicType("default", "User", ["amount", "level", "code"])
        for (rule in rules) {
            let _ = builder.rule(rule)
        }
        builder.build()
    }

    private func networkOf(rules: Array<Rule>, threshold: Float64): ReteNetwork {
        let ruleSet = ruleSetOf(rules)
        let network = ReteNetwork("default")
        network.build(ruleSet.rules, ruleSet.registry, coverageThreshold: threshold)
        network
    }

    /** 全部约束可索引：覆盖率 1.0，无建议字段，不写 WARN。 */
    @TestCase
    public func allIndexableHasFullCoverage(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("Order", "o")
                .constrain("amount", Operator.Gt, 100)
                .constrain("level", Operator.Eq, 3))
            .build()
        let before = NetworkBuilder.indexCoverageWarningCount()
        let network = networkOf([rule], 0.8)
        @Expect(network.indexCoverage, 1.0)
        @Assert(network.indexCoverageSuggestions.size, 0)
        @Assert(NetworkBuilder.indexCoverageWarningCount(), before)
    }

    /** 无约束模式没有可统计项，覆盖率按 1.0 处理，避免除零与误报。 */
    @TestCase
    public func emptyConditionHasFullCoverage(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern.any("Order", "o"))
            .build()
        let network = networkOf([rule], 0.8)
        @Expect(network.indexCoverage, 1.0)
        @Assert(network.indexCoverageSuggestions.size, 0)
    }

    /** 不可索引的 alpha 约束拉低覆盖率，WARN 并给出建议字段。 */
    @TestCase
    public func unindexableConstraintWarns(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("code", Operator.Matches, "^A"))
            .build()
        let before = NetworkBuilder.indexCoverageWarningCount()
        let network = networkOf([rule], 0.8)
        @Expect(network.indexCoverage, 0.0)
        @Assert(network.indexCoverageSuggestions.size, 1)
        @Assert(network.indexCoverageSuggestions[0][0], "Order")
        @Assert(network.indexCoverageSuggestions[0][1], "code")
        @Assert(NetworkBuilder.indexCoverageWarningCount(), before + 1)
    }

    /** 阈值可配置：阈值降到 0 时同一规则不写 WARN，但覆盖率统计不变。 */
    @TestCase
    public func thresholdIsConfigurable(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("code", Operator.Matches, "^A"))
            .build()
        let before = NetworkBuilder.indexCoverageWarningCount()
        let network = networkOf([rule], 0.0)
        @Expect(network.indexCoverage, 0.0)
        @Assert(network.indexCoverageSuggestions.size, 1)
        @Assert(NetworkBuilder.indexCoverageWarningCount(), before)
    }

    /** 无索引 join 计入覆盖率并给出两侧建议字段。 */
    @TestCase
    public func unindexableJoinWarns(): Unit {
        let rule = Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 100))
            .addPattern(Pattern("User", "u").constrain("level", Operator.Gt, 1))
            .join(JoinConstraint("o", "code", Operator.Contains, "u", "code"))
            .build()
        let before = NetworkBuilder.indexCoverageWarningCount()
        let network = networkOf([rule], 0.8)
        // 2 个可索引 alpha 约束 + 1 个不可索引 join = 2/3。
        @Expect(network.indexCoverage, 0.6666666666666666)
        @Assert(network.indexCoverageSuggestions.size, 2)
        @Assert(NetworkBuilder.indexCoverageWarningCount(), before + 1)
    }
}
