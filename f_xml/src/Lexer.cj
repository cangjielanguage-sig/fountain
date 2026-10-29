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

/** 解析器位置状态：只回答「当前位置允许出现什么」。元素配对靠名称栈。 */
internal enum ParserState <: Equatable<ParserState> {
    | Prolog
    | Content
    | Epilog

    public operator func ==(that: ParserState): Bool {
        match ((this, that)) {
            case (Prolog, Prolog) => true
            case (Content, Content) => true
            case (Epilog, Epilog) => true
            case _ => false
        }
    }
}

/** 词法阶段的名字：还没做命名空间解析，prefix 只是字面前缀。 */
internal struct RawName {
    let prefix: ?String
    let local: String
    let line: Int64
    let column: Int64

    init(prefix: ?String, local: String, line: Int64, column: Int64) {
        this.prefix = prefix
        this.local = local
        this.line = line
        this.column = column
    }
}

internal struct RawAttribute {
    let name: RawName
    let value: String

    init(name: RawName, value: String) {
        this.name = name
        this.value = value
    }
}

/** 一个引用的解码结果：字符（字符引用 / 预定义实体）或自定义实体名。 */
internal enum RefValue {
    | CharText(String)
    | EntityName(String)
}

internal enum Token {
    | TStartTag(RawName, ArrayList<RawAttribute>, Bool)
    | TEndTag(RawName)
    | TText(String)
    | TEntityRef(String, Int64, Int64)
    | TCData(String)
    | TComment(String)
    | TPi(String, String)
    | TDecl(String, ?String, ?Bool)
    | TDoctype(String, ?String, ?String, ?String, SourcePosition)
    | TEof
}

/**
 * 词法器：把字符流切成「标签 / 文本 / CDATA / 注释 / PI / 声明 / DOCTYPE」。
 *
 * 只做词法，不判状态；状态机在 `ParserEngine` 里。文本里的字符引用与五个预定义实体
 * 在这里就地解码，自定义实体吐 `TEntityRef` 交给上层（需要实体表，可能溢出到文件）。
 */
internal class Lexer {
    private let window: LineWindow
    let limits: EntityLimits
    private let feeds = ArrayList<RuneFeed>()
    /** DOCTYPE 解析完成后由上层注入；属性值里的实体展开要用。 */
    var entityTable: ?EntityTable = None
    var expander: ?EntityExpander = None
    /** 未声明实体的处置策略（由上层按 standalone 配置）。 */
    var entityRefPolicy: ?EntityRefPolicy = None
    /** 单个属性值（含展开）的长度上限。 */
    var maxAttributeValueLength: Int64 = 1024 * 1024

    init(window: LineWindow, limits!: EntityLimits = EntityLimits()) {
        this.window = window
        this.limits = limits
        this.feeds.add(WindowFeed(window))
    }

    // ---------------------------------------------------------------- 字符层

    /** 把一段（已展开的）实体替换文本压入输入栈，读完自动弹出。 */
    func pushFeed(feed: RuneFeed): Unit {
        this.feeds.add(feed)
    }

    func depth(): Int64 {
        this.feeds.size - 1
    }

    /** 热路径：直接给码点（`-1` = EOF），单帧时直连 `LineWindow`。 */
    func peekCp(offset: Int64): Int64 {
        if (this.feeds.size == 1) {
            return this.window.peekFast(offset)
        }
        match (this.peek(offset)) {
            case Some(r) => r.position()
            case None => -1
        }
    }

    /** 热路径：消费一个字符并返回码点（`-1` = EOF）。 */
    func advanceCp(): Int64 {
        if (this.feeds.size == 1) {
            return this.window.advanceFast()
        }
        match (this.advance()) {
            case Some(r) => r.position()
            case None => -1
        }
    }

    public func peek(offset: Int64): ?Rune {
        var remaining = offset
        var i = this.feeds.size - 1
        while (i >= 0) {
            let feed = this.feeds[i]
            match (feed.peek(remaining)) {
                case Some(r) => return Some(r)
                case None =>
                    if (feed.exhausted()) {
                        remaining -= feed.remaining()
                        i--
                        continue
                    }
                    return None
            }
        }
        None
    }

