/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_concurrent

public class BloomFilter<T> where T <: Hashable {
    private let mutex = Mutex()
    private let bits = BitSet()
    public BloomFilter(private let hashers: Array<(T, Int64) -> Int64>) {}
    public init(iterate!: Int64 = 5) {
        this(genHashers(iterate))
    }
    public init(hashers: Array<(T) -> Int64>) {
        this(Array<(T, Int64) -> Int64>(hashers.size) {i =>
            {v: T, _: Int64 =>
                hashers[i](v)
            }
        })
    }
    private static func genHashers(iterate: Int64): Array<(T, Int64) -> Int64> {
        @OverflowWrapping
        func hash(v: T, h: Int64) {
            h * 131 + v.hashCode()
        }
        Array<(T, Int64) -> Int64>(iterate, repeat: hash)
    }
    public func set(value: T): Unit {
        var h = value.hashCode()
        synchronized(mutex){
            bits[h] = true
            for(hasher in hashers){
                h = hasher(value, h)
                bits[h] = true
            }
        }
    }
    public func contains(value: T): Bool {
        var h = value.hashCode()
        synchronized(mutex){
            var result = bits[h]
            if (result) {
                var i = 0
                while(result && i < hashers.size) {
                    h = hashers[i](value, h)
                    result &&= bits[h]
                    i++
                }
            }
            result
        }
    }
}
