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

import std.collection.{ArrayList, HashMap}
import fountain::f_base.StringGenerator

/**
 * `<!ATTLIST>` 的属性类型。
 *
 * 只服务 XML 1.0 §3.3.3 的属性值规范化（区分 `CDATA` 与非 `CDATA`），**不**服务有效性：
 * 不检查 `ID` 唯一性、不检查 `IDREF` 指向、不检查枚举取值、不注入默认值。
 */
internal enum AttType <: ToString {
    | Cdata
    | Id
    | IdRef
    | IdRefs
    | Entity
    | Entities
    | Nmtoken
    | Nmtokens
    | Notation
    | Enumeration

    /** 非 `CDATA` 类型要「去首尾空格 + 内部连续空格折叠」。 */
    func isTokenized(): Bool {
        match (this) {
            case Cdata => false
            case _ => true
        }
    }

    public func toString(): String {
        match (this) {
            case Cdata => "CDATA"
            case Id => "ID"
            case IdRef => "IDREF"
            case IdRefs => "IDREFS"
            case Entity => "ENTITY"
            case Entities => "ENTITIES"
            case Nmtoken => "NMTOKEN"
            case Nmtokens => "NMTOKENS"
            case Notation => "NOTATION"
            case Enumeration => "枚举"
        }
    }
}

/**
 * 「元素字面名 → 属性名 → `AttType`」映射。
 *
 * 键按**字面名**（`prefix:local` 原文）匹配，不做命名空间解析——DTD 不认识命名空间，
 * 用展开名匹配会得到与规范相反的结果。同名重复声明取**第一个**。
 */
internal class AttTypeMap {
    private let table = HashMap<String, HashMap<String, AttType>>()

    func declare(element: String, attribute: String, attType: AttType): Unit {
        match (this.table.get(element)) {
            case Some(attributes) =>
                if (attributes.contains(attribute)) {
                    return
                }
                attributes[attribute] = attType
            case None =>
                let attributes = HashMap<String, AttType>()
                attributes[attribute] = attType
                this.table[element] = attributes
        }
    }

    func lookup(element: String, attribute: String): ?AttType {
        match (this.table.get(element)) {
            case Some(attributes) => attributes.get(attribute)
            case None => None
        }
    }
}

/**
 * DTD 内部子集解析器：四类声明 + 属性类型映射。
 *
 * 解析并校验**声明语法**（良构性，WFC），不校验有效性（VC）：
 * 不注入默认属性值、不比对内容模型与文档结构。
 *
 * - `<!ENTITY>`：`GEDecl` / `PEDecl`，`EntityValue` 里的**字符引用在声明时展开**，
 *   实体引用保持原文（延迟到使用时展开）。
 * - `<!ELEMENT>`：`EMPTY` / `ANY` / `Mixed` / `children`，含 `?` `*` `+` 的紧邻规则。
 * - `<!ATTLIST>`：八种 `AttType` 与枚举、`NOTATION` 枚举、四种 `DefaultDecl`；
 *   顺带建立「元素字面名 → 属性名 → `AttType`」映射，**只**用于属性值规范化。
 * - `<!NOTATION>`：`ExternalID` 或 `PublicID`。
 *
 * **条件段只属于外部子集**：XML 1.0 §3.4 的 `intSubset` 产生式里没有 `conditionalSect`，
 * 所以内部子集里出现 `<![INCLUDE[` / `<![IGNORE[` 一律报错——外部子集永不加载，
 * M1 不存在「按标志位选分支」的路径。
 */
internal class DoctypeParser {
    private let text: Array<Rune>
    private var pos: Int64 = 0
    private let table: EntityTable
    private let maxDepth: Int64
    private let depth: Int64
    /** 子集第一个字符在文档里的位置，用于把内部偏移换算成行列号。 */
    private let base: SourcePosition

    private init(
        text: Array<Rune>,
        table: EntityTable,
        base: SourcePosition,
        maxDepth!: Int64 = 16,
        depth!: Int64 = 0
    ) {
        this.text = text
        this.table = table
        this.base = base
        this.maxDepth = maxDepth
        this.depth = depth
    }

