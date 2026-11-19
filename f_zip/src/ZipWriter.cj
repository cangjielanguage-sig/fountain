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
package fountain::f_zip

import std.collection.ArrayList
import std.fs.{File, OpenMode, Path, exists, removeIfExists}
import std.io.{InputStream, OutputStream, SeekPosition}
import std.sync.AtomicBool
import std.time.DateTime
import stdx.compress.zlib.{CompressOutputStream, WrapType}
import fountain::f_io.ByteBuffer
import fountain::f_util.crc32

/**
 * ZIP 写入器。
 *
 * 两条路径，按"数据是否已在内存"分流：
 *
 * | | `add(name, data)` | `addFileStream(name, input)` |
 * | --- | --- | --- |
 * | crc / 大小 | 写 header **之前**已知 | 写完才知道 |
 * | local header | 真实值，bit 3 = 0 | 全 0 + bit 3 = 1 + version 45 + ZIP64 extra 占位 |
 * | data descriptor | 不写 | 写 24 字节 ZIP64 形式 |
 * | 适用 | 配置、xml、小图片 | 视频、日志、数据库导出 |
 *
 * **不是线程安全的**：单条 `OutputStream` 顺序写，同一个 writer 不得并发调用。
 * 唯一的例外是 `spilling`（`AtomicBool`）可以跨线程读。
 *
 * 写入中途抛异常后 writer 进入**脏状态**，此后任何 `add*` / `close()` 都抛异常——
 * 半截的 local header 无法修补，补出来的包结构合法但内容错，比报错更糟。
 */
public class ZipWriter {
    private let out: CountingOutputStream
    private let options: ZipWriterOptions
    private let names = EntryNameTable()
    private let entries = ArrayList<CentralEntry>()
    private let spillingFlag = AtomicBool(false)
    private var dirty = false
    private var dirtyEntry = ""
    private var closed = false
    /** 推模式条目正在写入时，禁止其它 `add*` / `close()`。 */
    private var entryOpen = false
    private var openEntryName = ""

    public init(output: OutputStream, options!: ZipWriterOptions = ZipWriterOptions()) {
        this.out = CountingOutputStream(output)
        this.options = options
    }

    /** 已写入 output 的字节数（local header + 压缩数据 + descriptor），`close()` 前不含中央目录。 */
    public prop position: Int64 {
        get() {
            out.count
        }
    }

    /**
     * 当前 `add()` 是否在"落临时文件"阶段（此时 `position` 不增长）。
     * 与 `position` **不保证原子一致**，只用于展示，不要拿来做逻辑判断。
     */
    public prop spilling: Bool {
        get() {
            spillingFlag.load()
        }
    }

    /**
     * 内存路径：先算 CRC 与压缩后大小，再写真实值的 header（不写 descriptor）。
     * 返回**实际写入的条目名**（同名冲突时会被改名）。
     *
     * `data` 超过 `memoryEntryThreshold` 时自动落临时文件后改走流式路径。
     */
    public func add(name: String, data: Array<Byte>): String {
        ensureUsable()
        if (data.size > options.memoryEntryThreshold) {
            return addSpilled(name, data)
        }
        let realName = names.allocate(name)
        let (nameBytes, utf8) = encodeName(realName)
        let method = options.method.value
        let crc = crc32(data)
        let payload = compressData(data)
        let now = DateTime.now()

        let header = LocalHeader()
        header.method = method
        header.flags = if (utf8) {
            ZipLayout.FLAG_UTF8_NAME
        } else {
            0
        }
        header.dosTime = encodeDosTime(now)
        header.dosDate = encodeDosDate(now)
        header.crc = crc
        header.compressedSize = payload.size
        header.uncompressedSize = data.size
        header.nameBytes = nameBytes

        let offset = position
        try {
            writeLocalHeader(out, header)
            out.write(payload)
        } catch (e: Exception) {
            markDirty(realName)
            throw e
        }
        record(
            nameBytes,
            utf8,
            method,
            header.dosTime,
            header.dosDate,
            crc,
            payload.size,
            data.size,
            offset,
            0,
            false
        )
        realName
    }

