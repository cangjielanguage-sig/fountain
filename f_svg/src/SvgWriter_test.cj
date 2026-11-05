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
import std.collection.ArrayList
import fountain::f_xml.*
import std.io.ByteBuffer

internal func writerSnapshot(element: SvgElement): String {
    let out = StringBuilder()
    out.append("E(")
    out.append(element.namespace)
    out.append("|")
    out.append(element.tag)
    out.append("){")
    for (attribute in element.attributes) {
        out.append("(")
        out.append(attribute.name.uri ?? "")
        out.append("|")
        out.append(attribute.name.local)
        out.append(")=")
        out.append(attribute.value)
        out.append(";")
    }
    out.append("}")
    for (node in element.children) {
        match (node) {
            case ElementNode(child) => out.append(writerSnapshot(child))
            case TextNode(text) => out.append("T(" + text + ")")
            case CDataNode(text) => out.append("C(" + text + ")")
            case CommentNode(text) => out.append("M(" + text + ")")
            case PiNode(target, data) => out.append("P(" + target + "," + data + ")")
        }
    }
    out.toString()
}

internal func svgNodeSnapshot(node: SvgNode): String {
    match (node) {
        case ElementNode(element) => writerSnapshot(element)
        case TextNode(text) => "T(" + text + ")"
        case CDataNode(text) => "C(" + text + ")"
        case CommentNode(text) => "M(" + text + ")"
        case PiNode(target, data) => "P(" + target + "," + data + ")"
    }
}

internal func documentSnapshot(document: SvgDocument): String {
    let out = StringBuilder()
    match (document.doctype) {
        case Some(doctype) =>
            out.append("D(")
            out.append(doctype.name)
            out.append(")")
        case None => ()
    }
    out.append("P[")
    for (node in document.prolog) {
        out.append(svgNodeSnapshot(node))
    }
    out.append("]R(")
    out.append(writerSnapshot(document.root))
    out.append(")E[")
    for (node in document.epilog) {
        out.append(svgNodeSnapshot(node))
    }
    out.append("]")
    out.toString()
}

private func writerBytes(document: SvgDocument, options: SvgWriteOptions): Array<Byte> {
    let buffer = ByteBuffer()
    let writer = SvgWriter(buffer, options: options)
    writer.write(document)
    writer.flush()
    buffer.bytes()
}

private func writerElementString(element: SvgElement): String {
    let buffer = ByteBuffer()
    let writer = SvgWriter(buffer, options: SvgWriteOptions(xmlDeclaration: false))
    writer.write(element)
    writer.flush()
    String.fromUtf8(buffer.bytes())
}

private let WRITER_SHAPES = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\">" +
    "<g transform=\"translate(10,20)\">" +
    "<rect x=\"1\" y=\"2\" width=\"10\" height=\"20\" fill=\"#f00\"/>" +
    "<circle cx=\"5\" cy=\"5\" r=\"3\"/>" +
    "<ellipse cx=\"5\" cy=\"5\" rx=\"3\" ry=\"2\"/>" +
    "<line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\"/>" +
    "<polyline points=\"0,0 1,1 2,0\"/>" +
    "<polygon points=\"0,0 1,1 2,0\"/>" +
    "<path d=\"M0 0 L10 10 Z\"/>" +
    "</g></svg>"

private let WRITER_TEXT = "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
    "<text x=\"10 20\" y=\"30\" font-size=\"12\">hello <tspan font-weight=\"bold\">world</tspan></text>" +
    "</svg>"

private let WRITER_GRADIENT = "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
    "<defs><linearGradient id=\"g1\" x1=\"0\" x2=\"1\"><stop offset=\"0\" stop-color=\"#fff\"/>" +
    "<stop offset=\"100%\" stop-color=\"#000\"/></linearGradient>" +
    "<radialGradient id=\"g2\" cx=\"50%\" cy=\"50%\" r=\"50%\"/></defs></svg>"

private let WRITER_NAMESPACES = "<svg xmlns=\"http://www.w3.org/2000/svg\" " +
    "xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:edit=\"urn:edit\">" +
    "<use xlink:href=\"#g1\"/><edit:metadata edit:key=\"v\"/></svg>"

private let WRITER_COMMENTS = "<!DOCTYPE svg><svg xmlns=\"http://www.w3.org/2000/svg\">" +
    "<!--before--><rect width=\"1\" height=\"1\"/><![CDATA[raw]]><?pi data?></svg>"

private let WRITER_UNSAFE = "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
    "<script>alert(1)</script><rect onload=\"x()\" width=\"10\" height=\"10\"/>" +
    "<image href=\"https://x/y.png\" width=\"5\" height=\"5\"/></svg>"

