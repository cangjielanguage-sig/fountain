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

import fountain::f_rule.fact.Fact

/**
 * 条件操作数（`doc/03-condition-expression.md` §3）。
 *
 * `Bind` 只能出现在 `JoinConstraint` 中；`Constraint` 的右操作数只允许 `Const`
 * 或同事实的 `Field`（构建期由校验器把关）。
 */
public enum Operand <: ToString {
    /** 常量。 */
    | Const(Any)
    /** 同一模式内的字段。 */
    | Field(String)
    /** 前序模式的绑定字段，写法 `$o.amount`。 */
    | Bind(String, String)

    /** 在单事实上下文里解析；`Bind` 无法单事实解析，返回 None。 */
    public func resolve(fact: Fact): ?Any {
        match (this) {
            case Const(value) => Some(value)
            case Field(name) => fact.get(name)
            case Bind(_, _) => None
        }
    }

    /** 是否引用了另一个绑定。 */
    public func isBind(): Bool {
        match (this) {
            case Bind(_, _) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Const(_) => "const"
            case Field(name) => "\$${name}"
            case Bind(binding, field) => "\$${binding}.${field}"
        }
    }
}
