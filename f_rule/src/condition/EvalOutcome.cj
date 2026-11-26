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
 * 一次表达式求值的结果分类（`doc/03-condition-expression.md` §6.2）。
 *
 * `Evaluated` 表示表达式正常执行完毕（结果 true/false）；其余三种都按 `Unknown`
 * 处理，由终端节点记录失败并累加规则级计数器。
 */
public enum EvalFailureKind <: ToString & Equatable<EvalFailureKind> {
    | Evaluated
    | Timeout
    | TypeMismatch
    | RuntimeFailure

    public func toString(): String {
        match (this) {
            case Evaluated => "Evaluated"
            case Timeout => "Timeout"
            case TypeMismatch => "TypeMismatch"
            case RuntimeFailure => "RuntimeFailure"
        }
    }

    public operator func ==(other: EvalFailureKind): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: EvalFailureKind): Bool {
        !(this == other)
    }
}

/** 求值结果：正常值时 [value] 有效；失败时 [kind]/[detail] 描述原因。 */
public class EvalOutcome {
    public let value: Bool
    public let kind: EvalFailureKind
    public let detail: String

    public init(value: Bool, kind: EvalFailureKind, detail: String) {
        this.value = value
        this.kind = kind
        this.detail = detail
    }

    public static func evaluated(value: Bool): EvalOutcome {
        EvalOutcome(value, EvalFailureKind.Evaluated, "")
    }

    public static func failed(kind: EvalFailureKind, detail: String): EvalOutcome {
        EvalOutcome(false, kind, detail)
    }

    public func isFailure(): Bool {
        kind != EvalFailureKind.Evaluated
    }
}

/** 解释器内部超时信号；不对外暴露，由 [EvalOutcome] 归类为 `Timeout`。 */
class ExpressionTimeoutException <: Exception {
    init() {
        super("表达式求值超时")
    }
}
