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

import std.fs.{File, OpenMode, removeIfExists}
import std.io.InputStream
import std.random.Random
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 慢用例：**单条目 > 4 GB** 的端到端往返（`F_ZIP_SLOW=1` 门控）。
 *
 * 用 **Stored**（method 0）：deflate 会先撞上 zlib 的压缩比安全阀与耗时，
 * 而这条用例要验的是"ZIP64 的 8 字节大小字段真的被写出来、真的能被自己读回"，
 * 与压缩算法无关。数据由"重复块流"生成，测试进程只持有一块。
 *
 * 磁盘：包本体 ≈ 4.4 GB。`/tmp` 是 tmpfs 的环境要用 `F_ZIP_TMP` 指到大磁盘。
 *
 * **耗时**：这条路要算两遍 4.4 GB 的 CRC（写一遍、读回校验一遍），
 * 而 `f_util.crc32` 在本机约 4.2 MB/s，一次往返 ≈ 35 分钟。
 * 所以这条用例只在发布前（faster machine / 优化过 CRC 之后）跑。
 */
@Test
public class Zip64BigEntry_test {
    /** 场景「单条目 > 4 GB」：往返后长度、CRC（由流读取校验）都一致。 */
    @TestCase
    public func singleEntryOverFourGigabytes(): Unit {
        if (!slowEnabled()) {
            skipGated("未设置 F_ZIP_SLOW=1，跳过慢用例 9.7b（单条目 > 4 GB）")
            return
        }
        let size: Int64 = 4 * 1024 * 1024 * 1024 + 4096
        let block = Array<Byte>(1024 * 1024, repeat: 0)
        Random(20261028).nextBytes(block)
        let work = bigWorkDir()
        let started = DateTime.now()
        try {
            let archive = work.join("big-entry.zip")
            let options = ZipWriterOptions(method: CompressionMethod.Stored)
            let file = File(archive.toString(), OpenMode.Write)
            try {
                let writer = ZipWriter(file, options: options)
                writer.addFileStream("huge.bin", RepeatingBlockInputStream(block, size))
                writer.close()
            } finally {
                try {
                    file.close()
                } catch (_: Exception) {}
            }
            let written = DateTime.now()

            // 单条目 4 GB 远超默认的 512 MB / 2 GB，必须显式放宽
            let limits = ZipLimits(maxEntrySize: 2 * size, maxTotalSize: 2 * size)
            let reader = ZipReader(archive.toString(), limits: limits)
            var read: Int64 = 0
            try {
                let entry = reader.entries()[0]
                @Assert(entry.uncompressedSize, size)
                @Assert(entry.compressedSize, size)
                @Assert(entry.method, 0u16)
                // 读到 EOF 时 ZipEntryInputStream 会校验长度与 CRC
                let stream = reader.open("huge.bin").getOrThrow()
                read = drain(stream)
            } finally {
                reader.close()
            }
            let finished = DateTime.now()
            println(
                "资源用例 9.7b：条目 ${size} 字节；写出 ${elapsedSeconds(started, written)} s，" +
                "读回 ${elapsedSeconds(written, finished)} s，总计 ${elapsedSeconds(started, finished)} s"
            )
            @Assert(read, size)
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }

    /** 把流读空，返回读到的字节数（流内部的 CRC 校验在读到 EOF 时触发）。 */
    private func drain(stream: InputStream): Int64 {
        let buf = Array<Byte>(1024 * 1024, repeat: 0)
        var total: Int64 = 0
        var n = stream.read(buf)
        while (n > 0) {
            total += n
            n = stream.read(buf)
        }
        total
    }

    private func elapsedSeconds(from: DateTime, to: DateTime): Int64 {
        (to - from).toSeconds()
    }
}
