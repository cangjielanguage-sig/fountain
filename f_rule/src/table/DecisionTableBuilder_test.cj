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

/**
 * 决策表构建 API（`doc/07-decision-table.md` §1/§3，用例 T-15 前置）。
 *
 * 列声明顺序即 `row(values)` 的顺序；`factSpace` 缺省 `default`；
 * `factType` 缺省时只在空间恰好一个类型时自动推断。
 */
@Test
class DecisionTableBuilder_test {
    private func sample(): DecisionTable {
        DecisionTable.builder("pricing")
            .name("订单折扣")
            .version("v1")
            .whenColumn("order.level")
            .whenColumn("order.amount")
            .thenColumn("discount")
            .row([">=3", ">200", "0.85"])
            .row("R2", [">=1", ">500", "0.90"])
            .build()
    }

    /** 列按声明顺序保存，条件列拆出 binding/field，输出列取 name。 */
    @TestCase
    public func declaresColumnsInOrder(): Unit {
        let table = sample()

        @Assert(table.id, "pricing")
        @Assert(table.name, "订单折扣")
        @Assert(table.version, "v1")
        @Assert(table.columns.size, 3)
        @Expect(table.columns[0].kind, ColumnKind.When)
        @Assert(table.columns[0].name, "when.order.level")
        @Assert(table.columns[0].binding, "order")
        @Assert(table.columns[0].field, "level")
        @Expect(table.columns[1].kind, ColumnKind.When)
        @Assert(table.columns[1].field, "amount")
        @Expect(table.columns[2].kind, ColumnKind.Then)
        @Assert(table.columns[2].name, "then.discount")
        @Assert(table.columns[2].path, "discount")
    }

    /** `row(values)` 自动编号 R1/R2，`line` 从 2 开始；显式 id 优先。 */
    @TestCase
    public func appendsRowsWithStableIdsAndLines(): Unit {
        let table = sample()

        @Assert(table.rows.size, 2)
        @Assert(table.rows[0].ruleId, "R1")
        @Assert(table.rows[0].line, 2)
        @Expect(table.rows[0].values.size, 3)
        @Expect(table.rows[0].values[0].getOrThrow(), ">=3")
        @Assert(table.rows[1].ruleId, "R2")
        @Assert(table.rows[1].line, 3)
        @Expect(table.rows[1].values[2].getOrThrow(), "0.90")
    }

    /** 缺省空间是 default；缺省命中策略 First；缺省 salience 0；未声明 factType。 */
    @TestCase
    public func appliesDefaults(): Unit {
        let table = sample()

        @Assert(table.factSpace, "default")
        @Expect(table.hitPolicy, HitPolicy.First)
        @Expect(table.salience, 0)
        @Assert(table.factType, "")
    }

    /** 单类型空间未声明 factType 时自动推断。 */
    @TestCase
    public func infersFactTypeFromSingleTypeSpace(): Unit {
        let ruleSet = tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "0.85"])
            .build()

        @Expect(table.resolvedFactType(ruleSet.registry), "Order")
        @Assert(table.binding, "order")
        @Assert(table.factSpace, "orders")
    }

    /** 多类型空间必须显式声明 factType，否则构建期 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsAmbiguousFactType(): Unit {
        let ruleSet = tableRuleSet("pricing") { space =>
            space.register(tableOrderSchema())
            space.register(tableCouponSchema())
        }
        let table = DecisionTable.builder("pricing")
            .factSpace("pricing")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "0.85"])
            .build()

        var code = RuleErrorCode.ILLEGAL_STATE
        var message = ""
        try {
            let _ = table.resolvedFactType(ruleSet.registry)
        } catch (e: RuleException) {
            code = e.code
            message = e.message
        }
        @Expect(code, RuleErrorCode.TABLE_INVALID)
        @Expect(message.contains("factType"), true)
    }

    /** 显式 factType 可在多类型空间使用。 */
    @TestCase
    public func acceptsExplicitFactType(): Unit {
        let ruleSet = tableRuleSet("pricing") { space =>
            space.register(tableOrderSchema())
            space.register(tableCouponSchema())
        }
        let table = DecisionTable.builder("pricing")
            .factSpace("pricing")
            .factType("Order")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row([">=3", "0.85"])
            .build()

        @Expect(table.resolvedFactType(ruleSet.registry), "Order")
    }

    /** 列数与行值不一致时构建期报 `TABLE_INVALID` 并带行号。 */
    @TestCase
    public func rejectsRowWidthMismatch(): Unit {
        var code = RuleErrorCode.ILLEGAL_STATE
        var message = ""
        try {
            let _ = DecisionTable.builder("pricing")
                .whenColumn("order.level")
                .thenColumn("discount")
                .row([">=3"])
                .build()
        } catch (e: RuleException) {
            code = e.code
            message = e.message
        }
        @Expect(code, RuleErrorCode.TABLE_INVALID)
        @Expect(message.contains("line=2"), true)
    }

    /** 未知表头列名报 `TABLE_INVALID`。 */
    @TestCase
    public func rejectsUnknownColumn(): Unit {
        var code = RuleErrorCode.ILLEGAL_STATE
        try {
            let _ = DecisionTable.builder("pricing")
                .column("unknown.level")
                .thenColumn("discount")
                .row([">=3", "0.85"])
                .build()
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.TABLE_INVALID)
    }
}
