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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.NativeRunner

/**
 * x86_64 执行冒烟（仅原生 x86_64 执行；其余平台跳过并计入「非原生跳过」）。
 *
 * 覆盖 `X86Compiler` 产物的真实执行：最小单元 / 算术 / 分支。
 */
@When[arch == 'x86_64' && os == 'Linux']
@Test
public class X86Exec_test {
    @TestCase
    public func minimalUnit(): Unit {
        X86Exec_test.check('X86/min', '{ => 1 }', Array<Any>())
    }

    @TestCase
    public func arithmetic(): Unit {
        X86Exec_test.check('X86/add', '{ a: Int64 => a + 1 }', [41])
    }

    @TestCase
    public func branch(): Unit {
        X86Exec_test.check('X86/branch', '{ a: Int64 => if (a > 0) { 1 } else { 0 } }', [5])
    }

    private static func check(id: String, src: String, args: Array<Any>): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        let r = NativeRunner().run(DiffCase(id, cu.raw, args))
        @Assert(r.errCode, 0)
        @Assert(r.result.size > 0, true)
    }
}
