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
package fountain::f_rule.condition

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.*

/**
 * 条件树与展开限制（`doc/03-condition-expression.md` §5，用例 C-06/C-07）。
 *
 * - `Or` 跨类型展开为多条规则，id 加 `#1`/`#2`；
 * - `Not` 只允许包裹单事实条件，包裹 join 抛 `ILLEGAL_STATE`；
 * - 嵌套深度上限 32，超出抛 `TABLE_INVALID`。
 */
@Test
class ConditionExpr_test {
    private func leaf(field: String, value: Int64): ConditionExpr {
        Leaf(Constraint(field, Operator.Gt, right: Operand.Const(value)))
    }

    private func validateCode(expr: ConditionExpr): RuleErrorCode {
        try {
            expr.validate()
        } catch (e: RuleException) {
            return e.code
        }
        RuleErrorCode.CLOSED
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** C-06：跨类型 Or 展开成 `<id>#1`、`<id>#2`。 */
    @TestCase
    public func orAcrossTypesExpands(): Unit {
        let clauses = [
            TypedClause("Order", leaf("amount", 200)),
            TypedClause("User", leaf("level", 3))
        ]
        let expanded = ConditionExpr.expand("R1", clauses)
        @Assert(expanded.size, 2)
        @Assert(expanded[0][0], "R1#1")
        @Assert(expanded[1][0], "R1#2")
        @Expect(expanded[0][1].typeTags(), ["Order"])
        @Expect(expanded[1][1].typeTags(), ["User"])
    }

    /** 同类型 Or 不展开，保持单条规则。 */
    @TestCase
    public func orWithinOneTypeDoesNotExpand(): Unit {
        let clauses = [
            TypedClause("Order", leaf("amount", 200)),
            TypedClause("Order", leaf("level", 3))
        ]
        let expanded = ConditionExpr.expand("R1", clauses)
        @Assert(expanded.size, 1)
        @Assert(expanded[0][0], "R1")
        @Expect(expanded[0][1].typeTags(), ["Order"])
    }

    /** C-07：嵌套 33 层抛 `TABLE_INVALID`。 */
    @TestCase
    public func depthLimitRejects33(): Unit {
        var expr = leaf("amount", 1)
        var i = 0
        while (i < 33) {
            expr = Not(expr)
            i += 1
        }
        @Expect(validateCode(expr), RuleErrorCode.TABLE_INVALID)

        var shallow = leaf("amount", 1)
        var j = 0
        while (j < 10) {
            shallow = Not(shallow)
            j += 1
        }
        shallow.validate()
    }

    /** `Not` 包裹 join 抛 `ILLEGAL_STATE`。 */
    @TestCase
    public func notAroundJoinRejected(): Unit {
        let join = Join(JoinConstraint("o", "amount", Operator.Gt, "u", "amount"))
        @Expect(codeOf({ => Not(join).validate() }), RuleErrorCode.ILLEGAL_STATE)
        // 普通否定合法
        Not(leaf("amount", 1)).validate()
    }

    /** `And`/`Or` 求值按三值逻辑折叠。 */
    @TestCase
    public func andOrEvaluateWithThreeValuedLogic(): Unit {
        let facts = HashMap<String, Fact>()
        let fact: Fact = TypedFact(CondOrder("A", 500, 3), condOrderSchema())
        let expr = And([
            leaf("amount", 200),
            Leaf(Constraint("missing", Operator.Gt, right: Operand.Const(1)))
        ])
        @Expect(expr.eval(fact, facts), Truth.Unknown)

        let orExpr = Or([leaf("amount", 1000), leaf("amount", 200)])
        @Expect(orExpr.eval(fact, facts), Truth.True)
    }
}
