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

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.*

/**
 * FNV 全族自检：32/64/128/256/1024 × fnv1/fnv1a，外加统一 API、增量喂入与长输入。
 *
 * 黄金值口径：
 * - 32/64/128/256 的空串基值 = 官方 FNV 偏移基值；`Fnv64.fnv1a("123456789")` = `0x06D5573923C6CDFC`
 *   是 FNV-1a-64 的公开已知向量。
 * - 其余（尤其 1024 位与 128 位以上的 `"123456789"`、emoji、长输入）由**独立 Python 大整数
 *   参考实现**按同一公式（`fnv1`：先乘后异或；`fnv1a`：先异或后乘，模 2^bits）算出后固化。
 *
 * 之所以钉住这么密：f_jit 的常量指纹（FNV-1a-64）与编译去重键（FNV-1a-128）都依赖本族，
 * 一旦素数/基值抄错或 1024 位高位丢进位，上层只表现为「偶发误判」，极难定位。
 */
@Test
public class Fnv_test {
    private let digits: String = '123456789'
    private let emoji: String = 'a\u{1F600}b'
    private let basis1024: Array<UInt64> = [
        0x0000000000000000u64, 0x005F7A76758ECC4Du64, 0x32E56D5A591028B7u64, 0x4B29FC4223FDADA1u64,
        0x6C3BF34EDA3674DAu64, 0x9A21D90000000000u64, 0x0000000000000000u64, 0x0000000000000000u64,
        0x0000000000000000u64, 0x0000000000000000u64, 0x0000000000000000u64, 0x000000000004C6D7u64,
        0xEB6E73802734510Au64, 0x555F256CC005AE55u64, 0x6BDE8CC9C6A93B21u64, 0xAFF4B16C71EE90B3u64
    ]

    /** 空串 = 偏移基值（32/64/128/256 用官方公布常量）。 */
    @TestCase
    public func emptyStringIsOffsetBasis(): Unit {
        @Assert(Fnv32.fnv1(''), 0x811C9DC5u32)
        @Assert(Fnv32.fnv1a(''), 0x811C9DC5u32)
        @Assert(Fnv64.fnv1(''), 0xCBF29CE484222325u64)
        @Assert(Fnv64.fnv1a(''), 0xCBF29CE484222325u64)
        @Assert(Fnv128.fnv1(''), UInt128(0x6C62272E07BB0142u64, 0x62B821756295C58Du64))
        @Assert(Fnv128.fnv1a(''), UInt128(0x6C62272E07BB0142u64, 0x62B821756295C58Du64))
        @Assert(
            Fnv256.fnv1(''),
            [0xDD268DBCAAC55036u64, 0x2D98C384C4E576CCu64, 0xC8B1536847B6BBB3u64, 0x1023B4C8CAEE0535u64]
        )
        @Assert(
            Fnv256.fnv1a(''),
            [0xDD268DBCAAC55036u64, 0x2D98C384C4E576CCu64, 0xC8B1536847B6BBB3u64, 0x1023B4C8CAEE0535u64]
        )
    }

    /** 空串 = 偏移基值（1024 位：官方基值的 16 字大端表示）。 */
    @TestCase
    public func emptyStringIsOffsetBasis1024(): Unit {
        @Assert(Fnv1024.fnv1(''), basis1024)
        @Assert(Fnv1024.fnv1a(''), basis1024)
    }

    /** `"123456789"` 已知向量：五宽度 × 两变体，逐字对照独立参考实现。 */
    @TestCase
    public func knownVector123456789(): Unit {
        @Assert(Fnv32.fnv1(digits), 0x24148816u32)
        @Assert(Fnv32.fnv1a(digits), 0xBB86B11Cu32)
        @Assert(Fnv64.fnv1(digits), 0xA72FFC362BF916D6u64)
        @Assert(Fnv64.fnv1a(digits), 0x06D5573923C6CDFCu64)
        @Assert(Fnv128.fnv1(digits), UInt128(0x8BEA2C73BE03B30Fu64, 0xD4142FB1EC2C2066u64))
        @Assert(Fnv128.fnv1a(digits), UInt128(0xDA2D42A08D04E458u64, 0x5DD325117F71D504u64))
        @Assert(
            Fnv256.fnv1(digits),
            [0x0C37A392D3522F84u64, 0x5F2553C403A80F65u64, 0x9B80C9A5B0151496u64, 0xCC37419F79B95EF6u64]
        )
        @Assert(
            Fnv256.fnv1a(digits),
            [0x0C2033A9BFAC2139u64, 0x8D7BA2C403A80F65u64, 0x9B80C9A5B01178B5u64, 0xCFF0AB62E9D53C4Cu64]
        )
    }

