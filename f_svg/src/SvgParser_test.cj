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
import std.fs.{File, OpenMode, Path}
import std.io.InputStream
import fountain::f_xml.*

/** 测试用内存输入流。 */
internal class TestSvgInputStream <: InputStream {
    private let data: Array<Byte>
    private var pos: Int64 = 0

    init(data: Array<Byte>) {
        this.data = data
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.pos >= this.data.size) {
            return 0
        }
        var count = this.data.size - this.pos
        if (count > buffer.size) {
            count = buffer.size
        }
        for (index in 0..count) {
            buffer[index] = this.data[this.pos + index]
        }
        this.pos += count
        count
    }

    public func close(): Unit {}
}

private let SVG_SAMPLE = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\">" +
    "<g><rect x=\"1\" y=\"2\" width=\"10\" height=\"20\"/></g></svg>"

private func parserSnapshot(document: SvgDocument): String {
    document.root.toString() + "|warnings=" + document.warnings.size.toString()
}

@Test
public class SvgParser_test {
    /** 文本入口。 */
    @TestCase
    public func textEntry(): Unit {
        let document = SvgParser.parse(SVG_SAMPLE)
        @Assert(document.root.tag == "svg")
        @Assert(document.root.width == Some(SvgLength(100.0)))
        @Assert(document.root.children.size == 1)
        let group = document.root.child("g").getOrThrow()
        let rect = group.child("rect").getOrThrow()
        @Assert(rect.tag == "rect")
        @Assert(rect.attr("x") == Some("1"))
        @Assert(document.warnings.size == 0)
    }

    /** 五个入口结构等价。 */
    @TestCase
    public func fiveEntriesEquivalent(): Unit {
        let fromText = SvgParser.parse(SVG_SAMPLE)
        let fromBytes = SvgParser.parse(SVG_SAMPLE.toArray())
        let fromStream = SvgParser.parse(TestSvgInputStream(SVG_SAMPLE.toArray()))
        let xml = XmlParser.parse(SVG_SAMPLE)
        let fromXml = SvgParser.parse(xml)

        let expected = parserSnapshot(fromText)
        @Assert(parserSnapshot(fromBytes) == expected)
        @Assert(parserSnapshot(fromStream) == expected)
        @Assert(parserSnapshot(fromXml) == expected)

        let path = Path("target/f_svg_parser_equivalence.svg")
        let file = File(path, OpenMode.Write)
        file.write(SVG_SAMPLE.toArray())
        file.close()
        let fromPath = SvgParser.parse(path)
        @Assert(parserSnapshot(fromPath) == expected)
    }

