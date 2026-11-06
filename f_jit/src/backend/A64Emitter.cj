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

/** 标签：名字 + 字节偏移。 */
internal struct A64Label {
    let name: String
    let at: Int64

    init(name: String, at: Int64) {
        this.name = name
        this.at = at
    }
}

/** 重定位项：kind 0=B/BL(imm26)、1=B.cond(imm19)、2=CBZ/CBNZ(imm19)。 */
internal struct A64Reloc {
    let at: Int64
    let kind: Int64
    let label: String

    init(at: Int64, kind: Int64, label: String) {
        this.at = at
        this.kind = kind
        this.label = label
    }
}

/**
 * AArch64 指令发射器（S5.9 基础）：小端 32 位字、标签与分支重定位。
 *
 * 编码以 `as`/`objdump` 实测为准（见 `A64_test` 的期望字）。
 */
internal class A64Emitter {
    private let out: ArrayList<UInt8>
    private let labels: ArrayList<A64Label>
    private let relocs: ArrayList<A64Reloc>
    private var done: Bool
    /** 条件分支一律放大为「取反条件 +8；b target」（±1 MB 越界时由第二遍开启）。 */
    private let farCond: Bool

    init() {
        this.out = ArrayList<UInt8>()
        this.labels = ArrayList<A64Label>()
        this.relocs = ArrayList<A64Reloc>()
        this.done = false
        this.farCond = false
    }

    /** 跳板模式：所有条件分支占 8 B（`b.cond +8; b target`）。 */
    init(farCond: Bool) {
        this.out = ArrayList<UInt8>()
        this.labels = ArrayList<A64Label>()
        this.relocs = ArrayList<A64Reloc>()
        this.done = false
        this.farCond = farCond
    }

    func size(): Int64 {
        this.out.size
    }

    func bind(name: String): Unit {
        this.labels.add(A64Label(name, this.out.size))
    }

    func labelOffset(name: String): Int64 {
        for (l in this.labels) {
            if (l.name == name) {
                return l.at
            }
        }
        -1
    }

    func word(w: UInt32): Unit {
        var k = 0
        while (k < 4) {
            this.out.add(UInt8((w >> (8 * UInt32(k))) & 0xFFu32))
            k = k + 1
        }
    }

    private func readWord(at: Int64): UInt32 {
        var w = 0u32
        var k = 0
        while (k < 4) {
            w = w | (UInt32(this.out[at + k]) << (8 * UInt32(k)))
            k = k + 1
        }
        w
    }

    private func patchWord(at: Int64, w: UInt32): Unit {
        var k = 0
        while (k < 4) {
            this.out[at + k] = UInt8((w >> (8 * UInt32(k))) & 0xFFu32)
            k = k + 1
        }
    }

    /** 回填全部分支重定位并返回字节序列（幂等）。 */
    func finish(): Array<UInt8> {
        if (this.done) {
            return this.out.toArray()
        }
        for (r in this.relocs) {
            let target = this.labelOffset(r.label)
            let delta = target - r.at
            let base = this.readWord(r.at)
            if (r.kind == 0) {
                let imm = (delta >> 2) & 0x03FFFFFF
                this.patchWord(r.at, base | UInt32(imm))
            } else {
                let imm = (delta >> 2) & 0x7FFFF
                this.patchWord(r.at, base | (UInt32(imm) << 5))
            }
        }
        this.done = true
        this.out.toArray()
    }

    /**
     * 回填并**校验分支可达范围**：`b/bl` ±128 MB、`b.cond`/`cbz`/`cbnz` ±1 MB。
     *
     * 越界 → None（调用方降级解释器；跳板改写由布局阶段 S5.10 负责）。
     */
    func finishOrNull(): ?Array<UInt8> {
        for (r in this.relocs) {
            let delta = this.labelOffset(r.label) - r.at
            if (delta % 4 != 0) {
                return None
            }
            let words = delta / 4
            if (r.kind == 0) {
                if (words < -33554432 || words > 33554431) {
                    return None
                }
            } else {
                if (words < -262144 || words > 262143) {
                    return None
                }
            }
        }
        Some(this.finish())
    }

