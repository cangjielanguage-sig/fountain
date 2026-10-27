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
 * 其余时候直接返回，不拖慢日常 `cjpm test`。
 */
@Test
public class Zip64EntryCount_test {
    private static func slowEnabled(): Bool {
        match (env.getVariable("F_ZIP_SLOW")) {
            case Some(v) => v == "1"
            case None => false
        }
    }

    /** 场景「条目数越界自动升级」。 */
    @TestCase
    public func entryCountOver65535WritesZip64(): Unit {
        if (!slowEnabled()) {
            return
        }
        let total: Int64 = 65536 + 1
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
        @Assert(Int64(reader.entries().size), total)
        @Assert(reader.read("e65536.txt").getOrThrow().size, 1)

        // 外部工具也认这个 ZIP64 包（装了才有得跑）
        let work = Directory.createTemp(env.getTempDirectory())
        try {
            let path = work.join("many.zip")
            File.writeTo(path, bytes)
            let (code, _, err) = try {
                executeWithOutput("7za", ["t", path.toString()])
            } catch (_: ProcessException) {
                return
            }
            if (code != 0) {
                @Fail("7za 拒绝了 65537 条目的 ZIP64 包：${String.fromUtf8(err)}")
            }
        } finally {
            try {
                removeIfExists(work, recursive: true)
            } catch (_: Exception) {}
        }
    }
}
