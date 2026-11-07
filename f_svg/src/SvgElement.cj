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
import std.sync.AtomicInt64
import fountain::f_base.*
import fountain::f_xml.*

/**
 * 类型化值的版本缓存。
 *
 * `attributes` 是唯一事实源；缓存只在 `attributesVersion` 未变时复用。
 */
internal class SvgValueCache<T> {
    private var version: Int64 = -1
    private var cached: ?T = None
    private var hasCached: Bool = false

    func get(version: Int64, compute: () -> ?T): ?T {
        if (!this.hasCached || this.version != version) {
            this.cached = compute()
            this.version = version
            this.hasCached = true
        }
        this.cached
    }
}

/**
 * SVG 元素基类。
 *
 * `attributes` 保存原始字符串与 `QName`，是唯一可写状态；类型化 getter 按需解析并按版本缓存。
 */
public open class SvgElement <: ToString {
    public let tag: String
    public let namespace: String
    public let attributes = ArrayList<SvgAttribute>()
    public let children = ArrayList<SvgNode>()
    public var parent: ?SvgElement = None

    /** 任何属性写入都会递增；类型化缓存据此整体失效。 */
    internal var attributesVersion: Int64 = 0

    private var transformCache: ?SvgValueCache<SvgTransform> = None

    /** 外部命名空间到前缀的稳定映射；同一 URI 复用，不同 URI 不冲突。 */
    private let namespacePrefixes = HashMap<String, String>()
    private var nextNamespaceOrdinal: Int64 = 1

    /** 原始限定名；未知元素用它保留前缀。 */
    internal var rawQName: ?QName = None

    /** 元素身份：用于 `==` 与 `elementPath()` 的兄弟定位。 */
    internal let identity: Int64

    public init(tag: String, namespace!: String = SvgNamespaces.SVG) {
        this.tag = tag
        this.namespace = namespace
        this.identity = SvgElement.nextIdentity.fetchAdd(1)
    }

    public operator func ==(that: SvgElement): Bool {
        this.identity == that.identity
    }

    public mut prop id: ?String {
        get() {
            this.attr("id")
        }
        set(value) {
            this.writeOptionalAttribute("id", value)
        }
    }

    /** `class` 属性。 */
    public mut prop className: ?String {
        get() {
            this.attr("class")
        }
        set(value) {
            this.writeOptionalAttribute("class", value)
        }
    }

    /** 原样保留，不解释 CSS。 */
    public mut prop style: ?String {
        get() {
            this.attr("style")
        }
        set(value) {
            this.writeOptionalAttribute("style", value)
        }
    }

    public mut prop transform: ?SvgTransform {
        get() {
            let cache = this.transformCacheOf()
            cache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("transform")) {
                        case Some(text) => parseTransformOrNone(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(transform) => this.setAttr("transform", transform.toString())
                case None => this.removeAttr("transform")
            }
        }
    }

    /** 按裸名读取属性（不带命名空间）。 */
    public func attr(name: String): ?String {
        let index = this.bareAttributeIndex(name)
        if (index >= 0) {
            return Some(this.attributes[index].value)
        }
        None
    }

    /** 按命名空间 + 本地名读取属性。 */
    public func attr(namespace: String, local: String): ?String {
        let index = this.namespacedAttributeIndex(namespace, local)
        if (index >= 0) {
            return Some(this.attributes[index].value)
        }
        None
    }

    /** 裸名写入；命中同名属性时原位替换，否则追加。 */
    public func setAttr(name: String, value: String): SvgElement {
        let index = this.bareAttributeIndex(name)
        if (index >= 0) {
            this.attributes[index] = SvgAttribute(this.attributes[index].name, value)
        } else {
            this.attributes.add(SvgAttribute(QName(name), value))
        }
        this.attributesVersion++
        this
    }

    /** 命名空间写入。`xlink` / `xml` 前缀固定，其余按 URI 稳定分配。 */
    public func setAttr(namespace: String, local: String, value: String): SvgElement {
        let index = this.namespacedAttributeIndex(namespace, local)
        if (index >= 0) {
            this.attributes[index] = SvgAttribute(this.attributes[index].name, value)
        } else {
            this.attributes.add(
                SvgAttribute(QName(local, prefix: Some(this.prefixFor(namespace)), uri: Some(namespace)), value)
            )
        }
        this.attributesVersion++
        this
    }

    /** 按命名空间 + 本地名删除属性。 */
    public func removeAttr(namespace: String, local: String): Bool {
        let index = this.namespacedAttributeIndex(namespace, local)
        if (index < 0) {
            return false
        }
        this.attributes.remove(at: index)
        this.attributesVersion++
        true
    }

