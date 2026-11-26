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

/** CSS 词法单元种类。 */
public enum CssTokenKind <: Equatable<CssTokenKind> & ToString {
    | Whitespace
    | Ident
    | Quoted
    | Url
    | Number
    | Hash
    | AtKeyword
    | Delim
    | Colon
    | Semicolon
    | Comma
    | LeftBrace
    | RightBrace
    | LeftParen
    | RightParen
    | LeftBracket
    | RightBracket

    public operator func ==(that: CssTokenKind): Bool {
        match ((this, that)) {
            case (Whitespace, Whitespace) => true
            case (Ident, Ident) => true
            case (Quoted, Quoted) => true
            case (Url, Url) => true
            case (Number, Number) => true
            case (Hash, Hash) => true
            case (AtKeyword, AtKeyword) => true
            case (Delim, Delim) => true
            case (Colon, Colon) => true
            case (Semicolon, Semicolon) => true
            case (Comma, Comma) => true
            case (LeftBrace, LeftBrace) => true
            case (RightBrace, RightBrace) => true
            case (LeftParen, LeftParen) => true
            case (RightParen, RightParen) => true
            case (LeftBracket, LeftBracket) => true
            case (RightBracket, RightBracket) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Whitespace => "Whitespace"
            case Ident => "Ident"
            case Quoted => "Quoted"
            case Url => "Url"
            case Number => "Number"
            case Hash => "Hash"
            case AtKeyword => "AtKeyword"
            case Delim => "Delim"
            case Colon => "Colon"
            case Semicolon => "Semicolon"
            case Comma => "Comma"
            case LeftBrace => "LeftBrace"
            case RightBrace => "RightBrace"
            case LeftParen => "LeftParen"
            case RightParen => "RightParen"
            case LeftBracket => "LeftBracket"
            case RightBracket => "RightBracket"
        }
    }
}

/** 一个词法单元：`text` 保留原始书写形式（含引号、反斜杠与 `url(...)`）。 */
public struct CssToken <: Equatable<CssToken> & ToString {
    public let kind: CssTokenKind
    public let text: String
    public let offset: Int64

    init(kind: CssTokenKind, text: String, offset: Int64) {
        this.kind = kind
        this.text = text
        this.offset = offset
    }

    public func toString(): String {
        "${this.kind}(${this.text})@${this.offset}"
    }

    public operator func ==(that: CssToken): Bool {
        this.kind == that.kind && this.text == that.text && this.offset == that.offset
    }
}

/**
 * CSS 词法分析器：单遍扫描，带字节位置。
 *
 * 注释直接丢弃；字符串与 `url(...)` 保留整体；未知字符降级为 `Delim` 后继续，
 * 不抛异常，保证样式表解析的整体容错。
 */
public class CssLexer {
    private let text: String
    private let bytes: Array<Byte>

    public init(text: String) {
        this.text = text
        this.bytes = text.unsafeBytes()
    }

    public func tokenize(): Array<CssToken> {
        let tokens = ArrayList<CssToken>()
        var i = 0
        while (i < this.bytes.size) {
            let start = i
            let byte = this.bytes[i]
            if (isCssSpace(byte)) {
                while (i < this.bytes.size && isCssSpace(this.bytes[i])) {
                    i++
                }
                if (tokens.size > 0 && tokens[tokens.size - 1].kind == CssTokenKind.Whitespace) {
                    let previous = tokens[tokens.size - 1]
                    tokens[tokens.size - 1] = CssToken(
                        CssTokenKind.Whitespace,
                        previous.text + this.text[start..i],
                        previous.offset
                    )
                } else {
                    tokens.add(CssToken(CssTokenKind.Whitespace, this.text[start..i], start))
                }
            } else if (byte == b'/' && i + 1 < this.bytes.size && this.bytes[i + 1] == b'*') {
                i = skipCssComment(this.bytes, i)
            } else if (byte == b'"' || byte == b'\'') {
                i = scanCssString(this.bytes, i)
                tokens.add(CssToken(CssTokenKind.Quoted, this.text[start..i], start))
            } else if (byte == b'#') {
                i++
                while (i < this.bytes.size) {
                    if (this.bytes[i] == b'\\') {
                        i = consumeCssEscape(this.bytes, i)
                    } else if (isCssIdentByte(this.bytes[i])) {
                        i++
                    } else {
                        break
                    }
                }
                tokens.add(CssToken(CssTokenKind.Hash, this.text[start..i], start))
            } else if (byte == b'@') {
                i++
                while (i < this.bytes.size) {
                    if (this.bytes[i] == b'\\') {
                        i = consumeCssEscape(this.bytes, i)
                    } else if (isCssIdentByte(this.bytes[i])) {
                        i++
                    } else {
                        break
                    }
                }
                tokens.add(CssToken(CssTokenKind.AtKeyword, this.text[start..i], start))
            } else if (isCssNumberStart(this.bytes, i)) {
                i = scanCssNumber(this.bytes, i)
                tokens.add(CssToken(CssTokenKind.Number, this.text[start..i], start))
            } else if (isCssIdentStart(this.bytes, i)) {
                i = scanCssIdent(this.bytes, i)
                let name = this.text[start..i]
                if (name.toAsciiLower() == "url") {
                    var look = i
                    while (look < this.bytes.size && isCssSpace(this.bytes[look])) {
                        look++
                    }
                    if (look < this.bytes.size && this.bytes[look] == b'(') {
                        i = scanCssUrl(this.bytes, look)
                        tokens.add(CssToken(CssTokenKind.Url, this.text[start..i], start))
                    } else {
                        tokens.add(CssToken(CssTokenKind.Ident, name, start))
                    }
                } else {
                    tokens.add(CssToken(CssTokenKind.Ident, name, start))
                }
            } else {
                let kind = cssPunctuation(byte)
                i += utf8Length(byte)
                if (i > this.bytes.size) {
                    i = this.bytes.size
                }
                tokens.add(CssToken(kind, this.text[start..i], start))
            }
        }
        tokens.toArray()
    }
}

