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

/**
 * SSTable — 合并了写入和读取功能的 SSTable 文件句柄。
 *
 * 文件格式:
 * [Data Block 1][Data Block 2]...[Data Block N]
 * [Index Block]
 * [Bloom Filter Block]
 * [Footer: 48 bytes]
 *
 * Data Block 记录编码（小端序）:
 *   key_len(8) + value_len(8) + sequence(8) + expire_at(8) + key_bytes + value_bytes
 *   value_len = -1 表示 tombstone
 *   expire_at = 0 表示永不过期
 *
 * Index Block:
 *   index_count(8) + [offset(8) + first_key_len(8) + first_key_bytes]...
 *
 * Bloom Filter Block:
 *   n(8) + p(8 bytes float64) + seed_count(8) + [seed(8)]... + bit_count(8) + [bits(8)]...
 *
 * Footer (64 bytes):
 *   index_offset(8) + index_size(8) + bloom_offset(8) + bloom_size(8)
 *   + entry_count(8) + magic(8) + sequence_start(8) + sequence_end(8)
 *   magic = 0x53545354 ("STST" in ASCII)
 *
 * 生命周期:
 *   构造(Writing) → write → finishWrite(Readable) → get/iterator/tailer → close(Closed)
 *   或
 *   SSTable.open(path)(Readable) → get/iterator/tailer → close(Closed)
 */
class SSTable <: Resource {
    private let path: String
    private let file: File

    // === 写入模式字段 ===
    private let bloomFilter: BloomFilter
    private let indexEntries: ArrayList<IndexEntry>
    private var currentOffset: Int64
    private var entryCount: Int64
    private var fileSize: Int64
    private var dataBlockSize: Int64
    private let dataBlockSizeThreshold: Int64
    private var firstKeyOfBlock: ?ByteArray
    private var minKey: ?ByteArray
    private var maxKey: ?ByteArray
    private var sequenceStart: Int64
    private var sequenceEnd: Int64

    // === 读取模式字段 ===
    private var metadata: ?SSTableMetadata
    private var indexOffset: Int64  // Index Block 起始偏移（即 Data Block 终止边界）

    // === 状态管理 ===
    private let state: AtomicInt64
    private let closed: AtomicBool

    // 状态常量（AtomicInt64 替代 AtomicReference，因为 enum 是值类型）
    static const STATE_WRITING: Int64 = 0
    static const STATE_READABLE: Int64 = 1
    static const STATE_CLOSED: Int64 = 2

    /** 非 Linux: 保护 seek+read 原子性 */
    @When[os != "Linux"]
    private let getLock: Mutex = Mutex()
    /** Linux: fd 用于 pread 定位读取 */
    @When[os == "Linux"]
    private var fd: Int32 = 0

    static let MAX_SSTABLE_SIZE: Int64 = 64 * 1024 * 1024 // 64MB
    // Footer: index_offset(8) + index_size(8) + bloom_offset(8) + bloom_size(8)
    //        + entry_count(8) + magic(8) + sequence_start(8) + sequence_end(8)
    static let FOOTER_SIZE: Int64 = 64
    static let MAGIC: UInt64 = 0x53545354u64

    /** 写入模式构造：创建新 SSTable 文件 */
    init(path: String, estimatedCount: Int64) {
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.path = path
        this.file = File(path, OpenMode.ReadWrite)
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
        this.metadata = None
        this.indexOffset = 0
        this.state = AtomicInt64(STATE_WRITING)
        this.closed = AtomicBool(false)
        @When[os == "Linux"]
        let _ = (this.fd = Int32(this.file.fileDescriptor.fileHandle))
    }

    /** 读取模式构造：从已有文件打开（内部使用） */
    private init(path: String, file: File, bloomFilter: BloomFilter,
                 indexEntries: ArrayList<IndexEntry>, metadata: SSTableMetadata, indexOffset: Int64) {
        this.path = path
        this.file = file
        this.bloomFilter = bloomFilter
        this.indexEntries = indexEntries
        this.currentOffset = 0
        this.entryCount = metadata.entryCount
        this.fileSize = 0
        this.dataBlockSize = 0
        this.dataBlockSizeThreshold = 4096
        this.firstKeyOfBlock = None
        this.minKey = Some(metadata.minKey)
        this.maxKey = Some(metadata.maxKey)
        this.sequenceStart = metadata.sequenceStart
        this.sequenceEnd = metadata.sequenceEnd
        this.metadata = Some(metadata)
        this.indexOffset = indexOffset
        this.state = AtomicInt64(STATE_READABLE)
        this.closed = AtomicBool(false)
        @When[os == "Linux"]
        let _ = {=>
            this.fd = Int32(file.fileDescriptor.fileHandle)
        }()
    }

    // ================================================================
    // 写入模式 API
    // ================================================================

