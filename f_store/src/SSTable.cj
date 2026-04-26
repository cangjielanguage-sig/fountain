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
package fountain::f_store

import std.io.IOStream
import std.fs.{File, OpenMode, Path, Directory, exists}
import std.sync.AtomicBool
import std.collection.ArrayList
import std.binary.*
import fountain::f_bloom.BloomFilter
import fountain::f_base.*
import fountain::f_io.IOUringStream

/** SSTable 元数据 */
class SSTableMetadata {
    let minKey: ByteArray
    let maxKey: ByteArray
    let entryCount: Int64
    let level: Int64
    let sequenceStart: Int64
    let sequenceEnd: Int64
    let filePath: String

    init(minKey: ByteArray, maxKey: ByteArray, entryCount: Int64, level: Int64,
         sequenceStart: Int64, sequenceEnd: Int64, filePath: String) {
        this.minKey = minKey
        this.maxKey = maxKey
        this.entryCount = entryCount
        this.level = level
        this.sequenceStart = sequenceStart
        this.sequenceEnd = sequenceEnd
        this.filePath = filePath
    }
}

/** Data Block 索引条目 */
struct IndexEntry {
    let offset: Int64
    let firstKey: ByteArray

    init(offset: Int64, firstKey: ByteArray) {
        this.offset = offset
        this.firstKey = firstKey
    }
}

/** SSTable 写入器。
 *  文件格式:
 *  [Data Block 1][Data Block 2]...[Data Block N]
 *  [Index Block]
 *  [Bloom Filter Block]
 *  [Footer: 48 bytes]
 *
 *  Data Block 记录编码（小端序）:
 *    key_len(8) + value_len(8) + sequence(8) + expire_at(8) + key_bytes + value_bytes
 *    value_len = -1 表示 tombstone
 *    expire_at = 0 表示永不过期
 *
 *  Index Block:
 *    index_count(8) + [offset(8) + first_key_len(8) + first_key_bytes]...
 *
 *  Bloom Filter Block:
 *    n(8) + p(8 bytes float64) + seed_count(8) + [seed(8)]... + bit_count(8) + [bits(8)]...
 *
 *  Footer (48 bytes):
 *    index_offset(8) + index_size(8) + bloom_offset(8) + bloom_size(8) + entry_count(8) + magic(8)
 *    magic = 0x53545354 ("STST" in ASCII)
 */
class SSTableWriter {
    private let file: File
    private let stream: IOStream
    private let bloomFilter: BloomFilter
    let indexEntries: ArrayList<IndexEntry>
    var currentOffset: Int64
    var entryCount: Int64
    var fileSize: Int64
    var dataBlockSize: Int64
    let dataBlockSizeThreshold: Int64
    var firstKeyOfBlock: ?ByteArray
    var minKey: ?ByteArray
    var maxKey: ?ByteArray
    var sequenceStart: Int64
    var sequenceEnd: Int64
    let closed: AtomicBool

    static let MAX_SSTABLE_SIZE: Int64 = 64 * 1024 * 1024 // 64MB
    static let FOOTER_SIZE: Int64 = 48
    static let MAGIC: UInt64 = 0x53545354u64

    init(path: String, estimatedCount: Int64) {
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.file = File(path, OpenMode.ReadWrite)
        @When[os == "Linux"]
        let s = IOUringStream(Int32(file.fileDescriptor.fileHandle))
        @When[os != "Linux"]
        let s: IOStream = file
        this.stream = s
        this.bloomFilter = BloomFilter.new(estimatedCount, 0.01)
        this.indexEntries = ArrayList<IndexEntry>()
        this.currentOffset = 0
        this.entryCount = 0
        this.fileSize = 0
        this.dataBlockSize = 0
        this.dataBlockSizeThreshold = 4096 // 4KB
        this.firstKeyOfBlock = None
        this.minKey = None
        this.maxKey = None
        this.sequenceStart = Int64.Max
        this.sequenceEnd = Int64.Min
        this.closed = AtomicBool(false)
    }

