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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_xml.*

@Test
public class SvgUnknownElement_test {
    private static let INKSCAPE = "http://www.inkscape.org/namespaces/inkscape"

    /** 非 SVG 命名空间元素保留前缀、URI、属性与子树。 */
    @TestCase
    public func foreignNamespacePreserved(): Unit {
        let rawName = QName("namedview", prefix: Some("sodipodi"), uri: Some(SvgUnknownElement_test.INKSCAPE))
        let element = SvgUnknownElement(rawName)
        @Assert(element.tag == "namedview")
        @Assert(element.namespace == SvgUnknownElement_test.INKSCAPE)
        @Assert(element.rawName.prefix == Some("sodipodi"))
        @Assert(element.rawName.uri == Some(SvgUnknownElement_test.INKSCAPE))

        element.setAttr("id", "base")
        element.setAttr(SvgUnknownElement_test.INKSCAPE, "label", "layer")
        let child = SvgElement("child", namespace: SvgUnknownElement_test.INKSCAPE)
        element.appendElement(child)
        @Assert(element.attr("id") == Some("base"))
        @Assert(element.attr(SvgUnknownElement_test.INKSCAPE, "label") == Some("layer"))
        @Assert(element.children.size == 1)
        @Assert(child.parent.getOrThrow() == element)
    }

    /** toXmlElement 保留前缀与 URI。 */
    @TestCase
    public func xmlMapping(): Unit {
        let rawName = QName("namedview", prefix: Some("sodipodi"), uri: Some(SvgUnknownElement_test.INKSCAPE))
        let element = SvgUnknownElement(rawName)
        element.setAttr("id", "x")
        let xml = element.toXmlElement()
        @Assert(xml.name.local == "namedview")
        @Assert(xml.name.prefix == Some("sodipodi"))
        @Assert(xml.name.uri == Some(SvgUnknownElement_test.INKSCAPE))
        @Assert(xml.attr("id") == Some("x"))
        @Assert(element.toString() == "<sodipodi:namedview id=\"x\"/>")
    }

    /** SVG 命名空间的未知标签。 */
    @TestCase
    public func svgNamespaceUnknown(): Unit {
        let element = SvgUnknownElement(QName("animate", uri: Some(SvgNamespaces.SVG)))
        @Assert(element.tag == "animate")
        @Assert(element.namespace == SvgNamespaces.SVG)
        @Assert(element.rawName.prefix.isNone())
        @Assert(element.toString() == "<animate/>")
    }

    /** 注释 / PI / CDATA 子节点原样保留。 */
    @TestCase
    public func preservesAllNodeKinds(): Unit {
        let element = SvgUnknownElement(QName("x", uri: Some("urn:x")))
        element.appendChild(SvgNode.CommentNode("c"))
        element.appendChild(SvgNode.CDataNode("d"))
        element.appendChild(SvgNode.PiNode("p", "v"))
        @Assert(element.children.size == 3)
        @Assert(element.toString() == "<x><!--c--><![CDATA[d]]><?p v?></x>")
    }
}

@Test
public class SvgDocument_test {
    /** elementById 深度优先返回第一个。 */
    @TestCase
    public func elementById(): Unit {
        let root = SvgRoot()
        let group = SvgElement("g")
        let first = SvgElement("rect")
        first.id = "dup"
        first.setAttr("data-order", "1")
        let second = SvgElement("rect")
        second.id = "dup"
        second.setAttr("data-order", "2")
        group.appendElement(first)
        group.appendElement(second)
        root.appendElement(group)
        let document = SvgDocument(root)
        let found = document.elementById("dup")
        @Assert(found.isSome())
        @Assert(found.getOrThrow().attr("data-order") == Some("1"))
        @Assert(document.elementById("missing").isNone())
    }

    /** elementsByTag 跨命名空间按 local name 匹配。 */
    @TestCase
    public func elementsByTag(): Unit {
        let root = SvgRoot()
        let use = SvgUse()
        use.href = "#a"
        root.appendElement(use)
        let foreignElement = SvgUnknownElement(QName("use", prefix: Some("x"), uri: Some("urn:x")))
        root.appendElement(foreignElement)
        let document = SvgDocument(root)
        let found = document.elementsByTag("use")
        @Assert(found.size == 2)
        @Assert(found[0].tag == "use")
        @Assert(found[1].tag == "use")
        @Assert(document.elementsByTag("rect").size == 0)
    }

    /** elementsByTag 只返回后代，不含根元素自身。 */
    @TestCase
    public func elementsByTagExcludesRoot(): Unit {
        let root = SvgRoot()
        root.appendElement(SvgRect(width: SvgLength(1.0), height: SvgLength(1.0)))
        let document = SvgDocument(root)
        @Assert(document.elementsByTag("svg").size == 0)
        @Assert(document.elementsByTag("rect").size == 1)
    }

    /** SvgDocument.toString 与 writeSvgString 默认选项一致。 */
    @TestCase
    public func toStringMatchesWriter(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><use href=\"#a\"/></svg>"
        )
        let text = document.toString()
        @Assert(text == writeSvgString(document))
        @Assert(text.contains("xlink:href=\"#a\""))
    }

    /** warnings 只增不减。 */
    @TestCase
    public func warningsAccumulate(): Unit {
        let document = SvgDocument(SvgRoot())
        @Assert(document.warnings.size == 0)
        document.warnings.add("first")
        document.warnings.add("second")
        @Assert(document.warnings.size == 2)
        @Assert(document.warnings[0] == "first")
        @Assert(document.warnings[1] == "second")
    }

    /** toXmlDocument 保留声明、DOCTYPE、prolog / epilog 与根。 */
    @TestCase
    public func toXmlDocument(): Unit {
        let root = SvgRoot(width: SvgLength(100.0))
        let document = SvgDocument(root)
        document.declaration = XmlDeclaration("1.0", encoding: Some("UTF-8"))
        document.doctype = DocTypeInfo("svg")
        document.prolog.add(SvgNode.CommentNode("before"))
        document.epilog.add(SvgNode.CommentNode("after"))
        let xml = document.toXmlDocument()
        @Assert(xml.root.isSome())
        @Assert(xml.root.getOrThrow().name.local == "svg")
        @Assert(xml.root.getOrThrow().attr("width") == Some("100"))
        @Assert(xml.declaration.isSome())
        @Assert(xml.doctype.isSome())
        @Assert(xml.prolog.size == 1)
        @Assert(xml.epilog.size == 1)
        @Assert(document.toString().contains("<?xml"))
        @Assert(document.toString().contains("before"))
        @Assert(document.toString().contains("after"))
    }
}
