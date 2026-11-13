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

/** 一条 CSS 声明。`value` 保留作者书写形式（`!important` 除外）。 */
public struct CssDeclaration <: Equatable<CssDeclaration> & ToString {
    public let property: String
    public let value: String
    public let important: Bool

    public init(property: String, value: String, important!: Bool = false) {
        this.property = property
        this.value = value
        this.important = important
    }

    public func toString(): String {
        let body = "${this.property}: ${this.value}"
        if (this.important) {
            body + " !important"
        } else {
            body
        }
    }

    public operator func ==(that: CssDeclaration): Bool {
        this.property == that.property && this.value == that.value && this.important == that.important
    }
}

/** 一条 CSS 规则集。`order` 表示源顺序，用于同特异性排序。 */
public class CssRule <: ToString {
    public let selectors: Array<CssSelector>
    public let declarations: Array<CssDeclaration>
    public let order: Int64
    /** `@media` 条件；`None` 表示无条件规则。 */
    public let media: ?CssMediaQuery

    init(
        selectors: Array<CssSelector>,
        declarations: Array<CssDeclaration>,
        order: Int64,
        media!: ?CssMediaQuery = None
    ) {
        this.selectors = selectors
        this.declarations = declarations
        this.order = order
        this.media = media
    }

    /** 分组选择器的特异性取最高值。 */
    public func specificity(): CssSpecificity {
        var best = CssSpecificity.zero
        for (index in 0..this.selectors.size) {
            if (this.selectors[index].specificity.compareTo(best) > 0) {
                best = this.selectors[index].specificity
            }
        }
        best
    }

    public func toString(): String {
        let selectorTexts = ArrayList<String>()
        for (selector in this.selectors) {
            selectorTexts.add(selector.toString())
        }
        let prefix = joinCssStrings(selectorTexts, ", ")
        let body = if (this.declarations.size == 0) {
            prefix + " {}"
        } else {
            let declarationTexts = ArrayList<String>()
            for (declaration in this.declarations) {
                declarationTexts.add(declaration.toString() + ";")
            }
            prefix + " { " + joinCssStrings(declarationTexts, " ") + " }"
        }
        match (this.media) {
            case Some(media) => "@media ${media.toString()} { ${body} }"
            case None => body
        }
    }
}

/** 一条 `@font-face` 别名声明。`src` 记录原文，不加载文件。 */
public class CssFontFaceRule <: ToString {
    public let family: String
    public let weight: ?String
    public let style: ?String
    public let srcPresent: Bool
    /** `src` 声明原文；未声明时为 `None`。 */
    public let src: ?String

    init(family: String, weight: ?String, style: ?String, srcPresent: Bool, src!: ?String = None) {
        this.family = family
        this.weight = weight
        this.style = style
        this.srcPresent = srcPresent
        this.src = src
    }

    public func toString(): String {
        "@font-face { font-family: ${this.family} }"
    }
}

/** 一条 `@color-profile` 声明；`src` 记录原文，不加载 ICC。 */
public class CssColorProfileRule <: ToString {
    public let name: String
    /** `src` 声明原文；未声明时为 `None`。 */
    public let src: ?String

    init(name: String, src!: ?String = None) {
        this.name = name
        this.src = src
    }

    public func toString(): String {
        "@color-profile ${this.name} { src: ${this.src ?? ""} }"
    }
}

/**
 * CSS 样式表：规则按源顺序保存。
 *
 * 解析采用容错策略：不支持的 at-rule / 选择器整条跳过并写 warning，语法残缺尽量恢复。
 */
public class CssStyleSheet <: ToString {
    public let rules: Array<CssRule>
    /** `@font-face` 别名，按源顺序。 */
    public let fontFaces: Array<CssFontFaceRule>
    /** `@color-profile` 声明，按源顺序。 */
    public let colorProfiles: Array<CssColorProfileRule>

