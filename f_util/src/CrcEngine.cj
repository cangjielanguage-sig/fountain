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
 * - 「反射 + 位宽 32」的变体额外生成 slicing-by-4 的三张派生表（`t1..t3`，由 `t0` 逐级
 *   `>> 8` 再查 `t0` 得到），一次消费 4 字节；其余变体走索引遍历的逐字节路径。
 *   两条路径的寄存器值逐位相同（用例见 CrcEngine_test.cj）；
 * - 增量接口（init/update/finish）与旧版 `crc32Init/crc32Update/crc32Finish` 的语义一致：
 *   update 操作的是**未做收尾异或**的寄存器值。
 */
class CrcEngine {
    private let width: Int64
    private let mask: UInt64
    private let poly: UInt64
    private let initValue: UInt64
    private let refin: Bool
    private let refout: Bool
    private let xorout: UInt64
    private let normalTable: Array<UInt64>
    private let reflectedTable: Array<UInt64>
    /** 是否走 slicing-by-4（只对「反射 + 位宽 32」启用）。 */
    private let slicing: Bool
    /** 切片表：`t1..t3` 只在 `slicing` 为真时有内容，其余变体是空数组（不会被索引）。 */
    private let slice1: Array<UInt64>
    private let slice2: Array<UInt64>
    private let slice3: Array<UInt64>
    /**
     * 64 位 slicing-by-8 表：`[0]` 是字节表，`[1..7]` 逐级派生；非 64 位变体为空数组。
     *
     * 反射变体由 `reflectedTable` 派生（`>> 8`），非反射变体由 `normalTable` 派生（`<< 8`），
     * 两条派生规则不可互换。
     */
    private let slices64: Array<Array<UInt64>>
    /** 64 位表是否走反射（LSB-first）派生与热循环。 */
    private let slicing64: Bool
    /**
     * 16 位 slicing-by-2 表：`[0]` 是字节表，`[1]` 是派生表；非 16 位变体为空数组。
     *
     * 16 位寄存器只有 2 字节窗口，只能与首 2 字节数据异或后查表；一次 4 字节需要 6 张交叉表，
     * 收益与 2 字节切片相同，因此这里固定 slicing-by-2。
     */
    private let slices16: Array<Array<UInt16>>
    /** 16 位表是否走反射（LSB-first）派生与热循环。 */
    private let slicing16: Bool
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
        this.poly = p
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
        // slicing-by-4 只对「反射 + 位宽 32」有意义：一次消费 4 字节，用 t3/t2/t1/t0 四张表拼出
        // 32 位寄存器的新值。其他口径（非反射、或 16/64 位）的字节表语义不同，误用会整体漂移。
        let useSlicing = refin && width == 32
        let none: Array<UInt64> = []
        let t1 = if (useSlicing) { CrcEngine.buildSliceTable(reflected, reflected) } else { none }
        let t2 = if (useSlicing) { CrcEngine.buildSliceTable(t1, reflected) } else { none }
        let t3 = if (useSlicing) { CrcEngine.buildSliceTable(t2, reflected) } else { none }
        this.slicing = useSlicing
        this.slice1 = t1
        this.slice2 = t2
        this.slice3 = t3
        // 64 位走 slicing-by-8：反射由 reflectedTable 派生，非反射由 normalTable 派生。
        // 派生深度固定 7 次（t0 即字节表本身），一次消费 8 字节。
        if (width == 64) {
            let base = if (refin) { reflected } else { normal }
            let tables = Array<Array<UInt64>>(8, repeat: base)
            var prev = base
            for (k in 1..8) {
                let next = if (refin) {
                    CrcEngine.buildSliceTable(prev, base)
                } else {
                    CrcEngine.buildSliceTableMsb(prev, base, mask)
                }
                tables[k] = next
                prev = next
            }
            this.slices64 = tables
            this.slicing64 = true
        } else {
            let empty: Array<Array<UInt64>> = []
            this.slices64 = empty
            this.slicing64 = false
        }
        // 16 位走 slicing-by-2：2 张 256 项 UInt16 表（512 B/变体）。
        if (width == 16) {
            let base64 = if (refin) { reflected } else { normal }
            let t0 = Array<UInt16>(256, repeat: 0u16)
            for (k in 0..256) {
                t0[k] = UInt16(base64[k] & 0xFFFFu64)
            }
            let t1 = Array<UInt16>(256, repeat: 0u16)
            for (k in 0..256) {
                let prev = UInt64(t0[k])
                t1[k] = if (refin) {
                    UInt16(((prev >> 8) ^ UInt64(t0[Int64(prev & 0xFFu64)])) & 0xFFFFu64)
                } else {
                    UInt16((((prev << 8) & 0xFFFFu64) ^ UInt64(t0[Int64((prev >> 8) & 0xFFu64)])) &
                        0xFFFFu64)
                }
            }
            this.slices16 = [t0, t1]
            this.slicing16 = true
        } else {
            let empty: Array<Array<UInt16>> = []
            this.slices16 = empty
            this.slicing16 = false
        }
    }
    /** 派生一张切片表：`t[k] = (prev[k] >> 8) ^ base[prev[k] & 0xFF]`（`t0` 即 `base` 本身）。 */
    private static func buildSliceTable(prev: Array<UInt64>, base: Array<UInt64>): Array<UInt64> {
        let table = Array<UInt64>(256, repeat: 0u64)
        for (k in 0..256) {
            table[k] = (prev[k] >> 8) ^ base[Int64(prev[k] & 0xFFu64)]
        }
        table
    }
    /** MSB-first 的派生：`t[k] = ((prev[k] << 8) & mask) ^ base[prev[k] >> (width-8)]`。 */
    private static func buildSliceTableMsb(prev: Array<UInt64>, base: Array<UInt64>,
        mask: UInt64): Array<UInt64> {
        let table = Array<UInt64>(256, repeat: 0u64)
        for (k in 0..256) {
            table[k] = ((prev[k] << 8) & mask) ^ base[Int64((prev[k] >> 56) & 0xFFu64)]
        }
        table
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
        // CRC-64/XZ 家族：数据量达到阈值时走生成式折叠核，尾部仍用表路径。
        if (width == 64 && refin && poly == 0x42F0E1EBA9EA3693u64 && data.size >= 256) {
            let aligned = data.size - (data.size % 16)
            if (aligned >= 16) {
                if (let Some(raw) <- Crc64Hw.update(c, data, aligned)) {
                    var t = raw
                    for (i in aligned..data.size) {
                        t = (t >> 8) ^ reflectedTable[Int64((t ^ UInt64(data[i])) & 0xFFu64)]
                    }
                    return t
                }
            }
        }
        if (slicing) {
            // 一次消费 4 字节：把 4 字节按小端组装进寄存器，再用四张表一次算完；
            // 尾巴（不足 4 字节）走与逐字节路径完全相同的那一行，保证任意长度都正确。
            //
            // 这里用 `acquireArrayRawData` 取裸指针而不是 `data[i]` / `table[k]`：在 `cjpm test`
            // 默认构建（未开优化）下，带边界检查的下标访问每次约 25 ns，1 MiB 只能跑到 ~20 MB/s；
            // 换成裸指针后同样的循环是 17~19 ms/MiB（51~58 MB/s）。只读、不改写、每个出口都配对 release。
            unsafe {
                let dataHandle = acquireArrayRawData<Byte>(data)
                let table0 = acquireArrayRawData<UInt64>(reflectedTable)
                let table1 = acquireArrayRawData<UInt64>(slice1)
                let table2 = acquireArrayRawData<UInt64>(slice2)
                let table3 = acquireArrayRawData<UInt64>(slice3)
                try {
                    let dp = dataHandle.pointer
                    let t0 = table0.pointer
                    let t1 = table1.pointer
                    let t2 = table2.pointer
                    let t3 = table3.pointer
                    let size = data.size
                    var i = 0i64
                    // 一次消费 4 字节（不展开：展开成 8 字节实测反而更慢，代码体积/寄存器压力在这个
                    // 未优化的构建里更贵）。
                    while (i + 4 <= size) {
                        let word = UInt64(dp.read(i)) |
                            (UInt64(dp.read(i + 1)) << 8) |
                            (UInt64(dp.read(i + 2)) << 16) |
                            (UInt64(dp.read(i + 3)) << 24)
                        c = c ^ word
                        c = t3.read(Int64(c & 0xFFu64)) ^
                            t2.read(Int64((c >> 8) & 0xFFu64)) ^
                            t1.read(Int64((c >> 16) & 0xFFu64)) ^
                            t0.read(Int64((c >> 24) & 0xFFu64))
                        i += 4
                    }
                    while (i < size) {
                        c = (c >> 8) ^ t0.read(Int64((c ^ UInt64(dp.read(i))) & 0xFFu64))
                        i += 1
                    }
                } finally {
                    releaseArrayRawData<Byte>(dataHandle)
                    releaseArrayRawData<UInt64>(table0)
                    releaseArrayRawData<UInt64>(table1)
                    releaseArrayRawData<UInt64>(table2)
                    releaseArrayRawData<UInt64>(table3)
                }
            }
        } else if (slicing64) {
            // 64 位 slicing-by-8：一次消费 8 字节，8 张表各消费一个字节。
            // 反射与正常（MSB-first）两条热循环分开写，避免在循环里判方向。
            unsafe {
                let dataHandle = acquireArrayRawData<Byte>(data)
                let h0 = acquireArrayRawData<UInt64>(slices64[0])
                let h1 = acquireArrayRawData<UInt64>(slices64[1])
                let h2 = acquireArrayRawData<UInt64>(slices64[2])
                let h3 = acquireArrayRawData<UInt64>(slices64[3])
                let h4 = acquireArrayRawData<UInt64>(slices64[4])
                let h5 = acquireArrayRawData<UInt64>(slices64[5])
                let h6 = acquireArrayRawData<UInt64>(slices64[6])
                let h7 = acquireArrayRawData<UInt64>(slices64[7])
                try {
                    let dp = dataHandle.pointer
                    let t0 = h0.pointer
                    let t1 = h1.pointer
                    let t2 = h2.pointer
                    let t3 = h3.pointer
                    let t4 = h4.pointer
                    let t5 = h5.pointer
                    let t6 = h6.pointer
                    let t7 = h7.pointer
                    let size = data.size
                    var i = 0i64
                    if (refin) {
                        // 反射域：小端机器上一次 64 位读正好是小端 word，省掉 8 次字节读。
                        let p64 = CPointer<UInt64>(dp)
                        var j = 0i64
                        while (i + 8 <= size) {
                            let word = p64.read(j)
                            c = c ^ word
                            c = t7.read(Int64(c & 0xFFu64)) ^
                                t6.read(Int64((c >> 8) & 0xFFu64)) ^
                                t5.read(Int64((c >> 16) & 0xFFu64)) ^
                                t4.read(Int64((c >> 24) & 0xFFu64)) ^
                                t3.read(Int64((c >> 32) & 0xFFu64)) ^
                                t2.read(Int64((c >> 40) & 0xFFu64)) ^
                                t1.read(Int64((c >> 48) & 0xFFu64)) ^
                                t0.read(Int64((c >> 56) & 0xFFu64))
                            i += 8
                            j += 1
                        }
                        while (i < size) {
                            c = (c >> 8) ^ t0.read(Int64((c ^ UInt64(dp.read(i))) & 0xFFu64))
                            i += 1
                        }
                    } else {
                        while (i + 8 <= size) {
                            let word = (UInt64(dp.read(i)) << 56) |
                                (UInt64(dp.read(i + 1)) << 48) |
                                (UInt64(dp.read(i + 2)) << 40) |
                                (UInt64(dp.read(i + 3)) << 32) |
                                (UInt64(dp.read(i + 4)) << 24) |
                                (UInt64(dp.read(i + 5)) << 16) |
                                (UInt64(dp.read(i + 6)) << 8) |
                                UInt64(dp.read(i + 7))
                            c = c ^ word
                            c = t7.read(Int64((c >> 56) & 0xFFu64)) ^
                                t6.read(Int64((c >> 48) & 0xFFu64)) ^
                                t5.read(Int64((c >> 40) & 0xFFu64)) ^
                                t4.read(Int64((c >> 32) & 0xFFu64)) ^
                                t3.read(Int64((c >> 24) & 0xFFu64)) ^
                                t2.read(Int64((c >> 16) & 0xFFu64)) ^
                                t1.read(Int64((c >> 8) & 0xFFu64)) ^
                                t0.read(Int64(c & 0xFFu64))
                            i += 8
                        }
                        while (i < size) {
                            c = ((c << 8) & mask) ^
                                t0.read(Int64(((c >> 56) ^ UInt64(dp.read(i))) & 0xFFu64))
                            i += 1
                        }
                    }
                } finally {
                    releaseArrayRawData<Byte>(dataHandle)
                    releaseArrayRawData<UInt64>(h0)
                    releaseArrayRawData<UInt64>(h1)
                    releaseArrayRawData<UInt64>(h2)
                    releaseArrayRawData<UInt64>(h3)
                    releaseArrayRawData<UInt64>(h4)
                    releaseArrayRawData<UInt64>(h5)
                    releaseArrayRawData<UInt64>(h6)
                    releaseArrayRawData<UInt64>(h7)
                }
            }
        } else if (slicing16) {
            // 16 位 slicing-by-2：一次消费 2 字节，2 张 UInt16 表各消费一个字节。
            unsafe {
                let dataHandle = acquireArrayRawData<Byte>(data)
                let h0 = acquireArrayRawData<UInt16>(slices16[0])
                let h1 = acquireArrayRawData<UInt16>(slices16[1])
                try {
                    let dp = dataHandle.pointer
                    let t0 = h0.pointer
                    let t1 = h1.pointer
                    let size = data.size
                    var i = 0i64
                    if (refin) {
                        while (i + 2 <= size) {
                            let word = UInt64(dp.read(i)) | (UInt64(dp.read(i + 1)) << 8)
                            c = c ^ word
                            c = UInt64(t1.read(Int64(c & 0xFFu64))) ^
                                UInt64(t0.read(Int64((c >> 8) & 0xFFu64)))
                            i += 2
                        }
                        while (i < size) {
                            c = (c >> 8) ^ UInt64(t0.read(Int64((c ^ UInt64(dp.read(i))) & 0xFFu64)))
                            i += 1
                        }
                    } else {
                        while (i + 2 <= size) {
                            let word = (UInt64(dp.read(i)) << 8) | UInt64(dp.read(i + 1))
                            c = c ^ word
                            c = UInt64(t1.read(Int64((c >> 8) & 0xFFu64))) ^
                                UInt64(t0.read(Int64(c & 0xFFu64)))
                            i += 2
                        }
                        while (i < size) {
                            c = ((c << 8) & mask) ^
                                UInt64(t0.read(Int64(((c >> 8) ^ UInt64(dp.read(i))) & 0xFFu64)))
                            i += 1
                        }
                    }
                } finally {
                    releaseArrayRawData<Byte>(dataHandle)
                    releaseArrayRawData<UInt16>(h0)
                    releaseArrayRawData<UInt16>(h1)
                }
            }
        } else if (refin) {
            // 索引遍历：`for (b in data)` 会为每个字节走一次迭代器协议，实测只有表驱动应有性能的 1/3 左右。
            for (i in 0..data.size) {
                c = (c >> 8) ^ reflectedTable[Int64((c ^ UInt64(data[i])) & 0xFFu64)]
            }
        } else {
            let shift = width - 8
            for (i in 0..data.size) {
                c = ((c << 8) & mask) ^ normalTable[Int64(((c >> shift) ^ UInt64(data[i])) & 0xFFu64)]
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