    public func advance(): ?Rune {
        while (this.feeds.size > 0) {
            let feed = this.feeds[this.feeds.size - 1]
            match (feed.advance()) {
                case Some(r) => return Some(r)
                case None =>
                    if (feed.exhausted()) {
                        this.feeds.remove(at: this.feeds.size - 1)
                        continue
                    }
                    return None
            }
        }
        None
    }

    /** 位置：实体展开帧里报引用位置，原始输入报真实行列号。 */
    func position(): SourcePosition {
        if (this.feeds.size > 1) {
            return this.feeds[this.feeds.size - 1].origin()
        }
        this.window.position()
    }

    func error(message: String): XmlException {
        let pos = this.position()
        XmlException(message, pos.line, pos.column)
    }

    func skipWhitespace(): Unit {
        while (true) {
            match (this.peek(0)) {
                case Some(r) =>
                    if (XmlChars.isWhitespace(r)) {
                        this.advance()
                    } else {
                        return
                    }
                case None => return
            }
        }
    }

    func startsWith(text: String): Bool {
        let runes = runesOf(text)
        for (i in 0..runes.size) {
            match (this.peek(i)) {
                case Some(r) => if (r != runes[i]) {
                    return false
                }
                case None => return false
            }
        }
        true
    }

    func consume(text: String): Unit {
        for (_ in text.runes()) {
            this.advance()
        }
    }

    func expect(text: String): Unit {
        if (!this.startsWith(text)) {
            throw this.error("期望「${text}」")
        }
        this.consume(text)
    }

    /**
     * 判断 `&` 开头的引用能否就地解码（字符引用或五个预定义实体）。
     *
     * 自定义实体必须单独成 token——它可能很大、可能含标记，也可能需要溢出到文件，
     * 不能和普通文本混在一条 `Text` 里。
     */
    private func referenceIsInline(): Bool {
        if (this.peek(1) == Some(r'#')) {
            return true
        }
        let candidates = ["lt", "gt", "amp", "quot", "apos"]
        for (name in candidates) {
            var ok = true
            let runes = runesOf(name)
            for (i in 0..runes.size) {
                if (this.peek(i + 1) != Some(runes[i])) {
                    ok = false
                    break
                }
            }
            if (ok && this.peek(1 + runes.size) == Some(r';')) {
                return true
            }
        }
        false
    }

    // ---------------------------------------------------------------- 名字

    /** 读一个 QName 字面名（`prefix:local`）。 */
    func readName(): RawName {
        let pos = this.position()
        let gen = StringGenerator()
        var colonSeen = false
        var first = true
        while (true) {
            let cp = this.peekCp(0)
            if (cp < 0) {
                break
            }
            let ok = if (first) {
                XmlChars.isNameStartChar(cp)
            } else {
                XmlChars.isNameChar(cp)
            }
            if (!ok) {
                break
            }
            if (cp == 0x3A) {
                if (colonSeen || first) {
                    throw this.error("名字里出现非法的冒号")
                }
                colonSeen = true
            }
            gen.append(Rune(cp))
            this.advanceCp()
            first = false
        }
        if (first) {
            throw this.error("缺少名字")
        }
        let text = gen.toString()
        if (colonSeen) {
            let idx = match (text.indexOf(":")) {
                case Some(i) => i
                case None => -1
            }
            let prefix = text[0..idx]
            let local = text[idx + 1..]
            if (prefix.isEmpty() || local.isEmpty()) {
                throw this.error("名字的空前缀 / 空本地名非法")
            }
            return RawName(Some(prefix), local, pos.line, pos.column)
        }
        RawName(None, text, pos.line, pos.column)
    }

    // ---------------------------------------------------------------- 引用

