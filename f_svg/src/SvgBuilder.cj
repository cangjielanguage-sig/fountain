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

/** 构建期间的可变状态。 */
internal class SvgBuildContext {
    let options: SvgParseOptions
    let warnings = ArrayList<String>()
    var elementCount: Int64 = 0

    init(options: SvgParseOptions) {
        this.options = options
    }
}

/** 把 `f_xml` DOM 构造成 `SvgDocument`。 */
internal func buildSvgDocument(xml: XmlDocument, options: SvgParseOptions): SvgDocument {
    let rootXml = match (xml.root) {
        case Some(root) => root
        case None => throw syntaxError("文档缺少根元素")
    }
    if (rootXml.name.local != "svg") {
        throw syntaxError("根元素必须是 svg，实际为「${rootXml.name.local}」")
    }
    match (rootXml.name.uri) {
        case Some(uri) => if (uri != SvgNamespaces.SVG) {
            throw syntaxError("根元素必须位于 SVG 命名空间或无命名空间，实际为「${uri}」")
        }
        case None => ()
    }

    if (countXmlElements(rootXml) > options.security.maxElements) {
        throw limitError("元素数超过上限 ${options.security.maxElements}")
    }
    checkDepth(rootXml, 1, options.security.maxDepth)

    let context = SvgBuildContext(options)
    let root = SvgRoot()
    context.elementCount = 1
    let rootPath = "/svg[1]"
    fillSvgAttributes(root, rootXml, rootPath, context)
    buildSvgChildren(root, rootXml, SvgNamespaces.SVG, "/svg[1]", 1, context)

    let document = SvgDocument(root)
    document.declaration = xml.declaration
    document.doctype = xml.doctype
    for (node in xml.prolog) {
        match (miscSvgNode(node)) {
            case Some(misc) => document.prolog.add(misc)
            case None => ()
        }
    }
    for (node in xml.epilog) {
        match (miscSvgNode(node)) {
            case Some(misc) => document.epilog.add(misc)
            case None => ()
        }
    }
    for (warning in context.warnings) {
        document.warnings.add(warning)
    }
    document
}

/** 递归构建子节点；深度与总量在进入前已由迭代检查拦截。 */
private func buildSvgChildren(
    parent: SvgElement,
    xml: XmlElement,
    parentNamespace: String,
    parentPath: String,
    depth: Int64,
    context: SvgBuildContext
): Unit {
    let counters = HashMap<String, Int64>()
    for (node in xml.children) {
        match (node) {
            case XmlNode.ElementNode(childXml) =>
                let tag = childXml.name.local
                let previous = counters.get(tag) ?? 0
                let index = previous + 1
                counters[tag] = index
                let path = parentPath + "/" + tag + "[" + index.toString() + "]"
                let namespace = namespaceOf(childXml, parentNamespace)
                match (buildSvgOne(childXml, namespace, path, depth + 1, context)) {
                    case Some(child) => parent.appendElement(child)
                    case None => ()
                }
            case XmlNode.TextNode(text) => appendTextNode(parent, text)
            case XmlNode.CDataNode(text) => parent.appendChild(SvgNode.CDataNode(text))
            case XmlNode.CommentNode(text) => parent.appendChild(SvgNode.CommentNode(text))
            case XmlNode.PiNode(target, data) => parent.appendChild(SvgNode.PiNode(target, data))
            case XmlNode.EntityRefNode(_) => ()
        }
    }
}

/** 只构建当前元素本身（属性 + 安全过滤 + 严格校验），不递归子节点。 */
private func buildSvgOne(
    xml: XmlElement,
    namespace: String,
    path: String,
    depth: Int64,
    context: SvgBuildContext
): ?SvgElement {
    context.elementCount++
    if (context.elementCount > context.options.security.maxElements) {
        throw limitError("元素数超过上限 ${context.options.security.maxElements}")
    }
    if (depth > context.options.security.maxDepth) {
        throw limitError("元素深度超过上限 ${context.options.security.maxDepth}")
    }

    let local = xml.name.local
    let rawName = QName(local, prefix: xml.name.prefix, uri: Some(namespace))

    if (namespace == SvgNamespaces.SVG && local == "script") {
        if (!context.options.security.allowScript) {
            match (context.options.security.unsafePolicy) {
                case SvgUnsafePolicy.Reject =>
                    throw SvgException("不允许脚本元素", 0, 0, kind: SvgErrorKind.Security, elementPath: Some(path))
                case SvgUnsafePolicy.Remove =>
                    context.warnings.add("已移除不安全元素 script（${path}）")
                    return None
                case SvgUnsafePolicy.Keep => ()
            }
        }
        let element = SvgUnknownElement(rawName)
        fillSvgAttributes(element, xml, path, context)
        buildSvgChildren(element, xml, namespace, path, depth, context)
        return Some(element)
    }

    let element: SvgElement
    if (namespace == SvgNamespaces.SVG && SvgTag.isKnown(local)) {
        element = match (SvgTag.create(local)) {
            case Some(created) => created
            case None => SvgUnknownElement(rawName)
        }
    } else if (namespace == SvgNamespaces.SVG) {
        if (context.options.strict) {
            throw SvgException(
                "不支持的 SVG 标签「${local}」",
                0,
                0,
                kind: SvgErrorKind.Unsupported,
                elementPath: Some(path)
            )
        }
        context.warnings.add("未知标签 ${local}（${path}）")
        element = SvgUnknownElement(rawName)
    } else {
        element = SvgUnknownElement(rawName)
    }

    fillSvgAttributes(element, xml, path, context)
    if (context.options.strict && namespace == SvgNamespaces.SVG) {
        checkRequiredAttributes(local, xml, path)
    }
    buildSvgChildren(element, xml, namespace, path, depth, context)
    Some(element)
}

