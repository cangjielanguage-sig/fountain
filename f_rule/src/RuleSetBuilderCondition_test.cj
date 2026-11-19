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
package fountain::f_rule

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.*
import fountain::f_rule.exception.*
import fountain::f_rule.rule.*

/**
 * 条件树接入构建期（`doc/03-condition-expression.md` §5，C-06/C-07）。
 *
 * `Rule.builder(...).condition(typeTag, expr)` 在 `RuleSetBuilder.buildOrInvalid()` 里
 * 转成 DNF：`And` 合并到同一 `Pattern`，`Or` 拆成多条规则（id 加 `#1`/`#2`），
 * 展开数量上限 64。
 */
@Test
class RuleSetBuilderCondition_test {
    private func leaf(field: String, op: Operator, value: Any): ConditionExpr {
        Leaf(Constraint(field, op, right: Operand.Const(value)))
    }

    private func throwCode(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    private func throwMessage(action: () -> Unit): String {
        try {
            action()
        } catch (e: RuleException) {
            return e.message
        }
        ""
    }

    private func baseBuilder(): RuleSetBuilder {
        RuleSetBuilder("cond")
            .registerDynamicType("default", "Order", ["amount", "level"])
            .registerDynamicType("default", "User", ["amount", "level"])
    }

    /** 单叶子条件在构建期落成单模式规则。 */
    @TestCase
    public func leafCompilesToPattern(): Unit {
        let rule = Rule.builder("R1")
            .condition("Order", leaf("amount", Operator.Gt, 100))
            .build()
        @Expect(rule.condition.isSome(), true)
        @Assert(rule.conditionType, "Order")

        let ruleSet = baseBuilder().rule(rule).build()
        @Assert(ruleSet.rules.size, 1)
        @Assert(ruleSet.rules[0].id, "R1")
        @Assert(ruleSet.rules[0].patterns.size, 1)
        @Assert(ruleSet.rules[0].patterns[0].typeTag, "Order")
        @Assert(ruleSet.rules[0].patterns[0].binding, "o")
        @Assert(ruleSet.rules[0].patterns[0].constraints.size, 1)
        @Expect(ruleSet.rules[0].patterns[0].constraints[0].op, Operator.Gt)
    }

    /** `And` 把多条约束合并进同一个 `Pattern`。 */
    @TestCase
    public func andMergesConstraintsIntoOnePattern(): Unit {
        let expr = And([
            leaf("amount", Operator.Gt, 100),
            leaf("level", Operator.Ge, 3)
        ])
        let ruleSet = baseBuilder()
            .rule(Rule.builder("R1").condition("Order", expr).build())
            .build()
        @Assert(ruleSet.rules.size, 1)
        @Assert(ruleSet.rules[0].patterns.size, 1)
        @Assert(ruleSet.rules[0].patterns[0].constraints.size, 2)
    }

    /** 同类型 `Or` 也拆成多条规则，id 依次加后缀。 */
    @TestCase
    public func orWithinOneTypeExpands(): Unit {
        let expr = Or([
            leaf("amount", Operator.Gt, 100),
            leaf("amount", Operator.Lt, 50)
        ])
        let ruleSet = baseBuilder()
            .rule(Rule.builder("R1").condition("Order", expr).build())
            .build()
        @Assert(ruleSet.rules.size, 2)
        @Assert(ruleSet.rules[0].id, "R1#1")
        @Assert(ruleSet.rules[1].id, "R1#2")
        @Assert(ruleSet.rules[0].patterns[0].typeTag, "Order")
    }

    /** 跨类型 `Or`：多次 `condition(typeTag, ...)` 合并为析取，展开后各自单类型。 */
    @TestCase
    public func orAcrossTypesExpands(): Unit {
        let rule = Rule.builder("R1")
            .condition("Order", leaf("amount", Operator.Gt, 100))
            .condition("User", leaf("level", Operator.Ge, 3))
            .build()

        let ruleSet = baseBuilder().rule(rule).build()
        @Assert(ruleSet.rules.size, 2)
        @Assert(ruleSet.rules[0].id, "R1#1")
        @Assert(ruleSet.rules[0].patterns[0].typeTag, "Order")
        @Assert(ruleSet.rules[1].id, "R1#2")
        @Assert(ruleSet.rules[1].patterns[0].typeTag, "User")
    }

    /** `And(Or(A, B), C)` 按分配律展开，每条规则两份约束。 */
    @TestCase
    public func nestedAndOrDistributes(): Unit {
        let expr = And([
            Or([
                leaf("amount", Operator.Gt, 100),
                leaf("amount", Operator.Lt, 50)
            ]),
            leaf("level", Operator.Ge, 2)
        ])
        let ruleSet = baseBuilder()
            .rule(Rule.builder("R1").condition("Order", expr).build())
            .build()
        @Assert(ruleSet.rules.size, 2)
        @Assert(ruleSet.rules[0].id, "R1#1")
        @Assert(ruleSet.rules[1].id, "R1#2")
        @Assert(ruleSet.rules[0].patterns[0].constraints.size, 2)
        @Assert(ruleSet.rules[1].patterns[0].constraints.size, 2)
    }

    /** `Not(Leaf)` 落成 `constrainNot` 语义（`negated == true`）。 */
    @TestCase
    public func notLeafUsesNegatedConstraint(): Unit {
        let ruleSet = baseBuilder()
            .rule(Rule.builder("R1")
                .condition("Order", Not(leaf("amount", Operator.Gt, 100)))
                .build())
            .build()
        @Assert(ruleSet.rules.size, 1)
        @Expect(ruleSet.rules[0].patterns[0].constraints[0].negated, true)
    }

    /** `Not` 包裹 join 在构建期拒绝。 */
    @TestCase
    public func notAroundJoinRejected(): Unit {
        let join = Join(JoinConstraint("o", "amount", Operator.Eq, "u", "amount"))
        @Expect(throwCode({ =>
            let _ = Rule.builder("R1").condition("Order", Not(join)).build()
        }), RuleErrorCode.ILLEGAL_STATE)
    }

    /** `Script` 进入规则的脚本条件列表。 */
    @TestCase
    public func scriptBecomesRuleScript(): Unit {
        let script = Script(JitExpression.interpreted("o.amount > 100", ["o"]))
        let ruleSet = baseBuilder()
            .expressionMode(ExpressionMode.Interpreted)
            .rule(Rule.builder("R1").condition("Order", script).build())
            .build()
        @Assert(ruleSet.rules.size, 1)
        @Assert(ruleSet.rules[0].scripts.size, 1)
        @Assert(ruleSet.rules[0].scripts[0], "o.amount > 100")
    }

    /** `Join` 引用规则里已有的绑定；条件生成自己的模式。 */
    @TestCase
    public func joinUsesExistingBinding(): Unit {
        let expr = And([
            leaf("amount", Operator.Gt, 100),
            Join(JoinConstraint("o", "amount", Operator.Eq, "u", "amount"))
        ])
        let ruleSet = baseBuilder()
            .rule(Rule.builder("R1")
                .addPattern(Pattern("User", "u"))
                .condition("Order", expr)
                .build())
            .build()
        @Assert(ruleSet.rules.size, 1)
        @Assert(ruleSet.rules[0].patterns.size, 2)
        @Assert(ruleSet.rules[0].joins.size, 1)
    }

    /** 展开数量超过 64 抛 `TABLE_INVALID`，消息点明展开爆炸。 */
    @TestCase
    public func expansionOverLimitRejected(): Unit {
        let leaves = ArrayList<ConditionExpr>()
        var i: Int64 = 0
        while (i < 65) {
            leaves.add(leaf("amount", Operator.Gt, i))
            i += 1
        }
        let builder = baseBuilder()
            .rule(Rule.builder("R1").condition("Order", Or(leaves.toArray())).build())
        @Expect(throwCode({ => let _ = builder.build() }), RuleErrorCode.TABLE_INVALID)
        @Expect(throwMessage({ => let _ = builder.build() }).contains("条件树展开爆炸"), true)
    }

    /** 展开后的规则仍走 `Validator`：未知字段在构建期失败，状态为 Invalid。 */
    @TestCase
    public func expandedRulesAreValidated(): Unit {
        let builder = baseBuilder()
            .rule(Rule.builder("R1").condition("Order", leaf("missing", Operator.Gt, 1)).build())
        let ruleSet = builder.buildOrInvalid()
        @Expect(ruleSet.isValid(), false)
        @Expect(builder.lastError().getOrThrow().code, RuleErrorCode.UNKNOWN_FIELD)
    }
}
