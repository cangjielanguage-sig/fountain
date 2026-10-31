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
 * DOM 节点。
 *
 * 保持 enum（而不是类继承）：穷尽 `match` 可用，且调用方无法注入任意节点类型。
 * 保留注释 / PI 节点是为了 M3 的 C14N `withComments`，M1 只是不忽略它们。
 */
public enum XmlNode <: ToString {
    | ElementNode(XmlElement)
    | TextNode(String)
    | CDataNode(String)
    | CommentNode(String)
    | PiNode(String, String)
    | EntityRefNode(String)

    public func toString(): String {
        match (this) {
            case ElementNode(e) => e.toString()
            case TextNode(t) => t
            case CDataNode(t) => "<![CDATA[${t}]]>"
            case CommentNode(t) => "<!--${t}-->"
            case PiNode(target, data) => "<?${target} ${data}?>"
            case EntityRefNode(name) => "&${name};"
        }
    }
}

/**
 * 显式实体引用节点的工厂。
 *
 * 仓颉不允许类继承 enum，所以这里只能是函数，不能是 `class XmlEntityRef <: XmlNode`。
 * 写侧只有显式构造的实体引用才会输出 `&name;`（解出来的文本不会）。
 */
public func XmlEntityRef(name: String): XmlNode {
    XmlNode.EntityRefNode(name)
}

/** XML 声明。 */
public class XmlDeclaration <: ToString {
    public let version: String
    public let encoding: ?String
    public let standalone: ?Bool

    public init(version: String, encoding!: ?String = None, standalone!: ?Bool = None) {
        this.version = version
        this.encoding = encoding
        this.standalone = standalone
    }

    public func toString(): String {
        var text = "<?xml version=\"${this.version}\""
        if (let Some(enc) <- this.encoding) {
            text += " encoding=\"${enc}\""
        }
        if (let Some(sa) <- this.standalone) {
            text += " standalone=\"${if (sa) { "yes" } else { "no" }}\""
        }
        text + "?>"
    }
}

/** 一个 DTD 实体声明。 */
public class EntityDecl <: ToString {
    public let name: String
    /** 内部实体有值；外部实体为 `None`。 */
    public let value: ?String
    public let publicId: ?String
    public let systemId: ?String
    /** 参数实体（`<!ENTITY % name ...>`）。 */
    public let parameter: Bool

    public init(
        name: String,
        value!: ?String = None,
        publicId!: ?String = None,
        systemId!: ?String = None,
        parameter!: Bool = false
    ) {
        this.name = name
        this.value = value
        this.publicId = publicId
        this.systemId = systemId
        this.parameter = parameter
    }

    /** 外部实体：声明可识别，引用即报错，永不加载。 */
    public func isExternal(): Bool {
        this.value.isNone()
    }

    public func toString(): String {
        match (this.value) {
            case Some(v) => "<!ENTITY ${if (this.parameter) { "% " } else { "" }}${this.name} \"${v}\">"
            case None =>
                "<!ENTITY ${if (this.parameter) { "% " } else { "" }}${this.name} SYSTEM \"${this.systemId ?? ""}\">"
        }
    }
}

/** DOCTYPE 信息（含内部子集的实体声明，按声明顺序）。 */
public class DocTypeInfo <: ToString {
    public let name: String
    public let publicId: ?String
    public let systemId: ?String
    public var entities: Array<EntityDecl>

    public init(
        name: String,
        publicId!: ?String = None,
        systemId!: ?String = None,
        entities!: Array<EntityDecl> = Array<EntityDecl>()
    ) {
        this.name = name
        this.publicId = publicId
        this.systemId = systemId
        this.entities = entities
    }

    public func toString(): String {
        "<!DOCTYPE ${this.name}>"
    }
}

/**
 * 元素：可变结构，属性与子节点都是有序列表。
 *
 * 便捷查询一律按 **local name** 匹配（`<x:item>` 与 `<item>` 都能命中）。
 */
public class XmlElement <: ToString {
    public let name: QName
    public let attributes = ArrayList<XmlAttribute>()
    public let children = ArrayList<XmlNode>()

