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
package fountain::f_jit.compiler

import std.collection.ArrayList
import fountain::f_base.UnsafeBytes

/**
 * 词法分析器（S3.2–S3.6）——design-m1 §4.3.1 / §4.4、规格 §8.5（注释与词法保护）、
 * §8.8（字符串三形态与行首锚定标记）、§11.9（字面值类型规则）。
 *
 * **成员面（design §4.3.1）**：有状态扫描器 ⇒ class；全部成员 = 构造 + `next` +
 * `position`/`line`/`column`（外加两个 §3.3 / S3.12 需要的窄访问器）。
 * `next()` 契约 = 「返回已判定合法的 token 或 `EOF`」，**非法输入即抛**（fail-fast，
 * **没有 error token**，理由见 `Token.cj` 文件头）。
 *
 * **处理顺序（冻结，§8.5 + §8.8）**：
 *
 * 1. 构造：整串**换行规范化**（CRLF / CR → LF，对整串一次）——跨平台常量字节与行列一致（P3）；
 * 2. 每 token：跳过空白与注释（多行注释**嵌套配平**）；
 * 3. 遇引号则**整枚字符串一次扫完**（含插值内的花括号 / 引号配对跳过）⇒
 *    串跨度内的「斜杠注释起始、引号、花括号、`>|`」天然不被后续任何规则识别
 *    ——与「① 字符串保护 → ② 注释剥离 → ③ 解析」三阶段语义等价（§8.5 冻结顺序）；
 * 4. 串体内部：**② 定界扫描取原始串体 → ③ `>|` 锚定截取 → ④ 转义解码 → ⑤ 插值切分**（S3.12）。
 */
internal class Lexer {
    /** 换行规范化之后的源码（诊断 `lineText` 与位置口径同源）。 */
    public let source: String
    private let bs: Array<UInt8>
    /** 当前字节游标（= `position()`）。 */
    private var cur: Int64 = 0
    private var curLine: Int64 = 1
    private var curColumn: Int64 = 1
    /** 上一个返回的 token kind——供斜杠的「正则 vs 除法」消歧使用。 */
    private var prevKind: TokenKind = TokenKind.EOF
    /** 最近一次返回的 `RegexLit` 的 flags 位域（§3.3：bit0=i bit1=m bit2=u）。 */
    private var regexFlags: UInt8 = 0u8

    /**
     * 绑定源码。**构造时对整串做一次换行规范化**（design §4.3.1）：
     * CRLF / 单个 CR 一律折算为 LF，使多行 / 原始串常量字节与行列计数跨平台一致。
     */
    public init(source: String) {
        this.source = Lexer.normalizeNewlines(source)
        this.bs = this.source.unsafeBytes()
    }

    /** 当前位置（基于**规范化后**的源码；design §4.3.1）。 */
    public func position(): Int64 {
        this.cur
    }

    /** 当前行（1 起）。 */
    public func line(): Int64 {
        this.curLine
    }

    /** 当前列（1 起，**Unicode 码点**——多字节字符按一个码点计）。 */
    public func column(): Int64 {
        this.curColumn
    }

    /** 最近一次 `RegexLit` 的 flags 位域（`Token` 只有 6 字段，flags 经本访问器送出）。 */
    public func lastRegexFlags(): UInt8 {
        this.regexFlags
    }

    /**
     * 取下一 token；到源码末尾后恒返回 `EOF`（幂等，不推进游标）。
     *
     * `nlBefore` = 本 token 之前（跳过空白与**注释**时）跨过了换行——**注释跨行同样算**（S3.2）。
     */
    public func next(): Token {
        let nl = this.skipTrivia()
        let start = this.cur
        let startLine = this.curLine
        let startCol = this.curColumn
        if (this.cur >= this.bs.size) {
            this.prevKind = TokenKind.EOF
            return Token(TokenKind.EOF, '', start, startLine, startCol, nl)
        }
        let t = this.scanOne(start, startLine, startCol, nl)
        this.prevKind = t.kind
        t
    }

    /** 一次性取到 EOF（测试便利；生产路径只用 `next()`）。 */
    public func tokenize(): Array<Token> {
        var out = ArrayList<Token>()
        while (true) {
            let t = this.next()
            out.add(t)
            if (t.kind == TokenKind.EOF) {
                break
            }
        }
        out.toArray()
    }

    // ------------------------------------------------------------------
    // 换行规范化
    // ------------------------------------------------------------------

    /**
     * CRLF / CR → LF（§8.8「换行规范化（钉死，跨平台编译一致）」）。
     *
     * 为什么单独 CR 也折算：部分来源以单个 CR 作行结束符；不折算会让同一源码在不同平台
     * 编译出**不同的常量字节**（违反 P3）。
     */
    internal static func normalizeNewlines(src: String): String {
        let srcBytes = src.unsafeBytes()
        var out = ArrayList<UInt8>()
        var p = 0
        while (p < srcBytes.size) {
            let b = srcBytes[p]
            if (b == 0x0Du8) {
                out.add(0x0Au8)
                if (p + 1 < srcBytes.size && srcBytes[p + 1] == 0x0Au8) {
                    p = p + 1
                }
            } else {
                out.add(b)
            }
            p = p + 1
        }
        String.fromUtf8(out.toArray())
    }

