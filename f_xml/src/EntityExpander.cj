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
 * 实体递归展开 + 计数 + 溢出判定。
 *
 * 计数挂在「往 sink 追加字符」的那一刻，**不先把展开结果拼成完整字符串再量长度**
 * （10 层 ×10 倍 = 10¹⁰ 字符）。
 */
internal class EntityExpander {
    private let table: EntityTable
    private let limits: EntityLimits
    private let counter: EntityCounter
    /** 未声明实体的处置策略（standalone 决定报错还是跳过并告警）。 */
    private let policy: ?EntityRefPolicy
    /** 实体展开后的字符数（含嵌套），按名字缓存。 */
    private let sizes = HashMap<String, Int64>()
    /** 已通过「替换文本自身良构」校验的实体名。 */
    private let validated = HashMap<String, Bool>()

    init(table: EntityTable, limits: EntityLimits, counter: EntityCounter, policy!: ?EntityRefPolicy = None) {
        this.table = table
        this.limits = limits
        this.counter = counter
        this.policy = policy
    }

    /**
     * 内容里的实体：**不在展开器里预先展开**，只做上限判定后把替换文本接回词法流。
     *
     * 替换文本里可能有标记（`<b>`）、CDATA（`<![CDATA[&x;]]>` 保护引用）、
     * 以及「被转义过一次」的引用（`&lt;foo>` 必须变成文本 `<foo>`，不能变成标签）——
     * 这些只有在词法层重新扫描才分得清。嵌套引用由词法器的输入栈自然处理，
     * 深度就是栈深。
     */
    func feed(name: String, line: Int64, column: Int64, bufSize: Int64, depth: Int64): ExpandReader {
        if (depth > this.limits.maxDepth) {
            throw XmlException(
                "实体递归深度 ${depth} 超过上限 ${this.limits.maxDepth}（实体「&${name};」）",
                line,
                column,
                kind: EntityLimitKind.Depth
            )
        }
        let decl = match (this.table.general(name)) {
            case Some(d) => d
            case None => match (this.policy) {
                case Some(p) =>
                    p.undeclared(name, line, column)
                    return MemoryExpandReader(runesOf(""))
                case None => throw XmlException("实体「&${name};」未声明", line, column)
            }
        }
        let value = match (decl.value) {
            case Some(v) => v
            case None => throw XmlException("外部实体「&${name};」永不加载", line, column)
        }
        // WFC: Parsed Entity——内容位置使用的实体，替换文本必须自身良构。
        this.checkReplacement(name, value, line, column)
        let size = Int64(runesOf(value).size)
        // 投影大小（含嵌套）用于提前判定指数膨胀，不需要真把文本生成出来。
        let projected = this.expandedSize(name, 1)
        let nextTotal = this.counter.total + (if (projected > size) { projected } else { size })
        // 判定顺序按「最先越过的阈值」：单实体原文超长 → 单实体；否则总量；最后才是硬限制。
        if (size > this.limits.maxExpandedPerEntity) {
            throw XmlException(
                "单实体展开量 ${size} 超过 ${kbText(this.limits.maxExpandedPerEntity)}（实体「&${name};」）",
                line,
                column,
                kind: EntityLimitKind.PerEntity
            )
        }
        if (nextTotal > this.limits.maxExpandedTotal &&
            this.limits.overflowPolicy == EntityOverflowPolicy.Strict) {
            throw XmlException(
                "实体展开总量 ${nextTotal} 超过 ${kbText(this.limits.maxExpandedTotal)}",
                line,
                column,
                kind: EntityLimitKind.Total
            )
        }
        if (nextTotal > this.limits.maxExpandedHardLimit) {
            throw XmlException(
                "实体展开总量超过硬限制 ${this.limits.maxExpandedHardLimit}",
                line,
                column,
                kind: EntityLimitKind.HardLimit
            )
        }
        this.counter.total = nextTotal
        if (size > this.limits.maxExpandedPerEntity) {
            // 单个实体的替换文本本身就超过软阈值：落到溢出文件，内存不随它增长。
            let sink = ExpandSink(this.limits, EntityCounter())
            sink.write(value)
            return sink.openReader(bufSize)
        }
        MemoryExpandReader(runesOf(value))
    }

