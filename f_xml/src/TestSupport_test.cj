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

import std.io.{InputStream, OutputStream}
import std.collection.ArrayList

/** 测试用的内存输入流。 */
internal class MemoryInputStream <: InputStream {
    private let data: Array<Byte>
    private var pos: Int64 = 0

    init(data: Array<Byte>) {
        this.data = data
    }

    init(text: String) {
        this.data = text.toArray()
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.pos >= this.data.size) {
            return 0
        }
        var n = this.data.size - this.pos
        if (n > buffer.size) {
            n = buffer.size
        }
        for (i in 0..n) {
            buffer[i] = this.data[this.pos + i]
        }
        this.pos += n
        n
    }

    func consumed(): Int64 {
        this.pos
    }

    public func close(): Unit {}
}

/** 记录 close / read 次数的输入流。 */
internal class TrackingInputStream <: InputStream & Resource {
    private let data: Array<Byte>
    private var pos: Int64 = 0

    var closeCount: Int64 = 0
    var readCount: Int64 = 0

    init(text: String) {
        this.data = text.toArray()
    }

    init(data: Array<Byte>) {
        this.data = data
    }

    public func read(buffer: Array<Byte>): Int64 {
        this.readCount++
        if (this.pos >= this.data.size) {
            return 0
        }
        var n = this.data.size - this.pos
        if (n > buffer.size) {
            n = buffer.size
        }
        for (i in 0..n) {
            buffer[i] = this.data[this.pos + i]
        }
        this.pos += n
        n
    }

    public func close(): Unit {
        this.closeCount++
    }

    public func isClosed(): Bool {
        this.closeCount > 0
    }
}

/** 记录写入次数与全部字节的输出流。 */
internal class RecordingOutputStream <: OutputStream {
    private let sink = ArrayList<Byte>()
    var writeCount: Int64 = 0
    var flushCount: Int64 = 0

    public func write(buffer: Array<Byte>): Unit {
        this.writeCount++
        for (b in buffer) {
            this.sink.add(b)
        }
    }

    public func flush(): Unit {
        this.flushCount++
    }

    func bytes(): Array<Byte> {
        this.sink.toArray()
    }

    func text(): String {
        String.fromUtf8(this.sink.toArray())
    }
}

/** 把字符来源读到底。 */
internal func drainRunes(source: RuneSource): String {
    let out = ArrayList<Rune>()
    while (let Some(r) <- source.advance()) {
        out.add(r)
    }
    String(out.toArray())
}

/** 把行窗口读到底。 */
internal func drainWindow(window: LineWindow): String {
    let out = ArrayList<Rune>()
    while (let Some(r) <- window.advance()) {
        out.add(r)
    }
    String(out.toArray())
}

internal func minOf(a: Int64, b: Int64): Int64 {
    if (a < b) {
        a
    } else {
        b
    }
}

/** 带消息的布尔断言（`@Assert` 的两参形式是「相等断言」，不能拿来传消息）。 */
internal func assertTrue(cond: Bool, message: String): Unit {
    if (!cond) {
        fail(message)
    }
}

/** 断言代码块抛出 `XmlException`，且消息包含指定片段。 */
internal func assertXmlError(body: () -> Unit, fragment: String): XmlException {
    try {
        body()
    } catch (e: XmlException) {
        assertTrue(e.message.contains(fragment), "异常消息应包含「${fragment}」，实际为「${e.message}」")
        return e
    }
    assertTrue(false, "应抛 XmlException（期望消息含「${fragment}」），实际未抛")
    throw XmlException("unreachable")
}

/** 断言代码块抛出 `XmlException`。 */
internal func assertAnyXmlError(body: () -> Unit): XmlException {
    try {
        body()
    } catch (e: XmlException) {
        return e
    }
    assertTrue(false, "应抛 XmlException，实际未抛")
    throw XmlException("unreachable")
}

