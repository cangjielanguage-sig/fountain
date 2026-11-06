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

import std.collection.*
import std.fs.Path
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.*

internal class M4ByteWriter {
    let data = ArrayList<Byte>()

    func u8(value: Int64): M4ByteWriter {
        this.data.add(UInt8(value & 0xFF))
        this
    }

    func u16(value: Int64): M4ByteWriter {
        this.data.add(UInt8((value >> 8) & 0xFF))
        this.data.add(UInt8(value & 0xFF))
        this
    }

    func i16(value: Int64): M4ByteWriter {
        this.u16(value & 0xFFFF)
    }

    func u32(value: Int64): M4ByteWriter {
        this.data.add(UInt8((value >> 24) & 0xFF))
        this.data.add(UInt8((value >> 16) & 0xFF))
        this.data.add(UInt8((value >> 8) & 0xFF))
        this.data.add(UInt8(value & 0xFF))
        this
    }

    func tag(value: String): M4ByteWriter {
        for (byte in value.unsafeBytes()) {
            this.data.add(byte)
        }
        this
    }

    func padding(alignment: Int64): M4ByteWriter {
        while (this.data.size % alignment != 0) {
            this.data.add(0)
        }
        this
    }

    func toArray(): Array<Byte> {
        this.data.toArray()
    }
}

private let M4_TTF_TABLES: Array<String> = [
    "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp"
]

private func m4TtfHead(indexToLocFormat: Int64): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u32(0x00010000)
    writer.u32(0x00010000) // fontRevision
    writer.u32(0) // checksumAdjustment
    writer.u32(0x5F0F3CF5) // magic
    writer.u16(0) // flags
    writer.u16(1000) // unitsPerEm at offset 18
    writer.u32(0).u32(0) // created (8 bytes)
    writer.u32(0).u32(0) // modified (8 bytes)
    writer.i16(0).i16(0).i16(100).i16(100) // bbox
    writer.u16(0) // macStyle
    writer.u16(8) // lowestRecPPEM
    writer.i16(2) // fontDirectionHint
    writer.i16(indexToLocFormat) // offset 50
    writer.i16(0) // glyphDataFormat
    writer.toArray()
}

private func m4TtfHhea(numMetrics: Int64): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u32(0x00010000)
    writer.i16(800) // ascender at offset 4
    writer.i16(-200) // descender at offset 6
    writer.i16(0) // lineGap
    writer.u16(1000) // advanceWidthMax
    writer.i16(0).i16(0).i16(100).i16(100) // bbox
    writer.i16(1) // caretSlopeRise
    writer.i16(0) // caretSlopeRun
    writer.i16(0).i16(0).i16(0).i16(0)
    writer.i16(0) // metricDataFormat
    writer.u16(numMetrics) // offset 34
    writer.toArray()
}

private func m4TtfMaxp(numGlyphs: Int64): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u32(0x00010000)
    writer.u16(numGlyphs)
    writer.toArray()
}

private func m4TtfHmtx(advances: Array<Int64>): Array<Byte> {
    let writer = M4ByteWriter()
    for (advance in advances) {
        writer.u16(advance)
        writer.i16(0)
    }
    writer.toArray()
}

private func m4TtfSimpleGlyph(): Array<Byte> {
    let writer = M4ByteWriter()
    writer.i16(1) // numberOfContours
    writer.i16(0).i16(0).i16(100).i16(100)
    writer.u16(2) // endPtsOfContours
    writer.u16(0) // instructionLength
    writer.u8(0x01).u8(0x00).u8(0x01) // on, off, on
    writer.i16(0).i16(50).i16(50) // x deltas
    writer.i16(0).i16(100).i16(-100) // y deltas
    writer.u8(0) // 使短 loca 偏移为偶数
    writer.toArray()
}

private func m4TtfCompositeGlyph(component: Int64, dx: Int64): Array<Byte> {
    let writer = M4ByteWriter()
    writer.i16(-1)
    writer.i16(0).i16(0).i16(100).i16(100)
    writer.u16(0x0001 | 0x0002) // ARG_1_AND_2_ARE_WORDS | ARGS_ARE_XY_VALUES
    writer.u16(component)
    writer.i16(dx)
    writer.i16(0)
    writer.toArray()
}

private func m4TtfCmap4(): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u16(0) // version
    writer.u16(1) // numTables
    writer.u16(3).u16(1).u32(12) // platform 3 / encoding 1
    // format 4 subtable
    writer.u16(4)
    writer.u16(40) // length
    writer.u16(0) // language
    writer.u16(6) // segCountX2 = 3 segments
    writer.u16(4).u16(1).u16(0) // searchRange / entrySelector / rangeShift
    writer.u16(65).u16(66).u16(0xFFFF) // endCode
    writer.u16(0) // reservedPad
    writer.u16(65).u16(66).u16(0xFFFF) // startCode
    writer.i16(-64).i16(-64).i16(1) // idDelta
    writer.u16(0).u16(0).u16(0) // idRangeOffset
    writer.toArray()
}