/** 相邻文本节点合并：序列化无法保留文本节点边界，合并后往返才稳定。 */
private func appendTextNode(parent: SvgElement, text: String): Unit {
    if (parent.children.size > 0) {
        let lastIndex = parent.children.size - 1
        match (parent.children[lastIndex]) {
            case SvgNode.TextNode(previous) =>
                parent.children[lastIndex] = SvgNode.TextNode(previous + text)
                return
            case _ => ()
        }
    }
    parent.appendChild(SvgNode.TextNode(text))
}

private func namespaceOf(xml: XmlElement, parentNamespace: String): String {
    match (xml.name.uri) {
        case Some(uri) => uri
        case None => parentNamespace
    }
}

private func fillSvgAttributes(
    element: SvgElement,
    xml: XmlElement,
    path: String,
    context: SvgBuildContext
): Unit {
    for (attribute in xml.attributes) {
        if (isXmlnsDeclaration(attribute.name)) {
            continue
        }
        if (shouldRemoveAttribute(attribute, path, context)) {
            continue
        }
        validateSvgAttribute(attribute, path, context)
        if (attribute.name.local == "offset") {
            warnOffsetIfClamped(attribute.value, path, context)
        }
        element.appendAttribute(attribute.name, attribute.value)
    }
}

private func isXmlnsDeclaration(name: QName): Bool {
    if (name.local == "xmlns") {
        return true
    }
    match (name.prefix) {
        case Some(prefix) => prefix == "xmlns"
        case None => false
    }
}

private func shouldRemoveAttribute(attribute: XmlAttribute, path: String, context: SvgBuildContext): Bool {
    let local = attribute.name.local
    let security = context.options.security
    if (attribute.name.uri.isNone() && local.size > 2 && local[0..2].toAsciiLower() == "on") {
        if (security.allowEventAttributes) {
            return false
        }
        return applyUnsafePolicy("事件属性 ${local}", path, context)
    }
    if (local == "href") {
        return handleHrefValue(attribute.value, path, context)
    }
    false
}

private func handleHrefValue(value: String, path: String, context: SvgBuildContext): Bool {
    let trimmed = value.trimAscii()
    let lower = trimmed.toAsciiLower()
    if (trimmed.size > 0 && trimmed[0] == b'#') {
        return false
    }
    let allowed = if (lower.size >= 5 && lower[0..5] == "data:") {
        context.options.security.allowDataImages
    } else {
        context.options.security.allowExternalReferences
    }
    if (allowed) {
        return false
    }
    if (context.options.strict) {
        throw SvgException("不允许外部引用「${trimmed}」", 0, 0, kind: SvgErrorKind.Security, elementPath: Some(path))
    }
    applyUnsafePolicy("外部引用 ${trimmed}", path, context)
}

private func applyUnsafePolicy(what: String, path: String, context: SvgBuildContext): Bool {
    match (context.options.security.unsafePolicy) {
        case SvgUnsafePolicy.Reject =>
            throw SvgException("不允许${what}", 0, 0, kind: SvgErrorKind.Security, elementPath: Some(path))
        case SvgUnsafePolicy.Remove =>
            context.warnings.add("已移除${what}（${path}）")
            true
        case SvgUnsafePolicy.Keep => false
    }
}

/** `offset` 归一后越界必须钳制并记 warning（不做严格模式报错）。 */
private func warnOffsetIfClamped(value: String, path: String, context: SvgBuildContext): Unit {
    let trimmed = value.trimAscii()
    if (trimmed.size == 0) {
        return
    }
    var body = trimmed
    var percent = false
    if (trimmed[trimmed.size - 1] == b'%') {
        percent = true
        body = trimmed[0..trimmed.size - 1]
    }
    match (tryParseSvgFloat(body)) {
        case Some(number) =>
            let raw = if (percent) {
                number / 100.0
            } else {
                number
            }
            if (raw < 0.0 || raw > 1.0) {
                context.warnings.add("属性「offset」的值「${value}」超出 0..1，已钳制（${path}）")
            }
        case None => ()
    }
}

private func validateSvgAttribute(attribute: XmlAttribute, path: String, context: SvgBuildContext): Unit {
    if (isValidSvgAttribute(attribute.name.local, attribute.value)) {
        return
    }
    let message = "属性「${attribute.name.local}」的值「${attribute.value}」不合法"
    if (context.options.strict) {
        throw SvgException(message, 0, 0, kind: SvgErrorKind.InvalidValue, elementPath: Some(path))
    }
    context.warnings.add("${message}（${path}）")
}