    /** 写入一条记录 */
    func write(key: ByteArray, entry: EntryValue): Unit {
        if (closed.load()) {
            throw StoreClosedException()
        }
        // 新 Data Block 开始，记录 IndexEntry
        if (dataBlockSize == 0) {
            indexEntries.add(IndexEntry(currentOffset, key))
            firstKeyOfBlock = key
        }
        // 编码记录: key_len(8) + value_len(8) + sequence(8) + expire_at(8) + key_bytes + value_bytes
        let keyBytes = key.bytes
        let keyLen = keyBytes.size
        let valueLen = if (let Some(v) <- entry.value) { v.size } else { -1 }
        let expireAtVal = if (let Some(ea) <- entry.expireAt) { ea } else { 0 }
        let headerLen = 32
        let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
        let recordLen = headerLen + keyLen + actualValueLen
        let buf = Array<Byte>(recordLen, repeat: 0u8)
        var offset = 0
        // key_len
        offset = writeInt64LE(buf, offset, Int64(keyLen))
        // value_len (-1 = tombstone)
        offset = writeInt64LE(buf, offset, Int64(valueLen))
        // sequence
        offset = writeInt64LE(buf, offset, entry.sequence)
        // expire_at (0 = never)
        offset = writeInt64LE(buf, offset, expireAtVal)
        // key_bytes
        for (i in 0..keyLen) {
            buf[offset] = keyBytes[i]
            offset++
        }
        // value_bytes
        if (let Some(v) <- entry.value) {
            for (i in 0..valueLen) {
                buf[offset] = v[i]
                offset++
            }
        }
        stream.write(buf)
        // bloom filter
        bloomFilter.add(keyBytes)
        // 更新统计
        currentOffset += recordLen
        fileSize += recordLen
        dataBlockSize += recordLen
        entryCount++
        // 更新 min/max key
        if (minKey.isNone()) {
            minKey = key
        }
        maxKey = key
        // 更新 sequence range
        if (entry.sequence < sequenceStart) {
            sequenceStart = entry.sequence
        }
        if (entry.sequence > sequenceEnd) {
            sequenceEnd = entry.sequence
        }
        // Data Block 阈值检查
        if (dataBlockSize >= dataBlockSizeThreshold) {
            dataBlockSize = 0
        }
    }

    /** 写完 Index + Bloom + Footer，flush，关闭 */
    func finish(): SSTableMetadata {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let indexOffset = currentOffset
        // 写 Index Block
        let indexSize = writeIndexBlock()
        // 写 Bloom Filter Block
        let bloomOffset = currentOffset
        let bloomSize = writeBloomFilterBlock()
        // 写 Footer
        writeFooter(indexOffset, indexSize, bloomOffset, bloomSize)
        // flush
        stream.flush()
        // 关闭
        closed.compareAndSwap(false, true)
        if (let r: Resource <- stream && !r.isClosed()) {
            r.close()
        }
        if (let r: Resource <- file && !r.isClosed()) {
            r.close()
        }
        // 构造 metadata
        let actualMinKey = minKey ?? ByteArray([])
        let actualMaxKey = maxKey ?? ByteArray([])
        SSTableMetadata(
            actualMinKey, actualMaxKey, entryCount, 0,
            sequenceStart, sequenceEnd, ""
        )
    }

    /** SSTable 是否已满（64MB） */
    func isFull(): Bool {
        fileSize >= MAX_SSTABLE_SIZE
    }

    /** 写 Index Block: index_count(8) + [offset(8) + first_key_len(8) + first_key_bytes]... */
    private func writeIndexBlock(): Int64 {
        let count = indexEntries.size
        // 预估大小
        var totalSize = 8 // count
        for (entry in indexEntries) {
            totalSize += 8 + 8 + entry.firstKey.bytes.size
        }
        let buf = Array<Byte>(totalSize, repeat: 0u8)
        var offset = 0
        offset = writeInt64LE(buf, offset, Int64(count))
        for (entry in indexEntries) {
            offset = writeInt64LE(buf, offset, entry.offset)
            offset = writeInt64LE(buf, offset, Int64(entry.firstKey.bytes.size))
            for (b in entry.firstKey.bytes) {
                buf[offset] = b
                offset++
            }
        }
        stream.write(buf)
        currentOffset += totalSize
        fileSize += totalSize
        Int64(totalSize)
    }

