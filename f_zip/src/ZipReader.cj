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
import std.io.InputStream
import std.sync.AtomicInt64
import stdx.compress.zlib.{DecompressInputStream, WrapType}
import fountain::f_io.ByteBuffer
import fountain::f_log.LoggerFactory
import fountain::f_util.{crc32Finish, crc32Init, crc32Update}

/**
 * ZIP 读取器。两种构造：
 *
 * - `ZipReader(input)` 把整个流缓冲进内存以获得随机访问（适合网络流、内存中的 zip）；
 * - `ZipReader(path)` 走 `File.seek` 窗口读，**不缓冲整个文件**（适合大 ZIP）。
 *
 * 两种模式的差别只在"怎么读到字节"，解析逻辑完全一致（见内部 `EntrySource`）。
 *
 * 解析完成后 `entries()` / `read()` / `contains()` 只读，可并发调用；
 * `open(name)` 每次另开独立游标，因此可以并发解压多个条目。
 *
 * `limits.maxTotalSize` 是**本实例**的累计解压上限，不是进程级全局闸门——
 * 要限制一次批量导入的总量，调用方得自己持配额再逐次传入。
 */
public class ZipReader {
    private static let logger = LoggerFactory.getLogger<ZipReader>()

    private let source: EntrySource
    private let limits: ZipLimits
    private let rawEntries = ArrayList<CentralEntry>()
    private let consumed = AtomicInt64(0)
    private var closed = false

    /**
     * 从流构造：先把整个流读进内存。ZIP 要随机访问中央目录，没有别的办法。
     */
    public init(input: InputStream, limits!: ZipLimits = ZipLimits()) {
        this.source = BufferSource(readAllBytes(input))
        this.limits = limits
        loadDirectory()
    }

    /**
     * 从文件构造：尾部窗口扫描 + 中央目录一次读入，条目数据按需读。
     */
    public init(path: String, limits!: ZipLimits = ZipLimits()) {
        this.source = FileSource(path)
        this.limits = limits
        loadDirectory()
    }

    /** 条目列表：按中央目录顺序，不合并同名、不排序。每次返回独立列表。 */
    public func entries(): ArrayList<ZipEntry> {
        ensureOpen()
        let out = ArrayList<ZipEntry>(rawEntries.size)
        for (e in rawEntries) {
            out.add(e.toZipEntry())
        }
        out
    }

    /** 是否存在该名字（含目录条目）。 */
    public func contains(name: String): Bool {
        ensureOpen()
        findLast(name).isSome()
    }

    /**
     * 取该名字**最后一个**条目解压后的数据；名字不存在返回 `None`。
     *
     * 取最后一个与 Info-ZIP / 7-Zip 的解压行为一致（后写覆盖）。
     * 这里**不做任何路径安全策略**——路径校验只在 `unzip` 里执行。
     */
    public func read(name: String): ?Array<Byte> {
        ensureOpen()
        if (let Some(e) <- findLast(name)) {
            return Some(decodeEntry(e))
        }
        None<Array<Byte>>
    }

    /** 按中央目录顺序返回全部同名条目解压后的数据。 */
    public func readAll(name: String): Array<Array<Byte>> {
        ensureOpen()
        let out = ArrayList<Array<Byte>>()
        for (e in rawEntries) {
            if (e.name == name && !e.isDirectory) {
                out.add(decodeEntry(e))
            }
        }
        out.toArray()
    }

    /**
     * 取该条目解压后的限长流。每次调用另开独立句柄，可并发读。
     * 流被读到结尾时才校验 CRC 与大小，不一致抛 `ZipException`。
     */
    public func open(name: String): ?InputStream {
        ensureOpen()
        if (let Some(e) <- findLast(name)) {
            if (e.isDirectory) {
                return None<InputStream>
            }
            return Some(openEntry(e))
        }
        None<InputStream>
    }