private func cssPunctuation(byte: Byte): CssTokenKind {
    match (byte) {
        case b':' => CssTokenKind.Colon
        case b';' => CssTokenKind.Semicolon
        case b',' => CssTokenKind.Comma
        case b'{' => CssTokenKind.LeftBrace
        case b'}' => CssTokenKind.RightBrace
        case b'(' => CssTokenKind.LeftParen
        case b')' => CssTokenKind.RightParen
        case b'[' => CssTokenKind.LeftBracket
        case b']' => CssTokenKind.RightBracket
        case _ => CssTokenKind.Delim
    }
}

internal func isCssSpace(byte: Byte): Bool {
    byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r' || byte == 0x0C
}

internal func isCssDigit(byte: Byte): Bool {
    byte >= b'0' && byte <= b'9'
}

internal func isCssHexDigit(byte: Byte): Bool {
    isCssDigit(byte) || (byte >= b'a' && byte <= b'f') || (byte >= b'A' && byte <= b'F')
}

internal func isCssAlpha(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || byte >= 0x80
}

internal func isCssIdentByte(byte: Byte): Bool {
    isCssAlpha(byte) || isCssDigit(byte) || byte == b'-' || byte == b'_'
}

internal func isCssIdentStart(bytes: Array<Byte>, index: Int64): Bool {
    if (index >= bytes.size) {
        return false
    }
    let byte = bytes[index]
    if (isCssAlpha(byte) || byte == b'_' || byte == b'\\') {
        return true
    }
    if (byte == b'-') {
        if (index + 1 >= bytes.size) {
            return false
        }
        let next = bytes[index + 1]
        return isCssAlpha(next) || next == b'_' || next == b'-' || next == b'\\'
    }
    false
}

internal func isCssNumberStart(bytes: Array<Byte>, index: Int64): Bool {
    if (index >= bytes.size) {
        return false
    }
    let byte = bytes[index]
    if (isCssDigit(byte)) {
        return true
    }
    if (byte == b'.') {
        return index + 1 < bytes.size && isCssDigit(bytes[index + 1])
    }
    if (byte == b'+' || byte == b'-') {
        if (index + 1 < bytes.size && isCssDigit(bytes[index + 1])) {
            return true
        }
        return index + 2 < bytes.size && bytes[index + 1] == b'.' && isCssDigit(bytes[index + 2])
    }
    false
}

private func utf8Length(lead: Byte): Int64 {
    if (lead < 0x80) {
        return 1
    }
    if ((lead & 0xE0) == 0xC0) {
        return 2
    }
    if ((lead & 0xF0) == 0xE0) {
        return 3
    }
    if ((lead & 0xF8) == 0xF0) {
        return 4
    }
    1
}

private func skipCssComment(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start + 2
    while (i + 1 < bytes.size) {
        if (bytes[i] == b'*' && bytes[i + 1] == b'/') {
            return i + 2
        }
        i++
    }
    bytes.size
}

