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
import std.time.MonoTime

@Test
public class Lexer_test {
    @TestCase
    public func selfClosingTag(): Unit {
        @Assert(lexAll("<a/>") == ["START a attrs=0 self=true", "EOF"])
    }

    @TestCase
    public func pairedTag(): Unit {
        @Assert(lexAll("<a></a>") == ["START a attrs=0 self=false", "END a", "EOF"])
    }

    @TestCase
    public func doubleQuotedAttribute(): Unit {
        @Assert(lexAll("<a b=\"1\"/>") == ["START a attrs=1 self=true", "EOF"])
    }

    @TestCase
    public func singleQuotedAttribute(): Unit {
        @Assert(lexAll("<a b='1'/>") == ["START a attrs=1 self=true", "EOF"])
    }

    @TestCase
    public func spaceBeforeSlash(): Unit {
        @Assert(lexAll("<a />") == ["START a attrs=0 self=true", "EOF"])
    }

    @TestCase
    public func textToken(): Unit {
        @Assert(lexAll("hello") == ["TEXT hello", "EOF"])
    }

    /** 五个预定义实体就地解码。 */
    @TestCase
    public func predefinedEntities(): Unit {
        @Assert(lexAll("&lt;&gt;&amp;&quot;&apos;") == ["TEXT <>&\"'", "EOF"])
    }

    @TestCase
    public func decimalCharRef(): Unit {
        @Assert(lexAll("&#65;") == ["TEXT A", "EOF"])
    }

    @TestCase
    public func hexCharRef(): Unit {
        @Assert(lexAll("&#x41;") == ["TEXT A", "EOF"])
    }

    @TestCase
    public func cdataToken(): Unit {
        @Assert(lexAll("<![CDATA[<b>&amp;]]>") == ["CDATA <b>&amp;", "EOF"])
    }

    @TestCase
    public func commentToken(): Unit {
        @Assert(lexAll("<!-- hi -->") == ["COMMENT  hi ", "EOF"])
    }

    @TestCase
    public func piToken(): Unit {
        @Assert(lexAll("<?pi d?>") == ["PI pi|d", "EOF"])
    }

    /** 自定义实体吐 `REF`，交给上层展开。 */
    @TestCase
    public func customEntityRef(): Unit {
        @Assert(lexAll("&foo;") == ["REF foo", "EOF"])
    }

    /** 属性值里的空白归一。 */
    @TestCase
    public func attributeWhitespaceNormalized(): Unit {
        @Assert(lexAll("<a b=\"x\ty\nz\"/>") == ["START a attrs=1 self=true", "EOF"])
    }

    /** 覆盖全部 token 类型的事件日志（golden）：扫描循环改写后逐行不变。 */
    @TestCase
    public func fullTokenStreamGolden(): Unit {
        let doc = "<?xml version=\"1.0\"?>" +
            "<!DOCTYPE root [<!ENTITY greet \"hello\">]>" +
            "<root id=\"1\"><!--c--><?pi d?><child a=\"v\">t&amp;x</child>" +
            "<![CDATA[raw]]>&greet;</root>"
        let expected = [
            "START document",
            "DECL 1.0 encoding=- standalone=-",
            "DOCTYPE root - -",
            "START QName(-,root,-) attrs=1 selfClosing=false",
            "COMMENT \"c\"",
            "PI pi \"d\"",
            "START QName(-,child,-) attrs=1 selfClosing=false",
            "TEXT \"t&x\" 3",
            "END QName(-,child,-)",
            "CDATA \"raw\" 3",
            "TEXT \"hello\" 5",
            "END QName(-,root,-)",
            "END document"
        ]
        let actual = parseEventLog(doc)
        assertTrue(logEquals(actual, expected), "事件日志不一致：\n${joinLog(actual)}")
    }

    /** 同一份文档在各块大小下事件日志一致。 */
    @TestCase
    public func goldenIsStableAcrossBufSizes(): Unit {
        let doc = "<root a=\"1\">前<s/>中<!--c--><![CDATA[x]]><?p q?>后</root>"
        let base = parseEventLog(doc)
        for (size in [4, 8, 16, 64, 65536]) {
            let options = XmlParserOptions(bufSize: size)
            let actual = parseEventLog(doc, options: options)
            assertTrue(logEquals(actual, base), "bufSize=${size} 事件日志不一致：\n${joinLog(actual)}")
        }
    }

    /** 名字后的错误位置仍指向出错字符。 */
    @TestCase
    public func errorPositionGolden(): Unit {
        let error = assertXmlError({=> parseEventLog("<a>\n  <b c=\"1\"d=\"2\"/></a>")}, "缺少空白")
        @Assert(error.line == 2)
        @Assert(error.column == 11)
    }

    /** 大量 PI 线性扫描冒烟：10 万个 `?>` 不出现二次复杂度。 */
    @TestCase
    public func manyProcessingInstructions(): Unit {
        let body = repeatText("<?p?>", 100000)
        let doc = "<r>${body}</r>"
        let start = MonoTime.now()
        let log = parseEventLog(doc)
        let elapsed = (MonoTime.now() - start) / Duration.millisecond
        assertTrue(log.size == 100004, "事件数应为 100004，实际 ${log.size}")
        assertTrue(elapsed < 10000.0, "10 万个 PI 耗时 ${elapsed} ms，疑似非线性")
    }
}