    private init(
        rules: Array<CssRule>,
        fontFaces!: Array<CssFontFaceRule> = Array<CssFontFaceRule>(),
        colorProfiles!: Array<CssColorProfileRule> = Array<CssColorProfileRule>()
    ) {
        this.rules = rules
        this.fontFaces = fontFaces
        this.colorProfiles = colorProfiles
    }

    public static func empty(): CssStyleSheet {
        CssStyleSheet(Array<CssRule>())
    }

    public static func parse(text: String): CssStyleSheet {
        let warnings = ArrayList<String>()
        CssStyleSheet.parse(text, warnings)
    }

    public static func parse(text: String, warnings: ArrayList<String>): CssStyleSheet {
        let tokens = CssLexer(text).tokenize()
        let state = CssSheetParseState(warnings)
        parseCssRuleBlock(tokens, 0, tokens.size, Option<CssMediaQuery>.None, state)
        CssStyleSheet(
            state.rules.toArray(),
            fontFaces: state.fontFaces.toArray(),
            colorProfiles: state.colorProfiles.toArray()
        )
    }

    public func toString(): String {
        let result = ArrayList<String>()
        for (rule in this.rules) {
            result.add(rule.toString())
        }
        joinCssStrings(result, "\n")
    }
}

/** 样式表解析的累积状态：规则、源顺序与告警。 */
private class CssSheetParseState {
    let rules = ArrayList<CssRule>()
    let fontFaces = ArrayList<CssFontFaceRule>()
    let colorProfiles = ArrayList<CssColorProfileRule>()
    let warnings: ArrayList<String>
    var order: Int64 = 0

    init(warnings: ArrayList<String>) {
        this.warnings = warnings
    }
}

/**
 * 解析 `[start, end)` 范围内的规则；`media` 为外层 `@media` 条件（嵌套时由内层覆盖）。
 */
private func parseCssRuleBlock(
    tokens: Array<CssToken>,
    start: Int64,
    end: Int64,
    media: ?CssMediaQuery,
    state: CssSheetParseState
): Unit {
    var i = start
    while (i < end) {
        i = skipCssTriviaWithin(tokens, i, end)
        if (i >= end) {
            break
        }
        if (tokens[i].kind == CssTokenKind.RightBrace) {
            i++
            continue
        }
        if (tokens[i].kind == CssTokenKind.AtKeyword) {
            if (tokens[i].text.toAsciiLower() == "@media") {
                i = parseCssMediaBlock(tokens, i, end, state)
                continue
            }
            if (tokens[i].text.toAsciiLower() == "@font-face") {
                i = parseCssFontFace(tokens, i, end, state)
                continue
            }
            if (tokens[i].text.toAsciiLower() == "@color-profile") {
                i = parseCssColorProfile(tokens, i, end, state)
                continue
            }
            state.warnings.add("已跳过不支持的 at-rule「${tokens[i].text}」")
            i = skipCssAtRuleWithin(tokens, i, end)
            continue
        }
        let preludeStart = i
        while (i < end && tokens[i].kind != CssTokenKind.LeftBrace &&
            tokens[i].kind != CssTokenKind.Semicolon) {
            i++
        }
        if (i >= end) {
            state.warnings.add("样式规则缺少左花括号")
            break
        }
        if (tokens[i].kind == CssTokenKind.Semicolon) {
            i++
            continue
        }
        let preludeEnd = i
        i++
        let parsed = parseCssDeclarations(tokens, i, state.warnings)
        let declarations = parsed.declarations
        i = parsed.position
        let selectors = ArrayList<CssSelector>()
        for (segment in splitCssSelectorList(tokens, preludeStart, preludeEnd)) {
            if (segment.size == 0) {
                continue
            }
            try {
                selectors.add(CssSelector.parse(segment))
            } catch (error: SvgException) {
                state.warnings.add("已跳过无法解析的选择器「${segment}」：${error.message}")
            }
        }
        if (selectors.size > 0) {
            state.rules.add(CssRule(selectors.toArray(), declarations, state.order, media: media))
            state.order++
        }
    }
}

