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

import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_util.crc32

@Test
public class Eocd_test {
    /** 场景「空 ZIP」。 */
    @TestCase
    public func emptyZip(): Unit {
        let out = ByteBuffer()
        writeU32LE(out, ZipLayout.SIGNATURE_EOCD)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU16LE(out, 0)
        writeU32LE(out, 0)
        writeU32LE(out, 0)
        writeU16LE(out, 0)
        let bytes = out.bytes()
        let reader = readerOf(bytes)
        @Assert(reader.entries().size, 0)
    }

    /** 场景「注释里嵌了 EOCD 签名」。 */
    @TestCase
    public func commentContainingEocdSignature(): Unit {
        let entry = RawEntrySpec("a.txt", "abc".toArray())
        // 注释里放一个假的 EOCD 签名，后面跟着足够的字节让"距离自洽"不成立
        let comment: Array<Byte> = [0x50u8, 0x4Bu8, 0x05u8, 0x06u8, 0x00u8, 0x00u8, 0x00u8]
        let bytes = buildRawZip([entry], comment: comment)
        let reader = readerOf(bytes)
        @Assert(reader.entries().size, 1)
        @Assert(reader.entries()[0].name, "a.txt")
        expectBytesEqual(reader.read("a.txt").getOrThrow(), "abc".toArray())
    }

    /** 场景「尾部窗口内找不到 EOCD」。 */
    @TestCase
    public func truncatedInputFails(): Unit {
        assertZipError({=> readerOf([0x50u8, 0x4Bu8, 0x03u8, 0x04u8])}, "不是有效的 ZIP 文件（未找到中央目录）")
    }

    /** 场景「CD 偏移越界」。 */
    @TestCase
    public func cdOffsetOutOfRange(): Unit {
        let bytes = buildRawZip([RawEntrySpec("a.txt", "abc".toArray())])
        let eocd = Int64(bytes.size) - 22
        // 把 CD 偏移改成远超文件长度的值
        let corrupted = Array<Byte>(bytes.size, repeat: 0)
        bytes.copyTo(corrupted, 0, 0, bytes.size)
        let huge = u32LEBytes(0x7FFFFFF)
        corrupted[eocd + 16] = huge[0]
        corrupted[eocd + 17] = huge[1]
        corrupted[eocd + 18] = huge[2]
        corrupted[eocd + 19] = huge[3]
        assertZipError({=> readerOf(corrupted)}, "中央目录偏移")
    }

    /** 场景「不越界时不查 ZIP64」+「有哨兵时读定位器与 EOCD64」。 */
    @TestCase
    public func zip64ChainIsRead(): Unit {
        let bytes = buildZip64Sample(false)
        let reader = readerOf(bytes)
        @Assert(reader.entries().size, 1)
        @Assert(reader.entries()[0].name, "a.txt")
        expectBytesEqual(reader.read("a.txt").getOrThrow(), "hi".toArray())
    }

    /**
     * 场景「路径构造的尾部窗口上界」的边界：EOCD 落在窗口之外时**直接失败**，
     * 不退化成全文件扫描（否则"文件损坏"会被拖成"读完整个文件才报错"）。
     */
    @TestCase
    public func eocdOutsideTailWindowIsNotFound(): Unit {
        let base = buildRawZip([RawEntrySpec("a.txt", "abc".toArray())])
        // 末尾追加 70 KB 垃圾：真正的 EOCD 已经被推到 22 + 65535 窗口之外
        let padding = Array<Byte>(70 * 1024, repeat: 0x5A)
        let corrupted = Array<Byte>(base.size + padding.size, repeat: 0)
        base.copyTo(corrupted, 0, 0, base.size)
        padding.copyTo(corrupted, 0, base.size, padding.size)
        assertZipError({=> readerOf(corrupted)}, "不是有效的 ZIP 文件（未找到中央目录）")
    }

    /** 场景「定位器签名不匹配」。 */
    @TestCase
    public func brokenLocatorSignature(): Unit {
        let bytes = buildZip64Sample(true)
        assertZipError({=> readerOf(bytes)}, "ZIP64 定位器")
    }

