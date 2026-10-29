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

import fountain::f_base.StringGenerator

/**
 * DTD 内部子集解析器。
 *
 * **只理解 `<!ENTITY>`**：`<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` 识别后跳过
 * （跳过器必须理解引号与内部 `>`，否则 `<!ATTLIST a x CDATA "1>2">` 会提前结束）。
 *
 * 条件段 `<![INCLUDE[ … ]]>` 解析内容，`<![IGNORE[ … ]]>` 原样跳过。
 */
internal class DoctypeParser {
    private let text: Array<Rune>
    private var pos: Int64 = 0
    private let table: EntityTable

    private init(text: Array<Rune>, table: EntityTable) {
        this.text = text
        this.table = table
    }

    static func parse(subset: String, limits: EntityLimits): EntityTable {
        let table = EntityTable(limits.maxDeclarations)
        let parser = DoctypeParser(runesOf(subset), table)
        parser.parseStatements()
        table
    }

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

    private func readName(): String {
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
            throw XmlException("DTD 里缺少名字")
        }
        gen.toString()
    }

    private func readQuoted(): String {
        let quoteRune = match (this.peek(offset: 0)) {
            case Some(r) => r
            case None => throw XmlException("DTD 声明缺少引号")
        }
        if (quoteRune != r'"' && quoteRune != r'\'') {
            throw XmlException("DTD 声明缺少引号")
        }
        this.pos++
        let gen = StringGenerator()
        var finished = false
        while (!finished) {
            match (this.peek(offset: 0)) {
                case Some(r) =>
                    if (r == quoteRune) {
                        this.pos++
                        finished = true
                    } else {
                        gen.append(r)
                        this.pos++
                    }
                case None => throw XmlException("DTD 字面量未闭合")
            }
        }
        expandCharRefs(gen.toString())
    }

    /** 实体值里的字符引用在**声明时**就展开（属性值归一顺序依赖这一点）。 */
    private func expandCharRefs(value: String): String {
        if (!value.contains("&")) {
            return value
        }
        let runes = runesOf(value)
        let gen = StringGenerator()
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] == r'&' && i + 1 < runes.size && runes[i + 1] == r'#') {
                var j = i + 2
                var hex = false
                if (j < runes.size && (runes[j] == r'x')) {
                    hex = true
                    j++
                }
                var value2: Int64 = 0
                var digits: Int64 = 0
                while (j < runes.size) {
                    let r = runes[j]
                    let ok = if (hex) { XmlChars.isHexDigit(r) } else { XmlChars.isDigit(r) }
                    if (!ok) {
                        break
                    }
                    let digit = if (hex) { XmlChars.hexValue(r) } else { Int64(r.position() - r'0'.position()) }
                    value2 = value2 * (if (hex) { 16 } else { 10 }) + digit
                    digits++
                    j++
                }
                if (digits > 0 && j < runes.size && runes[j] == r';' && XmlChars.isXmlChar(value2)) {
                    gen.append(Rune(value2))
                    i = j + 1
                    continue
                }
            }
            gen.append(runes[i])
            i++
        }
        gen.toString()
    }

    private func parseStatements(): Unit {
        while (!this.atEnd()) {
            this.skipWhitespace()
            if (this.atEnd()) {
                return
            }
            if (this.startsWith("<![INCLUDE[")) {
                this.consume("<![INCLUDE[")
                this.parseStatements()
                continue
            }
            if (this.startsWith("<![IGNORE[")) {
                this.consume("<![IGNORE[")
                this.skipUntil("]]>")
                continue
            }
            if (this.startsWith("<!--")) {
                this.consume("<!--")
                this.skipUntil("-->")
                continue
            }
            if (this.startsWith("<?")) {
                this.consume("<?")
                this.skipUntil("?>")
                continue
            }
            if (this.startsWith("<!ENTITY")) {
                this.parseEntity()
                continue
            }
            if (this.startsWith("<!ELEMENT") || this.startsWith("<!ATTLIST") || this.startsWith("<!NOTATION")) {
                this.skipDeclaration()
                continue
            }
            if (this.peek(offset: 0) == Some(r'%')) {
                this.pos++
                let name = this.readName()
                this.skipWhitespace()
                if (this.peek(offset: 0) == Some(r';')) {
                    this.pos++
                }
                this.expandParameterEntity(name)
                continue
            }
            if (this.startsWith("]]>")) {
                // INCLUDE / IGNORE 段的结束标记，交给上层继续。
                this.consume("]]>")
                return
            }
            // 容错：跳过一个字符，避免死循环。
            this.pos++
        }
    }

    private func expandParameterEntity(name: String): Unit {
        match (this.table.parameter(name)) {
            case Some(decl) =>
                match (decl.value) {
                    case Some(value) =>
                        let nested = DoctypeParser(runesOf(value), this.table)
                        nested.parseStatements()
                    case None => () // 外部参数实体：不加载
                }
            case None => throw XmlException("参数实体「%${name};」未声明")
        }
    }

    private func parseEntity(): Unit {
        this.consume("<!ENTITY")
        this.skipWhitespace()
        var parameter = false
        if (this.peek(offset: 0) == Some(r'%')) {
            parameter = true
            this.pos++
            this.skipWhitespace()
        }
        let name = this.readName()
        this.skipWhitespace()
        var value: ?String = None
        var publicId: ?String = None
        var systemId: ?String = None
        if (this.startsWith("SYSTEM")) {
            this.consume("SYSTEM")
            this.skipWhitespace()
            systemId = Some(this.readQuoted())
        } else if (this.startsWith("PUBLIC")) {
            this.consume("PUBLIC")
            this.skipWhitespace()
            publicId = Some(this.readQuoted())
            this.skipWhitespace()
            systemId = Some(this.readQuoted())
        } else {
            value = Some(this.readQuoted())
        }
        this.skipWhitespace()
        if (this.peek(offset: 0) != Some(r'>')) {
            throw XmlException("ENTITY 声明未闭合")
        }
        this.pos++
        this.table.declare(EntityDecl(
            name,
            value: value,
            publicId: publicId,
            systemId: systemId,
            parameter: parameter
        ))
    }

    /** 跳过 `<!ELEMENT …>` 这类声明：理解引号与内部 `>`。 */
    private func skipDeclaration() {
        var quoteRune: ?Rune = None
        while (let Some(r) <- this.peek(offset: 0)) {
            this.pos++
            match (quoteRune) {
                case Some(q) => if (r == q) {
                    quoteRune = None
                }
                case None =>
                    if (r == r'"' || r == r'\'') {
                        quoteRune = Some(r)
                    } else if (r == r'>') {
                        return
                    }
            }
        }
        throw XmlException("DTD 声明未闭合")
    }

    private func skipUntil(terminator: String): Unit {
        while (!this.atEnd()) {
            if (this.startsWith(terminator)) {
                this.consume(terminator)
                return
            }
            this.pos++
        }
        throw XmlException("DTD 构造未闭合：期望「${terminator}」")
    }
}
