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
package fountain::f_excel

import std.collection.ArrayList

/** 下划线样式。 */
public enum Underline <: ToString {
    | Off | Single | Double | SingleAccounting | DoubleAccounting

    public func toString(): String {
        match (this) {
            case Off => "none"
            case Single => "single"
            case Double => "double"
            case SingleAccounting => "singleAccounting"
            case DoubleAccounting => "doubleAccounting"
        }
    }
}

/** 填充图案。 */
public enum PatternType <: ToString {
    | NoFill | Solid | Gray125 | DarkGray | MediumGray | LightGray
    | DarkHorizontal | DarkVertical | DarkDown | DarkUp
    | LightHorizontal | LightVertical | LightDown | LightUp

    public func toString(): String {
        match (this) {
            case NoFill => "none"
            case Solid => "solid"
            case Gray125 => "gray125"
            case DarkGray => "darkGray"
            case MediumGray => "mediumGray"
            case LightGray => "lightGray"
            case DarkHorizontal => "darkHorizontal"
            case DarkVertical => "darkVertical"
            case DarkDown => "darkDown"
            case DarkUp => "darkUp"
            case LightHorizontal => "lightHorizontal"
            case LightVertical => "lightVertical"
            case LightDown => "lightDown"
            case LightUp => "lightUp"
        }
    }

    static func parse(value: String): PatternType {
        match (value) {
            case "solid" => Solid
            case "gray125" => Gray125
            case "darkGray" => DarkGray
            case "mediumGray" => MediumGray
            case "lightGray" => LightGray
            case "darkHorizontal" => DarkHorizontal
            case "darkVertical" => DarkVertical
            case "darkDown" => DarkDown
            case "darkUp" => DarkUp
            case "lightHorizontal" => LightHorizontal
            case "lightVertical" => LightVertical
            case "lightDown" => LightDown
            case "lightUp" => LightUp
            case _ => NoFill
        }
    }
}

/** 边框线型。 */
public enum BorderStyle <: ToString {
    | NoLine | Thin | Medium | Thick | Dashed | Dotted | Double | Hair
    | MediumDashed | DashDot | MediumDashDot | DashDotDot | MediumDashDotDot | SlantDashDot

    public func toString(): String {
        match (this) {
            case NoLine => "none"
            case Thin => "thin"
            case Medium => "medium"
            case Thick => "thick"
            case Dashed => "dashed"
            case Dotted => "dotted"
            case Double => "double"
            case Hair => "hair"
            case MediumDashed => "mediumDashed"
            case DashDot => "dashDot"
            case MediumDashDot => "mediumDashDot"
            case DashDotDot => "dashDotDot"
            case MediumDashDotDot => "mediumDashDotDot"
            case SlantDashDot => "slantDashDot"
        }
    }

    static func parse(value: String): BorderStyle {
        match (value) {
            case "thin" => Thin
            case "medium" => Medium
            case "thick" => Thick
            case "dashed" => Dashed
            case "dotted" => Dotted
            case "double" => Double
            case "hair" => Hair
            case "mediumDashed" => MediumDashed
            case "dashDot" => DashDot
            case "mediumDashDot" => MediumDashDot
            case "dashDotDot" => DashDotDot
            case "mediumDashDotDot" => MediumDashDotDot
            case "slantDashDot" => SlantDashDot
            case _ => NoLine
        }
    }
}

/** 水平对齐。 */
public enum Horizontal <: ToString {
    | General | Left | Center | Right | Fill | Justify | CenterContinuous | Distributed

    public func toString(): String {
        match (this) {
            case General => "general"
            case Left => "left"
            case Center => "center"
            case Right => "right"
            case Fill => "fill"
            case Justify => "justify"
            case CenterContinuous => "centerContinuous"
            case Distributed => "distributed"
        }
    }

    static func parse(value: String): Horizontal {
        match (value) {
            case "left" => Left
            case "center" => Center
            case "right" => Right
            case "fill" => Fill
            case "justify" => Justify
            case "centerContinuous" => CenterContinuous
            case "distributed" => Distributed
            case _ => General
        }
    }
}

/** 垂直对齐。 */
public enum Vertical <: ToString {
    | Top | Center | Bottom | Justify | Distributed

    public func toString(): String {
        match (this) {
            case Top => "top"
            case Center => "center"
            case Bottom => "bottom"
            case Justify => "justify"
            case Distributed => "distributed"
        }
    }

    static func parse(value: String): Vertical {
        match (value) {
            case "top" => Top
            case "center" => Center
            case "justify" => Justify
            case "distributed" => Distributed
            case _ => Bottom
        }
    }
}

