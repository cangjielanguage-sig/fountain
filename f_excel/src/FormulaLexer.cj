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
package fountain::f_excel

import std.collection.ArrayList
import std.convert.*
import fountain::f_base.StringGenerator

internal enum FTokKind <: Equatable<FTokKind> & ToString {
    | Num
    | Str
    | Ident
    | Quoted
    | Op
    | LParen
    | RParen
    | Comma
    | Semicolon
    | Colon
    | Bang
    | Percent
    | LBrace
    | RBrace
    | End

    public operator func ==(that: FTokKind): Bool {
        match ((this, that)) {
            case (Num, Num) => true
            case (Str, Str) => true
            case (Ident, Ident) => true
            case (Quoted, Quoted) => true
            case (Op, Op) => true
            case (LParen, LParen) => true
            case (RParen, RParen) => true
            case (Comma, Comma) => true
            case (Semicolon, Semicolon) => true
            case (Colon, Colon) => true
            case (Bang, Bang) => true
            case (Percent, Percent) => true
            case (LBrace, LBrace) => true
            case (RBrace, RBrace) => true
            case (End, End) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Num => "Num"
            case Str => "Str"
            case Ident => "Ident"
            case Quoted => "Quoted"
            case Op => "Op"
            case LParen => "("
            case RParen => ")"
            case Comma => ","
            case Semicolon => ";"
            case Colon => ":"
            case Bang => "!"
            case Percent => "%"
            case LBrace => "{"
            case RBrace => "}"
            case End => "EOF"
        }
    }

    public operator func !=(that: FTokKind): Bool {
        !(this == that)
    }
}

internal struct FToken <: ToString {
    public let kind: FTokKind
    public let text: String
    public let number: Float64

    public init(kind: FTokKind, text!: String = "", number!: Float64 = 0.0) {
        this.kind = kind
        this.text = text
        this.number = number
    }

    public func toString(): String {
        "${this.kind}:${this.text}"
    }
}

/** 公式语法错误；只在解析阶段内部使用，对外统一映射为 `#NAME?` / `#VALUE!`。 */
internal class FormulaSyntaxException <: Exception {
    public init(message: String) {
        super(message)
    }
}

private func isDigit(r: Rune): Bool {
    r >= r'0' && r <= r'9'
}

