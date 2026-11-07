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

private let CSS_STYLE_ORDER_CAP = 1000000
private let CSS_INLINE_ORDER = 2000000000
private let CSS_ORIGIN_PRESENTATION = 1
private let CSS_ORIGIN_SHEET = 2
private let CSS_ORIGIN_INLINE = 3

/** 一条候选声明及其级联排序键。 */
private class CssCandidate {
    let value: String
    let important: Bool
    let origin: Int64
    let specificity: CssSpecificity
    let order: Int64

    init(value: String, important: Bool, origin: Int64, specificity: CssSpecificity, order: Int64) {
        this.value = value
        this.important = important
        this.origin = origin
        this.specificity = specificity
        this.order = order
    }

    func beats(that: CssCandidate): Bool {
        if (this.important != that.important) {
            return this.important
        }
        if (this.origin != that.origin) {
            return this.origin > that.origin
        }
        let compared = this.specificity.compareTo(that.specificity)
        if (compared != 0) {
            return compared > 0
        }
        this.order > that.order
    }
}

/**
 * CSS 级联与计算样式解析器。
 *
 * `compute` 收集文档中的 `<style>`，与构造时传入的外部样式表合并（外部在前），
 * 再按 `(important, origin, specificity, order)` 逐属性取胜出值；
 * 计算过程只读 `SvgElement.attributes`，不写回文档。
 */
public class SvgStyleResolver <: ToString {
    public let warnings = ArrayList<String>()
    /** 本次解析得到的 `@font-face` 别名，按源顺序。 */
    public let fontFaces = ArrayList<CssFontFaceRule>()
    private let sheet: CssStyleSheet
    private let styleCache = HashMap<String, CssStyleSheet>()
    private let inlineCache = HashMap<String, Array<CssDeclaration>>()
    private var mergedRules: Array<CssRule> = Array<CssRule>()
    private var mergedFontFaces: Array<CssFontFaceRule> = Array<CssFontFaceRule>()
    private var selectorIndex: ?CssSelectorIndex = None
    private var preparedRoot: ?Int64 = None
    private var hasPrepared: Bool = false
    /** `@media` 与百分比长度求值基准；缺省 300×150。 */
    private var mediaWidth: Float64 = 300.0
    private var mediaHeight: Float64 = 150.0
    /** 本次求值的静态交互状态；空状态让 `:hover` / `:focus` 永不匹配。 */
    private var interaction: SvgInteractionState = SvgInteractionState.empty()
    /** 本次求值可见的 `@color-profile` 名称。 */
    private let declaredColorProfiles = HashMap<String, Bool>()
    /** 非 sRGB profile 的 warning 去重。 */
    private let warnedColorProfiles = HashMap<String, Bool>()

    public init(sheet!: CssStyleSheet = CssStyleSheet.empty()) {
        this.sheet = sheet
    }

    public func compute(root: SvgElement): SvgComputedStyleTree {
        this.compute(root, mediaWidth: 300.0, mediaHeight: 150.0)
    }

    /** 以给定逻辑视口求值 `@media` 与百分比几何长度。 */
    public func compute(
        root: SvgElement,
        interaction!: SvgInteractionState = SvgInteractionState.empty(),
        mediaWidth!: Float64,
        mediaHeight!: Float64 = 150.0
    ): SvgComputedStyleTree {
        this.mediaWidth = mediaWidth
        this.mediaHeight = mediaHeight
        this.interaction = interaction
        this.warnings.clear()
        this.prepare(Some(root))
        this.fontFaces.clear()
        for (face in this.mergedFontFaces) {
            this.fontFaces.add(face)
        }
        let tree = SvgComputedStyleTree()
        this.computeSubtree(root, Option<SvgComputedStyle>.None, tree)
        tree
    }

    /**
     * 计算单个元素。`parent` 为父元素的计算样式；
     * 独立调用时只使用外部样式表，不回溯真实祖先。
     */
    public func computeElement(element: SvgElement, parent: ?SvgComputedStyle): SvgComputedStyle {
        this.computeElement(element, parent, mediaWidth: 300.0, mediaHeight: 150.0)
    }

