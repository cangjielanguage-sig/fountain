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
import std.fs.Path
import fountain::f_xml.*

private func countWarnings(document: SvgDocument, needle: String): Int64 {
    var count = 0
    for (warning in document.warnings) {
        if (warning.contains(needle)) {
            count++
        }
    }
    count
}

@Test
public class SvgSecurity_test {
    /** unsafe.svg 驱动的默认过滤表。 */
    @TestCase
    public func defaultFiltering(): Unit {
        let document = SvgParser.parse(Path("testdata/unsafe.svg"))
        // 脚本整体移除。
        @Assert(document.root.childrenOf("script").size == 0)
        @Assert(countWarnings(document, "script") >= 1)
        @Assert(countWarnings(document, "/svg[1]") >= 1)

        // 事件属性移除，其余属性保留。
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect.attr("onload").isNone())
        @Assert(rect.attr("onclick").isNone())
        @Assert(rect.attr("width") == Some("10"))
        @Assert(rect.attr("fill") == Some("red"))

        // 外部引用全部移除。
        let images = document.root.childrenOf("image")
        @Assert(images[0].attr("href").isNone())
        @Assert(images[1].attr("href").isNone())
        @Assert(images[2].attr("href").isNone())
        // data 图片保留。
        @Assert(images[3].attr(SvgNamespaces.XLINK, "href") == Some("data:image/png;base64,AAAA"))

        let uses = document.root.childrenOf("use")
        @Assert(uses[0].attr(SvgNamespaces.XLINK, "href") == Some("#ok"))
        @Assert(uses[1].attr("href").isNone())
        @Assert(uses[2].attr("href").isNone())
        @Assert(uses[3].attr(SvgNamespaces.XLINK, "href").isNone())

