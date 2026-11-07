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
import std.sync.AtomicInt64
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
    SvgPropertySpec("pointer-events", true, "auto"),
    SvgPropertySpec("cursor", true, "auto"),
    SvgPropertySpec("shape-rendering", true, "auto"),
    SvgPropertySpec("text-rendering", true, "auto"),
    SvgPropertySpec("color-rendering", true, "auto"),
    SvgPropertySpec("color-interpolation", true, "auto"),
    SvgPropertySpec("color-profile", false, "auto"),
    SvgPropertySpec("clip-path", false, "none"),
    SvgPropertySpec("mask", false, "none"),
    SvgPropertySpec("clip-rule", true, "nonzero"),
    SvgPropertySpec("stop-color", false, "black"),
    SvgPropertySpec("stop-opacity", false, "1"),
    SvgPropertySpec("image-rendering", true, "auto"),
    SvgPropertySpec("filter", false, "none"),
    SvgPropertySpec("marker-start", true, "none"),
    SvgPropertySpec("marker-mid", true, "none"),
    SvgPropertySpec("marker-end", true, "none"),
    SvgPropertySpec("clip", false, "none"),
    SvgPropertySpec("overflow", false, "hidden"),
    SvgPropertySpec("vector-effect", false, "none"),
    SvgPropertySpec("dominant-baseline", true, "auto"),
    SvgPropertySpec("alignment-baseline", true, "auto"),
    SvgPropertySpec("baseline-shift", true, "baseline"),
    SvgPropertySpec("text-decoration", false, "none"),
    SvgPropertySpec("writing-mode", true, "lr-tb"),
    SvgPropertySpec("x", false, "0"),
    SvgPropertySpec("y", false, "0"),
    SvgPropertySpec("width", false, "auto"),
    SvgPropertySpec("height", false, "auto"),
    SvgPropertySpec("cx", false, "0"),
    SvgPropertySpec("cy", false, "0"),
    SvgPropertySpec("r", false, "0"),
    SvgPropertySpec("rx", false, "auto"),
    SvgPropertySpec("ry", false, "auto"),
    SvgPropertySpec("paint-order", true, "fill stroke markers"),
    SvgPropertySpec("mix-blend-mode", false, "normal"),
    SvgPropertySpec("isolation", false, "auto"),
    SvgPropertySpec("transform-origin", false, "0 0"),
    SvgPropertySpec("transform-box", false, "view-box"),
    SvgPropertySpec("direction", true, "ltr"),
    SvgPropertySpec("unicode-bidi", false, "normal"),
    SvgPropertySpec("font-kerning", true, "auto"),
    SvgPropertySpec("font-stretch", true, "normal"),
    SvgPropertySpec("font-variant", true, "normal"),
    SvgPropertySpec("font-variant-ligatures", true, "normal"),
    SvgPropertySpec("font-size-adjust", true, "none"),
    SvgPropertySpec("font-feature-settings", true, "normal"),
    SvgPropertySpec("text-decoration-line", false, "none"),
    SvgPropertySpec("text-decoration-style", false, "solid"),
    SvgPropertySpec("text-decoration-color", false, "currentColor"),
    SvgPropertySpec("text-decoration-thickness", false, "auto"),
    SvgPropertySpec("text-underline-position", true, "auto"),
    SvgPropertySpec("pathLength", false, "0")
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
    /** 含 `var()` 的属性原始表达式；供子元素用自身自定义属性重新展开。 */
    private let varExpressions: HashMap<String, String>
    public let source: CssStyleSource

    internal init(
        values: HashMap<String, String>,
        sources: HashMap<String, CssStyleSource>,
        source: CssStyleSource,
        varExpressions!: HashMap<String, String> = HashMap<String, String>()
    ) {
        this.values = values
        this.sources = sources
        this.source = source
        this.varExpressions = varExpressions
    }

    public func get(name: String): ?String {
        this.values.get(name)
    }

    public func has(name: String): Bool {
        this.values.get(name).isSome()
    }

    /** 自定义属性（`--*`）键值对；保持声明时的原始大小写。 */
    internal func customProperties(): Array<(String, String)> {
        let result = ArrayList<(String, String)>()
        for ((key, value) in this.values) {
            if (key.startsWith("--")) {
                result.add((key, value))
            }
        }
        result.toArray()
    }

    /** 该属性的 `var()` 原始表达式；无则返回 `None`。 */
    internal func varExpressionOf(name: String): ?String {
        this.varExpressions.get(name)
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

    /** 命中测试使用的 `pointer-events` 值；未知值回退 `auto`。 */
    public func pointerEvents(): SvgPointerEvents {
        SvgPointerEvents.fromName(this.get("pointer-events") ?? "auto") ?? SvgPointerEvents.Auto
    }

    /** 光标关键字；M6 不加载资源。 */
    public func cursor(): String {
        this.get("cursor") ?? "auto"
    }

    public func shapeRendering(): SvgShapeRendering {
        SvgShapeRendering.fromName(this.get("shape-rendering") ?? "auto") ?? SvgShapeRendering.Auto
    }

    public func textRendering(): SvgTextRendering {
        SvgTextRendering.fromName(this.get("text-rendering") ?? "auto") ?? SvgTextRendering.Auto
    }

    public func colorRendering(): SvgColorRendering {
        SvgColorRendering.fromName(this.get("color-rendering") ?? "auto") ?? SvgColorRendering.Auto
    }

    public func colorInterpolation(): SvgColorInterpolation {
        SvgColorInterpolation.fromName(this.get("color-interpolation") ?? "auto") ??
            SvgColorInterpolation.Auto
    }

    /** `@color-profile` 名称；`auto` / `sRGB` / 已声明名称。 */
    public func colorProfile(): String {
        this.get("color-profile") ?? "auto"
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

    /** `<image>` 的取样质量；未设置时按 `auto`。 */
    public func imageRendering(): SvgImageRendering {
        SvgImageRendering.fromName(this.get("image-rendering") ?? "auto") ?? SvgImageRendering.Auto
    }

    /** `clip` 解析结果；`none` / `auto` / 非法值返回 `None`。 */
    public func clipRect(): ?SvgClipRect {
        match (this.get("clip")) {
            case Some(text) => SvgClipProperty.parse(text)
            case None => None
        }
    }

    public func overflowMode(): SvgOverflow {
        SvgOverflow.fromName(this.get("overflow") ?? "hidden") ?? SvgOverflow.Hidden
    }

    public func vectorEffect(): SvgVectorEffect {
        SvgVectorEffect.fromName(this.get("vector-effect") ?? "none") ?? SvgVectorEffect.NoEffect
    }

    public func dominantBaseline(): SvgDominantBaseline {
        SvgDominantBaseline.fromName(this.get("dominant-baseline") ?? "auto") ??
            SvgDominantBaseline.Auto
    }

    public func alignmentBaseline(): SvgAlignmentBaseline {
        SvgAlignmentBaseline.fromName(this.get("alignment-baseline") ?? "auto") ??
            SvgAlignmentBaseline.Auto
    }

    public func baselineShift(): SvgBaselineShift {
        SvgBaselineShift.fromName(this.get("baseline-shift") ?? "baseline") ??
            SvgBaselineShift.Baseline
    }

    public func textDecoration(): SvgTextDecoration {
        if (this.sourceOf("text-decoration-line") != CssStyleSource.Default) {
            match (this.get("text-decoration-line")) {
                case Some(value) =>
                    match (parseSvgDecorationLines(value)) {
                        case Some(parsed) => return parsed
                        case None => ()
                    }
                case None => ()
            }
        }
        parseSvgDecorationLines(this.get("text-decoration") ?? "none") ?? SvgTextDecoration.none
    }

    public func fontStretch(): SvgFontStretch {
        SvgFontStretch.fromName(this.get("font-stretch") ?? "normal") ?? SvgFontStretch.Normal
    }

    /** `font-variant` 的 caps 关键字；M6 只支持 `normal` / `small-caps`。 */
    public func fontVariantCaps(): String {
        let lower = (this.get("font-variant") ?? "normal").trimAscii().toAsciiLower()
        if (lower.contains("small-caps")) {
            return "small-caps"
        }
        "normal"
    }

    /** `font-variant-ligatures` 的规范值；多值取首个可识别项。 */
    public func fontVariantLigatures(): String {
        let lower = (this.get("font-variant-ligatures") ?? "normal").trimAscii().toAsciiLower()
        for (value in ["none", "common-ligatures", "discretionary-ligatures", "historical-ligatures", "contextual"]) {
            if (lower.contains(value)) {
                return value
            }
        }
        "normal"
    }

    public func fontSizeAdjust(): ?Float64 {
        match (this.get("font-size-adjust")) {
            case Some(text) =>
                if (text.trimAscii().toAsciiLower() == "none") {
                    return Option<Float64>.None
                }
                match (tryParseSvgFloat(text)) {
                    case Some(value) => if (value > 0.0 && isFiniteSvgNumber(value)) {
                        Some(value)
                    } else {
                        Option<Float64>.None
                    }
                    case None => Option<Float64>.None
                }
            case None => Option<Float64>.None
        }
    }

    public func fontFeatures(): SvgFontFeatures {
        SvgFontFeatures.fromStyle(this)
    }

    public func textDecorationStyle(): SvgTextDecorationStyle {
        if (this.sourceOf("text-decoration-style") != CssStyleSource.Default) {
            match (this.get("text-decoration-style")) {
                case Some(text) =>
                    match (SvgTextDecorationStyle.fromName(text)) {
                        case Some(value) => return value
                        case None => ()
                    }
                case None => ()
            }
        }
        let shorthand = (this.get("text-decoration") ?? "").toAsciiLower()
        for (name in ["dotted", "dashed", "double", "wavy"]) {
            if (shorthand.contains(name)) {
                return SvgTextDecorationStyle.fromName(name) ?? SvgTextDecorationStyle.Solid
            }
        }
        SvgTextDecorationStyle.fromName(this.get("text-decoration-style") ?? "solid") ??
            SvgTextDecorationStyle.Solid
    }

    public func textDecorationColor(): ?SvgColor {
        if (this.sourceOf("text-decoration-color") != CssStyleSource.Default) {
            return parseSvgDecorationColor(this.get("text-decoration-color"), this.color())
        }
        if (this.sourceOf("text-decoration") != CssStyleSource.Default) {
            match (svgDecorationShorthandColor(this.get("text-decoration") ?? "", this.color())) {
                case Some(value) => return Some(value)
                case None => ()
            }
        }
        Option<SvgColor>.None
    }

    public func textDecorationThickness(): ?SvgLength {
        if (this.sourceOf("text-decoration-thickness") != CssStyleSource.Default) {
            return parseSvgDecorationThickness(this.get("text-decoration-thickness"))
        }
        if (this.sourceOf("text-decoration") != CssStyleSource.Default) {
            match (svgDecorationShorthandThickness(this.get("text-decoration") ?? "")) {
                case Some(value) => return Some(value)
                case None => ()
            }
        }
        match (this.get("text-decoration-thickness")) {
            case Some(text) => parseSvgDecorationThickness(Some(text))
            case None => Option<SvgLength>.None
        }
    }

    public func textUnderlinePosition(): SvgTextUnderlinePosition {
        SvgTextUnderlinePosition.fromName(this.get("text-underline-position") ?? "auto") ??
            SvgTextUnderlinePosition.Auto
    }

    public func textDecorationSpec(): SvgTextDecorationSpec {
        SvgTextDecorationSpec.fromStyle(this)
    }

    /** `pathLength` 声明值；`0` 表示未声明。 */
    public func pathLengthValue(): Float64 {
        match (tryParseSvgFloat(this.get("pathLength") ?? "0")) {
            case Some(value) => if (value > 0.0 && isFiniteSvgNumber(value)) { value } else { 0.0 }
            case None => 0.0
        }
    }

    public func writingMode(): SvgWritingMode {
        SvgWritingMode.fromName(this.get("writing-mode") ?? "lr-tb") ?? SvgWritingMode.LrTb
    }

    public func direction(): SvgDirection {
        SvgDirection.fromName(this.get("direction") ?? "ltr") ?? SvgDirection.Ltr
    }

    public func unicodeBidi(): SvgUnicodeBidi {
        SvgUnicodeBidi.fromName(this.get("unicode-bidi") ?? "normal") ?? SvgUnicodeBidi.Normal
    }

    public func fontKerning(): SvgFontKerning {
        SvgFontKerning.fromName(this.get("font-kerning") ?? "auto") ?? SvgFontKerning.Auto
    }

    /** `transform-box` 的参考盒；未知值回退 `view-box`。 */
    public func transformBox(): SvgTransformBox {
        SvgTransformBox.fromNameOrDefault(this.get("transform-box"))
    }

    /** 绘制顺序（未声明时取默认值）。 */
    public func paintOrder(): SvgPaintOrder {
        svgPaintOrderOf(this.get("paint-order"))
    }

    public func mixBlendMode(): SvgMixBlendMode {
        SvgMixBlendMode.fromNameOrDefault(this.get("mix-blend-mode"))
    }

    public func isolationIsolate(): Bool {
        this.get("isolation") == Some("isolate")
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
    /** 每次解析生成新版本，供单次渲染的 layout 缓存区分样式上下文。 */
    internal let version: Int64 = SvgComputedStyleTree.nextVersion.fetchAdd(1)
    private static let nextVersion = AtomicInt64(1)
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

/** 容错解析装饰线关键字；忽略 style / color / thickness 关键字。 */
internal func parseSvgDecorationLines(text: String): ?SvgTextDecoration {
    let lower = text.trimAscii().toAsciiLower()
    if (lower.size == 0) {
        return Option<SvgTextDecoration>.None
    }
    if (lower == "none") {
        return Some(SvgTextDecoration.none)
    }
    var underline = false
    var overline = false
    var lineThrough = false
    for (word in splitCssWhitespaceWords(lower)) {
        match (word) {
            case "underline" => underline = true
            case "overline" => overline = true
            case "line-through" => lineThrough = true
            case _ => ()
        }
    }
    if (!underline && !overline && !lineThrough) {
        return Option<SvgTextDecoration>.None
    }
    Some(SvgTextDecoration(underline: underline, overline: overline, lineThrough: lineThrough))
}

/** 解析 `text-decoration-color` 值；`currentColor` 解析为当前 `color`。 */
private func parseSvgDecorationColor(text: ?String, currentColor: SvgColor): ?SvgColor {
    match (text) {
        case Some(value) =>
            let lower = value.trimAscii().toAsciiLower()
            if (lower.size == 0 || lower == "auto") {
                return Option<SvgColor>.None
            }
            if (lower == "currentcolor") {
                return Some(currentColor)
            }
            SvgColor.tryParse(value)
        case None => Option<SvgColor>.None
    }
}

/** 解析 `text-decoration-thickness`；`auto` / 非法值返回 `None`。 */
private func parseSvgDecorationThickness(text: ?String): ?SvgLength {
    match (text) {
        case Some(value) =>
            let lower = value.trimAscii().toAsciiLower()
            if (lower.size == 0 || lower == "auto" || lower == "from-font") {
                return Option<SvgLength>.None
            }
            SvgLength.tryParse(value)
        case None => Option<SvgLength>.None
    }
}

/** 从 `text-decoration` 简写中提取颜色 token。 */
private func svgDecorationShorthandColor(text: String, currentColor: SvgColor): ?SvgColor {
    for (word in splitCssWhitespaceWords(text.trimAscii().toAsciiLower())) {
        if (word == "currentcolor") {
            return Some(currentColor)
        }
        match (SvgColor.tryParse(word)) {
            case Some(value) => return Some(value)
            case None => ()
        }
    }
    Option<SvgColor>.None
}

/** 从 `text-decoration` 简写中提取厚度 token。 */
private func svgDecorationShorthandThickness(text: String): ?SvgLength {
    for (word in splitCssWhitespaceWords(text.trimAscii().toAsciiLower())) {
        match (word) {
            case "none" | "underline" | "overline" | "line-through" | "solid" | "double" |
                "dotted" | "dashed" | "wavy" | "auto" | "from-font" => continue
            case _ => ()
        }
        match (SvgLength.tryParse(word)) {
            case Some(value) => return Some(value)
            case None => ()
        }
    }
    Option<SvgLength>.None
}
