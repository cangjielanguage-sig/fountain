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
 * `<!ATTLIST>` 的属性类型映射与属性值规范化（XML 1.0 §3.3.3）。
 *
 * 映射**只**服务规范化：不做 `ID` 唯一性、不做 `IDREF` 指向、不检查枚举取值、
 * 不注入默认值 / `#FIXED` 值。
 */
@Test
public class AttrNormalize_test {
    private func attrOf(document: XmlDocument, name: String): String {
        match (document.root.getOrThrow().attr(name)) {
            case Some(v) => v
            case None => "<missing>"
        }
    }

    /** 未在 `<!ATTLIST>` 里声明的属性按 `CDATA`：首尾空格保留。 */
    @TestCase
    public func undeclaredAttributeIsCdata(): Unit {
        @Assert(attrOf(parseText("<a x=\" v \"/>"), "x") == " v ")
    }

    /** 声明 `CDATA`：只做字符级归一，不折叠。 */
    @TestCase
    public func declaredCdataKeepsSpaces(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ATTLIST a x CDATA #IMPLIED>]><a x=\"  p   q  \"/>")
        @Assert(attrOf(doc, "x") == "  p   q  ")
    }

    /** 声明 `NMTOKENS`：去首尾 + 内部连续空格折叠。 */
    @TestCase
    public func nmtokensCollapsesSpaces(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ATTLIST a x NMTOKENS #IMPLIED>]><a x=\"  p   q  \"/>")
        @Assert(attrOf(doc, "x") == "p q")
    }

    /** 顺序是「展开 → 归一 → 折叠」：实体值里的换行先变空格，再被折叠。 */
    @TestCase
    public func expandThenCollapse(): Unit {
        let doc = parseText(
            "<!DOCTYPE a [<!ATTLIST a x NMTOKENS #IMPLIED><!ENTITY e \"&#10;p&#10;\">]><a x=\"q&e;\"/>"
        )
        @Assert(attrOf(doc, "x") == "q p")
    }

    /** 映射键按元素的**字面名**匹配，不因命名空间展开而错过。 */
    @TestCase
    public func mapKeyedByLiteralName(): Unit {
        let doc = parseText("<!DOCTYPE p:a [<!ATTLIST p:a x NMTOKENS #IMPLIED>]><p:a xmlns:p=\"u\" x=\"  p   q  \"/>")
        @Assert(attrOf(doc, "x") == "p q")
    }

    /** 同一元素的多条 `AttDef`：同名重复声明取第一个。 */
    @TestCase
    public func firstAttDefWins(): Unit {
        let doc = parseText(
            "<!DOCTYPE a [<!ATTLIST a x NMTOKENS #IMPLIED><!ATTLIST a x CDATA #IMPLIED>]><a x=\"  p   q  \"/>"
        )
        @Assert(attrOf(doc, "x") == "p q")
    }

    /** 未声明的元素走 `CDATA` 默认。 */
    @TestCase
    public func undeclaredElementIsCdata(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ATTLIST b x NMTOKENS #IMPLIED>]><a x=\"  p   q  \"/>")
        @Assert(attrOf(doc, "x") == "  p   q  ")
    }

    /**
     * 反向断言：不做有效性校验。
     *
     * `ID` 重复、`IDREF` 悬空、枚举取值不在候选里、`#FIXED` 值不一致——全部解析成功，
     * 也不注入任何默认值。
     */
    @TestCase
    public func validityNotChecked(): Unit {
        let doc = parseText(
            "<!DOCTYPE r [<!ELEMENT r (i,i)><!ELEMENT i EMPTY>" +
            "<!ATTLIST i id ID #REQUIRED ref IDREF #IMPLIED kind (a|b) #IMPLIED fixed CDATA #FIXED \"v\">" +
            "]><r><i id=\"x\" ref=\"nowhere\" kind=\"zzz\"/><i id=\"x\"/></r>"
        )
        let items = doc.root.getOrThrow().childrenOf("i")
        @Assert(items.size == 2)
        @Assert(items[0].attr("id") == Some("x"))
        assertTrue(items[0].attr("fixed").isNone(), "不应注入 #FIXED 默认值")
    }

    /**
     * `xmlns:b NMTOKEN` 的值经规范化后与 `xmlns:a` 相同，导致展开名重复——`not-wf`。
     *
     * 对应 xmlconf 的 `rmt-ns10-012`：属性值规范化反过来影响了命名空间绑定。
     */
    @TestCase
    public func normalizedNamespaceBindingCollides(): Unit {
        let error = assertXmlError({
            => parseText(
                "<?xml version=\"1.0\"?><!DOCTYPE foo [" +
                "<!ELEMENT foo ANY>" +
                "<!ATTLIST foo xmlns:a CDATA #IMPLIED xmlns:b NMTOKEN #IMPLIED xmlns:c CDATA #IMPLIED>" +
                "<!ELEMENT bar ANY>" +
                "<!ATTLIST bar a:attr CDATA #IMPLIED b:attr CDATA #IMPLIED c:attr CDATA #IMPLIED>" +
                "]><foo xmlns:a=\"urn:xyzzy\" xmlns:b=\" urn:xyzzy \">" +
                "<bar a:attr=\"1\" b:attr=\"2\"/></foo>"
            )
        }, "重复的属性")
        @Assert(error.line > 0)
    }
}