        @Assert(countWarnings(document, "外部引用") >= 6)
        @Assert(countWarnings(document, "事件属性") >= 2)
        @Assert(countWarnings(document, "/svg[1]/rect[1]") >= 1)
        @Assert(countWarnings(document, "/svg[1]/image[1]") >= 1)
    }

    /** Reject 策略：脚本与外部引用都抛 Security。 */
    @TestCase
    public func rejectPolicy(): Unit {
        let scriptError = expectSvgException({=>
            SvgParser.parse(
                "<svg><script>alert(1)</script></svg>",
                options: SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Reject))
            )
        })
        @Assert(scriptError.kind == SvgErrorKind.Security)

        let hrefError = expectSvgException({=>
            SvgParser.parse(
                "<svg><use href=\"https://x/y#a\"/></svg>",
                options: SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Reject))
            )
        })
        @Assert(hrefError.kind == SvgErrorKind.Security)
    }

    /** Keep 策略：脚本与外部引用原样保留。 */
    @TestCase
    public func keepPolicy(): Unit {
        let document = SvgParser.parse(
            "<svg><script>alert(1)</script><rect onload=\"x()\" width=\"1\" height=\"1\"/>" +
            "<use href=\"https://x/y#a\"/></svg>",
            options: SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Keep))
        )
        @Assert(document.root.childrenOf("script").size == 1)
        @Assert(document.root.child("rect").getOrThrow().attr("onload") == Some("x()"))
        @Assert(document.root.child("use").getOrThrow().attr("href") == Some("https://x/y#a"))
        @Assert(document.warnings.size == 0)
    }

    /** 只放行事件属性：脚本仍被移除。 */
    @TestCase
    public func allowEventAttributesOnly(): Unit {
        let document = SvgParser.parse(
            "<svg><script>alert(1)</script><rect onload=\"x()\" width=\"1\" height=\"1\"/></svg>",
            options: SvgParseOptions(security: SvgSecurityOptions(allowEventAttributes: true))
        )
        @Assert(document.root.childrenOf("script").size == 0)
        @Assert(document.root.child("rect").getOrThrow().attr("onload") == Some("x()"))
    }

    /** 放行脚本。 */
    @TestCase
    public func allowScript(): Unit {
        let document = SvgParser.parse(
            "<svg><script>alert(1)</script></svg>",
            options: SvgParseOptions(security: SvgSecurityOptions(allowScript: true))
        )
        @Assert(document.root.childrenOf("script").size == 1)
    }

    /** 放行外部引用：https 与协议相对引用保留且不记移除告警。 */
    @TestCase
    public func allowExternalReferences(): Unit {
        let document = SvgParser.parse(
            "<svg><use href=\"https://x/y#a\"/><use href=\"//evil/x.svg#a\"/></svg>",
            options: SvgParseOptions(security: SvgSecurityOptions(allowExternalReferences: true))
        )
        let uses = document.root.childrenOf("use")
        @Assert(uses[0].attr("href") == Some("https://x/y#a"))
        @Assert(uses[1].attr("href") == Some("//evil/x.svg#a"))
        @Assert(countWarnings(document, "外部引用") == 0)
    }

    /** 禁止 data 图片。 */
    @TestCase
    public func denyDataImages(): Unit {
        let document = SvgParser.parse(
            "<svg><image href=\"data:image/png;base64,AAAA\" width=\"1\" height=\"1\"/></svg>",
            options: SvgParseOptions(security: SvgSecurityOptions(allowDataImages: false))
        )
        let image = document.root.child("image").getOrThrow()
        @Assert(image.attr("href").isNone())
        @Assert(countWarnings(document, "外部引用") >= 1)
    }

    /** 片段引用始终保留。 */
    @TestCase
    public func fragmentAlwaysKept(): Unit {
        let document = SvgParser.parse("<svg><use href=\"#ok\"/><image href=\"#img\" width=\"1\" height=\"1\"/></svg>")
        @Assert(document.root.child("use").getOrThrow().attr("href") == Some("#ok"))
        @Assert(document.root.child("image").getOrThrow().attr("href") == Some("#img"))
        @Assert(document.warnings.size == 0)
    }

    /** 元素数上限：可配置阈值。 */
    @TestCase
    public func maxElements(): Unit {
        let options = SvgParseOptions(security: SvgSecurityOptions(maxElements: 3))
        let ok = SvgParser.parse("<svg><rect/><rect/></svg>", options: options)
        @Assert(ok.root.childrenOf("rect").size == 2)
        let error = expectSvgException({=>
            SvgParser.parse("<svg><rect/><rect/><rect/></svg>", options: options)
        })
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 默认上限 1,000,000：1,000,001 个元素触发 Limit。 */
    @TestCase
    public func elementCountAtDefaultLimit(): Unit {
        let document = XmlDocument()
        let root = XmlElement(QName("svg", uri: Some(SvgNamespaces.SVG)))
        let rect = XmlElement(QName("rect", uri: Some(SvgNamespaces.SVG)))
        for (_ in 0..1_000_000) {
            root.children.add(XmlNode.ElementNode(rect))
        }
        document.root = Some(root)
        let error = expectSvgException({=> SvgParser.parse(document)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 默认上限值。 */
    @TestCase
    public func defaultLimits(): Unit {
        let security = SvgSecurityOptions()
        @Assert(security.maxElements == 1_000_000)
        @Assert(security.maxDepth == 512)
        @Assert(!security.allowScript)
        @Assert(!security.allowEventAttributes)
        @Assert(!security.allowExternalReferences)
        @Assert(security.allowDataImages)
    }

    /** 深度上限 512：root + 512 层 g 触发 Limit。 */
    @TestCase
    public func maxDepth(): Unit {
        let text = nestedGroups(512)
        let error = expectSvgException({=> SvgParser.parse(text)})
        @Assert(error.kind == SvgErrorKind.Limit)
        // 宽松模式同样硬失败。
        let looseError = expectSvgException({=> SvgParser.parse(text, options: SvgParseOptions(strict: false))})
        @Assert(looseError.kind == SvgErrorKind.Limit)
        // 512 层刚好允许（root + 511 层 g）。
        let allowed = SvgParser.parse(nestedGroups(511))
        @Assert(allowed.root.children.size == 1)
    }

    /** 实体上限透传 f_xml：超限按 Syntax 包装。 */
    @TestCase
    public func entityLimitsPassthrough(): Unit {
        let limits = EntityLimits(maxExpandedPerEntity: 8, overflowPolicy: EntityOverflowPolicy.Strict)
        let text = "<!DOCTYPE svg [<!ENTITY a \"0123456789012345678901234567890123456789\">]>" +
            "<svg><text>&a;</text></svg>"
        let error = expectSvgException({=>
            SvgParser.parse(text, options: SvgParseOptions(xml: XmlParserOptions(entityLimits: limits)))
        })
        @Assert(error.kind == SvgErrorKind.Syntax)
    }
}

private func nestedGroups(levels: Int64): String {
    let out = StringBuilder()
    out.append("<svg>")
    for (_ in 0..levels) {
        out.append("<g>")
    }
    for (_ in 0..levels) {
        out.append("</g>")
    }
    out.append("</svg>")
    out.toString()
}
