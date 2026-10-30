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

import std.collection.ArrayList
import std.io.OutputStream
import cangjie_tpc::charset4cj.charset.encoding.{Encoder, Decoder}
import fountain::f_base.StringGenerator

/**
 * 增量写入时的元素栈帧：记录待闭合的 start tag 与是否已有子元素（缩进用）。
 */
internal class IncrementalFrame {
    let name: QName
    var pending = true
    var hadChild = false

    init(name: QName) {
        this.name = name
    }
}

/**
 * XML 生成器。
 *
 * 支持两种写法：整树（`write(doc)` / `write(element)`）与**增量**（`startElement` /
 * `text` / `endElement`）。两者不可混用——混用会破坏命名空间作用域与缩进状态，直接抛
 * `XmlException`。
 *
 * **`close()` 之后不得再调用任何方法**（未定义行为）。
 *
 * 两条实现约定：
 * 1. UTF-8 路径不经过 `String` 包装：`StringGenerator.unsafeBytes()` 直接给字节；
 * 2. 输出先攒在 8~64 KB 的缓冲里，攒满再写底层，不是一个 token 一次 `write`。
 */
public class XmlWriter {
    private let output: OutputStream
    private let options: XmlWriterOptions
    private let buffer = StringGenerator()
    private let encoder: Encoder
    private let decoder: Decoder
    private let ns = NamespaceScope()
    private var closed = false
    /** 增量写入的元素栈；`pending = true` 表示 start tag 还没闭合。 */
    private let frames = ArrayList<IncrementalFrame>()
    private var incrementalUsed = false
    private var treeUsed = false
    private var declarationWritten = false
    /** 往返校验的执行次数（UTF 系列必须恒为 0）。 */
    internal var roundTripChecks: Int64 = 0

    private static let FLUSH_THRESHOLD: Int64 = 16 * 1024

    public init(output: OutputStream, options!: XmlWriterOptions = XmlWriterOptions()) {
        this.output = output
        this.options = options
        this.encoder = options.charset.newEncoder()
        this.decoder = options.charset.newDecoder()
        if (this.isUtf16Le()) {
            output.write([0xFF, 0xFE])
        } else if (this.isUtf16Be()) {
            output.write([0xFE, 0xFF])
        } else if (this.isUtf32Le()) {
            output.write([0xFF, 0xFE, 0x00, 0x00])
        } else if (this.isUtf32Be()) {
            output.write([0x00, 0x00, 0xFE, 0xFF])
        }
    }

    // ---------------------------------------------------------------- 编码判定

    private func isUtf8(): Bool {
        this.options.charset == Charsets.UTF8
    }

    private func isUtf16Le(): Bool {
        this.options.charset == Charsets.UTF16LE
    }

    private func isUtf16Be(): Bool {
        this.options.charset == Charsets.UTF16BE
    }

    private func isUtf32Le(): Bool {
        this.options.charset == Charsets.UTF32LE
    }

    private func isUtf32Be(): Bool {
        this.options.charset == Charsets.UTF32BE
    }

    /** UTF-8 / UTF-16 / UTF-32 恒可编码，跳过往返校验。 */
    private func isWideUnicode(): Bool {
        this.isUtf8() || this.isUtf16Le() || this.isUtf16Be() || this.isUtf32Le() || this.isUtf32Be()
    }

    // ---------------------------------------------------------------- 对外

    /** 写整份文档：声明 → doctype → prolog → root → epilog。 */
    public func write(doc: XmlDocument): Unit {
        this.ensureOpen()
        this.ensureTreeMode()
        this.treeUsed = true
        this.ns.push()
        if (let Some(declaration) <- doc.declaration) {
            this.appendText(declaration.toString())
            this.newLine(0)
        }
        let doctype: ?Doctype = this.options.doctype
        if (let Some(d) <- doctype) {
            this.writeDoctype(d)
            this.newLine(0)
        } else if (let Some(info) <- doc.doctype) {
            this.writeDocTypeInfo(info)
            this.newLine(0)
        }
        for (node in doc.prolog) {
            this.writeNode(node, 1)
            this.newLine(0)
        }
        if (let Some(root) <- doc.root) {
            this.writeElement(root, 1)
            this.newLine(0)
        }
        for (node in doc.epilog) {
            this.writeNode(node, 1)
            this.newLine(0)
        }
        this.ns.pop()
    }