    /** 包内可见：按**指定**的中央目录项打开（`unzip` 要能区分同名条目）。 */
    internal func openEntry(e: CentralEntry): InputStream {
        ensureOpen()
        checkEntryReadable(e)
        let dataOffset = locateData(e)
        let raw = source.openRange(dataOffset, e.compressedSize)
        let decoded = wrapMethod(raw, e.method, e.name)
        ZipEntryInputStream(decoded, this, e.name, e.uncompressedSize, e.crc)
    }

    /** 包内可见：中央目录原始项（含 external attributes，`unzip` 判符号链接要用）。 */
    internal func internalEntries(): ArrayList<CentralEntry> {
        ensureOpen()
        rawEntries
    }

    /** 释放 `init(path)` 打开的文件句柄；幂等。 */
    public func close(): Unit {
        if (!closed) {
            closed = true
            source.close()
        }
    }

    // ---- 内部 ----

    private func ensureOpen(): Unit {
        if (closed) {
            throw ZipException("ZipReader 已关闭")
        }
    }

    private func findLast(name: String): ?CentralEntry {
        var found = None<CentralEntry>
        for (e in rawEntries) {
            if (e.name == name) {
                found = Some(e)
            }
        }
        found
    }

    private func loadDirectory(): Unit {
        let info = locateEocd(source)
        if (info.entryCount > limits.maxEntries) {
            throw ZipException("条目数 ${info.entryCount} 超过上限 ${limits.maxEntries}")
        }
        if (info.entryCount == 0) {
            return
        }
        let cdBytes = readFullyAt(source, info.cdOffset, info.cdSize)
        let buf = ByteBuffer(cdBytes)
        var i: Int64 = 0
        while (i < info.entryCount) {
            rawEntries.add(readCentralHeader(buf))
            i += 1
        }
    }

    /** 检查加密 / 压缩方法 / 条目大小上限，不合格直接抛。 */
    private func checkEntryReadable(e: CentralEntry): Unit {
        if ((e.flags & ZipLayout.FLAG_ENCRYPTED) != 0 || (e.flags & ZipLayout.FLAG_STRONG_ENCRYPTION) != 0) {
            throw ZipException("不支持加密 ZIP（${e.name}）")
        }
        if (e.method != 0 && e.method != 8) {
            throw ZipException("不支持压缩方法 ${e.method}（${e.name}）")
        }
        if (e.uncompressedSize > limits.maxEntrySize) {
            throw ZipException("解压体积超过上限 ${limits.maxEntrySize}（${e.name}）")
        }
        if (e.compressedSize > 0 && e.uncompressedSize > 0 &&
            e.uncompressedSize / e.compressedSize > limits.ratioWarnThreshold) {
            logger.warn("zip: 条目 ${e.name} 压缩比 ${e.uncompressedSize / e.compressedSize} 超过告警阈值 ${limits.ratioWarnThreshold}")
        }
    }

    /**
     * 用 local header 定位数据起点：**只**用来跳过 name 与 extra，
     * crc / 大小 / 方法一律以中央目录为准（bit 3 置位时 local header 里可能是 0）。
     */
    private func locateData(e: CentralEntry): Int64 {
        let head = Array<Byte>(ZipLayout.LOCAL_HEADER_SIZE, repeat: 0)
        let got = source.readAt(e.localHeaderOffset, head)
        if (got != ZipLayout.LOCAL_HEADER_SIZE) {
            throw ZipException("条目 ${e.name} 的 local header 截断")
        }
        let nameLen = Int64(u16At(head, 26))
        let extraLen = Int64(u16At(head, 28))
        let total = ZipLayout.LOCAL_HEADER_SIZE + nameLen + extraLen
        // 完整解一遍：签名、ZIP64 extra 的自洽性都在这里校验，
        // 但**只用它的 name/extra 长度定位数据起点**——crc / 大小 / 方法以中央目录为准。
        let full = readFullyAt(source, e.localHeaderOffset, total, message: "条目 ${e.name} 的 local header 截断")
        let buf = ByteBuffer(full)
        let header = readLocalHeader(buf)
        header.dataOffset = total
        e.localHeaderOffset + total
    }

