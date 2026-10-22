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

import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HelperAddresses

/**
 * AArch64 单函数编排（S5.8 最小路径）：帧序 + 指令降低 + 收敛块。
 *
 * 布局：`bti c` → 序言（x29/x30/x19、ctx、帧、实参拷入与卫生填 0）→ 函数体 →
 * `epilogue` → `bail1/bail2/bail3/deopt` 收敛块。分支重定位在 `finish()` 一次回填。
 */
public class A64Compiler {
    /**
     * `FRAME = align16(40 + 8*(nLocals + maxStack) + 8)`（§12.2/§12.3）。
     *
     * 末项是**转瞬实参槽**：helper 模板需把静态操作数（`TO_STR` 的标签、
     * `IS_TYPE`/`CAST`/`LOAD_CAP`/`MAP_ITER_STEP` 的立即数）压到操作数栈顶再调用，
     * 峰值比字节码 `maxStack` 多一格（§12.4 模板 A）。缺少这一格时该槽落在 `sp`
     * 之下，会被 helper 自己的栈帧覆盖（实测：插值串的 `TO_STR` 标签读回垃圾 ⇒ 14）。
     */
    static func frameSize(nLocals: Int64, maxStack: Int64): Int64 {
        let raw = 40 + 8 * (nLocals + maxStack + 1)
        ((raw + 15) / 16) * 16
    }

    /** 编译单函数；含未支持指令或分支越界 → None（调用方降级解释器）。 */
    public static func compileFunction(unit: LoadedUnit, fn: FuncEntry): ?Array<UInt8> {
        A64Compiler.compileFunctionWith(unit, fn, 0, 0)
    }

    /**
     * 带常量镜像 / fnTable 基址的编译入口（`PUSH_KH` / `CALL_FUNC`）。
     *
     * **两遍布局**（§12.4「分支可达范围差异」）：第一遍按短条件分支编码；若任一
     * `b.cond/cbz/cbnz` 越出 ±1 MB，第二遍把所有条件分支放大为
     * 「取反条件 +8；b target」跳板（`b` 范围 ±128 MB），语义逐位一致。
     */
    public static func compileFunctionWith(unit: LoadedUnit, fn: FuncEntry,
        constBase: Int64, fnTableBase: Int64): ?Array<UInt8> {
        match (A64Compiler.compileOnce(unit, fn, constBase, fnTableBase, false)) {
            case Some(b) => return Some(b)
            case None => ()
        }
        A64Compiler.compileOnce(unit, fn, constBase, fnTableBase, true)
    }

    /** 测试接缝：强制跳板模式编译（验证第二遍编码可用）。 */
    public static func compileFunctionFar(unit: LoadedUnit, fn: FuncEntry,
        constBase: Int64, fnTableBase: Int64): ?Array<UInt8> {
        A64Compiler.compileOnce(unit, fn, constBase, fnTableBase, true)
    }

    private static func compileOnce(unit: LoadedUnit, fn: FuncEntry,
        constBase: Int64, fnTableBase: Int64, farCond: Bool): ?Array<UInt8> {        let frame = A64Compiler.frameSize(Int64(fn.nLocals), Int64(fn.maxStack))
        let e = A64Emitter(farCond)
        e.btiC()
        e.prologue()
        e.movReg(19, 0)
        e.subImm(31, 31, frame)
        // 操作数栈指针 x20 = locals 区顶端（真实 sp 全程保持 16 对齐）
        e.subImm(20, 29, 40 + 8 * Int64(fn.nLocals))
        // 实参拷入 locals[0..nargs)：x1 指向最深实参（高地址），第 i 个在 −8i
        var i = 0
        while (i < Int64(fn.nargs)) {
            if (i == 0) {
                e.ldrOff(9, 1, 0)
            } else {
                e.subImm(11, 1, 8 * i)
                e.ldrOff(9, 11, 0)
            }
            e.strOff(9, 29, -40 - 8 * i)
            i = i + 1
        }
        // 其余局部槽卫生填 0
        while (i < Int64(fn.nLocals)) {
            e.movReg(9, 31)
            e.strOff(9, 29, -40 - 8 * i)
            i = i + 1
        }
        A64Emitter.resetAuditMemBases()
        let lower = A64Lower(e, fn, frame, constBase, fnTableBase)
        lower.lower(unit)
        if (!lower.success()) {
            return None
        }
        // G5 审计：机器码只能以 sp/fp/x19(ctx)/x20(操作数栈) 为内存基址
        if (!A64Emitter.auditAllows(A64Emitter.auditMemBasesSnapshot())) {
            return None
        }
        e.bind('epilogue')
        e.epilogue()
        A64Compiler.bindBail(e, fn, 'bail1', 1)
        A64Compiler.bindBail(e, fn, 'bail2', 2)
        A64Compiler.bindBail(e, fn, 'bail3', 3)
        A64Compiler.bindBail(e, fn, 'deopt', -1)
        e.finishOrNull()
    }

    /**
     * 收敛块：写错误槽 → （`k > 0` 时）单次转储 → 返回 0。
     *
     * 转储经 `@C` 入口 `jit_dump` 回到 `DbgDump.writeOnceStack`，与解释器共用同一份
     * 报告逻辑（T50）；`-1`（DEOPT）不转储。
     */
    private static func bindBail(e: A64Emitter, fn: FuncEntry, label: String, k: Int64): Unit {
        e.bind(label)
        e.movImm64(11, k)
        e.strOff(11, 19, 0)
        if (k > 0) {
            A64Compiler.emitDump(e, fn)
        }
        e.movReg(0, 31)
        e.b('epilogue')
    }

    /** `jit_dump(dbgBase, errCode, fnId, nLocals, &locals[0])`；locals[i] 在 `[x29, #-40-8i]`。 */
    private static func emitDump(e: A64Emitter, fn: FuncEntry): Unit {
        e.subImm(4, 29, 40)
        e.ldrOff(0, 19, 56)
        e.ldrOff(1, 19, 0)
        e.movImm64(2, Int64(fn.fnId))
        e.movImm64(3, Int64(fn.nLocals))
        e.movImm64(11, HelperAddresses.dump())
        e.blr(11)
    }
}