    /** 1024 位 `"123456789"`：两变体各自对照参考实现，且彼此不同（高位进位不丢）。 */
    @TestCase
    public func knownVector123456789For1024(): Unit {
        let fnv1 = [
            0xF6F747AF25A9DE26u64, 0xE8A493431E31B4A1u64, 0xED2A92304AF6CA97u64, 0x6BC1D96FFCAD3524u64,
            0x4E3884143F8313F9u64, 0xF4A6700000000000u64, 0x0000000000000000u64, 0x0000000000000000u64,
            0x0000000000000000u64, 0x0000000000000000u64, 0x00000000F7CA87CEu64, 0x43227B98C144607Eu64,
            0x67CC50AF99BCC5D1u64, 0x514BB0D923EEDEDDu64, 0x69E8E74701F66FA5u64, 0x2A5773983AA6FBAEu64
        ]
        let fnv1a = [
            0xF6F747AF25A9DE26u64, 0xE8A493431E31B4A1u64, 0xED2A92304AF6CA97u64, 0x6BC1D96FFCAD3524u64,
            0x4DFEE3C74FCD62CBu64, 0x8B4FB70000000000u64, 0x0000000000000000u64, 0x0000000000000000u64,
            0x0000000000000000u64, 0x0000000000000000u64, 0x00000000F7CA87CEu64, 0x43227B98C144607Eu64,
            0x67CC50AF99BCC5D1u64, 0x514BB0D923EEDEDDu64, 0x69E8E74701EC81AEu64, 0x5EB3A69FEE735B22u64
        ]
        @Assert(Fnv1024.fnv1(digits), fnv1)
        @Assert(Fnv1024.fnv1a(digits), fnv1a)
        if (Fnv1024.fnv1(digits) == Fnv1024.fnv1a(digits)) {
            @Fail('FNV-1024 的 fnv1 与 fnv1a 在非空输入上必须不同')
        }
    }

    /** 同一非空输入下 `fnv1` ≠ `fnv1a`（五种宽度全覆盖）。 */
    @TestCase
    public func variantsAreDistinguishable(): Unit {
        if (Fnv32.fnv1(digits) == Fnv32.fnv1a(digits)) {
            @Fail('FNV-32：fnv1 与 fnv1a 撞了')
        }
        if (Fnv64.fnv1(digits) == Fnv64.fnv1a(digits)) {
            @Fail('FNV-64：fnv1 与 fnv1a 撞了')
        }
        if (Fnv128.fnv1(digits) == Fnv128.fnv1a(digits)) {
            @Fail('FNV-128：fnv1 与 fnv1a 撞了')
        }
        if (Fnv256.fnv1(digits) == Fnv256.fnv1a(digits)) {
            @Fail('FNV-256：fnv1 与 fnv1a 撞了')
        }
        if (Fnv1024.fnv1(digits) == Fnv1024.fnv1a(digits)) {
            @Fail('FNV-1024：fnv1 与 fnv1a 撞了')
        }
    }

