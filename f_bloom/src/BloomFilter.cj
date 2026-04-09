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
package fountain::f_bloom

import std.math
import std.sync.AtomicUInt64
import fountain::f_base.*
import fountain::f_random.ThreadLocalRandom
import fountain::f_util.wyhash

public class BloomFilter {
    private let bitSet: Array<AtomicUInt64>
    private let size: Int64
    private let hashers: Array<(UInt64, (Array<Byte>) -> UInt64)>
    public let n: Int64
    public let p: Float64
    /**
     * 初始化过滤器
     * @param n 预期元素数量
     * @param p 期望误判率
     */
    public static func new(n: Int64, p: Float64): BloomFilter {
        // 计算最优 m 和 k
        let m = makeM(n, p)
        let k = makeK(m, n)
        let rand = ThreadLocalRandom.current
        BloomFilter(n, p, m, Array<UInt64>(k){_ => 
            rand.nextUInt64()
        })
    }
    public static func new(n: Int64, p: Float64, seeds: Array<UInt64>): BloomFilter {
        // 计算最优 m 和 k
        let m = makeM(n, p)
        BloomFilter(n, p, m, seeds)
    }
    private init(n: Int64, p: Float64, m: Int64, seeds: Array<UInt64>){
        this.n = n
        this.p = p
        this.size = m
        this.hashers = Array<(UInt64, (Array<Byte>) -> UInt64)>(seeds.size){i => 
            let seed = seeds[i]
            (seed, {bytes: Array<Byte> => wyhash(bytes, see: seed)})
        }

        let arraySize = (size + 63) / 64
        this.bitSet = Array<AtomicUInt64>(arraySize){_ => AtomicUInt64(0)}
        for (i in 0..arraySize) {
            bitSet[i] = AtomicUInt64(0)
        }
    }
    private static func ceilToInt64(f: Float64): Int64 {
        Int64(math.ceil(f))
    }
    private static func makeM(n: Int64, p: Float64): Int64 {
        return ceilToInt64(-(Float64(n) * math.log(p)) / (math.log(2.0) ** 2.0))
    }
    private static func makeK(m: Int64, n: Int64): Int64 {
        return ceilToInt64((Float64(m) / Float64(n)) * math.log(2.0))
    }
    public prop seeds: Iterator<UInt64> {
        get(){
            hashers.iterator().map{tpl => tpl[0]}
        }
    }
    /**
     * 添加元素 (无锁并发安全)
     */
    public func add(element: Array<Byte>): Unit {
        for ((_, h) in hashers) {
            let pos = h(element).toInt() % size
            let arrayIndex = pos / 64
            let bitIndex = pos % 64
            let mask = 1 << bitIndex
            bitSet[arrayIndex].fetchOr(mask.toUInt())
        }
    }
    public func add(element: String): Unit {
        add(element.unsafeBytes())
    }
    public func add(element: ToString): Unit {
        add(element.toString().unsafeBytes())
    }
    public func add(element: Hashable): Unit {
        add(hashableToBytes(element))
    }
    private func hashableToBytes(element: Hashable): Array<Byte> {
        let h = element.hashCode()
        return Array<Byte>(8){i => UInt8((h >> ((7 - i) * 8)).toUInt())}
    }
    /**
     * 查询元素 (无锁并发安全)
     */
    public func mightContain(element: Array<Byte>): Bool {
        for ((_, h) in hashers) {
            let pos = h(element).toInt() % size
            let arrayIndex = pos / 64
            let bitIndex = pos % 64
            let mask = 1 << bitIndex
            let value = bitSet[arrayIndex].load()
            if ((value & mask.toUInt()) == 0) {
                return false
            }
        }
        return true
    }
    public func mightContain(element: String): Bool {
        return mightContain(element.unsafeBytes())
    }
    public func mightContain(element: Hashable): Bool {
        return mightContain(hashableToBytes(element))
    }
    public func mightContain(element: ToString): Bool {
        return mightContain(element.toString().unsafeBytes())
    }
}