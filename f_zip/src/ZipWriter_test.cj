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

import std.env
import std.fs.{Directory, File, Path, SymbolicLink, removeIfExists}
import std.io.{ByteBuffer, InputStream, OutputStream}
import std.sync.AtomicBool
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_util.crc32

@Test
public class ZipWriter_test {
    private static func text(value: String): Array<Byte> {
        value.toArray()
    }

    // ---- 基础往返 ----

    /** 场景「内存路径的 header 字段」。 */
    @TestCase
    public func addWritesRealHeaderWithoutDescriptor(): Unit {
        let data = text("hello zip")
        let bytes = buildZipBytes({w => w.add("a.txt", data)})
        let header = parseLocalHeaderAt(bytes, 0)
        @Assert(header.flags & ZipLayout.FLAG_DATA_DESCRIPTOR, 0u16)
        @Assert(header.crc, crc32(data))
        @Assert(header.uncompressedSize, Int64(data.size))
        @Assert(header.versionNeeded, 20u16)

        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        @Assert(entry.crc32, header.crc)
        @Assert(entry.uncompressedSize, Int64(data.size))
        // 数据之后紧跟中央目录，没有 0x08074b50
        let dataOffset = 30 + header.nameBytes.size + Int64(u16At(bytes, 28))
        @Assert(u32At(bytes, dataOffset + entry.compressedSize), ZipLayout.SIGNATURE_CENTRAL)
        expectBytesEqual(reader.read("a.txt").getOrThrow(), data)
    }

