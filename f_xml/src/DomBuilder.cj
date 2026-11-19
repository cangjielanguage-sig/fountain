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
import fountain::f_base.StringGenerator

/**
 * 事件 → DOM。
 *
 * 三件事：
 * 1. **相邻文本合并**：连续 `Text` 事件累积在同一个缓冲里，遇到非文本事件才落成一个节点；
 * 2. `trimWhitespaceOnly = true` 时丢弃纯空白文本节点，`xml:space="preserve"` 作用域内强制保留；
 * 3. 深度由解析引擎的 `maxElementDepth` 把关，这里不再递归，不会栈溢出。
 */
internal class DomBuilder {
    private let options: XmlParserOptions
    private let doc = XmlDocument()
    private let stack = ArrayList<XmlElement>()
    private let preserve = ArrayList<Bool>()
    private let textBuffer = StringGenerator()
    private var hasPendingText = false

    init(options: XmlParserOptions) {
        this.options = options
    }

    func document(): XmlDocument {
        this.doc
    }

    func handle(event: XmlEvent): Unit {
        match (event) {
            case XmlEvent.StartDocument => ()
            case XmlEvent.XmlDeclaration(version, encoding, standalone) =>
                this.doc.declaration = XmlDeclaration(version, encoding: encoding, standalone: standalone)
            case XmlEvent.DocType(name, publicId, systemId) =>
                this.doc.doctype = DocTypeInfo(name, publicId: publicId, systemId: systemId)
            case XmlEvent.StartElement(name, attrs, _) =>
                this.flushText()
                let element = XmlElement(name)
                for (attribute in attrs) {
                    element.attributes.add(attribute)
                }
                let preserveHere = this.resolvePreserve(element)
                if (this.stack.size == 0) {
                    this.doc.root = element
                } else {
                    this.stack[this.stack.size - 1].children.add(XmlNode.ElementNode(element))
                }
                this.stack.add(element)
                this.preserve.add(preserveHere)
            case XmlEvent.EndElement(_) =>
                this.flushText()
                if (this.stack.size > 0) {
                    this.stack.remove(at: this.stack.size - 1)
                    this.preserve.remove(at: this.preserve.size - 1)
                }
            case XmlEvent.Text(text) =>
                this.textBuffer.append<String>(text)
                this.hasPendingText = true
            case XmlEvent.CData(text) =>
                this.flushText()
                this.appendNode(XmlNode.CDataNode(text))
            case XmlEvent.Comment(text) =>
                this.flushText()
                this.appendNode(XmlNode.CommentNode(text))
            case XmlEvent.ProcessingInstruction(target, data) =>
                this.flushText()
                this.appendNode(XmlNode.PiNode(target, data))
            case XmlEvent.EndDocument => this.flushText()
        }
    }

    private func resolvePreserve(element: XmlElement): Bool {
        let parentValue = if (this.preserve.size > 0) {
            this.preserve[this.preserve.size - 1]
        } else {
            false
        }
        match (element.attr(XML_NS_URI, "space")) {
            case Some("preserve") => true
            case Some("default") => false
            case _ => parentValue
        }
    }

    private func flushText(): Unit {
        if (!this.hasPendingText) {
            return
        }
        let text = this.textBuffer.toString()
        this.textBuffer.clear()
        this.hasPendingText = false
        if (this.options.trimWhitespaceOnly && !this.inPreserveScope() && isWhitespaceOnly(text)) {
            return
        }
        this.appendNode(XmlNode.TextNode(text))
    }

    private func inPreserveScope(): Bool {
        if (this.preserve.size == 0) {
            return false
        }
        this.preserve[this.preserve.size - 1]
    }

    private func appendNode(node: XmlNode): Unit {
        if (this.stack.size > 0) {
            this.stack[this.stack.size - 1].children.add(node)
        } else if (this.doc.root.isNone()) {
            this.doc.prolog.add(node)
        } else {
            this.doc.epilog.add(node)
        }
    }
}