    /**
     * WFC: Parsed Entity——内部一般实体的替换文本必须匹配 `content` 产生式。
     *
     * 做法是用词法器在**独立的输入**上把替换文本重新切一遍（实体表为空，嵌套引用只当
     * 引用、不展开），再检查标签是否在实体内部配平：
     * - `<b>` 留在实体外去配对 → 错；
     * - 实体里多一个 `</a>`（孤立结束标签、或关掉实体外的元素）→ 错；
     * - CDATA / 注释 / PI / 引用没闭合 → 词法器直接抛错，这里补上实体名与展开点位置。
     *
     * 参数实体不适用：它的替换文本是 DTD 片段，不是内容。
     */
    private func checkReplacement(name: String, value: String, line: Int64, column: Int64): Unit {
        if (!value.contains("<") && !value.contains("&") && !value.contains("]]>")) {
            // 纯文本实体：不会出现标签、半截引用或非法的 `]]>`，无需重扫。
            this.validated[name] = true
            return
        }
        if (this.validated.contains(name)) {
            return
        }
        let stack = ArrayList<String>()
        try {
            let lexer = Lexer(LineWindow(Utf8RuneSource(TextInputStream(value))))
            var done = false
            while (!done) {
                match (lexer.nextToken(ParserState.Content)) {
                    case Token.TEof => done = true
                    case Token.TStartTag(raw, _, selfClosing) =>
                        if (!selfClosing) {
                            stack.add(rawNameText(raw))
                        }
                    case Token.TEndTag(raw) =>
                        let local = rawNameText(raw)
                        if (stack.size == 0) {
                            throw XmlException("有孤立的结束标签「${local}」")
                        }
                        let top = stack[stack.size - 1]
                        if (top != local) {
                            throw XmlException("「${local}」与「${top}」没有在实体内部配平")
                        }
                        stack.remove(at: stack.size - 1)
                    case Token.TDecl(_, _, _) | Token.TDoctype(_, _, _, _, _) =>
                        throw XmlException("替换文本里不能出现 XML 声明或 DOCTYPE")
                    case _ => ()
                }
            }
            if (stack.size > 0) {
                let top = stack[stack.size - 1]
                throw XmlException("元素「${top}」没有在实体内部结束")
            }
        } catch (e: XmlException) {
            throw XmlException("实体「&${name};」的替换文本不良构：${e.message}", line, column)
        }
        this.validated[name] = true
    }