private func isLetter(r: Rune): Bool {
    (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z')
}

private func isIdentStart(r: Rune): Bool {
    isLetter(r) || r == r'_' || r == r'$'
}

private func isIdentPart(r: Rune): Bool {
    isLetter(r) || isDigit(r) || r == r'_' || r == r'$' || r == r'.'
}

private func isErrorChar(r: Rune): Bool {
    isLetter(r) || isDigit(r) || r == r'/' || r == r'!' || r == r'?' || r == r'_'
}

/**
 * 公式词法（设计 7.2）。
 *
 * 不做"引用 vs 名字"的判断：`Ident` 一律原样交给语法层，由它用 `CellRef.parse` 区分。
 * 空白直接跳过——M2 不支持引用交集运算符（`A1:A10 B1:B10`），遇到时按语法错误处理。
 */
internal func tokenizeFormula(source: String): Array<FToken> {
    let runes = ArrayList<Rune>()
    for (r in source.runes()) {
        runes.add(r)
    }
    let tokens = ArrayList<FToken>()
    var i: Int64 = 0
    let n = runes.size
    while (i < n) {
        let r = runes[i]
        if (r == r' ' || r == r'\t' || r == r'\n' || r == r'\r') {
            i++
            continue
        }
        if (isDigit(r) || (r == r'.' && i + 1 < n && isDigit(runes[i + 1]))) {
            let start = i
            var seenDot = false
            while (i < n && (isDigit(runes[i]) || runes[i] == r'.')) {
                if (runes[i] == r'.') {
                    if (seenDot) {
                        throw FormulaSyntaxException("数字里出现多个小数点")
                    }
                    seenDot = true
                }
                i++
            }
            if (i < n && (runes[i] == r'E' || runes[i] == r'e')) {
                i++
                if (i < n && (runes[i] == r'+' || runes[i] == r'-')) {
                    i++
                }
                let expStart = i
                while (i < n && isDigit(runes[i])) {
                    i++
                }
                if (i == expStart) {
                    throw FormulaSyntaxException("指数缺少数字")
                }
            }
            let text = runesToString(runes, start, i)
            let value = try {
                Float64.parse(text)
            } catch (_: Exception) {
                throw FormulaSyntaxException("无法解析数字：${text}")
            }
            tokens.add(FToken(FTokKind.Num, text: text, number: value))
            continue
        }
        if (r == r'"') {
            i++
            let value = StringGenerator()
            var closed = false
            while (i < n) {
                if (runes[i] == r'"') {
                    if (i + 1 < n && runes[i + 1] == r'"') {
                        value.append<String>("\"")
                        i += 2
                        continue
                    }
                    i++
                    closed = true
                    break
                }
                value.append(runes[i])
                i++
            }
            if (!closed) {
                throw FormulaSyntaxException("字符串缺少右引号")
            }
            tokens.add(FToken(FTokKind.Str, text: value.toString()))
            continue
        }
        if (r == r'\'') {
            i++
            let value = StringGenerator()
            var closed = false
            while (i < n) {
                if (runes[i] == r'\'') {
                    if (i + 1 < n && runes[i + 1] == r'\'') {
                        value.append<String>("'")
                        i += 2
                        continue
                    }
                    i++
                    closed = true
                    break
                }
                value.append(runes[i])
                i++
            }
            if (!closed) {
                throw FormulaSyntaxException("工作表名缺少右引号")
            }
            tokens.add(FToken(FTokKind.Quoted, text: value.toString()))
            continue
        }
        if (r == r'#') {
            let start = i
            i++
            while (i < n && isErrorChar(runes[i])) {
                i++
            }
            if (i == start + 1) {
                throw FormulaSyntaxException("孤立的 #")
            }
            tokens.add(FToken(FTokKind.Ident, text: runesToString(runes, start, i)))
            continue
        }
        if (isIdentStart(r)) {
            let start = i
            i++
            while (i < n && isIdentPart(runes[i])) {
                i++
            }
            tokens.add(FToken(FTokKind.Ident, text: runesToString(runes, start, i)))
            continue
        }
        match (r) {
            case r'+' => tokens.add(FToken(FTokKind.Op, text: "+"))
            case r'-' => tokens.add(FToken(FTokKind.Op, text: "-"))
            case r'*' => tokens.add(FToken(FTokKind.Op, text: "*"))
            case r'/' => tokens.add(FToken(FTokKind.Op, text: "/"))
            case r'^' => tokens.add(FToken(FTokKind.Op, text: "^"))
            case r'&' => tokens.add(FToken(FTokKind.Op, text: "&"))
            case r'=' => tokens.add(FToken(FTokKind.Op, text: "="))
            case r'<' =>
                if (i + 1 < n && runes[i + 1] == r'=') {
                    tokens.add(FToken(FTokKind.Op, text: "<="))
                    i++
                } else if (i + 1 < n && runes[i + 1] == r'>') {
                    tokens.add(FToken(FTokKind.Op, text: "<>"))
                    i++
                } else {
                    tokens.add(FToken(FTokKind.Op, text: "<"))
                }
            case r'>' =>
                if (i + 1 < n && runes[i + 1] == r'=') {
                    tokens.add(FToken(FTokKind.Op, text: ">="))
                    i++
                } else {
                    tokens.add(FToken(FTokKind.Op, text: ">"))
                }
            case r'(' => tokens.add(FToken(FTokKind.LParen))
            case r')' => tokens.add(FToken(FTokKind.RParen))
            case r',' => tokens.add(FToken(FTokKind.Comma))
            case r';' => tokens.add(FToken(FTokKind.Semicolon))
            case r':' => tokens.add(FToken(FTokKind.Colon))
            case r'!' => tokens.add(FToken(FTokKind.Bang))
            case r'%' => tokens.add(FToken(FTokKind.Percent))
            case r'{' => tokens.add(FToken(FTokKind.LBrace))
            case r'}' => tokens.add(FToken(FTokKind.RBrace))
            case _ => throw FormulaSyntaxException("无法识别的字符：${r}")
        }
        i++
    }
    tokens.add(FToken(FTokKind.End))
    tokens.toArray()
}

private func runesToString(runes: ArrayList<Rune>, start: Int64, end: Int64): String {
    let out = StringGenerator()
    var i = start
    while (i < end) {
        out.append(runes[i])
        i++
    }
    out.toString()
}
