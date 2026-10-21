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
package fountain::f_jit.runtime

//
import std.collection.ArrayList
import std.math.numeric.BigInt
import std.regex.Regex
import std.math.numeric.Decimal
import std.time.DateTime

/**
 * 文本化与数值互转的**内嵌**算法 —— `doc/jit-bytecode-m1.md` §11.9（逐字节冻结）。
 *
 * 三条硬要求（§11.9 + §11.1 P3 + §6 准入准则①）：
 *
 * 1. **禁止依赖平台 `printf` / locale** —— 全部格式算法在本文件内实现，只经 std 的**值**API
 *    （`Decimal.toString()` / `Duration.toString()` / `DateTime` 分量读取）取数；
 * 2. **Float64 用最短往返**（不是固定小数位）：本文件自实现「按 2 的幂展开成精确十进制 →
 *    逐位缩短至仍能往返」的搜索（std 的 `Float64.toString()` 是 6 位定点、`Decimal(Float64)`
 *    是**精确**二进制展开，两者都不是最短往返）；
 * 3. **DateTime 是全表唯一的「环境相关」格式项**（本地时区，v0.18.16）——偏移取自宿主标准库
 *    的本地时区设施，不内嵌时区表副本。
 */
public class TextFormat {
    /** 科学计数切换阈值：`exp10 ∈ [-6, 21)` 走 plain，其余走科学（与主流最短往返实现同口径）。 */
    public static const SCI_LOW: Int64 = -6
    public static const SCI_HIGH: Int64 = 21

    // ---- Float64 ----

    /**
     * Float64 → 文本（§11.9）：最短往返；整数值附 `.0`；`NaN` / `Infinity` / `-Infinity`；
     * 极大 / 极小按 `SCI_*` 阈值切科学计数。
     */
    public static func f64(v: Float64): String {
        let bits = v.toBits()
        let exp = Int64((bits >> 52) & 0x7FFu64)
        let frac = bits & 0x000FFFFFFFFFFFFFu64
        if (exp == 0x7FF) {
            if (frac == 0u64) {
                return if ((bits >> 63) != 0u64) { '-Infinity' } else { 'Infinity' }
            }
            return 'NaN'
        }
        let neg = (bits >> 63) != 0u64
        let r = shortestDigits(exp, frac)
        let sign = if (neg) { '-' } else { '' }
        sign + plainOrSci(r[1], r[2])
    }

    /**
     * 最短往返搜索：把 `m × 2^e` 展开成**精确**十进制 `digits / 10^scale`，再逐位缩短到
     * 「转回 Float64 后位模式仍等于原值」的最小位数（§11.9「最短往返」）。
     */
    internal static func shortestDigits(exp: Int64, frac: UInt64): (Bool, String, Int64) {
        var m = BigInt.parse(intToStr(frac))
        var e: Int64 = 0
        if (exp == 0) {
            e = -1074
        } else {
            m = m + pow2(52)
            e = exp - 1075
        }
        if (m == BigInt.parse('0')) {
            return (false, '0', 0)
        }
        // 精确十进制：value = D / 10^S
        var d = m
        var s: Int64 = 0
        if (e >= 0) {
            d = m * pow2(e)
        } else {
            d = m * pow5(-e)
            s = -e
        }
        var ds = d.toString()
        var p = 1
        while (p < ds.size) {
            let drop = ds.size - p
            let cand = roundToSignificant(d, drop)
            let cs = cand.toString()
            // 进位使位数增加时「移除的位数」仍是 drop，不能用 ds.size - cs.size 反推
            let scale = s - drop
            let back = Decimal(cand, Int32(scale)).toFloat64()
            if (back.toBits() == bitsOf(exp, frac)) {
                return (false, cs, scale)
            }
            p = p + 1
        }
        (false, ds, s)
    }

    /** 精确十进制 → 文本（plain 或科学，按 `SCI_*` 阈值）。 */
    internal static func plainOrSci(digits: String, scale: Int64): String {
        let rs = digits.toRuneArray()
        let n = Int64(rs.size)
        // value = digits × 10^(-scale) ⇒ 科学计数指数 = n - scale - 1
        let exp10 = n - scale - 1
        if (exp10 >= SCI_LOW && exp10 < SCI_HIGH) {
            return plainOf(rs, scale)
        }
        var man = ArrayList<Rune>()
        man.add(rs[0])
        if (rs.size > 1) {
            // 尾随零与小数点一并省略（最短往返表示不留无效位）
            var lastSig: Int64 = 0
            var i: Int64 = 1
            while (i < n) {
                if (rs[i] != r'0') {
                    lastSig = i
                }
                i = i + 1
            }
            if (lastSig >= 1) {
                man.add(r'.')
                var k: Int64 = 1
                while (k <= lastSig) {
                    man.add(rs[k])
                    k = k + 1
                }
            }
        }
        String(man.toArray()) + 'e' + signedExp(exp10)
    }

