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

class WAL <: Resource {
    /** 线程局部编码缓冲区（4KB 覆盖绝大多数小值记录） */
    private static let encodeBuf = ThreadLocal<Array<Byte>>()

    /** mmap WAL 文件基址（Linux），零 syscall 写入 page cache */
    @When[os == "Linux"]
    private var mmapPtr: CPointer<Byte>

    private var file: File
    let sequence: AtomicInt64
    let closed: AtomicBool
    private let syncInterval: Int64
    private let appendCount: AtomicInt64
    private let currentFileSize: AtomicInt64
    private let maxFileSize: Int64
    private var walPath: String
    private let walDir: String
    /** 已关闭的旧 WAL 文件路径列表（等待清理） */
    private let oldFiles: ArrayList<String>
    /** 保护 oldFiles 并发访问（rotate vs takeOldFiles） */
    private let oldFilesLock: Mutex
    /** 保护 append 中 file.write + rotate 的原子性 */
    private let appendLock: Mutex

    init(path: String, startSequence!: Int64 = 0, maxFileSize!: Int64 = 64 * 1024 * 1024) {
        // 确保目录存在
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.walPath = path
        this.walDir = parentDir.toString()
        this.file = File(path, OpenMode.ReadWrite)
        this.sequence = AtomicInt64(startSequence)
        this.closed = AtomicBool(false)
        this.syncInterval = 100
        this.appendCount = AtomicInt64(0)
        this.currentFileSize = AtomicInt64(0)
        this.maxFileSize = maxFileSize
        this.oldFiles = ArrayList<String>()
        this.oldFilesLock = Mutex()
        this.appendLock = Mutex()
        // Linux: ftruncate + fallocate + mmap（静态方法，不依赖 this 初始化完成）
        this.mmapPtr = mmapFile(this.file, maxFileSize)
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let seq = sequence.incrFetch()
        // 零分配编码（小值走线程局部 buffer，零拷贝切片）
        let encoded = encodeDirect(seq, key, value, expireAt)
        let recordSize = Int64(encoded.size)
        // 用 Mutex 保护 write + rotate + sync 的原子性，防止与 close 竞态
        synchronized (appendLock) {
            // 获取锁后再次检查 closed（可能在等待锁时 close() 已执行）
            if (closed.load()) {
                throw StoreClosedException()
            }
            // 检查写入当前记录后的文件大小是否超限，超限则先 rotate 再写入新文件
            if (currentFileSize.load() + recordSize > maxFileSize) {
                rotate()
            }
            // Linux: memcpy 到 mmap 区域（零 syscall）
            // 非 Linux: file.write()
            writeRecord(encoded)
            currentFileSize.fetchAdd(recordSize)
            // fsync / msync 锁内执行
            if (appendCount.incrFetch() % syncInterval == 0) {
                syncRecords()
            }
        }
        seq
    }

    /** Linux: memcpy 到 mmap 写 page cache。非 Linux: file.write() */
    @When[os == "Linux"]
    private func writeRecord(encoded: Array<Byte>): Unit {
        let writePos = currentFileSize.load()
        unsafe {
            let srcHdl = acquireArrayRawData<Byte>(encoded)
            memcpy(mmapPtr + writePos, srcHdl.pointer, encoded.size)
            releaseArrayRawData(srcHdl)
        }
    }
    @When[os != "Linux"]
    private func writeRecord(encoded: Array<Byte>): Unit {
        file.write(encoded)
    }

    /** fsync 刷盘（统一路径，Linux 下同样 flush mmap 脏页） */
    private func syncRecords(): Unit {
        file.flush()
    }