/**
 * 颜色：三种编码互斥。
 *
 * `Theme` 的 `tint` 在写入时原样保留；读取侧不做"主题色 → RGB"的展开（需要 theme1.xml，
 * 留给需要真实色值的调用方自行解析）。
 */
public enum Color <: ToString {
    | Rgb(String)
    | Theme(Int64, Float64)
    | Indexed(Int64)

    public func toString(): String {
        match (this) {
            case Rgb(value) => "rgb:${value}"
            case Theme(theme, tint) => "theme:${theme}:${tint}"
            case Indexed(index) => "indexed:${index}"
        }
    }
}

/** 字体。`name = None` 表示"文件里没写"，写回时同样省略。 */
public struct Font <: ToString {
    public let name: ?String
    public let size: Float64
    public let bold: Bool
    public let italic: Bool
    public let underline: Underline
    public let strike: Bool
    public let color: ?Color
    public let family: Int64
    public let charset: Int64
    public let scheme: ?String

    public init(
        name!: ?String = None,
        size!: Float64 = 11.0,
        bold!: Bool = false,
        italic!: Bool = false,
        underline!: Underline = Underline.Off,
        strike!: Bool = false,
        color!: ?Color = None,
        family!: Int64 = 2,
        charset!: Int64 = 0,
        scheme!: ?String = None
    ) {
        this.name = name
        this.size = size
        this.bold = bold
        this.italic = italic
        this.underline = underline
        this.strike = strike
        this.color = color
        this.family = family
        this.charset = charset
        this.scheme = scheme
    }

    public static func default(): Font {
        Font()
    }

    public func toString(): String {
        let color = match (this.color) {
            case Some(value) => value.toString()
            case None => ""
        }
        "Font(${this.name ?? "-"}, ${this.size}, b=${this.bold}, i=${this.italic}, u=${this.underline}, " +
            "s=${this.strike}, c=${color}, f=${this.family}, cs=${this.charset}, ${this.scheme ?? "-"})"
    }
}

/** 渐变的一个色标。 */
public struct GradientStop <: ToString {
    public let position: Float64
    public let color: Color

    public init(position: Float64, color: Color) {
        this.position = position
        this.color = color
    }

    public func toString(): String {
        "${this.position}:${this.color}"
    }
}

/** 渐变填充（type: "linear" / "path"；degree 只对 linear 有意义）。 */
public struct Gradient <: ToString {
    public let kind: String
    public let degree: Float64
    public let stops: ArrayList<GradientStop>

    public init(kind!: String = "linear", degree!: Float64 = 0.0, stops!: ArrayList<GradientStop> = ArrayList<GradientStop>()) {
        this.kind = kind
        this.degree = degree
        this.stops = stops
    }

    public func toString(): String {
        var text = "Gradient(${this.kind}, ${this.degree}"
        for (stop in this.stops) {
            text += ",${stop}"
        }
        text + ")"
    }
}

/** 填充。 */
public struct Fill <: ToString {
    public let patternType: PatternType
    public let fgColor: ?Color
    public let bgColor: ?Color
    public let gradient: ?Gradient

    public init(
        patternType!: PatternType = PatternType.NoFill,
        fgColor!: ?Color = None,
        bgColor!: ?Color = None,
        gradient!: ?Gradient = None
    ) {
        this.patternType = patternType
        this.fgColor = fgColor
        this.bgColor = bgColor
        this.gradient = gradient
    }

    public static func none(): Fill {
        Fill()
    }

    public static func solid(color: Color): Fill {
        Fill(patternType: PatternType.Solid, fgColor: Some(color), bgColor: Some(color))
    }

    public func toString(): String {
        let fg = match (this.fgColor) {
            case Some(value) => value.toString()
            case None => ""
        }
        let bg = match (this.bgColor) {
            case Some(value) => value.toString()
            case None => ""
        }
        let gradient = match (this.gradient) {
            case Some(value) => value.toString()
            case None => ""
        }
        "${this.patternType}:${fg}:${bg}:${gradient}"
    }
}

/** 边框的一条边。 */
public struct BorderSide <: ToString {
    public let style: BorderStyle
    public let color: ?Color

    public init(style!: BorderStyle = BorderStyle.NoLine, color!: ?Color = None) {
        this.style = style
        this.color = color
    }

    public static func none(): BorderSide {
        BorderSide()
    }

    public func toString(): String {
        let color = match (this.color) {
            case Some(value) => value.toString()
            case None => ""
        }
        "${this.style}:${color}"
    }
}