    @TestCase
    public func deflateRoundTrip(): Unit {
        let data = text("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let bytes = buildZipBytes({w => w.add("a.txt", data)})
        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        @Assert(entry.method, 8u16)
        @Assert(entry.compressedSize < entry.uncompressedSize, true)
        expectBytesEqual(reader.read("a.txt").getOrThrow(), data)
    }

    /** 场景「Stored 方法」。 */
    @TestCase
    public func storedRoundTrip(): Unit {
        let data = text("stored payload")
        let options = ZipWriterOptions(method: CompressionMethod.Stored)
        let bytes = buildZipBytes({w => w.add("s.bin", data)}, options: options)
        let entry = readerOf(bytes).entries()[0]
        @Assert(entry.method, 0u16)
        @Assert(entry.compressedSize, Int64(data.size))
        expectBytesEqual(readerOf(bytes).read("s.bin").getOrThrow(), data)
    }

    /** 场景「空数据条目」。 */
    @TestCase
    public func emptyEntry(): Unit {
        let bytes = buildZipBytes({w => w.add("empty.txt", Array<Byte>())})
        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        @Assert(entry.uncompressedSize, 0)
        @Assert(entry.crc32, 0u32)
        @Assert(reader.read("empty.txt").getOrThrow().size, 0)
    }

    /** 场景「空包」。 */
    @TestCase
    public func emptyArchive(): Unit {
        let bytes = buildZipBytes({_ => ()})
        let reader = readerOf(bytes)
        @Assert(reader.entries().size, 0)
        @Assert(bytes.size, 22)
    }

    /** 场景「重复 close」。 */
    @TestCase
    public func closeIsIdempotent(): Unit {
        let out = ByteBuffer()
        let w = ZipWriter(out)
        w.add("a.txt", text("a"))
        w.close()
        let first = out.bytes().size
        w.close()
        @Assert(out.bytes().size, first)
    }

    /**
     * 场景「重复 close」的失败分支：写中央目录失败时 `close()` **不能**先把
     * 自己置成已关闭，否则第二次 `close()` 静默返回，磁盘上留下半截文件。
     */
    @TestCase
    public func closeFailureDoesNotMarkClosed(): Unit {
        let options = ZipWriterOptions(method: CompressionMethod.Stored)
        // 先探出中央目录起点：条目字节数固定（Stored 不膨胀）
        let probe = CountingSink()
        let probeWriter = ZipWriter(probe, options: options)
        probeWriter.add("a.txt", text("abc"))
        let cdStart = probeWriter.position
        probeWriter.close()

        let sink = FailingOutputStream(cdStart)
        let writer = ZipWriter(sink, options: options)
        writer.add("a.txt", text("abc"))
        assertZipError({=> writer.close()}, "sink boom")
        @Assert(sink.count, cdStart)
        // 第二次仍然要抛：不静默成功
        assertZipError({=> writer.close()}, "sink boom")
    }

    /** 未 close 的产物不可读（没有 EOCD）。 */
    @TestCase
    public func unclosedOutputIsUnreadable(): Unit {
        let out = ByteBuffer()
        let w = ZipWriter(out)
        w.add("a.txt", text("a"))
        let bytes = out.bytes()
        assertZipError({=> ZipReader(ByteBuffer(bytes))}, "不是有效的 ZIP 文件")
    }

    // ---- 流式路径 ----

    /** 场景「header 的流式标记」+「descriptor 长度固定 24 字节」。 */
    @TestCase
    public func streamingHeaderAndDescriptor(): Unit {
        let data = text("stream content")
        let bytes = buildZipBytes({w => w.addFileStream("big.bin", ByteBuffer(data))})
        let header = parseLocalHeaderAt(bytes, 0)
        @Assert(header.flags & ZipLayout.FLAG_DATA_DESCRIPTOR, ZipLayout.FLAG_DATA_DESCRIPTOR)
        @Assert(header.versionNeeded, 45u16)
        @Assert(header.crc, 0u32)
        @Assert(header.compressedSize, 0)
        @Assert(header.uncompressedSize, 0)

        let extraLen = Int64(u16At(bytes, 28))
        @Assert(extraLen > 0, true)
        let extraStart = 30 + header.nameBytes.size
        @Assert(u16At(bytes, extraStart), ZipLayout.ZIP64_EXTRA_ID)
        @Assert(u16At(bytes, extraStart + 2), 16u16)
        @Assert(u64At(bytes, extraStart + 4), 0u64)
        @Assert(u64At(bytes, extraStart + 12), 0u64)

        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        let descriptorOffset = 30 + Int64(header.nameBytes.size) + extraLen + entry.compressedSize
        @Assert(u32At(bytes, descriptorOffset), ZipLayout.SIGNATURE_DATA_DESCRIPTOR)
        @Assert(u32At(bytes, descriptorOffset + 4), entry.crc32)
        @Assert(Int64(u64At(bytes, descriptorOffset + 8)), entry.compressedSize)
        @Assert(Int64(u64At(bytes, descriptorOffset + 16)), entry.uncompressedSize)
        // 紧跟其后的是下一条结构（这里只有一条条目，所以是中央目录）
        @Assert(u32At(bytes, descriptorOffset + 24), ZipLayout.SIGNATURE_CENTRAL)
        expectBytesEqual(reader.read("big.bin").getOrThrow(), data)
    }

    /** 场景「小内容也用 ZIP64 形式」。 */
    @TestCase
    public func tinyStreamingStillUsesZip64Descriptor(): Unit {
        let bytes = buildZipBytes({w => w.addFileStream("t.bin", ByteBuffer(text("0123456789")))})
        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        let header = parseLocalHeaderAt(bytes, 0)
        let descriptorOffset = 30 + Int64(header.nameBytes.size) + Int64(u16At(bytes, 28)) + entry.compressedSize
        @Assert(u32At(bytes, descriptorOffset), ZipLayout.SIGNATURE_DATA_DESCRIPTOR)
        @Assert(u32At(bytes, descriptorOffset + 24), ZipLayout.SIGNATURE_CENTRAL)
    }

    /** 场景「CRC 作用于原始字节」+「混合样本被自身读回」。 */
    @TestCase
    public func mixedPaths(): Unit {
        let a = text("alpha alpha alpha alpha")
        let b = text("bravo bravo bravo bravo")
        let c = text("charlie")
        let bytes = buildZipBytes(
            {w =>
                w.add("a.txt", a)
                w.addFileStream("b.bin", ByteBuffer(b))
                w.add("c.txt", c)
            }
        )
        let reader = readerOf(bytes)
        let entries = reader.entries()
        let raw = reader.internalEntries()
        @Assert(entries.size, 3)
        @Assert(entries[0].name, "a.txt")
        @Assert(entries[1].name, "b.bin")
        @Assert(entries[2].name, "c.txt")
        @Assert(raw[0].flags & ZipLayout.FLAG_DATA_DESCRIPTOR, 0u16)
        @Assert(raw[1].flags & ZipLayout.FLAG_DATA_DESCRIPTOR, ZipLayout.FLAG_DATA_DESCRIPTOR)
        @Assert(raw[2].flags & ZipLayout.FLAG_DATA_DESCRIPTOR, 0u16)
        expectBytesEqual(reader.read("a.txt").getOrThrow(), a)
        expectBytesEqual(reader.read("b.bin").getOrThrow(), b)
        expectBytesEqual(reader.read("c.txt").getOrThrow(), c)
        @Assert(entries[1].crc32, crc32(b))
    }

    // ---- 目录 / 中文名 ----

    /** 场景「自动补斜杠」+「目录条目的字段」。 */
    @TestCase
    public func directoryEntry(): Unit {
        let bytes = buildZipBytes({w => w.addDirectory("sub")})
        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        @Assert(entry.name, "sub/")
        @Assert(entry.isDirectory, true)
        @Assert(entry.uncompressedSize, 0)
        @Assert(entry.compressedSize, 0)
        @Assert(entry.method, 0u16)
        @Assert(entry.crc32, 0u32)
        let raw = reader.internalEntries()[0]
        @Assert((raw.externalAttributes >> 16), 0x41EDu32)
    }

    /** 场景「同名目录合并」。 */
    @TestCase
    public func duplicateDirectoryMerged(): Unit {
        let (bytes, names) = buildZipWithResult({w => (w.addDirectory("d"), w.addDirectory("d"))})
        @Assert(names[0], "d/")
        @Assert(names[1], "d/")
        @Assert(readerOf(bytes).entries().size, 1)
    }

    /** 场景「中文名置位 bit 11」+ 往返。 */
    @TestCase
    public func chineseName(): Unit {
        let data = text("中")
        let bytes = buildZipBytes({w => w.add("中文/文件.txt", data)})
        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        @Assert(entry.name, "中文/文件.txt")
        @Assert(reader.internalEntries()[0].flags & ZipLayout.FLAG_UTF8_NAME, ZipLayout.FLAG_UTF8_NAME)
        expectBytesEqual(reader.read("中文/文件.txt").getOrThrow(), data)
    }

    // ---- 同名消解 ----

    /** 场景「连续三次同名」/「无扩展名」/「点开头的隐藏文件」/「末尾点」。 */
    @TestCase
    public func duplicateNames(): Unit {
        let (_, names) = buildZipWithResult(
            {w => [w.add("a.txt", text("1")), w.add("a.txt", text("2")), w.add("a.txt", text("3"))]}
        )
        @Assert(names[0], "a.txt")
        @Assert(names[1], "a_2.txt")
        @Assert(names[2], "a_3.txt")

        let (_, plain) = buildZipWithResult({w => [w.add("a", text("1")), w.add("a", text("2"))]})
        @Assert(plain[1], "a_2")

        let (_, hidden) = buildZipWithResult(
            {w => [w.add(".gitignore", text("1")), w.add(".gitignore", text("2"))]}
        )
        @Assert(hidden[1], ".gitignore_2")

        let (_, dotted) = buildZipWithResult({w => [w.add("a.", text("1")), w.add("a.", text("2"))]})
        @Assert(dotted[1], "a_2.")
    }

    /** 场景「改名后再撞名」。 */
    @TestCase
    public func renamedCollisionAgain(): Unit {
        let (_, names) = buildZipWithResult(
            {w => [w.add("a.txt", text("1")), w.add("a.txt", text("2")), w.add("a_2.txt", text("3"))]}
        )
        @Assert(names[2], "a_2_2.txt")
    }

    // ---- addFile ----

    /** 场景「写入磁盘文件」+「符号链接被跟随」+「路径不存在」。 */
    @TestCase
    public func addFileFollowsSymlinkAndRejectsMissing(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let real = work.join("real.txt")
            File.writeTo(real, text("real content"))
            let link = work.join("link.txt")
            SymbolicLink.create(link, to: real)

            let out = ByteBuffer()
            let writer = ZipWriter(out)
            @Assert(writer.addFile("real.txt", real), "real.txt")
            @Assert(writer.addFile("link.txt", link), "link.txt")
            writer.close()

            let reader = readerOf(out.bytes())
            expectBytesEqual(reader.read("real.txt").getOrThrow(), text("real content"))
            expectBytesEqual(reader.read("link.txt").getOrThrow(), text("real content"))
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
        let out = ByteBuffer()
        let writer = ZipWriter(out)
        assertZipError({=> writer.addFile("x", Path("/definitely/not/here/f_zip.txt"))}, "文件不存在")
    }

    // ---- position / spilling ----

    /** 场景「单调递增」+「不含中央目录」。 */
    @TestCase
    public func positionIsMonotonic(): Unit {
        let out = ByteBuffer()
        let w = ZipWriter(out)
        w.add("a.txt", text("a"))
        let p1 = w.position
        w.add("b.txt", text("b"))
        let p2 = w.position
        w.add("c.txt", text("c"))
        let p3 = w.position
        @Assert(p1 < p2, true)
        @Assert(p2 < p3, true)
        w.close()
        @Assert(p3 < Int64(out.bytes().size), true)
    }

    /** 场景「Linux 默认 64 MB / 非 Linux 默认 16 MB」。 */
    @TestCase
    public func defaultThresholdByPlatform(): Unit {
        @Assert(ZipWriterOptions().memoryEntryThreshold, expectedMemoryEntryThreshold())
        @Assert(ZipWriterOptions.forServer().memoryEntryThreshold, 64 * 1024 * 1024)
        @Assert(ZipWriterOptions.forLowMemory().memoryEntryThreshold, 8 * 1024 * 1024)
        // 预设互不影响：改一个不影响下一次取到的
        let a = ZipWriterOptions.forLowMemory()
        a.memoryEntryThreshold = 1
        @Assert(ZipWriterOptions.forLowMemory().memoryEntryThreshold, 8 * 1024 * 1024)
    }

    /** 场景「落盘期间 spilling 为真」：另一线程轮询，能观察到 true。 */
    @TestCase
    public func spillingObservedDuringSpill(): Unit {
        let options = ZipWriterOptions(memoryEntryThreshold: 1024)
        let out = ByteBuffer()
        let writer = ZipWriter(out, options: options)
        let seen = AtomicBool(false)
        let done = AtomicBool(false)
        let poller = spawn { =>
            while (!done.load()) {
                if (writer.spilling) {
                    seen.store(true)
                }
            }
            0
        }
        var i: Int64 = 0
        while (i < 4) {
            writer.add("big${i}.bin", Array<Byte>(8 * 1024 * 1024, repeat: UInt8(i)))
            i += 1
        }
        writer.close()
        done.store(true)
        let _ = poller.get()
        @Assert(seen.load(), true)
        @Assert(writer.spilling, false)
    }

    /** 场景「流式写入不改 spilling」。 */
    @TestCase
    public func streamingKeepsSpillingFalse(): Unit {
        let out = ByteBuffer()
        let w = ZipWriter(out)
        @Assert(w.spilling, false)
        w.addFileStream("a.bin", ByteBuffer(text("abc")))
        @Assert(w.spilling, false)
        w.close()
    }

    /** 场景「超过阈值走流式」+「落盘结束后复位」。 */
    @TestCase
    public func thresholdSpillsToStreaming(): Unit {
        let options = ZipWriterOptions(memoryEntryThreshold: 1024)
        let data = Array<Byte>(100 * 1024, repeat: 65)
        let out = ByteBuffer()
        let w = ZipWriter(out, options: options)
        w.add("big.bin", data)
        @Assert(w.spilling, false)
        w.close()
        let bytes = out.bytes()
        let header = parseLocalHeaderAt(bytes, 0)
        @Assert(header.flags & ZipLayout.FLAG_DATA_DESCRIPTOR, ZipLayout.FLAG_DATA_DESCRIPTOR)
        let reader = readerOf(bytes)
        expectBytesEqual(reader.read("big.bin").getOrThrow(), data)
    }

    /** 场景「未超阈值不进临时文件」。 */
    @TestCase
    public func belowThresholdStaysInMemory(): Unit {
        let options = ZipWriterOptions(memoryEntryThreshold: 1024 * 1024)
        let data = Array<Byte>(100 * 1024, repeat: 66)
        let bytes = buildZipBytes({w => w.add("a.bin", data)}, options: options)
        let header = parseLocalHeaderAt(bytes, 0)
        @Assert(header.flags & ZipLayout.FLAG_DATA_DESCRIPTOR, 0u16)
        expectBytesEqual(readerOf(bytes).read("a.bin").getOrThrow(), data)
    }

    // ---- 脏状态 ----

    /** 场景「脏状态下不能继续加条目」+「输入流中途抛错」。 */
    @TestCase
    public func dirtyStateBlocksFurtherWrites(): Unit {
        let out = ByteBuffer()
        let w = ZipWriter(out)
        let failing = FailingInputStream(text("abc"), 1)
        assertZipError({=> w.addFileStream("bad.bin", failing)}, "boom")
        assertZipError({=> w.add("x.txt", text("x"))}, "写入中断")
        assertZipError({=> w.close()}, "写入中断")
    }

    /**
     * 场景「三个阶段各自失败都进脏状态」：底层输出流分别打在
     * ① local header ② 压缩数据泵送 ③ data descriptor 上，
     * 三种情况都必须进脏状态，不能只保护泵送阶段。
     */
    @TestCase
    public func dirtyStateCoversHeaderPumpAndDescriptor(): Unit {
        let name = "a.bin"
        let data = text("payload")
        let options = ZipWriterOptions(method: CompressionMethod.Stored)
        // 流式 local header = 30 固定 + name + 20 字节 ZIP64 extra 占位（见 LocalHeader.cj）
        let headerLen = ZipLayout.LOCAL_HEADER_SIZE + Int64(name.toArray().size) + 20
        let dataEnd = headerLen + Int64(data.size)

        // 先用不失败的输出确认分段边界：Stored 不膨胀，descriptor 固定 24 字节
        let probe = CountingSink()
        let probeWriter = ZipWriter(probe, options: options)
        probeWriter.addFileStream(name, ByteBuffer(data))
        @Assert(probe.count, dataEnd + ZipLayout.DATA_DESCRIPTOR_SIZE)
        probeWriter.close()

        let failPoints = [0, headerLen, dataEnd]
        for (failAt in failPoints) {
            let sink = FailingOutputStream(failAt)
            let w = ZipWriter(sink, options: options)
            assertZipError({=> w.addFileStream(name, ByteBuffer(data))}, "sink boom")
            @Assert(sink.count, failAt)
            assertZipError({=> w.add("x.txt", text("x"))}, "写入中断")
            assertZipError({=> w.close()}, "写入中断")
        }
    }

    /** 场景「内存路径写失败也进脏状态」：header 与数据写入必须同等保护。 */
    @TestCase
    public func memoryPathWriteFailureMarksDirty(): Unit {
        let sink = FailingOutputStream(0)
        let w = ZipWriter(sink)
        assertZipError({=> w.add("a.txt", text("abc"))}, "sink boom")
        assertZipError({=> w.add("b.txt", text("b"))}, "写入中断")
        assertZipError({=> w.close()}, "写入中断")
    }

    // ---- ZIP64 ----

    /** 场景「小文件不产生 ZIP64 字节」。 */
    @TestCase
    public func smallArchiveHasNoZip64(): Unit {
        let bytes = buildZipBytes({w => w.add("a.txt", text("abc"))})
        @Assert(countSignature(bytes, u32LEBytes(ZipLayout.SIGNATURE_EOCD64)), 0)
        @Assert(countSignature(bytes, u32LEBytes(ZipLayout.SIGNATURE_EOCD64_LOCATOR)), 0)
        // 两条 header 的 extra 长度都是 0（没有被塞进 0x0001）
        @Assert(u16At(bytes, 28), 0u16)
        let reader = readerOf(bytes)
        let entry = reader.entries()[0]
        let centralOffset = 30 + Int64(u16At(bytes, 26)) + entry.compressedSize
        @Assert(u32At(bytes, centralOffset), ZipLayout.SIGNATURE_CENTRAL)
        @Assert(u16At(bytes, centralOffset + 30), 0u16)
        // 普通 EOCD 的条目数是真实值
        let eocd = Int64(bytes.size) - 22
        @Assert(u16At(bytes, eocd + 10), 1u16)
        @Assert(u16At(bytes, eocd + 8), 1u16)
    }
}

/** 读到第 `failAfter` 个字节后抛异常的输入流（模拟传输中断）。 */internal class FailingInputStream <: InputStream {
    private let data: Array<Byte>
    private let failAfter: Int64
    private var position: Int64 = 0

    public init(data: Array<Byte>, failAfter: Int64) {
        this.data = data
        this.failAfter = failAfter
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (position >= failAfter) {
            throw ZipException("boom")
        }
        if (position >= data.size) {
            return -1
        }
        let n = if (buffer.size < data.size - position) {
            buffer.size
        } else {
            data.size - position
        }
        data.copyTo(buffer, position, 0, n)
        position += n
        n
    }
}

/** 只计数不落字节的输出流：用来确认分段边界。 */
internal class CountingSink <: OutputStream {
    private var written: Int64 = 0

    public prop count: Int64 {
        get() {
            written
        }
    }

    public func write(buffer: Array<Byte>): Unit {
        written += buffer.size
    }
}

/**
 * 在第 `failAt` 字节处抛异常的输出流（模拟磁盘写失败）。
 *
 * 每次 `write` 前判累计字节数：`failAt` 落在某个 write 的边界上时，
 * 失败就发生在该 write 所属的阶段，不会撕开一次写入。
 */
internal class FailingOutputStream <: OutputStream {
    private let failAt: Int64
    private var written: Int64 = 0

    public init(failAt: Int64) {
        this.failAt = failAt
    }

    public prop count: Int64 {
        get() {
            written
        }
    }

    public func write(buffer: Array<Byte>): Unit {
        if (written >= failAt) {
            throw ZipException("sink boom")
        }
        written += buffer.size
    }
}