    /** 字符串与其 UTF-8 字节流必须逐位相同（含 1024 位统一入口）。 */
    @TestCase
    public func stringEqualsUtf8Bytes(): Unit {
        @Assert(Fnv64.fnv1a(emoji), Fnv64.fnv1a(emoji.unsafeBytes()))
        @Assert(Fnv128.fnv1a(digits), Fnv128.fnv1a(digits.unsafeBytes()))
        @Assert(Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1A, emoji), Fnv1024.fnv1a(emoji.unsafeBytes()))
        @Assert(Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1, digits), Fnv1024.fnv1(digits.unsafeBytes()))
    }

    /** 4 字节码点（emoji）按字节处理，与参考实现一致。 */
    @TestCase
    public func fourByteCodePoint(): Unit {
        @Assert(Fnv64.fnv1(emoji), 0x90BF4FC6A19D0BC1u64)
        @Assert(Fnv64.fnv1a(emoji), 0x33C526094D790E49u64)
        @Assert(
            Fnv1024.fnv1(emoji),
            [
                0x00000631175FA7AEu64, 0x643AD08723D312C9u64, 0xFD024ADB91F77F6Bu64, 0x19587197A22BCDF2u64,
                0x3727166C3E59F9E3u64, 0x1321B70000000000u64, 0x0000000000000000u64, 0x0000000000000000u64,
                0x0000000000000000u64, 0x0000000000000000u64, 0x0000000000000042u64, 0x70D11EF418EF08B8u64,
                0xA49E1E825E547EB3u64, 0x9937F819222F3B7Fu64, 0xC92A0E4707900888u64, 0x82A5695FF80A51F7u64
            ]
        )
        @Assert(
            Fnv1024.fnv1a(emoji),
            [
                0x00000631175FA7AEu64, 0x643AD08723D312C9u64, 0xFD024ADB91F77F6Bu64, 0x19587197A22BCDF2u64,
                0x3727166C44CA70F4u64, 0x29A4930000000000u64, 0x0000000000000000u64, 0x0000000000000000u64,
                0x0000000000000000u64, 0x0000000000000000u64, 0x0000000000000042u64, 0x70D11EF418EF08B8u64,
                0xA49E1E825E547EB3u64, 0x9937F819222F3B7Fu64, 0xC92A0E4707900888u64, 0x844E7417E962257Fu64
            ]
        )
    }

    /** 分三段增量喂入 + 空增量，结果与一次性喂入逐位相同。 */
    @TestCase
    public func incrementalMatchesOneShot(): Unit {
        let all = Array<Byte>(200) { i => UInt8(i % 251) }
        let part1 = all[0..70]
        let part2 = all[70..71]
        let part3 = all[71..200]
        for (width in [FnvWidth.W32, FnvWidth.W64, FnvWidth.W128, FnvWidth.W256, FnvWidth.W1024]) {
            for (variant in [FnvVariant.FNV1, FnvVariant.FNV1A]) {
                let oneShot = Fnv.hash(width, variant, all)
                let h = FnvHasher(width, variant)
                h.update(part1)
                h.update(part2)
                h.update(Array<Byte>())
                h.update(part3)
                @Assert(h.finish(), oneShot)
            }
        }
    }

    /** 超过 4 KiB 的输入：分块喂入与一次性喂入一致，且等于独立参考实现的黄金值。 */
    @TestCase
    public func longInputIsChunkInvariant(): Unit {
        let long = Array<Byte>(5120) { i => UInt8(i % 256) }
        for (width in [FnvWidth.W64, FnvWidth.W128, FnvWidth.W256, FnvWidth.W1024]) {
            for (variant in [FnvVariant.FNV1, FnvVariant.FNV1A]) {
                let oneShot = Fnv.hash(width, variant, long)
                let h = FnvHasher(width, variant)
                var off = 0
                while (off < long.size) {
                    let end = if (off + 512 < long.size) { off + 512 } else { long.size }
                    h.update(long[off..end])
                    off += 512
                }
                @Assert(h.finish(), oneShot)
            }
        }
        @Assert(Fnv64.fnv1a(long), 0xA6EF0828AF1F9F25u64)
        @Assert(Fnv128.fnv1a(long), UInt128(0xAD034FA4D4093EF0u64, 0x724BA586DDBF218Du64))
        @Assert(
            Fnv1024.fnv1a(long),
            [
                0x0198D0ED682A5E7Cu64, 0xAE18049C351FE099u64, 0x87E2B01B41F49627u64, 0x9E68A096A3BA52DBu64,
                0xB1492F5F03BEFE88u64, 0x2CC6DE89313D948Au64, 0xCEB9A0F6F47F2A76u64, 0xFE93F269398C8A14u64,
                0x386A4558ADC3EA65u64, 0xB2144E840614BC56u64, 0x764DB8BCC9253874u64, 0x650AD6767B77CF3Cu64,
                0x53C453C0A4AEEFBEu64, 0xDCF3182EA54AD721u64, 0x1D3D6646C77CA8DBu64, 0x93C26586B23810B3u64
            ]
        )
    }

    /** 统一入口 `Fnv.hash` 的返回字数：1/1/2/4/16。 */
    @TestCase
    public func unifiedApiWordCounts(): Unit {
        @Assert(Fnv.hash(FnvWidth.W32, FnvVariant.FNV1A, digits).size, 1)
        @Assert(Fnv.hash(FnvWidth.W64, FnvVariant.FNV1A, digits).size, 1)
        @Assert(Fnv.hash(FnvWidth.W128, FnvVariant.FNV1A, digits).size, 2)
        @Assert(Fnv.hash(FnvWidth.W256, FnvVariant.FNV1A, digits).size, 4)
        @Assert(Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1A, digits).size, 16)
        @Assert(FnvWidth.W32.words(), 1)
        @Assert(FnvWidth.W64.words(), 1)
        @Assert(FnvWidth.W128.words(), 2)
        @Assert(FnvWidth.W256.words(), 4)
        @Assert(FnvWidth.W1024.words(), 16)
        @Assert(FnvWidth.W1024.bits(), 1024)
        @Assert(FnvWidth.W1024.name(), 'FNV-1024')
        @Assert(FnvVariant.FNV1A.name(), 'FNV-1a')
    }

    /** 统一入口与类型化入口逐位一致（两变体 × 五宽度）。 */
    @TestCase
    public func unifiedApiMatchesTypedEntries(): Unit {
        @Assert(Fnv.hash(FnvWidth.W32, FnvVariant.FNV1, digits)[0], UInt64(Fnv32.fnv1(digits)))
        @Assert(Fnv.hash(FnvWidth.W32, FnvVariant.FNV1A, digits)[0], UInt64(Fnv32.fnv1a(digits)))
        @Assert(Fnv.hash(FnvWidth.W64, FnvVariant.FNV1, digits)[0], Fnv64.fnv1(digits))
        @Assert(Fnv.hash(FnvWidth.W64, FnvVariant.FNV1A, digits)[0], Fnv64.fnv1a(digits))
        @Assert(Fnv128.fnv1(digits), hash128(FnvVariant.FNV1))
        @Assert(Fnv128.fnv1a(digits), hash128(FnvVariant.FNV1A))
        @Assert(Fnv.fnv1(FnvWidth.W256, digits), Fnv256.fnv1(digits))
        @Assert(Fnv.fnv1a(FnvWidth.W256, digits), Fnv256.fnv1a(digits))
        @Assert(Fnv.fnv1(FnvWidth.W1024, digits), Fnv1024.fnv1(digits))
        @Assert(Fnv.fnv1a(FnvWidth.W1024, digits), Fnv1024.fnv1a(digits))
    }

    /** `FnvHasher.finish` 可重复且不改状态；`reset` 回到偏移基值。 */
    @TestCase
    public func hasherFinishIsRepeatableAndResetWorks(): Unit {
        let h = FnvHasher(FnvWidth.W1024, FnvVariant.FNV1A)
        @Assert(h.finish(), basis1024)
        h.update(digits)
        let first = h.finish()
        @Assert(h.finish(), first)
        @Assert(h.finish(), first)
        h.update('x')
        h.reset()
        @Assert(h.finish(), basis1024)
        h.update(digits)
        @Assert(h.finish(), first)
    }

    /** 256/1024 位结果恒长 4 / 16 且最高有效字在前：同一输入两次调用逐位相等。 */
    @TestCase
    public func wordOrderIsBigEndianAndStable(): Unit {
        let w256 = Fnv256.fnv1a(digits)
        @Assert(w256.size, 4)
        @Assert(w256, Fnv256.fnv1a(digits))
        let w1024 = Fnv1024.fnv1a(digits)
        @Assert(w1024.size, 16)
        @Assert(w1024, Fnv1024.fnv1a(digits))
        // 最高有效字在前：空串的 1024 位基值首字为 0、末字为 0xAFF4B16C71EE90B3
        @Assert(basis1024[0], 0x0000000000000000u64)
        @Assert(basis1024[15], 0xAFF4B16C71EE90B3u64)
        @Assert(Fnv256.fnv1a('')[0], 0xDD268DBCAAC55036u64)
        @Assert(Fnv256.fnv1a('')[3], 0x1023B4C8CAEE0535u64)
    }

    /** 128 位结果是可直接比较 / 文本化 / 作容器键的 `UInt128`。 */
    @TestCase
    public func fnv128ResultIsUsable(): Unit {
        let a = Fnv128.fnv1a('alpha')
        let b = Fnv128.fnv1a('alpha')
        let c = Fnv128.fnv1a('beta')
        @Assert(a == b, true)
        @Assert(a == c, false)
        @Assert(a.toString().size > 0, true)
        let m = HashMap<UInt128, String>()
        m[a] = 'alpha'
        @Assert(m[a], 'alpha')
        @Assert(m.contains(c), false)
    }

    private func hash128(variant: FnvVariant): UInt128 {
        let w = Fnv.hash(FnvWidth.W128, variant, digits)
        UInt128(w[0], w[1])
    }
}
