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
        match (this.style) {
            case Solid => appendDecorationRect(commands, 0.0, width, y, thickness)
            case Double =>
                let half = thickness / 3.0
                appendDecorationRect(commands, 0.0, width, y, half)
                appendDecorationRect(commands, 0.0, width, y + half * 2.0, half)
            case Dotted =>
                let step = thickness * 2.0
                var x = 0.0
                while (x < width) {
                    let end = if (x + thickness > width) { width } else { x + thickness }
                    appendDecorationRect(commands, x, end, y, thickness)
                    x += step
                }
            case Dashed =>
                let dash = thickness * 4.0
                let gap = thickness * 2.0
                var x = 0.0
                while (x < width) {
                    let end = if (x + dash > width) { width } else { x + dash }
                    appendDecorationRect(commands, x, end, y, thickness)
                    x += dash + gap
                }
            case Wavy =>
                let steps: Int64 = 32
                let amplitude = thickness
                var index: Int64 = 0
                while (index <= steps) {
                    let x = width * Float64(index) / Float64(steps)
                    let wave = sin(Float64(index) / Float64(steps) * 2.0 * 3.141592653589793) *
                        amplitude
                    let kind = if (index == 0) {
                        SvgPathCommandKind.MoveTo
                    } else {
                        SvgPathCommandKind.LineTo
                    }
                    commands.add(SvgPathCommand(kind, false, [x, y + wave]))
                    index++
                }
        }
    }

    public func toString(): String {
        "SvgTextDecorationSpec(${this.lines.toString()}, ${this.style.toString()})"
    }
}

private func appendDecorationRect(
    commands: ArrayList<SvgPathCommand>,
    start: Float64,
    end: Float64,
    y: Float64,
    height: Float64
): Unit {
    commands.add(SvgPathCommand(SvgPathCommandKind.MoveTo, false, [start, y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [end, y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [end, y + height]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [start, y + height]))
    commands.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
}