    /** 读 `&...;`：字符引用与五个预定义实体就地解码，其余返回实体名。 */
    private func readReference(): RefValue {
        let start = this.position()
        this.expect("&")
        if (this.startsWith("#")) {
            this.advance()
            var hex = false
            if (this.startsWith("x")) {
                hex = true
                this.advance()
            }
            var value: Int64 = 0
            var digits: Int64 = 0
            while (true) {
                match (this.peek(0)) {
                    case Some(r) =>
                        let ok = if (hex) { XmlChars.isHexDigit(r) } else { XmlChars.isDigit(r) }
                        if (!ok) {
                            break
                        }
                        let digit = if (hex) { XmlChars.hexValue(r) } else { Int64(r.position() - r'0'.position()) }
                        value = value * (if (hex) { 16 } else { 10 }) + digit
                        if (value > 0x10FFFF) {
                            value = 0x110000
                        }
                        digits++
                        this.advance()
                    case None => break
                }
            }
            if (digits == 0) {
                throw XmlException("字符引用缺少数字", start.line, start.column)
            }
            if (!this.startsWith(";")) {
                throw XmlException("字符引用缺少分号", start.line, start.column)
            }
            this.advance()
            if (!XmlChars.isXmlChar(value)) {
                throw XmlException("非法的字符引用码点 U+${XmlChars.hex(value)}", start.line, start.column)
            }
            return RefValue.CharText(Rune(value).toString())
        }
        match (this.peek(0)) {
            case Some(r) => if (!XmlChars.isNameStartChar(r.position())) {
                throw XmlException("裸「&」必须写成 &amp;", start.line, start.column)
            }
            case None => throw XmlException("裸「&」必须写成 &amp;", start.line, start.column)
        }
        let name = this.readName()
        let nameText = match (name.prefix) {
            case Some(p) => "${p}:${name.local}"
            case None => name.local
        }
        if (!this.startsWith(";")) {
            throw XmlException("实体引用「&${nameText}」缺少分号", start.line, start.column)
        }
        this.advance()
        match (nameText) {
            case "lt" => RefValue.CharText("<")
            case "gt" => RefValue.CharText(">")
            case "amp" => RefValue.CharText("&")
            case "quot" => RefValue.CharText("\"")
            case "apos" => RefValue.CharText("'")
            case _ => RefValue.EntityName(nameText)
        }
    }

    // ---------------------------------------------------------------- 令牌

    /** 按当前状态取下一个令牌。 */
    func nextToken(state: ParserState): Token {
        match (state) {
            case ParserState.Prolog | ParserState.Epilog => this.nextMarkupToken()
            case ParserState.Content => this.nextContentToken()
        }
    }

    private func nextContentToken(): Token {
        let first = this.peekCp(0)
        if (first < 0) {
            return Token.TEof
        }
        if (first == 0x3C) {
            return this.readMarkup()
        }
        let gen = StringGenerator()
        while (true) {
            let cp = this.peekCp(0)
            if (cp < 0 || cp == 0x3C) {
                break
            }
            if (cp == 0x5D && this.peekCp(1) == 0x5D && this.peekCp(2) == 0x3E) {
                throw this.error("文本里不能出现「]]>」")
            }
            if (cp == 0x26) {
                if (this.referenceIsInline()) {
                    match (this.readReference()) {
                        case RefValue.CharText(text) => gen.append<String>(text)
                        case RefValue.EntityName(_) => ()
                    }
                    continue
                }
                if (gen.size > 0) {
                    break
                }
                let posBefore = this.position()
                match (this.readReference()) {
                    case RefValue.CharText(text) => gen.append<String>(text)
                    case RefValue.EntityName(name) =>
                        return Token.TEntityRef(name, posBefore.line, posBefore.column)
                }
                continue
            }
            if (!XmlChars.isXmlChar(cp)) {
                throw this.error("文本中出现 XML 1.0 不允许的字符 U+${XmlChars.hex(cp)}")
            }
            gen.append(Rune(cp))
            this.advanceCp()
        }
        if (gen.size == 0) {
            return Token.TEof
        }
        Token.TText(gen.toString())
    }

    private func nextMarkupToken(): Token {
        if (this.peek(0).isNone()) {
            return Token.TEof
        }
        if (this.peek(0) != Some(r'<')) {
            // 前导区 / 尾部区的裸文本由状态机判错，这里原样吐出便于给出准确消息。
            let gen = StringGenerator()
            while (let Some(r) <- this.peek(0)) {
                if (r == r'<' || r == r'&') {
                    break
                }
                gen.append(r)
                this.advance()
            }
            if (gen.size > 0) {
                return Token.TText(gen.toString())
            }
            throw this.error("前导区出现无法识别的内容")
        }
        this.readMarkup()
    }