    /** plain 记法：整数值恒带 `.0`（§11.9「整数值附 `.0`」）。 */
    internal static func plainOf(rs: Array<Rune>, scale: Int64): String {
        let n = Int64(rs.size)
        var out = ArrayList<Rune>()
        if (scale <= 0) {
            var i: Int64 = 0
            while (i < n) {
                out.add(rs[i])
                i = i + 1
            }
            var z: Int64 = 0
            while (z < 0 - scale) {
                out.add(r'0')
                z = z + 1
            }
            out.add(r'.')
            out.add(r'0')
            return String(out.toArray())
        }
        if (n > scale) {
            let cut = n - scale
            // 小数部分尾随零省略（最短往返表示不留无效位）；全零则回落到 `.0`
            var lastSig: Int64 = cut - 1
            var j: Int64 = cut
            while (j < n) {
                if (rs[j] != r'0') {
                    lastSig = j
                }
                j = j + 1
            }
            var i: Int64 = 0
            while (i <= lastSig) {
                if (i == cut) {
                    out.add(r'.')
                }
                out.add(rs[i])
                i = i + 1
            }
            if (lastSig < cut) {
                out.add(r'.')
                out.add(r'0')
            }
            return String(out.toArray())
        }
        // 纯小数：前补零后拼尾数，再省略尾随零（最短往返表示不留无效位）
        var frac = ArrayList<Rune>()
        var z2: Int64 = n
        while (z2 < scale) {
            frac.add(r'0')
            z2 = z2 + 1
        }
        var k: Int64 = 0
        while (k < n) {
            frac.add(rs[k])
            k = k + 1
        }
        var lastSig = 0 - 1
        var q: Int64 = 0
        while (q < Int64(frac.size)) {
            if (frac[q] != r'0') {
                lastSig = q
            }
            q = q + 1
        }
        out.add(r'0')
        out.add(r'.')
        var w: Int64 = 0
        while (w <= lastSig) {
            out.add(frac[w])
            w = w + 1
        }
        if (lastSig < 0) {
            out.add(r'0')
        }
        String(out.toArray())
    }

    internal static func signedExp(e: Int64): String {
        if (e >= 0) {
            '+' + e.toString()
        } else {
            '-' + (0 - e).toString()
        }
    }

    internal static func bitsOf(exp: Int64, frac: UInt64): UInt64 {
        (UInt64(exp) << 52) | frac
    }

    internal static func intToStr(v: UInt64): String {
        if (v == 0u64) {
            '0'
        } else {
            var out = ''
            var x = v
            while (x > 0u64) {
                out = (x % 10u64).toString() + out
                x = x / 10u64
            }
            out
        }
    }

    internal static func pow2(k: Int64): BigInt {
        var r = BigInt.parse('1')
        var i: Int64 = 0
        while (i < k) {
            r = r * BigInt.parse('2')
            i = i + 1
        }
        r
    }

    internal static func pow5(k: Int64): BigInt {
        var r = BigInt.parse('1')
        var i: Int64 = 0
        while (i < k) {
            r = r * BigInt.parse('5')
            i = i + 1
        }
        r
    }

    /** 保留 `p` 位有效数字（舍入 HalfEven），返回 BigInt。 */
    internal static func roundToSignificant(d: BigInt, drop: Int64): BigInt {
        if (drop <= 0) {
            return d
        }
        let ten = BigInt.parse('10')
        var p = BigInt.parse('1')
        var i: Int64 = 0
        while (i < drop) {
            p = p * ten
            i = i + 1
        }
        let q = d / p
        let r = d % p
        let two = r * BigInt.parse('2')
        if (two > p) {
            q + BigInt.parse('1')
        } else if (two == p) {
            // HalfEven：恰好一半时向偶数靠（q 为奇则 +1）
            let two2 = q * BigInt.parse('2')
            let qq = q / BigInt.parse('2')
            if (two2 - qq * BigInt.parse('2') * BigInt.parse('2') == BigInt.parse('0')) {
                q
            } else {
                q + BigInt.parse('1')
            }
        } else {
            q
        }
    }