/** 解析 `@media <query-list> { rules }`；`start` 指向 `@media`。 */
private func parseCssMediaBlock(
    tokens: Array<CssToken>,
    start: Int64,
    end: Int64,
    state: CssSheetParseState
): Int64 {
    var i = start + 1
    while (i < end && tokens[i].kind != CssTokenKind.LeftBrace &&
        tokens[i].kind != CssTokenKind.Semicolon) {
        i++
    }
    if (i >= end) {
        state.warnings.add("已跳过缺少规则块的 @media")
        return end
    }
    if (tokens[i].kind == CssTokenKind.Semicolon) {
        state.warnings.add("已跳过缺少规则块的 @media")
        return i + 1
    }
    let preludeText = tokensToCssText(tokens, start + 1, i)
    let blockEnd = findCssClosingBrace(tokens, i, end)
    if (blockEnd < 0) {
        state.warnings.add("已跳过缺少右花括号的 @media")
        return end
    }
    match (CssMediaQuery.parse(preludeText, state.warnings)) {
        case Some(query) =>
            parseCssRuleBlock(tokens, i + 1, blockEnd, Some(query), state)
        case None => ()
    }
    blockEnd + 1
}

/** 解析 `@font-face { ... }`；`start` 指向 `@font-face`。 */
private func parseCssFontFace(
    tokens: Array<CssToken>,
    start: Int64,
    end: Int64,
    state: CssSheetParseState
): Int64 {
    var i = start + 1
    while (i < end && tokens[i].kind != CssTokenKind.LeftBrace &&
        tokens[i].kind != CssTokenKind.Semicolon) {
        i++
    }
    if (i >= end || tokens[i].kind == CssTokenKind.Semicolon) {
        state.warnings.add("已跳过缺少声明块的 @font-face")
        return if (i >= end) { end } else { i + 1 }
    }
    let blockEnd = findCssClosingBrace(tokens, i, end)
    if (blockEnd < 0) {
        state.warnings.add("已跳过缺少右花括号的 @font-face")
        return end
    }
    let parsed = parseCssDeclarations(tokens, i + 1, state.warnings)
    var family: ?String = None
    var weight: ?String = None
    var style: ?String = None
    var srcPresent = false
    var srcValue: ?String = None
    for (declaration in parsed.declarations) {
        match (declaration.property) {
            case "font-family" =>
                let name = trimAsciiQuotes(declaration.value.trimAscii())
                if (name.size > 0) {
                    family = Some(name)
                }
            case "font-weight" => weight = Some(declaration.value.trimAscii().toAsciiLower())
            case "font-style" => style = Some(declaration.value.trimAscii().toAsciiLower())
            case "src" =>
                srcPresent = true
                srcValue = Some(declaration.value.trimAscii())
                state.warnings.add("已忽略 @font-face 的 src（不加载字体文件）：${declaration.value}")
            case _ => ()
        }
    }
    match (family) {
        case Some(name) =>
            state.fontFaces.add(CssFontFaceRule(name, weight, style, srcPresent, src: srcValue))
        case None => state.warnings.add("已跳过缺少 font-family 的 @font-face")
    }
    blockEnd + 1
}

