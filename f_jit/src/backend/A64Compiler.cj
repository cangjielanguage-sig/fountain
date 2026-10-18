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

/**
 * AArch64 单函数编排（S5.8 最小路径）：帧序 + 指令降低 + 收敛块。
 *
 * 布局：`bti c` → 序言（x29/x30/x19、ctx、帧、实参拷入与卫生填 0）→ 函数体 →
 * `epilogue` → `bail1/bail2/bail3/deopt` 收敛块。分支重定位在 `finish()` 一次回填。
 */
public class A64Compiler {
    /** `FRAME = align16(32 + 8*(nLocals+maxStack))`（§12.2/§12.3）。 */
    static func frameSize(nLocals: Int64, maxStack: Int64): Int64 {
        let raw = 32 + 8 * (nLocals + maxStack)
        ((raw + 15) / 16) * 16
    }

    /** 编译单函数；含未支持指令 → None（调用方降级解释器）。 */
    public static func compileFunction(unit: LoadedUnit, fn: FuncEntry): ?Array<UInt8> {
        let frame = A64Compiler.frameSize(Int64(fn.nLocals), Int64(fn.maxStack))
        let e = A64Emitter()
        e.btiC()
        e.prologue()
        e.movReg(19, 0)
        e.subImm(31, 31, frame)
        // 操作数栈指针 x20 = locals 区顶端（真实 sp 全程保持 16 对齐）
        e.subImm(20, 29, 32 + 8 * Int64(fn.nLocals))
        // 实参拷入 locals[0..nargs)
        var i = 0
        while (i < Int64(fn.nargs)) {
            e.ldrOff(9, 1, 8 * i)
            e.strOff(9, 29, -32 - 8 * i)
            i = i + 1
        }
        // 其余局部槽卫生填 0
        while (i < Int64(fn.nLocals)) {
            e.movReg(9, 31)
            e.strOff(9, 29, -32 - 8 * i)
            i = i + 1
        }
        let lower = A64Lower(e, fn, frame)
        lower.lower(unit)
        if (!lower.success()) {
            return None
        }
        e.bind('epilogue')
        e.epilogue()
        A64Compiler.bindBail(e, 'bail1', 1)
        A64Compiler.bindBail(e, 'bail2', 2)
        A64Compiler.bindBail(e, 'bail3', 3)
        A64Compiler.bindBail(e, 'deopt', -1)
        Some(e.finish())
    }

    private static func bindBail(e: A64Emitter, label: String, k: Int64): Unit {
        e.bind(label)
        e.movImm64(11, k)
        e.strOff(11, 19, 0)
        e.movReg(0, 31)
        e.b('epilogue')
    }
}
