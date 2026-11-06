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

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `CrcGf` 的常量自洽用例（`design.md` D5 / D9-B）。
 *
 * 参考实现独立写在本文件里：不复用 `CrcGf` 的辅助函数，避免"生成器自己证明自己"。
 */
@Test
public class CrcGf_test {
    /** 64 位反射 CRC 的参考实现（逐位），用于验证折叠算法。 */
    private func refCrc64Reflected(crc: UInt64, data: Array<Byte>, poly: UInt64): UInt64 {
        var rpoly = 0u64
        var v = poly
        for (_ in 0..64) {
            rpoly = (rpoly << 1) | (v & 1u64)
            v >>= 1
        }
        var c = crc
        for (i in 0..data.size) {
            c = c ^ UInt64(data[i])
            for (_ in 0..8) {
                c = if ((c & 1u64) != 0) { (c >> 1) ^ rpoly } else { c >> 1 }
            }
        }
        c
    }

    private func refCrc64Normal(crc: UInt64, data: Array<Byte>, poly: UInt64): UInt64 {
        var c = crc
        for (i in 0..data.size) {
            c = c ^ (UInt64(data[i]) << 56)
            for (_ in 0..8) {
                c = if ((c & 0x8000000000000000u64) != 0) { (c << 1) ^ poly } else { c << 1 }
            }
        }
        c
    }

    private func be64(data: Array<Byte>, off: Int64): UInt64 {
        var v = 0u64
        for (i in 0..8) {
            v = (v << 8) | UInt64(data[off + i])
        }
        v
    }

    private func le64(data: Array<Byte>, off: Int64): UInt64 {
        var v = 0u64
        for (i in 0..8) {
            v = v | (UInt64(data[off + i]) << (8 * i))
        }
        v
    }

    private func bitrev64(v: UInt64): UInt64 {
        var r = 0u64
        var x = v
        for (_ in 0..64) {
            r = (r << 1) | (x & 1u64)
            x >>= 1
        }
        r
    }

    private func bitrevByte(b: Byte): Byte {
        var r = 0u16
        var x = UInt16(UInt8(b))
        for (_ in 0..8) {
            r = (r << 1) | (x & 1u16)
            x >>= 1
        }
        UInt8(r & 0xFFu16)
    }

    /** 用软件模拟机器码折叠核的算法，与逐位参考实现对拍（长度必须是 16 的倍数）。 */
    @TestCase
    public func clmulFoldMatchesReferenceForReflected64(): Unit {
        let poly = 0x42F0E1EBA9EA3693u64
        let x128 = CrcGf.xPowModP(128, poly)
        let x192 = CrcGf.xPowModP(192, poly)
        let muLo = CrcGf.barrettMu(poly)[1]
        let lengths = [16, 32, 48, 64, 96, 128, 256, 1024, 4096]
        for (n in lengths) {
            let fixed: Array<Byte> = [0xADu8, 0x76, 0x36, 0x74, 0xEC, 0x79, 0xCF, 0xEA, 0x8B, 0x8E, 0x15, 0x03, 0xFD, 0x9E, 0x1F, 0xFF]
            var data = Array<Byte>(n, repeat: 0)
            for (i in 0..n) {
                data[i] = fixed[i % 16]
            }
            let seed = 0x0123456789ABCDEFu64
            let c0 = bitrev64(seed)
            // 第一块：acc = clmul(c0, P) ^ B0
            var blk = Array<Byte>(16, repeat: 0)
            for (k in 0..16) {
                blk[k] = bitrevByte(data[k])
            }
            let (h0, l0) = refClmul(c0, poly)
            var accHi = h0 ^ be64(blk, 0)
            var accLo = l0 ^ be64(blk, 8)
            var off = 16i64
            // 后续块：acc = clmul(accLo, x128) ^ clmul(accHi, x192) ^ B
            while (off + 16 <= n) {
                for (k in 0..16) {
                    blk[k] = bitrevByte(data[off + k])
                }
                let (aHi, aLo) = refClmul(accLo, x128)
                let (bHi, bLo) = refClmul(accHi, x192)
                accHi = aHi ^ bHi ^ be64(blk, 0)
                accLo = aLo ^ bLo ^ be64(blk, 8)
                off += 16
            }
            // 收尾：t = clmul(accLo, P) ^ clmul(accHi, x128)
            let (t1Hi, t1Lo) = refClmul(accLo, poly)
            let (t2Hi, t2Lo) = refClmul(accHi, x128)
            let tHi = t1Hi ^ t2Hi
            let tLo = t1Lo ^ t2Lo
            let got = bitrev64(barrettReduce(tHi, tLo, poly, muLo))
            let want = Crc64.xz.update(seed, data)
            @Assert(got, want)
        }
    }

    /** 参考：64×64 → 128 的 carry-less 乘法（逐位）。 */
    private func refClmul(a: UInt64, b: UInt64): (UInt64, UInt64) {
        var hi = 0u64
        var lo = 0u64
        for (i in 0..64) {
            if (((b >> i) & 1u64) != 0) {
                if (i == 0) {
                    lo = lo ^ a
                } else {
                    lo = lo ^ (a << i)
                    hi = hi ^ (a >> (64 - i))
                }
            }
        }
        (hi, lo)
    }

    /** 参考：128 位值按 P 逐位约减（从最高位消起）。 */
    private func refMod128(hi: UInt64, lo: UInt64, poly: UInt64): UInt64 {
        var h = hi
        var l = lo
        var i = 63i64
        while (i >= 0) {
            if (((h >> i) & 1u64) != 0) {
                h = h ^ (1u64 << i)
                l = l ^ (poly << i)
                if (i > 0) {
                    h = h ^ (poly >> (64 - i))
                }
            }
            i -= 1
        }
        l
    }