    /** 只写元素（不带 XML 声明）。 */
    public func write(element: XmlElement): Unit {
        this.ensureOpen()
        this.ensureTreeMode()
        this.treeUsed = true
        this.ns.push()
        if (let Some(d) <- this.options.doctype) {
            this.writeDoctype(d)
            this.newLine(0)
        }
        this.writeElement(element, 1)
        this.ns.pop()
    }

    /** 冲刷自身缓冲，并对底层 `output` 调用 `flush()`。 */
    public func flush(): Unit {
        this.ensureOpen()
        this.flushBuffer()
        this.output.flush()
    }

    // ---------------------------------------------------------------- 增量接口

    /** 写 XML 声明（只能调用一次，且必须在任何元素之前）。 */
    public func writeDeclaration(
        version!: String = "1.0",
        encoding!: ?String = None,
        standalone!: ?Bool = None
    ): Unit {
        this.ensureOpen()
        this.ensureIncrementalMode()
        if (this.declarationWritten) {
            throw XmlException("XML 声明只能写一次")
        }
        this.declarationWritten = true
        this.appendText(XmlDeclaration(version, encoding: encoding, standalone: standalone).toString())
        this.newLine(0)
    }

    /** 开始一个元素：写 `<name attrs`，延迟到有子内容或结束时再闭合。 */
    public func startElement(name: QName, attributes!: Array<XmlAttribute> = []): Unit {
        this.ensureOpen()
        this.ensureIncrementalMode()
        if (this.frames.size > 0) {
            this.closePendingStart()
            this.frames[this.frames.size - 1].hadChild = true
            this.newLine(this.frames.size)
        }
        this.appendText("<")
        this.appendText(this.literalName(name))
        this.ns.push()
        this.declareNamespacesFor(name, attributes)
        for (attribute in attributes) {
            this.appendText(" ")
            this.appendText(this.literalName(attribute.name))
            this.appendText("=\"")
            Escaper.escapeAttribute(attribute.value, attribute.name.local, this.buffer)
            this.appendText("\"")
        }
        this.frames.add(IncrementalFrame(name))
    }

    /** 结束元素：没有子内容时输出 `/>`，否则输出 `</name>`。 */
    public func endElement(name: QName): Unit {
        this.ensureOpen()
        this.ensureIncrementalMode()
        if (this.frames.size == 0) {
            throw XmlException("没有可结束的元素：</${this.literalName(name)}>")
        }
        let top = this.frames[this.frames.size - 1]
        if (this.literalName(top.name) != this.literalName(name)) {
            throw XmlException(
                "元素不匹配：期望 </${this.literalName(top.name)}>，实际 </${this.literalName(name)}>"
            )
        }
        if (top.pending) {
            this.appendText("/>")
        } else {
            if (top.hadChild) {
                this.newLine(this.frames.size - 1)
            }
            this.appendText("</")
            this.appendText(this.literalName(top.name))
            this.appendText(">")
        }
        this.ns.pop()
        this.frames.remove(at: this.frames.size - 1)
    }

    /** 写文本节点（自动转义；必须在某个元素内）。 */
    public func text(value: String): Unit {
        this.ensureOpen()
        this.ensureIncrementalMode()
        if (this.frames.size == 0) {
            throw XmlException("文本节点必须写在一个元素内")
        }
        this.closePendingStart()
        this.writeText(value, this.frames[this.frames.size - 1].name.local)
    }

    /** 空元素：等价于 `startElement` 紧跟 `endElement`，输出 `<name/>`。 */
    public func emptyElement(name: QName, attributes!: Array<XmlAttribute> = []): Unit {
        this.startElement(name, attributes: attributes)
        this.endElement(name)
    }

    /** 闭合当前元素的 start tag（`<a` → `<a>`）。 */
    private func closePendingStart(): Unit {
        if (this.frames.size == 0) {
            return
        }
        let top = this.frames[this.frames.size - 1]
        if (top.pending) {
            this.appendText(">")
            top.pending = false
        }
    }

    private func ensureTreeMode(): Unit {
        if (this.incrementalUsed) {
            throw XmlException("已使用增量接口，不能再整树写出")
        }
    }

    private func ensureIncrementalMode(): Unit {
        if (this.treeUsed) {
            throw XmlException("已使用整树写出，不能再使用增量接口")
        }
        this.incrementalUsed = true
    }

    /** 冲刷并关闭底层输出流。之后不得再调用任何方法。 */
    public func close(): Unit {
        if (this.closed) {
            return
        }
        if (this.frames.size > 0) {
            throw XmlException("有 ${this.frames.size} 个元素未闭合，不能关闭 XmlWriter")
        }
        this.flushBuffer()
        this.output.flush()
        if (let resource: Resource <- this.output) {
            resource.close()
        }
        this.closed = true
    }

