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

import fountain::f_rule.condition.{EvalFailureKind, ExpressionMode}
import fountain::f_rule.fact.{FactSpace, FactSpaceRegistry}

/** 规则集状态：校验失败后进入 `Invalid`，不得构造引擎。 */
public enum RuleSetStatus <: ToString & Equatable<RuleSetStatus> {
    | Valid
    | Invalid

    public func toString(): String {
        match (this) {
            case Valid => "Valid"
            case Invalid => "Invalid"
        }
    }

    public operator func ==(other: RuleSetStatus): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: RuleSetStatus): Bool {
        !(this == other)
    }
}

/**
 * 规则集（`doc/08-api.md` §3）。
 *
 * 构建期单线程；构建成功后空间与类型描述冻结，规则数组只读。
 * `status == Invalid` 时不得构造 `RuleEngine`（M3 落实现）。
 */
public class RuleSet {
    public let id: String
    public let version: String
    public let rules: Array<Rule>
    public let registry: FactSpaceRegistry
    public let expressionMode: ExpressionMode
    public let conflictResolver: ConflictResolver
    /** 运行期求值失败状态；按 `(ruleSetId, ruleId)` 归属，跨会话共享。 */
    public let failureGuard: RuleFailureGuard
    private var status_: RuleSetStatus
    private var closed_: Bool
    private var cycleEnabled_: Bool
    private var cycleWindow_: Int64
    private var cycleThreshold_: Int64

    public init(id: String, version: String, rules: Array<Rule>, registry: FactSpaceRegistry,
        expressionMode: ExpressionMode, conflictResolver: ConflictResolver) {
        this.id = id
        this.version = version
        this.rules = rules
        this.registry = registry
        this.expressionMode = expressionMode
        this.conflictResolver = conflictResolver
        this.failureGuard = RuleFailureGuard(id)
        this.status_ = RuleSetStatus.Valid
        this.closed_ = false
        this.cycleEnabled_ = false
        this.cycleWindow_ = 10000
        this.cycleThreshold_ = 100
    }

    public prop status: RuleSetStatus {
        get() {
            status_
        }
    }

    public prop closed: Bool {
        get() {
            closed_
        }
    }

    public func isValid(): Bool {
        status_ == RuleSetStatus.Valid && !closed_
    }

    /** 声明顺序的空间列表。 */
    public func factSpaces(): Array<FactSpace> {
        registry.spaces()
    }

    /** 是否开启循环检测（默认关闭）。 */
    public prop cycleDetection: Bool {
        get() {
            cycleEnabled_
        }
    }

    /** 循环检测窗口大小（最近 N 个激活指纹）。 */
    public prop cycleWindow: Int64 {
        get() {
            cycleWindow_
        }
    }

    /** 同一指纹在窗口内允许出现的次数上限，超过即抛 `CYCLE_LIMIT`。 */
    public prop cycleThreshold: Int64 {
        get() {
            cycleThreshold_
        }
    }

    /**
     * 开启循环检测（`doc/05-agenda-conflict-resolution.md` §9）。
     *
     * 有额外开销，默认关闭；`Loop` 模式未配 `limit` 时建议开启。
     */
    public func enableCycleDetection(window!: Int64 = 10000): Unit {
        cycleEnabled_ = true
        cycleWindow_ = window
    }

    /** 校验失败时由构建器调用；进入 `Invalid` 后不可恢复。 */
    public func markInvalid(): Unit {
        status_ = RuleSetStatus.Invalid
    }

    /** 配置单次表达式求值超时（`EngineOptions.expressionTimeout`）。 */
    public func configureExpressionTimeout(value: Duration): Unit {
        failureGuard.setExpressionTimeout(value)
    }

    /** 观测用：规则当前的连续失败次数（成功一次即清零）。 */
    public func ruleFailureCount(ruleId: String): Int64 {
        failureGuard.failureCount(ruleId)
    }

    /** 该规则是否已因连续失败被禁用（规则集级）。 */
    public func ruleDisabled(ruleId: String): Bool {
        failureGuard.isDisabled(ruleId)
    }

    /** 观测用：最近一次失败的分类；成功求值后清空。 */
    public func lastFailureKind(ruleId: String): ?EvalFailureKind {
        failureGuard.lastFailureKind(ruleId)
    }

    /** 校验通过后冻结空间集合与类型描述。 */
    public func freeze(): Unit {
        registry.freeze()
    }

    /** 清空网络与缓存；重复调用幂等。 */
    public func close(): Unit {
        closed_ = true
    }
}
