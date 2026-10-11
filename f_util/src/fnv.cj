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
 * FNV（Fowler–Noll–Vo）非加密哈希：**FNV-1 与 FNV-1a，宽度 32 / 64 / 128 / 256**。
 *
 * 定义（公有领域，1991；G. Fowler / L. C. Noll / K.-P. Vo）：
 * ```
 * FNV-1a :  hash = (hash XOR byte) * prime      // 推荐变体
 * FNV-1   :  hash = (hash * prime) XOR byte
 * ```
 * 全部运算为**无符号回绕**（mod 2^n）——仓颉默认溢出策略是 throwing，故本文件的实现函数
 * 一律标注 `@OverflowWrapping`（这是**语义对齐**，不是绕过检查）。
 *
 * 参数（prime = 2^s + 2^8 + c；offset basis 由 FNV-0 对 Noll 签名行求得，见 FNV 官方参数表）：
 *
 * | 宽度 | offset basis | prime |
 * |---|---|---|
 * | 32 | `0x811C9DC5` | `0x01000193` |
 * | 64 | `0xCBF29CE484222325` | `0x100000001B3` |
 * | 128 | `0x6C62272E07BB014262B821756295C58D` | `2^88 + 2^8 + 0x3B` |
 * | 256 | `0xDD268DBCAAC550362D98C384C4E576CCC8B1536847B6BBB31023B4C8CAEE0535` | `2^168 + 2^8 + 0x63` |
 *
 * **非加密**：可预测、可构造碰撞（相关输入间存在 XOR 关系，如 `fnv1a(a) XOR fnv1a(b) = fnv1a(a') XOR fnv1a(b')`），
 * **不得**用于签名/防篡改/抗洪泛场景；作缓存键或去重键时应**命中后二次校验原字节**。
 *
 * 用法：
 * ```
 * let h  = Fnv64.fnv1a.compute(bytes)          // 一次算完
 * var h2 = Fnv64.fnv1a.initRegister()          // 增量：init -> update -> finish
 * h2 = Fnv64.fnv1a.update(h2, chunk1)
 * h2 = Fnv64.fnv1a.update(h2, chunk2)
 * h2 = Fnv64.fnv1a.finish(h2)
 * let s  = Fnv64.fnv1a.computeHex(bytes)       // 定长十六进制（小写）
 * ```
 * 每个宽度提供 `fnv1` / `fnv1a` 两个变体，`all` 供遍历自检（见 `fnv_test.cj`：
 * 逐个核对 `"123456789"` 的黄金值、空输入 = offset basis、增量 ≡ 一次算完）。
 */

/** 下方 8 个变体的黄金值（`"123456789"`）与算法均为官方参数表的直接实现；256 位无值类型，用十六进制字符串承载。 */

public class Fnv32 {
    /** FNV-1-32：先乘后异或。 */
    public static let fnv1 = Fnv32('FNV-1-32', false, 0x811C9DC5u32, 0x01000193u32, 0x24148816u32)
    /** FNV-1a-32：先异或后乘（推荐）。 */
    public static let fnv1a = Fnv32('FNV-1a-32', true, 0x811C9DC5u32, 0x01000193u32, 0xBB86B11Cu32)
    /** 全部变体（自检/按需挑选）。 */
    public static let all = [fnv1, fnv1a]

    /** 变体名（如 `FNV-1a-32`）。 */
    public let name: String
    /** 是否为 FNV-1a（先异或后乘）；false = FNV-1（先乘后异或）。 */
    public let isFnv1a: Bool
    /** `"123456789"` 的黄金值。 */
    public let checkValue: UInt32
    private let offset: UInt32
    private let prime: UInt32

    public init(name: String, isFnv1a: Bool, offset: UInt32, prime: UInt32, checkValue: UInt32) {
        this.name = name
        this.isFnv1a = isFnv1a
        this.offset = offset
        this.prime = prime
        this.checkValue = checkValue
    }

    /** 增量起始值 = offset basis。 */
    public func initRegister(): UInt32 {
        offset
    }

    /** 增量更新（FNV 无末尾处理，`finish` 即恒等）。 */
    @OverflowWrapping
    public func update(hash: UInt32, data: Array<Byte>): UInt32 {
        var h = hash
        if (isFnv1a) {
            for (b in data) {
                h = (h ^ UInt32(b)) * prime
            }
        } else {
            for (b in data) {
                h = (h * prime) ^ UInt32(b)
            }
        }
        return h
    }

