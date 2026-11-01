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

@Test
public class PushPullParity_test {
    private let samples: Array<String> = [
        "<a/>",
        "<a><b/></a>",
        "<a x=\"1\"><b y='2'>t</b></a>",
        "<a><![CDATA[c]]></a>",
        "<a><!--c--><?p d?></a>",
        "<r xmlns:x=\"u\"><x:item a=\"1\"/></r>",
        "<a>&lt;&amp;&#65;</a>",
        "<a b=\"x\ny\"/>",
        "<a><b>1</b><c>2</c></a>"
    ]

    /** 拉模式与多回调的事件日志逐行相同。 */
    @TestCase
    public func pullEqualsPush(): Unit {
        for (sample in this.samples) {
            let viaPull = parseEventLog(sample)
            let viaPush = ArrayList<String>()
            parseWithHandler(TextInputStream(sample), LoggingHandler(viaPush), XmlParserOptions())
            assertTrue(logEquals(viaPull, viaPush.toArray()), "样本：${sample}\n拉：\n${joinLog(viaPull)}\n推：\n${joinLog(viaPush.toArray())}")
        }
    }

    /** 单回调与多回调等价（三份日志两两相等）。 */
    @TestCase
    public func singleCallbackEquivalent(): Unit {
        for (sample in this.samples) {
            let viaPull = parseEventLog(sample)
            let viaSingle = ArrayList<String>()
            XmlParser.parse(
                TextInputStream(sample),
                {event: XmlEvent =>
                    viaSingle.add(event.toString())
                    XmlAction.Continue
                }
            )
            let viaMulti = ArrayList<String>()
            parseWithHandler(TextInputStream(sample), LoggingHandler(viaMulti), XmlParserOptions())
            assertTrue(logEquals(viaPull, viaSingle.toArray()), "样本：${sample}")
            assertTrue(logEquals(viaSingle.toArray(), viaMulti.toArray()), "样本：${sample}")
        }
    }

    /** `Break`（拉模式提前结束）与 `Stop`（推模式）看到的前缀相同。 */
    @TestCase
    public func stopEqualsBreak(): Unit {
        let sample = "<a><b><c/></b><d/></a>"
        let pullPrefix = ArrayList<String>()
        let parser = XmlPullParser(text: sample, options: XmlParserOptions())
        var stop = false
        while (!stop) {
            match (parser.nextEvent()) {
                case Some(event) =>
                    pullPrefix.add(event.toString())
                    if (pullPrefix.size == 4) {
                        stop = true
                    }
                case None => stop = true
            }
        }
        let pushPrefix = ArrayList<String>()
        let limiter = LimitingHandler(pushPrefix, 4)
        parseWithHandler(TextInputStream(sample), limiter, XmlParserOptions())
        assertTrue(logEquals(pullPrefix.toArray(), pushPrefix.toArray()), joinLog(pushPrefix.toArray()))
    }

    /** `SkipSubtree` 与 `skipElement()` 的结果一致。 */
    @TestCase
    public func skipEqualsSkip(): Unit {
        let sample = "<a><b><c/></b><d/></a>"
        let viaPull = skipAt(sample, "b")

        let viaPush = ArrayList<String>()
        let skipping = SkippingHandler(viaPush, "b")
        parseWithHandler(TextInputStream(sample), skipping, XmlParserOptions())
        assertTrue(logEquals(viaPull, viaPush.toArray()), joinLog(viaPush.toArray()))
    }
}

/** 记录到 `limit` 条后返回 `Stop`。 */
internal class LimitingHandler <: XmlEventHandler {
    private let sink: ArrayList<String>
    private let limit: Int64

    init(sink: ArrayList<String>, limit: Int64) {
        this.sink = sink
        this.limit = limit
    }

    private func record(event: XmlEvent): XmlAction {
        this.sink.add(event.toString())
        if (this.sink.size >= this.limit) {
            XmlAction.Stop
        } else {
            XmlAction.Continue
        }
    }

    public func onStartDocument(): XmlAction {
        this.record(XmlEvent.StartDocument)
    }

    public func onXmlDeclaration(version: String, encoding: ?String, standalone: ?Bool): XmlAction {
        this.record(XmlEvent.XmlDeclaration(version, encoding, standalone))
    }

    public func onDocType(name: String, publicId: ?String, systemId: ?String): XmlAction {
        this.record(XmlEvent.DocType(name, publicId, systemId))
    }

    public func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        this.record(XmlEvent.StartElement(name, attrs, selfClosing))
    }

    public func onEndElement(name: QName): XmlAction {
        this.record(XmlEvent.EndElement(name))
    }

    public func onText(text: String): XmlAction {
        this.record(XmlEvent.Text(text))
    }

    public func onCData(text: String): XmlAction {
        this.record(XmlEvent.CData(text))
    }

    public func onComment(text: String): XmlAction {
        this.record(XmlEvent.Comment(text))
    }

    public func onProcessingInstruction(target: String, data: String): XmlAction {
        this.record(XmlEvent.ProcessingInstruction(target, data))
    }

    public func onEndDocument(): XmlAction {
        this.record(XmlEvent.EndDocument)
    }
}

/** 在指定元素的 StartElement 之后返回 `SkipSubtree`。 */
internal class SkippingHandler <: XmlEventHandler {
    private let sink: ArrayList<String>
    private let target: String

    init(sink: ArrayList<String>, target: String) {
        this.sink = sink
        this.target = target
    }

    private func record(event: XmlEvent): XmlAction {
        this.sink.add(event.toString())
        XmlAction.Continue
    }

    public func onStartDocument(): XmlAction {
        this.record(XmlEvent.StartDocument)
    }

    public func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction {
        this.sink.add(XmlEvent.StartElement(name, attrs, selfClosing).toString())
        if (name.local == this.target && !selfClosing) {
            XmlAction.SkipSubtree
        } else {
            XmlAction.Continue
        }
    }

    public func onEndElement(name: QName): XmlAction {
        this.record(XmlEvent.EndElement(name))
    }

    public func onText(text: String): XmlAction {
        this.record(XmlEvent.Text(text))
    }

    public func onCData(text: String): XmlAction {
        this.record(XmlEvent.CData(text))
    }

    public func onComment(text: String): XmlAction {
        this.record(XmlEvent.Comment(text))
    }

    public func onProcessingInstruction(target: String, data: String): XmlAction {
        this.record(XmlEvent.ProcessingInstruction(target, data))
    }

    public func onEndDocument(): XmlAction {
        this.record(XmlEvent.EndDocument)
    }
}