    /** 写 Bloom Filter Block:
     *  n(8) + p(8 bytes float64) + seed_count(8) + [seed(8)]... + bit_count(8) + [bits(8)]...
     */
    private func writeBloomFilterBlock(): Int64 {
        let n = bloomFilter.n
        let p = bloomFilter.p
        // 收集 seeds
        let seeds = ArrayList<UInt64>()
        for (seed in bloomFilter.seeds) {
            seeds.add(seed)
        }
        let seedCount = seeds.size
        // bitSet 大小
        let bitCount = bloomFilter.bitCount
        let bitSetWordCount = (bitCount + 63) / 64
        // 总大小: n(8) + p(8) + seed_count(8) + seeds + bit_count(8) + bits
        let totalSize = 8 + 8 + 8 + seedCount * 8 + 8 + bitSetWordCount * 8
        let buf = Array<Byte>(Int64(totalSize), repeat: 0u8)
        var offset = 0
        // n
        offset = writeInt64LE(buf, offset, n)
        // p (Float64 as 8 bytes LE)
        offset = writeFloat64LE(buf, offset, p)
        // seed_count
        offset = writeInt64LE(buf, offset, Int64(seedCount))
        // seeds
        for (seed in seeds) {
            offset = writeUInt64LE(buf, offset, seed)
        }
        // bit_count
        offset = writeInt64LE(buf, offset, bitCount)
        // bits - 需要从 bloomFilter 内部读取 bitSet
        // 使用反射方式读取 bitSet 不现实，改为遍历所有 Data Block 重建
        // 临时方案：将 bitSet 的位置先写零，open 时从 n/p/seeds 重建 BloomFilter 再遍历 Data Block 填充
        // 这里先写占位零
        for (_ in 0..bitSetWordCount) {
            offset = writeUInt64LE(buf, offset, 0u64)
        }
        stream.write(buf)
        currentOffset += Int64(totalSize)
        fileSize += Int64(totalSize)
        Int64(totalSize)
    }

    /** 写 Footer (48 bytes):
     *  index_offset(8) + index_size(8) + bloom_offset(8) + bloom_size(8) + entry_count(8) + magic(8)
     */
    private func writeFooter(indexOffset: Int64, indexSize: Int64, bloomOffset: Int64, bloomSize: Int64): Unit {
        let buf = Array<Byte>(FOOTER_SIZE, repeat: 0u8)
        var offset = 0
        offset = writeInt64LE(buf, offset, indexOffset)
        offset = writeInt64LE(buf, offset, indexSize)
        offset = writeInt64LE(buf, offset, bloomOffset)
        offset = writeInt64LE(buf, offset, bloomSize)
        offset = writeInt64LE(buf, offset, entryCount)
        offset = writeUInt64LE(buf, offset, MAGIC)
        stream.write(buf)
        currentOffset += FOOTER_SIZE
        fileSize += FOOTER_SIZE
    }
}

// === 小端序写入工具（SSTable 专用，复用 WAL 的 readInt64LE/readUInt32LE 等） ===

@OverflowWrapping
func writeUInt64LE(buf: Array<Byte>, offset: Int64, value: UInt64): Int64 {
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

func writeFloat64LE(buf: Array<Byte>, offset: Int64, value: Float64): Int64 {
    // 使用 std.binary.LittleEndianOrder<Float64> 扩展
    let tempBuf = Array<Byte>(8, repeat: 0u8)
    value.writeLittleEndian(tempBuf)
    for (i in 0..8) {
        buf[offset + i] = tempBuf[i]
    }
    offset + 8
}

func readUInt64LE(buf: Array<Byte>, offset: Int64): UInt64 {
    UInt64(buf[offset]) |
    (UInt64(buf[offset + 1]) << 8) |
    (UInt64(buf[offset + 2]) << 16) |
    (UInt64(buf[offset + 3]) << 24) |
    (UInt64(buf[offset + 4]) << 32) |
    (UInt64(buf[offset + 5]) << 40) |
    (UInt64(buf[offset + 6]) << 48) |
    (UInt64(buf[offset + 7]) << 56)
}

func readFloat64LE(buf: Array<Byte>, offset: Int64): Float64 {
    let tempBuf = Array<Byte>(8, repeat: 0u8)
    for (i in 0..8) {
        tempBuf[i] = buf[offset + i]
    }
    Float64.readLittleEndian(tempBuf)
}
