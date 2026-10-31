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

import fountain::f_rule.condition.ExpressionMode
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
    private var status_: RuleSetStatus
    private var closed_: Bool

    public init(id: String, version: String, rules: Array<Rule>, registry: FactSpaceRegistry,
        expressionMode: ExpressionMode, conflictResolver: ConflictResolver) {
        this.id = id
        this.version = version
        this.rules = rules
        this.registry = registry
        this.expressionMode = expressionMode
        this.conflictResolver = conflictResolver
        this.status_ = RuleSetStatus.Valid
        this.closed_ = false
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

    /** 校验失败时由构建器调用；进入 `Invalid` 后不可恢复。 */
    public func markInvalid(): Unit {
        status_ = RuleSetStatus.Invalid
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
