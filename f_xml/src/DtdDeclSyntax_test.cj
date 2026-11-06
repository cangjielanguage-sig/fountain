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
 * DTD 四类声明的**语法**矩阵（良构性，不是有效性）。
 *
 * 只验产生式：`<!ELEMENT>` 的内容模型、`<!ATTLIST>` 的属性类型与默认值、
 * `<!NOTATION>` 的外部标识符、`<!ENTITY>` 的 EntityDef。内容模型与文档是否匹配、
 * 属性类型语义、默认值注入都**不验**。
 */
internal func doctypeWith(body: String): String {
    "<!DOCTYPE a [" + body + "]><a/>"
}

internal func assertDoctypeError(body: String, fragment: String): XmlException {
    assertXmlError({=> parseText(doctypeWith(body))}, fragment)
}

@Test
public class DtdElementDecl_test {
    /** 合法内容模型：EMPTY / ANY / Mixed / children 的代表。 */
    @TestCase
    public func validContentModels(): Unit {
        let bodies = [
            "<!ELEMENT a EMPTY>",
            "<!ELEMENT a ANY>",
            "<!ELEMENT a (#PCDATA)>",
            "<!ELEMENT a (#PCDATA)*>",
            "<!ELEMENT a (#PCDATA|b|c)*>",
            "<!ELEMENT a (#PCDATA | b )*>",
            "<!ELEMENT a (b)>",
            "<!ELEMENT a (b,c)>",
            "<!ELEMENT a (b|c)>",
            "<!ELEMENT a (b?)>",
            "<!ELEMENT a (b*)>",
            "<!ELEMENT a (b+)>",
            "<!ELEMENT a ((b,c)|d)*>",
            "<!ELEMENT a (b,(c|d)+)>",
            "<!ELEMENT a ( b , c )>"
        ]
        for (body in bodies) {
            parseText(doctypeWith(body))
        }
    }

    /** `?` / `*` / `+` 必须紧跟在内容粒子后，`(b) ?` 非法。 */
    @TestCase
    public func quantifierMustBeAdjacent(): Unit {
        let error = assertDoctypeError("<!ELEMENT a ((b) ?)>", "ELEMENT")
        @Assert(error.line > 0)
    }

    /** 空分支、缺右括号、缺分隔符都非法。 */
    @TestCase
    public func invalidContentModels(): Unit {
        assertDoctypeError("<!ELEMENT a (b|)>", "ELEMENT")
        assertDoctypeError("<!ELEMENT a (|b)>", "ELEMENT")
        assertDoctypeError("<!ELEMENT a (b,c>", "ELEMENT")
        assertDoctypeError("<!ELEMENT a ()>", "ELEMENT")
        assertDoctypeError("<!ELEMENT a (b)&(c)>", "ELEMENT")
        // 混合内容里一旦出现名字，就必须以 `)*` 收尾。
        assertDoctypeError("<!ELEMENT a (#PCDATA|b)>", "ELEMENT")
        // 内容模型不能是裸名字，也不能是 SGML 的 CDATA / RCDATA。
        assertDoctypeError("<!ELEMENT a b>", "ELEMENT")
        assertDoctypeError("<!ELEMENT a CDATA>", "ELEMENT")
    }

    /** 错误消息带行列号。 */
    @TestCase
    public func errorCarriesPosition(): Unit {
        let error = assertDoctypeError("\n\n<!ELEMENT a ((b) ?)>", "ELEMENT")
        @Assert(error.line == 3)
    }
}

@Test
public class DtdAttlistDecl_test {
    /** 八种属性类型 + 四种默认值声明。 */
    @TestCase
    public func validAttributeTypes(): Unit {
        let bodies = [
            "<!ATTLIST a x CDATA #IMPLIED>",
            "<!ATTLIST a x ID #REQUIRED>",
            "<!ATTLIST a x IDREF #IMPLIED>",
            "<!ATTLIST a x IDREFS #IMPLIED>",
            "<!ATTLIST a x ENTITY #IMPLIED>",
            "<!ATTLIST a x ENTITIES #IMPLIED>",
            "<!ATTLIST a x NMTOKEN #IMPLIED>",
            "<!ATTLIST a x NMTOKENS #IMPLIED>",
            "<!ATTLIST a x (p|q) #FIXED \"p\">",
            "<!ATTLIST a x NOTATION (n1|n2) #IMPLIED>",
            "<!ATTLIST a x CDATA \"v\">",
            "<!ATTLIST a x CDATA #FIXED \"v\" y ID #IMPLIED>",
            "<!ATTLIST a x CDATA #IMPLIED><!ATTLIST a y CDATA #IMPLIED>",
            "<!ATTLIST a x CDATA \"1>2\">"
        ]
        for (body in bodies) {
            parseText(doctypeWith(body))
        }
    }

    /** 非法属性类型 / 缺类型 / `#FIXED` 缺值 / 空枚举都报错。 */
    @TestCase
    public func invalidAttlists(): Unit {
        let error = assertDoctypeError("<!ATTLIST a x NUTOKEN #IMPLIED>", "ATTLIST")
        @Assert(error.message.contains("NUTOKEN"))
        assertDoctypeError("<!ATTLIST a x #FIXED \"v\">", "ATTLIST")
        assertDoctypeError("<!ATTLIST a x CDATA #FIXED>", "ATTLIST")
        assertDoctypeError("<!ATTLIST a x NOTATION () #IMPLIED>", "ATTLIST")
        assertDoctypeError("<!ATTLIST a x () #IMPLIED>", "ATTLIST")
        assertDoctypeError("<!ATTLIST a x (p|) #IMPLIED>", "ATTLIST")
        assertDoctypeError("<!ATTLIST a x CDATA #REQUIRED y>", "ATTLIST")
    }

