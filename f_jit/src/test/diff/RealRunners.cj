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
package fountain::f_jit.test.diff

import fountain::f_base.Arch
import fountain::f_base.OS
import fountain::f_jit.backend.CodeBuffer
import fountain::f_jit.backend.ConstMirror
import fountain::f_jit.backend.FnTable
import fountain::f_jit.backend.JitCompiler
import fountain::f_jit.base.LocalType
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.MachineEnv
import fountain::f_jit.runtime.TextFormat

/**
 * 真实解释器 runner（S5.11 最小集基准）：同一份 `.fbc` + 同一组入参 → 四元组。
 *
 * 报告文本本步留空——转储文本的逐字节对齐属于 T50 的独立判据，S5.11 只要求
 * 结果 / NaN 位模式 / errCode / site 四项一致。
 */
public class InterpRunner <: DiffRunner {
    public func engine(): DiffEngine {
        DiffEngine.Interp
    }

    public func isAvailable(): Bool {
        true
    }

    public func run(c: DiffCase): DiffOutcome {
        let unit = FbcReader.load(c.unit)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0,
            fnId: Int64(unit.header.entryFn), dbgBase: 0)
        let r = interp.run(unit.header.entryFn, RealRunners.cells(c.args), ctx)
        let out = DiffOutcome(RealRunners.text(unit, unit.header.entryFn, r),
            ctx.errCode, ctx.site, '')
        JitContext.free(ctx)
        out
    }
}

/** 真实 AArch64 JIT runner；仅 Linux aarch64 给出证据。 */
public class AArch64Runner <: DiffRunner {
    public func engine(): DiffEngine {
        DiffEngine.BackendAArch64
    }

    public func isAvailable(): Bool {
        OS.current.isLinux && Arch.current.isAarch64
    }

    public func run(c: DiffCase): DiffOutcome {
        let unit = FbcReader.load(c.unit)
        let interp = Interp(unit)
        let ids = Array<Int64>(unit.consts.size, repeat: 0)
        var i = 0
        while (i < unit.consts.size) {
            ids[i] = interp.constHandle(i)
            i = i + 1
        }
        let mirror = ConstMirror.build(ids)
        let table = match (FnTable.alloc(unit.dir.size)) {
            case Some(t) => t
            case None => return DiffOutcome('JIT_ALLOC_FAILED', -1, -1, '')
        }
        let art = match (JitCompiler.compileUnitWith(unit, mirror.base(), table.base())) {
            case Some(a) => a
            case None =>
                table.free()
                mirror.free()
                return DiffOutcome('JIT_COMPILE_FAILED', -1, -1, '')
        }
        let buf = match (CodeBuffer.alloc(art.code.size + 16)) {
            case Some(b) => b
            case None =>
                table.free()
                mirror.free()
                return DiffOutcome('JIT_ALLOC_FAILED', -1, -1, '')
        }
        let unused0 = buf.write(art.code, 0)
        let unused1 = buf.seal()
        buf.flushICache()
        i = 0
        while (i < unit.dir.size) {
            let fn = unit.dir.at(i)
            match (art.entry(fn.fnId)) {
                case Some((off, _)) => table.set(fn.fnId, buf.base + off)
                case None => ()
            }
            i = i + 1
        }
        MachineEnv.setFnTableBase(table.base())
        let entryOff = match (art.entry(unit.header.entryFn)) {
            case Some((off, _)) => off
            case None => 0
        }
        let ctx = JitContext.create(hwBase: 0, hwCap: 0,
            fnId: Int64(unit.header.entryFn), dbgBase: 0)
        let args = RealRunners.cells(c.args)
        let argsPtr = RealRunners.arrayPointer(args)
        let f = CFunc<(CPointer<Unit>, CPointer<Int64>, Int64) -> Int64>(
            CPointer<Unit>(unsafe { buf.rawPointer() + entryOff }))
        let argv = if (args.size == 0) {
            CPointer<Int64>()
        } else {
            unsafe { argsPtr + (args.size - 1) }
        }
        let r = unsafe { f(CPointer<Unit>(ctx.cp()), argv, args.size) }
        let out = DiffOutcome(RealRunners.text(unit, unit.header.entryFn, r),
            ctx.errCode, ctx.site, '')
        if (args.size > 0) {
            unsafe { LibC.free<Int64>(argsPtr) }
        }
        MachineEnv.reset()
        JitContext.free(ctx)
        table.free()
        mirror.free()
        buf.free()
        out
    }
}

internal class RealRunners {
    /** `DiffCase.args` → cell 数组（最小集：Int64 / Float64 位型 / Bool）。 */
    static func cells(args: Array<Any>): Array<Int64> {
        let out = Array<Int64>(args.size, repeat: 0)
        var i = 0
        while (i < args.size) {
            match (args[i]) {
                case v: Int64 => out[i] = v
                case v: Float64 =>
                    let bits = v.toBits()
                    out[i] = if (bits >= 0x8000000000000000u64) {
                        Int64(bits - 0x8000000000000000u64) + Int64.Min
                    } else {
                        Int64(bits)
                    }
                case v: Bool => out[i] = if (v) { 1 } else { 0 }
                case _ => out[i] = 0
            }
            i = i + 1
        }
        out
    }

    static func arrayPointer(args: Array<Int64>): CPointer<Int64> {
        if (args.size == 0) {
            return CPointer<Int64>()
        }
        let p = LibC.malloc<Int64>(count: args.size)
        var i = 0
        while (i < args.size) {
            unsafe { p.write(i, args[args.size - 1 - i]) }
            i = i + 1
        }
        p
    }

    /** 结果按返回类型文本化（F64 → 最短往返；其余按 Int64）。 */
    static func text(unit: LoadedUnit, fnId: UInt32, cell: Int64): String {
        let t = unit.dir.get(fnId).retType
        if (t == LocalType.STRING) {
            match (HandleTable.getAny(cell)) {
                case Some(s: String) => return s
                case _ => return ''
            }
        }
        if (t == LocalType.F64) {
            let bits = if (cell < 0) {
                UInt64(cell - Int64.Min) + 0x8000000000000000u64
            } else {
                UInt64(cell)
            }
            return TextFormat.f64(Float64.fromBits(bits))
        }
        TextFormat.i64(cell)
    }
}
