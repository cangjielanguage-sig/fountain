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

/**
 * 状态机 + 名称栈 + 命名空间 + 实体展开。
 *
 * 只回答「当前位置允许出现什么」；元素配对靠名称栈（按展开名比较，不按字面名）。
 * 一次 `nextEvent()` 可能先消费若干不产事件的令牌（实体引用、空白），再产出一条事件。
 */
internal class ParserEngine {
    private let lexer: Lexer
    private let options: XmlParserOptions
    private let ns = NamespaceScope()
    private let stack = ArrayList<QName>()
    private let pending = ArrayList<XmlEvent>()

    private var state = ParserState.Prolog
    private var emittedStartDocument = false
    private var finished = false
    private var firstThing = true
    private var sawDeclaration = false
    private var sawDoctype = false
    private var sawRoot = false

    private var canSkip = false
    private var skipIsNoop = false
    private var lastStart: ?RawName = None
    private var lastStartName: ?QName = None

    private var entityTable = EntityTable(1024)
    private var expandedTotal: Int64 = 0

    init(window: LineWindow, options: XmlParserOptions) {
        this.options = options
        this.lexer = Lexer(window, limits: options.entityLimits)
        this.lexer.maxAttributeValueLength = options.maxAttributeValueLength
        this.entityTable = EntityTable(options.entityLimits.maxDeclarations)
        this.lexer.entityTable = this.entityTable
    }

    func totalExpanded(): Int64 {
        this.expandedTotal
    }

    /** DOCTYPE 内部子集里的实体声明（按声明顺序）。 */
    func doctypeEntities(): Array<EntityDecl> {
        this.entityTable.declarations()
    }

    // ---------------------------------------------------------------- 对外

    func nextEvent(): ?XmlEvent {
        if (this.pending.size > 0) {
            return Some(this.pending.remove(at: 0))
        }
        if (!this.emittedStartDocument) {
            this.emittedStartDocument = true
            return Some(XmlEvent.StartDocument)
        }
        if (this.finished) {
            return None
        }
        var result: ?XmlEvent = None
        var done = false
        while (!done) {
            match (this.step()) {
                case Some(e) =>
                    result = Some(e)
                    done = true
                case None => ()
            }
        }
        result
    }

    /** 消费一个令牌；产生事件则返回，不产生则返回 `None`。 */
    private func step(): ?XmlEvent {
        this.canSkip = false
        let token = this.lexer.nextToken(this.state)
        match (token) {
            case Token.TEof => this.handleEof()
            case Token.TText(text) => this.handleText(text)
            case Token.TComment(text) =>
                this.firstThing = false
                this.emitMisc(XmlEvent.Comment(text))
            case Token.TPi(target, data) =>
                this.firstThing = false
                this.emitMisc(XmlEvent.ProcessingInstruction(target, data))
            case Token.TDecl(version, encoding, standalone) => this.handleDeclaration(version, encoding, standalone)
            case Token.TDoctype(name, publicId, systemId, subset) =>
                this.handleDoctype(name, publicId, systemId, subset)
            case Token.TStartTag(name, attrs, selfClosing) =>
                if (this.state == ParserState.Epilog) {
                    throw XmlException("文档只能有一个根元素", name.line, name.column)
                }
                this.openElement(name, attrs, selfClosing)
            case Token.TEndTag(name) => this.closeElement(name)
            case Token.TCData(text) =>
                if (this.state != ParserState.Content) {
                    throw XmlException("CDATA 只能出现在元素内容里")
                }
                this.firstThing = false
                Some(XmlEvent.CData(text))
            case Token.TEntityRef(name, line, column) => this.expandEntity(name, line, column)
        }
    }

    private func handleEof(): ?XmlEvent {
        match (this.state) {
            case ParserState.Prolog => throw XmlException("文档没有根元素")
            case ParserState.Content => throw XmlException("文档在元素中间结束")
            case ParserState.Epilog =>
                this.finished = true
                Some(XmlEvent.EndDocument)
        }
    }

    private func handleText(text: String): ?XmlEvent {
        match (this.state) {
            case ParserState.Content =>
                this.firstThing = false
                Some(XmlEvent.Text(text))
            case ParserState.Prolog | ParserState.Epilog =>
                if (!isWhitespaceOnly(text)) {
                    let message = if (this.state == ParserState.Prolog) {
                        "根元素之前不允许出现文本"
                    } else {
                        "根元素之后不允许出现文本"
                    }
                    throw XmlException(message, this.lexer.position().line, this.lexer.position().column)
                }
                None
        }
    }

    private func emitMisc(event: XmlEvent): ?XmlEvent {
        match (this.state) {
            case ParserState.Content => Some(event)
            case ParserState.Prolog | ParserState.Epilog => Some(event)
        }
    }

    private func handleDeclaration(version: String, encoding: ?String, standalone: ?Bool): ?XmlEvent {
        if (this.sawDeclaration) {
            throw XmlException("XML 声明只能出现一次")
        }
        if (!this.firstThing) {
            throw XmlException("XML 声明必须出现在文档最前面")
        }
        this.sawDeclaration = true
        this.firstThing = false
        Some(XmlEvent.XmlDeclaration(version, encoding, standalone))
    }