    // ---- 分支 ----

    func b(label: String): Unit {
        this.relocs.add(A64Reloc(this.out.size, 0, label))
        this.word(0x14000000u32)
    }

    func bl(label: String): Unit {
        this.relocs.add(A64Reloc(this.out.size, 0, label))
        this.word(0x94000000u32)
    }

    func bCond(cond: Int64, label: String): Unit {
        if (this.farCond) {
            // b.<inverse> +8（跳过下一条 b）；b label（±128 MB）
            this.word(0x54000000u32 | (UInt32(A64Emitter.invert(cond)) & 0xFu32) | (2u32 << 5))
            this.b(label)
        } else {
            this.relocs.add(A64Reloc(this.out.size, 1, label))
            this.word(0x54000000u32 | (UInt32(cond) & 0xFu32))
        }
    }

    func cbz(rt: Int64, label: String): Unit {
        if (this.farCond) {
            this.word(0xB5000000u32 | (2u32 << 5) | UInt32(rt)) // cbnz rt,+8
            this.b(label)
        } else {
            this.relocs.add(A64Reloc(this.out.size, 2, label))
            this.word(0xB4000000u32 | UInt32(rt))
        }
    }

    func cbnz(rt: Int64, label: String): Unit {
        if (this.farCond) {
            this.word(0xB4000000u32 | (2u32 << 5) | UInt32(rt)) // cbz rt,+8
            this.b(label)
        } else {
            this.relocs.add(A64Reloc(this.out.size, 2, label))
            this.word(0xB5000000u32 | UInt32(rt))
        }
    }

    private static func invert(cond: Int64): Int64 {
        match (cond) {
            case 0 => 1
            case 1 => 0
            case 2 => 3
            case 3 => 2
            case 4 => 5
            case 5 => 4
            case 6 => 7
            case 7 => 6
            case 8 => 9
            case 9 => 8
            case 10 => 11
            case 11 => 10
            case 12 => 13
            case 13 => 12
            case _ => 1
        }
    }

    // ---- 杂项 / 帧序 ----

    func nop(): Unit {
        this.word(0xD503201Fu32)
    }

    func btiC(): Unit {
        this.word(0xD503245Fu32)
    }

    func ret(): Unit {
        this.word(0xD65F03C0u32)
    }

    func brk(): Unit {
        this.word(0xD4200000u32)
    }

    func blr(rn: Int64): Unit {
        this.word(0xD63F0000u32 | (UInt32(rn) << 5))
    }

    func prologue(): Unit {
        this.word(0xA9BF7BFDu32) // stp x29,x30,[sp,#-16]!
        this.word(0x910003FDu32) // mov x29,sp
        this.word(0xF81F83B3u32) // stur x19,[x29,#-8]
        this.word(0xF81F03B4u32) // stur x20,[x29,#-16]
        // FPCR.DN=1（§12.4：NaN 规范化由硬件完成；原值存 [x29,#-24]，出口恢复）
        this.word(0xD53B4409u32) // mrs x9,fpcr
        this.word(0xF81E83A9u32) // stur x9,[x29,#-24]
        this.word(0xB2670129u32) // orr x9,x9,#0x02000000
        this.word(0xD51B4409u32) // msr fpcr,x9
    }

    func epilogue(): Unit {
        this.word(0xF85E83A9u32) // ldur x9,[x29,#-24]
        this.word(0xD51B4409u32) // msr fpcr,x9
        this.word(0xF85F03B4u32) // ldur x20,[x29,#-16]
        this.word(0xF85F83B3u32) // ldur x19,[x29,#-8]
        this.word(0x910003BFu32) // mov sp,x29
        this.word(0xA8C17BFDu32) // ldp x29,x30,[sp],#16
        this.word(0xD65F03C0u32) // ret
    }

