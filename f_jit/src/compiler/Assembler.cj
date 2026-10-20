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
package fountain::f_jit.compiler

import std.collection.ArrayList
import fountain::f_jit.base.LocalType
import fountain::f_jit.bytecode.ByteWriter
import fountain::f_jit.bytecode.DecodedInsn
import fountain::f_jit.bytecode.FbcWriter
import fountain::f_jit.bytecode.FbcRuleRegistry
import fountain::f_jit.bytecode.FbcRuleSet
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.FuncFlags
import fountain::f_jit.bytecode.InsnDecoder
import fountain::f_jit.bytecode.OpInfo

/**
 * 汇编器 —— design-m1 §4.3.7、plan-m1 S3.20、规格 §11.6–11.7。
 *
 * 把 `CompileSession` 里逐个登记的函数体拼成 `.fbc`：
 *
 * ```
 * code 段 = FuncDir（count: u32 + 26 B × count）
 *           + 每个函数：局部类型表（nLocals B）
 *           + 每个函数：函数体（code 片段）
 * ```
 *
 * 同时完成站点**相对偏移 → 绝对偏移**的换算：`SET_SITE` 的立即数在降低期是本函数内偏移，
 * 这里加上 `codeOff` 并写入站点表（§11.6「全量 SET_SITE 必有条目」）。
 *
 * **汇编期校验 1–11 的落地范围**：本步保证结构自洽（目录/类型表/长度/入口命中），
 * 深度规则（未回填标签、分支汇合、栈下越界）已在 `BytecodeBuilder` 内即时拒绝；
 * 数据流与类型表合法性由 `FbcReader` 加载期复核（同一口径的双保险）。
 */
internal class Assembler {
    private let sess: CompileSession

    public init(sess: CompileSession) {
        this.sess = sess
    }

    /** 组装完整 `.fbc` 字节串。 */
    public func assemble(): Array<UInt8> {
        let n = this.sess.funcCount
        if (n == 0) {
            codeFail('汇编期无函数可产出（至少应有入口函数）')
        }
        let rules = this.rules()
        // 先冻结：校验 4 要求 `PUSH_KH` 的索引落在**已冻结**的常量表内。
        this.sess.consts.freeze()
        this.validateAll(rules)

        // 1) 计算布局：目录 + (类型表 + 体) × n
        let dirSize = 4 + 26 * n
        var entries = ArrayList<FuncEntry>()
        var bodies = ArrayList<Array<UInt8>>()
        var off = dirSize
        var i: Int64 = 0
        while (i < n) {
            let f = this.sess.funcAt(i)
            let ltSize = f.types.size
            let ltOff = off
            let codeOff = off + ltSize
            // 复制并回填站点立即数（函数内相对 → code 段绝对）
            let body = Array<UInt8>(f.body.code.size, repeat: 0u8)
            for (k in 0..f.body.code.size) {
                body[k] = f.body.code[k]
            }
            for (ps in f.sites) {
                let abs = codeOff + ps.relOff
                Assembler.patchI32(body, ps.relOff, abs)
                this.sess.sites.add(UInt32(abs), ps.pos)
            }
            entries.add(FuncEntry(f.fnId, UInt32(codeOff), UInt32(f.codeLen()), UInt32(ltOff),
                UInt16(f.nargs), UInt16(f.nLocals()), UInt16(f.body.maxStack), f.retType,
                f.body.flags))
            bodies.add(body)
            off = codeOff + Int64(f.body.code.size)
            i = i + 1
        }

        // 2) 写 code 段
        let cw = ByteWriter()
        cw.wU32(UInt32(n))
        for (e in entries) {
            cw.wU32(e.fnId)
            cw.wU32(e.codeOff)
            cw.wU32(e.codeLen)
            cw.wU32(e.localTypesOff)
            cw.wU16(e.nargs)
            cw.wU16(e.nLocals)
            cw.wU16(e.maxStack)
            cw.wU16(e.retType)
            cw.wU16(e.flags)
        }
        var j: Int64 = 0
        while (j < n) {
            let f = this.sess.funcAt(j)
            f.types.write(cw)
            cw.wBytes(bodies[j])
            j = j + 1
        }
        let codeBytes = cw.take()

        // 3) 常量 / 站点 / 名字段
        this.sess.sites.freeze()
        this.sess.names.freeze()
        let constBytes = this.sess.consts.encode()
        let siteBytes = this.sess.sites.encode()
        let nameBytes = this.sess.names.encode()

        // 4) 头 + 四段
        let w = FbcWriter()
        w.setVersion(rules.verMajor, rules.maxVerMinor)
        w.setEntryFn(this.sess.entryFn)
        w.setCode(codeBytes)
        w.setConst(constBytes)
        w.setSite(siteBytes)
        w.setName(nameBytes)
        w.build()
    }