    static func parse(subset: String, limits: EntityLimits, base: SourcePosition): EntityTable {
        let table = EntityTable(limits.maxDeclarations)
        let parser = DoctypeParser(runesOf(subset), table, base, maxDepth: limits.maxDepth)
        parser.parseStatements()
        table
    }

    // ---------------------------------------------------------------- 基础

    private func atEnd(): Bool {
        this.pos >= this.text.size
    }

    private func peek(offset!: Int64 = 0): ?Rune {
        let index = this.pos + offset
        if (index >= this.text.size) {
            return None
        }
        Some(this.text[index])
    }

    /** 把内部偏移换算成文档行列号（只在报错时调用，O(n) 可以接受）。 */
    private func positionAt(index: Int64): SourcePosition {
        var line = this.base.line
        var column = this.base.column
        var i: Int64 = 0
        while (i < index && i < this.text.size) {
            if (this.text[i] == r'\n') {
                line++
                column = 1
            } else {
                column++
            }
            i++
        }
        SourcePosition(line, column)
    }

    private func error(message: String): XmlException {
        let p = this.positionAt(this.pos)
        XmlException(message, p.line, p.column)
    }

    private func fail(decl: String, message: String): XmlException {
        this.error("${decl} ${message}")
    }

    private func startsWith(value: String): Bool {
        let runes = runesOf(value)
        for (i in 0..runes.size) {
            match (this.peek(offset: i)) {
                case Some(r) => if (r != runes[i]) {
                    return false
                }
                case None => return false
            }
        }
        true
    }

    /** 关键字必须在 NameChar 边界处结束，避免把 `IDREF` 认成 `ID`。 */
    private func startsWithKeyword(keyword: String): Bool {
        if (!this.startsWith(keyword)) {
            return false
        }
        match (this.peek(offset: Int64(runesOf(keyword).size))) {
            case Some(r) => !XmlChars.isNameChar(r.position())
            case None => true
        }
    }

    private func consume(value: String): Unit {
        for (_ in value.runes()) {
            this.pos++
        }
    }

    private func skipWhitespace(): Unit {
        while (let Some(r) <- this.peek(offset: 0)) {
            if (!XmlChars.isWhitespace(r)) {
                return
            }
            this.pos++
        }
    }

    private func trySkipWhitespace(): Bool {
        var seen = false
        while (let Some(r) <- this.peek(offset: 0)) {
            if (!XmlChars.isWhitespace(r)) {
                break
            }
            seen = true
            this.pos++
        }
        seen
    }

    private func requireWhitespace(decl: String, after: String): Unit {
        if (!this.trySkipWhitespace()) {
            throw this.fail(decl, "在${after}缺少空白")
        }
    }

    private func readName(decl: String): String {
        let gen = StringGenerator()
        var first = true
        while (let Some(r) <- this.peek(offset: 0)) {
            let cp = r.position()
            let ok = if (first) {
                XmlChars.isNameStartChar(cp)
            } else {
                XmlChars.isNameChar(cp)
            }
            if (!ok) {
                break
            }
            gen.append(r)
            this.pos++
            first = false
        }
        if (first) {
            throw this.fail(decl, "缺少名字")
        }
        gen.toString()
    }

    /** `Nmtoken ::= NameChar+` */
    private func readNmtoken(decl: String): String {
        let gen = StringGenerator()
        while (let Some(r) <- this.peek(offset: 0)) {
            if (!XmlChars.isNameChar(r.position())) {
                break
            }
            gen.append(r)
            this.pos++
        }
        if (gen.size == 0) {
            throw this.fail(decl, "缺少名字记号")
        }
        gen.toString()
    }

    /** 读一段连续 NameChar（允许为空），用于把非法记号原样带进消息。 */
    private func readNameCharRun(): String {
        let gen = StringGenerator()
        while (let Some(r) <- this.peek(offset: 0)) {
            if (!XmlChars.isNameChar(r.position())) {
                break
            }
            gen.append(r)
            this.pos++
        }
        gen.toString()
    }

