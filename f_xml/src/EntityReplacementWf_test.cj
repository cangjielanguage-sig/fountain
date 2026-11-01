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
 * WFC: Parsed Entity——内部一般实体的替换文本必须自身良构（`design.md` §6.7）。
 *
 * 校验的是「替换文本」这一层，与 DTD 内容模型无关：`<!ENTITY e "<b>">` 配 `<a>&e;</a>`
 * 不需要任何 `<!ELEMENT>` 声明就已经不良构。
 */
@Test
public class EntityReplacementWf_test {
    /** 实体里的开始标签未闭合。 */
    @TestCase
    public func unclosedStartTagInEntity(): Unit {
        let error = assertXmlError({
            => parseText("<!DOCTYPE a [<!ENTITY e \"<b>\">]><a>&e;</a>")
        }, "e")
        assertTrue(error.message.contains("不良构"), "消息应说明替换文本不良构：${error.message}")
        @Assert(error.line > 0 && error.column > 0)
    }

    /** 实体里的孤立结束标签。 */
    @TestCase
    public func strayEndTagInEntity(): Unit {
        let error = assertXmlError({
            => parseText("<!DOCTYPE a [<!ENTITY e \"</a>\">]><a>&e;</a>")
        }, "e")
        assertTrue(error.message.contains("结束标签"), "消息应指出孤立结束标签：${error.message}")
    }

    /** 实体内部配平的标签合法。 */
    @TestCase
    public func balancedMarkupInEntity(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"<b>x</b>\">]><a>&e;</a>")
        let root = doc.root.getOrThrow()
        @Assert(root.childrenOf("b").size == 1)
        @Assert(root.child("b").getOrThrow().text() == "x")
    }

    /** 属性值位置的替换文本含小于号：既报实体名也报属性名。 */
    @TestCase
    public func attributeValueEntityWithMarkup(): Unit {
        let error = assertXmlError({
            => parseText("<!DOCTYPE a [<!ENTITY e \"<b>\">]><a x=\"&e;\"/>")
        }, "x")
        assertTrue(error.message.contains("e"), "消息应带实体名：${error.message}")
    }

    /** 参数实体的替换文本是 DTD 片段，不受「内容必须良构」约束。 */
    @TestCase
    public func parameterEntityNotConstrained(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY % p \"<!ENTITY e 'v'>\">%p;]><a>&e;</a>")
        @Assert(doc.root.getOrThrow().text() == "v")
    }

    /** 跨实体边界配对不允许：`o` 开的元素不能由 `i` 关。 */
    @TestCase
    public func crossEntityPairingRejected(): Unit {
        let error = assertXmlError({
            => parseText("<!DOCTYPE a [<!ENTITY i \"</b>\"><!ENTITY o \"<b>\">]><a>&o;&i;</a>")
        }, "o")
        assertTrue(error.message.contains("不良构"), "消息应说明替换文本不良构：${error.message}")
    }

    /** 半截字符引用（`&#9`）也算替换文本不良构，不能借后续文本拼成合法引用。 */
    @TestCase
    public func truncatedCharReferenceInEntity(): Unit {
        assertXmlError({
            => parseText("<!DOCTYPE doc [<!ENTITY e \"&#38;#9\">]><doc>&e;7;</doc>")
        }, "e")
        assertXmlError({
            => parseText("<!DOCTYPE doc [<!ENTITY e \"&#38;\">]><doc>&e;#97;</doc>")
        }, "e")
    }

    /** 未闭合的 CDATA / 注释出现在替换文本里同样报错。 */
    @TestCase
    public func unclosedCdataOrCommentInEntity(): Unit {
        assertXmlError({
            => parseText("<!DOCTYPE doc [<!ENTITY e \"&#60;![CDATA[\">]><doc>&e;]]></doc>")
        }, "e")
        assertXmlError({
            => parseText("<!DOCTYPE doc [<!ENTITY e \"&#60;!--\">]><doc>&e;--></doc>")
        }, "e")
    }

    /** 只做良构校验：文本里出现正常的 `<` 引用、`&amp;` 不受影响。 */
    @TestCase
    public func escapedMarkupStaysText(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"&lt;b&gt;\">]><a>&e;</a>")
        @Assert(doc.root.getOrThrow().text() == "<b>")
        @Assert(doc.root.getOrThrow().children.size == 1)
    }
}
