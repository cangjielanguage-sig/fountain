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
import fountain::f_base.*

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
    private let data: Array<Byte>
    private let unitsPerEmValue: Int64
    private let ascenderValue: Int64
    private let descenderValue: Int64
    private let glyphCount: Int64
    private let longLoca: Bool
    private let hmtxOffset: Int64
    private let hmtxLength: Int64
    private let numberOfHMetrics: Int64
    private let locaOffset: Int64
    private let glyfOffset: Int64
    private let glyfLength: Int64
    private let cmapFormat: Int64
    private let cmapSegments: ArrayList<SvgCmapSegment>
    private let cmapGroups: ArrayList<SvgCmapGroup>

    private init(
        data: Array<Byte>,
        unitsPerEmValue: Int64,
        ascenderValue: Int64,
        descenderValue: Int64,
        glyphCount: Int64,
        longLoca: Bool,
        hmtxOffset: Int64,
        hmtxLength: Int64,
        numberOfHMetrics: Int64,
        locaOffset: Int64,
        glyfOffset: Int64,
        glyfLength: Int64,
        cmapFormat: Int64,
        cmapSegments: ArrayList<SvgCmapSegment>,
        cmapGroups: ArrayList<SvgCmapGroup>
    ) {
        this.data = data
        this.unitsPerEmValue = unitsPerEmValue
        this.ascenderValue = ascenderValue
        this.descenderValue = descenderValue
        this.glyphCount = glyphCount
        this.longLoca = longLoca
        this.hmtxOffset = hmtxOffset
        this.hmtxLength = hmtxLength
        this.numberOfHMetrics = numberOfHMetrics
        this.locaOffset = locaOffset
        this.glyfOffset = glyfOffset
        this.glyfLength = glyfLength
        this.cmapFormat = cmapFormat
        this.cmapSegments = cmapSegments
        this.cmapGroups = cmapGroups
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

        let unitsPerEm = readTtfU16(bytes, head.offset + 18)
        if (unitsPerEm <= 0) {
            throw SvgException("head.unitsPerEm 非法", kind: SvgErrorKind.Syntax)
        }
        let locaFormat = readTtfI16(bytes, head.offset + 50)
        if (locaFormat != 0 && locaFormat != 1) {
            throw SvgException("head.indexToLocFormat 非法", kind: SvgErrorKind.Syntax)
        }
        let glyphCount = readTtfU16(bytes, maxp.offset + 4)
        let ascender = readTtfI16(bytes, hhea.offset + 4)
        let descender = readTtfI16(bytes, hhea.offset + 6)
        let numberOfHMetrics = readTtfU16(bytes, hhea.offset + 34)
        if (numberOfHMetrics <= 0 || numberOfHMetrics > glyphCount) {
            throw SvgException("hhea.numberOfHMetrics 非法", kind: SvgErrorKind.Syntax)
        }
        if (hmtx.offset + numberOfHMetrics * 4 > hmtx.offset + hmtx.length) {
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
                readTtfU32(bytes, loca.offset + index * 4)
            } else {
                readTtfU16(bytes, loca.offset + index * 2) * 2
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
        let format = SvgTrueTypeFont.parseCmap(bytes, cmap, segments, groups)
        SvgTrueTypeFont(
            bytes,
            unitsPerEm,
            ascender,
            descender,
            glyphCount,
            longLoca,
            hmtx.offset,
            hmtx.length,
            numberOfHMetrics,
            loca.offset,
            glyf.offset,
            glyf.length,
            format,
            segments,
            groups
        )
    }

    public static func load(path: Path): SvgTrueTypeFont {
        let bytes = try {
            File.readFrom(path)
        } catch (_: FSException) {
            throw SvgException("无法读取字体文件 ${path}", kind: SvgErrorKind.Syntax)
        }
        parse(bytes)
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        let gid = match (this.glyphIndex(codePoint)) {
            case Some(value) => value
            case None => return 0.0
        }
        let metricIndex = if (gid < this.numberOfHMetrics) { gid } else { this.numberOfHMetrics - 1 }
        let advance = readTtfU16(this.data, this.hmtxOffset + metricIndex * 4)
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
            let glyph = readTtfU16(this.data, address)
            return Some(positiveTtfMod(glyph + segment.idDelta, 65536))
        }
        None
    }

    private func locaAt(index: Int64): Int64 {
        if (this.longLoca) {
            readTtfU32(this.data, this.locaOffset + index * 4)
        } else {
            readTtfU16(this.data, this.locaOffset + index * 2) * 2
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
        if (start < 0 || end > this.glyfLength || start > end) {
            throw SvgException("glyf 数据截断", kind: SvgErrorKind.Syntax)
        }
        let offset = this.glyfOffset + start
        let contours = readTtfI16(this.data, offset)
        if (contours >= 0) {
            return this.parseSimpleGlyph(offset, contours)
        }
        if (contours == -1) {
            return this.parseCompositeGlyph(offset, depth)
        }
        throw SvgException("字形 numberOfContours 非法", kind: SvgErrorKind.Syntax)
    }

    private func parseSimpleGlyph(offset: Int64, numberOfContours: Int64): Array<SvgPathCommand> {
        if (numberOfContours == 0) {
            return Array<SvgPathCommand>()
        }
        let endPoints = Array<Int64>(numberOfContours, repeat: 0)
        var contourIndex: Int64 = 0
        while (contourIndex < numberOfContours) {
            endPoints[contourIndex] = readTtfU16(this.data, offset + 10 + contourIndex * 2)
            contourIndex++
        }
        let pointCount = endPoints[numberOfContours - 1] + 1
        if (pointCount > SVG_TTF_MAX_POINTS) {
            throw SvgException(
                "字形点数 ${pointCount} 超过上限 ${SVG_TTF_MAX_POINTS}",
                kind: SvgErrorKind.Limit
            )
        }
        var cursor = offset + 10 + numberOfContours * 2
        let instructionLength = readTtfU16(this.data, cursor)
        cursor += 2 + instructionLength

        let flags = Array<Int64>(pointCount, repeat: 0)
        var flagIndex: Int64 = 0
        while (flagIndex < pointCount) {
            let flag = readTtfU8(this.data, cursor)
            cursor++
            flags[flagIndex] = flag
            flagIndex++
            if ((flag & 0x08) != 0) {
                var repeat = readTtfU8(this.data, cursor)
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
                delta = readTtfU8(this.data, cursor)
                cursor++
                if ((flag & 0x10) == 0) {
                    delta = -delta
                }
            } else if ((flag & 0x10) != 0) {
                delta = 0
            } else {
                delta = readTtfI16(this.data, cursor)
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
                delta = readTtfU8(this.data, cursor)
                cursor++
                if ((flag & 0x20) == 0) {
                    delta = -delta
                }
            } else if ((flag & 0x20) != 0) {
                delta = 0
            } else {
                delta = readTtfI16(this.data, cursor)
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

    private func parseCompositeGlyph(offset: Int64, depth: Int64): Array<SvgPathCommand> {
        let commands = ArrayList<SvgPathCommand>()
        var cursor = offset + 10
        var more = true
        var flags: Int64 = 0
        while (more) {
            flags = readTtfU16(this.data, cursor)
            let component = readTtfU16(this.data, cursor + 2)
            cursor += 4
            var argument1: Int64
            var argument2: Int64
            if ((flags & 0x0001) != 0) {
                argument1 = readTtfI16(this.data, cursor)
                argument2 = readTtfI16(this.data, cursor + 2)
                cursor += 4
            } else {
                argument1 = readTtfSignedByte(this.data, cursor)
                argument2 = readTtfSignedByte(this.data, cursor + 1)
                cursor += 2
            }
            let dx = if ((flags & 0x0002) != 0) { argument1 } else { 0 }
            let dy = if ((flags & 0x0002) != 0) { argument2 } else { 0 }
            var a = 1.0
            var b = 0.0
            var c = 0.0
            var d = 1.0
            if ((flags & 0x0008) != 0) {
                let scale = Float64(readTtfI16(this.data, cursor)) / 16384.0
                a = scale
                d = scale
                cursor += 2
            } else if ((flags & 0x0040) != 0) {
                a = Float64(readTtfI16(this.data, cursor)) / 16384.0
                d = Float64(readTtfI16(this.data, cursor + 2)) / 16384.0
                cursor += 4
            } else if ((flags & 0x0080) != 0) {
                a = Float64(readTtfI16(this.data, cursor)) / 16384.0
                b = Float64(readTtfI16(this.data, cursor + 2)) / 16384.0
                c = Float64(readTtfI16(this.data, cursor + 4)) / 16384.0
                d = Float64(readTtfI16(this.data, cursor + 6)) / 16384.0
                cursor += 8
            }
            let child = this.parseGlyph(component, depth + 1)
            for (command in child) {
                commands.add(transformTtfCommand(command, a, b, c, d, Float64(dx), Float64(dy)))
            }
            more = (flags & 0x0020) != 0
        }
        if ((flags & 0x0100) != 0) {
            let instructionLength = readTtfU16(this.data, cursor)
            cursor += 2 + instructionLength
        }
        commands.toArray()
    }

    private static func parseCmap(
        bytes: Array<Byte>,
        cmap: SvgTtfTable,
        segments: ArrayList<SvgCmapSegment>,
        groups: ArrayList<SvgCmapGroup>
    ): Int64 {
        if (cmap.length < 4) {
            throw SvgException("cmap 表截断", kind: SvgErrorKind.Syntax)
        }
        let count = readTtfU16(bytes, cmap.offset + 2)
        var chosenFormat: Int64 = 0
        var chosenOffset: Int64 = 0
        var index: Int64 = 0
        while (index < count) {
            let record = cmap.offset + 4 + index * 8
            let subtable = cmap.offset + readTtfU32(bytes, record + 4)
            if (subtable + 2 > cmap.offset + cmap.length) {
                throw SvgException("cmap 子表越界", kind: SvgErrorKind.Syntax)
            }
            let format = readTtfU16(bytes, subtable)
            if (format == 12) {
                chosenFormat = 12
                chosenOffset = subtable
                break
            }
            if (format == 4 && chosenFormat == 0) {
                chosenFormat = 4
                chosenOffset = subtable
            }
            index++
        }
        if (chosenFormat == 4) {
            let segCountX2 = readTtfU16(bytes, chosenOffset + 6)
            let segCount = segCountX2 / 2
            let endCodes = chosenOffset + 14
            let startCodes = endCodes + segCountX2 + 2
            let idDeltas = startCodes + segCountX2
            let idRangeOffsets = idDeltas + segCountX2
            var segmentIndex: Int64 = 0
            while (segmentIndex < segCount) {
                segments.add(
                    SvgCmapSegment(
                        readTtfU16(bytes, endCodes + segmentIndex * 2),
                        readTtfU16(bytes, startCodes + segmentIndex * 2),
                        readTtfI16(bytes, idDeltas + segmentIndex * 2),
                        readTtfU16(bytes, idRangeOffsets + segmentIndex * 2),
                        idRangeOffsets + segmentIndex * 2
                    )
                )
                segmentIndex++
            }
        } else if (chosenFormat == 12) {
            let groupCount = readTtfU32(bytes, chosenOffset + 12)
            var groupIndex: Int64 = 0
            while (groupIndex < groupCount) {
                let base = chosenOffset + 16 + groupIndex * 12
                groups.add(
                    SvgCmapGroup(
                        readTtfU32(bytes, base),
                        readTtfU32(bytes, base + 4),
                        readTtfU32(bytes, base + 8)
                    )
                )
                groupIndex++
            }
        } else {
            throw SvgException("cmap 缺少支持的 format 4 / 12", kind: SvgErrorKind.Syntax)
        }
        chosenFormat
    }
}

private func readTtfSignedByte(bytes: Array<Byte>, offset: Int64): Int64 {
    let value = readTtfU8(bytes, offset)
    if (value >= 128) {
        value - 256
    } else {
        value
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
