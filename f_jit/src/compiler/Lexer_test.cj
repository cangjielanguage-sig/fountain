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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*

/**
 * S3.1–S3.6 词法单元的失败用例（**先写红**）。
 *
 * 权威 = design-m1 §4.3.1（`TokenKind` 58 项 / `Token` 6 字段 / 词法错误策略）、
 * design §4.4（行首锚定标记）、规格 §8.5（注释与词法保护）、§8.8（字符串三形态）、
 * §3.3（正则字面量）、§11.9（字面值类型规则）。
 *
 * 判据（plan-m1 S3.2–S3.6 验收点）：
 *
 * - 逐 token 断言 kind / text / line / column / `nlBefore`；
 * - **词法错误族逐 kind 一条用例**（fail-fast、**无 error token**）；
 * - 位置保真：多字节字符**按码点**计列、CRLF→LF 之后位置与常量字节跨平台一致。
 */
@Test
public class Lexer_test {

    // ==================================================================
    // S3.1 TokenKind（58 项）与 Token（6 字段）
    // ==================================================================

    /**
     * 美元符号常量：被编译源码里的插值起始 `${` 若直接写进仓颉字面量会被仓颉自身
     * 当作插值起点，故一律经本常量拼接（仅影响用例书写，不影响词法行为）。
     */
    public static const DOLLAR: String = '$'

    /** 58 项全表逐一可构造（穷尽 `match` 的反向证明：写漏任何一项都会编译失败）。 */
    @TestCase
    public func allFiftyEightKindsAreConstructible(): Unit {
        var n = 0
        n = n + Lexer_test.count(TokenKind.IntLit)
        n = n + Lexer_test.count(TokenKind.DecLit)
        n = n + Lexer_test.count(TokenKind.F64Lit)
        n = n + Lexer_test.count(TokenKind.StrLit)
        n = n + Lexer_test.count(TokenKind.RegexLit)
        n = n + Lexer_test.count(TokenKind.Ident)
        n = n + Lexer_test.count(TokenKind.KwRecursive)
        n = n + Lexer_test.count(TokenKind.KwLet)
        n = n + Lexer_test.count(TokenKind.KwVar)
        n = n + Lexer_test.count(TokenKind.KwIf)
        n = n + Lexer_test.count(TokenKind.KwElse)
        n = n + Lexer_test.count(TokenKind.KwWhile)
        n = n + Lexer_test.count(TokenKind.KwFor)
        n = n + Lexer_test.count(TokenKind.KwIn)
        n = n + Lexer_test.count(TokenKind.KwWhere)
        n = n + Lexer_test.count(TokenKind.KwBreak)
        n = n + Lexer_test.count(TokenKind.KwContinue)
        n = n + Lexer_test.count(TokenKind.KwReturn)
        n = n + Lexer_test.count(TokenKind.KwTrue)
        n = n + Lexer_test.count(TokenKind.KwFalse)
        n = n + Lexer_test.count(TokenKind.KwNull)
        n = n + Lexer_test.count(TokenKind.LParen)
        n = n + Lexer_test.count(TokenKind.RParen)
        n = n + Lexer_test.count(TokenKind.LBrace)
        n = n + Lexer_test.count(TokenKind.RBrace)
        n = n + Lexer_test.count(TokenKind.LBracket)
        n = n + Lexer_test.count(TokenKind.RBracket)
        n = n + Lexer_test.count(TokenKind.Comma)
        n = n + Lexer_test.count(TokenKind.Colon)
        n = n + Lexer_test.count(TokenKind.Arrow)
        n = n + Lexer_test.count(TokenKind.Dot)
        n = n + Lexer_test.count(TokenKind.Underscore)
        n = n + Lexer_test.count(TokenKind.Semi)
        n = n + Lexer_test.count(TokenKind.Plus)
        n = n + Lexer_test.count(TokenKind.Minus)
        n = n + Lexer_test.count(TokenKind.Star)
        n = n + Lexer_test.count(TokenKind.Slash)
        n = n + Lexer_test.count(TokenKind.Percent)
        n = n + Lexer_test.count(TokenKind.Assign)
        n = n + Lexer_test.count(TokenKind.EqEq)
        n = n + Lexer_test.count(TokenKind.NotEq)
        n = n + Lexer_test.count(TokenKind.Lt)
        n = n + Lexer_test.count(TokenKind.Le)
        n = n + Lexer_test.count(TokenKind.Gt)
        n = n + Lexer_test.count(TokenKind.Ge)
        n = n + Lexer_test.count(TokenKind.AndAnd)
        n = n + Lexer_test.count(TokenKind.OrOr)
        n = n + Lexer_test.count(TokenKind.Bang)
        n = n + Lexer_test.count(TokenKind.Amp)
        n = n + Lexer_test.count(TokenKind.Pipe)
        n = n + Lexer_test.count(TokenKind.Caret)
        n = n + Lexer_test.count(TokenKind.Shl)
        n = n + Lexer_test.count(TokenKind.Shr)
        n = n + Lexer_test.count(TokenKind.Tilde)
        n = n + Lexer_test.count(TokenKind.BangTilde)
        n = n + Lexer_test.count(TokenKind.DotDot)
        n = n + Lexer_test.count(TokenKind.DotDotEq)
        n = n + Lexer_test.count(TokenKind.EOF)
        // 5 字面量 + 16 标识符/关键字 + 12 标点 + 24 运算符 + 1 EOF = 58
        @Assert(n, 58)
    }

