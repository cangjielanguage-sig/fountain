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

/**
 * 编译配置（design §7.3.2、plan S6.1）。
 *
 * `jit` = 用户意图（Off/Auto/Force），`cpuFeatures` 预留给 M2，`diagnostics` 只收降级/告警。
 */
public class CompileOptions {
    public var jit: JitMode = JitMode.Auto
    public var cpuFeatures: UInt64 = 0
    public let diagnostics: DiagnosticsSink

    public init(diagnostics: DiagnosticsSink) {
        this.diagnostics = diagnostics
    }
}
