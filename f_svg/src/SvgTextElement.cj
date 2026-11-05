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

/** 文本锚点。 */
public enum SvgTextAnchor <: Equatable<SvgTextAnchor> & ToString {
    | Start
    | Middle
    | End

    public operator func ==(that: SvgTextAnchor): Bool {
        match ((this, that)) {
            case (Start, Start) => true
            case (Middle, Middle) => true
            case (End, End) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Start => "Start"
            case Middle => "Middle"
            case End => "End"
        }
    }

    internal func attrName(): String {
        match (this) {
            case Start => "start"
            case Middle => "middle"
            case End => "end"
        }
    }

    internal static func fromName(name: String): ?SvgTextAnchor {
        match (name) {
            case "start" => Some(Start)
            case "middle" => Some(Middle)
            case "end" => Some(End)
            case _ => None
        }
    }
}

/** 文本长度调整方式。 */
public enum SvgLengthAdjust <: Equatable<SvgLengthAdjust> & ToString {
    | Spacing
    | SpacingAndGlyphs

    public operator func ==(that: SvgLengthAdjust): Bool {
        match ((this, that)) {
            case (Spacing, Spacing) => true
            case (SpacingAndGlyphs, SpacingAndGlyphs) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Spacing => "Spacing"
            case SpacingAndGlyphs => "SpacingAndGlyphs"
        }
    }

    internal func attrName(): String {
        match (this) {
            case Spacing => "spacing"
            case SpacingAndGlyphs => "spacingAndGlyphs"
        }
    }

    internal static func fromName(name: String): ?SvgLengthAdjust {
        match (name) {
            case "spacing" => Some(Spacing)
            case "spacingAndGlyphs" => Some(SpacingAndGlyphs)
            case _ => None
        }
    }
}

/** 文本元素基类：`text` / `tspan` / `textPath` 共用。 */
public open class SvgTextElement <: SvgElement {
    private let xCache = SvgValueCache<Array<SvgLength>>()
    private let yCache = SvgValueCache<Array<SvgLength>>()
    private let dxCache = SvgValueCache<Array<SvgLength>>()
    private let dyCache = SvgValueCache<Array<SvgLength>>()
    private let rotateCache = SvgValueCache<Array<Float64>>()
    private let textLengthCache = SvgValueCache<SvgLength>()
    private let lengthAdjustCache = SvgValueCache<SvgLengthAdjust>()
    private let textAnchorCache = SvgValueCache<SvgTextAnchor>()
    private let fontSizeCache = SvgValueCache<SvgLength>()
    private let letterSpacingCache = SvgValueCache<SvgLength>()
    private let wordSpacingCache = SvgValueCache<SvgLength>()

    protected init(tag: String) {
        super(tag)
    }

    public mut prop x: ?Array<SvgLength> {
        get() {
            this.xCache.get(this.attributesVersion, {=> readLengthArray(this, "x")})
        }
        set(value) {
            writeLengthArray(this, "x", value)
        }
    }

    public mut prop y: ?Array<SvgLength> {
        get() {
            this.yCache.get(this.attributesVersion, {=> readLengthArray(this, "y")})
        }
        set(value) {
            writeLengthArray(this, "y", value)
        }
    }

    public mut prop dx: ?Array<SvgLength> {
        get() {
            this.dxCache.get(this.attributesVersion, {=> readLengthArray(this, "dx")})
        }
        set(value) {
            writeLengthArray(this, "dx", value)
        }
    }

    public mut prop dy: ?Array<SvgLength> {
        get() {
            this.dyCache.get(this.attributesVersion, {=> readLengthArray(this, "dy")})
        }
        set(value) {
            writeLengthArray(this, "dy", value)
        }
    }

    public mut prop rotate: ?Array<Float64> {
        get() {
            this.rotateCache.get(this.attributesVersion, {=> readNumberArray(this, "rotate")})
        }
        set(value) {
            match (value) {
                case Some(values) => this.setAttr("rotate", formatSvgNumberArray(values))
                case None => this.removeAttr("rotate")
            }
        }
    }

    public mut prop textLength: ?SvgLength {
        get() {
            this.textLengthCache.get(this.attributesVersion, {=> readLength(this, "textLength")})
        }
        set(value) {
            writeLength(this, "textLength", value)
        }
    }

    public mut prop lengthAdjust: ?SvgLengthAdjust {
        get() {
            this.lengthAdjustCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("lengthAdjust")) {
                        case Some(text) => SvgLengthAdjust.fromName(text.trimAscii())
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(adjust) => this.setAttr("lengthAdjust", adjust.attrName())
                case None => this.removeAttr("lengthAdjust")
            }
        }
    }

    public mut prop textAnchor: ?SvgTextAnchor {
        get() {
            this.textAnchorCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("text-anchor")) {
                        case Some(text) => SvgTextAnchor.fromName(text.trimAscii())
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(anchor) => this.setAttr("text-anchor", anchor.attrName())
                case None => this.removeAttr("text-anchor")
            }
        }
    }

    public mut prop fontFamily: ?String {
        get() {
            this.attr("font-family")
        }
        set(value) {
            this.writeOptionalAttribute("font-family", value)
        }
    }

    public mut prop fontSize: ?SvgLength {
        get() {
            this.fontSizeCache.get(this.attributesVersion, {=> readLength(this, "font-size")})
        }
        set(value) {
            writeLength(this, "font-size", value)
        }
    }

    public mut prop fontWeight: ?String {
        get() {
            this.attr("font-weight")
        }
        set(value) {
            this.writeOptionalAttribute("font-weight", value)
        }
    }

    public mut prop fontStyle: ?String {
        get() {
            this.attr("font-style")
        }
        set(value) {
            this.writeOptionalAttribute("font-style", value)
        }
    }

    public mut prop letterSpacing: ?SvgLength {
        get() {
            this.letterSpacingCache.get(this.attributesVersion, {=> readLength(this, "letter-spacing")})
        }
        set(value) {
            writeLength(this, "letter-spacing", value)
        }
    }

    public mut prop wordSpacing: ?SvgLength {
        get() {
            this.wordSpacingCache.get(this.attributesVersion, {=> readLength(this, "word-spacing")})
        }
        set(value) {
            writeLength(this, "word-spacing", value)
        }
    }
}

internal func readLengthArray(element: SvgElement, name: String): ?Array<SvgLength> {
    match (element.attr(name)) {
        case Some(text) => parseSvgLengthList(text)
        case None => None
    }
}

internal func writeLengthArray(element: SvgElement, name: String, value: ?Array<SvgLength>): Unit {
    match (value) {
        case Some(list) => element.setAttr(name, formatSvgLengthList(list))
        case None => element.removeAttr(name)
    }
}

internal func readNumberArray(element: SvgElement, name: String): ?Array<Float64> {
    match (element.attr(name)) {
        case Some(text) =>
            let trimmed = text.trimAscii()
            if (trimmed.size == 0) {
                None
            } else {
                tryParseSvgNumberArray(trimmed)
            }
        case None => None
    }
}

internal func tryParseSvgNumberArray(text: String): ?Array<Float64> {
    try {
        Some(SvgNumberList.parse(text).values)
    } catch (_: SvgException) {
        None
    }
}

internal func formatSvgNumberArray(values: Array<Float64>): String {
    let out = StringBuilder()
    for (index in 0..values.size) {
        if (index > 0) {
            out.append(",")
        }
        out.append(formatSvgNumber(values[index]))
    }
    out.toString()
}