    private func readMarkup(): Token {
        let start = this.position()
        this.expect("<")
        match (this.peek(0)) {
            case Some(r) =>
                if (r == r'?') {
                    return this.readPiOrDeclaration(start)
                }
                if (r == r'!') {
                    this.advance()
                    return this.readBang(start)
                }
                if (r == r'/') {
                    this.advance()
                    let name = this.readName()
                    this.skipWhitespace()
                    if (!this.startsWith(">")) {
                        throw this.error("结束标签缺少「>」")
                    }
                    this.advance()
                    return Token.TEndTag(name)
                }
                return this.readStartTag(start)
            case None => throw XmlException("文档在标签中间结束", start.line, start.column)
        }
    }

    private func readStartTag(start: SourcePosition): Token {
        let name = this.readName()
        let attrs = ArrayList<RawAttribute>()
        var selfClosing = false
        var needSeparator = false
        while (true) {
            let hadWhitespace = this.trySkipWhitespace()
            match (this.peek(0)) {
                case Some(r) =>
                    if (r == r'>') {
                        this.advance()
                        break
                    }
                    if (r == r'/') {
                        this.advance()
                        if (!this.startsWith(">")) {
                            throw this.error("自闭合标签缺少「>」")
                        }
                        this.advance()
                        selfClosing = true
                        break
                    }
                    if (needSeparator && !hadWhitespace) {
                        throw this.error("属性之间缺少空白")
                    }
                    let attrName = this.readName()
                    this.trySkipWhitespace()
                    if (this.peek(0) != Some(r'=')) {
                        throw this.error("属性「${attrName.local}」缺少「=」")
                    }
                    this.advance()
                    this.trySkipWhitespace()
                    let value = this.readAttributeValue(attrName)
                    attrs.add(RawAttribute(attrName, value))
                    needSeparator = true
                case None => throw XmlException("标签未闭合", start.line, start.column)
            }
        }
        Token.TStartTag(name, attrs, selfClosing)
    }

    func trySkipWhitespace(): Bool {
        var seen = false
        while (let Some(r) <- this.peek(0)) {
            if (!XmlChars.isWhitespace(r)) {
                break
            }
            seen = true
            this.advance()
        }
        seen
    }

    /**
     * 属性值：引号配对、裸 `<` 报错、实体与字符引用展开，最后做空白归一。
     *
     * 归一顺序固定为「先展开再归一」：实体值里的换行会变成空格；而直接写在属性里的
     * `&#10;` 是字符引用，**不参与**归一，保持换行。
     */
    private func readAttributeValue(name: RawName): String {
        let quoteRune = match (this.peek(0)) {
            case Some(r) => r
            case None => throw this.error("属性值缺少引号")
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw this.error("属性「${name.local}」的值缺少引号")
        }
        this.advance()
        let gen = StringGenerator()
        var finished = false
        while (!finished) {
            match (this.peek(0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.advance()
                        finished = true
                    } else if (r == r'<') {
                        throw this.error("属性值里不能出现裸「<」，请使用 &lt;")
                    } else if (r == r'&') {
                        let refPos = this.position()
                        match (this.readReference()) {
                            // 字符引用 / 预定义实体：不参与空白归一。
                            case RefValue.CharText(text) => gen.append<String>(text)
                            case RefValue.EntityName(entity) =>
                                let expanded = this.expandAttributeValue(entity, name.local, refPos)
                                // WFC: No `<` in Attribute Values——实体替换文本里也不能含裸 `<`。
                                if (expanded.contains("<")) {
                                    throw this.error("属性「${name.local}」的值里出现裸「<」（来自实体「&${entity};」）")
                                }
                                gen.append<String>(expanded)
                        }
                    } else if (r == r'\n' || r == r'\t' || r == r'\r') {
                        gen.append<String>(" ")
                        this.advance()
                    } else {
                        if (!XmlChars.isXmlChar(r.position())) {
                            throw this.error("属性值里出现 XML 1.0 不允许的字符")
                        }
                        gen.append(r)
                        this.advance()
                    }
                case None => throw this.error("属性「${name.local}」的值未闭合")
            }
        }
        gen.toString()
    }