    private static func count(k: TokenKind): Int64 {
        let t = Token(k, 'x', 0, 1, 1, false)
        @Assert(t.text, 'x')
        @Assert(t.line, 1)
        @Assert(t.nlBefore, false)
        1
    }

    /** `Token` 六字段值语义：构造 → 字段读回逐项保真。 */
    @TestCase
    public func tokenCarriesSixFields(): Unit {
        let t = Token(TokenKind.Ident, 'abc', 7, 3, 5, true)
        @Assert(t.kind == TokenKind.Ident, true)
        @Assert(t.text, 'abc')
        @Assert(t.pos, 7)
        @Assert(t.line, 3)
        @Assert(t.column, 5)
        @Assert(t.nlBefore, true)
    }

    /** 穷尽 `match` 可用性（`TokenKind` 是无载荷 enum，解析器依赖这一点）。 */
    @TestCase
    public func kindNameCoversEveryCase(): Unit {
        @Assert(Lexer_test.kindName(TokenKind.Plus), 'Plus')
        @Assert(Lexer_test.kindName(TokenKind.Arrow), 'Arrow')
        @Assert(Lexer_test.kindName(TokenKind.EOF), 'EOF')
    }

    private static func kindName(k: TokenKind): String {
        match (k) {
            case TokenKind.IntLit => 'IntLit'
            case TokenKind.DecLit => 'DecLit'
            case TokenKind.F64Lit => 'F64Lit'
            case TokenKind.StrLit => 'StrLit'
            case TokenKind.RegexLit => 'RegexLit'
            case TokenKind.Ident => 'Ident'
            case TokenKind.KwRecursive => 'KwRecursive'
            case TokenKind.KwLet => 'KwLet'
            case TokenKind.KwVar => 'KwVar'
            case TokenKind.KwIf => 'KwIf'
            case TokenKind.KwElse => 'KwElse'
            case TokenKind.KwWhile => 'KwWhile'
            case TokenKind.KwFor => 'KwFor'
            case TokenKind.KwIn => 'KwIn'
            case TokenKind.KwWhere => 'KwWhere'
            case TokenKind.KwBreak => 'KwBreak'
            case TokenKind.KwContinue => 'KwContinue'
            case TokenKind.KwReturn => 'KwReturn'
            case TokenKind.KwTrue => 'KwTrue'
            case TokenKind.KwFalse => 'KwFalse'
            case TokenKind.KwNull => 'KwNull'
            case TokenKind.LParen => 'LParen'
            case TokenKind.RParen => 'RParen'
            case TokenKind.LBrace => 'LBrace'
            case TokenKind.RBrace => 'RBrace'
            case TokenKind.LBracket => 'LBracket'
            case TokenKind.RBracket => 'RBracket'
            case TokenKind.Comma => 'Comma'
            case TokenKind.Colon => 'Colon'
            case TokenKind.Arrow => 'Arrow'
            case TokenKind.Dot => 'Dot'
            case TokenKind.Underscore => 'Underscore'
            case TokenKind.Semi => 'Semi'
            case TokenKind.Plus => 'Plus'
            case TokenKind.Minus => 'Minus'
            case TokenKind.Star => 'Star'
            case TokenKind.Slash => 'Slash'
            case TokenKind.Percent => 'Percent'
            case TokenKind.Assign => 'Assign'
            case TokenKind.EqEq => 'EqEq'
            case TokenKind.NotEq => 'NotEq'
            case TokenKind.Lt => 'Lt'
            case TokenKind.Le => 'Le'
            case TokenKind.Gt => 'Gt'
            case TokenKind.Ge => 'Ge'
            case TokenKind.AndAnd => 'AndAnd'
            case TokenKind.OrOr => 'OrOr'
            case TokenKind.Bang => 'Bang'
            case TokenKind.Amp => 'Amp'
            case TokenKind.Pipe => 'Pipe'
            case TokenKind.Caret => 'Caret'
            case TokenKind.Shl => 'Shl'
            case TokenKind.Shr => 'Shr'
            case TokenKind.Tilde => 'Tilde'
            case TokenKind.BangTilde => 'BangTilde'
            case TokenKind.DotDot => 'DotDot'
            case TokenKind.DotDotEq => 'DotDotEq'
            case TokenKind.EOF => 'EOF'
        }
    }

