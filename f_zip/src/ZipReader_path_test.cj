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
import std.fs.{Directory, File, removeIfExists}
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ZipReader_path_test {
    /** 场景「流构造可读内存中的 ZIP」与「路径构造能列出完全相同的条目」。 */
    @TestCase
    public func pathConstructorMatchesStream(): Unit {
        let bytes = buildZipBytes(
            {w =>
                w.add("a.txt", "alpha".toArray())
                w.addFileStream("b.bin", ByteBuffer("bravo".toArray()))
                w.addDirectory("dir")
                w.add("dir/c.txt", "charlie".toArray())
            }
        )
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let path = work.join("sample.zip")
            File.writeTo(path, bytes)
            let fromPath = ZipReader(path.toString())
            let fromStream = readerOf(bytes)
            try {
                let a = fromPath.entries()
                let b = fromStream.entries()
                @Assert(a.size, b.size)
                for (i in 0..a.size) {
                    @Assert(a[i].name, b[i].name)
                    @Assert(a[i].uncompressedSize, b[i].uncompressedSize)
                    @Assert(a[i].crc32, b[i].crc32)
                }
                expectBytesEqual(fromPath.read("a.txt").getOrThrow(), "alpha".toArray())
                expectBytesEqual(fromPath.read("dir/c.txt").getOrThrow(), "charlie".toArray())
                expectBytesEqual(fromPath.read("b.bin").getOrThrow(), "bravo".toArray())
            } finally {
                fromPath.close()
                fromStream.close()
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「并发读四个条目不串数据」（FileSource 每次另开句柄）。 */
    @TestCase
    public func concurrentOpensFromPath(): Unit {
        let bytes = buildZipBytes(
            {w =>
                w.add("1.bin", "1111".toArray())
                w.add("2.bin", "222222".toArray())
                w.add("3.bin", "33".toArray())
                w.add("4.bin", "44444444".toArray())
            }
        )
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let path = work.join("c.zip")
            File.writeTo(path, bytes)
            let reader = ZipReader(path.toString())
            try {
                let s1 = reader.open("1.bin").getOrThrow()
                let s2 = reader.open("2.bin").getOrThrow()
                let s3 = reader.open("3.bin").getOrThrow()
                let s4 = reader.open("4.bin").getOrThrow()
                @Assert(String.fromUtf8(drain(s1)), "1111")
                @Assert(String.fromUtf8(drain(s2)), "222222")
                @Assert(String.fromUtf8(drain(s3)), "33")
                @Assert(String.fromUtf8(drain(s4)), "44444444")
            } finally {
                reader.close()
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「路径构造的尾部窗口上界」：文件远大于窗口时仍能定位。 */
    @TestCase
    public func largeFileStillLocatesEocd(): Unit {
        // 造一个 200 KB 的条目，尾部窗口仍然是 64 KB 上界
        let payload = Array<Byte>(200 * 1024, repeat: 5)
        let bytes = buildZipBytes({w => w.add("big.bin", payload)})
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let path = work.join("big.zip")
            File.writeTo(path, bytes)
            let reader = ZipReader(path.toString())
            try {
                @Assert(reader.entries().size, 1)
                @Assert(reader.read("big.bin").getOrThrow().size, Int64(payload.size))
            } finally {
                reader.close()
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}
