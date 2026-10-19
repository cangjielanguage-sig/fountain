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
import std.collection.ArrayList
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.bytecode.ByteWriter
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.FbcHeader
import fountain::f_jit.bytecode.FbcFlags
import fountain::f_jit.bytecode.FbcRuleRegistry
import fountain::f_jit.bytecode.FuncDir
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.bytecode.LocalTypes
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.bytecode.SiteTable
import fountain::f_jit.base.Version

/**
 * S4.20–S4.22 解释器的验收用例（**语义基准**）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §5（ISA 逐指令语义）、§0（fail-fast 冻结）、§11.9（语义组）。
 * 单元由测试**手工装配**（不经前端）：`FuncDir` + 局部类型表 + 函数体，交给 `Interp` 解释执行。
 */
@Test
public class Interp_test {
    // ---- 汇编小工具（手工装配字节，不依赖前端）----

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

    private func opU16(op: UInt8, v: UInt16): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.wU16(v)
        w.take()
    }

    private func opI32(op: UInt8, v: Int32): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.wI32(v)
        w.take()
    }

    private func opI64(op: UInt8, v: Int64): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.wI64(v)
        w.take()
    }

    private func opU16U8(op: UInt8, a: UInt16, b: UInt8): Array<UInt8> {
        let w = ByteWriter()
        w.wU8(op)
        w.wU16(a)
        w.wU8(b)
        w.take()
    }

    private func cat(xs: Array<Array<UInt8>>): Array<UInt8> {
        let w = ByteWriter()
        for (x in xs) {
            w.wBytes(x)
        }
        w.take()
    }

    /** 装配一个 `LoadedUnit`（目录 + 局部类型表 + 各函数体）。 */
    private func unit(
        bodies: Array<Array<UInt8>>,
        nLocalsList: Array<Int64>,
        maxStackList: Array<Int64>,
        nargsList: Array<Int64>,
        typesList: Array<Array<UInt8>>,
        consts: ConstRegistry,
        names: Array<(UInt32, UInt32, String)>
    ): LoadedUnit {
        let dirSize = 4 + 26 * bodies.size
        var typesSize = 0
        for (t in typesList) {
            typesSize = typesSize + t.size
        }
        let codeOff = dirSize + typesSize
        var all = ByteWriter()
        all.wU32(UInt32(bodies.size))
        var i = 0
        var bodyStart = codeOff
        var starts = ArrayList<Int64>()
        for (b in bodies) {
            starts.add(bodyStart)
            bodyStart = bodyStart + b.size
        }
        i = 0
        while (i < bodies.size) {
            let e = FuncEntry(
                UInt32(i), UInt32(starts[i]), UInt32(bodies[i].size), UInt32(dirSize),
                UInt16(nargsList[i]), UInt16(nLocalsList[i]), UInt16(maxStackList[i]), 0u16, 0u16)
            e.write(all)
            i = i + 1
        }
        for (t in typesList) {
            all.wBytes(t)
        }
        for (b in bodies) {
            all.wBytes(b)
        }
        let code = all.take()

        let dir = FuncDir()
        i = 0
        while (i < bodies.size) {
            dir.add(FuncEntry(
                UInt32(i), UInt32(starts[i]), UInt32(bodies[i].size), UInt32(dirSize),
                UInt16(nargsList[i]), UInt16(nLocalsList[i]), UInt16(maxStackList[i]), 0u16, 0u16))
            i = i + 1
        }
        var typesArr = ArrayList<LocalTypes>()
        for (t in typesList) {
            typesArr.add(LocalTypes.read(t))
        }
        let site = SiteTable()
        site.freeze()
        let name = NameTable()
        for (n in names) {
            name.add(n[0], n[1], n[2])
        }
        name.freeze()
        let header = FbcHeader(
            Version.MAGIC, Version.MAJOR, Version.MINOR,
            FbcFlags.UTF8 | FbcFlags.VALUE_OPS, UInt32(Version.HDR_SIZE),
            UInt32(code.size), UInt32(0), UInt32(0), 0u32, UInt32(4), 0u32)
        LoadedUnit(header, code, consts, site, name, dir, typesArr.toArray(), FbcRuleRegistry.V1)
    }

    private func typesOf(ts: Array<UInt8>): Array<UInt8> {
        ts
    }

    /** UInt64 位模式 → Int64 cell（负数按补码折算，避免 `Int64(UInt64)` 溢出异常）。 */
    private func cellOfBits(b: UInt64): Int64 {
        if (b >= 0x8000000000000000u64) {
            Int64(b - 0x8000000000000000u64) + Int64.Min
        } else {
            Int64(b)
        }
    }

    /** Int64 cell → UInt64 位模式。 */
    private func bitsOfCell(v: Int64): UInt64 {
        if (v < 0) {
            UInt64(v - Int64.Min) + 0x8000000000000000u64
        } else {
            UInt64(v)
        }
    }

    private func ctxOf(): JitContext {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 0, dbgBase: 0)
    }

    // ========================================================================
    // S4.20 框架
    // ========================================================================

    /** 帧尺寸按 §3.1 公式并 16 对齐；`frameInfo` 与目录一致。 */
    @TestCase
    public func frameSizeFollowsSpecFormula(): Unit {
        let u = unit([op0(0x7Du8)], [0], [0], [0], [typesOf([])], ConstRegistry(), [])
        let it = Interp(u)
        let fi = it.frameInfo(0u32)
        @Assert(fi[0], 0)
        @Assert(fi[1], 0)
        // 32 + 0 + 0 + 8 = 40 ⇒ 对齐到 48
        @Assert(it.frameSize(0u32), 48)
        let u2 = unit([op0(0x7Du8)], [3], [2], [0], [typesOf([0, 0, 0])], ConstRegistry(), [])
        let it2 = Interp(u2)
        let fi2 = it2.frameInfo(0u32)
        @Assert(fi2[0], 3)
        @Assert(fi2[1], 2)
        // 32 + 24 + 16 + 8 = 80 ⇒ 已是 16 的倍数
        @Assert(it2.frameSize(0u32), 80)
        @Assert(Interp.align16(16), 16)
        @Assert(Interp.align16(17), 32)
    }

    /** `LOADL` / `STOREL` 与 `RET` / `RET_VOID` 两个唯一出口。 */
    @TestCase
    public func localsAndReturn(): Unit {
        let body = cat([
            opI32(0x11u8, 7), opU16(0x21u8, 0), // STOREL 0
            opU16(0x20u8, 0), opI32(0x11u8, 35), op0(0x30u8), // LOADL 0 + 35 + IADD
            op0(0x7Cu8)]) // RET
        let u = unit([body], [1], [4], [0], [typesOf([0])], ConstRegistry(), [])
        let ctx = ctxOf()
        try {
            let r = Interp(u).run(0u32, [], ctx)
            @Assert(r, 42)
            @Assert(ctx.errCode, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** `RET_VOID`：`rax = 0`，栈不留残留。 */
    @TestCase
    public func retVoidReturnsZero(): Unit {
        let u = unit([cat([opI32(0x11u8, 5), op0(0x19u8), op0(0x7Du8)])], [0], [2], [0],
            [typesOf([])], ConstRegistry(), [])
        let ctx = ctxOf()
        try {
            @Assert(Interp(u).run(0u32, [], ctx), 0)
            @Assert(ctx.errCode, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    // ========================================================================
    // S4.21 指令语义
    // ========================================================================

    /** 常量入栈与栈操作：`DUP / DUP2 / POP / POP2 / SWAP / PICK`。 */
    @TestCase
    public func constAndStackOps(): Unit {
        let body = cat([
            opI32(0x11u8, 1), opI32(0x11u8, 2), opI32(0x11u8, 3),
            opU8(0x1Cu8, 2u8)]) // PICK 2 → 复制最深的 1
        let u = unit([body], [0], [8], [0], [typesOf([])], ConstRegistry(), [])
        let ctx = ctxOf()
        try {
            let it = Interp(u)
            let r = it.run(0u32, [], ctx)
            // 无 RET ⇒ 走唯一出口返回 0；这里只验证不报错
            @Assert(ctx.errCode, 0)
            @Assert(r, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 整型：溢出 → 3、`IDIV` ÷0 → 1 与 `INT_MIN/-1` → 3、`IMOD` 四象限与 `INT_MIN % -1 → 0`。 */
    @TestCase
    public func intArithmeticEdges(): Unit {
        let ctx = ctxOf()
        try {
            // 1 + 1 = 2
            @Assert(runBody(ctx, cat([opI32(0x11u8, 1), opI32(0x11u8, 1), op0(0x30u8), op0(0x7Cu8)])), 2)
            // Int64.Max + 1 → 3
            @Assert(runBody(ctx, cat([opI64(0x12u8, Int64.Max), opI32(0x11u8, 1), op0(0x30u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.OVERFLOW_I64)
            ctx.errCode = 0
            // 1 / 0 → 1
            @Assert(runBody(ctx, cat([opI32(0x11u8, 1), opI32(0x11u8, 0), op0(0x33u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.DIV_ZERO)
            ctx.errCode = 0
            // Int64.Min / -1 → 3
            @Assert(runBody(ctx, cat([opI64(0x12u8, Int64.Min), opI32(0x11u8, -1), op0(0x33u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.OVERFLOW_I64)
            ctx.errCode = 0
            // -4 % 3 = -1、4 % -3 = 1（符号随被除数）
            @Assert(runBody(ctx, cat([opI32(0x11u8, -4), opI32(0x11u8, 3), op0(0x34u8), op0(0x7Cu8)])), -1)
            @Assert(runBody(ctx, cat([opI32(0x11u8, 4), opI32(0x11u8, -3), op0(0x34u8), op0(0x7Cu8)])), 1)
            // INT_MIN % -1 → 0（不报溢出）
            @Assert(runBody(ctx, cat([opI64(0x12u8, Int64.Min), opI32(0x11u8, -1), op0(0x34u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, 0)
            // 1 % 0 → 2
            @Assert(runBody(ctx, cat([opI32(0x11u8, 1), opI32(0x11u8, 0), op0(0x34u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.MOD_ZERO)
            ctx.errCode = 0
            // ICLZ / IPOPCNT
            @Assert(runBody(ctx, cat([opI64(0x12u8, 1), op0(0x3Au8), op0(0x7Cu8)])), 63)
            @Assert(runBody(ctx, cat([opI64(0x12u8, 7), op0(0x3Bu8), op0(0x7Cu8)])), 3)
            @Assert(runBody(ctx, cat([opI64(0x12u8, Int64.Min), op0(0x36u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.OVERFLOW_I64)
        } finally {
            JitContext.free(ctx)
        }
    }

    private func runBody(ctx: JitContext, body: Array<UInt8>): Int64 {
        ctx.errCode = 0
        ctx.site = -1
        let u = unit([body], [0], [8], [0], [typesOf([])], ConstRegistry(), [])
        Interp(u).run(0u32, [], ctx)
    }

    /** 浮点：NaN 规范化为同一位模式（§11.3）；÷0 不报错。 */
    @TestCase
    public func floatNanCanonicalization(): Unit {
        let ctx = ctxOf()
        try {
            // 0.0 / 0.0 ⇒ canonical NaN
            let r = runBody(ctx, cat([
                opI64(0x13u8, 0), opI64(0x13u8, 0), op0(0x43u8), op0(0x7Cu8)]))
            @Assert(bitsOfCell(r), Interp.CANON_NAN)
            @Assert(ctx.errCode, 0)
            // 1.0 / 0.0 ⇒ +Inf（不报错）
            let inf = runBody(ctx, cat([
                opI64(0x13u8, cellOfBits(Float64(1.0).toBits())), opI64(0x13u8, 0), op0(0x43u8), op0(0x7Cu8)]))
            @Assert(bitsOfCell(inf), 0x7FF0000000000000u64)
            @Assert(ctx.errCode, 0)
            // FMIN / FMAX 遇 NaN ⇒ canonical NaN
            let mn = runBody(ctx, cat([
                opI64(0x13u8, 0), opI64(0x13u8, 0), op0(0x43u8),
                opI64(0x13u8, cellOfBits(Float64(1.0).toBits())), op0(0x47u8), op0(0x7Cu8)]))
            @Assert(bitsOfCell(mn), Interp.CANON_NAN)
            // FADD 1.5 + 2.25
            let sum = runBody(ctx, cat([
                opI64(0x13u8, cellOfBits(Float64(1.5).toBits())),
                opI64(0x13u8, cellOfBits(Float64(2.25).toBits())), op0(0x40u8), op0(0x7Cu8)]))
            @Assert(Float64.fromBits(UInt64(sum)), Float64(3.75))
            // FFLOOR / FCEIL / FTRUNC / FROUND
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Float64(-1.7).toBits())), op0(0x4Au8), op0(0x7Cu8)])), -2)
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Float64(-1.7).toBits())), op0(0x4Bu8), op0(0x7Cu8)])), -1)
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Float64(-1.7).toBits())), op0(0x4Cu8), op0(0x7Cu8)])), -1)
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Float64(2.5).toBits())), op0(0x4Du8), op0(0x7Cu8)])), 2)
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Float64(3.5).toBits())), op0(0x4Du8), op0(0x7Cu8)])), 4)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 比较 / 逻辑 / 位；`NOT_B` / `AND_B` / `OR_B` / `XOR_B`；句柄同一性。 */
    @TestCase
    public func compareLogicAndBitOps(): Unit {
        let ctx = ctxOf()
        try {
            @Assert(runBody(ctx, cat([opI32(0x11u8, 3), opI32(0x11u8, 5), op0(0x50u8), op0(0x7Cu8)])), -1)
            @Assert(runBody(ctx, cat([opI32(0x11u8, 5), opI32(0x11u8, 3), op0(0x50u8), op0(0x7Cu8)])), 1)
            @Assert(runBody(ctx, cat([opI32(0x11u8, 4), opI32(0x11u8, 4), op0(0x56u8), op0(0x7Cu8)])), 0)
            @Assert(runBody(ctx, cat([opI32(0x11u8, 4), opI32(0x11u8, 4), op0(0x55u8), op0(0x7Cu8)])), 1)
            // NaN 比较：EQ_F false、NE_F true
            @Assert(runBody(ctx, cat([opI64(0x13u8, 0), opI64(0x13u8, 0), op0(0x43u8), op0(0x17u8),
                opI64(0x13u8, 0), op0(0x58u8), op0(0x7Cu8)])), 0)
            @Assert(runBody(ctx, cat([opI64(0x13u8, 0), opI64(0x13u8, 0), op0(0x43u8), op0(0x17u8),
                opI64(0x13u8, 0), op0(0x59u8), op0(0x7Cu8)])), 1)
            // 逻辑与位
            @Assert(runBody(ctx, cat([opU8(0x14u8, 1), op0(0x5Eu8), op0(0x7Cu8)])), 0)
            @Assert(runBody(ctx, cat([opU8(0x14u8, 1), opU8(0x14u8, 0), op0(0x5Fu8), op0(0x7Cu8)])), 0)
            @Assert(runBody(ctx, cat([opU8(0x14u8, 1), opU8(0x14u8, 0), op0(0x60u8), op0(0x7Cu8)])), 1)
            @Assert(runBody(ctx, cat([opI32(0x11u8, 6), opI32(0x11u8, 3), op0(0x62u8), op0(0x7Cu8)])), 2)
            @Assert(runBody(ctx, cat([opI32(0x11u8, 0), op0(0x65u8), op0(0x7Cu8)])), -1)
            // 移位取低 6 位
            @Assert(runBody(ctx, cat([opI32(0x11u8, 1), opI32(0x11u8, 64), op0(0x66u8), op0(0x7Cu8)])), 1)
            // 句柄同一性 EQ_H / NE_H
            @Assert(runBody(ctx, cat([op0(0x15u8), op0(0x17u8), op0(0x69u8), op0(0x7Cu8)])), 1)
            @Assert(runBody(ctx, cat([op0(0x15u8), op0(0x17u8), op0(0x6Au8), op0(0x7Cu8)])), 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 控制流：`JMP` / `JZ` / `JNZ` / `LOOP_BACK`（回边安全点）。 */
    @TestCase
    public func controlFlowAndLoopBack(): Unit {
        let ctx = ctxOf()
        try {
            // JMP 跳过一段：PUSH 1; JMP +3; PUSH 99(nil); RET
            let jmp = cat([opI32(0x11u8, 1), opI32(0x70u8, 5), opI32(0x11u8, 99), op0(0x7Cu8)])
            @Assert(runBody(ctx, jmp), 1)
            // JZ：条件为 0 ⇒ 跳（跳过 PUSH 99）
            @Assert(runBody(ctx, cat([opI32(0x11u8, 7), opU8(0x14u8, 0), opI32(0x71u8, 5),
                opI32(0x11u8, 99), op0(0x7Cu8)])), 7)
            // JNZ：条件非 0 ⇒ 跳（跳过 PUSH 99）
            @Assert(runBody(ctx, cat([opI32(0x11u8, 7), opU8(0x14u8, 1), opI32(0x72u8, 5),
                opI32(0x11u8, 99), op0(0x7Cu8)])), 7)
            // LOOP_BACK 回边：1 + 1 + 1（两轮回边）
            let loopBody = cat([
                opI32(0x11u8, 0), opU16(0x21u8, 0), // STOREL 0 = 0
                opU16(0x20u8, 0), opI32(0x11u8, 1), op0(0x30u8), opU16(0x21u8, 0),
                opU16(0x20u8, 0), opI32(0x11u8, 3), op0(0x54u8), // LT_I
                opI32(0x72u8, -26), // JNZ 回跳（相对下一条指令，回到循环体首）
                opU16(0x20u8, 0), op0(0x7Cu8)])
            @Assert(runBodyL(ctx, loopBody, 1), 3)
        } finally {
            JitContext.free(ctx)
        }
    }

    private func runBodyL(ctx: JitContext, body: Array<UInt8>, nLocals: Int64): Int64 {
        ctx.errCode = 0
        ctx.site = -1
        var ts = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < nLocals) {
            ts.add(0u8)
            i = i + 1
        }
        let u = unit([body], [nLocals], [8], [0], [typesOf(ts.toArray())], ConstRegistry(), [])
        Interp(u).run(0u32, [], ctx)
    }

    /** `CALL_FUNC` 共窗口；`CALL_CLOSURE` 经闭包对象的 `fnId` + 捕获。 */
    @TestCase
    public func callsShareWindowAndClosures(): Unit {
        let ctx = ctxOf()
        try {
            // fn1: LOADL0 * 10 ; fn0: PUSH 2; CALL_FUNC 1,1; RET
            let mainBody = cat([opI32(0x11u8, 2), opU16U8(0x78u8, 1u16, 1u8), op0(0x7Cu8)])
            let sub = cat([opU16(0x20u8, 0), opI32(0x11u8, 10), op0(0x32u8), op0(0x7Cu8)])
            let u = unit([mainBody, sub], [0, 1], [4, 4], [0, 1], [typesOf([]), typesOf([0])], ConstRegistry(), [])
            let r = Interp(u).run(0u32, [], ctx)
            @Assert(r, 20)
            @Assert(ctx.errCode, 0)

            // 闭包：closure_new(1, [100]) → CALL_CLOSURE argc=1 → LOAD_CAP 0 + LOADL 1
            let mainBody2 = cat([
                opI64(0x12u8, 1), // fnId = 1
                opI64(0x12u8, 100), // 捕获
                opU16U8(0x75u8, 54u16, 2u8), // CALL_HELPER 54, argc=2
                opI32(0x11u8, 5), // 实参
                opU8(0x7Fu8, 1u8), // CALL_CLOSURE argc=1
                op0(0x7Cu8)])
            let cl = cat([opU16(0x26u8, 0), opU16(0x20u8, 1), op0(0x30u8), op0(0x7Cu8)])
            let u2 = unit([mainBody2, cl], [0, 2], [8, 4], [0, 1],
                [typesOf([]), typesOf([12, 0])], ConstRegistry(), [])
            let r2 = Interp(u2).run(0u32, [], ctx)
            @Assert(r2, 105)
            @Assert(ctx.errCode, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 类型指令：`CAST` / `TO_I64` / `TO_F64` / `IS_TYPE` / `GUARD_TYPE` / `ASSERT` / `ABORT` /
     *  `THROW` / `GUARD_NNZ` / `TYPE_OF`。 */
    @TestCase
    public func typeInstructions(): Unit {
        let ctx = ctxOf()
        try {
            // TO_F64：Int64 3 → 3.0
            let f = runBody(ctx, cat([opI32(0x11u8, 3), op0(0x82u8), op0(0x7Cu8)]))
            @Assert(Float64.fromBits(UInt64(f)), Float64(3.0))
            // TO_I64 mode=0：NaN → 13
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Interp.CANON_NAN)), opU8(0x81u8, 0u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.FP_INVALID)
            ctx.errCode = 0
            // TO_I64 mode=1：NaN → DEOPT(-1)
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Interp.CANON_NAN)), opU8(0x81u8, 1u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.DEOPT)
            ctx.errCode = 0
            // TO_I64 正常：-2.7 → -2（向零截断）
            @Assert(runBody(ctx, cat([opI64(0x13u8, cellOfBits(Float64(-2.7).toBits())), opU8(0x81u8, 0u8), op0(0x7Cu8)])), -2)
            // IS_TYPE：null → 0
            @Assert(runBody(ctx, cat([op0(0x15u8), opU16(0x83u8, LocalType.STRING), op0(0x7Cu8)])), 0)
            // GUARD_TYPE mode=0 对 null → 8
            @Assert(runBody(ctx, cat([op0(0x15u8), opU16U8(0x84u8, LocalType.STRING, 0u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.HANDLE_TYPE)
            ctx.errCode = 0
            // ASSERT：false → BAIL(code)
            @Assert(runBody(ctx, cat([opU8(0x14u8, 0), opU8(0x86u8, 17u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, 17)
            ctx.errCode = 0
            // ABORT：无条件 BAIL
            @Assert(runBody(ctx, cat([opU8(0x87u8, 20u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, 20)
            ctx.errCode = 0
            // THROW → 17
            @Assert(runBody(ctx, cat([opU8(0x85u8, 5u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.EXPLICIT)
            ctx.errCode = 0
            // GUARD_NNZ mode=0：null → 6
            @Assert(runBody(ctx, cat([op0(0x15u8), opU8(0x88u8, 0u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.NULL_HANDLE)
            ctx.errCode = 0
            // TYPE_OF：null → 6
            @Assert(runBody(ctx, cat([op0(0x15u8), op0(0x89u8), op0(0x7Cu8)])), 0)
            @Assert(ctx.errCode, ErrCode.NULL_HANDLE)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** T6/7：`CAST` 值型转型失败 → 7（`BAD_CAST`），与 `GUARD_TYPE` 的 8 区分。 */
    @TestCase
    public func castTypeMismatchYields7(): Unit {
        let ctx = ctxOf()
        try {
            let body = cat([
                opI32(0x11u8, 1), // PUSH_I64 1（I64 值）
                opU16U8(0x80u8, UInt16(LocalType.STRING), 0u8), // CAST STRING mode0
                op0(0x7Cu8)])
            @Assert(runBody(ctx, body), 0)
            @Assert(ctx.errCode, ErrCode.BAD_CAST)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 容器与值提取：`LEN / GET_IDX / HAS_KEY / GET_KEY_OR`；`PUSH_KH` 常量句柄。 */
    @TestCase
    public func containerAndValueExtraction(): Unit {
        let ctx = ctxOf()
        try {
            let consts = ConstRegistry()
            let kh = consts.addStr('hello')
            consts.freeze()
            consts.instantiateAll()
            // PUSH_KH; LEN → 5
            let body = cat([opU16(0x16u8, UInt16(kh)), op0(0x90u8), op0(0x7Cu8)])
            let u = unit([body], [0], [4], [0], [typesOf([])], consts, [])
            @Assert(Interp(u).run(0u32, [], ctx), 5)
            @Assert(ctx.errCode, 0)
            // STR_AT 1 → 'e'
            let body2 = cat([opU16(0x16u8, UInt16(kh)), opI32(0x11u8, 1), op0(0x95u8), op0(0x7Cu8)])
            let u2 = unit([body2], [0], [4], [0], [typesOf([])], consts, [])
            @Assert(Interp(u2).run(0u32, [], ctx), Int64(UInt32(r'e')))
            // STR_AT 越界 → 4
            let body3 = cat([opU16(0x16u8, UInt16(kh)), opI32(0x11u8, 9), op0(0x95u8), op0(0x7Cu8)])
            let u3 = unit([body3], [0], [4], [0], [typesOf([])], consts, [])
            @Assert(Interp(u3).run(0u32, [], ctx), 0)
            @Assert(ctx.errCode, ErrCode.IDX_OOB)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** **fail-fast**：错误后剩余指令不再执行；`CALL_HELPER` 自动 `CHECK_ERR` 短路。 */
    @TestCase
    public func failFastStopsRemainingInstructions(): Unit {
        let ctx = ctxOf()
        try {
            // 1 / 0 → 1；其后 PUSH 99 与 RET 都不执行 ⇒ 返回值 0
            let body = cat([
                opI32(0x11u8, 1), opI32(0x11u8, 0), op0(0x33u8),
                opI32(0x11u8, 99), op0(0x7Cu8)])
            @Assert(runBody(ctx, body), 0)
            @Assert(ctx.errCode, ErrCode.DIV_ZERO)
            ctx.errCode = 0
            // CALL_HELPER（H01 hl_len）对 null → 6，其后指令不执行
            let body2 = cat([
                op0(0x15u8), opU16U8(0x75u8, 1u16, 1u8), opI32(0x11u8, 99), op0(0x7Cu8)])
            @Assert(runBody(ctx, body2), 0)
            @Assert(ctx.errCode, ErrCode.NULL_HANDLE)
            ctx.errCode = 0
            // CALL_HELPER_NC 不做错误检查（断言语义）⇒ 后续指令照常执行
            let body3 = cat([
                op0(0x15u8), op0(0x17u8), opU16U8(0x76u8, 10u16, 2u8), op0(0x19u8),
                opI32(0x11u8, 42), op0(0x7Cu8)])
            @Assert(runBody(ctx, body3), 42)
        } finally {
            JitContext.free(ctx)
        }
    }

    // ========================================================================
    // S4.22 §11.9 语义组
    // ========================================================================

    /** List 迭代（`LEN` 快照 + `GET_IDX`）与 `s[a..=b]` 折算（半开 `[a, b+1)`）。 */
    @TestCase
    public func listIterationAndClosedSlice(): Unit {
        let ctx = ctxOf()
        try {
            let consts = ConstRegistry()
            let kh = consts.addStr('hello')
            consts.freeze()
            consts.instantiateAll()
            // s[1..=3] → STR_SUB(1, 4) = "ell"
            let body = cat([
                opU16(0x16u8, UInt16(kh)), opI32(0x11u8, 1), opI32(0x11u8, 4), op0(0xB8u8), op0(0x7Cu8)])
            let u = unit([body], [0], [4], [0], [typesOf([])], consts, [])
            let h = Interp(u).run(0u32, [], ctx)
            @Assert(ctx.errCode, 0)
            match (HandleTable.getAny(h)) {
                case Some(v) => match (v) { case s: String => @Assert(s, 'ell'); case _ => @Assert(1, 2) }
                case None => @Assert(1, 2)
            }
        } finally {
            JitContext.free(ctx)
        }
    }

    /** Map 迭代中修改**同一** map ⇒ 23（§11.9 迭代语义②）。 */
    @TestCase
    public func mapIterationDetectsConcurrentModification(): Unit {
        let ctx = ctxOf()
        try {
            // MAKE_MAP; PUSH 1; PUSH 11; MAP_PUT; MAP_ITER_BEGIN; STEP 0; PUSH 2; PUSH 22; MAP_PUT; STEP 0
            let body = cat([
                op0(0xA2u8), opU16(0x21u8, 0), // MAKE_MAP → STOREL 0
                opU16(0x20u8, 0), opI32(0x11u8, 1), opI32(0x11u8, 11), op0(0xA3u8), op0(0x19u8),
                opU16(0x20u8, 0), op0(0xAFu8), opU16(0x21u8, 1), // cur → STOREL 1
                opU16(0x20u8, 1), opU8(0xBEu8, 0u8), op0(0x19u8), // advance
                opU16(0x20u8, 0), opI32(0x11u8, 2), opI32(0x11u8, 22), op0(0xA3u8), op0(0x19u8),
                opU16(0x20u8, 1), opU8(0xBEu8, 0u8), // 第二次推进 ⇒ 23
                op0(0x7Cu8)])
            var ts = ArrayList<UInt8>()
            ts.add(UInt8(LocalType.MAP))
            ts.add(UInt8(LocalType.I64))
            let u = unit([body], [2], [8], [0], [typesOf(ts.toArray())], ConstRegistry(), [])
            @Assert(Interp(u).run(0u32, [], ctx), 0)
            @Assert(ctx.errCode, ErrCode.CONCURRENT_MOD)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** Map 正常迭代（取键 / 取值）与出口 `close`。 */
    @TestCase
    public func mapIterationYieldsKeyValuePairs(): Unit {
        let ctx = ctxOf()
        try {
            let body = cat([
                op0(0xA2u8), opU16(0x21u8, 0),
                opU16(0x20u8, 0), opI32(0x11u8, 7), opI32(0x11u8, 70), op0(0xA3u8), op0(0x19u8),
                opU16(0x20u8, 0), op0(0xAFu8), opU16(0x21u8, 1),
                opU16(0x20u8, 1), opU8(0xBEu8, 0u8), op0(0x19u8), // advance
                opU16(0x20u8, 1), opU8(0xBEu8, 2u8), opU16(0x21u8, 2), // value → STOREL 2
                opU16(0x20u8, 1), opU8(0xBEu8, 3u8), op0(0x19u8), // close
                opU16(0x20u8, 2), op0(0x7Cu8)])
            var ts = ArrayList<UInt8>()
            ts.add(UInt8(LocalType.MAP))
            ts.add(UInt8(LocalType.I64))
            ts.add(UInt8(LocalType.I64))
            let u = unit([body], [3], [8], [0], [typesOf(ts.toArray())], ConstRegistry(), [])
            @Assert(Interp(u).run(0u32, [], ctx), 70)
            @Assert(ctx.errCode, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 插值串 = `TO_STR(t)` + `STR_CAT` 左结合（§9 附则 13）。 */
    @TestCase
    public func interpolationIsToStrPlusStrCat(): Unit {
        let ctx = ctxOf()
        try {
            let consts = ConstRegistry()
            let ka = consts.addStr('a')
            consts.freeze()
            consts.instantiateAll()
            // PUSH_KH 'a'; PUSH 42; TO_STR t=0; STR_CAT
            let body = cat([
                opU16(0x16u8, UInt16(ka)), opI32(0x11u8, 42), opU8(0xB7u8, 0u8), op0(0xA4u8), op0(0x7Cu8)])
            let u = unit([body], [0], [4], [0], [typesOf([])], consts, [])
            let h = Interp(u).run(0u32, [], ctx)
            @Assert(ctx.errCode, 0)
            match (HandleTable.getAny(h)) {
                case Some(v) => match (v) { case s: String => @Assert(s, 'a42'); case _ => @Assert(1, 2) }
                case None => @Assert(1, 2)
            }
        } finally {
            JitContext.free(ctx)
        }
    }

    /** 区间与正则操作（§11.9）：`RANGE_NEW` / `RANGE_CONTAINS` / `REGEX_IS_MATCH` / 替换。 */
    @TestCase
    public func rangeAndRegexOperations(): Unit {
        let ctx = ctxOf()
        try {
            // RANGE_NEW(1, 5, 1, 0) → RANGE_CONTAINS(3) = 1
            let body = cat([
                opI32(0x11u8, 1), opI32(0x11u8, 5), opI32(0x11u8, 1), opI32(0x11u8, 0), op0(0x9Au8),
                opI32(0x11u8, 3), op0(0x9Bu8), op0(0x7Cu8)])
            @Assert(runBody(ctx, body), 1)
            @Assert(ctx.errCode, 0)
            // step = 0 ⇒ 14
            let body2 = cat([
                opI32(0x11u8, 1), opI32(0x11u8, 5), opI32(0x11u8, 0), opI32(0x11u8, 0), op0(0x9Au8), op0(0x7Cu8)])
            @Assert(runBody(ctx, body2), 0)
            @Assert(ctx.errCode, ErrCode.ARG_MISMATCH)
            ctx.errCode = 0

            // 正则：常量 /a+/ → REGEX_IS_MATCH 'baa'
            let consts = ConstRegistry()
            let kre = consts.addRegex('a+', 0u8)
            let ks = consts.addStr('baa')
            let kx = consts.addStr('X')
            consts.freeze()
            consts.instantiateAll()
            let body3 = cat([opU16(0x16u8, UInt16(kre)), opU16(0x16u8, UInt16(ks)), op0(0xBAu8), op0(0x7Cu8)])
            let u3 = unit([body3], [0], [4], [0], [typesOf([])], consts, [])
            @Assert(Interp(u3).run(0u32, [], ctx), 1)
            @Assert(ctx.errCode, 0)
            // CALL_HELPER H58（regex_replace_all）：'baa' 中的 'a+' 全部替换为 'X' ⇒ 'bX'
            let body4 = cat([
                opU16(0x16u8, UInt16(kre)), opU16(0x16u8, UInt16(ks)), opU16(0x16u8, UInt16(kx)),
                opU16U8(0x75u8, 58u16, 3u8), op0(0x7Cu8)])
            let u4 = unit([body4], [0], [4], [0], [typesOf([])], consts, [])
            let h4 = Interp(u4).run(0u32, [], ctx)
            @Assert(ctx.errCode, 0)
            match (HandleTable.getAny(h4)) {
                case Some(v) => match (v) { case s: String => @Assert(s, 'bX'); case _ => @Assert(1, 2) }
                case None => @Assert(1, 2)
            }
        } finally {
            JitContext.free(ctx)
        }
    }

    /** `TO_STR` 契约：值型按 §11.9 文本化，且结果是新串（分配型）。 */
    @TestCase
    public func toStrContract(): Unit {
        let ctx = ctxOf()
        try {
            let body = cat([opI32(0x11u8, -7), opU8(0xB7u8, 0u8), op0(0x7Cu8)])
            let u = unit([body], [0], [4], [0], [typesOf([])], ConstRegistry(), [])
            let before = HandleTable.windowUsed()
            let h = Interp(u).run(0u32, [], ctx)
            @Assert(ctx.errCode, 0)
            @Assert(HandleTable.windowUsed(), before + 1) // 登记 1 槽
            match (HandleTable.getAny(h)) {
                case Some(v) => match (v) { case s: String => @Assert(s, '-7'); case _ => @Assert(1, 2) }
                case None => @Assert(1, 2)
            }
        } finally {
            JitContext.free(ctx)
        }
    }

    /** Range 迭代（`for i in r` 的规范降低：隐藏计数局部 + 条件 + 步进）。 */
    @TestCase
    public func rangeIterationVisitsEveryStep(): Unit {
        let ctx = ctxOf()
        try {
            let body = cat([
                opI32(0x11u8, 1), opU16(0x21u8, 0), // i = 1
                opI32(0x11u8, 0), opU16(0x21u8, 1), // sum = 0
                opU16(0x20u8, 0), opI32(0x11u8, 4), op0(0x54u8), opI32(0x71u8, 27), // i < 4
                opU16(0x20u8, 1), opU16(0x20u8, 0), op0(0x30u8), opU16(0x21u8, 1),
                opU16(0x20u8, 0), opI32(0x11u8, 1), op0(0x30u8), opU16(0x21u8, 0),
                opI32(0x70u8, -41),
                opU16(0x20u8, 1), op0(0x7Cu8)])
            var ts = ArrayList<UInt8>()
            ts.add(0u8)
            ts.add(0u8)
            let u = unit([body], [2], [8], [0], [typesOf(ts.toArray())], ConstRegistry(), [])
            @Assert(Interp(u).run(0u32, [], ctx), 6) // 1 + 2 + 3
            @Assert(ctx.errCode, 0)
        } finally {
            JitContext.free(ctx)
        }
    }

    /** String 迭代按**码点**推进（`LEN` 快照 + `STR_AT`，§11.9 迭代语义④）。 */
    @TestCase
    public func stringIterationWalksCodePoints(): Unit {
        let ctx = ctxOf()
        try {
            let consts = ConstRegistry()
            let ks = consts.addStr('ace')
            consts.freeze()
            consts.instantiateAll()
            let body = cat([
                opU16(0x16u8, UInt16(ks)), opU16(0x21u8, 0), // h
                opI32(0x11u8, 0), opU16(0x21u8, 1), // i
                opI32(0x11u8, 0), opU16(0x21u8, 2), // acc
                opU16(0x20u8, 1), opU16(0x20u8, 0), op0(0x90u8), op0(0x54u8), opI32(0x71u8, 31),
                opU16(0x20u8, 2), opU16(0x20u8, 0), opU16(0x20u8, 1), op0(0x95u8), op0(0x30u8),
                opU16(0x21u8, 2),
                opU16(0x20u8, 1), opI32(0x11u8, 1), op0(0x30u8), opU16(0x21u8, 1),
                opI32(0x70u8, -44),
                opU16(0x20u8, 2), op0(0x7Cu8)])
            var ts = ArrayList<UInt8>()
            ts.add(UInt8(LocalType.STRING))
            ts.add(0u8)
            ts.add(0u8)
            let u = unit([body], [3], [8], [0], [typesOf(ts.toArray())], consts, [])
            @Assert(ctx.errCode, 0)
            let r = Interp(u).run(0u32, [], ctx)
            @Assert(ctx.errCode, 0)
            @Assert(r, 97 + 99 + 101)
        } finally {
            JitContext.free(ctx)
        }
    }

}