/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
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
