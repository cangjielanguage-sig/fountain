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

/** `text-decoration-style`。 */
public enum SvgTextDecorationStyle <: Equatable<SvgTextDecorationStyle> & ToString {
    | Solid
    | Double
    | Dotted
    | Dashed
    | Wavy

    public operator func ==(that: SvgTextDecorationStyle): Bool {
        match ((this, that)) {
            case (Solid, Solid) => true
            case (Double, Double) => true
            case (Dotted, Dotted) => true
            case (Dashed, Dashed) => true
            case (Wavy, Wavy) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Solid => "solid"
            case Double => "double"
            case Dotted => "dotted"
            case Dashed => "dashed"
            case Wavy => "wavy"
        }
    }

    internal static func fromName(name: String): ?SvgTextDecorationStyle {
        match (name.trimAscii().toAsciiLower()) {
            case "solid" => Some(Solid)
            case "double" => Some(Double)
            case "dotted" => Some(Dotted)
            case "dashed" => Some(Dashed)
            case "wavy" => Some(Wavy)
            case _ => Option<SvgTextDecorationStyle>.None
        }
    }
}

/** `text-underline-position`。 */
public enum SvgTextUnderlinePosition <: Equatable<SvgTextUnderlinePosition> & ToString {
    | Auto
    | Under
    | Above

    public operator func ==(that: SvgTextUnderlinePosition): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Under, Under) => true
            case (Above, Above) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case Under => "under"
            case Above => "above"
        }
    }

    internal static func fromName(name: String): ?SvgTextUnderlinePosition {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "under" => Some(Under)
            case "above" => Some(Above)
            case _ => Option<SvgTextUnderlinePosition>.None
        }
    }
}

/** 解析后的装饰线规格；由计算样式逐属性从最近声明祖先生效。 */
internal class SvgDecorationStyle {
    let lines: SvgTextDecoration
    let style: SvgTextDecorationStyle
    let color: ?SvgColor
    let thickness: ?SvgLength
    let underlinePosition: SvgTextUnderlinePosition

    init(
        lines!: SvgTextDecoration = SvgTextDecoration.none,
        style!: SvgTextDecorationStyle = SvgTextDecorationStyle.Solid,
        color!: ?SvgColor = None,
        thickness!: ?SvgLength = None,
        underlinePosition!: SvgTextUnderlinePosition = SvgTextUnderlinePosition.Auto
    ) {
        this.lines = lines
        this.style = style
        this.color = color
        this.thickness = thickness
        this.underlinePosition = underlinePosition
    }

    static func none(): SvgDecorationStyle {
        SvgDecorationStyle()
    }
}

/** 装饰线几何规格：线型、颜色、厚度与下划线位置。 */
public class SvgTextDecorationSpec <: ToString {
    public let lines: SvgTextDecoration
    public let style: SvgTextDecorationStyle
    public let color: ?SvgColor
    public let thickness: ?SvgLength
    public let underlinePosition: SvgTextUnderlinePosition

    public init(
        lines!: SvgTextDecoration = SvgTextDecoration.none,
        style!: SvgTextDecorationStyle = SvgTextDecorationStyle.Solid,
        color!: ?SvgColor = None,
        thickness!: ?SvgLength = None,
        underlinePosition!: SvgTextUnderlinePosition = SvgTextUnderlinePosition.Auto
    ) {
        this.lines = lines
        this.style = style
        this.color = color
        this.thickness = thickness
        this.underlinePosition = underlinePosition
    }

    public static func fromStyle(style: SvgComputedStyle): SvgTextDecorationSpec {
        SvgTextDecorationSpec(
            lines: style.textDecoration(),
            style: style.textDecorationStyle(),
            color: style.textDecorationColor(),
            thickness: style.textDecorationThickness(),
            underlinePosition: style.textUnderlinePosition()
        )
    }