    /** 默认值里引用外部实体违反 WFC: No External Entity References。 */
    @TestCase
    public func defaultValueMayNotReferenceExternalEntity(): Unit {
        assertDoctypeError(
            "<!ENTITY ent SYSTEM \"ent\"><!ATTLIST a x CDATA \"see &ent;\">",
            "ATTLIST"
        )
    }
}

@Test
public class DtdNotationDecl_test {
    /** `SYSTEM` / `PUBLIC` / `PUBLIC` + `SYSTEM` 三种写法。 */
    @TestCase
    public func validNotations(): Unit {
        let bodies = [
            "<!NOTATION n SYSTEM \"u\">",
            "<!NOTATION n PUBLIC \"pub-id\">",
            "<!NOTATION n PUBLIC \"pub-id\" \"sys-id\">"
        ]
        for (body in bodies) {
            parseText(doctypeWith(body))
        }
    }

    /** 缺标识符、多余字面量、未闭合都报错，消息含 NOTATION。 */
    @TestCase
    public func invalidNotations(): Unit {
        assertDoctypeError("<!NOTATION n>", "NOTATION")
        assertDoctypeError("<!NOTATION n PUBLIC \"a\" \"b\" \"c\">", "NOTATION")
        assertDoctypeError("<!NOTATION n SYSTEM \"u\"", "NOTATION")
        assertDoctypeError("<!NOTATION n \"u\">", "NOTATION")
    }
}

@Test
public class DtdEntityDeclSyntax_test {
    /** 普通 / 参数 / 外部 / `NDATA` 四种实体声明。 */
    @TestCase
    public func validEntityDecls(): Unit {
        let bodies = [
            "<!ENTITY e \"v\">",
            "<!ENTITY % p \"v\">",
            "<!ENTITY e SYSTEM \"u\">",
            "<!ENTITY e PUBLIC \"pub-id\" \"sys-id\">",
            "<!ENTITY e SYSTEM \"u\" NDATA gif>",
            "<!ENTITY % p SYSTEM \"u\">"
        ]
        for (body in bodies) {
            parseText(doctypeWith(body))
        }
    }

    /** `NDATA` 只能出现在外部普通实体上，且必须有值。 */
    @TestCase
    public func invalidEntityDecls(): Unit {
        assertDoctypeError("<!ENTITY e SYSTEM \"u\" NDATA>", "ENTITY")
        assertDoctypeError("<!ENTITY % p SYSTEM \"u\" NDATA gif>", "ENTITY")
        assertDoctypeError("<!ENTITY e \"v\" NDATA gif>", "ENTITY")
        assertDoctypeError("<!ENTITY e>", "ENTITY")
        assertDoctypeError("<!ENTITY e PUBLIC \"pub-id\">", "ENTITY")
    }
}

@Test
public class DtdIgnoreSection_test {
    /** IGNORE 段在内部子集里不合法：整段声明必须报错，而不是跳过。 */
    @TestCase
    public func ignoreSectionRejected(): Unit {
        let error = assertXmlError({
            => parseText(
                "<!DOCTYPE a [<!ENTITY e \"x\"><![IGNORE[<!ELEMENT a ((b) ?)><!ATTLIST a x NUTOKEN #IMPLIED>]]>]><a>&e;</a>"
            )
        }, "条件段只能出现在外部子集")
        @Assert(error.line > 0)
    }
}

@Test
public class DtdMiscSyntax_test {
    /** 空的 `<!ATTLIST a>` 合法（AttDef 可以为零条）。 */
    @TestCase
    public func emptyAttlistAllowed(): Unit {
        parseText(doctypeWith("<!ATTLIST a>"))
        parseText(doctypeWith("<!ATTLIST a >"))
    }

    /** `PEReference ::= '%' Name ';'`：名字与 `;` 之间不能有空白。 */
    @TestCase
    public func parameterEntityReferenceNeedsTightSemicolon(): Unit {
        assertDoctypeError("<!ENTITY % p \"<!ATTLIST a>\">%p ;", "参数实体引用")
    }

    /** DTD 里的 PI target 之后必须是空白或 `?>`。 */
    @TestCase
    public func piTargetNeedsSeparator(): Unit {
        assertDoctypeError("<?bad-pi+?>", "处理指令")
        parseText(doctypeWith("<?good-pi d?>"))
    }

    /** `ExternalID ::= 'PUBLIC' S PubidLiteral S SystemLiteral`：PUBLIC 后必须两个字面量。 */
    @TestCase
    public func doctypePublicNeedsSystemLiteral(): Unit {
        assertXmlError({=> parseText("<!DOCTYPE a PUBLIC \"-//X//DTD//EN\"\"x.dtd\"><a/>")}, "空白")
        parseText("<!DOCTYPE a PUBLIC \"-//X//DTD//EN\" \"x.dtd\"><a/>")
    }
}
