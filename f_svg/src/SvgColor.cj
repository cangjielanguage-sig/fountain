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
import std.math.*
import std.convert.*
import fountain::f_base.*

private let SVG_COLOR_NAMES: Array<(String, Int64)> = [
    ("aliceblue", 0xF0F8FF), ("antiquewhite", 0xFAEBD7), ("aqua", 0x00FFFF), ("aquamarine", 0x7FFFD4),
    ("azure", 0xF0FFFF), ("beige", 0xF5F5DC), ("bisque", 0xFFE4C4), ("black", 0x000000),
    ("blanchedalmond", 0xFFEBCD), ("blue", 0x0000FF), ("blueviolet", 0x8A2BE2), ("brown", 0xA52A2A),
    ("burlywood", 0xDEB887), ("cadetblue", 0x5F9EA0), ("chartreuse", 0x7FFF00), ("chocolate", 0xD2691E),
    ("coral", 0xFF7F50), ("cornflowerblue", 0x6495ED), ("cornsilk", 0xFFF8DC), ("crimson", 0xDC143C),
    ("cyan", 0x00FFFF), ("darkblue", 0x00008B), ("darkcyan", 0x008B8B), ("darkgoldenrod", 0xB8860B),
    ("darkgray", 0xA9A9A9), ("darkgreen", 0x006400), ("darkgrey", 0xA9A9A9), ("darkkhaki", 0xBDB76B),
    ("darkmagenta", 0x8B008B), ("darkolivegreen", 0x556B2F), ("darkorange", 0xFF8C00),
    ("darkorchid", 0x9932CC), ("darkred", 0x8B0000), ("darksalmon", 0xE9967A), ("darkseagreen", 0x8FBC8F),
    ("darkslateblue", 0x483D8B), ("darkslategray", 0x2F4F4F), ("darkslategrey", 0x2F4F4F),
    ("darkturquoise", 0x00CED1), ("darkviolet", 0x9400D3), ("deeppink", 0xFF1493), ("deepskyblue", 0x00BFFF),
    ("dimgray", 0x696969), ("dimgrey", 0x696969), ("dodgerblue", 0x1E90FF), ("firebrick", 0xB22222),
    ("floralwhite", 0xFFFAF0), ("forestgreen", 0x228B22), ("fuchsia", 0xFF00FF), ("gainsboro", 0xDCDCDC),
    ("ghostwhite", 0xF8F8FF), ("gold", 0xFFD700), ("goldenrod", 0xDAA520), ("gray", 0x808080),
    ("green", 0x008000), ("greenyellow", 0xADFF2F), ("grey", 0x808080), ("honeydew", 0xF0FFF0),
    ("hotpink", 0xFF69B4), ("indianred", 0xCD5C5C), ("indigo", 0x4B0082), ("ivory", 0xFFFFF0),
    ("khaki", 0xF0E68C), ("lavender", 0xE6E6FA), ("lavenderblush", 0xFFF0F5), ("lawngreen", 0x7CFC00),
    ("lemonchiffon", 0xFFFACD), ("lightblue", 0xADD8E6), ("lightcoral", 0xF08080), ("lightcyan", 0xE0FFFF),
    ("lightgoldenrodyellow", 0xFAFAD2), ("lightgray", 0xD3D3D3), ("lightgreen", 0x90EE90),
    ("lightgrey", 0xD3D3D3), ("lightpink", 0xFFB6C1), ("lightsalmon", 0xFFA07A), ("lightseagreen", 0x20B2AA),
    ("lightskyblue", 0x87CEFA), ("lightslategray", 0x778899), ("lightslategrey", 0x778899),
    ("lightsteelblue", 0xB0C4DE), ("lightyellow", 0xFFFFE0), ("lime", 0x00FF00), ("limegreen", 0x32CD32),
    ("linen", 0xFAF0E6), ("magenta", 0xFF00FF), ("maroon", 0x800000), ("mediumaquamarine", 0x66CDAA),
    ("mediumblue", 0x0000CD), ("mediumorchid", 0xBA55D3), ("mediumpurple", 0x9370DB),
    ("mediumseagreen", 0x3CB371), ("mediumslateblue", 0x7B68EE), ("mediumspringgreen", 0x00FA9A),
    ("mediumturquoise", 0x48D1CC), ("mediumvioletred", 0xC71585), ("midnightblue", 0x191970),
    ("mintcream", 0xF5FFFA), ("mistyrose", 0xFFE4E1), ("moccasin", 0xFFE4B5), ("navajowhite", 0xFFDEAD),
    ("navy", 0x000080), ("oldlace", 0xFDF5E6), ("olive", 0x808000), ("olivedrab", 0x6B8E23),
    ("orange", 0xFFA500), ("orangered", 0xFF4500), ("orchid", 0xDA70D6), ("palegoldenrod", 0xEEE8AA),
    ("palegreen", 0x98FB98), ("paleturquoise", 0xAFEEEE), ("palevioletred", 0xDB7093),
    ("papayawhip", 0xFFEFD5), ("peachpuff", 0xFFDAB9), ("peru", 0xCD853F), ("pink", 0xFFC0CB),
    ("plum", 0xDDA0DD), ("powderblue", 0xB0E0E6), ("purple", 0x800080), ("rebeccapurple", 0x663399),
    ("red", 0xFF0000), ("rosybrown", 0xBC8F8F), ("royalblue", 0x4169E1), ("saddlebrown", 0x8B4513),
    ("salmon", 0xFA8072), ("sandybrown", 0xF4A460), ("seagreen", 0x2E8B57), ("seashell", 0xFFF5EE),
    ("sienna", 0xA0522D), ("silver", 0xC0C0C0), ("skyblue", 0x87CEEB), ("slateblue", 0x6A5ACD),
    ("slategray", 0x708090), ("slategrey", 0x708090), ("snow", 0xFFFAFA), ("springgreen", 0x00FF7F),
    ("steelblue", 0x4682B4), ("tan", 0xD2B48C), ("teal", 0x008080), ("thistle", 0xD8BFD8),
    ("tomato", 0xFF6347), ("turquoise", 0x40E0D0), ("violet", 0xEE82EE), ("wheat", 0xF5DEB3),
    ("white", 0xFFFFFF), ("whitesmoke", 0xF5F5F5), ("yellow", 0xFFFF00), ("yellowgreen", 0x9ACD32)
]