    private func readPiOrDeclaration(start: SourcePosition): Token {
        this.expect("?")
        let target = this.readName()
        if (target.prefix.isSome()) {
            throw XmlException("处理指令 target 不能带前缀", start.line, start.column)
        }
        if (target.local.toAsciiLower() == "xml") {
            if (target.local != "xml") {
                throw XmlException("处理指令 target 不能是「${target.local}」（xml 保留）", start.line, start.column)
            }
            return this.readDeclaration(start)
        }
        // PI：target 之后必须是空白或直接 `?>`
        let gen = StringGenerator()
        if (this.trySkipWhitespace()) {
            while (true) {
                if (this.startsWith("?>")) {
                    break
                }
                match (this.advance()) {
                    case Some(r) =>
                        if (!XmlChars.isXmlChar(r.position())) {
                            throw XmlException("处理指令里出现 XML 1.0 不允许的字符", start.line, start.column)
                        }
                        gen.append(r)
                    case None => throw XmlException("处理指令未闭合", start.line, start.column)
                }
            }
        }
        if (!this.startsWith("?>")) {
            throw XmlException("处理指令未闭合", start.line, start.column)
        }
        this.consume("?>")
        Token.TPi(target.local, gen.toString())
    }

    private func readDeclaration(start: SourcePosition): Token {
        var version: ?String = None
        var encoding: ?String = None
        var standalone: ?Bool = None
        var seen: ArrayList<String> = ArrayList<String>()
        // `XMLDecl ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'`：顺序固定，每项前都有 S。
        var stage: Int64 = 0
        while (true) {
            let hadWhitespace = this.trySkipWhitespace()
            if (this.startsWith("?>")) {
                this.consume("?>")
                break
            }
            if (!hadWhitespace) {
                throw XmlException("XML 声明里缺少空白", start.line, start.column)
            }
            let attrName = this.readName()
            this.skipWhitespace()
            if (this.peek(0) != Some(r'=')) {
                throw XmlException("XML 声明里「${attrName.local}」缺少「=」", start.line, start.column)
            }
            this.advance()
            this.skipWhitespace()
            let value = this.readDeclarationValue(attrName)
            for (s in seen) {
                if (s == attrName.local) {
                    throw XmlException("XML 声明里「${attrName.local}」重复", start.line, start.column)
                }
            }
            seen.add(attrName.local)
            match (attrName.local) {
                case "version" =>
                    if (stage != 0) {
                        throw XmlException("XML 声明里 version 必须是第一项", start.line, start.column)
                    }
                    stage = 1
                    version = Some(value)
                case "encoding" =>
                    if (stage == 0) {
                        throw XmlException("XML 声明里 encoding 之前必须有 version", start.line, start.column)
                    }
                    if (stage >= 2) {
                        throw XmlException("XML 声明里 encoding 必须在 standalone 之前", start.line, start.column)
                    }
                    // `EncName ::= [A-Za-z] ([A-Za-z0-9._] | '-')*`
                    if (!isEncName(value)) {
                        throw XmlException("encoding 名字非法「${value}」", start.line, start.column)
                    }
                    stage = 2
                    encoding = Some(value)
                case "standalone" =>
                    if (stage == 0) {
                        throw XmlException("XML 声明里 standalone 之前必须有 version", start.line, start.column)
                    }
                    stage = 3
                    if (value == "yes") {
                        standalone = Some(true)
                    } else if (value == "no") {
                        standalone = Some(false)
                    } else {
                        throw XmlException("standalone 只能是 yes / no", start.line, start.column)
                    }
                case _ => throw XmlException("XML 声明里出现未知项「${attrName.local}」", start.line, start.column)
            }
        }
        let v = match (version) {
            case Some(v) => v
            case None => throw XmlException("XML 声明缺少 version", start.line, start.column)
        }
        if (v == "1.1") {
            throw XmlException("XML 1.1 尚未支持（M3）", start.line, start.column)
        }
        // `VersionNum ::= '1.' [0-9]+`：不允许尾随空白或其他字符。
        if (!isVersionNum(v)) {
            throw XmlException("不支持的 XML 版本「${v}」", start.line, start.column)
        }
        Token.TDecl(v, encoding, standalone)
    }

