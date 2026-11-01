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

@Test
public class DomBuilder_test {
    /** 相邻 Text 合并为一个节点：`x&amp;y` 解出来是 `x&y`，只有一个 TextNode。 */
    @TestCase
    public func adjacentTextMerged(): Unit {
        let doc = parseText("<a>x&amp;y</a>")
        let root = doc.root.getOrThrow()
        assertTrue(root.children.size == 1, "实际子节点数 ${root.children.size}")
        match (root.children[0]) {
            case XmlNode.TextNode(text) => @Assert(text == "x&y")
            case _ => assertTrue(false, "应为文本节点")
        }
    }

    /** Text 与 CDATA 不合并。 */
    @TestCase
    public func textAndCDataSeparate(): Unit {
        let doc = parseText("<a>x<![CDATA[y]]></a>")
        let root = doc.root.getOrThrow()
        @Assert(root.children.size == 2)
        match (root.children[0]) {
            case XmlNode.TextNode(t) => @Assert(t == "x")
            case _ => assertTrue(false, "第一个应为文本")
        }
        match (root.children[1]) {
            case XmlNode.CDataNode(t) => @Assert(t == "y")
            case _ => assertTrue(false, "第二个应为 CDATA")
        }
    }

    /** 默认保留缩进空白。 */
    @TestCase
    public func whitespaceKeptByDefault(): Unit {
        let doc = parseText("<a>\n  <b/>\n</a>")
        let root = doc.root.getOrThrow()
        var textNodes: Int64 = 0
        for (node in root.children) {
            match (node) {
                case XmlNode.TextNode(_) => textNodes++
                case _ => ()
            }
        }
        @Assert(textNodes == 2)
    }

    /** `trimWhitespaceOnly` 丢弃纯空白。 */
    @TestCase
    public func trimWhitespaceOnly(): Unit {
        let doc = parseText("<a>\n  <b/>\n</a>", options: XmlParserOptions(trimWhitespaceOnly: true))
        let root = doc.root.getOrThrow()
        @Assert(root.children.size == 1)
        match (root.children[0]) {
            case XmlNode.ElementNode(e) => @Assert(e.name.local == "b")
            case _ => assertTrue(false, "应为元素节点")
        }
    }

    /** 非纯空白文本不被 trim 丢弃。 */
    @TestCase
    public func trimKeepsNonWhitespace(): Unit {
        let doc = parseText("<a> x </a>", options: XmlParserOptions(trimWhitespaceOnly: true))
        let root = doc.root.getOrThrow()
        @Assert(root.text() == " x ")
    }

    /** `xml:space="preserve"` 强制保留。 */
    @TestCase
    public func xmlSpacePreserve(): Unit {
        let doc = parseText(
            "<a xml:space=\"preserve\">  <b/>  </a>",
            options: XmlParserOptions(trimWhitespaceOnly: true)
        )
        let root = doc.root.getOrThrow()
        assertTrue(root.children.size == 3, "实际 ${root.children.size}")
    }

    /** `xml:space="default"` 恢复默认（丢弃）。 */
    @TestCase
    public func xmlSpaceDefault(): Unit {
        let doc = parseText(
            "<a xml:space=\"preserve\"><b xml:space=\"default\">  </b></a>",
            options: XmlParserOptions(trimWhitespaceOnly: true)
        )
        let root = doc.root.getOrThrow()
        let b = root.child("b").getOrThrow()
        @Assert(b.children.size == 0)
    }

    /** 注释与 PI 保留为节点，prolog / epilog 分开。 */
    @TestCase
    public func prologAndEpilog(): Unit {
        let doc = parseText("<?xml version=\"1.0\"?><!--p--><a/><?q v?><!--e-->")
        @Assert(doc.prolog.size == 1)
        @Assert(doc.epilog.size == 2)
    }

    /** 建树深度上限。 */
    @TestCase
    public func depthLimit(): Unit {
        let open = repeatText("<a>", 101)
        let close = repeatText("</a>", 101)
        assertXmlError({=> parseText(open + close, options: XmlParserOptions(maxElementDepth: 100))}, "嵌套深度")
    }
}
