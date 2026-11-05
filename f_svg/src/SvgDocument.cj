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
import fountain::f_xml.*

/** 一份 SVG 文档：根、声明、DOCTYPE、前后的杂项节点与告警。 */
public class SvgDocument <: ToString {
    public var root: SvgRoot
    public var declaration: ?XmlDeclaration = None
    public var doctype: ?DocTypeInfo = None
    public let prolog = ArrayList<SvgNode>()
    public let epilog = ArrayList<SvgNode>()
    /** 宽松模式下的降级与安全移除记录，只增。 */
    public let warnings = ArrayList<String>()

    public init(root: SvgRoot) {
        this.root = root
    }

    /** 深度优先，返回第一个匹配的 id。 */
    public func elementById(id: String): ?SvgElement {
        findSvgElementById(this.root, id)
    }

    /** 全部 local name 匹配的元素（不区分命名空间）。 */
    public func elementsByTag(tag: String): ArrayList<SvgElement> {
        let result = ArrayList<SvgElement>()
        collectSvgElementsByTag(this.root, tag, result)
        result
    }

    public func toXmlDocument(): XmlDocument {
        let document = XmlDocument()
        document.declaration = this.declaration
        document.doctype = this.doctype
        for (node in this.prolog) {
            document.prolog.add(svgNodeToXml(node))
        }
        document.root = Some(this.root.toXmlElement())
        for (node in this.epilog) {
            document.epilog.add(svgNodeToXml(node))
        }
        document
    }

    public func toString(): String {
        this.toXmlDocument().toString()
    }
}

private func findSvgElementById(element: SvgElement, id: String): ?SvgElement {
    if (element.attr("id") == Some(id)) {
        return Some(element)
    }
    for (node in element.children) {
        match (node) {
            case ElementNode(child) =>
                match (findSvgElementById(child, id)) {
                    case Some(found) => return Some(found)
                    case None => ()
                }
            case _ => ()
        }
    }
    None
}

private func collectSvgElementsByTag(element: SvgElement, tag: String, result: ArrayList<SvgElement>): Unit {
    if (element.tag == tag) {
        result.add(element)
    }
    for (node in element.children) {
        match (node) {
            case ElementNode(child) => collectSvgElementsByTag(child, tag, result)
            case _ => ()
        }
    }
}

internal func svgNodeToXml(node: SvgNode): XmlNode {
    match (node) {
        case ElementNode(element) => XmlNode.ElementNode(element.toXmlElement())
        case TextNode(text) => XmlNode.TextNode(text)
        case CDataNode(text) => XmlNode.CDataNode(text)
        case CommentNode(text) => XmlNode.CommentNode(text)
        case PiNode(target, data) => XmlNode.PiNode(target, data)
    }
}
