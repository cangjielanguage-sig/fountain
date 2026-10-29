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
public class DoctypeParser_test {
    /** `<!ENTITY>` 单双引号都支持。 */
    @TestCase
    public func entityQuotes(): Unit {
        @Assert(parseText("<!DOCTYPE a [<!ENTITY e \"v\">]><a>&e;</a>").root.getOrThrow().text() == "v")
        @Assert(parseText("<!DOCTYPE a [<!ENTITY e 'v'>]><a>&e;</a>").root.getOrThrow().text() == "v")
    }

    /** 参数实体只能在 DTD 内部以 `%name;` 使用。 */
    @TestCase
    public func parameterEntity(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY % p \"<!ENTITY e 'v'>\">%p;]><a>&e;</a>")
        @Assert(doc.root.getOrThrow().text() == "v")
    }

    /** `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` 跳过，内部 `>` 与引号不提前结束。 */
    @TestCase
    public func otherDeclarationsSkipped(): Unit {
        let doc = parseText(
            "<!DOCTYPE a [<!ELEMENT a (b*)><!ATTLIST a x CDATA \"1>2\"><!NOTATION n SYSTEM \"u\"><!ENTITY e \"v\">]><a>&e;</a>"
        )
        @Assert(doc.root.getOrThrow().text() == "v")
    }

    /** 条件段 IGNORE 分支不生效。 */
    @TestCase
    public func ignoreSection(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"x\"><![IGNORE[<!ENTITY e \"y\">]]>]><a>&e;</a>")
        @Assert(doc.root.getOrThrow().text() == "x")
    }

    /** 条件段 INCLUDE 分支生效。 */
    @TestCase
    public func includeSection(): Unit {
        let doc = parseText("<!DOCTYPE a [<![INCLUDE[<!ENTITY e \"y\">]]>]><a>&e;</a>")
        @Assert(doc.root.getOrThrow().text() == "y")
    }

    /** 同一实体重复声明，第一个生效。 */
    @TestCase
    public func firstDeclarationWins(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"x\"><!ENTITY e \"y\">]><a>&e;</a>")
        @Assert(doc.root.getOrThrow().text() == "x")
    }

    /** SYSTEM / PUBLIC 声明可识别，引用即报错。 */
    @TestCase
    public func externalEntityRecognized(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><a/>")
        @Assert(doc.doctype.getOrThrow().entities.size == 1)
        @Assert(doc.doctype.getOrThrow().entities[0].isExternal())
        assertXmlError({=> parseText("<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><a>&x;</a>")}, "外部实体")
    }

    /** 外部子集不加载。 */
    @TestCase
    public func externalSubsetNotLoaded(): Unit {
        let doc = parseText("<!DOCTYPE a SYSTEM \"http://127.0.0.1:1/x.dtd\"><a/>")
        @Assert(doc.root.isSome())
    }
}

