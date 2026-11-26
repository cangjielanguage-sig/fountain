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
import fountain::f_rule.exception.*
import fountain::f_rule.fact.FactSpaceRegistry
import fountain::f_rule.rule.RuleSet

/**
 * 两条执行路径的实例级互斥（`doc/11-assembly.md` §4.5，用例 AS-11）。
 *
 * 同一张表既编译进规则集又交给 `TableExecutor` 会重复触发，必须显式失败；
 * 同模式重复使用合法，互斥只约束实例，不约束同一份定义的多个实例。
 */
@Test
class TableMode_test {
    private func table(): DecisionTable {
        DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row("R1", [">=3", "0.85"])
            .build()
    }

    private func registry(): FactSpaceRegistry {
        tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }.registry
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        try {
            action()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** 装配后再执行：`TABLE_MODE_CONFLICT`。 */
    @TestCase
    public func assembledThenExecutedConflicts(): Unit {
        let target = table()
        let _ = target.compileInto(registry())
        @Expect(codeOf({ => TableExecutor(target, registry()) }),
            RuleErrorCode.TABLE_MODE_CONFLICT)
    }

    /** 执行后再装配：`TABLE_MODE_CONFLICT`。 */
    @TestCase
    public func executedThenAssembledConflicts(): Unit {
        let target = table()
        let _ = TableExecutor(target, registry())
        @Expect(codeOf({ => target.compileInto(registry()) }),
            RuleErrorCode.TABLE_MODE_CONFLICT)
    }

    /** 同模式重复使用允许：多次编译、多次执行都不报错。 */
    @TestCase
    public func repeatedUseWithinSameModeIsAllowed(): Unit {
        let assembled = table()
        @Expect(assembled.compileInto(registry()).size, 1)
        @Expect(assembled.compileInto(registry()).size, 1)

        let executed = table()
        let _ = TableExecutor(executed, registry())
        let _ = TableExecutor(executed, registry())
        @Expect(executed.mode, TableMode.Executed)
    }

    /** 互斥是实例级：另一份相同定义不受影响。 */
    @TestCase
    public func differentInstancesAreIndependent(): Unit {
        let executed = table()
        let assembled = table()
        let _ = TableExecutor(executed, registry())
        @Expect(assembled.compileInto(registry()).size, 1)
        @Expect(assembled.mode, TableMode.Assembled)
    }

    /** 未使用的表处于 `Unbound`。 */
    @TestCase
    public func unusedTableIsUnbound(): Unit {
        @Expect(table().mode, TableMode.Unbound)
    }
}
