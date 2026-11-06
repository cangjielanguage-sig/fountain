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
import std.fs.{File, Path, FSException}
import std.sync.AtomicInt64
import fountain::f_base.*

/**
 * 字体文件读取入口。
 *
 * 库内只有 `SvgTrueTypeFont.load(path)` 会经过这里；`parse(bytes)` 与渲染链
 * 不访问文件系统。读取计数供单元测试验证这条边界。
 */
internal class SvgFontFileAccess {
    private static let readCount = AtomicInt64(0)

    static func read(path: Path): Array<Byte> {
        readCount.fetchAdd(1)
        File.readFrom(path)
    }

    @When[test]
    public static func count(): Int64 {
        readCount.load()
    }

    @When[test]
    public static func reset(): Unit {
        readCount.store(0)
    }
}

/** TrueType 单字形点数上限。 */
internal let SVG_TTF_MAX_POINTS: Int64 = 10000
/** 复合字形递归深度上限。 */
internal let SVG_TTF_MAX_COMPOSITE_DEPTH: Int64 = 8

private class SvgCmapSegment {
    let endCode: Int64
    let startCode: Int64
    let idDelta: Int64
    let idRangeOffset: Int64
    let glyphArrayBase: Int64

    init(
        endCode: Int64,
        startCode: Int64,
        idDelta: Int64,
        idRangeOffset: Int64,
        glyphArrayBase: Int64
    ) {
        this.endCode = endCode
        this.startCode = startCode
        this.idDelta = idDelta
        this.idRangeOffset = idRangeOffset
        this.glyphArrayBase = glyphArrayBase
    }
}

private struct SvgCmapGroup {
    let startChar: Int64
    let endChar: Int64
    let startGlyph: Int64

    init(startChar: Int64, endChar: Int64, startGlyph: Int64) {
        this.startChar = startChar
        this.endChar = endChar
        this.startGlyph = startGlyph
    }
}

/**
 * TrueType 字体：只解析 `cmap`（4/12）、`glyf`、`hmtx`、`head`、`hhea`、`maxp`、`loca`。
 *
 * 不解析 hinting、GSUB / GPOS / kern；坐标按 `unitsPerEm` 缩放并翻转 y 轴。
 */
public class SvgTrueTypeFont <: SvgFont {
    private let unitsPerEmValue: Int64
    private let ascenderValue: Int64
    private let descenderValue: Int64
    private let glyphCount: Int64
    private let longLoca: Bool
    private let numberOfHMetrics: Int64
    private let hmtxReader: SvgTtfTableReader
    private let locaReader: SvgTtfTableReader
    private let glyfReader: SvgTtfTableReader
    private let cmapFormat: Int64
    private let cmapSubReader: SvgTtfTableReader
    private let cmapSegments: ArrayList<SvgCmapSegment>
    private let cmapGroups: ArrayList<SvgCmapGroup>
    /** 可选 OpenType 布局表；缺失或损坏时为 `None`。 */
    private let kernPairs: ?SvgKernPairs
    private let gposPairs: ?SvgGposPairs
    private let ligatureTable: ?SvgGsubLigatures

    private init(
        unitsPerEmValue: Int64,
        ascenderValue: Int64,
        descenderValue: Int64,
        glyphCount: Int64,
        longLoca: Bool,
        numberOfHMetrics: Int64,
        hmtxReader: SvgTtfTableReader,
        locaReader: SvgTtfTableReader,
        glyfReader: SvgTtfTableReader,
        cmapFormat: Int64,
        cmapSubReader: SvgTtfTableReader,
        cmapSegments: ArrayList<SvgCmapSegment>,
        cmapGroups: ArrayList<SvgCmapGroup>,
        kernPairs: ?SvgKernPairs,
        gposPairs: ?SvgGposPairs,
        ligatureTable: ?SvgGsubLigatures
    ) {
        this.unitsPerEmValue = unitsPerEmValue
        this.ascenderValue = ascenderValue
        this.descenderValue = descenderValue
        this.glyphCount = glyphCount
        this.longLoca = longLoca
        this.numberOfHMetrics = numberOfHMetrics
        this.hmtxReader = hmtxReader
        this.locaReader = locaReader
        this.glyfReader = glyfReader
        this.cmapFormat = cmapFormat
        this.cmapSubReader = cmapSubReader
        this.cmapSegments = cmapSegments
        this.cmapGroups = cmapGroups
        this.kernPairs = kernPairs
        this.gposPairs = gposPairs
        this.ligatureTable = ligatureTable
    }