    /** 汇编目标规则集：只接受**已实现**的版本；v3 仅登记，不能作为汇编目标。 */
    private func rules(): FbcRuleSet {
        match (FbcRuleRegistry.get(this.sess.verMajor)) {
            case Some(r) => if (r.implemented) {
                r
            } else {
                codeFail('汇编目标 verMajor=${this.sess.verMajor} 未实现（规则集仅登记合法集，design-m2 D12）')
            }
            case None => codeFail('汇编目标 verMajor=${this.sess.verMajor} 未登记（design-m2 D12）')
        }
    }

    /**
     * §7 校验 1–11 的汇编期落地（design-m1 §4.3.7）。
     *
     * 只做**字节流可判定**的部分：结构（1/2/4/5/7/8/9/11）在此统一拒绝；3 由 `BytecodeBuilder`
     * 构建期即时拒绝（sink 前栈平衡）、10 由 `DefiniteAssignment` 前端拒绝（同一口径双保险）。
     *
     * Q2.4 起校验按 `FbcRuleSet` 参数化：合法 LocalType 集与 `CALL_HOST` 版本门槛取自同一规则集。
     */
    private func validateAll(rules: FbcRuleSet): Unit {
        if (Int64(this.sess.entryFn) >= this.sess.funcCount) {
            codeFail('入口函数号越界: ${this.sess.entryFn} / ${this.sess.funcCount}（§11.7）')
        }
        var i: Int64 = 0
        while (i < this.sess.funcCount) {
            this.validateFunc(this.sess.funcAt(i), rules)
            i = i + 1
        }
    }

