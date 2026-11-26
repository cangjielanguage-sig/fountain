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

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler
import fountain::f_rule.exception.*
import fountain::f_rule.fact.{DynamicFact, Fact, TypedFact}

/**
 * `expr` 列单元格编译（`doc/07-decision-table.md` §4.3）。
 *
 * 裸表达式按 `factType` + 绑定包装成 lambda 后编译；语法错误抛 `SCRIPT_COMPILE`；
 * 动态事实绑定整体走内置解释器。
 */
@Test
class ExprColumn_test {
    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<TableOrder>()
        c
    }

    private func hostType(): String {
        tableOrderSchema().hostSimpleName
    }

    private func bindings(order: TableOrder): HashMap<String, Fact> {
        let map = HashMap<String, Fact>()
        map["o"] = TypedFact(order, tableOrderSchema())
        map
    }

    /** 按事实类型 + 绑定名包装后编译，并能求值。 */
    @TestCase
    public func compilesTypedExpression(): Unit {
        let expr = ExprColumn.compile(Some("o.amount > 200"), "o", hostType(), compiler()).getOrThrow()
        @Expect(expr.usesJit, true)
        @Assert(expr.parameters[0], "o")
        @Expect(expr.eval(bindings(TableOrder("A", 3, 500))), true)
        @Expect(expr.eval(bindings(TableOrder("B", 3, 100))), false)
    }

    /** 语法错误抛 `SCRIPT_COMPILE`。 */
    @TestCase
    public func rejectsSyntaxError(): Unit {
        var code = RuleErrorCode.ILLEGAL_STATE
        try {
            let _ = ExprColumn.compile(Some("o.amount >"), "o", hostType(), compiler())
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.SCRIPT_COMPILE)
    }

    /** 空单元格不产生条件。 */
    @TestCase
    public func emptyCellIsIgnored(): Unit {
        @Expect(ExprColumn.compile(None, "o", hostType(), compiler()).isNone(), true)
        @Expect(ExprColumn.compile(Some("  "), "o", hostType(), compiler()).isNone(), true)
        @Expect(ExprColumn.compile(Some("-"), "o", hostType(), compiler()).isNone(), true)
    }

    /** 动态事实无法进 JIT，整体降级解释器。 */
    @TestCase
    public func dynamicFactUsesInterpreter(): Unit {
        let expr = ExprColumn.compile(Some("amount > 200"), "o", "", compiler()).getOrThrow()
        @Expect(expr.usesJit, false)
        let fact = DynamicFact("Row")
        fact.set("amount", 500)
        let map = HashMap<String, Fact>()
        map["o"] = fact
        @Expect(expr.eval(map), true)
    }
}