    private func ensureOpen(): Unit {
        if (this.closed) {
            throw XmlException("XmlWriter 已关闭，不得再调用")
        }
    }

    // ---------------------------------------------------------------- 输出

    private func appendText(text: String): Unit {
        this.buffer.append<String>(text)
        if (this.buffer.size >= XmlWriter.FLUSH_THRESHOLD) {
            this.flushBuffer()
        }
    }

    private func flushBuffer(): Unit {
        if (this.buffer.size == 0) {
            return
        }
        if (this.isUtf8()) {
            this.output.write(this.buffer.unsafeBytes())
            this.buffer.clear()
            return
        }
        let text = this.buffer.toString()
        this.buffer.clear()
        this.output.write(this.encodeChecked(text))
    }

    /**
     * 非 UTF 编码：先用往返校验判断是否可无损编码，再决定抛错还是用 `?` 兜底。
     *
     * `charset4cj` 对不可映射字符会静默替换成 `?`，所以「等它抛异常」不可行。
     */
    private func encodeChecked(text: String): Array<Byte> {
        if (this.isWideUnicode()) {
            return this.encoder.encode(text)
        }
        this.roundTripChecks++
        let bytes = this.encoder.encode(text)
        let back = this.decoder.decode(bytes)
        if (back == text) {
            return bytes
        }
        let out = ArrayList<Byte>()
        var position: Int64 = 0
        for (r in text.runes()) {
            position++
            let piece = r.toString()
            let encoded = this.encoder.encode(piece)
            let decoded = this.decoder.decode(encoded)
            if (decoded == piece) {
                for (b in encoded) {
                    out.add(b)
                }
            } else {
                if (this.options.onInvalidChar == InvalidCharMode.Throw) {
                    throw XmlException(
                        "字符 U+${XmlChars.hex(r.position())} 无法用「${this.options.charset}」编码（文本内第 ${position} 个字符）"
                    )
                }
                out.add(0x3F)
            }
        }
        out.toArray()
    }

    // ---------------------------------------------------------------- 文档部件

    private func writeDoctype(doctype: Doctype): Unit {
        this.appendText("<!DOCTYPE ")
        this.appendText(doctype.name)
        match (doctype.publicId) {
            case Some(publicId) =>
                this.appendText(" PUBLIC \"")
                this.appendText(publicId)
                this.appendText("\" \"")
                this.appendText(doctype.systemId ?? "")
                this.appendText("\"")
            case None => match (doctype.systemId) {
                case Some(systemId) =>
                    this.appendText(" SYSTEM \"")
                    this.appendText(systemId)
                    this.appendText("\"")
                case None => ()
            }
        }
        if (doctype.entities.size > 0) {
            this.appendText(" [")
            for (decl in doctype.entities) {
                this.appendText(decl.toString())
            }
            this.appendText("]")
        }
        this.appendText(">")
    }

    private func writeDocTypeInfo(info: DocTypeInfo): Unit {
        let doctype = Doctype(
            info.name,
            publicId: info.publicId,
            systemId: info.systemId,
            entities: info.entities
        )
        this.writeDoctype(doctype)
    }

    private func newLine(depth: Int64): Unit {
        match (this.options.indent) {
            case Some(step) =>
                this.appendText("\n")
                for (_ in 0..depth) {
                    this.appendText(step)
                }
            case None => ()
        }
    }

    // ---------------------------------------------------------------- 节点

    private func writeNode(node: XmlNode, depth: Int64): Unit {
        match (node) {
            case XmlNode.ElementNode(e) => this.writeElement(e, depth)
            case XmlNode.TextNode(text) => this.writeText(text, "")
            case XmlNode.CDataNode(text) =>
                Escaper.writeCData(text, "", this.buffer)
            case XmlNode.CommentNode(text) =>
                this.appendText("<!--")
                this.appendText(text)
                this.appendText("-->")
            case XmlNode.PiNode(target, data) =>
                this.appendText("<?")
                this.appendText(target)
                if (!data.isEmpty()) {
                    this.appendText(" ")
                    this.appendText(data)
                }
                this.appendText("?>")
            case XmlNode.EntityRefNode(name) => this.writeEntityRef(name)
        }
    }

    private func writeText(text: String, elementName: String): Unit {
        match (this.options.cdata) {
            case CdataMode.Always => Escaper.writeCData(text, elementName, this.buffer)
            case CdataMode.Auto | CdataMode.Never => Escaper.escapeText(text, elementName, this.buffer)
        }
        this.checkThreshold()
    }

