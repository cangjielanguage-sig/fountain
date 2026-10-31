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
import fountain::f_jit.bytecode.InsnDecoder
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HelperAddresses

/**
 * AArch64 指令降低（§12.4）。
 *
 * 约定：`x19` = ctx、`x29` = 帧指针、`sp` = 操作数栈顶；
 * `locals[i]` = `[x29, #-32-8i]`；二元 `a b` 中 `b@[sp]`、`a@[sp+8]`。
 *
 * 当前覆盖 0x00–0x8F 的无 helper 子集；遇到未实现指令返回 false，由调用方降级解释器。
 */
internal class A64Lower {
    private let e: A64Emitter
    private let fn: FuncEntry
    private let frame: Int64
    private let helperDispatch: Int64
    /** 常量句柄镜像基址（`PUSH_KH` 烘焙；0 = 未提供 → 含 PUSH_KH 即降级）。 */
    private let constBase: Int64
    /** `fnTable` 基址（`CALL_FUNC` 烘焙；0 = 未提供 → 含 CALL_FUNC 即降级）。 */
    private let fnTableBase: Int64
    private var ok: Bool
    private var seq: Int64

    init(e: A64Emitter, fn: FuncEntry, frame: Int64, constBase: Int64,
        fnTableBase: Int64) {
        this.e = e
        this.fn = fn
        this.frame = frame
        this.helperDispatch = HelperAddresses.dispatch()
        this.constBase = constBase
        this.fnTableBase = fnTableBase
        this.ok = true
        this.seq = 0
    }

    func success(): Bool {
        this.ok
    }

    private func bail(k: Int64): Unit {
        this.e.movImm64(11, k)
        this.e.strOff(11, 19, 0)
        this.e.movReg(0, 31)
        this.e.b('epilogue')
    }

    private func bailLabel(k: Int64, label: String): Unit {
        this.e.bind(label)
        this.bail(k)
    }

    /**
     * 收敛前的单次转储（T50）：`jit_dump(dbgBase, errCode, fnId, nLocals, &locals[0])`。
     *
     * `DbgDump` 内部仍按 `dbgBase=0` / `errCode≤0` / 首格哨兵三条规则跳过，
     * 因此 DEOPT(-1)、INTERRUPT(-2) 与「外层传播帧」都不会覆盖最深失败帧。
     */
    private func emitDump(): Unit {
        this.e.subImm(4, 29, 40)
        this.e.ldrOff(0, 19, 56)
        this.e.ldrOff(1, 19, 0)
        this.e.movImm64(2, Int64(this.fn.fnId))
        this.e.movImm64(3, Int64(this.fn.nLocals))
        this.e.movImm64(11, HelperAddresses.dump())
        this.e.blr(11)
    }

    /** 降低单函数体；返回是否全部支持。 */
    func lower(unit: LoadedUnit): Unit {
        var off = Int64(this.fn.codeOff)
        let end = Int64(this.fn.codeOff) + Int64(this.fn.codeLen)
        while (off < end) {
            this.e.bind('L${off}')
            let insn = InsnDecoder.decode(unit.code, off)
            let next = off + insn.size
            this.translate(insn.op, insn.operands, off, next)
            off = next
        }
    }

    private static func u8(bs: Array<UInt8>, at: Int64): Int64 {
        Int64(bs[at])
    }

    private static func i8(bs: Array<UInt8>, at: Int64): Int64 {
        let v = Int64(bs[at])
        if (v >= 128) { v - 256 } else { v }
    }

    private static func u16(bs: Array<UInt8>, at: Int64): Int64 {
        Int64(bs[at]) | (Int64(bs[at + 1]) << 8)
    }

    private static func i32(bs: Array<UInt8>, at: Int64): Int64 {
        let v = Int64(bs[at]) | (Int64(bs[at + 1]) << 8) | (Int64(bs[at + 2]) << 16) | (Int64(bs[at + 3]) << 24)
        if (v >= 2147483648) { v - 4294967296 } else { v }
    }

    private static func u32(bs: Array<UInt8>, at: Int64): Int64 {
        Int64(bs[at]) | (Int64(bs[at + 1]) << 8) | (Int64(bs[at + 2]) << 16) | (Int64(bs[at + 3]) << 24)
    }

    private static func i64(bs: Array<UInt8>, at: Int64): Int64 {
        var v: Int64 = 0
        var k = 0
        while (k < 8) {
            v = v | (Int64(bs[at + k]) << (8 * k))
            k = k + 1
        }
        v
    }

    private func pushX(reg: Int64): Unit {
        this.e.subImm(20, 20, 8)
        this.e.strOff(reg, 20, 0)
    }