private func m4TtfCmap12(): Array<Byte> {
    let writer = M4ByteWriter()
    writer.u16(0)
    writer.u16(1)
    writer.u16(3).u16(10).u32(12)
    writer.u16(12)
    writer.u16(0)
    writer.u32(28) // length
    writer.u32(0) // language
    writer.u32(1) // nGroups
    writer.u32(65).u32(65).u32(1) // U+0041 -> gid 1
    writer.toArray()
}

internal func m4BuildTtf(
    cmap12!: Bool = false,
    selfComposite!: Bool = false
): Array<Byte> {
    let simple = m4TtfSimpleGlyph()
    let composite = if (selfComposite) {
        m4TtfCompositeGlyph(2, 0)
    } else {
        m4TtfCompositeGlyph(1, 50)
    }
    let glyf = M4ByteWriter()
    for (byte in simple) {
        glyf.data.add(byte)
    }
    for (byte in composite) {
        glyf.data.add(byte)
    }
    let glyfBytes = glyf.toArray()
    let simpleLength = Int64(simple.size)
    let compositeLength = Int64(composite.size)
    let locaWriter = M4ByteWriter()
    locaWriter.u16(0)
    locaWriter.u16(0)
    locaWriter.u16(simpleLength / 2)
    locaWriter.u16((simpleLength + compositeLength) / 2)

    let tables = HashMap<String, Array<Byte>>()
    tables["head"] = m4TtfHead(0)
    tables["hhea"] = m4TtfHhea(3)
    tables["maxp"] = m4TtfMaxp(3)
    tables["hmtx"] = m4TtfHmtx([500, 600, 700])
    tables["loca"] = locaWriter.toArray()
    tables["cmap"] = if (cmap12) { m4TtfCmap12() } else { m4TtfCmap4() }
    tables["glyf"] = glyfBytes

    let headerSize = 12 + 16 * Int64(M4_TTF_TABLES.size)
    var offset = headerSize
    let offsets = HashMap<String, Int64>()
    let lengths = HashMap<String, Int64>()
    for (tag in M4_TTF_TABLES) {
        offset = (offset + 3) / 4 * 4
        offsets[tag] = offset
        let data = tables.get(tag).getOrThrow()
        lengths[tag] = Int64(data.size)
        offset += Int64(data.size)
    }

    let writer = M4ByteWriter()
    writer.u32(0x00010000)
    writer.u16(Int64(M4_TTF_TABLES.size))
    writer.u16(128).u16(3).u16(32)
    for (tag in M4_TTF_TABLES) {
        writer.tag(tag)
        writer.u32(0)
        writer.u32(offsets.get(tag).getOrThrow())
        writer.u32(lengths.get(tag).getOrThrow())
    }
    for (tag in M4_TTF_TABLES) {
        writer.padding(4)
        let data = tables.get(tag).getOrThrow()
        for (byte in data) {
            writer.data.add(byte)
        }
    }
    writer.toArray()
}

private func m4TableEntryOffset(tag: String): Int64 {
    var index = 0
    while (index < M4_TTF_TABLES.size) {
        if (M4_TTF_TABLES[index] == tag) {
            return 12 + Int64(index) * 16
        }
        index++
    }
    -1
}

private func m4WriteU32(target: Array<Byte>, offset: Int64, value: Int64): Unit {
    target[offset] = UInt8((value >> 24) & 0xFF)
    target[offset + 1] = UInt8((value >> 16) & 0xFF)
    target[offset + 2] = UInt8((value >> 8) & 0xFF)
    target[offset + 3] = UInt8(value & 0xFF)
}

@Test
public class SvgTrueTypeTablesM4_test {
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
        @Assert(readTtfI16(bytes, head.offset + 50) == 0)
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

@Test
public class SvgTrueTypeFontM4_test {
    /** unitsPerEm、advance、简单字形路径与包围盒。 */
    @TestCase
    public func simpleGlyph(): Unit {
        let font = SvgTrueTypeFont.parse(m4BuildTtf())
        @Assert(font.unitsPerEm == 1000)
        @Assert(near(font.ascent(1000.0), 800.0))
        @Assert(near(font.descent(1000.0), 200.0))
        @Assert(near(font.advance(65, 1000.0), 600.0))
        @Assert(near(font.advance(65, 500.0), 300.0))

        let path = font.glyphPath(65, 1000.0)
        @Assert(path.isSome())
        let commands = path.getOrThrow().commands
        @Assert(commands.size == 3)
        @Assert(commands[0].kind == SvgPathCommandKind.MoveTo)
        @Assert(commands[1].kind == SvgPathCommandKind.QuadraticBezierTo)
        @Assert(commands[2].kind == SvgPathCommandKind.ClosePath)
        // y 轴翻转：控制点 (50,100) → (50,-100)。
        @Assert(near(commands[1].values[1], -100.0))
        @Assert(near(commands[1].values[3], 0.0))

        let bounds = font.glyphBounds(65, 1000.0)
        @Assert(bounds.isSome())
        @Assert(near(bounds.getOrThrow().x, 0.0))
        @Assert(near(bounds.getOrThrow().y, -50.0))
        @Assert(near(bounds.getOrThrow().width, 100.0))
        @Assert(near(bounds.getOrThrow().height, 50.0))

        // 空字形（gid 0）。
        let empty = font.glyphPath(0xFFFF, 1000.0)
        @Assert(empty.isSome())
        @Assert(empty.getOrThrow().commands.size == 0)
        let emptyBounds = font.glyphBounds(0xFFFF, 1000.0).getOrThrow()
        @Assert(near(emptyBounds.width, 0.0) && near(emptyBounds.height, 0.0))

        @Assert(font.glyphPath(999, 1000.0).isNone())
    }

