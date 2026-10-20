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
package fountain::f_jit.surface

import std.unittest.*
import std.unittest.testmacro.*
// **只导根包**：本文件是 GAP-01 的用户面探针——注册协议的全部类型都必须经
// `fountain::f_jit` 的再导出可见。放在**独立包**（而非根包或 test 包）的原因：
// 根包内的文件可以自己 `import …base.*`（那样测不出再导出缺失，M1 的
// `BaseVisibility_test` 正是如此）；test 包与根包已有循环依赖。
import fountain::f_jit.*

/**
 * GAP-01：只 `import fountain::f_jit.*` 就能完成一次手工注册。
 *
 * 用户面最小集 = `Compiler` / `CompileOptions`（根包直接声明）+ `ClassDescriptor` /
 * `PublicField` / `PublicMethod` / `PublicCtor` / `RegistrationException` /
 * `RegistrationRejectKind` / `LocalType`（经根包再导出）。缺任一条本文件即编译失败。
 */
@Test
public class FacadeSurface_test {
    @TestCase
    public func canRegisterThroughRootImportOnly(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let field = PublicField(name: 'id', `type`: LocalType.I64, index: 0u16,
            mutable: false, typeRef: None)
        let bind = PredefinedFunction('Smoke.bump', [LocalType.HOST_OBJECT, LocalType.I64],
            LocalType.UNIT, { _ => () })
        let method = PublicMethod(name: 'bump', bind: bind)
        let ctor = PublicCtor(params: [LocalType.STRING],
            adapter: { a => match (a[0]) { case s: String => s; case _ => '' } })
        let desc = ClassDescriptor(name: 'SmokeUser', fields: [field], methods: [method],
            ctors: [ctor])
        c.registerClass(desc)
        @Assert(c.hasClass('SmokeUser'), true)

        // 拒绝体例同样要能在用户面捕获并读出 kind
        var kind: ?RegistrationRejectKind = None
        try {
            c.registerClass(desc)
        } catch (e: RegistrationException) {
            kind = Some(e.kind)
        }
        @Assert(match (kind) {
            case Some(k) => k == RegistrationRejectKind.DuplicateClass
            case None => false
        }, true)
    }
}
