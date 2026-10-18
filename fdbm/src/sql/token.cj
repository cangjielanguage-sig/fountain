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
package fountain::fdbm.sql

import std.collection.ArrayList
import std.unicode.UnicodeStringExtension
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.exception.FdbmException

/** 词法记号种类（设计 §8.2）。 */
protected enum TokenKind <: Equatable<TokenKind> {
    | Ident | Number | Text | HexText | Question | Operator | LParen | RParen | Comma | Semicolon
    | Dot | End

    public operator func ==(other: TokenKind): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case Ident => 0
            case Number => 1
            case Text => 2
            case HexText => 3
            case Question => 4
            case Operator => 5
            case LParen => 6
            case RParen => 7
            case Comma => 8
            case Semicolon => 9
            case Dot => 10
            case End => 11
        }
    }
}

/** 一个记号：原文、位置（0 起）与大小写无关的上界（关键字比较用）。 */
protected class Token {
    public let kind: TokenKind
    public let text: String
    public let position: Int64
    /** 该标识符在原文里是否带引用符（`"..."` / `` `...` ``）。 */
    public let quoted: Bool
    private let upper: String

    public init(kind: TokenKind, text: String, position: Int64, quoted!: Bool = false) {
        this.kind = kind
        this.text = text
        this.position = position
        this.quoted = quoted
        this.upper = text.toUpper()
    }

    /** 是否关键字（大小写不敏感）；引用过的标识符不算关键字。 */
    public func isKeyword(word: String): Bool {
        kind == TokenKind.Ident && !quoted && upper == word.toUpper()
    }

    public func upperText(): String {
        upper
    }
}