    /**
     * 场景「分卷 ZIP 读到即报错」：普通 EOCD 的 *disk number*（+4）与
     * *disk with CD*（+6）非 0 时直接拒绝，不往下解析。
     */
    @TestCase
    public func splitArchiveEocdDiskFieldsRejected(): Unit {
        let base = buildRawZip([RawEntrySpec("a.txt", "abc".toArray())])
        let eocd = Int64(base.size) - 22
        var offset: Int64 = 4
        while (offset <= 6) {
            let corrupted = cloneBytes(base)
            corrupted[eocd + offset] = 1
            assertZipError({=> readerOf(corrupted)}, "分卷")
            offset += 2
        }
    }

    /**
     * 场景「带 ZIP64 的分卷 ZIP 读到即报错」：EOCD64 的两个 4 字节 disk 字段
     * （+16 / +20）非 0 时同样拒绝。
     */
    @TestCase
    public func splitArchiveZip64DiskFieldsRejected(): Unit {
        let base = buildZip64Sample(false)
        // 布局：EOCD64(56) → 定位器(20) → 普通 EOCD(22)
        let eocd64 = Int64(base.size) - 22 - 20 - 56
        var offset: Int64 = 16
        while (offset <= 20) {
            let corrupted = cloneBytes(base)
            corrupted[eocd64 + offset] = 1
            assertZipError({=> readerOf(corrupted)}, "分卷")
            offset += 4
        }
    }
}

private func cloneBytes(bytes: Array<Byte>): Array<Byte> {
    let copy = Array<Byte>(bytes.size, repeat: 0)
    bytes.copyTo(copy, 0, 0, bytes.size)
    copy
}

/** 构造一个 ZIP64 样本：1 条 Stored 条目 + EOCD64 + 定位器 + 带哨兵的普通 EOCD。 */
internal func buildZip64Sample(breakLocator: Bool): Array<Byte> {
    let data = "hi".toArray()
    let name = "a.txt".toArray()
    let crc = crc32(data)
    let out = ByteBuffer()

    writeU32LE(out, ZipLayout.SIGNATURE_LOCAL)
    writeU16LE(out, 45)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU32LE(out, crc)
    writeU32LE(out, UInt32(data.size))
    writeU32LE(out, UInt32(data.size))
    writeU16LE(out, UInt16(name.size))
    writeU16LE(out, 0)
    out.write(name)
    out.write(data)

    let cdStart = Int64(out.bytes().size)
    writeU32LE(out, ZipLayout.SIGNATURE_CENTRAL)
    writeU16LE(out, ZipLayout.VERSION_MADE_BY_UNIX)
    writeU16LE(out, 45)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU32LE(out, crc)
    writeU32LE(out, UInt32(data.size))
    writeU32LE(out, UInt32(data.size))
    writeU16LE(out, UInt16(name.size))
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU32LE(out, 0)
    writeU32LE(out, 0)
    out.write(name)
    let cdSize = Int64(out.bytes().size) - cdStart

    let eocd64Offset = Int64(out.bytes().size)
    writeU32LE(out, ZipLayout.SIGNATURE_EOCD64)
    writeU64LE(out, 44)
    writeU16LE(out, ZipLayout.VERSION_MADE_BY_UNIX)
    writeU16LE(out, 45)
    writeU32LE(out, 0)
    writeU32LE(out, 0)
    writeU64LE(out, 1)
    writeU64LE(out, 1)
    writeU64LE(out, UInt64(cdSize))
    writeU64LE(out, UInt64(cdStart))

    writeU32LE(out, if (breakLocator) {
        0x12345678
    } else {
        ZipLayout.SIGNATURE_EOCD64_LOCATOR
    })
    writeU32LE(out, 0)
    writeU64LE(out, UInt64(eocd64Offset))
    writeU32LE(out, 1)

    writeU32LE(out, ZipLayout.SIGNATURE_EOCD)
    writeU16LE(out, 0)
    writeU16LE(out, 0)
    writeU16LE(out, 0xFFFF)
    writeU16LE(out, 0xFFFF)
    writeU32LE(out, 0xFFFFFFFF)
    writeU32LE(out, 0xFFFFFFFF)
    writeU16LE(out, 0)
    out.bytes()
}
