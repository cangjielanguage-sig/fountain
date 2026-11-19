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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList

/**
 * 文本与属性值的批量扫描：与逐字符路径逐字符等价，事件边界 / 报错位置 / 空白归一不变。
 */
@Test
public class TextScan_test {
    private func lexerOf(text: String, bufSize!: Int64 = 8192): Lexer {
        Lexer(LineWindow(Utf8RuneSource(TextInputStream(text), bufSize: bufSize)))
    }

    /** 反复拼接同一个字符块（避免在用例里写 1 MB 字面量，也避免 `+=` 的二次复杂度）。 */
    private func repeatBlock(block: String, times: Int64): String {
        repeatText(block, times)
    }

    private func tokens(text: String, bufSize!: Int64 = 8192): (Array<Token>, Int64) {
        let lexer = this.lexerOf(text, bufSize: bufSize)
        let out = ArrayList<Token>()
        while (true) {
            let token = lexer.nextToken(ParserState.Content)
            out.add(token)
            match (token) {
                case Token.TEof => break
                case _ => ()
            }
        }
        (out.toArray(), lexer.peekCalls)
    }

    private func textOf(token: Token): String {
        match (token) {
            case Token.TText(text) => text
            case _ => ""
        }
    }

    /** 1 MB 纯 ASCII 文本：一个 `Text` 事件，且 `peekCp` 调用次数远小于字符数。 */
    @TestCase
    public func longAsciiTextIsSingleEvent(): Unit {
        let body = this.repeatBlock("abcdefgh", 1024 * 1024 / 8)
        let result = this.tokens("<a>${body}</a>")
        var textCount: Int64 = 0
        var captured = ""
        for (token in result[0]) {
            match (token) {
                case Token.TText(text) =>
                    textCount++
                    captured = text
                case _ => ()
            }
        }
        assertTrue(textCount == 1, "应只有 1 个 Text 令牌，实际 ${textCount}")
        assertTrue(captured.size == body.size, "文本长度应为 ${body.size}，实际 ${captured.size}")
        assertTrue(captured == body, "文本内容与输入不一致")
        let bound = Int64(body.size) / 16
        assertTrue(result[1] < bound, "peekCp 调用 ${result[1]} 次，应远小于 ${bound}（批量路径未生效？）")
    }

    /** 跨块边界仍只产出一个 `Text`，内容一致。 */
    @TestCase
    public func textAcrossBufferBoundaries(): Unit {
        let body = "0123456789abcdefghij"
        for (bufSize in [Int64(4), Int64(8), Int64(16), Int64(8192)]) {
            let result = this.tokens("<a>${body}</a>", bufSize: bufSize)
            var textCount: Int64 = 0
            for (token in result[0]) {
                match (token) {
                    case Token.TText(text) =>
                        textCount++
                        assertTrue(text == body, "bufSize=${bufSize}：文本应为「${body}」，实际「${text}」")
                    case _ => ()
                }
            }
            assertTrue(textCount == 1, "bufSize=${bufSize}：应只有 1 个 Text 令牌，实际 ${textCount}")
        }
    }

    /** 非 ASCII 文本退回逐字符路径，内容不变。 */
    @TestCase
    public func nonAsciiTextStillCorrect(): Unit {
        for (bufSize in [Int64(4), Int64(8192)]) {
            let result = this.tokens("<a>日本語テキスト</a>", bufSize: bufSize)
            var captured = ""
            var textCount: Int64 = 0
            for (token in result[0]) {
                match (token) {
                    case Token.TText(text) =>
                        textCount++
                        captured = text
                    case _ => ()
                }
            }
            assertTrue(textCount == 1 && captured == "日本語テキスト", "bufSize=${bufSize}：实际「${captured}」")
        }
    }

    /** `]]>` 仍然报错，消息与位置不变。 */
    @TestCase
    public func cdataCloseInTextStillErrors(): Unit {
        let error = assertXmlError({=> this.tokens("<a>x]]>y</a>")}, "文本里不能出现「]]>」")
        assertTrue(error.line == 1 && error.column == 5, "位置应为 1:5，实际 ${error.line}:${error.column}")
    }

    /** 自定义实体在 `&` 处切分（行为与改动前一致）。 */
    @TestCase
    public func entityRefStillSplitsText(): Unit {
        let result = this.tokens("x&foo;y")
        let kinds = ArrayList<String>()
        for (token in result[0]) {
            match (token) {
                case Token.TText(text) => kinds.add("TEXT ${text}")
                case Token.TEntityRef(name, _, _) => kinds.add("REF ${name}")
                case Token.TEof => kinds.add("EOF")
                case _ => kinds.add("OTHER")
            }
        }
        assertTrue(
            logEquals(kinds.toArray(), ["TEXT x", "REF foo", "TEXT y", "EOF"]),
            "实际：${kinds}"
        )
    }