    private func checkThreshold(): Unit {
        if (this.buffer.size >= XmlWriter.FLUSH_THRESHOLD) {
            this.flushBuffer()
        }
    }

    private func writeEntityRef(name: String): Unit {
        match (this.options.doctype) {
            case Some(d) =>
                if (!d.isDeclared(name)) {
                    if (this.options.strictEntities) {
                        throw XmlException("实体「${name}」未在 doctype 里声明")
                    }
                }
            case None =>
                if (this.options.strictEntities) {
                    throw XmlException("实体「${name}」未在 doctype 里声明")
                }
        }
        this.appendText("&")
        this.appendText(name)
        this.appendText(";")
    }

    private func writeElement(element: XmlElement, depth: Int64): Unit {
        this.ns.push()
        this.appendText("<")
        this.appendText(this.literalName(element.name))
        this.declareNamespaces(element)
        for (attribute in element.attributes) {
            this.appendText(" ")
            this.appendText(this.literalName(attribute.name))
            this.appendText("=\"")
            Escaper.escapeAttribute(attribute.value, attribute.name.local, this.buffer)
            this.appendText("\"")
        }
        if (element.children.size == 0) {
            this.appendText("/>")
            this.ns.pop()
            return
        }
        this.appendText(">")
        let indented = this.hasElementChild(element)
        for (node in element.children) {
            match (node) {
                case XmlNode.ElementNode(_) => if (indented) {
                    this.newLine(depth)
                }
                case _ => ()
            }
            this.writeNodeWithName(node, element.name.local, depth)
        }
        if (indented) {
            this.newLine(depth - 1)
        }
        this.appendText("</")
        this.appendText(this.literalName(element.name))
        this.appendText(">")
        this.ns.pop()
    }

    private func writeNodeWithName(node: XmlNode, elementName: String, depth: Int64): Unit {
        match (node) {
            case XmlNode.ElementNode(e) => this.writeElement(e, depth + 1)
            case XmlNode.TextNode(text) => this.writeText(text, elementName)
            case _ => this.writeNode(node, depth)
        }
    }

    private func hasElementChild(element: XmlElement): Bool {
        match (this.options.indent) {
            case None => false
            case Some(_) =>
                for (node in element.children) {
                    match (node) {
                        case XmlNode.ElementNode(_) => return true
                        case _ => ()
                    }
                }
                false
        }
    }

    // ---------------------------------------------------------------- 命名空间

    private func literalName(name: QName): String {
        match (name.prefix) {
            case Some(prefix) => "${prefix}:${name.local}"
            case None => name.local
        }
    }

    private func currentUri(prefix: ?String): ?String {
        match (this.ns.elementNamespace(prefix)) {
            case NsLookup.Declared(uri) => Some(uri)
            case _ => None
        }
    }

    /** 只在首次引入或改变绑定时输出 `xmlns` / `xmlns:p`。 */
    private func declareNamespaces(element: XmlElement): Unit {
        this.declareNamespacesFor(element.name, element.attributes.toArray())
    }

    private func declareNamespacesFor(name: QName, attributes: Array<XmlAttribute>): Unit {
        this.ensureBinding(name)
        for (attribute in attributes) {
            match (attribute.name.uri) {
                case Some(_) => if (attribute.name.prefix.isSome()) {
                    this.ensureBinding(attribute.name)
                }
                case None => ()
            }
        }
    }

    private func ensureBinding(name: QName): Unit {
        let target = name.uri
        match (name.prefix) {
            case None =>
                let current = this.currentUri(None)
                if (target != current) {
                    match (target) {
                        case Some(uri) =>
                            this.appendText(" xmlns=\"")
                            Escaper.escapeAttribute(uri, "xmlns", this.buffer)
                            this.appendText("\"")
                            this.ns.declare(None, Some(uri))
                        case None =>
                            this.appendText(" xmlns=\"\"")
                            this.ns.declare(None, None)
                    }
                }
            case Some(prefix) =>
                match (target) {
                    case Some(uri) =>
                        let current = this.currentUri(Some(prefix))
                        if (current != Some(uri)) {
                            this.appendText(" xmlns:${prefix}=\"")
                            Escaper.escapeAttribute(uri, "xmlns:${prefix}", this.buffer)
                            this.appendText("\"")
                            this.ns.declare(Some(prefix), Some(uri))
                        }
                    case None => ()
                }
        }
    }
}
