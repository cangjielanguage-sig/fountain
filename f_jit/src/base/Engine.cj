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
 * 实际引擎（**输出侧「实际事实」**）—— design-m1 §2.3.6、plan-m1 S1.5、规格 §12.1。
 *
 * 与 `JitMode` 的分离是刻意的：`Force` 成功时二者同为 JIT；失败时 `Engine = Interp` 而用户传入的
 * `JitMode` 不被改写——「配置」与「事实」是两条信息，缺后者就无法断言降级是否真的发生（§2.3.6）。
 *
 * **可见性 `protected`（design D2 / §8.7 D6 结案）**：产出者 `BackendSelector.select`（§6.3.4），
 * 消费者是 diagnostics 记录、模块内测试断言与 `JitFunction` 内部状态；**用户面无消费路径** ⇒
 * 只到模块级可见，**不随根包 `public import` 进用户面**。用户要感知降级只能经 diagnostics 的
 * `(Warn, JitFallback)` 事件（§2.3.7）。
 */
protected enum Engine <: Equatable<Engine> {
    | Interp
    | Jit

    public operator func ==(other: Engine): Bool {
        match (this) {
            case Interp =>
                match (other) {
                    case Interp => true
                    case _ => false
                }
            case Jit =>
                match (other) {
                    case Jit => true
                    case _ => false
                }
        }
    }
}