/** 四边 + 对角线。 */
public struct Border <: ToString {
    public let left: BorderSide
    public let right: BorderSide
    public let top: BorderSide
    public let bottom: BorderSide
    public let diagonal: BorderSide

    public init(
        left!: BorderSide = BorderSide.none(),
        right!: BorderSide = BorderSide.none(),
        top!: BorderSide = BorderSide.none(),
        bottom!: BorderSide = BorderSide.none(),
        diagonal!: BorderSide = BorderSide.none()
    ) {
        this.left = left
        this.right = right
        this.top = top
        this.bottom = bottom
        this.diagonal = diagonal
    }

    public static func none(): Border {
        Border()
    }

    public func toString(): String {
        "${this.left}|${this.right}|${this.top}|${this.bottom}|${this.diagonal}"
    }
}

/** 对齐。 */
public struct Alignment <: ToString {
    public let horizontal: Horizontal
    public let vertical: Vertical
    public let wrapText: Bool
    public let textRotation: Int64
    public let indent: Int64
    public let shrinkToFit: Bool

    public init(
        horizontal!: Horizontal = Horizontal.General,
        vertical!: Vertical = Vertical.Bottom,
        wrapText!: Bool = false,
        textRotation!: Int64 = 0,
        indent!: Int64 = 0,
        shrinkToFit!: Bool = false
    ) {
        this.horizontal = horizontal
        this.vertical = vertical
        this.wrapText = wrapText
        this.textRotation = textRotation
        this.indent = indent
        this.shrinkToFit = shrinkToFit
    }

    public static func default(): Alignment {
        Alignment()
    }

    public func toString(): String {
        "${this.horizontal}/${this.vertical}/${this.wrapText}/${this.textRotation}/${this.indent}/${this.shrinkToFit}"
    }
}

/** 保护。 */
public struct Protection <: ToString {
    public let locked: Bool
    public let hidden: Bool

    public init(locked!: Bool = true, hidden!: Bool = false) {
        this.locked = locked
        this.hidden = hidden
    }

    public static func default(): Protection {
        Protection()
    }

    public func toString(): String {
        "locked=${this.locked},hidden=${this.hidden}"
    }
}

/**
 * 单元格完整样式（值类型）。
 *
 * 写侧按值深比较去重；`numberFormat` 与 M1 的 `Cell.numberFormat` 语义一致。
 */
public struct CellStyle <: ToString {
    public let numberFormat: NumberFormat
    public let font: Font
    public let fill: Fill
    public let border: Border
    public let alignment: Alignment
    public let protection: Protection
    public let namedStyle: ?String

    public init(
        numberFormat!: NumberFormat = NumberFormat.General,
        font!: Font = Font.default(),
        fill!: Fill = Fill.none(),
        border!: Border = Border.none(),
        alignment!: Alignment = Alignment.default(),
        protection!: Protection = Protection.default(),
        namedStyle!: ?String = None
    ) {
        this.numberFormat = numberFormat
        this.font = font
        this.fill = fill
        this.border = border
        this.alignment = alignment
        this.protection = protection
        this.namedStyle = namedStyle
    }

    public func withFont(value: Font): CellStyle {
        CellStyle(numberFormat: this.numberFormat, font: value, fill: this.fill, border: this.border,
            alignment: this.alignment, protection: this.protection, namedStyle: this.namedStyle)
    }

    public func withFill(value: Fill): CellStyle {
        CellStyle(numberFormat: this.numberFormat, font: this.font, fill: value, border: this.border,
            alignment: this.alignment, protection: this.protection, namedStyle: this.namedStyle)
    }

    public func withNumberFormat(value: NumberFormat): CellStyle {
        CellStyle(numberFormat: value, font: this.font, fill: this.fill, border: this.border,
            alignment: this.alignment, protection: this.protection, namedStyle: this.namedStyle)
    }

    public func withAlignment(value: Alignment): CellStyle {
        CellStyle(numberFormat: this.numberFormat, font: this.font, fill: this.fill, border: this.border,
            alignment: value, protection: this.protection, namedStyle: this.namedStyle)
    }

    public func withBorder(value: Border): CellStyle {
        CellStyle(numberFormat: this.numberFormat, font: this.font, fill: this.fill, border: value,
            alignment: this.alignment, protection: this.protection, namedStyle: this.namedStyle)
    }

    public func toString(): String {
        "CellStyle(${this.numberFormat}|${this.font}|${this.fill}|${this.border}|${this.alignment}|${this.protection}|${this.namedStyle ?? ""})"
    }
}

/** 样式去重键（深比较的等价物，避免为每个嵌套 struct 实现 Equatable）。 */
internal func styleKey(style: CellStyle): String {
    style.toString()
}
