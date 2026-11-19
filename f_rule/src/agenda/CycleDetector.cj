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

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 环形指纹窗口（`doc/05-agenda-conflict-resolution.md` §9，A-11）。
 *
 * 记录最近 `window` 个激活的 `(factSpace, ruleId, bindings)` 指纹；同一指纹在窗口内
 * 出现次数达到 `threshold` 后，下一次出现立即抛 `CYCLE_LIMIT`。
 *
 * `window` 必须大于 `threshold` 才能触发——窗口比阈值小意味着旧记录一直在被淘汰，
 * 计数永远到不了阈值。这是配置错误，构造期直接拒绝。
 */
public class CycleDetector {
    private let window_: Int64
    private let threshold_: Int64
    private let order_: ArrayList<String>
    private let counts_: HashMap<String, Int64>

    public init(window!: Int64 = 10000, threshold!: Int64 = 100) {
        if (window < 1) {
            throw RuleException(RuleErrorCode.ILLEGAL_STATE, "循环检测窗口必须为正数: ${window}")
        }
        if (threshold < 1) {
            throw RuleException(RuleErrorCode.ILLEGAL_STATE, "循环检测阈值必须为正数: ${threshold}")
        }
        this.window_ = window
        this.threshold_ = threshold
        this.order_ = ArrayList<String>()
        this.counts_ = HashMap<String, Int64>()
    }

    public prop window: Int64 {
        get() {
            window_
        }
    }

    public prop threshold: Int64 {
        get() {
            threshold_
        }
    }

    /** 记录一次激活；达到阈值时抛 `CYCLE_LIMIT`。 */
    public func record(activation: Activation): Unit {
        let key = activation.sortKey()
        let current = match (counts_.get(key)) {
            case Some(found) => found
            case None => 0
        }
        if (current >= threshold_) {
            throw RuleException(
                RuleErrorCode.CYCLE_LIMIT,
                "激活指纹在窗口 ${window_} 内重复超过 ${threshold_} 次: ${key}"
            )
        }
        counts_[key] = current + 1
        order_.add(key)
        if (order_.size > window_) {
            let evicted = order_[0]
            order_.remove(at: 0)
            let remaining = match (counts_.get(evicted)) {
                case Some(found) => found - 1
                case None => 0
            }
            if (remaining <= 0) {
                let _ = counts_.remove(evicted)
            } else {
                counts_[evicted] = remaining
            }
        }
    }

    public func reset(): Unit {
        order_.clear()
        counts_.clear()
    }
}
