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
package fountain::f_rule.agenda

import std.sync.AtomicInt64
import fountain::f_rule.rule.Rule

/**
 * 议程激活（`doc/05-agenda-conflict-resolution.md` §2）。
 *
 * 由终端节点产出：`factSpace + ruleId + bindings` 唯一确定一个激活；
 * `seq` 由构造顺序单调分配，只用于冲突消解的全序兜底，不参与判等。
 *
 * `sortKey()` 与测试基准 `NaiveActivation.sortKey()` 保持同一格式，
 * 差分测试依赖这一点逐条比对两侧激活集合。
 */
public class Activation <: Hashable & Equatable<Activation> & ToString {
    /** 计数走原子操作：激活产出是高频路径，互斥锁会成为瓶颈。 */
    private static let seqCounter = AtomicInt64(0)

    public let rule: Rule
    public let factSpace: String
    public let bindings: Bindings
    public let salience: Int64
    public let seq: Int64
    public let specificity: Int64
    /** 互斥组名；只影响调度，不参与 `key_`（相等键）。 */
    public let activationGroup: ?String
    private let key_: String

    public init(rule: Rule, bindings: Bindings) {
        this.rule = rule
        this.factSpace = rule.factSpace
        this.bindings = bindings
        this.salience = rule.salience
        this.seq = Activation.nextSeq()
        this.specificity = Activation.specificityOf(rule)
        this.activationGroup = rule.activationGroup
        this.key_ = "${rule.factSpace}|${rule.id}|${bindings.sortKey()}"
    }

    /** `specificity` = 模式数 + 约束总数，条件越多越具体。 */
    public static func specificityOf(rule: Rule): Int64 {
        var total = Int64(rule.patterns.size)
        for (pattern in rule.patterns) {
            total += Int64(pattern.constraints.size)
        }
        total
    }

    public prop ruleId: String {
        get() {
            rule.id
        }
    }

    /** 规则在规则集中的声明顺序。 */
    public prop ruleOrder: Int64 {
        get() {
            rule.order
        }
    }

    /** 稳定排序键，同时也是判等键。 */
    public func sortKey(): String {
        key_
    }

    public operator func ==(other: Activation): Bool {
        this.key_ == other.key_
    }

    public operator func !=(other: Activation): Bool {
        !(this == other)
    }

    public func hashCode(): Int64 {
        key_.hashCode()
    }

    public func toString(): String {
        "Activation(${key_})"
    }

    private static func nextSeq(): Int64 {
        seqCounter.fetchAdd(1) + 1
    }
}