    private func loadLocal(i: Int64, reg: Int64): Unit {
        this.e.ldrOff(reg, 29, -40 - 8 * i)
    }

    private func storeLocal(i: Int64, reg: Int64): Unit {
        this.e.strOff(reg, 29, -40 - 8 * i)
    }

    private func translate(op: UInt8, ops: Array<UInt8>, at: Int64, next: Int64): Unit {
        match (op) {
            case 0x00 => this.e.nop()
            case 0x01 => this.e.brk()
            case 0x02 => this.e.nop()
            case 0x03 =>
                this.e.movImm64(11, A64Lower.i32(ops, 0))
                this.e.strOff(11, 19, 8)
            case 0x04 =>
                this.e.ldrOff(11, 19, 0)
                this.e.cbz(11, 'chk${at}')
                this.emitDump()
                this.e.movReg(0, 31)
                this.e.b('epilogue')
                this.e.bind('chk${at}')
            case 0x05 =>
                this.bail(A64Lower.i8(ops, 0))
            case 0x06 => this.e.nop()
            case 0x07 =>
                let need = A64Lower.u16(ops, 0)
                this.e.movReg(11, 29)
                this.e.subImm(11, 11, this.frame)
                this.e.subReg(11, 11, 31)
                this.e.movImm64(12, need)
                this.e.cmpReg(11, 12)
                this.e.bCond(A64Cond.LO, 'deopt')
            case 0x10 =>
                this.e.movImm64(9, A64Lower.i8(ops, 0))
                this.pushX(9)
            case 0x11 =>
                this.e.movImm64(9, A64Lower.i32(ops, 0))
                this.pushX(9)
            case 0x12 =>
                this.e.movImm64(9, A64Lower.i64(ops, 0))
                this.pushX(9)
            case 0x13 =>
                this.e.movImm64(9, A64Lower.i64(ops, 0))
                this.e.fmovDFromX(0, 9)
                this.e.subImm(20, 20, 8)
                this.e.strD(0, 20, 0)
            case 0x14 =>
                this.e.movImm64(9, if (A64Lower.u8(ops, 0) == 0) { 0 } else { 1 })
                this.pushX(9)
            case 0x15 =>
                this.e.movReg(9, 31)
                this.pushX(9)
            case 0x16 =>
                // PUSH_KH idx：常量句柄镜像（基址编译期烘焙，§12.4）
                if (this.constBase == 0) {
                    this.ok = false
                } else {
                    let idx = A64Lower.u16(ops, 0)
                    this.e.movImm64(9, this.constBase + 8 * idx)
                    this.e.ldrAbs(9, 9, 0)
                    this.pushX(9)
                }
            case 0x17 =>
                this.e.ldrOff(9, 20, 0)
                this.pushX(9)
            case 0x18 =>
                this.e.ldrOff(9, 20, 0)
                this.e.ldrOff(10, 20, 8)
                this.pushX(9)
                this.pushX(10)
            case 0x19 => this.e.addImm(20, 20, 8)
            case 0x1A => this.e.addImm(20, 20, 16)
            case 0x1B =>
                this.e.ldrOff(9, 20, 0)
                this.e.ldrOff(10, 20, 8)
                this.e.strOff(9, 20, 8)
                this.e.strOff(10, 20, 0)
            case 0x1C =>
                this.e.ldrOff(9, 20, 8 * A64Lower.u8(ops, 0))
                this.pushX(9)
            case 0x20 =>
                let i = A64Lower.u16(ops, 0)
                this.loadLocal(i, 9)
                this.pushX(9)
            case 0x21 =>
                let i = A64Lower.u16(ops, 0)
                this.e.ldrOff(9, 20, 0)
                this.e.addImm(20, 20, 8)
                this.storeLocal(i, 9)
            case 0x22 => this.loadLocal(0, 9); this.pushX(9)
            case 0x23 => this.loadLocal(1, 9); this.pushX(9)
            case 0x24 => this.loadLocal(2, 9); this.pushX(9)
            case 0x25 => this.loadLocal(3, 9); this.pushX(9)
            case 0x26 =>
                // LOAD_CAP idx：locals[0] 闭包句柄 + idx → H56
                let capIdx = A64Lower.u16(ops, 0)
                this.loadLocal(0, 9)
                this.pushX(9)
                this.e.movImm64(9, capIdx)
                this.pushX(9)
                this.helperCall(56, 2, 0)
            case 0x30 => this.intBin(A64Bin.ADD)
            case 0x31 => this.intBin(A64Bin.SUB)
            case 0x32 => this.intBin(A64Bin.MUL)
            case 0x33 => this.intDiv(false, at)
            case 0x34 => this.intDiv(true, at)
            case 0x35 =>
                this.e.ldrOff(9, 20, 0)
                this.e.word(0xEB0903E9u32) // negs x9,x9
                this.e.bCond(A64Cond.VS, 'bail3')
                this.e.strOff(9, 20, 0)
            case 0x36 =>
                this.e.ldrOff(9, 20, 0)
                this.e.cmpImm(9, 0)
                this.e.bCond(A64Cond.GE, 'abs${at}')
                this.e.word(0xEB0903E9u32) // negs x9,x9
                this.e.bCond(A64Cond.VS, 'bail3')
                this.e.bind('abs${at}')
                this.e.strOff(9, 20, 0)
            case 0x37 => this.intMinMax(false)
            case 0x38 => this.intMinMax(true)
            case 0x39 => this.intBin(A64Bin.ADD_WRAP)
            case 0x3A =>
                this.e.ldrOff(9, 20, 0)
                this.e.clz(9, 9)
                this.e.strOff(9, 20, 0)
            case 0x3B =>
                // IPOPCNT：fmov d8,x9; cnt v8.8b,v8.8b; addv b8,v8.8b; fmov x9,d8
                this.e.ldrOff(9, 20, 0)
                this.e.fmovDFromX(8, 9)
                this.e.cntBytes(8, 8)
                this.e.addvB(8, 8)
                this.e.fmovXFromD(9, 8)
                this.e.strOff(9, 20, 0)
            case 0x40 => this.floatBin(0)
            case 0x41 => this.floatBin(1)
            case 0x42 => this.floatBin(2)
            case 0x43 => this.floatBin(3)
            case 0x44 => this.floatBin(4)
            case 0x45 =>
                this.e.ldrD(0, 20, 0)
                this.e.fneg(0, 0)
                this.e.strD(0, 20, 0)
            case 0x46 =>
                this.e.ldrD(0, 20, 0)
                this.e.fabs(0, 0)
                this.e.strD(0, 20, 0)
            case 0x47 => this.floatMinMax(false)
            case 0x48 => this.floatMinMax(true)
            case 0x49 =>
                this.e.ldrD(0, 20, 0)
                this.e.fsqrt(0, 0)
                this.e.strD(0, 20, 0)
            case 0x4A =>
                this.e.ldrD(0, 20, 0)
                this.e.frintm(0, 0)
                this.e.strD(0, 20, 0)
            case 0x4B =>
                this.e.ldrD(0, 20, 0)
                this.e.frintp(0, 0)
                this.e.strD(0, 20, 0)
            case 0x4C =>
                this.e.ldrD(0, 20, 0)
                this.e.frintz(0, 0)
                this.e.strD(0, 20, 0)
            case 0x4D =>
                this.e.ldrD(0, 20, 0)
                this.e.frintn(0, 0)
                this.e.strD(0, 20, 0)
            case 0x50 => this.intCmpI()
            case 0x51 => this.floatCmpTri()
            case 0x52 => this.intCmp(A64Cond.EQ)
            case 0x53 => this.intCmp(A64Cond.NE)
            case 0x54 => this.intCmp(A64Cond.LT)
            case 0x55 => this.intCmp(A64Cond.LE)
            case 0x56 => this.intCmp(A64Cond.GT)
            case 0x57 => this.intCmp(A64Cond.GE)
            case 0x58 => this.floatCmp(A64Cond.EQ, false)
            case 0x59 => this.floatCmp(A64Cond.NE, false)
            case 0x5A => this.floatCmp(A64Cond.LT, false)
            case 0x5B => this.floatCmp(A64Cond.LE, false)
            case 0x5C => this.floatCmp(A64Cond.GT, true)
            case 0x5D => this.floatCmp(A64Cond.GE, true)
            case 0x5E =>
                this.e.ldrOff(9, 20, 0)
                this.e.eorImm1(9, 9) // 逻辑非：eor x9,x9,#1（0↔1）
                this.e.strOff(9, 20, 0)
            case 0x5F => this.boolBin(0)
            case 0x60 => this.boolBin(1)
            case 0x61 => this.boolBin(2)
            case 0x62 => this.bitBin(0)
            case 0x63 => this.bitBin(1)
            case 0x64 => this.bitBin(2)
            case 0x65 =>
                this.e.ldrOff(9, 20, 0)
                this.e.mvn(9, 9)
                this.e.strOff(9, 20, 0)
            case 0x66 => this.shiftBin(0)
            case 0x67 => this.shiftBin(1)
            case 0x68 => this.shiftBin(2)
            case 0x69 => this.intCmp(A64Cond.EQ)
            case 0x6A => this.intCmp(A64Cond.NE)
            case 0x6B => this.helperCall(9, 2, 0)
            case 0x6C => this.helperCall(11, 2, 0)
            case 0x6D => this.helperCall(13, 2, 0)
            case 0x6E => this.helperCall(15, 2, 0)
            case 0x70 =>
                // rel32 是**有符号**（向后跳为负；§5/§11.7），按 u32 读会把回边变成巨大正偏移
                let rel = A64Lower.i32(ops, 0)
                this.e.b('L${next + rel}')
            case 0x71 =>
                let rel = A64Lower.i32(ops, 0)
                this.e.ldrOff(9, 20, 0)
                this.e.addImm(20, 20, 8)
                this.e.cbz(9, 'L${next + rel}')
            case 0x72 =>
                let rel = A64Lower.i32(ops, 0)
                this.e.ldrOff(9, 20, 0)
                this.e.addImm(20, 20, 8)
                this.e.cbnz(9, 'L${next + rel}')
            case 0x74 =>
                // 回边：STACK_GUARD + H22 安全点，再跳目标
                let need = this.frame
                this.e.movReg(11, 29)
                this.e.subImm(11, 11, this.frame)
                this.e.subReg(11, 11, 31)
                this.e.movImm64(12, need)
                this.e.cmpReg(11, 12)
                this.e.bCond(A64Cond.LO, 'deopt')
                this.helperCall0(22)
                this.e.b('L${next + A64Lower.i32(ops, 0)}')
            case 0x75 => this.helperCall(A64Lower.u16(ops, 0), A64Lower.u8(ops, 2), 0)
            case 0x76 => this.helperCall(A64Lower.u16(ops, 0), A64Lower.u8(ops, 2), 1)
            case 0x77 => this.helperCall(A64Lower.u16(ops, 0), A64Lower.u8(ops, 2), 2)
            case 0x78 => this.callFunc(A64Lower.u16(ops, 0), A64Lower.u8(ops, 2))
            case 0x79 => this.helperCall(63, Int64(A64Lower.u8(ops, 0)) + 1, 0)
            case 0x7A => this.bail(18) // HW_OPEN：M1 未启用
            case 0x7B => this.e.nop()   // HW_CLOSE
            case 0x7F => this.callClosure(A64Lower.u8(ops, 0))
            case 0x7C =>
                this.e.ldrOff(0, 20, 0)
                this.e.b('epilogue')
            case 0x7D =>
                this.e.movReg(0, 31)
                this.e.b('epilogue')
            case 0x7E =>
                this.e.movReg(0, 31)
                this.e.b('epilogue')
            case 0x81 =>
                this.toI64(A64Lower.u8(ops, 0), at)
            case 0x82 =>
                this.e.ldrOff(9, 20, 0)
                this.e.scvtf(0, 9)
                this.e.strD(0, 20, 0)
            case 0x80 =>
                this.castLike(A64Lower.u16(ops, 0), A64Lower.u8(ops, 2), at)
            case 0x83 =>
                this.e.movImm64(9, A64Lower.u16(ops, 0))
                this.pushX(9)
                this.helperCall(17, 2, 0)
            case 0x84 =>
                if (A64Lower.u8(ops, 2) == 0) {
                    this.e.movImm64(9, A64Lower.u16(ops, 0))
                    this.pushX(9)
                    this.helperCall(19, 2, 0)
                } else {
                    this.castLike(A64Lower.u16(ops, 0), 1, at)
                }
            case 0x85 =>
                this.bail(17)
            case 0x86 =>
                this.e.ldrOff(9, 20, 0)
                this.e.addImm(20, 20, 8)
                this.e.cmpImm(9, 0)
                this.e.cbnz(9, 'asm${at}')
                this.bail(A64Lower.u8(ops, 0))
                this.e.bind('asm${at}')
            case 0x87 =>
                this.bail(A64Lower.u8(ops, 0))
            case 0x88 =>
                this.e.ldrOff(9, 20, 0)
                this.e.cbnz(9, 'gnnz${at}')
                if (A64Lower.u8(ops, 0) == 0) {
                    this.bail(6)
                } else {
                    this.e.b('deopt')
                }
                this.e.bind('gnnz${at}')
            case 0x89 => this.helperCall(18, 1, 0)
            // ---- 0x90–0xBF：全量 CALL_HELPER 路由（§12.4）----
            case 0x90 => this.lenOp()
            case 0x91 => this.helperCall(2, 2, 0)
            case 0x92 => this.helperCall(4, 2, 0)
            case 0x93 => this.helperCall(5, 3, 0)
            case 0x94 => this.helperCall(6, 2, 0)
            case 0x95 => this.helperCall(8, 2, 0)
            case 0x96 =>
                this.e.movImm64(9, A64Lower.u8(ops, 0))
                this.pushX(9)
                this.helperCall(14, 2, 0)
            case 0x97 => this.helperCall(16, 1, 0)
            case 0x98 => this.helperCall(12, 1, 0)
            case 0x99 => this.helperCall(18, 1, 0)
            case 0x9A => this.helperCall(41, 4, 0)
            case 0x9B => this.helperCall(42, 2, 0)
            case 0x9C =>
                this.helperCall(if (A64Lower.u8(ops, 0) == 0) { 28 } else { 29 }, 1, 0)
            case 0x9D =>
                // DEC_TO_I64：mode1 时 DEC_RANGE(9) 改写为 DEOPT(-1)
                this.helperCall(30, 1, 1)
                this.seq = this.seq + 1
                let doneLabel = 'dec${this.seq}'
                let failLabel = 'decf${this.seq}'
                this.e.ldrOff(11, 19, 0)
                this.e.cbz(11, doneLabel)
                if (A64Lower.u8(ops, 0) == 1) {
                    this.e.cmpImm(11, 9)
                    this.e.bCond(A64Cond.NE, failLabel)
                    this.e.movImm64(11, -1)
                    this.e.strOff(11, 19, 0)
                    this.e.b(doneLabel)
                    this.e.bind(failLabel)
                }
                this.e.movReg(0, 31)
                this.e.b('epilogue')
                this.e.bind(doneLabel)
            case 0x9E => this.helperCall(31, 1, 0)
            case 0xA0 => this.helperCall(70, 0, 0)
            case 0xA1 => this.helperCall(43, 2, 0)
            case 0xA2 => this.helperCall(71, 0, 0)
            case 0xA3 => this.helperCall(44, 3, 0)
            case 0xA4 => this.helperCall(32, 2, 0)
            case 0xA5 => this.helperCall(24, 2, 0)
            case 0xA6 => this.helperCall(25, 2, 0)
            case 0xA7 => this.helperCall(26, 2, 0)
            case 0xA8 => this.helperCall(27, 2, 0)
            case 0xA9 => this.ok = false // DT_NEW：汇编期禁发
            case 0xAA => this.ok = false // DUR_NEW：汇编期禁发
            case 0xAB => this.helperCall(45, 3, 0)
            case 0xAC => this.helperCall(46, 3, 0)
            case 0xAD => this.helperCall(47, 2, 0)
            case 0xAE => this.helperCall(48, 2, 0)
            case 0xAF => this.helperCall(49, 1, 0)
            case 0xB0 => this.helperCall(34, 2, 0)
            case 0xB1 => this.helperCall(35, 2, 0)
            case 0xB2 => this.helperCall(36, 2, 0)
            case 0xB3 => this.helperCall(37, 2, 0)
            case 0xB4 => this.helperCall(38, 2, 0)
            case 0xB5 => this.helperCall(39, 2, 0)
            case 0xB6 => this.helperCall(40, 1, 0)
            case 0xB7 =>
                this.e.movImm64(9, A64Lower.u8(ops, 0))
                this.pushX(9)
                this.helperCall(33, 2, 0)
            case 0xB8 => this.helperCall(50, 3, 0)
            case 0xB9 => this.helperCall(51, 3, 0)
            case 0xBA => this.helperCall(52, 2, 0)
            case 0xBB => this.helperCall(53, 2, 0)
            case 0xBC => this.helperCall(60, 2, 0)
            case 0xBD => this.helperCall(61, 2, 0)
            case 0xBE =>
                this.e.movImm64(9, A64Lower.u8(ops, 0))
                this.pushX(9)
                this.helperCall(62, 2, 0)
            case 0xBF => this.helperCall(69, 1, 0)
            case _ => this.ok = false
        }
    }

