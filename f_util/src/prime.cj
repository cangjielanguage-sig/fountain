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

/**
 * 快速幂取模
 * @param a
 * @param b
 * @param m
 * @return
 */
public func qpow(a: UInt64, b: UInt64, m: UInt64) {
    var aa = a
    var bb = b
    var ans = 1u64
    while (bb != 0) {
        if ((bb & 1) != 0) {
            ans = (ans * aa) % m
        }
        bb >>= 1
        aa = (aa * aa) % m
    }
    return ans
}

public func millerRabin(x: UInt64, p: UInt64) {
    var d = p - 1
    while ((d & 1) == 0) {
        d >>= 1
    }
    var t = qpow(x, d, p)
    while (d != p - 1) {
        if (t == 1 || t == p - 1) {
            return true
        }
        t = (t * t) % p
        d <<= 1
    }
    return false
}
/**
 * 判定素数
 * @param p
 * @return
 */
public func isPrime(p: UInt64) {
    if (p < 2) {
        return false
    }
    let a: Array<UInt64> = [2, 3, 5, 7, 11]
    for (i in 0..a.size) {
        if (p == a[i]) {
            return true
        }
        if (!millerRabin(a[i], p)) {
            return false
        }
    }
    return true
}
