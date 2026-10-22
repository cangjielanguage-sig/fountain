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

import std.collection.ArrayList
import std.collection.HashMap
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.InsnDecoder
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_base.CpuFeatures
import fountain::f_jit.runtime.HelperAddresses

/**
 * x86_64 指令降低（§12.4）：与 `A64Lower` 同构，补齐控制流、比较、调用模板与常量镜像。
 *
 * 约定：`r15` = ctx、`rbp` = 帧指针、`rsp` = 操作数栈顶；
 * `locals[i]` = `[rbp-32-8i]`；二元 `a b` 中 `b@[rsp]`、`a@[rsp+8]`。
 *
 * 未支持指令（浮点算术、CAST、CALL_CLOSURE 等）返回 `None`，调用方整单元降级解释器。
 */
internal class X86Lower {
    private let code = ArrayList<UInt8>()
    private let labels = HashMap<String, Int64>()
    private let fixOff = ArrayList<Int64>()
    private let fixLabel = ArrayList<String>()
    private let fn: FuncEntry
    private let constBase: Int64
    private let fnTableBase: Int64
    private let dispatch: Int64
    private var depth: Int64
    private var ok: Bool
    /** `roundsd` 需要 SSE4.1；不支持时含取整指令的单元整体降级解释器。 */
    private let sse41: Bool
    private var seq: Int64
    /** 探针遍：抑制机器码/标签发射，仅采集逐指令栈增量。 */
    private var probing: Bool
    /** 逐指令净栈变化（探针遍采集，供 CFG 数据流使用）。 */
    private let delta = HashMap<Int64, Int64>()
    /** 每条指令入口深度（CFG 数据流结果）。 */
    private var depthAt = HashMap<Int64, Int64>()

    init(fn: FuncEntry, constBase: Int64, fnTableBase: Int64) {
        this.fn = fn
        this.constBase = constBase
        this.fnTableBase = fnTableBase
        this.dispatch = HelperAddresses.dispatch()
        this.depth = 0
        this.ok = true
        this.sse41 = CpuFeatures.hasSse41
        this.seq = 0
        this.probing = false
    }

    func success(): Bool {
        this.ok
    }

    func bindLabel(name: String): Unit {
        this.bind(name)
    }

    func appendBytes(bs: Array<UInt8>): Unit {
        this.add(bs)
    }

