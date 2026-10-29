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
public class XmlElement_test {
    /** 带前缀与不带前缀的同名元素都能按 local name 命中。 */
    @TestCase
    public func childrenByLocalName(): Unit {
        let doc = parseText("<r xmlns:x=\"u\"><x:item/><item/></r>")
        let root = doc.root.getOrThrow()
        @Assert(root.childrenOf("item").size == 2)
        @Assert(root.child("item").isSome())
    }

    /** 属性按命名空间精确取。 */
    @TestCase
    public func attrByNamespace(): Unit {
        let doc = parseText("<a xmlns:x=\"u\" id=\"1\" x:id=\"2\"/>")
        let root = doc.root.getOrThrow()
        @Assert(root.attr("id") == Some("1"))
        @Assert(root.attr("u", "id") == Some("2"))
        @Assert(root.attr("id") == Some("1"))
    }

    /** `setAttr` 覆盖同名属性。 */
    @TestCase
    public func setAttrOverwrites(): Unit {
        let element = XmlElement("a")
        element.setAttr("a", "1")
        element.setAttr("a", "2")
        @Assert(element.attributes.size == 1)
        @Assert(element.attr("a") == Some("2"))
    }

    /** `text()` 跳过注释与 PI，包含 CDATA。 */
    @TestCase
    public func textSkipsMisc(): Unit {
        let element = XmlElement("a")
        element.appendChild(XmlNode.TextNode("a"))
        element.appendChild(XmlNode.CommentNode("c"))
        element.appendChild(XmlNode.CDataNode("b"))
        element.appendChild(XmlNode.PiNode("p", "d"))
        @Assert(element.text() == "ab")
    }

    /** 链式构造。 */
    @TestCase
    public func chainedBuild(): Unit {
        let element = XmlElement("a").withText("x").appendChild(XmlNode.CommentNode("c"))
        @Assert(element.children.size == 2)
        @Assert(element.text() == "x")
    }

    /** `XmlEntityRef` 是工厂函数，返回实体引用节点。 */
    @TestCase
    public func entityRefFactory(): Unit {
        let node = XmlEntityRef("company")
        match (node) {
            case XmlNode.EntityRefNode(name) => @Assert(name == "company")
            case _ => assertTrue(false, "应为 EntityRefNode")
        }
    }

    /** DOCTYPE 携带实体声明，顺序与声明顺序一致。 */
    @TestCase
    public func doctypeEntities(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"v\"><!ENTITY f \"w\">]><a>&e;&f;</a>")
        let doctype = doc.doctype.getOrThrow()
        @Assert(doctype.entities.size == 2)
        @Assert(doctype.entities[0].name == "e")
        @Assert(doctype.entities[1].name == "f")
        @Assert(doc.root.getOrThrow().text() == "vw")
    }
}

@Test
public class QName_test {
    @TestCase
    public func literalName(): Unit {
        @Assert(QName("row", prefix: Some("x"), uri: Some("u")).toString() == "x:row")
        @Assert(QName("row").toString() == "row")
    }

    /** 比较按展开名：前缀不同但 uri + local 相同视为相等。 */
    @TestCase
    public func equalityByExpandedName(): Unit {
        let a = QName("x", prefix: Some("p"), uri: Some("u"))
        let b = QName("x", prefix: Some("q"), uri: Some("u"))
        @Assert(a == b)
        @Assert(QName("x") != QName("x", uri: Some("u")))
    }
}
