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

    /** `switch` 子元素同样计入 maxElements，不能绕过上限。 */
    @TestCase
    public func switchChildrenCountTowardMaxElements(): Unit {
        let options = SvgParseOptions(security: SvgSecurityOptions(maxElements: 3))
        let error = expectSvgException({=>
            SvgParser.parse(
                "<svg><switch><rect/><rect/></switch></svg>",
                options: options
            )
        })
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /**
     * 字体族为文件 URL 时渲染器不读取文件，只按缺失字体降级。
     *
     * `parse(Array<Byte>)` 是纯内存路径；显式 `load(Path)` 才会访问文件系统，
     * 这里用不存在的路径反证两条路径的边界。
     */
    @TestCase
    public func renderDoesNotLoadFontFiles(): Unit {
        let font = SvgTrueTypeFont.parse(m4BuildTtf())
        @Assert(font.glyphPath(65, 12.0).isSome())
        let loadError = expectSvgException({=>
            SvgTrueTypeFont.load(Path("/definitely-not-a-font/f_svg-m4.ttf"))
        })
        @Assert(loadError.kind == SvgErrorKind.Syntax)

        let document = SvgParser.parse(
            "<svg width=\"20\" height=\"20\">" +
            "<text x=\"0\" y=\"15\" font-family=\"file:///etc/fonts/not-a-font.ttf\" " +
            "font-size=\"12\">A</text></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(bitmap.width == 20 && bitmap.height == 20)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("未找到字体")) {
                warned = true
            }
        }
        @Assert(warned)
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

    /** URL 型属性中的外部引用按 unsafePolicy 移除，片段引用保留。 */
    @TestCase
    public func urlAttributesFiltered(): Unit {
        let text = "<svg><rect width=\"10\" height=\"10\" " +
            "fill=\"url(https://evil/x.svg#p)\" stroke=\"url(http://evil/s.svg#s)\" " +
            "filter=\"url(https://evil/f.svg#f)\" clip-path=\"url(http://evil/c.svg#c)\" " +
            "mask=\"url(https://evil/m.svg#m)\" marker-start=\"url(http://evil/ms.svg#m)\" " +
            "marker-mid=\"url(http://evil/mm.svg#m)\" marker-end=\"url(http://evil/me.svg#m)\" " +
            "cursor=\"url(https://evil/cu.svg#c)\"/>" +
            "<rect width=\"1\" height=\"1\" fill=\"url(#ok) red\"/></svg>"
        let document = SvgParser.parse(text)
        let rects = document.root.childrenOf("rect")
        let blocked = [
            "fill", "stroke", "filter", "clip-path", "mask",
            "marker-start", "marker-mid", "marker-end", "cursor"
        ]
        for (name in blocked) {
            @Assert(rects[0].attr(name).isNone())
        }
        @Assert(rects[1].attr("fill") == Some("url(#ok) red"))
        @Assert(countWarnings(document, "外部引用") >= 9)
    }

    /** Reject：URL 型属性中的外部引用抛 Security。 */
    @TestCase
    public func urlAttributeRejectPolicy(): Unit {
        let error = expectSvgException({=>
            SvgParser.parse(
                "<svg><rect width=\"1\" height=\"1\" fill=\"url(https://x/y#p)\"/></svg>",
                options: SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Reject))
            )
        })
        @Assert(error.kind == SvgErrorKind.Security)
    }

    /** 严格模式：URL 型属性中的外部引用抛 Security。 */
    @TestCase
    public func urlAttributeStrict(): Unit {
        let error = expectSvgException({=>
            SvgParser.parse(
                "<svg><rect width=\"1\" height=\"1\" filter=\"url(http://x/f.svg#f)\"/></svg>",
                options: SvgParseOptions(strict: true)
            )
        })
        @Assert(error.kind == SvgErrorKind.Security)
    }

    /** Keep：URL 型属性原样保留。 */
    @TestCase
    public func urlAttributeKeep(): Unit {
        let document = SvgParser.parse(
            "<svg><rect width=\"1\" height=\"1\" fill=\"url(https://x/y#p)\"/></svg>",
            options: SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Keep))
        )
        @Assert(
            document.root.child("rect").getOrThrow().attr("fill") == Some("url(https://x/y#p)")
        )
    }

    /** allowExternalReferences 只放行 http/https/协议相对，不放行 javascript:/file:。 */
    @TestCase
    public func allowExternalReferencesKeepsDangerousSchemesOut(): Unit {
        let text = "<svg><use href=\"javascript:alert(1)\"/>" +
            "<image href=\"file:///etc/passwd\" width=\"1\" height=\"1\"/>" +
            "<use href=\"https://x/y#a\"/></svg>"
        let document = SvgParser.parse(
            text,
            options: SvgParseOptions(security: SvgSecurityOptions(allowExternalReferences: true))
        )
        let uses = document.root.childrenOf("use")
        @Assert(uses[0].attr("href").isNone())
        @Assert(uses[1].attr("href") == Some("https://x/y#a"))
        @Assert(document.root.child("image").getOrThrow().attr("href").isNone())
        @Assert(countWarnings(document, "外部引用") == 2)
    }

    /** Keep 策略下 javascript:/file: 仍可显式保留。 */
    @TestCase
    public func dangerousSchemesKeptOnlyByKeepPolicy(): Unit {
        let document = SvgParser.parse(
            "<svg><use href=\"javascript:alert(1)\"/><image href=\"file:///etc/passwd\" width=\"1\" height=\"1\"/></svg>",
            options: SvgParseOptions(
                security: SvgSecurityOptions(
                    unsafePolicy: SvgUnsafePolicy.Keep,
                    allowExternalReferences: true
                )
            )
        )
        @Assert(document.root.child("use").getOrThrow().attr("href") == Some("javascript:alert(1)"))
        @Assert(document.root.child("image").getOrThrow().attr("href") == Some("file:///etc/passwd"))
    }

    /** script 按 local name 过滤，不限于 SVG 命名空间。 */
    @TestCase
    public func scriptRemovedInEveryNamespace(): Unit {
        let text = "<svg><foreignObject>" +
            "<script xmlns=\"http://www.w3.org/1999/xhtml\">alert(1)</script>" +
            "</foreignObject><script>alert(2)</script></svg>"
        let document = SvgParser.parse(text)
        let foreignObject = document.root.child("foreignObject").getOrThrow()
        @Assert(foreignObject.childrenOf("script").size == 0)
        @Assert(document.root.childrenOf("script").size == 0)
        @Assert(countWarnings(document, "script") >= 2)

        let kept = SvgParser.parse(
            text,
            options: SvgParseOptions(security: SvgSecurityOptions(allowScript: true))
        )
        @Assert(kept.root.child("foreignObject").getOrThrow().childrenOf("script").size == 1)
        @Assert(kept.root.childrenOf("script").size == 1)
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

    /** 外部实体：声明可识别，引用即报错，永不加载。 */
    @TestCase
    public func externalEntityReferenceRejected(): Unit {
        let text = "<?xml version=\"1.0\"?>" +
            "<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" +
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>&x;</text></svg>"
        let error = expectSvgException({=> SvgParser.parse(text)})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** 外部 DTD 子集不加载：不联网、不打开文件，文档仍可解析。 */
    @TestCase
    public func externalDtdSubsetNotLoaded(): Unit {
        let text = "<?xml version=\"1.0\"?>" +
            "<!DOCTYPE svg SYSTEM \"https://example.invalid/svg.dtd\">" +
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"1\" height=\"1\"/></svg>"
        let document = SvgParser.parse(text)
        @Assert(document.root.child("rect").isSome())
    }

    /** 外部命名空间的同名 URL 属性不参与 SVG 安全过滤。 */
    @TestCase
    public func foreignNamespaceUrlAttributePreserved(): Unit {
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:x=\"urn:x\">" +
            "<x:rect fill=\"url(http://evil/x.svg#p)\" width=\"1\" height=\"1\"/></svg>"
        let document = SvgParser.parse(text, options: SvgParseOptions(strict: true))
        let rawElement = document.root.childrenOf("rect")[0]
        @Assert(rawElement.attr("fill") == Some("url(http://evil/x.svg#p)"))
    }

    /** style 属性与 `<style>` 内容中的外部 URL 默认移除。 */
    @TestCase
    public func cssExternalUrlsRemoved(): Unit {
        let text = "<svg><rect width=\"1\" height=\"1\" " +
            "style=\"fill:url(https://evil/x.svg#p);stroke:red\"/>" +
            "<style>@import url(https://evil/x.css);</style></svg>"
        let document = SvgParser.parse(text)
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect.attr("style").isNone())
        @Assert(document.root.child("style").isNone())
        @Assert(countWarnings(document, "外部引用") >= 2)
    }

    /** `xml:base` 默认移除，避免把 `#id` 重定位到外部文档。 */
    @TestCase
    public func xmlBaseRemoved(): Unit {
        let text = "<svg><use href=\"#a\" xml:base=\"https://evil/\"/></svg>"
        let document = SvgParser.parse(text)
        let use = document.root.child("use").getOrThrow()
        @Assert(use.attr("base").isNone())
        @Assert(use.attr("href") == Some("#a"))
        @Assert(countWarnings(document, "xml:base") == 1)
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
