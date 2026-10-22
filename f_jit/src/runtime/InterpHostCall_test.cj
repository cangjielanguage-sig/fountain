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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.ByteWriter
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.FbcFlags
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.FbcWriter
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.bytecode.SiteTable

/**
 * Q4.11 `Interp` 的 `CALL_HOST`（0x79）语义（m2 §5/§7）。
 *
 * 解释器与 H63 共用同一实现：栈序 `[h_fn, a1..an]`（h_fn 栈底）→ `host_call_trampoline`。
 * 验收：与直接转发**逐位一致**（结果/错误码/site/窗口账目）；v2 单元含 0x79 可执行；
 * 失败后不再执行后续指令（fail-fast）。
 */
@Test
public class InterpHostCall_test {
    private func op0(op: UInt8): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.take()
    }

    private func opU8(op: UInt8, v: UInt8): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.wU8(v)
        w.take()
    }

    private func opI32(op: UInt8, v: Int32): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.wI32(v)
        w.take()
    }

    private func cat(xs: Array<Array<UInt8>>): Array<UInt8> {
        let w = ByteWriter()
        for (x in xs) {
            w.wBytes(x)
        }
        w.take()
    }

    /** 组装一份 **verMajor=2** 的单函数单元（经 `FbcReader` 的 v2 规则集加载）。 */
    private func v2Unit(body: Array<UInt8>, nLocals: Int64, maxStack: Int64,
        types: Array<UInt8>): (LoadedUnit, Array<UInt8>) {
        let dirSize = 4 + 26
        let codeOff = dirSize + types.size
        var all = ByteWriter()
        all.wU32(1u32)
        FuncEntry(0u32, UInt32(codeOff), UInt32(body.size), UInt32(dirSize), 1u16,
            UInt16(nLocals), UInt16(maxStack), 0u16, 0u16).write(all)
        all.wBytes(types)
        all.wBytes(body)
        let code = all.take()

        let consts = ConstRegistry()
        consts.freeze()
        let site = SiteTable()
        site.freeze()
        let names = NameTable()
        names.freeze()
        let w = FbcWriter()
        w.setVersion(Version.M2_MAJOR, Version.M2_MINOR)
        w.setEntryFn(0u32)
        w.setFlags(FbcFlags.UTF8)
        w.setCode(code)
        w.setConst(consts.encode())
        w.setSite(site.encode())
        w.setName(names.encode())
        let raw = w.build()
        (FbcReader.load(raw), raw)
    }

    private func setup(): JitContext {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1, dbgBase: 0)
    }

    private func entry(fn: Any, params: Array<UInt16>, ret: UInt16): Int64 {
        HandleTable.pin(HostCallback(fn, SignatureDescriptor(params, ret)))
    }

    /** v2 单元含 `0x79`：加载通过，解释执行调用宿主闭包（值型返回零登记）。 */
    @TestCase
    public func v2CallHostExecutes(): Unit {
        let body = cat([op0(0x22u8), opI32(0x11u8, 2), opU8(0x79u8, 1u8), op0(0x7Cu8)])
        let (unit, _) = v2Unit(body, 1, 2, [UInt8(LocalType.HOST_CLOSURE)])
        let ctx = setup()
        try {
            let h = entry({ x: Int64 => x * 10 + 1 }, [LocalType.I64], LocalType.I64)
            let before = HandleTable.windowUsed()
            let r = Interp(unit).run(0u32, [h], ctx)
            @Assert(ctx.errCode, 0)
            @Assert(r, 21)
            @Assert(HandleTable.windowUsed(), before)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 解释器路径与 H63 直接转发逐位一致：结果 / errCode / site / 窗口账目。 */
    @TestCase
    public func interpreterMatchesDirectTrampoline(): Unit {
        let body = cat([op0(0x22u8), opI32(0x11u8, 2), opU8(0x79u8, 1u8), op0(0x7Cu8)])
        let (unit, _) = v2Unit(body, 1, 2, [UInt8(LocalType.HOST_CLOSURE)])
        let ctx1 = setup()
        let ctx2 = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1,
            dbgBase: 0)
        try {
            let h = entry({ x: Int64 => x + 40 }, [LocalType.I64], LocalType.I64)
            let r1 = Interp(unit).run(0u32, [h], ctx1)
            let used1 = HandleTable.windowUsed()
            let r2 = invokeHelper(ctx2, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h, 2])
            @Assert(r1, r2)
            @Assert(ctx1.errCode, ctx2.errCode)
            @Assert(ctx1.site, ctx2.site)
            @Assert(used1, HandleTable.windowUsed())
        } finally {
            JitContext.free(ctx1)
            JitContext.free(ctx2)
        }
    }

    /** 宿主闭包抛异常 ⇒ 21；**错误点之后的指令不执行**（后面的人工除零不会改写错误码）。 */
    @TestCase
    public func failureStopsFollowingInstructions(): Unit {
        let body = cat([
            op0(0x22u8), opI32(0x11u8, 2), opU8(0x79u8, 1u8),
            opI32(0x11u8, 0), opI32(0x11u8, 0), op0(0x33u8), // 0 / 0（若执行 ⇒ 1）
            op0(0x7Cu8)
        ])
        let (unit, _) = v2Unit(body, 1, 4, [UInt8(LocalType.HOST_CLOSURE)])
        let ctx = setup()
        try {
            let h = entry({ x: Int64 =>
                if (x >= 0) {
                    throw Exception('boom')
                }
                0
            }, [LocalType.I64], LocalType.I64)
            let r = Interp(unit).run(0u32, [h], ctx)
            @Assert(ctx.errCode, ErrCode.HOST_EXCEPTION)
            @Assert(r, 0)
        } finally {
            JitContext.free(ctx)
        }
    }
}
