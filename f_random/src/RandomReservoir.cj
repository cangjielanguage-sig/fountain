/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_random

import std.collection.ArrayList
import stdx.crypto.crypto.SecureRandom

public func randomReservoir<T>(count: Int64, source: Iterable<T>, priv!: Bool = false): ArrayList<T> {
    let rand = SecureRandom(priv: priv)
    var result = ArrayList<T>()
    var c = 0
    for (v in source) {
        if (c < count) {
            result.add(v)
        } else {
            let r = rand.nextInt64(c)
            if (r < count) {
                result[r] = v
            }
        }
        c++
    }
    return result
}
