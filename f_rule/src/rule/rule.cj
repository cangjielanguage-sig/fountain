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
import fountain::f_rule.condition.{JoinConstraint, Pattern}
import fountain::f_rule.exception.*
import fountain::f_rule.fact.TypeTag

/** 规则动作：执行期由议程注入 `ActionContext`。 */
public type RuleAction = (ActionContext) -> Unit

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
    public let patterns: Array<Pattern>
    public let joins: Array<JoinConstraint>
    public let scripts: Array<String>
    public let actions: Array<RuleAction>
    public let order: Int64

    init(id: String, salience: Int64, factSpace: String, explicitSpace: Bool,
        patterns: Array<Pattern>, joins: Array<JoinConstraint>, scripts: Array<String>,
        actions: Array<RuleAction>, order: Int64) {
        this.id = id
        this.salience = salience
        this.factSpace = factSpace
        this.explicitSpace = explicitSpace
        this.patterns = patterns
        this.joins = joins
        this.scripts = scripts
        this.actions = actions
        this.order = order
    }

    public static func builder(id: String): RuleBuilder {
        RuleBuilder(id)
    }

    /** 复制并设置规则序号（`RuleSet` 装配用）。 */
    public func withOrder(value: Int64): Rule {
        Rule(id, salience, factSpace, explicitSpace, patterns, joins, scripts, actions, value)
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
    private let patterns_: ArrayList<Pattern>
    private let joins_: ArrayList<JoinConstraint>
    private let scripts_: ArrayList<String>
    private let actions_: ArrayList<RuleAction>

    init(id: String) {
        this.id_ = id
        this.salience_ = 0
        this.factSpace_ = TypeTag.DEFAULT_SPACE
        this.explicitSpace_ = false
        this.patterns_ = ArrayList<Pattern>()
        this.joins_ = ArrayList<JoinConstraint>()
        this.scripts_ = ArrayList<String>()
        this.actions_ = ArrayList<RuleAction>()
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

    /** 追加模式（文档中的 `when`）。 */
    public func addPattern(pattern: Pattern): RuleBuilder {
        patterns_.add(pattern)
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

    public func then(action: RuleAction): RuleBuilder {
        actions_.add(action)
        this
    }

    /**
     * 构建规则。
     *
     * 无模式抛 `EMPTY_PATTERN`；同一规则内绑定名重复抛 `ILLEGAL_STATE`。
     */
    public func build(): Rule {
        if (patterns_.isEmpty()) {
            throw RuleException(
                RuleErrorCode.EMPTY_PATTERN,
                "规则 ${id_} 没有任何模式"
            )
        }
        Pattern.requireUniqueBindings(patterns_.toArray())
        Rule(id_, salience_, factSpace_, explicitSpace_, patterns_.toArray(), joins_.toArray(),
            scripts_.toArray(), actions_.toArray(), -1)
    }
}
