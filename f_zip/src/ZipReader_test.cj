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

import std.io.{ByteBuffer, InputStream}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_util.crc32

@Test
public class ZipReader_test {
    /** 场景「顺序与中央目录一致」。 */
    @TestCase
    public func entriesKeepCentralDirectoryOrder(): Unit {
        let bytes = buildZipBytes(
            {w =>
                w.add("b.txt", "b".toArray())
                w.add("a.txt", "a".toArray())
                w.addDirectory("dir")
            }
        )
        let names = readerOf(bytes).entries()
        @Assert(names.size, 3)
        @Assert(names[0].name, "b.txt")
        @Assert(names[1].name, "a.txt")
        @Assert(names[2].name, "dir/")
        @Assert(names[2].isDirectory, true)
    }

    /** 场景「同名条目全部保留」+「同名取最后一个」+「readAll 返回全部」。 */
    @TestCase
    public func duplicateNamesReadLast(): Unit {
        let first = RawEntrySpec("x.txt", "A".toArray())
        let second = RawEntrySpec("x.txt", "B".toArray())
        let reader = readerOf(buildRawZip([first, second]))
        @Assert(reader.entries().size, 2)
        @Assert(String.fromUtf8(reader.read("x.txt").getOrThrow()), "B")
        let all = reader.readAll("x.txt")
        @Assert(all.size, 2)
        @Assert(String.fromUtf8(all[0]), "A")
        @Assert(String.fromUtf8(all[1]), "B")
    }

    /** 场景「修改返回列表不影响内部」。 */
    @TestCase
    public func entriesReturnsIndependentList(): Unit {
        let bytes = buildZipBytes({w => w.add("a.txt", "a".toArray())})
        let reader = readerOf(bytes)
        let first = reader.entries()
        first.clear()
        @Assert(reader.entries().size, 1)
    }

    /** 场景「名字不存在」+「contains」。 */
    @TestCase
    public func containsAndAbsent(): Unit {
        let bytes = buildZipBytes({w => w.add("a.txt", "a".toArray())})
        let reader = readerOf(bytes)
        @Assert(reader.contains("a.txt"), true)
        @Assert(reader.contains("absent.txt"), false)
        @Assert(reader.read("absent.txt").isNone(), true)
        @Assert(reader.open("absent.txt").isNone(), true)
    }

    /** 场景「不支持的方法报出具体数值」。 */
    @TestCase
    public func unsupportedMethodReportsNumber(): Unit {
        let entry = RawEntrySpec("weird.bin", "abc".toArray())
        entry.method = 12
        let reader = readerOf(buildRawZip([entry]))
        assertZipError({=> reader.read("weird.bin")}, "12")
        assertZipError({=> reader.read("weird.bin")}, "weird.bin")
    }

    @TestCase
    public func zstandardMethodRejected(): Unit {
        let entry = RawEntrySpec("z.bin", "abc".toArray())
        entry.method = 93
        let reader = readerOf(buildRawZip([entry]))
        assertZipError({=> reader.read("z.bin")}, "93")
    }

    /** 场景「普通加密（bit 0）」+「强加密（bit 6）」。 */
    @TestCase
    public func encryptedEntriesRejected(): Unit {
        let normal = RawEntrySpec("enc.bin", "abc".toArray())
        normal.flags = 1
        assertZipError({=> readerOf(buildRawZip([normal])).read("enc.bin")}, "不支持加密 ZIP")

        let strong = RawEntrySpec("enc2.bin", "abc".toArray())
        strong.flags = 0x40
        assertZipError({=> readerOf(buildRawZip([strong])).read("enc2.bin")}, "不支持加密 ZIP")
    }

    /** 场景「CRC 校验失败」。 */
    @TestCase
    public func crcMismatchReported(): Unit {
        let entry = RawEntrySpec("bad.txt", "abc".toArray())
        entry.crc = 0
        let reader = readerOf(buildRawZip([entry]))
        assertZipError({=> reader.read("bad.txt")}, "CRC 校验失败")
    }