    public prop unitsPerEm: Int64 {
        get() {
            this.unitsPerEmValue
        }
    }

    public static func parse(bytes: Array<Byte>): SvgTrueTypeFont {
        let directory = SvgTtfTableDirectory.parse(bytes)
        if (directory.size < 7) {
            throw SvgException("TrueType 必需表数量不足", kind: SvgErrorKind.Syntax)
        }
        if (directory.table("CFF ").isSome()) {
            throw SvgException("不支持 CFF / OTF 轮廓", kind: SvgErrorKind.Unsupported)
        }
        let head = requireTtfTable(directory, "head")
        let hhea = requireTtfTable(directory, "hhea")
        let maxp = requireTtfTable(directory, "maxp")
        let hmtx = requireTtfTable(directory, "hmtx")
        let loca = requireTtfTable(directory, "loca")
        let cmap = requireTtfTable(directory, "cmap")
        let glyf = requireTtfTable(directory, "glyf")

        let headReader = SvgTtfTableReader(bytes, head)
        let hheaReader = SvgTtfTableReader(bytes, hhea)
        let maxpReader = SvgTtfTableReader(bytes, maxp)
        let hmtxReader = SvgTtfTableReader(bytes, hmtx)
        let locaReader = SvgTtfTableReader(bytes, loca)
        let cmapReader = SvgTtfTableReader(bytes, cmap)
        let glyfReader = SvgTtfTableReader(bytes, glyf)

        if (head.length < 54) {
            throw SvgException("head 表截断", kind: SvgErrorKind.Syntax)
        }
        if (hhea.length < 36) {
            throw SvgException("hhea 表截断", kind: SvgErrorKind.Syntax)
        }
        if (maxp.length < 6) {
            throw SvgException("maxp 表截断", kind: SvgErrorKind.Syntax)
        }
        let unitsPerEm = headReader.u16(18)
        if (unitsPerEm <= 0) {
            throw SvgException("head.unitsPerEm 非法", kind: SvgErrorKind.Syntax)
        }
        let locaFormat = headReader.i16(50)
        if (locaFormat != 0 && locaFormat != 1) {
            throw SvgException("head.indexToLocFormat 非法", kind: SvgErrorKind.Syntax)
        }
        let glyphCount = maxpReader.u16(4)
        let ascender = hheaReader.i16(4)
        let descender = hheaReader.i16(6)
        let numberOfHMetrics = hheaReader.u16(34)
        if (numberOfHMetrics <= 0 || numberOfHMetrics > glyphCount) {
            throw SvgException("hhea.numberOfHMetrics 非法", kind: SvgErrorKind.Syntax)
        }
        if (numberOfHMetrics * 4 > hmtx.length) {
            throw SvgException("hmtx 表截断", kind: SvgErrorKind.Syntax)
        }
        let longLoca = locaFormat == 1
        let requiredLoca = if (longLoca) {
            (glyphCount + 1) * 4
        } else {
            (glyphCount + 1) * 2
        }
        if (requiredLoca > loca.length) {
            throw SvgException("loca 表截断", kind: SvgErrorKind.Syntax)
        }

        var previous: Int64 = 0
        var index: Int64 = 0
        while (index <= glyphCount) {
            let value = if (longLoca) {
                locaReader.u32(index * 4)
            } else {
                locaReader.u16(index * 2) * 2
            }
            if (index > 0 && value < previous) {
                throw SvgException("loca 表非单调", kind: SvgErrorKind.Syntax)
            }
            if (value > glyf.length) {
                throw SvgException("loca 偏移越过 glyf 表", kind: SvgErrorKind.Syntax)
            }
            previous = value
            index++
        }

        let segments = ArrayList<SvgCmapSegment>()
        let groups = ArrayList<SvgCmapGroup>()
        let cmapParsed = SvgTrueTypeFont.parseCmap(cmapReader, segments, groups)
        let layoutWarnings = ArrayList<String>()
        let kern = match (directory.table("kern")) {
            case Some(table) => SvgKernPairs.parse(SvgTtfTableReader(bytes, table), layoutWarnings)
            case None => Option<SvgKernPairs>.None
        }
        let gpos = match (directory.table("GPOS")) {
            case Some(table) => SvgGposPairs.parse(SvgTtfTableReader(bytes, table), layoutWarnings)
            case None => Option<SvgGposPairs>.None
        }
        let ligatures = match (directory.table("GSUB")) {
            case Some(table) => SvgGsubLigatures.parse(SvgTtfTableReader(bytes, table), layoutWarnings)
            case None => Option<SvgGsubLigatures>.None
        }
        SvgTrueTypeFont(
            unitsPerEm,
            ascender,
            descender,
            glyphCount,
            longLoca,
            numberOfHMetrics,
            hmtxReader,
            locaReader,
            glyfReader,
            cmapParsed.format,
            cmapParsed.reader,
            segments,
            groups,
            kern,
            gpos,
            ligatures
        )
    }