    // ------------------------------------------------------------------
    // 位置推进（列按码点）
    // ------------------------------------------------------------------

    /** 消费 1 字节并维护 line/column：UTF-8 续字节（0x80–0xBF）不增列 ⇒ 列 = 码点数。 */
    private func bump(): Unit {
        let b = this.bs[this.cur]
        if (b == 0x0Au8) {
            this.curLine = this.curLine + 1
            this.curColumn = 1
        } else if (b < 0x80u8 || b > 0xBFu8) {
            this.curColumn = this.curColumn + 1
        }
        this.cur = this.cur + 1
    }

    /** 从当前位置推进到 `target`（保持 line/column 记账正确）。 */
    private func advanceTo(target: Int64): Unit {
        while (this.cur < target) {
            this.bump()
        }
    }

    private func at(k: Int64): UInt8 {
        let idx = this.cur + k
        if (idx < 0 || idx >= this.bs.size) {
            0u8
        } else {
            this.bs[idx]
        }
    }

    private func isEof(): Bool {
        this.cur >= this.bs.size
    }

    // ------------------------------------------------------------------
    // 空白与注释剥离
    // ------------------------------------------------------------------

    /**
     * 跳过空白与注释，返回**是否跨过换行**（驱动 `Token.nlBefore`）。
     *
     * 单行注释至行尾；多行注释**支持嵌套**（§8.5：与仓颉一致，维护深度，起始符 +1、
     * 结束符 −1，归零结束）；源码结束仍深度 > 0 → `UnterminatedComment`。
     * 注释内容不参与词法（其中的引号 / 花括号 / 起始序列均无语义）。
     */
    private func skipTrivia(): Bool {
        var nl = false
        while (!this.isEof()) {
            let b = this.bs[this.cur]
            if (b == 0x0Au8) {
                nl = true
                this.bump()
            } else if (b == 0x20u8 || b == 0x09u8 || b == 0x0Bu8 || b == 0x0Cu8) {
                this.bump()
            } else if (b == 0x2Fu8 && this.at(1) == 0x2Fu8) {
                while (!this.isEof() && this.bs[this.cur] != 0x0Au8) {
                    this.bump()
                }
            } else if (b == 0x2Fu8 && this.at(1) == 0x2Au8) {
                let startLine = this.curLine
                let startCol = this.curColumn
                let startPos = this.cur
                var depth: Int64 = 0
                while (!this.isEof()) {
                    if (this.bs[this.cur] == 0x2Fu8 && this.at(1) == 0x2Au8) {
                        depth = depth + 1
                        this.bump()
                        this.bump()
                    } else if (this.bs[this.cur] == 0x2Au8 && this.at(1) == 0x2Fu8) {
                        depth = depth - 1
                        this.bump()
                        this.bump()
                        if (depth <= 0) {
                            break
                        }
                    } else {
                        if (this.bs[this.cur] == 0x0Au8) {
                            nl = true
                        }
                        this.bump()
                    }
                }
                if (depth > 0) {
                    diagFail(DiagKind.UNTERMINATED_COMMENT, this.source, startPos, startLine, startCol,
                        '多行注释未闭合（支持嵌套：少一个结束符配平）')
                }
            } else {
                break
            }
        }
        nl
    }

    // ------------------------------------------------------------------
    // 主分派
    // ------------------------------------------------------------------

    private func scanOne(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        let b = this.bs[this.cur]
        if (b >= 0x30u8 && b <= 0x39u8) {
            return this.scanNumber(start, startLine, startCol, nl)
        }
        if (Lexer.isIdentStart(b)) {
            if (b == 0x5Fu8 && !Lexer.isIdentPart(this.at(1))) {
                this.bump()
                return Token(TokenKind.Underscore, '_', start, startLine, startCol, nl)
            }
            return this.scanIdent(start, startLine, startCol, nl)
        }
        if (b == 0x27u8 || b == 0x22u8) {
            return this.scanString(start, startLine, startCol, nl)
        }
        if (b == 0x23u8) {
            return this.scanRawString(start, startLine, startCol, nl)
        }
        if (b == 0x60u8) {
            return this.scanJson(start, startLine, startCol, nl)
        }
        if (b == 0x2Fu8) {
            if (Lexer.canStartRegex(this.prevKind)) {
                return this.scanRegex(start, startLine, startCol, nl)
            }
        }
        return this.scanOp(start, startLine, startCol, nl)
    }