    /** 任意前缀按 URI 归属。 */
    @TestCase
    public func arbitraryPrefix(): Unit {
        let text = "<s:svg xmlns:s=\"http://www.w3.org/2000/svg\"><s:rect width=\"10\" height=\"10\"/></s:svg>"
        let document = SvgParser.parse(text)
        @Assert(document.root.tag == "svg")
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect.tag == "rect")
        @Assert(rect.namespace == SvgNamespaces.SVG)
    }

    /** 无命名空间子元素继承 SVG 命名空间。 */
    @TestCase
    public func namespaceInheritance(): Unit {
        let document = SvgParser.parse("<svg><rect width=\"10\" height=\"10\"/></svg>")
        @Assert(document.root.namespace == SvgNamespaces.SVG)
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect.namespace == SvgNamespaces.SVG)
    }

    /** 根命名空间非法。 */
    @TestCase
    public func illegalRootNamespace(): Unit {
        let error = expectSvgException({=> SvgParser.parse("<svg xmlns=\"http://example.com/ns\"/>")})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** xlink:href 按 URI 识别。 */
    @TestCase
    public func xlinkHref(): Unit {
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" " +
            "xmlns:xlink=\"http://www.w3.org/1999/xlink\"><use xlink:href=\"#a\"/></svg>"
        let document = SvgParser.parse(text)
        let use = document.root.child("use").getOrThrow()
        @Assert(use.attr(SvgNamespaces.XLINK, "href") == Some("#a"))
    }

    /** 宽松模式：未知标签保留并记 warning。 */
    @TestCase
    public func unknownTagLoose(): Unit {
        let document = SvgParser.parse("<svg><animate attributeName=\"x\"/></svg>")
        let child = document.root.children[0]
        match (child) {
            case ElementNode(element) =>
                @Assert(element is SvgUnknownElement)
                @Assert(element.tag == "animate")
            case _ => @Fail("期望元素节点")
        }
        @Assert(document.warnings.size >= 1)
    }

    /** 严格模式：未知标签抛 Unsupported。 */
    @TestCase
    public func unknownTagStrict(): Unit {
        let error = expectSvgException({=> SvgParser.parse("<svg><animate/></svg>", options: SvgParseOptions(strict: true))})
        @Assert(error.kind == SvgErrorKind.Unsupported)
        @Assert(error.elementPath == Some("/svg[1]/animate[1]"))
    }

    /** 宽松模式：非法颜色降级为 None 并记 warning。 */
    @TestCase
    public func invalidAttributeLoose(): Unit {
        let document = SvgParser.parse("<svg><rect fill=\"notacolor\" width=\"10\" height=\"10\"/></svg>")
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect is SvgRect)
        let shape = (rect as SvgShape).getOrThrow()
        @Assert(shape.fill.isNone())
        @Assert(rect.attr("fill") == Some("notacolor"))
        @Assert(document.warnings.size >= 1)
        @Assert(document.warnings[0].contains("fill"))
        @Assert(document.warnings[0].contains("/svg[1]/rect[1]"))
    }

    /** 严格模式：非法颜色抛 InvalidValue 并带元素路径。 */
    @TestCase
    public func invalidAttributeStrict(): Unit {
        let error = expectSvgException({=>
            SvgParser.parse(
                "<svg><rect fill=\"notacolor\" width=\"10\" height=\"10\"/></svg>",
                options: SvgParseOptions(strict: true)
            )
        })
        @Assert(error.kind == SvgErrorKind.InvalidValue)
        @Assert(error.elementPath == Some("/svg[1]/rect[1]"))
    }

    /** 严格模式：缺必需属性抛 InvalidValue。 */
    @TestCase
    public func missingRequiredStrict(): Unit {
        let error = expectSvgException({=> SvgParser.parse("<svg><rect/></svg>", options: SvgParseOptions(strict: true))})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
        @Assert(error.elementPath == Some("/svg[1]/rect[1]"))
    }

    /** 宽松模式：缺必需属性允许并保持 None。 */
    @TestCase
    public func missingRequiredLoose(): Unit {
        let document = SvgParser.parse("<svg><rect/></svg>")
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect is SvgRect)
        let shape = (rect as SvgRect).getOrThrow()
        @Assert(shape.width.isNone())
        @Assert(shape.height.isNone())
    }

    /** 严格模式：外部引用抛 Security。 */
    @TestCase
    public func externalReferenceStrict(): Unit {
        let error = expectSvgException({=>
            SvgParser.parse(
                "<svg><image href=\"https://x/y.png\" width=\"10\" height=\"10\"/></svg>",
                options: SvgParseOptions(strict: true)
            )
        })
        @Assert(error.kind == SvgErrorKind.Security)
    }

    /** 宽松模式：外部引用被移除并记 warning。 */
    @TestCase
    public func externalReferenceLoose(): Unit {
        let document = SvgParser.parse("<svg><image href=\"https://x/y.png\" width=\"10\" height=\"10\"/></svg>")
        let image = document.root.child("image").getOrThrow()
        @Assert(image.attr("href").isNone())
        @Assert(image.attr(SvgNamespaces.XLINK, "href").isNone())
        @Assert(document.warnings.size >= 1)
    }


    /** 严格模式只校验 SVG 命名空间的已知元素与属性。 */
    @TestCase
    public func foreignNamespaceSkippedInStrict(): Unit {
        let foreignDoc = "<svg xmlns:x=\"urn:x\"><x:rect fill=\"var(--x)\" width=\"1\"/></svg>"
        let document = SvgParser.parse(foreignDoc, options: SvgParseOptions(strict: true))
        let rect = document.root.child("rect").getOrThrow()
        @Assert(rect is SvgUnknownElement)
        @Assert(rect.attr("fill") == Some("var(--x)"))
        @Assert(document.warnings.size == 0)

        let foreignAttribute =
            "<svg xmlns:x=\"urn:x\"><rect x:fill=\"var(--x)\" width=\"1\" height=\"1\"/></svg>"
        let withAttribute = SvgParser.parse(foreignAttribute, options: SvgParseOptions(strict: true))
        let shape = withAttribute.root.child("rect").getOrThrow()
        @Assert(shape.attr("urn:x", "fill") == Some("var(--x)"))
        @Assert(withAttribute.warnings.size == 0)
    }

    /** 标签表全覆盖：每个已知标签都得到对应模型类型。 */
    @TestCase
    public func tagTableCoverage(): Unit {
        let text = "<svg>" +
            "<g/><defs/><symbol/><marker/><pattern/><clipPath/><mask/><switch/><a/><foreignObject/>" +
            "<rect width=\"1\" height=\"1\"/><circle r=\"1\"/><ellipse rx=\"1\" ry=\"1\"/>" +
            "<line/><polyline points=\"0,0 1,1\"/><polygon points=\"0,0 1,1\"/><path d=\"M0 0\"/>" +
            "<text/><tspan/><textPath/>" +
            "<linearGradient/><radialGradient/><stop/>" +
            "<use/><image/></svg>"
        let document = SvgParser.parse(text)
        @Assert(document.root is SvgRoot)
        @Assert(document.root.child("g").getOrThrow() is SvgContainer)
        @Assert(document.root.child("defs").getOrThrow() is SvgContainer)
        @Assert(document.root.child("clipPath").getOrThrow() is SvgContainer)
        @Assert(document.root.child("a").getOrThrow() is SvgContainer)
        @Assert(document.root.child("rect").getOrThrow() is SvgRect)
        @Assert(document.root.child("circle").getOrThrow() is SvgCircle)
        @Assert(document.root.child("ellipse").getOrThrow() is SvgEllipse)
        @Assert(document.root.child("line").getOrThrow() is SvgLine)
        @Assert(document.root.child("polyline").getOrThrow() is SvgPolyline)
        @Assert(document.root.child("polygon").getOrThrow() is SvgPolygon)
        @Assert(document.root.child("path").getOrThrow() is SvgPath)
        @Assert(document.root.child("text").getOrThrow() is SvgText)
        @Assert(document.root.child("tspan").getOrThrow() is SvgTspan)
        @Assert(document.root.child("textPath").getOrThrow() is SvgTextPath)
        @Assert(document.root.child("linearGradient").getOrThrow() is SvgLinearGradient)
        @Assert(document.root.child("radialGradient").getOrThrow() is SvgRadialGradient)
        @Assert(document.root.child("stop").getOrThrow() is SvgStop)
        @Assert(document.root.child("use").getOrThrow() is SvgUse)
        @Assert(document.root.child("image").getOrThrow() is SvgImage)
    }

    /** offset 越界钳制时记 warning。 */
    @TestCase
    public func offsetClampWarning(): Unit {
        let document = SvgParser.parse("<svg><stop offset=\"1.5\"/><stop offset=\"-0.2\"/></svg>")
        let stops = document.root.childrenOf("stop")
        @Assert((stops[0] as SvgStop).getOrThrow().offset == Some(1.0))
        @Assert((stops[1] as SvgStop).getOrThrow().offset == Some(0.0))
        @Assert(document.warnings.size >= 2)
        @Assert(document.warnings[0].contains("offset"))
    }

    /** XML 语法错误包装为 Syntax，保留行列。 */
    @TestCase
    public func xmlSyntaxError(): Unit {
        let error = expectSvgException({=> SvgParser.parse("<svg><rect></svg>")})
        @Assert(error.kind == SvgErrorKind.Syntax)
        @Assert(error.line > 0)
        @Assert(error.column > 0)
    }

    /** XML 解析选项透传：丢弃纯空白文本节点。 */
    @TestCase
    public func xmlOptionsPassthrough(): Unit {
        let text = "<svg>\n  <rect width=\"10\" height=\"10\"/>\n</svg>"
        let kept = SvgParser.parse(text)
        let trimmed = SvgParser.parse(
            text,
            options: SvgParseOptions(xml: XmlParserOptions(trimWhitespaceOnly: true))
        )
        @Assert(kept.root.children.size == 3)
        @Assert(trimmed.root.children.size == 1)
    }
}