    // ==================================================================
    // S3.2 Lexer 基础
    // ==================================================================

    /** 标识符 / 关键字 / 标点 / 运算符逐 token 断言（含 `!~` 单 token）。 */
    @TestCase
    public func operatorsAndKeywordsScanToDistinctTokens(): Unit {
        let ts = Lexer('let f = a != b ~ c !~ d .. e ..= 1 && 2 || 3 << 4 >> 5').tokenize()
        @Assert(Lexer_test.kindName(ts[0].kind), 'KwLet')
        @Assert(Lexer_test.kindName(ts[1].kind), 'Ident')
        @Assert(Lexer_test.kindName(ts[2].kind), 'Assign')
        @Assert(Lexer_test.kindName(ts[4].kind), 'NotEq')
        @Assert(Lexer_test.kindName(ts[6].kind), 'Tilde')
        @Assert(Lexer_test.kindName(ts[8].kind), 'BangTilde')
        @Assert(Lexer_test.kindName(ts[10].kind), 'DotDot')
        @Assert(Lexer_test.kindName(ts[12].kind), 'DotDotEq')
        @Assert(Lexer_test.kindName(ts[14].kind), 'AndAnd')
        @Assert(Lexer_test.kindName(ts[16].kind), 'OrOr')
        @Assert(Lexer_test.kindName(ts[18].kind), 'Shl')
        @Assert(Lexer_test.kindName(ts[20].kind), 'Shr')
        @Assert(Lexer_test.kindName(ts[21].kind), 'IntLit')
        @Assert(Lexer_test.kindName(ts[22].kind), 'EOF')
    }

    /** `=>` 与标点族；`;` 与 `_`。 */
    @TestCase
    public func arrowAndPunctuation(): Unit {
        let ts = Lexer('(a, b) => { a;_ }').tokenize()
        @Assert(Lexer_test.kindName(ts[0].kind), 'LParen')
        @Assert(Lexer_test.kindName(ts[2].kind), 'Comma')
        @Assert(Lexer_test.kindName(ts[4].kind), 'RParen')
        @Assert(Lexer_test.kindName(ts[5].kind), 'Arrow')
        @Assert(ts[5].text, '=>')
        @Assert(Lexer_test.kindName(ts[6].kind), 'LBrace')
        @Assert(Lexer_test.kindName(ts[8].kind), 'Semi')
        @Assert(Lexer_test.kindName(ts[9].kind), 'Underscore')
        @Assert(Lexer_test.kindName(ts[10].kind), 'RBrace')
    }

