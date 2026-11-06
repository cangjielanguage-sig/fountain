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
import std.fs.{File, OpenMode, Path}

/**
 * 三个解析前端的入口。
 *
 * 拉模式（`XmlPullParser`）是唯一内核；这里只做「推模式」的转译与 DOM 累积。
 */
public class XmlParser {
    /** 从流读到 DOM。 */
    public static func parse(input: InputStream, options!: XmlParserOptions = XmlParserOptions()): XmlDocument {
        let parser = XmlPullParser(input, options: options)
        parseToDocument(parser, options)
    }

    public static func parse(bytes: Array<Byte>, options!: XmlParserOptions = XmlParserOptions()): XmlDocument {
        let parser = XmlPullParser(TextInputStream(bytes), options: options)
        parseToDocument(parser, options)
    }

    /** 输入已经是字符：跳过字节嗅探，不做编码判断。 */
    public static func parse(text: String, options!: XmlParserOptions = XmlParserOptions()): XmlDocument {
        let parser = XmlPullParser(text: text, options: options)
        parseToDocument(parser, options)
    }

    public static func parse(path: Path, options!: XmlParserOptions = XmlParserOptions()): XmlDocument {
        let file = File(path.toString(), OpenMode.Read)
        try {
            let parser = XmlPullParser(file, options: options)
            parseToDocument(parser, options)
        } finally {
            file.close()
        }
    }

    /** 单回调：不产生 DOM。 */
    public static func parse(
        input: InputStream,
        onEvent: (XmlEvent) -> XmlAction,
        options!: XmlParserOptions = XmlParserOptions()
    ): Unit {
        parseWithHandler(input, LambdaEventHandler(onEvent), options)
    }

    /** 多回调：只覆盖关心的方法即可，其余默认 `Continue`。 */
    public static func parse(input: InputStream, handler: XmlEventHandler, options!: XmlParserOptions = XmlParserOptions()): Unit {
        parseWithHandler(input, handler, options)
    }

    private static func parseToDocument(parser: XmlPullParser, options: XmlParserOptions): XmlDocument {
        let builder = DomBuilder(options)
        var done = false
        while (!done) {
            match (parser.nextEvent()) {
                case Some(event) =>
                    builder.handle(event)
                case None => done = true
            }
        }
        let document = builder.document()
        match (document.doctype) {
            case Some(doctype) => doctype.entities = parser.doctypeEntities()
            case None => ()
        }
        document
    }
}

/** 推模式：在拉模式之上循环 dispatch。`Stop` 立即终止，`SkipSubtree` 调 `skipElement()`。 */
internal func parseWithHandler(input: InputStream, handler: XmlEventHandler, options: XmlParserOptions): Unit {
    let parser = XmlPullParser(input, options: options)
    var running = true
    while (running) {
        match (parser.nextEvent()) {
            case Some(event) =>
                let action = dispatch(handler, event)
                if (action == XmlAction.Stop) {
                    running = false
                } else if (action == XmlAction.SkipSubtree) {
                    parser.skipElement()
                }
            case None => running = false
        }
    }
}

internal func dispatch(handler: XmlEventHandler, event: XmlEvent): XmlAction {
    match (event) {
        case XmlEvent.StartDocument => handler.onStartDocument()
        case XmlEvent.XmlDeclaration(version, encoding, standalone) =>
            handler.onXmlDeclaration(version, encoding, standalone)
        case XmlEvent.DocType(name, publicId, systemId) => handler.onDocType(name, publicId, systemId)
        case XmlEvent.StartElement(name, attrs, selfClosing) => handler.onStartElement(name, attrs, selfClosing)
        case XmlEvent.EndElement(name) => handler.onEndElement(name)
        case XmlEvent.Text(text) => handler.onText(text)
        case XmlEvent.CData(text) => handler.onCData(text)
        case XmlEvent.Comment(text) => handler.onComment(text)
        case XmlEvent.ProcessingInstruction(target, data) => handler.onProcessingInstruction(target, data)
        case XmlEvent.EndDocument => handler.onEndDocument()
    }
}

/** 把单回调适配成 `XmlEventHandler`。 */
internal class LambdaEventHandler <: XmlEventHandler {
    private let callback: (XmlEvent) -> XmlAction

    init(callback: (XmlEvent) -> XmlAction) {
        this.callback = callback
    }

    public func onStartDocument(): XmlAction {
        this.callback(XmlEvent.StartDocument)
    }

    public func onXmlDeclaration(version: String, encoding: ?String, standalone: ?Bool): XmlAction {
        this.callback(XmlEvent.XmlDeclaration(version, encoding, standalone))
    }

    public func onDocType(name: String, publicId: ?String, systemId: ?String): XmlAction {
        this.callback(XmlEvent.DocType(name, publicId, systemId))
    }

    public func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        this.callback(XmlEvent.StartElement(name, attrs, selfClosing))
    }

    public func onEndElement(name: QName): XmlAction {
        this.callback(XmlEvent.EndElement(name))
    }

    public func onText(text: String): XmlAction {
        this.callback(XmlEvent.Text(text))
    }

    public func onCData(text: String): XmlAction {
        this.callback(XmlEvent.CData(text))
    }

    public func onComment(text: String): XmlAction {
        this.callback(XmlEvent.Comment(text))
    }

    public func onProcessingInstruction(target: String, data: String): XmlAction {
        this.callback(XmlEvent.ProcessingInstruction(target, data))
    }

    public func onEndDocument(): XmlAction {
        this.callback(XmlEvent.EndDocument)
    }
}
