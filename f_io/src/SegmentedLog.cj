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
import std.io.{InputStream, SeekPosition}
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
    private var curPath: String
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

    public init(config: LogConfig) {
        this.config = config
        // 确保目录存在
        let dir = config.dir
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        // 打开初始文件
        let path = "${dir}/${config.filePrefix}_${config.startSeq}${config.fileExt}"
        this.file = File(path, OpenMode.ReadWrite)
        this.curPath = path
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
    /** 从指定路径创建。rotate() 仍使用 config 生成新文件路径 */
    public init(config: LogConfig, initPath: String) {
        this.config = config
        // 确保目录存在
        let dir = config.dir
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        this.file = File(initPath, OpenMode.ReadWrite)
        this.curPath = initPath
        this.seq = AtomicInt64(config.startSeq)
        this.closed = AtomicBool(false)
        this.currentSize = AtomicInt64(0)
        this.appendCount = AtomicInt64(0)
        this.oldFiles = ArrayList<String>()
        this.oldFilesLock = Mutex()
        this.appendLock = Mutex()
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

    /**
     * 返回一个 InputStream，依次读取所有 segment 中已写入的数据。
     * 读完后自动关闭。调用方可用 DefaultCodec 流式解码每条 entry。
     */
    public func openEntryStream(): InputStream {
        // 收集旧 segment 路径
        let paths = ArrayList<String>()
        synchronized (oldFilesLock) {
            for (p in oldFiles) {
                paths.add(p)
            }
        }
        ChainedSegmentStream(paths, readCurrentData())
    }

    // ===== 内部实现 =====

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
        synchronized (oldFilesLock) {
            oldFiles.add(curPath)
        }
        // 创建新文件
        let newSeq = seq.fetchAdd(1) + 1
        let newPath = "${config.dir}/${config.filePrefix}_${newSeq}${config.fileExt}"
        this.file = File(newPath, OpenMode.ReadWrite)
        this.curPath = newPath
        this.mmapPtr = initFileMapping(this.file, config.maxFileSize)
        this.currentSize.store(0)
        this.appendCount.store(0)
    }

    /** 读当前 segment 已写入的数据。Linux 从 mmap 读，非 Linux 从文件读 */
    @When[os == "Linux"]
    private func readCurrentData(): Array<Byte> {
        let size = currentSize.load()
        if (size <= 0) { return [] }
        let result = Array<Byte>(size, repeat: 0u8)
        unsafe {
            let dstHdl = acquireArrayRawData<Byte>(result)
            mcopy(CPointer<Unit>(dstHdl.pointer), CPointer<Unit>(mmapPtr), UIntNative(size))
            releaseArrayRawData(dstHdl)
        }
        result
    }
    @When[os != "Linux"]
    private func readCurrentData(): Array<Byte> {
        let size = currentSize.load()
        if (size <= 0) { return [] }
        let pos = file.seek(SeekPosition.Current(0))
        if (pos > size) { file.seek(SeekPosition.Begin(0)) }
        let result = Array<Byte>(size, repeat: 0u8)
        file.read(result)
        result
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

/**
 * 链式 segment 输入流：依次读取多个旧 segment 文件，然后读取当前 segment 的内存数据。
 * 实现 InputStream 接口，可作为 DefaultCodec.decode 的参数逐条解码 entry。
 */
public class ChainedSegmentStream <: InputStream & Resource {
    private let filePaths: ArrayList<String>
    private let currentData: Array<Byte>
    private var fileIndex: Int64 = 0
    private var currentFile: ?File = None
    private var filePos: Int64 = 0
    private let currentTotal: Int64
    private var currentPos: Int64 = 0
    private var closed: Bool = false

    public init(filePaths: ArrayList<String>, currentData: Array<Byte>) {
        this.filePaths = filePaths
        this.currentData = currentData
        this.currentTotal = currentData.size
        openNextFile()
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (closed || buffer.size == 0) { return 0 }
        var written: Int64 = 0
        while (written < buffer.size) {
            if (let Some(f) <- currentFile) {
                let n = f.read(buffer)
                if (n > 0) {
                    written += n
                    filePos += n
                }
                if (n < buffer.size - written) {
                    advanceFile()
                }
            } else {
                let avail = currentTotal - currentPos
                if (avail <= 0) { break }
                let want = buffer.size - written
                let take = if (want < avail) { want } else { avail }
                for (i in 0..take) {
                    buffer[written + i] = currentData[currentPos + i]
                }
                written += take
                currentPos += take
                if (currentPos >= currentTotal) { break }
            }
        }
        written
    }

    public func isClosed(): Bool { closed }

    public func close(): Unit {
        if (closed) { return }
        closed = true
        if (let Some(f) <- currentFile) {
            if (!f.isClosed()) { f.close() }
        }
    }

    private func openNextFile(): Unit {
        while (fileIndex < filePaths.size) {
            let path = filePaths[fileIndex]
            fileIndex += 1
            try {
                let f = File(path, OpenMode.Read)
                currentFile = f
                filePos = 0
                return
            } catch (_: Exception) { continue }
        }
        currentFile = None
    }

    private func advanceFile(): Unit {
        if (let Some(f) <- currentFile) {
            if (!f.isClosed()) { f.close() }
        }
        openNextFile()
    }
}