/** 返回字符串结束后的位置；未闭合时到输入末尾。 */
private func scanCssString(bytes: Array<Byte>, start: Int64): Int64 {
    let quoteByte = bytes[start]
    var i = start + 1
    while (i < bytes.size) {
        if (bytes[i] == b'\\') {
            i += 2
            if (i > bytes.size) {
                return bytes.size
            }
        } else if (bytes[i] == quoteByte) {
            return i + 1
        } else {
            i++
        }
    }
    bytes.size
}

/** 反斜杠转义的结束位置：十六进制转义最多 6 位并吞掉一个尾随空白。 */
private func consumeCssEscape(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start + 1
    if (i >= bytes.size) {
        return bytes.size
    }
    if (isCssHexDigit(bytes[i])) {
        var count = 0
        while (i < bytes.size && count < 6 && isCssHexDigit(bytes[i])) {
            i++
            count++
        }
        if (i < bytes.size && isCssSpace(bytes[i])) {
            i++
        }
        return i
    }
    i + 1
}

private func scanCssIdent(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start
    while (i < bytes.size) {
        if (bytes[i] == b'\\') {
            i = consumeCssEscape(bytes, i)
        } else if (isCssIdentByte(bytes[i])) {
            i++
        } else {
            break
        }
    }
    i
}

private func scanCssNumber(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start
    if (i < bytes.size && (bytes[i] == b'+' || bytes[i] == b'-')) {
        i++
    }
    while (i < bytes.size && isCssDigit(bytes[i])) {
        i++
    }
    if (i < bytes.size && bytes[i] == b'.' && i + 1 < bytes.size && isCssDigit(bytes[i + 1])) {
        i++
        while (i < bytes.size && isCssDigit(bytes[i])) {
            i++
        }
    }
    if (i < bytes.size && (bytes[i] == b'e' || bytes[i] == b'E')) {
        var exponent = i + 1
        if (exponent < bytes.size && (bytes[exponent] == b'+' || bytes[exponent] == b'-')) {
            exponent++
        }
        if (exponent < bytes.size && isCssDigit(bytes[exponent])) {
            i = exponent + 1
            while (i < bytes.size && isCssDigit(bytes[i])) {
                i++
            }
        }
    }
    i
}

/** `start` 指向 `url` 后的左括号；返回右括号之后的位置。 */
private func scanCssUrl(bytes: Array<Byte>, start: Int64): Int64 {
    var i = start + 1
    while (i < bytes.size) {
        let byte = bytes[i]
        if (byte == b'\\') {
            i += 2
            if (i > bytes.size) {
                return bytes.size
            }
        } else if (byte == b'"' || byte == b'\'') {
            i = scanCssString(bytes, i)
        } else if (byte == b')') {
            return i + 1
        } else {
            i++
        }
    }
    bytes.size
}

/** 去掉 ident 中的反斜杠转义，供选择器与属性名比较。 */
internal func decodeCssIdent(raw: String): String {
    let bytes = raw.unsafeBytes()
    let out = StringBuilder()
    var i = 0
    while (i < bytes.size) {
        if (bytes[i] == b'\\' && i + 1 < bytes.size) {
            let end = consumeCssEscape(bytes, i)
            let content = raw[i + 1..end]
            if (content.size > 0 && isCssHexDigit(content.unsafeBytes()[0])) {
                var hexText = ""
                var k = 0
                let contentBytes = content.unsafeBytes()
                while (k < contentBytes.size && isCssHexDigit(contentBytes[k])) {
                    hexText = hexText + content[k..k + 1]
                    k++
                }
                match (parseCssHexCodePoint(hexText)) {
                    case Some(rune) => out.append(rune)
                    case None => out.append("\u{FFFD}")
                }
            } else if (content.size > 0) {
                out.append(content[0..utf8Length(content.unsafeBytes()[0])])
            }
            i = end
        } else {
            let length = utf8Length(bytes[i])
            let end = if (i + length <= bytes.size) {
                i + length
            } else {
                i + 1
            }
            out.append(raw[i..end])
            i = end
        }
    }
    out.toString()
}

private func parseCssHexCodePoint(hexText: String): ?Rune {
    if (hexText.size == 0) {
        return None
    }
    var value = 0
    for (byte in hexText.unsafeBytes()) {
        value = value * 16 + cssHexValue(byte)
    }
    if (value <= 0 || value > 0x10FFFF) {
        return None
    }
    Some(Rune(UInt32(value)))
}

private func cssHexValue(byte: Byte): Int64 {
    if (byte >= b'0' && byte <= b'9') {
        return Int64(byte - b'0')
    }
    if (byte >= b'a' && byte <= b'f') {
        return Int64(byte - b'a') + 10
    }
    Int64(byte - b'A') + 10
}
