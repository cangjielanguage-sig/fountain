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

/**
 * 冲突消解的排序键（`doc/05-agenda-conflict-resolution.md` §2）。
 *
 * 声明在 `rule` 包是为了让 `RuleSet` 能保存解析器而不反向依赖 `agenda`；
 * `agenda` 的 `Activation` 在比较时构造本类型。
 */
public class ConflictKey {
    public let salience: Int64
    public let specificity: Int64
    public let ruleOrder: Int64
    public let seq: Int64
    public let factSpace: String
    public let ruleId: String

    public init(salience: Int64, specificity: Int64, ruleOrder: Int64, seq: Int64,
        factSpace: String, ruleId: String) {
        this.salience = salience
        this.specificity = specificity
        this.ruleOrder = ruleOrder
        this.seq = seq
        this.factSpace = factSpace
        this.ruleId = ruleId
    }
}

/**
 * 冲突消解策略。
 *
 * `compare` 返回 `Ordering.LT` 表示 **left 先执行**（与堆的最小序一致）。
 * 组合策略必须给出全序（任意两个不同激活比较不为 `EQ`），见用例 A-04。
 */
public interface ConflictResolver {
    func compare(left: ConflictKey, right: ConflictKey): Ordering
}

/**
 * 默认链：`salience ↓ → specificity ↓ → ruleOrder ↑ → seq ↑`。
 *
 * 最后用 `(factSpace, ruleId)` 兜底，保证不同规则之间也有确定顺序。
 */
public class DefaultConflictResolver <: ConflictResolver {
    public init() {}

    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        var result = compareDesc(left.salience, right.salience)
        if (result != Ordering.EQ) {
            return result
        }
        result = compareDesc(left.specificity, right.specificity)
        if (result != Ordering.EQ) {
            return result
        }
        result = compareAsc(left.ruleOrder, right.ruleOrder)
        if (result != Ordering.EQ) {
            return result
        }
        result = compareAsc(left.seq, right.seq)
        if (result != Ordering.EQ) {
            return result
        }
        result = compareAsc(left.factSpace, right.factSpace)
        if (result != Ordering.EQ) {
            return result
        }
        compareAsc(left.ruleId, right.ruleId)
    }

    private static func compareDesc(a: Int64, b: Int64): Ordering {
        if (a == b) {
            Ordering.EQ
        } else if (a > b) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func compareAsc(a: Int64, b: Int64): Ordering {
        if (a == b) {
            Ordering.EQ
        } else if (a < b) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }

    private static func compareAsc(a: String, b: String): Ordering {
        if (a == b) {
            Ordering.EQ
        } else if (a < b) {
            Ordering.LT
        } else {
            Ordering.GT
        }
    }
}
