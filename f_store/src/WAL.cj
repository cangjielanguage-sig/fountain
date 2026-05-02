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
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let seq = sequence.incrFetch()
        // 零分配编码（小值走线程局部 buffer，零拷贝切片）
        let encoded = encodeDirect(seq, key, value, expireAt)
        // 用 Mutex 保护 file.write + rotate + sync 的原子性，防止与 close 竞态
        synchronized (appendLock) {
            // 获取锁后再次检查 closed（可能在等待锁时 close() 已执行）
            if (closed.load()) {
                throw StoreClosedException()
            }
            // 检查写入当前记录后的文件大小是否超限，超限则先 rotate 再写入新文件
            if (currentFileSize.load() + Int64(encoded.size) > maxFileSize) {
                rotate()
            }
            // 始终同步写入文件（数据到 OS page cache，进程崩溃可恢复）
            file.write(encoded)
            currentFileSize.fetchAdd(Int64(encoded.size))
            // fsync 锁内执行，确保与 close 互斥
            if (appendCount.incrFetch() % syncInterval == 0) {
                file.flush()
            }
        }
        seq
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
                file.flush()
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
        // sync（flush 缓冲区） + close 当前文件
        sync()
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
        this.walPath = newPath
        this.currentFileSize.store(0)
        this.appendCount.store(0)
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // 用 appendLock 确保在 append 中无正在进行的 file.write
        synchronized (appendLock) {
            // 强制 fsync 确保数据落盘（绕过 sync 的 closed 检查）
            file.flush()
            if (!file.isClosed()) {
                file.close()
            }
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
