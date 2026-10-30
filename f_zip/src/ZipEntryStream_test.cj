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

import std.io.OutputStream
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.ByteBuffer
import fountain::f_util.crc32

/**
 * `ZipWriter.openEntry` 的推模式条目流。
 *
 * 与 `addFileStream` 的区别只在"谁来推"：`addFileStream` 从调用方给的 `InputStream` 拉，
 * `openEntry` 把 `OutputStream` 交给调用方推——调用方本来就在生成数据时（如逐行写 XML），
 * 不必先造一个输入流适配器。
 */
@Test
public class ZipEntryStream_test {
    private static func text(value: String): Array<Byte> {
        value.toArray()
    }

    private static func build(writer: (ZipWriter) -> Unit, capacity!: Int64 = 64 * 1024): Array<Byte> {
        let buf = ByteBuffer(initialCapacity: capacity)
        let w = ZipWriter(buf)
        writer(w)
        w.close()
        buf.bytes()
    }

    /** 场景「推模式写入后能按普通条目读回」。 */
    @TestCase
    public func openEntryRoundTrip(): Unit {
        let data = text("hello streaming entry")
        let bytes = build({
            w =>
            let entry = w.openEntry("a.txt")
            entry.write(data[0..5])
            entry.write(data[5..])
            entry.close()
        })
        let reader = ZipReader(ByteBuffer(bytes))
        let entry = reader.entries()[0]
        @Assert(entry.name, "a.txt")
        @Assert(entry.method, 8u16)
        @Assert(entry.uncompressedSize, Int64(data.size))
        @Assert(entry.crc32, crc32(data))
        @Assert(String.fromUtf8(reader.read("a.txt").getOrThrow()), "hello streaming entry")
        reader.close()
    }

    /** 场景「Stored 方法也走推模式」。 */
    @TestCase
    public func openEntryStored(): Unit {
        let data = text("stored payload")
        let options = ZipWriterOptions(method: CompressionMethod.Stored)
        let buf = ByteBuffer()
        let w = ZipWriter(buf, options: options)
        let entry = w.openEntry("s.bin")
        entry.write(data)
        entry.close()
        w.close()
        let reader = ZipReader(ByteBuffer(buf.bytes()))
        let e = reader.entries()[0]
        @Assert(e.method, 0u16)
        @Assert(e.compressedSize, Int64(data.size))
        @Assert(String.fromUtf8(reader.read("s.bin").getOrThrow()), "stored payload")
        reader.close()
    }

    /** 场景「空条目」。 */
    @TestCase
    public func openEntryEmpty(): Unit {
        let bytes = build({
            w =>
            let entry = w.openEntry("empty.txt")
            entry.close()
        })
        let reader = ZipReader(ByteBuffer(bytes))
        let e = reader.entries()[0]
        @Assert(e.uncompressedSize, 0)
        @Assert(e.crc32, crc32(Array<Byte>()))
        @Assert(reader.read("empty.txt").getOrThrow().size, 0)
        reader.close()
    }

    /** 场景「flush 只冲刷压缩器，不结束条目」。 */
    @TestCase
    public func openEntryFlushKeepsEntryOpen(): Unit {
        let bytes = build({
            w =>
            let entry = w.openEntry("f.txt")
            entry.write(text("part1"))
            entry.flush()
            entry.write(text("-part2"))
            entry.close()
        })
        let reader = ZipReader(ByteBuffer(bytes))
        @Assert(String.fromUtf8(reader.read("f.txt").getOrThrow()), "part1-part2")
        reader.close()
    }

    /** 场景「多条推模式条目」。 */
    @TestCase
    public func openEntryMultiple(): Unit {
        let bytes = build({
            w =>
            for (i in 0..3) {
                let entry = w.openEntry("e${i}.txt")
                entry.write(text("v${i}"))
                entry.close()
            }
        })
        let reader = ZipReader(ByteBuffer(bytes))
        @Assert(reader.entries().size, 3)
        @Assert(String.fromUtf8(reader.read("e1.txt").getOrThrow()), "v1")
        reader.close()
    }

    /** 场景「条目未关闭时禁止其它写入与 close」。 */
    @TestCase
    public func openEntryBlocksOtherWrites(): Unit {
        let buf = ByteBuffer()
        let w = ZipWriter(buf)
        let entry = w.openEntry("a.txt")
        entry.write(text("x"))
        var addRejected = false
        try {
            w.add("b.txt", text("y"))
        } catch (_: ZipException) {
            addRejected = true
        }
        @Assert(addRejected, true)
        var closeRejected = false
        try {
            w.close()
        } catch (_: ZipException) {
            closeRejected = true
        }
        @Assert(closeRejected, true)
        entry.close()
        w.close()
    }

    /** 场景「条目 close 幂等」。 */
    @TestCase
    public func openEntryCloseIdempotent(): Unit {
        let bytes = build({
            w =>
            let entry = w.openEntry("a.txt")
            entry.write(text("x"))
            entry.close()
            entry.close()
        })
        let reader = ZipReader(ByteBuffer(bytes))
        @Assert(reader.entries().size, 1)
        @Assert(String.fromUtf8(reader.read("a.txt").getOrThrow()), "x")
        reader.close()
    }

    /** 场景「close 之后不能再写」。 */
    @TestCase
    public func openEntryWriteAfterCloseThrows(): Unit {
        let buf = ByteBuffer()
        let w = ZipWriter(buf)
        let entry = w.openEntry("a.txt")
        entry.write(text("x"))
        entry.close()
        var rejected = false
        try {
            entry.write(text("y"))
        } catch (_: ZipException) {
            rejected = true
        }
        @Assert(rejected, true)
        w.close()
    }

    /** 场景「1 MB 分块写入，CRC 与内容一致」。 */
    @TestCase
    public func openEntryLargeChunked(): Unit {
        let total: Int64 = 1024 * 1024
        let chunk = Array<Byte>(4096, repeat: 0x5A)
        let expected = Array<Byte>(total, repeat: 0x5A)
        let bytes = build(
            {
                w =>
                let entry = w.openEntry("big.bin")
                var written: Int64 = 0
                while (written < total) {
                    entry.write(chunk)
                    written += chunk.size
                }
                entry.close()
            },
            capacity: 4 * 1024 * 1024
        )
        let reader = ZipReader(ByteBuffer(bytes))
        let e = reader.entries()[0]
        @Assert(e.uncompressedSize, total)
        @Assert(e.crc32, crc32(expected))
        @Assert(reader.read("big.bin").getOrThrow().size, total)
        reader.close()
    }

    /** 场景「按 ZipEntry 句柄打开解压流」。 */
    @TestCase
    public func readerOpenEntryByHandle(): Unit {
        let bytes = build({
            w =>
            w.add("a.txt", text("by handle"))
        })
        let reader = ZipReader(ByteBuffer(bytes))
        let entry = reader.entries()[0]
        let input = reader.openEntry(entry).getOrThrow()
        let buf = Array<Byte>(32, repeat: 0)
        let n = input.read(buf)
        @Assert(String.fromUtf8(buf[0..n]), "by handle")
        reader.close()
    }
}