    /**
     * 流式路径：边压边写，用 data descriptor 回填。适合大文件、长度未知。
     *
     * local header 一次写定（`version needed = 45` + ZIP64 extra 占位），
     * 数据后写 **24 字节** descriptor，因此不需要可回退的输出流。
     */
    public func addFileStream(name: String, input: InputStream): String {
        ensureUsable()
        spillingFlag.store(false)
        let realName = names.allocate(name)
        let (nameBytes, utf8) = encodeName(realName)
        let method = options.method.value
        let now = DateTime.now()

        let header = LocalHeader()
        header.method = method
        header.flags = if (utf8) {
            ZipLayout.FLAG_UTF8_NAME
        } else {
            0
        }
        header.dosTime = encodeDosTime(now)
        header.dosDate = encodeDosDate(now)
        header.nameBytes = nameBytes
        header.streaming = true

        let offset = position
        let crcStream = Crc32InputStream(input)
        let compressedCounter = CountingOutputStream(out)
        var crc: UInt32 = 0
        var compressedSize: Int64 = 0
        var uncompressedSize: Int64 = 0
        // 三个阶段（header / 数据泵送 / descriptor）同等保护：任一阶段失败都进脏状态，
        // 半截的 local header 无法修补，续写出来的包结构合法但内容错。
        try {
            writeLocalHeader(out, header)

            if (method == 8) {
                let compressor = CompressOutputStream(compressedCounter, wrap: WrapType.DeflateFormat, bufLen: 8192)
                pump(crcStream, compressor)
                compressor.close()
            } else {
                pump(crcStream, compressedCounter)
            }

            crc = crcStream.checksum()
            compressedSize = compressedCounter.count
            uncompressedSize = crcStream.count

            writeU32LE(out, ZipLayout.SIGNATURE_DATA_DESCRIPTOR)
            writeU32LE(out, crc)
            writeU64LE(out, UInt64(compressedSize))
            writeU64LE(out, UInt64(uncompressedSize))
        } catch (e: Exception) {
            markDirty(realName)
            throw e
        }

        record(
            nameBytes,
            utf8,
            method,
            header.dosTime,
            header.dosDate,
            crc,
            compressedSize,
            uncompressedSize,
            offset,
            0,
            true
        )
        realName
    }

    /**
     * 推模式流式条目：把条目输出流交给调用方，边生成边压缩写出。
     *
     * 与 `addFileStream` 的差别只在数据来源方向：那个从 `InputStream` 拉，这个让调用方推。
     * 条目关闭前**不得**调用其它 `add*` / `openEntry` / `close()`。
     */
    public func openEntry(name: String): ZipEntryOutputStream {
        ensureUsable()
        spillingFlag.store(false)
        let realName = names.allocate(name)
        let (nameBytes, utf8) = encodeName(realName)
        let method = options.method.value
        let now = DateTime.now()

        let header = LocalHeader()
        header.method = method
        header.flags = if (utf8) {
            ZipLayout.FLAG_UTF8_NAME
        } else {
            0
        }
        header.dosTime = encodeDosTime(now)
        header.dosDate = encodeDosDate(now)
        header.nameBytes = nameBytes
        header.streaming = true

        let offset = position
        try {
            writeLocalHeader(out, header)
        } catch (e: Exception) {
            markDirty(realName)
            throw e
        }
        entryOpen = true
        openEntryName = realName
        ZipEntryOutputStream(
            this,
            out,
            realName,
            nameBytes,
            utf8,
            method,
            header.dosTime,
            header.dosDate,
            offset
        )
    }

    /** 推模式条目正常结束：写 descriptor + 登记中央目录信息。 */
    internal func finishEntry(
        name: String,
        nameBytes: Array<Byte>,
        utf8: Bool,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc: UInt32,
        compressedSize: Int64,
        uncompressedSize: Int64,
        offset: Int64
    ): Unit {
        try {
            writeU32LE(out, ZipLayout.SIGNATURE_DATA_DESCRIPTOR)
            writeU32LE(out, crc)
            writeU64LE(out, UInt64(compressedSize))
            writeU64LE(out, UInt64(uncompressedSize))
        } catch (e: Exception) {
            markDirty(name)
            clearEntryOpen()
            throw e
        }
        record(
            nameBytes,
            utf8,
            method,
            dosTime,
            dosDate,
            crc,
            compressedSize,
            uncompressedSize,
            offset,
            0,
            true
        )
        clearEntryOpen()
    }