    /** 计算单个元素，并以给定视口求值 `@media` 与百分比几何长度。 */
    public func computeElement(
        element: SvgElement,
        parent: ?SvgComputedStyle,
        interaction!: SvgInteractionState = SvgInteractionState.empty(),
        mediaWidth!: Float64,
        mediaHeight!: Float64 = 150.0
    ): SvgComputedStyle {
        this.mediaWidth = mediaWidth
        this.mediaHeight = mediaHeight
        this.interaction = interaction
        this.prepare(Option<SvgElement>.None)
        this.cascade(element, parent)
    }

    public func toString(): String {
        "SvgStyleResolver(rules: ${this.mergedRules.size})"
    }

    private func computeSubtree(
        element: SvgElement,
        parent: ?SvgComputedStyle,
        tree: SvgComputedStyleTree
    ): Unit {
        let style = this.cascade(element, parent)
        tree.put(element, style)
        for (node in element.children) {
            match (node) {
                case ElementNode(child) => this.computeSubtree(child, Some(style), tree)
                case _ => ()
            }
        }
    }

    private func prepare(root: ?SvgElement): Unit {
        let key: ?Int64 = match (root) {
            case Some(element) => Some(element.identity)
            case None => None
        }
        if (this.hasPrepared && this.preparedRoot == key) {
            return
        }
        let rules = ArrayList<CssRule>()
        let faces = ArrayList<CssFontFaceRule>()
        this.declaredColorProfiles.clear()
        for (profile in this.sheet.colorProfiles) {
            this.declaredColorProfiles[profile.name] = true
        }
        for (rule in this.sheet.rules) {
            rules.add(CssRule(rule.selectors, rule.declarations, rule.order, media: rule.media))
        }
        for (face in this.sheet.fontFaces) {
            faces.add(face)
        }
        match (root) {
            case Some(element) =>
                let texts = ArrayList<String>()
                collectCssStyleTexts(element, texts)
                var styleIndex = 1
                for (text in texts) {
                    let parsed = this.parseStyleText(text)
                    for (face in parsed.fontFaces) {
                        faces.add(face)
                    }
                    for (profile in parsed.colorProfiles) {
                        this.declaredColorProfiles[profile.name] = true
                    }
                    for (rule in parsed.rules) {
                        rules.add(
                            CssRule(
                                rule.selectors,
                                rule.declarations,
                                styleIndex * CSS_STYLE_ORDER_CAP + rule.order,
                                media: rule.media
                            )
                        )
                    }
                    styleIndex++
                }
            case None => ()
        }
        this.mergedRules = rules.toArray()
        this.mergedFontFaces = faces.toArray()
        this.selectorIndex = CssSelectorIndex(this.mergedRules)
        this.preparedRoot = key
        this.hasPrepared = true
    }

    private func parseStyleText(text: String): CssStyleSheet {
        match (this.styleCache.get(text)) {
            case Some(sheet) => sheet
            case None =>
                let parsed = CssStyleSheet.parse(text, this.warnings)
                this.styleCache[text] = parsed
                parsed
        }
    }

    private func inlineDeclarations(text: String): Array<CssDeclaration> {
        match (this.inlineCache.get(text)) {
            case Some(declarations) => declarations
            case None =>
                let parsed = CssStyleSheet.parse("*{" + text + "}", this.warnings)
                let declarations = if (parsed.rules.size > 0) {
                    parsed.rules[0].declarations
                } else {
                    Array<CssDeclaration>()
                }
                this.inlineCache[text] = declarations
                declarations
        }
    }

