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

/** 字面名（`prefix:local` 原文）。 */
internal func rawNameText(name: RawName): String {
    match (name.prefix) {
        case Some(p) => "${p}:${name.local}"
        case None => name.local
    }
}

/** 去首尾空格并把内部连续空格折叠成一个（只有 `#x20`，见 XML 1.0 §3.3.3）。 */
internal func collapseSpaces(value: String): String {
    let gen = StringGenerator()
    var pendingSpace = false
    for (r in value.runes()) {
        if (r == r' ') {
            pendingSpace = true
            continue
        }
        if (pendingSpace && gen.size > 0) {
            gen.append<String>(" ")
        }
        pendingSpace = false
        gen.append(r)
    }
    gen.toString()
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
    /** 固定串的码点常量：`startsWith` / `consume` / `expect` 不再每次 `runesOf` 新建数组。 */
    private static let kCommentOpen = cpsOf("<!--")
    private static let kCommentClose = cpsOf("-->")
    private static let kDoubleHyphen = cpsOf("--")
    /** `readBang` 进入时 `<` 与 `!` 已消费，这里只需匹配 `[CDATA[`。 */
    private static let kCdataBody = cpsOf("[CDATA[")
    private static let kCdataClose = cpsOf("]]>")
    private static let kPiOpen = cpsOf("<?")
    private static let kPiClose = cpsOf("?>")
    private static let kDoctype = cpsOf("DOCTYPE")
    private static let kPublic = cpsOf("PUBLIC")
    private static let kSystem = cpsOf("SYSTEM")
    private static let kConditionalOpen = cpsOf("<![")
    private static let kInlineNames = [cpsOf("lt"), cpsOf("gt"), cpsOf("amp"), cpsOf("quot"), cpsOf("apos")]
    /**
     * 文本批量扫描的边界掩码（`true` = 停在逐字符路径）：`<`、`&`、`]`，
     * 以及 XML 1.0 不允许的 ASCII 控制字符（让原路径给出原文与原文位置）。
     */
    private static let kTextMask = XmlChars.asciiMaskFor([0x3C, 0x26, 0x5D], invalid: true)
    /** 属性值批量扫描的边界掩码：当前引号 + `&` + `<` + 三个要归一的空白。 */
    private static let kAttrMaskDouble = XmlChars.asciiMaskFor([0x22, 0x26, 0x3C, 0x0A, 0x09, 0x0D], invalid: true)
    private static let kAttrMaskSingle = XmlChars.asciiMaskFor([0x27, 0x26, 0x3C, 0x0A, 0x09, 0x0D], invalid: true)

    private let window: LineWindow
    let limits: EntityLimits
    private let feeds = ArrayList<RuneFeed>()
    /** 名字扫描缓冲：`bytes()` 是零拷贝视图，驻留表的逐字节比对直接用它。 */
    private let nameScratch = ByteScratch()
    /** 属性值 / 声明值 / DOCTYPE 字面量的复用缓冲。 */
    private let valueScratch = StringGenerator()
    /** 文本、CDATA、注释、PI 数据、内部子集的复用缓冲。 */
    private let textScratch = StringGenerator()
    /** 名字驻留表；`hits` / `misses` / `insertions` 供测试做结构性断言。 */
    let names = NameTable()
    /** 开始标签的属性列表：入口 `clear()` 后复用（令牌在同一 `step()` 内被消费完）。 */
    private let attrsScratch = ArrayList<RawAttribute>()
    /** `peekCp` 调用次数（批量扫描的结构性证据，不参与任何业务判断）。 */
    var peekCalls: Int64 = 0
    /**
     * 三条复用缓冲的实例序号（名字缓冲用 `ByteScratch.id`，两个生成器用这里发的号）。
     *
     * 只给用例做「实例数恒定」的结构性断言：同一次解析内不变，不随 token 数增长。
     */
    private static var nextScratchId: Int64 = 0
    let nameScratchId: Int64
    let valueScratchId: Int64
    let textScratchId: Int64
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
        this.nameScratchId = this.nameScratch.id
        Lexer.nextScratchId++
        this.valueScratchId = Lexer.nextScratchId
        Lexer.nextScratchId++
        this.textScratchId = Lexer.nextScratchId
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
        this.peekCalls++
        if (this.feeds.size == 1) {
            return this.window.peekFast(offset)
        }
        var remaining = offset
        var i = this.feeds.size - 1
        while (i >= 0) {
            let feed = this.feeds[i]
            let cp = feed.peekCp(remaining)
            if (cp >= 0) {
                return cp
            }
            if (feed.exhausted()) {
                remaining -= feed.remaining()
                i--
                continue
            }
            return -1
        }
        -1
    }

    /** 热路径：消费一个字符并返回码点（`-1` = EOF）。 */
    func advanceCp(): Int64 {
        if (this.feeds.size == 1) {
            return this.window.advanceFast()
        }
        while (this.feeds.size > 0) {
            let feed = this.feeds[this.feeds.size - 1]
            let cp = feed.advanceCp()
            if (cp >= 0) {
                return cp
            }
            if (feed.exhausted()) {
                this.feeds.remove(at: this.feeds.size - 1)
                continue
            }
            return -1
        }
        -1
    }

    public func peek(offset: Int64): ?Rune {
        let cp = this.peekCp(offset)
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func advance(): ?Rune {
        let cp = this.advanceCp()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
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
            let cp = this.peekCp(0)
            if (cp < 0 || !XmlChars.isWhitespace(cp)) {
                return
            }
            this.advanceCp()
        }
    }

    /** 固定串匹配（码点常量版）：不新建数组。 */
    func startsWithCp(pattern: Array<Int64>): Bool {
        for (i in 0..pattern.size) {
            if (this.peekCp(i) != pattern[i]) {
                return false
            }
        }
        true
    }

    func consumeCp(pattern: Array<Int64>): Unit {
        for (_ in pattern) {
            this.advanceCp()
        }
    }

    /** 单字符 `expect`：错误消息只在失败时构造。 */
    private func expectChar(cp: Int64, text: String): Unit {
        if (this.peekCp(0) != cp) {
            throw this.error("期望「${text}」")
        }
        this.advanceCp()
    }

    /** 动态串版本：只给 `SkipScanner` 这类非热路径用。 */
    func startsWith(text: String): Bool {
        this.startsWithCp(cpsOf(text))
    }

    func consume(text: String): Unit {
        for (_ in text.runes()) {
            this.advanceCp()
        }
    }


    /**
     * 判断 `&` 开头的引用能否就地解码（字符引用或五个预定义实体）。
     *
     * 自定义实体必须单独成 token——它可能很大、可能含标记，也可能需要溢出到文件，
     * 不能和普通文本混在一条 `Text` 里。
     */
    private func referenceIsInline(): Bool {
        if (this.peekCp(1) == 0x23) {
            return true
        }
        for (name in Lexer.kInlineNames) {
            var ok = true
            for (i in 0..name.size) {
                if (this.peekCp(i + 1) != name[i]) {
                    ok = false
                    break
                }
            }
            if (ok && this.peekCp(1 + name.size) == 0x3B) {
                return true
            }
        }
        false
    }

    // ---------------------------------------------------------------- 名字

    /**
     * 读一个 QName 字面名（`prefix:local`）。
     *
     * 一次扫描同时算 FNV-1a hash 并把码点写进复用缓冲；扫描结束先查驻留表，
     * 命中直接复用表里**已切分**的 `prefix` / `local`（零 `String` 分配、零切片），
     * 未命中才 `toString()` + 切分 + 插入（`design.md` §4.2）。
     * 冒号规则与空前缀 / 空本地名的报错时机、消息与改动前完全一致。
     */
    func readName(): RawName {
        let pos = this.position()
        this.nameScratch.reset()
        var hash = NameTable.kFnvOffset
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
            this.nameScratch.putCp(cp)
            hash = NameTable.fold(hash, cp)
            this.advanceCp()
            first = false
        }
        if (first) {
            throw this.error("缺少名字")
        }
        match (this.names.lookup(hash, this.nameScratch)) {
            case Some(entry) => return RawName(entry.prefix, entry.local, pos.line, pos.column)
            case None => ()
        }
        let text = this.nameScratch.toUtf8String()
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
            this.names.insert(hash, text, Some(prefix), local)
            return RawName(Some(prefix), local, pos.line, pos.column)
        }
        this.names.insert(hash, text, None, text)
        RawName(None, text, pos.line, pos.column)
    }

    // ---------------------------------------------------------------- 引用

    /** 读 `&...;`：字符引用与五个预定义实体就地解码，其余返回实体名。 */
    private func readReference(): RefValue {
        let start = this.position()
        this.expectChar(0x26, "&")
        if (this.peekCp(0) == 0x23) {
            this.advanceCp()
            var hex = false
            if (this.peekCp(0) == 0x78) {
                hex = true
                this.advanceCp()
            }
            var value: Int64 = 0
            var digits: Int64 = 0
            while (true) {
                let cp = this.peekCp(0)
                if (cp < 0) {
                    break
                }
                let ok = if (hex) { XmlChars.isHexDigit(cp) } else { XmlChars.isDigit(cp) }
                if (!ok) {
                    break
                }
                let digit = if (hex) { XmlChars.hexValue(cp) } else { cp - 0x30 }
                value = value * (if (hex) { 16 } else { 10 }) + digit
                if (value > 0x10FFFF) {
                    value = 0x110000
                }
                digits++
                this.advanceCp()
            }
            if (digits == 0) {
                throw XmlException("字符引用缺少数字", start.line, start.column)
            }
            if (this.peekCp(0) != 0x3B) {
                throw XmlException("字符引用缺少分号", start.line, start.column)
            }
            this.advanceCp()
            if (!XmlChars.isXmlChar(value)) {
                throw XmlException("非法的字符引用码点 U+${XmlChars.hex(value)}", start.line, start.column)
            }
            return RefValue.CharText(Rune(value).toString())
        }
        let next = this.peekCp(0)
        if (next < 0 || !XmlChars.isNameStartChar(next)) {
            throw XmlException("裸「&」必须写成 &amp;", start.line, start.column)
        }
        let name = this.readName()
        let nameText = rawNameText(name)
        if (this.peekCp(0) != 0x3B) {
            throw XmlException("实体引用「&${nameText}」缺少分号", start.line, start.column)
        }
        this.advanceCp()
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
        let gen = this.textScratch.reset()
        while (true) {
            // 批量路径：只在单帧（无实体展开）时可用，块视图由 `runAvailable` 建立。
            if (this.feeds.size == 1) {
                if (this.window.runAvailable() == 0) {
                    break
                }
                let run = this.window.asciiRunLength(Lexer.kTextMask)
                if (run > 0) {
                    var j: Int64 = 0
                    while (j < run) {
                        gen.append(Rune(this.window.cpAt(j)))
                        j++
                    }
                    this.window.skipRun(run)
                    continue
                }
            }
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
        let first = this.peekCp(0)
        if (first < 0) {
            return Token.TEof
        }
        if (first != 0x3C) {
            // 前导区 / 尾部区的裸文本由状态机判错，这里原样吐出便于给出准确消息。
            let gen = this.textScratch.reset()
            while (true) {
                let cp = this.peekCp(0)
                if (cp < 0 || cp == 0x3C || cp == 0x26) {
                    break
                }
                gen.append(Rune(cp))
                this.advanceCp()
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
        this.expectChar(0x3C, "<")
        let cp = this.peekCp(0)
        if (cp < 0) {
            throw XmlException("文档在标签中间结束", start.line, start.column)
        }
        if (cp == 0x3F) {
            return this.readPiOrDeclaration(start)
        }
        if (cp == 0x21) {
            this.advanceCp()
            return this.readBang(start)
        }
        if (cp == 0x2F) {
            this.advanceCp()
            let name = this.readName()
            this.skipWhitespace()
            if (this.peekCp(0) != 0x3E) {
                throw this.error("结束标签缺少「>」")
            }
            this.advanceCp()
            return Token.TEndTag(name)
        }
        this.readStartTag(start)
    }

    private func readStartTag(start: SourcePosition): Token {
        let name = this.readName()
        let attrs = this.attrsScratch
        attrs.clear()
        var selfClosing = false
        var needSeparator = false
        while (true) {
            let hadWhitespace = this.trySkipWhitespace()
            let cp = this.peekCp(0)
            if (cp < 0) {
                throw XmlException("标签未闭合", start.line, start.column)
            }
            if (cp == 0x3E) {
                this.advanceCp()
                break
            }
            if (cp == 0x2F) {
                this.advanceCp()
                if (this.peekCp(0) != 0x3E) {
                    throw this.error("自闭合标签缺少「>」")
                }
                this.advanceCp()
                selfClosing = true
                break
            }
            if (needSeparator && !hadWhitespace) {
                throw this.error("属性之间缺少空白")
            }
            let attrName = this.readName()
            this.trySkipWhitespace()
            if (this.peekCp(0) != 0x3D) {
                throw this.error("属性「${attrName.local}」缺少「=」")
            }
            this.advanceCp()
            this.trySkipWhitespace()
            let value = this.readAttributeValue(attrName)
            attrs.add(RawAttribute(attrName, value))
            needSeparator = true
        }
        this.normalizeAttributeTypes(name, attrs)
        Token.TStartTag(name, attrs, selfClosing)
    }

    /**
     * XML 1.0 §3.3.3 的第三步：`CDATA` 之外的类型去首尾空格并折叠内部连续空格。
     *
     * 前两步（引用展开、空白字符归一）已在 `readAttributeValue` 里完成；类型表由
     * `<!ATTLIST>` 建好，未声明的属性按 `CDATA` 处理（规范默认，不是遗漏）。
     */
    private func normalizeAttributeTypes(element: RawName, attrs: ArrayList<RawAttribute>): Unit {
        let table = match (this.entityTable) {
            case Some(t) => t
            case None => return
        }
        let elementName = rawNameText(element)
        for (i in 0..attrs.size) {
            let attribute = attrs[i]
            let attType = match (table.attTypes.lookup(elementName, rawNameText(attribute.name))) {
                case Some(t) => t
                case None => AttType.Cdata
            }
            if (attType.isTokenized()) {
                attrs[i] = RawAttribute(attribute.name, collapseSpaces(attribute.value))
            }
        }
    }

    func trySkipWhitespace(): Bool {
        var seen = false
        while (true) {
            let cp = this.peekCp(0)
            if (cp < 0 || !XmlChars.isWhitespace(cp)) {
                break
            }
            seen = true
            this.advanceCp()
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
        let quoteCp = this.peekCp(0)
        if (quoteCp < 0) {
            throw this.error("属性值缺少引号")
        }
        if (quoteCp != 0x22 && quoteCp != 0x27) {
            throw this.error("属性「${name.local}」的值缺少引号")
        }
        this.advanceCp()
        let gen = this.valueScratch.reset()
        let mask = if (quoteCp == 0x22) {
            Lexer.kAttrMaskDouble
        } else {
            Lexer.kAttrMaskSingle
        }
        var finished = false
        while (!finished) {
            // 批量路径只处理「原样拷贝」的 ASCII 段；引号 / `&` / `<` / 空白 / 非法字符
            // 一律落到下面的原分支，归一与报错位置逐字符不变（`design.md` §6.3）。
            if (this.feeds.size == 1) {
                if (this.window.runAvailable() > 0) {
                    let run = this.window.asciiRunLength(mask)
                    if (run > 0) {
                        var j: Int64 = 0
                        while (j < run) {
                            gen.append(Rune(this.window.cpAt(j)))
                            j++
                        }
                        this.window.skipRun(run)
                        continue
                    }
                }
            }
            let cp = this.peekCp(0)
            if (cp < 0) {
                throw this.error("属性「${name.local}」的值未闭合")
            }
            if (cp == quoteCp) {
                this.advanceCp()
                finished = true
            } else if (cp == 0x3C) {
                throw this.error("属性值里不能出现裸「<」，请使用 &lt;")
            } else if (cp == 0x26) {
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
            } else if (cp == 0x0A || cp == 0x09 || cp == 0x0D) {
                gen.append<String>(" ")
                this.advanceCp()
            } else {
                if (!XmlChars.isXmlChar(cp)) {
                    throw this.error("属性值里出现 XML 1.0 不允许的字符")
                }
                gen.append(Rune(cp))
                this.advanceCp()
            }
        }
        gen.toString()
    }

    private func readPiOrDeclaration(start: SourcePosition): Token {
        this.expectChar(0x3F, "?")
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
        let gen = this.textScratch.reset()
        if (this.trySkipWhitespace()) {
            while (true) {
                if (this.startsWithCp(Lexer.kPiClose)) {
                    break
                }
                let cp = this.advanceCp()
                if (cp < 0) {
                    throw XmlException("处理指令未闭合", start.line, start.column)
                }
                if (!XmlChars.isXmlChar(cp)) {
                    throw XmlException("处理指令里出现 XML 1.0 不允许的字符", start.line, start.column)
                }
                gen.append(Rune(cp))
            }
        }
        if (!this.startsWithCp(Lexer.kPiClose)) {
            throw XmlException("处理指令未闭合", start.line, start.column)
        }
        this.consumeCp(Lexer.kPiClose)
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
            if (this.startsWithCp(Lexer.kPiClose)) {
                this.consumeCp(Lexer.kPiClose)
                break
            }
            if (!hadWhitespace) {
                throw XmlException("XML 声明里缺少空白", start.line, start.column)
            }
            let attrName = this.readName()
            this.skipWhitespace()
            if (this.peekCp(0) != 0x3D) {
                throw XmlException("XML 声明里「${attrName.local}」缺少「=」", start.line, start.column)
            }
            this.advanceCp()
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
        let quoteCp = this.peekCp(0)
        if (quoteCp < 0) {
            throw this.error("XML 声明缺少属性值")
        }
        if (quoteCp != 0x22 && quoteCp != 0x27) {
            throw this.error("XML 声明「${name.local}」的值缺少引号")
        }
        this.advanceCp()
        let gen = this.valueScratch.reset()
        var finished = false
        while (!finished) {
            let cp = this.peekCp(0)
            if (cp < 0) {
                throw this.error("XML 声明未闭合")
            }
            if (cp == quoteCp) {
                this.advanceCp()
                finished = true
            } else {
                gen.append(Rune(cp))
                this.advanceCp()
            }
        }
        gen.toString()
    }

    private func readBang(start: SourcePosition): Token {
        if (this.startsWithCp(Lexer.kDoubleHyphen)) {
            return this.readComment(start)
        }
        if (this.startsWithCp(Lexer.kCdataBody)) {
            this.consumeCp(Lexer.kCdataBody)
            let gen = this.textScratch.reset()
            var token: ?Token = None
            while (token.isNone()) {
                if (this.startsWithCp(Lexer.kCdataClose)) {
                    this.consumeCp(Lexer.kCdataClose)
                    token = Some(Token.TCData(gen.toString()))
                } else {
                    let cp = this.advanceCp()
                    if (cp < 0) {
                        throw XmlException("CDATA 未闭合", start.line, start.column)
                    }
                    if (!XmlChars.isXmlChar(cp)) {
                        throw XmlException("CDATA 里出现 XML 1.0 不允许的字符", start.line, start.column)
                    }
                    gen.append(Rune(cp))
                }
            }
            return token.getOrThrow()
        }
        if (this.startsWithCp(Lexer.kDoctype)) {
            this.consumeCp(Lexer.kDoctype)
            return this.readDoctype(start)
        }
        throw XmlException("未知的「<!」构造", start.line, start.column)
    }

    private func readComment(start: SourcePosition): Token {
        this.consumeCp(Lexer.kDoubleHyphen)
        let gen = this.textScratch.reset()
        var token: ?Token = None
        while (token.isNone()) {
            if (this.startsWithCp(Lexer.kDoubleHyphen)) {
                this.consumeCp(Lexer.kDoubleHyphen)
                if (this.peekCp(0) == 0x2D) {
                    throw XmlException("注释不能以「-」结尾", start.line, start.column)
                }
                if (this.peekCp(0) != 0x3E) {
                    throw XmlException("注释未闭合", start.line, start.column)
                }
                this.advanceCp()
                token = Some(Token.TComment(gen.toString()))
            } else {
                let cp = this.advanceCp()
                if (cp < 0) {
                    throw XmlException("注释未闭合", start.line, start.column)
                }
                if (!XmlChars.isXmlChar(cp)) {
                    throw XmlException("注释里出现 XML 1.0 不允许的字符", start.line, start.column)
                }
                gen.append(Rune(cp))
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
        if (this.startsWithCp(Lexer.kPublic)) {
            this.consumeCp(Lexer.kPublic)
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
        } else if (this.startsWithCp(Lexer.kSystem)) {
            this.consumeCp(Lexer.kSystem)
            if (!this.trySkipWhitespace()) {
                throw XmlException("「SYSTEM」之后缺少空白", start.line, start.column)
            }
            systemId = Some(this.readQuoted(start))
            this.skipWhitespace()
        }
        var subset: ?String = None
        var subsetStart = start
        if (this.peekCp(0) == 0x5B) {
            this.advanceCp()
            // 内部子集第一个字符的位置：DTD 报错要把内部偏移换算成文档行列号。
            subsetStart = this.position()
            subset = Some(this.readInternalSubset(start))
            this.skipWhitespace()
        }
        if (this.peekCp(0) != 0x3E) {
            throw XmlException("DOCTYPE 未闭合", start.line, start.column)
        }
        this.advanceCp()
        Token.TDoctype(name.local, publicId, systemId, subset, subsetStart)
    }

    private func readQuoted(start: SourcePosition): String {
        let quoteCp = this.peekCp(0)
        if (quoteCp < 0 || (quoteCp != 0x22 && quoteCp != 0x27)) {
            throw XmlException("DOCTYPE 缺少引号", start.line, start.column)
        }
        this.advanceCp()
        let gen = this.valueScratch.reset()
        var result: ?String = None
        while (result.isNone()) {
            let cp = this.peekCp(0)
            if (cp < 0) {
                throw XmlException("DOCTYPE 字面量未闭合", start.line, start.column)
            }
            if (cp == quoteCp) {
                this.advanceCp()
                result = Some(gen.toString())
            } else {
                gen.append(Rune(cp))
                this.advanceCp()
            }
        }
        result.getOrThrow()
    }

    /** 读内部子集原文（不含两端的中括号），正确处理引号内的 `]`。 */
    private func readInternalSubset(start: SourcePosition): String {
        let gen = this.textScratch.reset()
        var quoteCp: Int64 = -1
        var conditionalDepth: Int64 = 0
        var result: ?String = None
        while (result.isNone()) {
            if (conditionalDepth == 0 && quoteCp < 0 && this.peekCp(0) == 0x5D) {
                this.advanceCp()
                result = Some(gen.toString())
                continue
            }
            if (quoteCp < 0 && this.startsWithCp(Lexer.kCommentOpen)) {
                this.consumeCp(Lexer.kCommentOpen)
                gen.append<String>("<!--")
                while (!this.startsWithCp(Lexer.kCommentClose)) {
                    let cp = this.advanceCp()
                    if (cp < 0) {
                        throw XmlException("DOCTYPE 内部子集里的注释未闭合", start.line, start.column)
                    }
                    gen.append(Rune(cp))
                }
                this.consumeCp(Lexer.kCommentClose)
                gen.append<String>("-->")
                continue
            }
            if (quoteCp < 0 && this.startsWithCp(Lexer.kPiOpen)) {
                this.consumeCp(Lexer.kPiOpen)
                gen.append<String>("<?")
                while (!this.startsWithCp(Lexer.kPiClose)) {
                    let cp = this.advanceCp()
                    if (cp < 0) {
                        throw XmlException("DOCTYPE 内部子集里的 PI 未闭合", start.line, start.column)
                    }
                    gen.append(Rune(cp))
                }
                this.consumeCp(Lexer.kPiClose)
                gen.append<String>("?>")
                continue
            }
            if (quoteCp < 0 && this.startsWithCp(Lexer.kConditionalOpen)) {
                this.consumeCp(Lexer.kConditionalOpen)
                gen.append<String>("<![")
                conditionalDepth++
                continue
            }
            if (quoteCp < 0 && conditionalDepth > 0 && this.startsWithCp(Lexer.kCdataClose)) {
                this.consumeCp(Lexer.kCdataClose)
                gen.append<String>("]]>")
                conditionalDepth--
                continue
            }
            let cp = this.advanceCp()
            if (cp < 0) {
                throw XmlException("DOCTYPE 内部子集未闭合", start.line, start.column)
            }
            if (quoteCp > 0) {
                if (cp == quoteCp) {
                    quoteCp = -1
                }
            } else if (cp == 0x22 || cp == 0x27) {
                quoteCp = cp
            }
            gen.append(Rune(cp))
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

/** 字符来源帧：原始输入流或实体展开文本。**只走码点**，热路径不出现 `?Rune`。 */
internal interface RuneFeed {
    func peekCp(offset: Int64): Int64
    func advanceCp(): Int64
    func exhausted(): Bool
    func remaining(): Int64
    func origin(): SourcePosition
}

internal class WindowFeed <: RuneFeed {
    private let window: LineWindow

    init(window: LineWindow) {
        this.window = window
    }

    public func peekCp(offset: Int64): Int64 {
        this.window.peekFast(offset)
    }

    public func advanceCp(): Int64 {
        this.window.advanceFast()
    }

    public func exhausted(): Bool {
        this.window.peekFast(0) < 0
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
    private let cps: Array<Int32>
    private var pos: Int64 = 0
    private let originPos: SourcePosition

    init(text: String, origin: SourcePosition) {
        let source = cpsOf(text)
        let converted = Array<Int32>(source.size, repeat: 0)
        for (i in 0..source.size) {
            converted[i] = Int32(source[i])
        }
        this.cps = converted
        this.originPos = origin
    }

    public func peekCp(offset: Int64): Int64 {
        let index = this.pos + offset
        if (index >= this.cps.size) {
            return -1
        }
        Int64(this.cps[index])
    }

    public func advanceCp(): Int64 {
        if (this.pos >= this.cps.size) {
            return -1
        }
        let cp = Int64(this.cps[this.pos])
        this.pos++
        cp
    }

    public func exhausted(): Bool {
        this.pos >= this.cps.size
    }

    public func remaining(): Int64 {
        this.cps.size - this.pos
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
