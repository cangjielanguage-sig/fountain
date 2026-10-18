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
import fountain::f_jit.backend.JitCompiler
import fountain::f_jit.backend.CodeBuffer
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.runtime.JitContext

/**
 * S5.8/S5.9 原生执行：源码 → 字节码 → AArch64 机器码 → 直接调用。
 *
 * 仅在 aarch64 Linux 有意义（本机即原生架构）。
 */
@Test
public class A64Exec_test {
    @TestCase
    public func minimalUnitReturnsOne(): Unit {
        @Assert(A64Exec_test.run('{ => 1 }', Array<Int64>()), 1)
    }

    @TestCase
    public func integerArithmetic(): Unit {
        @Assert(A64Exec_test.run('{ => 3 + 4 }', Array<Int64>()), 7)
        @Assert(A64Exec_test.run('{ => 9 - 4 }', Array<Int64>()), 5)
        @Assert(A64Exec_test.run('{ => 3 * 4 }', Array<Int64>()), 12)
        @Assert(A64Exec_test.run('{ => 7 / 2 }', Array<Int64>()), 3)
        @Assert(A64Exec_test.run('{ => 7 % 2 }', Array<Int64>()), 1)
    }

    @TestCase
    public func argumentsAndBranches(): Unit {
        @Assert(A64Exec_test.run('{ n: Int64 => n + 1 }', [41]), 42)
        @Assert(A64Exec_test.run('{ n: Int64 => n * n }', [9]), 81)
        @Assert(A64Exec_test.run('{ n: Int64 => if (n > 0) { 10 } else { 20 } }', [1]), 10)
        @Assert(A64Exec_test.run('{ n: Int64 => if (n > 0) { 10 } else { 20 } }', [-1]), 20)
        @Assert(A64Exec_test.run('{ => if (3 < 5) { 1 } else { 0 } }', Array<Int64>()), 1)
    }

    @TestCase
    public func floatArithmetic(): Unit {
        // 1.5 + 2.5 = 4.0 → 位型 0x4010000000000000
        @Assert(A64Exec_test.run('{ => 1.5f64 + 2.5f64 }', Array<Int64>()), 0x4010000000000000)
        // 1.5 * 2.0 = 3.0 → 0x4008000000000000
        @Assert(A64Exec_test.run('{ => 1.5f64 * 2.0f64 }', Array<Int64>()), 0x4008000000000000)
    }

    /** 编译并直接调用；断言 errCode 为 0，返回 x0。 */
    private static func run(src: String, args: Array<Int64>): Int64 {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        let unit = FbcReader.load(cu.raw)
        var result: Int64 = -1
        if (let Some(art) <- JitCompiler.compileUnit(unit)) {
            if (let Some(code) <- art.codeOf(cu.entryFn)) {
                if (let Some(buf) <- CodeBuffer.alloc(code.size + 16)) {
                @Assert(buf.write(code, 0), true)
                @Assert(buf.seal(), true)
                buf.flushICache()
                let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: Int64(cu.entryFn), dbgBase: 0)
                let argsPtr = A64Exec_test.argsPointer(args)
                let f = CFunc<(CPointer<Unit>, CPointer<Int64>, Int64) -> Int64>(
                    CPointer<Unit>(buf.rawPointer()))
                result = unsafe { f(CPointer<Unit>(ctx.cp()), argsPtr, args.size) }
                @Assert(unsafe { ctx.cp().read(0) }, 0)
                if (args.size > 0) {
                    unsafe { LibC.free<Int64>(argsPtr) }
                }
                    JitContext.free(ctx)
                    buf.free()
                } else {
                    @Fail('CodeBuffer.alloc 失败')
                }
            } else {
                @Fail('JitArtifacts.codeOf 返回 None')
            }
        } else {
            @Fail('JitCompiler.compileUnit 返回 None')
        }
        result
    }

    private static func argsPointer(args: Array<Int64>): CPointer<Int64> {
        if (args.size == 0) {
            return CPointer<Int64>()
        }
        let p = LibC.malloc<Int64>(count: args.size)
        var i = 0
        while (i < args.size) {
            unsafe { p.write(i, args[i]) }
            i = i + 1
        }
        p
    }
}