    private func cascade(element: SvgElement, parent: ?SvgComputedStyle): SvgComputedStyle {
        let best = HashMap<String, CssCandidate>()
        let customBest = HashMap<String, CssCandidate>()
        let elementPath = element.elementPath()
        this.considerPresentation(element, best)
        this.considerSheet(element, best, customBest)
        this.considerInline(element, best, customBest)

        let custom = HashMap<String, String>()
        match (parent) {
            case Some(parentStyle) =>
                for ((name, value) in parentStyle.customProperties()) {
                    custom[name] = value
                }
            case None => ()
        }
        for ((name, candidate) in customBest) {
            custom[name] = candidate.value
        }

        let values = HashMap<String, String>()
        let sources = HashMap<String, CssStyleSource>()
        let varExpressions = HashMap<String, String>()
        var overall = CssStyleSource.Default
        let fontSpec = SvgPropertySpec("font-size", true, "16px")
        var fontSizeRaw = "16px"
        var fontSizeExpression: ?String = None
        match (best.get("font-size")) {
            case Some(candidate) =>
                fontSizeRaw = candidate.value
                if (containsCssVariable(candidate.value)) {
                    fontSizeExpression = Some(candidate.value)
                }
            case None =>
                match (parent) {
                    case Some(parentStyle) =>
                        match (parentStyle.varExpressionOf("font-size")) {
                            case Some(expression) =>
                                fontSizeRaw = expression
                                fontSizeExpression = Some(expression)
                            case None => fontSizeRaw = parentStyle.get("font-size") ?? "16px"
                        }
                    case None => ()
                }
        }
        match (expandCustomValue(fontSizeRaw, custom)) {
            case Some(text) => fontSizeRaw = text
            case None =>
                this.warnings.add("元素「${elementPath}」属性「font-size」的 var() 无法解析，已回退")
                fontSizeRaw = ""
        }
        fontSizeRaw = resolveCssKeyword(fontSizeRaw, fontSpec, parent)
        var normalizedFontSize = this.normalizeValue(
            "font-size",
            fontSizeRaw,
            parent,
            elementPath,
            16.0
        )
        if (normalizedFontSize.isNone()) {
            let original = fontSizeRaw
            fontSizeExpression = None
            let inherited = match (parent) {
                case Some(parentStyle) => parentStyle.get("font-size") ?? "16px"
                case None => "16px"
            }
            normalizedFontSize = this.normalizeValue("font-size", inherited, parent, elementPath, 16.0)
            if (normalizedFontSize.isNone()) {
                normalizedFontSize = Some("16px")
            }
            this.warnings.add("元素「${elementPath}」属性「font-size」的值「${original}」不合法，已回退")
        }
        let resolvedFontSize = normalizedFontSize ?? "16px"
        let fontSizePx = (SvgLength.tryParse(resolvedFontSize) ?? SvgLength(16.0)).value
        for (spec in SVG_PROPERTY_TABLE) {
            let name = spec.name
            var raw = spec.initial
            var rawExpression: ?String = None
            var source = CssStyleSource.Default
            match (best.get(name)) {
                case Some(candidate) =>
                    raw = candidate.value
                    if (containsCssVariable(candidate.value)) {
                        rawExpression = Some(candidate.value)
                    }
                    source = if (candidate.important) {
                        CssStyleSource.Important
                    } else {
                        originSource(candidate.origin)
                    }
                case None =>
                    if (spec.inherited) {
                        match (parent) {
                            case Some(parentStyle) =>
                                match (parentStyle.varExpressionOf(name)) {
                                    case Some(expression) =>
                                        raw = expression
                                        rawExpression = Some(expression)
                                    case None => raw = parentStyle.get(name) ?? spec.initial
                                }
                            case None => raw = spec.initial
                        }
                    }
            }
            match (expandCustomValue(raw, custom)) {
                case Some(text) => raw = text
                case None =>
                    this.warnings.add("元素「${elementPath}」属性「${name}」的 var() 无法解析，已回退")
                    raw = ""
                    rawExpression = None
            }
            raw = resolveCssKeyword(raw, spec, parent)
            var normalized = if (name == "font-size") {
                normalizedFontSize
            } else {
                this.normalizeValue(name, raw, parent, elementPath, fontSizePx)
            }
            match (normalized) {
                case Some(_) => ()
                case None =>
                    let original = raw
                    rawExpression = None
                    if (spec.inherited) {
                        match (parent) {
                            case Some(parentStyle) => raw = parentStyle.get(name) ?? spec.initial
                            case None => raw = spec.initial
                        }
                    } else {
                        raw = spec.initial
                    }
                    normalized = this.normalizeValue(name, raw, parent, elementPath, fontSizePx)
                    if (normalized.isNone()) {
                        normalized = this.normalizeValue(name, spec.initial, parent, elementPath, fontSizePx)
                    }
                    this.warnings.add("元素「${elementPath}」属性「${name}」的值「${original}」不合法，已回退")
            }
            values[name] = normalized ?? spec.initial
            sources[name] = source
            match (rawExpression) {
                case Some(expression) => varExpressions[name] = expression
                case None => ()
            }
            if (source.rank() > overall.rank()) {
                overall = source
            }
        }
        if (normalizedFontSize.isNone()) {
            fontSizeExpression = None
        }
        match (fontSizeExpression) {
            case Some(expression) => varExpressions["font-size"] = expression
            case None => ()
        }
        for ((name, value) in custom) {
            values[name] = value
        }
        let color = values.get("color") ?? "#000000"
        for (name in ["fill", "stroke", "stop-color"]) {
            if (values.get(name) == Some("currentColor")) {
                values[name] = color
            }
        }
        SvgComputedStyle(values, sources, overall, varExpressions: varExpressions)
    }