    public static func load(path: Path): SvgTrueTypeFont {
        let bytes = try {
            SvgFontFileAccess.read(path)
        } catch (_: FSException) {
            throw SvgException("无法读取字体文件 ${path}", kind: SvgErrorKind.Syntax)
        }
        parse(bytes)
    }

    /** 字体是否提供字距（GPOS 优先，其次 kern）。 */
    internal func hasKerning(): Bool {
        this.gposPairs.isSome() || this.kernPairs.isSome()
    }

    /** 相邻字形的 x advance 调整（设计单位换算到目标字号）。 */
    internal func kerningAdjust(left: Int64, right: Int64, fontSize: Float64): Float64 {
        let leftGlyph = match (this.glyphIndex(left)) {
            case Some(value) => value
            case None => return 0.0
        }
        let rightGlyph = match (this.glyphIndex(right)) {
            case Some(value) => value
            case None => return 0.0
        }
        let units = match (this.gposPairs) {
            case Some(value) => value.adjust(leftGlyph, rightGlyph)
            case None => match (this.kernPairs) {
                case Some(value) => value.adjust(leftGlyph, rightGlyph)
                case None => 0
            }
        }
        Float64(units) * fontSize / Float64(this.unitsPerEmValue)
    }

    /** 字体是否提供 `liga` 连字。 */
    internal func hasLigatures(): Bool {
        this.ligatureTable.isSome()
    }

    /** 从 `start` 起匹配最长连字，返回 `(连字字形 id, 消费字符数)`。 */
    internal func ligatureAt(codePoints: Array<Int64>, start: Int64): ?(Int64, Int64) {
        let table = match (this.ligatureTable) {
            case Some(value) => value
            case None => return Option<(Int64, Int64)>.None
        }
        let glyphs = ArrayList<Int64>()
        for (codePoint in codePoints) {
            match (this.glyphIndex(codePoint)) {
                case Some(value) => glyphs.add(value)
                case None => glyphs.add(0)
            }
        }
        table.findLigature(glyphs.toArray(), start)
    }

    /** 按字形 id 取 advance（不经过 cmap）。 */
    internal func advanceById(gid: Int64, fontSize: Float64): Float64 {
        let metricIndex = if (gid < this.numberOfHMetrics) { gid } else { this.numberOfHMetrics - 1 }
        let advance = this.hmtxReader.u16(metricIndex * 4)
        Float64(advance) * fontSize / Float64(this.unitsPerEmValue)
    }

