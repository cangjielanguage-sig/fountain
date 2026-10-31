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
public class XmlPullParser_test {
    /** 自闭合产 Start + End 两条事件。 */
    @TestCase
    public func selfClosingTwoEvents(): Unit {
        let log = parseEventLog("<a><b/></a>")
        assertTrue(
            logEquals(log, ["START document", "START QName(-,a,-) attrs=0 selfClosing=false",
                "START QName(-,b,-) attrs=0 selfClosing=true", "END QName(-,b,-)",
                "END QName(-,a,-)", "END document"]),
            joinLog(log)
        )
    }

    /** `Stop` 之后不再读流。 */
    @TestCase
    public func stopStopsReading(): Unit {
        let text = "<a>" + repeatText("<b>x</b>", 2000) + "</a>"
        let full = TrackingInputStream(text)
        let parser = XmlPullParser(full, options: XmlParserOptions())
        var count: Int64 = 0
        var stop = false
        while (!stop) {
            match (parser.nextEvent()) {
                case Some(event) =>
                    count++
                    if (count == 3) {
                        break
                    }
                case None => stop = true
            }
        }
        let readsAfterStop = full.readCount
        @Assert(count == 3)

        let baseline = TrackingInputStream(text)
        let parser2 = XmlPullParser(baseline, options: XmlParserOptions())
        var draining = true
        while (draining) {
            match (parser2.nextEvent()) {
                case Some(_) => ()
                case None => draining = false
            }
        }
        assertTrue(readsAfterStop < baseline.readCount, "Stop 后不应继续读流")
    }

    /** `skipElement` 后子节点不回调，但 EndElement 仍到。 */
    @TestCase
    public func skipSubtreeStillEmitsEnd(): Unit {
        let parser = XmlPullParser(text: "<a><b><c/></b><d/></a>", options: XmlParserOptions())
        let log = ArrayList<String>()
        var skipped = false
        var done = false
        while (!done) {
            match (parser.nextEvent()) {
                case Some(event) =>
                    log.add(event.toString())
                    match (event) {
                        case XmlEvent.StartElement(name, _, selfClosing) =>
                            if (name.local == "b" && !selfClosing && !skipped) {
                                parser.skipElement()
                                skipped = true
                            }
                        case _ => ()
                    }
                case None => done = true
            }
        }
        assertTrue(
            logEquals(log.toArray(), ["START document", "START QName(-,a,-) attrs=0 selfClosing=false",
                "START QName(-,b,-) attrs=0 selfClosing=false", "END QName(-,b,-)",
                "START QName(-,d,-) attrs=0 selfClosing=true", "END QName(-,d,-)",
                "END QName(-,a,-)", "END document"]),
            joinLog(log.toArray())
        )
    }

    /** 自闭合元素上的 skip 是空操作：下一次仍是 EndElement。 */
    @TestCase
    public func skipOnSelfClosingIsNoop(): Unit {
        let parser = XmlPullParser(text: "<a/>", options: XmlParserOptions())
        @Assert(parser.nextEvent().isSome()) // StartDocument
        let start = parser.nextEvent().getOrThrow()
        match (start) {
            case XmlEvent.StartElement(_, _, selfClosing) => @Assert(selfClosing)
            case _ => assertTrue(false, "应为 StartElement")
        }
        parser.skipElement()
        match (parser.nextEvent().getOrThrow()) {
            case XmlEvent.EndElement(name) => @Assert(name.local == "a")
            case _ => assertTrue(false, "应为 EndElement")
        }
    }

    /** 非法位置调用 skipElement 报错，消息含 StartElement。 */
    @TestCase
    public func skipAtIllegalPosition(): Unit {
        let parser = XmlPullParser(text: "<a>x</a>", options: XmlParserOptions())
        @Assert(parser.nextEvent().isSome()) // StartDocument
        @Assert(parser.nextEvent().isSome()) // StartElement a
        @Assert(parser.nextEvent().isSome()) // Text
        assertXmlError({=> parser.skipElement()}, "StartElement")
    }

    /** `None` 只在 EndDocument 之后返回。 */
    @TestCase
    public func noneAfterEndDocument(): Unit {
        let parser = XmlPullParser(text: "<a/>", options: XmlParserOptions())
        var sawEnd = false
        var done = false
        while (!done) {
            match (parser.nextEvent()) {
                case Some(event) =>
                    match (event) {
                        case XmlEvent.EndDocument => sawEnd = true
                        case _ => ()
                    }
                case None => done = true
            }
        }
        @Assert(sawEnd)
        @Assert(parser.nextEvent().isNone())
    }
}