/**
 * 手写词法（设计 §8.2）：标识符 / 数字 / 单引号字符串 / `?` / 比较与算术运算符 / 标点。
 *
 * `'...'` 是字符串（`''` 转义）；`"..."` 与 `` `...` `` 是引用标识符（SQL 标准 / MySQL）。
 * `--` 行注释与 `/* */` 块注释被跳过。
 */
protected struct Lexer {
    private let source: String

    public init(source: String) {
        this.source = source
    }

    public func tokenize(): Array<Token> {
        let tokens = ArrayList<Token>()
        let chars = source.toArray()
        var i: Int64 = 0
        while (i < chars.size) {
            let byte = chars[i]
            if (isSpace(byte)) {
                i += 1
                continue
            }
            if (byte == 0x2D && i + 1 < chars.size && chars[i + 1] == 0x2D) {
                // -- 行注释
                i += 2
                while (i < chars.size && chars[i] != 0x0A) {
                    i += 1
                }
                continue
            }
            if (byte == 0x2F && i + 1 < chars.size && chars[i + 1] == 0x2A) {
                // /* 块注释 */
                let start = i
                i += 2
                var closed = false
                while (i + 1 < chars.size) {
                    if (chars[i] == 0x2A && chars[i + 1] == 0x2F) {
                        i += 2
                        closed = true
                        break
                    }
                    i += 1
                }
                if (!closed) {
                    throw syntax('unterminated block comment', start)
                }
                continue
            }
            if ((byte == 0x58 || byte == 0x78) && i + 1 < chars.size && chars[i + 1] == 0x27) {
                // X'...' 十六进制字面量（MySQL 二进制字面量；渲染时按方言改写）
                let start = i
                i += 2
                let digits = ArrayList<Byte>()
                while (i < chars.size && chars[i] != 0x27) {
                    digits.add(chars[i])
                    i += 1
                }
                if (i >= chars.size) {
                    throw syntax('unterminated hex literal', start)
                }
                i += 1
                tokens.add(Token(TokenKind.HexText, String.fromUtf8(digits.toArray()), start))
                continue
            }
            if (byte == 0x27) {
                // 'string literal'（单引号才是字符串）
                let start = i
                i += 1
                let text = ArrayList<Byte>()
                var closed = false
                while (i < chars.size) {
                    if (chars[i] == 0x27) {
                        if (i + 1 < chars.size && chars[i + 1] == 0x27) {
                            text.add(0x27)
                            i += 2
                            continue
                        }
                        i += 1
                        closed = true
                        break
                    }
                    text.add(chars[i])
                    i += 1
                }
                if (!closed) {
                    throw syntax('unterminated string literal', start)
                }
                tokens.add(Token(TokenKind.Text, String.fromUtf8(text.toArray()), start))
                continue
            }
            if (byte == 0x22) {
                // "quoted identifier"（SQL 标准；`""` 转义为 `"`）
                let start = i
                i += 1
                let name = ArrayList<Byte>()
                var closed = false
                while (i < chars.size) {
                    if (chars[i] == 0x22) {
                        if (i + 1 < chars.size && chars[i + 1] == 0x22) {
                            name.add(0x22)
                            i += 2
                            continue
                        }
                        i += 1
                        closed = true
                        break
                    }
                    name.add(chars[i])
                    i += 1
                }
                if (!closed) {
                    throw syntax('unterminated quoted identifier', start)
                }
                tokens.add(Token(TokenKind.Ident, String.fromUtf8(name.toArray()), start,
                    quoted: true))
                continue
            }
            if (byte == 0x60) {
                // `quoted identifier`（MySQL；``` `` ``` 转义为 `` ` ``）
                let start = i
                i += 1
                let name = ArrayList<Byte>()
                var closed = false
                while (i < chars.size) {
                    if (chars[i] == 0x60) {
                        if (i + 1 < chars.size && chars[i + 1] == 0x60) {
                            name.add(0x60)
                            i += 2
                            continue
                        }
                        i += 1
                        closed = true
                        break
                    }
                    name.add(chars[i])
                    i += 1
                }
                if (!closed) {
                    throw syntax('unterminated quoted identifier', start)
                }
                tokens.add(Token(TokenKind.Ident, String.fromUtf8(name.toArray()), start,
                    quoted: true))
                continue
            }
            if (isDigit(byte)) {
                let start = i
                while (i < chars.size && isDigit(chars[i])) {
                    i += 1
                }
                if (i < chars.size && chars[i] == 0x2E) {
                    i += 1
                    while (i < chars.size && isDigit(chars[i])) {
                        i += 1
                    }
                }
                if (i < chars.size && (chars[i] == 0x65 || chars[i] == 0x45)) {
                    i += 1
                    if (i < chars.size && (chars[i] == 0x2B || chars[i] == 0x2D)) {
                        i += 1
                    }
                    while (i < chars.size && isDigit(chars[i])) {
                        i += 1
                    }
                }
                tokens.add(Token(TokenKind.Number, String.fromUtf8(chars[start..i]), start))
                continue
            }
            if (isIdentStart(byte)) {
                let start = i
                while (i < chars.size && isIdentPart(chars[i])) {
                    i += 1
                }
                tokens.add(Token(TokenKind.Ident, String.fromUtf8(chars[start..i]), start))
                continue
            }
            if (byte == 0x3F) {
                tokens.add(Token(TokenKind.Question, '?', i))
                i += 1
                continue
            }
            if (byte == 0x28) {
                tokens.add(Token(TokenKind.LParen, '(', i))
                i += 1
                continue
            }
            if (byte == 0x29) {
                tokens.add(Token(TokenKind.RParen, ')', i))
                i += 1
                continue
            }
            if (byte == 0x2C) {
                tokens.add(Token(TokenKind.Comma, ',', i))
                i += 1
                continue
            }
            if (byte == 0x3B) {
                tokens.add(Token(TokenKind.Semicolon, ';', i))
                i += 1
                continue
            }
            if (byte == 0x2E) {
                tokens.add(Token(TokenKind.Dot, '.', i))
                i += 1
                continue
            }
            if (isOperatorStart(byte)) {
                let start = i
                i += 1
                if (i < chars.size) {
                    let next = chars[i]
                    if ((byte == 0x3C && (next == 0x3D || next == 0x3E)) ||
                        (byte == 0x3E && next == 0x3D) || (byte == 0x21 && next == 0x3D)) {
                        i += 1
                    }
                }
                tokens.add(Token(TokenKind.Operator, String.fromUtf8(chars[start..i]), start))
                continue
            }
            throw syntax('unexpected character', i)
        }
        tokens.add(Token(TokenKind.End, '', chars.size))
        tokens.toArray()
    }

    private static func isSpace(byte: UInt8): Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isDigit(byte: UInt8): Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isIdentStart(byte: UInt8): Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
            byte == 0x5F || byte == 0x24
    }

    private static func isIdentPart(byte: UInt8): Bool {
        isIdentStart(byte) || isDigit(byte)
    }

    private static func isOperatorStart(byte: UInt8): Bool {
        byte == 0x3D || byte == 0x3C || byte == 0x3E || byte == 0x21 ||
            byte == 0x2B || byte == 0x2D || byte == 0x2A || byte == 0x2F
    }

    private static func syntax(message: String, position: Int64): FdbmException {
        FdbmException(DbdErrorCode.SQL_SYNTAX, '${message} at position ${position}')
    }
}
