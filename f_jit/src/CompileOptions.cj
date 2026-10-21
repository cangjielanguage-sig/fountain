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
package fountain::f_jit

import fountain::f_jit.base.JitMode
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.Version

/**
 * 编译配置（design §7.3.2、plan S6.1）。
 *
 * `jit` = 用户意图（Off/Auto/Force），`cpuFeatures` 预留给 M2，`diagnostics` 只收降级/告警。
 */
public class CompileOptions {
    public var jit: JitMode = JitMode.Auto
    public var cpuFeatures: UInt64 = 0
    /**
     * 源码产物的字节码主版本（X1）。
     *
     * 缺省 `Version.LATEST`；只允许 `Version.supportedMajors()` 内的值，其余在 `compile` 时
     * 以 `SourceCompileException` 拒绝。缓存键包含该值——同源不同版本必须产出独立单元。
     */
    public var verMajor: UInt16 = Version.LATEST
    /**
     * 严格浮点（X3）：决定 `Float64` 的 `/` 发 `FDIV`（÷0 得 ±Inf）还是 `FDIV_CHK`（÷0 → 1）。
     *
     * 这是**产物级**选项：同一份源码在两种配置下是两份独立产物，不存在「同一条指令两种行为」。
     */
    public var strictFp: Bool = false
    public let diagnostics: DiagnosticsSink

    public init(diagnostics: DiagnosticsSink) {
        this.diagnostics = diagnostics
    }
}
