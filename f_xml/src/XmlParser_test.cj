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

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.fs.{File, OpenMode, Path, removeIfExists}
import std.env

@Test
public class XmlParser_test {
    /** `parse(text)` 不重新编码：声明 GBK 也照常解析。 */
    @TestCase
    public func parseTextIgnoresDeclarationEncoding(): Unit {
        let doc = parseText("<?xml version=\"1.0\" encoding=\"GBK\"?><a>中</a>")
        @Assert(doc.root.getOrThrow().text() == "中")
    }

    /** `parse(bytes)` 走嗅探。 */
    @TestCase
    public func parseBytes(): Unit {
        let doc = XmlParser.parse("<a>x</a>".toArray())
        @Assert(doc.root.getOrThrow().text() == "x")
    }

    /** `parse(path)` 读到 EOF 不阻塞。 */
    @TestCase
    public func parsePath(): Unit {
        let path = env.getWorkingDirectory().join(".f_xml_parse_test.xml")
        try {
            let file = File(path.toString(), OpenMode.Write)
            file.write("<a/>".toArray())
            file.close()
            let doc = XmlParser.parse(path)
            @Assert(doc.root.isSome())
        } finally {
            try {
                removeIfExists(path)
            } catch (_: Exception) {}
        }
    }

    /** 自定义 `InputStream`（模拟 TCP）可直接解析。 */
    @TestCase
    public func parseCustomStream(): Unit {
        let doc = XmlParser.parse(MemoryInputStream("<a>tcp</a>"))
        @Assert(doc.root.getOrThrow().text() == "tcp")
    }

    /** 单回调重载：拿到事件，不产 DOM。 */
    @TestCase
    public func singleCallback(): Unit {
        let events = ArrayList<String>()
        XmlParser.parse(
            TextInputStream("<a>x</a>"),
            {event: XmlEvent =>
                events.add(event.toString())
                XmlAction.Continue
            }
        )
        assertTrue(events.size == 5, "实际 ${events.size}")
        @Assert(events[0] == "START document")
        @Assert(events[events.size - 1] == "END document")
    }

    /** 多回调与单回调事件序列等价。 */
    @TestCase
    public func multiCallbackEquivalent(): Unit {
        let viaHandler = ArrayList<String>()
        let handler = LoggingHandler(viaHandler)
        parseWithHandler(TextInputStream("<a><b/>x</a>"), handler, XmlParserOptions())

        let viaLambda = ArrayList<String>()
        XmlParser.parse(
            TextInputStream("<a><b/>x</a>"),
            {event: XmlEvent =>
                viaLambda.add(event.toString())
                XmlAction.Continue
            }
        )
        assertTrue(logEquals(viaHandler.toArray(), viaLambda.toArray()), joinLog(viaLambda.toArray()))
    }

    /** 文档结构：声明 / doctype / prolog / root / epilog。 */
    @TestCase
    public func documentStructure(): Unit {
        let doc = parseText("<?xml version=\"1.0\"?><!DOCTYPE a><!--p--><a/><!--e-->")
        @Assert(doc.declaration.isSome())
        @Assert(doc.doctype.isSome())
        @Assert(doc.prolog.size == 1)
        @Assert(doc.epilog.size == 1)
    }
}

internal class LoggingHandler <: XmlEventHandler {
    private let sink: ArrayList<String>

    init(sink: ArrayList<String>) {
        this.sink = sink
    }

    public func onStartDocument(): XmlAction {
        this.sink.add(XmlEvent.StartDocument.toString())
        XmlAction.Continue
    }

    public func onXmlDeclaration(version: String, encoding: ?String, standalone: ?Bool): XmlAction {
        this.sink.add(XmlEvent.XmlDeclaration(version, encoding, standalone).toString())
        XmlAction.Continue
    }

    public func onDocType(name: String, publicId: ?String, systemId: ?String): XmlAction {
        this.sink.add(XmlEvent.DocType(name, publicId, systemId).toString())
        XmlAction.Continue
    }

    public func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        this.sink.add(XmlEvent.StartElement(name, attrs, selfClosing).toString())
        XmlAction.Continue
    }

    public func onEndElement(name: QName): XmlAction {
        this.sink.add(XmlEvent.EndElement(name).toString())
        XmlAction.Continue
    }

    public func onText(text: String): XmlAction {
        this.sink.add(XmlEvent.Text(text).toString())
        XmlAction.Continue
    }

    public func onCData(text: String): XmlAction {
        this.sink.add(XmlEvent.CData(text).toString())
        XmlAction.Continue
    }

    public func onComment(text: String): XmlAction {
        this.sink.add(XmlEvent.Comment(text).toString())
        XmlAction.Continue
    }

    public func onProcessingInstruction(target: String, data: String): XmlAction {
        this.sink.add(XmlEvent.ProcessingInstruction(target, data).toString())
        XmlAction.Continue
    }

    public func onEndDocument(): XmlAction {
        this.sink.add(XmlEvent.EndDocument.toString())
        XmlAction.Continue
    }
}