    /** 生成装饰线路径；`thickness` 为本规格的实际厚度。 */
    public func outline(width!: Float64, thickness!: Float64): SvgPathData {
        let commands = ArrayList<SvgPathCommand>()
        let safeThickness = if (thickness > 0.0) { thickness } else { 1.0 }
        if (this.lines.underline) {
            let baseline = match (this.underlinePosition) {
                case Above => -safeThickness * 2.0
                case Under => safeThickness * 3.0
                case Auto => safeThickness
            }
            appendDecorationLine(commands, width, baseline, safeThickness)
        }
        if (this.lines.overline) {
            appendDecorationLine(commands, width, -12.0, safeThickness)
        }
        if (this.lines.lineThrough) {
            appendDecorationLine(commands, width, -6.0, safeThickness)
        }
        SvgPathData(commands.toArray())
    }

    private func appendDecorationLine(
        commands: ArrayList<SvgPathCommand>,
        width: Float64,
        y: Float64,
        thickness: Float64
    ): Unit {
        appendSvgDecorationSegments(
            commands,
            SvgMatrix.identity,
            width,
            y,
            thickness,
            this.style
        )
    }

    public func toString(): String {
        "SvgTextDecorationSpec(${this.lines.toString()}, ${this.style.toString()})"
    }
}

/** 按线型生成装饰线段；`matrix` 把局部坐标映射到用户空间。 */
internal func appendSvgDecorationSegments(
    commands: ArrayList<SvgPathCommand>,
    matrix: SvgMatrix,
    width: Float64,
    offsetY: Float64,
    thickness: Float64,
    style: SvgTextDecorationStyle
): Unit {
    let safeThickness = if (thickness > 0.0) { thickness } else { 1.0 }
    match (style) {
        case Solid => appendSvgDecorationRect(commands, matrix, 0.0, width, offsetY, safeThickness)
        case Double =>
            let half = safeThickness / 3.0
            appendSvgDecorationRect(commands, matrix, 0.0, width, offsetY, half)
            appendSvgDecorationRect(
                commands,
                matrix,
                0.0,
                width,
                offsetY + half * 2.0,
                half
            )
        case Dotted =>
            let step = safeThickness * 2.0
            var x = 0.0
            while (x < width) {
                let end = if (x + safeThickness > width) { width } else { x + safeThickness }
                appendSvgDecorationRect(commands, matrix, x, end, offsetY, safeThickness)
                x += step
            }
        case Dashed =>
            let dash = safeThickness
            let gap = safeThickness
            var x = 0.0
            while (x < width) {
                let end = if (x + dash > width) { width } else { x + dash }
                appendSvgDecorationRect(commands, matrix, x, end, offsetY, safeThickness)
                x += dash + gap
            }
        case Wavy =>
            let steps: Int64 = 32
            let amplitude = safeThickness
            var index: Int64 = 0
            while (index <= steps) {
                let x = width * Float64(index) / Float64(steps)
                let wave = sin(Float64(index) / Float64(steps) * 2.0 * 3.141592653589793) *
                    amplitude
                let point = matrix.apply(SvgPoint(x, offsetY + wave))
                let kind = if (index == 0) {
                    SvgPathCommandKind.MoveTo
                } else {
                    SvgPathCommandKind.LineTo
                }
                commands.add(SvgPathCommand(kind, false, [point.x, point.y]))
                index++
            }
    }
}