    /** 按字形 id 取轮廓。 */
    internal func pathById(gid: Int64, fontSize: Float64): ?SvgPathData {
        let commands = this.parseGlyph(gid, 0)
        let scale = fontSize / Float64(this.unitsPerEmValue)
        let scaled = ArrayList<SvgPathCommand>()
        for (command in commands) {
            scaled.add(scaleTtfCommand(command, scale))
        }
        Some(SvgPathData(scaled.toArray()))
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        let gid = match (this.glyphIndex(codePoint)) {
            case Some(value) => value
            case None => return 0.0
        }
        let metricIndex = if (gid < this.numberOfHMetrics) { gid } else { this.numberOfHMetrics - 1 }
        let advance = this.hmtxReader.u16(metricIndex * 4)
        Float64(advance) * fontSize / Float64(this.unitsPerEmValue)
    }

    public func ascent(fontSize: Float64): Float64 {
        Float64(this.ascenderValue) / Float64(this.unitsPerEmValue) * fontSize
    }

    public func descent(fontSize: Float64): Float64 {
        -Float64(this.descenderValue) / Float64(this.unitsPerEmValue) * fontSize
    }

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        let gid = match (this.glyphIndex(codePoint)) {
            case Some(value) => value
            case None => return None
        }
        let commands = this.parseGlyph(gid, 0)
        let scale = fontSize / Float64(this.unitsPerEmValue)
        let scaled = ArrayList<SvgPathCommand>()
        for (command in commands) {
            scaled.add(scaleTtfCommand(command, scale))
        }
        Some(SvgPathData(scaled.toArray()))
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        let path = match (this.glyphPath(codePoint, fontSize)) {
            case Some(value) => value
            case None => return None
        }
        if (path.commands.size == 0) {
            return Some(SvgBounds(0.0, 0.0, 0.0, 0.0))
        }
        pathDataBounds(path)
    }

    private func glyphIndex(codePoint: Int64): ?Int64 {
        if (this.cmapFormat == 12) {
            for (group in this.cmapGroups) {
                if (codePoint >= group.startChar && codePoint <= group.endChar) {
                    return Some(group.startGlyph + codePoint - group.startChar)
                }
            }
            return None
        }
        for (segment in this.cmapSegments) {
            if (codePoint > segment.endCode) {
                continue
            }
            if (codePoint < segment.startCode) {
                return None
            }
            if (segment.idRangeOffset == 0) {
                return Some(positiveTtfMod(codePoint + segment.idDelta, 65536))
            }
            let address = segment.glyphArrayBase + segment.idRangeOffset +
                2 * (codePoint - segment.startCode)
            let glyph = this.cmapSubReader.u16(address)
            return Some(positiveTtfMod(glyph + segment.idDelta, 65536))
        }
        None
    }

    private func locaAt(index: Int64): Int64 {
        if (this.longLoca) {
            this.locaReader.u32(index * 4)
        } else {
            this.locaReader.u16(index * 2) * 2
        }
    }

    private func parseGlyph(index: Int64, depth: Int64): Array<SvgPathCommand> {
        if (depth > SVG_TTF_MAX_COMPOSITE_DEPTH) {
            throw SvgException(
                "复合字形递归深度超过 ${SVG_TTF_MAX_COMPOSITE_DEPTH}",
                kind: SvgErrorKind.Limit
            )
        }
        if (index < 0 || index >= this.glyphCount) {
            throw SvgException("字形索引 ${index} 越界", kind: SvgErrorKind.Syntax)
        }
        let start = this.locaAt(index)
        let end = this.locaAt(index + 1)
        if (start == end) {
            return Array<SvgPathCommand>()
        }
        if (start < 0 || end > this.glyfReader.length || start > end) {
            throw SvgException("glyf 数据截断", kind: SvgErrorKind.Syntax)
        }
        let glyph = this.glyfReader.slice(start, end - start)
        let contours = glyph.i16(0)
        if (contours >= 0) {
            return this.parseSimpleGlyph(glyph, contours)
        }
        if (contours == -1) {
            return this.parseCompositeGlyph(glyph, depth)
        }
        throw SvgException("字形 numberOfContours 非法", kind: SvgErrorKind.Syntax)
    }

    private func parseSimpleGlyph(glyph: SvgTtfTableReader, numberOfContours: Int64): Array<SvgPathCommand> {
        if (numberOfContours == 0) {
            return Array<SvgPathCommand>()
        }
        let endPoints = Array<Int64>(numberOfContours, repeat: 0)
        var contourIndex: Int64 = 0
        while (contourIndex < numberOfContours) {
            endPoints[contourIndex] = glyph.u16(10 + contourIndex * 2)
            contourIndex++
        }
        let pointCount = endPoints[numberOfContours - 1] + 1
        if (pointCount > SVG_TTF_MAX_POINTS) {
            throw SvgException(
                "字形点数 ${pointCount} 超过上限 ${SVG_TTF_MAX_POINTS}",
                kind: SvgErrorKind.Limit
            )
        }
        contourIndex = 1
        while (contourIndex < numberOfContours) {
            if (endPoints[contourIndex] <= endPoints[contourIndex - 1]) {
                throw SvgException("字形 endPtsOfContours 非严格递增", kind: SvgErrorKind.Syntax)
            }
            contourIndex++
        }
        var cursor = 10 + numberOfContours * 2
        let instructionLength = glyph.u16(cursor)
        cursor += 2 + instructionLength

        let flags = Array<Int64>(pointCount, repeat: 0)
        var flagIndex: Int64 = 0
        while (flagIndex < pointCount) {
            let flag = glyph.u8(cursor)
            cursor++
            flags[flagIndex] = flag
            flagIndex++
            if ((flag & 0x08) != 0) {
                var repeat = glyph.u8(cursor)
                cursor++
                while (repeat > 0 && flagIndex < pointCount) {
                    flags[flagIndex] = flag
                    flagIndex++
                    repeat--
                }
            }
        }

        let xs = Array<Int64>(pointCount, repeat: 0)
        let ys = Array<Int64>(pointCount, repeat: 0)
        var x: Int64 = 0
        var y: Int64 = 0
        var index: Int64 = 0
        while (index < pointCount) {
            let flag = flags[index]
            var delta: Int64
            if ((flag & 0x02) != 0) {
                delta = glyph.u8(cursor)
                cursor++
                if ((flag & 0x10) == 0) {
                    delta = -delta
                }
            } else if ((flag & 0x10) != 0) {
                delta = 0
            } else {
                delta = glyph.i16(cursor)
                cursor += 2
            }
            x += delta
            xs[index] = x
            index++
        }
        index = 0
        while (index < pointCount) {
            let flag = flags[index]
            var delta: Int64
            if ((flag & 0x04) != 0) {
                delta = glyph.u8(cursor)
                cursor++
                if ((flag & 0x20) == 0) {
                    delta = -delta
                }
            } else if ((flag & 0x20) != 0) {
                delta = 0
            } else {
                delta = glyph.i16(cursor)
                cursor += 2
            }
            y += delta
            ys[index] = y
            index++
        }

        let commands = ArrayList<SvgPathCommand>()
        var startPoint: Int64 = 0
        contourIndex = 0
        while (contourIndex < numberOfContours) {
            let endPoint = endPoints[contourIndex]
            appendTtfContour(commands, xs, ys, flags, startPoint, endPoint)
            startPoint = endPoint + 1
            contourIndex++
        }
        commands.toArray()
    }

    private func parseCompositeGlyph(glyph: SvgTtfTableReader, depth: Int64): Array<SvgPathCommand> {
        let commands = ArrayList<SvgPathCommand>()
        var cursor: Int64 = 10
        var more = true
        var flags: Int64 = 0
        while (more) {
            flags = glyph.u16(cursor)
            let component = glyph.u16(cursor + 2)
            cursor += 4
            var argument1: Int64
            var argument2: Int64
            if ((flags & 0x0001) != 0) {
                argument1 = glyph.i16(cursor)
                argument2 = glyph.i16(cursor + 2)
                cursor += 4
            } else {
                argument1 = glyph.i8(cursor)
                argument2 = glyph.i8(cursor + 1)
                cursor += 2
            }
            let dx = if ((flags & 0x0002) != 0) { argument1 } else { 0 }
            let dy = if ((flags & 0x0002) != 0) { argument2 } else { 0 }
            var a = 1.0
            var b = 0.0
            var c = 0.0
            var d = 1.0
            if ((flags & 0x0008) != 0) {
                let scale = Float64(glyph.i16(cursor)) / 16384.0
                a = scale
                d = scale
                cursor += 2
            } else if ((flags & 0x0040) != 0) {
                a = Float64(glyph.i16(cursor)) / 16384.0
                d = Float64(glyph.i16(cursor + 2)) / 16384.0
                cursor += 4
            } else if ((flags & 0x0080) != 0) {
                a = Float64(glyph.i16(cursor)) / 16384.0
                b = Float64(glyph.i16(cursor + 2)) / 16384.0
                c = Float64(glyph.i16(cursor + 4)) / 16384.0
                d = Float64(glyph.i16(cursor + 6)) / 16384.0
                cursor += 8
            }
            let child = this.parseGlyph(component, depth + 1)
            for (command in child) {
                commands.add(transformTtfCommand(command, a, b, c, d, Float64(dx), Float64(dy)))
            }
            more = (flags & 0x0020) != 0
        }
        if ((flags & 0x0100) != 0) {
            let instructionLength = glyph.u16(cursor)
            cursor += 2 + instructionLength
        }
        commands.toArray()
    }

    private static func parseCmap(
        cmap: SvgTtfTableReader,
        segments: ArrayList<SvgCmapSegment>,
        groups: ArrayList<SvgCmapGroup>
    ): SvgCmapParseResult {
        if (cmap.length < 4) {
            throw SvgException("cmap 表截断", kind: SvgErrorKind.Syntax)
        }
        let count = cmap.u16(2)
        if (4 + count * 8 > cmap.length) {
            throw SvgException("cmap 编码记录截断", kind: SvgErrorKind.Syntax)
        }
        var chosenFormat: Int64 = 0
        var chosenOffset: Int64 = 0
        var chosenLength: Int64 = 0
        var index: Int64 = 0
        while (index < count) {
            let record = 4 + index * 8
            let subtableOffset = cmap.u32(record + 4)
            if (subtableOffset + 4 > cmap.length) {
                throw SvgException("cmap 子表越界", kind: SvgErrorKind.Syntax)
            }
            let format = cmap.u16(subtableOffset)
            let declaredLength = if (format == 12) {
                if (subtableOffset + 8 > cmap.length) {
                    throw SvgException("cmap 子表越界", kind: SvgErrorKind.Syntax)
                }
                cmap.u32(subtableOffset + 4)
            } else {
                cmap.u16(subtableOffset + 2)
            }
            if (declaredLength <= 0 || subtableOffset + declaredLength > cmap.length) {
                throw SvgException("cmap 子表长度越界", kind: SvgErrorKind.Syntax)
            }
            if (format == 12) {
                chosenFormat = 12
                chosenOffset = subtableOffset
                chosenLength = declaredLength
                break
            }
            if (format == 4 && chosenFormat == 0) {
                chosenFormat = 4
                chosenOffset = subtableOffset
                chosenLength = declaredLength
            }
            index++
        }
        if (chosenFormat == 0) {
            throw SvgException("cmap 缺少支持的 format 4 / 12", kind: SvgErrorKind.Syntax)
        }
        let subtable = cmap.slice(chosenOffset, chosenLength)
        if (chosenFormat == 4) {
            if (subtable.length < 14) {
                throw SvgException("cmap format 4 子表截断", kind: SvgErrorKind.Syntax)
            }
            let segCountX2 = subtable.u16(6)
            let segCount = segCountX2 / 2
            let required = 16 + segCountX2 * 4
            if (required > subtable.length) {
                throw SvgException("cmap format 4 段表截断", kind: SvgErrorKind.Syntax)
            }
            let endCodes = 14
            let startCodes = endCodes + segCountX2 + 2
            let idDeltas = startCodes + segCountX2
            let idRangeOffsets = idDeltas + segCountX2
            var segmentIndex: Int64 = 0
            while (segmentIndex < segCount) {
                let endCode = subtable.u16(endCodes + segmentIndex * 2)
                let startCode = subtable.u16(startCodes + segmentIndex * 2)
                let idDelta = subtable.i16(idDeltas + segmentIndex * 2)
                let rangeOffsetAddress = idRangeOffsets + segmentIndex * 2
                let idRangeOffset = subtable.u16(rangeOffsetAddress)
                if (startCode > endCode) {
                    throw SvgException("cmap format 4 段范围非法", kind: SvgErrorKind.Syntax)
                }
                if (idRangeOffset != 0) {
                    let glyphAddress = rangeOffsetAddress + idRangeOffset
                    if (glyphAddress + (endCode - startCode + 1) * 2 > subtable.length) {
                        throw SvgException("cmap format 4 字形数组越界", kind: SvgErrorKind.Syntax)
                    }
                }
                segments.add(
                    SvgCmapSegment(
                        endCode,
                        startCode,
                        idDelta,
                        idRangeOffset,
                        rangeOffsetAddress
                    )
                )
                segmentIndex++
            }
        } else {
            if (subtable.length < 16) {
                throw SvgException("cmap format 12 子表截断", kind: SvgErrorKind.Syntax)
            }
            let groupCount = subtable.u32(12)
            if (16 + groupCount * 12 > subtable.length) {
                throw SvgException("cmap format 12 分组截断", kind: SvgErrorKind.Syntax)
            }
            var groupIndex: Int64 = 0
            while (groupIndex < groupCount) {
                let base = 16 + groupIndex * 12
                let startChar = subtable.u32(base)
                let endChar = subtable.u32(base + 4)
                if (startChar > endChar) {
                    throw SvgException("cmap format 12 分组范围非法", kind: SvgErrorKind.Syntax)
                }
                groups.add(
                    SvgCmapGroup(startChar, endChar, subtable.u32(base + 8))
                )
                groupIndex++
            }
        }
        SvgCmapParseResult(chosenFormat, subtable)
    }
}