    private static func isIdentStart(b: UInt8): Bool {
        (b >= 0x41u8 && b <= 0x5Au8) || (b >= 0x61u8 && b <= 0x7Au8) || b == 0x5Fu8
    }

    private static func isIdentPart(b: UInt8): Bool {
        isIdentStart(b) || (b >= 0x30u8 && b <= 0x39u8)
    }

    /**
     * 斜杠能否起始正则字面量（§11.9「替换段词法」+ design §4.3.1 消歧要求）。
     *
     * **上一个 token 是「值」或闭合符时按除法**；否则起始正则。这是三形态替换
     * （无 flags 字面量 / 带 flags 字面量 / 正则变量）能被识别的前提：
     * `RegexLit` 之后的斜杠必须是 `Slash`（分隔符），而不是开启新的正则。
     */
    private static func canStartRegex(prev: TokenKind): Bool {
        match (prev) {
            case TokenKind.Ident | TokenKind.IntLit | TokenKind.DecLit | TokenKind.F64Lit |
                TokenKind.StrLit | TokenKind.RegexLit | TokenKind.JsonLit | TokenKind.RParen |
                TokenKind.RBracket | TokenKind.RBrace | TokenKind.Underscore |
                TokenKind.KwTrue | TokenKind.KwFalse | TokenKind.KwNull => false
            case _ => true
        }
    }

    private func scanIdent(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        while (!this.isEof() && Lexer.isIdentPart(this.bs[this.cur])) {
            this.bump()
        }
        let text = Lexer.sliceStr(this.bs, start, this.cur)
        Token(Lexer.keywordOf(text), text, start, startLine, startCol, nl)
    }

    /** 关键字表（design §4.3.1「类型名不作独立 kind」——`Int64` / `String` 等一律 `Ident`）。 */
    private static func keywordOf(text: String): TokenKind {
        match (text) {
            case 'recursive' => TokenKind.KwRecursive
            case 'let' => TokenKind.KwLet
            case 'var' => TokenKind.KwVar
            case 'if' => TokenKind.KwIf
            case 'else' => TokenKind.KwElse
            case 'while' => TokenKind.KwWhile
            case 'for' => TokenKind.KwFor
            case 'in' => TokenKind.KwIn
            case 'where' => TokenKind.KwWhere
            case 'break' => TokenKind.KwBreak
            case 'continue' => TokenKind.KwContinue
            case 'return' => TokenKind.KwReturn
            case 'true' => TokenKind.KwTrue
            case 'false' => TokenKind.KwFalse
            case 'null' => TokenKind.KwNull
            case 'as' => TokenKind.KwAs
            case 'is' => TokenKind.KwIs
            case _ => TokenKind.Ident
        }
    }

    // ------------------------------------------------------------------
    // 数字（§11.9 字面值类型规则）
    // ------------------------------------------------------------------

    /**
     * 整数 → `IntLit`；含小数部或指数部 → `DecLit`；带 `f64` 后缀 → `F64Lit`。
     *
     * **超 Int64 域是合法输入**（§11.9：降级为 Decimal 常量 scale 0），因此这里**不判值域**，
     * 只判**字形**：`1.2.3` / `3e` / `12abc` → `BadNumber`（design §4.3.1 策略 ④）。
     */
    private func scanNumber(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        while (!this.isEof() && this.bs[this.cur] >= 0x30u8 && this.bs[this.cur] <= 0x39u8) {
            this.bump()
        }
        var frac = false
        var exp = false
        if (this.at(0) == 0x2Eu8 && this.at(1) >= 0x30u8 && this.at(1) <= 0x39u8) {
            frac = true
            this.bump()
            while (!this.isEof() && this.bs[this.cur] >= 0x30u8 && this.bs[this.cur] <= 0x39u8) {
                this.bump()
            }
        }
        if (this.at(0) == 0x65u8 || this.at(0) == 0x45u8) {
            exp = true
            this.bump()
            if (this.at(0) == 0x2Bu8 || this.at(0) == 0x2Du8) {
                this.bump()
            }
            if (!(this.at(0) >= 0x30u8 && this.at(0) <= 0x39u8)) {
                diagFail(DiagKind.BAD_NUMBER, this.source, start, startLine, startCol,
                    '指数部缺数字（形如 3e2 / 1e-3；§11.9）')
            }
            while (!this.isEof() && this.bs[this.cur] >= 0x30u8 && this.bs[this.cur] <= 0x39u8) {
                this.bump()
            }
        }
        // 后缀 f64 → Float64 字面量（§11.9「Float64 值来源：显式标注的字面值」）
        if (this.at(0) == 0x66u8 && this.at(1) == 0x36u8 && this.at(2) == 0x34u8) {
            let end = this.cur
            this.bump()
            this.bump()
            this.bump()
            return Token(TokenKind.F64Lit, Lexer.sliceStr(this.bs, start, end), start, startLine, startCol, nl)
        }
        if (this.at(0) == 0x2Eu8 && this.at(1) >= 0x30u8 && this.at(1) <= 0x39u8) {
            diagFail(DiagKind.BAD_NUMBER, this.source, start, startLine, startCol, '数字字面量中出现多个小数点')
        }
        if (!this.isEof() && Lexer.isIdentStart(this.bs[this.cur])) {
            diagFail(DiagKind.BAD_NUMBER, this.source, start, startLine, startCol,
                '数字字面量紧邻标识符字符（如需浮点后缀请写 f64）')
        }
        let kind = if (frac || exp) { TokenKind.DecLit } else { TokenKind.IntLit }
        Token(kind, Lexer.sliceStr(this.bs, start, this.cur), start, startLine, startCol, nl)
    }

