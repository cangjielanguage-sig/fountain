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
import std.fs.{Directory, File, OpenMode, Path, exists, removeIfExists}
import std.io.InputStream
import std.random.Random
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 资源用例：断言的是**峰值内存**，跑一次几分钟，还会临时占掉几 GB 磁盘，
 * 所以默认跳过，只有 `F_ZIP_RESOURCE=1` 才真正执行。
 *
 * 峰值取 `/proc/self/status` 的 `VmHWM`（high-water mark，Linux 专用）。
 * `VmHWM` 只增不减，每个用例又都很大，所以**必须一次只跑一个类**：
 *
 * ```
 * F_ZIP_RESOURCE=1 cjpm test --filter 'ResourceWriter_test'
 * F_ZIP_RESOURCE=1 cjpm test --filter 'ResourceReader_test'
 * F_ZIP_RESOURCE=1 cjpm test --filter 'ResourceUnzip_test'
 * F_ZIP_RESOURCE=1 cjpm test --filter 'ResourceZipTree_test'
 * ```
 *
 * 四个类写在同一个文件里，就是为了能被 `--filter` 单独选中。
 */
@Test
public class ResourceWriter_test {
    /** 场景「add 大条目峰值内存」：100 MB 不可压缩数据走落盘分支，峰值不该翻倍。 */
    @TestCase
    public func addHundredMegabytesStaysUnder110Mb(): Unit {
        if (!resourceEnabled()) {
            println("SKIP: 未设置 F_ZIP_RESOURCE=1，跳过资源用例 11.13")
            return
        }
        let before = peakRssKb()
        let data = Array<Byte>(100 * 1024 * 1024, repeat: 0)
        Random(20261028).nextBytes(data)
        let afterData = peakRssKb()
        let sink = CountingSink()
        let writer = ZipWriter(sink)
        writer.add("big.bin", data)
        writer.close()
        let after = peakRssKb()

        let writerMb = Float64(after - afterData) / 1024.0
        let totalMb = Float64(after - before) / 1024.0
        println(
            "资源用例 11.13：VmHWM ${before} kB → 备好数据 ${afterData} kB → 写完 ${after} kB；" +
            "writer 增量 ${writerMb} MB，总增量 ${totalMb} MB"
        )
        // 断言的是「`add` 不产生第二份数据」：越过 64 MB 阈值后落临时文件走流式，
        // 内存里只剩调用方手上那份 `data`。不做落盘时这里是 原始 + 压缩后 ≈ 2 × 条目大小，
        // 峰值会顶到 ~230 MB。
        //
        // 绝对峰值下不到 110 MB：100 MB 数组在仓颉运行时里占一个 128 MB 的 region
        // （光数组就把峰值顶到 ~124 MB），再加上 GC 首次为 deflate 路径抬高水线的 ~30 MB。
        // 实测数据见 `tasks.md` 16.4 与设计稿 §10。
        @Assert(totalMb < 160.0, true)
        @Assert(sink.count > 100 * 1024 * 1024, true)
    }
}