    private func considerPresentation(element: SvgElement, best: HashMap<String, CssCandidate>): Unit {
        for (spec in SVG_PROPERTY_TABLE) {
            match (element.attr(spec.name)) {
                case Some(value) =>
                    considerCssCandidate(
                        best,
                        spec.name,
                        CssCandidate(value, false, CSS_ORIGIN_PRESENTATION, CssSpecificity.zero, 0)
                    )
                case None => ()
            }
        }
    }

    private func considerSheet(
        element: SvgElement,
        best: HashMap<String, CssCandidate>,
        customBest: HashMap<String, CssCandidate>
    ): Unit {
        let index = match (this.selectorIndex) {
            case Some(value) => value
            case None => return
        }
        for (ruleIndex in index.candidates(element)) {
            let rule = this.mergedRules[ruleIndex]
            match (rule.media) {
                case Some(media) =>
                    if (!media.matches(this.mediaWidth)) {
                        continue
                    }
                case None => ()
            }
            var matched = false
            var specificity = CssSpecificity.zero
            for (selector in rule.selectors) {
                if (selector.matches(element, this.interaction)) {
                    if (!matched || selector.specificity.compareTo(specificity) > 0) {
                        specificity = selector.specificity
                        matched = true
                    }
                }
            }
            if (!matched) {
                continue
            }
            for (declaration in rule.declarations) {
                let candidate = CssCandidate(
                    declaration.value,
                    declaration.important,
                    CSS_ORIGIN_SHEET,
                    specificity,
                    rule.order
                )
                if (declaration.property.startsWith("--")) {
                    if (declaration.value.trimAscii().size > 0) {
                        considerCssCandidate(customBest, declaration.property, candidate)
                    }
                    continue
                }
                if (findSvgPropertySpec(declaration.property).isNone()) {
                    continue
                }
                considerCssCandidate(best, declaration.property, candidate)
            }
        }
    }

    private func considerInline(
        element: SvgElement,
        best: HashMap<String, CssCandidate>,
        customBest: HashMap<String, CssCandidate>
    ): Unit {
        match (element.style) {
            case Some(text) =>
                if (text.trimAscii().size == 0) {
                    return
                }
                for (declaration in this.inlineDeclarations(text)) {
                    let candidate = CssCandidate(
                        declaration.value,
                        declaration.important,
                        CSS_ORIGIN_INLINE,
                        CssSpecificity.zero,
                        CSS_INLINE_ORDER
                    )
                    if (declaration.property.startsWith("--")) {
                        if (declaration.value.trimAscii().size > 0) {
                            considerCssCandidate(customBest, declaration.property, candidate)
                        }
                        continue
                    }
                    if (findSvgPropertySpec(declaration.property).isNone()) {
                        continue
                    }
                    considerCssCandidate(best, declaration.property, candidate)
                }
            case None => ()
        }
    }