    private func validateFunc(f: LoweredFunc, rules: FbcRuleSet): Unit {
        let code = f.body.code
        var off: Int64 = 0
        // CALL_HOST 的栈布局校验需要「到此为止的栈深」与每个深度上的压栈来源；
        // 其余指令不据深度拒绝（分支汇合由 BytecodeBuilder 在构建期守）。
        var depth: Int64 = 0
        // slots[i] = 第 i 个栈元素由哪条 `LOADL` 压入（槽号）；非 `LOADL` 压入记 -1。
        var slots = ArrayList<Int64>()
        while (off < code.size) {
            let info = OpInfo.OPCODE_TABLE[Int64(code[off])]
            if (info.cat == OpInfo.CAT_FORBID || info.cat == OpInfo.CAT_RSVD) {
                notImplFail('禁用/保留 opcode 0x${Assembler.hex(code[off])} @${off}（§7 校验 2）')
            }
            if (off + info.len > code.size) {
                codeFail('指令操作数被截断: opcode 0x${Assembler.hex(code[off])} @${off}（§7 校验 2）')
            }
            let insn = InsnDecoder.decode(code, off)
            let op = insn.op
            // 8) M2 专属指令：HW_OPEN/HW_CLOSE 恒 NotImpl；CALL_HOST 由规则集决定
            if (op == Op.HW_OPEN || op == Op.HW_CLOSE) {
                notImplFail('M2 专属指令 0x${Assembler.hex(op)} @${off} 在后档专项未实现（§7 校验 8）')
            }
            if (op == Op.CALL_HOST && !rules.isInstructionLegal(op)) {
                notImplFail(
                    'M2 专属指令 0x${Assembler.hex(op)} @${off} 在 verMajor=${rules.verMajor} 规则集下未启用（§7 校验 8）')
            }
            // 1/6) 每条 CALL_HELPER(_V) 必须紧邻 CHECK_ERR（跨回边也不得被优化掉）
            if (op == Op.CALL_HELPER || op == Op.CALL_HELPER_V) {
                let next = off + insn.size
                if (next >= code.size || code[next] != Op.CHECK_ERR) {
                    codeFail('CALL_HELPER 后缺 CHECK_ERR @${off}（§7 校验 1/6）')
                }
            }
            // 4) PUSH_KH 索引 < 常量表长度（常量表在布局前冻结）
            if (op == Op.PUSH_KH) {
                let idx = Int64(InsnDecoder.u16(insn, 0))
                if (idx >= this.sess.consts.size) {
                    codeFail('PUSH_KH 常量索引越界: ${idx} / ${this.sess.consts.size}（§7 校验 4）')
                }
            }
            // 5) 局部槽索引 < nLocals
            if (op == Op.LOADL || op == Op.STOREL) {
                let idx = Int64(InsnDecoder.u16(insn, 0))
                if (idx >= f.nLocals()) {
                    codeFail('局部槽越界: ${idx} / ${f.nLocals()} @${off}（§7 校验 5）')
                }
            }
            if (op >= Op.LOADL0 && op <= Op.LOADL3) {
                let idx = Int64(op - Op.LOADL0)
                if (idx >= f.nLocals()) {
                    codeFail('压缩局部槽越界: LOADL${idx} / ${f.nLocals()} @${off}（§7 校验 5）')
                }
            }
            // 7) CALL_FUNC 目标必须在目录内且 argc == nargs
            if (op == Op.CALL_FUNC) {
                let fid = InsnDecoder.u16(insn, 0)
                let argc = Int64(InsnDecoder.u8(insn, 2))
                let nargs = this.nargsOf(fid)
                if (nargs < 0) {
                    codeFail('CALL_FUNC 目标不在目录内: fid=${fid} @${off}（§7 校验 7）')
                }
                if (nargs != argc) {
                    codeFail(
                        'CALL_FUNC argc 不符: fid=${fid} argc=${argc} nargs=${nargs} @${off}（§7 校验 7）')
                }
            }
            // 7') Q2.4：CALL_HOST 的 `[h_fn, a1..an]` 栈布局（h_fn 是**最先**压入的那个）
            if (op == Op.CALL_HOST) {
                let argc = Int64(InsnDecoder.u8(insn, 0))
                if (depth < argc + 1 || slots.size < argc + 1) {
                    codeFail(
                        'CALL_HOST argc 与栈不符: argc=${argc} 需 ${argc + 1} 槽，实际 ${depth} @${off}（§7 校验 7）')
                }
                let base = slots[slots.size - argc - 1]
                if (!Assembler.isHostClosureSlot(base, f)) {
                    codeFail('CALL_HOST 调用块栈底非句柄: 须为 13 型 LOADL @${off}（§7 校验 7）')
                }
            }
            // 11) 变更型函数禁用 deopt 源（DEC_TO_I64 / TO_I64 的 mode=1）
            if (op == Op.DEC_TO_I64 || op == Op.TO_I64) {
                let mode = InsnDecoder.u8(insn, 0)
                if ((f.body.flags & FuncFlags.MUTATION) != 0u16 && mode == 1u8) {
                    notImplFail(
                        '变更型函数禁用 deopt 模式: op=0x${Assembler.hex(op)} mode=1 @${off}（§7 校验 11）')
                }
            }
            // 栈深（仅供 CALL_HOST 判据；分支造成的偏差不在此拒绝）
            let (pop, push) = StackEffect.of(op, Assembler.effectArgc(op, insn))
            if (pop >= 0) {
                var k: Int64 = 0
                while (k < pop && !slots.isEmpty()) {
                    slots.remove(at: slots.size - 1)
                    k = k + 1
                }
                let loaded = Assembler.loadedSlotOf(op, insn)
                var j: Int64 = 0
                while (j < push) {
                    slots.add(if (j == 0) { loaded } else { -1 })
                    j = j + 1
                }
                depth = if (depth >= pop) {
                    depth - pop + push
                } else {
                    push
                }
            }
            off = off + insn.size
        }
        // 9) 类型表长度 = nLocals（由 LocalTypes 保证）且值在规则集合法集内
        var i: Int64 = 0
        while (i < f.types.size) {
            let t = UInt16(f.types.get(i))
            if (!rules.isLocalTypeInLegalSet(t)) {
                codeFail(
                    '局部槽类型码非法: ${t} @${i}（verMajor=${rules.verMajor} 合法集 0–${rules.maxLocalType}，§7 校验 9）')
            }
            i = i + 1
        }
    }