    /** 场景「大小不符」：中央目录声明 5 字节，实际 3 字节。 */
    @TestCase
    public func sizeMismatchReported(): Unit {
        let entry = RawEntrySpec("short.txt", "abc".toArray())
        entry.uncompressedSize = 5
        let reader = readerOf(buildRawZip([entry]))
        assertZipError({=> reader.read("short.txt")}, "数据不完整")
    }

    /** 场景「截断的压缩流」：deflate 数据被切掉一半，解压中途结束。 */
    @TestCase
    public func truncatedDeflateStreamReported(): Unit {
        let original = "abcdefghijklmnopqrstuvwxyz0123456789".toArray()
        let compressed = deflateBytes(original)
        let truncated = compressed[0..(compressed.size / 2)]
        let entry = RawEntrySpec("t.bin", truncated)
        entry.method = 8
        entry.uncompressedSize = Int64(original.size)
        entry.crc = crc32(original)
        let reader = readerOf(buildRawZip([entry]))
        assertZipError({=> reader.read("t.bin")}, "t.bin")
    }

    /** 场景「bit 3 置位的条目」+「local header 与中央目录不一致」。 */
    @TestCase
    public func centralDirectoryWinsOverLocalHeader(): Unit {
        let entry = RawEntrySpec("s.txt", "payload".toArray())
        entry.flags = ZipLayout.FLAG_DATA_DESCRIPTOR
        entry.localCompressedSize = Some(0)
        entry.localUncompressedSize = Some(0)
        let reader = readerOf(buildRawZip([entry]))
        expectBytesEqual(reader.read("s.txt").getOrThrow(), "payload".toArray())
    }

    /** 场景「含穿越路径的条目仍可读取」：读取层不做路径策略。 */
    @TestCase
    public func readerDoesNotApplyPathPolicy(): Unit {
        let entry = RawEntrySpec("../evil.txt", "X".toArray())
        let reader = readerOf(buildRawZip([entry]))
        @Assert(String.fromUtf8(reader.read("../evil.txt").getOrThrow()), "X")
        @Assert(reader.contains("../evil.txt"), true)
    }

    // ---- 限制 ----

    /** 场景「单条目超限」。 */
    @TestCase
    public func entrySizeLimit(): Unit {
        let bytes = buildZipBytes({w => w.add("a.bin", Array<Byte>(4096, repeat: 7))})
        let reader = readerOf(bytes, limits: ZipLimits(maxEntrySize: 1024))
        assertZipError({=> reader.read("a.bin")}, "解压体积超过上限 1024")
    }

    /** 场景「累计超限」+「同实例跨 read 与 open 累计」。 */
    @TestCase
    public func totalSizeLimitAccumulates(): Unit {
        let payloadA = Array<Byte>(2000, repeat: 1)
        let payloadB = Array<Byte>(2000, repeat: 2)
        let bytes = buildZipBytes(
            {w =>
                w.add("a.bin", payloadA)
                w.add("b.bin", payloadB)
            }
        )
        let reader = readerOf(bytes, limits: ZipLimits(maxTotalSize: 3000))
        @Assert(reader.read("a.bin").getOrThrow().size, 2000)
        assertZipError({=> reader.read("b.bin")}, "解压体积超过上限 3000")

        // 同一实例上 read 之后再 open 也要累计
        let reader2 = readerOf(bytes, limits: ZipLimits(maxTotalSize: 3000))
        @Assert(reader2.read("a.bin").getOrThrow().size, 2000)
        let stream = reader2.open("b.bin").getOrThrow()
        assertZipError({=> drain(stream)}, "解压体积超过上限 3000")
    }

    /** 场景「两个实例各自计数」。 */
    @TestCase
    public func limitsArePerInstance(): Unit {
        let bytes = buildZipBytes({w => w.add("a.bin", Array<Byte>(2000, repeat: 1))})
        let limits = ZipLimits(maxTotalSize: 3000)
        @Assert(readerOf(bytes, limits: limits).read("a.bin").getOrThrow().size, 2000)
        @Assert(readerOf(bytes, limits: limits).read("a.bin").getOrThrow().size, 2000)
    }