    public func finish(hash: UInt32): UInt32 {
        hash
    }

    public func compute(data: Array<Byte>): UInt32 {
        update(initRegister(), data)
    }

    public func compute(s: String): UInt32 {
        compute(s.unsafeBytes())
    }

    /** 定长十六进制（8 位、小写）。 */
    public func computeHex(data: Array<Byte>): String {
        fnvHex64(UInt64(compute(data)), 8)
    }

    public func computeHex(s: String): String {
        computeHex(s.unsafeBytes())
    }
}

public class Fnv64 {
    /** FNV-1-64：先乘后异或。 */
    public static let fnv1 = Fnv64('FNV-1-64', false, 0xCBF29CE484222325u64, 0x100000001B3u64, 0xA72FFC362BF916D6u64)
    /** FNV-1a-64：先异或后乘（推荐）。 */
    public static let fnv1a = Fnv64('FNV-1a-64', true, 0xCBF29CE484222325u64, 0x100000001B3u64, 0x06D5573923C6CDFCu64)
    /** 全部变体（自检/按需挑选）。 */
    public static let all = [fnv1, fnv1a]

    /** 变体名（如 `FNV-1a-64`）。 */
    public let name: String
    /** 是否为 FNV-1a（先异或后乘）；false = FNV-1（先乘后异或）。 */
    public let isFnv1a: Bool
    /** `"123456789"` 的黄金值。 */
    public let checkValue: UInt64
    private let offset: UInt64
    private let prime: UInt64

    public init(name: String, isFnv1a: Bool, offset: UInt64, prime: UInt64, checkValue: UInt64) {
        this.name = name
        this.isFnv1a = isFnv1a
        this.offset = offset
        this.prime = prime
        this.checkValue = checkValue
    }

    /** 增量起始值 = offset basis。 */
    public func initRegister(): UInt64 {
        offset
    }

    /** 增量更新（FNV 无末尾处理，`finish` 即恒等）。 */
    @OverflowWrapping
    public func update(hash: UInt64, data: Array<Byte>): UInt64 {
        var h = hash
        if (isFnv1a) {
            for (b in data) {
                h = (h ^ UInt64(b)) * prime
            }
        } else {
            for (b in data) {
                h = (h * prime) ^ UInt64(b)
            }
        }
        return h
    }

    public func finish(hash: UInt64): UInt64 {
        hash
    }

    public func compute(data: Array<Byte>): UInt64 {
        update(initRegister(), data)
    }

    public func compute(s: String): UInt64 {
        compute(s.unsafeBytes())
    }

    /** 定长十六进制（16 位、小写）。 */
    public func computeHex(data: Array<Byte>): String {
        fnvHex64(compute(data), 16)
    }

    public func computeHex(s: String): String {
        computeHex(s.unsafeBytes())
    }
}

public class Fnv128 {
    /** FNV-1-128：先乘后异或。 */
    public static let fnv1 = Fnv128('FNV-1-128', false,
        UInt128(0x6C62272E07BB0142u64, 0x62B821756295C58Du64),
        [0x13Bu64, 0x1000000u64],
        UInt128(0x8BEA2C73BE03B30Fu64, 0xD4142FB1EC2C2066u64))
    /** FNV-1a-128：先异或后乘（推荐；**f_jit 的源/字节码指纹用它**）。 */
    public static let fnv1a = Fnv128('FNV-1a-128', true,
        UInt128(0x6C62272E07BB0142u64, 0x62B821756295C58Du64),
        [0x13Bu64, 0x1000000u64],
        UInt128(0xDA2D42A08D04E458u64, 0x5DD325117F71D504u64))
    /** 全部变体（自检/按需挑选）。 */
    public static let all = [fnv1, fnv1a]

    /** 变体名（如 `FNV-1a-128`）。 */
    public let name: String
    /** 是否为 FNV-1a（先异或后乘）；false = FNV-1（先乘后异或）。 */
    public let isFnv1a: Bool
    /** `"123456789"` 的黄金值。 */
    public let checkValue: UInt128
    private let offset: Array<UInt64> // 小端 limb： [低 64 位, 高 64 位]
    private let prime: Array<UInt64>

