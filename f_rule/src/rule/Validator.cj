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
package fountain::f_rule.rule

import std.collection.{HashMap, HashSet}
import fountain::f_rule.condition.{ExpressionMode, JitExpression, Operator, Pattern}
import fountain::f_rule.exception.*
import fountain::f_rule.fact.{FactSpace, FieldType}
import fountain::f_rule.runtime.RuleRuntime

/**
 * 构建期校验器（`doc/02-fact-model.md` §8）。
 *
 * 顺序即优先级：先空间与规则身份，再模式（空间/类型/字段），最后算子类型兼容。
 * 任一失败立即抛错，由构建器把规则集标为 `Invalid`。
 */
public class Validator {
    private init() {}

    public static func validate(ruleSet: RuleSet): Unit {
        let registry = ruleSet.registry
        if (registry.ids().size == 0) {
            throw RuleException(
                RuleErrorCode.EMPTY_FACT_SPACE_SET,
                "规则集 ${ruleSet.id} 没有任何事实空间"
            )
        }
        let seen = HashSet<String>()
        for (rule in ruleSet.rules) {
            if (seen.contains(rule.id)) {
                throw RuleException(
                    RuleErrorCode.DUPLICATE_RULE,
                    "规则集中规则 id 重复: ${rule.id}"
                )
            }
            seen.add(rule.id)
            if (!registry.has(rule.factSpace)) {
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FACT_SPACE,
                    "规则 ${rule.id} 引用了未声明的事实空间 ${rule.factSpace}"
                )
            }
            let space = registry.get(rule.factSpace).getOrThrow()
            let byBinding = HashMap<String, Pattern>()
            for (pattern in rule.patterns) {
                let effective = if (pattern.space == "") {
                    rule.factSpace
                } else {
                    pattern.space
                }
                if (effective != rule.factSpace) {
                    throw RuleException(
                        RuleErrorCode.CROSS_SPACE_JOIN,
                        "规则 ${rule.id} 的模式跨空间: ${rule.factSpace} vs ${effective}"
                    )
                }
                // UNKNOWN_TYPE / UNKNOWN_FIELD / Bind 右值
                pattern.validate(space)
                validateConstraintTypes(space, pattern)
                byBinding[pattern.binding] = pattern
            }
            for (join in rule.joins) {
                let left = byBinding.get(join.leftBinding)
                let right = byBinding.get(join.rightBinding)
                match ((left, right)) {
                    case (Some(leftPattern), Some(rightPattern)) =>
                        validateJoinField(space, leftPattern.typeTag, join.leftField, rule.id)
                        validateJoinField(space, rightPattern.typeTag, join.rightField, rule.id)
                        validateJoinTypes(space, leftPattern.typeTag, join.leftField,
                            rightPattern.typeTag, join.rightField, join.op, rule.id)
                    case _ =>
                        throw RuleException(
                            RuleErrorCode.UNKNOWN_BINDING,
                            "规则 ${rule.id} 的 join 引用了不存在的绑定"
                        )
                }
            }
            // 脚本条件在构建期编译并校验形参：编译失败抛 SCRIPT_COMPILE，
            // 形参不在模式绑定中抛 SCRIPT_BINDING_MISSING。运行时不再兜底。
            // 求值模式与网络构建保持一致：`Interpreted` 也必须在这里先过解释器，
            // 否则要到建网络时才暴露超出解释器子集的语法。
            let compiler = RuleRuntime.compiler()
            for (source in rule.scripts) {
                let expression = if (ruleSet.expressionMode == ExpressionMode.Interpreted) {
                    JitExpression.interpretedOf(source)
                } else {
                    JitExpression.of(source, compiler)
                }
                expression.requireBindings(byBinding.keys().toArray())
            }
        }
    }

    private static func validateJoinField(space: FactSpace, typeTag: String, field: String,
        ruleId: String): Unit {
        if (!space.hasType(typeTag)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_TYPE,
                "规则 ${ruleId} 的 join 引用了未注册类型 ${typeTag}"
            )
        }
        if (!space.fieldNames(typeTag).contains(field)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_FIELD,
                "规则 ${ruleId} 的 join 引用了未声明字段 ${typeTag}.${field}"
            )
        }
    }

    /** 排序类 join 要求两侧字段同域（Number/Text/Time 之一）。 */
    private static func validateJoinTypes(space: FactSpace, leftTypeTag: String, leftField: String,
        rightTypeTag: String, rightField: String, op: Operator, ruleId: String): Unit {
        if (!op.ordering) {
            return
        }
        let left = space.fieldType(leftTypeTag, leftField).getOrThrow()
        let right = space.fieldType(rightTypeTag, rightField).getOrThrow()
        if (!pairCompatible(left, right, op)) {
            throw RuleException(
                RuleErrorCode.TYPE_MISMATCH,
                "规则 ${ruleId} 的 join 两侧字段类型不兼容: ${left} vs ${right}"
            )
        }
    }

    /** 单事实约束的算子 vs 字段静态类型。 */
    private static func validateConstraintTypes(space: FactSpace, pattern: Pattern): Unit {
        for (constraint in pattern.constraints) {
            let fieldType = space.fieldType(pattern.typeTag, constraint.field).getOrThrow()
            if (!compatible(fieldType, constraint.op)) {
                throw RuleException(
                    RuleErrorCode.TYPE_MISMATCH,
                    "字段 ${pattern.typeTag}.${constraint.field}（${fieldType}）不支持算子 ${constraint.op}"
                )
            }
            match (constraint.right) {
                case Field(name) =>
                    let rightType = space.fieldType(pattern.typeTag, name).getOrThrow()
                    if (!pairCompatible(fieldType, rightType, constraint.op)) {
                        throw RuleException(
                            RuleErrorCode.TYPE_MISMATCH,
                            "字段 ${constraint.field}（${fieldType}）与 ${name}（${rightType}）不能比较"
                        )
                    }
                case _ => ()
            }
        }
    }

    /**
     * 字段类型与算子的兼容矩阵（`doc/03-condition-expression.md` §2 的左右值列）。
     *
     * `Any`/`Scalar` 视为未知，一律放行——动态事实的类型只能在运行期确定。
     */
    public static func compatible(fieldType: FieldType, op: Operator): Bool {
        match (op) {
            case IsNull | NotNull => true
            // 等值/不等值对任意标量与列表都成立（ValueKey 全序）
            case Eq | Ne => true
            case Gt | Ge | Lt | Le =>
                match (fieldType) {
                    case Number | Text | Time | Scalar | `Any` => true
                    case _ => false
                }
            case Contains =>
                match (fieldType) {
                    case Text | List | Scalar | `Any` => true
                    case _ => false
                }
            case StartsWith | EndsWith | Matches =>
                match (fieldType) {
                    case Text | Scalar | `Any` => true
                    case _ => false
                }
            case In | NotIn =>
                match (fieldType) {
                    case Number | Text | Time | `Bool` | Scalar | `Any` => true
                    case _ => false
                }
            case Between =>
                match (fieldType) {
                    case Number | Time | Scalar | `Any` => true
                    case _ => false
                }
        }
    }

    /** 字段 vs 字段比较：排序类要求同域。 */
    static func pairCompatible(left: FieldType, right: FieldType, op: Operator): Bool {
        if (!op.ordering) {
            return true
        }
        if (left == FieldType.`Any` || right == FieldType.`Any` || left == FieldType.Scalar ||
            right == FieldType.Scalar) {
            return true
        }
        left == right
    }
}