    /**
     * 实体展开后的字符数（含嵌套引用），带缓存。
     *
     * 用它做「投影判定」而不是等真展开完再数：Billion Laughs 这类指数膨胀能在
     * 毫秒级被判定为超限，不需要先把 8 MB 文本生成出来。
     */
    private func expandedSize(name: String, depth: Int64): Int64 {
        match (this.sizes.get(name)) {
            case Some(value) => return value
            case None => ()
        }
        if (depth > this.limits.maxDepth) {
            throw XmlException(
                "实体递归深度 ${depth} 超过上限 ${this.limits.maxDepth}",
                0,
                0,
                kind: EntityLimitKind.Depth
            )
        }
        let decl = match (this.table.general(name)) {
            case Some(d) => d
            case None => return 0
        }
        let value = match (decl.value) {
            case Some(v) => v
            case None => return 0
        }
        let runes = runesOf(value)
        var total: Int64 = 0
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] != r'&') {
                total++
                i++
                continue
            }
            var j = i + 1
            if (j < runes.size && runes[j] == r'#') {
                total++
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
                return total + 1
            }
            let gen = StringGenerator()
            for (x in j..k) {
                gen.append(runes[x])
            }
            let ref = gen.toString()
            match (ref) {
                case "lt" | "gt" | "amp" | "quot" | "apos" => total++
                case _ =>
                    let child = this.expandedSize(ref, depth + 1)
                    if (child > this.limits.maxExpandedHardLimit - total) {
                        return this.limits.maxExpandedHardLimit + 1
                    }
                    total += child
            }
            if (total > this.limits.maxExpandedHardLimit) {
                return this.limits.maxExpandedHardLimit + 1
            }
            i = k + 1
        }
        this.sizes[name] = total
        total
    }

    /** 展开一个实体引用，返回落点（内存或溢出文件）。 */
    func expand(
        name: String,
        line: Int64,
        column: Int64,
        attribute!: Bool = false,
        attrName!: ?String = None
    ): ExpandSink {
        let sink = ExpandSink(this.limits, this.counter, attribute: attribute, attrName: attrName)
        try {
            this.expandInto(name, sink, 1, line, column, attribute)
        } catch (e: Exception) {
            sink.close()
            throw e
        }
        sink
    }

    private func expandInto(
        name: String,
        sink: ExpandSink,
        depth: Int64,
        line: Int64,
        column: Int64,
        attribute: Bool
    ): Unit {
        if (depth > this.limits.maxDepth) {
            throw XmlException(
                "实体递归深度 ${depth} 超过上限 ${this.limits.maxDepth}（实体「&${name};」）",
                line,
                column,
                kind: EntityLimitKind.Depth
            )
        }
        let decl = match (this.table.general(name)) {
            case Some(d) => d
            case None => match (this.policy) {
                case Some(p) =>
                    p.undeclared(name, line, column)
                    return
                case None => throw XmlException("实体「&${name};」未声明", line, column)
            }
        }
        let value = match (decl.value) {
            case Some(v) => v
            case None => throw XmlException("外部实体「&${name};」永不加载", line, column)
        }
        let runes = runesOf(value)
        let gen = StringGenerator()
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] != r'&') {
                if (attribute) {
                    // 属性值归一：换行 / 制表变空格（字符引用不归一，已在上面单独处理）。
                    match (runes[i]) {
                        case r'\n' => gen.append<String>(" ")
                        case r'\r' => gen.append<String>(" ")
                        case r'\t' => gen.append<String>(" ")
                        case _ => gen.append(runes[i])
                    }
                } else {
                    gen.append(runes[i])
                }
                i++
                continue
            }
            if (gen.size > 0) {
                this.writeChecked(sink, gen.toString(), line, column)
                gen.clear()
            }
            var j = i + 1
            if (j < runes.size && runes[j] == r'#') {
                j++
                var hex = false
                if (j < runes.size && runes[j] == r'x') {
                    hex = true
                    j++
                }
                var cp: Int64 = 0
                var digits: Int64 = 0
                while (j < runes.size) {
                    let d = runes[j]
                    let ok = if (hex) { XmlChars.isHexDigit(d) } else { XmlChars.isDigit(d) }
                    if (!ok) {
                        break
                    }
                    cp = cp * (if (hex) { 16 } else { 10 }) + (if (hex) { XmlChars.hexValue(d) } else {
                        Int64(d.position() - r'0'.position())
                    })
                    if (cp > 0x10FFFF) {
                        cp = 0x110000
                    }
                    digits++
                    j++
                }
                if (digits > 0 && j < runes.size && runes[j] == r';' && XmlChars.isXmlChar(cp)) {
                    this.writeChecked(sink, Rune(cp).toString(), line, column)
                    i = j + 1
                    continue
                }
                throw XmlException("实体「&${name};」的值里有非法字符引用", line, column)
            }
            var k = j
            while (k < runes.size && XmlChars.isNameChar(runes[k].position())) {
                k++
            }
            if (k >= runes.size || runes[k] != r';') {
                throw XmlException("实体「&${name};」的值里有非法引用", line, column)
            }
            let refName = StringGenerator()
            for (x in j..k) {
                refName.append(runes[x])
            }
            let refText = refName.toString()
            match (refText) {
                case "lt" => this.writeChecked(sink, "<", line, column)
                case "gt" => this.writeChecked(sink, ">", line, column)
                case "amp" => this.writeChecked(sink, "&", line, column)
                case "quot" => this.writeChecked(sink, "\"", line, column)
                case "apos" => this.writeChecked(sink, "'", line, column)
                case _ => this.expandInto(refText, sink, depth + 1, line, column, attribute)
            }
            i = k + 1
        }
        if (gen.size > 0) {
            this.writeChecked(sink, gen.toString(), line, column)
        }
    }

    /** `sink.write` 抛出的上限类错误没有位置信息，这里补上。 */
    private func writeChecked(sink: ExpandSink, segment: String, line: Int64, column: Int64): Unit {
        try {
            sink.write(segment)
        } catch (e: XmlException) {
            if (e.line == 0 && e.column == 0) {
                match (e.entityLimitKind) {
                    case Some(kind) => throw XmlException(e.message, line, column, kind: kind)
                    case None => throw XmlException(e.message, line, column)
                }
            }
            throw e
        }
    }
}

/** 把溢出内容当作字符帧接回词法流；读到 EOF 时关闭读回器（删除临时文件）。 */
internal class SinkFeed <: RuneFeed {
    private let reader: ExpandReader
    private let buffer = ArrayList<Rune>()
    private var head: Int64 = 0
    private let originPos: SourcePosition
    private var finished = false

    init(reader: ExpandReader, origin: SourcePosition) {
        this.reader = reader
        this.originPos = origin
    }

    private func fillTo(count: Int64): Bool {
        while (this.buffer.size - this.head < count) {
            if (this.finished) {
                return false
            }
            match (this.reader.next()) {
                case Some(r) => this.buffer.add(r)
                case None =>
                    this.finished = true
                    this.reader.close()
                    return false
            }
        }
        true
    }

    public func peek(offset: Int64): ?Rune {
        if (!this.fillTo(offset + 1)) {
            return None
        }
        this.buffer[this.head + offset]
    }

    public func advance(): ?Rune {
        if (!this.fillTo(1)) {
            return None
        }
        let r = this.buffer[this.head]
        this.head++
        Some(r)
    }

    public func exhausted(): Bool {
        this.peek(0).isNone()
    }

    public func remaining(): Int64 {
        this.buffer.size - this.head
    }

    public func origin(): SourcePosition {
        this.originPos
    }
}
