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
package fountain::f_jit.backend

import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.MachineEnv

/**
 * 生产路径的 JIT 执行器（S6.9 桥接）：编译 → 码内存 → 入口表/常量镜像 → 调用。
 *
 * 与差分层 `RealRunners` 使用同一套资产顺序（常量镜像 → 入口表 → 编译 → 拷码 → 填入口），
 * 任何一步失败都返回 `None`，调用方静默退回解释器（T7/T9）。
 *
 * 生命周期：`release()` 幂等，按「码内存最后释放」的顺序回收。
 */
public class JitExecutor {
    private let buf: CodeBuffer
    private let table: FnTable
    private let mirror: ConstMirror
    private let entryOff: Int64
    private var released: Bool

    private init(buf: CodeBuffer, table: FnTable, mirror: ConstMirror, entryOff: Int64) {
        this.buf = buf
        this.table = table
        this.mirror = mirror
        this.entryOff = entryOff
        this.released = false
    }

    /** 为 `entryFn` 建可执行资产；不支持/分配失败 → None。 */
    public static func create(unit: LoadedUnit, entryFn: UInt32): ?JitExecutor {
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
            case None =>
                mirror.free()
                return None
        }
        let art = match (JitCompiler.compileUnitWith(unit, mirror.base(), table.base())) {
            case Some(a) => a
            case None =>
                table.free()
                mirror.free()
                return None
        }
        let entryOff = match (art.entry(entryFn)) {
            case Some((off, _)) => off
            case None =>
                table.free()
                mirror.free()
                return None
        }
        let buf = match (CodeBuffer.alloc(art.code.size + 16)) {
            case Some(b) => b
            case None =>
                table.free()
                mirror.free()
                return None
        }
        if (!buf.write(art.code, 0) || !buf.seal()) {
            buf.free()
            table.free()
            mirror.free()
            return None
        }
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
        Some(JitExecutor(buf, table, mirror, entryOff))
    }

    /** 以 `cells` 为实参执行入口函数；入参按「最深实参在高地址」的共享 ABI 排列。 */
    public func invoke(ctx: JitContext, cells: Array<Int64>): Int64 {
        MachineEnv.setFnTableBase(this.table.base())
        let n = cells.size
        let p = if (n == 0) {
            CPointer<Int64>()
        } else {
            let raw = LibC.malloc<Int64>(count: n)
            var i = 0
            while (i < n) {
                unsafe { raw.write(i, cells[n - 1 - i]) }
                i = i + 1
            }
            unsafe { raw + (n - 1) }
        }
        let rawAlloc = if (n == 0) {
            CPointer<Int64>()
        } else {
            unsafe { p - (n - 1) }
        }
        let f = CFunc<(CPointer<Unit>, CPointer<Int64>, Int64) -> Int64>(
            CPointer<Unit>(unsafe { this.buf.rawPointer() + this.entryOff }))
        let r = unsafe { f(CPointer<Unit>(ctx.cp()), p, n) }
        if (n > 0) {
            unsafe { LibC.free<Int64>(rawAlloc) }
        }
        MachineEnv.reset()
        r
    }

    /** 释放码内存/入口表/常量镜像（幂等；码内存最后释放）。 */
    public func release(): Unit {
        if (this.released) {
            return
        }
        this.released = true
        this.table.free()
        this.mirror.free()
        this.buf.free()
    }
}
