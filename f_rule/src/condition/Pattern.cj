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

import std.collection.{ArrayList, HashSet}
import fountain::f_rule.exception.*
import fountain::f_rule.fact.*

/**
 * 模式：事实类型 + 绑定名 + 约束集（`doc/03-condition-expression.md` §4）。
 *
 * 约束顺序无关：求值是 `And` 折叠，三值 `And` 可交换。`space` 缺省为空串，
 * 表示继承所属规则的 `factSpace`；显式设置用于构建期发现跨空间模式。
 */
public class Pattern {
    public let typeTag: String
    public let binding: String
    public let space: String
    private let constraints_: ArrayList<Constraint>

    public init(typeTag: String, binding: String, space!: String = "") {
        this.typeTag = typeTag
        this.binding = binding
        this.space = space
        this.constraints_ = ArrayList<Constraint>()
    }

    public prop constraints: Array<Constraint> {
        get() {
            constraints_.toArray()
        }
    }

    /** 常量右值约束。 */
    public func constrain(field: String, op: Operator, value: Any): Pattern {
        constraints_.add(Constraint(field, op, right: Operand.Const(value)))
        this
    }

    /**
     * 同事实字段右值约束。
     *
     * 用独立名字而不是重载 `constrain`：`constrain(field, op, "text")` 会被重载解析优先
     * 当成"字段名"，与用户意图相反，因此字符串常量与字段比较必须显式区分。
     * 文档里的 `where` 是仓颉关键字，公开 API 只能改名（见 README 的偏差说明）。
     */
    public func constrainField(field: String, op: Operator, rightField: String): Pattern {
        constraints_.add(Constraint(field, op, right: Operand.Field(rightField)))
        this
    }

    /** 否定约束（`Not Unknown` 仍为 `Unknown`）。 */
    public func constrainNot(field: String, op: Operator, value: Any): Pattern {
        constraints_.add(Constraint(field, op, right: Operand.Const(value), negated: true))
        this
    }

    /** 无条件模式：匹配该类型所有事实。 */
    public static func any(typeTag: String, binding: String): Pattern {
        Pattern(typeTag, binding)
    }

    /** `And` 折叠全部约束。 */
    public func eval(fact: Fact): Truth {
        var result = Truth.True
        for (constraint in constraints_) {
            result = result.and(constraint.eval(fact))
        }
        result
    }

    /** 只接受 `True`；`Unknown` 与 `False` 都不匹配。 */
    public func matches(fact: Fact): Bool {
        eval(fact).isTrue()
    }

    /** 构建期校验：类型已注册、字段已声明。 */
    public func validate(space: FactSpace): Unit {
        if (!space.hasType(typeTag)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_TYPE,
                "空间 ${space.id} 未注册类型 ${typeTag}"
            )
        }
        for (constraint in constraints_) {
            constraint.validate(space, typeTag)
        }
    }

    /** 同一规则内绑定名必须唯一。 */
    public static func requireUniqueBindings(patterns: Array<Pattern>): Unit {
        let seen = HashSet<String>()
        for (pattern in patterns) {
            if (seen.contains(pattern.binding)) {
                throw RuleException(
                    RuleErrorCode.ILLEGAL_STATE,
                    "同一规则内绑定名重复: ${pattern.binding}"
                )
            }
            seen.add(pattern.binding)
        }
    }

    public func toString(): String {
        "Pattern(${typeTag} as \$${binding}, ${constraints_.size} constraints)"
    }
}