/**
 * RGBA 颜色。
 *
 * 解析接受 `#rgb` / `#rrggbb` / `#rrggbbaa`、`rgb()` / `rgba()`（逗号、空格、斜杠语法）、
 * `hsl()` / `hsla()` 与 CSS3 命名色；`none` 是画笔关键字，不是颜色，解析失败。
 */
public struct SvgColor <: Equatable<SvgColor> & ToString {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: Float64

    public static let Black = SvgColor(0, 0, 0, alpha: 1.0)
    public static let White = SvgColor(255, 255, 255, alpha: 1.0)
    public static let Transparent = SvgColor(0, 0, 0, alpha: 0.0)

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha!: Float64 = 1.0) {
        this.red = red
        this.green = green
        this.blue = blue
        this.alpha = clampAlpha(alpha)
    }

    public static func parse(text: String): SvgColor {
        let trimmed = text.trimAscii()
        if (trimmed.size == 0) {
            throw invalidValue("颜色不能为空")
        }
        if (trimmed[0] == b'#') {
            return parseHex(trimmed[1..])
        }
        let lower = trimmed.toAsciiLower()
        if (lower == "transparent") {
            return SvgColor.Transparent
        }
        let open = indexOfSvgByte(lower, b'(')
        if (open >= 0) {
            return parseFunction(lower, open)
        }
        for (entry in SVG_COLOR_NAMES) {
            let name = entry[0]
            let rgb = entry[1]
            if (name == lower) {
                return fromRgb(
                    UInt8(Int64((rgb >> 16) & 0xFF)),
                    UInt8(Int64((rgb >> 8) & 0xFF)),
                    UInt8(Int64(rgb & 0xFF))
                )
            }
        }
        throw invalidValue("未知颜色「${text}」")
    }

    public static func tryParse(text: String): ?SvgColor {
        try {
            Some(SvgColor.parse(text))
        } catch (_: SvgException) {
            None
        }
    }

    public static func fromRgb(r: UInt8, g: UInt8, b: UInt8, alpha!: Float64 = 1.0): SvgColor {
        SvgColor(r, g, b, alpha: alpha)
    }

    /** `h` 为角度，`s` / `l` / `alpha` 取 `0..1`。 */
    public static func fromHsl(h: Float64, s: Float64, l: Float64, alpha!: Float64 = 1.0): SvgColor {
        let (r, g, b) = hslToRgb(h, clampUnit(s), clampUnit(l))
        SvgColor(r, g, b, alpha: alpha)
    }

    public func toString(): String {
        if (this.alpha == 1.0) {
            return "#" + hexByte(this.red) + hexByte(this.green) + hexByte(this.blue)
        }
        let alphaByte = Int64(round(this.alpha * 255.0))
        if (alphaByte >= 0 && alphaByte <= 255 && Float64(alphaByte) / 255.0 == this.alpha) {
            return "#" + hexByte(this.red) + hexByte(this.green) + hexByte(this.blue) +
                hexByte(UInt8(alphaByte))
        }
        "rgba(${this.red},${this.green},${this.blue},${formatSvgNumber(this.alpha)})"
    }

    public operator func ==(that: SvgColor): Bool {
        this.red == that.red && this.green == that.green && this.blue == that.blue && this.alpha == that.alpha
    }

    private static func parseHex(hex: String): SvgColor {
        var digits = ArrayList<UInt8>()
        for (byte in hex.unsafeBytes()) {
            match (hexDigitValue(byte)) {
                case Some(value) => digits.add(value)
                case None => throw invalidValue("非法的十六进制颜色「#${hex}」")
            }
        }
        match (digits.size) {
            case 3 =>
                fromRgb(
                    UInt8(Int64(digits[0] * 17)),
                    UInt8(Int64(digits[1] * 17)),
                    UInt8(Int64(digits[2] * 17))
                )
            case 6 =>
                fromRgb(
                    UInt8(Int64(digits[0] * 16 + digits[1])),
                    UInt8(Int64(digits[2] * 16 + digits[3])),
                    UInt8(Int64(digits[4] * 16 + digits[5]))
                )
            case 8 =>
                fromRgb(
                    UInt8(Int64(digits[0] * 16 + digits[1])),
                    UInt8(Int64(digits[2] * 16 + digits[3])),
                    UInt8(Int64(digits[4] * 16 + digits[5])),
                    alpha: Float64(Int64(digits[6] * 16 + digits[7])) / 255.0
                )
            case _ => throw invalidValue("十六进制颜色长度必须是 3、6 或 8 位「#${hex}」")
        }
    }

    private static func parseFunction(lower: String, open: Int64): SvgColor {
        if (lower[lower.size - 1] != b')') {
            throw invalidValue("颜色函数缺少右括号「${lower}」")
        }
        let name = lower[0..open].trimAscii()
        if (name != "rgb" && name != "rgba" && name != "hsl" && name != "hsla") {
            throw invalidValue("未知颜色函数「${name}」")
        }
        let args = splitColorArgs(lower[open + 1..lower.size - 1])
        if (args.parts.size != 3) {
            throw invalidValue("颜色函数需要 3 个分量，实际 ${args.parts.size} 个")
        }
        if (name == "rgb" || name == "rgba") {
            let red = clampByte(parseRgbComponent(args.parts[0]))
            let green = clampByte(parseRgbComponent(args.parts[1]))
            let blue = clampByte(parseRgbComponent(args.parts[2]))
            let alpha = match (args.alpha) {
                case Some(text) => parseAlpha(text)
                case None => 1.0
            }
            fromRgb(red, green, blue, alpha: alpha)
        } else {
            let hue = parseHue(args.parts[0])
            let saturation = parseHslPercent(args.parts[1], "饱和度")
            let lightness = parseHslPercent(args.parts[2], "亮度")
            let alpha = match (args.alpha) {
                case Some(text) => parseAlpha(text)
                case None => 1.0
            }
            fromHsl(hue, saturation, lightness, alpha: alpha)
        }
    }
}