    public init(name: String, isFnv1a: Bool, offset: UInt128, prime: Array<UInt64>, checkValue: UInt128) {
        this.name = name
        this.isFnv1a = isFnv1a
        this.offset = [offset.right, offset.left]
        this.prime = prime
        this.checkValue = checkValue
    }

    /** 增量起始值 = offset basis。 */
    public func initRegister(): UInt128 {
        UInt128(offset[1], offset[0])
    }

    /** 增量更新（FNV 无末尾处理，`finish` 即恒等）。 */
    @OverflowWrapping
    public func update(hash: UInt128, data: Array<Byte>): UInt128 {
        let h = [hash.right, hash.left] // 小端 limb
        let acc = Array<UInt64>(2, repeat: 0)
        for (b in data) {
            if (isFnv1a) {
                h[0] ^= UInt64(b)
                fnvMulInto(h, prime, acc)
            } else {
                fnvMulInto(h, prime, acc)
                h[0] ^= UInt64(b)
            }
        }
        return UInt128(h[1], h[0])
    }

    public func finish(hash: UInt128): UInt128 {
        hash
    }

    public func compute(data: Array<Byte>): UInt128 {
        update(initRegister(), data)
    }

    public func compute(s: String): UInt128 {
        compute(s.unsafeBytes())
    }

    /** 定长十六进制（32 位、小写）。 */
    public func computeHex(data: Array<Byte>): String {
        fnvHex128(compute(data))
    }

    public func computeHex(s: String): String {
        computeHex(s.unsafeBytes())
    }
}

/**
 * FNV-256：**结果与状态均为 32 字节大端字节数组**（仓颉无 256 位整数类型；
 * 如需值类型可后续补 `UInt256`——接口以字节数组承载，语义不受影响）。
 */
public class Fnv256 {
    private static let OFFSET: Array<UInt64> =
        [0x1023B4C8CAEE0535u64, 0xC8B1536847B6BBB3u64, 0x2D98C384C4E576CCu64, 0xDD268DBCAAC55036u64]
    // prime = 2^168 + 2^8 + 0x63：2^168 = 2^(128+40) ⇒ **limb2** 的第 40 位（limb0 = 2^8 + 0x63）
    private static let PRIME: Array<UInt64> = [0x163u64, 0x0u64, 0x10000000000u64, 0x0u64]

    /** FNV-1-256：先乘后异或。 */
    public static let fnv1 = Fnv256('FNV-1-256', false,
        "0c37a392d3522f845f2553c403a80f659b80c9a5b0151496cc37419f79b95ef6")
    /** FNV-1a-256：先异或后乘（推荐）。 */
    public static let fnv1a = Fnv256('FNV-1a-256', true,
        "0c2033a9bfac21398d7ba2c403a80f659b80c9a5b01178b5cff0ab62e9d53c4c")
    /** 全部变体（自检/按需挑选）。 */
    public static let all = [fnv1, fnv1a]

    /** 变体名（如 `FNV-1a-256`）。 */
    public let name: String
    /** 是否为 FNV-1a（先异或后乘）；false = FNV-1（先乘后异或）。 */
    public let isFnv1a: Bool
    /** `"123456789"` 的黄金值（十六进制小写，64 位定长）。 */
    public let checkHex: String

    public init(name: String, isFnv1a: Bool, checkHex: String) {
        this.name = name
        this.isFnv1a = isFnv1a
        this.checkHex = checkHex
    }

    /** 增量起始值 = offset basis（大端 32 字节）。 */
    public func initRegister(): Array<Byte> {
        fnvBytes(Fnv256.OFFSET)
    }

    /** 增量更新（FNV 无末尾处理，`finish` 即恒等）。 */
    @OverflowWrapping
    public func update(hash: Array<Byte>, data: Array<Byte>): Array<Byte> {
        let h = fnvLimbs(hash)
        let acc = Array<UInt64>(4, repeat: 0)
        for (b in data) {
            if (isFnv1a) {
                h[0] ^= UInt64(b)
                fnvMulInto(h, Fnv256.PRIME, acc)
            } else {
                fnvMulInto(h, Fnv256.PRIME, acc)
                h[0] ^= UInt64(b)
            }
        }
        return fnvBytes(h)
    }

    public func finish(hash: Array<Byte>): Array<Byte> {
        hash
    }

    public func compute(data: Array<Byte>): Array<Byte> {
        update(initRegister(), data)
    }