/** 解析 `@color-profile <name> { ... }`；`start` 指向 at-keyword。 */
private func parseCssColorProfile(
    tokens: Array<CssToken>,
    start: Int64,
    end: Int64,
    state: CssSheetParseState
): Int64 {
    var i = start + 1
    while (i < end && tokens[i].kind != CssTokenKind.LeftBrace &&
        tokens[i].kind != CssTokenKind.Semicolon) {
        i++
    }
    if (i >= end || tokens[i].kind == CssTokenKind.Semicolon) {
        state.warnings.add("已跳过缺少声明块的 @color-profile")
        return if (i >= end) { end } else { i + 1 }
    }
    let name = trimAsciiQuotes(tokensToCssText(tokens, start + 1, i).trimAscii())
    let blockEnd = findCssClosingBrace(tokens, i, end)
    if (blockEnd < 0) {
        state.warnings.add("已跳过缺少右花括号的 @color-profile")
        return end
    }
    let parsed = parseCssDeclarations(tokens, i + 1, state.warnings)
    var src: ?String = None
    for (declaration in parsed.declarations) {
        if (declaration.property == "src") {
            src = Some(declaration.value.trimAscii())
            state.warnings.add("已忽略 @color-profile 的 src（不做 ICC 变换）：${declaration.value}")
        }
    }
    if (name.size == 0) {
        state.warnings.add("已跳过缺少名称的 @color-profile")
    } else {
        state.colorProfiles.add(CssColorProfileRule(name, src: src))
    }
    blockEnd + 1
}

/** 找到与 `open` 左花括号配对的右花括号下标；越界返回 -1。 */
private func findCssClosingBrace(tokens: Array<CssToken>, open: Int64, end: Int64): Int64 {
    var depth = 0
    var i = open
    while (i < end) {
        match (tokens[i].kind) {
            case LeftBrace => depth++
            case RightBrace =>
                depth--
                if (depth == 0) {
                    return i
                }
            case _ => ()
        }
        i++
    }
    -1
}

private func skipCssTriviaWithin(tokens: Array<CssToken>, start: Int64, end: Int64): Int64 {
    var i = start
    while (i < end &&
        (tokens[i].kind == CssTokenKind.Whitespace || tokens[i].kind == CssTokenKind.Semicolon)) {
        i++
    }
    i
}

/** 跳过 at-rule：带块时按花括号配对，`@import` 一类跳到分号。 */
private func skipCssAtRuleWithin(tokens: Array<CssToken>, start: Int64, end: Int64): Int64 {
    var i = start + 1
    while (i < end && tokens[i].kind != CssTokenKind.LeftBrace &&
        tokens[i].kind != CssTokenKind.Semicolon) {
        i++
    }
    if (i >= end) {
        return end
    }
    if (tokens[i].kind == CssTokenKind.Semicolon) {
        return i + 1
    }
    let close = findCssClosingBrace(tokens, i, end)
    if (close < 0) {
        return end
    }
    close + 1
}

/** 声明块解析结果。 */
private class CssDeclarationParseResult {
    let declarations: Array<CssDeclaration>
    let position: Int64

    init(declarations: Array<CssDeclaration>, position: Int64) {
        this.declarations = declarations
        this.position = position
    }
}

private func parseCssDeclarations(
    tokens: Array<CssToken>,
    start: Int64,
    warnings: ArrayList<String>
): CssDeclarationParseResult {
    let declarations = ArrayList<CssDeclaration>()
    var i = start
    var closed = false
    while (i < tokens.size) {
        while (i < tokens.size &&
            (tokens[i].kind == CssTokenKind.Whitespace || tokens[i].kind == CssTokenKind.Semicolon)) {
            i++
        }
        if (i >= tokens.size) {
            break
        }
        if (tokens[i].kind == CssTokenKind.RightBrace) {
            closed = true
            i++
            break
        }
        if (tokens[i].kind != CssTokenKind.Ident) {
            warnings.add("已跳过无法识别的声明片段「${tokens[i].text}」")
            i = skipToCssDeclarationEnd(tokens, i)
            continue
        }
        let decodedProperty = decodeCssIdent(tokens[i].text)
        let property = if (decodedProperty.startsWith("--")) {
            decodedProperty
        } else {
            decodedProperty.toAsciiLower()
        }
        i++
        while (i < tokens.size && tokens[i].kind == CssTokenKind.Whitespace) {
            i++
        }
        if (i >= tokens.size || tokens[i].kind != CssTokenKind.Colon) {
            warnings.add("属性「${property}」缺少冒号")
            i = skipToCssDeclarationEnd(tokens, i)
            continue
        }
        i++
        let valueStart = i
        var depth = 0
        while (i < tokens.size) {
            match (tokens[i].kind) {
                case LeftParen => depth++
                case RightParen => if (depth > 0) {
                    depth--
                }
                case Semicolon => if (depth == 0) {
                    break
                }
                case RightBrace => if (depth == 0) {
                    break
                }
                case _ => ()
            }
            i++
        }
        let rawValue = tokensToCssText(tokens, valueStart, i).trimAscii()
        if (rawValue.size > 0) {
            let value = splitCssImportant(rawValue)
            if (value.text.size > 0) {
                declarations.add(CssDeclaration(property, value.text, important: value.important))
            } else {
                warnings.add("属性「${property}」的值只有 !important")
            }
        } else {
            warnings.add("属性「${property}」的值为空")
        }
        if (i < tokens.size && tokens[i].kind == CssTokenKind.Semicolon) {
            i++
        }
    }
    if (!closed) {
        warnings.add("样式规则缺少右花括号")
    }
    CssDeclarationParseResult(declarations.toArray(), i)
}