    // ------------------------------------------------------------------
    // 字符串三形态（§8.8 / design §4.4）
    // ------------------------------------------------------------------

    /**
     * 单行 / 多行形态。三引号**最长匹配**（§8.8「词法消歧（钉死）」）：起始处连续三个同种引号
     * 一律按多行定界识别——空单行串后紧邻引号串的写法需改用另一种引号或插入分隔。
     */
    private func scanString(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        let q = this.bs[this.cur]
        let triple = this.at(1) == q && this.at(2) == q
        if (!triple) {
            this.bump()
            let bodyStart = this.cur
            let end = this.findBodyEnd(q, false, start, startLine, startCol, DiagKind.UNTERMINATED_STRING)
            let raw = Lexer.sliceStr(this.bs, bodyStart, end)
            this.advanceTo(end + 1)
            return Token(TokenKind.StrLit, Lexer.decodeEscapes(raw, this.source, start, startLine, startCol),
                start, startLine, startCol, nl)
        }
        this.bump()
        this.bump()
        this.bump()
        while (this.at(0) == 0x20u8 || this.at(0) == 0x09u8) {
            this.bump()
        }
        if (this.isEof()) {
            diagFail(DiagKind.UNTERMINATED_MULTILINE_STRING, this.source, start, startLine, startCol,
                '多行串未闭合（缺终止三引号）')
        }
        if (this.bs[this.cur] != 0x0Au8) {
            diagFail(DiagKind.MULTILINE_HEAD_CONTENT, this.source, start, startLine, startCol,
                '多行串开头三引号之后必须换行（同行不得出现非空白内容；§8.8）')
        }
        this.bump()
        let bodyStart = this.cur
        let end = this.findBodyEnd(q, true, start, startLine, startCol, DiagKind.UNTERMINATED_MULTILINE_STRING)
        let raw = Lexer.sliceStr(this.bs, bodyStart, end)
        this.advanceTo(end + 3)
        // 处理顺序（冻结）：锚定截取 → 转义解码（插值 `${…}` 原文保留，切分留给 S3.12）
        let anchored = dedentAnchored(raw)
        return Token(TokenKind.StrLit, Lexer.decodeEscapes(anchored, this.source, start, startLine, startCol),
            start, startLine, startCol, nl)
    }

    /**
     * 反引号 JSON 字面量（m3 §11 / D4）：`` `{…}` `` / `` `[…]` ``。
     *
     * 内容**零宿主转义**——`"`、`\` 原样保留（JSON 自身的转义交给 JSON 解析器消费），可跨行。
     * 取界 = **下一个反引号**：段内的行注释、块注释、引号、`{}`、行首锚定标记都不进入扫描逻辑，
     * 因而天然不会被当成注释、字符串或括号配对。
     */
    private func scanJson(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        this.bump()
        let bodyStart = this.cur
        while (!this.isEof() && this.bs[this.cur] != 0x60u8) {
            this.bump()
        }
        if (this.isEof()) {
            diagFail(DiagKind.UNTERMINATED_STRING, this.source, start, startLine, startCol,
                'JSON 字面量缺少闭合反引号（`` `{…}` `` / `` `[…]` ``，m3 §11）')
        }
        let text = Lexer.sliceStr(this.bs, bodyStart, this.cur)
        this.bump()
        Token(TokenKind.JsonLit, text, start, startLine, startCol, nl)
    }

