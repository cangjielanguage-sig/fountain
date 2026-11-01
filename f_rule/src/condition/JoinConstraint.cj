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
package fountain::f_rule.condition

import std.collection.HashMap
import fountain::f_rule.fact.Fact

/**
 * 跨模式连接约束（`doc/03-condition-expression.md` §4）。
 *
 * 两侧都是绑定名 + 字段；绑定在规则内解析，任一绑定缺失都视为 `Unknown`
 * （不产生激活），而不是抛错——运行期事实可能尚未齐备。
 */
public class JoinConstraint {
    public let leftBinding: String
    public let leftField: String
    public let op: Operator
    public let rightBinding: String
    public let rightField: String

    public init(leftBinding: String, leftField: String, op: Operator,
        rightBinding: String, rightField: String) {
        this.leftBinding = leftBinding
        this.leftField = leftField
        this.op = op
        this.rightBinding = rightBinding
        this.rightField = rightField
    }

    public func eval(bindings: HashMap<String, Fact>): Truth {
        let left = match (bindings.get(leftBinding)) {
            case Some(fact) => fact.get(leftField)
            case None => return Truth.Unknown
        }
        let right = match (bindings.get(rightBinding)) {
            case Some(fact) => fact.get(rightField)
            case None => return Truth.Unknown
        }
        OperatorEvaluator.apply(op, left, right)
    }

    /**
     * 用解析函数取绑定事实。
     *
     * Rete 的 join 热路径不需要完整绑定表（令牌只持有父链 + 事实），
     * 这个重载避免为每次候选判定构造 `HashMap`。
     */
    public func evalWith(resolve: (String) -> ?Fact): Truth {
        let left = match (resolve(leftBinding)) {
            case Some(fact) => fact.get(leftField)
            case None => return Truth.Unknown
        }
        let right = match (resolve(rightBinding)) {
            case Some(fact) => fact.get(rightField)
            case None => return Truth.Unknown
        }
        OperatorEvaluator.apply(op, left, right)
    }

    public func toString(): String {
        "\$${leftBinding}.${leftField} ${op} \$${rightBinding}.${rightField}"
    }
}
