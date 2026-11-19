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
    /** 解析该文档时使用的选项；供外部文档引用复制安全策略。 */
    public var parseOptions: SvgParseOptions = SvgParseOptions()
    /** 文档级变更 hub。 */
    internal let mutationHub = SvgMutationHub()

    public init(root: SvgRoot) {
        this.root = root
        root.mutationHub = Some(this.mutationHub)
        this.mutationHub.warnings = Some(this.warnings)
    }

    /** 注册变更监听器；上限 32，超限抛 `InvalidValue`。 */
    public func addMutationListener(listener: SvgMutationListener): Unit {
        this.mutationHub.add(listener)
    }

    public func removeMutationListener(listener: SvgMutationListener): Unit {
        this.mutationHub.remove(listener)
    }

    public func getIntersectionList(
        rect: SvgBounds,
        reference!: ?SvgElement = None
    ): ArrayList<SvgElement> {
        svgDocumentHitQuery(this, rect, reference, false)
    }

    public func getEnclosureList(
        rect: SvgBounds,
        reference!: ?SvgElement = None
    ): ArrayList<SvgElement> {
        svgDocumentHitQuery(this, rect, reference, true)
    }

    public func checkIntersection(element: SvgElement, rect: SvgBounds): Bool {
        svgDocumentHitQueryCheck(this, element, rect, false)
    }

    public func checkEnclosure(element: SvgElement, rect: SvgBounds): Bool {
        svgDocumentHitQueryCheck(this, element, rect, true)
    }

    /** 深度优先，返回第一个匹配的 id。 */
    public func elementById(id: String): ?SvgElement {
        findSvgElementById(this.root, id)
    }

    /** 根元素的 `baseProfile`；缺省 `None`。 */
    public func baseProfile(): ?String {
        this.root.attr("baseProfile")
    }

    /** 根元素的 `version`；缺省 `None`。 */
    public func version(): ?String {
        this.root.attr("version")
    }

    /** 根元素的 `zoomAndPan`；非法值 warning 后回退 `Disable`。 */
    public func zoomAndPan(): SvgZoomAndPan {
        match (this.root.attr("zoomAndPan")) {
            case Some(text) =>
                match (SvgZoomAndPan.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        let warning = "根元素 zoomAndPan 的值「${text}」不合法，已回退 disable"
                        if (!this.warnings.contains(warning)) {
                            this.warnings.add(warning)
                        }
                        SvgZoomAndPan.Disable
                }
            case None => SvgZoomAndPan.Disable
        }
    }

    /** 全部后代元素（不区分命名空间），不含根元素自身。 */
    public func elementsByTag(tag: String): ArrayList<SvgElement> {
        let result = ArrayList<SvgElement>()
        for (node in this.root.children) {
            match (node) {
                case ElementNode(child) => collectSvgElementsByTag(child, tag, result)
                case _ => ()
            }
        }
        result
    }

    /** 按文档顺序返回全部 `view` 元素。 */
    public func views(): ArrayList<SvgView> {
        let all = this.elementsByTag("view")
        let result = ArrayList<SvgView>()
        for (element in all) {
            match (element) {
                case view: SvgView => result.add(view)
                case _ => ()
            }
        }
        result
    }

    /** 按 id 返回第一个 `view`；不存在或类型不符返回 `None`。 */
    public func view(id: String): ?SvgView {
        match (this.elementById(id)) {
            case Some(element) =>
                match (element) {
                    case view: SvgView => Some(view)
                    case _ => None
                }
            case None => None
        }
    }

    /** 按文档顺序返回全部 `a` 链接信息。 */
    public func anchors(): ArrayList<SvgAnchorInfo> {
        let result = ArrayList<SvgAnchorInfo>()
        for (node in this.root.children) {
            match (node) {
                case ElementNode(child) => collectSvgAnchors(child, result)
                case _ => ()
            }
        }
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
        writeSvgString(this)
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

private func collectSvgAnchors(element: SvgElement, result: ArrayList<SvgAnchorInfo>): Unit {
    match (element) {
        case container: SvgContainer =>
            if (container.kind == SvgContainerKind.Anchor) {
                let href: ?String = match (readSvgHref(element)) {
                    case Some(value) =>
                        if (value.trimAscii().size > 0) {
                            Some(value)
                        } else {
                            None
                        }
                    case None => None
                }
                result.add(SvgAnchorInfo(element, href, element.attr("target") ?? ""))
            }
        case _ => ()
    }
    for (node in element.children) {
        match (node) {
            case ElementNode(child) => collectSvgAnchors(child, result)
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