    /** 数字三形：整数 / 小数 / 指数 / 显式浮点后缀；**超 Int64 域仍是合法 `IntLit`**。 */
    @TestCase
    public func numberLiteralsKeepSourceText(): Unit {
        let litTokens = [
            Lexer('42').tokenize()[0],
            Lexer('1.5').tokenize()[0],
            Lexer('3e2').tokenize()[0],
            Lexer('1e-3').tokenize()[0],
            Lexer('1.5f64').tokenize()[0],
            Lexer('99999999999999999999999').tokenize()[0]
        ]
        @Assert(Lexer_test.kindName(litTokens[0].kind), 'IntLit')
        @Assert(litTokens[0].text, '42')
        @Assert(Lexer_test.kindName(litTokens[1].kind), 'DecLit')
        @Assert(Lexer_test.kindName(litTokens[2].kind), 'DecLit')
        @Assert(litTokens[2].text, '3e2')
        @Assert(Lexer_test.kindName(litTokens[3].kind), 'DecLit')
        @Assert(litTokens[3].text, '1e-3')
        // 显式浮点后缀：kind = F64Lit，text **不含**后缀
        @Assert(Lexer_test.kindName(litTokens[4].kind), 'F64Lit')
        @Assert(litTokens[4].text, '1.5')
        // 超出 Int64 的字面值在词法层**合法**（§11.9：由前端降级为 Decimal 常量 scale 0）
        @Assert(Lexer_test.kindName(litTokens[5].kind), 'IntLit')
        @Assert(litTokens[5].text, '99999999999999999999999')
    }

    /** `nlBefore`：同行紧跟为假、直接换行为真、**单行注释跨行**与**多行注释跨行**都为真。 */
    @TestCase
    public func nlBeforeMarksCrossedNewLines(): Unit {
        let same = Lexer('a b').tokenize()
        @Assert(same[0].nlBefore, false)
        @Assert(same[1].nlBefore, false)

        let direct = Lexer('a\nb').tokenize()
        @Assert(direct[1].nlBefore, true)
        @Assert(direct[1].line, 2)
        @Assert(direct[1].column, 1)

        let lineComment = Lexer('a // tail\nb').tokenize()
        @Assert(lineComment[1].nlBefore, true)

        let blockComment = Lexer('a /* head\ntail */ b').tokenize()
        @Assert(blockComment[1].nlBefore, true)
    }

    /** EOF 幂等（连续 `next()` 都返回 EOF 且不推进游标）。 */
    @TestCase
    public func eofIsIdempotent(): Unit {
        let lex = Lexer('a')
        let first = lex.next()
        @Assert(Lexer_test.kindName(first.kind), 'Ident')
        @Assert(Lexer_test.kindName(lex.next().kind), 'EOF')
        @Assert(Lexer_test.kindName(lex.next().kind), 'EOF')
        @Assert(lex.position(), 1)
        @Assert(lex.line(), 1)
        @Assert(lex.column(), 2)
    }

    // ---- 词法错误族（逐 kind 一条；fail-fast、无 error token）----

    /** ① `IllegalCharacter`：不属于任何合法词法单元的字符。 */
    @TestCase
    public func illegalCharacterFailsFastAtRightPosition(): Unit {
        let e = expectLexError('    let b = @')
        @Assert(e.kind, DiagKind.ILLEGAL_CHARACTER)
        @Assert(e.line, 1)
        @Assert(e.column, 13)
        @Assert(e.lineText, '    let b = @')
    }

    /** ② `UnterminatedString`：单行串未闭合 / 跨行 / 插值未闭合（三类一条用例）。 */
    @TestCase
    public func unterminatedStringIsRejected(): Unit {
        @Assert(expectLexError('"abc').kind, DiagKind.UNTERMINATED_STRING)
        @Assert(expectLexError('"ab\ncd"').kind, DiagKind.UNTERMINATED_STRING)
        @Assert(expectLexError('"' + Lexer_test.DOLLAR + '{1 + 2"').kind, DiagKind.UNTERMINATED_STRING)
    }

    /** ③ `BadEscape`：非法转义与多行串中的单独反斜杠。 */
    @TestCase
    public func badEscapeIsRejected(): Unit {
        @Assert(expectLexError('"a\\qb"').kind, DiagKind.BAD_ESCAPE)
        @Assert(expectLexError("'''\nab\\q\n'''").kind, DiagKind.BAD_ESCAPE)
    }

