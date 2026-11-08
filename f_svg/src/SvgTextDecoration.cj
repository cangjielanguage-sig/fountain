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

/** `text-decoration` 组合；`none` 表示为全 `false`。 */
public struct SvgTextDecoration <: Equatable<SvgTextDecoration> & ToString {
    public let underline: Bool
    public let overline: Bool
    public let lineThrough: Bool

    public init(underline!: Bool = false, overline!: Bool = false, lineThrough!: Bool = false) {
        this.underline = underline
        this.overline = overline
        this.lineThrough = lineThrough
    }

    public static let none = SvgTextDecoration()

    public func isNone(): Bool {
        !this.underline && !this.overline && !this.lineThrough
    }

    public operator func ==(that: SvgTextDecoration): Bool {
        this.underline == that.underline && this.overline == that.overline &&
            this.lineThrough == that.lineThrough
    }

    /** 规范顺序：underline → overline → line-through。 */
    public func toString(): String {
        if (this.isNone()) {
            return "none"
        }
        let parts = ArrayList<String>()
        if (this.underline) {
            parts.add("underline")
        }
        if (this.overline) {
            parts.add("overline")
        }
        if (this.lineThrough) {
            parts.add("line-through")
        }
        var text = ""
        for (index in 0..parts.size) {
            if (index > 0) {
                text += " "
            }
            text += parts[index]
        }
        text
    }

    /** 解析关键字列表；非法 token 返回 `None`。 */
    public static func tryParse(text: String): ?SvgTextDecoration {
        let trimmed = text.trimAscii()
        if (trimmed.size == 0) {
            return None
        }
        var underline = false
        var overline = false
        var lineThrough = false
        var sawNone = false
        var sawOther = false
        let bytes = trimmed.unsafeBytes()
        var index = 0
        while (index < bytes.size) {
            while (index < bytes.size && (isSvgSpace(bytes[index]) || bytes[index] == b',')) {
                index++
            }
            if (index >= bytes.size) {
                break
            }
            let start = index
            while (index < bytes.size && !isSvgSpace(bytes[index]) && bytes[index] != b',') {
                index++
            }
            match (trimmed[start..index].toAsciiLower()) {
                case "none" => sawNone = true
                case "underline" =>
                    underline = true
                    sawOther = true
                case "overline" =>
                    overline = true
                    sawOther = true
                case "line-through" =>
                    lineThrough = true
                    sawOther = true
                case _ => return None
            }
        }
        if (sawNone) {
            if (sawOther) {
                return None
            }
            return Some(SvgTextDecoration.none)
        }
        if (!sawOther) {
            return None
        }
        SvgTextDecoration(underline: underline, overline: overline, lineThrough: lineThrough)
    }
}

/** 装饰线几何。 */
public class SvgTextDecorationGeometry {
    /** 下划线距基线的偏移（正值向下）。 */
    public static func underlineOffset(fontSize: Float64): Float64 {
        0.10 * fontSize
    }

    /** 上划线距基线的偏移（正值向下，即基线上方 ascent 处）。 */
    public static func overlineOffset(ascent: Float64): Float64 {
        -ascent
    }

    /** 删除线距基线的偏移（正值向下）。 */
    public static func lineThroughOffset(ascent: Float64): Float64 {
        -0.55 * ascent
    }

    /** 装饰线厚度。 */
    public static func thickness(fontSize: Float64): Float64 {
        let value = fontSize / 14.0
        if (value > 1.0) {
            value
        } else {
            1.0
        }
    }
}