    /** 场景「条目数在解析期拒绝」。 */
    @TestCase
    public func entryCountLimit(): Unit {
        let bytes = buildZipBytes(
            {w =>
                w.add("a", "a".toArray())
                w.add("b", "b".toArray())
                w.add("c", "c".toArray())
            }
        )
        assertZipError({=> readerOf(bytes, limits: ZipLimits(maxEntries: 2))}, "条目数 3 超过上限 2")
    }

    /** 场景「高压缩比只告警」。 */
    @TestCase
    public func highRatioOnlyWarns(): Unit {
        let payload = Array<Byte>(1024 * 1024, repeat: 0)
        let bytes = buildZipBytes({w => w.add("zeros.bin", payload)})
        let reader = readerOf(bytes, limits: ZipLimits(ratioWarnThreshold: 10))
        @Assert(reader.read("zeros.bin").getOrThrow().size, Int64(payload.size))
    }

    // ---- 关闭语义 ----

    /** 场景「重复关闭」+「关闭后读取」。 */
    @TestCase
    public func closeSemantics(): Unit {
        let bytes = buildZipBytes({w => w.add("a.txt", "a".toArray())})
        let reader = readerOf(bytes)
        reader.close()
        reader.close()
        assertZipError({=> reader.entries()}, "已关闭")
        assertZipError({=> reader.read("a.txt")}, "已关闭")
        assertZipError({=> reader.open("a.txt")}, "已关闭")
    }

    /** 场景「并发读四个条目不串数据」：四个 open 出来的流交替读。 */
    @TestCase
    public func interleavedOpensDoNotMix(): Unit {
        let bytes = buildZipBytes(
            {w =>
                w.add("a.bin", "AAAA".toArray())
                w.add("b.bin", "BBBBBB".toArray())
                w.add("c.bin", "CC".toArray())
                w.add("d.bin", "DDDDDDDD".toArray())
            }
        )
        let reader = readerOf(bytes)
        let sa = reader.open("a.bin").getOrThrow()
        let sb = reader.open("b.bin").getOrThrow()
        let sc = reader.open("c.bin").getOrThrow()
        let sd = reader.open("d.bin").getOrThrow()
        let buf = Array<Byte>(1, repeat: 0)
        @Assert(sa.read(buf), 1)
        @Assert(sb.read(buf), 1)
        @Assert(sc.read(buf), 1)
        @Assert(sd.read(buf), 1)
        @Assert(buf[0], 0x44u8)          // 'D'
        @Assert(String.fromUtf8(drain(sa)), "AAA")
        @Assert(String.fromUtf8(drain(sb)), "BBBBB")
        @Assert(String.fromUtf8(drain(sc)), "C")
        @Assert(String.fromUtf8(drain(sd)), "DDDDDDD")
    }

    /** 场景「读到 EOF 才校验」：open 出来的流只在 EOF 处报 CRC 错。 */
    @TestCase
    public func openValidatesAtEof(): Unit {
        let entry = RawEntrySpec("bad.bin", "abc".toArray())
        entry.crc = 0
        let reader = readerOf(buildRawZip([entry]))
        let stream = reader.open("bad.bin").getOrThrow()
        assertZipError({=> drain(stream)}, "CRC 校验失败")
    }

    /** 空条目经 open 也是空流。 */
    @TestCase
    public func openEmptyEntry(): Unit {
        let bytes = buildZipBytes({w => w.add("empty.txt", Array<Byte>())})
        let reader = readerOf(bytes)
        let stream = reader.open("empty.txt").getOrThrow()
        @Assert(drain(stream).size, 0)
    }

    /** 目录条目 open 返回 None（没有数据可读）。 */
    @TestCase
    public func openDirectoryReturnsNone(): Unit {
        let bytes = buildZipBytes({w => w.addDirectory("d")})
        @Assert(readerOf(bytes).open("d/").isNone(), true)
    }
}

internal func drain(stream: InputStream): Array<Byte> {
    let out = ByteBuffer()
    let buf = Array<Byte>(3, repeat: 0)
    var n = stream.read(buf)
    while (n > 0) {
        out.write(buf[0..n])
        n = stream.read(buf)
    }
    out.bytes()
}
