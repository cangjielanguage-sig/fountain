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
    private let sheet: CssStyleSheet
    private let styleCache = HashMap<String, CssStyleSheet>()
    private let inlineCache = HashMap<String, Array<CssDeclaration>>()
    private var mergedRules: Array<CssRule> = Array<CssRule>()
    private var selectorIndex: ?CssSelectorIndex = None
    private var preparedRoot: ?Int64 = None

    public init(sheet!: CssStyleSheet = CssStyleSheet.empty()) {
        this.sheet = sheet
    }

    public func compute(root: SvgElement): SvgComputedStyleTree {
        this.warnings.clear()
        this.prepare(Some(root))
        let tree = SvgComputedStyleTree()
        this.computeSubtree(root, None, tree)
        tree
    }

    /**
     * 计算单个元素。`parent` 为父元素的计算样式；
     * 独立调用时只使用外部样式表，不回溯真实祖先。
     */
    public func computeElement(element: SvgElement, parent: ?SvgComputedStyle): SvgComputedStyle {
        this.prepare(None)
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
        if (this.preparedRoot == key) {
            return
        }
        let rules = ArrayList<CssRule>()
        for (rule in this.sheet.rules) {
            rules.add(CssRule(rule.selectors, rule.declarations, rule.order))
        }
        match (root) {
            case Some(element) =>
                let texts = ArrayList<String>()
                collectCssStyleTexts(element, texts)
                var styleIndex = 1
                for (text in texts) {
                    let parsed = this.parseStyleText(text)
                    for (rule in parsed.rules) {
                        rules.add(
                            CssRule(
                                rule.selectors,
                                rule.declarations,
                                styleIndex * CSS_STYLE_ORDER_CAP + rule.order
                            )
                        )
                    }
                    styleIndex++
                }
            case None => ()
        }
        this.mergedRules = rules.toArray()
        this.selectorIndex = CssSelectorIndex(this.mergedRules)
        this.preparedRoot = key
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
        let elementPath = element.elementPath()
        this.considerPresentation(element, best)
        this.considerSheet(element, best)
        this.considerInline(element, best)

        let values = HashMap<String, String>()
        let sources = HashMap<String, CssStyleSource>()
        var overall = CssStyleSource.Default
        let fontSpec = SvgPropertySpec("font-size", true, "16px")
        var fontSizeRaw = "16px"
        match (best.get("font-size")) {
            case Some(candidate) => fontSizeRaw = candidate.value
            case None =>
                match (parent) {
                    case Some(parentStyle) => fontSizeRaw = parentStyle.get("font-size") ?? "16px"
                    case None => ()
                }
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
            var source = CssStyleSource.Default
            match (best.get(name)) {
                case Some(candidate) =>
                    raw = candidate.value
                    source = if (candidate.important) {
                        CssStyleSource.Important
                    } else {
                        originSource(candidate.origin)
                    }
                case None =>
                    if (spec.inherited) {
                        match (parent) {
                            case Some(parentStyle) => raw = parentStyle.get(name) ?? spec.initial
                            case None => raw = spec.initial
                        }
                    }
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
            if (source.rank() > overall.rank()) {
                overall = source
            }
        }
        let color = values.get("color") ?? "#000000"
        for (name in ["fill", "stroke", "stop-color"]) {
            if (values.get(name) == Some("currentColor")) {
                values[name] = color
            }
        }
        SvgComputedStyle(values, sources, overall)
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

    private func considerSheet(element: SvgElement, best: HashMap<String, CssCandidate>): Unit {
        let index = match (this.selectorIndex) {
            case Some(value) => value
            case None => return
        }
        for (ruleIndex in index.candidates(element)) {
            let rule = this.mergedRules[ruleIndex]
            var matched = false
            var specificity = CssSpecificity.zero
            for (selector in rule.selectors) {
                if (selector.matches(element)) {
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
                if (findSvgPropertySpec(declaration.property).isNone()) {
                    continue
                }
                considerCssCandidate(
                    best,
                    declaration.property,
                    CssCandidate(
                        declaration.value,
                        declaration.important,
                        CSS_ORIGIN_SHEET,
                        specificity,
                        rule.order
                    )
                )
            }
        }
    }

    private func considerInline(element: SvgElement, best: HashMap<String, CssCandidate>): Unit {
        match (element.style) {
            case Some(text) =>
                if (text.trimAscii().size == 0) {
                    return
                }
                for (declaration in this.inlineDeclarations(text)) {
                    if (findSvgPropertySpec(declaration.property).isNone()) {
                        continue
                    }
                    considerCssCandidate(
                        best,
                        declaration.property,
                        CssCandidate(
                            declaration.value,
                            declaration.important,
                            CSS_ORIGIN_INLINE,
                            CssSpecificity.zero,
                            CSS_INLINE_ORDER
                        )
                    )
                }
            case None => ()
        }
    }

    private func normalizeValue(
        name: String,
        raw: String,
        parent: ?SvgComputedStyle,
        elementPath: String,
        fontSizePx: Float64
    ): ?String {
        let trimmed = raw.trimAscii()
        if (trimmed.size == 0) {
            return None
        }
        let lower = trimmed.toAsciiLower()
        match (name) {
            case "fill" | "stroke" => return this.normalizePaint(name, trimmed, elementPath)
            case "color" =>
                if (lower == "currentcolor") {
                    match (parent) {
                        case Some(parentStyle) => return Some(parentStyle.color().toString())
                        case None => return Some(SvgColor.Black.toString())
                    }
                }
                return this.normalizeColor(trimmed)
            case "stop-color" =>
                if (lower == "currentcolor") {
                    return Some("currentColor")
                }
                return this.normalizeColor(trimmed)
            case "fill-opacity" | "stroke-opacity" | "opacity" | "stop-opacity" =>
                match (tryParseSvgFloat(trimmed)) {
                    case Some(value) => return Some(formatSvgNumber(clampSvgUnit(value)))
                    case None => return None
                }
            case "stroke-miterlimit" =>
                match (tryParseSvgFloat(trimmed)) {
                    case Some(value) => if (value < 1.0) {
                        return None
                    } else {
                        return Some(formatSvgNumber(value))
                    }
                    case None => return None
                }
            case "font-size" =>
                match (SvgLength.tryParse(trimmed)) {
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
                if ((name == "letter-spacing" || name == "word-spacing") && lower == "normal") {
                    return Some("0")
                }
                match (SvgLength.tryParse(trimmed)) {
                    case Some(length) =>
                        return Some(resolveFontRelativeLength(length, fontSizePx))
                    case None => return None
                }
            case "stroke-dasharray" =>
                if (lower == "none") {
                    return Some("none")
                }
                match (parseSvgLengthList(trimmed)) {
                    case Some(list) => return Some(formatSvgLengthList(list))
                    case None => return None
                }
            case "clip-path" | "mask" =>
                if (lower == "none") {
                    return Some("none")
                }
                if (lower.size > 4 && lower[0..4] == "url(") {
                    return Some(trimmed)
                }
                return None
            case "fill-rule" | "clip-rule" =>
                match (SvgFillRule.fromName(lower)) {
                    case Some(rule) => return Some(rule.attrName())
                    case None => return None
                }
            case "stroke-linecap" =>
                match (SvgLineCap.fromName(lower)) {
                    case Some(cap) => return Some(cap.attrName())
                    case None => return None
                }
            case "stroke-linejoin" =>
                match (SvgLineJoin.fromName(lower)) {
                    case Some(join) => return Some(join.attrName())
                    case None => return None
                }
            case "text-anchor" =>
                match (SvgTextAnchor.fromName(lower)) {
                    case Some(anchor) => return Some(anchor.attrName())
                    case None => return None
                }
            case "visibility" =>
                if (lower == "visible" || lower == "hidden" || lower == "collapse") {
                    return Some(lower)
                }
                return None
            case "display" =>
                if (lower == "inline" || lower == "block" || lower == "none" || lower == "inline-block") {
                    return Some(lower)
                }
                return None
            case "font-family" => return trimmed
            case "font-weight" =>
                if (lower == "normal" || lower == "bold" || lower == "bolder" || lower == "lighter") {
                    return Some(lower)
                }
                match (tryParseSvgFloat(lower)) {
                    case Some(value) => return Some(formatSvgNumber(value))
                    case None => return None
                }
            case "font-style" =>
                if (lower == "normal" || lower == "italic" || lower == "oblique") {
                    return Some(lower)
                }
                return None
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