    /** 百分比几何长度所用的视口参考；非几何属性返回 `None`。 */
    private func cssCalcPercentReference(name: String): ?Float64 {
        match (name) {
            case "x" | "width" | "cx" | "rx" => Some(this.mediaWidth)
            case "y" | "height" | "cy" | "ry" => Some(this.mediaHeight)
            case "r" => Some((this.mediaWidth + this.mediaHeight) / 2.0)
            case _ => Option<Float64>.None
        }
    }

    private func normalizeValue(
        name: String,
        raw: String,
        parent: ?SvgComputedStyle,
        elementPath: String,
        fontSizePx: Float64
    ): ?String {
        var text = raw.trimAscii()
        if (text.size == 0) {
            return None
        }
        var textLower = text.toAsciiLower()
        if (text.size > 5 && text[text.size - 1] == b')' && text[0..5].toAsciiLower() == "calc(") {
            if (!cssCalcAppliesTo(name)) {
                return None
            }
            let baseFontSize = if (name == "font-size") {
                match (parent) {
                    case Some(parentStyle) => parentStyle.fontSize().value
                    case None => 16.0
                }
            } else {
                fontSizePx
            }
            match (evaluateCssCalc(
                text[5..text.size - 1],
                baseFontSize,
                percentReference: this.cssCalcPercentReference(name)
            )) {
                case Some(value) =>
                    text = value
                    textLower = value.toAsciiLower()
                case None => return None
            }
        }
        match (name) {
            case "fill" | "stroke" => return this.normalizePaint(name, text, elementPath)
            case "color" =>
                if (textLower == "currentcolor") {
                    match (parent) {
                        case Some(parentStyle) => return Some(parentStyle.color().toString())
                        case None => return Some(SvgColor.Black.toString())
                    }
                }
                return this.normalizeColor(text)
            case "stop-color" =>
                if (textLower == "currentcolor") {
                    return Some("currentColor")
                }
                return this.normalizeColor(text)
            case "fill-opacity" | "stroke-opacity" | "opacity" | "stop-opacity" =>
                match (tryParseSvgFloat(text)) {
                    case Some(value) => return Some(formatSvgNumber(clampSvgUnit(value)))
                    case None => return None
                }
            case "stroke-miterlimit" =>
                match (tryParseSvgFloat(text)) {
                    case Some(value) => if (value < 1.0) {
                        return None
                    } else {
                        return Some(formatSvgNumber(value))
                    }
                    case None => return None
                }
            case "x" | "y" =>
                match (SvgLength.tryParse(text)) {
                    case Some(length) => return Some(length.toString())
                    case None =>
                        match (parseSvgLengthList(text)) {
                            case Some(values) => if (values.size > 1) {
                                return Some(text)
                            } else {
                                return None
                            }
                            case None => return None
                        }
                }
            case "width" | "height" | "cx" | "cy" | "r" | "rx" | "ry" =>
                if (textLower == "auto") {
                    return Some("auto")
                }
                match (SvgLength.tryParse(text)) {
                    case Some(length) => return Some(length.toString())
                    case None => return None
                }
            case "font-size" =>
                match (SvgLength.tryParse(text)) {
                    case Some(length) =>
                        match (length.unit) {
                            case Em =>
                                let base = match (parent) {
                                    case Some(parentStyle) => parentStyle.fontSize().value
                                    case None => 16.0
                                }
                                return Some(formatSvgNumber(base * length.value) + "px")
                            case Ex =>
                                let base = match (parent) {
                                    case Some(parentStyle) => parentStyle.fontSize().value
                                    case None => 16.0
                                }
                                return Some(formatSvgNumber(base * length.value / 2.0) + "px")
                            case Percent =>
                                let base = match (parent) {
                                    case Some(parentStyle) => parentStyle.fontSize().value
                                    case None => 16.0
                                }
                                return Some(formatSvgNumber(base * length.value / 100.0) + "px")
                            case _ => return Some(length.toString())
                        }
                    case None => return None
                }
            case "stroke-width" | "letter-spacing" | "word-spacing" | "stroke-dashoffset" =>
                if ((name == "letter-spacing" || name == "word-spacing") && textLower == "normal") {
                    return Some("0")
                }
                match (SvgLength.tryParse(text)) {
                    case Some(length) =>
                        return Some(resolveFontRelativeLength(length, fontSizePx))
                    case None => return None
                }
            case "stroke-dasharray" =>
                if (textLower == "none") {
                    return Some("none")
                }
                match (parseSvgLengthList(text)) {
                    case Some(list) =>
                        let out = StringBuilder()
                        for (index in 0..list.size) {
                            if (index > 0) {
                                out.append(",")
                            }
                            out.append(resolveFontRelativeLength(list[index], fontSizePx))
                        }
                        return Some(out.toString())
                    case None => return None
                }
            case "clip-path" | "mask" | "filter" | "marker-start" | "marker-mid" | "marker-end" =>
                if (textLower == "none") {
                    return Some("none")
                }
                if (textLower.size > 4 && textLower[0..4] == "url(") {
                    return Some(text)
                }
                return None
            case "clip" => return SvgClipProperty.normalize(text)
            case "overflow" =>
                match (SvgOverflow.fromName(textLower)) {
                    case Some(value) =>
                        if (value.clips()) {
                            return Some("hidden")
                        }
                        return Some("visible")
                    case None => return None
                }
            case "vector-effect" =>
                match (SvgVectorEffect.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "dominant-baseline" =>
                match (SvgDominantBaseline.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "alignment-baseline" =>
                match (SvgAlignmentBaseline.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "baseline-shift" =>
                match (SvgBaselineShift.fromName(text)) {
                    case Some(value) =>
                        match (value) {
                            case Length(length) =>
                                match (length.unit) {
                                    case Percent =>
                                        return Some(
                                            formatSvgNumber(length.value / 100.0 * fontSizePx) + "px"
                                        )
                                    case _ => return Some(resolveFontRelativeLength(length, fontSizePx))
                                }
                            case _ => return Some(value.toString())
                        }
                    case None => return None
                }
            case "text-decoration" => return normalizeSvgTextDecorationShorthand(text)
            case "writing-mode" =>
                match (SvgWritingMode.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "fill-rule" | "clip-rule" =>
                match (SvgFillRule.fromName(textLower)) {
                    case Some(rule) => return Some(rule.attrName())
                    case None => return None
                }
            case "stroke-linecap" =>
                match (SvgLineCap.fromName(textLower)) {
                    case Some(cap) => return Some(cap.attrName())
                    case None => return None
                }
            case "stroke-linejoin" =>
                match (SvgLineJoin.fromName(textLower)) {
                    case Some(join) => return Some(join.attrName())
                    case None => return None
                }
            case "text-anchor" =>
                match (SvgTextAnchor.fromName(textLower)) {
                    case Some(anchor) => return Some(anchor.attrName())
                    case None => return None
                }
            case "visibility" =>
                if (textLower == "visible" || textLower == "hidden" || textLower == "collapse") {
                    return Some(textLower)
                }
                return None
            case "pointer-events" =>
                match (SvgPointerEvents.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "cursor" => return Some(SvgCursor.parse(text, this.warnings).toString())
            case "shape-rendering" =>
                match (SvgShapeRendering.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "text-rendering" =>
                match (SvgTextRendering.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "color-rendering" =>
                match (SvgColorRendering.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "color-interpolation" =>
                match (SvgColorInterpolation.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "color-profile" => return this.normalizeColorProfile(text)
            case "display" =>
                if (textLower == "inline" || textLower == "block" || textLower == "none" || textLower == "inline-block") {
                    return Some(textLower)
                }
                return None
            case "font-family" => return text
            case "font-weight" =>
                if (textLower == "normal" || textLower == "bold" || textLower == "bolder" || textLower == "lighter") {
                    return Some(textLower)
                }
                match (tryParseSvgFloat(textLower)) {
                    case Some(value) => return Some(formatSvgNumber(value))
                    case None => return None
                }
            case "font-style" =>
                if (textLower == "normal" || textLower == "italic" || textLower == "oblique") {
                    return Some(textLower)
                }
                return None
            case "image-rendering" =>
                match (SvgImageRendering.fromName(textLower)) {
                    case Some(rendering) => return Some(rendering.toString())
                    case None => return None
                }
            case "paint-order" => return normalizeCssPaintOrder(textLower, this.warnings)
            case "mix-blend-mode" =>
                match (textLower) {
                    case "normal" | "multiply" | "screen" | "overlay" | "darken" | "lighten" |
                        "color-dodge" | "color-burn" | "hard-light" | "soft-light" | "difference" |
                        "exclusion" => return Some(textLower)
                    case _ => return None
                }
            case "isolation" =>
                if (textLower == "auto" || textLower == "isolate") {
                    return Some(textLower)
                }
                return None
            case "transform-origin" => return normalizeCssTransformOrigin(text)
            case "transform-box" =>
                match (SvgTransformBox.fromName(textLower)) {
                    case Some(box) => return Some(box.toString())
                    case None => return None
                }
            case "direction" =>
                if (textLower == "ltr" || textLower == "rtl") {
                    return Some(textLower)
                }
                return None
            case "unicode-bidi" =>
                if (textLower == "normal" || textLower == "embed" || textLower == "bidi-override") {
                    return Some(textLower)
                }
                return None
            case "font-kerning" =>
                if (textLower == "auto" || textLower == "normal" || textLower == "none") {
                    return Some(textLower)
                }
                return None
            case "font-stretch" =>
                match (SvgFontStretch.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "font-variant" =>
                if (textLower == "normal") {
                    return Some("normal")
                }
                if (textLower.contains("small-caps")) {
                    return Some("small-caps")
                }
                return None
            case "font-variant-ligatures" =>
                if (textLower == "normal" || textLower == "none" ||
                    textLower.contains("common-ligatures") ||
                    textLower.contains("discretionary-ligatures") ||
                    textLower.contains("historical-ligatures") ||
                    textLower.contains("contextual")) {
                    return Some(textLower)
                }
                return None
            case "font-size-adjust" =>
                if (textLower == "none") {
                    return Some("none")
                }
                match (tryParseSvgFloat(text)) {
                    case Some(value) => if (value > 0.0 && isFiniteSvgNumber(value)) {
                        return Some(formatSvgNumber(value))
                    } else {
                        return None
                    }
                    case None => return None
                }
            case "font-feature-settings" => return Some(text)
            case "text-decoration-line" =>
                match (parseSvgDecorationLines(text)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "text-decoration-style" =>
                match (SvgTextDecorationStyle.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "text-decoration-color" =>
                if (textLower == "currentcolor") {
                    return Some("currentColor")
                }
                return this.normalizeColor(text)
            case "text-decoration-thickness" =>
                if (textLower == "auto") {
                    return Some("auto")
                }
                match (SvgLength.tryParse(text)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "text-underline-position" =>
                match (SvgTextUnderlinePosition.fromName(textLower)) {
                    case Some(value) => return Some(value.toString())
                    case None => return None
                }
            case "pathLength" =>
                match (tryParseSvgFloat(text)) {
                    case Some(value) => if (value >= 0.0 && isFiniteSvgNumber(value)) {
                        return Some(formatSvgNumber(value))
                    } else {
                        return None
                    }
                    case None => return None
                }
            case _ => return None
        }
    }

    private func normalizePaint(name: String, text: String, elementPath: String): ?String {
        try {
            Some(SvgPaint.parse(text).toString())
        } catch (error: SvgException) {
            if (error.kind == SvgErrorKind.Security) {
                this.warnings.add("元素「${elementPath}」属性「${name}」的外部画笔引用已按 none 处理：${text}")
                Some("none")
            } else {
                None
            }
        }
    }

    private func normalizeColor(text: String): ?String {
        match (SvgColor.tryParse(text)) {
            case Some(color) => Some(color.toString())
            case None => None
        }
    }

    /** `color-profile` 只接受 `auto` / `sRGB` / 已声明名称；其余回退 sRGB。 */
    private func normalizeColorProfile(text: String): ?String {
        let lower = text.trimAscii().toAsciiLower()
        if (lower == "auto") {
            return Some("auto")
        }
        if (lower == "srgb") {
            return Some("sRGB")
        }
        let name = text.trimAscii()
        if (this.declaredColorProfiles.get(name) ?? false) {
            return Some(name)
        }
        if (!(this.warnedColorProfiles.get(name) ?? false)) {
            this.warnedColorProfiles[name] = true
            this.warnings.add("color-profile「${name}」未声明，已按 sRGB 处理")
        }
        Some("sRGB")
    }
}

/** 展开单个属性的 `var()`；无 `var(` 时原样返回。 */
private func expandCustomValue(raw: String, custom: HashMap<String, String>): ?String {
    if (!containsCssVariable(raw)) {
        return Some(raw)
    }
    expandCssVariables(raw, {name => custom.get(name)}, Array<String>(), 0)
}

/** `calc()` 只对长度属性生效。 */
private func cssCalcAppliesTo(name: String): Bool {
    match (name) {
        case "stroke-width" | "letter-spacing" | "word-spacing" | "font-size" | "stroke-dashoffset" |
            "x" | "y" | "width" | "height" | "cx" | "cy" | "r" | "rx" | "ry" => true
        case _ => false
    }
}

private func resolveFontRelativeLength(length: SvgLength, fontSizePx: Float64): String {
    match (length.unit) {
        case Em => formatSvgNumber(length.value * fontSizePx) + "px"
        case Ex => formatSvgNumber(length.value * fontSizePx / 2.0) + "px"
        case _ => length.toString()
    }
}

private func considerCssCandidate(
    best: HashMap<String, CssCandidate>,
    property: String,
    candidate: CssCandidate
): Unit {
    match (best.get(property)) {
        case Some(existing) =>
            if (candidate.beats(existing)) {
                best[property] = candidate
            }
        case None => best[property] = candidate
    }
}

private func originSource(origin: Int64): CssStyleSource {
    if (origin == CSS_ORIGIN_PRESENTATION) {
        return CssStyleSource.Presentation
    }
    if (origin == CSS_ORIGIN_SHEET) {
        return CssStyleSource.Sheet
    }
    if (origin == CSS_ORIGIN_INLINE) {
        return CssStyleSource.Inline
    }
    CssStyleSource.Default
}

/** 处理 `inherit` / `initial` / `unset`，其余值原样返回。 */
private func resolveCssKeyword(raw: String, spec: SvgPropertySpec, parent: ?SvgComputedStyle): String {
    let lower = raw.trimAscii().toAsciiLower()
    match (lower) {
        case "inherit" =>
            match (parent) {
                case Some(parentStyle) => parentStyle.get(spec.name) ?? spec.initial
                case None => spec.initial
            }
        case "initial" => spec.initial
        case "unset" =>
            if (spec.inherited) {
                match (parent) {
                    case Some(parentStyle) => parentStyle.get(spec.name) ?? spec.initial
                    case None => spec.initial
                }
            } else {
                spec.initial
            }
        case _ => raw
    }
}

private func collectCssStyleTexts(element: SvgElement, out: ArrayList<String>): Unit {
    if (element.tag == "style" && element.namespace == SvgNamespaces.SVG) {
        out.add(element.text())
    }
    for (node in element.children) {
        match (node) {
            case ElementNode(child) => collectCssStyleTexts(child, out)
            case _ => ()
        }
    }
}

/** 简写规范化：纯线型返回规范顺序；含 style 关键字时保留原文供 getter 读取。 */
private func normalizeSvgTextDecorationShorthand(text: String): ?String {
    let lower = text.trimAscii().toAsciiLower()
    let words = splitCssWhitespaceWords(lower)
    var sawNone = false
    var sawLine = false
    var sawStyle = false
    for (word in words) {
        match (word) {
            case "none" => sawNone = true
            case "underline" | "overline" | "line-through" => sawLine = true
            case "solid" | "double" | "dotted" | "dashed" | "wavy" => sawStyle = true
            case _ => ()
        }
    }
    if (sawNone) {
        if (words.size > 1) {
            return Option<String>.None
        }
        return Some("none")
    }
    if (!sawLine) {
        return Option<String>.None
    }
    if (sawStyle) {
        return Some(text.trimAscii())
    }
    match (parseSvgDecorationLines(lower)) {
        case Some(value) => Some(value.toString())
        case None => Option<String>.None
    }
}
