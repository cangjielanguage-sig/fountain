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
public class NamespaceScope_test {
    /** 默认命名空间继承到子元素。 */
    @TestCase
    public func defaultNamespaceInherited(): Unit {
        let doc = parseText("<a xmlns=\"u\"><b/></a>")
        let root = doc.root.getOrThrow()
        @Assert(root.name.uri == Some("u"))
        @Assert(root.child("b").getOrThrow().name.uri == Some("u"))
    }

    /** 前缀声明与使用。 */
    @TestCase
    public func prefixDeclaration(): Unit {
        let doc = parseText("<x:a xmlns:x=\"u\"/>")
        let root = doc.root.getOrThrow()
        @Assert(root.name.prefix == Some("x"))
        @Assert(root.name.uri == Some("u"))
    }

    /** `xmlns=""` 重置默认命名空间。 */
    @TestCase
    public func xmlnsEmptyResets(): Unit {
        let doc = parseText("<a xmlns=\"X\"><b xmlns=\"\"/></a>")
        let root = doc.root.getOrThrow()
        @Assert(root.name.uri == Some("X"))
        @Assert(root.child("b").getOrThrow().name.uri.isNone())
    }

    /** 嵌套重定义后恢复。 */
    @TestCase
    public func nestedRedefinitionRestores(): Unit {
        let doc = parseText("<a xmlns:p=\"u1\"><p:b xmlns:p=\"u2\"/><p:c/></a>")
        let root = doc.root.getOrThrow()
        let b = root.childrenOf("b")[0]
        let c = root.childrenOf("c")[0]
        @Assert(b.name.uri == Some("u2"))
        @Assert(c.name.uri == Some("u1"))
    }

    /** 多个前缀指向同一 URI 视为同一命名空间。 */
    @TestCase
    public func multiplePrefixesSameUri(): Unit {
        let doc = parseText("<a xmlns:p=\"u\" xmlns:q=\"u\"><p:b/><q:b/></a>")
        let root = doc.root.getOrThrow()
        let first = root.childrenOf("b")[0]
        let second = root.childrenOf("b")[1]
        @Assert(first.name.uri == second.name.uri)
    }

    /** `xml` 前缀无需声明。 */
    @TestCase
    public func xmlPrefixImplicit(): Unit {
        let doc = parseText("<a xml:lang=\"zh\"/>")
        let root = doc.root.getOrThrow()
        @Assert(root.attributes[0].name.prefix == Some("xml"))
        @Assert(root.attributes[0].name.uri == Some(XML_NS_URI))
    }

    /** 属性不受默认命名空间影响。 */
    @TestCase
    public func attributeUnaffectedByDefaultNs(): Unit {
        let doc = parseText("<a xmlns=\"X\" b=\"1\"/>")
        let root = doc.root.getOrThrow()
        @Assert(root.name.uri == Some("X"))
        @Assert(root.attributes[0].name.uri.isNone())
    }

    /** 未声明前缀报错，消息含前缀。 */
    @TestCase
    public func undeclaredPrefix(): Unit {
        assertXmlError({=> parseText("<p:a/>")}, "前缀")
    }

    /** `xmlns` 作元素前缀报错。 */
    @TestCase
    public func xmlnsAsElementPrefix(): Unit {
        assertXmlError({=> parseText("<xmlns:a/>")}, "xmlns")
    }

    /** `xmlns` 作前缀声明的前缀报错。 */
    @TestCase
    public func xmlnsAsPrefixRejected(): Unit {
        assertXmlError({=> parseText("<a xmlns:xmlns=\"u\"/>")}, "xmlns")
    }

    /** 命名空间声明不出现在属性集合里。 */
    @TestCase
    public func namespaceDeclarationsNotAttributes(): Unit {
        let doc = parseText("<a xmlns:x=\"u\" b=\"1\"/>")
        let root = doc.root.getOrThrow()
        @Assert(root.attributes.size == 1)
        @Assert(root.attributes[0].name.local == "b")
    }

    /** `xmlns:p=""` 非法。 */
    @TestCase
    public func emptyUriForPrefixRejected(): Unit {
        assertXmlError({=> parseText("<a xmlns:p=\"\"/>")}, "空 URI")
    }

    /** 非 xml 前缀不能绑定到 xml 命名空间。 */
    @TestCase
    public func reservedXmlUriRejected(): Unit {
        assertXmlError({=> parseText("<a xmlns:p=\"${XML_NS_URI}\"/>")}, "xml")
    }
}