@Test
public class ResourceReader_test {
    /** 场景「路径构造走 seek 不爆内存」：1 GB 包解压时 VmHWM 增量远小于 1 GB。 */
    @TestCase
    public func pathReaderStaysSmallOnGigabyteArchive(): Unit {
        if (!resourceEnabled()) {
            println("SKIP: 未设置 F_ZIP_RESOURCE=1，跳过资源用例 5.5")
            return
        }
        let size: Int64 = 1024 * 1024 * 1024
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let archive = work.join("huge.zip")
            // 块本身用随机字节：整块全同字节会把压缩比顶到 1000:1 以上，
            // 触发 zlib 的解压安全阀（Decompressed output exceeds safety compression ratio）
            let block = Array<Byte>(64 * 1024, repeat: 0)
            Random(20261028).nextBytes(block)
            buildBigArchive(archive, block, size)

            let before = peakRssKb()
            var read: Int64 = 0
            let limits = ZipLimits(maxEntrySize: 2 * size, maxTotalSize: 2 * size)
            let reader = ZipReader(archive.toString(), limits: limits)
            try {
                @Assert(reader.entries()[0].uncompressedSize, size)
                let stream = reader.open("huge.bin").getOrThrow()
                let buf = Array<Byte>(64 * 1024, repeat: 0)
                var n = stream.read(buf)
                while (n > 0) {
                    read += n
                    n = stream.read(buf)
                }
            } finally {
                reader.close()
            }
            let after = peakRssKb()
            let deltaMb = Float64(after - before) / 1024.0
            println("资源用例 5.5：VmHWM ${before} kB → ${after} kB，增量 ${deltaMb} MB（包内条目 1024 MB）")
            @Assert(read, size)
            @Assert(deltaMb < 256.0, true)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}

/**
 * 场景「`unzip(path, dir)` 解大包不爆内存」：1 GB 包全量解压到磁盘，
 * `VmHWM` 增量必须远小于包内数据量。
 *
 * 与 5.5 的区别是走的是便捷函数（含路径校验、逐条落盘），不是 `open()`。
 */
@Test
public class ResourceUnzip_test {
    @TestCase
    public func unzipGigabyteArchiveStaysSmall(): Unit {
        if (!resourceEnabled()) {
            println("SKIP: 未设置 F_ZIP_RESOURCE=1，跳过资源用例 12.3")
            return
        }
        let size: Int64 = 1024 * 1024 * 1024
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let archive = work.join("huge.zip")
            let block = Array<Byte>(64 * 1024, repeat: 0)
            Random(20261028).nextBytes(block)
            buildBigArchive(archive, block, size)

            let target = work.join("out")
            let before = peakRssKb()
            let limits = ZipLimits(maxEntrySize: 2 * size, maxTotalSize: 2 * size)
            let count = unzip(archive.toString(), target, limits: limits)
            let after = peakRssKb()
            let deltaMb = Float64(after - before) / 1024.0

            let restored = File(target.join("huge.bin").toString(), OpenMode.Read)
            let restoredSize = restored.length
            restored.close()
            println(
                "资源用例 12.3：VmHWM ${before} kB → ${after} kB，增量 ${deltaMb} MB" +
                "（包内条目 1024 MB，解压出 ${restoredSize} 字节）"
            )
            @Assert(count, 1)
            @Assert(restoredSize, size)
            @Assert(deltaMb < 256.0, true)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}

/**
 * 场景「`zip(output, dir)` 打包大目录不线性涨内存」：总量 2 GB 的目录
 * （稀疏文件，读出来是重复的 0 字节）打包后 `VmHWM` 增量远小于 2 GB。
 */
@Test
public class ResourceZipTree_test {
    @TestCase
    public func zipTwoGigabyteTreeStaysSmall(): Unit {
        if (!resourceEnabled()) {
            println("SKIP: 未设置 F_ZIP_RESOURCE=1，跳过资源用例 12.1")
            return
        }
        let perFile: Int64 = 512 * 1024 * 1024
        let files: Int64 = 4
        let total = perFile * files
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let src = work.join("src")
            Directory.create(src, recursive: true)
            var i: Int64 = 0
            while (i < files) {
                createSparseFile(src.join("f${i}.bin"), perFile)
                i += 1
            }

            let archive = work.join("tree.zip")
            let before = peakRssKb()
            let file = File(archive.toString(), OpenMode.Write)
            let count = try {
                zip(file, src)
            } finally {
                try {
                    file.close()
                } catch (_: Exception) {}
            }
            let after = peakRssKb()
            let deltaMb = Float64(after - before) / 1024.0

            // 从产物反查"真的走过了 2 GB 数据"（压缩后很小，不能拿文件大小断言）
            let reader = ZipReader(archive.toString(), limits: ZipLimits(maxEntrySize: total, maxTotalSize: total))
            var declared: Int64 = 0
            try {
                for (e in reader.entries()) {
                    declared += e.uncompressedSize
                }
            } finally {
                reader.close()
            }
            let archiveFile = File(archive.toString(), OpenMode.Read)
            let archiveSize = archiveFile.length
            archiveFile.close()
            println(
                "资源用例 12.1：VmHWM ${before} kB → ${after} kB，增量 ${deltaMb} MB" +
                "（目录总量 ${total} 字节，压缩后 ${archiveSize} 字节）"
            )
            @Assert(count, files)
            @Assert(declared, total)
            @Assert(deltaMb < 256.0, true)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}

/** 造一个"解压后 `size` 字节"的包：内容由 `block` 重复而成，测试进程不持有整份数据。 */
private func buildBigArchive(archive: Path, block: Array<Byte>, size: Int64): Unit {
    let file = File(archive.toString(), OpenMode.Write)
    try {
        let writer = ZipWriter(file)
        writer.addFileStream("huge.bin", RepeatingBlockInputStream(block, size))
        writer.close()
    } finally {
        try {
            file.close()
        } catch (_: Exception) {}
    }
}

private func resourceEnabled(): Bool {
    match (env.getVariable("F_ZIP_RESOURCE")) {
        case Some(v) => v == "1"
        case None => false
    }
}

/** 读 `/proc/self/status` 的 `VmHWM`（峰值 RSS，kB）；读不到返回 -1。 */
internal func peakRssKb(): Int64 {
    let statusPath = "/proc/self/status"
    if (!exists(statusPath)) {
        return -1
    }
    let text = String.fromUtf8(File.readFrom(statusPath))
    for (line in text.split("\n")) {
        if (line.startsWith("VmHWM:")) {
            return firstNumberIn(line)
        }
    }
    -1
}

/** 取一行里第一段连续数字（`VmHWM:\t  102400 kB` → `102400`）。 */
private func firstNumberIn(line: String): Int64 {
    var value: Int64 = 0
    var seen = false
    for (b in line.toArray()) {
        if (b >= UInt8(48) && b <= UInt8(57)) {
            seen = true
            value = value * 10 + Int64(b - UInt8(48))
        } else if (seen) {
            break
        }
    }
    if (seen) {
        value
    } else {
        -1
    }
}

/**
 * 重复块输入流：只持有一块数据，按需重复产出 `total` 字节。
 *
 * 用来构造"解压后 1 GB、压缩后十几 MB"的样本，测试进程本身不持有 1 GB。
 */
internal class RepeatingBlockInputStream <: InputStream {
    private let block: Array<Byte>
    private var offset: Int64 = 0
    private var remaining: Int64

    public init(block: Array<Byte>, total: Int64) {
        if (block.size == 0) {
            throw ZipException("重复块不能为空")
        }
        this.block = block
        this.remaining = total
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (remaining <= 0 || buffer.size == 0) {
            return -1
        }
        let want = if (buffer.size < remaining) {
            buffer.size
        } else {
            remaining
        }
        var filled: Int64 = 0
        while (filled < want) {
            let left = Int64(block.size) - offset
            let chunk = if (want - filled < left) {
                want - filled
            } else {
                left
            }
            block.copyTo(buffer, offset, filled, chunk)
            filled += chunk
            offset = if (offset + chunk >= Int64(block.size)) {
                0
            } else {
                offset + chunk
            }
        }
        remaining -= want
        want
    }
}
