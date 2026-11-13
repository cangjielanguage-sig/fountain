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

import std.collection.ArrayList
import fountain::f_rule.condition.*
import fountain::f_rule.exception.*

/**
 * 条件树 → DNF → 规则展开（`doc/03-condition-expression.md` §5）。
 *
 * 一条 `condition(typeTag, expr)` 分支先转成析取范式：每个合取项生成一条规则，
 * 叶子约束合并进同一个 `Pattern(typeTag, "o")`；`Or` 因此自然拆成多条规则，
 * 嵌套的 `And(Or(A, B), C)` 按分配律展开。展开数量上限 64，防止条件树爆炸。
 */
class ConditionExpander {
    /** 单条规则条件树的最大展开条数。 */
    static let maxExpansions: Int64 = 64

    /** 无条件的规则原样返回；有条件的规则按 DNF 展开并改写 id。 */
    static func expand(rule: Rule): Array<Rule> {
        if (rule.conditionClauses.isEmpty()) {
            return [rule]
        }
        let out = ArrayList<Rule>()
        for (clause in rule.conditionClauses) {
            for (conjunction in dnf(clause.expr)) {
                out.add(compile(rule, clause.typeTag, conjunction))
                limit(Int64(out.size), rule.id)
            }
        }
        if (out.isEmpty()) {
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "规则 ${rule.id} 的条件树展开为空"
            )
        }
        if (out.size == 1) {
            return out.toArray()
        }
        let named = ArrayList<Rule>()
        var index: Int64 = 1
        for (item in out) {
            named.add(item.withId("${rule.id}#${index}"))
            index += 1
        }
        named.toArray()
    }

    /** 析取范式：返回所有合取项。 */
    private static func dnf(expr: ConditionExpr): ArrayList<Conjunction> {
        match (expr) {
            case Leaf(constraint) => singleConstraint(constraint)
            case Join(join) => singleJoin(join)
            case Script(script) => singleScript(script.source)
            case Not(inner) => dnfNot(inner)
            case And(children) =>
                var out = ArrayList<Conjunction>()
                out.add(Conjunction())
                for (child in children) {
                    out = cross(out, dnf(child))
                }
                out
            case Or(children) =>
                let out = ArrayList<Conjunction>()
                for (child in children) {
                    for (item in dnf(child)) {
                        out.add(item)
                        limit(Int64(out.size), "")
                    }
                }
                out
        }
    }

    /** 否定下推到叶子；`Not(Join)` 与 `Not(Script)` 没有对应模式。 */
    private static func dnfNot(inner: ConditionExpr): ArrayList<Conjunction> {
        match (inner) {
            case Leaf(constraint) =>
                let negated = Constraint(constraint.field, constraint.op,
                    right: constraint.right, negated: !constraint.negated)
                singleConstraint(negated)
            case Not(inner2) => dnf(inner2)
            case Join(_) =>
                throw RuleException(
                    RuleErrorCode.ILLEGAL_STATE,
                    "Not 不能包裹 JoinConstraint；否定模式尚未支持"
                )
            case Script(_) =>
                throw RuleException(
                    RuleErrorCode.ILLEGAL_STATE,
                    "Not 不能包裹 Script 条件；条件树不支持脚本取反"
                )
            case And(children) =>
                // Not(A ∧ B) = (Not A) ∨ (Not B)
                let out = ArrayList<Conjunction>()
                for (child in children) {
                    for (item in dnfNot(child)) {
                        out.add(item)
                        limit(Int64(out.size), "")
                    }
                }
                out
            case Or(children) =>
                // Not(A ∨ B) = (Not A) ∧ (Not B)
                var out = ArrayList<Conjunction>()
                out.add(Conjunction())
                for (child in children) {
                    out = cross(out, dnfNot(child))
                }
                out
        }
    }

    private static func cross(left: ArrayList<Conjunction>,
        right: ArrayList<Conjunction>): ArrayList<Conjunction> {
        let out = ArrayList<Conjunction>()
        for (a in left) {
            for (b in right) {
                out.add(a.merge(b))
                limit(Int64(out.size), "")
            }
        }
        out
    }

    private static func singleConstraint(constraint: Constraint): ArrayList<Conjunction> {
        let item = Conjunction()
        item.constraints_.add(constraint)
        let out = ArrayList<Conjunction>()
        out.add(item)
        out
    }

    private static func singleJoin(join: JoinConstraint): ArrayList<Conjunction> {
        let item = Conjunction()
        item.joins_.add(join)
        let out = ArrayList<Conjunction>()
        out.add(item)
        out
    }

    private static func singleScript(source: String): ArrayList<Conjunction> {
        let item = Conjunction()
        item.scripts_.add(source)
        let out = ArrayList<Conjunction>()
        out.add(item)
        out
    }

    /** 一个合取项落成一条规则：生成模式 + 合并已有模式/join/脚本。 */
    private static func compile(rule: Rule, typeTag: String, conjunction: Conjunction): Rule {
        for (pattern in rule.patterns) {
            if (pattern.binding == "o") {
                throw RuleException(
                    RuleErrorCode.ILLEGAL_STATE,
                    "规则 ${rule.id} 已有绑定 o，条件树生成模式需要该绑定名"
                )
            }
        }
        let generated = Pattern(typeTag, "o")
        for (constraint in conjunction.constraints_) {
            let _ = generated.addConstraint(constraint)
        }

        let patterns = ArrayList<Pattern>()
        for (pattern in rule.patterns) {
            patterns.add(pattern)
        }
        patterns.add(generated)

        let joins = ArrayList<JoinConstraint>()
        for (join in rule.joins) {
            joins.add(join)
        }
        for (join in conjunction.joins_) {
            joins.add(join)
        }

        let scripts = ArrayList<String>()
        for (script in rule.scripts) {
            scripts.add(script)
        }
        for (script in conjunction.scripts_) {
            scripts.add(script)
        }

        Rule(rule.id, rule.salience, rule.factSpace, rule.explicitSpace, rule.activationGroup,
            patterns.toArray(), joins.toArray(), scripts.toArray(), rule.actions, rule.order,
            rule.condition, rule.conditionType, rule.conditionClauses)
    }

    private static func limit(result: Int64, ruleId: String): Unit {
        if (result > maxExpansions) {
            let owner = if (ruleId == "") {
                "条件树"
            } else {
                "规则 ${ruleId} 的条件树"
            }
            throw RuleException(
                RuleErrorCode.TABLE_INVALID,
                "${owner}展开数量超过 ${maxExpansions} 条（条件树展开爆炸）"
            )
        }
    }
}

/** DNF 的合取项：约束、join 与脚本条件的有序集合。 */
class Conjunction {
    let constraints_: ArrayList<Constraint>
    let joins_: ArrayList<JoinConstraint>
    let scripts_: ArrayList<String>

    init() {
        this.constraints_ = ArrayList<Constraint>()
        this.joins_ = ArrayList<JoinConstraint>()
        this.scripts_ = ArrayList<String>()
    }

    func merge(other: Conjunction): Conjunction {
        let out = Conjunction()
        for (item in constraints_) {
            out.constraints_.add(item)
        }
        for (item in other.constraints_) {
            out.constraints_.add(item)
        }
        for (item in joins_) {
            out.joins_.add(item)
        }
        for (item in other.joins_) {
            out.joins_.add(item)
        }
        for (item in scripts_) {
            out.scripts_.add(item)
        }
        for (item in other.scripts_) {
            out.scripts_.add(item)
        }
        out
    }
}