/** 把字符串按 UTF-16LE 编码（不含 BOM）。 */
internal func utf16leBytes(text: String, withBom!: Bool = false): Array<Byte> {
    let out = ArrayList<Byte>()
    if (withBom) {
        out.add(0xFF)
        out.add(0xFE)
    }
    for (r in text.runes()) {
        var cp = r.position()
        if (cp >= 0x10000) {
            let v = cp - 0x10000
            let high = 0xD800 + (v >> 10)
            let low = 0xDC00 + (v & 0x3FF)
            out.add(UInt8(high & 0xFF))
            out.add(UInt8((high >> 8) & 0xFF))
            out.add(UInt8(low & 0xFF))
            out.add(UInt8((low >> 8) & 0xFF))
        } else {
            out.add(UInt8(cp & 0xFF))
            out.add(UInt8((cp >> 8) & 0xFF))
        }
    }
    out.toArray()
}

/** 把字符串按 UTF-32BE 编码（不含 BOM）。 */
internal func utf32beBytes(text: String, withBom!: Bool = false): Array<Byte> {
    let out = ArrayList<Byte>()
    if (withBom) {
        out.add(0x00)
        out.add(0x00)
        out.add(0xFE)
        out.add(0xFF)
    }
    for (r in text.runes()) {
        let cp = r.position()
        out.add(UInt8((cp >> 24) & 0xFF))
        out.add(UInt8((cp >> 16) & 0xFF))
        out.add(UInt8((cp >> 8) & 0xFF))
        out.add(UInt8(cp & 0xFF))
    }
    out.toArray()
}

internal func repeatText(text: String, times: Int64): String {
    let out = ArrayList<Rune>()
    for (_ in 0..times) {
        for (r in text.runes()) {
            out.add(r)
        }
    }
    String(out.toArray())
}

internal func gbkBytes(text: String): Array<Byte> {
    Charsets.GBK.newEncoder().encode(text)
}


internal func parseText(text: String, options!: XmlParserOptions = XmlParserOptions()): XmlDocument {
    XmlParser.parse(text, options: options)
}

/** 用一个 Text 输入构造词法器（跳过字节嗅探）。 */
internal func makeLexer(text: String): Lexer {
    Lexer(LineWindow(Utf8RuneSource(TextInputStream(text))))
}

/** 把令牌渲染成便于断言的文本。 */
internal func tokenText(token: Token): String {
    match (token) {
        case Token.TStartTag(name, attrs, selfClosing) =>
            "START ${nameText(name)} attrs=${attrs.size} self=${selfClosing}"
        case Token.TEndTag(name) => "END ${nameText(name)}"
        case Token.TText(text) => "TEXT ${text}"
        case Token.TEntityRef(name, _, _) => "REF ${name}"
        case Token.TCData(text) => "CDATA ${text}"
        case Token.TComment(text) => "COMMENT ${text}"
        case Token.TPi(target, data) => "PI ${target}|${data}"
        case Token.TDecl(version, encoding, standalone) =>
            "DECL ${version} ${encoding ?? "-"} ${standalone ?? false}"
        case Token.TDoctype(name, publicId, systemId, subset) =>
            "DOCTYPE ${name} ${publicId ?? "-"} ${systemId ?? "-"} ${subset.isSome()}"
        case Token.TEof => "EOF"
    }
}

internal func nameText(name: RawName): String {
    match (name.prefix) {
        case Some(p) => "${p}:${name.local}"
        case None => name.local
    }
}

/** 在指定状态下把输入切完。 */
internal func lexAll(text: String, state!: ParserState = ParserState.Content): Array<String> {
    let lexer = makeLexer(text)
    let out = ArrayList<String>()
    var done = false
    while (!done) {
        let token = lexer.nextToken(state)
        out.add(tokenText(token))
        if (match (token) {
            case Token.TEof => true
            case _ => false
        }) {
            done = true
        }
    }
    out.toArray()
}

/** 把事件渲染成日志行。 */
internal func parseEventLog(text: String, options!: XmlParserOptions = XmlParserOptions()): Array<String> {
    let parser = XmlPullParser(text: text, options: options)
    let out = ArrayList<String>()
    var done = false
    while (!done) {
        match (parser.nextEvent()) {
            case Some(event) =>
                out.add(event.toString())
            case None => done = true
        }
    }
    out.toArray()
}

internal func logEquals(actual: Array<String>, expected: Array<String>): Bool {
    if (actual.size != expected.size) {
        return false
    }
    for (i in 0..actual.size) {
        if (actual[i] != expected[i]) {
            return false
        }
    }
    true
}

internal func joinLog(lines: Array<String>): String {
    var out = ""
    for (line in lines) {
        out += line + "\n"
    }
    out
}
