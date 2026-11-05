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

/** 计算样式属性的来源，按优先级从低到高。 */
public enum CssStyleSource <: Equatable<CssStyleSource> & ToString {
    | Default
    | Presentation
    | Sheet
    | Inline
    | Important

    public operator func ==(that: CssStyleSource): Bool {
        match ((this, that)) {
            case (Default, Default) => true
            case (Presentation, Presentation) => true
            case (Sheet, Sheet) => true
            case (Inline, Inline) => true
            case (Important, Important) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Default => "Default"
            case Presentation => "Presentation"
            case Sheet => "Sheet"
            case Inline => "Inline"
            case Important => "Important"
        }
    }

    internal func rank(): Int64 {
        match (this) {
            case Default => 0
            case Presentation => 1
            case Sheet => 2
            case Inline => 3
            case Important => 4
        }
    }
}

/** 一个受支持属性的元数据。 */
internal struct SvgPropertySpec {
    let name: String
    let inherited: Bool
    let initial: String

    init(name: String, inherited: Bool, initial: String) {
        this.name = name
        this.inherited = inherited
        this.initial = initial
    }
}

/** 属性元数据表。表外属性不进入计算样式。 */
internal let SVG_PROPERTY_TABLE: Array<SvgPropertySpec> = [
    SvgPropertySpec("fill", true, "black"),
    SvgPropertySpec("fill-opacity", true, "1"),
    SvgPropertySpec("fill-rule", true, "nonzero"),
    SvgPropertySpec("stroke", true, "none"),
    SvgPropertySpec("stroke-opacity", true, "1"),
    SvgPropertySpec("stroke-width", true, "1"),
    SvgPropertySpec("stroke-linecap", true, "butt"),
    SvgPropertySpec("stroke-linejoin", true, "miter"),
    SvgPropertySpec("stroke-miterlimit", true, "4"),
    SvgPropertySpec("stroke-dasharray", true, "none"),
    SvgPropertySpec("stroke-dashoffset", true, "0"),
    SvgPropertySpec("opacity", false, "1"),
    SvgPropertySpec("color", true, "black"),
    SvgPropertySpec("font-family", true, "sans-serif"),
    SvgPropertySpec("font-size", true, "16px"),
    SvgPropertySpec("font-weight", true, "normal"),
    SvgPropertySpec("font-style", true, "normal"),
    SvgPropertySpec("text-anchor", true, "start"),
    SvgPropertySpec("letter-spacing", true, "0"),
    SvgPropertySpec("word-spacing", true, "0"),
    SvgPropertySpec("visibility", true, "visible"),
    SvgPropertySpec("display", false, "inline"),
    SvgPropertySpec("clip-path", false, "none"),
    SvgPropertySpec("mask", false, "none"),
    SvgPropertySpec("clip-rule", true, "nonzero"),
    SvgPropertySpec("stop-color", false, "black"),
    SvgPropertySpec("stop-opacity", false, "1")
]

internal func findSvgPropertySpec(name: String): ?SvgPropertySpec {
    for (spec in SVG_PROPERTY_TABLE) {
        if (spec.name == name) {
            return Some(spec)
        }
    }
    None
}

/**
 * 计算样式快照：规范化字符串值 + 类型化 getter。
 *
 * 对象只读；`get` 返回值经过颜色 / 长度 / 枚举规范化，可直接用于比较与渲染。
 */
public class SvgComputedStyle <: ToString {
    private let values: HashMap<String, String>
    private let sources: HashMap<String, CssStyleSource>
    public let source: CssStyleSource

    internal init(values: HashMap<String, String>, sources: HashMap<String, CssStyleSource>, source: CssStyleSource) {
        this.values = values
        this.sources = sources
        this.source = source
    }

    public func get(name: String): ?String {
        this.values.get(name)
    }

    public func has(name: String): Bool {
        this.values.get(name).isSome()
    }

    public func sourceOf(name: String): CssStyleSource {
        this.sources.get(name) ?? CssStyleSource.Default
    }

    public func fill(): SvgPaint {
        parsePaintOrNone(this.get("fill"))
    }

    public func stroke(): SvgPaint {
        parsePaintOrNone(this.get("stroke"))
    }

    public func strokeWidth(): SvgLength {
        parseLengthOrDefault(this.get("stroke-width"), SvgLength(1.0))
    }

    public func opacity(): Float64 {
        tryParseSvgFloat(this.get("opacity") ?? "1") ?? 1.0
    }