    /** 统一 helper 调用：variant 0=普通、1=NC（无 CHECK_ERR）、2=V（无结果）。 */
    private func helperCall(hid: Int64, argc: Int64, variant: Int64): Unit {
        this.e.movImm64(0, hid)
        this.e.movReg(1, 19)
        if (argc == 0) {
            this.e.movReg(2, 31)
        } else {
            this.e.addImm(2, 20, 8 * (argc - 1))
        }
        this.e.movImm64(3, argc)
        this.e.movImm64(9, this.helperDispatch)
        this.e.blr(9)
        if (variant == 2) {
            this.e.addImm(20, 20, 8 * argc)
        } else {
            if (argc == 0) {
                this.e.subImm(20, 20, 8)
                this.e.strOff(0, 20, 0)
            } else {
                this.e.strOff(0, 20, 8 * (argc - 1))
                this.e.addImm(20, 20, 8 * (argc - 1))
            }
            if (variant == 0) {
                this.seq = this.seq + 1
                let okLabel = 'hok${this.seq}'
                this.e.ldrOff(11, 19, 0)
                this.e.cbz(11, okLabel)
                this.emitDump()
                this.e.movReg(0, 31)
                this.e.b('epilogue')
                this.e.bind(okLabel)
            }
        }
    }

    /** 零参 V 变体（H22 安全点）。 */
    private func helperCall0(hid: Int64): Unit {
        this.e.movImm64(0, hid)
        this.e.movReg(1, 19)
        this.e.movReg(2, 31)
        this.e.movReg(3, 31)
        this.e.movImm64(9, this.helperDispatch)
        this.e.blr(9)
        this.seq = this.seq + 1
        let okLabel = 'h0ok${this.seq}'
        this.e.ldrOff(11, 19, 0)
        this.e.cbz(11, okLabel)
        this.emitDump()
        this.e.movReg(0, 31)
        this.e.b('epilogue')
        this.e.bind(okLabel)
    }

