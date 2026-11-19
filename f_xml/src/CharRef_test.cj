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
public class CharRef_test {
    @TestCase
    public func highCodepoint(): Unit {
        let doc = parseText("<a>&#x1F600;</a>")
        @Assert(doc.root.getOrThrow().text() == "😀")
        @Assert(runesOf(doc.root.getOrThrow().text()).size == 1)
    }

    @TestCase
    public func nulRejected(): Unit {
        assertXmlError({=> parseText("<a>&#0;</a>")}, "非法的字符引用")
    }

    @TestCase
    public func surrogateRejected(): Unit {
        assertXmlError({=> parseText("<a>&#xD800;</a>")}, "D800")
    }

    @TestCase
    public func beyondRangeRejected(): Unit {
        assertXmlError({=> parseText("<a>&#x110000;</a>")}, "非法的字符引用")
    }

    @TestCase
    public func htmlEntityRejected(): Unit {
        assertXmlError({=> parseText("<a>&nbsp;</a>")}, "未声明")
    }

    @TestCase
    public func bareAmpersandRejected(): Unit {
        assertXmlError({=> parseText("<a>a & b</a>")}, "&amp;")
    }

    @TestCase
    public func entityWithoutSemicolonRejected(): Unit {
        assertXmlError({=> parseText("<a>&foo</a>")}, "分号")
    }
}

@Test
public class Cdata_test {
    /** 只有 `]]>` 结束，`]]` 不结束。 */
    @TestCase
    public func doubleBracketInside(): Unit {
        let doc = parseText("<a><![CDATA[a]]b]]></a>")
        match (doc.root.getOrThrow().children[0]) {
            case XmlNode.CDataNode(t) => @Assert(t == "a]]b")
            case _ => assertTrue(false, "应为 CDATA")
        }
    }

    /** 空 CDATA 合法。 */
    @TestCase
    public func emptyCdata(): Unit {
        let doc = parseText("<a><![CDATA[]]></a>")
        match (doc.root.getOrThrow().children[0]) {
            case XmlNode.CDataNode(t) => @Assert(t == "")
            case _ => assertTrue(false, "应为 CDATA")
        }
    }

    /** 相邻 CDATA 各一次事件。 */
    @TestCase
    public func adjacentCdata(): Unit {
        let log = parseEventLog("<a><![CDATA[1]]><![CDATA[2]]></a>")
        var count: Int64 = 0
        for (line in log) {
            if (line.startsWith("CDATA")) {
                count++
            }
        }
        @Assert(count == 2)
    }

    /** CDATA 与文本混排顺序不乱。 */
    @TestCase
    public func mixedTextAndCdata(): Unit {
        let doc = parseText("<a>x<![CDATA[y]]>z</a>")
        let root = doc.root.getOrThrow()
        @Assert(root.children.size == 3)
        @Assert(root.text() == "xyz")
    }

    /** CDATA 内不展开实体。 */
    @TestCase
    public func cdataNoEntityExpansion(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"v\">]><a><![CDATA[&e;]]></a>")
        @Assert(doc.root.getOrThrow().text() == "&e;")
    }
}

@Test
public class CommentPi_test {
    /** 注释内容里出现 `>` 不提前结束。 */
    @TestCase
    public func commentWithGt(): Unit {
        let doc = parseText("<!-- a > b --><a/>")
        match (doc.prolog[0]) {
            case XmlNode.CommentNode(t) => @Assert(t == " a > b ")
            case _ => assertTrue(false, "应为注释")
        }
    }

    /** PI data 里的 `?` 不提前结束。 */
    @TestCase
    public func piWithQuestionMark(): Unit {
        let doc = parseText("<?p a?b?><a/>")
        match (doc.prolog[0]) {
            case XmlNode.PiNode(target, data) =>
                @Assert(target == "p")
                @Assert(data == "a?b")
            case _ => assertTrue(false, "应为 PI")
        }
    }

    /** 注释内不展开实体。 */
    @TestCase
    public func commentNoEntityExpansion(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"v\">]><!-- &e; --><a/>")
        match (doc.prolog[0]) {
            case XmlNode.CommentNode(t) => @Assert(t == " &e; ")
            case _ => assertTrue(false, "应为注释")
        }
    }
}
