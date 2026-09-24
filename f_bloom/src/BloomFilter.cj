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

import std.binary.*
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
    public prop bitCount: Int64 {
        get() {
            size
        }
    }
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
            let pos = (h(element) % UInt64(size)).toInt()
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
            let pos = (h(element) % UInt64(size)).toInt()
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

    /** 序列化为字节数组。
     *  格式: n(8) + p(8) + seed_count(8) + [seed(8)]... + bit_count(8) + [bits(8)]...
     *  所有整数小端序，Float64 小端序。
     */
    public func serialize(): Array<Byte> {
        // 收集 seeds
        let seedsArr = ArrayList<UInt64>()
        for (seed in seeds) {
            seedsArr.add(seed)
        }
        let seedCount = seedsArr.size
        let bitCount = this.size
        let wordCount = (bitCount + 63) / 64

        // 总大小
        let totalSize = 8 + 8 + 8 + seedCount * 8 + 8 + wordCount * 8
        let buf = Array<Byte>(totalSize, repeat: 0u8)
        var offset = 0

        // n (Int64 LE)
        offset = writeInt64LE(buf, offset, n)
        // p (Float64 LE)
        offset = writeFloat64LE(buf, offset, p)
        // seed_count (Int64 LE)
        offset = writeInt64LE(buf, offset, Int64(seedCount))
        // seeds (UInt64 LE)
        for (seed in seedsArr) {
            offset = writeUInt64LE(buf, offset, seed)
        }
        // bit_count (Int64 LE)
        offset = writeInt64LE(buf, offset, bitCount)
        // bits — 原子读取每个 word
        for (i in 0..wordCount) {
            offset = writeUInt64LE(buf, offset, bitSet[i].load())
        }
        buf
    }

    /** 从字节数组反序列化。
     *  格式同 serialize()：n(8) + p(8) + seed_count(8) + [seed(8)]... + bit_count(8) + [bits(8)]...
     */
    public static func deserialize(bytes: Array<Byte>): BloomFilter {
        if (bytes.size < 24) {
            return BloomFilter.new(1, 0.01) // 最小默认
        }
        let n = readInt64LE(bytes, 0)
        let pBuf = Array<Byte>(8){i => bytes[8 + i]}
        let p = Float64.readLittleEndian(pBuf)
        let seedCount = readInt64LE(bytes, 16)
        let seeds = Array<UInt64>(seedCount, repeat: 0u64)
        var off = 24
        for (i in 0..seedCount) {
            seeds[i] = readUInt64LE(bytes, off)
            off += 8
        }
        let bitCount = readInt64LE(bytes, off)
        off += 8
        let wordCount = (bitCount + 63) / 64

        if (off + wordCount * 8 > bytes.size) {
            return BloomFilter.new(1, 0.01) // 数据不完整
        }

        // 构造 BloomFilter 并直接填充 bitSet
        let filter = BloomFilter.new(n, p, seeds)
        for (i in 0..wordCount) {
            let word = readUInt64LE(bytes, off)
            off += 8
            filter.bitSet[i].store(word)
        }
        filter
    }

    // === 小端序写工具（BloomFilter内部使用） ===

    @OverflowWrapping
    private static func writeInt64LE(buf: Array<Byte>, offset: Int64, value: Int64): Int64 {
        let uv = value.toUInt()
        buf[offset] = UInt8(uv & 0xFFu64)
        buf[offset + 1] = UInt8((uv >> 8) & 0xFFu64)
        buf[offset + 2] = UInt8((uv >> 16) & 0xFFu64)
        buf[offset + 3] = UInt8((uv >> 24) & 0xFFu64)
        buf[offset + 4] = UInt8((uv >> 32) & 0xFFu64)
        buf[offset + 5] = UInt8((uv >> 40) & 0xFFu64)
        buf[offset + 6] = UInt8((uv >> 48) & 0xFFu64)
        buf[offset + 7] = UInt8((uv >> 56) & 0xFFu64)
        offset + 8
    }

    @OverflowWrapping
    private static func writeUInt64LE(buf: Array<Byte>, offset: Int64, value: UInt64): Int64 {
        buf[offset] = UInt8(value & 0xFFu64)
        buf[offset + 1] = UInt8((value >> 8) & 0xFFu64)
        buf[offset + 2] = UInt8((value >> 16) & 0xFFu64)
        buf[offset + 3] = UInt8((value >> 24) & 0xFFu64)
        buf[offset + 4] = UInt8((value >> 32) & 0xFFu64)
        buf[offset + 5] = UInt8((value >> 40) & 0xFFu64)
        buf[offset + 6] = UInt8((value >> 48) & 0xFFu64)
        buf[offset + 7] = UInt8((value >> 56) & 0xFFu64)
        offset + 8
    }

    private static func writeFloat64LE(buf: Array<Byte>, offset: Int64, value: Float64): Int64 {
        let tempBuf = Array<Byte>(8, repeat: 0u8)
        value.writeLittleEndian(tempBuf)
        for (i in 0..8) {
            buf[offset + i] = tempBuf[i]
        }
        offset + 8
    }

    @OverflowWrapping
    private static func readInt64LE(buf: Array<Byte>, offset: Int64): Int64 {
        let v = (UInt64(buf[offset])) |
        (UInt64(buf[offset + 1]) << 8) |
        (UInt64(buf[offset + 2]) << 16) |
        (UInt64(buf[offset + 3]) << 24) |
        (UInt64(buf[offset + 4]) << 32) |
        (UInt64(buf[offset + 5]) << 40) |
        (UInt64(buf[offset + 6]) << 48) |
        (UInt64(buf[offset + 7]) << 56)
        v.toInt()
    }

    @OverflowWrapping
    private static func readUInt64LE(buf: Array<Byte>, offset: Int64): UInt64 {
        UInt64(buf[offset]) |
        (UInt64(buf[offset + 1]) << 8) |
        (UInt64(buf[offset + 2]) << 16) |
        (UInt64(buf[offset + 3]) << 24) |
        (UInt64(buf[offset + 4]) << 32) |
        (UInt64(buf[offset + 5]) << 40) |
        (UInt64(buf[offset + 6]) << 48) |
        (UInt64(buf[offset + 7]) << 56)
    }
}