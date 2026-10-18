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
