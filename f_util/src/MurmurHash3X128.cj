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

import std.binary.LittleEndianOrder
import std.convert.*
import stdx.encoding.hex.*
import fountain::f_base.*
import fountain::f_data.DataParsable
import fountain::f_util.exception.HashException

// 核心哈希函数：对字节数组进行哈希（静态方法）
@OverflowWrapping
public func murmurHash(data: Array<Byte>, seed!: UInt64 = 0): UInt128 {
    let len = data.size
    let nblocks = len / 16

    let c1: UInt64 = 0x87c37b91114253d5
    let c2: UInt64 = 0x4cf5ad432745937f

    var h1: UInt64 = seed
    var h2: UInt64 = seed

    // 1. 处理完整的16字节块
    for (offset in 0..nblocks : 16) {
        let blockSlice = data[offset..offset + 16]

        let k1 = UInt64.readLittleEndian(blockSlice[0..8])
        let k2 = UInt64.readLittleEndian(blockSlice[8..16])

        // 混合 k1
        var k1_mixed = k1
        k1_mixed *= c1
        k1_mixed = rotl64(k1_mixed, 31)
        k1_mixed *= c2
        h1 ^= k1_mixed

        h1 = rotl64(h1, 27)
        h1 += h2
        h1 = h1 * 5 + 0x52dce729

        // 混合 k2
        var k2_mixed = k2
        k2_mixed *= c2
        k2_mixed = rotl64(k2_mixed, 33)
        k2_mixed *= c1
        h2 ^= k2_mixed

        h2 = rotl64(h2, 31)
        h2 += h1
        h2 = h2 * 5 + 0x38495ab5
    }

    // 2. 处理尾部剩余字节 (Tail Processing)
    var k1_tail: UInt64 = 0
    var k2_tail: UInt64 = 0
    let tailStart = nblocks * 16
    let tailLen = len - tailStart

    if (tailLen > 0) {
        let tailSlice = data[tailStart..]
        // 处理 k1 的尾部 (8字节)
        if (tailLen >= 8) {
            k1_tail = UInt64.readLittleEndian(tailSlice[0..8])
            k1_tail *= c1
            k1_tail = rotl64(k1_tail, 31)
            k1_tail *= c2
            h1 ^= k1_tail
        }
        // 处理 k2 的尾部 (8字节)
        if (tailLen > 8) {
            // 注意：读取不足8字节时需要手动掩码
            k2_tail = 0
            let k2Start = 8
            for (i in k2Start..tailLen) {
                let shift = (i - k2Start) * 8
                k2_tail ^= (UInt64(tailSlice[i]) & 0xFF) << shift
            }
            k2_tail *= c2
            k2_tail = rotl64(k2_tail, 33)
            k2_tail *= c1
            h2 ^= k2_tail
        } else if (tailLen > 0) {
            // 如果尾部长度在1-7之间，这部分数据属于k1的剩余字节
            k1_tail = 0
            for (i in (0..tailLen : 1)) {
                let shift = i * 8
                k1_tail ^= (UInt64(tailSlice[i]) & 0xFF) << shift
            }
            k1_tail *= c1
            k1_tail = rotl64(k1_tail, 31)
            k1_tail *= c2
            h1 ^= k1_tail
        }
    }

    // 3. 最终混淆 (Finalization)
    h1 ^= len.toUInt()
    h2 ^= len.toUInt()

    h1 += h2
    h2 += h1

    h1 = fmix64(h1)
    h2 = fmix64(h2)

    h1 += h2
    h2 += h1

    return UInt128(h1, h2)
}

// 便捷函数：直接对字符串进行哈希（静态方法）
public func murmurHash(text: String, seed!: UInt64 = 0): UInt128 {
    let bytes = text.unsafeBytes()
    return murmurHash(bytes, seed: seed)
}
public func murmurHash<T>(text: T, seed!: UInt64 = 0): UInt128 where T <: ToString {
    return murmurHash(text.toString(), seed: seed)
}
// 64 位循环左移（私有静态辅助函数）
@OverflowWrapping
private func rotl64(x: UInt64, r: Int): UInt64 {
    return (x << r) | (x >> (64 - r))
}

// 64 位最终混合函数（私有静态辅助函数）
@OverflowWrapping
private func fmix64(k: UInt64): UInt64 {
    var k_var = k
    k_var ^= k_var >> 33
    k_var *= 0xff51afd7ed558ccd
    k_var ^= k_var >> 33
    k_var *= 0xc4ceb9fe1a85ec53
    k_var ^= k_var >> 33
    return k_var
}
