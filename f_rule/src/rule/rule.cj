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
import fountain::f_rule.condition.{ConditionExpr, JoinConstraint, Pattern, TypedClause}
import fountain::f_rule.exception.*
import fountain::f_rule.fact.TypeTag

/** 规则动作：执行期由议程注入 `ActionContext`。 */
public interface RuleAction {
    func execute(ctx: ActionContext): Unit
}

/**
 * 规则模型（`doc/08-api.md` §4）。
 *
 * 不可变；`order` 由 `RuleSet` 在装配时按加入顺序赋值，用于冲突消解的最后一级。
 */
public class Rule {
    public let id: String
    public let salience: Int64
    public let factSpace: String
    /** `false` 表示未显式 `.facts(...)`，归入 default；校验器据此区分 F-14/F-15。 */
    public let explicitSpace: Bool
    /**
     * 互斥组名；同组激活只执行一个（`doc/11-assembly.md` §4.4）。
     *
     * 组只影响议程调度，不参与 [Activation] 的相等键。`None` 表示不分组。
     */
    public let activationGroup: ?String
    public let patterns: Array<Pattern>
    public let joins: Array<JoinConstraint>
    public let scripts: Array<String>
    public let actions: Array<RuleAction>
    public let order: Int64
    /** 构建期条件树；`None` 表示用 `patterns`/`joins` 直接描述条件。 */
    public let condition: ?ConditionExpr
    /**
     * 条件树的事实类型；无条件是空串。
     *
     * 多次 `condition(typeTag, expr)` 表达跨类型析取时，类型不一致则为空串
     * （此时以 [conditionClauses] 里每个分支自己的类型为准）。
     */
    public let conditionType: String
    /** 每个 `condition(typeTag, expr)` 调用保留的带类型分支；展开时使用。 */
    let conditionClauses: Array<TypedClause>

    init(id: String, salience: Int64, factSpace: String, explicitSpace: Bool,
        activationGroup: ?String, patterns: Array<Pattern>, joins: Array<JoinConstraint>,
        scripts: Array<String>, actions: Array<RuleAction>, order: Int64,
        condition: ?ConditionExpr, conditionType: String,
        conditionClauses: Array<TypedClause>) {
        this.id = id
        this.salience = salience
        this.factSpace = factSpace
        this.explicitSpace = explicitSpace
        this.activationGroup = activationGroup
        this.patterns = patterns
        this.joins = joins
        this.scripts = scripts
        this.actions = actions
        this.order = order
        this.condition = condition
        this.conditionType = conditionType
        this.conditionClauses = conditionClauses
    }

    public static func builder(id: String): RuleBuilder {
        RuleBuilder(id)
    }

    /** 复制并设置规则序号（`RuleSet` 装配用）。 */
    public func withOrder(value: Int64): Rule {
        Rule(id, salience, factSpace, explicitSpace, activationGroup, patterns, joins, scripts,
            actions, value, condition, conditionType, conditionClauses)
    }

    /** 条件树展开后改写规则 id（内部使用）。 */
    func withId(value: String): Rule {
        Rule(value, salience, factSpace, explicitSpace, activationGroup, patterns, joins, scripts,
            actions, order, condition, conditionType, conditionClauses)
    }

    public func toString(): String {
        "Rule(${id}, space=${factSpace}, patterns=${patterns.size})"
    }
}

/**
 * 规则构建器。
 *
 * 公开 API 相对 `doc/08` 有两处改名（仓颉关键字）：`when` → [addPattern]，
 * `where` → [script]。
 */
public class RuleBuilder {
    private let id_: String
    private var salience_: Int64
    private var factSpace_: String
    private var explicitSpace_: Bool
    private var activationGroup_: ?String
    private let patterns_: ArrayList<Pattern>
    private let joins_: ArrayList<JoinConstraint>
    private let scripts_: ArrayList<String>
    private let actions_: ArrayList<RuleAction>
    private let conditions_: ArrayList<TypedClause>