    private func readQuoted(decl: String, what: String): String {
        let quoteRune = match (this.peek(offset: 0)) {
            case Some(r) => r
            case None => throw this.fail(decl, "缺少${what}")
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw this.fail(decl, "缺少${what}")
        }
        this.pos++
        let gen = StringGenerator()
        var result: ?String = None
        while (result.isNone()) {
            match (this.peek(offset: 0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.pos++
                        result = Some(gen.toString())
                    } else if (!XmlChars.isXmlChar(r.position())) {
                        throw this.fail(decl, "的${what}里出现非法字符")
                    } else {
                        gen.append(r)
                        this.pos++
                    }
                case None => throw this.fail(decl, "的${what}未闭合")
            }
        }
        result.getOrThrow()
    }

    /** `PubidChar ::= #x20 | #xD | #xA | [a-zA-Z0-9] | [-'()+,./:=?;!*#@$_%]` */
    private func readPubidLiteral(decl: String): String {
        let value = this.readQuoted(decl, "PubidLiteral")
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
                throw this.fail(decl, "的 PubidLiteral 里出现非法字符「${r}」")
            }
        }
        value
    }

    private func expectGreater(decl: String): Unit {
        this.skipWhitespace()
        if (this.peek(offset: 0) != Some(r'>')) {
            throw this.fail(decl, "未闭合（缺少「>」）")
        }
        this.pos++
    }

    // ---------------------------------------------------------------- 子集

    /**
     * 依次解析声明。内部子集里不允许条件段：`intSubset` 产生式不含 `conditionalSect`，
     * 外部子集又永不加载，所以这里遇到 `<![` 一律报错。
     */
    private func parseStatements(): Unit {
        while (!this.atEnd()) {
            this.skipWhitespace()
            if (this.atEnd()) {
                break
            }
            if (this.startsWith("]]>")) {
                throw this.error("DTD 内部子集里出现多余的「]]>」")
            }
            if (this.startsWith("<!--")) {
                this.consume("<!--")
                this.skipUntil("-->", "注释")
                continue
            }
            if (this.startsWith("<?")) {
                this.consume("<?")
                let target = this.readName("处理指令")
                if (target.toAsciiLower() == "xml") {
                    throw this.error("DTD 内部子集里不允许出现 XML 声明")
                }
                // `PI ::= '<?' PITarget (S (Char* - (Char* '?>' Char*)))? '?>'`：target 后必须是 S 或 `?>`。
                if (!this.trySkipWhitespace() && !this.startsWith("?>")) {
                    throw this.error("处理指令 target 之后必须是空白或「?>」")
                }
                this.skipUntil("?>", "处理指令")
                continue
            }
            if (this.startsWith("<![")) {
                throw this.error("条件段只能出现在外部子集")
            }
            if (this.startsWith("<!ENTITY")) {
                this.parseEntityDecl()
                continue
            }
            if (this.startsWith("<!ELEMENT")) {
                this.parseElementDecl()
                continue
            }
            if (this.startsWith("<!ATTLIST")) {
                this.parseAttlistDecl()
                continue
            }
            if (this.startsWith("<!NOTATION")) {
                this.parseNotationDecl()
                continue
            }
            if (this.peek(offset: 0) == Some(r'%')) {
                this.pos++
                let name = this.readName("参数实体引用")
                // `PEReference ::= '%' Name ';'`：`;` 必须紧跟名字，`%foo ;` 非法。
                if (this.peek(offset: 0) != Some(r';')) {
                    throw this.error("参数实体引用「%${name}」缺少「;」")
                }
                this.pos++
                this.table.sawParameterRef = true
                this.expandParameterEntity(name)
                continue
            }
            throw this.error("DTD 内部子集里出现无法识别的内容")
        }
    }

    private func skipUntil(terminator: String, what: String): Unit {
        while (!this.atEnd()) {
            if (this.startsWith(terminator)) {
                this.consume(terminator)
                return
            }
            this.pos++
        }
        throw this.error("${what}未闭合：期望「${terminator}」")
    }

    private func expandParameterEntity(name: String): Unit {
        if (this.depth + 1 > this.maxDepth) {
            throw XmlException(
                "参数实体递归深度超过上限 ${this.maxDepth}（「%${name};」）",
                0,
                0,
                kind: EntityLimitKind.Depth
            )
        }
        match (this.table.parameter(name)) {
            case Some(decl) =>
                match (decl.value) {
                    case Some(value) =>
                        let nested = DoctypeParser(
                            runesOf(value),
                            this.table,
                            this.positionAt(this.pos),
                            maxDepth: this.maxDepth,
                            depth: this.depth + 1
                        )
                        nested.parseStatements()
                    case None => () // 外部参数实体：不加载
                }
            case None => throw this.error("参数实体「%${name};」未声明")
        }
    }

    // ---------------------------------------------------------------- ENTITY

    private func parseEntityDecl(): Unit {
        let decl = "<!ENTITY>"
        this.consume("<!ENTITY")
        this.requireWhitespace(decl, "「<!ENTITY」之后")
        var parameter = false
        if (this.peek(offset: 0) == Some(r'%')) {
            parameter = true
            this.pos++
            this.requireWhitespace(decl, "「%」之后")
        }
        let name = this.readName(decl)
        this.requireWhitespace(decl, "实体名之后")
        var value: ?String = None
        var publicId: ?String = None
        var systemId: ?String = None
        var external = false
        if (this.startsWithKeyword("PUBLIC")) {
            external = true
            this.consume("PUBLIC")
            this.requireWhitespace(decl, "「PUBLIC」之后")
            publicId = Some(this.readPubidLiteral(decl))
            this.requireWhitespace(decl, "PubidLiteral 之后")
            systemId = Some(this.readQuoted(decl, "SystemLiteral"))
        } else if (this.startsWithKeyword("SYSTEM")) {
            external = true
            this.consume("SYSTEM")
            this.requireWhitespace(decl, "「SYSTEM」之后")
            systemId = Some(this.readQuoted(decl, "SystemLiteral"))
        } else {
            value = Some(this.parseEntityValue(decl))
        }
        let hadWhitespace = this.trySkipWhitespace()
        if (hadWhitespace && this.startsWithKeyword("NDATA")) {
            if (!external) {
                throw this.fail(decl, "的「NDATA」只能出现在外部实体上")
            }
            if (parameter) {
                throw this.fail(decl, "的参数实体不能带「NDATA」")
            }
            this.consume("NDATA")
            this.requireWhitespace(decl, "「NDATA」之后")
            this.readName(decl)
        }
        this.expectGreater(decl)
        this.table.declare(EntityDecl(
            name,
            value: value,
            publicId: publicId,
            systemId: systemId,
            parameter: parameter
        ))
    }

    /**
     * `EntityValue ::= '"' ([^%&"] | PEReference | Reference)* '"'`
     *
     * 字符引用**声明时**展开（`&#38;#38;` 这类双重转义依赖这一点）；实体引用只存原文，
     * 等实体被使用时再递归展开——前向引用因此合法。
     */
    private func parseEntityValue(decl: String): String {
        let quoteRune = match (this.peek(offset: 0)) {
            case Some(r) => r
            case None => throw this.fail(decl, "缺少 EntityValue")
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw this.fail(decl, "缺少 EntityValue")
        }
        this.pos++
        let gen = StringGenerator()
        while (true) {
            match (this.peek(offset: 0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.pos++
                        return expandCharRefs(gen.toString())
                    }
                    if (r == r'%') {
                        throw this.fail(decl, "的值里不能出现参数实体引用")
                    }
                    if (r == r'&') {
                        this.appendReference(decl, gen)
                        continue
                    }
                    if (!XmlChars.isXmlChar(r.position())) {
                        throw this.fail(decl, "的值里出现非法字符")
                    }
                    gen.append(r)
                    this.pos++
                case None => throw this.fail(decl, "的 EntityValue 未闭合")
            }
        }
        ""
    }

    /** 校验一个 `Reference` 并把原文写进 `gen`（字符引用留给 `expandCharRefs`）。 */
    private func appendReference(decl: String, gen: StringGenerator): Unit {
        gen.append<String>("&")
        this.pos++
        if (this.peek(offset: 0) == Some(r'#')) {
            gen.append<String>("#")
            this.pos++
            var hex = false
            if (this.peek(offset: 0) == Some(r'x')) {
                hex = true
                gen.append<String>("x")
                this.pos++
            }
            var digits: Int64 = 0
            var cp: Int64 = 0
            while (let Some(r) <- this.peek(offset: 0)) {
                let ok = if (hex) { XmlChars.isHexDigit(r) } else { XmlChars.isDigit(r) }
                if (!ok) {
                    break
                }
                cp = cp * (if (hex) { 16 } else { 10 }) + (if (hex) { XmlChars.hexValue(r) } else {
                    Int64(r.position() - r'0'.position())
                })
                digits++
                gen.append(r)
                this.pos++
            }
            if (digits == 0 || this.peek(offset: 0) != Some(r';')) {
                throw this.fail(decl, "的值里有非法字符引用")
            }
            if (!XmlChars.isXmlChar(cp)) {
                throw this.fail(decl, "的值里有非法码点")
            }
            gen.append<String>(";")
            this.pos++
            return
        }
        let name = this.readName(decl)
        if (this.peek(offset: 0) != Some(r';')) {
            throw this.fail(decl, "的值里有非法引用「&${name}」")
        }
        gen.append<String>(name)
        gen.append<String>(";")
        this.pos++
    }

    // ---------------------------------------------------------------- ELEMENT

    private func parseElementDecl(): Unit {
        let decl = "<!ELEMENT>"
        this.consume("<!ELEMENT")
        this.requireWhitespace(decl, "「<!ELEMENT」之后")
        this.readName(decl)
        this.requireWhitespace(decl, "元素名之后")
        this.parseContentSpec(decl)
        this.expectGreater(decl)
    }

    private func parseContentSpec(decl: String): Unit {
        if (this.startsWithKeyword("EMPTY")) {
            this.consume("EMPTY")
            return
        }
        if (this.startsWithKeyword("ANY")) {
            this.consume("ANY")
            return
        }
        if (this.peek(offset: 0) == Some(r'(')) {
            let mixed = this.parseGroup(decl, topLevel: true)
            // `children ::= (choice | seq) ('?' | '*' | '+')?`：量词必须紧邻分组。
            if (!mixed) {
                match (this.peek(offset: 0)) {
                    case Some(r) =>
                        if (r == r'?' || r == r'*' || r == r'+') {
                            this.pos++
                        }
                    case None => ()
                }
            }
            return
        }
        let token = this.readNameCharRun()
        if (token.isEmpty()) {
            throw this.fail(decl, "缺少内容模型")
        }
        throw this.fail(decl, "的内容模型「${token}」不合法（只能是 EMPTY / ANY / Mixed / children）")
    }

    /** `'(' S? (#PCDATA …) | '(' S? cp …`；返回是否为 Mixed（Mixed 只能出现在 contentspec 顶层）。 */
    private func parseGroup(decl: String, topLevel!: Bool): Bool {
        this.consume("(")
        this.skipWhitespace()
        if (this.startsWith("#PCDATA")) {
            if (!topLevel) {
                throw this.fail(decl, "的混合内容不能出现在分组里")
            }
            this.parseMixed(decl)
            return true
        }
        this.parseCp(decl)
        this.skipWhitespace()
        var separator: ?Rune = None
        match (this.peek(offset: 0)) {
            case Some(r) =>
                if (r == r'|' || r == r',') {
                    separator = Some(r)
                }
            case None => ()
        }
        match (separator) {
            case Some(sep) =>
                while (true) {
                    this.skipWhitespace()
                    match (this.peek(offset: 0)) {
                        case Some(r) =>
                            if (r != sep) {
                                break
                            }
                            this.pos++
                            this.skipWhitespace()
                            this.parseCp(decl)
                            this.skipWhitespace()
                        case None => throw this.fail(decl, "的内容模型分组未闭合")
                    }
                }
            case None => ()
        }
        this.skipWhitespace()
        if (this.peek(offset: 0) != Some(r')')) {
            throw this.fail(decl, "的内容模型分组里有非法字符")
        }
        this.pos++
        false
    }

    /** `cp ::= (Name | choice | seq) ('?' | '*' | '+')?`，量词必须紧邻。 */
    private func parseCp(decl: String): Unit {
        match (this.peek(offset: 0)) {
            case Some(r) =>
                if (r == r'(') {
                    this.parseGroup(decl, topLevel: false)
                } else if (XmlChars.isNameStartChar(r.position())) {
                    this.readName(decl)
                } else {
                    throw this.fail(decl, "的内容模型里缺少内容粒子")
                }
            case None => throw this.fail(decl, "的内容模型未闭合")
        }
        match (this.peek(offset: 0)) {
            case Some(r) =>
                if (r == r'?' || r == r'*' || r == r'+') {
                    this.pos++
                }
            case None => ()
        }
    }

    /**
     * `Mixed ::= '(' S? '#PCDATA' (S? '|' S? Name)* S? ')*' | '(' S? '#PCDATA' S? ')'`
     *
     * 两种备选都合法，所以 `(#PCDATA)` 与 `(#PCDATA)*` 都对；但一旦出现 `| Name`，
     * 就必须以 `)*` 收尾（`(#PCDATA|a)` 非法）。
     */
    private func parseMixed(decl: String): Unit {
        this.consume("#PCDATA")
        this.skipWhitespace()
        var names: Int64 = 0
        while (this.peek(offset: 0) == Some(r'|')) {
            this.pos++
            this.skipWhitespace()
            this.readName(decl)
            names++
            this.skipWhitespace()
        }
        if (this.peek(offset: 0) != Some(r')')) {
            throw this.fail(decl, "的混合内容未闭合")
        }
        this.pos++
        if (names > 0 && this.peek(offset: 0) != Some(r'*')) {
            throw this.fail(decl, "的混合内容必须以「)*」收尾")
        }
        if (this.peek(offset: 0) == Some(r'*')) {
            this.pos++
        }
    }

    // ---------------------------------------------------------------- ATTLIST

    private func parseAttlistDecl(): Unit {
        let decl = "<!ATTLIST>"
        this.consume("<!ATTLIST")
        this.requireWhitespace(decl, "「<!ATTLIST」之后")
        // 元素名按**字面名**进映射：DTD 不认识命名空间，用展开名匹配会得到相反结果。
        let element = this.readName(decl)
        while (true) {
            let hadWhitespace = this.trySkipWhitespace()
            match (this.peek(offset: 0)) {
                case Some(r) =>
                    if (r == r'>') {
                        this.pos++
                        return
                    }
                    if (!hadWhitespace) {
                        throw this.fail(decl, "的属性声明之间缺少空白")
                    }
                    let attribute = this.readName(decl)
                    this.requireWhitespace(decl, "属性名之后")
                    let attType = this.parseAttType(decl)
                    this.requireWhitespace(decl, "属性类型之后")
                    this.parseDefaultDecl(decl)
                    // 映射只服务属性值规范化；同名重复声明取第一个。
                    this.table.attTypes.declare(element, attribute, attType)
                case None => throw this.fail(decl, "未闭合（缺少「>」）")
            }
        }
    }

    private func parseAttType(decl: String): AttType {
        if (this.startsWithKeyword("CDATA")) {
            this.consume("CDATA")
            return AttType.Cdata
        }
        if (this.startsWithKeyword("NOTATION")) {
            this.consume("NOTATION")
            this.requireWhitespace(decl, "「NOTATION」之后")
            if (this.peek(offset: 0) != Some(r'(')) {
                throw this.fail(decl, "的 NOTATION 枚举缺少「(」")
            }
            this.parseNameEnum(decl)
            return AttType.Notation
        }
        for (keyword in ["IDREFS", "ENTITIES", "NMTOKENS", "IDREF", "ENTITY", "NMTOKEN", "ID"]) {
            if (this.startsWithKeyword(keyword)) {
                this.consume(keyword)
                return attTypeOf(keyword)
            }
        }
        if (this.peek(offset: 0) == Some(r'(')) {
            this.parseNmtokenEnum(decl)
            return AttType.Enumeration
        }
        let token = this.readNameCharRun()
        if (token.isEmpty()) {
            throw this.fail(decl, "缺少属性类型")
        }
        throw this.fail(decl, "的属性类型「${token}」不是合法记号")
    }

    /** `'(' S? Name (S? '|' S? Name)* S? ')'` */
    private func parseNameEnum(decl: String): Unit {
        this.consume("(")
        this.skipWhitespace()
        this.readName(decl)
        this.skipWhitespace()
        while (this.peek(offset: 0) == Some(r'|')) {
            this.pos++
            this.skipWhitespace()
            this.readName(decl)
            this.skipWhitespace()
        }
        if (this.peek(offset: 0) != Some(r')')) {
            throw this.fail(decl, "的枚举未闭合")
        }
        this.pos++
    }

    /** `'(' S? Nmtoken (S? '|' S? Nmtoken)* S? ')'` */
    private func parseNmtokenEnum(decl: String): Unit {
        this.consume("(")
        this.skipWhitespace()
        this.readNmtoken(decl)
        this.skipWhitespace()
        while (this.peek(offset: 0) == Some(r'|')) {
            this.pos++
            this.skipWhitespace()
            this.readNmtoken(decl)
            this.skipWhitespace()
        }
        if (this.peek(offset: 0) != Some(r')')) {
            throw this.fail(decl, "的枚举未闭合")
        }
        this.pos++
    }

    /** `DefaultDecl ::= '#REQUIRED' | '#IMPLIED' | (('#FIXED' S)? AttValue)` */
    private func parseDefaultDecl(decl: String): Unit {
        if (this.startsWith("#REQUIRED")) {
            this.consume("#REQUIRED")
            return
        }
        if (this.startsWith("#IMPLIED")) {
            this.consume("#IMPLIED")
            return
        }
        if (this.startsWith("#FIXED")) {
            this.consume("#FIXED")
            this.requireWhitespace(decl, "「#FIXED」之后")
        }
        this.parseAttValue(decl)
    }

    /** `AttValue ::= '"' ([^<&"] | Reference)* '"'`，默认值里不许引用外部实体。 */
    private func parseAttValue(decl: String): Unit {
        let quoteRune = match (this.peek(offset: 0)) {
            case Some(r) => r
            case None => throw this.fail(decl, "缺少默认值")
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw this.fail(decl, "缺少默认值")
        }
        this.pos++
        while (true) {
            match (this.peek(offset: 0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.pos++
                        return
                    }
                    if (r == r'<') {
                        throw this.fail(decl, "的默认值里不能出现裸「<」")
                    }
                    if (r == r'&') {
                        this.parseAttributeReference(decl)
                        continue
                    }
                    if (!XmlChars.isXmlChar(r.position())) {
                        throw this.fail(decl, "的默认值里出现非法字符")
                    }
                    this.pos++
                case None => throw this.fail(decl, "的默认值未闭合")
            }
        }
    }

    /** 属性默认值里的引用：字符引用任意，实体引用不能是外部实体（WFC）。 */
    private func parseAttributeReference(decl: String): Unit {
        this.pos++
        if (this.peek(offset: 0) == Some(r'#')) {
            this.pos++
            var hex = false
            if (this.peek(offset: 0) == Some(r'x')) {
                hex = true
                this.pos++
            }
            var digits: Int64 = 0
            var cp: Int64 = 0
            while (let Some(r) <- this.peek(offset: 0)) {
                let ok = if (hex) { XmlChars.isHexDigit(r) } else { XmlChars.isDigit(r) }
                if (!ok) {
                    break
                }
                cp = cp * (if (hex) { 16 } else { 10 }) + (if (hex) { XmlChars.hexValue(r) } else {
                    Int64(r.position() - r'0'.position())
                })
                digits++
                this.pos++
            }
            if (digits == 0 || this.peek(offset: 0) != Some(r';')) {
                throw this.fail(decl, "的默认值里有非法字符引用")
            }
            if (!XmlChars.isXmlChar(cp)) {
                throw this.fail(decl, "的默认值里有非法码点")
            }
            this.pos++
            return
        }
        let name = this.readName(decl)
        if (this.peek(offset: 0) != Some(r';')) {
            throw this.fail(decl, "的默认值里有非法引用「&${name}」")
        }
        this.pos++
        match (name) {
            case "lt" | "gt" | "amp" | "quot" | "apos" => ()
            case _ => this.checkDefaultEntity(name, decl)
        }
    }

    /**
     * 属性默认值里的实体引用必须能解析：已声明、非外部、无递归。
     *
     * 这里做的是**声明期**的 WFC 检查（Entity Declared / No External Entity References /
     * No Recursion），不涉及默认值注入。
     */
    private func checkDefaultEntity(name: String, decl: String): Unit {
        this.checkDefaultEntityInto(name, decl, ArrayList<String>())
    }

    private func checkDefaultEntityInto(name: String, decl: String, stack: ArrayList<String>): Unit {
        for (s in stack) {
            if (s == name) {
                throw this.fail(decl, "的默认值里出现递归引用「&${name};」")
            }
        }
        let entity = match (this.table.general(name)) {
            case Some(e) => e
            case None => throw this.fail(decl, "的默认值里引用了未声明的实体「&${name};」")
        }
        if (entity.isExternal()) {
            throw this.fail(decl, "的默认值里不能引用外部实体「&${name};」")
        }
        let value = match (entity.value) {
            case Some(v) => v
            case None => return
        }
        stack.add(name)
        let runes = runesOf(value)
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] != r'&') {
                i++
                continue
            }
            var j = i + 1
            if (j < runes.size && runes[j] == r'#') {
                while (j < runes.size && runes[j] != r';') {
                    j++
                }
                i = j + 1
                continue
            }
            var k = j
            while (k < runes.size && XmlChars.isNameChar(runes[k].position())) {
                k++
            }
            if (k >= runes.size || runes[k] != r';') {
                i = k + 1
                continue
            }
            let gen = StringGenerator()
            for (x in j..k) {
                gen.append(runes[x])
            }
            let nested = gen.toString()
            match (nested) {
                case "lt" | "gt" | "amp" | "quot" | "apos" => ()
                case _ => this.checkDefaultEntityInto(nested, decl, stack)
            }
            i = k + 1
        }
        stack.remove(at: stack.size - 1)
    }

    // ---------------------------------------------------------------- NOTATION

    private func parseNotationDecl(): Unit {
        let decl = "<!NOTATION>"
        this.consume("<!NOTATION")
        this.requireWhitespace(decl, "「<!NOTATION」之后")
        this.readName(decl)
        this.requireWhitespace(decl, "记号名之后")
        if (this.startsWithKeyword("PUBLIC")) {
            this.consume("PUBLIC")
            this.requireWhitespace(decl, "「PUBLIC」之后")
            this.readPubidLiteral(decl)
            let hadWhitespace = this.trySkipWhitespace()
            if (this.peek(offset: 0) != Some(r'>')) {
                if (!hadWhitespace) {
                    throw this.fail(decl, "的 SystemLiteral 之前缺少空白")
                }
                this.readQuoted(decl, "SystemLiteral")
            }
        } else if (this.startsWithKeyword("SYSTEM")) {
            this.consume("SYSTEM")
            this.requireWhitespace(decl, "「SYSTEM」之后")
            this.readQuoted(decl, "SystemLiteral")
        } else {
            throw this.fail(decl, "缺少外部标识符（SYSTEM / PUBLIC）")
        }
        this.expectGreater(decl)
    }
}