internal class SvgCmapParseResult {
    let format: Int64
    let reader: SvgTtfTableReader

    init(format: Int64, reader: SvgTtfTableReader) {
        this.format = format
        this.reader = reader
    }
}

private func positiveTtfMod(value: Int64, modulus: Int64): Int64 {
    let remainder = value % modulus
    if (remainder < 0) {
        remainder + modulus
    } else {
        remainder
    }
}

private func requireTtfTable(directory: SvgTtfTableDirectory, tag: String): SvgTtfTable {    match (directory.table(tag)) {
        case Some(value) => value
        case None => throw SvgException("缺少必需表「${tag}」", kind: SvgErrorKind.Syntax)
    }
}

private func appendTtfContour(
    commands: ArrayList<SvgPathCommand>,
    xs: Array<Int64>,
    ys: Array<Int64>,
    flags: Array<Int64>,
    startPoint: Int64,
    endPoint: Int64
): Unit {
    if (startPoint < 0 || endPoint < startPoint || endPoint >= xs.size ||
        endPoint >= ys.size || endPoint >= flags.size) {
        throw SvgException("字形轮廓端点越界", kind: SvgErrorKind.Syntax)
    }
    let count = endPoint - startPoint + 1
    if (count <= 0) {
        return
    }
    var firstOn: Int64 = -1
    var index: Int64 = 0
    while (index < count) {
        if ((flags[startPoint + index] & 0x01) != 0) {
            firstOn = index
            break
        }
        index++
    }
    if (firstOn < 0) {
        let last = startPoint + count - 1
        let startX = (Float64(xs[last]) + Float64(xs[startPoint])) / 2.0
        let startY = (Float64(ys[last]) + Float64(ys[startPoint])) / 2.0
        commands.add(
            SvgPathCommand(SvgPathCommandKind.MoveTo, false, [startX, startY])
        )
        index = 0
        while (index < count) {
            let control = startPoint + index
            let next = startPoint + (index + 1) % count
            let endX = (Float64(xs[control]) + Float64(xs[next])) / 2.0
            let endY = (Float64(ys[control]) + Float64(ys[next])) / 2.0
            commands.add(
                SvgPathCommand(
                    SvgPathCommandKind.QuadraticBezierTo,
                    false,
                    [Float64(xs[control]), Float64(ys[control]), endX, endY]
                )
            )
            index++
        }
        commands.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
        return
    }

    let startX = Float64(xs[startPoint + firstOn])
    let startY = Float64(ys[startPoint + firstOn])
    commands.add(SvgPathCommand(SvgPathCommandKind.MoveTo, false, [startX, startY]))
    var current = firstOn
    var guard: Int64 = 0
    while (guard <= count + 1) {
        let control = (current + 1) % count
        if (control == firstOn) {
            break
        }
        let controlPoint = startPoint + control
        if ((flags[controlPoint] & 0x01) != 0) {
            commands.add(
                SvgPathCommand(
                    SvgPathCommandKind.LineTo,
                    false,
                    [Float64(xs[controlPoint]), Float64(ys[controlPoint])]
                )
            )
            current = control
        } else {
            let after = (control + 1) % count
            let afterPoint = startPoint + after
            if (after == firstOn) {
                commands.add(
                    SvgPathCommand(
                        SvgPathCommandKind.QuadraticBezierTo,
                        false,
                        [
                            Float64(xs[controlPoint]), Float64(ys[controlPoint]),
                            startX, startY
                        ]
                    )
                )
                break
            }
            if ((flags[afterPoint] & 0x01) != 0) {
                commands.add(
                    SvgPathCommand(
                        SvgPathCommandKind.QuadraticBezierTo,
                        false,
                        [
                            Float64(xs[controlPoint]), Float64(ys[controlPoint]),
                            Float64(xs[afterPoint]), Float64(ys[afterPoint])
                        ]
                    )
                )
                current = after
            } else {
                let endX = (Float64(xs[controlPoint]) + Float64(xs[afterPoint])) / 2.0
                let endY = (Float64(ys[controlPoint]) + Float64(ys[afterPoint])) / 2.0
                commands.add(
                    SvgPathCommand(
                        SvgPathCommandKind.QuadraticBezierTo,
                        false,
                        [
                            Float64(xs[controlPoint]), Float64(ys[controlPoint]),
                            endX, endY
                        ]
                    )
                )
                current = control
            }
        }
        guard++
    }
    commands.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
}

private func transformTtfCommand(
    command: SvgPathCommand,
    a: Float64,
    b: Float64,
    c: Float64,
    d: Float64,
    dx: Float64,
    dy: Float64
): SvgPathCommand {
    if (command.kind == SvgPathCommandKind.ClosePath) {
        return command
    }
    let values = ArrayList<Float64>()
    var index = 0
    while (index + 1 < command.values.size) {
        let x = command.values[index]
        let y = command.values[index + 1]
        values.add(a * x + c * y + dx)
        values.add(b * x + d * y + dy)
        index += 2
    }
    SvgPathCommand(command.kind, false, values.toArray())
}

private func scaleTtfCommand(command: SvgPathCommand, scale: Float64): SvgPathCommand {
    if (command.kind == SvgPathCommandKind.ClosePath) {
        return command
    }
    let values = ArrayList<Float64>()
    var index = 0
    while (index + 1 < command.values.size) {
        values.add(command.values[index] * scale)
        values.add(-command.values[index + 1] * scale)
        index += 2
    }
    SvgPathCommand(command.kind, false, values.toArray())
}