    init(id: String) {
        this.id_ = id
        this.salience_ = 0
        this.factSpace_ = TypeTag.DEFAULT_SPACE
        this.explicitSpace_ = false
        this.activationGroup_ = None
        this.patterns_ = ArrayList<Pattern>()
        this.joins_ = ArrayList<JoinConstraint>()
        this.scripts_ = ArrayList<String>()
        this.actions_ = ArrayList<RuleAction>()
        this.conditions_ = ArrayList<TypedClause>()
    }

    public func salience(value: Int64): RuleBuilder {
        salience_ = value
        this
    }

    /** 绑定事实库；缺省 default。 */
    public func facts(space: String): RuleBuilder {
        factSpace_ = space
        explicitSpace_ = true
        this
    }

    /** 互斥组名；同组激活只执行一个，其余在首个执行后失效。 */
    public func activationGroup(name: String): RuleBuilder {
        activationGroup_ = Some(name)
        this
    }

    /** 追加模式（文档中的 `when`）。 */
    public func addPattern(pattern: Pattern): RuleBuilder {
        patterns_.add(pattern)
        this
    }

    /**
     * 条件树入口（`doc/03-condition-expression.md` §5）。
     *
     * 多次调用表示析取：同类型的多个分支在构建期合并成一个 `Or`，
     * 不同类型的多个分支展开成多条单类型规则。叶子统一绑定到 `"o"`；
     * 若需要 join 到别的模式，先 `addPattern` 再在条件树里写 `Join`。
     */
    public func condition(typeTag: String, expr: ConditionExpr): RuleBuilder {
        conditions_.add(TypedClause(typeTag, expr))
        this
    }

    public func join(constraint: JoinConstraint): RuleBuilder {
        joins_.add(constraint)
        this
    }

    /** 脚本条件源码（文档中的 `where`）；编译发生在 `RuleSet.build()`。 */
    public func script(source: String): RuleBuilder {
        scripts_.add(source)
        this
    }

    /** 宿主闭包动作；公开签名保持不变，内部包装成 [ClosureAction]。 */
    public func then(action: (ActionContext) -> Unit): RuleBuilder {
        actions_.add(ClosureAction(action))
        this
    }

    /**
     * 脚本动作（`f_jit` 编译 `{ ctx: ActionContext => ... }`）。
     *
     * 编译在调用本方法时完成；失败抛 `RuleException(SCRIPT_COMPILE)`。
     */
    public func thenScript(source: String): RuleBuilder {
        actions_.add(ScriptAction(source))
        this
    }

    /**
     * 构建规则。
     *
     * 无模式且无条件树抛 `EMPTY_PATTERN`；同一规则内绑定名重复抛 `ILLEGAL_STATE`。
     * 条件树的深度与 `Not` 限制在此校验，展开在 `RuleSetBuilder`。
     */
    public func build(): Rule {
        if (patterns_.isEmpty() && conditions_.isEmpty()) {
            throw RuleException(
                RuleErrorCode.EMPTY_PATTERN,
                "规则 ${id_} 没有任何模式"
            )
        }
        Pattern.requireUniqueBindings(patterns_.toArray())

        var condition: ?ConditionExpr = None
        var conditionType = ""
        if (!conditions_.isEmpty()) {
            let branches = ArrayList<ConditionExpr>()
            for (clause in conditions_) {
                branches.add(clause.expr)
            }
            condition = if (branches.size == 1) {
                Some(branches[0])
            } else {
                Some(Or(branches.toArray()))
            }
            // 按合并后的树校验：多次 condition(...) 会多一层 Or。
            condition.getOrThrow().validate()
            conditionType = if (sameTypeTag(conditions_)) {
                conditions_[0].typeTag
            } else {
                ""
            }
        }
        Rule(id_, salience_, factSpace_, explicitSpace_, activationGroup_, patterns_.toArray(),
            joins_.toArray(), scripts_.toArray(), actions_.toArray(), -1,
            condition, conditionType, conditions_.toArray())
    }

    private func sameTypeTag(clauses: ArrayList<TypedClause>): Bool {
        if (clauses.isEmpty()) {
            return false
        }
        let first = clauses[0].typeTag
        for (clause in clauses) {
            if (clause.typeTag != first) {
                return false
            }
        }
        true
    }
}
