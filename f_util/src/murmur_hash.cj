/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_util

import std.overflow.WrappingOp
import f_base.*

let MURMUR_HASH_MASK = 0xc6a4a7935bd1e995_u64.
toInt()

public func hash(data: Array<Byte>, offset!: Int64 = 0, length!: Int64 = data.size, seed!: Int64 = 0x1234567890ABCDEF): Int64 {
    func getLong(buf: Array<Byte>, cur: Int64): (Int64, Int64) {
        var k = 0
        var i = cur
        do {
            k = (k << 8) | Int64(buf[i])
            i++
        } while (i < length && i % 8 != 0)
        return (k, i)
    }
    let buf = data.slice(offset, length)
    let m = MURMUR_HASH_MASK
    let r = 47

    var h = seed ^ (length.wrappingMul(m))
    var k: Int64
    var i = 0
    while (length - i >= 8) {
        let tpl = getLong(buf, i)
        k = tpl[0]
        i = tpl[1]
        k = k.wrappingMul(m)
        k ^= k >> r
        k = k.wrappingMul(m)

        h ^= k
        h = k.wrappingMul(m)
    }

    if (length - i > 0) {
        h ^= getLong(buf, i)[0]
        h = h.wrappingMul(m)
    }

    h ^= h >> r
    h = h.wrappingMul(m)
    h ^= h >> r

    return h
}