    /** ④ `BadNumber`：数字字形畸形（**超 Int64 域不属此类**）。 */
    @TestCase
    public func badNumberIsRejected(): Unit {
        @Assert(expectLexError('1.2.3').kind, DiagKind.BAD_NUMBER)
        @Assert(expectLexError('3e').kind, DiagKind.BAD_NUMBER)
        @Assert(expectLexError('12abc').kind, DiagKind.BAD_NUMBER)
    }

    /** ⑤ `UnterminatedRegex`：正则段缺闭合斜杠。 */
    @TestCase
    public func unterminatedRegexIsRejected(): Unit {
        let e = expectLexError('/[a-z')
        @Assert(e.kind, DiagKind.UNTERMINATED_REGEX)
        @Assert(e.column, 1)
    }

    /** ⑥ `UnterminatedComment`：嵌套多行注释少一个结束符。 */
    @TestCase
    public func unterminatedCommentIsRejected(): Unit {
        @Assert(expectLexError('a /* x /* y */ b').kind, DiagKind.UNTERMINATED_COMMENT)
    }

    // ==================================================================
    // S3.3 字符串三形态
    // ==================================================================

    /** 单行：转义解码、异种引号为内容（§8.8 v0.18.9）。 */
    @TestCase
    public func singleLineStringsSupportEscapesAndForeignQuotes(): Unit {
        @Assert(Lexer('"a\\nb\\t\\\\"').tokenize()[0].text, 'a\nb\t\\')
        @Assert(Lexer('\'"aa"\'').tokenize()[0].text, '"aa"')
        @Assert(Lexer("\"'aa'\"").tokenize()[0].text, "'aa'")
        @Assert(Lexer('""').tokenize()[0].text, '')
        // 码点转义
        @Assert(Lexer('"\\u{41}"').tokenize()[0].text, 'A')
    }

    /** 多行：首个非转义三连终止；异种三连是内容；闭合前的换行与缩进属于内容。 */
    @TestCase
    public func multilineStringsScanToFirstTripleQuote(): Unit {
        let body = Lexer("'''\n  hello\n  '''").tokenize()[0].text
        // §8.8「闭合引号前的换行与缩进属于内容」：闭合符前的两个空格也是内容的一部分
        @Assert(body, '  hello\n  ')
        // 异种三连不终止（""" 内的 ''' 是内容）
        let mixed = Lexer("\"\"\"\na'''\nb\n\"\"\"").tokenize()[0].text
        @Assert(mixed, "a'''\nb\n")
        // 空多行串
        @Assert(Lexer("'''\n'''").tokenize()[0].text, '')
    }

    /** 同行的头部内容 → `MultilineHeadContent`；未闭合 → `UnterminatedMultilineString`。 */
    @TestCase
    public func multilineHeadContentAndUnterminatedAreRejected(): Unit {
        @Assert(expectLexError("'''abc'''").kind, DiagKind.MULTILINE_HEAD_CONTENT)
        @Assert(expectLexError("'''\nabc").kind, DiagKind.UNTERMINATED_MULTILINE_STRING)
    }

    /** 原始串：verbatim（不转义、不插值）、`#`×n 定界、可跨行、未闭合被拒。 */
    @TestCase
    public func rawStringsAreVerbatim(): Unit {
        @Assert(Lexer('#"a\\nb"#').tokenize()[0].text, 'a\\nb')
        @Assert(Lexer('#"' + Lexer_test.DOLLAR + '{x}"#').tokenize()[0].text, Lexer_test.DOLLAR + '{x}')
        @Assert(Lexer('#"a\nb"#').tokenize()[0].text, 'a\nb')
        // 内含更少 # 的引号序列不终止
        @Assert(Lexer('##"say "hi"#"##').tokenize()[0].text, 'say "hi"#')
        @Assert(expectLexError('#"abc').kind, DiagKind.UNTERMINATED_RAW_STRING)
    }

    /** `'''`/`"""` 三连定界**最长匹配**（§8.8 词法消歧）。 */
    @TestCase
    public func tripleQuoteDelimiterWinsByLongestMatch(): Unit {
        let ts = Lexer("'''\nx\n'''\n1").tokenize()
        @Assert(Lexer_test.kindName(ts[0].kind), 'StrLit')
        @Assert(ts[0].text, 'x\n')
        @Assert(Lexer_test.kindName(ts[1].kind), 'IntLit')
    }