    /** `CALL_HOST` 调用块栈底必须是 `LOADL`/`LOADL0-3` 且槽类型为 13（HostClosure）。 */
    private static func isHostClosureSlot(slot: Int64, f: LoweredFunc): Bool {
        slot >= 0 && slot < f.types.size &&
            UInt16(f.types.get(slot)) == LocalType.HOST_CLOSURE
    }

    /** 栈账所需的 `argc`（`CALL_*` 家族）；其余 0。 */
    private static func effectArgc(op: UInt8, insn: DecodedInsn): Int64 {
        if (op == Op.CALL_HELPER || op == Op.CALL_HELPER_NC || op == Op.CALL_HELPER_V ||
            op == Op.CALL_FUNC) {
            return Int64(InsnDecoder.u8(insn, 2))
        }
        if (op == Op.CALL_CLOSURE || op == Op.CALL_HOST) {
            return Int64(InsnDecoder.u8(insn, 0))
        }
        0
    }

    /** `LOADL*` 压入的槽号；其余返回 −1。 */
    private static func loadedSlotOf(op: UInt8, insn: DecodedInsn): Int64 {
        if (op == Op.LOADL) {
            return Int64(InsnDecoder.u16(insn, 0))
        }
        if (op >= Op.LOADL0 && op <= Op.LOADL3) {
            return Int64(op - Op.LOADL0)
        }
        -1
    }

    /** 目录内按 fnId 查形参个数；未命中 → −1。 */
    private func nargsOf(fid: UInt16): Int64 {
        var i: Int64 = 0
        while (i < this.sess.funcCount) {
            let f = this.sess.funcAt(i)
            if (f.fnId == UInt32(fid)) {
                return f.nargs
            }
            i = i + 1
        }
        -1
    }

    private static func hex(v: UInt8): String {
        let hi = Int64(v >> 4)
        let lo = Int64(v & 0x0Fu8)
        Assembler.hexDigit(hi) + Assembler.hexDigit(lo)
    }

    private static func hexDigit(v: Int64): String {
        match (v) {
            case 0 => '0'
            case 1 => '1'
            case 2 => '2'
            case 3 => '3'
            case 4 => '4'
            case 5 => '5'
            case 6 => '6'
            case 7 => '7'
            case 8 => '8'
            case 9 => '9'
            case 10 => 'A'
            case 11 => 'B'
            case 12 => 'C'
            case 13 => 'D'
            case 14 => 'E'
            case _ => 'F'
        }
    }

    /** 回填 `i32` 立即数（小端，位于 `opOff + 1`）。 */
    private static func patchI32(code: Array<UInt8>, opOff: Int64, v: Int64): Unit {
        let u = UInt32(Int32(v))
        var k = 0
        while (k < 4) {
            code[opOff + 1 + k] = UInt8((u >> (8 * UInt32(k))) & 0xFFu32)
            k = k + 1
        }
    }
}
