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
import std.process.{ProcessException, executeWithOutput}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 慢用例：条目数越过 `0xFFFF` 时 `close()` 自动升级 ZIP64。
 *
 * 只有发布前才需要跑全量：设置环境变量 `F_ZIP_SLOW=1`。
 * 其余时候打印一行 `SKIP` 后返回，不拖慢日常 `cjpm test`。
 */
@Test
public class Zip64EntryCount_test {
    /** 场景「条目数越界自动升级」。 */
    @TestCase
    public func entryCountOver65535WritesZip64(): Unit {
        if (!slowEnabled()) {
            skipGated("未设置 F_ZIP_SLOW=1，跳过慢用例 9.7a（65537 条目）")
            return
        }
        let total: Int64 = 65536 + 1
        checkZip64AroundEntryLimit(total)
    }

    /**
     * 场景「条目数越界自动升级」的**边界**：恰好 65535 条。
     *
     * 65535 既是 2 字节字段能表示的最大值，又是读取侧认的哨兵值。
     * 写侧若按"`> 0xFFFF` 才升级"，就会写出条目数字段等于 `0xFFFF` 的普通 EOCD，
     * 读取侧当成哨兵去找 ZIP64 定位器 → 自家产出的包自己读不回来。
     * 所以判定必须是 `>= 0xFFFF`。
     */
    @TestCase
    public func exactly65535EntriesWritesZip64(): Unit {
        if (!slowEnabled()) {
            skipGated("未设置 F_ZIP_SLOW=1，跳过慢用例 9.7a 边界（65535 条目）")
            return
        }
        checkZip64AroundEntryLimit(Int64(0xFFFF))
    }

    /** 写 `total` 条条目，断言 ZIP64 结构存在、普通 EOCD 填哨兵、自身读得回来。 */
    private func checkZip64AroundEntryLimit(total: Int64): Unit {
        let out = ByteBuffer()
        let writer = ZipWriter(out)
        var i: Int64 = 0
        while (i < total) {
            writer.add("e${i}.txt", [UInt8(i & 0x7F)])
            i += 1
        }
        writer.close()
        let bytes = out.bytes()
        @Assert(countSignature(bytes, u32LEBytes(ZipLayout.SIGNATURE_EOCD64)) >= 1, true)
        @Assert(countSignature(bytes, u32LEBytes(ZipLayout.SIGNATURE_EOCD64_LOCATOR)) >= 1, true)
        // 普通 EOCD 的条目数写哨兵
        let eocd = Int64(bytes.size) - 22
        @Assert(u16At(bytes, eocd + 8), 0xFFFFu16)
        @Assert(u16At(bytes, eocd + 10), 0xFFFFu16)

        let reader = readerOf(bytes, limits: ZipLimits(maxEntries: 200000))
        let entries = reader.entries()
        @Assert(Int64(entries.size), total)
        @Assert(entries[0].name, "e0.txt")
        @Assert(entries[entries.size - 1].name, "e${total - 1}.txt")
        @Assert(reader.read("e${total - 1}.txt").getOrThrow().size, 1)

        // 外部工具也认这个 ZIP64 包（装了才有得跑）
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let path = work.join("many.zip")
            File.writeTo(path, bytes)
            let (code, _, err) = try {
                executeWithOutput("7za", ["t", path.toString()])
            } catch (_: ProcessException) {
                skipMissingTool("7za", "7za t/l 校验 ${total} 条目的 ZIP64 包")
                return
            }
            if (code != 0) {
                @Fail("7za 拒绝了 ${total} 条目的 ZIP64 包：${String.fromUtf8(err)}")
            }
            // `7za l` 的汇总行也要认这个包：不只"能解开"，列出的条目数也要对。
            let (listCode, listOut, listErr) = try {
                executeWithOutput("7za", ["l", path.toString()])
            } catch (_: ProcessException) {
                skipMissingTool("7za", "7za l 条目计数（${total} 条）")
                return
            }
            if (listCode != 0) {
                @Fail("7za l 失败：${String.fromUtf8(listErr)}")
            }
            let listed = sevenZipListedFiles(String.fromUtf8(listOut))
            if (listed != total) {
                @Fail("7za l 汇总的条目数是 ${listed}，预期 ${total}")
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}

/** 从 `7za l` 的汇总行（`... 2 files, 1 folders` / `... 65537 files`）里取条目数；取不到返回 -1。 */
private func sevenZipListedFiles(listing: String): Int64 {
    for (line in listing.split("\n")) {
        if (let Some(pos) <- line.indexOf(" files")) {
            return numberBefore(line, pos)
        }
    }
    -1
}

/** 取 `line[0..end)` 里紧挨着 `end` 的那串十进制数字（跳过空格）。 */
private func numberBefore(line: String, end: Int64): Int64 {
    let chars = line.toArray()
    var i = end - 1
    while (i >= 0 && chars[i] == UInt8(32)) {
        i -= 1
    }
    var value: Int64 = 0
    var scale: Int64 = 1
    var seen = false
    while (i >= 0 && chars[i] >= UInt8(48) && chars[i] <= UInt8(57)) {
        value += Int64(chars[i] - UInt8(48)) * scale
        scale *= 10
        seen = true
        i -= 1
    }
    if (seen) {
        value
    } else {
        -1
    }
}
