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

private let HERSHEY_GLYPHS: HashMap<Int64, String> = buildHersheyGlyphs()

/**
 * 内置单线字体（Hershey 风格）。
 *
 * 字形在 4×6 网格上以折线描述，`glyphPath` 按字号线性缩放；
 * 覆盖 ASCII 32–126，空格返回空路径，非 ASCII 返回 `None`。
 */
public class SvgHersheyFont <: SvgFont {
    private static let GLYPH_UNITS = 6.0
    private static let ADVANCE_UNITS = 5.0

    public init() {}

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        if (fontSize <= 0.0) {
            return None
        }
        if (codePoint == 32) {
            return Some(SvgPathData(Array<SvgPathCommand>()))
        }
        let encoded = match (HERSHEY_GLYPHS.get(codePoint)) {
            case Some(value) => value
            case None => return None
        }
        let scale = fontSize / (SvgHersheyFont.GLYPH_UNITS + 1.0)
        let commands = ArrayList<SvgPathCommand>()
        for (stroke in splitHersheyStrokes(encoded)) {
            let points = parseHersheyPoints(stroke)
            if (points.size == 0) {
                continue
            }
            commands.add(
                SvgPathCommand(
                    SvgPathCommandKind.MoveTo,
                    false,
                    [points[0].x * scale, points[0].y * scale]
                )
            )
            for (index in 1..points.size) {
                commands.add(
                    SvgPathCommand(
                        SvgPathCommandKind.LineTo,
                        false,
                        [points[index].x * scale, points[index].y * scale]
                    )
                )
            }
        }
        if (commands.size == 0) {
            return None
        }
        Some(SvgPathData(commands.toArray()))
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        if (codePoint == 32) {
            return fontSize * 0.35
        }
        fontSize * SvgHersheyFont.ADVANCE_UNITS / (SvgHersheyFont.GLYPH_UNITS + 1.0)
    }

    public func ascent(fontSize: Float64): Float64 {
        fontSize
    }

    public func descent(fontSize: Float64): Float64 {
        fontSize / (SvgHersheyFont.GLYPH_UNITS + 1.0)
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        match (this.glyphPath(codePoint, fontSize)) {
            case Some(path) => pathDataBounds(path)
            case None => None
        }
    }
}

private func splitHersheyStrokes(encoded: String): ArrayList<String> {
    let result = ArrayList<String>()
    let bytes = encoded.unsafeBytes()
    var start = 0
    var index = 0
    while (index < bytes.size) {
        if (bytes[index] == b';') {
            let part = encoded[start..index].trimAscii()
            if (part.size > 0) {
                result.add(part)
            }
            start = index + 1
        }
        index++
    }
    let tail = encoded[start..bytes.size].trimAscii()
    if (tail.size > 0) {
        result.add(tail)
    }
    result
}

private func parseHersheyPoints(stroke: String): ArrayList<SvgPoint> {
    let points = ArrayList<SvgPoint>()
    let bytes = stroke.unsafeBytes()
    var index = 0
    while (index < bytes.size) {
        while (index < bytes.size && isCssSpace(bytes[index])) {
            index++
        }
        let start = index
        while (index < bytes.size && !isCssSpace(bytes[index])) {
            index++
        }
        if (index == start) {
            continue
        }
        let token = stroke[start..index]
        match (parseHersheyPoint(token)) {
            case Some(point) => points.add(point)
            case None => ()
        }
    }
    points
}

private func parseHersheyPoint(token: String): ?SvgPoint {
    let bytes = token.unsafeBytes()
    var comma = -1
    for (index in 0..bytes.size) {
        if (bytes[index] == b',') {
            comma = index
            break
        }
    }
    if (comma <= 0) {
        return None
    }
    match ((tryParseSvgFloat(token[0..comma]), tryParseSvgFloat(token[comma + 1..bytes.size]))) {
        case (Some(x), Some(y)) => Some(SvgPoint(x, y))
        case _ => None
    }
}

