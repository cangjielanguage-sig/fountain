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

import fountain::f_io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class LocalHeader_test {
    /** 场景「30 字节头往返」。 */
    @TestCase
    public func roundTrip(): Unit {
        let h = LocalHeader()
        h.versionNeeded = 20
        h.flags = ZipLayout.FLAG_UTF8_NAME
        h.method = 8
        h.dosTime = 0x6E4E
        h.dosDate = 0x5A3C
        h.crc = 0xDEADBEEF
        h.compressedSize = 1234
        h.uncompressedSize = 5678
        h.nameBytes = "中文.txt".toArray()

        let out = ByteBuffer()
        writeLocalHeader(out, h)
        let bytes = out.bytes()
        @Assert(u32At(bytes, 0), ZipLayout.SIGNATURE_LOCAL)

        let buf = ByteBuffer(bytes)
        let back = readLocalHeader(buf)
        @Assert(back.versionNeeded, 20u16)
        @Assert(back.flags, ZipLayout.FLAG_UTF8_NAME)
        @Assert(back.method, 8u16)
        @Assert(back.dosTime, 0x6E4Eu16)
        @Assert(back.dosDate, 0x5A3Cu16)
        @Assert(back.crc, 0xDEADBEEFu32)
        @Assert(back.compressedSize, 1234)
        @Assert(back.uncompressedSize, 5678)
        @Assert(back.nameBytes.size, "中文.txt".toArray().size)
    }

    /** 场景「bit 3 为 0 时写真实值」。 */
    @TestCase
    public func memoryPathWritesRealValues(): Unit {
        let h = LocalHeader()
        h.crc = 42
        h.compressedSize = 7
        h.uncompressedSize = 9
        h.nameBytes = "a".toArray()
        let out = ByteBuffer()
        writeLocalHeader(out, h)
        let bytes = out.bytes()
        @Assert(u16At(bytes, 6), 0u16)                    // flags
        @Assert(u32At(bytes, 14), 42u32)                  // crc
        @Assert(Int64(u32At(bytes, 18)), 7)               // compressed
        @Assert(Int64(u32At(bytes, 22)), 9)               // uncompressed
        @Assert(u16At(bytes, 4), 20u16)                   // version needed
    }

    /** 流式 header：bit 3 置位、version 45、extra `0x0001` 两个 8 字节值都是 0。 */
    @TestCase
    public func streamingHeaderPlaceholders(): Unit {
        let h = LocalHeader()
        h.nameBytes = "big.bin".toArray()
        h.streaming = true
        let out = ByteBuffer()
        writeLocalHeader(out, h)
        let bytes = out.bytes()
        @Assert(u16At(bytes, 4), 45u16)
        @Assert(u16At(bytes, 6) & ZipLayout.FLAG_DATA_DESCRIPTOR, ZipLayout.FLAG_DATA_DESCRIPTOR)
        @Assert(u32At(bytes, 14), 0u32)
        @Assert(u32At(bytes, 18), 0u32)
        @Assert(u32At(bytes, 22), 0u32)
        @Assert(Int64(u16At(bytes, 28)), 20)              // extra 长度 = 4 + 16
        let extraStart = 30 + h.nameBytes.size
        @Assert(u16At(bytes, extraStart), ZipLayout.ZIP64_EXTRA_ID)
        @Assert(u16At(bytes, extraStart + 2), 16u16)
        @Assert(u64At(bytes, extraStart + 4), 0u64)
        @Assert(u64At(bytes, extraStart + 12), 0u64)
    }

    /** 场景「ZIP64 extra 按固定顺序只含越界项」。 */
    @TestCase
    public func zip64ExtraOnlyOverflowFields(): Unit {
        // 只有 originalSize 越界
        let onlyOriginal = buildZip64Extra(0x1_0000_0000, true, 100, false, 0, false, 0, false)
        @Assert(u16At(onlyOriginal, 0), ZipLayout.ZIP64_EXTRA_ID)
        @Assert(Int64(u16At(onlyOriginal, 2)), 8)
        @Assert(Int64(u64At(onlyOriginal, 4)), 0x1_0000_0000)

        // originalSize + localHeaderOffset 越界，compressedSize 不越界
        let two = buildZip64Extra(0x1_0000_0000, true, 100, false, 0x1_0000_0000, true, 0, false)
        @Assert(Int64(u16At(two, 2)), 16)
        @Assert(Int64(u64At(two, 4)), 0x1_0000_0000)
        @Assert(Int64(u64At(two, 12)), 0x1_0000_0000)

        let parsed = parseZip64Extra(two, true, false, true, false, "a.txt")
        @Assert(parsed.originalSize.getOrThrow(), 0x1_0000_0000)
        @Assert(parsed.compressedSize.isNone(), true)
        @Assert(parsed.localHeaderOffset.getOrThrow(), 0x1_0000_0000)

        // 都不越界 → 不产生任何 extra 字节
        @Assert(buildZip64Extra(0, false, 0, false, 0, false, 0, false).size, 0)
    }

    /** 场景「ZIP64 extra 长度不足即拒绝」。 */
    @TestCase
    public func zip64ExtraTooShort(): Unit {
        // 声明长度 8，但两个字段都需要（16 字节）
        let short = concatBytes([u16LEBytes(ZipLayout.ZIP64_EXTRA_ID), u16LEBytes(8), u64LEBytes(1)])
        assertZipError({=> parseZip64Extra(short, true, true, false, false, "a.txt")}, "ZIP64 extra 长度不足")
        assertZipError({=> parseZip64Extra(Array<Byte>(), true, false, false, false, "a.txt")}, "ZIP64 extra 长度不足")
    }

    /** 大条目 header 自动升级 ZIP64（字段写哨兵 + extra 放真实值）。 */
    @TestCase
    public func bigEntryUsesZip64(): Unit {
        let h = LocalHeader()
        h.nameBytes = "huge.bin".toArray()
        h.compressedSize = 0x1_0000_0000
        h.uncompressedSize = 0x1_0000_0000
        let out = ByteBuffer()
        writeLocalHeader(out, h)
        let bytes = out.bytes()
        @Assert(u16At(bytes, 4), 45u16)
        @Assert(u32At(bytes, 18), 0xFFFFFFFFu32)
        @Assert(u32At(bytes, 22), 0xFFFFFFFFu32)
        let back = readLocalHeader(ByteBuffer(bytes))
        @Assert(back.compressedSize, 0x1_0000_0000)
        @Assert(back.uncompressedSize, 0x1_0000_0000)
    }
}

