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
import std.time.*
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
    /** segment 序号（对应文件名 `{filePrefix}_{seq}{fileExt}`） */
    public let seq: Int64
    /** 段内字节偏移，可直接回传给 `openEntryStream(seq, offset)` 续读 */
    public let offset: Int64

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

    public init(dir: String, filePrefix: String, maxFileSize: Int64, syncInterval: Int64, startSeq!: Int64 = 1,
        fileExt!: String = ".log") {
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

/** 一个 log 文件的元数据 */
public class SegmentedMeta {
    public SegmentedMeta(
        public let index: Int64, // log 文件的序号
        public let size: Int64, // log 文件的有效数据大小（字节）
        public let creationTime: DateTime, // log 文件的创建时间
        public let updateTime: DateTime, // log 文件的最后修改时间
        public let last: Bool // 是否当下最后一个
    ) {}
}

/** 目录扫描结果（内部使用）：比 SegmentedMeta 多带文件路径 */
private struct SegmentFile {
    let index: Int64
    let path: String
    let size: Int64
    let creationTime: DateTime
    let updateTime: DateTime
    let last: Bool

    init(index: Int64, path: String, size: Int64, creationTime: DateTime, updateTime: DateTime, last: Bool) {
        this.index = index
        this.path = path
        this.size = size
        this.creationTime = creationTime
        this.updateTime = updateTime
        this.last = last
    }
}

public class SegmentedLog <: Resource {
    private let config: LogConfig

    // 当前文件
    private var file: File
    private var curPath: String

    private var mmapPtr: CPointer<Byte> = CPointer<Byte>()

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
        // 编号单调递增：新段取目录中最新编号 + 1（删除过的编号不再复用）
        let nextSeq = SegmentedLog.nextSegmentIndex(config)
        let path = "${dir}/${config.filePrefix}_${nextSeq}${config.fileExt}"
        this.file = File(path, OpenMode.ReadWrite)
        this.curPath = path
        this.seq = AtomicInt64(nextSeq)
        this.closed = AtomicBool(false)
        this.currentSize = AtomicInt64(0)
        this.appendCount = AtomicInt64(0)
        this.oldFiles = ArrayList<String>()
        this.oldFilesLock = Mutex()
        this.appendLock = Mutex()
        // Linux: ftruncate + fallocate + mmap，非 Linux 返回 null
        initFileMapping(this, config.maxFileSize)
    }
    /** 从指定路径创建。rotate() 仍使用 config 生成新文件路径；编号起点不低于目录里已有的最大编号 */
    public init(config: LogConfig, initPath: String) {
        this.config = config
        // 确保目录存在
        let dir = config.dir
        if (!exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        this.file = File(initPath, OpenMode.ReadWrite)
        this.curPath = initPath
        let existingMax = SegmentedLog.maxSegmentIndex(config)
        let startSeq = if (existingMax > config.startSeq) {
            existingMax
        } else {
            config.startSeq
        }
        this.seq = AtomicInt64(startSeq)
        this.closed = AtomicBool(false)
        this.currentSize = AtomicInt64(0)
        this.appendCount = AtomicInt64(0)
        this.oldFiles = ArrayList<String>()
        this.oldFilesLock = Mutex()
        this.appendLock = Mutex()
        initFileMapping(this, config.maxFileSize)
    }

    /** 追加数据到当前 segment。返回 (segment 序号, 段内偏移) */
    public func append(data: Array<Byte>): LogPosition {
        if (closed.load()) {
            throw LogClosedException()
        }
        synchronized(appendLock) {
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
        synchronized(appendLock) {
            if (!closed.load()) {
                syncImpl()
            }
        }
    }

    /** 主动轮转：关闭当前 segment，创建新 segment。一般在 checkpoint 后配合 takeOldFiles() 删除旧文件 */
    public func rotate(): Unit {
        synchronized(appendLock) {
            if (closed.load()) {
                return
            }
            doRotate()
        }
    }

    /** 获取已轮转的旧文件路径列表（外部负责删除清理），并清空内部列表 */
    public func takeOldFiles(): ArrayList<String> {
        synchronized(oldFilesLock) {
            let result = ArrayList<String>()
            for (p in oldFiles) {
                result.add(p)
            }
            oldFiles.clear()
            result
        }
    }

    /**
     * 返回日志目录下所有 log 文件的元数据，按编号升序。
     *
     * - `size` 为文件的有效日志字节数：封口段是被截断后的文件大小，当前段是已写入字节数
     * - `last` 标记当前正在写入的段
     * - 不符合 "{filePrefix}_{index}{fileExt}" 命名规则的文件不会被列出（自定义命名的当前段除外）
     */
    public func logMetas(): ArrayList<SegmentedMeta> {
        let result = ArrayList<SegmentedMeta>()
        synchronized(appendLock) {
            for (f in scanSegments()) {
                result.add(SegmentedMeta(f.index, f.size, f.creationTime, f.updateTime, f.last))
            }
        }
        result
    }

    /**
     * 删除指定编号的 log 文件。
     *
     * 当前正在写入的段不允许删除（抛出 IllegalArgumentException，避免追加写进已 unlink 的 inode）；
     * 编号不存在时为空操作。删除不影响编号分配：后续新段仍按最新编号 + 1 取名，不复用已删编号。
     */
    public func removeById(index: Int64): Unit {
        synchronized(appendLock) {
            if (index == currentSegmentIndex()) {
                throw IllegalArgumentException("cannot remove the active segment ${index}, call rotate() first")
            }
            removeIndexedFile(index)
        }
    }

    /** 删除创建时间早于 time 的所有封口段（当前段始终保留） */
    public func removeCreatedBefore(time: DateTime): Unit {
        removeSegmentsMatching {f: SegmentFile => f.creationTime < time}
    }

    /** 删除创建时间晚于 time 的所有封口段（当前段始终保留） */
    public func removeCreatedAfter(time: DateTime): Unit {
        removeSegmentsMatching {f: SegmentFile => f.creationTime > time}
    }

    /** 删除最后修改时间早于 time 的所有封口段（当前段始终保留） */
    public func removeUpdatedBefore(time: DateTime): Unit {
        removeSegmentsMatching {f: SegmentFile => f.updateTime < time}
    }

    /** 删除最后修改时间晚于 time 的所有封口段（当前段始终保留） */
    public func removeUpdatedAfter(time: DateTime): Unit {
        removeSegmentsMatching {f: SegmentFile => f.updateTime > time}
    }

    /** 删除创建时间落在 [start, end)（前闭后开）内的所有封口段（当前段始终保留） */
    public func removeBetween(start: DateTime, end: DateTime): Unit {
        removeSegmentsMatching {f: SegmentFile => !(f.creationTime < start) && f.creationTime < end}
    }

    /** 删除编号落在 range 内的所有封口段：`1..3` 为 [1, 3)，`1..=3` 为 [1, 3]（当前段始终保留） */
    public func removeBetween(range: Range<Int64>): Unit {
        let lo = range.start
        let hi = range.end
        if (range.isClosed) {
            removeSegmentsMatching {f: SegmentFile => f.index >= lo && f.index <= hi}
        } else {
            removeSegmentsMatching {f: SegmentFile => f.index >= lo && f.index < hi}
        }
    }

    /**
     * 返回一个 InputStream，从编号为 index 的 log 文件的 offset 处开始读，
     * 依次读到最后一个文件的最后一个有效字节为止。读完后自动关闭。
     * 调用方可用 DefaultCodec 流式解码每条 entry。
     * 编号不存在（含已被删除）或 offset 为负时抛 IllegalArgumentException。
     */
    public func openEntryStream(index: Int64, offset: Int64): InputStream {
        if (offset < 0) {
            throw IllegalArgumentException("offset must not be negative, got ${offset}")
        }
        let paths = ArrayList<String>()
        let sizes = ArrayList<Int64>()
        var found = false
        synchronized(appendLock) {
            for (f in scanSegments()) {
                if (f.index < index) {
                    continue
                }
                if (f.index == index) {
                    found = true
                }
                paths.add(f.path)
                sizes.add(f.size)
            }
        }
        if (!found) {
            throw IllegalArgumentException("segment ${index} not found in ${config.dir}")
        }
        ChainedSegmentStream(paths, sizes, startOffset: offset)
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
        synchronized(appendLock) {
            syncImpl()
            unmapFile(mmapPtr, config.maxFileSize)
            if (!file.isClosed()) {
                truncateFile(file, currentSize.load())
                file.close()
            }
        }
    }

    /** 扫描日志目录，返回所有 segment 文件（按编号升序）。当前段总是以 last=true 出现 */
    private func scanSegments(): ArrayList<SegmentFile> {
        let prefix = "${config.filePrefix}_"
        let ext = config.fileExt
        let cur = curPath
        let curSize = currentSize.load()
        let files = ArrayList<SegmentFile>()
        Directory.walk(config.dir) {
            fi: FileInfo =>
                if (!fi.isDirectory()) {
                    if (let Some(index) <- SegmentedLog.parseSegmentIndex(fi.name, prefix, ext)) {
                        let path = fi.path.toString()
                        let isLast = path == cur
                        // 封口段读文件大小（封口时已截断到实际写入长度），当前段读已写入字节数
                        files.add(
                            SegmentFile(index, path, if (isLast) {
                                curSize
                            } else {
                                fi.size
                            }, fi.creationTime, fi.lastModificationTime, isLast))
                    }
                }
                true
        }
        SegmentedLog.sortByIndex(files)
        // 当前段若用了自定义文件名（不符合命名规则），补一条
        var hasCurrent = false
        for (f in files) {
            if (f.last) {
                hasCurrent = true
                break
            }
        }
        if (!hasCurrent) {
            let fi = FileInfo(cur)
            files.add(SegmentFile(seq.load(), cur, curSize, fi.creationTime, fi.lastModificationTime, true))
            SegmentedLog.sortByIndex(files)
        }
        files
    }

    /** 删除编号为 index 的 segment 文件（不存在则空操作） */
    private func removeIndexedFile(index: Int64): Unit {
        for (f in scanSegments()) {
            if (f.index == index) {
                deleteSegmentFile(f.path)
                return
            }
        }
    }

    /** 删除所有满足条件的封口段；当前段始终跳过 */
    private func removeSegmentsMatching(predicate: (SegmentFile) -> Bool): Unit {
        synchronized(appendLock) {
            for (f in scanSegments()) {
                if (f.last) {
                    continue
                }
                if (predicate(f)) {
                    deleteSegmentFile(f.path)
                }
            }
        }
    }

    /** 删除文件，并把它从待清理列表里摘掉（外部 clearOldFiles 不会重复处理） */
    private func deleteSegmentFile(path: String): Unit {
        if (exists(path)) {
            remove(path)
        }
        synchronized(oldFilesLock) {
            var i = oldFiles.size - 1
            while (i >= 0) {
                if (oldFiles[i] == path) {
                    oldFiles.remove(at: i)
                }
                i -= 1
            }
        }
    }

    /** 当前段的编号：文件名符合命名规则时取文件名里的编号，否则取内部序号 */
    private func currentSegmentIndex(): Int64 {
        let name = Path(curPath).fileName
        if (let Some(index) <- SegmentedLog.parseSegmentIndex(name, "${config.filePrefix}_", config.fileExt)) {
            return index
        }
        seq.load()
    }

    /** 解析 "{prefix}_{index}{ext}" 形式的文件名；不匹配或编号非法时返回 None */
    private static func parseSegmentIndex(name: String, prefix: String, ext: String): ?Int64 {
        if (!name.startsWith(prefix) || !name.endsWith(ext)) {
            return None
        }
        if (name.size <= prefix.size + ext.size) {
            return None
        }
        let digits = name[prefix.size..name.size - ext.size]
        if (digits.size > 18) {
            return None // 位数过多，避免解析溢出
        }
        var index: Int64 = 0
        for (c in digits) {
            // 迭代 String 得到的是字节（UInt8）
            if (c < b'0' || c > b'9') {
                return None
            }
            index = index * 10 + Int64(c - b'0')
        }
        Some(index)
    }

    /** 按编号升序排列（段数很少，插入排序足够） */
    private static func sortByIndex(files: ArrayList<SegmentFile>): Unit {
        for (i in 1..files.size) {
            let item = files[i]
            var j = i - 1
            while (j >= 0 && files[j].index > item.index) {
                files[j + 1] = files[j]
                j -= 1
            }
            files[j + 1] = item
        }
    }

    /** 目录里已有的最大编号；目录为空或没有符合命名规则的文件时返回 -1 */
    private static func maxSegmentIndex(config: LogConfig): Int64 {
        if (!exists(config.dir)) {
            return -1
        }
        let prefix = "${config.filePrefix}_"
        let ext = config.fileExt
        let indexes = ArrayList<Int64>()
        Directory.walk(config.dir) {
            fi: FileInfo =>
                if (!fi.isDirectory()) {
                    if (let Some(index) <- SegmentedLog.parseSegmentIndex(fi.name, prefix, ext)) {
                        indexes.add(index)
                    }
                }
                true
        }
        var maxIndex: Int64 = -1
        for (index in indexes) {
            if (index > maxIndex) {
                maxIndex = index
            }
        }
        maxIndex
    }

    /** 新建 segment 时使用的编号：目录中最新编号 + 1（空目录取 startSeq） */
    private static func nextSegmentIndex(config: LogConfig): Int64 {
        let next = SegmentedLog.maxSegmentIndex(config) + 1
        if (next < config.startSeq) {
            config.startSeq
        } else {
            next
        }
    }

    /** 把文件截断到实际写入长度（Linux 下文件是按 maxFileSize 预分配的） */
    private static func truncateFile(file: File, size: Int64): Unit {
        try {
            file.setLength(size)
        } catch (_: Exception) {
            // 截断失败只影响文件大小的可读性，不应打断写入路径
        }
    }

    // ===== 内部实现 =====

    /** 实际轮转：sync → munmap → truncate → close → open new → mmap new */
    private func doRotate(): Unit {
        syncImpl()
        unmapFile(mmapPtr, config.maxFileSize)
        if (!file.isClosed()) {
            // 封口时截断到实际写入长度，封口段的 size 才是有效数据大小
            truncateFile(file, currentSize.load())
            file.close()
        }
        // 将旧路径加入待清理列表
        synchronized(oldFilesLock) {
            oldFiles.add(curPath)
        }
        // 创建新文件
        let newSeq = seq.fetchAdd(1) + 1
        let newPath = "${config.dir}/${config.filePrefix}_${newSeq}${config.fileExt}"
        this.file = File(newPath, OpenMode.ReadWrite)
        this.curPath = newPath
        initFileMapping(this, config.maxFileSize)
        this.currentSize.store(0)
        this.appendCount.store(0)
    }

    // ---- @When[os] 双版本方法 ----

    /** Linux: ftruncate + fallocate + mmap。非 Linux: 返回 null */
    @When[os == "Linux"]
    private static func initFileMapping(segmlog: SegmentedLog, size: Int64): Unit {
        let fd = segmlog.file.fileDescriptor.fileHandle
        unsafe { ftruncate(Int32(fd), size) }
        unsafe { fallocate(Int32(fd), 0, 0, size) }
        let protBits = [MMapProt.Read, MMapProt.Write].combine()
        unsafe {
            segmlog.mmapPtr = CPointer<Byte>(
                mmap(nullptr, UIntNative(size), protBits, MMapFlag.Shared.value, fd, IntNative(0)))
        }
    }
    @When[os != "Linux"]
    private static func initFileMapping(_: SegmentedLog, _: Int64): Unit {}

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
 * 链式 segment 输入流：按编号升序依次读取多个 segment 文件，读完之后自动关闭当前文件。
 * 首个文件从 startOffset 处起读（其余从 0 起），每个文件最多读 sizes[i] 字节
 * （封口段为文件大小，当前段为已写入长度，因此不会读到预分配区的空洞）。
 * 实现 InputStream 接口，可作为 DefaultCodec.decode 的参数逐条解码 entry。
 */
public class ChainedSegmentStream <: InputStream & Resource {
    private let filePaths: ArrayList<String>
    private let sizes: ArrayList<Int64>
    private let startOffset: Int64
    private var fileIndex: Int64 = 0
    private var currentFile: ?File = None
    private var remaining: Int64 = 0
    private var closed: Bool = false

    public init(filePaths: ArrayList<String>, sizes: ArrayList<Int64>, startOffset!: Int64 = 0) {
        this.filePaths = filePaths
        this.sizes = sizes
        this.startOffset = startOffset
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (closed || buffer.size == 0) {
            return 0
        }
        var written: Int64 = 0
        while (written < buffer.size) {
            if (remaining <= 0) {
                closeCurrentFile()
                if (!openNextFile()) {
                    break
                }
            }
            if (let Some(f) <- currentFile) {
                let want = buffer.size - written
                let take = if (want < remaining) {
                    want
                } else {
                    remaining
                }
                let n = f.read(buffer[written..written + take])
                if (n <= 0) {
                    remaining = 0 // 文件提前读完，跳到下一段
                    continue
                }
                written += n
                remaining -= n
            }
        }
        written
    }

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        closeCurrentFile()
    }

    private func openNextFile(): Bool {
        while (fileIndex < filePaths.size) {
            let i = fileIndex
            fileIndex += 1
            var available = sizes[i]
            if (i == 0) {
                available -= startOffset
            }
            if (available <= 0) {
                continue
            }
            try {
                let f = File(filePaths[i], OpenMode.Read)
                if (i == 0 && startOffset > 0) {
                    f.seek(SeekPosition.Begin(startOffset))
                }
                currentFile = f
                remaining = available
                return true
            } catch (_: Exception) {
                continue
            }
        }
        currentFile = None
        false
    }

    private func closeCurrentFile(): Unit {
        if (let Some(f) <- currentFile) {
            if (!f.isClosed()) {
                f.close()
            }
        }
        currentFile = None
        remaining = 0
    }
}