    private func handleDoctype(name: String, publicId: ?String, systemId: ?String, subset: ?String): ?XmlEvent {
        if (this.sawDoctype) {
            throw XmlException("DOCTYPE 只能出现一次")
        }
        if (this.state != ParserState.Prolog) {
            throw XmlException("DOCTYPE 只能出现在根元素之前")
        }
        this.sawDoctype = true
        this.firstThing = false
        if (let Some(text) <- subset) {
            this.entityTable = DoctypeParser.parse(text, this.options.entityLimits)
            this.lexer.entityTable = this.entityTable
        }
        Some(XmlEvent.DocType(name, publicId, systemId))
    }

    // ---------------------------------------------------------------- 元素

    private func openElement(raw: RawName, attrs: ArrayList<RawAttribute>, selfClosing: Bool): ?XmlEvent {
        if (this.stack.size + 1 > this.options.maxElementDepth) {
            throw XmlException(
                "元素嵌套深度超过上限 ${this.options.maxElementDepth}",
                raw.line,
                raw.column
            )
        }
        this.ns.push()
        // 第一遍：登记本元素的命名空间声明（声明对元素名与属性名同时生效）。
        for (attribute in attrs) {
            this.declareNamespace(attribute)
        }
        let name = this.resolveElementName(raw)
        let resolved = ArrayList<XmlAttribute>()
        let seen = ArrayList<QName>()
        for (attribute in attrs) {
            if (this.isNamespaceDeclaration(attribute.name)) {
                continue
            }
            let attrName = this.resolveAttributeName(attribute.name)
            for (existing in seen) {
                if (existing == attrName) {
                    throw XmlException("重复的属性「${attrName}」", attribute.name.line, attribute.name.column)
                }
            }
            seen.add(attrName)
            if (attribute.value.size > this.options.maxAttributeValueLength) {
                throw XmlException(
                    "属性「${attrName.local}」的值长度 ${attribute.value.size} 超过上限 ${this.options.maxAttributeValueLength}",
                    attribute.name.line,
                    attribute.name.column
                )
            }
            resolved.add(XmlAttribute(attrName, attribute.value))
        }
        this.pending.add(XmlEvent.StartElement(name, resolved.toArray(), selfClosing))
        if (selfClosing) {
            this.ns.pop()
            this.pending.add(XmlEvent.EndElement(name))
            this.canSkip = true
            this.skipIsNoop = true
            this.lastStart = raw
            this.lastStartName = Some(name)
            if (this.state == ParserState.Prolog) {
                this.state = ParserState.Epilog
                this.sawRoot = true
            }
        } else {
            this.stack.add(name)
            this.canSkip = true
            this.skipIsNoop = false
            this.lastStart = raw
            this.lastStartName = Some(name)
            if (this.state == ParserState.Prolog) {
                this.state = ParserState.Content
                this.sawRoot = true
            }
        }
        this.firstThing = false
        Some(this.pending.remove(at: 0))
    }

    private func closeElement(raw: RawName): ?XmlEvent {
        if (this.stack.size == 0) {
            throw XmlException("没有匹配的开始标签「${raw.local}」", raw.line, raw.column)
        }
        let name = this.resolveElementName(raw)
        let top = this.stack[this.stack.size - 1]
        if (top != name) {
            throw XmlException(
                "结束标签「${name}」与开始标签「${top}」不匹配",
                raw.line,
                raw.column
            )
        }
        this.stack.remove(at: this.stack.size - 1)
        this.ns.pop()
        if (this.stack.size == 0) {
            this.state = ParserState.Epilog
        }
        this.firstThing = false
        Some(XmlEvent.EndElement(name))
    }

    private func isNamespaceDeclaration(name: RawName): Bool {
        if (name.local == "xmlns" && name.prefix.isNone()) {
            return true
        }
        match (name.prefix) {
            case Some(p) => p == "xmlns"
            case None => false
        }
    }

    private func declareNamespace(attribute: RawAttribute): Unit {
        if (!this.isNamespaceDeclaration(attribute.name)) {
            return
        }
        let uri = attribute.value
        match (attribute.name.prefix) {
            case None =>
                // `xmlns="..."`：空串表示重置为无命名空间。
                if (uri.isEmpty()) {
                    this.ns.declare(None, None)
                } else {
                    this.ns.declare(None, Some(uri))
                }
            case Some(_) =>
                let prefix = attribute.name.local
                if (prefix == "xmlns") {
                    throw XmlException("「xmlns」不能作为前缀声明", attribute.name.line, attribute.name.column)
                }
                if (prefix == "xml") {
                    if (uri != XML_NS_URI) {
                        throw XmlException("「xml」前缀只能绑定到 ${XML_NS_URI}", attribute.name.line, attribute.name.column)
                    }
                } else if (uri == XML_NS_URI) {
                    throw XmlException(
                        "只有「xml」前缀可以绑定到 ${XML_NS_URI}",
                        attribute.name.line,
                        attribute.name.column
                    )
                }
                if (uri.isEmpty()) {
                    throw XmlException("前缀「${prefix}」不能绑定到空 URI", attribute.name.line, attribute.name.column)
                }
                this.ns.declare(Some(prefix), Some(uri))
        }
    }

