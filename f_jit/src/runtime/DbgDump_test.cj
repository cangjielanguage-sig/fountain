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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos
import fountain::f_jit.bytecode.LocalTypes
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.bytecode.SiteTable

/**
 * S4.19 单次诊断转储与报告组装的验收用例。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §9 附则 16（v0.18.23 / v0.18.25）：首格哨兵（首个收敛点获胜）、
 * DEOPT / INTERRUPT 不转储、`dbgBase = 0` 跳过、报告模板逐字节冻结。
 */
@Test
public class DbgDump_test {
    /** 分配 / 释放配对（T27 计数断言）；缓冲首格清零。 */
    @TestCase
    public func allocateAndFreeAreBalanced(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(4)
        @Assert(NativeMem.mallocCount, 1)
        unsafe { @Assert(p.read(0), 0) }
        DbgDump.freeDump(p)
        @Assert(NativeMem.mallocCount, 1)
        @Assert(NativeMem.freeCount, 1)
        @Assert(NativeMem.outstanding(), 0)
        NativeMem.resetCounters()
    }

    /** `dbgBase = 0`（转储区禁用）⇒ 跳过转储，首格保持 0。 */
    @TestCase
    public func dumpSkippedWhenDbgBaseIsZero(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(2)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 3, dbgBase: 0)
        try {
            ctx.errCode = 5
            DbgDump.writeOnce(ctx, 3, [Int64(11), Int64(22)])
            unsafe { @Assert(p.read(0), 0) } // 未转储
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }

    /** DEOPT(-1) 与 INTERRUPT(-2) **不**转储（§9.16「-1/-2 不转储」）。 */
    @TestCase
    public func deoptAndInterruptAreNotDumped(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(2)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 1, dbgBase: 0)
        ctx.attachDump(p)
        try {
            ctx.errCode = -1
            DbgDump.writeOnce(ctx, 1, [Int64(7)])
            unsafe { @Assert(p.read(0), 0) }
            ctx.errCode = -2
            DbgDump.writeOnce(ctx, 1, [Int64(7)])
            unsafe { @Assert(p.read(0), 0) }
            // 真正的错误码（> 0）才转储
            ctx.errCode = 4
            DbgDump.writeOnce(ctx, 1, [Int64(7), Int64(8)])
            unsafe {
                @Assert(p.read(0), 1) // fnId
                @Assert(p.read(1), 2) // nLocals
                @Assert(p.read(2), 7)
                @Assert(p.read(3), 8)
            }
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }

    /** 首格哨兵：**首个收敛点获胜**（= 最深失败帧），后续转储不覆盖。 */
    @TestCase
    public func firstConvergencePointWins(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(2)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 9, dbgBase: 0)
        ctx.attachDump(p)
        try {
            ctx.errCode = 4
            DbgDump.writeOnce(ctx, 9, [Int64(1), Int64(2)])
            // 外层传播帧再试图转储 ⇒ 首格哨兵非 0，直接跳过
            ctx.errCode = 8
            DbgDump.writeOnce(ctx, 1, [Int64(99)])
            unsafe {
                @Assert(p.read(0), 9)
                @Assert(p.read(1), 2)
                @Assert(p.read(2), 1)
                @Assert(p.read(3), 2)
            }
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }

    /** 报告模板逐字节：首行 + 源码行 + 变量清单（有名字 / 无名字 / 句柄型 `#idx`）。 */
    @TestCase
    public func reportTemplateIsByteExact(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(3)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 7, dbgBase: 0)
        ctx.attachDump(p)
        HandleTable.resetForTest()
        try {
            let s = HandleTable.pin('vv')
            ctx.errCode = 5
            ctx.site = 12
            let locals = [Int64(42), s, Int64(3)]
            DbgDump.writeOnce(ctx, 7, locals)
            let site = SiteTable()
            site.add(0u32, SourcePos(3, 7))
            site.freeze()
            let name = NameTable()
            name.add(7u32, 0u32, 'a')
            name.add(7u32, 1u32, 's')
            name.freeze()
            var ts = LocalTypes(3)
            ts.set(0, UInt8(LocalType.I64))
            ts.set(1, UInt8(LocalType.STRING))
            ts.set(2, UInt8(LocalType.I64))
            let text = DbgDump.report(5, 12, 7, ts, site, name, p)
            @Assert(text,
                '（code=5，site=12）\n  源码行 3:7 · fnId=7\n  变量: [0] a: Int64 = 42; ' +
                '[1] s: String#${HandleTable.idxOf(s)}; [2] Int64 = 3')
            // 首段（`L:C · fnId=F`）逐字节可断言
            @Assert(text.contains('源码行 3:7 · fnId=7'), true)
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }

    /** `site = -1` ⇒ 无行号、无变量（只有首行）。 */
    @TestCase
    public func reportWithoutSiteHasNoLineOrVariables(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(2)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 1, dbgBase: 0)
        ctx.attachDump(p)
        try {
            let site = SiteTable()
            site.freeze()
            let name = NameTable()
            name.freeze()
            let ts = LocalTypes(1)
            let text = DbgDump.report(19, -1, 1, ts, site, name, p)
            @Assert(text, '（code=19，site=-1）')
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }

    /** 转储区禁用（`dbgBase = 0`）时报告只含行号（§9.16 防御分支）。 */
    @TestCase
    public func reportFallsBackToLineOnly(): Unit {
        let site = SiteTable()
        site.add(0u32, SourcePos(11, 2))
        site.freeze()
        let ts = LocalTypes(1)
        let text = DbgDump.report(6, 8, 2, ts, site)
        @Assert(text, '（code=6，site=8）\n  源码行 11:2 · fnId=2')
    }

    /** 值型的四种呈现：`Int64` / `Float64` / `Bool` / `Unit`（§11.9 文本化）。 */
    @TestCase
    public func slotTextCoversValueTypes(): Unit {
        HandleTable.resetForTest()
        let name = NameTable()
        name.freeze()
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.I64), 42), 'Int64 = 42')
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.F64), Int64(Float64(1.5).toBits())),
            'Float64 = 1.5')
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.BOOL), 1), 'Bool = true')
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.UNIT), 0), 'Unit = Unit')
        // 句柄型记 `<类型名>#<idx>`，null ⇒ #0（不取对象）
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.STRING), 0), 'String#0')
    }

    /** 无名槽省略名字（§9.16「无条目 ⇒ 省略名字」）。 */
    @TestCase
    public func unnamedSlotOmitsName(): Unit {
        let name = NameTable()
        name.freeze()
        @Assert(DbgDump.slotText(name, 1, 3, UInt8(LocalType.I64), 7), 'Int64 = 7')
    }
}