    /** 错误槽非 0 → 立刻收敛（共享出口）。 */
    private func checkErr(): Unit {
        this.seq = this.seq + 1
        let okLabel = 'ce${this.seq}'
        this.e.ldrOff(11, 19, 0)
        this.e.cbz(11, okLabel)
        this.emitDump()
        this.e.movReg(0, 31)
        this.e.b('epilogue')
        this.e.bind(okLabel)
    }

    /** helper 编号已在寄存器（`LEN` 的 tag 分派）。 */
    private func helperCallHidReg(hidReg: Int64, argc: Int64): Unit {
        this.e.movReg(0, hidReg)
        this.e.movReg(1, 19)
        if (argc == 0) {
            this.e.movReg(2, 31)
        } else {
            this.e.addImm(2, 20, 8 * (argc - 1))
        }
        this.e.movImm64(3, argc)
        this.e.movImm64(9, this.helperDispatch)
        this.e.blr(9)
        this.e.strOff(0, 20, 8 * (argc - 1))
        this.e.addImm(20, 20, 8 * (argc - 1))
        this.checkErr()
    }

    /** `LEN`：H18 取 tag → LIST=1/H01、MAP=2/H03、其余 H07。 */
    private func lenOp(): Unit {
        this.e.ldrOff(9, 20, 0)
        this.pushX(9) // DUP（保留 h）
        this.helperCall(18, 1, 0) // tag 覆盖副本
        this.e.ldrOff(10, 20, 0)
        this.e.addImm(20, 20, 8) // 弹 tag
        this.e.movImm64(12, 7)
        this.e.movImm64(13, 1)
        this.e.cmpImm(10, 1)
        this.e.csel(12, 13, 12, A64Cond.EQ)
        this.e.movImm64(13, 3)
        this.e.cmpImm(10, 2)
        this.e.csel(12, 13, 12, A64Cond.EQ)
        this.helperCallHidReg(12, 1)
    }