private func skipToCssDeclarationEnd(tokens: Array<CssToken>, start: Int64): Int64 {
    var i = start
    while (i < tokens.size && tokens[i].kind != CssTokenKind.Semicolon &&
        tokens[i].kind != CssTokenKind.RightBrace) {
        i++
    }
    if (i < tokens.size && tokens[i].kind == CssTokenKind.Semicolon) {
        i++
    }
    i
}

/** 按顶层逗号拆分选择器列表，返回每个选择器的原始文本。 */
private func splitCssSelectorList(tokens: Array<CssToken>, start: Int64, end: Int64): Array<String> {
    let segments = ArrayList<String>()
    var segmentStart = start
    var depth = 0
    for (index in start..end) {
        match (tokens[index].kind) {
            case LeftParen => depth++
            case RightParen => if (depth > 0) {
                depth--
            }
            case Comma => if (depth == 0) {
                let text = tokensToCssText(tokens, segmentStart, index).trimAscii()
                if (text.size > 0) {
                    segments.add(text)
                }
                segmentStart = index + 1
            }
            case _ => ()
        }
    }
    let tail = tokensToCssText(tokens, segmentStart, end).trimAscii()
    if (tail.size > 0) {
        segments.add(tail)
    }
    segments.toArray()
}

/** 拼接 token 原文；注释已由词法器丢弃，空白保持。 */
private func tokensToCssText(tokens: Array<CssToken>, start: Int64, end: Int64): String {
    let out = StringBuilder()
    var i = start
    while (i < end) {
        out.append(tokens[i].text)
        i++
    }
    out.toString()
}

/** `!important` 拆分结果。 */
private class CssImportantSplit {
    let text: String
    let important: Bool

    init(text: String, important: Bool) {
        this.text = text
        this.important = important
    }
}

/** 拆分尾部 `!important`。 */
private func splitCssImportant(text: String): CssImportantSplit {
    let bytes = text.unsafeBytes()
    var marker = -1
    var i = bytes.size - 1
    while (i >= 0) {
        if (bytes[i] == b'!') {
            marker = i
            break
        }
        i--
    }
    if (marker < 0) {
        return CssImportantSplit(text, false)
    }
    let suffix = text[marker + 1..].trimAscii().toAsciiLower()
    if (suffix != "important") {
        return CssImportantSplit(text, false)
    }
    CssImportantSplit(text[0..marker].trimAscii(), true)
}

internal func joinCssStrings(items: ArrayList<String>, separator: String): String {
    let out = StringBuilder()
    for (index in 0..items.size) {
        if (index > 0) {
            out.append(separator)
        }
        out.append(items[index])
    }
    out.toString()
}
