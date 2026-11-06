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

/**
 * 五个格式样本 + 组合矩阵。
 *
 * 样本只用来验证「风格变体」都能读，不作为「通用性」的唯一证据——
 * 通用性由 xmlconf 与语法矩阵承担。
 */
@Test
public class FormatSamples_test {
    /** RSS 2.0：默认命名空间 + 混合内容 + CDATA。 */
    @TestCase
    public func rss(): Unit {
        let doc = parseText(
            "<rss version=\"2.0\"><channel><title>我的订阅</title>" +
            "<item><title>一</title><description><![CDATA[<b>html</b>]]></description></item>" +
            "</channel></rss>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.attr("version") == Some("2.0"))
        @Assert(root.child("channel").getOrThrow().child("title").getOrThrow().text() == "我的订阅")
    }

    /** Atom：带命名空间前缀 + xml:lang。 */
    @TestCase
    public func atom(): Unit {
        let doc = parseText(
            "<feed xmlns=\"http://www.w3.org/2005/Atom\" xml:lang=\"zh\">" +
            "<title>标题</title><entry><id>urn:1</id></entry></feed>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.name.uri == Some("http://www.w3.org/2005/Atom"))
        @Assert(root.attr(XML_NS_URI, "lang") == Some("zh"))
        @Assert(root.child("entry").getOrThrow().child("id").getOrThrow().text() == "urn:1")
    }

    /** SVG：自闭合元素 + 属性里的空格。 */
    @TestCase
    public func svg(): Unit {
        let doc = parseText(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<rect x=\"0\" y=\"0\" width=\"5\" height=\"5\"/><circle r=\"2\"/></svg>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.childrenOf("rect").size == 1)
        @Assert(root.childrenOf("rect")[0].attr("width") == Some("5"))
    }

    /** SOAP：信封 + 前缀 + 混合内容。 */
    @TestCase
    public func soap(): Unit {
        let doc = parseText(
            "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\">" +
            "<soap:Body><m:GetPrice xmlns:m=\"urn:shop\"><m:Item>Apple</m:Item></m:GetPrice>" +
            "</soap:Body></soap:Envelope>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.name.prefix == Some("soap"))
        @Assert(root.child("Body").getOrThrow().child("GetPrice").getOrThrow().text() == "Apple")
    }

    /** POM：DOCTYPE + 注释 + 缩进空白。 */
    @TestCase
    public func pom(): Unit {
        let doc = parseText(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n" +
            "  <!-- 坐标 -->\n" +
            "  <groupId>com.example</groupId>\n" +
            "  <artifactId>demo</artifactId>\n" +
            "</project>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.child("groupId").getOrThrow().text() == "com.example")
        @Assert(root.children.size == 7) // 空白 / 注释 / 空白 / 元素 / 空白 / 元素 / 空白
    }

    /** OOXML 片段：`xml:space="preserve"` 保留首尾空格。 */
    @TestCase
    public func ooxmlXmlSpace(): Unit {
        let doc = parseText(
            "<w:p xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
            "<w:t xml:space=\"preserve\"> x </w:t></w:p>",
            options: XmlParserOptions(trimWhitespaceOnly: true)
        )
        let run = doc.root.getOrThrow().child("t").getOrThrow()
        @Assert(run.text() == " x ")
    }
}

@Test
public class Combination_test {
    /** 带命名空间的自闭合元素：Start + End 两条事件，URI 正确。 */
    @TestCase
    public func selfClosingWithNamespace(): Unit {
        let log = parseEventLog("<x:a xmlns:x=\"A\"/>")
        @Assert(log.contains("START QName(x,a,A) attrs=0 selfClosing=true"))
        @Assert(log.contains("END QName(x,a,A)"))
    }

    /** CDATA 在带命名空间的元素里。 */
    @TestCase
    public func cdataInsideNamespacedElement(): Unit {
        let doc = parseText("<x:a xmlns:x=\"A\"><![CDATA[<b>&]]></x:a>")
        @Assert(doc.root.getOrThrow().text() == "<b>&")
    }

    /** 注释夹在元素之间 + PI 紧邻 CDATA。 */
    @TestCase
    public func commentAndPiAroundCdata(): Unit {
        let doc = parseText("<a><b/><!--c--><?p d?><![CDATA[v]]></a>")
        let root = doc.root.getOrThrow()
        @Assert(root.children.size == 4)
    }

    /** 深层嵌套中某层重置命名空间。 */
    @TestCase
    public func nestedNamespaceReset(): Unit {
        let doc = parseText("<a xmlns=\"A\"><b><c xmlns=\"\"/></b></a>")
        let root = doc.root.getOrThrow()
        @Assert(root.child("b").getOrThrow().child("c").getOrThrow().name.uri.isNone())
    }

    /** 属性值跨行 + 实体展开 + 命名空间三者叠加。 */
    @TestCase
    public func multiLineAttributeWithEntity(): Unit {
        let doc = parseText(
            "<!DOCTYPE a [<!ENTITY e \"x&#10;y\">]><a xmlns:p=\"u\" b=\"&e;\" p:c=\"1\"/>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.attr("b") == Some("x y"))
        @Assert(root.attr("u", "c") == Some("1"))
    }
}
