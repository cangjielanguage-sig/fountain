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
 * `Pattern` 的约束集合契约（`doc/03-condition-expression.md` §4，用例 C-05/C-08）。
 *
 * 约束顺序不影响语义；字段必须在类型的字段声明中；同一规则内绑定名唯一。
 */
@Test
class Pattern_test {
    private func facts(): Array<Fact> {
        [
            TypedFact(CondOrder("A", 500, 3), condOrderSchema()),
            TypedFact(CondOrder("B", 100, 1), condOrderSchema()),
            TypedFact(CondOrder("C", 300, 2), condOrderSchema())
        ]
    }

    private func matchedIds(pattern: Pattern): String {
        var result = ""
        for (fact in facts()) {
            if (pattern.matches(fact)) {
                match (fact.get("id")) {
                    case Some(v) =>
                        match (v) {
                            case id: String => result = result + id
                            case _ => ()
                        }
                    case None => ()
                }
            }
        }
        result
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

    /** C-05：约束重排后匹配集合相同。 */
    @TestCase
    public func reorderingConstraintsKeepsSemantics(): Unit {
        let first = Pattern("Order", "o")
            .constrain("amount", Operator.Ge, 300)
            .constrain("level", Operator.Ge, 2)
        let second = Pattern("Order", "o")
            .constrain("level", Operator.Ge, 2)
            .constrain("amount", Operator.Ge, 300)

        @Assert(first.constraints.size, 2)
        @Assert(matchedIds(first), matchedIds(second))
        @Assert(matchedIds(first), "AC")
    }

    /** `any` 无条件匹配该类型全部事实；`whereNot` 取反。 */
    @TestCase
    public func anyAndWhereNot(): Unit {
        @Assert(matchedIds(Pattern.any("Order", "o")), "ABC")
        let notExpensive = Pattern("Order", "o").constrainNot("amount", Operator.Ge, 300)
        @Assert(matchedIds(notExpensive), "B")
    }

    /** 右操作数可以是同事实字段。 */
    @TestCase
    public func comparesFieldsWithinPattern(): Unit {
        let pattern = Pattern("Order", "o").constrainField("amount", Operator.Gt, "level")
        @Assert(matchedIds(pattern), "ABC")
    }

    /** C-08：约束引用未声明字段抛 `UNKNOWN_FIELD`。 */
    @TestCase
    public func unknownFieldRejected(): Unit {
        let pattern = Pattern("Order", "o").constrain("nonexistent", Operator.Eq, 1)
        @Expect(codeOf({ => pattern.validate(condOrderSpace()) }), RuleErrorCode.UNKNOWN_FIELD)

        let viaField = Pattern("Order", "o").constrainField("amount", Operator.Gt, "nonexistent")
        @Expect(codeOf({ => viaField.validate(condOrderSpace()) }), RuleErrorCode.UNKNOWN_FIELD)
    }

    /** 未注册类型同样拒绝。 */
    @TestCase
    public func unknownTypeRejected(): Unit {
        let pattern = Pattern("Missing", "o")
        @Expect(codeOf({ => pattern.validate(condOrderSpace()) }), RuleErrorCode.UNKNOWN_TYPE)
    }

    /** 绑定名重复抛 `ILLEGAL_STATE`。 */
    @TestCase
    public func duplicateBindingRejected(): Unit {
        let patterns = [Pattern("Order", "o"), Pattern("Order", "o")]
        @Expect(codeOf({ => Pattern.requireUniqueBindings(patterns) }), RuleErrorCode.ILLEGAL_STATE)

        let ok = [Pattern("Order", "o"), Pattern("Order", "u")]
        Pattern.requireUniqueBindings(ok)
    }

    /** `JoinConstraint` 按绑定取值比较。 */
    @TestCase
    public func joinConstraintEvaluatesBindings(): Unit {
        let bindings = HashMap<String, Fact>()
        bindings["o"] = TypedFact(CondOrder("A", 500, 3), condOrderSchema())
        bindings["u"] = TypedFact(CondOrder("U", 100, 9), condOrderSchema())
        let join = JoinConstraint("o", "amount", Operator.Gt, "u", "amount")
        @Expect(join.eval(bindings), Truth.True)

        let missing = JoinConstraint("o", "amount", Operator.Gt, "x", "amount")
        @Expect(missing.eval(bindings), Truth.Unknown)
    }
}