@Test
public class SvgWriter_test {
    /** 紧凑模式：无缩进、无换行，保留属性顺序。 */
    @TestCase
    public func compactOutput(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect x=\"1\" width=\"10\" height=\"20\"/></svg>"
        )
        let text = writeSvgString(document)
        @Assert(!text.contains("\n"))
        @Assert(text.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(text.contains("<rect x=\"1\" width=\"10\" height=\"20\"/>"))
        @Assert(text.contains("<svg "))
    }

    /** 缩进模式产生换行与缩进。 */
    @TestCase
    public func indentOutput(): Unit {
        let document = SvgParser.parse(WRITER_SHAPES)
        let text = writeSvgString(document, options: SvgWriteOptions(indent: Some("  ")))
        @Assert(text.contains("\n"))
        @Assert(text.contains("\n  <g"))
        @Assert(text.contains("\n    <rect"))
    }

    /** XML 声明开关。 */
    @TestCase
    public func xmlDeclarationSwitch(): Unit {
        let document = SvgParser.parse(WRITER_TEXT)
        let withDeclaration = writeSvgString(document)
        @Assert(withDeclaration.startsWith("<?xml version=\"1.0\""))
        let without = writeSvgString(document, options: SvgWriteOptions(xmlDeclaration: false))
        @Assert(!without.startsWith("<?xml"))
        @Assert(without.startsWith("<svg"))
    }

    /** 末尾换行开关。 */
    @TestCase
    public func trailingNewlineSwitch(): Unit {
        let document = SvgParser.parse(WRITER_TEXT)
        let plain = writeSvgString(document)
        @Assert(!plain.endsWith("\n"))
        let newline = writeSvgString(document, options: SvgWriteOptions(trailingNewline: true))
        @Assert(newline.endsWith("\n"))
    }

    /** charset 默认 UTF-8，输出可按 UTF-8 解码。 */
    @TestCase
    public func charsetOutput(): Unit {
        let document = SvgParser.parse(WRITER_TEXT)
        let bytes = writerBytes(document, SvgWriteOptions(charset: Charsets.UTF8))
        @Assert(String.fromUtf8(bytes).contains("hello"))
    }

    /** 根元素自动声明默认命名空间与 xlink。 */
    @TestCase
    public func namespaceDeclarations(): Unit {
        let document = SvgParser.parse(WRITER_NAMESPACES)
        let text = writeSvgString(document)
        @Assert(text.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(text.contains("xmlns:xlink=\"http://www.w3.org/1999/xlink\""))
        @Assert(text.contains("xlink:href=\"#g1\""))
        @Assert(text.contains("xmlns:edit=\"urn:edit\""))
        @Assert(text.contains("edit:key=\"v\""))
    }

    /** xlink 开关：关闭时写裸 href。 */
    @TestCase
    public func xlinkSwitch(): Unit {
        let document = SvgParser.parse(WRITER_NAMESPACES)
        let text = writeSvgString(document, options: SvgWriteOptions(xlink: false))
        @Assert(text.contains("href=\"#g1\""))
        @Assert(!text.contains("xlink:href"))
        @Assert(!text.contains("xmlns:xlink"))
    }

    /** 裸 href 在默认开关下写成 xlink:href。 */
    @TestCase
    public func bareHrefBecomesXlink(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><use href=\"#a\"/></svg>"
        )
        let text = writeSvgString(document)
        @Assert(text.contains("xlink:href=\"#a\""))
        @Assert(text.contains("xmlns:xlink="))
    }

    /** 六个样本的结构等价往返。 */
    @TestCase
    public func structuralRoundTrip(): Unit {
        let samples = [
            WRITER_SHAPES, WRITER_TEXT, WRITER_GRADIENT, WRITER_NAMESPACES, WRITER_COMMENTS, WRITER_UNSAFE
        ]
        for (sample in samples) {
            let original = SvgParser.parse(sample)
            let written = writeSvgString(original)
            let reparsed = SvgParser.parse(written)
            @Assert(documentSnapshot(reparsed) == documentSnapshot(original))
        }
    }

    /** 紧凑模式二次写入字节稳定。 */
    @TestCase
    public func compactByteStability(): Unit {
        let samples = [
            WRITER_SHAPES, WRITER_TEXT, WRITER_GRADIENT, WRITER_NAMESPACES, WRITER_COMMENTS, WRITER_UNSAFE
        ]
        for (sample in samples) {
            let first = writeSvgString(SvgParser.parse(sample))
            let second = writeSvgString(SvgParser.parse(first))
            @Assert(first == second)
        }
    }

    /** 元素写入省略 XML 声明以外的前后杂项。 */
    @TestCase
    public func writeSingleElement(): Unit {
        let rect = SvgRect(width: SvgLength(10.0), height: SvgLength(20.0))
        let text = writerElementString(rect)
        @Assert(text.contains("<rect"))
        @Assert(text.contains("width=\"10\""))
    }
}
