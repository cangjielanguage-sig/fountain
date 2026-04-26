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

import std.io.{IOStream, SeekPosition}
import std.fs.{File, OpenMode, Path, Directory, FileInfo, exists}
import std.sync.AtomicBool
import std.collection.ArrayList
import std.binary.*
import std.sort.*
import std.convert.*
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
    private let path: String
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
        this.path = path
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
            sequenceStart, sequenceEnd, path
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

// ==== SSTableReader =============================================================

/** SSTable 读取器。
 *  使用 std.fs.File 同步读取（seek + read）。
 *  open 时加载 Footer → Index Block → Bloom Filter Block。
 *  get 时先查 BloomFilter → 二分定位 Data Block → 读取扫描。
 */
class SSTableReader {
    let metadata: SSTableMetadata
    let bloomFilter: BloomFilter
    let indexEntries: ArrayList<IndexEntry>
    private let file: File
    private let indexOffset: Int64 // Index Block 起始偏移（即 Data Block 终止边界）

    private init(metadata: SSTableMetadata, bloomFilter: BloomFilter,
                 indexEntries: ArrayList<IndexEntry>, file: File, indexOffset: Int64) {
        this.metadata = metadata
        this.bloomFilter = bloomFilter
        this.indexEntries = indexEntries
        this.file = file
        this.indexOffset = indexOffset
    }

    /** 打开 SSTable 文件并加载元数据/索引/BloomFilter */
    static func open(path: String): SSTableReader {
        let file = File(path, OpenMode.Read)
        return openFromFile(file, path)
    }

    static func openFromFile(file: File, path: String): SSTableReader {
        let fileLen = file.length
        if (fileLen < SSTableWriter.FOOTER_SIZE) {
            throw Exception("SSTable file too small: " + path)
        }
        // 1. 读取 Footer (最后 48 bytes)
        let footerBuf = Array<Byte>(SSTableWriter.FOOTER_SIZE, repeat: 0u8)
        file.seek(SeekPosition.Begin(fileLen - SSTableWriter.FOOTER_SIZE))
        file.read(footerBuf)
        let idxOff = readInt64LE(footerBuf, 0)
        let idxSz = readInt64LE(footerBuf, 8)
        let bloomOff = readInt64LE(footerBuf, 16)
        let bloomSz = readInt64LE(footerBuf, 24)
        let eCount = readInt64LE(footerBuf, 32)
        let magic = readUInt64LE(footerBuf, 40)
        if (magic != SSTableWriter.MAGIC) {
            throw Exception("SSTable magic mismatch: " + path)
        }
        // 2. 读取 Index Block
        let indexBuf = Array<Byte>(idxSz, repeat: 0u8)
        file.seek(SeekPosition.Begin(idxOff))
        file.read(indexBuf)
        let indexEntries = ArrayList<IndexEntry>()
        var offset = 0
        let count = readInt64LE(indexBuf, offset)
        offset += 8
        for (_ in 0..count) {
            let entryOff = readInt64LE(indexBuf, offset)
            offset += 8
            let keyLen = readInt64LE(indexBuf, offset)
            offset += 8
            let keyBytes = Array<Byte>(keyLen, repeat: 0u8)
            for (i in 0..keyLen) {
                keyBytes[i] = indexBuf[offset]
                offset++
            }
            indexEntries.add(IndexEntry(entryOff, ByteArray(keyBytes)))
        }
        // 3. 读取 Bloom Filter Block
        let bloomBuf = Array<Byte>(bloomSz, repeat: 0u8)
        file.seek(SeekPosition.Begin(bloomOff))
        file.read(bloomBuf)
        let n = readInt64LE(bloomBuf, 0)
        // Float64 占据 bloomBuf[1..9] (8 bytes)，手动重建 Array<Byte>
        let pBuf = Array<Byte>(8){i => bloomBuf[8+i]}
        let p = Float64.readLittleEndian(pBuf)
        let seedCount = readInt64LE(bloomBuf, 16)
        let seeds = Array<UInt64>(seedCount, repeat: 0u64)
        var boff = 24
        for (i in 0..seedCount) {
            seeds[i] = readUInt64LE(bloomBuf, boff)
            boff += 8
        }
        let bitCount = readInt64LE(bloomBuf, boff)
        boff += 8
        // 重建 BloomFilter（seed 驱动，bitset 以 0 初始化，需遍历 Data Block 重新填充）
        let filter = BloomFilter.new(n, p, seeds.clone())
        // 遍历所有 Data Block，将 key 重新 add 到 bloom filter
        for (i in 0..indexEntries.size) {
            let blockStart = indexEntries[i].offset
            let blockEnd = if (i + 1 < indexEntries.size) {
                indexEntries[i + 1].offset
            } else {
                idxOff
            }
            let blockSize = blockEnd - blockStart
            let blockBuf = Array<Byte>(blockSize, repeat: 0u8)
            file.seek(SeekPosition.Begin(blockStart))
            file.read(blockBuf)
            var off = 0
            while (off + 32 <= blockSize) {
                let keyLen = readInt64LE(blockBuf, off)
                let valueLen = readInt64LE(blockBuf, off + 8)
                let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
                if (off + 32 + keyLen + actualValueLen > blockSize) { break }
                let kBuf = Array<Byte>(keyLen, repeat: 0u8)
                for (i in 0..keyLen) {
                    kBuf[i] = blockBuf[off + 32 + i]
                }
                filter.add(kBuf)
                off += 32 + keyLen + actualValueLen
            }
        }
        // 4. 重建 metadata
        let firstKey = if (indexEntries.size > 0) { indexEntries[0].firstKey } else { ByteArray([]) }
        let lastIdx = indexEntries.size - 1
        let lastKey = if (lastIdx >= 0) { indexEntries[lastIdx].firstKey } else { ByteArray([]) }
        let metadata = SSTableMetadata(
            firstKey, lastKey, eCount, 0, 0, Int64.Max, path
        )
        SSTableReader(metadata, filter, indexEntries, file, idxOff)
    }