private func appendSvgDecorationRect(
    commands: ArrayList<SvgPathCommand>,
    matrix: SvgMatrix,
    start: Float64,
    end: Float64,
    y: Float64,
    height: Float64
): Unit {
    let p0 = matrix.apply(SvgPoint(start, y))
    let p1 = matrix.apply(SvgPoint(end, y))
    let p2 = matrix.apply(SvgPoint(end, y + height))
    let p3 = matrix.apply(SvgPoint(start, y + height))
    commands.add(SvgPathCommand(SvgPathCommandKind.MoveTo, false, [p0.x, p0.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [p1.x, p1.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [p2.x, p2.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [p3.x, p3.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
}

/**
 * 逐属性解析装饰线：从元素自身向上取最近声明；四类非继承长属性按 CSS 语义
 * 由最近声明祖先决定，`text-underline-position` 直接读取已继承的计算值。
 */
internal func resolveSvgDecorationStyle(
    element: SvgElement,
    style: SvgComputedStyle,
    styles: ?SvgComputedStyleTree
): SvgDecorationStyle {
    var lines = SvgTextDecoration.none
    var decoStyle = SvgTextDecorationStyle.Solid
    var color: ?SvgColor = None
    var thickness: ?SvgLength = None
    var haveLines = false
    var haveStyle = false
    var haveColor = false
    var haveThickness = false
    var underlinePosition = style.textUnderlinePosition()
    var current: ?SvgElement = Some(element)
    var first = true
    while (true) {
        let node = match (current) {
            case Some(value) => value
            case None => break
        }
        let currentStyle: ?SvgComputedStyle = match (styles) {
            case Some(tree) =>
                if (first) {
                    Some(style)
                } else {
                    tree.get(node)
                }
            case None => if (first) {
                Some(style)
            } else {
                Option<SvgComputedStyle>.None
            }
        }
        match (currentStyle) {
            case Some(value) =>
                if (!haveLines && svgDecorationDeclares(value, "text-decoration-line")) {
                    lines = value.textDecoration()
                    haveLines = true
                }
                if (!haveStyle && svgDecorationDeclares(value, "text-decoration-style")) {
                    decoStyle = value.textDecorationStyle()
                    haveStyle = true
                }
                if (!haveColor && svgDecorationDeclares(value, "text-decoration-color")) {
                    color = value.textDecorationColor()
                    haveColor = true
                }
                if (!haveThickness && svgDecorationDeclares(value, "text-decoration-thickness")) {
                    thickness = value.textDecorationThickness()
                    haveThickness = true
                }
            case None => ()
        }
        // 无样式树时按属性回退，保留 M4 的祖先属性传播语义。
        if (styles.isNone()) {
            if (!haveLines) {
                match (node.attr("text-decoration-line")) {
                    case Some(text) =>
                        match (parseSvgDecorationLines(text)) {
                            case Some(value) =>
                                lines = value
                                haveLines = true
                            case None => ()
                        }
                    case None =>
                        match (node.attr("text-decoration")) {
                            case Some(text) =>
                                match (parseSvgDecorationLines(text)) {
                                    case Some(value) =>
                                        lines = value
                                        haveLines = true
                                    case None => ()
                                }
                            case None => ()
                        }
                }
            }
            if (!haveStyle) {
                match (node.attr("text-decoration-style")) {
                    case Some(text) =>
                        match (SvgTextDecorationStyle.fromName(text)) {
                            case Some(value) =>
                                decoStyle = value
                                haveStyle = true
                            case None => ()
                        }
                    case None => ()
                }
            }
            if (!haveColor) {
                match (node.attr("text-decoration-color")) {
                    case Some(text) =>
                        match (SvgColor.tryParse(text)) {
                            case Some(value) =>
                                color = Some(value)
                                haveColor = true
                            case None => ()
                        }
                    case None => ()
                }
            }
            if (!haveThickness) {
                match (node.attr("text-decoration-thickness")) {
                    case Some(text) =>
                        match (SvgLength.tryParse(text)) {
                            case Some(value) =>
                                thickness = Some(value)
                                haveThickness = true
                            case None => ()
                        }
                    case None => ()
                }
            }
            if (first) {
                underlinePosition = match (node.attr("text-underline-position")) {
                    case Some(text) =>
                        SvgTextUnderlinePosition.fromName(text) ?? SvgTextUnderlinePosition.Auto
                    case None => SvgTextUnderlinePosition.Auto
                }
            }
        }
        current = node.parent
        first = false
    }
    SvgDecorationStyle(
        lines: lines,
        style: decoStyle,
        color: color,
        thickness: thickness,
        underlinePosition: underlinePosition
    )
}

/** 该计算样式是否声明了指定装饰属性（简写视为声明全部长属性）。 */
private func svgDecorationDeclares(style: SvgComputedStyle, name: String): Bool {
    if (style.sourceOf(name) != CssStyleSource.Default) {
        return true
    }
    if (name == "text-underline-position") {
        return false
    }
    style.sourceOf("text-decoration") != CssStyleSource.Default
}