    /** 内联引用（`&amp;` / `&#x41;`）仍然合并进同一个文本令牌。 */
    @TestCase
    public func inlineReferencesStayInOneToken(): Unit {
        let result = this.tokens("a&amp;b&#x41;c")
        let texts = ArrayList<String>()
        for (token in result[0]) {
            match (token) {
                case Token.TText(text) => texts.add(text)
                case _ => ()
            }
        }
        assertTrue(texts.size == 1 && texts[0] == "a&bAc", "实际：${texts}")
    }

    /** 文本里的非法控制字符仍报同一句消息，位置指向该字符自身。 */
    @TestCase
    public func controlCharInTextStillErrors(): Unit {
        let error = assertXmlError(
            {=> this.tokens("<a>x${Rune(0x01).toString()}y</a>")},
            "文本中出现 XML 1.0 不允许的字符 U+1"
        )
        assertTrue(error.line == 1 && error.column == 5, "位置应为 1:5，实际 ${error.line}:${error.column}")
    }

    /** 长属性值：内容一致，`peekCp` 调用次数下降。 */
    @TestCase
    public func longAttributeValueIsBatched(): Unit {
        let value = this.repeatBlock("abcdefgh", 64 * 1024 / 8)
        let result = this.tokens("<a v=\"${value}\"/>")
        var captured = ""
        for (token in result[0]) {
            match (token) {
                case Token.TStartTag(_, attrs, _) => captured = attrs[0].value
                case _ => ()
            }
        }
        assertTrue(captured == value, "属性值内容与输入不一致")
        let bound = Int64(value.size) / 16
        assertTrue(result[1] < bound, "peekCp 调用 ${result[1]} 次，应远小于 ${bound}（属性值批量路径未生效？）")
    }

    /** 跨行属性值：字面换行 / Tab / CR 归一成空格，`&#10;` 保持换行。 */
    @TestCase
    public func attributeWhitespaceNormalizationUnchanged(): Unit {
        let result = this.tokens("<a v=\"x\ny\tz\rw\"/>")
        var captured = ""
        for (token in result[0]) {
            match (token) {
                case Token.TStartTag(_, attrs, _) => captured = attrs[0].value
                case _ => ()
            }
        }
        assertTrue(captured == "x y z w", "空白归一错误：实际「${captured}」")

        let withRef = this.tokens("<a v=\"a&#10;b\"/>")
        var refValue = ""
        for (token in withRef[0]) {
            match (token) {
                case Token.TStartTag(_, attrs, _) => refValue = attrs[0].value
                case _ => ()
            }
        }
        assertTrue(refValue == "a\nb", "字符引用 `&#10;` 应保持换行，实际「${refValue}」")
    }

    /** 属性值里的裸 `<` 仍报错，消息与位置不变。 */
    @TestCase
    public func bareLessThanInAttributeStillErrors(): Unit {
        let error = assertXmlError({=> this.tokens("<a v=\"x<y\"/>")}, "属性值里不能出现裸「<」")
        assertTrue(error.line == 1 && error.column == 8, "位置应为 1:8，实际 ${error.line}:${error.column}")
    }

    /** 属性值未闭合仍报错。 */
    @TestCase
    public func unclosedAttributeStillErrors(): Unit {
        assertXmlError({=> this.tokens("<a v=\"xyz")}, "的值未闭合")
    }

    /** 实体展开后含裸 `<` 仍报错（走引擎路径，需要实体表）。 */
    @TestCase
    public func entityExpandedLessThanStillErrors(): Unit {
        assertXmlError(
            {=> parseEventLog("<!DOCTYPE a [<!ENTITY e \"<\">]><a v=\"&e;\"/>")},
            "的值里出现裸「<」"
        )
    }

    /** ASCII 合法性查表与 `isXmlChar(Int64)` 在 `0x00..0x7F` 上逐点一致。 */
    @TestCase
    public func asciiMaskMatchesIsXmlChar(): Unit {
        let mask = XmlChars.asciiMaskFor([], invalid: true)
        for (cp in 0..128) {
            let legal = XmlChars.isXmlChar(cp)
            assertTrue(XmlChars.isAsciiXmlChar(cp) == legal, "U+${cp} 合法性判定不一致")
            assertTrue(mask[cp] == !legal, "U+${cp} 掩码应为 ${!legal}")
        }
        let stops = XmlChars.asciiMaskFor([0x3C, 0x26], invalid: false)
        assertTrue(stops[0x3C] && stops[0x26] && !stops[0x41], "停点掩码错误")
        assertTrue(!stops[0x00], "未开 invalid 时控制字符不应自动成为停点")
    }
}
