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
 * Map 键的**规范键**（D5 单一事实来源）。
 *
 * 常量表的 `ConstRegistry.tokenOf` 与运行期句柄表的 `HandleTable.canonKeyOf` 原先各写一套
 * 前缀（`f:<bits>` vs 缺行、`d<sign>|<scale>` vs `d:<toString>`），于是 `Map<Float64,…>` /
 * `Map<Decimal,…>` 的常量键在运行期**永不命中**（P1-7）。两边改为共用本类即可。
 *
 * 约定：值不可变 ⇒ 等值即等价。Decimal 归一为「符号 + 十进制指数 + 去尾零系数」，
 * 因此 `1.5` 与 `1.50` 同键（同值不同写法必须同键）。
 */
public class CanonKey {
    /** Int64。 */
    public static func i64(v: Int64): String {
        'i:${v}'
    }

    /**
     * **裸 cell** 键（值型键的通用形态）。
     *
     * Map 的值型键（Int64 / Float64 / Bool）在字节码里就是裸 cell，运行期 `mapKeyOf` 拿不到
     * 类型码，只能按 cell 取值——因此常量表侧的同类键也必须走这里（Float64 常量键此前用
     * `f:<bits>`，与运行期的 `i:<cell>` 永不相等，P1-7 的主因）。
     */
    public static func cell(v: Int64): String {
        'i:${v}'
    }

    /** Float64：按**位模式**取键（NaN 的多个位模式视为不同值，与 `==` 语义一致）。 */
    public static func f64(bits: UInt64): String {
        'f:${bits}'
    }

    /** String。 */
    public static func str(s: String): String {
        's:${s}'
    }

    /**
     * Decimal：`d:<sign>|<scale>|<coeff>`，系数去尾零并同步调整 scale。
     *
     * `coeff` 是纯数字串（不含符号/小数点）；全零统一为 `d:0|0|0`（`-0` 与 `0` 同键）。
     */
    public static func dec(sign: UInt8, scale: Int32, coeff: String): String {
        var c = coeff
        var sc = scale
        while (c.size > 1 && c[c.size - 1] == b'0') {
            c = c[0..c.size - 1]
            sc = sc - 1
        }
        var zero = true
        var k = 0
        while (k < c.size) {
            if (c[k] != b'0') {
                zero = false
            }
            k = k + 1
        }
        if (zero) {
            return 'd:0|0|0'
        }
        'd:${sign}|${sc}|${c}'
    }

    /**
     * Decimal 的文本形态 → 规范键（运行期只有 `Decimal` 对象，先文本化再归一）。
     *
     * 支持 `[-]digits[.digits][E[+|-]digits]`；其它形态（NaN/Infinity）按原文取键，
     * 保证「同输入同键」而不是抛异常。
     */
    public static func decFromText(src: String): String {
        let s = src
        var i = 0
        var sign: UInt8 = 0u8
        if (i < s.size && (s[i] == b'-' || s[i] == b'+')) {
            if (s[i] == b'-') {
                sign = 1u8
            }
            i = i + 1
        }
        var digits = ''
        var scale: Int32 = 0
        var seenDot = false
        var sawDigit = false
        while (i < s.size) {
            let b = s[i]
            if (b == b'.') {
                if (seenDot) {
                    return 'd:raw|${s}'
                }
                seenDot = true
                i = i + 1
                continue
            }
            if (b == b'E' || b == b'e') {
                break
            }
            if (b < b'0' || b > b'9') {
                return 'd:raw|${s}'
            }
            digits = digits + String.fromUtf8([b])
            if (seenDot) {
                scale = scale + 1
            }
            sawDigit = true
            i = i + 1
        }
        if (!sawDigit) {
            return 'd:raw|${s}'
        }
        // 指数部分
        if (i < s.size && (s[i] == b'E' || s[i] == b'e')) {
            i = i + 1
            var neg = false
            if (i < s.size && (s[i] == b'-' || s[i] == b'+')) {
                neg = s[i] == b'-'
                i = i + 1
            }
            var e: Int32 = 0
            var any = false
            while (i < s.size && s[i] >= b'0' && s[i] <= b'9') {
                e = e * 10 + Int32(s[i] - b'0')
                any = true
                i = i + 1
            }
            if (!any || i != s.size) {
                return 'd:raw|${s}'
            }
            scale = if (neg) { scale + e } else { scale - e }
        } else if (i != s.size) {
            return 'd:raw|${s}'
        }
        if (scale < 0) {
            var k: Int32 = 0
            while (k < 0 - scale) {
                digits = digits + '0'
                k = k + 1
            }
            scale = 0
        }
        dec(sign, scale, digits)
    }

    /** DateTime：epoch 纳秒。 */
    public static func dateTime(nanos: Int64): String {
        't:${nanos}'
    }

    /** Duration：纳秒。 */
    public static func duration(nanos: Int64): String {
        'u:${nanos}'
    }

    /** Range<Int64>：边界 / 步长 / 开闭必须全等（`..` 与 `..=` 是不同值）。 */
    public static func range(start: Int64, end: Int64, step: Int64, isClosed: Bool): String {
        'r:${start}|${end}|${step}|${isClosed}'
    }

    /** Regex：pattern + flags 位域（`/a/i` 与 `/a/` 是不同值）。 */
    public static func regex(pattern: String, flags: UInt8): String {
        'x:${pattern}|${flags}'
    }
}