    func jumpTo(label: String): Unit {
        this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], label)
    }

    func movImm64(reg: Int64, v: Int64): Unit {
        this.movImm(reg, v)
    }

    func appendCallRax(): Unit {
        this.add([0xFFu8, 0xD0u8])
    }

    func appendXorEax(): Unit {
        this.add([0x31u8, 0xC0u8])
    }

    /**
     * 两遍降低：
     *
     * 1. **探针遍**：照常走 `translate`，但抑制发射，采集每条指令的净栈变化 `delta[off]`；
     * 2. **深度遍**：以 `delta` 为输入做控制流数据流（`X86Depth.analyze`），得到每条指令入口深度；
     *    任一汇合点深度不一致 / 指令未识别 ⇒ 放弃 JIT（`ok = false`，整单元退回解释器）；
     * 3. **发射遍**：逐指令以 CFG 深度设定栈模型后再降低（`alignBeforeCall` 因而正确）。
     *
     * 这样分支汇合后的 `sub rsp, 8` 奇偶与运行期一致（修复 x86_64 栈对齐缺陷）。
     */
    func lower(unit: LoadedUnit): Unit {
        let start = Int64(this.fn.codeOff)
        let end = start + Int64(this.fn.codeLen)

        // 1) 探针遍：采集逐指令栈增量（不发射任何机器码/标签）
        this.probing = true
        this.depth = 0
        this.delta.clear()
        var off = start
        while (off < end) {
            let before = this.depth
            let insn = InsnDecoder.decode(unit.code, off)
            this.translate(insn.op, insn.operands, off, off + insn.size)
            this.delta[off] = this.depth - before
            off = off + insn.size
        }
        this.probing = false

        // 2) 控制流数据流
        let analyzed = X86Depth.analyze(unit.code, start, Int64(this.fn.codeLen), this.delta)
        match (analyzed) {
            case Some(m) => this.depthAt = m
            case None =>
                this.ok = false
                return
        }

        // 3) 发射遍
        off = start
        while (off < end) {
            this.bind('L${off}')
            let insn = InsnDecoder.decode(unit.code, off)
            let next = off + insn.size
            // 可达偏移以 CFG 深度为准；不可达区域（RET/BAIL 之后的死代码、内联错误块）
            // 无深度记录，沿用线性累加（与修复前行为一致，且不影响可达汇合点）。
            match (this.depthAt.get(off)) {
                case Some(d) => this.depth = d
                case None => ()
            }
            this.translate(insn.op, insn.operands, off, next)
            off = next
        }
    }

    /** 回填 rel32 并返回最终机器码；缺标签 → None。 */
    func finish(): ?Array<UInt8> {
        if (!this.ok) {
            return None
        }
        let out = this.code.toArray()
        var i = 0
        while (i < this.fixOff.size) {
            let off = this.fixOff[i]
            let target = match (this.labels.get(this.fixLabel[i])) {
                case Some(v) => v
                case None => return None
            }
            let rel = target - (off + 4)
            let u = UInt32(rel & 0xFFFFFFFF)
            out[off] = UInt8((u >> 0) & 0xFFu32)
            out[off + 1] = UInt8((u >> 8) & 0xFFu32)
            out[off + 2] = UInt8((u >> 16) & 0xFFu32)
            out[off + 3] = UInt8((u >> 24) & 0xFFu32)
            i = i + 1
        }
        out
    }

    // ---------------------------------------------------------------- emit

    /** 单字节发射（探针遍抑制，供底层编码器共用）。 */
    private func put(b: UInt8): Unit {
        if (this.probing) {
            return
        }
        this.code.add(b)
    }

    private func add(bs: Array<UInt8>): Unit {
        if (this.probing) {
            return
        }
        for (b in bs) {
            this.put(b)
        }
    }

    private func bind(name: String): Unit {
        if (this.probing) {
            return
        }
        this.labels[name] = this.code.size
    }

    private func rel32(op: Array<UInt8>, label: String): Unit {
        if (this.probing) {
            return
        }
        this.add(op)
        this.fixOff.add(this.code.size - 4)
        this.fixLabel.add(label)
    }

    private func w64(v: Int64): Unit {
        var k = 0
        while (k < 8) {
            this.put(UInt8((v >> (8 * k)) & 0xFF))
            k = k + 1
        }
    }

    private func w32(v: Int64): Unit {
        var k = 0
        while (k < 4) {
            this.put(UInt8((v >> (8 * k)) & 0xFF))
            k = k + 1
        }
    }

    /** `mov r64, imm64`（reg 0–15）。 */
    private func movImm(reg: Int64, v: Int64): Unit {
        this.put(if (reg >= 8) { 0x49u8 } else { 0x48u8 })
        this.put(UInt8(0xB8 + (reg & 7)))
        this.w64(v)
    }

    /** `mov dst, src`（64 位寄存器）。 */
    private func movReg(dst: Int64, src: Int64): Unit {
        var rex = 0x48u8
        if (src >= 8) {
            rex = rex | 0x04u8
        }
        if (dst >= 8) {
            rex = rex | 0x01u8
        }
        this.put(rex)
        this.put(0x89u8)
        this.put(UInt8(0xC0 | ((src & 7) << 3) | (dst & 7)))
    }

    private func pushReg(reg: Int64): Unit {
        if (reg >= 8) {
            this.put(0x41u8)
        }
        this.put(UInt8(0x50 + (reg & 7)))
    }

    private func popReg(reg: Int64): Unit {
        if (reg >= 8) {
            this.put(0x41u8)
        }
        this.put(UInt8(0x58 + (reg & 7)))
    }

    private func addRsp(v: Int64): Unit {
        if (v == 0) {
            return
        }
        if (v <= 127) {
            this.add([0x48u8, 0x83u8, 0xC4u8, UInt8(v)])
        } else {
            this.add([0x48u8, 0x81u8, 0xC4u8])
            this.w32(v)
        }
    }

    private func subRsp(v: Int64): Unit {
        if (v == 0) {
            return
        }
        if (v <= 127) {
            this.add([0x48u8, 0x83u8, 0xECu8, UInt8(v)])
        } else {
            this.add([0x48u8, 0x81u8, 0xECu8])
            this.w32(v)
        }
    }

    /** ctx 字段均为 Int64：必须 64 位写，避免高 32 位残留（site/fnId/errCode）。 */
    private func movQwordCtx(off: Int64, v: Int64): Unit {
        this.add([0x49u8, 0xC7u8, 0x47u8, UInt8(off)])
        this.w32(v)
    }

    private func movRaxMemRsp(disp: Int64): Unit {
        this.add([0x48u8, 0x8Bu8, 0x84u8, 0x24u8])
        this.w32(disp)
    }

    private func movMemRspRax(disp: Int64): Unit {
        this.add([0x48u8, 0x89u8, 0x84u8, 0x24u8])
        this.w32(disp)
    }

    private func leaRdxRsp(disp: Int64): Unit {
        this.add([0x48u8, 0x8Du8, 0x94u8, 0x24u8])
        this.w32(disp)
    }

    private func leaRsiRsp(disp: Int64): Unit {
        this.add([0x48u8, 0x8Du8, 0xB4u8, 0x24u8])
        this.w32(disp)
    }

    private func leaR8Rbp(disp: Int64): Unit {
        this.add([0x4Cu8, 0x8Du8, 0x45u8, UInt8(disp)])
    }

    private func pushMemRsp(disp: Int64): Unit {
        this.add([0xFFu8, 0xB4u8, 0x24u8])
        this.w32(disp)
    }

    private func pushMemRbp(disp: Int64): Unit {
        this.add([0xFFu8, 0xB5u8])
        this.w32(disp)
    }

    private func popMemRbp(disp: Int64): Unit {
        this.add([0x48u8, 0x8Fu8, 0x85u8])
        this.w32(disp)
    }

    private func moveRaxToMemRsp(disp: Int64): Unit {
        this.movMemRspRax(disp)
    }

    private func setccAl(cc: UInt8): Unit {
        this.add([0x0Fu8, cc, 0xC0u8, 0x0Fu8, 0xB6u8, 0xC0u8])
    }

    private func binOp(op: Array<UInt8>, checked: Bool): Unit {
        this.movRaxMemRsp(8)
        this.add(op)
        if (checked) {
            this.seq = this.seq + 1
            let okLabel = 'ov${this.seq}'
            // JNO ok：未溢出直接继续；溢出才落到下面的 bail(3)
            this.rel32([0x0Fu8, 0x81u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], okLabel)
            this.bail(3)
            this.bind(okLabel)
        }
        this.movMemRspRax(8)
        this.addRsp(8)
        this.depth = this.depth - 1
    }

    private func cmpOp(cc: UInt8): Unit {
        this.movRaxMemRsp(8)
        this.add([0x48u8, 0x3Bu8, 0x04u8, 0x24u8])
        this.setccAl(cc)
        this.movMemRspRax(8)
        this.addRsp(8)
        this.depth = this.depth - 1
    }

    private func bail(k: Int64): Unit {
        this.movQwordCtx(0, k)
        if (k > 0) {
            this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'checkfail')
        } else {
            this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'epilogue')
        }
    }

    private func checkErr(): Unit {
        this.add([0x49u8, 0x83u8, 0x3Fu8, 0x00u8])
        this.rel32([0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'checkfail')
    }

    private func alignBeforeCall(): Bool {
        let pad = (this.depth % 2) != 0
        if (pad) {
            this.subRsp(8)
        }
        pad
    }

    private func unalignAfterCall(pad: Bool): Unit {
        if (pad) {
            this.addRsp(8)
        }
    }

    /** `h_dispatch(hid, ctx, &args, argc)`；结果替换最深实参并收参（variant 0/1/2）。 */
    private func helper(hid: Int64, argc: Int64, variant: Int64): Unit {
        let disp = 8 * (argc - 1)
        if (argc == 0) {
            this.add([0x31u8, 0xF6u8, 0x31u8, 0xD2u8]) // xor esi; xor edx
        } else {
            this.leaRdxRsp(disp)
        }
        this.movImm(7, hid) // rdi = hid
        this.movReg(6, 15) // rsi = ctx
        this.add([0xB9u8])
        this.w32(argc) // rcx = argc
        this.movImm(0, this.dispatch)
        let pad = this.alignBeforeCall()
        this.add([0xFFu8, 0xD0u8])
        this.unalignAfterCall(pad)
        if (variant == 2) {
            this.addRsp(8 * argc)
            this.depth = this.depth - argc
            return
        }
        if (argc == 0) {
            this.pushReg(0)
        } else {
            this.moveRaxToMemRsp(disp)
            this.addRsp(disp)
        }
        this.depth = this.depth - argc + 1
        if (variant == 0) {
            this.checkErr()
        }
    }

    private func callFunc(fid: Int64, argc: Int64): Unit {
        if (this.fnTableBase == 0) {
            this.ok = false
            return
        }
        let disp = 8 * (argc - 1)
        if (argc == 0) {
            this.add([0x31u8, 0xF6u8, 0x31u8, 0xD2u8])
        } else {
            this.leaRsiRsp(disp)
            this.add([0xBAu8])
            this.w32(argc)
        }
        this.movReg(7, 15) // rdi = ctx
        this.movImm(0, this.fnTableBase)
        let pad = this.alignBeforeCall()
        this.add([0xFFu8, 0x90u8])
        this.w32(8 * fid)
        this.unalignAfterCall(pad)
        this.checkErr()
        this.movQwordCtx(40, Int64(this.fn.fnId))
        if (argc == 0) {
            this.pushReg(0)
        } else {
            this.moveRaxToMemRsp(disp)
            this.addRsp(disp)
        }
        this.depth = this.depth - argc + 1
    }

    // ---------------------------------------------------------------- 指令组

    private func sseBinRR(op: UInt8): Unit {
        this.add([0xF2u8, 0x0Fu8, op, 0xC1u8])
    }

    private func floatBin(op: UInt8, commutative: Bool): Unit {
        if (commutative) {
            this.sseLoad(0, 0)
            this.sseBin(op, 8)
        } else {
            this.sseLoad(0, 8)
            this.sseBin(op, 0)
        }
        this.canonXmm0()
        this.sseStore(8, 0)
        this.addRsp(8)
        this.depth = this.depth - 1
    }

    private func floatDivChk(): Unit {
        this.seq = this.seq + 1
        let go = 'fd${this.seq}'
        let z = 'fdz${this.seq}'
        let done = 'fdd${this.seq}'
        this.add([0x66u8, 0x0Fu8, 0x57u8, 0xC9u8])
        this.ucomisdRM(1, 0)
        this.jcc(0x8Au8, go) // jp：仅除数 NaN（无序，PF=1）跳过零检查
        this.jcc(0x84u8, z)
        this.bind(go)
        this.floatBin(0x5Eu8, false)
        this.jmpLabel(done)
        this.bind(z)
        this.bail(1)
        this.bind(done)
    }

    private func floatMinMax(op: UInt8): Unit {
        this.seq = this.seq + 1
        let canon = 'fmc${this.seq}'
        let done = 'fmd${this.seq}'
        this.sseLoad(0, 8)
        this.sseLoad(1, 0)
        this.ucomisdRR(0, 0)
        this.jcc(0x8Au8, canon) // jp
        this.ucomisdRR(1, 1)
        this.jcc(0x8Au8, canon)
        this.sseBinRR(op)
        this.jmpLabel(done)
        this.bind(canon)
        this.movImm(0, Int64(0x7FF8000000000000))
        this.movqXmmRax(0)
        this.bind(done)
        this.sseStore(8, 0)
        this.addRsp(8)
        this.depth = this.depth - 1
    }

    private func floatRoundChecked(imm: UInt8): Unit {
        if (!this.sse41) {
            this.ok = false
            return
        }
        this.floatRound(imm)
    }

    private func floatRound(imm: UInt8): Unit {
        this.sseLoad(0, 0)
        this.add([0x66u8, 0x0Fu8, 0x3Au8, 0x0Bu8, 0xC0u8, imm])
        this.canonXmm0()
        this.sseStore(0, 0)
    }

    /** `cc`：0=EQ、1=LT、2=LE、4=NE、6=GE、7=GT（无序语义按 §12.4）。 */
    private func floatCmp(cc: UInt8): Unit {
        this.sseLoad(0, 8)
        this.sseLoad(1, 0)
        this.ucomisdRR(0, 1)
        match (cc) {
            case 0u8 =>
                this.add([0x0Fu8, 0x94u8, 0xC0u8, 0x0Fu8, 0x9Bu8, 0xC2u8, 0x20u8, 0xD0u8])
            case 1u8 =>
                this.add([0x0Fu8, 0x92u8, 0xC0u8, 0x0Fu8, 0x9Bu8, 0xC2u8, 0x20u8, 0xD0u8])
            case 2u8 =>
                this.add([0x0Fu8, 0x96u8, 0xC0u8, 0x0Fu8, 0x9Bu8, 0xC2u8, 0x20u8, 0xD0u8])
            case 4u8 =>
                this.add([0x0Fu8, 0x95u8, 0xC0u8, 0x0Fu8, 0x9Au8, 0xC2u8, 0x08u8, 0xD0u8])
            case 6u8 =>
                this.add([0x0Fu8, 0x93u8, 0xC0u8])
            case _ =>
                this.add([0x0Fu8, 0x97u8, 0xC0u8])
        }
        this.add([0x0Fu8, 0xB6u8, 0xC0u8, 0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8])
        this.depth = this.depth - 1
    }

    /** `CMP_F` 三向：`(a<b) - (a>b)`，NaN → 0。 */
    private func floatCmpTri(): Unit {
        this.sseLoad(0, 8)
        this.sseLoad(1, 0)
        this.ucomisdRR(0, 1)
        this.add([0x0Fu8, 0x92u8, 0xC0u8, 0x0Fu8, 0x97u8, 0xC2u8,
            0x0Fu8, 0xB6u8, 0xC0u8, 0x0Fu8, 0xB6u8, 0xD2u8,
            0x29u8, 0xD0u8, 0x48u8, 0x98u8,
            0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8])
        this.depth = this.depth - 1
    }

    private func minMax(cmov: UInt8): Unit {
        this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8, 0x48u8, 0x3Bu8, 0xC1u8,
            0x48u8, 0x0Fu8, cmov, 0xC1u8, 0x48u8, 0x89u8, 0x04u8, 0x24u8])
        this.depth = this.depth - 1
    }

    private func castLike(tok: Int64, mode: Int64): Unit {
        this.pushMemRsp(0)
        this.depth = this.depth + 1
        this.movImm(0, tok)
        this.pushReg(0)
        this.depth = this.depth + 1
        this.helper(17, 2, 0)
        this.popReg(0)
        this.depth = this.depth - 1
        this.add([0x48u8, 0x85u8, 0xC0u8])
        this.seq = this.seq + 1
        let ok = 'cast${this.seq}'
        this.jcc(0x85u8, ok)
        if (mode == 0) {
            this.bail(7)
        } else {
            this.bail(-1)
        }
        this.bind(ok)
    }

    private func toI64(mode: Int64): Unit {
        this.seq = this.seq + 1
        let bad = 'ti${this.seq}'
        let done = 'tid${this.seq}'
        this.sseLoad(0, 0)
        this.ucomisdRR(0, 0)
        this.jcc(0x8Au8, bad) // jp：NaN
        this.movImm(0, Int64(0x43E0000000000000))
        this.movqXmmRax(1)
        this.ucomisdRR(0, 1)
        this.jcc(0x83u8, bad) // jae：>= 2^63
        this.movImm(0, -4332462841530417152) // -2^63
        this.movqXmmRax(1)
        this.ucomisdRR(0, 1)
        this.jcc(0x86u8, bad) // jbe：<= -2^63
        this.add([0xF2u8, 0x48u8, 0x0Fu8, 0x2Cu8, 0xC0u8,
            0x48u8, 0x89u8, 0x04u8, 0x24u8])
        this.jmpLabel(done)
        this.bind(bad)
        if (mode == 0) {
            this.bail(13)
        } else {
            this.bail(-1)
        }
        this.bind(done)
    }

    private func callClosure(argc: Int64): Unit {
        let disp = 8 * argc
        // H55(ctx, &closure, 1) → fnId；闭包槽不覆盖
        this.movImm(7, 55)
        this.movReg(6, 15)
        this.leaRdxRsp(disp)
        this.add([0xB9u8])
        this.w32(1)
        this.movImm(0, this.dispatch)
        let p1 = this.alignBeforeCall()
        this.add([0xFFu8, 0xD0u8])
        this.unalignAfterCall(p1)
        this.add([0x48u8, 0x89u8, 0x45u8, 0xF0u8]) // mov [rbp-16],rax
        this.checkErr()
        // H57(ctx) → fnTable 基址
        this.movImm(7, 57)
        this.movReg(6, 15)
        this.add([0x31u8, 0xD2u8, 0x31u8, 0xC9u8])
        this.movImm(0, this.dispatch)
        let p2 = this.alignBeforeCall()
        this.add([0xFFu8, 0xD0u8])
        this.unalignAfterCall(p2)
        this.add([0x48u8, 0x89u8, 0x45u8, 0xE8u8]) // mov [rbp-24],rax
        this.checkErr()
        this.add([0x48u8, 0x8Bu8, 0x45u8, 0xF0u8,
            0x48u8, 0x8Bu8, 0x4Du8, 0xE8u8,
            0x48u8, 0x8Bu8, 0x04u8, 0xC1u8]) // rax = fnTable[fnId]
        this.movReg(7, 15)
        this.leaRsiRsp(disp)
        this.add([0xBAu8])
        this.w32(argc)
        let p3 = this.alignBeforeCall()
        this.add([0xFFu8, 0xD0u8])
        this.unalignAfterCall(p3)
        this.checkErr()
        this.movQwordCtx(40, Int64(this.fn.fnId))
        this.moveRaxToMemRsp(disp)
        this.addRsp(disp)
        this.depth = this.depth - argc
    }

    // ---------------------------------------------------------------- SSE / 分支

    private func sseLoad(dst: Int64, disp: Int64): Unit {
        this.add([0xF2u8, 0x0Fu8, 0x10u8, UInt8(0x84 + dst * 8), 0x24u8])
        this.w32(disp)
    }

    private func sseStore(disp: Int64, src: Int64): Unit {
        this.add([0xF2u8, 0x0Fu8, 0x11u8, UInt8(0x84 + src * 8), 0x24u8])
        this.w32(disp)
    }

    private func sseBin(op: UInt8, disp: Int64): Unit {
        this.add([0xF2u8, 0x0Fu8, op, 0x84u8, 0x24u8])
        this.w32(disp)
    }

    private func ucomisdRR(a: Int64, b: Int64): Unit {
        this.add([0x66u8, 0x0Fu8, 0x2Eu8, UInt8(0xC0 | (a << 3) | b)])
    }

    private func ucomisdRM(reg: Int64, disp: Int64): Unit {
        this.add([0x66u8, 0x0Fu8, 0x2Eu8, UInt8(0x84 | (reg << 3)), 0x24u8])
        this.w32(disp)
    }

    private func movqXmmRax(xmm: Int64): Unit {
        this.add([0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, UInt8(0xC0 | (xmm << 3))])
    }

    private func movqRaxXmm(xmm: Int64): Unit {
        this.add([0x66u8, 0x48u8, 0x0Fu8, 0x7Eu8, UInt8(0xC0 | (xmm << 3))])
    }

    private func jcc(cc: UInt8, label: String): Unit {
        this.rel32([0x0Fu8, cc, 0x00u8, 0x00u8, 0x00u8, 0x00u8], label)
    }

    private func jmpLabel(label: String): Unit {
        this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], label)
    }

    /** 结果 NaN → CANON（`ucomisd xmm0,xmm0; jnp ok`）。 */
    private func canonXmm0(): Unit {
        this.seq = this.seq + 1
        let ok = 'nan${this.seq}'
        this.ucomisdRR(0, 0)
        this.jcc(0x8Bu8, ok) // jnp
        this.movImm(0, Int64(0x7FF8000000000000))
        this.movqXmmRax(0)
        this.bind(ok)
    }

    private func helperReg(hidReg: Int64, argc: Int64): Unit {
        let disp = 8 * (argc - 1)
        if (argc == 0) {
            this.add([0x31u8, 0xD2u8])
        } else {
            this.leaRdxRsp(disp)
        }
        this.movReg(7, hidReg)
        this.movReg(6, 15)
        this.add([0xB9u8])
        this.w32(argc)
        this.movImm(0, this.dispatch)
        let pad = this.alignBeforeCall()
        this.add([0xFFu8, 0xD0u8])
        this.unalignAfterCall(pad)
        if (argc == 0) {
            this.pushReg(0)
        } else {
            this.moveRaxToMemRsp(disp)
            this.addRsp(disp)
        }
        this.depth = this.depth - argc + 1
        this.checkErr()
    }

    private func translate(op: UInt8, ops: Array<UInt8>, at: Int64, next: Int64): Unit {
        match (op) {
            case 0x00u8 => this.add([0x90u8])
            case 0x01u8 => this.add([0xCCu8])
            case 0x02u8 => this.add([0x90u8])
            case 0x03u8 =>
                this.movQwordCtx(8, X86Lower.i32(ops, 0))
            case 0x04u8 => this.checkErr()
            case 0x05u8 => this.bail(X86Lower.i8(ops, 0))
            case 0x06u8 => ()
            case 0x07u8 => ()
            case 0x10u8 =>
                this.movImm(0, X86Lower.i8(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
            case 0x11u8 =>
                this.movImm(0, X86Lower.i32(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
            case 0x12u8 =>
                this.movImm(0, X86Lower.i64(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
            case 0x13u8 =>
                this.movImm(0, X86Lower.i64(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
            case 0x14u8 =>
                this.movImm(0, X86Lower.u8(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
            case 0x15u8 =>
                this.add([0x31u8, 0xC0u8, 0x50u8])
                this.depth = this.depth + 1
            case 0x16u8 =>
                if (this.constBase == 0) {
                    this.ok = false
                } else {
                    this.movImm(0, this.constBase + 8 * X86Lower.u16(ops, 0))
                    this.add([0x48u8, 0x8Bu8, 0x00u8])
                    this.pushReg(0)
                    this.depth = this.depth + 1
                }
            case 0x17u8 =>
                this.pushMemRsp(0)
                this.depth = this.depth + 1
            case 0x18u8 =>
                this.pushMemRsp(8)
                this.pushMemRsp(8)
                this.depth = this.depth + 2
            case 0x19u8 =>
                this.addRsp(8)
                this.depth = this.depth - 1
            case 0x1Au8 =>
                this.addRsp(16)
                this.depth = this.depth - 2
            case 0x1Bu8 =>
                this.add([0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x8Bu8, 0x4Cu8, 0x24u8,
                    0x08u8, 0x48u8, 0x89u8, 0x0Cu8, 0x24u8, 0x48u8, 0x89u8, 0x44u8, 0x24u8,
                    0x08u8])
            case 0x1Cu8 =>
                this.pushMemRsp(8 * X86Lower.u8(ops, 0))
                this.depth = this.depth + 1
            case 0x20u8 =>
                this.pushMemRbp(0 - (32 + 8 * X86Lower.u16(ops, 0)))
                this.depth = this.depth + 1
            case 0x21u8 =>
                this.popMemRbp(0 - (32 + 8 * X86Lower.u16(ops, 0)))
                this.depth = this.depth - 1
            case 0x22u8 =>
                this.pushMemRbp(-32)
                this.depth = this.depth + 1
            case 0x23u8 =>
                this.pushMemRbp(-40)
                this.depth = this.depth + 1
            case 0x24u8 =>
                this.pushMemRbp(-48)
                this.depth = this.depth + 1
            case 0x25u8 =>
                this.pushMemRbp(-56)
                this.depth = this.depth + 1
            case 0x26u8 =>
                this.pushMemRbp(-32)
                this.movImm(0, X86Lower.u16(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 2
                this.helper(56, 2, 0)
            case 0x30u8 => this.binOp([0x48u8, 0x03u8, 0x04u8, 0x24u8], true)
            case 0x31u8 => this.binOp([0x48u8, 0x2Bu8, 0x04u8, 0x24u8], true)
            case 0x32u8 => this.binOp([0x48u8, 0x0Fu8, 0xAFu8, 0x04u8, 0x24u8], true)
            case 0x33u8 =>
                this.movRaxMemRsp(8)
                this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0x85u8, 0xC9u8])
                this.seq = this.seq + 1
                let div0 = 'd0${this.seq}'
                let ok = 'dok${this.seq}'
                let ov = 'dov${this.seq}'
                let done = 'ddone${this.seq}'
                this.jcc(0x84u8, div0)
                this.add([0x48u8, 0x83u8, 0xF9u8, 0xFFu8])
                this.jcc(0x85u8, ok)
                this.movImm(2, -9223372036854775807 - 1)
                this.add([0x48u8, 0x39u8, 0xD0u8])
                this.jcc(0x84u8, ov)
                this.bind(ok)
                this.add([0x48u8, 0x99u8, 0x48u8, 0xF7u8, 0xF9u8,
                    0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8])
                this.jmpLabel(done)
                this.bind(div0)
                this.bail(1)
                this.bind(ov)
                this.bail(3)
                this.bind(done)
                this.depth = this.depth - 1
            case 0x34u8 =>
                this.movRaxMemRsp(8)
                this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0x85u8, 0xC9u8])
                this.seq = this.seq + 1
                let m0 = 'm0${this.seq}'
                let mz = 'mz${this.seq}'
                let md = 'md${this.seq}'
                this.jcc(0x84u8, m0)
                this.add([0x48u8, 0x83u8, 0xF9u8, 0xFFu8])
                this.jcc(0x84u8, mz)
                this.add([0x48u8, 0x99u8, 0x48u8, 0xF7u8, 0xF9u8,
                    0x48u8, 0x89u8, 0x54u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8])
                this.jmpLabel(md)
                this.bind(mz)
                this.add([0x31u8, 0xD2u8, 0x48u8, 0x89u8, 0x54u8, 0x24u8, 0x08u8,
                    0x48u8, 0x83u8, 0xC4u8, 0x08u8])
                this.jmpLabel(md)
                this.bind(m0)
                this.bail(2)
                this.bind(md)
                this.depth = this.depth - 1
            case 0x35u8 =>
                this.add([0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0xF7u8, 0xD8u8])
                this.seq = this.seq + 1
                let okLabel = 'ng${this.seq}'
                // JNO ok：正常取负继续；仅 INT64_MIN 取负溢出时 bail(3)
                this.rel32([0x0Fu8, 0x81u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], okLabel)
                this.bail(3)
                this.bind(okLabel)
                this.add([0x48u8, 0x89u8, 0x04u8, 0x24u8])
            case 0x36u8 =>
                this.popReg(0)
                this.add([0x48u8, 0x85u8, 0xC0u8])
                this.seq = this.seq + 1
                let aok = 'ab${this.seq}'
                let aov = 'abo${this.seq}'
                let ad = 'abd${this.seq}'
                this.jcc(0x89u8, aok)
                this.add([0x48u8, 0xF7u8, 0xD8u8])
                this.jcc(0x80u8, aov)
                this.bind(aok)
                this.pushReg(0)
                this.jmpLabel(ad)
                this.bind(aov)
                this.bail(3)
                this.bind(ad)
            case 0x37u8 =>
                this.minMax(0x4Du8)
            case 0x38u8 =>
                this.minMax(0x4Cu8)
            case 0x39u8 => this.binOp([0x48u8, 0x03u8, 0x04u8, 0x24u8], false)
            case 0x3Au8 =>
                this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0xC7u8, 0xC0u8,
                    0x40u8, 0x00u8, 0x00u8, 0x00u8, 0x48u8, 0x85u8, 0xC9u8])
                this.seq = this.seq + 1
                let cdone = 'cl${this.seq}'
                this.jcc(0x84u8, cdone)
                this.add([0x48u8, 0x0Fu8, 0xBDu8, 0xC1u8, 0x48u8, 0x35u8,
                    0x3Fu8, 0x00u8, 0x00u8, 0x00u8])
                this.bind(cdone)
                this.add([0x48u8, 0x89u8, 0x04u8, 0x24u8])
            case 0x3Bu8 => this.add(BackendX86_64.emitIPopcnt())
            case 0x40u8 => this.floatBin(0x58u8, true)
            case 0x41u8 => this.floatBin(0x5Cu8, false)
            case 0x42u8 => this.floatBin(0x59u8, true)
            case 0x43u8 => this.floatBin(0x5Eu8, false)
            case 0x44u8 => this.floatDivChk()
            case 0x45u8 =>
                this.sseLoad(0, 0)
                this.movImm(0, -9223372036854775807 - 1)
                this.movqXmmRax(1)
                this.add([0x66u8, 0x0Fu8, 0x57u8, 0xC1u8])
                this.canonXmm0()
                this.sseStore(0, 0)
            case 0x46u8 =>
                this.sseLoad(0, 0)
                this.movImm(0, 9223372036854775807)
                this.movqXmmRax(1)
                this.add([0x66u8, 0x0Fu8, 0x54u8, 0xC1u8])
                this.canonXmm0()
                this.sseStore(0, 0)
            case 0x47u8 => this.floatMinMax(0x5Du8)
            case 0x48u8 => this.floatMinMax(0x5Fu8)
            case 0x49u8 =>
                this.sseLoad(0, 0)
                this.add([0xF2u8, 0x0Fu8, 0x51u8, 0x04u8, 0x24u8])
                this.canonXmm0()
                this.sseStore(0, 0)
            case 0x4Au8 => this.floatRoundChecked(1u8)
            case 0x4Bu8 => this.floatRoundChecked(2u8)
            case 0x4Cu8 => this.floatRoundChecked(3u8)
            case 0x4Du8 => this.floatRoundChecked(0u8)
            case 0x50u8 => this.add(BackendX86_64.emitCmpI()); this.depth = this.depth - 1
            case 0x51u8 => this.floatCmpTri()
            case 0x52u8 => this.cmpOp(0x94u8)
            case 0x53u8 => this.cmpOp(0x95u8)
            case 0x54u8 => this.cmpOp(0x9Cu8)
            case 0x55u8 => this.cmpOp(0x9Eu8)
            case 0x56u8 => this.cmpOp(0x9Fu8)
            case 0x57u8 => this.cmpOp(0x9Du8)
            case 0x58u8 => this.floatCmp(0u8)
            case 0x59u8 => this.floatCmp(4u8)
            case 0x5Au8 => this.floatCmp(1u8)
            case 0x5Bu8 => this.floatCmp(2u8)
            case 0x5Cu8 => this.floatCmp(7u8)
            case 0x5Du8 => this.floatCmp(6u8)
            case 0x5Eu8 => this.add([0x48u8, 0x83u8, 0x34u8, 0x24u8, 0x01u8])
            case 0x5Fu8 => this.binOp([0x48u8, 0x23u8, 0x04u8, 0x24u8], false)
            case 0x60u8 => this.binOp([0x48u8, 0x0Bu8, 0x04u8, 0x24u8], false)
            case 0x61u8 => this.binOp([0x48u8, 0x33u8, 0x04u8, 0x24u8], false)
            case 0x62u8 => this.binOp([0x48u8, 0x23u8, 0x04u8, 0x24u8], false)
            case 0x63u8 => this.binOp([0x48u8, 0x0Bu8, 0x04u8, 0x24u8], false)
            case 0x64u8 => this.binOp([0x48u8, 0x33u8, 0x04u8, 0x24u8], false)
            case 0x65u8 =>
                this.add([0x48u8, 0xF7u8, 0x14u8, 0x24u8])
            case 0x66u8 =>
                this.movRaxMemRsp(8)
                this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0xD3u8, 0xE0u8,
                    0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8])
                this.depth = this.depth - 1
            case 0x67u8 =>
                this.movRaxMemRsp(8)
                this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0xD3u8, 0xF8u8,
                    0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8])
                this.depth = this.depth - 1
            case 0x68u8 =>
                this.movRaxMemRsp(8)
                this.add([0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0xD3u8, 0xE8u8,
                    0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8])
                this.depth = this.depth - 1
            case 0x69u8 => this.cmpOp(0x94u8)
            case 0x6Au8 => this.cmpOp(0x95u8)
            case 0x6Bu8 => this.helper(9, 2, 0)
            case 0x6Cu8 => this.helper(11, 2, 0)
            case 0x6Du8 => this.helper(13, 2, 0)
            case 0x6Eu8 => this.helper(15, 2, 0)
            case 0x70u8 =>
                let rel = X86Lower.i32(ops, 0)
                this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'L${next + rel}')
            case 0x71u8 =>
                let rel = X86Lower.i32(ops, 0)
                this.add([0x58u8, 0x48u8, 0x85u8, 0xC0u8])
                this.rel32([0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'L${next + rel}')
                this.depth = this.depth - 1
            case 0x72u8 =>
                let rel = X86Lower.i32(ops, 0)
                this.add([0x58u8, 0x48u8, 0x85u8, 0xC0u8])
                this.rel32([0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'L${next + rel}')
                this.depth = this.depth - 1
            case 0x73u8 => ()
            case 0x74u8 =>
                // 回边 = 安全点：先 H22 interrupt_poll（与解释器同语义），再跳
                this.helper(22, 0, 0) // 变体 0：占位结果 + 自动 CHECK_ERR
                this.addRsp(8)
                this.depth = this.depth - 1
                let rel = X86Lower.i32(ops, 0)
                this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'L${next + rel}')
            case 0x75u8 => this.helper(X86Lower.u16(ops, 0), X86Lower.u8(ops, 2), 0)
            case 0x76u8 => this.helper(X86Lower.u16(ops, 0), X86Lower.u8(ops, 2), 1)
            case 0x77u8 => this.helper(X86Lower.u16(ops, 0), X86Lower.u8(ops, 2), 2)
            case 0x78u8 => this.callFunc(X86Lower.u16(ops, 0), X86Lower.u8(ops, 2))
            case 0x79u8 => this.helper(63, Int64(X86Lower.u8(ops, 0)) + 1, 0)
            case 0x7Au8 => this.bail(18)
            case 0x7Bu8 => ()
            case 0x7Cu8 =>
                this.add([0x48u8, 0x8Bu8, 0x04u8, 0x24u8])
                this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'epilogue')
            case 0x7Du8 =>
                this.add([0x31u8, 0xC0u8])
                this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'epilogue')
            case 0x7Eu8 =>
                this.add([0x31u8, 0xC0u8])
                this.rel32([0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], 'epilogue')
            case 0x7Fu8 => this.callClosure(X86Lower.u8(ops, 0))
            case 0x80u8 => this.castLike(X86Lower.u16(ops, 0), X86Lower.u8(ops, 2))
            case 0x81u8 => this.toI64(X86Lower.u8(ops, 0))
            case 0x82u8 =>
                this.movRaxMemRsp(0)
                this.add([0xF2u8, 0x48u8, 0x0Fu8, 0x2Au8, 0xC0u8])
                this.sseStore(0, 0)
            case 0x83u8 =>
                this.movImm(0, X86Lower.u16(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
                this.helper(17, 2, 0)
            case 0x84u8 =>
                if (X86Lower.u8(ops, 2) == 0) {
                    this.movImm(0, X86Lower.u16(ops, 0))
                    this.pushReg(0)
                    this.depth = this.depth + 1
                    this.helper(19, 2, 0)
                } else {
                    this.castLike(X86Lower.u16(ops, 0), 1)
                }
            case 0x85u8 => this.bail(17)
            case 0x86u8 =>
                let code = X86Lower.u8(ops, 0)
                this.add([0x58u8, 0x48u8, 0x85u8, 0xC0u8])
                let okLabel = 'asm${at}'
                this.rel32([0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], okLabel)
                this.depth = this.depth - 1
                this.bail(code)
                this.bind(okLabel)
            case 0x87u8 => this.bail(X86Lower.u8(ops, 0))
            case 0x88u8 =>
                let code = X86Lower.u8(ops, 0)
                this.add([0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x85u8, 0xC0u8])
                let okLabel = 'gnnz${at}'
                this.rel32([0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8], okLabel)
                if (code == 0) {
                    this.bail(6)
                } else {
                    this.bail(-1)
                }
                this.bind(okLabel)
            case 0x89u8 => this.helper(18, 1, 0)
            case 0x90u8 =>
                this.pushMemRsp(0)
                this.depth = this.depth + 1
                this.helper(18, 1, 0)
                this.popReg(0)
                this.depth = this.depth - 1
                this.seq = this.seq + 1
                let lcall = 'len${this.seq}'
                this.movImm(7, 1)
                this.add([0x48u8, 0x83u8, 0xF8u8, 0x01u8])
                this.jcc(0x84u8, lcall)
                this.movImm(7, 3)
                this.add([0x48u8, 0x83u8, 0xF8u8, 0x02u8])
                this.jcc(0x84u8, lcall)
                this.movImm(7, 7)
                this.bind(lcall)
                this.helperReg(7, 1)
            case 0x91u8 => this.helper(2, 2, 0)
            case 0x92u8 => this.helper(4, 2, 0)
            case 0x93u8 => this.helper(5, 3, 0)
            case 0x94u8 => this.helper(6, 2, 0)
            case 0x95u8 => this.helper(8, 2, 0)
            case 0x96u8 =>
                this.movImm(0, X86Lower.u8(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
                this.helper(14, 2, 0)
            case 0x97u8 => this.helper(16, 1, 0)
            case 0x98u8 => this.helper(12, 1, 0)
            case 0x99u8 => this.helper(18, 1, 0)
            case 0x9Au8 => this.helper(41, 4, 0)
            case 0x9Bu8 => this.helper(42, 2, 0)
            case 0x9Cu8 =>
                this.helper(if (X86Lower.u8(ops, 0) == 0) { 28 } else { 29 }, 1, 0)
            case 0x9Du8 =>
                if (X86Lower.u8(ops, 0) == 1) {
                    this.helper(30, 1, 1)
                    this.seq = this.seq + 1
                    let dfin = 'df${this.seq}'
                    let dother = 'dfo${this.seq}'
                    this.add([0x41u8, 0x83u8, 0x3Fu8, 0x00u8])
                    this.jcc(0x84u8, dfin) // errCode == 0
                    this.add([0x41u8, 0x83u8, 0x3Fu8, 0x09u8])
                    this.jcc(0x85u8, dother) // != 9
                    this.movQwordCtx(0, -1)
                    this.jmpLabel('epilogue')
                    this.bind(dother)
                    this.jmpLabel('checkfail')
                    this.bind(dfin)
                } else {
                    this.helper(30, 1, 0)
                }
            case 0x9Eu8 => this.helper(31, 1, 0)
            case 0xA0u8 => this.helper(70, 0, 0)
            case 0xA1u8 => this.helper(43, 2, 0)
            case 0xA2u8 => this.helper(71, 0, 0)
            case 0xA3u8 => this.helper(44, 3, 0)
            case 0xA4u8 => this.helper(32, 2, 0)
            case 0xA5u8 => this.helper(24, 2, 0)
            case 0xA6u8 => this.helper(25, 2, 0)
            case 0xA7u8 => this.helper(26, 2, 0)
            case 0xA8u8 => this.helper(27, 2, 0)
            case 0xA9u8 => this.ok = false
            case 0xAAu8 => this.ok = false
            case 0xABu8 => this.helper(45, 3, 0)
            case 0xACu8 => this.helper(46, 3, 0)
            case 0xADu8 => this.helper(47, 2, 0)
            case 0xAEu8 => this.helper(48, 2, 0)
            case 0xAFu8 => this.helper(49, 1, 0)
            case 0xB0u8 => this.helper(34, 2, 0)
            case 0xB1u8 => this.helper(35, 2, 0)
            case 0xB2u8 => this.helper(36, 2, 0)
            case 0xB3u8 => this.helper(37, 2, 0)
            case 0xB4u8 => this.helper(38, 2, 0)
            case 0xB5u8 => this.helper(39, 2, 0)
            case 0xB6u8 => this.helper(40, 1, 0)
            case 0xB7u8 =>
                this.movImm(0, X86Lower.u8(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
                this.helper(33, 2, 0)
            case 0xB8u8 => this.helper(50, 3, 0)
            case 0xB9u8 => this.helper(51, 3, 0)
            case 0xBAu8 => this.helper(52, 2, 0)
            case 0xBBu8 => this.helper(53, 2, 0)
            case 0xBCu8 => this.helper(60, 2, 0)
            case 0xBDu8 => this.helper(61, 2, 0)
            case 0xBEu8 =>
                this.movImm(0, X86Lower.u8(ops, 0))
                this.pushReg(0)
                this.depth = this.depth + 1
                this.helper(62, 2, 0)
            case 0xBFu8 => this.helper(69, 1, 0)
            case _ => this.ok = false
        }
    }

    private static func u8(bs: Array<UInt8>, at: Int64): Int64 {
        Int64(bs[at])
    }

    private static func i8(bs: Array<UInt8>, at: Int64): Int64 {
        let v = Int64(bs[at])
        if (v >= 128) {
            v - 256
        } else {
            v
        }
    }

    private static func u16(bs: Array<UInt8>, at: Int64): Int64 {
        Int64(bs[at]) | (Int64(bs[at + 1]) << 8)
    }

    private static func i32(bs: Array<UInt8>, at: Int64): Int64 {
        let v = Int64(bs[at]) | (Int64(bs[at + 1]) << 8) | (Int64(bs[at + 2]) << 16) |
            (Int64(bs[at + 3]) << 24)
        if (v >= 2147483648) {
            v - 4294967296
        } else {
            v
        }
    }

    private static func i64(bs: Array<UInt8>, at: Int64): Int64 {
        var u: UInt64 = 0
        var i = 7
        while (i >= 0) {
            u = (u << 8) | UInt64(bs[at + i])
            i = i - 1
        }
        Int64(u)
    }
}
