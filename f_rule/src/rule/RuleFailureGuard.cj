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
import std.sync.Mutex
import fountain::f_rule.condition.EvalFailureKind

/**
 * 规则级求值健康状态（`doc/03-condition-expression.md` §6.2）。
 *
 * 计数与禁用位是**规则集级**的：键为 `(ruleSetId, ruleId)`，同一规则集的所有会话
 * 共享同一份状态。成功一次即清零「连续失败」计数；达到阈值后禁用位永久保留。
 */
public class RuleFailureGuard {
    /** 连续失败阈值（`doc/03` §6.2 固定 100）。 */
    public static let DEFAULT_THRESHOLD: Int64 = 100

    private let ruleSetId_: String
    private let threshold_: Int64
    private let mtx_: Mutex
    private let failures_: HashMap<String, Int64>
    private let disabled_: HashSet<String>
    private let lastKinds_: HashMap<String, EvalFailureKind>
    private var expressionTimeout_: Duration

    public init(ruleSetId: String, threshold!: Int64 = DEFAULT_THRESHOLD,
        expressionTimeout!: Duration = Duration.millisecond * 50) {
        this.ruleSetId_ = ruleSetId
        this.threshold_ = threshold
        this.mtx_ = Mutex()
        this.failures_ = HashMap<String, Int64>()
        this.disabled_ = HashSet<String>()
        this.lastKinds_ = HashMap<String, EvalFailureKind>()
        this.expressionTimeout_ = expressionTimeout
    }

    public prop ruleSetId: String {
        get() {
            ruleSetId_
        }
    }

    public prop threshold: Int64 {
        get() {
            threshold_
        }
    }

    /** 单次表达式求值超时（来自 `EngineOptions.expressionTimeout`）。 */
    public prop expressionTimeout: Duration {
        get() {
            synchronized(mtx_) {
                expressionTimeout_
            }
        }
    }

    public func setExpressionTimeout(value: Duration): Unit {
        synchronized(mtx_) {
            expressionTimeout_ = value
        }
    }

    /**
     * 记录一次求值失败；返回 `true` 表示本次刚好触发禁用。
     *
     * 禁用后仍保留计数与失败分类，便于诊断；后续不再累加（终端节点会先检查禁用位）。
     */
    public func recordFailure(ruleId: String, kind: EvalFailureKind): Bool {
        synchronized(mtx_) {
            let key = keyOf(ruleId)
            if (disabled_.contains(key)) {
                return false
            }
            let count = match (failures_.get(key)) {
                case Some(existing) => existing + 1
                case None => 1
            }
            failures_[key] = count
            lastKinds_[key] = kind
            if (count >= threshold_) {
                disabled_.add(key)
                return true
            }
            false
        }
    }

    /** 成功求值一次即清零连续失败计数；禁用位不受影响。 */
    public func recordSuccess(ruleId: String): Unit {
        synchronized(mtx_) {
            let key = keyOf(ruleId)
            let _ = failures_.remove(key)
            let _ = lastKinds_.remove(key)
        }
    }

    public func failureCount(ruleId: String): Int64 {
        synchronized(mtx_) {
            match (failures_.get(keyOf(ruleId))) {
                case Some(count) => count
                case None => 0
            }
        }
    }

    public func isDisabled(ruleId: String): Bool {
        synchronized(mtx_) {
            disabled_.contains(keyOf(ruleId))
        }
    }

    public func lastFailureKind(ruleId: String): ?EvalFailureKind {
        synchronized(mtx_) {
            lastKinds_[keyOf(ruleId)]
        }
    }

    /** 键显式包含规则集 id：状态按 `(ruleSetId, ruleId)` 归属。 */
    public func keyOf(ruleId: String): String {
        "${ruleSetId_}\u{0001}${ruleId}"
    }
}