    /** `CALL_FUNC fid argc`：fnTable 间接调用 + 共窗口 + 重写 fnId。 */
    private func callFunc(fid: Int64, argc: Int64): Unit {
        if (this.fnTableBase == 0) {
            // 未提供入口表基址（桥未建表）→ 降级解释器，避免运行期空表跳转
            this.ok = false
            return
        }
        this.e.movImm64(9, this.fnTableBase + 8 * fid)
        this.e.ldrAbs(10, 9, 0)
        this.e.movReg(0, 19)
        if (argc == 0) {
            this.e.movReg(1, 31)
        } else {
            this.e.addImm(1, 20, 8 * (argc - 1))
        }
        this.e.movImm64(2, argc)
        this.e.blr(10)
        this.checkErr()
        this.e.movImm64(11, Int64(this.fn.fnId))
        this.e.strOff(11, 19, 40)
        if (argc == 0) {
            this.pushX(0)
        } else {
            this.e.strOff(0, 20, 8 * (argc - 1))
            this.e.addImm(20, 20, 8 * (argc - 1))
        }
    }

    /** `CALL_CLOSURE argc`：H55 取 fnId → H57 取 fnTable → 间接调用。 */
    private func callClosure(argc: Int64): Unit {
        let disp = 8 * argc
        // H55(ctx, &closure, 1) → fnId；不覆盖闭包槽（被调帧 locals[0] 仍需要句柄）
        this.e.movImm64(0, 55)
        this.e.movReg(1, 19)
        this.e.addImm(2, 20, disp)
        this.e.movImm64(3, 1)
        this.e.movImm64(9, this.helperDispatch)
        this.e.blr(9)
        // fnId 暂存 [x29,#-32]（跨 H57 调用不可存活于寄存器）
        this.e.strOff(0, 29, -32)
        this.checkErr()
        // H57(ctx) → fnTable 基址
        this.e.movImm64(0, 57)
        this.e.movReg(1, 19)
        this.e.movReg(2, 31)
        this.e.movReg(3, 31)
        this.e.movImm64(9, this.helperDispatch)
        this.e.blr(9)
        this.e.movReg(12, 0)
        this.checkErr()
        this.e.ldrOff(9, 29, -32) // fnId
        this.e.ldrReg(10, 12, 9)
        this.e.movReg(0, 19)
        // 闭包帧实参区 = [闭包句柄, a1..argc]（句柄在低地址），x1 指向句柄
        this.e.addImm(1, 20, disp)
        this.e.movImm64(2, argc)
        this.e.blr(10)
        this.e.movImm64(11, Int64(this.fn.fnId))
        this.e.strOff(11, 19, 40)
        this.checkErr()
        this.e.strOff(0, 20, disp)
        this.e.addImm(20, 20, disp)
    }

