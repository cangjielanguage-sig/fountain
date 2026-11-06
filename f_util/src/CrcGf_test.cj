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
