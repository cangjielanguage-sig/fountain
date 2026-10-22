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
package fountain::f_jit.base

/**
 * 诊断级别 —— design-m1 §2.3.7（D1 结案）：`Info | Warn`，**只有两档**。
 *
 * **错误一律走异常**（`SourceCompileException` / `JitException`），**走不到 diag**——这是
 * 「diag 不承担错误通道」这条契约（§2.3.7 契约 1）在类型层的落点：没有 `Error` 档，
 * 也就不存在「诊断替代异常」的写法。
 *
 * 实现 `Equatable` 是为了让 T7 之类的断言能直接写「存在 `(Warn, JitFallback)` 事件」
 * （§2.3.7 末段：供断言/匹配的是 `level` + `code`，**不匹配 message 文本**）。
 */
public enum DiagnosticLevel <: Equatable<DiagnosticLevel> {
    | Info
    | Warn

    public operator func ==(other: DiagnosticLevel): Bool {
        match (this) {
            case Info =>
                match (other) {
                    case Info => true
                    case _ => false
                }
            case Warn =>
                match (other) {
                    case Warn => true
                    case _ => false
                }
        }
    }
}
