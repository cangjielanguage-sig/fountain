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
import fountain::f_xml.QName

@Test
public class SvgElement_test {
    /** 基本构造与缺省值。 */
    @TestCase
    public func construction(): Unit {
        let element = SvgElement("g")
        @Assert(element.tag == "g")
        @Assert(element.namespace == SvgNamespaces.SVG)
        @Assert(element.attributes.size == 0)
        @Assert(element.children.size == 0)
        @Assert(element.parent.isNone())
        let custom = SvgElement("foo", namespace: "urn:test")
        @Assert(custom.namespace == "urn:test")
    }

    /** attr / setAttr / removeAttr 与同名原位替换。 */
    @TestCase
    public func attributes(): Unit {
        let element = SvgElement("rect")
        element.setAttr("x", "1").setAttr("y", "2")
        @Assert(element.attr("x") == Some("1"))
        @Assert(element.attr("missing").isNone())
        @Assert(element.attributes.size == 2)
        @Assert(element.attributes[0].name.local == "x")

        element.setAttr("x", "10")
        @Assert(element.attributes.size == 2)
        @Assert(element.attributes[0].name.local == "x")
        @Assert(element.attr("x") == Some("10"))
        @Assert(element.attributes[1].name.local == "y")

        element.setAttr("z", "3")
        @Assert(element.attributes[2].name.local == "z")

        @Assert(element.removeAttr("y"))
        @Assert(!element.removeAttr("y"))
        @Assert(element.attr("y").isNone())
        @Assert(element.attributes.size == 2)
    }

    /** 命名空间属性与裸名互不干扰。 */
    @TestCase
    public func namespacedAttributes(): Unit {
        let element = SvgElement("use")
        element.setAttr(SvgNamespaces.XLINK, "href", "#a")
        @Assert(element.attr(SvgNamespaces.XLINK, "href") == Some("#a"))
        @Assert(element.attr("href").isNone())
        element.setAttr("href", "#b")
        @Assert(element.attr("href") == Some("#b"))
        @Assert(element.attr(SvgNamespaces.XLINK, "href") == Some("#a"))
        @Assert(element.attributes.size == 2)
        @Assert(element.attributes[0].name.prefix == Some("xlink"))
    }

    /** 子节点顺序与 parent 维护。 */
    @TestCase
    public func children(): Unit {
        let root = SvgElement("svg")
        let first = SvgElement("g")
        let second = SvgElement("rect")
        root.appendElement(first)
        root.appendElement(second)
        @Assert(root.children.size == 2)
        @Assert(root.childrenOf("g").size == 1)
        @Assert(root.childrenOf("rect").size == 1)
        @Assert(first.parent.getOrThrow().tag == "svg")
        @Assert(second.parent.getOrThrow().tag == "svg")
        @Assert(root.child("g").getOrThrow().tag == "g")
        @Assert(root.child("missing").isNone())

        root.appendChild(SvgNode.TextNode("hi"))
        @Assert(root.children.size == 3)
        @Assert(root.children[2].toString() == "hi")
    }

    /** text() 拼接后代文本与 CDATA，忽略注释与 PI。 */
    @TestCase
    public func textContent(): Unit {
        let root = SvgElement("text")
        root.appendText("a")
        let child = SvgElement("tspan")
        child.appendText("b")
        child.appendChild(SvgNode.CDataNode("c"))
        child.appendChild(SvgNode.CommentNode("ignored"))
        child.appendChild(SvgNode.PiNode("pi", "data"))
        root.appendElement(child)
        root.appendText("d")
        @Assert(root.text() == "abcd")
    }