private func buildHersheyGlyphs(): HashMap<Int64, String> {
    let glyphs = HashMap<Int64, String>()
    glyphs[33] = "2,-6 2,-2;2,0 2,-0.2"
    glyphs[34] = "1,-6 1,-4;3,-6 3,-4"
    glyphs[35] = "1,-6 1,0;3,-6 3,0;0,-4 4,-4;0,-2 4,-2"
    glyphs[36] = "4,-5 3,-6 1,-6 0,-5 0,-4 1,-3 3,-3 4,-2 4,-1 3,0 1,0 0,-1;2,-6 2,0"
    glyphs[37] = "0,0 4,-6;0,-6 1,-5 1,-4 0,-3 0,-6;3,-1 4,0 4,1 3,2 2,1 2,0 3,-1"
    glyphs[38] = "4,0 1,-3 1,-5 2,-6 3,-5 2,-3 0,-1 0,-4 1,-6 3,-4 3,-2 4,0"
    glyphs[39] = "2,-6 2,-4"
    glyphs[40] = "3,-6 1,-4 1,-2 3,0"
    glyphs[41] = "1,-6 3,-4 3,-2 1,0"
    glyphs[42] = "1,-4 3,-2;3,-4 1,-2;2,-5 2,-1"
    glyphs[43] = "1,-3 3,-3;2,-4 2,-2"
    glyphs[44] = "2,0 1,1"
    glyphs[45] = "1,-3 3,-3"
    glyphs[46] = "1,0 2,0"
    glyphs[47] = "0,0 4,-6"
    glyphs[48] = "1,0 0,-1 0,-5 1,-6 3,-6 4,-5 4,-1 3,0 1,0"
    glyphs[49] = "1,-5 2,-6 2,0;1,0 3,0"
    glyphs[50] = "0,-5 1,-6 3,-6 4,-5 4,-4 0,0 4,0"
    glyphs[51] = "0,-6 4,-6 2,-3 3,-3 4,-2 4,-1 3,0 1,0 0,-1"
    glyphs[52] = "3,0 3,-6 0,-2 4,-2"
    glyphs[53] = "4,-6 0,-6 0,-3 3,-3 4,-2 4,-1 3,0 1,0 0,-1"
    glyphs[54] = "4,-6 1,-6 0,-5 0,-1 1,0 3,0 4,-1 4,-2 3,-3 0,-3"
    glyphs[55] = "0,-6 4,-6 1,0"
    glyphs[56] = "1,-3 0,-4 0,-5 1,-6 3,-6 4,-5 4,-4 3,-3 1,-3 0,-2 0,-1 1,0 3,0 4,-1 4,-2 3,-3"
    glyphs[57] = "0,0 3,0 4,-1 4,-5 3,-6 1,-6 0,-5 0,-4 1,-3 4,-3"
    glyphs[58] = "2,-2 2,-3;2,0 2,-1"
    glyphs[59] = "2,-2 2,-3;2,0 1,1"
    glyphs[60] = "4,-5 0,-3 4,-1"
    glyphs[61] = "1,-4 3,-4;1,-2 3,-2"
    glyphs[62] = "0,-5 4,-3 0,-1"
    glyphs[63] = "0,-5 1,-6 3,-6 4,-5 4,-4 2,-2 2,-1;2,0 2,-0.2"
    glyphs[64] = "3,-2 2,-2 2,-4 3,-4 3,-2;4,-5 1,-6 0,-4 0,-2 1,0 3,0 4,-1"
    glyphs[65] = "0,0 2,-6 4,0;0.5,-2 3.5,-2"
    glyphs[66] = "0,0 0,-6 3,-6 4,-5 4,-4 3,-3 0,-3;3,-3 4,-2 4,-1 3,0 0,0"
    glyphs[67] = "4,0 1,0 0,-1 0,-5 1,-6 4,-6"
    glyphs[68] = "0,0 0,-6 3,-6 4,-5 4,-1 3,0 0,0"
    glyphs[69] = "4,-6 0,-6 0,0 4,0;0,-3 3,-3"
    glyphs[70] = "4,-6 0,-6 0,0;0,-3 3,-3"
    glyphs[71] = "4,-6 1,-6 0,-5 0,-1 1,0 4,0 4,-3 2,-3"
    glyphs[72] = "0,0 0,-6;4,0 4,-6;0,-3 4,-3"
    glyphs[73] = "0,0 4,0;2,0 2,-6;0,-6 4,-6"
    glyphs[74] = "4,0 1,0 0,-1 0,-2;4,0 4,-6"
    glyphs[75] = "0,0 0,-6;4,-6 0,-3;1.5,-4 4,0"
    glyphs[76] = "0,-6 0,0 4,0"
    glyphs[77] = "0,0 0,-6 2,-3 4,-6 4,0"
    glyphs[78] = "0,0 0,-6 4,0 4,-6"
    glyphs[79] = "1,0 0,-1 0,-5 1,-6 3,-6 4,-5 4,-1 3,0 1,0"
    glyphs[80] = "0,0 0,-6 3,-6 4,-5 4,-3 3,-2 0,-2"
    glyphs[81] = "1,0 0,-1 0,-5 1,-6 3,-6 4,-5 4,-1 3,0 1,0;2,-2 4,0"
    glyphs[82] = "0,0 0,-6 3,-6 4,-5 4,-3 3,-2 0,-2;2,-2 4,0"
    glyphs[83] = "4,-6 1,-6 0,-5 0,-4 1,-3 3,-3 4,-2 4,-1 3,0 0,0"
    glyphs[84] = "0,-6 4,-6;2,-6 2,0"
    glyphs[85] = "0,-6 0,-1 1,0 3,0 4,-1 4,-6"
    glyphs[86] = "0,-6 2,0 4,-6"
    glyphs[87] = "0,-6 1,0 2,-4 3,0 4,-6"
    glyphs[88] = "0,-6 4,0;4,-6 0,0"
    glyphs[89] = "0,-6 2,-3 4,-6;2,-3 2,0"
    glyphs[90] = "0,-6 4,-6 0,0 4,0"
    glyphs[91] = "3,-6 1,-6 1,0 3,0"
    glyphs[92] = "0,-6 4,0"
    glyphs[93] = "1,-6 3,-6 3,0 1,0"
    glyphs[94] = "1,-4 2,-6 3,-4"
    glyphs[95] = "0,0 4,0"
    glyphs[96] = "1,-6 2,-5"
    glyphs[123] = "3,-6 2,-5 2,-4 1,-3 2,-2 2,-1 3,0"
    glyphs[124] = "2,-6 2,0"
    glyphs[125] = "1,-6 2,-5 2,-4 3,-3 2,-2 2,-1 1,0"
    glyphs[126] = "0,-3 1,-4 3,-2 4,-3"

    // 小写字母复用大写字形，保证 ASCII 全覆盖。
    for (codePoint in 97..=122) {
        glyphs[codePoint] = glyphs.get(codePoint - 32) ?? "0,0 4,0 4,-6 0,-6 0,0"
    }
    // 未显式定义的可见字符使用占位方框。
    for (codePoint in 33..=126) {
        if (glyphs.get(codePoint).isNone()) {
            glyphs[codePoint] = "0,0 4,0 4,-6 0,-6 0,0"
        }
    }
    glyphs
}