    private func readDeclarationValue(name: RawName): String {
        let quoteRune = match (this.peek(0)) {
            case Some(r) => r
            case None => throw this.error("XML 声明缺少属性值")
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw this.error("XML 声明「${name.local}」的值缺少引号")
        }
        this.advance()
        let gen = StringGenerator()
        var finished = false
        while (!finished) {
            match (this.peek(0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.advance()
                        finished = true
                    } else {
                        gen.append(r)
                        this.advance()
                    }
                case None => throw this.error("XML 声明未闭合")
            }
        }
        gen.toString()
    }

    private func readBang(start: SourcePosition): Token {
        if (this.startsWith("--")) {
            return this.readComment(start)
        }
        if (this.startsWith("[CDATA[")) {
            this.consume("[CDATA[")
            let gen = StringGenerator()
            var token: ?Token = None
            while (token.isNone()) {
                if (this.startsWith("]]>")) {
                    this.consume("]]>")
                    token = Some(Token.TCData(gen.toString()))
                } else {
                    match (this.advance()) {
                        case Some(r) =>
                            if (!XmlChars.isXmlChar(r.position())) {
                                throw XmlException("CDATA 里出现 XML 1.0 不允许的字符", start.line, start.column)
                            }
                            gen.append(r)
                        case None => throw XmlException("CDATA 未闭合", start.line, start.column)
                    }
                }
            }
            return token.getOrThrow()
        }
        if (this.startsWith("DOCTYPE")) {
            this.consume("DOCTYPE")
            return this.readDoctype(start)
        }
        throw XmlException("未知的「<!」构造", start.line, start.column)
    }

    private func readComment(start: SourcePosition): Token {
        this.consume("--")
        let gen = StringGenerator()
        var token: ?Token = None
        while (token.isNone()) {
            if (this.startsWith("--")) {
                this.consume("--")
                if (this.peek(0) == Some(r'-')) {
                    throw XmlException("注释不能以「-」结尾", start.line, start.column)
                }
                if (this.peek(0) != Some(r'>')) {
                    throw XmlException("注释未闭合", start.line, start.column)
                }
                this.advance()
                token = Some(Token.TComment(gen.toString()))
            } else {
                match (this.advance()) {
                    case Some(r) =>
                        if (!XmlChars.isXmlChar(r.position())) {
                            throw XmlException("注释里出现 XML 1.0 不允许的字符", start.line, start.column)
                        }
                        gen.append(r)
                    case None => throw XmlException("注释未闭合", start.line, start.column)
                }
            }
        }
        token.getOrThrow()
    }

    private func readDoctype(start: SourcePosition): Token {
        if (!this.trySkipWhitespace()) {
            throw XmlException("<!DOCTYPE 之后缺少空白", start.line, start.column)
        }
        let name = this.readName()
        this.skipWhitespace()
        var publicId: ?String = None
        var systemId: ?String = None
        if (this.startsWith("PUBLIC")) {
            this.consume("PUBLIC")
            if (!this.trySkipWhitespace()) {
                throw XmlException("「PUBLIC」之后缺少空白", start.line, start.column)
            }
            publicId = Some(this.readQuoted(start))
            // `PubidLiteral ::= '"' PubidChar* '"'`：`[` 之类的字符不在 PubidChar 里。
            if (!isPubidLiteral(publicId.getOrThrow())) {
                throw XmlException("PubidLiteral 里有非法字符", start.line, start.column)
            }
            // `ExternalID ::= 'PUBLIC' S PubidLiteral S SystemLiteral`
            if (!this.trySkipWhitespace()) {
                throw XmlException("PubidLiteral 之后缺少空白（缺少 SystemLiteral）", start.line, start.column)
            }
            systemId = Some(this.readQuoted(start))
            this.skipWhitespace()
        } else if (this.startsWith("SYSTEM")) {
            this.consume("SYSTEM")
            if (!this.trySkipWhitespace()) {
                throw XmlException("「SYSTEM」之后缺少空白", start.line, start.column)
            }
            systemId = Some(this.readQuoted(start))
            this.skipWhitespace()
        }
        var subset: ?String = None
        var subsetStart = start
        if (this.peek(0) == Some(r'[')) {
            this.advance()
            // 内部子集第一个字符的位置：DTD 报错要把内部偏移换算成文档行列号。
            subsetStart = this.position()
            subset = Some(this.readInternalSubset(start))
            this.skipWhitespace()
        }
        if (this.peek(0) != Some(r'>')) {
            throw XmlException("DOCTYPE 未闭合", start.line, start.column)
        }
        this.advance()
        Token.TDoctype(name.local, publicId, systemId, subset, subsetStart)
    }

