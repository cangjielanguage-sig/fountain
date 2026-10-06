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
package fountain::f_util

/**
 * 通用表驱动 CRC 引擎。
 *
 * 参数口径与命名跟 **RevEng CRC catalogue**（<https://reveng.sourceforge.io/crc-catalogue/>）一致：
 * `width`（位宽）/`poly`（多项式，**最高位省略**，即不含隐含的 x^width 项）/`init`（寄存器初值；仓颉里 `init` 是关键字，
 * 所以代码里这个参数叫 `initValue`）/
 * `refin`（输入字节是否反射）/`refout`（输出寄存器是否反射）/`xorout`（结果异或值）。
 * 每个变体对应的“标准检查值”是 `"123456789"` 的 CRC，用来在用例里钉住参数（见 crc_check_test.cj）。
 *
 * 实现要点：
 * - 表在构造时现算：非反射（MSB-first）一张、反射（LSB-first）一张，运行时按 `refin` 选；
 *   `refout != refin` 的少数变体在收尾时对寄存器整体反射一次；
 * - 内部统一用 UInt64 寄存器 + `mask` 截宽，所以同一份实现支持 8/16/24/32/40/64 位；
 * - 增量接口（init/update/finish）与旧版 `crc32Init/crc32Update/crc32Finish` 的语义一致：
 *   update 操作的是**未做收尾异或**的寄存器值。
 */
class CrcEngine {
    private let width: Int64
    private let mask: UInt64
    private let initValue: UInt64
    private let refin: Bool
    private let refout: Bool
    private let xorout: UInt64
    private let normalTable: Array<UInt64>
    private let reflectedTable: Array<UInt64>
    CrcEngine(width: Int64, poly: UInt64, initValue: UInt64, refin: Bool, refout: Bool, xorout: UInt64) {
        this.width = width
        this.mask = if (width >= 64) { UInt64.Max } else { (1u64 << width) - 1u64 }
        this.refin = refin
        this.refout = refout
        // 反射口径（refin=true）时，catalogue 给的 init 是"非反射表示"，要整体反射后才是寄存器初值
        //（对称的 0x0000/0xFFFF 看不出差别，非对称的如 CRC-16/TMS37157 的 0x89EC 会算错）。
        this.initValue = if (refin) { CrcEngine.reflectBits(initValue & mask, width) } else { initValue & mask }
        this.xorout = xorout & mask
        let p = poly & mask
        let normal = Array<UInt64>(256, repeat: 0u64)
        let shift = width - 8
        for (i in 0..256) {
            var crc = UInt64(i) << shift
            for (_ in 0..8) {
                crc = if ((crc & (1u64 << (width - 1))) != 0) {
                    ((crc << 1) & mask) ^ p
                } else {
                    (crc << 1) & mask
                }
            }
            normal[i] = crc
        }
        this.normalTable = normal
        // 反射表按 LSB-first 直接生成（多项式先整体反射）；等价于「normal 表 + 索引字节反序」，
        // 但直接生成不容易写错（早期版本漏了索引反序 ⇒ 所有反射变体都算错）。
        let rpoly = CrcEngine.reflectBits(p, width)
        let reflected = Array<UInt64>(256, repeat: 0u64)
        for (i in 0..256) {
            var crc = UInt64(i)
            for (_ in 0..8) {
                crc = if ((crc & 1u64) != 0) {
                    (crc >> 1) ^ rpoly
                } else {
                    crc >> 1
                }
            }
            reflected[i] = crc & mask
        }
        this.reflectedTable = reflected
    }
    /** 把 value 的低 width 位整体翻转（如 width=16 时 0x0001 -> 0x8000）。 */
    private static func reflectBits(value: UInt64, width: Int64): UInt64 {
        var out = 0u64
        var v = value
        for (_ in 0..width) {
            out = (out << 1) | (v & 1u64)
            v >>= 1
        }
        out
    }
    /** 寄存器初值（未反射、未异或）。 */
    func initRegister(): UInt64 {
        initValue
    }
    /** 继续累计一段字节。 */
    func update(crc: UInt64, data: Array<Byte>): UInt64 {
        var c = crc & mask
        if (refin) {
            for (b in data) {
                c = (c >> 8) ^ reflectedTable[Int64((c ^ UInt64(b)) & 0xFFu64)]
            }
        } else {
            let shift = width - 8
            for (b in data) {
                c = ((c << 8) & mask) ^ normalTable[Int64(((c >> shift) ^ UInt64(b)) & 0xFFu64)]
            }
        }
        c
    }
    /** 收尾：按需反射寄存器，再与 xorout 异或。 */
    func finish(crc: UInt64): UInt64 {
        var c = crc & mask
        if (refout != refin) {
            c = CrcEngine.reflectBits(c, width)
        }
        (c ^ xorout) & mask
    }
    /** 一次算完整段（等价 init → update → finish）。 */
    func compute(data: Array<Byte>): UInt64 {
        finish(update(initRegister(), data))
    }
}