private func isValidSvgAttribute(local: String, value: String): Bool {
    match (local) {
        case "fill" | "stroke" => tryParseSvgPaint(value).isSome()
        case "color" | "stop-color" =>
            value.trimAscii().toAsciiLower() == "currentcolor" ||
            SvgColor.tryParse(value).isSome() ||
            value.trimAscii().toAsciiLower() == "none"
        case "transform" | "gradientTransform" => tryParseSvgTransform(value).isSome()
        case "viewBox" => tryParseSvgViewBox(value).isSome()
        case "preserveAspectRatio" => tryParseSvgPreserveAspectRatio(value).isSome()
        case "points" => tryParseSvgPointList(value).isSome()
        case "d" => SvgPathData.tryParse(value).isSome()
        case "stroke-dasharray" =>
            value.trimAscii().toAsciiLower() == "none" || parseSvgLengthList(value).isSome()
        case "x" | "y" | "dx" | "dy" => parseSvgLengthList(value).isSome()
        case "width" | "height" | "x1" | "y1" | "x2" | "y2" | "cx" | "cy" | "r" | "rx" | "ry" |
            "stroke-width" | "stroke-dashoffset" | "font-size" | "letter-spacing" | "word-spacing" |
            "textLength" | "startOffset" => SvgLength.tryParse(value).isSome()
        case "opacity" | "fill-opacity" | "stroke-opacity" | "stroke-miterlimit" | "stop-opacity" =>
            tryParseSvgFloat(value).isSome()
        case "offset" => tryParseSvgOffset(value).isSome()
        case "fill-rule" => SvgFillRule.fromName(value.trimAscii().toAsciiLower()).isSome()
        case "stroke-linecap" => SvgLineCap.fromName(value.trimAscii().toAsciiLower()).isSome()
        case "stroke-linejoin" => SvgLineJoin.fromName(value.trimAscii().toAsciiLower()).isSome()
        case "text-anchor" => SvgTextAnchor.fromName(value.trimAscii()).isSome()
        case "lengthAdjust" => SvgLengthAdjust.fromName(value.trimAscii()).isSome()
        case "gradientUnits" => SvgCoordinateUnits.fromName(value.trimAscii()).isSome()
        case "spreadMethod" => SvgSpreadMethod.fromName(value.trimAscii()).isSome()
        case _ => true
    }
}

private func checkRequiredAttributes(tag: String, xml: XmlElement, path: String): Unit {
    let required: Array<String> = match (tag) {
        case "rect" => ["width", "height"]
        case "circle" => ["r"]
        case "ellipse" => ["rx", "ry"]
        case "path" => ["d"]
        case "polyline" | "polygon" => ["points"]
        case _ => Array<String>()
    }
    for (name in required) {
        if (xml.attr(name).isNone()) {
            throw SvgException(
                "元素「${tag}」缺少必需属性「${name}」",
                0,
                0,
                kind: SvgErrorKind.InvalidValue,
                elementPath: Some(path)
            )
        }
    }
}

private func miscSvgNode(node: XmlNode): ?SvgNode {
    match (node) {
        case XmlNode.CommentNode(text) => Some(SvgNode.CommentNode(text))
        case XmlNode.PiNode(target, data) => Some(SvgNode.PiNode(target, data))
        case XmlNode.TextNode(text) => Some(SvgNode.TextNode(text))
        case _ => None
    }
}

/** 迭代统计元素数：不递归、不构造模型。 */
private func countXmlElements(root: XmlElement): Int64 {
    let queue = ArrayList<XmlElement>()
    queue.add(root)
    var position = 0
    var count = 0
    while (position < queue.size) {
        let element = queue[position]
        position++
        count++
        for (node in element.children) {
            match (node) {
                case XmlNode.ElementNode(child) => queue.add(child)
                case _ => ()
            }
        }
    }
    count
}

private class SvgDepthEntry {
    let element: XmlElement
    let depth: Int64

    init(element: XmlElement, depth: Int64) {
        this.element = element
        this.depth = depth
    }
}

/** 迭代检查深度，避免深文档在构建前就爆栈。 */
private func checkDepth(root: XmlElement, rootDepth: Int64, maxDepth: Int64): Unit {
    let queue = ArrayList<SvgDepthEntry>()
    queue.add(SvgDepthEntry(root, rootDepth))
    var position = 0
    while (position < queue.size) {
        let entry = queue[position]
        position++
        if (entry.depth > maxDepth) {
            throw limitError("元素深度超过上限 ${maxDepth}")
        }
        for (node in entry.element.children) {
            match (node) {
                case XmlNode.ElementNode(child) => queue.add(SvgDepthEntry(child, entry.depth + 1))
                case _ => ()
            }
        }
    }
}

private func limitError(message: String): SvgException {
    SvgException(message, kind: SvgErrorKind.Limit)
}
