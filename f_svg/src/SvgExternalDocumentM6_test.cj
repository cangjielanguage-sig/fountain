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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.*

class M6DocumentProvider <: SvgExternalDocumentProvider {
    let documents: HashMap<String, Array<Byte>>
    var calls: Int64 = 0
    let requested = ArrayList<String>()

    init(documents: HashMap<String, Array<Byte>>) {
        this.documents = documents
    }

    public func resolveHref(href: String): ?Array<Byte> {
        this.calls++
        this.requested.add(href)
        this.documents.get(href)
    }
}

@Test
public class SvgExternalDocumentM6_test {
    private let svgOpen = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"

    private func allowedOptions(): SvgParseOptions {
        SvgParseOptions(security: SvgSecurityOptions(allowExternalReferences: true))
    }

    private func redDocument(id: String, x: Int64): String {
        svgOpen + "<rect id=\"" + id + "\" x=\"" + x.toString() +
        "\" y=\"0\" width=\"10\" height=\"20\" fill=\"red\"/></svg>"
    }

    /** 同一 href 只调用 provider 一次。 */
    @TestCase
    public func providerCalledOnce(): Unit {
        let documents = HashMap<String, Array<Byte>>()
        documents["https://example.com/ext.svg#r"] = redDocument("r", 0).unsafeBytes()
        let provider = M6DocumentProvider(documents)
        let primary = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/ext.svg#r\"/><use href=\"https://example.com/ext.svg#r\"/></svg>",
            options: allowedOptions()
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        ).render(primary)
        @Assert(provider.calls == 1)
        @Assert(bitmap.pixel(5, 10).toString() == "#ff0000")
    }

    /** 片段定位与无片段使用根。 */
    @TestCase
    public func fragmentAndRoot(): Unit {
        let documents = HashMap<String, Array<Byte>>()
        documents["https://example.com/ext.svg#r"] = (
            svgOpen + "<rect id=\"r\" x=\"0\" y=\"0\" width=\"10\" height=\"20\" fill=\"red\"/>" +
            "<rect x=\"10\" y=\"0\" width=\"10\" height=\"20\" fill=\"blue\"/></svg>"
        ).unsafeBytes()
        documents["https://example.com/ext.svg"] = (
            svgOpen + "<rect id=\"r\" x=\"0\" y=\"0\" width=\"10\" height=\"20\" fill=\"red\"/>" +
            "<rect x=\"10\" y=\"0\" width=\"10\" height=\"20\" fill=\"blue\"/></svg>"
        ).unsafeBytes()
        let provider = M6DocumentProvider(documents)
        let fragment = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/ext.svg#r\"/></svg>",
            options: allowedOptions()
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        ).render(fragment)
        @Assert(bitmap.pixel(5, 10).toString() == "#ff0000")
        @Assert(bitmap.pixel(15, 10).alpha == 0.0)

        let whole = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/ext.svg\"/></svg>",
            options: allowedOptions()
        )
        let full = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        ).render(whole)
        @Assert(full.pixel(5, 10).toString() == "#ff0000")
        @Assert(full.pixel(15, 10).toString() == "#0000ff")
    }

    /** 缺少 provider / provider 返回 None 都 warning 并跳过。 */
    @TestCase
    public func missingProviderWarns(): Unit {
        let primary = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/ext.svg#r\"/></svg>",
            options: allowedOptions()
        )
        let rendered = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20))
        let bitmap = rendered.render(primary)
        @Assert(bitmap.pixel(5, 10).alpha == 0.0)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("provider")) {
                warned = true
            }
        }
        @Assert(warned)

        let empty = M6DocumentProvider(HashMap<String, Array<Byte>>())
        let second = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: empty)
        )
        second.render(primary)
        var missing = false
        for (warning in second.warnings) {
            if (warning.contains("不可用")) {
                missing = true
            }
        }
        @Assert(missing)
    }

    /** 未放行外部引用时解析期已移除 href。 */
    @TestCase
    public func externalNotAllowed(): Unit {
        let documents = HashMap<String, Array<Byte>>()
        documents["https://example.com/ext.svg#r"] = redDocument("r", 0).unsafeBytes()
        let provider = M6DocumentProvider(documents)
        let primary = SvgParser.parse(svgOpen + "<use href=\"https://example.com/ext.svg#r\"/></svg>")
        let rendered = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        )
        rendered.render(primary)
        @Assert(provider.calls == 0)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("href")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 外部文档嵌套深度上限：0..3 可用，4 拒绝；5 层链在第二层停止。 */
    @TestCase
    public func depthLimit(): Unit {
        @Assert(svgExternalDepthAllows(0))
        @Assert(svgExternalDepthAllows(3))
        @Assert(!svgExternalDepthAllows(4))
        @Assert(!svgExternalDepthAllows(5))

        let documents = HashMap<String, Array<Byte>>()
        for (index in 1..6) {
            let next = index + 1
            let body = if (index == 5) {
                "<rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\"/>"
            } else {
                "<use href=\"https://example.com/ext" + next.toString() + ".svg\"/>"
            }
            documents["https://example.com/ext" + index.toString() + ".svg"] = (svgOpen + body + "</svg>").unsafeBytes()
        }
        let provider = M6DocumentProvider(documents)
        let primary = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/ext1.svg\"/></svg>",
            options: allowedOptions()
        )
        let rendered = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        )
        rendered.render(primary)
        @Assert(provider.calls == 1)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("href")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 超过 16 MiB 触发 Limit。 */
    @TestCase
    public func byteLimit(): Unit {
        let documents = HashMap<String, Array<Byte>>()
        documents["https://example.com/big.svg"] = Array<Byte>(16 * 1024 * 1024 + 1, repeat: b' ')
        let provider = M6DocumentProvider(documents)
        let primary = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/big.svg\"/></svg>",
            options: allowedOptions()
        )
        var limited = false
        try {
            SvgRenderer(
                options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
            ).render(primary)
        } catch (error: SvgException) {
            limited = error.kind == SvgErrorKind.Limit
        }
        @Assert(limited)
    }

    /** 循环引用 warning 后停止。 */
    @TestCase
    public func circularReference(): Unit {
        let documents = HashMap<String, Array<Byte>>()
        documents["https://example.com/loop.svg"] = (
            svgOpen + "<g id=\"a\"><use href=\"#a\"/></g></svg>"
        ).unsafeBytes()
        let provider = M6DocumentProvider(documents)
        let primary = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/loop.svg\"/></svg>",
            options: allowedOptions()
        )
        let rendered = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        )
        rendered.render(primary)
        @Assert(provider.calls == 1)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("循环")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 外部文档自身不再加载外部引用。 */
    @TestCase
    public func externalDocumentCannotChain(): Unit {
        let documents = HashMap<String, Array<Byte>>()
        documents["https://example.com/one.svg"] = (svgOpen + "<use href=\"https://example.com/two.svg\"/></svg>").unsafeBytes()
        documents["https://example.com/two.svg"] = redDocument("r", 0).unsafeBytes()
        let provider = M6DocumentProvider(documents)
        let primary = SvgParser.parse(
            svgOpen + "<use href=\"https://example.com/one.svg\"/></svg>",
            options: allowedOptions()
        )
        let rendered = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, externalDocuments: provider)
        )
        rendered.render(primary)
        @Assert(provider.calls == 1)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("href")) {
                warned = true
            }
        }
        @Assert(warned)
    }
}
