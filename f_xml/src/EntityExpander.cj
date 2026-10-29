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
 * 实体递归展开 + 计数 + 溢出判定。
 *
 * 计数挂在「往 sink 追加字符」的那一刻，**不先把展开结果拼成完整字符串再量长度**
 * （10 层 ×10 倍 = 10¹⁰ 字符）。
 */
internal class EntityExpander {
    private let table: EntityTable
    private let limits: EntityLimits
    private let counter: EntityCounter

    init(table: EntityTable, limits: EntityLimits, counter: EntityCounter) {
        this.table = table
        this.limits = limits
        this.counter = counter
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
            case None => throw XmlException("实体「&${name};」未声明", line, column)
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
