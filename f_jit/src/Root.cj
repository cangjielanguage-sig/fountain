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

// 门面/桥层：用户面 API 的再导出点（见 doc/plan-m1.md §0.4、S0.1 / S6.11）。
//
// 用户面冻结（S6.11，design §7.3）：**只**导出下列声明。
// `JitContext` / `Engine` / `JitValue` / `CompileCache` / `AdapterRegistry` /
// `CompilePipeline` 等执行期内部类型一律不进用户面（根包内部按需普通 import）。
public import fountain::f_jit.base.JitException
public import fountain::f_jit.base.ErrCode
public import fountain::f_jit.base.SourceCompileException
public import fountain::f_jit.base.SourcePos
public import fountain::f_jit.base.JitMode
public import fountain::f_jit.base.DiagnosticsSink
public import fountain::f_jit.base.DiagnosticLevel
public import fountain::f_jit.base.DiagCode
public import fountain::f_jit.base.DummyDiagnosticsSink
// M2：PredefinedFunction 下沉到 base（PublicMethod.bind 需要），用户面路径不变
public import fountain::f_jit.base.PredefinedFunction
// M2 用户面：注册协议（`registerClass` / `registerType<T>()` 的入参与拒绝体例）。
// 缺这几条时用户 `import fountain::f_jit.*` 后写不出任何注册代码——GAP-01。
public import fountain::f_jit.base.ClassDescriptor
public import fountain::f_jit.base.PublicField
public import fountain::f_jit.base.PublicMethod
public import fountain::f_jit.base.JitBindings
public import fountain::f_jit.base.JitFieldBinding
public import fountain::f_jit.base.PublicCtor
public import fountain::f_jit.base.RegistrationException
public import fountain::f_jit.base.RegistrationRejectKind
// 注册协议的入参是**类型码**，用户写不出 `PublicField(type: …)` 就无法注册——
// `LocalType` 与上面六个同属用户面最小集（GAP-01 清单外补项）。
public import fountain::f_jit.base.LocalType