internal struct SvgColorArgs {
    let parts: ArrayList<String>
    let alpha: ?String

    init(parts: ArrayList<String>, alpha: ?String) {
        this.parts = parts
        this.alpha = alpha
    }
}

private func splitColorArgs(content: String): SvgColorArgs {
    let trimmed = content.trimAscii()
    if (trimmed.size == 0) {
        throw invalidValue("颜色函数的参数不能为空")
    }
    if (indexOfSvgByte(trimmed, b',') >= 0) {
        if (indexOfSvgByte(trimmed, b'/') >= 0) {
            throw invalidValue("颜色函数不能混用逗号与斜杠")
        }
        let raw = trimmed.split(",")
        let parts = ArrayList<String>()
        for (part in raw) {
            parts.add(part.trimAscii())
        }
        match (parts.size) {
            case 3 => SvgColorArgs(parts, Option<String>.None)
            case 4 =>
                let alpha = parts[3]
                parts.remove(at: 3)
                SvgColorArgs(parts, Some(alpha))
            case _ => throw invalidValue("颜色函数需要 3 个分量，实际 ${parts.size} 个")
        }
    } else {
        let slash = indexOfSvgByte(trimmed, b'/')
        var colorPart = trimmed
        var alpha: ?String = None
        if (slash >= 0) {
            colorPart = trimmed[0..slash].trimAscii()
            alpha = Some(trimmed[slash + 1..].trimAscii())
        }
        let parts = splitSvgSpaces(colorPart)
        SvgColorArgs(parts, alpha)
    }
}

internal func splitSvgSpaces(text: String): ArrayList<String> {
    let parts = ArrayList<String>()
    let bytes = text.unsafeBytes()
    var i = 0
    while (i < bytes.size) {
        while (i < bytes.size && isSvgSpace(bytes[i])) {
            i++
        }
        if (i >= bytes.size) {
            break
        }
        let start = i
        while (i < bytes.size && !isSvgSpace(bytes[i])) {
            i++
        }
        parts.add(text[start..i])
    }
    parts
}