    public init(name: QName) {
        this.name = name
    }

    public init(name: String) {
        this.name = QName(name)
    }

    /** 同名（local name）属性覆盖，不新增。 */
    public func setAttr(name: String, value: String): Unit {
        for (i in 0..this.attributes.size) {
            if (this.attributes[i].name.local == name) {
                this.attributes[i] = XmlAttribute(QName(name, uri: this.attributes[i].name.uri), value)
                return
            }
        }
        this.attributes.add(XmlAttribute(QName(name), value))
    }

    public func appendChild(node: XmlNode): XmlElement {
        this.children.add(node)
        this
    }

    public func withText(text: String): XmlElement {
        this.children.add(XmlNode.TextNode(text))
        this
    }

    /** 按 local name 取属性值（第一个命中）。 */
    public func attr(name: String): ?String {
        for (attribute in this.attributes) {
            if (attribute.name.local == name) {
                return Some(attribute.value)
            }
        }
        None
    }

    /** 按命名空间 + local name 精确取属性值。 */
    public func attr(ns: String, local: String): ?String {
        for (attribute in this.attributes) {
            if (attribute.name.local == local) {
                match (attribute.name.uri) {
                    case Some(uri) => if (uri == ns) {
                        return Some(attribute.value)
                    }
                    case None => ()
                }
            }
        }
        None
    }

    /** 第一个 local name 匹配的子元素。 */
    public func child(name: String): ?XmlElement {
        for (node in this.children) {
            match (node) {
                case XmlNode.ElementNode(e) => if (e.name.local == name) {
                    return Some(e)
                }
                case _ => ()
            }
        }
        None
    }

    public func childrenOf(name: String): ArrayList<XmlElement> {
        let list = ArrayList<XmlElement>()
        for (node in this.children) {
            match (node) {
                case XmlNode.ElementNode(e) => if (e.name.local == name) {
                    list.add(e)
                }
                case _ => ()
            }
        }
        list
    }

    /** 拼接所有后代文本（含 CDATA），不含注释与 PI。 */
    public func text(): String {
        let out = StringGenerator()
        collectText(this, out)
        out.toString()
    }

    private static func collectText(element: XmlElement, out: StringGenerator): Unit {
        for (node in element.children) {
            match (node) {
                case XmlNode.TextNode(t) => out.append<String>(t)
                case XmlNode.CDataNode(t) => out.append<String>(t)
                case XmlNode.ElementNode(e) => collectText(e, out)
                case _ => ()
            }
        }
    }

    public func toString(): String {
        let out = StringGenerator()
        out.append<String>("<")
        out.append<String>(this.name.toString())
        for (attribute in this.attributes) {
            out.append<String>(" ")
            out.append<String>(attribute.toString())
        }
        out.append<String>(">")
        for (node in this.children) {
            out.append<String>(node.toString())
        }
        out.append<String>("</")
        out.append<String>(this.name.toString())
        out.append<String>(">")
        out.toString()
    }
}

/**
 * 一份解析完成的文档。
 *
 * **不暴露 `DomBuilder`**：建成后 builder 的栈已空，外露只会诱导「继续往文档里追加」
 * 这种没有语义的操作。
 */
public class XmlDocument <: ToString {
    public var root: ?XmlElement = None
    public var declaration: ?XmlDeclaration = None
    public var doctype: ?DocTypeInfo = None
    /** 根元素之前的注释 / PI。 */
    public let prolog = ArrayList<XmlNode>()
    /** 根元素之后的注释 / PI。 */
    public let epilog = ArrayList<XmlNode>()

    public init() {}

    public func toString(): String {
        let out = StringGenerator()
        if (let Some(decl) <- this.declaration) {
            out.append<String>(decl.toString())
        }
        if (let Some(dt) <- this.doctype) {
            out.append<String>(dt.toString())
        }
        for (node in this.prolog) {
            out.append<String>(node.toString())
        }
        if (let Some(r) <- this.root) {
            out.append<String>(r.toString())
        }
        for (node in this.epilog) {
            out.append<String>(node.toString())
        }
        out.toString()
    }
}