    /**
     * 原始串（`#`×n + 引号，n ≥ 1）：至**相同引号 + 相同数量 `#`** 为止（§8.8「仓颉一致」）。
     *
     * verbatim：不转义、不插值（`${` 为字面文本）、不支持锚定；可跨行（换行与缩进逐字节保留）。
     * 内容中含更少 `#` 的引号序列**不终止**。
     */
    private func scanRawString(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        var hashes: Int64 = 0
        while (!this.isEof() && this.bs[this.cur] == 0x23u8) {
            hashes = hashes + 1
            this.bump()
        }
        if (hashes < 1) {
            diagFail(DiagKind.ILLEGAL_CHARACTER, this.source, start, startLine, startCol, '原始串缺 # 定界符')
        }
        if (this.isEof() || (this.bs[this.cur] != 0x27u8 && this.bs[this.cur] != 0x22u8)) {
            diagFail(DiagKind.UNTERMINATED_RAW_STRING, this.source, start, startLine, startCol,
                '原始串的 # 之后缺起始引号（§8.8）')
        }
        let q = this.bs[this.cur]
        this.bump()
        let bodyStart = this.cur
        while (true) {
            if (this.isEof()) {
                diagFail(DiagKind.UNTERMINATED_RAW_STRING, this.source, start, startLine, startCol,
                    '原始串未闭合（缺「相同引号 + 相同数量 #」终止序列；§8.8）')
            }
            if (this.bs[this.cur] == q) {
                var k: Int64 = 0
                while (k < hashes && this.cur + 1 + k < this.bs.size && this.bs[this.cur + 1 + k] == 0x23u8) {
                    k = k + 1
                }
                if (k == hashes) {
                    break
                }
            }
            this.bump()
        }
        let body = Lexer.sliceStr(this.bs, bodyStart, this.cur)
        this.advanceTo(this.cur + 1 + hashes)
        Token(TokenKind.StrLit, body, start, startLine, startCol, nl)
    }

    /**
     * 定界扫描：自当前游标起找闭合定界符的起点，返回其下标（**不推进游标**）。
     * 顺带完成转义形态校验与插值跨度的花括号 / 引号配对跳过。
     */
    private func findBodyEnd(q: UInt8, triple: Bool, start: Int64, startLine: Int64, startCol: Int64,
        unterminatedKind: String): Int64 {
        var p = this.cur
        let n = this.bs.size
        while (p < n) {
            let b = this.bs[p]
            if (b == 0x5Cu8) {
                p = p + Lexer.escapeLen(this.bs, p, this.source, start, startLine, startCol)
                continue
            }
            if (b == q) {
                if (!triple) {
                    return p
                }
                if (p + 2 < n && this.bs[p + 1] == q && this.bs[p + 2] == q) {
                    if (Lexer.oddBackslashesBefore(this.bs, p)) {
                        p = p + 3
                        continue
                    }
                    return p
                }
                p = p + 1
                continue
            }
            if (b == 0x24u8 && p + 1 < n && this.bs[p + 1] == 0x7Bu8) {
                p = Lexer.skipInterp(this.bs, p, this.source, start, startLine, startCol)
                continue
            }
            if (b == 0x0Au8 && !triple) {
                diagFail(unterminatedKind, this.source, start, startLine, startCol,
                    '单行字符串不得跨行（跨行请改用多行串或原始串；§8.8）')
            }
            p = p + 1
        }
        diagFail(unterminatedKind, this.source, start, startLine, startCol, '字符串未闭合')
    }

    /** 转义序列长度（含反斜杠本身）；非法转义 → `BadEscape`。 */
    private static func escapeLen(bs: Array<UInt8>, p: Int64, src: String, sx: Int64, sy: Int64, sc: Int64): Int64 {
        if (p + 1 >= bs.size) {
            diagFail(DiagKind.BAD_ESCAPE, src, sx, sy, sc, '转义符位于源码末尾（单独反斜杠 → 编译错误；§8.8）')
        }
        let c = bs[p + 1]
        // \n \t \r \b \f \\ \' \" \0 —— 单字符转义
        let single = c == 0x6Eu8 || c == 0x74u8 || c == 0x72u8 || c == 0x62u8 || c == 0x66u8 ||
            c == 0x5Cu8 || c == 0x27u8 || c == 0x22u8 || c == 0x30u8
        if (single) {
            return 2
        }
        if (c == 0x75u8) {
            if (p + 2 < bs.size && bs[p + 2] == 0x7Bu8) {
                var k = p + 3
                var digits: Int64 = 0
                while (k < bs.size && bs[k] != 0x7Du8) {
                    let h = bs[k]
                    if (!((h >= 0x30u8 && h <= 0x39u8) || (h >= 0x41u8 && h <= 0x46u8) ||
                        (h >= 0x61u8 && h <= 0x66u8))) {
                        diagFail(DiagKind.BAD_ESCAPE, src, sx, sy, sc, '码点转义内含非十六进制字符')
                    }
                    digits = digits + 1
                    k = k + 1
                }
                if (k >= bs.size || digits == 0 || digits > 6) {
                    diagFail(DiagKind.BAD_ESCAPE, src, sx, sy, sc, '码点转义需 1–6 位十六进制并以右花括号闭合')
                }
                return (k - p) + 1
            }
            diagFail(DiagKind.BAD_ESCAPE, src, sx, sy, sc, 'u 转义必须后跟花括号包裹的码点')
        }
        diagFail(DiagKind.BAD_ESCAPE, src, sx, sy, sc,
            '非法转义序列（合法：换行 制表 回车 退格 换页 反斜杠 引号 空字符 码点；多行串内单独反斜杠亦非法）')
    }