    // ---- 立即数与寄存器 ----

    func movz(rd: Int64, imm16: Int64, shift: Int64): Unit {
        this.word(0xD2800000u32 | (UInt32(shift / 16) << 21) | (UInt32(imm16 & 0xFFFF) << 5) | UInt32(rd))
    }

    func movk(rd: Int64, imm16: Int64, shift: Int64): Unit {
        this.word(0xF2800000u32 | (UInt32(shift / 16) << 21) | (UInt32(imm16 & 0xFFFF) << 5) | UInt32(rd))
    }

    func movImm64(rd: Int64, v: Int64): Unit {
        var first = true
        var shift = 0
        while (shift < 64) {
            let chunk = (v >> shift) & 0xFFFF
            if (first) {
                this.movz(rd, chunk, shift)
                first = false
            } else if (chunk != 0) {
                this.movk(rd, chunk, shift)
            }
            shift = shift + 16
        }
    }

    func movReg(rd: Int64, rm: Int64): Unit {
        this.word(0xAA0003E0u32 | (UInt32(rm) << 16) | UInt32(rd))
    }

    func addImm(rd: Int64, rn: Int64, imm: Int64): Unit {
        this.word(0x91000000u32 | (UInt32(imm & 0xFFF) << 10) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func subImm(rd: Int64, rn: Int64, imm: Int64): Unit {
        this.word(0xD1000000u32 | (UInt32(imm & 0xFFF) << 10) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func addReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x8B000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func subReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0xCB000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func addsReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0xAB000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func subsReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0xEB000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func cmpReg(rn: Int64, rm: Int64): Unit {
        this.word(0xEB00001Fu32 | (UInt32(rm) << 16) | (UInt32(rn) << 5))
    }

    func cmpImm(rn: Int64, imm: Int64): Unit {
        this.word(0xF100001Fu32 | (UInt32(imm & 0xFFF) << 10) | (UInt32(rn) << 5))
    }

    func mul(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x9B007C00u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func msub(rd: Int64, rn: Int64, rm: Int64, ra: Int64): Unit {
        this.word(0x9B008000u32 | (UInt32(rm) << 16) | (UInt32(ra) << 10) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func sdiv(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x9AC00C00u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func neg(rd: Int64, rm: Int64): Unit {
        this.word(0xCB0003E0u32 | (UInt32(rm) << 16) | UInt32(rd))
    }

    func mvn(rd: Int64, rm: Int64): Unit {
        this.word(0xAA2003E0u32 | (UInt32(rm) << 16) | UInt32(rd))
    }

    func andReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x8A000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func orrReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0xAA000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func eorReg(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0xCA000000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    /**
     * `EOR Xd, Xn, #1`（`EOR (immediate)`：`sf=1, opc=10, N=1, immr=0, imms=0`）。
     *
     * 位掩码恒为 `#1`，因此只有 `Rn`(9–5) / `Rd`(4–0) 两个字段需要填——走字段构造
     * 而不是裸字面量，正是为了避免「注释写 `X9, X9`、编码却是 `X9, X0`」这类
     * 长期不一致（fix-jit-unary-not D1）。
     */
    func eorImm1(rd: Int64, rn: Int64): Unit {
        this.word(0xD2400000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func lslv(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x9AC02000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func lsrv(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x9AC02400u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func asrv(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x9AC02800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func clz(rd: Int64, rn: Int64): Unit {
        this.word(0xDAC01000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    /** `cset rd, cond`（cond 为期望条件码；内部取反给 csinc）。 */
    func cset(rd: Int64, cond: Int64): Unit {
        let inv = match (cond) {
            case 0 => 1
            case 1 => 0
            case 2 => 3
            case 3 => 2
            case 4 => 5
            case 5 => 4
            case 6 => 7
            case 7 => 6
            case 8 => 9
            case 9 => 8
            case 10 => 11
            case 11 => 10
            case 12 => 13
            case 13 => 12
            case _ => 1
        }
        this.word(0x9A9F07E0u32 | (UInt32(inv) << 12) | UInt32(rd))
    }

    func csel(rd: Int64, rn: Int64, rm: Int64, cond: Int64): Unit {
        this.word(0x9A800000u32 | (UInt32(rm) << 16) | (UInt32(cond) << 12) | (UInt32(rn) << 5) | UInt32(rd))
    }

    // ---- 内存 ----

    /**
     * 慢路径 scratch（IP0 / x16）：寄存器分配只用 x0–x15，x16/x17 是调用约定的临时寄存器。
     *
     * 偏移超出 `STUR/LDUR` 的 imm9（−256..255）时，先 `scratch = rn + off` 再访问
     * `[scratch, #0]`，**不再**把偏移截断成 9 位（旧实现 `off & 0x1FF` 会让 −257 读成 +255、
     * 256 读成 −256，静默错位）。
     */
    private static const SCRATCH: Int64 = 16

    // ---- 发射审计（G5，与 x86 侧同构）----
    //
    // 记录每条 `ldr/str` 的**概念基址**（慢路径的 scratch 仍归属 `rn`）；`A64Compiler` 在
    // 降低结束后校验必须落在 `{x19(19), x20(20), x29(29), sp(31)}`。
    private static let auditMemBases = ArrayList<Int64>()

    internal static func noteMemBase(reg: Int64): Unit {
        auditMemBases.add(reg)
    }

    internal static func resetAuditMemBases(): Unit {
        auditMemBases.clear()
    }

    internal static func auditMemBasesSnapshot(): Array<Int64> {
        auditMemBases.toArray()
    }

    /** 允许的内存基址：`x19(19)` / `x20(20)` / `x29(29)` / `sp(31)`；其余一律拒绝。 */
    internal static func auditAllows(bases: Array<Int64>): Bool {
        for (b in bases) {
            if (b != 19 && b != 20 && b != 29 && b != 31) {
                return false
            }
        }
        true
    }

    func strOff(rt: Int64, rn: Int64, off: Int64): Unit {
        A64Emitter.noteMemBase(rn)
        if (off >= 0 && off % 8 == 0 && off <= 32760) {
            this.word(0xF9000000u32 | (UInt32(off / 8) << 10) | (UInt32(rn) << 5) | UInt32(rt))
        } else if (off >= -256 && off <= 255) {
            this.word(0xF8000000u32 | (UInt32(off & 0x1FF) << 12) | (UInt32(rn) << 5) | UInt32(rt))
        } else {
            this.addOff(A64Emitter.SCRATCH, rn, off)
            this.word(0xF9000000u32 | (UInt32(A64Emitter.SCRATCH) << 5) | UInt32(rt))
        }
    }

    func ldrOff(rt: Int64, rn: Int64, off: Int64): Unit {
        A64Emitter.noteMemBase(rn)
        this.emitLdr(rt, rn, off)
    }

    /**
     * 以**宿主绝对地址**为基址的读：基址寄存器由 `movImm64` 物化（常量镜像 / 函数表），
     * 不是 cell，因此**不参与** G5 审计。
     *
     * 审计要防的是「把 helper 返回的 cell 当指针解引用」；这类地址来自桥，属于可信输入。
     */
    func ldrAbs(rt: Int64, rn: Int64, off: Int64): Unit {
        this.emitLdr(rt, rn, off)
    }

    private func emitLdr(rt: Int64, rn: Int64, off: Int64): Unit {
        if (off >= 0 && off % 8 == 0 && off <= 32760) {
            this.word(0xF9400000u32 | (UInt32(off / 8) << 10) | (UInt32(rn) << 5) | UInt32(rt))
        } else if (off >= -256 && off <= 255) {
            this.word(0xF8400000u32 | (UInt32(off & 0x1FF) << 12) | (UInt32(rn) << 5) | UInt32(rt))
        } else {
            this.addOff(A64Emitter.SCRATCH, rn, off)
            this.word(0xF9400000u32 | (UInt32(A64Emitter.SCRATCH) << 5) | UInt32(rt))
        }
    }

    /** `rd = rn + off`：`add/sub` 的 imm12 只有 4095，按块累加（|off| 可超 4K）。 */
    private func addOff(rd: Int64, rn: Int64, off: Int64): Unit {
        var left = off
        var cur = rn
        while (left > 4095) {
            this.addImm(rd, cur, 4095)
            cur = rd
            left = left - 4095
        }
        while (left < -4095) {
            this.subImm(rd, cur, 4095)
            cur = rd
            left = left + 4095
        }
        if (left >= 0) {
            this.addImm(rd, cur, left)
        } else {
            this.subImm(rd, cur, 0 - left)
        }
    }

    func strD(rt: Int64, rn: Int64, off: Int64): Unit {
        this.word(0xFD000000u32 | (UInt32(off / 8) << 10) | (UInt32(rn) << 5) | UInt32(rt))
    }

    func ldrD(rt: Int64, rn: Int64, off: Int64): Unit {
        this.word(0xFD400000u32 | (UInt32(off / 8) << 10) | (UInt32(rn) << 5) | UInt32(rt))
    }

    // ---- 浮点 ----

    func fmovDFromX(rd: Int64, rn: Int64): Unit {
        this.word(0x9E670000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fmovXFromD(rd: Int64, rn: Int64): Unit {
        this.word(0x9E660000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fadd(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x1E602800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fsub(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x1E603800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fmul(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x1E600800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fdiv(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x1E601800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fneg(rd: Int64, rn: Int64): Unit {
        this.word(0x1E614000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fabs(rd: Int64, rn: Int64): Unit {
        this.word(0x1E60C000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fsqrt(rd: Int64, rn: Int64): Unit {
        this.word(0x1E61C000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fmin(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x1E625800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fmax(rd: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0x1E624800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fcmp(rn: Int64, rm: Int64): Unit {
        this.word(0x1E602000u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5))
    }

    func frintm(rd: Int64, rn: Int64): Unit {
        this.word(0x1E654000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func frintp(rd: Int64, rn: Int64): Unit {
        this.word(0x1E64C000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func frintz(rd: Int64, rn: Int64): Unit {
        this.word(0x1E65C000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func frintn(rd: Int64, rn: Int64): Unit {
        this.word(0x1E644000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func scvtf(rd: Int64, rn: Int64): Unit {
        this.word(0x9E620000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    func fcvtzs(rd: Int64, rn: Int64): Unit {
        this.word(0x9E780000u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    // ---- 位计数 / 寄存器偏移寻址（S5.9）----

    /** `cnt vd.8b, vn.8b`。 */
    func cntBytes(rd: Int64, rn: Int64): Unit {
        this.word(0x0E205800u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    /** `addv bd, vn.8b`（横向求和到字节）。 */
    func addvB(rd: Int64, rn: Int64): Unit {
        this.word(0x0E31B800u32 | (UInt32(rn) << 5) | UInt32(rd))
    }

    /** `ldr xt, [xn, xm, lsl #3]`（fnTable 间接取入口）。 */
    func ldrReg(rt: Int64, rn: Int64, rm: Int64): Unit {
        this.word(0xF8607800u32 | (UInt32(rm) << 16) | (UInt32(rn) << 5) | UInt32(rt))
    }
}

/** 条件码（AArch64）。 */
internal class A64Cond {
    static const EQ: Int64 = 0
    static const NE: Int64 = 1
    static const HS: Int64 = 2
    static const LO: Int64 = 3
    static const MI: Int64 = 4
    static const PL: Int64 = 5
    static const VS: Int64 = 6
    static const VC: Int64 = 7
    static const HI: Int64 = 8
    static const LS: Int64 = 9
    static const GE: Int64 = 10
    static const LT: Int64 = 11
    static const GT: Int64 = 12
    static const LE: Int64 = 13
}