@Test
public class EntityExpansion_test {
    /** 实体值嵌套引用。 */
    @TestCase
    public func nestedEntityValues(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY a \"x\"><!ENTITY b \"&a;y\">]><a>&b;</a>")
        @Assert(doc.root.getOrThrow().text() == "xy")
    }

    /** 实体值里的引用**延迟到使用时**展开：前向引用合法。 */
    @TestCase
    public func forwardReferenceSucceeds(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY b \"&a;y\"><!ENTITY a \"x\">]><a>&b;</a>")
        @Assert(doc.root.getOrThrow().text() == "xy")
    }

    /** 声明时不解析引用，只有**使用时**仍未声明才报错。 */
    @TestCase
    public func undeclaredAtUseRejected(): Unit {
        let error = assertXmlError({
            => parseText(
                "<?xml version=\"1.0\" standalone=\"yes\"?><!DOCTYPE a [<!ENTITY b \"&missing;y\">]><a>&b;</a>"
            )
        }, "missing")
        @Assert(error.line > 0)
    }

    /** 自引用在使用时由深度上限拦住，不会无限递归。 */
    @TestCase
    public func selfReferenceHitsDepthLimit(): Unit {
        let error = assertXmlError({=> parseText("<!DOCTYPE a [<!ENTITY e \"&e;\">]><a>&e;</a>")}, "深度")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.Depth))
    }

    /** 实体内容可以含标记。 */
    @TestCase
    public func entityWithMarkup(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"<b>x</b>\">]><a>&e;</a>")
        let root = doc.root.getOrThrow()
        @Assert(root.child("b").getOrThrow().text() == "x")
    }

    /** 属性值里的实体展开，且换行归一成空格。 */
    @TestCase
    public func attributeEntityNormalized(): Unit {
        let doc = parseText("<!DOCTYPE a [<!ENTITY e \"a&#10;b\">]><a x=\"&e;\"/>")
        @Assert(doc.root.getOrThrow().attr("x") == Some("a b"))
    }

    /** 属性值首尾空格保留（不 trim）。 */
    @TestCase
    public func attributeSpacesPreserved(): Unit {
        let doc = parseText("<a x=\" v \"/>")
        @Assert(doc.root.getOrThrow().attr("x") == Some(" v "))
    }

    /** 注释 / CDATA 不展开。 */
    @TestCase
    public func noExpansionInCommentOrCdata(): Unit {
        let doc = parseText(
            "<!DOCTYPE a [<!ENTITY e \"v\">]><a><!--&e;--><![CDATA[&e;]]></a>"
        )
        let root = doc.root.getOrThrow()
        @Assert(root.text() == "&e;")
    }

    /** standalone="yes" 引用只在外部子集声明的实体报错。 */
    @TestCase
    public func standaloneYesRejected(): Unit {
        assertXmlError({
            => parseText("<?xml version=\"1.0\" standalone=\"yes\"?><!DOCTYPE a SYSTEM \"x.dtd\"><a>&ext;</a>")
        }, "standalone")
    }

    /** standalone 缺省跳过该实体并记告警。 */
    @TestCase
    public func standaloneDefaultSkips(): Unit {
        let parser = XmlPullParser(text: "<?xml version=\"1.0\"?><!DOCTYPE a SYSTEM \"x.dtd\"><a>&ext;</a>", options: XmlParserOptions())
        var done = false
        while (!done) {
            match (parser.nextEvent()) {
                case Some(_) => ()
                case None => done = true
            }
        }
        @Assert(parser.warnings().size == 1)
        @Assert(parser.warnings()[0].contains("ext"))
    }

    /** standalone="no" 时内容位置的未声明实体产出空文本。 */
    @TestCase
    public func standaloneNoSkipsInContent(): Unit {
        let parser = XmlPullParser(text: "<?xml version=\"1.0\" standalone=\"no\"?><a>&ext;</a>", options: XmlParserOptions())
        var done = false
        while (!done) {
            match (parser.nextEvent()) {
                case Some(_) => ()
                case None => done = true
            }
        }
        @Assert(parser.warnings().size == 1)
        @Assert(parser.warnings()[0].contains("ext"))
    }

    /** standalone="no" 时属性值里的未声明实体被去掉。 */
    @TestCase
    public func standaloneNoRemovesAttributeRef(): Unit {
        let parser = XmlPullParser(
            text: "<?xml version=\"1.0\" standalone=\"no\"?><a x=\"1&ext;2\"/>",
            options: XmlParserOptions()
        )
        var done = false
        while (!done) {
            match (parser.nextEvent()) {
                case Some(_) => ()
                case None => done = true
            }
        }
        @Assert(parser.warnings().size == 1)
        @Assert(parser.warnings()[0].contains("ext"))
    }

    /**
     * 既没有外部子集、也没有参数实体引用时，未声明实体按 WFC 报错。
     *
     * 这条与「standalone 缺省就跳过」的区别：没有任何可能的外部声明来源时，
     * `&nbsp;` 这类笔误必须暴露出来，而不是被当成空文本吞掉。
     */
    @TestCase
    public func noDoctypeUndeclaredRejected(): Unit {
        assertXmlError({=> parseText("<?xml version=\"1.0\"?><a>&ext;</a>")}, "未声明")
    }
}