    /** 将记录直接编码到线程局部缓冲区，返回零拷贝切片。小值路径零堆分配。
     *  超大记录（> 4KB）回退到 WALRecord.encode()。 */
    private static func encodeDirect(
        sequence: Int64,
        key: Array<Byte>,
        value: ?Array<Byte>,
        expireAt: ?Int64
    ): Array<Byte> {
        let kLen = key.size
        let vLen = if (let Some(v) <- value) { v.size } else { -1 }
        let expireAtVal = if (let Some(ea) <- expireAt) { ea } else { 0 }
        // checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8) + key + value
        let totalLen = 36 + kLen + (if (vLen > 0) { vLen } else { 0 })

        // 超大记录回退到分配路径
        let scratch = encodeBuf.getOrCompute { => Array<Byte>(4096, repeat: 0u8) }
        if (scratch.size < totalLen) {
            return WALRecord(sequence, key, value, expireAt: expireAt).encode()
        }

        // 1. 写入各字段到 scratch（跳过 checksum 4 字节槽位）
        var off: Int64 = 4
        off = writeInt64LE(scratch, off, sequence)
        off = writeInt64LE(scratch, off, Int64(kLen))
        off = writeInt64LE(scratch, off, Int64(vLen))
        off = writeInt64LE(scratch, off, expireAtVal)
        key.copyTo(scratch[off .. off + kLen])
        off += kLen
        if (let Some(v) <- value) {
            v.copyTo(scratch[off .. off + vLen])
            off += vLen
        }

        // 2. 计算 CRC32（零拷贝切片，只覆盖 payload，不含 checksum 自身）
        let payload = scratch[4 .. totalLen]
        let crc = crc32(payload)

        // 3. checksum 写回 scratch[0..4]
        writeUInt32LE(scratch, 0, crc)

        // 4. 零拷贝切片返回
        scratch[0 .. totalLen]
    }

    func sync(): Unit {
        synchronized (appendLock) {
            if (!closed.load()) {
                syncRecords()
            }
        }
    }

    /** 返回已关闭的旧 WAL 文件路径列表（等待清理），并清空内部列表 */
    func takeOldFiles(): ArrayList<String> {
        synchronized (oldFilesLock) {
            let result = ArrayList<String>()
            for (p in oldFiles) {
                result.add(p)
            }
            oldFiles.clear()
            result
        }
    }

    private func rotate(): Unit {
        // sync（flush 缓冲区）+ close 当前文件
        sync()
        unmapFile(mmapPtr, maxFileSize)
        if (!file.isClosed()) {
            file.close()
        }
        // 将旧路径加入待清理列表
        synchronized (oldFilesLock) {
            oldFiles.add(walPath)
        }

        // 用当前 sequence 创建新 WAL 文件
        let startSeq = sequence.load()
        let newPath = "${walDir}/wal_${startSeq}.wal"
        this.file = File(newPath, OpenMode.ReadWrite)
        this.mmapPtr = mmapFile(this.file, maxFileSize)
        this.walPath = newPath
        this.currentFileSize.store(0)
        this.appendCount.store(0)
    }

    /** Linux: munmap。非 Linux: 空操作 */
    @When[os == "Linux"]
    private static func unmapFile(ptr: CPointer<Byte>, size: Int64): Unit {
        unsafe { munmap(ptr, size) }
    }
    @When[os != "Linux"]
    private static func unmapFile(_: CPointer<Byte>, _: Int64): Unit {}

    /** Linux: ftruncate + fallocate + mmap。非 Linux: 空操作 */
    @When[os == "Linux"]
    private static func mmapFile(file: File, size: Int64): CPointer<Byte> {
        let fd = Int32(file.fileDescriptor.fileHandle)
        unsafe { ftruncate(fd, size) }
        unsafe { fallocate(fd, 0, 0, size) }
        unsafe { mmap(CPointer<Byte>(), size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) }
    }
    @When[os != "Linux"]
    private static func mmapFile(_: File, _: Int64): CPointer<Byte> {
        CPointer<Byte>()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // 用 appendLock 确保在 append 中无正在进行的 write/memcpy
        synchronized (appendLock) {
            // 强制 sync 确保数据落盘
            syncRecords()
            unmapFile(mmapPtr, maxFileSize)
            if (!file.isClosed()) {
                file.close()
            }
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
