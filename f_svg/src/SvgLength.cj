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

import std.math.*
import fountain::f_base.*

/** SVG 长度单位。`Number` 表示无单位数。 */
public enum SvgLengthUnit <: Equatable<SvgLengthUnit> & ToString {
    | Number
    | Percent
    | Em
    | Ex
    | Px
    | Pt
    | Pc
    | Cm
    | Mm
    | In

    public operator func ==(that: SvgLengthUnit): Bool {
        match ((this, that)) {
            case (Number, Number) => true
            case (Percent, Percent) => true
            case (Em, Em) => true
            case (Ex, Ex) => true
            case (Px, Px) => true
            case (Pt, Pt) => true
            case (Pc, Pc) => true
            case (Cm, Cm) => true
            case (Mm, Mm) => true
            case (In, In) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Number => "Number"
            case Percent => "Percent"
            case Em => "Em"
            case Ex => "Ex"
            case Px => "Px"
            case Pt => "Pt"
            case Pc => "Pc"
            case Cm => "Cm"
            case Mm => "Mm"
            case In => "In"
        }
    }

    /** SVG 属性里书写的单位后缀；无单位数为空串。 */
    internal func suffix(): String {
        match (this) {
            case Number => ""
            case Percent => "%"
            case Em => "em"
            case Ex => "ex"
            case Px => "px"
            case Pt => "pt"
            case Pc => "pc"
            case Cm => "cm"
            case Mm => "mm"
            case In => "in"
        }
    }
}

/**
 * 长度值：数值 + 单位。
 *
 * `parse` 失败抛 `SvgException(InvalidValue)`，`tryParse` 返回 `None`；
 * `toString` 输出规范形式；对规范形式可表示的值满足 `parse(toString(x)) == x`
 * （超过 6 位小数与 `|v| < 1e-6` 归零是已声明的不保真边界）。
 */
public struct SvgLength <: Equatable<SvgLength> & ToString {
    public let value: Float64
    public let unit: SvgLengthUnit

    public init(value: Float64, unit!: SvgLengthUnit = SvgLengthUnit.Number) {
        this.value = value
        this.unit = unit
    }

    public static func parse(text: String): SvgLength {
        let trimmed = text.trimAscii()
        if (trimmed.size == 0) {
            throw invalidValue("长度不能为空")
        }
        match (scanSvgNumber(trimmed, 0)) {
            case Some(token) =>
                let value = requireFinite(token.value, "长度值")
                SvgLength(value, unit: parseUnit(trimmed[token.end..]))
            case None => throw invalidValue("无法解析长度「${text}」")
        }
    }

    public static func tryParse(text: String): ?SvgLength {
        try {
            Some(SvgLength.parse(text))
        } catch (_: SvgException) {
            None
        }
    }

    /** 绝对单位（不依赖视口或字号）。 */
    public func isAbsolute(): Bool {
        match (this.unit) {
            case Number | Px | Pt | Pc | Cm | Mm | In => true
            case Percent | Em | Ex => false
        }
    }

    public func toString(): String {
        formatSvgNumber(this.value) + this.unit.suffix()
    }

    public operator func ==(that: SvgLength): Bool {
        this.value == that.value && this.unit == that.unit
    }

    private static func parseUnit(text: String): SvgLengthUnit {
        if (text.size == 0) {
            return SvgLengthUnit.Number
        }
        if (text == "%") {
            return SvgLengthUnit.Percent
        }
        match (text.toAsciiLower()) {
            case "em" => SvgLengthUnit.Em
            case "ex" => SvgLengthUnit.Ex
            case "px" => SvgLengthUnit.Px
            case "pt" => SvgLengthUnit.Pt
            case "pc" => SvgLengthUnit.Pc
            case "cm" => SvgLengthUnit.Cm
            case "mm" => SvgLengthUnit.Mm
            case "in" => SvgLengthUnit.In
            case _ => throw invalidValue("未知的长度单位「${text}」")
        }
    }
}

/** 百分比长度的基准轴。 */
public enum SvgLengthAxis <: Equatable<SvgLengthAxis> & ToString {
    | Horizontal
    | Vertical
    | Diagonal

    public operator func ==(that: SvgLengthAxis): Bool {
        match ((this, that)) {
            case (Horizontal, Horizontal) => true
            case (Vertical, Vertical) => true
            case (Diagonal, Diagonal) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Horizontal => "Horizontal"
            case Vertical => "Vertical"
            case Diagonal => "Diagonal"
        }
    }
}

/** 长度换算的上下文：视口尺寸、字号与 DPI。 */
public struct SvgLengthContext {
    public let viewportWidth: Float64
    public let viewportHeight: Float64
    public let fontSize: Float64
    public let dpi: Float64

    public init(
        viewportWidth: Float64,
        viewportHeight: Float64,
        fontSize!: Float64 = 16.0,
        dpi!: Float64 = 96.0
    ) {
        this.viewportWidth = viewportWidth
        this.viewportHeight = viewportHeight
        this.fontSize = fontSize
        this.dpi = dpi
    }

    public static func of(width: Float64, height: Float64): SvgLengthContext {
        SvgLengthContext(width, height)
    }
}

/** 把长度换算成用户单位。百分比基准由 `axis` 显式指定。 */
public func toUserUnits(length: SvgLength, axis: SvgLengthAxis, context: SvgLengthContext): Float64 {
    match (length.unit) {
        case Number | Px => length.value
        case In => length.value * context.dpi
        case Cm => length.value * context.dpi / 2.54
        case Mm => length.value * context.dpi / 25.4
        case Pt => length.value * context.dpi / 72.0
        case Pc => length.value * context.dpi / 6.0
        case Em => length.value * context.fontSize
        case Ex => length.value * context.fontSize / 2.0
        case Percent =>
            match (axis) {
                case Horizontal => length.value / 100.0 * context.viewportWidth
                case Vertical => length.value / 100.0 * context.viewportHeight
                case Diagonal =>
                    let diagonal = sqrt(
                        context.viewportWidth * context.viewportWidth +
                        context.viewportHeight * context.viewportHeight
                    )
                    length.value / 100.0 * diagonal / sqrt(2.0)
            }
    }
}
