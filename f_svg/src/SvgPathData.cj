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
import fountain::f_base.*

/** 路径命令种类。 */
public enum SvgPathCommandKind <: Equatable<SvgPathCommandKind> & ToString {
    | MoveTo
    | LineTo
    | HorizontalLineTo
    | VerticalLineTo
    | CurveTo
    | SmoothCurveTo
    | QuadraticBezierTo
    | SmoothQuadraticBezierTo
    | ArcTo
    | ClosePath

    public operator func ==(that: SvgPathCommandKind): Bool {
        match ((this, that)) {
            case (MoveTo, MoveTo) => true
            case (LineTo, LineTo) => true
            case (HorizontalLineTo, HorizontalLineTo) => true
            case (VerticalLineTo, VerticalLineTo) => true
            case (CurveTo, CurveTo) => true
            case (SmoothCurveTo, SmoothCurveTo) => true
            case (QuadraticBezierTo, QuadraticBezierTo) => true
            case (SmoothQuadraticBezierTo, SmoothQuadraticBezierTo) => true
            case (ArcTo, ArcTo) => true
            case (ClosePath, ClosePath) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case MoveTo => "MoveTo"
            case LineTo => "LineTo"
            case HorizontalLineTo => "HorizontalLineTo"
            case VerticalLineTo => "VerticalLineTo"
            case CurveTo => "CurveTo"
            case SmoothCurveTo => "SmoothCurveTo"
            case QuadraticBezierTo => "QuadraticBezierTo"
            case SmoothQuadraticBezierTo => "SmoothQuadraticBezierTo"
            case ArcTo => "ArcTo"
            case ClosePath => "ClosePath"
        }
    }

    internal func letter(): Byte {
        match (this) {
            case MoveTo => b'M'
            case LineTo => b'L'
            case HorizontalLineTo => b'H'
            case VerticalLineTo => b'V'
            case CurveTo => b'C'
            case SmoothCurveTo => b'S'
            case QuadraticBezierTo => b'Q'
            case SmoothQuadraticBezierTo => b'T'
            case ArcTo => b'A'
            case ClosePath => b'Z'
        }
    }

    internal func arity(): Int64 {
        match (this) {
            case MoveTo => 2
            case LineTo => 2
            case HorizontalLineTo => 1
            case VerticalLineTo => 1
            case CurveTo => 6
            case SmoothCurveTo => 4
            case QuadraticBezierTo => 4
            case SmoothQuadraticBezierTo => 2
            case ArcTo => 7
            case ClosePath => 0
        }
    }
}

/** 一条路径命令。`values` 保留原始书写形式（相对命令仍是相对值）。 */
public struct SvgPathCommand <: Equatable<SvgPathCommand> & ToString {
    public let kind: SvgPathCommandKind
    public let relative: Bool
    public let values: Array<Float64>

    public init(kind: SvgPathCommandKind, relative: Bool, values: Array<Float64>) {
        this.kind = kind
        this.relative = relative
        this.values = values
    }

    public func toString(): String {
        var text = commandLetter(this.kind, this.relative).toString()
        for (value in this.values) {
            text += " " + formatSvgNumber(value)
        }
        text
    }

    public operator func ==(that: SvgPathCommand): Bool {
        this.kind == that.kind && this.relative == that.relative && this.values == that.values
    }
}

/** 弧命令的语义化参数。 */
public struct SvgArcParams {
    public let rx: Float64
    public let ry: Float64
    public let xAxisRotation: Float64
    public let largeArc: Bool
    public let sweep: Bool
    public let x: Float64
    public let y: Float64

    public init(
        rx: Float64,
        ry: Float64,
        xAxisRotation: Float64,
        largeArc: Bool,
        sweep: Bool,
        x: Float64,
        y: Float64
    ) {
        this.rx = rx
        this.ry = ry
        this.xAxisRotation = xAxisRotation
        this.largeArc = largeArc
        this.sweep = sweep
        this.x = x
        this.y = y
    }
}

private func commandLetter(kind: SvgPathCommandKind, relative: Bool): Rune {
    let letter = kind.letter()
    let shifted = if (relative) {
        UInt32(letter) + 32
    } else {
        UInt32(letter)
    }
    Rune(shifted)
}

/** SVG 路径数据：命令列表 + 解析 / 绝对化 / 规范序列化。 */
public class SvgPathData <: ToString {
    public let commands: Array<SvgPathCommand>

    public init(commands: Array<SvgPathCommand>) {
        this.commands = commands
    }

    public static func parse(text: String): SvgPathData {
        SvgPathData(SvgPathScanner(text).parse())
    }

    public static func tryParse(text: String): ?SvgPathData {
        try {
            Some(SvgPathData.parse(text))
        } catch (_: SvgException) {
            None
        }
    }