    /** 原样追加 / 替换属性，保留 `QName` 的前缀与 URI。供解析器使用。 */
    internal func appendAttribute(name: QName, value: String): Unit {
        for (index in 0..this.attributes.size) {
            if (this.attributes[index].name == name) {
                this.attributes[index] = SvgAttribute(name, value)
                this.attributesVersion++
                return
            }
        }
        this.attributes.add(SvgAttribute(name, value))
        this.attributesVersion++
    }

    public func removeAttr(name: String): Bool {
        let index = this.bareAttributeIndex(name)
        if (index < 0) {
            return false
        }
        this.attributes.remove(at: index)
        this.attributesVersion++
        true
    }

    public func appendChild(node: SvgNode): SvgElement {
        this.children.add(node)
        match (node) {
            case ElementNode(element) => element.parent = this
            case _ => ()
        }
        this
    }

    public func appendElement(element: SvgElement): SvgElement {
        this.appendChild(SvgNode.ElementNode(element))
    }

    public func appendText(text: String): SvgElement {
        this.appendChild(SvgNode.TextNode(text))
    }

    public func child(tag: String): ?SvgElement {
        for (node in this.children) {
            match (node) {
                case ElementNode(element) => if (element.tag == tag) {
                    return Some(element)
                }
                case _ => ()
            }
        }
        None
    }

    public func childrenOf(tag: String): ArrayList<SvgElement> {
        let result = ArrayList<SvgElement>()
        for (node in this.children) {
            match (node) {
                case ElementNode(element) => if (element.tag == tag) {
                    result.add(element)
                }
                case _ => ()
            }
        }
        result
    }

    /** 拼接所有后代文本与 CDATA，不含注释与 PI。 */
    public func text(): String {
        let out = StringGenerator()
        collectText(this, out)
        out.toString()
    }

    /** 形如 `/svg[1]/g[2]/rect[1]`，序号是同名兄弟中的 1-based 位置。 */
    public func elementPath(): String {
        let index = this.siblingIndex()
        let segment = "/${this.tag}[${index}]"
        match (this.parent) {
            case Some(parent) => parent.elementPath() + segment
            case None => segment
        }
    }

    public func toXmlElement(): XmlElement {
        let uri: ?String = if (this.namespace.size == 0) {
            None
        } else {
            Some(this.namespace)
        }
        let element = match (this.rawQName) {
            case Some(qname) => XmlElement(qname)
            case None => XmlElement(QName(this.tag, uri: uri))
        }
        for (attribute in this.attributes) {
            element.attributes.add(XmlAttribute(attribute.name, attribute.value))
        }
        for (node in this.children) {
            match (node) {
                case ElementNode(child) => element.children.add(XmlNode.ElementNode(child.toXmlElement()))
                case TextNode(text) => element.children.add(XmlNode.TextNode(text))
                case CDataNode(text) => element.children.add(XmlNode.CDataNode(text))
                case CommentNode(text) => element.children.add(XmlNode.CommentNode(text))
                case PiNode(target, data) => element.children.add(XmlNode.PiNode(target, data))
            }
        }
        element
    }

    /** 紧凑序列化，不输出命名空间声明；完整输出走 `SvgWriter`。 */
    public func toString(): String {
        let literalName = match (this.rawQName) {
            case Some(qname) => qname.toString()
            case None => this.tag
        }
        let out = StringBuilder()
        out.append("<")
        out.append(literalName)
        for (attribute in this.attributes) {
            out.append(" ")
            out.append(attribute.name.toString())
            out.append("=\"")
            out.append(escapeSvgAttribute(attribute.value))
            out.append("\"")
        }
        if (this.children.size == 0) {
            out.append("/>")
        } else {
            out.append(">")
            for (node in this.children) {
                match (node) {
                    case ElementNode(element) => out.append(element.toString())
                    case TextNode(text) => out.append(escapeSvgText(text))
                    case CDataNode(text) => out.append(serializeSvgCData(text))
                    case CommentNode(text) => out.append(serializeSvgComment(text))
                    case PiNode(target, data) => out.append("<?${target} ${data}?>")
                }
            }
            out.append("</")
            out.append(literalName)
            out.append(">")
        }
        out.toString()
    }

