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

import fountain::f_base.UnsafeBytes
import fountain::f_jit.bytecode.OpInfo

/**
 * 字节码的**文本可读形式**（供降低 / 汇编用例断言）——plan-m1 S3.19 联测。
 *
 * **为什么放在 lib 单元**（design §4.3 实施注意 1）：把解码逻辑抄进 `*_test.cj` 会让每个测试文件
 * 各自维护一份偏移口径；集中到本文件后，用例一律断言**字符串**，与第一现场的
 * 「不要直接 match 递归 AST 枚举」同族规则。
 *
 * 三种视图：
 *
 * - `dump`：逐行 `偏移: 助记符 操作数`，`rel32` 渲染为 `->绝对目标`（口径同 `InsnDecoder.rel32`）；
 * - `ops`：只留助记符序列（空格分隔），用于「指令序列」级断言；
 * - `hex`：原始字节小写十六进制，用于单条指令的编码断言。
 */
internal class CodeDump {
    /** 逐行反汇编；未知 opcode 记为 `RSVD(op)`（保持行数与指令数一致）。 */
    public static func dump(code: Array<UInt8>): String {
        let table = OpInfo.OPCODE_TABLE
        var out = ''
        var p = 0
        while (p < code.size) {
            let op = code[p]
            let info = table[Int64(op)]
            if (p > 0) {
                out = out + '\n'
            }
            out = out + pad4(p) + ': ' + mnemonicOf(info.name, info.cat) + operandsOf(code, p, info)
            p = p + info.len
        }
        out
    }

    /** 只留助记符序列（空格分隔）。 */
    public static func ops(code: Array<UInt8>): String {
        let table = OpInfo.OPCODE_TABLE
        var out = ''
        var p = 0
        while (p < code.size) {
            let info = table[Int64(code[p])]
            if (p > 0) {
                out = out + ' '
            }
            out = out + mnemonicOf(info.name, info.cat)
            p = p + info.len
        }
        out
    }

    /** 小写十六进制（无分隔符）。 */
    public static func hex(bs: Array<UInt8>): String {
        var out = ''
        for (b in bs) {
            out = out + hex2(b)
        }
        out
    }

    private static func mnemonicOf(name: String, _: UInt8): String {
        if (name.startsWith('OP_RSVD')) {
            return 'RSVD'
        }
        if (name.startsWith('OP_')) {
            return sliceText(name, 3)
        }
        name
    }

    /** 去掉前 `n` 个字节（逐字节走，不依赖 String 下标语义）。 */
    private static func sliceText(s: String, n: Int64): String {
        let bs = s.unsafeBytes()
        var out = Array<UInt8>(bs.size - n, repeat: 0u8)
        for (i in n..bs.size) {
            out[i - n] = bs[i]
        }
        String.fromUtf8(out)
    }

    /** 按 fmt 渲染操作数字符串（前导一个空格）。 */
    private static func operandsOf(code: Array<UInt8>, p: Int64, info: OpInfo): String {
        match (info.fmt) {
            case '-' => ''
            case 'u8' => ' ' + code[p + 1].toString()
            case 'i8' => ' ' + signed8(code[p + 1]).toString()
            case 'u16' => ' ' + u16At(code, p + 1).toString()
            case 'i32' => ' ' + i32At(code, p + 1).toString()
            case 'rel32' => ' ->' + pad4(p + info.len + i32At(code, p + 1))
            case 'i64' => ' ' + i64At(code, p + 1).toString()
            case 'u16 u8' => ' ' + u16At(code, p + 1).toString() + ',' + code[p + 3].toString()
            case _ => ' <bad-fmt>'
        }
    }

    private static func signed8(v: UInt8): Int64 {
        let n = Int64(v)
        if (n >= 128) {
            n - 256
        } else {
            n
        }
    }

    private static func pad4(v: Int64): String {
        let s = if (v < 0) {
            (-v).toString()
        } else {
            v.toString()
        }
        var pad = ''
        var n = byteLenOf(s)
        while (n < 4) {
            pad = pad + '0'
            n = n + 1
        }
        if (v < 0) {
            '-' + pad + s
        } else {
            pad + s
        }
    }

    private static func byteLenOf(s: String): Int64 {
        s.unsafeBytes().size
    }

    private static func hex2(v: UInt8): String {
        let hi = Int64(v) / 16
        let lo = Int64(v) % 16
        digit(hi) + digit(lo)
    }

    private static func digit(v: Int64): String {
        if (v < 10) {
            v.toString()
        } else {
            match (v) {
                case 10 => 'a'
                case 11 => 'b'
                case 12 => 'c'
                case 13 => 'd'
                case 14 => 'e'
                case _ => 'f'
            }
        }
    }

    private static func u16At(bs: Array<UInt8>, off: Int64): Int64 {
        Int64(bs[off]) | (Int64(bs[off + 1]) << 8)
    }

    private static func i32At(bs: Array<UInt8>, off: Int64): Int64 {
        var v: Int64 = 0
        for (i in 0..4) {
            v = v | (Int64(bs[off + i]) << (8 * i))
        }
        if (v >= 0x80000000) {
            v - 0x100000000
        } else {
            v
        }
    }

    private static func i64At(bs: Array<UInt8>, off: Int64): Int64 {
        var v: Int64 = 0
        for (i in 0..8) {
            v = v | (Int64(bs[off + i]) << (8 * i))
        }
        v
    }
}
