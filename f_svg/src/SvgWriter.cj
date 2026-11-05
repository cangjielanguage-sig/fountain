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

import std.io.{ByteBuffer, OutputStream}
import fountain::f_xml.*

/** 生成选项。 */
public struct SvgWriteOptions {
    /** `None` = 紧凑；`Some("  ")` 等为缩进步长。 */
    public let indent: ?String
    public let xmlDeclaration: Bool
    public let charset: Charset
    public let cdata: CdataMode
    /** `true` 时引用写 `xlink:href`，`false` 写裸 `href`。 */
    public let xlink: Bool
    public let trailingNewline: Bool

    public init(
        indent!: ?String = None,
        xmlDeclaration!: Bool = true,
        charset!: Charset = Charsets.UTF8,
        cdata!: CdataMode = CdataMode.Auto,
        xlink!: Bool = true,
        trailingNewline!: Bool = false
    ) {
        this.indent = indent
        this.xmlDeclaration = xmlDeclaration
        this.charset = charset
        this.cdata = cdata
        this.xlink = xlink
        this.trailingNewline = trailingNewline
    }
}

/**
 * SVG 生成器。
 *
 * 先把模型转成 `XmlDocument`，再交给 `f_xml::XmlWriter`：
 * 转义、命名空间声明、缩进与编码全部复用 `f_xml`。
 */
public class SvgWriter {
    private let output: OutputStream
    private let options: SvgWriteOptions
    private let writer: XmlWriter

    public init(output: OutputStream, options!: SvgWriteOptions = SvgWriteOptions()) {
        this.output = output
        this.options = options
        this.writer = XmlWriter(
            output,
            options: XmlWriterOptions(
                indent: options.indent,
                cdata: options.cdata,
                charset: options.charset
            )
        )
    }

    public func write(document: SvgDocument): Unit {
        let xml = document.toXmlDocument()
        this.normalizeHrefs(xml.root)
        xml.declaration = this.declarationFor(document)
        this.writer.write(xml)
        this.finish()
    }

    public func write(element: SvgElement): Unit {
        let xmlElement = element.toXmlElement()
        this.normalizeHrefs(Some(xmlElement))
        let document = XmlDocument()
        document.root = Some(xmlElement)
        document.declaration = if (this.options.xmlDeclaration) {
            Some(XmlDeclaration("1.0"))
        } else {
            None
        }
        this.writer.write(document)
        this.finish()
    }

    public func flush(): Unit {
        this.writer.flush()
    }

    public func close(): Unit {
        this.writer.close()
    }

    private func finish(): Unit {
        this.writer.flush()
        if (this.options.trailingNewline) {
            this.output.write("\n".toArray())
            this.output.flush()
        }
    }

    private func declarationFor(document: SvgDocument): ?XmlDeclaration {
        if (!this.options.xmlDeclaration) {
            return None
        }
        match (document.declaration) {
            case Some(declaration) => Some(declaration)
            case None => Some(XmlDeclaration("1.0"))
        }
    }

    private func normalizeHrefs(root: ?XmlElement): Unit {
        match (root) {
            case Some(element) => this.normalizeElementHrefs(element)
            case None => ()
        }
    }

    private func normalizeElementHrefs(element: XmlElement): Unit {
        let referencing = match (element.name.local) {
            case "use" | "image" | "textPath" | "linearGradient" | "radialGradient" => true
            case _ => false
        }
        for (index in 0..element.attributes.size) {
            let attribute = element.attributes[index]
            if (attribute.name.local != "href") {
                continue
            }
            if (this.options.xlink) {
                if (referencing && attribute.name.uri.isNone()) {
                    element.attributes[index] = XmlAttribute(
                        QName("href", prefix: Some("xlink"), uri: Some(SvgNamespaces.XLINK)),
                        attribute.value
                    )
                }
            } else {
                element.attributes[index] = XmlAttribute(QName("href"), attribute.value)
            }
        }
        for (node in element.children) {
            match (node) {
                case XmlNode.ElementNode(child) => this.normalizeElementHrefs(child)
                case _ => ()
            }
        }
    }
}

/** 便捷函数：写出为字符串（UTF-8）。 */
public func writeSvgString(
    document: SvgDocument,
    options!: SvgWriteOptions = SvgWriteOptions()
): String {
    let buffer = ByteBuffer()
    let writer = SvgWriter(buffer, options: options)
    writer.write(document)
    writer.flush()
    String.fromUtf8(buffer.bytes())
}
