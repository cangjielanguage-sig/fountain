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
import std.fs.{Directory, File, Path, SymbolicLink, exists, removeIfExists}
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Unzip_security_test {
    private static func tempDir(): Path {
        Directory.createTemp(env.getTempDirectory())
    }

    /** 场景「相对穿越」。 */
    @TestCase
    public func relativeTraversalRejected(): Unit {
        let work = tempDir()
        try {
            let bytes = buildRawZip([RawEntrySpec("../../etc/passwd", "X".toArray())])
            assertZipError({=> unzip(ByteBuffer(bytes), work.join("out"))}, "条目路径非法：../../etc/passwd")
            @Assert(exists(work.join("out").join("etc").join("passwd")), false)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「绝对路径」。 */
    @TestCase
    public func absolutePathRejected(): Unit {
        let work = tempDir()
        try {
            let bytes = buildRawZip([RawEntrySpec("/abs/path.txt", "X".toArray())])
            assertZipError({=> unzip(ByteBuffer(bytes), work.join("out"))}, "条目路径非法：/abs/path.txt")
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「名字伪装」（`a/../../b.txt`）与目标目录内的 `..`：一律拒绝。 */
    @TestCase
    public func deepTraversalRejected(): Unit {
        let work = tempDir()
        try {
            assertZipError(
                {=> resolveSafeTarget(work, "a/../../b.txt")},
                "条目路径非法：a/../../b.txt"
            )
            assertZipError({=> resolveSafeTarget(work, "a/../b.txt")}, "条目路径非法")
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「校验先于落盘」：前两条合法、第三条非法时的部分成功语义。 */
    @TestCase
    public func validationHappensBeforeWriting(): Unit {
        let work = tempDir()
        try {
            let bytes = buildRawZip(
                [
                    RawEntrySpec("good1.txt", "1".toArray()),
                    RawEntrySpec("good2.txt", "2".toArray()),
                    RawEntrySpec("../evil.txt", "bad".toArray())
                ]
            )
            let target = work.join("out")
            assertZipError({=> unzip(ByteBuffer(bytes), target)}, "条目路径非法：../evil.txt")
            @Assert(exists(target.join("good1.txt")), true)
            @Assert(exists(target.join("good2.txt")), true)
            @Assert(exists(work.join("evil.txt")), false)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「解压不落链接」：S_IFLNK 条目跳过，目标目录下不存在该名字。 */
    @TestCase
    public func symlinkEntrySkipped(): Unit {
        let work = tempDir()
        try {
            let link = RawEntrySpec("link", "/etc/passwd".toArray())
            link.externalAttributes = 0xA1FF0000      // S_IFLNK | 0777
            let normal = RawEntrySpec("ok.txt", "ok".toArray())
            let bytes = buildRawZip([link, normal])
            let target = work.join("out")
            @Assert(unzip(ByteBuffer(bytes), target), 1)
            @Assert(exists(target.join("link")), false)
            @Assert(exists(target.join("ok.txt")), true)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「高压缩比炸弹被拦」+「计数不采信 header」。 */
    @TestCase
    public func bombLimitedByActualBytes(): Unit {
        let work = tempDir()
        try {
            // header 只声明 1 字节，实际解压出 5000 字节
            let payload = Array<Byte>(5000, repeat: 65)
            let bomb = RawEntrySpec("bomb.bin", payload)
            bomb.uncompressedSize = 1
            let bytes = buildRawZip([bomb])
            let target = work.join("out")
            assertZipError(
                {=> unzip(ByteBuffer(bytes), target, limits: ZipLimits(maxEntrySize: 1024))},
                "解压体积超过上限 1024"
            )
            @Assert(exists(target.join("bomb.bin")), false)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「条目数在解析期拒绝」：一个文件都没创建。 */
    @TestCase
    public func entryCountRejectedBeforeAnyWrite(): Unit {
        let work = tempDir()
        try {
            let bytes = buildRawZip(
                [
                    RawEntrySpec("a.txt", "a".toArray()),
                    RawEntrySpec("b.txt", "b".toArray()),
                    RawEntrySpec("c.txt", "c".toArray())
                ]
            )
            let target = work.join("out")
            assertZipError({=> unzip(ByteBuffer(bytes), target, limits: ZipLimits(maxEntries: 2))}, "条目数 3 超过上限 2")
            @Assert(exists(target), false)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「解压加密条目」：该条目不被写出，也不做部分支持。 */
    @TestCase
    public func encryptedEntryNotWritten(): Unit {
        let work = tempDir()
        try {
            let encrypted = RawEntrySpec("enc.txt", "secret".toArray())
            encrypted.flags = 1
            let plain = RawEntrySpec("plain.txt", "p".toArray())
            let bytes = buildRawZip([encrypted, plain])
            let target = work.join("out")
            assertZipError({=> unzip(ByteBuffer(bytes), target)}, "不支持加密 ZIP")
            @Assert(exists(target.join("enc.txt")), false)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「嵌套路径自动建目录」+「目录条目被创建」。 */
    @TestCase
    public func nestedPathsAndDirectoryEntries(): Unit {
        let work = tempDir()
        try {
            let bytes = buildZipBytes(
                {w =>
                    w.add("a/b/c.txt", "nested".toArray())
                    w.addDirectory("empty")
                }
            )
            let target = work.join("out")
            @Assert(unzip(ByteBuffer(bytes), target), 1)
            @Assert(exists(target.join("a").join("b").join("c.txt")), true)
            @Assert(exists(target.join("empty")), true)
            @Assert(String.fromUtf8(File.readFrom(target.join("a").join("b").join("c.txt"))), "nested")
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「包源文件直接跳过符号链接」+「目录链接不递归」。 */
    @TestCase
    public func zipSkipsSymlinks(): Unit {
        let work = tempDir()
        try {
            let src = work.join("src")
            Directory.create(src, recursive: true)
            File.writeTo(src.join("real.txt"), "real".toArray())
            SymbolicLink.create(src.join("file-link.txt"), to: src.join("real.txt"))
            SymbolicLink.create(src.join("dir-link"), to: Path("/"))

            let out = ByteBuffer()
            let count = zip(out, src)
            @Assert(count, 1)
            let reader = readerOf(out.bytes())
            let names = reader.entries()
            @Assert(names.size, 1)
            @Assert(names[0].name, "real.txt")
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「空目录」：返回 0，但包内仍有目录条目。 */
    @TestCase
    public func zipEmptySubdirectory(): Unit {
        let work = tempDir()
        try {
            let src = work.join("src")
            Directory.create(src.join("empty"), recursive: true)
            let out = ByteBuffer()
            @Assert(zip(out, src), 0)
            let entries = readerOf(out.bytes()).entries()
            @Assert(entries.size, 1)
            @Assert(entries[0].name, "empty/")
            @Assert(entries[0].isDirectory, true)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}
