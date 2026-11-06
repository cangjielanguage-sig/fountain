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
 * GF(2) 多项式小工具：只为 CRC-64 折叠核推导常量，不参与热路径。
 *
 * 口径：`poly` 是 RevEng 口径的低 64 位，隐含最高项 `x^64`；元素都是 UInt64，
 * 乘法/约减在调用点按 128 位处理。
 */
class CrcGf {
    /** `x * v mod P`，`v` 次数 < 64。 */
    static func mulX(v: UInt64, poly: UInt64): UInt64 {
        let shifted = v << 1
        if ((v & 0x8000000000000000u64) != 0) {
            shifted ^ poly
        } else {
            shifted
        }
    }

    /** `x^n mod P`，`n >= 0`。 */
    static func xPowModP(n: Int64, poly: UInt64): UInt64 {
        var r = 1u64
        for (_ in 0..n) {
            r = mulX(r, poly)
        }
        r
    }

    /**
     * `floor(x^128 / P)` 的 65 位商。
     *
     * 商最高位恒为 1（`x^64` 项），这里返回 `(1, 低 64 位)`。
     * 推导：`x^128 = (x^64 + q)·(x^64 + p) + r`，令 `D = x^64·p`，则 `q = floor(D / P)`；
     * 对 `D` 做 64 步移位减法即可，纯构造期计算。
     */
    static func barrettMu(poly: UInt64): (UInt64, UInt64) {
        var hi = poly
        var lo = 0u64
        var q = 0u64
        var i = 63i64
        while (i >= 0) {
            if (((hi >> i) & 1u64) != 0) {
                hi = hi ^ (1u64 << i)
                lo = lo ^ (poly << i)
                if (i > 0) {
                    hi = hi ^ (poly >> (64 - i))
                }
                q = q | (1u64 << i)
            }
            i -= 1
        }
        (1u64, q)
    }

    /** 反射域折叠常量：`[foldLo, foldHi, lane1, lane2, lane3, kTail, muLo, poly]`。 */
    static func reflectConstants(poly: UInt64): Array<UInt64> {
        let (_, muLo) = barrettMu(poly)
        [
            xPowModP(128, poly),
            xPowModP(192, poly),
            xPowModP(128, poly),
            xPowModP(256, poly),
            xPowModP(384, poly),
            poly,
            muLo,
            poly
        ]
    }
}