    /** `p` 之前连续反斜杠个数的奇偶性（奇数 ⇒ 该三引号被转义，不终止多行串）。 */
    private static func oddBackslashesBefore(bs: Array<UInt8>, p: Int64): Bool {
        var k = p - 1
        var cnt: Int64 = 0
        while (k >= 0 && bs[k] == 0x5Cu8) {
            cnt = cnt + 1
            k = k - 1
        }
        cnt % 2 == 1
    }

    /**
     * 跳过插值跨度：花括号配平（嵌套 `${` 由左花括号计数自然覆盖），其内可含字符串字面量
     * ——这是「字符串跨度内的花括号与引号不参与识别」（§8.5 / S3.5）的兑现。
     * 源码结束前未配平 → `UnterminatedString`（design §4.3.1「插值未闭合」）。
     */
    private static func skipInterp(bs: Array<UInt8>, p: Int64, src: String, sx: Int64, sy: Int64,
        sc: Int64): Int64 {
        var q = p + 2
        var depth: Int64 = 1
        let n = bs.size
        while (q < n) {
            let b = bs[q]
            if (b == 0x7Bu8) {
                depth = depth + 1
            } else if (b == 0x7Du8) {
                depth = depth - 1
                if (depth == 0) {
                    return q + 1
                }
            } else if (b == 0x27u8 || b == 0x22u8) {
                let qch = b
                if (q + 2 < n && bs[q + 1] == qch && bs[q + 2] == qch) {
                    q = q + 3
                    while (q + 2 < n) {
                        if (bs[q] == qch && bs[q + 1] == qch && bs[q + 2] == qch) {
                            break
                        }
                        if (bs[q] == 0x5Cu8) {
                            q = q + 1
                        }
                        q = q + 1
                    }
                    q = q + 3
                    continue
                }
                q = q + 1
                while (q < n && bs[q] != qch) {
                    if (bs[q] == 0x5Cu8) {
                        q = q + 1
                    }
                    q = q + 1
                }
                q = q + 1
                continue
            }
            q = q + 1
        }
        diagFail(DiagKind.UNTERMINATED_STRING, src, sx, sy, sc, '插值未闭合（缺右花括号）')
    }

    /**
     * 转义解码（**保留插值原文**：锚定 → 转义 → 插值切分的冻结顺序里本步是第二步，
     * 切分留给 S3.12 的前端糖阶段）。
     */
    internal static func decodeEscapes(s: String, src: String, sx: Int64, sy: Int64, sc: Int64): String {
        let bs = s.unsafeBytes()
        var out = ArrayList<UInt8>()
        var p = 0
        let n = bs.size
        while (p < n) {
            let b = bs[p]
            if (b == 0x24u8 && p + 1 < n && bs[p + 1] == 0x7Bu8) {
                let end = Lexer.skipInterp(bs, p, src, sx, sy, sc)
                for (k in p..end) {
                    out.add(bs[k])
                }
                p = end
                continue
            }
            if (b == 0x5Cu8) {
                let c = bs[p + 1]
                if (c == 0x6Eu8) {
                    out.add(0x0Au8)
                } else if (c == 0x74u8) {
                    out.add(0x09u8)
                } else if (c == 0x72u8) {
                    out.add(0x0Du8)
                } else if (c == 0x62u8) {
                    out.add(0x08u8)
                } else if (c == 0x66u8) {
                    out.add(0x0Cu8)
                } else if (c == 0x30u8) {
                    out.add(0x00u8)
                } else if (c == 0x75u8) {
                    var k = p + 3
                    var cp: UInt32 = 0u32
                    while (bs[k] != 0x7Du8) {
                        let h = bs[k]
                        let v: UInt32 = if (h >= 0x30u8 && h <= 0x39u8) {
                            UInt32(h - 0x30u8)
                        } else if (h >= 0x41u8 && h <= 0x46u8) {
                            UInt32(h - 0x41u8 + 10u8)
                        } else {
                            UInt32(h - 0x61u8 + 10u8)
                        }
                        cp = cp * 16u32 + v
                        k = k + 1
                    }
                    Lexer.appendUtf8(out, cp)
                    p = k + 1
                    continue
                } else {
                    out.add(c)
                }
                p = p + 2
                continue
            }
            out.add(b)
            p = p + 1
        }
        String.fromUtf8(out.toArray())
    }

