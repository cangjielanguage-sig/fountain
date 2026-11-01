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
import fountain::f_rule.rule.RuleSetBuilder

/**
 * 决策表装配进规则集（`doc/11-assembly.md` §4.1，用例 AS-01~AS-05）。
 *
 * `RuleSetBuilder.table(source)` 只依赖 `TableSource` 接口，不反向依赖 `table` 包；
 * 表在装配期编译，规则 id 带表 id 前缀，空间/字段错误在装配期暴露。
 */
@Test
class TableAssembly_test {
    private func pricingTable(): DecisionTable {
        DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row("R1", [">=3", "0.85"])
            .row("R2", [">=1", "0.90"])
            .build()
    }

    private func builder(): RuleSetBuilder {
        RuleSetBuilder("pricing")
            .registerFact("orders", tableOrderSchema())
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        try {
            action()
            return RuleErrorCode.ILLEGAL_STATE
        } catch (e: RuleException) {
            return e.code
        }
    }

    /** AS-01：表规则进入规则集，数量等于数据行数。 */
    @TestCase
    public func assemblesOneRulePerRow(): Unit {
        let ruleSet = builder().table(pricingTable()).build()

        @Expect(ruleSet.rules.size, 2)
        @Expect(ruleSet.isValid(), true)
        @Expect(ruleSet.rules[0].factSpace, "orders")
    }

    /** AS-02：编译出的规则 id 形如 `<tableId>/<rowId>`。 */
    @TestCase
    public func prefixesRuleIdsWithTableId(): Unit {
        let ruleSet = builder().table(pricingTable()).build()

        @Assert(ruleSet.rules[0].id, "pricing/R1")
        @Assert(ruleSet.rules[1].id, "pricing/R2")
    }

    /** AS-03：表引用的空间未声明时抛 `UNKNOWN_FACT_SPACE`。 */
    @TestCase
    public func rejectsUnknownFactSpace(): Unit {
        let table = pricingTable()
        @Expect(codeOf({ => RuleSetBuilder("pricing").table(table) }),
            RuleErrorCode.UNKNOWN_FACT_SPACE)
    }

    /** AS-04：同一张表重复装配时规则 id 冲突，抛 `DUPLICATE_RULE`。 */
    @TestCase
    public func rejectsDuplicateAssembly(): Unit {
        let table = pricingTable()
        @Expect(codeOf({ => builder().table(table).table(table) }),
            RuleErrorCode.DUPLICATE_RULE)
    }

    /** AS-05：`when.*` 引用未注册字段时抛 `UNKNOWN_FIELD`。 */
    @TestCase
    public func rejectsUnknownField(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.missing")
            .thenColumn("discount")
            .row("R1", [">=3", "0.85"])
            .build()
        @Expect(codeOf({ => builder().table(table) }), RuleErrorCode.UNKNOWN_FIELD)
    }
}
