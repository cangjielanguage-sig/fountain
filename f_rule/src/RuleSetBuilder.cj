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

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.condition.ExpressionMode
import fountain::f_rule.exception.*
import fountain::f_rule.fact.*
import fountain::f_rule.rule.*

/**
 * `RuleSet` 的装配器（`doc/08-api.md` §3）。
 *
 * 放在包根是为了既能引用 `fact`/`condition`，又能引用 `rule` 模型，不制造包循环。
 * 文档里的 `RuleSet.builder(id)` 在仓颉里会形成 `rule → 根包` 的反向依赖，
 * 因此改用本类的构造函数 `RuleSetBuilder(id)`。
 */
public class RuleSetBuilder {
    private let id_: String
    private var version_: String
    private let registry_: FactSpaceRegistry
    private let rules_: ArrayList<Rule>
    private let ruleIds_: HashMap<String, Bool>
    private var expressionMode_: ExpressionMode
    private var conflictResolver_: ConflictResolver

    public init(id: String) {
        this.id_ = id
        this.version_ = "v1"
        this.registry_ = FactSpaceRegistry()
        this.rules_ = ArrayList<Rule>()
        this.ruleIds_ = HashMap<String, Bool>()
        this.expressionMode_ = ExpressionMode.JitPreferred
        this.conflictResolver_ = DefaultConflictResolver()
    }

    public func version(version: String): RuleSetBuilder {
        version_ = version
        this
    }

    /** 声明一个事实库空间；规则通过 `.facts(id)` 引用。 */
    public func factSpace(id: String): RuleSetBuilder {
        let _ = registry_.declare(id)
        this
    }

    /** 在缺省空间 `default` 注册强类型事实。 */
    public func registerFact<T>(schema: FactSchema<T>): RuleSetBuilder {
        registerFact(TypeTag.DEFAULT_SPACE, schema)
    }

    /** 在指定空间注册；空间不存在时自动声明。 */
    public func registerFact<T>(space: String, schema: FactSchema<T>): RuleSetBuilder {
        let target = registry_.declare(space)
        let _ = target.register(schema)
        this
    }

    /** 在缺省空间注册动态类型（字段类型按 `Any`）。 */
    public func registerDynamicType(typeTag: String, fields: Array<String>): RuleSetBuilder {
        registerDynamicType(TypeTag.DEFAULT_SPACE, typeTag, fields)
    }

    /** 在指定空间注册动态类型。 */
    public func registerDynamicType(space: String, typeTag: String, fields: Array<String>): RuleSetBuilder {
        let typed = ArrayList<(String, FieldType)>()
        for (name in fields) {
            typed.add((name, FieldType.`Any`))
        }
        let target = registry_.declare(space)
        let _ = target.registerDynamic(typeTag, typed.toArray())
        this
    }

    /** 追加规则；id 重复立即抛 `DUPLICATE_RULE`。 */
    public func rule(rule: Rule): RuleSetBuilder {
        if (ruleIds_.contains(rule.id)) {
            throw RuleException(
                RuleErrorCode.DUPLICATE_RULE,
                "规则集中规则 id 重复: ${rule.id}"
            )
        }
        ruleIds_[rule.id] = true
        rules_.add(rule)
        // 隐式 default 空间的规则自动声明该空间（F-15）；显式空间留给校验器判 UNKNOWN_FACT_SPACE
        if (!rule.explicitSpace) {
            let _ = registry_.declare(TypeTag.DEFAULT_SPACE)
        }
        this
    }

    public func rules(rules: Array<Rule>): RuleSetBuilder {
        for (rule in rules) {
            let _ = this.rule(rule)
        }
        this
    }

    /** 表达式求值模式，缺省 `JitPreferred`。 */
    public func expressionMode(mode: ExpressionMode): RuleSetBuilder {
        expressionMode_ = mode
        this
    }

    /** 冲突消解策略，缺省 `salience → specificity → ruleOrder → seq`。 */
    public func conflictResolver(resolver: ConflictResolver): RuleSetBuilder {
        conflictResolver_ = resolver
        this
    }

    /** 构建并校验；失败抛异常，规则集不可用。 */
    public func build(): RuleSet {
        let ruleSet = buildOrInvalid()
        if (!ruleSet.isValid()) {
            match (lastError_) {
                case Some(error) => throw error
                case None =>
                    throw RuleException(
                        RuleErrorCode.TABLE_INVALID,
                        "规则集 ${id_} 校验失败，状态为 Invalid"
                    )
            }
        }
        ruleSet
    }

    /**
     * 构建并把失败留在 `RuleSet.status` 里（`Invalid`），不抛校验异常。
     *
     * 供测试与诊断使用：`build()` 是它的"失败即抛"薄封装。
     */
    public func buildOrInvalid(): RuleSet {
        let ordered = ArrayList<Rule>()
        var index: Int64 = 0
        for (rule in rules_) {
            ordered.add(rule.withOrder(index))
            index += 1
        }
        let ruleSet = RuleSet(id_, version_, ordered.toArray(), registry_, expressionMode_, conflictResolver_)
        try {
            Validator.validate(ruleSet)
            ruleSet.freeze()
        } catch (e: RuleException) {
            ruleSet.markInvalid()
            lastError_ = Some(e)
        }
        ruleSet
    }

    private var lastError_: ?RuleException = None

    /** 最近一次校验失败的错误（`buildOrInvalid` 路径）。 */
    public func lastError(): ?RuleException {
        lastError_
    }
}
