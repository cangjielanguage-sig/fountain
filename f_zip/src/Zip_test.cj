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
import std.fs.{Directory, File, Path, exists, removeIfExists}
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Zip_test {
    /** 场景「目录打包后解压还原」：两层子目录 5 个文件，返回 5 且逐文件一致。 */
    @TestCase
    public func zipThenUnzipRestoresTree(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let src = work.join("src")
            Directory.create(src.join("one").join("two"), recursive: true)
            File.writeTo(src.join("a.txt"), "A".toArray())
            File.writeTo(src.join("one").join("b.txt"), "BB".toArray())
            File.writeTo(src.join("one").join("two").join("c.txt"), "CCC".toArray())
            File.writeTo(src.join("one").join("two").join("d.bin"), Array<Byte>(1000, repeat: 9))
            File.writeTo(src.join("e.txt"), "E".toArray())

            let out = ByteBuffer()
            @Assert(zip(out, src), 5)

            let restored = work.join("restored")
            @Assert(unzip(ByteBuffer(out.bytes()), restored), 5)

            @Assert(String.fromUtf8(File.readFrom(restored.join("a.txt"))), "A")
            @Assert(String.fromUtf8(File.readFrom(restored.join("one").join("b.txt"))), "BB")
            @Assert(String.fromUtf8(File.readFrom(restored.join("one").join("two").join("c.txt"))), "CCC")
            @Assert(String.fromUtf8(File.readFrom(restored.join("e.txt"))), "E")
            expectBytesEqual(
                File.readFrom(restored.join("one").join("two").join("d.bin")),
                Array<Byte>(1000, repeat: 9)
            )
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「解压并返回文件数」：3 文件 + 2 目录条目 → 3。 */
    @TestCase
    public func unzipReturnsFileCount(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let bytes = buildZipBytes(
                {w =>
                    w.addDirectory("d1")
                    w.addDirectory("d2")
                    w.add("d1/a.txt", "a".toArray())
                    w.add("d1/b.txt", "b".toArray())
                    w.add("d2/c.txt", "c".toArray())
                }
            )
            let target = work.join("out")
            @Assert(unzip(ByteBuffer(bytes), target), 3)
            @Assert(exists(target.join("d1")), true)
            @Assert(exists(target.join("d2")), true)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「同名覆盖」：后写的内容留下。 */
    @TestCase
    public func duplicateEntriesOverwrite(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let bytes = buildRawZip(
                [RawEntrySpec("x.txt", "A".toArray()), RawEntrySpec("x.txt", "B".toArray())]
            )
            let target = work.join("out")
            @Assert(unzip(ByteBuffer(bytes), target), 2)
            @Assert(String.fromUtf8(File.readFrom(target.join("x.txt"))), "B")
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** `unzip(path, dir)` 与流式构造结果一致（走 seek）。 */
    @TestCase
    public func unzipFromPath(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let bytes = buildZipBytes({w => w.add("a/b.txt", "data".toArray())})
            let archive = work.join("a.zip")
            File.writeTo(archive, bytes)
            let target = work.join("out")
            @Assert(unzip(archive.toString(), target), 1)
            @Assert(String.fromUtf8(File.readFrom(target.join("a").join("b.txt"))), "data")
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}

@Test
public class TempSpill_test {
    /** 场景「临时目录按序解析」：显式 tempDir 排在最前，其次 TMPDIR。 */
    @TestCase
    public func candidateOrder(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        let oldTmp = env.getVariable("TMPDIR")
        try {
            let explicit = work.join("explicit")
            Directory.create(explicit, recursive: true)
            env.setVariable("TMPDIR", work.join("fromEnv").toString())
            let options = ZipWriterOptions(tempDir: Some(explicit))
            let list = TempSpill.candidates(options)
            @Assert(list[0].toString(), explicit.toString())
            @Assert(list[1].toString(), work.join("fromEnv").toString())
            @Assert(list[2].toString(), env.getTempDirectory().toString())
            @Assert(list[3].toString(), TempSpill.fallbackDirectory().toString())
        } finally {
            match (oldTmp) {
                case Some(v) => env.setVariable("TMPDIR", v)
                case None => env.removeVariable("TMPDIR")
            }
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「显式设置 tempDir」：临时文件落在该目录（条目本身走流式）。 */
    @TestCase
    public func explicitTempDirIsUsed(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let explicit = work.join("tmp")
            Directory.create(explicit, recursive: true)
            let options = ZipWriterOptions(memoryEntryThreshold: 1024, tempDir: Some(explicit))
            let data = Array<Byte>(64 * 1024, repeat: 3)
            let out = ByteBuffer()
            let writer = ZipWriter(out, options: options)
            writer.add("big.bin", data)
            writer.close()
            let reader = readerOf(out.bytes())
            expectBytesEqual(reader.read("big.bin").getOrThrow(), data)
            // 用完即删，不留垃圾
            @Assert(Directory.readFrom(explicit).size, 0)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「全部失败即报错」：候选目录都不可用时抛明确错误，不降级回内存。 */
    @TestCase
    public func allCandidatesFailThrows(): Unit {
        let bogus = [Path("/proc/f_zip_no_such_dir"), Path("/proc/f_zip_no_such_dir2")]
        assertZipError({=> TempSpill.createIn(bogus, "x.bin", 1234, 1024)}, "无法创建临时文件")
        assertZipError({=> TempSpill.createIn(bogus, "x.bin", 1234, 1024)}, "1234")
        assertZipError({=> TempSpill.createIn(bogus, "x.bin", 1234, 1024)}, "1024")
    }
}