    /** 条目流写入失败：writer 进入脏状态（半截 local header 无法修补）。 */
    internal func entryFailed(name: String): Unit {
        markDirty(name)
        clearEntryOpen()
    }

    private func clearEntryOpen(): Unit {
        entryOpen = false
        openEntryName = ""
    }

    /**
     * 以流式路径写入一个磁盘文件。传入符号链接路径时**跟随**链接
     * （调用方指名道姓要这个文件，它知道自己在干什么）。
     */
    public func addFile(name: String, path: Path): String {
        ensureUsable()
        if (!exists(path)) {
            throw ZipException("文件不存在：${path}")
        }
        let file = File(path.toString(), OpenMode.Read)
        try {
            return addFileStream(name, file)
        } finally {
            try {
                file.close()
            } catch (_: Exception) {}
        }
    }

    /**
     * 目录条目：名字以 `/` 结尾，两个大小为 0、method 0、CRC 0，
     * external attributes 置目录位。同名目录**合并**（返回原名，不写第二条）。
     */
    public func addDirectory(name: String): String {
        ensureUsable()
        var realName = name
        if (!realName.endsWith("/")) {
            realName = "${realName}/"
        }
        let (allocated, shouldWrite) = names.allocateDirectory(realName)
        if (!shouldWrite) {
            return allocated
        }
        let (nameBytes, utf8) = encodeName(realName)
        let now = DateTime.now()
        let header = LocalHeader()
        header.method = 0
        header.flags = if (utf8) {
            ZipLayout.FLAG_UTF8_NAME
        } else {
            0
        }
        header.dosTime = encodeDosTime(now)
        header.dosDate = encodeDosDate(now)
        header.nameBytes = nameBytes
        let offset = position
        try {
            writeLocalHeader(out, header)
        } catch (e: Exception) {
            markDirty(allocated)
            throw e
        }
        record(
            nameBytes,
            utf8,
            0,
            header.dosTime,
            header.dosDate,
            0,
            0,
            0,
            offset,
            ZipLayout.EXTERNAL_ATTRIBUTES_DIRECTORY,
            false
        )
        allocated
    }

    /**
     * 写中央目录（必要时写 EOCD64 与定位器）与 EOCD。必须调用，否则文件不完整。
     * 幂等：第二次调用不重复写、不抛异常；但**写失败时不算已关闭**，
     * 再次调用会重试（而不是静默返回、留下半截文件）。
     */
    public func close(): Unit {
        if (closed) {
            return
        }
        if (entryOpen) {
            throw ZipException("条目 ${openEntryName} 仍在写入，先关闭条目流")
        }
        if (dirty) {
            throw ZipException("条目 ${dirtyEntry} 写入中断，ZIP 结构不完整")
        }
        let cdStart = position
        for (e in entries) {
            writeCentralHeader(out, e)
        }
        let cdSize = position - cdStart
        // 条目数的判定是 `>=`：`0xFFFF` 在读取侧是哨兵，恰好 65535 条也必须升级 ZIP64，
        // 否则普通 EOCD 里写下的"真实值 0xFFFF"会被读端当成哨兵去找 ZIP64 定位器。
        let zip64Entries = Int64(entries.size) >= ZipLayout.ZIP64_MAX_U16
        let needZip64 = zip64Entries || cdSize >= ZipLayout.ZIP64_MAX_U32 ||
            cdStart >= ZipLayout.ZIP64_MAX_U32

        if (needZip64) {
            let eocd64Offset = position
            writeU32LE(out, ZipLayout.SIGNATURE_EOCD64)
            writeU64LE(out, 44)          // 本记录剩余长度（固定 44）
            writeU16LE(out, ZipLayout.VERSION_MADE_BY_UNIX)
            writeU16LE(out, ZipLayout.VERSION_ZIP64)
            writeU32LE(out, 0)           // this disk
            writeU32LE(out, 0)           // disk with CD start
            writeU64LE(out, UInt64(entries.size))
            writeU64LE(out, UInt64(entries.size))
            writeU64LE(out, UInt64(cdSize))
            writeU64LE(out, UInt64(cdStart))

            writeU32LE(out, ZipLayout.SIGNATURE_EOCD64_LOCATOR)
            writeU32LE(out, 0)           // disk with EOCD64
            writeU64LE(out, UInt64(eocd64Offset))
            writeU32LE(out, 1)           // total disks
        }

        writeU32LE(out, ZipLayout.SIGNATURE_EOCD)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU16LE(out, if (zip64Entries) {
            ZipLayout.SENTINEL_U16
        } else {
            UInt16(entries.size)
        })
        writeU16LE(out, if (zip64Entries) {
            ZipLayout.SENTINEL_U16
        } else {
            UInt16(entries.size)
        })
        writeU32LE(out, if (cdSize >= ZipLayout.ZIP64_MAX_U32) {
            ZipLayout.SENTINEL_U32
        } else {
            UInt32(cdSize)
        })
        writeU32LE(out, if (cdStart >= ZipLayout.ZIP64_MAX_U32) {
            ZipLayout.SENTINEL_U32
        } else {
            UInt32(cdStart)
        })
        writeU16LE(out, 0)               // comment length
        out.flush()
        // 置位放在最后：写中央目录 / EOCD 抛异常时 writer 仍是"未关闭"，
        // 第二次 close() 会重试并再次报错，不会静默成功。
        closed = true
    }

