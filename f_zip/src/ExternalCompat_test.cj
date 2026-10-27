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
import std.fs.{Directory, File, Path, removeIfExists}
import std.io.ByteBuffer
import std.process.{ProcessException, executeWithOutput}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 外部工具交叉验证：自己读自己写可能互相容忍同一个错误，所以写出来的包必须过
 * 第三方校验。工具不存在时用例直接返回（不算失败），在 CI 里装了工具就会真正跑。
 *
 * 覆盖四类样本：普通 / 纯流式 / 混合 / ZIP64 形式 descriptor。
 */
@Test
public class ExternalCompat_test {
    private static func samples(dir: Path): Array<Path> {
        let plain = dir.join("plain.zip")
        let streaming = dir.join("stream.zip")
        let mixed = dir.join("mixed.zip")
        let tinyStream = dir.join("tiny_stream.zip")

        File.writeTo(
            plain,
            buildZipBytes(
                {w =>
                    w.add("a.txt", "hello".toArray())
                    w.add("dir/b.txt", "world world world".toArray())
                    w.addDirectory("dir/empty")
                }
            )
        )
        File.writeTo(
            streaming,
            buildZipBytes(
                {w => w.addFileStream("big.bin", ByteBuffer(Array<Byte>(50000, repeat: 65)))}
            )
        )
        File.writeTo(
            mixed,
            buildZipBytes(
                {w =>
                    w.add("a.txt", "alpha".toArray())
                    w.addFileStream("b.bin", ByteBuffer("bravo bravo".toArray()))
                    w.add("c.txt", "charlie".toArray())
                }
            )
        )
        File.writeTo(
            tinyStream,
            buildZipBytes({w => w.addFileStream("t.txt", ByteBuffer("0123456789".toArray()))})
        )
        [plain, streaming, mixed, tinyStream]
    }

    /** 反向：Python `zipfile.testzip()` 跑四类样本。 */
    @TestCase
    public func pythonZipfileAcceptsOurArchives(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let script = "import sys, zipfile\nz = zipfile.ZipFile(sys.argv[1])\nbad = z.testzip()\nsys.exit(0 if bad is None else 1)\n"
            for (sample in samples(work)) {
                let (code, out, err) = try {
                    executeWithOutput("python3", ["-c", script, sample.toString()])
                } catch (_: ProcessException) {
                    return
                }
                @Assert(code, 0)
                if (code != 0) {
                    @Fail("python zipfile 拒绝了 ${sample}：${String.fromUtf8(err)}")
                }
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 场景「中文名在 7-Zip 里不乱码」：`7za l` 的输出里能看到原名。 */
    @TestCase
    public func chineseNameVisibleToSevenZip(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let archive = work.join("cn.zip")
            File.writeTo(
                archive,
                buildZipBytes(
                    {w =>
                        w.add("中文/文件.txt", "内容".toArray())
                        w.add("plain.txt", "ascii".toArray())
                    }
                )
            )
            let (code, out, err) = try {
                executeWithOutput("7za", ["l", archive.toString()])
            } catch (_: ProcessException) {
                return
            }
            if (code != 0) {
                @Fail("7za l 失败：${String.fromUtf8(err)}")
            }
            let listing = String.fromUtf8(out)
            if (!listing.contains("中文/文件.txt")) {
                @Fail("7za 列出的名字不含中文原名：${listing}")
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 反向：7-Zip（`7za t`）跑四类样本。 */
    @TestCase
    public func sevenZipAcceptsOurArchives(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            for (sample in samples(work)) {
                let (code, _, err) = try {
                    executeWithOutput("7za", ["t", sample.toString()])
                } catch (_: ProcessException) {
                    return
                }
                if (code != 0) {
                    @Fail("7za 拒绝了 ${sample}：${String.fromUtf8(err)}")
                }
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 反向：Info-ZIP `unzip -t`（环境里没有就跳过）。 */
    @TestCase
    public func unzipAcceptsOurArchives(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            for (sample in samples(work)) {
                let (code, _, err) = try {
                    executeWithOutput("unzip", ["-t", sample.toString()])
                } catch (_: ProcessException) {
                    return
                }
                if (code != 0) {
                    @Fail("unzip -t 拒绝了 ${sample}：${String.fromUtf8(err)}")
                }
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 正向：读 Info-ZIP `zip` 产出的包（标准 deflate + UTF-8 名）。 */
    @TestCase
    public func readInfoZipSample(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            File.writeTo(work.join("a.txt"), "alpha".toArray())
            File.writeTo(work.join("b.txt"), "bravo bravo bravo".toArray())
            let archive = work.join("linux.zip")
            let (code, _, err) = try {
                executeWithOutput("zip", ["-q", "-X", archive.toString(), "a.txt", "b.txt"], workingDirectory: work)
            } catch (_: ProcessException) {
                return
            }
            if (code != 0) {
                @Fail("zip 没能造出样本：${String.fromUtf8(err)}")
            }
            let reader = ZipReader(archive.toString())
            try {
                @Assert(reader.entries().size, 2)
                @Assert(String.fromUtf8(reader.read("a.txt").getOrThrow()), "alpha")
                @Assert(String.fromUtf8(reader.read("b.txt").getOrThrow()), "bravo bravo bravo")
            } finally {
                reader.close()
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 正向：读 7-Zip 产出的包。 */
    @TestCase
    public func readSevenZipSample(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            File.writeTo(work.join("a.txt"), "alpha".toArray())
            File.writeTo(work.join("b.txt"), "bravo bravo bravo".toArray())
            let archive = work.join("seven.zip")
            let (code, _, err) = try {
                executeWithOutput("7za", ["a", "-tzip", archive.toString(), "a.txt", "b.txt"], workingDirectory: work)
            } catch (_: ProcessException) {
                return
            }
            if (code != 0) {
                @Fail("7za 没能造出样本：${String.fromUtf8(err)}")
            }
            let reader = ZipReader(archive.toString())
            try {
                @Assert(reader.entries().size, 2)
                @Assert(String.fromUtf8(reader.read("a.txt").getOrThrow()), "alpha")
                @Assert(String.fromUtf8(reader.read("b.txt").getOrThrow()), "bravo bravo bravo")
            } finally {
                reader.close()
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 正向：读 Python `zipfile` 产出的包（含目录条目与 deflate）。 */
    @TestCase
    public func readPythonZipfileSample(): Unit {
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let archive = work.join("python.zip")
            let script = "import sys, zipfile\n" +
                "z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)\n" +
                "z.writestr('a.txt', 'alpha')\n" +
                "z.writestr('sub/b.txt', 'bravo' * 50)\n" +
                "z.writestr('sub/', b'')\n" +
                "z.close()\n"
            let (code, _, err) = try {
                executeWithOutput("python3", ["-c", script, archive.toString()])
            } catch (_: ProcessException) {
                return
            }
            if (code != 0) {
                @Fail("python zipfile 没能造出样本：${String.fromUtf8(err)}")
            }
            let reader = ZipReader(archive.toString())
            try {
                let entries = reader.entries()
                @Assert(entries.size, 3)
                @Assert(String.fromUtf8(reader.read("a.txt").getOrThrow()), "alpha")
                @Assert(reader.read("sub/b.txt").getOrThrow().size, 250)
                @Assert(reader.contains("sub/"), true)
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