    /** 复合字形按偏移组合。 */
    @TestCase
    public func compositeGlyph(): Unit {
        let font = SvgTrueTypeFont.parse(m4BuildTtf())
        let path = font.glyphPath(66, 1000.0).getOrThrow()
        @Assert(path.commands.size == 3)
        @Assert(near(path.commands[0].values[0], 50.0))
        let bounds = font.glyphBounds(66, 1000.0).getOrThrow()
        @Assert(near(bounds.x, 50.0))
        @Assert(near(bounds.width, 100.0))
    }

    /** cmap format 12。 */
    @TestCase
    public func cmapFormat12(): Unit {
        let font = SvgTrueTypeFont.parse(m4BuildTtf(cmap12: true))
        @Assert(font.glyphPath(65, 1000.0).isSome())
        @Assert(font.glyphPath(66, 1000.0).isNone())
    }

    /** CFF / OTF 拒绝、必需表缺失。 */
    @TestCase
    public func unsupportedAndMissing(): Unit {
        let otto = m4BuildTtf()
        otto[0] = 0x4F
        otto[1] = 0x54
        otto[2] = 0x54
        otto[3] = 0x4F
        let cffError = expectSvgException({=> SvgTrueTypeFont.parse(otto)})
        @Assert(cffError.kind == SvgErrorKind.Unsupported)

        let missing = m4BuildTtf()
        // 把 maxp 目录项 tag 改成 junk，制造必需表缺失。
        missing[12] = 0x6A
        missing[13] = 0x75
        missing[14] = 0x6E
        missing[15] = 0x6B
        let missingError = expectSvgException({=> SvgTrueTypeFont.parse(missing)})
        @Assert(missingError.kind == SvgErrorKind.Syntax)

        let loadError = expectSvgException({=> SvgTrueTypeFont.load(Path("/nonexistent/f_svg_m4.ttf"))})
        @Assert(loadError.kind == SvgErrorKind.Syntax)
    }

    /** 字形点数与复合深度上限。 */
    @TestCase
    public func fontLimits(): Unit {
        let manyPoints = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(manyPoints)
        let glyf = directory.table("glyf").getOrThrow()
        // 简单字形 endPtsOfContours 在 glyf 起始 +10。
        manyPoints[glyf.offset + 10] = 0x27
        manyPoints[glyf.offset + 11] = 0x10 // 10000
        let font = SvgTrueTypeFont.parse(manyPoints)
        let pointError = expectSvgException({=> font.glyphPath(65, 1000.0)})
        @Assert(pointError.kind == SvgErrorKind.Limit)

        let deep = SvgTrueTypeFont.parse(m4BuildTtf(selfComposite: true))
        let depthError = expectSvgException({=> deep.glyphPath(66, 1000.0)})
        @Assert(depthError.kind == SvgErrorKind.Limit)
    }

    /** 非单调 endPtsOfContours 不得触发数组越界，必须抛 Syntax。 */
    @TestCase
    public func malformedEndPoints(): Unit {
        let bytes = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(bytes)
        let glyf = directory.table("glyf").getOrThrow()
        // 声明 2 个 contour，endPts = [1000, 1]。
        bytes[glyf.offset] = 0
        bytes[glyf.offset + 1] = 2
        bytes[glyf.offset + 10] = 0x03
        bytes[glyf.offset + 11] = 0xE8
        bytes[glyf.offset + 12] = 0
        bytes[glyf.offset + 13] = 1
        bytes[glyf.offset + 14] = 0
        bytes[glyf.offset + 15] = 0
        let font = SvgTrueTypeFont.parse(bytes)
        let error = expectSvgException({=> font.glyphPath(65, 1000.0)})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** 注册到 SvgFontRegistry 后渲染文本。 */
    @TestCase
    public func registryIntegration(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Ttf", SvgTrueTypeFont.parse(m4BuildTtf()))
        let document = SvgParser.parse(
            "<svg width=\"40\" height=\"40\"><text x=\"5\" y=\"30\" font-family=\"Ttf\" " +
            "font-size=\"20\" fill=\"red\">A</text></svg>"
        )
        let renderer = SvgRenderer(
            options: SvgRenderOptions(fonts: registry, samplesPerPixel: 1)
        )
        let bitmap = renderer.render(document)
        var ink = false
        for (index in 0..bitmap.pixels.size) {
            if (bitmap.pixels[index] != 0) {
                ink = true
                break
            }
        }
        @Assert(ink)
    }
}