    private func readQuoted(start: SourcePosition): String {
        let quoteRune = match (this.peek(0)) {
            case Some(r) => r
            case None => throw XmlException("DOCTYPE 缺少引号", start.line, start.column)
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw XmlException("DOCTYPE 缺少引号", start.line, start.column)
        }
        this.advance()
        let gen = StringGenerator()
        var result: ?String = None
        while (result.isNone()) {
            match (this.peek(0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.advance()
                        result = Some(gen.toString())
                    } else {
                        gen.append(r)
                        this.advance()
                    }
                case None => throw XmlException("DOCTYPE 字面量未闭合", start.line, start.column)
            }
        }
        result.getOrThrow()
    }

    /** 读内部子集原文（不含两端的中括号），正确处理引号内的 `]`。 */
    private func readInternalSubset(start: SourcePosition): String {
        let gen = StringGenerator()
        var quoteRune: ?Rune = None
        var conditionalDepth: Int64 = 0
        var result: ?String = None
        while (result.isNone()) {
            if (conditionalDepth == 0 && quoteRune.isNone() && this.peek(0) == Some(r']')) {
                this.advance()
                result = Some(gen.toString())
                continue
            }
            if (quoteRune.isNone() && this.startsWith("<!--")) {
                this.consume("<!--")
                gen.append<String>("<!--")
                while (!this.startsWith("-->")) {
                    match (this.advance()) {
                        case Some(r) => gen.append(r)
                        case None => throw XmlException("DOCTYPE 内部子集里的注释未闭合", start.line, start.column)
                    }
                }
                this.consume("-->")
                gen.append<String>("-->")
                continue
            }
            if (quoteRune.isNone() && this.startsWith("<?")) {
                this.consume("<?")
                gen.append<String>("<?")
                while (!this.startsWith("?>")) {
                    match (this.advance()) {
                        case Some(r) => gen.append(r)
                        case None => throw XmlException("DOCTYPE 内部子集里的 PI 未闭合", start.line, start.column)
                    }
                }
                this.consume("?>")
                gen.append<String>("?>")
                continue
            }
            if (quoteRune.isNone() && this.startsWith("<![")) {
                this.consume("<![")
                gen.append<String>("<![")
                conditionalDepth++
                continue
            }
            if (quoteRune.isNone() && conditionalDepth > 0 && this.startsWith("]]>")) {
                this.consume("]]>")
                gen.append<String>("]]>")
                conditionalDepth--
                continue
            }
            match (this.advance()) {
                case Some(r) =>
                    match (quoteRune) {
                        case Some(q) => if (r == q) {
                            quoteRune = None
                        }
                        case None => if (r == r'"' || r == r'\'') {
                            quoteRune = Some(r)
                        }
                    }
                    gen.append(r)
                case None => throw XmlException("DOCTYPE 内部子集未闭合", start.line, start.column)
            }
        }
        result.getOrThrow()
    }

