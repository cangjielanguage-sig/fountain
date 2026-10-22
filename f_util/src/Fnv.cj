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

import fountain::f_base.*

/**
 * FNV 哈希族：**标准 FNV-1 / FNV-1a**，覆盖 32 / 64 / 128 / 256 / 1024 五种宽度。
 *
 * 全部常数取自官方 FNV 参考定义（Glenn Fowler / Landon Curt Noll / Phong Vo，
 * `http://www.isthe.com/chongo/tech/comp/fnv/index.html`，以及 `fnv.rs` / IETF
 * `draft-eastlake-fnv`）——偏移基值（offset basis）与素数（prime）**逐字抄录，不自造**。
 * 五种宽度的素数都形如 `2^k + 2^8 + c`：
 *
 * | 宽度 | 偏移基值来源                    | 素数            | `k`（位） | `c`    |
 * |-----|----------------------------|----------------|----------|--------|
 * | 32  | `0x811C9DC5`               | `2^24+2^8+0x93` | 24       | 0x93   |
 * | 64  | `0xCBF29CE484222325`       | `2^40+2^8+0xB3` | 40       | 0xB3   |
 * | 128 | `0x6C62272E07BB014262B821756295C58D` | `2^88+2^8+0x3B` | 88 | 0x3B |
 * | 256 | 见 `FnvCore.BASIS_256`     | `2^168+2^8+0x63`| 168      | 0x63   |
 * | 1024| 见 `FnvCore.BASIS_1024`    | `2^680+2^8+0x8D`| 680      | 0x8D   |
 *
 * 用法：
 * ```
 * Fnv64.fnv1a('123456789')                    // 0x06D5573923C6CDFC：常量指纹
 * Fnv128.fnv1a(src)                           // UInt128：编译去重键
 * Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1A, data)  // 统一入口，16 字大端
 * let h = FnvHasher(FnvWidth.W64, FnvVariant.FNV1A) // 增量：update -> finish -> reset
 * ```
 *
 * 所有宽度共用 `FnvCore` 一份算法（32 位 limb 数组 + 素数分解乘法），类型化入口只做
 * 结果形态转换，不复制算法；输入一律按 **字节** 处理，与字符边界、主机端序无关。
 */
public class Fnv {
    /** 一次性算完：`String` 输入按其 UTF-8 字节序列计算。 */
    public static func hash(width: FnvWidth, variant: FnvVariant, data: String): Array<UInt64> {
        hash(width, variant, data.unsafeBytes())
    }
    /** 一次性算完：字节流输入。返回 `width.words()` 个 `UInt64`，**最高有效字在前**。 */
    public static func hash(width: FnvWidth, variant: FnvVariant, data: Array<Byte>): Array<UInt64> {
        let core = FnvCore.of(width, variant)
        core.update(data)
        core.words()
    }
    /** `Fnv.hash` 的 FNV-1 简写。 */
    public static func fnv1(width: FnvWidth, data: String): Array<UInt64> {
        hash(width, FnvVariant.FNV1, data)
    }
    /** `Fnv.hash` 的 FNV-1 简写（字节流）。 */
    public static func fnv1(width: FnvWidth, data: Array<Byte>): Array<UInt64> {
        hash(width, FnvVariant.FNV1, data)
    }
    /** `Fnv.hash` 的 FNV-1a 简写。 */
    public static func fnv1a(width: FnvWidth, data: String): Array<UInt64> {
        hash(width, FnvVariant.FNV1A, data)
    }
    /** `Fnv.hash` 的 FNV-1a 简写（字节流）。 */
    public static func fnv1a(width: FnvWidth, data: Array<Byte>): Array<UInt64> {
        hash(width, FnvVariant.FNV1A, data)
    }
}

/** FNV-32：`fnv1` / `fnv1a`，返回 `UInt32`。 */
public class Fnv32 {
    /** FNV-1（先乘后异或）。 */
    public static func fnv1(data: String): UInt32 {
        fnv1(data.unsafeBytes())
    }
    /** FNV-1（字节流）。 */
    public static func fnv1(data: Array<Byte>): UInt32 {
        UInt32(Fnv.hash(FnvWidth.W32, FnvVariant.FNV1, data)[0])
    }
    /** FNV-1a（先异或后乘）。 */
    public static func fnv1a(data: String): UInt32 {
        fnv1a(data.unsafeBytes())
    }
    /** FNV-1a（字节流）。 */
    public static func fnv1a(data: Array<Byte>): UInt32 {
        UInt32(Fnv.hash(FnvWidth.W32, FnvVariant.FNV1A, data)[0])
    }
}

