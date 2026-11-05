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

    init(selectors: Array<CssSelector>, declarations: Array<CssDeclaration>, order: Int64) {
        this.selectors = selectors
        this.declarations = declarations
        this.order = order
    }

    public func toString(): String {
        let selectorTexts = ArrayList<String>()
        for (selector in this.selectors) {
            selectorTexts.add(selector.toString())
        }
        let prefix = joinCssStrings(selectorTexts, ", ")
        if (this.declarations.size == 0) {
            return prefix + " {}"
        }
        let declarationTexts = ArrayList<String>()
        for (declaration in this.declarations) {
            declarationTexts.add(declaration.toString() + ";")
        }
        prefix + " { " + joinCssStrings(declarationTexts, " ") + " }"
    }
}

/**
 * CSS 样式表：规则按源顺序保存。
 *
 * 解析采用容错策略：不支持的 at-rule / 选择器整条跳过并写 warning，语法残缺尽量恢复。
 */
public class CssStyleSheet <: ToString {
    public let rules: Array<CssRule>

    private init(rules: Array<CssRule>) {
        this.rules = rules
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
        let rules = ArrayList<CssRule>()
        var i = 0
        var order = 0
        while (i < tokens.size) {
            i = skipCssTrivia(tokens, i)
            if (i >= tokens.size) {
                break
            }
            if (tokens[i].kind == CssTokenKind.AtKeyword) {
                warnings.add("已跳过不支持的 at-rule「${tokens[i].text}」")
                i = skipCssAtRule(tokens, i)
                continue
            }
            let preludeStart = i
            while (i < tokens.size && tokens[i].kind != CssTokenKind.LeftBrace &&
                tokens[i].kind != CssTokenKind.Semicolon) {
                i++
            }
            if (i >= tokens.size) {
                warnings.add("样式规则缺少左花括号")
                break
            }
            if (tokens[i].kind == CssTokenKind.Semicolon) {
                i++
                continue
            }
            let preludeEnd = i
            i++
            let parsed = parseCssDeclarations(tokens, i, warnings)
            let declarations = parsed.declarations
            i = parsed.position
            let prelude = tokensToCssText(tokens, preludeStart, preludeEnd)
            let selectors = ArrayList<CssSelector>()
            if (containsUnsupportedSelector(tokens, preludeStart, preludeEnd)) {
                warnings.add("已跳过不支持的选择器「${prelude}」")
            } else {
                for (segment in splitCssSelectorList(tokens, preludeStart, preludeEnd)) {
                    if (segment.size == 0) {
                        continue
                    }
                    try {
                        selectors.add(CssSelector.parse(segment))
                    } catch (_: SvgException) {
                        warnings.add("已跳过无法解析的选择器「${segment}」")
                    }
                }
            }
            if (selectors.size > 0) {
                rules.add(CssRule(selectors.toArray(), declarations, order))
                order++
            }
        }
        CssStyleSheet(rules.toArray())
    }

    public func toString(): String {
        let result = ArrayList<String>()
        for (rule in this.rules) {
            result.add(rule.toString())
        }
        joinCssStrings(result, "\n")
    }
}

private func skipCssTrivia(tokens: Array<CssToken>, start: Int64): Int64 {
    var i = start
    while (i < tokens.size &&
        (tokens[i].kind == CssTokenKind.Whitespace || tokens[i].kind == CssTokenKind.Semicolon)) {
        i++
    }
    i
}

/** 跳过 at-rule：带块时按花括号配对，`@import` 一类跳到分号。 */
private func skipCssAtRule(tokens: Array<CssToken>, start: Int64): Int64 {
    var i = start + 1
    while (i < tokens.size && tokens[i].kind != CssTokenKind.LeftBrace &&
        tokens[i].kind != CssTokenKind.Semicolon) {
        i++
    }
    if (i >= tokens.size) {
        return tokens.size
    }
    if (tokens[i].kind == CssTokenKind.Semicolon) {
        return i + 1
    }
    var depth = 0
    while (i < tokens.size) {
        match (tokens[i].kind) {
            case LeftBrace => depth++
            case RightBrace =>
                depth--
                if (depth <= 0) {
                    return i + 1
                }
            case _ => ()
        }
        i++
    }
    tokens.size
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
        let property = decodeCssIdent(tokens[i].text).toAsciiLower()
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

private func containsUnsupportedSelector(tokens: Array<CssToken>, start: Int64, end: Int64): Bool {
    for (index in start..end) {
        match (tokens[index].kind) {
            case Colon | LeftBracket | RightBracket => return true
            case _ => ()
        }
    }
    false
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