    /** 点查询 */
    func get(key: ByteArray): ?EntryValue {
        let keyBytes = key.bytes
        // Bloom 快速否定
        if (!bloomFilter.mightContain(keyBytes)) {
            return None
        }
        // 二分查找定位 Data Block
        let idx = binarySearchIndex(key)
        if (idx < 0) {
            return None
        }
        // 读取 Data Block
        let blockStart = indexEntries[idx].offset
        let blockEnd = if (idx + 1 < indexEntries.size) {
            indexEntries[idx + 1].offset
        } else {
            indexOffset
        }
        let blockSize = blockEnd - blockStart
        return scanDataBlock(blockStart, blockSize, keyBytes)
    }

    /** 二分查找：返回 key 应落在的 Data Block 索引（-1 表示所有 key 都大于该 key） */
    private func binarySearchIndex(key: ByteArray): Int64 {
        let n = indexEntries.size
        if (n == 0) {
            return -1
        }
        // 如果 key < 第一个 Data Block 的 firstKey
        if (key < indexEntries[0].firstKey) {
            return -1
        }
        var lo = 0
        var hi = n - 1
        while (lo < hi) {
            let mid = lo + (hi - lo + 1) / 2
            if (indexEntries[mid].firstKey <= key) {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        lo
    }

    /** 在 Data Block 中扫描查找 key */
    private func scanDataBlock(blockStart: Int64, blockSize: Int64, targetKey: Array<Byte>): ?EntryValue {
        let buf = Array<Byte>(blockSize, repeat: 0u8)
        file.seek(SeekPosition.Begin(blockStart))
        file.read(buf)
        var offset = 0
        while (offset + 32 <= blockSize) {
            let keyLen = readInt64LE(buf, offset)
            let valueLen = readInt64LE(buf, offset + 8)
            let seq = readInt64LE(buf, offset + 16)
            let expireAt = readInt64LE(buf, offset + 24)
            let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
            if (offset + 32 + keyLen + actualValueLen > blockSize) {
                break
            }
            offset += 32
            // 提取 key
            let kBuf = Array<Byte>(keyLen, repeat: 0u8)
            for (i in 0..keyLen) {
                kBuf[i] = buf[offset]
                offset++
            }
            // 提取 value
            let val = if (valueLen < 0) {
                None<Array<Byte>>
            } else {
                let vBuf = Array<Byte>(valueLen, repeat: 0u8)
                for (i in 0..valueLen) {
                    vBuf[i] = buf[offset]
                    offset++
                }
                Some(vBuf)
            }
            let exp = if (expireAt == 0) { None<Int64> } else { Some(expireAt) }
            if (kBuf == targetKey) {
                return EntryValue(val, seq, expireAt: exp)
            }
        }
        None
    }

    /** 全量有序遍历 */
    func iterator(): Iterator<(ByteArray, EntryValue)> {
        SSTableIterator(file, indexEntries, indexOffset, None)
    }

    /** 从 min key 开始遍历 */
    func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)> {
        SSTableIterator(file, indexEntries, indexOffset, min)
    }

    /** 关闭 */
    func close(): Unit {
        if (!file.isClosed()) {
            file.close()
        }
    }
}

/** SSTable 全量/前缀遍历器 */
class SSTableIterator <: Iterator<(ByteArray, EntryValue)> {
    private let file: File
    private let indexEntries: ArrayList<IndexEntry>
    private let indexOffset: Int64
    private var blockIdx: Int64
    private var blockData: Array<Byte>
    private var offsetInBlock: Int64
    private var done: Bool