private func parseRgbComponent(text: String): Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        throw invalidValue("颜色分量不能为空")
    }
    if (trimmed[trimmed.size - 1] == b'%') {
        let percent = parseSvgFloat(trimmed[0..trimmed.size - 1], "颜色分量")
        clampSvg(percent * 255.0 / 100.0, 0.0, 255.0)
    } else {
        let value = parseSvgFloat(trimmed, "颜色分量")
        clampSvg(value, 0.0, 255.0)
    }
}

private func parseAlpha(text: String): Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        throw invalidValue("alpha 分量不能为空")
    }
    if (trimmed[trimmed.size - 1] == b'%') {
        clampAlpha(parseSvgFloat(trimmed[0..trimmed.size - 1], "alpha") / 100.0)
    } else {
        clampAlpha(parseSvgFloat(trimmed, "alpha"))
    }
}

private func parseHue(text: String): Float64 {
    let trimmed = text.trimAscii()
    let lower = trimmed.toAsciiLower()
    if (lower.size > 3 && lower[lower.size - 3..lower.size] == "deg") {
        parseSvgFloat(lower[0..lower.size - 3], "色相")
    } else {
        parseSvgFloat(lower, "色相")
    }
}

private func parseHslPercent(text: String, what: String): Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        throw invalidValue("${what}分量不能为空")
    }
    if (trimmed[trimmed.size - 1] == b'%') {
        clampUnit(parseSvgFloat(trimmed[0..trimmed.size - 1], what) / 100.0)
    } else {
        clampUnit(parseSvgFloat(trimmed, what))
    }
}

private func parseSvgFloat(text: String, what: String): Float64 {
    var value = 0.0
    var ok = true
    try {
        value = Float64.parse(text)
    } catch (_: Exception) {
        ok = false
    }
    if (!ok || value.isNaN() || value.isInf()) {
        throw invalidValue("${what}不是合法数字「${text}」")
    }
    value
}

private func clampSvg(value: Float64, low: Float64, high: Float64): Float64 {
    if (value < low) {
        low
    } else if (value > high) {
        high
    } else {
        value
    }
}

private func clampUnit(value: Float64): Float64 {
    clampSvg(value, 0.0, 1.0)
}

private func clampAlpha(value: Float64): Float64 {
    if (value.isNaN() || value.isInf()) {
        throw invalidValue("颜色 alpha 必须是有限数")
    }
    clampSvg(value, 0.0, 1.0)
}

private func clampByte(value: Float64): UInt8 {
    UInt8(Int64(round(clampSvg(value, 0.0, 255.0))))
}

private func hslToRgb(hue: Float64, saturation: Float64, lightness: Float64): (UInt8, UInt8, UInt8) {
    let normalized = hue - floor(hue / 360.0) * 360.0
    let chroma = (1.0 - abs(2.0 * lightness - 1.0)) * saturation
    let sector = normalized / 60.0
    let sectorMod = sector - floor(sector / 2.0) * 2.0
    let x = chroma * (1.0 - abs(sectorMod - 1.0))
    var redPrime = 0.0
    var greenPrime = 0.0
    var bluePrime = 0.0
    if (sector < 1.0) {
        redPrime = chroma
        greenPrime = x
    } else if (sector < 2.0) {
        redPrime = x
        greenPrime = chroma
    } else if (sector < 3.0) {
        greenPrime = chroma
        bluePrime = x
    } else if (sector < 4.0) {
        greenPrime = x
        bluePrime = chroma
    } else if (sector < 5.0) {
        redPrime = x
        bluePrime = chroma
    } else {
        redPrime = chroma
        bluePrime = x
    }
    let m = lightness - chroma / 2.0
    (
        clampByte((redPrime + m) * 255.0),
        clampByte((greenPrime + m) * 255.0),
        clampByte((bluePrime + m) * 255.0)
    )
}

private func hexDigitValue(byte: Byte): ?UInt8 {
    if (byte >= b'0' && byte <= b'9') {
        Some(byte - b'0')
    } else if (byte >= b'a' && byte <= b'f') {
        Some(byte - b'a' + 10)
    } else if (byte >= b'A' && byte <= b'F') {
        Some(byte - b'A' + 10)
    } else {
        None
    }
}

private func hexByte(value: UInt8): String {
    let digits = "0123456789abcdef"
    let high = Int64(value) / 16
    let low = Int64(value) % 16
    digits[high..high + 1] + digits[low..low + 1]
}

internal func indexOfSvgByte(text: String, target: Byte): Int64 {
    let bytes = text.unsafeBytes()
    var i = 0
    while (i < bytes.size) {
        if (bytes[i] == target) {
            return i
        }
        i++
    }
    -1
}
