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

/** 构造 `e1 → e2 → … → eN → "x"` 的实体链文档。 */
internal func entityChain(levels: Int64, limits: EntityLimits): String {
    let gen = StringBuilder()
    gen.append("<!DOCTYPE a [<!ENTITY e1 \"x\">")
    for (i in 2..levels + 1) {
        gen.append("<!ENTITY e${i} \"&e${i - 1};\">")
    }
    gen.append("]><a>&e${levels};</a>")
    gen.toString()
}

@Test
public class EntityLimits_test {
    /** 深度正好 16 通过。 */
    @TestCase
    public func depthAtLimitPasses(): Unit {
        let doc = parseText(entityChain(16, EntityLimits()))
        @Assert(doc.root.getOrThrow().text() == "x")
    }

    /** 深度 17 报错，分类为 Depth。 */
    @TestCase
    public func depthOverLimitRejected(): Unit {
        let error = assertXmlError({=> parseText(entityChain(17, EntityLimits()))}, "深度")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.Depth))
    }

    /** 声明数 1025 报错。 */
    @TestCase
    public func declarationsLimit(): Unit {
        let gen = StringBuilder()
        gen.append("<!DOCTYPE a [")
        for (i in 0..1025) {
            gen.append("<!ENTITY e${i} \"v\">")
        }
        gen.append("]><a/>")
        let error = assertXmlError({=> parseText(gen.toString())}, "声明数")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.Declarations))
    }

    /** 硬限制直接抛 HardLimit。 */
    @TestCase
    public func hardLimit(): Unit {
        let body = repeatText("x", 500)
        let doc = "<!DOCTYPE a [<!ENTITY e \"${body}\">]><a>&e;</a>"
        let options = XmlParserOptions(
            entityLimits: EntityLimits(maxExpandedHardLimit: 100)
        )
        let error = assertXmlError({=> parseText(doc, options: options)}, "硬限制")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.HardLimit))
    }

    /** 原文不计入展开总量。 */
    @TestCase
    public func originalTextNotCounted(): Unit {
        let body = repeatText("x", 1024 * 1024)
        let doc = parseText("<a>${body}</a>")
        @Assert(doc.root.getOrThrow().text().size == 1024 * 1024)
    }

    /** 边展开边计数：1 MB 总量上限下不会先拼出 10¹⁰ 字符。 */
    @TestCase
    public func incrementalCounting(): Unit {
        let gen = StringBuilder()
        gen.append("<!DOCTYPE a [<!ENTITY e0 \"lol\">")
        for (i in 1..10) {
            gen.append("<!ENTITY e${i} \"")
            for (_ in 0..10) {
                gen.append("&e${i - 1};")
            }
            gen.append("\">")
        }
        gen.append("]><a>&e9;</a>")
        let options = XmlParserOptions(
            entityLimits: EntityLimits(
                maxExpandedPerEntity: 4 * 1024 * 1024,
                maxExpandedTotal: 1024 * 1024,
                overflowPolicy: EntityOverflowPolicy.Strict
            )
        )
        let error = assertXmlError({=> parseText(gen.toString(), options: options)}, "总量")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.Total))
    }

    /** Strict 拿到 Total 后改用 Spill 重试成功。 */
    @TestCase
    public func degradeRetrySucceeds(): Unit {
        let gen = StringBuilder()
        gen.append("<!DOCTYPE a [<!ENTITY e0 \"lol\">")
        for (i in 1..6) {
            gen.append("<!ENTITY e${i} \"")
            for (_ in 0..10) {
                gen.append("&e${i - 1};")
            }
            gen.append("\">")
        }
        gen.append("]><a>&e5;</a>")
        let strict = XmlParserOptions(
            entityLimits: EntityLimits(maxExpandedTotal: 1024, overflowPolicy: EntityOverflowPolicy.Strict)
        )
        let error = assertAnyXmlError({=> parseText(gen.toString(), options: strict)})
        @Assert(error.entityLimitKind == Some(EntityLimitKind.Total))

        let spill = XmlParserOptions(
            entityLimits: EntityLimits(maxExpandedTotal: 1024, overflowPolicy: EntityOverflowPolicy.Spill)
        )
        let doc = parseText(gen.toString(), options: spill)
        @Assert(doc.root.getOrThrow().text().size == 3 * 100000)
    }

    /** 硬限制分类重试仍同分类。 */
    @TestCase
    public func depthRetrySameKind(): Unit {
        let first = assertAnyXmlError({=> parseText(entityChain(17, EntityLimits()))})
        let second = assertAnyXmlError({=> parseText(entityChain(17, EntityLimits()))})
        @Assert(first.entityLimitKind == second.entityLimitKind)
        @Assert(first.entityLimitKind == Some(EntityLimitKind.Depth))
    }

    /** 非实体错误没有分类。 */
    @TestCase
    public func nonEntityErrorHasNoKind(): Unit {
        let error = assertXmlError({=> parseText("<a></b>")}, "不匹配")
        @Assert(error.entityLimitKind.isNone())
    }

    /** 属性值单实体超限：即便 Spill 也抛 AttributeValue，消息带属性名与阈值。 */
    @TestCase
    public func attributeValueLimit(): Unit {
        let body = repeatText("x", 100 * 1024)
        let doc = "<!DOCTYPE a [<!ENTITY big \"${body}\">]><a r=\"&big;\"/>"
        let error = assertXmlError({=> parseText(doc)}, "属性")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.AttributeValue))
        @Assert(error.message.contains("属性 'r'"))
        @Assert(error.message.contains("64 KB"))
        @Assert(error.line == 1)
    }
}