    /** 写入一条记录。仅在 Writing 状态下可用 */
    func write(key: ByteArray, entry: EntryValue): Unit {
        guardWriting()
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
        file.write(buf)
        // bloom filter
        bloomFilter.add(keyBytes)
        // 更新统计
        currentOffset += recordLen
        fileSize += recordLen
        dataBlockSize += recordLen
        entryCount++
        // 验证写入有序性（语法检查，开销可忽略）
        if (let Some(lastKey) <- maxKey) {
            if (key < lastKey) {
                throw Exception("SSTable write out of order")
            }
        }
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

    /** 写完 Index + Bloom + Footer，flush，切换到 Readable 状态。
     *  flush 后数据在 OS page cache 中，对新 File 句柄可见。
     *  返回 SSTableMetadata。
     */
    func finishWrite(level!: Int64 = 0): SSTableMetadata {
        guardWriting()
        let indexOffset = currentOffset
        // 写 Index Block
        let indexSize = writeIndexBlock()
        // 写 Bloom Filter Block
        let bloomOffset = currentOffset
        let bloomSize = writeBloomFilterBlock()
        // 写 Footer
        writeFooter(indexOffset, indexSize, bloomOffset, bloomSize)
        // flush（File.flush 确保数据落盘）
        file.flush()
        // 构造 metadata
        let actualMinKey = minKey ?? ByteArray([])
        let actualMaxKey = maxKey ?? ByteArray([])
        let meta = SSTableMetadata(
            actualMinKey, actualMaxKey, entryCount, level,
            sequenceStart, sequenceEnd, path, fileSize: this.fileSize
        )
        this.metadata = Some(meta)
        this.indexOffset = indexOffset
        // 切换到读取模式
        state.store(STATE_READABLE)
        meta
    }

    /** SSTable 是否已满（64MB）。仅在 Writing 状态下可用 */
    func isFull(): Bool {
        guardWriting()
        fileSize >= MAX_SSTABLE_SIZE
    }

    /** 当前写入的记录数。仅在 Writing 状态下可用 */
    func getEntryCount(): Int64 {
        entryCount
    }

    // ================================================================
    // 读取模式 API
    // ================================================================

    /** 获取元数据。Readable 状态下可用 */
    func getMetadata(): SSTableMetadata {
        guardReadable()
        metadata ?? SSTableMetadata(ByteArray([]), ByteArray([]), 0, 0, 0, 0, path)
    }

    /** 获取 BloomFilter。Readable 状态下可用 */
    func getBloomFilter(): BloomFilter {
        guardReadable()
        bloomFilter
    }

    /** 点查询。Readable 状态下可用。
     *  Linux: 使用 pread（单 syscall 原子定位读取，无锁）
     *  非 Linux: 使用 seek+read（Mutex 保护并发安全） */
    func get(key: ByteArray): ?EntryValue {
        guardReadable()
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
        @When[os == "Linux"]
        let result = {=>
            let buf = Array<Byte>(blockSize, repeat: 0u8)
            let bufHdl = unsafe { acquireArrayRawData<Byte>(buf) }
            let readOk = try {
                positionedRead(fd, bufHdl.pointer, blockSize, blockStart)
            } finally {
                unsafe { releaseArrayRawData(bufHdl) }
            }
            let scanResult: ?EntryValue = if (readOk) {
                scanBuffer(buf, blockSize, keyBytes)
            } else {
                // pread 失败：可能是 compaction 关闭本 SSTable 后另一线程持有旧快照
                if (closed.load()) {
                    None
                } else {
                    throw Exception("SSTable I/O error: positionedRead failed")
                }
            }
            scanResult
        }()
        @When[os != "Linux"]
        let result = synchronized(getLock) {
            guardReadable()
            let buf = Array<Byte>(blockSize, repeat: 0u8)
            file.seek(SeekPosition.Begin(blockStart))
            file.read(buf)
            scanBuffer(buf, blockSize, keyBytes)
        }
        result
    }

    /** 全量有序遍历。Readable 状态下可用。每次调用打开独立的文件句柄以避免 seek/read 竞态。 */
    func iterator(): Iterator<(ByteArray, EntryValue)> {
        guardReadable()
        SSTableIterator(File(path, OpenMode.Read), indexEntries, indexOffset, None)
    }

    /** 从 min key 开始遍历。Readable 状态下可用。每次调用打开独立的文件句柄以避免 seek/read 竞态。 */
    func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)> {
        guardReadable()
        SSTableIterator(File(path, OpenMode.Read), indexEntries, indexOffset, min)
    }

    // ================================================================
    // 生命周期管理
    // ================================================================

    /** 从文件路径打开已有 SSTable，进入 Readable 状态 */
    static func open(path: String): SSTable {
        let file = File(path, OpenMode.Read)
        openFromFile(file, path)
    }

