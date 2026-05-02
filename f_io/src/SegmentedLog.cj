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
package fountain::f_io

import std.fs.*
import std.sync.*
import std.collection.ArrayList
import fountain::f_base.{mcopy, nullptr}

/**
 * SegmentedLog — 固定大小分段、纯顺序追加的写日志
 *
 * 通用层，接管 mmap 文件 I/O + 轮转 + 同步。
 * 供 f_store::WAL 和未来 MQ 模块复用。
 *
 * - Linux: ftruncate + fallocate + mmap(MAP_SHARED)，memcpy 零 syscall 写入
 * - 非 Linux: 回退 file.write()
 * - 固定大小分段（rotate 在 append 时自动触发）
 * - 线程安全（Mutex 保护 append + rotate 临界区）
 */

/** 写入位置：segment 序号 + 段内偏移 */
public struct LogPosition {
    let seq: Int64
    let offset: Int64

    public init(seq: Int64, offset: Int64) {
        this.seq = seq
        this.offset = offset
    }
}

/** SegmentedLog 配置参数 */
public struct LogConfig {
    /** 日志目录 */
    let dir: String
    /** 文件名前缀，如 "wal" → 生成 "wal_1.log", "wal_2.log" */
    let filePrefix: String
    /** 每个 segment 文件的最大大小（bytes） */
    let maxFileSize: Int64
    /** 自动 fsync 间隔（append 次数）。<= 0 表示每次 append 都 sync */
    let syncInterval: Int64
    /** 起始 sequence 号 */
    let startSeq: Int64
    /** 文件扩展名（含前导点），默认 ".log" */
    let fileExt: String

    public init(dir: String, filePrefix: String, maxFileSize: Int64, syncInterval: Int64,
                startSeq!: Int64 = 1, fileExt!: String = ".log") {
        this.dir = dir
        this.filePrefix = filePrefix
        this.maxFileSize = maxFileSize
        this.syncInterval = syncInterval
        this.startSeq = startSeq
        this.fileExt = fileExt
    }
}

/** 日志已关闭时抛出的异常 */
public class LogClosedException <: Exception {
    public init() {
        super("SegmentedLog is closed")
    }
}

public class SegmentedLog <: Resource {
    private let config: LogConfig

    // 当前文件
    private var file: File
    @When[os == "Linux"]
    private var mmapPtr: CPointer<Byte>

    // 状态
    private let seq: AtomicInt64
    private let closed: AtomicBool
    private let currentSize: AtomicInt64
    private let appendCount: AtomicInt64
    private let oldFiles: ArrayList<String>
    private let oldFilesLock: Mutex
    private let appendLock: Mutex

    init(config: LogConfig) {
        this.config = config
        // 确保目录存在
        let dir = config.dir
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        // 打开初始文件
        let path = "${dir}/${config.filePrefix}_${config.startSeq}${config.fileExt}"
        this.file = File(path, OpenMode.ReadWrite)
        this.seq = AtomicInt64(config.startSeq)
        this.closed = AtomicBool(false)
        this.currentSize = AtomicInt64(0)
        this.appendCount = AtomicInt64(0)
        this.oldFiles = ArrayList<String>()
        this.oldFilesLock = Mutex()
        this.appendLock = Mutex()
        // Linux: ftruncate + fallocate + mmap，非 Linux 返回 null
        this.mmapPtr = initFileMapping(this.file, config.maxFileSize)
    }

    /** 追加数据到当前 segment。返回 (segment 序号, 段内偏移) */
    public func append(data: Array<Byte>): LogPosition {
        if (closed.load()) {
            throw LogClosedException()
        }
        synchronized (appendLock) {
            if (closed.load()) {
                throw LogClosedException()
            }
            // 检查是否超限，超限先轮转
            if (currentSize.load() + data.size > config.maxFileSize) {
                rotate()
            }
            let pos = currentSize.load()
            // Linux: memcpy 到 mmap 区域，非 Linux: file.write()
            writeImpl(data)
            currentSize.fetchAdd(data.size)
            // 周期性 fsync
            let interval = config.syncInterval
            if (interval <= 0 || (appendCount.fetchAdd(1) + 1) % interval == 0) {
                syncImpl()
            }
            LogPosition(seq.load(), pos)
        }
    }

