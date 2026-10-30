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
import std.io.OutputStream
import std.unittest.*
import std.unittest.testmacro.*

/** 增量写入的独立输出缓冲（不复用 `TestSupport_test.cj` 的 helper，避免耦合）。 */
internal class IncrementalSink <: OutputStream {
    private let bytes_ = ArrayList<Byte>()

    public func write(buffer: Array<Byte>): Unit {
        for (b in buffer) {
            bytes_.add(b)
        }
    }

    public func flush(): Unit {}

    func text(): String {
        String.fromUtf8(bytes_.toArray())
    }
}

@Test
public class XmlWriterIncremental_test {
    private static func writer(options!: XmlWriterOptions = XmlWriterOptions()): (XmlWriter, IncrementalSink) {
        let sink = IncrementalSink()
        (XmlWriter(sink, options: options), sink)
    }

    /** 场景「声明 + 嵌套元素 + 文本」。 */
    @TestCase
    public func simpleDocument(): Unit {
        let (w, sink) = writer()
        w.writeDeclaration(encoding: "UTF-8")
        w.startElement(QName("a"))
        w.startElement(QName("b"))
        w.text("hi")
        w.endElement(QName("b"))
        w.endElement(QName("a"))
        w.close()
        @Assert(sink.text(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a><b>hi</b></a>")
    }

    /** 场景「空元素自闭合」。 */
    @TestCase
    public func emptyElement(): Unit {
        let (w, sink) = writer()
        w.emptyElement(QName("a"))
        w.close()
        @Assert(sink.text(), "<a/>")
    }

    /** 场景「start + end 紧邻也自闭合」。 */
    @TestCase
    public func adjacentStartEndIsSelfClosing(): Unit {
        let (w, sink) = writer()
        w.startElement(QName("a"))
        w.endElement(QName("a"))
        w.close()
        @Assert(sink.text(), "<a/>")
    }

    /** 场景「文本与属性转义与整树写一致」。 */
    @TestCase
    public func escaping(): Unit {
        let (w, sink) = writer()
        w.startElement(QName("a"), attributes: [XmlAttribute(QName("v"), "a&\"<")])
        w.text("a&<b>")
        w.endElement(QName("a"))
        w.close()
        @Assert(sink.text(), "<a v=\"a&amp;&quot;&lt;\">a&amp;&lt;b&gt;</a>")
    }

    /** 场景「命名空间只在首次引入时声明」。 */
    @TestCase
    public func namespaceDeclaredOnce(): Unit {
        let (w, sink) = writer()
        let root = QName("a", prefix: Some("x"), uri: Some("urn:x"))
        let child = QName("b", prefix: Some("x"), uri: Some("urn:x"))
        w.startElement(root)
        w.startElement(child)
        w.text("t")
        w.endElement(child)
        w.endElement(root)
        w.close()
        @Assert(sink.text(), "<x:a xmlns:x=\"urn:x\"><x:b>t</x:b></x:a>")
    }

    /** 场景「增量输出与整树输出逐字节一致」。 */
    @TestCase
    public func parityWithTreeWriter(): Unit {
        let child = XmlElement("b").withText("hi")
        let root = XmlElement("a").appendChild(XmlNode.ElementNode(child))
        let tree = writeElementText(root)

        let (w, sink) = writer()
        w.startElement(QName("a"))
        w.startElement(QName("b"))
        w.text("hi")
        w.endElement(QName("b"))
        w.endElement(QName("a"))
        w.close()
        @Assert(sink.text(), tree)
    }

    /** 场景「缩进与整树写一致」。 */
    @TestCase
    public func indentMatchesTreeWriter(): Unit {
        let options = XmlWriterOptions(indent: "  ")
        let child = XmlElement("b").withText("x")
        let root = XmlElement("a").appendChild(XmlNode.ElementNode(child))
        let tree = writeElementText(root, options: options)

        let (w, sink) = writer(options: options)
        w.startElement(QName("a"))
        w.startElement(QName("b"))
        w.text("x")
        w.endElement(QName("b"))
        w.endElement(QName("a"))
        w.close()
        @Assert(sink.text(), tree)
    }

    /** 场景「未闭合就 close 抛错」。 */
    @TestCase
    public func closeWithOpenElementThrows(): Unit {
        let (w, _) = writer()
        w.startElement(QName("a"))
        var thrown = false
        try {
            w.close()
        } catch (_: XmlException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    /** 场景「endElement 不匹配抛错」。 */
    @TestCase
    public func mismatchedEndThrows(): Unit {
        let (w, _) = writer()
        w.startElement(QName("a"))
        var thrown = false
        try {
            w.endElement(QName("b"))
        } catch (_: XmlException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    /** 场景「根外写文本抛错」。 */
    @TestCase
    public func textOutsideRootThrows(): Unit {
        let (w, _) = writer()
        var thrown = false
        try {
            w.text("x")
        } catch (_: XmlException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    /** 场景「增量模式与整树写不可混用」。 */
    @TestCase
    public func mixingWithTreeWriteThrows(): Unit {
        let (w, _) = writer()
        w.startElement(QName("a"))
        var thrown = false
        try {
            w.write(XmlElement("b"))
        } catch (_: XmlException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    /** 场景「声明只能写一次」。 */
    @TestCase
    public func declarationTwiceThrows(): Unit {
        let (w, _) = writer()
        w.writeDeclaration()
        var thrown = false
        try {
            w.writeDeclaration()
        } catch (_: XmlException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    /** 场景「flush 后仍可继续写」。 */
    @TestCase
    public func flushKeepsWriting(): Unit {
        let (w, sink) = writer()
        w.startElement(QName("a"))
        w.text("p1")
        w.flush()
        w.text("p2")
        w.endElement(QName("a"))
        w.close()
        @Assert(sink.text(), "<a>p1p2</a>")
    }
}