    private func resolveElementName(raw: RawName): QName {
        match (raw.prefix) {
            case Some(prefix) =>
                if (prefix == "xmlns") {
                    throw XmlException("「xmlns」不能作为元素前缀", raw.line, raw.column)
                }
                match (this.ns.elementNamespace(Some(prefix))) {
                    case NsLookup.Declared(uri) => QName(raw.local, prefix: Some(prefix), uri: Some(uri))
                    case NsLookup.Reset =>
                        throw XmlException("前缀「${prefix}」绑定到空 URI", raw.line, raw.column)
                    case NsLookup.Missing => throw XmlException("未声明的前缀「${prefix}」", raw.line, raw.column)
                }
            case None => match (this.ns.elementNamespace(None)) {
                case NsLookup.Declared(uri) => QName(raw.local, uri: Some(uri))
                case NsLookup.Reset => QName(raw.local)
                case NsLookup.Missing => QName(raw.local)
            }
        }
    }

    private func resolveAttributeName(raw: RawName): QName {
        match (raw.prefix) {
            case Some(prefix) =>
                if (prefix == "xmlns") {
                    throw XmlException("「xmlns」不能作为属性前缀", raw.line, raw.column)
                }
                match (this.ns.attributeNamespace(prefix)) {
                    case NsLookup.Declared(uri) => QName(raw.local, prefix: Some(prefix), uri: Some(uri))
                    case NsLookup.Reset =>
                        throw XmlException("前缀「${prefix}」绑定到空 URI", raw.line, raw.column)
                    case NsLookup.Missing => throw XmlException("未声明的前缀「${prefix}」", raw.line, raw.column)
                }
            case None => QName(raw.local)
        }
    }

    // ---------------------------------------------------------------- 实体

    private func expandEntity(name: String, line: Int64, column: Int64): ?XmlEvent {
        if (this.state != ParserState.Content) {
            throw XmlException("实体引用只能出现在元素内容里（&${name};）", line, column)
        }
        let decl = match (this.entityTable.general(name)) {
            case Some(d) => d
            case None => throw XmlException("实体「&${name};」未声明", line, column)
        }
        let value = match (decl.value) {
            case Some(v) => v
            case None => throw XmlException("外部实体「&${name};」永不加载", line, column)
        }
        let depth = this.lexer.depth() + 1
        if (depth > this.options.entityLimits.maxDepth) {
            throw XmlException(
                "实体递归深度 ${depth} 超过上限 ${this.options.entityLimits.maxDepth}（实体「&${name};」）",
                line,
                column,
                kind: EntityLimitKind.Depth
            )
        }
        let size = Int64(runesOf(value).size)
        if (this.options.entityLimits.overflowPolicy == EntityOverflowPolicy.Strict &&
            size > this.options.entityLimits.maxExpandedPerEntity) {
            throw XmlException(
                "实体「&${name};」的展开量超过 ${this.options.entityLimits.maxExpandedPerEntity} 字节",
                line,
                column,
                kind: EntityLimitKind.PerEntity
            )
        }
        this.expandedTotal += size
        if (this.expandedTotal > this.options.entityLimits.maxExpandedHardLimit) {
            throw XmlException(
                "实体展开总量超过硬限制 ${this.options.entityLimits.maxExpandedHardLimit}",
                line,
                column,
                kind: EntityLimitKind.HardLimit
            )
        }
        if (this.options.entityLimits.overflowPolicy == EntityOverflowPolicy.Strict &&
            this.expandedTotal > this.options.entityLimits.maxExpandedTotal) {
            throw XmlException(
                "实体展开总量超过 ${this.options.entityLimits.maxExpandedTotal}",
                line,
                column,
                kind: EntityLimitKind.Total
            )
        }
        this.lexer.pushFeed(StringFeed(value, SourcePosition(line, column)))
        // 实体的替换文本可能含标记，继续按内容状态读。
        None
    }

    // ---------------------------------------------------------------- 跳过

    func skipElement(): Unit {
        if (!this.canSkip) {
            throw XmlException("skipElement 必须在 StartElement 之后调用")
        }
        this.canSkip = false
        if (this.skipIsNoop) {
            return
        }
        let raw = match (this.lastStart) {
            case Some(r) => r
            case None => throw XmlException("skipElement 必须在 StartElement 之后调用")
        }
        let name = match (this.lastStartName) {
            case Some(n) => n
            case None => throw XmlException("skipElement 必须在 StartElement 之后调用")
        }
        SkipScanner.skipSubtree(this.lexer, raw)
        this.stack.remove(at: this.stack.size - 1)
        this.ns.pop()
        if (this.stack.size == 0) {
            this.state = ParserState.Epilog
        }
        this.pending.add(XmlEvent.EndElement(name))
    }
}

internal func isWhitespaceOnly(text: String): Bool {
    for (r in text.runes()) {
        if (!XmlChars.isWhitespace(r)) {
            return false
        }
    }
    true
}