    /** 强制 fsync 当前 segment */
    public func sync(): Unit {
        synchronized (appendLock) {
            if (!closed.load()) {
                syncImpl()
            }
        }
    }

    /** 主动轮转：关闭当前 segment，创建新 segment。一般在 checkpoint 后配合 takeOldFiles() 删除旧文件 */
    public func rotate(): Unit {
        synchronized (appendLock) {
            if (closed.load()) {
                return
            }
            doRotate()
        }
    }

    /** 获取已轮转的旧文件路径列表（外部负责删除清理），并清空内部列表 */
    public func takeOldFiles(): ArrayList<String> {
        synchronized (oldFilesLock) {
            let result = ArrayList<String>()
            for (p in oldFiles) {
                result.add(p)
            }
            oldFiles.clear()
            result
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        // 用 appendLock 确保无正在进行的 append
        synchronized (appendLock) {
            syncImpl()
            unmapFile(mmapPtr, config.maxFileSize)
            if (!file.isClosed()) {
                file.close()
            }
        }
    }

    // ===== 内部实现 =====

    /** 实际轮转：sync → munmap → close → open new → mmap new */
    private func doRotate(): Unit {
        syncImpl()
        unmapFile(mmapPtr, config.maxFileSize)
        if (!file.isClosed()) {
            file.close()
        }
        // 将旧路径加入待清理列表
        let oldPath = "${config.dir}/${config.filePrefix}_${seq.load()}${config.fileExt}"
        synchronized (oldFilesLock) {
            oldFiles.add(oldPath)
        }
        // 创建新文件
        let newSeq = seq.fetchAdd(1) + 1
        let newPath = "${config.dir}/${config.filePrefix}_${newSeq}${config.fileExt}"
        this.file = File(newPath, OpenMode.ReadWrite)
        this.mmapPtr = initFileMapping(this.file, config.maxFileSize)
        this.currentSize.store(0)
        this.appendCount.store(0)
    }

    // ---- @When[os] 双版本方法 ----

    /** Linux: ftruncate + fallocate + mmap。非 Linux: 返回 null */
    @When[os == "Linux"]
    private static func initFileMapping(file: File, size: Int64): CPointer<Byte> {
        let fd = file.fileDescriptor.fileHandle
        unsafe { ftruncate(Int32(fd), size) }
        unsafe { fallocate(Int32(fd), 0, 0, size) }
        let protBits = [MMapProt.Read, MMapProt.Write].combine()
        unsafe {
            CPointer<Byte>(mmap(nullptr, UIntNative(size), protBits, MMapFlag.Shared.value, fd, IntNative(0)))
        }
    }
    @When[os != "Linux"]
    private static func initFileMapping(_: File, _: Int64): CPointer<Byte> {
        CPointer<Byte>()
    }

    /** Linux: munmap。非 Linux: 空操作 */
    @When[os == "Linux"]
    private static func unmapFile(ptr: CPointer<Byte>, size: Int64): Unit {
        unsafe { munmap(CPointer<Unit>(ptr), UIntNative(size)) }
    }
    @When[os != "Linux"]
    private static func unmapFile(_: CPointer<Byte>, _: Int64): Unit {}

    /** Linux: memcpy 到 mmap 写 page cache。非 Linux: file.write() */
    @When[os == "Linux"]
    private func writeImpl(data: Array<Byte>): Unit {
        let pos = currentSize.load()
        unsafe {
            let srcHdl = acquireArrayRawData<Byte>(data)
            mcopy(CPointer<Unit>(mmapPtr + pos), CPointer<Unit>(srcHdl.pointer), UIntNative(data.size))
            releaseArrayRawData(srcHdl)
        }
    }
    @When[os != "Linux"]
    private func writeImpl(data: Array<Byte>): Unit {
        file.write(data)
    }

    /** fsync 刷盘（统一路径，Linux 下同样 flush mmap 脏页） */
    private func syncImpl(): Unit {
        file.flush()
    }
}
