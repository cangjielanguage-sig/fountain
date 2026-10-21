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
 * 降级 / 告警接收器 —— design-m1 §2.3.7（D1 结案）、spec「诊断接口与空实现」。
 *
 * 两个入口：
 *
 * - `diag(level, code, message)`：**主签名（结构化入口）**，携带**稳定事件码**；
 * - `diag(level, message)`：便捷入口，**默认实现**以 `code = Unspecified` 转发主签名
 *   （实现方可改写）。
 *
 * 契约（§2.3.7）：
 *
 * 1. **不承担错误通道**：`diag` 只收降级/告警；编译/调用失败一律异常。
 * 2. **不承诺串行化**：`diag` 可能在并发 `compile` 的不同线程上被调用，**线程安全由实现方负责**
 *    ——本模块不加锁、不排队。
 * 3. **sink 异常由引擎吞掉**：有在途异常 ⇒ `在途.addSuppressed(sinkEx)`；无在途异常 ⇒ 仅吞掉；
 *    `Error`（灾难性）**不捕、不吞**；**不重入 diag**。
 */
public interface DiagnosticsSink {
    /** 主签名：结构化入口（level + 稳定事件码 + 自由文本）。 */
    func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit

    /** 便捷入口：默认以 `Unspecified` 码转发主签名。 */
    func diag(level: DiagnosticLevel, message: String): Unit {
        this.diag(level, DiagCode.Unspecified, message)
    }
}