    /**
     * 元素自身用户空间包围盒；定义型或几何无效元素返回 `None`。
     *
     * `mediaWidth` / `mediaHeight` 用于与渲染选项一致的 `@media` 与百分比几何求值。
     */
    public func getBBox(
        options!: SvgBBoxOptions = SvgBBoxOptions(),
        mediaWidth!: ?Float64 = None,
        mediaHeight!: ?Float64 = None
    ): ?SvgBounds {
        let width = mediaWidth ?? 300.0
        let height = mediaHeight ?? 150.0
        let styles = match (svgRootOf(this)) {
            case Some(root) => Some(
                SvgStyleResolver().compute(root, mediaWidth: width, mediaHeight: height)
            )
            case None => Option<SvgComputedStyleTree>.None
        }
        svgBBoxOf(
            this,
            SvgBBoxRequest(
                options,
                styles,
                viewportWidth: width,
                viewportHeight: height
            )
        )
    }

    /** 元素到根用户空间的矩阵；未挂载时为单位矩阵。 */
    public func getCTM(
        mediaWidth!: ?Float64 = None,
        mediaHeight!: ?Float64 = None
    ): SvgMatrix {
        svgElementCtm(this, mediaWidth: mediaWidth, mediaHeight: mediaHeight)
    }

    /** 元素到设备空间的矩阵；`viewport` 为空时按根尺寸与 DPR 1 构造。 */
    public func getScreenCTM(
        viewport!: ?SvgViewportTransform = None,
        mediaWidth!: ?Float64 = None,
        mediaHeight!: ?Float64 = None
    ): SvgMatrix {
        svgElementScreenCtm(
            this,
            viewport,
            mediaWidth: mediaWidth,
            mediaHeight: mediaHeight
        )
    }

    /** 后代中 `class` 含指定词的第一个集合（文档顺序，不含自身）。 */
    public func getElementsByClassName(name: String): ArrayList<SvgElement> {
        svgElementsByClassName(this, name)
    }

    /** 复用 M5 选择器引擎查询后代；非法选择器抛 `InvalidValue`。 */
    public func querySelectorAll(selector: String): ArrayList<SvgElement> {
        svgQuerySelectorAll(this, selector)
    }

    internal func writeOptionalAttribute(name: String, value: ?String): Unit {
        match (value) {
            case Some(text) => this.setAttr(name, text)
            case None => this.removeAttr(name)
        }
    }

    private func transformCacheOf(): SvgValueCache<SvgTransform> {
        match (this.transformCache) {
            case Some(cache) => cache
            case None =>
                let created = SvgValueCache<SvgTransform>()
                this.transformCache = Some(created)
                created
        }
    }

    private func bareAttributeIndex(name: String): Int64 {
        for (index in 0..this.attributes.size) {
            let attribute = this.attributes[index]
            if (attribute.name.local == name && attribute.name.uri.isNone()) {
                return index
            }
        }
        -1
    }

    private func namespacedAttributeIndex(namespace: String, local: String): Int64 {
        for (index in 0..this.attributes.size) {
            let attribute = this.attributes[index]
            if (attribute.name.local == local) {
                match (attribute.name.uri) {
                    case Some(uri) => if (uri == namespace) {
                        return index
                    }
                    case None => ()
                }
            }
        }
        -1
    }

    /** 同一 URI 复用前缀；新 URI 分配 `ns1`、`ns2`… 并跳过已占用前缀。 */
    private func prefixFor(namespace: String): String {
        if (namespace == SvgNamespaces.XLINK) {
            return "xlink"
        }
        if (namespace == SvgNamespaces.XML) {
            return "xml"
        }
        match (this.namespacePrefixes.get(namespace)) {
            case Some(prefix) => return prefix
            case None => ()
        }
        for (attribute in this.attributes) {
            if (attribute.name.uri == Some(namespace)) {
                match (attribute.name.prefix) {
                    case Some(prefix) =>
                        this.namespacePrefixes[namespace] = prefix
                        return prefix
                    case None => ()
                }
            }
        }
        var candidate = ""
        while (true) {
            candidate = "ns" + this.nextNamespaceOrdinal.toString()
            this.nextNamespaceOrdinal++
            if (!this.prefixInUse(candidate)) {
                break
            }
        }
        this.namespacePrefixes[namespace] = candidate
        candidate
    }

    private func prefixInUse(prefix: String): Bool {
        for (attribute in this.attributes) {
            match (attribute.name.prefix) {
                case Some(existing) => if (existing == prefix) {
                    return true
                }
                case None => ()
            }
        }
        for ((_, used) in this.namespacePrefixes) {
            if (used == prefix) {
                return true
            }
        }
        false
    }