    /**
     * 属性值里的实体展开：**不支持溢出**。
     *
     * 属性值必须在开始标签解析完后整体在内存（要参与命名空间解析与 `xml:space` 判定），
     * 所以单实体超限时即便 `Spill` 也抛 `AttributeValue`。
     */
    private func expandAttributeValue(name: String, attrName: String, origin: SourcePosition): String {
        match (this.entityTable) {
            case Some(table) => if (table.general(name).isNone()) {
                // 未声明：按 standalone 决定报错还是去掉该引用（属性值不产出空节点）。
                match (this.entityRefPolicy) {
                    case Some(policy) =>
                        policy.undeclared(name, origin.line, origin.column)
                        return ""
                    case None => throw this.error("实体「&${name};」未声明")
                }
            }
            case None => throw this.error("实体「&${name};」未声明")
        }
        let expander = match (this.expander) {
            case Some(e) => e
            case None => throw this.error("实体「&${name};」未声明")
        }
        let pos = this.position()
        let sink = expander.expand(name, pos.line, pos.column, attribute: true, attrName: Some(attrName))
        let text = sink.text()
        sink.close()
        text
    }
}

/** 字符来源帧：原始输入流或实体展开文本。 */
internal interface RuneFeed {
    func peek(offset: Int64): ?Rune
    func advance(): ?Rune
    func exhausted(): Bool
    func remaining(): Int64
    func origin(): SourcePosition
}

internal class WindowFeed <: RuneFeed {
    private let window: LineWindow

    init(window: LineWindow) {
        this.window = window
    }

    public func peek(offset: Int64): ?Rune {
        this.window.peek(offset)
    }

    public func advance(): ?Rune {
        this.window.advance()
    }

    public func exhausted(): Bool {
        this.window.peek(0).isNone()
    }

    public func remaining(): Int64 {
        if (this.exhausted()) {
            0
        } else {
            1
        }
    }

    public func origin(): SourcePosition {
        this.window.position()
    }
}

/** 一段已展开的实体文本（内存）。 */
internal class StringFeed <: RuneFeed {
    private let runes: Array<Rune>
    private var pos: Int64 = 0
    private let originPos: SourcePosition

    init(text: String, origin: SourcePosition) {
        this.runes = runesOf(text)
        this.originPos = origin
    }

    public func peek(offset: Int64): ?Rune {
        let index = this.pos + offset
        if (index >= this.runes.size) {
            return None
        }
        this.runes[index]
    }

    public func advance(): ?Rune {
        if (this.pos >= this.runes.size) {
            return None
        }
        let r = this.runes[this.pos]
        this.pos++
        r
    }

    public func exhausted(): Bool {
        this.pos >= this.runes.size
    }

    public func remaining(): Int64 {
        this.runes.size - this.pos
    }

    public func origin(): SourcePosition {
        this.originPos
    }
}

/** `EncName ::= [A-Za-z] ([A-Za-z0-9._] | '-')*` */
internal func isEncName(value: String): Bool {
    var first = true
    for (r in value.runes()) {
        let cp = r.position()
        let letter = (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)
        let digit = cp >= 0x30 && cp <= 0x39
        let ok = if (first) {
            letter
        } else {
            letter || digit || r == r'.' || r == r'_' || r == r'-'
        }
        if (!ok) {
            return false
        }
        first = false
    }
    !first
}

/** `VersionNum ::= '1.' [0-9]+` */
internal func isVersionNum(value: String): Bool {
    let runes = runesOf(value)
    if (runes.size < 3 || runes[0] != r'1' || runes[1] != r'.') {
        return false
    }
    for (i in 2..runes.size) {
        if (!XmlChars.isDigit(runes[i])) {
            return false
        }
    }
    true
}

/** `PubidChar ::= #x20 | #xD | #xA | [a-zA-Z0-9] | [-'()+,./:=?;!*#@$_%]` */
internal func isPubidLiteral(value: String): Bool {
    for (r in value.runes()) {
        let cp = r.position()
        let ok = cp == 0x20 || cp == 0x0D || cp == 0x0A ||
            (cp >= 0x30 && cp <= 0x39) ||
            (cp >= 0x41 && cp <= 0x5A) ||
            (cp >= 0x61 && cp <= 0x7A) ||
            r == r'-' || r == r'\'' || r == r'(' || r == r')' || r == r'+' || r == r',' ||
            r == r'.' || r == r'/' || r == r':' || r == r'=' || r == r'?' || r == r';' ||
            r == r'!' || r == r'*' || r == r'#' || r == r'@' || r == r'$' || r == r'_' ||
            r == r'%'
        if (!ok) {
            return false
        }
    }
    true
}