    // ---- 内部 ----

    private func ensureUsable(): Unit {
        if (closed) {
            throw ZipException("ZipWriter 已关闭，不能再写入")
        }
        if (entryOpen) {
            throw ZipException("条目 ${openEntryName} 仍在写入，先关闭条目流")
        }
        if (dirty) {
            throw ZipException("条目 ${dirtyEntry} 写入中断，ZIP 结构不完整")
        }
    }

    /** 三个阶段（header / 数据泵送 / descriptor）任一失败都走这里。 */
    private func markDirty(name: String): Unit {
        dirty = true
        dirtyEntry = name
    }

    /** 超阈值条目：先落临时文件（`spilling` 置位），再走流式路径，最后删临时文件。 */
    private func addSpilled(name: String, data: Array<Byte>): String {
        let file = TempSpill.createFile(options, name, data.size)
        let tmpPath = file.info.path
        spillingFlag.store(true)
        try {
            file.write(data)
            file.flush()
            file.seek(Begin(0))
            spillingFlag.store(false)
            let realName = addFileStream(name, file)
            return realName
        } catch (e: Exception) {
            spillingFlag.store(false)
            throw e
        } finally {
            try {
                file.close()
            } catch (_: Exception) {}
            try {
                removeIfExists(tmpPath)
            } catch (_: Exception) {}
        }
    }

    private func compressData(data: Array<Byte>): Array<Byte> {
        if (options.method.value == CompressionMethod.Stored.value) {
            return data
        }
        let buf = ByteBuffer(initialCapacity: 8192)
        let compressor = CompressOutputStream(buf, wrap: WrapType.DeflateFormat, bufLen: 8192)
        if (data.size > 0) {
            compressor.write(data)
        }
        compressor.close()
        buf.bytes()
    }

    private func pump(src: InputStream, dst: OutputStream): Unit {
        let chunk = Array<Byte>(8192, repeat: 0)
        var n = src.read(chunk)
        while (n > 0) {
            dst.write(chunk[0..n])
            n = src.read(chunk)
        }
    }

    private func record(
        nameBytes: Array<Byte>,
        utf8: Bool,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc: UInt32,
        compressedSize: Int64,
        uncompressedSize: Int64,
        offset: Int64,
        externalAttributes: UInt32,
        streaming: Bool
    ): Unit {
        let e = CentralEntry()
        e.versionMadeBy = ZipLayout.VERSION_MADE_BY_UNIX
        e.versionNeeded = if (streaming) {
            ZipLayout.VERSION_ZIP64
        } else {
            ZipLayout.VERSION_DEFAULT
        }
        e.flags = if (utf8) {
            ZipLayout.FLAG_UTF8_NAME
        } else {
            0
        }
        if (streaming) {
            e.flags = e.flags | ZipLayout.FLAG_DATA_DESCRIPTOR
        }
        e.method = method
        e.dosTime = dosTime
        e.dosDate = dosDate
        e.crc = crc
        e.compressedSize = compressedSize
        e.uncompressedSize = uncompressedSize
        e.localHeaderOffset = offset
        e.externalAttributes = externalAttributes
        e.nameBytes = nameBytes
        entries.add(e)
    }
}
