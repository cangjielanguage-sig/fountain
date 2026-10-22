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
package fountain::f_jit.bytecode

/**
 * 单指令解码 —— design-m1 §3.3.3、plan-m1 S2.3。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §10.2（操作数编码种类）、§10.3（定长指令表）、
 * §10.1（`rel` 为相对**下一条指令**的有符号 32 位偏移）、§11.2（全部指令定长、逐字节读取）。
 *
 * **归属**：解码与操作数读取全在 `InsnDecoder`（只放 `static` 函数、无实例状态；操作数读取的
 * 首参即解码产物 `insn`）；`DecodedInsn` 只持数据（struct：值语义、按值传递，不与产物表或
 * 调用方共享可变状态）。解释器取指、汇编期校验、反汇编都走这一个入口。
 *
 * **保留 / 禁用编码在解码阶段即拒绝**（§10.1「发射即 `ERR_NOT_IMPL`」）：RSVD 是未分配槽与
 * 0xC0–0xFF 预留区，FORBID 是 0xA9–0xAA 时间构造（M2 启用）；它们**不进入执行**。
 */

/** 解码产物：纯数据（op / 指令长度 / 操作数字节）。 */
public struct DecodedInsn {
    /** opcode。 */
    public let op: UInt8
    /** 本指令总长（1 + 操作数字节），取自 `OpInfo.len`。 */
    public let size: Int64
    /** 操作数字节（不含 opcode 本身），按 §11.2 固定小端排布。 */
    public let operands: Array<UInt8>

    public init(op: UInt8, size: Int64, operands: Array<UInt8>) {
        this.op = op
        this.size = size
        this.operands = operands
    }
}

public class InsnDecoder {
    /**
     * 从 `code[off]` 解出一条指令。
     *
     * - `off` 越界、操作数不足（码流被截断）⇒ 容器格式类拒绝（18）；
     * - opcode 属 RSVD / FORBID ⇒ 语义拒绝（18），不进入执行。
     */
    public static func decode(code: Array<UInt8>, off: Int64): DecodedInsn {
        if (off < 0 || off >= code.size) {
            rejectFormat('指令解码越界: off=${off}, codeLen=${code.size}')
        }
        let op = code[off]
        let info = OpInfo.OPCODE_TABLE[Int64(op)]
        if (info.cat == OpInfo.CAT_RSVD) {
            rejectFormat('保留 opcode 不可执行: 0x${hex2(op)}（M1 发射即 ERR_NOT_IMPL，§10.1）')
        }
        if (info.cat == OpInfo.CAT_FORBID) {
            rejectFormat('禁用 opcode 不可执行: 0x${hex2(op)}（时间构造，M2 启用，§10.1）')
        }
        let opsLen = info.len - 1
        if (off + info.len > code.size) {
            rejectFormat('指令操作数被截断: 0x${hex2(op)} 需 ${info.len} 字节, 余 ${code.size - off} 字节')
        }
        let operands = Array<UInt8>(opsLen, repeat: 0u8)
        for (i in 0..opsLen) {
            operands[i] = code[off + 1 + i]
        }
        DecodedInsn(op, info.len, operands)
    }

    /** 读取 u8 操作数（下标相对 `operands`）。 */
    public static func u8(insn: DecodedInsn, i: Int64): UInt8 {
        need(insn, i, 1)
        insn.operands[i]
    }

    /** 读取 u16 操作数（小端）。 */
    public static func u16(insn: DecodedInsn, i: Int64): UInt16 {
        need(insn, i, 2)
        UInt16(insn.operands[i]) | (UInt16(insn.operands[i + 1]) << 8)
    }

    /** 读取 i32 操作数（小端，补码）。 */
    public static func i32(insn: DecodedInsn, i: Int64): Int32 {
        need(insn, i, 4)
        let b0 = UInt32(insn.operands[i])
        let b1 = UInt32(insn.operands[i + 1])
        let b2 = UInt32(insn.operands[i + 2])
        let b3 = UInt32(insn.operands[i + 3])
        u32ToI32(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }

    /** 读取 i64 操作数（小端，补码）。 */
    public static func i64(insn: DecodedInsn, i: Int64): Int64 {
        need(insn, i, 8)
        var acc: UInt64 = 0u64
        for (k in 0..8) {
            acc = acc | (UInt64(insn.operands[i + k]) << (8 * k))
        }
        u64ToI64(acc)
    }

    /**
     * 相对跳转目标 = **本指令之后的第一条指令位置 + 偏移**（§10.1）。
     *
     * 即 `insnOff + insn.size + offset`——偏移以「下一条指令」而非「本指令」为基准，
     * 这是汇编器回填与解释器取指共用的唯一口径。
     */
    public static func rel32(insn: DecodedInsn, insnOff: Int64): Int64 {
        let offset = i32(insn, 0)
        (insnOff + insn.size) + Int64(offset)
    }

    private static func need(insn: DecodedInsn, i: Int64, width: Int64): Unit {
        if (i < 0 || i + width > insn.operands.size) {
            rejectFormat(
                '操作数下标越界: op=0x${hex2(insn.op)}, i=${i}, width=${width}, operands=${insn.operands.size}')
        }
    }
}

/** 单字节十六进制（诊断文本用，避免宿主格式化差异）。 */
internal func hex2(v: UInt8): String {
    let hi = Int64(v >> 4)
    let lo = Int64(v & 0x0Fu8)
    hexDigit(hi) + hexDigit(lo)
}

internal func hexDigit(v: Int64): String {
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