    let startKey: ?ByteArray

    init(file: File, indexEntries: ArrayList<IndexEntry>, indexOffset: Int64, startKey: ?ByteArray) {
        this.file = file
        this.indexEntries = indexEntries
        this.indexOffset = indexOffset
        this.startKey = startKey
        this.blockIdx = if (let Some(key) <- startKey) {
            // 定位起始 Data Block
            let n = indexEntries.size
            if (n == 0) {
                0
            } else {
                var lo = 0
                var hi = n - 1
                while (lo < hi) {
                    let mid = lo + (hi - lo + 1) / 2
                    if (indexEntries[mid].firstKey <= key) {
                        lo = mid
                    } else {
                        hi = mid - 1
                    }
                }
                if (lo < n && indexEntries[lo].firstKey <= key) {
                    lo
                } else {
                    0
                }
            }
        } else {
            0
        }
        this.blockData = Array<Byte>(0, repeat: 0u8)
        this.offsetInBlock = 0
        this.done = false
        loadBlock()
        // 跳过 startKey 之前的条目
        if (let Some(sk) <- startKey) {
            skipBefore(sk)
        }
    }

    /** 跳过所有 key < startKey 的条目 */
    private func skipBefore(startKey: ByteArray): Unit {
        while (true) {
            if (done) { return }
            if (offsetInBlock + 32 > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return
                }
                loadBlock()
                continue
            }
            let keyLen = readInt64LE(blockData, offsetInBlock)
            let valueLen = readInt64LE(blockData, offsetInBlock + 8)
            let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
            if (offsetInBlock + 32 + keyLen + actualValueLen > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return
                }
                loadBlock()
                continue
            }
            // 提取 key 比较
            var off = offsetInBlock + 32
            let kBuf = Array<Byte>(keyLen, repeat: 0u8)
            for (i in 0..keyLen) {
                kBuf[i] = blockData[off]
                off++
            }
            let k = ByteArray(kBuf)
            if (k >= startKey) {
                return // 找到起始位置
            }
            // 跳过此条目
            offsetInBlock = offsetInBlock + 32 + keyLen + actualValueLen
        }
    }

    public func next(): Option<(ByteArray, EntryValue)> {
        if (done) {
            return None
        }
        while (true) {
            if (offsetInBlock + 32 > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return None
                }
                loadBlock()
                continue
            }
            let keyLen = readInt64LE(blockData, offsetInBlock)
            let valueLen = readInt64LE(blockData, offsetInBlock + 8)
            let seq = readInt64LE(blockData, offsetInBlock + 16)
            let expireAt = readInt64LE(blockData, offsetInBlock + 24)
            let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
            if (offsetInBlock + 32 + keyLen + actualValueLen > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return None
                }
                loadBlock()
                continue
            }
            var off = offsetInBlock + 32
            let kBuf = Array<Byte>(keyLen, repeat: 0u8)
            for (i in 0..keyLen) {
                kBuf[i] = blockData[off]
                off++
            }
            let val = if (valueLen < 0) {
                None<Array<Byte>>
            } else {
                let vBuf = Array<Byte>(valueLen, repeat: 0u8)
                for (i in 0..valueLen) {
                    vBuf[i] = blockData[off]
                    off++
                }
                Some(vBuf)
            }
            let exp = if (expireAt == 0) { None<Int64> } else { Some(expireAt) }
            offsetInBlock = off
            let entry = EntryValue(val, seq, expireAt: exp)
            let pair: (ByteArray, EntryValue) = (ByteArray(kBuf), entry)
            return Some(pair)
        }
        None
    }

    private func loadBlock(): Unit {
        let blockStart = indexEntries[blockIdx].offset
        let blockEnd = if (blockIdx + 1 < indexEntries.size) {
            indexEntries[blockIdx + 1].offset
        } else {
            indexOffset
        }
        let blockSize = blockEnd - blockStart
        blockData = Array<Byte>(blockSize, repeat: 0u8)
        file.seek(SeekPosition.Begin(blockStart))
        file.read(blockData)
        offsetInBlock = 0
    }
}

