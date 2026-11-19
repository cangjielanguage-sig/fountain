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
import fountain::f_rule.rule.TableSource

/**
 * `TableSource` 接口（`doc/11-assembly.md` §4.1/§4.2）。
 *
 * 表只依赖事实空间注册表，不再要求调用方先构建完整 `RuleSet`：
 * 装配器拿到 registry 即可编译，单测也可直接构造最小注册表。
 */
@Test
class TableSource_test {
    private func pricingTable(): DecisionTable {
        DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .thenColumn("discount")
            .row("R1", [">=3", "0.85"])
            .row("R2", [">=1", "0.90"])
            .build()
    }

    private func ordersRegistry(): FactSpaceRegistry {
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

    /** 编译结果只依赖 registry：每行一条规则。 */
    @TestCase
    public func compileIntoReturnsOneRulePerRow(): Unit {
        let source: TableSource = pricingTable()
        let rules = source.compileInto(ordersRegistry())

        @Expect(rules.size, 2)
        @Expect(rules[0].patterns.size, 1)
        @Expect(rules[1].patterns.size, 1)
    }

    /** 表引用了未声明空间时抛 `UNKNOWN_FACT_SPACE`。 */
    @TestCase
    public func compileIntoRejectsUnknownSpace(): Unit {
        let source: TableSource = pricingTable()
        @Expect(codeOf({ => source.compileInto(FactSpaceRegistry()) }),
            RuleErrorCode.UNKNOWN_FACT_SPACE)
    }
}