    /** `TO_I64 mode`：NaN 与 ±2^63 界外 → mode0 `<bail:13>` / mode1 `<deopt>`。 */
    private func toI64(mode: Int64, at: Int64): Unit {
        this.e.ldrD(0, 20, 0)
        this.e.fcmp(0, 0)
        this.e.bCond(A64Cond.VS, 'ti64bad${at}')
        this.e.movImm64(9, 0x43E0000000000000)
        this.e.fmovDFromX(1, 9)
        this.e.fcmp(0, 1)
        this.e.bCond(A64Cond.GE, 'ti64bad${at}')
        this.e.movImm64(9, -4332462841530417152)
        this.e.fmovDFromX(1, 9)
        this.e.fcmp(0, 1)
        this.e.bCond(A64Cond.LT, 'ti64bad${at}')
        this.e.fcvtzs(9, 0)
        this.e.strOff(9, 20, 0)
        this.e.b('ti64done${at}')
        this.e.bind('ti64bad${at}')
        if (mode == 0) {
            this.bail(13)
        } else {
            this.e.b('deopt')
        }
        this.e.bind('ti64done${at}')
    }

    /** `CAST`/`GUARD_TYPE mode1`：DUP 保留值 → H17 判定 → 失败 bail7 / deopt。 */
    private func castLike(tok: Int64, mode: Int64, at: Int64): Unit {
        this.e.ldrOff(9, 20, 0)
        this.pushX(9) // DUP
        this.e.movImm64(9, tok)
        this.pushX(9)
        this.helperCall(17, 2, 0) // 结果 bool 覆盖副本值槽
        this.e.ldrOff(9, 20, 0)
        this.e.addImm(20, 20, 8) // 弹掉 bool，保留原值
        this.e.cbnz(9, 'castok${at}')
        if (mode == 0) {
            this.bail(7)
        } else {
            this.e.b('deopt')
        }
        this.e.bind('castok${at}')
    }