    public func fillOpacity(): Float64 {
        tryParseSvgFloat(this.get("fill-opacity") ?? "1") ?? 1.0
    }

    public func strokeOpacity(): Float64 {
        tryParseSvgFloat(this.get("stroke-opacity") ?? "1") ?? 1.0
    }

    public func color(): SvgColor {
        match (this.get("color")) {
            case Some(text) => SvgColor.tryParse(text) ?? SvgColor.Black
            case None => SvgColor.Black
        }
    }

    public func fontFamily(): String {
        this.get("font-family") ?? "sans-serif"
    }

    public func fontSize(): SvgLength {
        parseLengthOrDefault(this.get("font-size"), SvgLength(16.0, unit: SvgLengthUnit.Px))
    }

    public func fontWeight(): String {
        this.get("font-weight") ?? "normal"
    }

    public func fontStyle(): String {
        this.get("font-style") ?? "normal"
    }

    public func fillRule(): SvgFillRule {
        SvgFillRule.fromName(this.get("fill-rule") ?? "nonzero") ?? SvgFillRule.Nonzero
    }

    public func clipRule(): SvgFillRule {
        SvgFillRule.fromName(this.get("clip-rule") ?? "nonzero") ?? SvgFillRule.Nonzero
    }

    public func strokeLineCap(): SvgLineCap {
        SvgLineCap.fromName(this.get("stroke-linecap") ?? "butt") ?? SvgLineCap.Butt
    }

    public func strokeLineJoin(): SvgLineJoin {
        SvgLineJoin.fromName(this.get("stroke-linejoin") ?? "miter") ?? SvgLineJoin.Miter
    }

    public func strokeMiterLimit(): Float64 {
        tryParseSvgFloat(this.get("stroke-miterlimit") ?? "4") ?? 4.0
    }

    public func strokeDashArray(): Array<SvgLength> {
        match (this.get("stroke-dasharray")) {
            case Some(text) =>
                if (text.trimAscii().toAsciiLower() == "none") {
                    Array<SvgLength>()
                } else {
                    parseSvgLengthList(text) ?? Array<SvgLength>()
                }
            case None => Array<SvgLength>()
        }
    }

    public func strokeDashOffset(): SvgLength {
        parseLengthOrDefault(this.get("stroke-dashoffset"), SvgLength(0.0))
    }

    public func textAnchor(): SvgTextAnchor {
        SvgTextAnchor.fromName(this.get("text-anchor") ?? "start") ?? SvgTextAnchor.Start
    }

    public func letterSpacing(): SvgLength {
        parseLengthOrDefault(this.get("letter-spacing"), SvgLength(0.0))
    }

    public func wordSpacing(): SvgLength {
        parseLengthOrDefault(this.get("word-spacing"), SvgLength(0.0))
    }

    public func visibility(): String {
        this.get("visibility") ?? "visible"
    }

    public func display(): String {
        this.get("display") ?? "inline"
    }

    public func stopColor(): SvgColor {
        match (this.get("stop-color")) {
            case Some(text) => SvgColor.tryParse(text) ?? SvgColor.Black
            case None => SvgColor.Black
        }
    }

    public func stopOpacity(): Float64 {
        tryParseSvgFloat(this.get("stop-opacity") ?? "1") ?? 1.0
    }

    public func toString(): String {
        let out = StringBuilder()
        for (index in 0..SVG_PROPERTY_TABLE.size) {
            let spec = SVG_PROPERTY_TABLE[index]
            if (index > 0) {
                out.append("; ")
            }
            out.append(spec.name)
            out.append(": ")
            out.append(this.values.get(spec.name) ?? spec.initial)
        }
        out.toString()
    }
}

/** 以元素身份为键的计算样式表。 */
public class SvgComputedStyleTree {
    private let styles = HashMap<Int64, SvgComputedStyle>()

    internal func put(element: SvgElement, style: SvgComputedStyle): Unit {
        this.styles[element.identity] = style
    }

    public func get(element: SvgElement): ?SvgComputedStyle {
        this.styles.get(element.identity)
    }

    public prop size: Int64 {
        get() {
            this.styles.size
        }
    }
}

private func parsePaintOrNone(text: ?String): SvgPaint {
    match (text) {
        case Some(value) => tryParseSvgPaint(value) ?? SvgPaint.None
        case None => SvgPaint.None
    }
}

private func parseLengthOrDefault(text: ?String, fallback: SvgLength): SvgLength {
    match (text) {
        case Some(value) => SvgLength.tryParse(value) ?? fallback
        case None => fallback
    }
}