    /** 换行规范化：CRLF / CR 一律折算为 LF（同一源码在任何平台编译出的常量字节一致）。 */
    @TestCase
    public func newlinesAreNormalizedInEveryForm(): Unit {
        @Assert(Lexer('#"a\r\nb"#').tokenize()[0].text, 'a\nb')
        @Assert(Lexer('#"a\rb"#').tokenize()[0].text, 'a\nb')
        @Assert(Lexer("'''\r\nx\r\n'''").tokenize()[0].text, 'x\n')
    }

    // ==================================================================
    // S3.4 行首锚定标记 `>|`
    // ==================================================================

    /** 有效标记：消耗「前导缩进 + 标记」，其后全部字符为内容；无标记行整行原样保留。 */
    @TestCase
    public func anchoredLinesDropMarkerAndIndentOnly(): Unit {
        @Assert(dedentAnchored('    >|first\n    >|second\n  plain\n'), 'first\nsecond\n  plain\n')
        // 标记本身不进入产物；单独标记行 ⇒ 空串
        @Assert(dedentAnchored('>|a\n   >|\n>|b\n'), 'a\n\nb\n')
        // 首现语义：只有首个非空白位置的标记是定位语法，其后全是字面文本
        @Assert(dedentAnchored('>|>|abc\n'), '>|abc\n')
        @Assert(dedentAnchored('>|    >|\n'), '    >|\n')
    }

    /** 非标记情形（v0.14.4 三例冻结）：`>>|`、`a>|b`、`|>|` 一律是字面内容。 */
    @TestCase
    public func nonMarkerSequencesStayLiteral(): Unit {
        @Assert(dedentAnchored(' >>|x\n'), ' >>|x\n')
        @Assert(dedentAnchored('a>|b\n'), 'a>|b\n')
        @Assert(dedentAnchored('|>|x\n'), '|>|x\n')
    }

    /** 锚定不作用于单行 / 原始串；`>|` 在其内是普通字面文本。 */
    @TestCase
    public func anchoringIsExclusiveToMultilineStrings(): Unit {
        @Assert(Lexer('"a>|b"').tokenize()[0].text, 'a>|b')
        @Assert(Lexer('#" >|x"#').tokenize()[0].text, ' >|x')
    }

    /** 处理顺序：锚定在转义之前（锚定后的字符才参与转义）。 */
    @TestCase
    public func anchoringHappensBeforeEscapeDecoding(): Unit {
        let src = "'''\n  >|a\\nb\n  >|end\n'''"
        @Assert(Lexer(src).tokenize()[0].text, 'a\nb\nend\n')
    }

    // ==================================================================
    // S3.5 注释与词法保护
    // ==================================================================

    /** 单行 / 多行嵌套配平；嵌套只是注释内容（少一个结束符即判定未闭合）。 */
    @TestCase
    public func commentsAreStrippedWithNestingBalance(): Unit {
        let flat = Lexer('/* mid */ 42').tokenize()
        @Assert(Lexer_test.kindName(flat[0].kind), 'IntLit')
        let nested = Lexer('/* a /* b */ c */ 42').tokenize()
        @Assert(Lexer_test.kindName(nested[0].kind), 'IntLit')
        @Assert(nested[0].text, '42')
    }

    /** 字符串跨度内的注释起始序列 / 引号 / 花括号 / 锚定标记不参与识别。 */
    @TestCase
    public func stringSpansShieldCommentAndStructuralScans(): Unit {
        let ts = Lexer('"// not a comment /* nor { this } */ >| plain" + 1').tokenize()
        @Assert(ts[0].text, '// not a comment /* nor { this } */ >| plain')
        @Assert(Lexer_test.kindName(ts[1].kind), 'Plus')
        @Assert(Lexer_test.kindName(ts[2].kind), 'IntLit')
        // 花括号：插值跨度被整体跳过，其中的引号不终止外层串
        let interp = Lexer('"a' + Lexer_test.DOLLAR + '{m["k"]}b" + 1').tokenize()
        @Assert(interp[0].text, 'a' + Lexer_test.DOLLAR + '{m["k"]}b')
        @Assert(Lexer_test.kindName(interp[1].kind), 'Plus')
    }