    /** 码点 → UTF-8 字节追加（被调用点保证 cp 合法）。 */
    private static func appendUtf8(out: ArrayList<UInt8>, cp: UInt32): Unit {
        if (cp < 0x80u32) {
            out.add(UInt8(cp))
        } else if (cp < 0x800u32) {
            out.add(UInt8(cp / 64u32) | 0xC0u8)
            out.add(UInt8(cp % 64u32) | 0x80u8)
        } else if (cp < 0x10000u32) {
            out.add(UInt8(cp / 4096u32) | 0xE0u8)
            out.add(UInt8((cp / 64u32) % 64u32) | 0x80u8)
            out.add(UInt8(cp % 64u32) | 0x80u8)
        } else {
            out.add(UInt8(cp / 262144u32) | 0xF0u8)
            out.add(UInt8((cp / 4096u32) % 64u32) | 0x80u8)
            out.add(UInt8((cp / 64u32) % 64u32) | 0x80u8)
            out.add(UInt8(cp % 64u32) | 0x80u8)
        }
    }

    // ------------------------------------------------------------------
    // 正则字面量（§3.3 / §11.9）
    // ------------------------------------------------------------------

    /**
     * `/pattern/flags`：两个斜杠之间为 pattern（UTF-8），尾随 flags 取自 `i m u` 三字符——
     * **顺序无关、重复幂等**（§3.3），归一为位域 bit0=i bit1=m bit2=u。
     *
     * 字符类内（方括号之间）的斜杠不终止；反斜杠转义其后的斜杠。
     * 非法 pattern / flags **不在词法层判**（加载期错误码 14，design §4.3.1「边界」）。
     */
    private func scanRegex(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        this.bump()
        let bodyStart = this.cur
        var inClass = false
        while (true) {
            if (this.isEof()) {
                diagFail(DiagKind.UNTERMINATED_REGEX, this.source, start, startLine, startCol,
                    '正则字面量缺闭合斜杠（形如 /pattern/flags；§3.3）')
            }
            let b = this.bs[this.cur]
            if (b == 0x5Cu8) {
                this.bump()
                if (!this.isEof()) {
                    this.bump()
                }
                continue
            }
            if (b == 0x5Bu8) {
                inClass = true
            } else if (b == 0x5Du8) {
                inClass = false
            } else if (b == 0x2Fu8 && !inClass) {
                break
            }
            this.bump()
        }
        let pattern = Lexer.sliceStr(this.bs, bodyStart, this.cur)
        this.bump()
        var bits: UInt8 = 0u8
        while (!this.isEof()) {
            let f = this.bs[this.cur]
            if (f == 0x69u8) {
                bits = bits | 0x01u8
            } else if (f == 0x6Du8) {
                bits = bits | 0x02u8
            } else if (f == 0x75u8) {
                bits = bits | 0x04u8
            } else {
                break
            }
            this.bump()
        }
        this.regexFlags = bits
        Token(TokenKind.RegexLit, pattern, start, startLine, startCol, nl)
    }

    // ------------------------------------------------------------------
    // 标点与运算符（design §4.3.1 全表）
    // ------------------------------------------------------------------

    /** 最长匹配优先；无法归类 → `IllegalCharacter`（**没有 error token**）。 */
    private func scanOp(start: Int64, startLine: Int64, startCol: Int64, nl: Bool): Token {
        let b = this.bs[this.cur]
        let n1 = this.at(1)
        let n2 = this.at(2)
        var k: TokenKind = TokenKind.EOF
        var len: Int64 = 1
        if (b == 0x3Du8 && n1 == 0x3Eu8) {
            k = TokenKind.Arrow
            len = 2
        } else if (b == 0x3Du8 && n1 == 0x3Du8) {
            k = TokenKind.EqEq
            len = 2
        } else if (b == 0x21u8 && n1 == 0x3Du8) {
            k = TokenKind.NotEq
            len = 2
        } else if (b == 0x21u8 && n1 == 0x7Eu8) {
            k = TokenKind.BangTilde
            len = 2
        } else if (b == 0x3Cu8 && n1 == 0x3Du8) {
            k = TokenKind.Le
            len = 2
        } else if (b == 0x3Eu8 && n1 == 0x3Du8) {
            k = TokenKind.Ge
            len = 2
        } else if (b == 0x26u8 && n1 == 0x26u8) {
            k = TokenKind.AndAnd
            len = 2
        } else if (b == 0x7Cu8 && n1 == 0x7Cu8) {
            k = TokenKind.OrOr
            len = 2
        } else if (b == 0x3Cu8 && n1 == 0x3Cu8) {
            k = TokenKind.Shl
            len = 2
        } else if (b == 0x3Eu8 && n1 == 0x3Eu8) {
            k = TokenKind.Shr
            len = 2
        } else if (b == 0x3Fu8 && n1 == 0x3Fu8) {
            // `??`（M2.2）：单 `?` 不属于任何合法词法单元，仍走 ILLEGAL_CHARACTER
            k = TokenKind.QuestionQuestion
            len = 2
        } else if (b == 0x2Eu8 && n1 == 0x2Eu8 && n2 == 0x3Du8) {
            k = TokenKind.DotDotEq
            len = 3
        } else if (b == 0x2Eu8 && n1 == 0x2Eu8) {
            k = TokenKind.DotDot
            len = 2
        } else {
            k = Lexer.singleOpOf(b)
            if (k == TokenKind.EOF) {
                diagFail(DiagKind.ILLEGAL_CHARACTER, this.source, start, startLine, startCol,
                    '不属于任何合法词法单元的字符（0x${Lexer.hex2(b)}）')
            }
        }
        this.advanceTo(start + len)
        Token(k, Lexer.sliceStr(this.bs, start, this.cur), start, startLine, startCol, nl)
    }