    private func siblingIndex(): Int64 {
        match (this.parent) {
            case None => 1
            case Some(parent) =>
                var position = 0
                for (node in parent.children) {
                    match (node) {
                        case ElementNode(element) =>
                            if (element.tag == this.tag) {
                                position++
                                if (element == this) {
                                    return position
                                }
                            }
                        case _ => ()
                    }
                }
                position
        }
    }

    private static let nextIdentity = AtomicInt64(1)

    private static func collectText(element: SvgElement, out: StringGenerator): Unit {
        for (node in element.children) {
            match (node) {
                case TextNode(text) => out.append<String>(text)
                case CDataNode(text) => out.append<String>(text)
                case ElementNode(child) => collectText(child, out)
                case _ => ()
            }
        }
    }
}

private func parseTransformOrNone(text: String): ?SvgTransform {
    try {
        Some(SvgTransform.parse(text))
    } catch (_: SvgException) {
        None
    }
}

/** `href` 读取：优先无前缀，其次 `xlink:href`。 */
internal func readSvgHref(element: SvgElement): ?String {
    match (element.attr("href")) {
        case Some(value) => Some(value)
        case None => element.attr(SvgNamespaces.XLINK, "href")
    }
}

/** `href` 写入：默认写 `xlink:href`，同时清掉裸名，避免双份。 */
internal func writeSvgHref(element: SvgElement, value: ?String): Unit {
    match (value) {
        case Some(href) =>
            element.removeAttr("href")
            element.setAttr(SvgNamespaces.XLINK, "href", href)
        case None =>
            element.removeAttr("href")
            element.removeAttr(SvgNamespaces.XLINK, "href")
    }
}

/** CDATA 中出现 `]]>` 时拆成两段，保证输出仍是合法 XML。 */
internal func serializeSvgCData(text: String): String {
    let runes = ArrayList<Rune>()
    for (rune in text.runes()) {
        runes.add(rune)
    }
    let out = StringBuilder()
    out.append("<![CDATA[")
    var index = 0
    while (index < runes.size) {
        if (runes[index] == r']' && index + 2 < runes.size && runes[index + 1] == r']' &&
            runes[index + 2] == r'>') {
            out.append("]]]]><![CDATA[>")
            index += 3
        } else {
            out.append(runes[index])
            index++
        }
    }
    out.append("]]>")
    out.toString()
}

/** 注释中的 `--` 与结尾 `-` 会破坏 XML，插入空格规避。 */
internal func serializeSvgComment(text: String): String {
    let out = StringBuilder()
    var previousDash = false
    for (rune in text.runes()) {
        if (previousDash && rune == r'-') {
            out.append(" ")
        }
        out.append(rune)
        previousDash = rune == r'-'
    }
    var body = out.toString()
    if (body.endsWith("-")) {
        body += " "
    }
    "<!--" + body + "-->"
}

internal func escapeSvgText(text: String): String {
    let out = StringBuilder()
    for (rune in text.runes()) {
        match (rune) {
            case r'&' => out.append("&amp;")
            case r'<' => out.append("&lt;")
            case r'>' => out.append("&gt;")
            case _ => out.append(rune)
        }
    }
    out.toString()
}

internal func escapeSvgAttribute(text: String): String {
    let out = StringBuilder()
    for (rune in text.runes()) {
        match (rune) {
            case r'&' => out.append("&amp;")
            case r'<' => out.append("&lt;")
            case r'>' => out.append("&gt;")
            case r'"' => out.append("&quot;")
            case _ => out.append(rune)
        }
    }
    out.toString()
}

/** 写入 / 替换内联样式中的单个声明，保留其他声明。 */
public func svgSetInlineStyleProperty(element: SvgElement, name: String, value: String): Unit {
    let target = name.trimAscii().toAsciiLower()
    let kept = ArrayList<String>()
    match (element.style) {
        case Some(text) =>
            for (declaration in text.split(";")) {
                let trimmed = declaration.trimAscii()
                if (trimmed.size == 0) {
                    continue
                }
                let colon = findSvgStyleColon(trimmed)
                if (colon < 0) {
                    kept.add(trimmed)
                    continue
                }
                let property = trimmed[0..colon].trimAscii().toAsciiLower()
                if (property != target) {
                    kept.add(trimmed)
                }
            }
        case None => ()
    }
    kept.add(target + ": " + value)
    element.style = joinCssStrings(kept, "; ")
}

private func findSvgStyleColon(text: String): Int64 {
    let bytes = text.unsafeBytes()
    for (index in 0..bytes.size) {
        if (bytes[index] == b':') {
            return index
        }
    }
    -1
}
