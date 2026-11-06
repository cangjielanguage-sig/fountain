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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgTrueTypeTables_test {
    /** 表目录、be16 / be32 / i16 边界读取与截断。 */
    @TestCase
    public func tableDirectoryAndReaders(): Unit {
        let bytes = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(bytes)
        @Assert(directory.size == 7)
        let head = directory.table("head").getOrThrow()
        @Assert(head.tag == "head")
        @Assert(head.length == 54)
        @Assert(head.offset > 0)
        @Assert(directory.table("missing").isNone())

        @Assert(readTtfU16(bytes, head.offset + 18) == 1000)
        @Assert(SvgTtfTableReader(bytes, head).i16(50) == 0)
        @Assert(readTtfU32(bytes, 0) == 0x00010000)

        let u16Error = expectSvgException({=> readTtfU16(bytes, Int64(bytes.size) - 1)})
        @Assert(u16Error.kind == SvgErrorKind.Syntax)
        let u32Error = expectSvgException({=> readTtfU32(bytes, Int64(bytes.size) - 2)})
        @Assert(u32Error.kind == SvgErrorKind.Syntax)

        let truncated = bytes[0..100]
        let truncationError = expectSvgException({=> SvgTtfTableDirectory.parse(truncated)})
        @Assert(truncationError.kind == SvgErrorKind.Syntax)

        let maxp = directory.table("maxp").getOrThrow()
        @Assert(readTtfU16(bytes, maxp.offset + 4) == 3)
    }

    /** loca 非单调抛 Syntax。 */
    @TestCase
    public func locaNonMonotonic(): Unit {
        let bytes = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(bytes)
        let loca = directory.table("loca").getOrThrow()
        // 短 loca：把第 3 项改小，破坏单调性。
        bytes[loca.offset + 6] = 0
        bytes[loca.offset + 7] = 0
        let error = expectSvgException({=> SvgTrueTypeFont.parse(bytes)})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** 表数与表长上限在读取表体前失败。 */
    @TestCase
    public func tableLimits(): Unit {
        let tooMany = m4BuildTtf()
        tooMany[4] = 0
        tooMany[5] = 65
        let countError = expectSvgException({=> SvgTtfTableDirectory.parse(tooMany)})
        @Assert(countError.kind == SvgErrorKind.Limit)

        let tooLong = m4BuildTtf()
        // 第一个目录项从 12 开始：tag(4) checksum(4) offset(4) length(4)
        let huge = 17 * 1024 * 1024
        tooLong[24] = UInt8((huge >> 24) & 0xFF)
        tooLong[25] = UInt8((huge >> 16) & 0xFF)
        tooLong[26] = UInt8((huge >> 8) & 0xFF)
        tooLong[27] = UInt8(huge & 0xFF)
        let lengthError = expectSvgException({=> SvgTtfTableDirectory.parse(tooLong)})
        @Assert(lengthError.kind == SvgErrorKind.Limit)
    }

    /** 表 tag 必须是 4 字节 ASCII；非法 tag 抛 Syntax 而非运行时异常。 */
    @TestCase
    public func nonAsciiTag(): Unit {
        let bytes = m4BuildTtf()
        bytes[12] = 0xFF
        let error = expectSvgException({=> SvgTtfTableDirectory.parse(bytes)})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** head / hhea / maxp 的声明长度不足必须在读取字段前抛 Syntax。 */
    @TestCase
    public func declaredTableLengths(): Unit {
        for (tag in ["head", "hhea", "maxp"]) {
            let bytes = m4BuildTtf()
            let entry = m4TableEntryOffset(tag)
            m4WriteU32(bytes, entry + 12, 0)
            let error = expectSvgException({=> SvgTrueTypeFont.parse(bytes)})
            @Assert(error.kind == SvgErrorKind.Syntax)
        }
    }

    /** cmap 子表声明长度不足必须在解析段表前抛 Syntax。 */
    @TestCase
    public func cmapSubtableLength(): Unit {
        let bytes = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(bytes)
        let cmap = directory.table("cmap").getOrThrow()
        // cmap 头 4 字节 + 1 条记录 8 字节，子表从记录中的偏移 12 开始。
        let subtable = cmap.offset + 12
        bytes[subtable + 2] = 0
        bytes[subtable + 3] = 10
        let error = expectSvgException({=> SvgTrueTypeFont.parse(bytes)})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** 文件在 loca 表中间被截断。 */
    @TestCase
    public func locaTruncatedInMiddle(): Unit {
        let bytes = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(bytes)
        let loca = directory.table("loca").getOrThrow()
        let truncated = bytes[0..loca.offset + 3]
        let error = expectSvgException({=> SvgTrueTypeFont.parse(truncated)})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }
}