/** FNV-64：`fnv1` / `fnv1a`，返回 `UInt64`。f_jit 的常量指纹用它。 */
public class Fnv64 {
    /** FNV-1（先乘后异或）。 */
    public static func fnv1(data: String): UInt64 {
        fnv1(data.unsafeBytes())
    }
    /** FNV-1（字节流）。 */
    public static func fnv1(data: Array<Byte>): UInt64 {
        Fnv.hash(FnvWidth.W64, FnvVariant.FNV1, data)[0]
    }
    /** FNV-1a（先异或后乘）。 */
    public static func fnv1a(data: String): UInt64 {
        fnv1a(data.unsafeBytes())
    }
    /** FNV-1a（字节流）。 */
    public static func fnv1a(data: Array<Byte>): UInt64 {
        Fnv.hash(FnvWidth.W64, FnvVariant.FNV1A, data)[0]
    }
}

/** FNV-128：`fnv1` / `fnv1a`，返回 `UInt128`（可直接比较 / 文本化 / 作容器键）。f_jit 的编译去重键用它。 */
public class Fnv128 {
    /** FNV-1（先乘后异或）。 */
    public static func fnv1(data: String): UInt128 {
        fnv1(data.unsafeBytes())
    }
    /** FNV-1（字节流）。 */
    public static func fnv1(data: Array<Byte>): UInt128 {
        let w = Fnv.hash(FnvWidth.W128, FnvVariant.FNV1, data)
        UInt128(w[0], w[1])
    }
    /** FNV-1a（先异或后乘）。 */
    public static func fnv1a(data: String): UInt128 {
        fnv1a(data.unsafeBytes())
    }
    /** FNV-1a（字节流）。 */
    public static func fnv1a(data: Array<Byte>): UInt128 {
        let w = Fnv.hash(FnvWidth.W128, FnvVariant.FNV1A, data)
        UInt128(w[0], w[1])
    }
}

/** FNV-256：`fnv1` / `fnv1a`，返回 4 个 `UInt64`（**最高有效字在前**）。 */
public class Fnv256 {
    /** FNV-1（先乘后异或）。 */
    public static func fnv1(data: String): Array<UInt64> {
        Fnv.hash(FnvWidth.W256, FnvVariant.FNV1, data)
    }
    /** FNV-1（字节流）。 */
    public static func fnv1(data: Array<Byte>): Array<UInt64> {
        Fnv.hash(FnvWidth.W256, FnvVariant.FNV1, data)
    }
    /** FNV-1a（先异或后乘）。 */
    public static func fnv1a(data: String): Array<UInt64> {
        Fnv.hash(FnvWidth.W256, FnvVariant.FNV1A, data)
    }
    /** FNV-1a（字节流）。 */
    public static func fnv1a(data: Array<Byte>): Array<UInt64> {
        Fnv.hash(FnvWidth.W256, FnvVariant.FNV1A, data)
    }
}

/** FNV-1024：`fnv1` / `fnv1a`，返回 16 个 `UInt64`（**最高有效字在前**）。 */
public class Fnv1024 {
    /** FNV-1（先乘后异或）。 */
    public static func fnv1(data: String): Array<UInt64> {
        Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1, data)
    }
    /** FNV-1（字节流）。 */
    public static func fnv1(data: Array<Byte>): Array<UInt64> {
        Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1, data)
    }
    /** FNV-1a（先异或后乘）。 */
    public static func fnv1a(data: String): Array<UInt64> {
        Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1A, data)
    }
    /** FNV-1a（字节流）。 */
    public static func fnv1a(data: Array<Byte>): Array<UInt64> {
        Fnv.hash(FnvWidth.W1024, FnvVariant.FNV1A, data)
    }
}

/**
 * 增量哈希上下文：`update` 可任意分段喂入，`finish` 可重复调用（不改状态），
 * `reset` 回到偏移基值。分段喂入与一次性喂入结果逐位相同。
 */
