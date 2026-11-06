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

/**
 * 条件算子（`doc/03-condition-expression.md` §2）。
 *
 * 名称为稳定字符串：决策表错误定位与日志都依赖它，改名等同于破坏兼容性。
 */
public enum Operator <: ToString & Hashable & Equatable<Operator> {
    | Eq
    | Ne
    | Gt
    | Ge
    | Lt
    | Le
    | Contains
    | StartsWith
    | EndsWith
    | In
    | NotIn
    | IsNull
    | NotNull
    | Matches
    | Between

    public func toString(): String {
        match (this) {
            case Eq => "Eq"
            case Ne => "Ne"
            case Gt => "Gt"
            case Ge => "Ge"
            case Lt => "Lt"
            case Le => "Le"
            case Contains => "Contains"
            case StartsWith => "StartsWith"
            case EndsWith => "EndsWith"
            case In => "In"
            case NotIn => "NotIn"
            case IsNull => "IsNull"
            case NotNull => "NotNull"
            case Matches => "Matches"
            case Between => "Between"
        }
    }

    public func hashCode(): Int64 {
        "fountain::f_rule.condition.Operator.${this}".hashCode()
    }

    public operator func ==(other: Operator): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: Operator): Bool {
        !(this == other)
    }

    /** 是否可走 alpha 索引（`doc/03` §2 的"可索引"列）。 */
    public prop indexable: Bool {
        get() {
            match (this) {
                case Eq => true
                case Gt | Ge | Lt | Le => true
                case In => true
                case IsNull | NotNull => true
                case Between => true
                case _ => false
            }
        }
    }

    /** 是否为排序类算子：跨域时必须报 `TYPE_MISMATCH`。 */
    public prop ordering: Bool {
        get() {
            match (this) {
                case Gt | Ge | Lt | Le => true
                case Between => true
                case _ => false
            }
        }
    }
}
