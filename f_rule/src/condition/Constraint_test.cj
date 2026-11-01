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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*
import fountain::f_rule.fact.*

/** 条件测试共用宿主类。 */
public class CondOrder {
    public var id: String
    public var amount: Int64
    public var level: Int64

    public init(id: String, amount: Int64, level: Int64) {
        this.id = id
        this.amount = amount
        this.level = level
    }
}

/** 条件测试共用 schema。 */
public func condOrderSchema(): FactSchema<CondOrder> {
    FactSchema<CondOrder>("Order")
        .field("id", FieldType.Text, { o => o.id })
        .field("amount", FieldType.Number, { o => o.amount })
        .field("level", FieldType.Number, { o => o.level })
}

/** 条件测试共用事实空间。 */
public func condOrderSpace(): FactSpace {
    let registry = FactSpaceRegistry()
    let space = registry.declare("orders")
    let _ = space.register(condOrderSchema())
    space
}

/**
 * `Constraint` 的单事实求值契约（`doc/03-condition-expression.md` §4）。
 *
 * 右操作数允许常量或同事实字段；字段缺失一律 `Unknown`，`IsNull` 除外。
 */
@Test
class Constraint_test {
    private func fact(amount: Int64, level: Int64): Fact {
        TypedFact(CondOrder("A", amount, level), condOrderSchema())
    }

    /** 常量右值：范围与等值。 */
    @TestCase
    public func evaluatesConstantRight(): Unit {
        let constraint = Constraint("amount", Operator.Gt, right: Operand.Const(200))
        @Expect(constraint.eval(fact(500, 3)), Truth.True)
        @Expect(constraint.eval(fact(100, 3)), Truth.False)
    }

    /** `whereNot` 语义：结果取反，`Unknown` 仍为 `Unknown`。 */
    @TestCase
    public func negationFlipsKnownOnly(): Unit {
        let constraint = Constraint("amount", Operator.Gt, right: Operand.Const(200), negated: true)
        @Expect(constraint.eval(fact(100, 3)), Truth.True)
        @Expect(constraint.eval(fact(500, 3)), Truth.False)

        let missing = Constraint("missing", Operator.Gt, right: Operand.Const(200), negated: true)
        @Expect(missing.eval(fact(500, 3)), Truth.Unknown)
    }

    /** 右值是同事实字段：`amount Gt level`。 */
    @TestCase
    public func comparesTwoFields(): Unit {
        let constraint = Constraint("amount", Operator.Gt, right: Operand.Field("level"))
        @Expect(constraint.eval(fact(10, 3)), Truth.True)
        @Expect(constraint.eval(fact(1, 3)), Truth.False)
    }

    /** 动态事实缺字段：普通算子 `Unknown`，`IsNull` 命中。 */
    @TestCase
    public func missingFieldIsUnknownExceptIsNull(): Unit {
        let dynamic = DynamicFact("Order")
        dynamic.set("level", 3)
        let ordinary = Constraint("amount", Operator.Gt, right: Operand.Const(100))
        @Expect(ordinary.eval(dynamic), Truth.Unknown)

        let isNull = Constraint("amount", Operator.IsNull, right: Operand.Const(0))
        @Expect(isNull.eval(dynamic), Truth.True)
    }

    /** `Bind` 右值不能出现在单事实约束里。 */
    @TestCase
    public func bindRightIsIllegalInConstraint(): Unit {
        let constraint = Constraint("amount", Operator.Gt, right: Operand.Bind("o", "level"))
        @Expect(constraint.eval(fact(10, 1)), Truth.Unknown)
        var caught = RuleErrorCode.CLOSED
        try {
            constraint.validate(condOrderSpace(), "Order")
        } catch (e: RuleException) {
            caught = e.code
        }
        @Expect(caught, RuleErrorCode.ILLEGAL_STATE)
    }

    /** 约束校验：未声明字段抛 `UNKNOWN_FIELD`。 */
    @TestCase
    public func unknownFieldRejected(): Unit {
        var caught = RuleErrorCode.CLOSED
        try {
            Constraint("nonexistent", Operator.Eq, right: Operand.Const(1))
                .validate(condOrderSpace(), "Order")
        } catch (e: RuleException) {
            caught = e.code
        }
        @Expect(caught, RuleErrorCode.UNKNOWN_FIELD)
    }
}
