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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.test.TCase

/**
 * S4.1 `JitContext` 的验收用例（偏移 / 复位 / 配对释放 / 跨调用独立）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §1 ctx 布局表；分配与释放机制 = design D6
 * （`LibC.malloc<Int64>(count: 8)` + 桥 `finally`，不用 `CPointerResource`）。
 */
@Test
public class JitContext_test {
    /** 偏移与 §1 布局表逐项一致：0/8/16/24/32/40/48/56，总长 64 B、8 字。 */
    @TestCase
    public func offsetsMatchSpecLayout(): Unit {
        @Assert(JitContext.OFF_ERR_CODE, 0)
        @Assert(JitContext.OFF_SITE, 8)
        @Assert(JitContext.OFF_HW_BASE, 16)
        @Assert(JitContext.OFF_HW_CAP, 24)
        @Assert(JitContext.OFF_HW_TOP, 32)
        @Assert(JitContext.OFF_FN_ID, 40)
        @Assert(JitContext.OFF_FLAGS, 48)
        @Assert(JitContext.OFF_DBG_BASE, 56)
        @Assert(JitContext.SIZE_BYTES, 64)
        @Assert(JitContext.WORD_COUNT, 8)
    }

    /** `create` 的初值：errCode=0、site=-1、hwTop=hwBase，其余按入参。 */
    @TestCase
    public func createWritesInitialFields(): Unit {
        let ctx = JitContext.create(hwBase: 7, hwCap: 128, fnId: 3, dbgBase: 0)
        try {
            @Assert(ctx.errCode, 0)
            @Assert(ctx.site, -1)
            @Assert(ctx.hwBase, 7)
            @Assert(ctx.hwCap, 128)
            @Assert(ctx.hwTop, 7)
            @Assert(ctx.fnId, 3)
            @Assert(ctx.flags, 0)
            @Assert(ctx.dbgBase, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 各字段的**按偏移**读写与访问器一致（机器码按同一偏移直接读写的契约）。 */
    @TestCase
    public func accessorsAgreeWithRawOffsets(): Unit {
        let ctx = JitContext.create(hwBase: 1, hwCap: 2, fnId: 4, dbgBase: 5)
        try {
            ctx.errCode = 11
            ctx.site = 22
            ctx.hwBase = 33
            ctx.hwCap = 44
            ctx.hwTop = 55
            ctx.fnId = 66
            ctx.flags = CtxFlags.STRICT_FP
            ctx.dbgBase = 77
            @Assert(ctx.readAt(0), 11)
            @Assert(ctx.readAt(8), 22)
            @Assert(ctx.readAt(16), 33)
            @Assert(ctx.readAt(24), 44)
            @Assert(ctx.readAt(32), 55)
            @Assert(ctx.readAt(40), 66)
            @Assert(ctx.readAt(48), CtxFlags.STRICT_FP)
            @Assert(ctx.readAt(56), 77)
            // 反向：按偏移写、访问器读
            ctx.writeAt(0, 99)
            @Assert(ctx.errCode, 99)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** `resetForCall` 归零三件事：errCode=0、site=-1、hwTop=hwBase（§8.2 第 1 步）。 */
    @TestCase
    public func resetForCallClearsErrSiteAndWindow(): Unit {
        let ctx = JitContext.create(hwBase: 100, hwCap: 128, fnId: 1, dbgBase: 0)
        try {
            ctx.errCode = 4
            ctx.site = 4096
            ctx.hwTop = 117
            ctx.resetForCall()
            @Assert(ctx.errCode, 0)
            @Assert(ctx.site, -1)
            @Assert(ctx.hwTop, 100)
            // 不追溯：hwBase / hwCap / fnId / dbgBase 保持
            @Assert(ctx.hwBase, 100)
            @Assert(ctx.hwCap, 128)
            @Assert(ctx.fnId, 1)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** `create` / `free` 配对（T27 的 malloc/free 计数断言）：正常路径无泄漏。 */
    @TestCase
    public func createFreePairIsBalanced(): Unit {
        NativeMem.resetCounters()
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        @Assert(NativeMem.mallocCount, 1)
        @Assert(NativeMem.freeCount, 0)
        @Assert(NativeMem.outstanding(), 1)
        JitContext.free(ctx)
        @Assert(NativeMem.mallocCount, 1)
        @Assert(NativeMem.freeCount, 1)
        @Assert(TCase.hit('T27/create-free-paired', NativeMem.outstanding() == 0), true)
        NativeMem.resetCounters()
    }

    /** 多段路径（正常 / 已写错误码 / 复位后释放）全部配对，计数不漂移。 */
    @TestCase
    public func allPathsPairMallocAndFree(): Unit {
        NativeMem.resetCounters()
        for (i in 0..8) {
            let c = JitContext.create(hwBase: 0, hwCap: 128, fnId: i, dbgBase: 0)
            if (i % 2 == 0) {
                c.errCode = 16
            } else {
                c.resetForCall()
            }
            JitContext.free(c)
        }
        @Assert(NativeMem.mallocCount, 8)
        @Assert(NativeMem.freeCount, 8)
        @Assert(NativeMem.outstanding(), 0)
        NativeMem.resetCounters()
    }

    /** 两个 ctx 指向两块互不相同的 64 B 非托管内存（跨调用 / 跨线程独立的前提）。 */
    @TestCase
    public func twoContextsAreIndependent(): Unit {
        let a = JitContext.create(hwBase: 0, hwCap: 128, fnId: 1, dbgBase: 0)
        let b = JitContext.create(hwBase: 0, hwCap: 128, fnId: 2, dbgBase: 0)
        try {
            @Assert(a.cp().toUIntNative() == b.cp().toUIntNative(), false)
            a.errCode = 5
            @Assert(b.errCode, 0)
            b.site = 77
            @Assert(a.site, -1)
        } finally {
            JitContext.free(a)
            JitContext.free(b)
        }
    }

    /** `CtxFlags` 位定义：bit0=strictFp、bit1=trace、bit2=hasLoop，互不重叠。 */
    @TestCase
    public func ctxFlagsBitsAreDistinct(): Unit {
        @Assert(CtxFlags.STRICT_FP, 1)
        @Assert(CtxFlags.TRACE, 2)
        @Assert(CtxFlags.HAS_LOOP, 4)
        @Assert(CtxFlags.STRICT_FP | CtxFlags.TRACE | CtxFlags.HAS_LOOP, 7)
    }
}