    /** 机器码折叠核将采用的 Barrett 约减公式，先用软件验证。 */
    private func barrettReduce(hi: UInt64, lo: UInt64, poly: UInt64, muLo: UInt64): UInt64 {
        // mu 是 65 位（隐藏最高位 1）：q = floor(T / x^64) * mu / x^64
        let (t1Hi, _) = refClmul(hi, muLo)
        let q = t1Hi ^ hi
        let (_, rLo) = refClmul(q, poly)
        lo ^ rLo
    }

    @TestCase
    public func barrettReductionMatchesModulo(): Unit {
        for (p in polys) {
            let (_, muLo) = CrcGf.barrettMu(p)
            var x = 0x2545F4914F6CDD1Du64
            for (_ in 0..200) {
                x = x ^ (x << 13)
                x = x ^ (x >> 7)
                x = x ^ (x << 17)
                let hi = x
                x = x ^ (x << 13)
                x = x ^ (x >> 7)
                x = x ^ (x << 17)
                let lo = x
                @Assert(barrettReduce(hi, lo, p, muLo), refMod128(hi, lo, p))
            }
        }
    }

    /** 参考：`v * x mod P`（与方法实现同口径，但独立写一遍）。 */
    private func refMulX(v: UInt64, poly: UInt64): UInt64 {
        if ((v & 0x8000000000000000u64) != 0) {
            (v << 1) ^ poly
        } else {
            v << 1
        }
    }

    /** 参考：`x^n mod P`，逐次乘 x。 */
    private func refXPowModP(n: Int64, poly: UInt64): UInt64 {
        var r = 1u64
        for (_ in 0..n) {
            r = refMulX(r, poly)
        }
        r
    }

    /** CRC-64 家族用到的三个多项式（测试侧常量，仅作输入）。 */
    private let polys: Array<UInt64> = [0x42F0E1EBA9EA3693u64, 0x000000000000001Bu64, 0xAD93D23594C935A9u64]

    @TestCase
    public func xPowModPBaseCases(): Unit {
        for (p in polys) {
            @Assert(CrcGf.xPowModP(0, p), 1u64)
            // x^64 ≡ poly (mod x^64 + poly)
            @Assert(CrcGf.xPowModP(64, p), p)
        }
    }

    @TestCase
    public func xPowModPRecurrenceHolds(): Unit {
        for (p in polys) {
            for (n in 0..201) {
                let next = CrcGf.mulX(CrcGf.xPowModP(n, p), p)
                @Assert(CrcGf.xPowModP(n + 1, p), next)
                @Assert(CrcGf.xPowModP(n, p), refXPowModP(n, p))
            }
        }
    }

    /**
     * 参考：129 位长除法求 `floor(x^128 / P)` 的低 64 位商。
     *
     * `x^128` 只有 bit128 为 1；P = x^64 + poly。商的最高位恒为 1（x^64 项），
     * 这里返回低 64 位，供与 `barrettMu` 比较。
     */
    private func refBarrettMuLow(poly: UInt64): UInt64 {
        // rem = x^128：bit0..63 -> lo，bit64..127 -> hi，bit128 -> top
        var lo = 0u64
        var hi = 0u64
        var top = 1u64
        var q = 0u64
        var i = 64i64
        while (i >= 0) {
            if (i == 64) {
                // P << 64 = x^128 + poly·x^64；低项落在 hi
                if (top != 0) {
                    top = 0
                    hi = hi ^ poly
                }
            } else {
                // 余数的 bit (64+i) 即 hi 的 bit i
                if (((hi >> i) & 1u64) != 0) {
                    hi = hi ^ (1u64 << i)
                    lo = lo ^ (poly << i)
                    if (i > 0) {
                        hi = hi ^ (poly >> (64 - i))
                    }
                    q = q | (1u64 << i)
                }
            }
            i -= 1
        }
        q
    }

    @TestCase
    public func reflectedReferenceMatchesCheckValue(): Unit {
        let digits: Array<Byte> = [49u8, 50, 51, 52, 53, 54, 55, 56, 57]
        let got = refCrc64Reflected(0xFFFFFFFFFFFFFFFFu64, digits,
            0x42F0E1EBA9EA3693u64) ^ 0xFFFFFFFFFFFFFFFFu64
        @Assert(got, 0x995DC9BBDF1939FAu64)
    }

    @TestCase
    public func barrettMuMatchesLongDivision(): Unit {
        for (p in polys) {
            let (high, low) = CrcGf.barrettMu(p)
            @Assert(high, 1u64)
            @Assert(low, refBarrettMuLow(p))
        }
    }

    @TestCase
    public func reflectConstantsAreConsistent(): Unit {
        for (p in polys) {
            let c = CrcGf.reflectConstants(p)
            @Assert(c.size, 8)
            @Assert(c[0], CrcGf.xPowModP(128, p)) // foldLo
            @Assert(c[1], CrcGf.xPowModP(192, p)) // foldHi
            @Assert(c[2], CrcGf.xPowModP(128, p)) // lane1
            @Assert(c[3], CrcGf.xPowModP(256, p)) // lane2
            @Assert(c[4], CrcGf.xPowModP(384, p)) // lane3
            @Assert(c[5], p) // kTail = x^64 mod P
            @Assert(c[7], p) // poly
            let (high, low) = CrcGf.barrettMu(p)
            @Assert(high, 1u64)
            @Assert(c[6], low)
        }
    }
}
