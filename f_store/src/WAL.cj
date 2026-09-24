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
 * WAL — Write-Ahead Log
 *
 * 基于 fountain::f_io.SegmentedLog 实现。
 * 业务层：记录编码（encodeDirect）、序号管理、过期时间。
 * I/O 层：固定大小分段、mmap（Linux）零 syscall 写入、自动轮转 — 全部委托给 SegmentedLog。
 */
class WAL <: Resource {
    /** 线程局部编码缓冲区（4KB 覆盖绝大多数小值记录） */
    private static let encodeBuf = ThreadLocal<Array<Byte>>()

    /** SegmentedLog 负责所有 I/O：mmap/file.write + 轮转 + 同步 */
    private let segmentLog: SegmentedLog

    /** f_store 业务序列号（独立于 SegmentedLog 的文件序列号） */
    let sequence: AtomicInt64
    private let closed: AtomicBool

    init(path: String, startSequence!: Int64 = 0, maxFileSize!: Int64 = 64 * 1024 * 1024) {
        let parentDir = Path(path).parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        this.sequence = AtomicInt64(startSequence)
        this.closed = AtomicBool(false)
        let config = LogConfig(
            parentDir.toString(),
            "wal",
            maxFileSize,
            100,
            fileExt: ".wal"
        )
        // 使用 initPath 构造器保留传入的原始路径
        this.segmentLog = SegmentedLog(config, path)
    }

    func append(key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None): Int64 {
        if (closed.load()) {
            throw StoreClosedException()
        }
        let seq = sequence.incrFetch()
        // 零分配编码（小值走线程局部 buffer，零拷贝切片）
        let encoded = encodeDirect(seq, key, value, expireAt)
        // 委托给 SegmentedLog：写入 + 自动轮转 + 周期性 fsync
        segmentLog.append(encoded)
        seq
    }

    func sync(): Unit {
        segmentLog.sync()
    }

    /** 返回已关闭的旧 WAL 文件路径列表（等待清理），并清空内部列表 */
    func takeOldFiles(): ArrayList<String> {
        segmentLog.takeOldFiles()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // SegmentedLog 内部持有关闭保护（appendLock + CAS），直接委托
        segmentLog.close()
    }

    public func isClosed(): Bool {
        closed.load()
    }

    // ===== 编码逻辑（f_store 业务层，保持不变） =====

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

        // 溢出检测: totalLen < header(36) 表示 Int64 加法溢出
        // 超大记录回退到分配路径
        let scratch = encodeBuf.getOrCompute { => Array<Byte>(4096, repeat: 0u8) }
        if (totalLen < 36 || totalLen > scratch.size) {
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
}
