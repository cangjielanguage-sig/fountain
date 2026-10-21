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
 * 诊断**稳定事件码** —— design-m1 §2.3.7（D1 结案）。
 *
 * | 码 | 事件 | 锚点 |
 * |---|---|---|
 * | `JitFallback` | 引擎降级：非 Linux / 架构不支持 | §12.1、T7 |
 * | `MmapFailed` | 代码内存分配失败降级 | §12.5 |
 * | `RegistrationSkipped` | 注册跳过（成员名冲突等） | M2 / M3 |
 * | `PredefinedLimit` | 预定义函数注册上限 | M2 |
 * | `PlanFallback` | 特化冷路径回退 | M3 |
 * | `Unspecified` | 便捷重载 `diag(level, message)` 的默认码 | §2.3.7 |
 *
 * `message` 是**自由文本、不冻结**（改文案不算破坏兼容）；供断言与匹配的是
 * `level` + `code`（T7 断言 = 存在 `(Warn, JitFallback)`），因此本类型实现 `Equatable`。
 */
public enum DiagCode <: Equatable<DiagCode> {
    | JitFallback
    | MmapFailed
    | RegistrationSkipped
    | PredefinedLimit
    | PlanFallback
    | Unspecified

    public operator func ==(other: DiagCode): Bool {
        match (this) {
            case JitFallback =>
                match (other) {
                    case JitFallback => true
                    case _ => false
                }
            case MmapFailed =>
                match (other) {
                    case MmapFailed => true
                    case _ => false
                }
            case RegistrationSkipped =>
                match (other) {
                    case RegistrationSkipped => true
                    case _ => false
                }
            case PredefinedLimit =>
                match (other) {
                    case PredefinedLimit => true
                    case _ => false
                }
            case PlanFallback =>
                match (other) {
                    case PlanFallback => true
                    case _ => false
                }
            case Unspecified =>
                match (other) {
                    case Unspecified => true
                    case _ => false
                }
        }
    }
}