    public func compute(s: String): Array<Byte> {
        compute(s.unsafeBytes())
    }

    /** 定长十六进制（64 位、小写）。 */
    public func computeHex(data: Array<Byte>): String {
        fnvHexBytes(compute(data))
    }

    public func computeHex(s: String): String {
        computeHex(s.unsafeBytes())
    }
}

// ============================ 内部工具：十六进制与 limb 算术 ============================

/** 无符号值的定长十六进制（小写，`nibbles` 位）。 */
func fnvHex64(value: UInt64, nibbles: Int64): String {
    let digits = "0123456789abcdef".toArray()
    let out = Array<Byte>(nibbles, repeat: 0)
    var v = value
    var i = nibbles - 1
    while (i >= 0) {
        out[i] = digits[Int64(v & 0xF)]
        v = v >> 4
        i--
    }
    return String.fromUtf8(out)
}

func fnvHex128(value: UInt128): String {
    fnvHex64(value.left, 16) + fnvHex64(value.right, 16)
}

func fnvHexBytes(bytes: Array<Byte>): String {
    let digits = "0123456789abcdef".toArray()
    let out = Array<Byte>(bytes.size * 2, repeat: 0)
    for (i in 0..bytes.size) {
        let v = UInt64(bytes[i])
        out[i * 2] = digits[Int64(v >> 4)]
        out[i * 2 + 1] = digits[Int64(v & 0xF)]
    }
    return String.fromUtf8(out)
}

/** 大端字节（32 B）→ 小端 limb（4 项）。 */
func fnvLimbs(bytes: Array<Byte>): Array<UInt64> {
    let out = Array<UInt64>(4, repeat: 0)
    for (i in 0..4) {
        var v = 0u64
        for (j in 0..8) {
            v = (v << 8) | UInt64(bytes[(3 - i) * 8 + j])
        }
        out[i] = v
    }
    return out
}

/** 小端 limb（4 项）→ 大端字节（32 B）。 */
func fnvBytes(limbs: Array<UInt64>): Array<Byte> {
    let out = Array<Byte>(32, repeat: 0)
    for (i in 0..4) {
        var v = limbs[i]
        for (j in 0..8) {
            out[(3 - i) * 8 + (7 - j)] = UInt8(v & 0xFF)
            v = v >> 8
        }
    }
    return out
}

/** 64×64 → (hi, lo)。用 32 位半字拆分，避免 128 位中间值。 */
@OverflowWrapping
func fnvMul64x64(a: UInt64, b: UInt64): (UInt64, UInt64) {
    let a0 = a & 0xFFFFFFFFu64
    let a1 = a >> 32
    let b0 = b & 0xFFFFFFFFu64
    let b1 = b >> 32
    let p00 = a0 * b0
    let p01 = a0 * b1
    let p10 = a1 * b0
    let p11 = a1 * b1
    let mid = (p00 >> 32) + (p01 & 0xFFFFFFFFu64) + (p10 & 0xFFFFFFFFu64)
    let lo = (p00 & 0xFFFFFFFFu64) | (mid << 32)
    let hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32)
    return (hi, lo)
}

/** `acc[idx..] += v`（带进位传播，越界丢弃 = mod 2^(64·len)）。 */
@OverflowWrapping
func fnvAddAt(acc: Array<UInt64>, idx: Int64, v: UInt64): Unit {
    var j = idx
    var add = v
    while (j < acc.size && add != 0) {
        let s = acc[j] + add
        add = if (s < add) { 1u64 } else { 0u64 }
        acc[j] = s
        j++
    }
}

/** `h = h * p (mod 2^(64·n))`：schoolbook 截断乘；`acc` 为复用的暂存（长度 = n）。 */
@OverflowWrapping
func fnvMulInto(h: Array<UInt64>, p: Array<UInt64>, acc: Array<UInt64>): Unit {
    let n = h.size
    var i = 0
    while (i < n) {
        acc[i] = 0
        i++
    }
    i = 0
    while (i < n) {
        var j = 0
        while (j < n - i) {
            let (hi, lo) = fnvMul64x64(h[i], p[j])
            fnvAddAt(acc, i + j, lo)
            if (i + j + 1 < n) {
                fnvAddAt(acc, i + j + 1, hi)
            }
            j++
        }
        i++
    }
    i = 0
    while (i < n) {
        h[i] = acc[i]
        i++
    }
}