public class FnvHasher {
    private let core: FnvCore
    /** 以给定宽度与变体建立上下文（初始状态 = 该宽度的偏移基值）。 */
    public init(width: FnvWidth, variant: FnvVariant) {
        this.core = FnvCore.of(width, variant)
    }
    /** 喂入一段字符串（取其 UTF-8 字节）。 */
    public func update(data: String): Unit {
        core.update(data)
    }
    /** 喂入一段字节流。 */
    public func update(data: Array<Byte>): Unit {
        core.update(data)
    }
    /** 取出当前摘要（`width.words()` 个字，最高有效字在前）；可重复调用。 */
    public func finish(): Array<UInt64> {
        core.words()
    }
    /** 丢弃已喂入的数据，回到偏移基值。 */
    public func reset(): Unit {
        core.reset()
    }
}

/** FNV 宽度：`W32`/`W64`/`W128`/`W256`/`W1024`，决定状态位宽与统一入口返回的字（`UInt64`）个数。 */
public enum FnvWidth {
    W32 | W64 | W128 | W256 | W1024
    /** 规格名，如 `FNV-1024`。 */
    public func name(): String {
        match (this) {
            case W32 => 'FNV-32'
            case W64 => 'FNV-64'
            case W128 => 'FNV-128'
            case W256 => 'FNV-256'
            case W1024 => 'FNV-1024'
        }
    }
    /** 状态位宽。 */
    public func bits(): Int64 {
        match (this) {
            case W32 => 32
            case W64 => 64
            case W128 => 128
            case W256 => 256
            case W1024 => 1024
        }
    }
    /** `Fnv.hash` 返回的 `UInt64` 字数（32/64 位各占 1 个字）。 */
    public func words(): Int64 {
        match (this) {
            case W32 => 1
            case W64 => 1
            case W128 => 2
            case W256 => 4
            case W1024 => 16
        }
    }
}

/** FNV 变体：`FNV1` 先乘后异或，`FNV1A` 先异或后乘。 */
public enum FnvVariant {
    FNV1 | FNV1A
    /** 规格名。 */
    public func name(): String {
        match (this) {
            case FNV1 => 'FNV-1'
            case FNV1A => 'FNV-1a'
        }
    }
}

/**
 * 五宽度共用的 FNV 引擎（包内可见）。
 *
 * 状态是 `bits/32` 个 `UInt32`（**小端序**：下标 0 为最低有效 limb）；借助
 * `prime = 2^k + 2^8 + c` 这一标准形式，把 32/64 位乘法换成
 * `state * prime = (state << k) + (state << 8) + state * c`（模 2^bits），
 * 从而在不引入 128 位中间类型的情况下精确处理 256 / 1024 位的进位。
 */
internal class FnvCore {
    /** 1024 位偏移基值（官方参考值，16 字大端序）。 */
    private static let BASIS_1024: Array<UInt64> = [
        0x0000000000000000u64, 0x005F7A76758ECC4Du64, 0x32E56D5A591028B7u64, 0x4B29FC4223FDADA1u64,
        0x6C3BF34EDA3674DAu64, 0x9A21D90000000000u64, 0x0000000000000000u64, 0x0000000000000000u64,
        0x0000000000000000u64, 0x0000000000000000u64, 0x0000000000000000u64, 0x000000000004C6D7u64,
        0xEB6E73802734510Au64, 0x555F256CC005AE55u64, 0x6BDE8CC9C6A93B21u64, 0xAFF4B16C71EE90B3u64
    ]
    /** 256 位偏移基值（官方参考值，4 字大端序）。 */
    private static let BASIS_256: Array<UInt64> = [
        0xDD268DBCAAC55036u64, 0x2D98C384C4E576CCu64, 0xC8B1536847B6BBB3u64, 0x1023B4C8CAEE0535u64
    ]
    private let limbCount: Int64
    private let wordCount: Int64
    private let shiftBytes: Int64
    private let smallC: UInt64
    private let basis: Array<UInt32>
    private var state: Array<UInt32>
    private var scratchA: Array<UInt32>
    private var scratchB: Array<UInt32>
    private let variant: FnvVariant

    private init(
        limbCount: Int64,
        wordCount: Int64,
        shiftBytes: Int64,
        smallC: UInt64,
        basisWords: Array<UInt64>,
        variant: FnvVariant
    ) {
        this.limbCount = limbCount
        this.wordCount = wordCount
        this.shiftBytes = shiftBytes
        this.smallC = smallC
        this.variant = variant
        this.basis = FnvCore.toLimbs(basisWords, limbCount)
        this.state = FnvCore.copyOf(this.basis)
        this.scratchA = Array<UInt32>(limbCount, repeat: 0u32)
        this.scratchB = Array<UInt32>(limbCount, repeat: 0u32)
    }

