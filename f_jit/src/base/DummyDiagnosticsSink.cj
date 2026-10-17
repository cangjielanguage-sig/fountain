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
 * `DiagnosticsSink` 的**空实现** —— design-m1 §2.3.7、plan-m1 S1.10。
 *
 * 两个入口皆空操作；`CompileOptions` 未显式传入 sink 时的默认值，兼测试用。
 * 只重写主签名即可——便捷重载的默认实现转发到主签名后同样是空操作。
 */
public class DummyDiagnosticsSink <: DiagnosticsSink {
    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {}
}
