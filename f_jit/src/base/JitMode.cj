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
 * 引擎选择开关（**输入侧「用户意图」**）—— design-m1 §2.3.6、plan-m1 S1.5、规格 §12.1。
 *
 * - `Off`：不产生机器码，直接走解释器；
 * - `Auto`：平台可用则 JIT（另以字节码指纹为缓存键）；
 * - `Force`：期望 JIT。
 *
 * **不可用一律静默降级**：非 Linux 平台与 SDK 未支持指令集下，`Force` 亦降级为解释器——
 * 接口与语义完全一致，只记 diagnostics，不报错、不改语义（§12.1 冻结决策、§9 附则 10）。
 * 因此 `JitMode`（配置）与 `Engine`（事实）是两条信息：失败时 `Engine = Interp` 而用户传入的
 * `JitMode` 不被改写（§2.3.6）。
 *
 * 可见性 `public`：它是 `CompileOptions.jit` 的类型，属用户面（design §7 再导出清单）。
 */
public enum JitMode <: Equatable<JitMode> {
    | Off
    | Auto
    | Force

    public operator func ==(other: JitMode): Bool {
        match (this) {
            case Off =>
                match (other) {
                    case Off => true
                    case _ => false
                }
            case Auto =>
                match (other) {
                    case Auto => true
                    case _ => false
                }
            case Force =>
                match (other) {
                    case Force => true
                    case _ => false
                }
        }
    }
}