    /** 按宽度取得引擎：`(limb 数, 字 数, 素数 2^k 项的字节偏移, 素数低位常数, 偏移基值)`。 */
    internal static func of(width: FnvWidth, variant: FnvVariant): FnvCore {
        match (width) {
            case W32 => FnvCore(1, 1, 3, 0x93u64, [0x811C9DC5u64], variant)
            case W64 => FnvCore(2, 1, 5, 0xB3u64, [0xCBF29CE484222325u64], variant)
            case W128 => FnvCore(4, 2, 11, 0x3Bu64, [0x6C62272E07BB0142u64, 0x62B821756295C58Du64], variant)
            case W256 => FnvCore(8, 4, 21, 0x63u64, BASIS_256, variant)
            case W1024 => FnvCore(32, 16, 85, 0x8Du64, BASIS_1024, variant)
        }
    }

    /** 逐字节喂入；按变体决定「乘—异或」的顺序。 */
    internal func update(data: Array<Byte>): Unit {
        for (b in data) {
            match (variant) {
                case FNV1 =>
                    mulPrime()
                    state[0] ^= UInt32(b)
                case FNV1A =>
                    state[0] ^= UInt32(b)
                    mulPrime()
            }
        }
    }

    /** 喂入字符串的 UTF-8 字节。 */
    internal func update(data: String): Unit {
        update(data.unsafeBytes())
    }

    /** 取出摘要（`wordCount` 个 `UInt64`，最高有效字在前）；不改变状态。 */
    internal func words(): Array<UInt64> {
        FnvCore.toWords(state, wordCount)
    }

    /** 回到偏移基值。 */
    internal func reset(): Unit {
        this.state = FnvCore.copyOf(this.basis)
    }

    /** `state = state * prime (mod 2^bits)`，素数按 `2^k + 2^8 + c` 展开。 */
    @OverflowWrapping
    private func mulPrime(): Unit {
        shiftBytesInto(scratchA, shiftBytes)
        shiftBytesInto(scratchB, 1)
        var carry: UInt64 = 0
        for (i in 0..limbCount) {
            let prod = UInt64(state[i]) * smallC
            let sum = UInt64(scratchA[i]) + UInt64(scratchB[i]) + (prod & 0xFFFFFFFFu64) + carry
            state[i] = UInt32(sum & 0xFFFFFFFFu64)
            carry = (sum >> 32) + (prod >> 32)
        }
    }

    /** `dst = state << (n * 8)` 位，超出 `bits` 的高位丢弃（`dst` 就地覆盖）。 */
    @OverflowWrapping
    private func shiftBytesInto(dst: Array<UInt32>, n: Int64): Unit {
        for (i in 0..limbCount) {
            dst[i] = 0u32
        }
        let limbShift = n / 4
        let bitShift = (n % 4) * 8
        if (limbShift >= limbCount) {
            return
        }
        for (i in limbShift..limbCount) {
            let src = i - limbShift
            var v = (UInt64(state[src]) << bitShift) & 0xFFFFFFFFu64
            if (bitShift > 0 && src > 0) {
                v |= UInt64(state[src - 1]) >> (32 - bitShift)
            }
            dst[i] = UInt32(v)
        }
    }

    /** 大端 `UInt64` 字 -> 小端 `UInt32` limb。 */
    private static func toLimbs(words: Array<UInt64>, limbCount: Int64): Array<UInt32> {
        var out = Array<UInt32>(limbCount, repeat: 0u32)
        for (l in 0..limbCount) {
            let w = words[words.size - 1 - l / 2]
            out[l] = if (l % 2 == 0) {
                UInt32(w & 0xFFFFFFFFu64)
            } else {
                UInt32(w >> 32)
            }
        }
        out
    }

    /** 小端 `UInt32` limb -> 大端 `UInt64` 字。 */
    private static func toWords(state: Array<UInt32>, wordCount: Int64): Array<UInt64> {
        var out = Array<UInt64>(wordCount, repeat: 0u64)
        for (l in 0..state.size) {
            let w = wordCount - 1 - l / 2
            if (l % 2 == 0) {
                out[w] |= UInt64(state[l])
            } else {
                out[w] |= UInt64(state[l]) << 32
            }
        }
        out
    }

    private static func copyOf(src: Array<UInt32>): Array<UInt32> {
        var out = Array<UInt32>(src.size, repeat: 0u32)
        for (i in 0..src.size) {
            out[i] = src[i]
        }
        out
    }
}
