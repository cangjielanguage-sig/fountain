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
package fountain::f_rule.table

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler
import fountain::f_rule.rule.RuleSet

/**
 * 决策表 → 议程的 HitPolicy 映射（`doc/07-decision-table.md` §2.1）。
 *
 * 议程只看单条规则，`HitPolicy` 必须落到 `activationGroup` + `salience`：
 * - `First` / `Unique` / `Priority` 同组，行序高者 salience 高；
 * - `Collect` / `RuleOrder` / `Any` / `OutputOrder` 不分组；
 * - `Collect` / `OutputOrder` 用行序 salience，`RuleOrder` 保留原始 salience。
 */
@Test
class TableCompilerAgenda_test {
    private func orderRuleSet(): RuleSet {
        tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
    }

    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<TableOrder>()
        c
    }

    private func table(policy: HitPolicy, salience: Int64, rows: Int64): DecisionTable {
        let builder = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(policy)
            .salience(salience)
            .whenColumn("order.level")
            .thenColumn("discount")
        var index: Int64 = 0
        while (index < rows) {
            if (index == 0) {
                let _ = builder.row("R1", [">=3", "0.85"])
            } else if (index == 1) {
                let _ = builder.row("R2", [">=2", "0.90"])
            } else {
                let _ = builder.row("R3", [">=1", "0.95"])
            }
            index += 1
        }
        builder.build()
    }

    private func compile(policy: HitPolicy, salience: Int64, rows: Int64): CompiledTable {
        TableCompiler(table(policy, salience, rows), orderRuleSet().registry, compiler()).compile()
    }

    /** `First` / `Unique`：同组，salience 按行序递减，首行最高。 */
    @TestCase
    public func firstAndUniqueUseGroupAndRowOrderSalience(): Unit {
        for (policy in [HitPolicy.First, HitPolicy.Unique]) {
            let compiled = compile(policy, 100, 2)
            @Expect(compiled.rules[0].activationGroup.getOrThrow(), "pricing")
            @Expect(compiled.rules[1].activationGroup.getOrThrow(), "pricing")
            @Expect(compiled.rules[0].salience > compiled.rules[1].salience, true)
            @Expect(compiled.rules[0].salience, 100)
            @Expect(compiled.rules[1].salience, 99)
        }
    }

    /** `Priority`：同组，但议程无法按输出值比较，降级为行序 salience。 */
    @TestCase
    public func priorityUsesGroupButDegradesToRowOrder(): Unit {
        let compiled = compile(HitPolicy.Priority, 50, 2)
        @Expect(compiled.rules[0].activationGroup.getOrThrow(), "pricing")
        @Expect(compiled.rules[0].salience, 50)
        @Expect(compiled.rules[1].salience, 49)
    }

    /** `Collect` 不分组但按行序；`RuleOrder` 不分组且保留原始 salience。 */
    @TestCase
    public func collectAndRuleOrderDoNotGroup(): Unit {
        let collect = compile(HitPolicy.Collect, 10, 3)
        for (rule in collect.rules) {
            @Expect(rule.activationGroup.isNone(), true)
        }
        @Expect(collect.rules[0].salience, 10)
        @Expect(collect.rules[1].salience, 9)
        @Expect(collect.rules[2].salience, 8)

        let byRule = compile(HitPolicy.RuleOrder, 10, 2)
        for (rule in byRule.rules) {
            @Expect(rule.activationGroup.isNone(), true)
        }
        @Expect(byRule.rules[0].salience, 10)
        @Expect(byRule.rules[1].salience, 10)
    }

    /** `Any` / `OutputOrder` 不分组；`OutputOrder` 降级为行序 salience。 */
    @TestCase
    public func anyAndOutputOrderDoNotGroup(): Unit {
        let any = compile(HitPolicy.Any, 0, 2)
        for (rule in any.rules) {
            @Expect(rule.activationGroup.isNone(), true)
        }

        let byOutput = compile(HitPolicy.OutputOrder, 30, 2)
        for (rule in byOutput.rules) {
            @Expect(rule.activationGroup.isNone(), true)
        }
        @Expect(byOutput.rules[0].salience, 30)
        @Expect(byOutput.rules[1].salience, 29)
    }
}