    static func openFromFile(file: File, path: String): SSTable {
        let fileLen = file.length
        if (fileLen < FOOTER_SIZE) {
            throw Exception("SSTable file too small: " + path)
        }
        // 1. 读取 Footer (最后 64 bytes)
        let footerBuf = Array<Byte>(FOOTER_SIZE, repeat: 0u8)
        file.seek(SeekPosition.Begin(fileLen - FOOTER_SIZE))
        file.read(footerBuf)
        let idxOff = readInt64LE(footerBuf, 0)
        let idxSz = readInt64LE(footerBuf, 8)
        let bloomOff = readInt64LE(footerBuf, 16)
        let _ = readInt64LE(footerBuf, 24) // bloomSz 暂不使用
        let eCount = readInt64LE(footerBuf, 32)
        let magic = readUInt64LE(footerBuf, 40)
        if (magic != MAGIC) {
            throw Exception("SSTable magic mismatch: " + path)
        }
        let seqStart = readInt64LE(footerBuf, 48)
        let seqEnd = readInt64LE(footerBuf, 56)
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
        let bloomBuf = Array<Byte>(readInt64LE(footerBuf, 24), repeat: 0u8)
        if (bloomBuf.size > 0) {
            file.seek(SeekPosition.Begin(bloomOff))
            file.read(bloomBuf)
        }
        let filter = if (bloomBuf.size > 0) {
            parseBloomFilter(bloomBuf)
        } else {
            BloomFilter.new(0, 0.01)
        }
        // 4. 重建 metadata
        let firstKey = if (indexEntries.size > 0) { indexEntries[0].firstKey } else { ByteArray([]) }
        let lastIdx = indexEntries.size - 1
        let lastKey = if (lastIdx >= 0) { indexEntries[lastIdx].firstKey } else { ByteArray([]) }
        // 从文件名 L{level}_{sstIndex}.sst 解析 level
        let actualLevel = parseLevelFromSSTablePath(path)
        let meta = SSTableMetadata(
            firstKey, lastKey, eCount, actualLevel, seqStart, seqEnd, path, fileSize: fileLen
        )
        SSTable(path, file, filter, indexEntries, meta, idxOff)
    }

    /** 扫描目录，加载所有 .sst 文件 */
    static func loadAll(sstDir: String): ArrayList<SSTable> {
        let result = ArrayList<SSTable>()
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

    /** 关闭 SSTable，释放所有资源 */
    public func close(): Unit {
        if (closed.compareAndSwap(false, true)) {
            state.store(STATE_CLOSED)
            // 非 Linux: 锁内关闭文件，防止新 get 进入后 read 已关闭文件
            @When[os != "Linux"]
            let _ = synchronized(getLock) {
                if (!file.isClosed()) {
                    file.close()
                }
            }
            // Linux: pread 内核级原子，直接关闭即可
            @When[os == "Linux"]
            let _ = {=>
                if (!file.isClosed()) {
                    file.close()
                }
            }()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    // ================================================================
    // 内部方法
    // ================================================================

    /** 检查 Writing 状态 */
    private func guardWriting(): Unit {
        if (state.load() != STATE_WRITING) {
            throw StoreClosedException()
        }
    }

    /** 检查 Readable 状态 */
    private func guardReadable(): Unit {
        if (state.load() != STATE_READABLE) {
            throw StoreClosedException()
        }
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

    /** 在已读取的 Data Block 缓冲区中扫描查找 key */
    private func scanBuffer(buf: Array<Byte>, blockSize: Int64, targetKey: Array<Byte>): ?EntryValue {
        var offset: Int64 = 0
        while (offset + 32 <= blockSize) {
            let keyLen = readInt64LE(buf, offset)
            let valueLen = readInt64LE(buf, offset + 8)
            let seq = readInt64LE(buf, offset + 16)
            let expireAt = readInt64LE(buf, offset + 24)
            // 帧校验：检测损坏/僵尸数据
            if (keyLen < 0 || keyLen > 1024 * 1024) {
                break
            }
            if (valueLen < -1) {
                break
            }
            if (seq < 0) {
                break
            }
            let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
            let headerEnd = offset + 32
            if (headerEnd > blockSize) {
                break
            }
            var remaining = blockSize - headerEnd
            if (keyLen > remaining) {
                break
            }
            remaining -= keyLen
            if (actualValueLen > remaining) {
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
        file.write(buf)
        currentOffset += totalSize
        fileSize += totalSize
        Int64(totalSize)
    }

    /** 写 Bloom Filter Block：使用 BloomFilter.serialize() 直接序列化 bitSet */
    private func writeBloomFilterBlock(): Int64 {
        let buf = bloomFilter.serialize()
        file.write(buf)
        let totalSize = Int64(buf.size)
        currentOffset += totalSize
        fileSize += totalSize
        totalSize
    }

    /** 写 Footer (64 bytes):
     *  index_offset(8) + index_size(8) + bloom_offset(8) + bloom_size(8)
     *  + entry_count(8) + magic(8) + sequence_start(8) + sequence_end(8)
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
        offset = writeInt64LE(buf, offset, sequenceStart)
        offset = writeInt64LE(buf, offset, sequenceEnd)
        file.write(buf)
        currentOffset += FOOTER_SIZE
        fileSize += FOOTER_SIZE
    }

    /** 解析 Bloom Filter Block 并直接反序列化 bitSet */
    private static func parseBloomFilter(bloomBuf: Array<Byte>): BloomFilter {
        BloomFilter.deserialize(bloomBuf)
    }
}
