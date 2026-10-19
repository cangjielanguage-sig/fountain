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
import fountain::f_jit.backend.X86Compiler
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.bytecode.FbcReader

/** S5.4/S5.5–S5.7：x86 分支/容器/递归单元的组装层验收（字节级，不执行）。 */
@Test
public class X86Compile_test {
    @TestCase
    public func branchCompiles(): Unit {
        let code = X86Compile_test.compile('{ n: Int64 => if (n > 0) { 10 } else { 20 } }', 0)
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func containerCompilesWithConstMirror(): Unit {
        let code = X86Compile_test.compile(
            '{ => let l = [1, 2]\n l[0] = 3\n l[0] }', 0x1000)
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func recursiveCompilesWithFnTable(): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(
            '{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }')
        let unit = FbcReader.load(cu.raw)
        let fn = unit.dir.get(cu.entryFn)
        let code = match (X86Compiler.compileFunctionWith(unit, fn, 0, 0x2000)) {
            case Some(b) => b
            case None => Array<UInt8>()
        }
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func floatAndCompareCompiles(): Unit {
        let code = X86Compile_test.compile(
            '{ a: Float64, b: Float64 => if (a * b > 1.0f64) { a + b } else { a - b } }', 0)
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func divModCompiles(): Unit {
        let code = X86Compile_test.compile('{ a: Int64 => a / 3 + a % 2 }', 0)
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func castCompiles(): Unit {
        let code = X86Compile_test.compile('{ x: Float64 => Int64(x) }', 0)
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func closureCompiles(): Unit {
        let code = X86Compile_test.compile(
            '{ => let f = { x: Int64 => x + 1 }\n f(2) }', 0)
        @Assert(code.size > 0, true)
    }

    @TestCase
    public func lenCompiles(): Unit {
        let code = X86Compile_test.compile(
            '{ => let l = [1, 2, 3]\n var s = 0\n for (x in l) { s = s + x }\n s }', 0x1000)
        @Assert(code.size > 0, true)
    }

    /** 溢出检查必须是 JNO（未溢出继续），不能是 JO（否则正常值全部误报 3）。 */
    @TestCase
    public func checkedArithmeticUsesJno(): Unit {
        let add = X86Compile_test.hex(X86Compile_test.compile('{ a: Int64 => a + 1 }', 0))
        @Assert(add.contains('480304240F81'), true)
        let mul = X86Compile_test.hex(X86Compile_test.compile('{ a: Int64 => a * a }', 0))
        @Assert(mul.contains('480FAF04240F81'), true)
        let neg = X86Compile_test.hex(X86Compile_test.compile('{ a: Int64 => -a }', 0))
        @Assert(neg.contains('48F7D80F81'), true)
    }

    /** ctx 字段（fnId/site）必须 64 位写，避免高 32 位残留。 */
    @TestCase
    public func ctxStoresAreQword(): Unit {
        let code = X86Compile_test.hex(X86Compile_test.compile('{ a: Int64 => a / 3 }', 0))
        @Assert(code.contains('49C74728'), true)
        @Assert(code.contains('49C74708'), true)
    }

    @TestCase
    public func goldenFloatDivCastClosureLen(): Unit {
        let fadd = X86Compile_test.hex(X86Compile_test.compile(
            '{ a: Float64, b: Float64 => a + b }', 0))
        @Assert(fadd.contains('F20F10'), true)
        @Assert(fadd.contains('F20F58842408000000'), true)

        let idiv = X86Compile_test.hex(X86Compile_test.compile('{ a: Int64 => a / 3 }', 0))
        @Assert(idiv.contains('48F7F9'), true)
        @Assert(idiv.contains('4883F9FF'), true)

        let imod = X86Compile_test.hex(X86Compile_test.compile('{ a: Int64 => a % 3 }', 0))
        @Assert(imod.contains('48F7F9'), true)
        @Assert(imod.contains('31D2'), true)

        let cast = X86Compile_test.hex(X86Compile_test.compile('{ x: Float64 => Int64(x) }', 0))
        @Assert(cast.contains('F2480F2CC0'), true)
        @Assert(cast.contains('000000000000E043'), true)

        let clo = X86Compile_test.hex(X86Compile_test.compile(
            '{ => let f = { x: Int64 => x + 1 }\n f(2) }', 0))
        @Assert(clo.contains('48BF3700000000000000'), true) // H55
        @Assert(clo.contains('48BF3900000000000000'), true) // H57
        @Assert(clo.contains('488B04C1'), true) // fnTable[fnId]

        let len = X86Compile_test.hex(X86Compile_test.compile(
            '{ => let l = [1, 2]\n var s = 0\n for (x in l) { s = s + x }\n s }', 0x1000))
        @Assert(len.contains('48BF1200000000000000'), true) // H18 type_of
        @Assert(len.contains('48BF0100000000000000'), true) // H01 list_len
        @Assert(len.contains('48BF0300000000000000'), true) // H03 map_len
        @Assert(len.contains('48BF0700000000000000'), true) // H07 str_len
    }

    private static func hex(bs: Array<UInt8>): String {
        var s = ''
        for (b in bs) {
            let v = Int64(b)
            let hi = v / 16
            let lo = v % 16
            s = s + X86Compile_test.nib(hi) + X86Compile_test.nib(lo)
        }
        s
    }

    private static func nib(v: Int64): String {
        match (v) {
            case 0 => '0'
            case 1 => '1'
            case 2 => '2'
            case 3 => '3'
            case 4 => '4'
            case 5 => '5'
            case 6 => '6'
            case 7 => '7'
            case 8 => '8'
            case 9 => '9'
            case 10 => 'A'
            case 11 => 'B'
            case 12 => 'C'
            case 13 => 'D'
            case 14 => 'E'
            case _ => 'F'
        }
    }

    private static func compile(src: String, constBase: Int64): Array<UInt8> {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        let unit = FbcReader.load(cu.raw)
        let fn = unit.dir.get(cu.entryFn)
        match (X86Compiler.compileFunctionWith(unit, fn, constBase, 0)) {
            case Some(b) => b
            case None => Array<UInt8>()
        }
    }
}
