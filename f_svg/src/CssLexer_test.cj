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
import std.unittest.*
import std.unittest.testmacro.*

/** 非空白 token 的文本序列，便于断言。 */
internal func cssTokenTexts(text: String): Array<String> {
    let result = ArrayList<String>()
    for (token in CssLexer(text).tokenize()) {
        if (token.kind != CssTokenKind.Whitespace) {
            result.add(token.text)
        }
    }
    result.toArray()
}

@Test
public class CssLexer_test {
    /** 注释整段跳过，不产生 token。 */
    @TestCase
    public func commentsAreSkipped(): Unit {
        let tokens = CssLexer("a /* note */ b").tokenize()
        let kinds = ArrayList<CssTokenKind>()
        for (token in tokens) {
            kinds.add(token.kind)
        }
        @Assert(kinds.size == 3)
        @Assert(kinds[0] == CssTokenKind.Ident)
        @Assert(kinds[1] == CssTokenKind.Whitespace)
        @Assert(kinds[2] == CssTokenKind.Ident)
        @Assert(cssTokenTexts("a/*x*/b") == ["a", "b"])
        @Assert(cssTokenTexts("a/* 未闭合").size == 1)
    }

    /** 单双引号字符串原样保留，引号内的注释与分号不生效。 */
    @TestCase
    public func quotedStrings(): Unit {
        @Assert(cssTokenTexts("'a;b' \"c/*d*/e\"") == ["'a;b'", "\"c/*d*/e\""])
        @Assert(cssTokenTexts("\"a\\\"b\"") == ["\"a\\\"b\""])
        @Assert(cssTokenTexts("'a\\\\b'") == ["'a\\\\b'"])
    }

    /** url(...) 保留整体，括号内的空白与井号不拆分。 */
    @TestCase
    public func urlIsKeptWhole(): Unit {
        @Assert(cssTokenTexts("url(#grad)") == ["url(#grad)"])
        @Assert(cssTokenTexts("URL( 'a b' )") == ["URL( 'a b' )"])
        @Assert(cssTokenTexts("url(#a) red") == ["url(#a)", "red"])
        @Assert(CssLexer("url(#a)").tokenize()[0].kind == CssTokenKind.Url)
    }

    /** 转义序列在 ident 内保持原样，不把转义字符当结构符号。 */
    @TestCase
    public func escapesStayInIdent(): Unit {
        @Assert(cssTokenTexts("a\\:b") == ["a\\:b"])
        @Assert(cssTokenTexts(".x\\ y") == [".", "x\\ y"])
        @Assert(cssTokenTexts("a\\31 23") == ["a\\31 23"])
    }

    /** 未知字符降级为 Delim 后继续扫描。 */
    @TestCase
    public func invalidCharacterRecovery(): Unit {
        let tokens = CssLexer("a < b ;").tokenize()
        var sawDelimiter = false
        for (token in tokens) {
            if (token.kind == CssTokenKind.Delim && token.text == "<") {
                sawDelimiter = true
            }
        }
        @Assert(sawDelimiter)
        @Assert(cssTokenTexts("a < b ;") == ["a", "<", "b", ";"])
        @Assert(cssTokenTexts("\u{0}rect") == ["\u{0}", "rect"])
    }

    /** 位置与分界符号。 */
    @TestCase
    public func punctuationAndOffsets(): Unit {
        let tokens = CssLexer("rect.a#b{fill:red}").tokenize()
        @Assert(tokens[0].text == "rect")
        @Assert(tokens[0].offset == 0)
        let kinds = ArrayList<CssTokenKind>()
        for (token in tokens) {
            if (token.kind != CssTokenKind.Whitespace) {
                kinds.add(token.kind)
            }
        }
        @Assert(kinds.toArray() == [
            CssTokenKind.Ident, CssTokenKind.Delim, CssTokenKind.Ident, CssTokenKind.Hash,
            CssTokenKind.LeftBrace, CssTokenKind.Ident, CssTokenKind.Colon, CssTokenKind.Ident,
            CssTokenKind.RightBrace
        ])
    }
}