    private func wrapMethod(raw: InputStream, method: UInt16, name: String): InputStream {
        match (method) {
            case 0 => raw
            case 8 => DecompressInputStream(raw, wrap: WrapType.DeflateFormat, bufLen: 8192)
            case _ => throw ZipException("不支持压缩方法 ${method}（${name}）")
        }
    }

    private func decodeEntry(e: CentralEntry): Array<Byte> {
        checkEntryReadable(e)
        let dataOffset = locateData(e)
        let raw = source.openRange(dataOffset, e.compressedSize)
        let decoded = wrapMethod(raw, e.method, e.name)
        let out = ByteBuffer(initialCapacity: 8192)
        let chunk = Array<Byte>(8192, repeat: 0)
        var crc = crc32Init()
        var produced: Int64 = 0
        var n = safeRead(decoded, chunk, e.name)
        while (n > 0) {
            account(n, e.name, produced)
            produced += n
            crc = crc32Update(crc, chunk[0..n])
            out.write(chunk[0..n])
            n = safeRead(decoded, chunk, e.name)
        }
        verifyEntry(e.name, produced, crc32Finish(crc), e.uncompressedSize, e.crc)
        out.bytes()
    }

    /** 累计限额记账：先判单条目，再判本实例累计（按**实际解压出的字节**）。 */
    internal func account(n: Int64, name: String, producedSoFar: Int64): Unit {
        if (producedSoFar + n > limits.maxEntrySize) {
            throw ZipException("解压体积超过上限 ${limits.maxEntrySize}（${name}）")
        }
        let before = consumed.fetchAdd(n)
        if (before + n > limits.maxTotalSize) {
            throw ZipException("解压体积超过上限 ${limits.maxTotalSize}（${name}）")
        }
    }

    private func verifyEntry(name: String, produced: Int64, actualCrc: UInt32, expectedSize: Int64, expectedCrc: UInt32): Unit {
        if (produced != expectedSize) {
            throw ZipException("条目 ${name} 数据不完整：期望 ${expectedSize} 字节，实际 ${produced} 字节")
        }
        if (actualCrc != expectedCrc) {
            throw ZipException("CRC 校验失败：期望 ${expectedCrc}，实际 ${actualCrc}（${name}）")
        }
    }
}

/** `open(name)` 返回的流：读满之后校验 CRC 与大小。 */
internal class ZipEntryInputStream <: InputStream {
    private let inner: InputStream
    private let owner: ZipReader
    private let entryName: String
    private let expectedSize: Int64
    private let expectedCrc: UInt32
    private var produced: Int64 = 0
    private var crc: UInt32 = crc32Init()
    private var done: Bool = false

    public init(inner: InputStream, owner: ZipReader, entryName: String, expectedSize: Int64, expectedCrc: UInt32) {
        this.inner = inner
        this.owner = owner
        this.entryName = entryName
        this.expectedSize = expectedSize
        this.expectedCrc = expectedCrc
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (done) {
            return -1
        }
        let n = safeRead(inner, buffer, entryName)
        if (n <= 0) {
            done = true
            if (produced != expectedSize) {
                throw ZipException("条目 ${entryName} 数据不完整：期望 ${expectedSize} 字节，实际 ${produced} 字节")
            }
            let actual = crc32Finish(crc)
            if (actual != expectedCrc) {
                throw ZipException("CRC 校验失败：期望 ${expectedCrc}，实际 ${actual}（${entryName}）")
            }
            return -1
        }
        owner.account(n, entryName, produced)
        produced += n
        crc = crc32Update(crc, buffer[0..n])
        n
    }
}

/** 把整个流读进内存。 */
internal func readAllBytes(input: InputStream): Array<Byte> {
    let buf = ByteBuffer(initialCapacity: 8192)
    let chunk = Array<Byte>(8192, repeat: 0)
    var n = input.read(chunk)
    while (n > 0) {
        buf.write(chunk[0..n])
        n = input.read(chunk)
    }
    buf.bytes()
}