    /** elementPath 的同名兄弟编号。 */
    @TestCase
    public func elementPaths(): Unit {
        let root = SvgElement("svg")
        let firstGroup = SvgElement("g")
        let secondGroup = SvgElement("g")
        let rect = SvgElement("rect")
        root.appendElement(firstGroup)
        root.appendElement(secondGroup)
        secondGroup.appendElement(rect)
        @Assert(rect.elementPath() == "/svg[1]/g[2]/rect[1]")
        @Assert(firstGroup.elementPath() == "/svg[1]/g[1]")
        @Assert(root.elementPath() == "/svg[1]")
        let detached = SvgElement("rect")
        @Assert(detached.elementPath() == "/rect[1]")
    }

    /** 通用类型化属性。 */
    @TestCase
    public func typedCommonProperties(): Unit {
        let element = SvgElement("rect")
        element.id = "a"
        element.className = "b c"
        element.style = "fill:red"
        @Assert(element.id == Some("a"))
        @Assert(element.className == Some("b c"))
        @Assert(element.style == Some("fill:red"))
        @Assert(element.attr("id") == Some("a"))
        @Assert(element.attr("class") == Some("b c"))

        element.id = None
        @Assert(element.id.isNone())
        @Assert(element.attr("id").isNone())
    }

    /** 类型化缓存随 attributesVersion 失效。 */
    @TestCase
    public func cacheInvalidation(): Unit {
        let element = SvgElement("rect")
        element.setAttr("transform", "scale(2)")
        let first = element.transform
        @Assert(first.isSome())
        @Assert(matrixNear(first.getOrThrow().toMatrix(), SvgMatrix.scale(2.0, 2.0)))

        element.setAttr("transform", "translate(3 4)")
        let second = element.transform
        @Assert(matrixNear(second.getOrThrow().toMatrix(), SvgMatrix.translate(3.0, 4.0)))

        @Assert(element.removeAttr("transform"))
        @Assert(element.transform.isNone())
    }

    /** 非法类型化值读取返回 None，不抛错。 */
    @TestCase
    public func invalidTypedValue(): Unit {
        let element = SvgElement("rect")
        element.setAttr("transform", "bogus(1)")
        @Assert(element.transform.isNone())
    }

    /** toXmlElement 的标签、命名空间与属性映射。 */
    @TestCase
    public func toXmlElement(): Unit {
        let element = SvgElement("rect", namespace: SvgNamespaces.SVG)
        element.setAttr("x", "10")
        element.setAttr(SvgNamespaces.XLINK, "href", "#a")
        element.appendText("t")
        let xml = element.toXmlElement()
        @Assert(xml.name.local == "rect")
        @Assert(xml.name.uri == Some(SvgNamespaces.SVG))
        @Assert(xml.attr("x") == Some("10"))
        @Assert(xml.attr(SvgNamespaces.XLINK, "href") == Some("#a"))
        @Assert(xml.text() == "t")
    }

    /** 紧凑序列化。 */
    @TestCase
    public func compactSerialization(): Unit {
        let rect = SvgElement("rect")
        rect.setAttr("x", "10")
        rect.setAttr("width", "80")
        @Assert(rect.toString() == "<rect x=\"10\" width=\"80\"/>")
        let group = SvgElement("g")
        group.appendElement(rect)
        @Assert(group.toString() == "<g><rect x=\"10\" width=\"80\"/></g>")
    }

    /** SvgAttribute 的结构与字符串。 */
    @TestCase
    public func attributeStruct(): Unit {
        let attribute = SvgAttribute(QName("x", uri: Some(SvgNamespaces.SVG)), "1")
        @Assert(attribute.name.local == "x")
        @Assert(attribute.value == "1")
        @Assert(attribute.toString() == "x=\"1\"")
    }

    /** SvgNode 的字符串形式。 */
    @TestCase
    public func nodeStrings(): Unit {
        @Assert(SvgNode.TextNode("a").toString() == "a")
        @Assert(SvgNode.CDataNode("a").toString() == "<![CDATA[a]]>")
        @Assert(SvgNode.CommentNode("a").toString() == "<!--a-->")
        @Assert(SvgNode.PiNode("p", "d").toString() == "<?p d?>")
    }
}
