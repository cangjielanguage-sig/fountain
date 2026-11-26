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

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.exception.*
import fountain::f_rule.fact.Fact

/**
 * 布尔条件树（`doc/03-condition-expression.md` §5）。
 *
 * 限制：
 * - 嵌套深度上限 32（`TABLE_INVALID`），防止构造期栈溢出；
 * - `Not` 只能包裹单事实条件；包裹 join 抛 `ILLEGAL_STATE`（否定模式留待后续）；
 * - `Or` 分支跨 `typeTag` 时由 [expand] 展开为多条规则。
 */
public enum ConditionExpr {
    | And(Array<ConditionExpr>)
    | Or(Array<ConditionExpr>)
    | Not(ConditionExpr)
    | Leaf(Constraint)
    | Join(JoinConstraint)
    | Script(JitExpression)

    /** 树高（叶子为 1）。 */
    public func depth(): Int64 {
        match (this) {
            case And(children) => ConditionExpr.maxDepth(children) + 1
            case Or(children) => ConditionExpr.maxDepth(children) + 1
            case Not(inner) => inner.depth() + 1
            case Leaf(_) | Join(_) | Script(_) => 1
        }
    }

    private static func maxDepth(children: Array<ConditionExpr>): Int64 {
        var result: Int64 = 0
        for (child in children) {
            let d = child.depth()
            if (d > result) {
                result = d
            }
        }
        result
    }

    /** 构建期校验：深度上限与 `Not` 的限制。 */
    public func validate(): Unit {
        if (depth() > 32) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "条件树嵌套深度超过 32 层"
            )
        }
        match (this) {
            case And(children) =>
                for (child in children) {
                    child.validate()
                }
            case Or(children) =>
                for (child in children) {
                    child.validate()
                }
            case Not(inner) =>
                match (inner) {
                    case Join(_) =>
                        throw RuleException(
                            RuleErrorCode.ILLEGAL_STATE,
                            "Not 不能包裹 JoinConstraint；否定模式尚未支持"
                        )
                    case _ => inner.validate()
                }
            case Leaf(_) | Join(_) | Script(_) => ()
        }
    }

    /** 求值：`Script` 与 `Join` 需要绑定表，`Leaf` 只需要当前事实。 */
    public func eval(fact: Fact, bindings: HashMap<String, Fact>): Truth {
        match (this) {
            case And(children) =>
                var result = Truth.True
                for (child in children) {
                    result = result.and(child.eval(fact, bindings))
                }
                result
            case Or(children) =>
                var result = Truth.False
                for (child in children) {
                    result = result.or(child.eval(fact, bindings))
                }
                result
            case Not(inner) => inner.eval(fact, bindings).not()
            case Leaf(constraint) => constraint.eval(fact)
            case Join(join) => join.eval(bindings)
            case Script(script) =>
                if (script.eval(bindings)) {
                    Truth.True
                } else {
                    Truth.False
                }
        }
    }

    /**
     * `Or` 跨类型展开（`doc/03` §5）。
     *
     * 同一类型的分支合回一个 `Or`；不同 `typeTag` 拆成多条规则，id 依次加 `#1`、`#2`。
     * 返回的 [TypedClause] 保留类型标签，供上层维护 `Rule.patterns`。
     */
    public static func expand(ruleId: String, clauses: Array<TypedClause>): Array<(String, TypedClause)> {
        let order = ArrayList<String>()
        for (clause in clauses) {
            if (!order.contains(clause.typeTag)) {
                order.add(clause.typeTag)
            }
        }
        let out = ArrayList<(String, TypedClause)>()
        if (order.size <= 1) {
            let exprs = ArrayList<ConditionExpr>()
            for (clause in clauses) {
                exprs.add(clause.expr)
            }
            let merged = if (exprs.size == 1) {
                exprs[0]
            } else {
                ConditionExpr.Or(exprs.toArray())
            }
            let typeTag = if (order.size == 1) { order[0] } else { "" }
            out.add((ruleId, TypedClause(typeTag, merged)))
            return out.toArray()
        }
        var index = 0
        for (typeTag in order) {
            let exprs = ArrayList<ConditionExpr>()
            for (clause in clauses) {
                if (clause.typeTag == typeTag) {
                    exprs.add(clause.expr)
                }
            }
            let merged = if (exprs.size == 1) {
                exprs[0]
            } else {
                ConditionExpr.Or(exprs.toArray())
            }
            out.add(("${ruleId}#${index + 1}", TypedClause(typeTag, merged)))
            index += 1
        }
        out.toArray()
    }
}

/**
 * 带类型标签的条件分支。
 *
 * 条件树本身（`Leaf`）不知道事实类型；`Or` 展开需要类型信息，因此由调用方在分支上显式标注。
 */
public class TypedClause {
    public let typeTag: String
    public let expr: ConditionExpr

    public init(typeTag: String, expr: ConditionExpr) {
        this.typeTag = typeTag
        this.expr = expr
    }

    public func typeTags(): Array<String> {
        [typeTag]
    }
}