    /** 注释剥离不改变后续 token 的位置语义（`nlBefore` 除外，它显式记录换行）。 */
    @TestCase
    public func commentRemovalPreservesTokenPositions(): Unit {
        let withComment = Lexer('1 /* c */ + 2').tokenize()
        let withoutComment = Lexer('1 + 2').tokenize()
        @Assert(withComment[0].column, withoutComment[0].column)
        @Assert(withComment[1].column, 11)
        @Assert(withComment[2].column, 13)
    }

    // ==================================================================
    // S3.6 正则字面量
    // ==================================================================

    /** flags 顺序无关、重复幂等 → 同一位域；非法 flags 不在词法层判（加载期 14）。 */
    @TestCase
    public func regexFlagsNormalizeToABitfield(): Unit {
        let a = Lexer('/[a-z]/im')
        let ta = a.tokenize()[0]
        @Assert(Lexer_test.kindName(ta.kind), 'RegexLit')
        @Assert(ta.text, '[a-z]')
        @Assert(a.lastRegexFlags(), 0x03u8)

        let b = Lexer('/[a-z]/mi')
        b.tokenize()
        @Assert(b.lastRegexFlags(), 0x03u8)

        let c = Lexer('/[a-z]/ii')
        c.tokenize()
        @Assert(c.lastRegexFlags(), 0x01u8)

        let d = Lexer('/[a-z]/imu')
        d.tokenize()
        @Assert(d.lastRegexFlags(), 0x07u8)
    }

    /** 正则段扫描：字符类内的斜杠不终止；反斜杠转义其后的斜杠。 */
    @TestCase
    public func regexSectionScanHonoursClassesAndEscapes(): Unit {
        @Assert(Lexer('/[a/]/').tokenize()[0].text, '[a/]')
        @Assert(Lexer('/a\\/b/').tokenize()[0].text, 'a\\/b')
    }

    /** 斜杠消歧：值 / 闭合符之后为除法，其余位置起始正则（`/\s//s/r/g` 三形态的识别前提）。 */
    @TestCase
    public func slashDisambiguatesDivisionFromRegex(): Unit {
        let div = Lexer('a / b').tokenize()
        @Assert(Lexer_test.kindName(div[0].kind), 'Ident')
        @Assert(Lexer_test.kindName(div[1].kind), 'Slash')
        @Assert(Lexer_test.kindName(div[2].kind), 'Ident')
        // 无 flags 字面量 + 替换段：两个相邻斜杠各司其职（闭合 + 分隔）
        let rep = Lexer('/\\s//s/r/g').tokenize()
        @Assert(Lexer_test.kindName(rep[0].kind), 'RegexLit')
        @Assert(rep[0].text, '\\s')
        @Assert(Lexer_test.kindName(rep[1].kind), 'Slash')
        @Assert(Lexer_test.kindName(rep[2].kind), 'Ident')
        @Assert(Lexer_test.kindName(rep[3].kind), 'Slash')
        @Assert(Lexer_test.kindName(rep[4].kind), 'Ident')
        @Assert(Lexer_test.kindName(rep[5].kind), 'Slash')
        @Assert(Lexer_test.kindName(rep[6].kind), 'Ident')
    }

    /** 相邻斜杠序列：`//` 始终是注释（注释识别优先于正则，且 `skipTrivia` 先于扫描）。 */
    @TestCase
    public func doubleSlashIsAlwaysAComment(): Unit {
        let ts = Lexer('// note\n42').tokenize()
        @Assert(Lexer_test.kindName(ts[0].kind), 'IntLit')
        @Assert(ts[0].nlBefore, true)
    }
}

/** 期望 `src` 在词法阶段 fail-fast：**Return the exception**（没有 error token ⇒ 只能抛）。 */
private func expectLexError(src: String): SourceCompileException {
    try {
        Lexer(src).tokenize()
    } catch (e: SourceCompileException) {
        return e
    }
    @Fail('期望词法阶段抛出 SourceCompileException')
}