    /** 全部转成绝对命令；`H/V` 转 `L`，`A` 只转终点。 */
    public func toAbsolute(): SvgPathData {
        let result = ArrayList<SvgPathCommand>()
        var currentX = 0.0
        var currentY = 0.0
        var startX = 0.0
        var startY = 0.0
        for (command in this.commands) {
            match (command.kind) {
                case MoveTo =>
                    let x = if (command.relative) {
                        currentX + command.values[0]
                    } else {
                        command.values[0]
                    }
                    let y = if (command.relative) {
                        currentY + command.values[1]
                    } else {
                        command.values[1]
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.MoveTo, false, [x, y]))
                    currentX = x
                    currentY = y
                    startX = x
                    startY = y
                case LineTo =>
                    let x = if (command.relative) {
                        currentX + command.values[0]
                    } else {
                        command.values[0]
                    }
                    let y = if (command.relative) {
                        currentY + command.values[1]
                    } else {
                        command.values[1]
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [x, y]))
                    currentX = x
                    currentY = y
                case HorizontalLineTo =>
                    let x = if (command.relative) {
                        currentX + command.values[0]
                    } else {
                        command.values[0]
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [x, currentY]))
                    currentX = x
                case VerticalLineTo =>
                    let y = if (command.relative) {
                        currentY + command.values[0]
                    } else {
                        command.values[0]
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [currentX, y]))
                    currentY = y
                case CurveTo =>
                    let values = if (command.relative) {
                        absolutePairs(command.values, 6, currentX, currentY)
                    } else {
                        command.values
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.CurveTo, false, values))
                    currentX = values[4]
                    currentY = values[5]
                case SmoothCurveTo =>
                    let values = if (command.relative) {
                        absolutePairs(command.values, 4, currentX, currentY)
                    } else {
                        command.values
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.SmoothCurveTo, false, values))
                    currentX = values[2]
                    currentY = values[3]
                case QuadraticBezierTo =>
                    let values = if (command.relative) {
                        absolutePairs(command.values, 4, currentX, currentY)
                    } else {
                        command.values
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.QuadraticBezierTo, false, values))
                    currentX = values[2]
                    currentY = values[3]
                case SmoothQuadraticBezierTo =>
                    let values = if (command.relative) {
                        absolutePairs(command.values, 2, currentX, currentY)
                    } else {
                        command.values
                    }
                    result.add(SvgPathCommand(SvgPathCommandKind.SmoothQuadraticBezierTo, false, values))
                    currentX = values[0]
                    currentY = values[1]
                case ArcTo =>
                    let arcValues = ArrayList<Float64>()
                    for (index in 0..5) {
                        arcValues.add(command.values[index])
                    }
                    if (command.relative) {
                        arcValues.add(currentX + command.values[5])
                        arcValues.add(currentY + command.values[6])
                    } else {
                        arcValues.add(command.values[5])
                        arcValues.add(command.values[6])
                    }
                    let values = arcValues.toArray()
                    result.add(SvgPathCommand(SvgPathCommandKind.ArcTo, false, values))
                    currentX = values[5]
                    currentY = values[6]
                case ClosePath =>
                    result.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
                    currentX = startX
                    currentY = startY
            }
        }
        SvgPathData(result.toArray())
    }

    public func toString(): String {
        let out = StringBuilder()
        for (index in 0..this.commands.size) {
            if (index > 0) {
                out.append(" ")
            }
            out.append(this.commands[index].toString())
        }
        out.toString()
    }

    public operator func ==(that: SvgPathData): Bool {
        this.commands == that.commands
    }
}

private func absolutePairs(
    values: Array<Float64>,
    count: Int64,
    currentX: Float64,
    currentY: Float64
): Array<Float64> {
    let result = ArrayList<Float64>()
    var index = 0
    while (index < count) {
        result.add(currentX + values[index])
        result.add(currentY + values[index + 1])
        index += 2
    }
    result.toArray()
}

/**
 * 路径词法扫描器：单遍、带位置。
 *
 * 逗号最多一个且不能出现在命令字母前；数字之间允许只有符号分隔。
 */
private class SvgPathScanner {
    private let text: String
    private let bytes: Array<Byte>
    private var pos: Int64

    init(text: String) {
        this.text = text
        this.bytes = text.unsafeBytes()
        this.pos = 0
    }

