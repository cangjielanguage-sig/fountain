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

import std.io.InputStream

/**
 * 拉模式解析器：**唯一内核**。
 *
 * 推模式（多回调 / 单回调）建立在它之上——同一输入的事件日志逐行一致。
 * `None` 表示文档结束（`EndDocument` 之后）。
 */
public class XmlPullParser {
    private let engine: ParserEngine
    private let stream: InputStream

    public init(input: InputStream, options!: XmlParserOptions = XmlParserOptions()) {
        this.stream = input
        this.engine = createEngine(input, options, sniff: true)
    }

    /** 内部构造：`parse(text)` 已经是字符，跳过字节嗅探。 */
    internal init(text!: String, options!: XmlParserOptions) {
        let stream = TextInputStream(text)
        this.stream = stream
        this.engine = createEngine(stream, options, sniff: false)
    }

    public func nextEvent(): ?XmlEvent {
        this.engine.nextEvent()
    }

    /**
     * 跳过当前元素的整棵子树。
     *
     * 只能在「刚产出 `StartElement`」之后调用，否则抛异常；`selfClosing = true` 时是空操作。
     * 匹配的 `EndElement` 仍然发出。
     */
    public func skipElement(): Unit {
        this.engine.skipElement()
    }

    public func close(): Unit {
        if (let resource: Resource <- this.stream) {
            resource.close()
        }
    }

    /** 解析过程中产生的告警。 */
    internal func warnings(): Array<String> {
        this.engine.warnings()
    }

    internal func doctypeEntities(): Array<EntityDecl> {
        this.engine.doctypeEntities()
    }

    /** 当前已展开的实体字符总量（测试与观测用）。 */
    internal func totalExpanded(): Int64 {
        this.engine.totalExpanded()
    }
}

/** 按嗅探结果构造字符来源。 */
internal func createEngine(input: InputStream, options: XmlParserOptions, sniff!: Bool): ParserEngine {
    var stream = input
    var encoding = DetectedEncoding.Utf8
    var mode = options.onInvalidByte
    if (sniff) {
        let result = ByteSniffer.sniff(input)
        encoding = result.encoding
        mode = options.onInvalidByte
        stream = PrefixStream(result.prefix[result.bomLength..], input)
    }
    let source: RuneSource = match (encoding) {
        case DetectedEncoding.Utf8 => Utf8RuneSource(stream, mode: mode, bufSize: options.bufSize)
        case DetectedEncoding.Utf16Le =>
            BlockRuneSource(stream, codec: ByteCodec.Utf16Le, bufSize: options.bufSize)
        case DetectedEncoding.Utf16Be =>
            BlockRuneSource(stream, codec: ByteCodec.Utf16Be, bufSize: options.bufSize)
        case DetectedEncoding.Utf32Le =>
            BlockRuneSource(stream, codec: ByteCodec.Utf32Le, bufSize: options.bufSize)
        case DetectedEncoding.Utf32Be =>
            BlockRuneSource(stream, codec: ByteCodec.Utf32Be, bufSize: options.bufSize)
        case DetectedEncoding.Other(charset) =>
            CharsetRuneSource(stream, charset: charset, bufSize: options.bufSize)
    }
    ParserEngine(LineWindow(source), options)
}
