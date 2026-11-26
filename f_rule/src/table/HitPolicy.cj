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
package fountain::f_rule.table

import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 命中策略（`doc/07-decision-table.md` §2）。
 *
 * `Unique` 零命中/多命中都抛错，其余策略零命中返回空；`First` 是默认值。
 * 策略不进入单条 `Rule`，由 [HitAggregator] 在收集行级输出后应用。
 */
public enum HitPolicy <: ToString & Equatable<HitPolicy> {
    /** 只允许一行命中。 */
    | Unique
    /** 按行序取第一行。 */
    | First
    /** 按 `outputOrder` 取最小。 */
    | Priority
    /** 多行命中时输出必须一致。 */
    | Any
    /** 收集全部命中，按行序。 */
    | Collect
    /** 收集全部命中，按 salience 降序。 */
    | RuleOrder
    /** 收集全部命中，按输出值升序。 */
    | OutputOrder

    public func toString(): String {
        match (this) {
            case Unique => "Unique"
            case First => "First"
            case Priority => "Priority"
            case Any => "Any"
            case Collect => "Collect"
            case RuleOrder => "RuleOrder"
            case OutputOrder => "OutputOrder"
        }
    }

    public operator func ==(other: HitPolicy): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: HitPolicy): Bool {
        !(this == other)
    }

    /** 解析表属性里的策略名，大小写不敏感；未知值抛 `TABLE_INVALID`。 */
    public static func parse(text: String): HitPolicy {
        match (text.trimAscii().toAsciiLower()) {
            case "unique" => HitPolicy.Unique
            case "first" => HitPolicy.First
            case "priority" => HitPolicy.Priority
            case "any" => HitPolicy.Any
            case "collect" => HitPolicy.Collect
            case "ruleorder" => HitPolicy.RuleOrder
            case "outputorder" => HitPolicy.OutputOrder
            case _ =>
                throw RuleException(
                    RuleErrorCode.TABLE_INVALID,
                    "未知的 hitPolicy: ${text}（允许 Unique/First/Priority/Any/Collect/RuleOrder/OutputOrder）"
                )
        }
    }
}
