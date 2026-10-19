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
import fountain::f_jit.test.diff.InterpRunner
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
    public func constAdd(): Unit {
        X86Exec_test.check('X86/constAdd', '{ => 1 + 2 }', Array<Any>())
    }

    @TestCase
    public func identityArg(): Unit {
        X86Exec_test.check('X86/identity', '{ a: Int64 => a }', [41])
    }

    @TestCase
    public func argAddZero(): Unit {
        X86Exec_test.check('X86/addZero', '{ a: Int64 => a + 0 }', [41])
    }

    @TestCase
    public func branch(): Unit {
        X86Exec_test.check('X86/branch', '{ a: Int64 => if (a > 0) { 1 } else { 0 } }', [5])
    }

    @TestCase
    public func containerMutation(): Unit {
        X86Exec_test.check('X86/container', '{ => let l = [1, 2]\n l[0] = 3\n l[0] }',
            Array<Any>())
    }

    @TestCase
    public func recursiveCall(): Unit {
        X86Exec_test.check('X86/recursive',
            '{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }', [5])
    }

    @TestCase
    public func floatArithmetic(): Unit {
        X86Exec_test.check('X86/float', '{ a: Float64, b: Float64 => a * b + 1.0f64 }', [2.5, 4.0])
    }

    @TestCase
    public func divMod(): Unit {
        X86Exec_test.check('X86/divmod', '{ a: Int64 => a / 3 + a % 2 }', [17])
    }

    @TestCase
    public func floatToInt(): Unit {
        X86Exec_test.check('X86/cast', '{ x: Float64 => Int64(x) }', [3.9])
    }

    @TestCase
    public func closureCall(): Unit {
        X86Exec_test.check('X86/closure', '{ => let f = { x: Int64 => x + 1 }\n f(2) }',
            Array<Any>())
    }

    @TestCase
    public func listLen(): Unit {
        X86Exec_test.check('X86/len',
            '{ => let l = [1, 2, 3]\n var s = 0\n for (x in l) { s = s + x }\n s }', Array<Any>())
    }

    private static func check(id: String, src: String, args: Array<Any>): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        let c = DiffCase(id, cu.raw, args)
        let base = InterpRunner().run(c)
        let r = NativeRunner().run(c)
        @Assert(r.errCode, base.errCode)
        @Assert(r.site, base.site)
        @Assert(r.result, base.result)
    }
}
