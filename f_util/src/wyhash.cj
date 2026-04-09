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

// this wyhash is copied from cangjie-runtime
/**
 * @brief cangjie version of wyRand & wyHash
 *
 * wyRand is a fast pseudo-random function, It can eliminate the performance loss caused by bad hashes.
 *
 * @param seed The seed to generate a 64-bit random number
 */
private const SECRET0 = 0xa0761d6478bd642fu64
private const SECRET1 = 0xe7037ed1a0b428dbu64
private const SECRET2 = 0x8ebc6af09c88c6e3u64
private const SECRET3 = 0x589965cc75374cc3u64

public func wyrand(seed: Int64): UInt64 {
    return wyrand(seed.toUInt())
}
@OverflowWrapping
public func wyrand(seed: UInt64): UInt64 {
    let v: UInt64 = seed + SECRET0
    return mix(v, v ^ SECRET1)
}
public func wyhash(s: String, start!: Int64 = 0, size!: Int64 = s.size, see!: UInt64 = 0): UInt64 {
    return wyhash(s.unsafeBytes(), start: start, size: size, see: see)
}
public func wyhash<T>(s: T, start!: Int64 = 0, see!: UInt64 = 0): UInt64 where T <: ToString {
    let bytes = s.toString().unsafeBytes()
    return wyhash(bytes, start: start, size: bytes.size, see: see)
}
@OverflowWrapping
public func wyhash(arr: Array<UInt8>, start!: Int64 = 0, size!: Int64 = arr.size, see!: UInt64 = 0): UInt64 {
    var seed = see ^ mix(see ^ SECRET0, SECRET1)
    if (size == 0) {
        return seed
    }
    var a: UInt64
    var b: UInt64
    match {
        case size < 4 =>
            a = (UInt64(arr[start]) << 16) | (UInt64(arr[start + (size >> 1)]) << 8) | (UInt64(arr[start + size - 1]))
            b = 0
        case size == 4 =>
            a = r4(arr, start)
            b = a
        case size < 8 =>
            a = r4(arr, start)
            b = r4(arr, start + size - 4)
        case size <= 16 =>
            a = r8(arr, start)
            b = r8(arr, start + size - 8)
        case _ =>
            var pos = start
            var l = size
            if (l > 48) {
                var seed1 = seed
                var seed2 = seed

                do {
                    seed = mix(r8(arr, pos) ^ SECRET1, r8(arr, pos + 8) ^ seed)
                    seed1 = mix(r8(arr, pos + 16) ^ SECRET2, r8(arr, pos + 24) ^ seed1)
                    seed2 = mix(r8(arr, pos + 32) ^ SECRET3, r8(arr, pos + 40) ^ seed2)
                    pos += 48
                    l -= 48
                } while (l > 48)
                seed = seed ^ seed1 ^ seed2
            }

            while (l > 16) {
                seed = mix(r8(arr, pos) ^ SECRET1, r8(arr, pos + 8) ^ seed)
                l -= 16
                pos += 16
            }
            a = r8(arr, pos + l - 16)
            b = r8(arr, pos + l - 8)
    }
    a ^= SECRET1
    b ^= seed
    return mix(a ^ SECRET0 ^ UInt64(size), b ^ SECRET1)
}

@OverflowWrapping
private func mix(A: UInt64, B: UInt64): UInt64 {
    let ha: UInt64 = A >> 32
    let hb: UInt64 = B >> 32
    let la: UInt64 = UInt64(UInt32(A))
    let lb: UInt64 = UInt64(UInt32(B))
    let rh = ha * hb
    let rm0 = ha * lb
    let rm1 = hb * la
    let rl = la * lb
    let t = rl + (rm0 << 32)
    var c: UInt64 = if (t < rl) {
        1
    } else {
        0
    }
    let lo = t + (rm1 << 32)
    c += if (lo < t) {
        1
    } else {
        0
    }
    let hi = rh + (rm0 >> 32) + (rm1 >> 32) + c
    return lo ^ hi
}

@OverflowWrapping
private func r4(arr: Array<UInt8>, pos: Int64): UInt64 {
    (UInt64(arr[pos]) << 24) | (UInt64(arr[pos + 1]) << 16) | (UInt64(arr[pos + 2]) << 8) | UInt64(arr[pos + 3])
}

@OverflowWrapping
private func r8(arr: Array<UInt8>, pos: Int64): UInt64 {
    (UInt64(arr[pos]) << 56) | (UInt64(arr[pos + 1]) << 48) | (UInt64(arr[pos + 2]) << 40) | (UInt64(arr[pos + 3]) << 32) |
        (UInt64(arr[pos + 4]) << 24) | (UInt64(arr[pos + 5]) << 16) | (UInt64(arr[pos + 6]) << 8) | UInt64(arr[pos + 7])
}
