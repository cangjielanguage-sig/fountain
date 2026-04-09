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

import std.convert.*
import fountain::f_base.*
import fountain::f_data.*

// CityHash 常量
private const k0: UInt64 = 0xc3a5c85c97cb3127
private const k1: UInt64 = 0xb492b66fbe98f273

public func cityHash(data: String): UInt128 {
    cityHash(data.unsafeBytes())
}
public func cityHash<T>(data: T): UInt128 where T <: ToString {
    return cityHash(data.toString().unsafeBytes())
}
public func cityHash(data: Array<UInt8>): UInt128 {
    let len = data.size
    // 短字符串处理 (len < 128)
    if (len < 128) {
        return weakHashLen32WithSeeds(data, 0, len, k0, k1)
    }

    // 长字符串处理 (len >= 128)
    var x = seedLow(data, len)
    var y = seedHigh(data, len)
    var z = len.toUInt() * k1

    var low = rotate64(y ^ k1, 49) * k1 + fetch64(data, 0)
    var high = rotate64(low, 42) * k1 + fetch64(data, 8)
    var v = UInt128(high, low)

    low = rotate64(y + z, 35) * k1 + x
    high = rotate64(x + fetch64(data, 88), 53) * k1
    var w = UInt128(high, low)

    // 分块处理 (每块 128 字节)
    var pos: Int64 = 0
    let end = len - 128
    while (pos <= end) {
        x = rotate64(x + y + v.right + fetch64(data, pos + 16), 37) * k1
        y = rotate64(y + v.left + fetch64(data, pos + 48), 42) * k1
        x ^= w.left
        y ^= v.right
        z = rotate64(z + w.right, 33) * k1

        // 交换并混合 v, w
        v = weakHashLen32WithSeeds(data, pos + 64, 32, v.left * k1, x + w.right)
        w = weakHashLen32WithSeeds(data, pos + 96, 32, z + w.left, y + fetch64(data, pos + 16))
        v = UInt128(x, z)
        x = v.right

        pos += 128
    }

    // 处理尾部数据 (最后 128 字节)
    x += rotate64(v.right + z, 49) * k0
    z += rotate64(w.right, 37) * k0

    // 逐步处理剩余的字节块
    let remaining = len - pos
    var tailOffset = pos
    while (remaining > 0) {
        let chunkSize = if (remaining >= 32) {
            32
        } else {
            remaining
        }
        let chunkSize32 = chunkSize
        y = rotate64(y + x, 42) * k0 + v.left
        let right = w.right + fetch64(data, tailOffset + chunkSize - 16)
        x = x * k0 + right
        z += w.left + fetch64(data, tailOffset + chunkSize - 32)
        w = weakHashLen32WithSeeds(data, tailOffset, chunkSize32, x + y, v.right + z)
        (x, z) = (z, x)
        tailOffset += chunkSize
    }
    // 最终混合
    return finalMerge(x, v.right, y, w.right, len)
}
// 辅助函数：最终哈希值混合
private func finalMerge(a: UInt64, b: UInt64, c: UInt64, d: UInt64, len: Int64): UInt128 {
    let low = hashLen16(a, c, len)
    let high = hashLen16(b, d, len + 8)
    return UInt128(high, low)
}

// 辅助函数：计算种子值
private func seedLow(data: Array<UInt8>, len: Int64): UInt64 {
    return fetch64(data, len - 64) ^ k1
}

private func seedHigh(data: Array<UInt8>, len: Int64): UInt64 {
    return fetch64(data, len - 56) ^ k0
}

// 辅助函数：16字节哈希
private func hashLen16(u: UInt64, v: UInt64, len: Int64): UInt64 {
    let xorResult = u ^ v
    let mix = shiftMix(xorResult * k1) * k1
    return hashLen16Minimal(u, v) ^ UInt64(len)
}

// 辅助函数：基础16字节哈希
private func hashLen16Minimal(u: UInt64, v: UInt64): UInt64 {
    let xorResult = u ^ v
    return shiftMix(xorResult * k1) * k1
}

// 辅助函数：以小端序从字节数组中读取 UInt64
private func fetch64(bytes: Array<UInt8>, offset: Int64): UInt64 {
    var result: UInt64 = 0
    // 小端序：最低有效字节在前
    for (i in 0..8) {
        result |= UInt64(bytes[offset + i]) << (i * 8)
    }
    return result
}

// 辅助函数：64 位循环右移
private func rotate64(val: UInt64, shift: Int32): UInt64 {
    // 避免未定义行为：取模 64
    let s = shift & 63
    return (val >> s) | (val << (64 - s))
}

// 辅助函数：32 位循环右移（用于 Mur 混合）
private func rotate32(val: UInt32, shift: Int32): UInt32 {
    let s = shift & 31
    return (val >> s) | (val << (32 - s))
}

// 核心混合函数（源自 MurmurHash3 的逻辑）
private func mur(a: UInt32, h: UInt32): UInt32 {
    var aVar = a
    var hVar = h
    let c1: UInt32 = 0xcc9e2d51
    let c2: UInt32 = 0x1b873593

    aVar *= c1
    aVar = rotate32(aVar, 17)
    aVar *= c2

    hVar ^= aVar
    hVar = rotate32(hVar, 19)

    return hVar * 5 + 0xe6546b64
}

// 弱哈希函数：对约 32 字节数据进行哈希混合
private func weakHashLen32WithSeeds(bytes: Array<UInt8>, offset: Int64, len: Int64, seedA: UInt64, seedB: UInt64): UInt128 {
    // 组合种子
    var a = seedA
    var b = seedB
    var c: UInt64 = 0
    var d: UInt64 = 0

    // 根据长度调整初始值
    if (len <= 16) {
        a = shiftMix(a * k1) * k1
        c = b * k1 + fetch64(bytes, offset + len - 8)
        d = shiftMix(a + (if (len >= 8) {
            fetch64(bytes, offset)
        } else {
            c
        }))
    } else {
        // 处理 17-32 字节
        c = fetch64(bytes, offset + len - 8)
        d = fetch64(bytes, offset + len - 16) * k1
        a += d
        d = shiftMix(a + b)
    }

    // 主混合逻辑
    a = fetch64(bytes, offset)
    b = fetch64(bytes, offset + 8)

    // 核心运算（模拟 C++ 中的位混合）
    a ^= k1
    b ^= a
    a = rotate64(a, 43) + rotate64(b, 30) + c
    b = shiftMix(a + b + d)

    return UInt128(a, b)
}

// 辅助函数：位混合
private func shiftMix(value: UInt64): UInt64 {
    return value ^ (value >> 47)
}
