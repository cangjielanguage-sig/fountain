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

import fountain::f_rule.exception.*
import fountain::f_rule.fact.*

/**
 * 单事实约束（`doc/03-condition-expression.md` §4）。
 *
 * 左值是当前事实的字段，右值是常量或同事实字段；求值走三值逻辑。
 * `negated` 对应 `whereNot`，`Not Unknown` 仍为 `Unknown`。
 */
public class Constraint {
    public let field: String
    public let op: Operator
    public let right: Operand
    public let negated: Bool

    public init(field: String, op: Operator, right!: Operand, negated!: Bool = false) {
        this.field = field
        this.op = op
        this.right = right
        this.negated = negated
    }

    public func eval(fact: Fact): Truth {
        let result = OperatorEvaluator.apply(op, fact.get(field), right.resolve(fact))
        if (negated) {
            result.not()
        } else {
            result
        }
    }

    /** 构建期校验：`Bind` 右值非法、字段必须已声明。 */
    public func validate(space: FactSpace, typeTag: String): Unit {
        if (right.isBind()) {
            throw RuleException(
                RuleErrorCode.ILLEGAL_STATE,
                "Constraint(${field}) 不允许 Bind 右值；跨模式比较请用 JoinConstraint"
            )
        }
        Constraint.validateField(space, typeTag, field)
        match (right) {
            case Field(name) => Constraint.validateField(space, typeTag, name)
            case _ => ()
        }
    }

    static func validateField(space: FactSpace, typeTag: String, field: String): Unit {
        if (!space.hasType(typeTag)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_TYPE,
                "空间 ${space.id} 未注册类型 ${typeTag}"
            )
        }
        if (!space.fieldNames(typeTag).contains(field)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_FIELD,
                "类型 ${typeTag} 未声明字段 ${field}"
            )
        }
    }

    public func toString(): String {
        let body = "${field} ${op} ${right}"
        if (negated) {
            "not(${body})"
        } else {
            body
        }
    }
}