    private static func singleOpOf(b: UInt8): TokenKind {
        match (b) {
            case 0x2Bu8 => TokenKind.Plus
            case 0x2Du8 => TokenKind.Minus
            case 0x2Au8 => TokenKind.Star
            case 0x2Fu8 => TokenKind.Slash
            case 0x25u8 => TokenKind.Percent
            case 0x3Du8 => TokenKind.Assign
            case 0x3Cu8 => TokenKind.Lt
            case 0x3Eu8 => TokenKind.Gt
            case 0x21u8 => TokenKind.Bang
            case 0x26u8 => TokenKind.Amp
            case 0x7Cu8 => TokenKind.Pipe
            case 0x5Eu8 => TokenKind.Caret
            case 0x7Eu8 => TokenKind.Tilde
            case 0x28u8 => TokenKind.LParen
            case 0x29u8 => TokenKind.RParen
            case 0x7Bu8 => TokenKind.LBrace
            case 0x7Du8 => TokenKind.RBrace
            case 0x5Bu8 => TokenKind.LBracket
            case 0x5Du8 => TokenKind.RBracket
            case 0x2Cu8 => TokenKind.Comma
            case 0x3Au8 => TokenKind.Colon
            case 0x2Eu8 => TokenKind.Dot
            case 0x3Bu8 => TokenKind.Semi
            case _ => TokenKind.EOF
        }
    }

    /**
     * 锚定行的输出：跳过前导空白后以 `>|` 开头 ⇒ 只写标记之后的全部字符；
     * 否则整行原样（design §4.4「非标记行处理」）。
     */
    internal static func emitAnchoredLine(out: ArrayList<UInt8>, bs: Array<UInt8>, from: Int64, to: Int64): Unit {
        var k = from
        while (k < to && (bs[k] == 0x20u8 || bs[k] == 0x09u8)) {
            k = k + 1
        }
        if (k + 1 < to && bs[k] == 0x3Eu8 && bs[k + 1] == 0x7Cu8) {
            k = k + 2
        } else {
            k = from
        }
        for (i in k..to) {
            out.add(bs[i])
        }
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    internal static func sliceStr(bs: Array<UInt8>, from: Int64, to: Int64): String {
        let n = to - from
        if (n <= 0) {
            return ''
        }
        let out = Array<UInt8>(n, repeat: 0u8)
        for (i in 0..n) {
            out[i] = bs[from + i]
        }
        String.fromUtf8(out)
    }

    internal static func hex2(b: UInt8): String {
        '${Lexer.hexDigit(b / 16u8)}${Lexer.hexDigit(b % 16u8)}'
    }

    private static func hexDigit(v: UInt8): String {
        match (v) {
            case 0u8 => '0'
            case 1u8 => '1'
            case 2u8 => '2'
            case 3u8 => '3'
            case 4u8 => '4'
            case 5u8 => '5'
            case 6u8 => '6'
            case 7u8 => '7'
            case 8u8 => '8'
            case 9u8 => '9'
            case 10u8 => 'A'
            case 11u8 => 'B'
            case 12u8 => 'C'
            case 13u8 => 'D'
            case _ => 'F'
        }
    }
}

/**
 * 多行串「行首锚定标记」`>|` 的**纯函数式后处理**（design §4.4「无状态、可单测」）。
 *
 * 逐行规则（design §4.4「逐行无状态等价」——两模式下非标记行处理完全相同，无需先扫全文判模式）：
 *
 * - 跳过前导空白后以 `>|` 开头 ⇒ 消耗「前导空白 + 标记」，其后**全部字符**为内容
 *   （其中再出现的 `>|` 一律是字面文本——**首现语义**）；单独标记行 ⇒ 内容为空串；
 * - 否则 **整行原样保留**（不截取、不归一）：空白行、含内容的行、非首位标记（如 `a>|b`）都在此列。
 */
internal func dedentAnchored(body: String): String {
    let bs = body.unsafeBytes()
    var out = ArrayList<UInt8>()
    var lineStart: Int64 = 0
    var p: Int64 = 0
    while (p <= bs.size) {
        if (p == bs.size || bs[p] == 0x0Au8) {
            Lexer.emitAnchoredLine(out, bs, lineStart, p)
            if (p < bs.size) {
                out.add(0x0Au8)
            }
            lineStart = p + 1
        }
        p = p + 1
    }
    String.fromUtf8(out.toArray())
}