@Test
public class CentralHeader_test {
    /** 场景「46 字节头往返」。 */
    @TestCase
    public func roundTrip(): Unit {
        let e = CentralEntry()
        e.versionMadeBy = 0x031E
        e.versionNeeded = 20
        e.flags = ZipLayout.FLAG_UTF8_NAME
        e.method = 8
        e.dosTime = 0x1234
        e.dosDate = 0x5678
        e.crc = 0xCAFEBABE
        e.compressedSize = 111
        e.uncompressedSize = 222
        e.internalAttributes = 1
        e.externalAttributes = 0x81A40000
        e.localHeaderOffset = 33
        e.nameBytes = "dir/文件.txt".toArray()

        let out = ByteBuffer()
        writeCentralHeader(out, e)
        let bytes = out.bytes()
        @Assert(Int64(bytes.size), Int64(ZipLayout.CENTRAL_HEADER_SIZE) + e.nameBytes.size)

        let back = readCentralHeader(ByteBuffer(bytes))
        @Assert(back.versionMadeBy, 0x031Eu16)
        @Assert(back.versionNeeded, 20u16)
        @Assert(back.flags, ZipLayout.FLAG_UTF8_NAME)
        @Assert(back.method, 8u16)
        @Assert(back.dosTime, 0x1234u16)
        @Assert(back.dosDate, 0x5678u16)
        @Assert(back.crc, 0xCAFEBABEu32)
        @Assert(back.compressedSize, 111)
        @Assert(back.uncompressedSize, 222)
        @Assert(back.internalAttributes, 1u16)
        @Assert(back.externalAttributes, 0x81A40000u32)
        @Assert(back.localHeaderOffset, 33)
        @Assert(back.name, "dir/文件.txt")
    }

    /** 场景「注释被完整跳过」：两条带注释的 central header 连续解析。 */
    @TestCase
    public func commentsAreSkipped(): Unit {
        let first = CentralEntry()
        first.nameBytes = "a".toArray()
        first.comment = "first comment".toArray()
        let second = CentralEntry()
        second.nameBytes = "b".toArray()
        second.comment = "second".toArray()
        let out = ByteBuffer()
        writeCentralHeader(out, first)
        writeCentralHeader(out, second)

        let buf = ByteBuffer(out.bytes())
        let a = readCentralHeader(buf)
        @Assert(a.name, "a")
        @Assert(a.comment.size, 13)
        let b = readCentralHeader(buf)
        @Assert(b.name, "b")
        @Assert(b.comment.size, 6)
    }

    /** ZIP64 哨兵 + extra：字段值从 extra 里还原。 */
    @TestCase
    public func zip64SentinelsResolved(): Unit {
        let e = CentralEntry()
        e.nameBytes = "big".toArray()
        e.compressedSize = 0x1_0000_0000
        e.uncompressedSize = 0x2_0000_0000
        e.localHeaderOffset = 0x3_0000_0000
        let out = ByteBuffer()
        writeCentralHeader(out, e)
        let bytes = out.bytes()
        @Assert(Int64(u16At(bytes, 6)), Int64(ZipLayout.VERSION_ZIP64))
        @Assert(u32At(bytes, 20), 0xFFFFFFFFu32)
        @Assert(u32At(bytes, 24), 0xFFFFFFFFu32)
        @Assert(u32At(bytes, 42), 0xFFFFFFFFu32)
        let back = readCentralHeader(ByteBuffer(bytes))
        @Assert(back.compressedSize, 0x1_0000_0000)
        @Assert(back.uncompressedSize, 0x2_0000_0000)
        @Assert(back.localHeaderOffset, 0x3_0000_0000)
    }
}