    private func intBin(kind: Int64): Unit {
        this.e.ldrOff(9, 20, 8)
        this.e.ldrOff(10, 20, 0)
        this.e.addImm(20, 20, 8)
        if (kind == 0) {
            this.e.addsReg(9, 9, 10)
            this.e.bCond(A64Cond.VS, 'bail3')
        } else if (kind == 1) {
            this.e.subsReg(9, 9, 10)
            this.e.bCond(A64Cond.VS, 'bail3')
        } else if (kind == 2) {
            this.e.word(0x9B4A7D2Bu32) // smulh x11,x9,x10
            this.e.mul(9, 9, 10)
            this.e.word(0xEB89FD7Fu32) // cmp x11,x9,asr #63
            this.e.bCond(A64Cond.NE, 'bail3')
        } else {
            this.e.addReg(9, 9, 10)
        }
        this.e.strOff(9, 20, 0)
    }

    private func intDiv(isMod: Bool, at: Int64): Unit {
        this.e.ldrOff(9, 20, 8)
        this.e.ldrOff(10, 20, 0)
        this.e.addImm(20, 20, 8)
        this.e.cbz(10, if (isMod) { 'bail2' } else { 'bail1' })
        this.e.cmpImm(10, -1)
        this.e.bCond(A64Cond.NE, 'divok${at}')
        this.e.movImm64(11, -9223372036854775807 - 1)
        this.e.cmpReg(9, 11)
        if (isMod) {
            this.e.bCond(A64Cond.EQ, 'modzero${at}')
        } else {
            this.e.bCond(A64Cond.EQ, 'bail3')
        }
        this.e.bind('divok${at}')
        this.e.sdiv(11, 9, 10)
        if (isMod) {
            this.e.msub(9, 11, 10, 9)
        } else {
            this.e.movReg(9, 11)
        }
        this.e.strOff(9, 20, 0)
        if (isMod) {
            this.e.b('moddone${at}')
            this.e.bind('modzero${at}')
            this.e.movReg(9, 31)
            this.e.strOff(9, 20, 0)
            this.e.bind('moddone${at}')
        }
    }

