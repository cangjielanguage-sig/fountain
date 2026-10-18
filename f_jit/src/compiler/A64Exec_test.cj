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
import fountain::f_jit.backend.A64Compiler
import fountain::f_jit.backend.CodeBuffer
import fountain::f_jit.backend.FnTable
import fountain::f_jit.backend.ConstMirror
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.runtime.HelperAddresses
import fountain::f_jit.runtime.h_dispatch
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.MachineEnv
import fountain::f_jit.runtime.Interp

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

    @TestCase
    public func helperDispatchTrampoline(): Unit {
        let addr = HelperAddresses.dispatch()
        @Assert(addr != 0, true)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let f: CFunc<(Int64, CPointer<Unit>, CPointer<Int64>, Int64) -> Int64> = h_dispatch
        let r = unsafe { f(22, CPointer<Unit>(ctx.cp()), CPointer<Int64>(), 0) }
        @Assert(r, 0)
        JitContext.free(ctx)
    }

    /** S5.9：`PUSH_KH` 常量镜像 —— JIT 与解释器取到同一句柄。 */
    @TestCase
    public func constantHandleMirror(): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile('{ => "hi" }')
        let unit = FbcReader.load(cu.raw)
        @Assert(unit.consts.size > 0, true)
        let interp = Interp(unit)
        let ids = Array<Int64>(unit.consts.size, repeat: 0)
        var i = 0
        while (i < unit.consts.size) {
            ids[i] = interp.constHandle(i)
            i = i + 1
        }
        let mirror = ConstMirror.build(ids)
        @Assert(mirror.base() != 0, true)
        let (r, err) = A64Exec_test.runUnit(cu, mirror.base(), Array<Int64>())
        @Assert(err, 0)
        @Assert(r != 0, true)
        // JIT 取到的句柄必须命中本单元常量句柄之一（同一 pinConst 结果）
        var hit = false
        i = 0
        while (i < unit.consts.size) {
            if (ids[i] == r) {
                hit = true
            }
            i = i + 1
        }
        @Assert(hit, true)
        mirror.free()
    }

    /** S5.9：`FPCR.DN=1` —— 0/0 的 NaN 位型收敛到 canonical。 */
    @TestCase
    public func nanCanonicalizedByHardware(): Unit {
        let (r, err) = A64Exec_test.run2('{ => 0.0f64 / 0.0f64 }', Array<Int64>())
        @Assert(err, 0)
        @Assert(r, 0x7FF8000000000000)
    }

    /** S5.9：闭包值调用（H54/H55/H57 + `CALL_CLOSURE`）。 */
    @TestCase
    public func closureCall(): Unit {
        let (r, err) = A64Exec_test.run2('{ => let f = { x: Int64 => x + 1 }\n f(41) }', Array<Int64>())
        @Assert(err, 0)
        @Assert(r, 42)
    }

    /** S5.9：`LOAD_CAP` 捕获外层实参。 */
    @TestCase
    public func capturedUpvalue(): Unit {
        let (r, err) = A64Exec_test.run2(
            '{ a: Int64 => let f = { b: Int64 => a + b }\n f(2) }', [40])
        @Assert(err, 0)
        @Assert(r, 42)
    }

    /** S5.10：跳板模式（第二遍布局）可编译分支函数。 */
    @TestCase
    public func trampolineLayoutCompiles(): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(
            '{ n: Int64 => if (n > 0) { 10 } else { 20 } }')
        let unit = FbcReader.load(cu.raw)
        @Assert(A64Compiler.compileFunctionFar(unit, unit.entry(), 0, 0).isSome(), true)
    }

    /** S5.10：跳板模式执行语义与短距模式一致。 */
    @TestCase
    public func farCondSemanticsMatchNear(): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(
            '{ n: Int64 => if (n > 0) { 10 } else { 20 } }')
        let unit = FbcReader.load(cu.raw)
        let code = match (A64Compiler.compileFunctionFar(unit, unit.entry(), 0, 0)) {
            case Some(b) => b
            case None => @Fail('compileFunctionFar 返回 None'); return
        }
        let buf = match (CodeBuffer.alloc(code.size + 16)) {
            case Some(b) => b
            case None => @Fail('CodeBuffer.alloc 失败'); return
        }
        @Assert(buf.write(code, 0), true)
        @Assert(buf.seal(), true)
        buf.flushICache()
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: Int64(cu.entryFn), dbgBase: 0)
        let argsPtr = A64Exec_test.argsPointer([1])
        let f = CFunc<(CPointer<Unit>, CPointer<Int64>, Int64) -> Int64>(
            CPointer<Unit>(buf.rawPointer()))
        let r = unsafe { f(CPointer<Unit>(ctx.cp()), argsPtr, 1) }
        @Assert(unsafe { ctx.cp().read(0) }, 0)
        @Assert(r, 10)
        unsafe { LibC.free<Int64>(argsPtr) }
        JitContext.free(ctx)
        buf.free()
    }

    /** S5.10：`CALL_FUNC` 跨函数入口回填（顶层 recursive 自递归）。 */
    @TestCase
    public func factorialViaCallFunc(): Unit {
        let (r, err) = A64Exec_test.run2(
            '{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }', [5])
        @Assert(err, 0)
        @Assert(r, 120)
    }

    /** S5.14：每个函数入口与间接调用着陆点都以 `bti c` 开始（IBT/BTI）。 */
    @TestCase
    public func allFunctionEntriesStartWithBtiC(): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(
            '{ => let f = { x: Int64 => x + 1 }\n f(41) }')
        let unit = FbcReader.load(cu.raw)
        let art = match (JitCompiler.compileUnitWith(unit, 0, 0)) {
            case Some(a) => a
            case None => @Fail('compileUnitWith 返回 None'); return
        }
        @Assert(unit.dir.size >= 2, true)
        var i = 0
        while (i < unit.dir.size) {
            let code = match (art.codeOf(unit.dir.at(i).fnId)) {
                case Some(c) => c
                case None => @Fail('codeOf 返回 None'); return
            }
            @Assert(code.size >= 4, true)
            // bti c = 0xD503245F，小端 5F 24 03 D5
            @Assert(code[0], 0x5Fu8)
            @Assert(code[1], 0x24u8)
            @Assert(code[2], 0x03u8)
            @Assert(code[3], 0xD5u8)
            i = i + 1
        }
    }

    /** 编译整单元 → 单块 CodeBuffer → fnTable/常量镜像回填 → 调用入口。 */
    private static func run2(src: String, args: Array<Int64>): (Int64, Int64) {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        A64Exec_test.runUnit(cu, 0, args)
    }

    private static func runUnit(cu: CompiledSourceUnit, constBase: Int64,
        args: Array<Int64>): (Int64, Int64) {
        let unit = FbcReader.load(cu.raw)
        var result: Int64 = -1
        var err: Int64 = -1
        // 先建入口表（桥的真实顺序：表 → 编译烘焙基址 → 拷码 → 填入口）
        let table = match (FnTable.alloc(unit.dir.size)) {
            case Some(t) => t
            case None => @Fail('FnTable.alloc 失败'); return (result, err)
        }
        match (JitCompiler.compileUnitWith(unit, constBase, table.base())) {
            case Some(art) =>
                let buf = match (CodeBuffer.alloc(art.code.size + 16)) {
                    case Some(b) => b
                    case None => @Fail('CodeBuffer.alloc 失败'); return (result, err)
                }
                @Assert(buf.write(art.code, 0), true)
                @Assert(buf.seal(), true)
                buf.flushICache()
                var i = 0
                while (i < unit.dir.size) {
                    let fn = unit.dir.at(i)
                    match (art.entry(fn.fnId)) {
                        case Some((off, _)) => table.set(fn.fnId, buf.base + off)
                        case None => ()
                    }
                    i = i + 1
                }
                MachineEnv.setFnTableBase(table.base())
                let entryOff = match (art.entry(cu.entryFn)) {
                    case Some((off, _)) => off
                    case None => 0
                }
                let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: Int64(cu.entryFn), dbgBase: 0)
                let argsPtr = A64Exec_test.argsPointer(args)
                let f = CFunc<(CPointer<Unit>, CPointer<Int64>, Int64) -> Int64>(
                    CPointer<Unit>(unsafe { buf.rawPointer() + entryOff }))
                result = unsafe { f(CPointer<Unit>(ctx.cp()), argsPtr, args.size) }
                err = unsafe { ctx.cp().read(0) }
                if (args.size > 0) {
                    unsafe { LibC.free<Int64>(argsPtr) }
                }
                MachineEnv.reset()
                table.free()
                JitContext.free(ctx)
                buf.free()
            case None => @Fail('JitCompiler.compileUnitWith 返回 None')
        }
        (result, err)
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
