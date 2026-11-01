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
import fountain::f_base.StringGenerator

/** 把 DOM 用给定选项写成字符串。 */
internal func writeText(doc: XmlDocument, options!: XmlWriterOptions = XmlWriterOptions()): String {
    let output = RecordingOutputStream()
    let writer = XmlWriter(output, options: options)
    writer.write(doc)
    writer.close()
    output.text()
}

internal func writeElementText(element: XmlElement, options!: XmlWriterOptions = XmlWriterOptions()): String {
    let output = RecordingOutputStream()
    let writer = XmlWriter(output, options: options)
    writer.write(element)
    writer.close()
    output.text()
}

@Test
public class Escaper_test {
    private func escapeAll(text: String): String {
        let gen = StringGenerator()
        Escaper.escapeText(text, "a", gen)
        gen.toString()
    }

    private func escapeAttr(text: String, name!: String = "x"): String {
        let gen = StringGenerator()
        Escaper.escapeAttribute(text, name, gen)
        gen.toString()
    }

    /** 逐格转义表。 */
    @TestCase
    public func escapeTable(): Unit {
        @Assert(escapeAll("&") == "&amp;")
        @Assert(escapeAll("<") == "&lt;")
        @Assert(escapeAll(">") == "&gt;")
        @Assert(escapeAll("\"") == "\"")
        @Assert(escapeAll("'") == "'")
        @Assert(escapeAll("\r") == "&#13;")
        @Assert(escapeAttr("&") == "&amp;")
        @Assert(escapeAttr("<") == "&lt;")
        @Assert(escapeAttr(">") == "&gt;")
        @Assert(escapeAttr("\"") == "&quot;")
        @Assert(escapeAttr("'") == "'")
        @Assert(escapeAttr("\r") == "&#13;")
    }

    /** 非法控制字符拒绝，消息带元素名 / 属性名。 */
    @TestCase
    public func invalidControlRejected(): Unit {
        let nul = String(Rune(0))
        let error = assertXmlError({=> escapeAll(nul)}, "元素「a」")
        @Assert(error.message.contains("U+0"))

        let verticalTab = String(Rune(0x0B))
        assertXmlError({=> escapeAttr(verticalTab, name: "attr")}, "属性「attr」")
    }
}

@Test
public class XmlWriter_test {
    /** 紧凑模式逐字节等于原文。 */
    @TestCase
    public func compactExact(): Unit {
        let doc = parseText("<a><b>x</b></a>")
        @Assert(writeText(doc) == "<a><b>x</b></a>")
    }

    /** 紧凑模式不产生换行。 */
    @TestCase
    public func compactNoNewline(): Unit {
        let doc = parseText("<a><b>x</b><c/></a>")
        @Assert(!writeText(doc).contains("\n"))
    }

    /** 缩进只在元素之间换行，元素内部的文本前后没有额外空白。 */
    @TestCase
    public func indentOnlyBetweenElements(): Unit {
        let doc = parseText("<a><b>x</b><c/></a>")
        let text = writeText(doc, options: XmlWriterOptions(indent: Some("  ")))
        @Assert(text.contains("<b>x</b>"))
        @Assert(text.contains("\n  <b>"))
        @Assert(text.contains("\n</a>") || text.contains("\n  </a>") || text.contains("\n</a>"))
    }

    /** `write(doc)` 顺序：声明 → doctype → prolog → root → epilog。 */
    @TestCase
    public func documentOrder(): Unit {
        let doc = parseText("<?xml version=\"1.0\"?><!--p--><a/><!--e-->")
        let text = writeText(doc)
        @Assert(text.startsWith("<?xml version=\"1.0\"?>"))
        @Assert(text.contains("<!--p--><a/><!--e-->"))
    }

    /** `write(element)` 不带 XML 声明。 */
    @TestCase
    public func elementWithoutDeclaration(): Unit {
        let element = XmlElement("a").withText("x")
        let text = writeElementText(element)
        @Assert(text == "<a>x</a>")
        @Assert(!text.contains("<?xml"))
    }

    /** `close()` 冲刷底层并关闭。 */
    @TestCase
    public func closeFlushes(): Unit {
        let output = RecordingOutputStream()
        let writer = XmlWriter(output, options: XmlWriterOptions())
        writer.write(XmlElement("a"))
        @Assert(output.bytes().size == 0)
        writer.close()
        @Assert(output.text() == "<a/>")
        @Assert(output.flushCount >= 1)
    }

    /** `flush()` 冲刷自身缓冲到底层。 */
    @TestCase
    public func flushWrites(): Unit {
        let output = RecordingOutputStream()
        let writer = XmlWriter(output, options: XmlWriterOptions())
        writer.write(XmlElement("a"))
        writer.flush()
        @Assert(output.text() == "<a/>")
    }

    /** `setAttr` 出来的属性按名字输出，值被转义。 */
    @TestCase
    public func attributeEscaping(): Unit {
        let element = XmlElement("a")
        element.setAttr("b", "a\"b")
        @Assert(writeElementText(element) == "<a b=\"a&quot;b\"/>")
    }

    /** 文本里的回车写成 `&#13;`，重新解析仍是 `\r`。 */
    @TestCase
    public func carriageReturnRoundTrip(): Unit {
        let element = XmlElement("a").withText("a\rb")
        let text = writeElementText(element)
        @Assert(text.contains("a&#13;b"))
        @Assert(parseText(text).root.getOrThrow().text() == "a\rb")
    }
}

@Test
public class CdataMode_test {
    /** `Always` 包裹普通文本。 */
    @TestCase
    public func alwaysWraps(): Unit {
        let element = XmlElement("a").withText("a<b")
        let text = writeElementText(element, options: XmlWriterOptions(cdata: CdataMode.Always))
        @Assert(text.contains("<![CDATA[a<b]]>"))
    }

    /** `]]>` 被拆分且往返语义不变。 */
    @TestCase
    public func bracketSplit(): Unit {
        let element = XmlElement("a").withText("a]]>b")
        let text = writeElementText(element, options: XmlWriterOptions(cdata: CdataMode.Always))
        @Assert(text.contains("a]]]]><![CDATA[>b"))
        @Assert(parseText(text).root.getOrThrow().text() == "a]]>b")
    }

    /** `Always` 不影响属性值。 */
    @TestCase
    public func alwaysDoesNotAffectAttributes(): Unit {
        let element = XmlElement("a")
        element.setAttr("b", "a<b")
        let text = writeElementText(element, options: XmlWriterOptions(cdata: CdataMode.Always))
        @Assert(text.contains("a&lt;b"))
        @Assert(!text.contains("<![CDATA["))
    }

    /** `Never` 强制转义。 */
    @TestCase
    public func neverEscapes(): Unit {
        let element = XmlElement("a").withText("a<b")
        let text = writeElementText(element, options: XmlWriterOptions(cdata: CdataMode.Never))
        @Assert(text == "<a>a&lt;b</a>")
    }

    /** 枚举比较走显式实现。 */
    @TestCase
    public func cdataEnumEquality(): Unit {
        @Assert(CdataMode.Auto == CdataMode.Auto)
        @Assert(CdataMode.Auto != CdataMode.Always)
        @Assert(CdataMode.Never.toString() == "Never")
        @Assert(InvalidCharMode.Throw != InvalidCharMode.Replace)
    }
}
