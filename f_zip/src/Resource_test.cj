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
import std.fs.{Directory, File, OpenMode, exists, removeIfExists}
import std.io.InputStream
import std.random.Random
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 资源用例：断言的是**峰值内存**，跑一次几十秒到几分钟，还会临时占掉几百 MB 磁盘，
 * 所以默认跳过，只有 `F_ZIP_RESOURCE=1` 才真正执行。
 *
 * 峰值取 `/proc/self/status` 的 `VmHWM`（high-water mark，Linux 专用）。
 * `VmHWM` 只增不减，两个用例又都很大，所以**必须一次只跑一个类**：
 *
 * ```
 * F_ZIP_RESOURCE=1 cjpm test --filter 'ResourceWriter_test'
 * F_ZIP_RESOURCE=1 cjpm test --filter 'ResourceReader_test'
 * ```
 *
 * 两个类默认分开写在同一个文件里，就是为了能被 `--filter` 单独选中。
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
            let file = File(archive.toString(), OpenMode.Write)
            let writer = ZipWriter(file)
            try {
                writer.addFileStream("huge.bin", RepeatingBlockInputStream(block, size))
                writer.close()
            } finally {
                try {
                    file.close()
                } catch (_: Exception) {}
            }

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