    // ---- 其它值型 ----

    /** Bool → `true` / `false`（§11.9）。 */
    public static func bool(v: Bool): String {
        if (v) { 'true' } else { 'false' }
    }

    /** Int64 → 十进制（负号 `-`）。 */
    public static func i64(v: Int64): String {
        v.toString()
    }

    /** Decimal → `std.math.numeric.Decimal.toString()`（恒 plain，§11.9）。 */
    public static func decimal(v: Decimal): String {
        v.toString()
    }

    /** Duration → `std.core.Duration.toString()`（v0.18.17 对齐仓颉）。 */
    public static func duration(v: Duration): String {
        v.toString()
    }

    /**
     * DateTime → 本地时区呈现（v0.18.16）：
     * `YYYY-MM-DDTHH:MM:SS.nnnnnnnnn` + 偏移（零偏移 `Z`，否则 `±HH:MM`）。
     *
     * 偏移与本地墙钟分量取自宿主标准库（`inLocal()` / `zoneOffset`），不内嵌时区表副本。
     */
    public static func dateTime(v: DateTime): String {
        let l = v.inLocal()
        let offSec = l.zoneOffset.toSeconds()
        var out = pad4(l.year) + '-' + pad2(l.month.toInteger()) + '-' + pad2(l.dayOfMonth)
        out = out + 'T' + pad2(l.hour) + ':' + pad2(l.minute) + ':' + pad2(l.second)
        out = out + '.' + pad9(l.nanosecond)
        out + offsetText(offSec)
    }

    /** Range → `{start}..{end}` / `{start}..={end}`；`step ≠ 1` 附加 ` : {step}`（§11.9）。 */
    public static func range(v: Range<Int64>): String {
        var out = v.start.toString() + (if (v.isClosed) { '..=' } else { '..' }) + v.end.toString()
        if (v.step != 1) {
            out = out + ' : ' + v.step.toString()
        }
        out
    }

    /** Regex → `/pattern/flags`（flags 按规范序 `i m u` 拼接，v0.18.18）。 */
    public static func regex(v: JitRegex): String {
        var flags = ''
        if ((v.flags & 0x01u8) != 0u8) {
            flags = flags + 'i'
        }
        if ((v.flags & 0x02u8) != 0u8) {
            flags = flags + 'm'
        }
        if ((v.flags & 0x04u8) != 0u8) {
            flags = flags + 'u'
        }
        '/' + v.re.string() + '/' + flags
    }

    public static func pad2(v: Int64): String {
        if (v < 10) {
            '0' + v.toString()
        } else {
            v.toString()
        }
    }

    public static func pad4(v: Int64): String {
        if (v > 9999) {
            // ISO 8601 扩展年份（前导 `+`；仅值域两端折算后可发生）
            '+' + v.toString()
        } else if (v < 1000) {
            var p = ''
            var t = v
            if (t < 100) {
                p = p + '0'
            }
            if (t < 10) {
                p = p + '0'
            }
            '0' + p + v.toString()
        } else {
            v.toString()
        }
    }

    public static func pad9(v: Int64): String {
        let s = v.toString()
        var pad = ''
        var i = Int64(s.size)
        while (i < 9) {
            pad = pad + '0'
            i = i + 1
        }
        pad + s
    }

    /** 秒偏移 → `Z` / `±HH:MM`。 */
    public static func offsetText(offSec: Int64): String {
        if (offSec == 0) {
            'Z'
        } else {
            let sign = if (offSec < 0) { '-' } else { '+' }
            let a = if (offSec < 0) { 0 - offSec } else { offSec }
            sign + pad2(a / 3600) + ':' + pad2((a % 3600) / 60)
        }
    }
}

/**
 * Regex 句柄的承载对象 —— §11.9「TO_STR 的 Regex 行要输出 flags」。
 *
 * `std.regex.Regex` 只暴露 pattern（`string()`），不暴露构造时的 flags ⇒ 运行期把
 * `(Regex, flags)` 成对承载：常量按 §11.5 kind 10 的位域登记，`STR_TO_REGEX`（H69）恒 0。
 */
public class JitRegex {
    public let re: Regex
    public let flags: UInt8

    public init(re: Regex, flags: UInt8) {
        this.re = re
        this.flags = flags
    }
}