// ==== SSTableFile — SSTable 文件管理 ===========================================

/** SSTable 文件句柄，持有 Reader + 元数据便捷访问。
 *  文件命名规则: L{level}_{sequenceStart}_{sequenceEnd}.sst
 */
class SSTableFile <: Resource {
    let reader: SSTableReader
    let metadata: SSTableMetadata
    let bloomFilter: BloomFilter
    private let closed: AtomicBool

    init(reader: SSTableReader) {
        this.reader = reader
        this.metadata = reader.metadata
        this.bloomFilter = reader.bloomFilter
        this.closed = AtomicBool(false)
    }

    /** 查询 key */
    func get(key: ByteArray): ?EntryValue {
        if (closed.load()) {
            throw StoreClosedException()
        }
        reader.get(key)
    }

    /** 全量有序遍历 */
    func iterator(): Iterator<(ByteArray, EntryValue)> {
        reader.iterator()
    }

    /** 从 min key 开始遍历 */
    func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)> {
        reader.tailer(min)
    }

    /** 关闭 */
    public func close(): Unit {
        if (closed.compareAndSwap(false, true)) {
            reader.close()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    /** 从文件路径打开 SSTableFile */
    static func open(path: String): SSTableFile {
        let reader = SSTableReader.open(path)
        SSTableFile(reader)
    }

    /** 扫描目录，加载所有 .sst 文件 */
    static func loadAll(sstDir: String): ArrayList<SSTableFile> {
        let result = ArrayList<SSTableFile>()
        if (!exists(sstDir)) {
            return result
        }
        let sstFiles = ArrayList<String>()
        Directory.walk(sstDir) { fi: FileInfo =>
            if (fi.path.extensionName == "sst" && !fi.isDirectory()) {
                sstFiles.add(fi.path.toString())
            }
            true
        }
        sort(sstFiles)
        for (path in sstFiles) {
            try {
                result.add(open(path))
            } catch (_: Exception) {
                // 不符合命名规则或损坏的文件跳过
            }
        }
        result
    }

    /** 解析文件名提取 level 和 sequence 范围。
     *  文件名格式: L{level}_{seqStart}_{seqEnd}.sst
     *  返回 (level, seqStart, seqEnd) 或 None
     */
    static func parseFileName(fileName: String): ?(Int64, Int64, Int64) {
        // 去掉 .sst 后缀
        let name = if (fileName.endsWith(".sst")) {
            fileName[0 .. (fileName.size - 4)]
        } else {
            fileName
        }
        // 期望格式: L{level}_{seqStart}_{seqEnd}
        if (!name.startsWith("L")) {
            return None
        }
        let rest = name[1 .. name.size]
        let parts = rest.split("_")
        if (parts.size != 3) {
            return None
        }
        try {
            let level = Int64.parse(parts[0])
            let seqStart = Int64.parse(parts[1])
            let seqEnd = Int64.parse(parts[2])
            let result: (Int64, Int64, Int64) = (level, seqStart, seqEnd)
            return Some(result)
        } catch (_: Exception) {
            return None
        }
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