    private func intMinMax(isMax: Bool): Unit {
        this.e.ldrOff(10, 20, 0)
        this.e.ldrOff(9, 20, 8)
        this.e.addImm(20, 20, 8)
        this.e.cmpReg(9, 10)
        this.e.csel(9, 9, 10, if (isMax) { A64Cond.GT } else { A64Cond.LT })
        this.e.strOff(9, 20, 0)
    }

    private func intCmpI(): Unit {
        this.e.ldrOff(10, 20, 0)
        this.e.ldrOff(9, 20, 8)
        this.e.addImm(20, 20, 8)
        this.e.cmpReg(9, 10)
        this.e.cset(11, A64Cond.LT)
        this.e.cset(10, A64Cond.GT)
        this.e.subReg(9, 11, 10)
        this.e.strOff(9, 20, 0)
    }

    private func intCmp(cond: Int64): Unit {
        this.e.ldrOff(10, 20, 0)
        this.e.ldrOff(9, 20, 8)
        this.e.addImm(20, 20, 8)
        this.e.cmpReg(9, 10)
        this.e.cset(9, cond)
        this.e.strOff(9, 20, 0)
    }

    private func boolBin(kind: Int64): Unit {
        this.e.ldrOff(10, 20, 0)
        this.e.ldrOff(9, 20, 8)
        this.e.addImm(20, 20, 8)
        if (kind == 0) {
            this.e.andReg(9, 9, 10)
        } else if (kind == 1) {
            this.e.orrReg(9, 9, 10)
        } else {
            this.e.eorReg(9, 9, 10)
        }
        this.e.strOff(9, 20, 0)
    }

    private func bitBin(kind: Int64): Unit {
        this.boolBin(kind)
    }

    private func shiftBin(kind: Int64): Unit {
        this.e.ldrOff(10, 20, 0)
        this.e.ldrOff(9, 20, 8)
        this.e.addImm(20, 20, 8)
        if (kind == 0) {
            this.e.lslv(9, 9, 10)
        } else if (kind == 1) {
            this.e.asrv(9, 9, 10)
        } else {
            this.e.lsrv(9, 9, 10)
        }
        this.e.strOff(9, 20, 0)
    }

    private func floatBin(kind: Int64): Unit {
        this.e.ldrD(0, 20, 8)
        this.e.ldrD(1, 20, 0)
        this.e.addImm(20, 20, 8)
        if (kind == 4) {
            this.e.word(0x9E6703E2u32) // fmov d2,xzr
            this.e.fcmp(1, 2)
            this.e.bCond(A64Cond.EQ, 'bail1')
            this.e.fdiv(0, 0, 1)
        } else if (kind == 0) {
            this.e.fadd(0, 0, 1)
        } else if (kind == 1) {
            this.e.fsub(0, 0, 1)
        } else if (kind == 2) {
            this.e.fmul(0, 0, 1)
        } else {
            this.e.fdiv(0, 0, 1)
        }
        this.e.strD(0, 20, 0)
    }

    private func floatMinMax(isMax: Bool): Unit {
        this.e.ldrD(0, 20, 8)
        this.e.ldrD(1, 20, 0)
        this.e.addImm(20, 20, 8)
        if (isMax) {
            this.e.fmax(0, 0, 1)
        } else {
            this.e.fmin(0, 0, 1)
        }
        this.e.strD(0, 20, 0)
    }

    /** `CMP_F`：三路浮点比较（NaN → 0，与解释器一致）。 */
    private func floatCmpTri(): Unit {
        this.e.ldrD(0, 20, 0) // b
        this.e.ldrD(1, 20, 8) // a
        this.e.addImm(20, 20, 8)
        this.e.fcmp(1, 0)
        this.e.cset(9, A64Cond.LT)
        this.e.cset(10, A64Cond.GT)
        this.e.subReg(9, 9, 10)
        this.e.strOff(9, 20, 0)
    }

    private func floatCmp(cond: Int64, swapped: Bool): Unit {
        if (swapped) {
            this.e.ldrD(0, 20, 0)
            this.e.ldrD(1, 20, 8)
        } else {
            this.e.ldrD(0, 20, 8)
            this.e.ldrD(1, 20, 0)
        }
        this.e.addImm(20, 20, 8)
        this.e.fcmp(0, 1)
        this.e.cset(9, cond)
        this.e.strOff(9, 20, 0)
    }
}

internal class A64Bin {
    static const ADD: Int64 = 0
    static const SUB: Int64 = 1
    static const MUL: Int64 = 2
    static const ADD_WRAP: Int64 = 3
}
