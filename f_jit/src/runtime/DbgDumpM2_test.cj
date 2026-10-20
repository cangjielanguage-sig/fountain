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
 * Q4.12 `DbgDump` 的 13/14 呈现（m2 §5.1 / design §5.2）。
 *
 * 13 记 `<HostClosure>#idx`、14 记 `<HostObject>#idx`——**大类名加尖括号**呈现（与 4–12 的
 * 真实类型名区分）；不取对象、不解析注册类名。
 * 报告模板与 M1 §9.16 逐条一致（三行模板 / 条目格式 / 槽位序号 / `site=-1` / `dbgBase=0` /
 * `-1`·`-2` 不转储 / 最深失败帧获胜）。
 */
@Test
public class DbgDumpM2_test {
    /** 13/14 的值呈现 = 大类名 + `#idx`（与 4–12 同款，无尖括号）。 */
    @TestCase
    public func hostHandleSlotTextUsesLargeClassName(): Unit {
        HandleTable.resetForTest()
        let name = NameTable()
        name.freeze()
        let id13 = HandleTable.makeId(7, 10u16, 1u16)
        let id14 = HandleTable.makeId(9, 11u16, 1u16)
        @Assert(DbgDump.slotText(name, 1, 0, UInt8(LocalType.HOST_CLOSURE), id13),
            '<HostClosure>#7')
        @Assert(DbgDump.slotText(name, 1, 1, UInt8(LocalType.HOST_OBJECT), id14),
            '<HostObject>#9')
        // 0（null）同样只呈现大类名 + 0
        @Assert(DbgDump.slotText(name, 1, 2, UInt8(LocalType.HOST_OBJECT), 0),
            '<HostObject>#0')
    }

    /** 报告中的 13/14 槽：名字 + 大类名 + idx；**不取对象**（陈旧/不存在的槽也能呈现）。 */
    @TestCase
    public func reportRendersHostHandlesWithoutFetching(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(3)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 7, dbgBase: 0)
        ctx.attachDump(p)
        HandleTable.resetForTest()
        try {
            // idx 9999 / 8888 并不存在：若实现尝试 fetch 就会失败或输出 0
            let h13 = HandleTable.makeId(9999, 10u16, 1u16)
            let h14 = HandleTable.makeId(8888, 11u16, 1u16)
            ctx.errCode = 21
            ctx.site = 3
            let locals = [h13, Int64(5), h14]
            DbgDump.writeOnce(ctx, 7, locals)
            let site = SiteTable()
            site.add(3u32, SourcePos(12, 4))
            site.freeze()
            let name = NameTable()
            name.add(7u32, 0u32, 'cb')
            name.add(7u32, 2u32, 'obj')
            name.freeze()
            var ts = LocalTypes(3)
            ts.set(0, UInt8(LocalType.HOST_CLOSURE))
            ts.set(1, UInt8(LocalType.I64))
            ts.set(2, UInt8(LocalType.HOST_OBJECT))
            let text = DbgDump.report(21, 3, 7, ts, site, name, p)
            @Assert(text,
                '（code=21，site=3）\n  源码行 12:4 · fnId=7\n  变量: ' +
                '[0] cb: <HostClosure>#9999; [1] Int64 = 5; [2] obj: <HostObject>#8888')
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }

    /** `site=-1` 规则对 13/14 同样生效：只有首行，无行号/变量。 */
    @TestCase
    public func siteMinusOneStillSuppressesHostHandleVariables(): Unit {
        NativeMem.resetCounters()
        let p = DbgDump.allocateDump(1)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 1, dbgBase: 0)
        ctx.attachDump(p)
        try {
            ctx.errCode = 21
            DbgDump.writeOnce(ctx, 1, [HandleTable.makeId(3, 10u16, 1u16)])
            let site = SiteTable()
            site.freeze()
            let name = NameTable()
            name.freeze()
            let ts = LocalTypes(1)
            ts.set(0, UInt8(LocalType.HOST_CLOSURE))
            @Assert(DbgDump.report(21, -1, 1, ts, site, name, p), '（code=21，site=-1）')
        } finally {
            JitContext.free(ctx)
            DbgDump.freeDump(p)
        }
        NativeMem.resetCounters()
    }
}
