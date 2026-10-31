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

import std.fs.Path
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler
import fountain::f_rule.fact.{FactBaseViewStore, TypedFact}
import fountain::f_rule.rule.RuleSet

/**
 * 夹具表（`src/fixtures` 下的 CSV）解析与编译，覆盖 T-01 的真实文件路径。
 *
 * 三个夹具分别落在 `orders`（两张）与 `users`（一张）空间，用来验证
 * 多表多空间共存时 `factType` 推断与 `binding` 解析。
 */
@Test
class FixtureTable_test {
    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<TableOrder>()
        c
    }

    private func ordersRuleSet(): RuleSet {
        tableRuleSet("orders") { space =>
            space.register(tableOrderSchema())
        }
    }

    private func usersRuleSet(): RuleSet {
        tableRuleSet("users") { space =>
            space.register(tableUserSchema())
        }
    }

    /** pricing.csv：单类型空间自动推断 factType。 */
    @TestCase
    public func parsesPricingFixture(): Unit {
        let table = CsvTableParser.parseFile(Path("src/fixtures/pricing.csv"))
        @Assert(table.id, "pricing")
        @Assert(table.factSpace, "orders")
        @Expect(table.hitPolicy, HitPolicy.First)
        @Expect(table.salience, 100)
        @Assert(table.rows.size, 3)
        @Assert(table.rows[2].ruleId, "R3")

        let compiled = TableCompiler(table, ordersRuleSet(), compiler()).compile()
        @Expect(compiled.factType, "Order")
        @Expect(compiled.rules.size, 3)
        @Expect(compiled.rules[0].salience, 100)
    }

    /** orders.csv：显式 factType 与单条件列。 */
    @TestCase
    public func parsesOrdersFixture(): Unit {
        let table = CsvTableParser.parseFile(Path("src/fixtures/orders.csv"))
        @Assert(table.id, "orders")
        @Assert(table.factType, "Order")
        @Assert(table.rows.size, 2)
        let compiled = TableCompiler(table, ordersRuleSet(), compiler()).compile()
        @Expect(compiled.rules.size, 2)
        @Expect(compiled.factType, "Order")
    }

    /** users.csv：Collect 策略与另一空间。 */
    @TestCase
    public func parsesUsersFixture(): Unit {
        let table = CsvTableParser.parseFile(Path("src/fixtures/users.csv"))
        @Assert(table.id, "users")
        @Assert(table.factSpace, "users")
        @Expect(table.hitPolicy, HitPolicy.Collect)
        let compiled = TableCompiler(table, usersRuleSet(), compiler()).compile()
        @Expect(compiled.rules.size, 2)
        @Expect(compiled.factType, "User")
    }

    /** 夹具端到端：pricing 命中 R1，折扣 0.85。 */
    @TestCase
    public func executesPricingFixture(): Unit {
        let ruleSet = ordersRuleSet()
        let table = CsvTableParser.parseFile(Path("src/fixtures/pricing.csv"))
        let view = FactBaseViewStore(ruleSet.registry).view("orders", "fixture")
        let _ = view.assert(TypedFact(TableOrder("A", 3, 500), tableOrderSchema()))
        let result = TableExecutor(table, ruleSet, compiler()).execute(view)
        @Assert(result.hits[0].ruleId, "R1")
        @Assert(result.outputs[0].get("discount").getOrThrow() as Float64, 0.85)
    }
}