/** 实体值里的字符引用在**声明时**展开；实体引用保持原文。 */
internal func expandCharRefs(value: String): String {    if (!value.contains("&")) {
        return value
    }
    let runes = runesOf(value)
    let gen = StringGenerator()
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i] == r'&' && i + 1 < runes.size && runes[i + 1] == r'#') {
            var j = i + 2
            var hex = false
            if (j < runes.size && runes[j] == r'x') {
                hex = true
                j++
            }
            var cp: Int64 = 0
            var digits: Int64 = 0
            while (j < runes.size) {
                let r = runes[j]
                let ok = if (hex) { XmlChars.isHexDigit(r) } else { XmlChars.isDigit(r) }
                if (!ok) {
                    break
                }
                cp = cp * (if (hex) { 16 } else { 10 }) + (if (hex) { XmlChars.hexValue(r) } else {
                    Int64(r.position() - r'0'.position())
                })
                digits++
                j++
            }
            if (digits > 0 && j < runes.size && runes[j] == r';' && XmlChars.isXmlChar(cp)) {
                gen.append(Rune(cp))
                i = j + 1
                continue
            }
        }
        gen.append(runes[i])
        i++
    }
    gen.toString()
}

/** `<!ATTLIST>` 的具名属性类型 → `AttType`。 */
internal func attTypeOf(keyword: String): AttType {
    match (keyword) {
        case "ID" => AttType.Id
        case "IDREF" => AttType.IdRef
        case "IDREFS" => AttType.IdRefs
        case "ENTITY" => AttType.Entity
        case "ENTITIES" => AttType.Entities
        case "NMTOKEN" => AttType.Nmtoken
        case "NMTOKENS" => AttType.Nmtokens
        case _ => AttType.Cdata
    }
}
