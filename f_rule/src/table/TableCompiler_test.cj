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
import fountain::f_rule.condition.{Operand, Operator}
import fountain::f_rule.exception.*
import fountain::f_rule.rule.RuleSet

/**
 * 决策表编译（`doc/07-decision-table.md` §7/§8，用例 T-15）。
 *
 * 每行 → 一条单模式规则；字段/算子/值/绑定全部在构建期校验，失败即抛。
 */
@Test
class TableCompiler_test {
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

    private func codeOf(action: () -> Unit): RuleErrorCode {
        try {
            action()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** 每行编译为单模式规则；factSpace/salience/id/约束逐项映射。 */
    @TestCase
    public func compilesRowsToSinglePatternRules(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .salience(100)
            .whenColumn("order.level")
            .whenColumn("order.amount")
            .thenColumn("discount")
            .row([">=3", ">200", "0.85"])
            .row("R2", [">=1", ">500", "0.90"])
            .build()

        let compiled = TableCompiler(table, orderRuleSet(), compiler()).compile()
        @Assert(compiled.factType, "Order")
        @Assert(compiled.binding, "order")
        @Expect(compiled.rules.size, 2)
        let rule = compiled.rules[0]
        @Assert(rule.id, "R1")
        @Expect(rule.factSpace, "orders")
        @Expect(rule.salience, 100)
        @Expect(rule.patterns.size, 1)
        @Expect(rule.patterns[0].constraints.size, 2)
        @Assert(rule.actions.size, 1)

        let first = rule.patterns[0].constraints[0]
        @Assert(first.field, "level")
        @Expect(first.op, Operator.Ge)
        match (first.right) {
            case Operand.Const(value) => @Assert(value as Int64, 3)
            case _ => @Expect("const operand", "other")
        }
        @Expect(rule.patterns[0].constraints[1].op, Operator.Gt)
        @Assert(compiled.rows[0].outputs[0].name, "discount")
    }

    /** 公开 API `DecisionTable.compile(ruleSet)` 与 TableCompiler 结果一致。 */
    @TestCase
    public func compilesThroughPublicApi(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "0.85"])
            .build()
        let rules = table.compile(orderRuleSet())
        @Expect(rules.size, 1)
        @Assert(rules[0].id, "R1")
        @Expect(rules[0].patterns[0].typeTag, "Order")
    }

    /** salience 列覆盖表缺省值。 */
    @TestCase
    public func mapsSalienceColumn(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .salience(10)
            .whenColumn("order.level")
            .thenColumn("discount")
            .column("salience")
            .row([">=3", "0.85", "99"])
            .build()

        let compiled = TableCompiler(table, orderRuleSet(), compiler()).compile()
        @Expect(compiled.rules[0].salience, 99)
    }

    /** 非法 salience 单元格抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsInvalidSalience(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .column("salience")
            .row([">=3", "0.85", "high"])
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.TABLE_INVALID)
    }

    /** 未声明字段抛 `UNKNOWN_FIELD`。 */
    @TestCase
    public func rejectsUnknownField(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.missing")
            .thenColumn("discount")
            .row(["1", "0.85"])
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.UNKNOWN_FIELD)
    }

    /** 值无法解析为字段类型抛 `TYPE_MISMATCH`。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.amount")
            .thenColumn("discount")
            .row(["abc", "0.85"])
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.TYPE_MISMATCH)
    }

    /** 输出引用未声明绑定抛 `UNKNOWN_BINDING`。 */
    @TestCase
    public func rejectsUnknownOutputBinding(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "\${u.level}"])
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.UNKNOWN_BINDING)
    }

    /** 输出引用未声明字段抛 `UNKNOWN_FIELD`。 */
    @TestCase
    public func rejectsUnknownOutputField(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "\${order.missing}"])
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.UNKNOWN_FIELD)
    }

    /** T-15：空表抛 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsEmptyTable(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.TABLE_INVALID)
    }

    /** `Unique` 策略下条件完全相同的两行在构建期拒绝。 */
    @TestCase
    public func rejectsDuplicateRowsUnderUnique(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .hitPolicy(HitPolicy.Unique)
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "0.85"])
            .row([">=3", "0.90"])
            .build()
        @Expect(codeOf({ => TableCompiler(table, orderRuleSet(), compiler()).compile() }),
            RuleErrorCode.TABLE_INVALID)
    }

    /** `expr` 列编译进规则脚本与行条件。 */
    @TestCase
    public func compilesExprColumn(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .exprColumn("risk")
            .thenColumn("discount")
            .row([">=3", "order.amount > 200", "0.85"])
            .build()

        let compiled = TableCompiler(table, orderRuleSet(), compiler()).compile()
        @Assert(compiled.rules[0].scripts.size, 1)
        @Expect(compiled.rules[0].scripts[0].startsWith("{"), true)
        @Expect(compiled.rows[0].conditions.size, 2)
        @Expect(compiled.rows[0].conditions[1].expression.getOrThrow().usesJit, true)
    }
}