    func parse(): Array<SvgPathCommand> {
        let commands = ArrayList<SvgPathCommand>()
        while (true) {
            this.pos = skipSvgSpaces(this.bytes, this.pos)
            if (this.pos >= this.bytes.size) {
                break
            }
            let letter = this.bytes[this.pos]
            let kind = pathKind(letter)
            let relative = letter >= b'a' && letter <= b'z'
            this.pos++
            if (kind == SvgPathCommandKind.ClosePath) {
                commands.add(SvgPathCommand(kind, relative, Array<Float64>()))
                let after = skipSvgSpaces(this.bytes, this.pos)
                if (after < this.bytes.size && (this.bytes[after] == b',' || isNumberStart(this.bytes[after]))) {
                    throw invalidValue("Z 命令后不允许直接跟数字")
                }
                this.pos = after
                continue
            }
            let first = if (kind == SvgPathCommandKind.ArcTo) {
                readArcGroup()
            } else {
                readGroup(kind.arity())
            }
            commands.add(SvgPathCommand(kind, relative, first))
            let repeatKind = if (kind == SvgPathCommandKind.MoveTo) {
                SvgPathCommandKind.LineTo
            } else {
                kind
            }
            while (true) {
                var after = skipSvgSpaces(this.bytes, this.pos)
                var sawComma = false
                if (after < this.bytes.size && this.bytes[after] == b',') {
                    sawComma = true
                    after = skipSvgSpaces(this.bytes, after + 1)
                    if (after >= this.bytes.size || this.bytes[after] == b',') {
                        throw invalidValue("路径出现多余的逗号")
                    }
                }
                if (after < this.bytes.size && isNumberStart(this.bytes[after])) {
                    this.pos = after
                    let more = if (repeatKind == SvgPathCommandKind.ArcTo) {
                        readArcGroup()
                    } else {
                        readGroup(repeatKind.arity())
                    }
                    commands.add(SvgPathCommand(repeatKind, relative, more))
                } else {
                    if (sawComma) {
                        throw invalidValue("路径出现多余的逗号")
                    }
                    this.pos = after
                    break
                }
            }
        }
        commands.toArray()
    }

    private func readGroup(arity: Int64): Array<Float64> {
        let values = ArrayList<Float64>()
        for (index in 0..arity) {
            if (index > 0) {
                consumeSeparator()
            } else {
                this.pos = skipSvgSpaces(this.bytes, this.pos)
            }
            values.add(readNumber())
        }
        values.toArray()
    }

    private func readArcGroup(): Array<Float64> {
        this.pos = skipSvgSpaces(this.bytes, this.pos)
        let values = ArrayList<Float64>()
        values.add(readNumber())
        consumeSeparator()
        values.add(readNumber())
        consumeSeparator()
        values.add(readNumber())
        consumeSeparator()
        values.add(readFlag())
        consumeSeparator()
        values.add(readFlag())
        consumeSeparator()
        values.add(readNumber())
        consumeSeparator()
        values.add(readNumber())
        values.toArray()
    }

    private func consumeSeparator(): Unit {
        this.pos = skipSvgSpaces(this.bytes, this.pos)
        if (this.pos < this.bytes.size && this.bytes[this.pos] == b',') {
            this.pos = skipSvgSpaces(this.bytes, this.pos + 1)
            if (this.pos >= this.bytes.size || this.bytes[this.pos] == b',') {
                throw invalidValue("路径出现多余的逗号")
            }
        }
    }

    private func readNumber(): Float64 {
        this.pos = skipSvgSpaces(this.bytes, this.pos)
        match (scanSvgNumber(this.text, this.pos)) {
            case Some(token) =>
                this.pos = token.end
                requireFinite(token.value, "路径坐标")
            case None => throw invalidValue("路径坐标不是合法数字")
        }
    }

    private func readFlag(): Float64 {
        this.pos = skipSvgSpaces(this.bytes, this.pos)
        if (this.pos >= this.bytes.size) {
            throw invalidValue("弧命令缺少标志位")
        }
        let byte = this.bytes[this.pos]
        if (byte == b'0') {
            this.pos++
            return 0.0
        }
        if (byte == b'1') {
            this.pos++
            return 1.0
        }
        throw invalidValue("弧标志位只能是 0 或 1")
    }
}

private func pathKind(letter: Byte): SvgPathCommandKind {
    match (letter) {
        case b'M' | b'm' => SvgPathCommandKind.MoveTo
        case b'L' | b'l' => SvgPathCommandKind.LineTo
        case b'H' | b'h' => SvgPathCommandKind.HorizontalLineTo
        case b'V' | b'v' => SvgPathCommandKind.VerticalLineTo
        case b'C' | b'c' => SvgPathCommandKind.CurveTo
        case b'S' | b's' => SvgPathCommandKind.SmoothCurveTo
        case b'Q' | b'q' => SvgPathCommandKind.QuadraticBezierTo
        case b'T' | b't' => SvgPathCommandKind.SmoothQuadraticBezierTo
        case b'A' | b'a' => SvgPathCommandKind.ArcTo
        case b'Z' | b'z' => SvgPathCommandKind.ClosePath
        case _ => throw invalidValue("路径中出现未知命令「${letter}」")
    }
}
